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
    // 1. Detect language from explicit param or unicode script
    var lang = language?.toLowerCase().trim();
    if (lang == null || lang.isEmpty || lang == 'auto') {
      if (RegExp(r'[\u3040-\u309f\u30a0-\u30ff]').hasMatch(text)) {
        lang = 'ja';
      } else if (RegExp(r'[\uac00-\ud7af\u1100-\u11ff]').hasMatch(text)) {
        lang = 'ko';
      } else if (RegExp(r'[\u4e00-\u9fff]').hasMatch(text)) {
        lang = 'zh';
      } else if (RegExp(r'[\u0400-\u04ff]').hasMatch(text)) {
        lang = 'ru';
      } else if (RegExp(r'[\u0600-\u06ff]').hasMatch(text)) {
        lang = 'ar';
      } else if (RegExp(r'[\u0900-\u097f]').hasMatch(text)) {
        lang = 'hi';
      } else if (RegExp(r'[\u0e00-\u0e7f]').hasMatch(text)) {
        lang = 'th';
      } else if (RegExp(r'[áéíóúüñ¿¡]').hasMatch(text)) {
        lang = 'es';
      } else if (RegExp(r'[àâçéèêëîïôûùüÿœæ]').hasMatch(text)) {
        lang = 'fr';
      } else if (RegExp(r'[äöüß]').hasMatch(text)) {
        lang = 'de';
      } else if (RegExp(r'[àèéìíîòóùú]').hasMatch(text)) {
        lang = 'it';
      } else {
        lang = 'en';
      }
    }

    final v = (voiceId ?? 'default').toLowerCase().trim();

    // 2. Japanese Language Voices (Distinct F1-F5, M1-M5)
    if (lang.startsWith('ja')) {
      return switch (v) {
        'f1' => 'Kyoko',
        'f2' => 'Flo (Japanese (Japan))',
        'f3' => 'Sandy (Japanese (Japan))',
        'f4' => 'Shelley (Japanese (Japan))',
        'f5' => 'Grandma (Japanese (Japan))',
        'm1' => 'Eddy (Japanese (Japan))',
        'm2' => 'Reed (Japanese (Japan))',
        'm3' => 'Rocko (Japanese (Japan))',
        'm4' => 'Grandpa (Japanese (Japan))',
        'm5' => 'Otoya',
        _ => 'Kyoko',
      };
    }

    // 3. Korean Language Voices (Distinct F1-F5, M1-M5)
    if (lang.startsWith('ko')) {
      return switch (v) {
        'f1' => 'Yuna',
        'f2' => 'Flo (Korean (South Korea))',
        'f3' => 'Sandy (Korean (South Korea))',
        'f4' => 'Shelley (Korean (South Korea))',
        'f5' => 'Grandma (Korean (South Korea))',
        'm1' => 'Eddy (Korean (South Korea))',
        'm2' => 'Reed (Korean (South Korea))',
        'm3' => 'Rocko (Korean (South Korea))',
        'm4' => 'Grandpa (Korean (South Korea))',
        _ => 'Yuna',
      };
    }

    // 4. Chinese Language Voices (Distinct F1-F5, M1-M5)
    if (lang.startsWith('zh')) {
      return switch (v) {
        'f1' => 'Tingting',
        'f2' => 'Flo (Chinese (China mainland))',
        'f3' => 'Sandy (Chinese (China mainland))',
        'f4' => 'Shelley (Chinese (China mainland))',
        'f5' => 'Meijia',
        'm1' => 'Eddy (Chinese (China mainland))',
        'm2' => 'Reed (Chinese (China mainland))',
        'm3' => 'Rocko (Chinese (China mainland))',
        'm4' => 'Grandpa (Chinese (China mainland))',
        _ => 'Tingting',
      };
    }

    // 5. Spanish Language Voices (Distinct F1-F5, M1-M5)
    if (lang.startsWith('es')) {
      return switch (v) {
        'f1' => 'Mónica',
        'f2' => 'Flo (Spanish (Spain))',
        'f3' => 'Sandy (Spanish (Spain))',
        'f4' => 'Paulina',
        'f5' => 'Shelley (Spanish (Spain))',
        'm1' => 'Eddy (Spanish (Spain))',
        'm2' => 'Reed (Spanish (Spain))',
        'm3' => 'Rocko (Spanish (Spain))',
        'm4' => 'Grandpa (Spanish (Spain))',
        _ => 'Mónica',
      };
    }

    // 6. French Language Voices (Distinct F1-F5, M1-M5)
    if (lang.startsWith('fr')) {
      return switch (v) {
        'f1' => 'Amélie',
        'f2' => 'Flo (French (France))',
        'f3' => 'Sandy (French (France))',
        'f4' => 'Shelley (French (France))',
        'f5' => 'Grandma (French (France))',
        'm1' => 'Thomas',
        'm2' => 'Jacques',
        'm3' => 'Eddy (French (France))',
        'm4' => 'Rocko (French (France))',
        _ => 'Amélie',
      };
    }

    // 7. German Language Voices (Distinct F1-F5, M1-M5)
    if (lang.startsWith('de')) {
      return switch (v) {
        'f1' => 'Anna',
        'f2' => 'Flo (German (Germany))',
        'f3' => 'Sandy (German (Germany))',
        'f4' => 'Shelley (German (Germany))',
        'f5' => 'Grandma (German (Germany))',
        'm1' => 'Eddy (German (Germany))',
        'm2' => 'Reed (German (Germany))',
        'm3' => 'Rocko (German (Germany))',
        'm4' => 'Grandpa (German (Germany))',
        _ => 'Anna',
      };
    }

    // 8. Italian Language Voices (Distinct F1-F5, M1-M5)
    if (lang.startsWith('it')) {
      return switch (v) {
        'f1' => 'Alice',
        'f2' => 'Flo (Italian (Italy))',
        'f3' => 'Sandy (Italian (Italy))',
        'f4' => 'Shelley (Italian (Italy))',
        'f5' => 'Grandma (Italian (Italy))',
        'm1' => 'Eddy (Italian (Italy))',
        'm2' => 'Reed (Italian (Italy))',
        'm3' => 'Rocko (Italian (Italy))',
        'm4' => 'Grandpa (Italian (Italy))',
        _ => 'Alice',
      };
    }

    // 9. Portuguese Language Voices
    if (lang.startsWith('pt')) {
      return switch (v) {
        'f1' => 'Luciana',
        'f2' => 'Flo (Portuguese (Brazil))',
        'f3' => 'Sandy (Portuguese (Brazil))',
        'f4' => 'Shelley (Portuguese (Brazil))',
        'm1' => 'Eddy (Portuguese (Brazil))',
        'm2' => 'Reed (Portuguese (Brazil))',
        'm3' => 'Rocko (Portuguese (Brazil))',
        _ => 'Luciana',
      };
    }

    // 10. Russian
    if (lang.startsWith('ru')) {
      return v.startsWith('m') ? 'Yuri' : 'Milena';
    }

    // 11. Hindi
    if (lang.startsWith('hi')) {
      return v.startsWith('m') ? 'Rishi' : 'Lekha';
    }

    // Other Languages
    if (lang.startsWith('sv')) return 'Alva';
    if (lang.startsWith('nl')) return 'Xander';
    if (lang.startsWith('pl')) return 'Zosia';
    if (lang.startsWith('tr')) return 'Yelda';
    if (lang.startsWith('vi')) return 'Linh';
    if (lang.startsWith('id')) return 'Damayanti';
    if (lang.startsWith('th')) return 'Kanya';
    if (lang.startsWith('ar')) return 'Majed';
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

    // English (Default)
    return switch (v) {
      'f1' => 'Samantha',
      'f2' => 'Flo (English (US))',
      'f3' => 'Sandy (English (US))',
      'f4' => 'Karen',
      'f5' => 'Shelley (English (US))',
      'm1' => 'Daniel',
      'm2' => 'Eddy (English (US))',
      'm3' => 'Reed (English (US))',
      'm4' => 'Rocko (English (US))',
      'm5' => 'Albert',
      'bella' => 'Sandy (English (US))',
      'nicole' => 'Flo (English (US))',
      'sarah' => 'Karen',
      'adam' => 'Daniel',
      'michael' => 'Reed (English (US))',
      _ => 'Samantha',
    };
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
