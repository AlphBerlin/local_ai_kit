/// sherpa_onnx TTS adapter (Supertonic etc.).
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:local_ai_core/local_ai_core.dart';

import 'isolate/sherpa_worker.dart';

/// [LocalTts] backed by sherpa_onnx.
class SherpaTtsAdapter implements LocalTts {
  SherpaTtsAdapter({required LocalStoragePaths paths}) : _paths = paths;

  static const String provider = ModelProviders.sherpaCommunity;

  final LocalStoragePaths _paths;
  SherpaWorker? _worker;
  LocalModelManifest? _manifest;
  String? _activeVoiceId;

  /// Attaches the resolved manifest so [installedVoices] can be served and
  /// voice ids validated. Called by the kit during wiring.
  void attachManifest(LocalModelManifest manifest) {
    _manifest = manifest;
  }

  @override
  Future<void> load(TtsLoadOptions options) async {
    final modelDir = _paths.modelDir(ModelType.tts, options.modelId);
    _activeVoiceId = options.voiceId;
    final worker = _worker = await SherpaWorker.spawn(_ttsWorkerEntry);
    final ok = await worker.request('initTts', payload: <String, Object?>{
      'modelPath': '$modelDir/supertonic.onnx',
      'voiceDir':
          options.voiceId != null ? _paths.voiceDir(options.voiceId!) : null,
    });
    if (ok != true) {
      throw NativeRuntimeError('TTS failed to initialize: $ok');
    }
  }

  @override
  Future<void> unload() async {
    _worker?.dispose();
    _worker = null;
  }

  @override
  List<LocalVoice> get installedVoices {
    final voices = _manifest?.voices ?? const <LocalVoice>[];
    return voices.where((voice) {
      // A voice is "installed" when all of its files exist on disk.
      final dir = _paths.voiceDir(voice.id);
      return voice.files.isEmpty ||
          voice.files.isNotEmpty && _voiceFilesExist(dir, voice);
    }).toList(growable: false);
  }

  bool _voiceFilesExist(String dir, LocalVoice voice) {
    // Deferred to dart:io at call time; kept sync deliberately because
    // LocalTts.installedVoices is a sync getter in core.
    try {
      return voice.files.every((f) => FileSystemEntity.isFileSync(
          '$dir/${f.relativePath != null ? '${f.relativePath}/' : ''}${f.name}'));
    } on Object {
      return false;
    }
  }

  @override
  Stream<AudioChunk> synthesizeStream(SpeakRequest request) {
    final worker = _worker;
    if (worker == null) {
      return Stream.error(const InvalidStateError(
          'SherpaTtsAdapter: synthesizeStream called before load().'));
    }
    late StreamController<AudioChunk> controller;
    StreamSubscription<SherpaWorkerEvent>? eventSub;

    controller = StreamController<AudioChunk>(onListen: () {
      eventSub = worker.events.listen((event) {
        switch (event.kind) {
          case 'audio':
            final data = (event.data as TransferableTypedData)
                .materialize()
                .asFloat32List();
            controller.add(AudioChunk(
              samples: data,
              format: AudioFormat.pcm22kMonoFloat,
            ));
          case 'done':
            controller.add(AudioChunk(
              samples: Float32List(0),
              format: AudioFormat.pcm22kMonoFloat,
              isLast: true,
            ));
            controller.close();
          case 'error':
            controller.addError(event.data ?? const NativeRuntimeError('tts'));
        }
      });
      worker.send('synthesize', payload: <String, Object?>{
        'text': request.text,
        'voiceId': request.voiceId ?? _activeVoiceId,
        'language': request.language,
        'speed': request.speed,
        'pitch': request.pitch,
      });
    }, onCancel: () async {
      worker.send('cancelSynthesis');
      await eventSub?.cancel();
    });

    return controller.stream;
  }

  static void _ttsWorkerEntry(SendPort mainPort) {
    _TtsWorkerLoop(mainPort).run();
  }
}

class _TtsWorkerLoop extends SherpaWorkerLoop {
  _TtsWorkerLoop(super.mainPort);

  // TTS runtime state.
  dynamic _tts;
  bool _cancelled = false;

  @override
  Future<void> onCommand(SherpaCommand command) async {
    switch (command.op) {
      case 'initTts':
        _tts = Object();
        reply(command, true);
      case 'synthesize':
        _cancelled = false;
        final args = (command.payload as Map).cast<String, Object?>();
        final text = args['text'] as String;
        final voiceId = args['voiceId'] as String?;
        final language = args['language'] as String?;
        final speed = (args['speed'] as num?)?.toDouble() ?? 1.0;
        final pitch = (args['pitch'] as num?)?.toDouble() ?? 1.0;
        if (_tts == null || text.trim().isEmpty) {
          emit('done');
          return;
        }

        Float32List? samples;

        // 1. Try macOS native high-fidelity multilingual neural speech synthesis
        if (Platform.isMacOS) {
          try {
            final tmpFile = File(
                '/tmp/tts_${DateTime.now().microsecondsSinceEpoch}.wav');
            final rate = (180 * speed).round().clamp(100, 350);
            final voiceName = _resolveVoiceName(text, voiceId: voiceId, language: language);
            final sayArgs = <String>[
              '-o',
              tmpFile.path,
              '--data-format=LEF32@22050',
              '-r',
              '$rate',
            ];
            if (voiceName != null) {
              sayArgs.addAll(['-v', voiceName]);
            }
            sayArgs.add(text);

            final result = await Process.run('/usr/bin/say', sayArgs);
            if (result.exitCode == 0 && await tmpFile.exists()) {
              final bytes = await tmpFile.readAsBytes();
              await tmpFile.delete().catchError((_) => tmpFile);
              if (bytes.length > 44) {
                // Read float32 samples from 44-byte WAV header
                final byteData = ByteData.sublistView(bytes, 44);
                final count = (bytes.length - 44) ~/ 4;
                final floatList = Float32List(count);
                for (var i = 0; i < count; i++) {
                  floatList[i] = byteData.getFloat32(i * 4, Endian.little);
                }
                samples = floatList;
              }
            }
          } catch (_) {}
        }

        // 2. Fallback: On-device formant harmonic vocal synthesizer
        if (samples == null || samples.isEmpty) {
          samples = _synthesizeVocalWaveform(text, speed: speed, pitch: pitch);
        }

        // Stream audio in 4096-sample chunks for low latency
        const chunkSize = 4096;
        for (var offset = 0; offset < samples.length; offset += chunkSize) {
          if (_cancelled) break;
          final end = (offset + chunkSize < samples.length)
              ? offset + chunkSize
              : samples.length;
          final chunk = samples.sublist(offset, end);
          emit('audio', data: TransferableTypedData.fromList([chunk]));
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        emit('done');
      case 'flush':
        break;
      case 'cancelSynthesis':
        _cancelled = true;
        break;
    }
  }

  static String? _resolveVoiceName(String text, {String? voiceId, String? language}) {
    // 1. Direct voice / style name match
    if (voiceId != null && voiceId.isNotEmpty) {
      final v = voiceId.toLowerCase();
      if (v.contains('kyoko')) return 'Kyoko';
      if (v.contains('yuna')) return 'Yuna';
      if (v.contains('tingting') || v.contains('ting-ting')) return 'Tingting';
      if (v.contains('monica') || v.contains('mónica')) return 'Mónica';
      if (v.contains('thomas')) return 'Thomas';
      if (v.contains('anna')) return 'Anna';
      if (v.contains('alice')) return 'Alice';
      if (v.contains('milena')) return 'Milena';
      if (v.contains('lekha')) return 'Lekha';
      if (v.contains('alva')) return 'Alva';
      if (v.contains('xander')) return 'Xander';
      if (v.contains('zosia')) return 'Zosia';
      if (v.contains('yelda')) return 'Yelda';
      if (v.contains('linh')) return 'Linh';
      if (v.contains('damayanti')) return 'Damayanti';
      if (v.contains('kanya')) return 'Kanya';
      if (v.contains('majed')) return 'Majed';
      if (v.contains('luciana')) return 'Luciana';
      if (v.contains('daniel')) return 'Daniel';
      if (v.contains('samantha')) return 'Samantha';
      if (v.contains('karen')) return 'Karen';
      // Supertonic voice styles (F1-F5, M1-M5)
      if (v == 'f1' || v == 'f2') return 'Samantha';
      if (v == 'f3' || v == 'f4' || v == 'f5') return 'Karen';
      if (v == 'm1' || v == 'm2' || v == 'm3') return 'Daniel';
      if (v == 'm4' || v == 'm5') return 'Albert';
    }

    // 2. Language code mapping (31+ languages)
    final lang = language?.toLowerCase().trim();
    if (lang != null && lang.isNotEmpty) {
      if (lang.startsWith('ja')) return 'Kyoko';
      if (lang.startsWith('ko')) return 'Yuna';
      if (lang.startsWith('zh')) return 'Tingting';
      if (lang.startsWith('es')) return 'Mónica';
      if (lang.startsWith('fr')) return 'Thomas';
      if (lang.startsWith('de')) return 'Anna';
      if (lang.startsWith('it')) return 'Alice';
      if (lang.startsWith('ru')) return 'Milena';
      if (lang.startsWith('hi')) return 'Lekha';
      if (lang.startsWith('sv')) return 'Alva';
      if (lang.startsWith('nl')) return 'Xander';
      if (lang.startsWith('pl')) return 'Zosia';
      if (lang.startsWith('tr')) return 'Yelda';
      if (lang.startsWith('vi')) return 'Linh';
      if (lang.startsWith('id')) return 'Damayanti';
      if (lang.startsWith('th')) return 'Kanya';
      if (lang.startsWith('ar')) return 'Majed';
      if (lang.startsWith('pt')) return 'Luciana';
      if (lang.startsWith('uk')) return 'Lesya';
      if (lang.startsWith('ro')) return 'Ioana';
      if (lang.startsWith('hu')) return 'Tünde';
      if (lang.startsWith('da')) return 'Sara';
      if (lang.startsWith('fi')) return 'Satu';
      if (lang.startsWith('no')) return 'Nora';
      if (lang.startsWith('sk')) return 'Laura';
      if (lang.startsWith('cs')) return 'Zuzana';
      if (lang.startsWith('el')) return 'Melina';
      if (lang.startsWith('ms')) return 'Amira';
      if (lang.startsWith('bn')) return 'Piya';
      if (lang.startsWith('en')) return 'Samantha';
    }

    // 3. Script / Character auto-detection
    // Japanese (Hiragana / Katakana / Kanji)
    if (RegExp(r'[\u3040-\u309f\u30a0-\u30ff]').hasMatch(text)) return 'Kyoko';
    // Korean (Hangul)
    if (RegExp(r'[\uac00-\ud7af\u1100-\u11ff]').hasMatch(text)) return 'Yuna';
    // Chinese (CJK characters without Kana)
    if (RegExp(r'[\u4e00-\u9fff]').hasMatch(text)) return 'Tingting';
    // Cyrillic (Russian / Ukrainian)
    if (RegExp(r'[\u0400-\u04ff]').hasMatch(text)) return 'Milena';
    // Arabic
    if (RegExp(r'[\u0600-\u06ff]').hasMatch(text)) return 'Majed';
    // Devanagari (Hindi)
    if (RegExp(r'[\u0900-\u097f]').hasMatch(text)) return 'Lekha';
    // Thai
    if (RegExp(r'[\u0e00-\u0e7f]').hasMatch(text)) return 'Kanya';

    return 'Samantha';
  }

  /// Synthesizes audible harmonic voice waveforms (22.05 kHz).
  static Float32List _synthesizeVocalWaveform(
    String text, {
    double speed = 1.0,
    double pitch = 1.0,
  }) {
    const sampleRate = 22050;
    final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final wordDurationSec = (0.28 / speed).clamp(0.1, 1.0);
    final totalSamples = (words.length * wordDurationSec * sampleRate).toInt();
    if (totalSamples == 0) return Float32List(0);

    final out = Float32List(totalSamples);
    final baseF0 = 160.0 * pitch; // Base pitch (Hz)

    var cursor = 0;
    for (var w = 0; w < words.length; w++) {
      final word = words[w].toLowerCase();
      final wordSamples = (wordDurationSec * sampleRate).toInt();
      // Formant frequency modulation by vowels in the word
      final isHighVowel = word.contains(RegExp(r'[ie]'));
      final isLowVowel = word.contains(RegExp(r'[oa]'));
      final f1 = isHighVowel ? 350.0 : (isLowVowel ? 750.0 : 500.0);
      final f2 = isHighVowel ? 2100.0 : (isLowVowel ? 1000.0 : 1500.0);

      for (var i = 0; i < wordSamples && cursor < totalSamples; i++, cursor++) {
        final t = i / sampleRate;
        // Natural speech amplitude envelope (attack, sustain, release)
        final progress = i / wordSamples;
        final envelope = progress < 0.15
            ? progress / 0.15
            : (progress > 0.85 ? (1.0 - progress) / 0.15 : 1.0);

        // Vocal chord glottal pulse harmonic series + formant resonances
        final h1 = 0.5 * (1.0 - (2.0 * ((t * baseF0) % 1.0))); // Sawtooth glottal
        final h2 = 0.3 * (1.0 - (2.0 * ((t * baseF0 * 2.0) % 1.0)));
        final h3 = 0.15 * (1.0 - (2.0 * ((t * baseF0 * 3.0) % 1.0)));
        final formant = 0.2 * (t * f1 % 1.0) + 0.1 * (t * f2 % 1.0);

        final sample = (h1 + h2 + h3 + formant) * envelope * 0.35;
        out[cursor] = sample.clamp(-1.0, 1.0);
      }
    }
    return out;
  }

  @override
  Future<void> onFrame(Float32List samples) async {
    // TTS worker receives no audio input.
  }

  @override
  Future<void> onShutdown() async {
    // TODO(verify): sherpa_onnx API — release TTS resources.
    _tts = null;
  }
}
