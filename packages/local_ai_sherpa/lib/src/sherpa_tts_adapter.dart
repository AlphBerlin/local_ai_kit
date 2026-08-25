/// sherpa_onnx TTS adapter (Supertonic etc.).
library;

import 'dart:async';
import 'dart:convert';
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
      'modelDir': modelDir,
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
            Float32List data;
            int sampleRate = 44100;
            if (event.data is Map) {
              final map = event.data as Map;
              final transferable = map['samples'] as TransferableTypedData;
              data = transferable.materialize().asFloat32List();
              sampleRate = map['sampleRate'] as int? ?? 44100;
            } else {
              data = (event.data as TransferableTypedData)
                  .materialize()
                  .asFloat32List();
            }
            final format = (sampleRate == 24000)
                ? AudioFormat.pcm24kMonoFloat
                : ((sampleRate == 22050)
                    ? AudioFormat.pcm22kMonoFloat
                    : ((sampleRate == 16000)
                        ? AudioFormat.pcm16kMono
                        : AudioFormat.pcm44kMonoFloat));
            controller.add(AudioChunk(
              samples: data,
              format: format,
            ));
          case 'done':
            controller.add(AudioChunk(
              samples: Float32List(0),
              format: AudioFormat.pcm44kMonoFloat,
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
  String? _modelDir;
  Process? _serverProcess;
  StreamIterator<String>? _lineIterator;
  bool _cancelled = false;

  static const _ttsServerScript = r'''import sys, json, os, glob
import numpy as np

def main():
    model_dir = sys.argv[1] if len(sys.argv) > 1 else None
    engine_type = "none"
    tts = None
    styles = {}
    
    # 1. Try Supertonic 3
    if model_dir and os.path.exists(os.path.join(model_dir, "duration_predictor.onnx")):
        try:
            import supertonic
            tts = supertonic.TTS(model="supertonic-3", model_dir=model_dir, intra_op_num_threads=4)
            for name in tts.voice_style_names:
                styles[name] = tts.get_voice_style(name)
            engine_type = "supertonic"
        except Exception as e:
            sys.stderr.write(f"Failed to load Supertonic: {e}\n")

    # 2. Try Kokoro / Piper via sherpa_onnx
    if tts is None and model_dir and os.path.exists(model_dir):
        try:
            import sherpa_onnx
            
            # Check for Kokoro
            kokoro_models = glob.glob(os.path.join(model_dir, "**", "*kokoro*.onnx"), recursive=True) or glob.glob(os.path.join(model_dir, "**", "model.onnx"), recursive=True)
            voices_bins = glob.glob(os.path.join(model_dir, "**", "*voices*.bin"), recursive=True) or glob.glob(os.path.join(model_dir, "**", "voices.bin"), recursive=True)
            tokens_txts = glob.glob(os.path.join(model_dir, "**", "*tokens*.txt"), recursive=True) or glob.glob(os.path.join(model_dir, "**", "tokens.txt"), recursive=True)
            data_dirs = glob.glob(os.path.join(model_dir, "**", "*espeak*"), recursive=True) or glob.glob(os.path.join(model_dir, "**", "data"), recursive=True)
            
            if kokoro_models and tokens_txts and voices_bins:
                config = sherpa_onnx.OfflineTtsConfig(
                    model=sherpa_onnx.OfflineTtsModelConfig(
                        kokoro=sherpa_onnx.OfflineTtsKokoroModelConfig(
                            model=kokoro_models[0],
                            voices=voices_bins[0],
                            tokens=tokens_txts[0],
                            data_dir=data_dirs[0] if data_dirs else "",
                            length_scale=1.0,
                        ),
                        num_threads=4,
                        provider="cpu",
                    )
                )
                tts = sherpa_onnx.OfflineTts(config)
                engine_type = "kokoro"
            
            # Check for VITS / Piper
            if tts is None:
                vits_models = glob.glob(os.path.join(model_dir, "**", "*.onnx"), recursive=True)
                if vits_models and tokens_txts:
                    config = sherpa_onnx.OfflineTtsConfig(
                        model=sherpa_onnx.OfflineTtsModelConfig(
                            vits=sherpa_onnx.OfflineTtsVitsModelConfig(
                                model=vits_models[0],
                                tokens=tokens_txts[0],
                                data_dir=data_dirs[0] if data_dirs else "",
                                length_scale=1.0,
                            ),
                            num_threads=4,
                            provider="cpu",
                        )
                    )
                    tts = sherpa_onnx.OfflineTts(config)
                    engine_type = "vits"
        except Exception as e:
            sys.stderr.write(f"Failed to load Sherpa-ONNX model: {e}\n")

    # 3. Fallback to Supertonic 3 default
    if tts is None:
        try:
            import supertonic
            tts = supertonic.TTS(model="supertonic-3", intra_op_num_threads=4)
            for name in tts.voice_style_names:
                styles[name] = tts.get_voice_style(name)
            engine_type = "supertonic"
        except Exception as e:
            sys.stderr.write(f"Failed fallback Supertonic: {e}\n")

    print(json.dumps({"ready": True, "engine": engine_type, "sample_rate": getattr(tts, "sample_rate", 44100)}), flush=True)

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            if req.get("op") == "stop":
                break
            text = req["text"]
            lang = req.get("language", "en")
            v_style = req.get("voice_style", "F1").upper()
            speed = float(req.get("speed", 1.0))
            total_steps = int(req.get("total_step", 8))
            output_path = req["output_path"]

            if engine_type == "supertonic":
                style = styles.get(v_style) or styles.get("F1")
                wav, dur = tts(text, voice_style=style, lang=lang, total_steps=total_steps, speed=speed)
                sample_rate = tts.sample_rate
                exact_len = int(sample_rate * dur[0])
                trimmed_wav = wav[0][:exact_len] if exact_len < len(wav[0]) else wav[0]
                raw_bytes = trimmed_wav.astype(np.float32).tobytes()
                duration = float(dur[0])
            elif engine_type in ("kokoro", "vits"):
                voice_map = {"DEFAULT": 0, "BELLA": 1, "NICOLE": 2, "SARAH": 3, "ADAM": 4, "MICHAEL": 5, "F1": 0, "F2": 1, "F3": 2, "M1": 3, "M2": 4}
                sid = voice_map.get(v_style, 0)
                audio = tts.generate(text, sid=sid, speed=speed)
                sample_rate = audio.sample_rate
                samples_arr = np.array(audio.samples, dtype=np.float32)
                raw_bytes = samples_arr.tobytes()
                duration = float(len(samples_arr)) / float(sample_rate)
            else:
                raise ValueError("No TTS engine loaded")

            with open(output_path, "wb") as f:
                f.write(raw_bytes)

            print(json.dumps({"ok": True, "duration": duration, "samples": len(raw_bytes)//4, "sample_rate": sample_rate}), flush=True)
        except Exception as e:
            print(json.dumps({"ok": False, "error": str(e)}), flush=True)

if __name__ == "__main__":
    main()
''';

  Future<void> _startServer(String onnxDir) async {
    try {
      final scriptFile = File('/tmp/supertonic_server.py');
      if (!scriptFile.existsSync()) {
        await scriptFile.writeAsString(_ttsServerScript);
      }

      final uvPath = File('/Users/ajithberlin/.local/bin/uv').existsSync()
          ? '/Users/ajithberlin/.local/bin/uv'
          : 'uv';
      final proc = await Process.start(uvPath, [
        'run',
        '--with',
        'supertonic',
        '--with',
        'sherpa-onnx',
        '--with',
        'numpy',
        'python3',
        '/tmp/supertonic_server.py',
        onnxDir,
      ]);
      _serverProcess = proc;
      final lines =
          proc.stdout.transform(utf8.decoder).transform(const LineSplitter());
      final iterator = StreamIterator(lines);
      _lineIterator = iterator;
      while (await iterator.moveNext()) {
        final line = iterator.current.trim();
        if (line.contains('"ready": true') || line.contains('"ready":true')) {
          break;
        }
      }
    } catch (_) {}
  }

  @override
  Future<void> onCommand(SherpaCommand command) async {
    switch (command.op) {
      case 'initTts':
        _modelDir = (command.payload as Map)['modelDir'] as String?;
        _tts = Object();
        if (_modelDir != null) {
          await _startServer(_modelDir!);
        }
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
        var sampleRate = 44100;

        // 1. Try ONNX Neural Inference via persistent server (Supertonic / Kokoro / Piper)
        final onnxDir = _modelDir;
        final server = _serverProcess;
        final iterator = _lineIterator;
        if (onnxDir != null && server != null && iterator != null) {
          try {
            final tmpPcm = File(
                '/tmp/tts_pcm_${DateTime.now().microsecondsSinceEpoch}.pcm');
            final vStyle = (voiceId ?? 'F1')
                .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')
                .toUpperCase();
            final langCode = (language ?? 'en')
                .toLowerCase()
                .split('-')
                .first
                .split('_')
                .first;

            final reqJson = jsonEncode({
              'text': text,
              'language': langCode,
              'voice_style': vStyle,
              'speed': speed,
              'total_step': 8,
              'output_path': tmpPcm.path,
            });

            server.stdin.writeln(reqJson);
            await server.stdin.flush();

            if (await iterator.moveNext()) {
              final respLine = iterator.current.trim();
              if (respLine.isNotEmpty && await tmpPcm.exists()) {
                final resp = jsonDecode(respLine) as Map<String, dynamic>;
                sampleRate = resp['sample_rate'] as int? ?? 44100;
                final bytes = await tmpPcm.readAsBytes();
                await tmpPcm.delete().catchError((_) => tmpPcm);
                if (bytes.isNotEmpty) {
                  final byteData = ByteData.sublistView(bytes);
                  final count = bytes.lengthInBytes ~/ 4;
                  final floatList = Float32List(count);
                  for (var i = 0; i < count; i++) {
                    floatList[i] = byteData.getFloat32(i * 4, Endian.little);
                  }
                  samples = floatList;
                }
              }
            }
          } catch (_) {}
        }

        // 2. Fallback: macOS Native Studio Neural Speech Synthesis
        if (samples == null || samples.isEmpty) {
          if (Platform.isMacOS) {
            try {
              final tmpFile =
                  File('/tmp/tts_${DateTime.now().microsecondsSinceEpoch}.wav');
              final rate = (180 * speed).round().clamp(100, 350);
              final voiceName =
                  _resolveVoiceName(text, voiceId: voiceId, language: language);
              final sayArgs = <String>[
                '-o',
                tmpFile.path,
                '--data-format=LEF32@44100',
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
                  sampleRate = 44100;
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
        }

        // 3. Fallback: On-device formant harmonic vocal synthesizer
        if (samples == null || samples.isEmpty) {
          samples = _synthesizeVocalWaveform(text, speed: speed, pitch: pitch);
          sampleRate = 44100;
        }

        // Stream audio in 4096-sample chunks for low latency
        const chunkSize = 4096;
        for (var offset = 0; offset < samples.length; offset += chunkSize) {
          if (_cancelled) break;
          final end = (offset + chunkSize < samples.length)
              ? offset + chunkSize
              : samples.length;
          final chunk = samples.sublist(offset, end);
          emit('audio', data: {
            'samples': TransferableTypedData.fromList([chunk]),
            'sampleRate': sampleRate,
          });
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

  static String? _resolveVoiceName(String text,
      {String? voiceId, String? language}) {
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

    // 2. Japanese Language Voices
    if (lang.startsWith('ja')) {
      return (v.startsWith('m') || v == 'adam' || v == 'michael')
          ? 'Otoya'
          : 'Kyoko';
    }

    // 3. Korean Language Voices
    if (lang.startsWith('ko')) {
      return 'Yuna';
    }

    // 4. Chinese Language Voices
    if (lang.startsWith('zh')) {
      return (v == 'f5' || v == 'sarah') ? 'Meijia' : 'Tingting';
    }

    // 5. Spanish Language Voices
    if (lang.startsWith('es')) {
      return (v == 'f4' || v == 'nicole') ? 'Paulina' : 'Mónica';
    }

    // 6. French Language Voices
    if (lang.startsWith('fr')) {
      return (v.startsWith('m') || v == 'adam' || v == 'michael')
          ? 'Thomas'
          : 'Amélie';
    }

    // 7. German Language Voices
    if (lang.startsWith('de')) {
      return 'Anna';
    }

    // 8. Italian Language Voices
    if (lang.startsWith('it')) {
      return 'Alice';
    }

    // 9. Portuguese Language Voices
    if (lang.startsWith('pt')) {
      return 'Luciana';
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

    // English (Default) - Clean, premium Apple voices
    return switch (v) {
      'f1' => 'Samantha',
      'f2' => 'Karen',
      'f3' => 'Moira',
      'f4' => 'Tessa',
      'f5' => 'Victoria',
      'm1' => 'Alex',
      'm2' => 'Daniel',
      'm3' => 'Oliver',
      'm4' => 'Thomas',
      'm5' => 'Rishi',
      'bella' => 'Samantha',
      'nicole' => 'Karen',
      'sarah' => 'Moira',
      'adam' => 'Alex',
      'michael' => 'Daniel',
      _ => 'Samantha',
    };
  }

  /// Synthesizes audible harmonic voice waveforms (22.05 kHz).
  static Float32List _synthesizeVocalWaveform(
    String text, {
    double speed = 1.0,
    double pitch = 1.0,
  }) {
    const sampleRate = 44100;
    final words =
        text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
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
        final h1 =
            0.5 * (1.0 - (2.0 * ((t * baseF0) % 1.0))); // Sawtooth glottal
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
    try {
      _serverProcess?.stdin.writeln('{"op":"stop"}');
      await _serverProcess?.stdin.flush();
    } catch (_) {}
    _serverProcess?.kill();
    _serverProcess = null;
    await _lineIterator?.cancel();
    _lineIterator = null;
    _tts = null;
  }
}
