/// SenseVoice / Zipformer / Whisper (sherpa_onnx) STT adapter.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:local_ai_core/local_ai_core.dart';

import 'isolate/sherpa_worker.dart';
import 'sherpa_stt_model_layout.dart';

/// [LocalStt] backed by sherpa_onnx (SenseVoice, Zipformer, Whisper).
class SherpaSttAdapter implements LocalStt {
  SherpaSttAdapter({required LocalStoragePaths paths}) : _paths = paths;

  static const String provider = ModelProviders.sherpaCommunity;

  final LocalStoragePaths _paths;
  SherpaWorker? _worker;

  @override
  Future<void> load(SttLoadOptions options) async {
    final modelDir = _paths.modelDir(ModelType.stt, options.modelId);
    final worker = _worker = await SherpaWorker.spawn(_sttWorkerEntry);
    final ok =
        await worker.request('initRecognizer', payload: <String, Object?>{
      'modelDir': modelDir,
      'modelKind': sherpaSttModelKindForId(options.modelId).name,
      'cacheDir': _paths.cacheDir,
      'language': options.language,
      'enablePunctuation': options.enablePunctuation,
    });
    if (ok != true) {
      throw NativeRuntimeError('STT recognizer failed to init: $ok');
    }
  }

  @override
  Future<void> unload() async {
    _worker?.dispose();
    _worker = null;
  }

  @override
  Stream<TranscriptEvent> transcribeStream(
    Stream<AudioFrame> audio, {
    SttOptions? options,
  }) {
    final worker = _worker;
    if (worker == null) {
      return Stream.error(const InvalidStateError(
          'SherpaSttAdapter: transcribeStream called before load().'));
    }
    late StreamController<TranscriptEvent> controller;
    StreamSubscription<AudioFrame>? audioSub;
    StreamSubscription<SherpaWorkerEvent>? eventSub;
    final buffer = <AudioFrame>[];

    controller = StreamController<TranscriptEvent>(onListen: () {
      eventSub = worker.events.listen((event) {
        switch (event.kind) {
          case 'partial':
            controller.add(TranscriptPartial(event.data as String? ?? ''));
          case 'final':
            controller.add(
                TranscriptFinal(Transcript(text: event.data as String? ?? '')));
          case 'error':
            controller.addError(event.data ?? const NativeRuntimeError('stt'));
        }
      });
      worker.send('startUtterance');
      audioSub = audio.listen(
        (frame) {
          buffer.add(frame);
          worker.sendFrame(frame.samples);
        },
        onDone: () async {
          if (buffer.isNotEmpty) {
            final t = await transcribe(AudioBuffer.fromFrames(buffer));
            controller.add(TranscriptFinal(t));
          }
          worker.send('endUtterance');
          await controller.close();
        },
        onError: controller.addError,
      );
    }, onCancel: () async {
      await audioSub?.cancel();
      await eventSub?.cancel();
    });

    return controller.stream;
  }

  @override
  Future<Transcript> transcribe(AudioBuffer audio,
      {SttOptions? options}) async {
    final worker = _worker;
    if (worker == null) {
      throw const InvalidStateError(
          'SherpaSttAdapter: transcribe called before load().');
    }
    final result = await worker.request('decodeBuffer', payload: {
      'samples': TransferableTypedData.fromList([audio.samples]),
      'sampleRate': audio.format.sampleRate,
    });
    return Transcript(text: result as String? ?? '');
  }

  static void _sttWorkerEntry(SendPort mainPort) {
    _SttWorkerLoop(mainPort).run();
  }
}

class _SttWorkerLoop extends SherpaWorkerLoop {
  _SttWorkerLoop(super.mainPort);

  String? _modelDir;
  Process? _serverProcess;
  StreamIterator<String>? _lineIterator;

  static const _sttServerScript = r'''import sys, json, os, glob
import numpy as np

def main():
    model_dir = sys.argv[1] if len(sys.argv) > 1 else None
    model_kind = sys.argv[2] if len(sys.argv) > 2 else 'auto'
    recognizer = None
    engine_type = 'none'
    is_online = False

    if model_dir and os.path.exists(model_dir):
        try:
            import sherpa_onnx
            
            tokens = glob.glob(os.path.join(model_dir, '**', '*tokens*.txt'), recursive=True)
            joiners = glob.glob(os.path.join(model_dir, '**', '*joiner*.onnx'), recursive=True)
            encoders = glob.glob(os.path.join(model_dir, '**', '*encoder*.onnx'), recursive=True)
            decoders = glob.glob(os.path.join(model_dir, '**', '*decoder*.onnx'), recursive=True)

            # Dolphin is a single-model offline CTC recognizer. Keep this
            # branch ahead of SenseVoice because both archives use
            # model*.onnx plus tokens.txt.
            if model_kind == 'dolphin':
                dolphin_models = glob.glob(os.path.join(model_dir, '**', 'model*.onnx'), recursive=True)
                if dolphin_models and tokens:
                    recognizer = sherpa_onnx.OfflineRecognizer.from_dolphin_ctc(
                        model=dolphin_models[0],
                        tokens=tokens[0],
                        num_threads=4,
                    )
                    engine_type = 'dolphin'
                    is_online = False

            # Moonshine v2 uses two ORT files instead of Moonshine v1's four
            # ONNX files. The explicit model kind also prevents these generic
            # encoder/decoder names from being mistaken for Whisper.
            if recognizer is None and model_kind == 'moonshineV2':
                v2_encoders = glob.glob(os.path.join(model_dir, '**', 'encoder_model.ort'), recursive=True)
                merged_decoders = glob.glob(os.path.join(model_dir, '**', 'decoder_model_merged.ort'), recursive=True)
                if v2_encoders and merged_decoders and tokens:
                    recognizer = sherpa_onnx.OfflineRecognizer.from_moonshine_v2(
                        encoder=v2_encoders[0],
                        decoder=merged_decoders[0],
                        tokens=tokens[0],
                        num_threads=4,
                    )
                    engine_type = 'moonshine_v2'
                    is_online = False

            # Heuristic fallback is retained for external/legacy manifests.
            # Built-in Dolphin and Moonshine manifests arrive with an
            # explicit model kind above.
            if recognizer is None and model_kind == 'auto' and encoders and decoders and not joiners and tokens:
                recognizer = sherpa_onnx.OfflineRecognizer.from_whisper(
                    encoder=encoders[0],
                    decoder=decoders[0],
                    tokens=tokens[0],
                    language='',
                    task='transcribe',
                    num_threads=4,
                )
                engine_type = 'whisper'
                is_online = False

            # 2. Moonshine (Offline Recognizer)
            if recognizer is None and model_kind in ('auto', 'moonshineV1'):
                preprocessors = glob.glob(os.path.join(model_dir, '**', '*preprocess*.onnx'), recursive=True)
                uncached_dec = glob.glob(os.path.join(model_dir, '**', '*uncached_decode*.onnx'), recursive=True)
                cached_dec = glob.glob(os.path.join(model_dir, '**', '*cached_decode*.onnx'), recursive=True)
                m_encoders = glob.glob(os.path.join(model_dir, '**', '*encode*.onnx'), recursive=True)
                if preprocessors and m_encoders and uncached_dec and cached_dec and tokens:
                    recognizer = sherpa_onnx.OfflineRecognizer.from_moonshine(
                        preprocessor=preprocessors[0],
                        encoder=m_encoders[0],
                        uncached_decoder=uncached_dec[0],
                        cached_decoder=cached_dec[0],
                        tokens=tokens[0],
                        num_threads=4,
                    )
                    engine_type = 'moonshine'
                    is_online = False

            # 3. SenseVoice (Offline Recognizer)
            if recognizer is None:
                sense_models = glob.glob(os.path.join(model_dir, '**', '*model*int8*.onnx'), recursive=True) or glob.glob(os.path.join(model_dir, '**', '*model*.onnx'), recursive=True)
                if sense_models and tokens:
                    recognizer = sherpa_onnx.OfflineRecognizer.from_sense_voice(
                        model=sense_models[0],
                        tokens=tokens[0],
                        num_threads=4,
                        use_itn=True,
                    )
                    engine_type = 'sense_voice'
                    is_online = False

            # 4. Zipformer / Transducer (Online Recognizer)
            if recognizer is None and encoders and decoders and joiners and tokens:
                int8_enc = [e for e in encoders if 'int8' in e]
                int8_dec = [d for d in decoders if 'int8' in d]
                int8_join = [j for j in joiners if 'int8' in j]
                enc_file = int8_enc[0] if int8_enc else encoders[0]
                dec_file = int8_dec[0] if int8_dec else decoders[0]
                join_file = int8_join[0] if int8_join else joiners[0]
                
                recognizer = sherpa_onnx.OnlineRecognizer.from_transducer(
                    encoder=enc_file,
                    decoder=dec_file,
                    joiner=join_file,
                    tokens=tokens[0],
                    num_threads=4,
                    decoding_method='modified_beam_search',
                    max_active_paths=4,
                )
                engine_type = 'transducer'
                is_online = True

        except Exception as e:
            sys.stderr.write(f'Failed to load Sherpa-ONNX ASR: {e}\n')

    print(json.dumps({'ready': True, 'engine': engine_type, 'is_online': is_online}), flush=True)

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            if req.get('op') == 'stop':
                break
            input_pcm = req.get('input_path')
            sample_rate = int(req.get('sample_rate', 16000))
            
            if not input_pcm or not os.path.exists(input_pcm):
                print(json.dumps({'ok': False, 'error': 'File not found'}), flush=True)
                continue
                
            with open(input_pcm, 'rb') as f:
                raw_bytes = f.read()
            samples = np.frombuffer(raw_bytes, dtype=np.float32)
            
            # 1. Gain normalization: scale peak sample to 0.85 so quiet speech is amplified
            if len(samples) > 0:
                max_val = np.max(np.abs(samples))
                if max_val > 0.001:
                    samples = samples * (0.85 / max_val)
                # 2. Add clean 300ms trailing silence pad for complete token decoding
                post_pad = np.zeros(int(sample_rate * 0.3), dtype=np.float32)
                samples = np.concatenate([samples, post_pad])

            text = ''
            if recognizer is not None and len(samples) > 0:
                stream = recognizer.create_stream()
                if is_online:
                    stream.accept_waveform(sample_rate, samples)
                    stream.input_finished()
                    while recognizer.is_ready(stream):
                        recognizer.decode_stream(stream)
                    res = recognizer.get_result(stream)
                    text = res if isinstance(res, str) else getattr(res, 'text', str(res))
                else:
                    stream.accept_waveform(sample_rate, samples)
                    recognizer.decode_stream(stream)
                    res = stream.result
                    text = res.text if hasattr(res, 'text') else str(res)
            
            # Clean ITN and formatting tags
            import re
            text = re.sub(r'<\|.*?\|>', '', text).strip()
            # Normalize casing for CTC/Transducer models (e.g. 'HELLO' -> 'Hello')
            if text.isupper() and len(text) > 1:
                words = text.split()
                acronyms = {'AI', 'LLM', 'VAD', 'STT', 'TTS', 'CPU', 'GPU', 'UI', 'API', 'RAM', 'ML', 'ASR', 'OK'}
                res_words = []
                for i, w in enumerate(words):
                    if w in acronyms:
                        res_words.append(w)
                    elif i == 0:
                        res_words.append(w.capitalize())
                    else:
                        res_words.append(w.lower())
                text = ' '.join(res_words)
            elif len(text) == 1:
                text = text.upper()
            else:
                text = ' '.join(text.split())
            
            print(json.dumps({'ok': True, 'text': text}), flush=True)
        except Exception as e:
            print(json.dumps({'ok': False, 'error': str(e)}), flush=True)

if __name__ == '__main__':
    main()
''';

  String _cacheDir = '/tmp';

  Future<void> _startServer(
    String modelDir, {
    required SherpaSttModelKind modelKind,
  }) async {
    try {
      final cacheDirObj = Directory(_cacheDir);
      if (!cacheDirObj.existsSync()) {
        cacheDirObj.createSync(recursive: true);
      }
      final scriptFile = File('$_cacheDir/sherpa_stt_server.py');
      await scriptFile.writeAsString(_sttServerScript);

      final uvPath = File('/Users/ajithberlin/.local/bin/uv').existsSync()
          ? '/Users/ajithberlin/.local/bin/uv'
          : 'uv';
      final proc = await Process.start(uvPath, [
        'run',
        '--with',
        'sherpa-onnx',
        '--with',
        'numpy',
        'python3',
        scriptFile.path,
        modelDir,
        modelKind.name,
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
      case 'initRecognizer':
        final args = (command.payload as Map).cast<String, Object?>();
        _modelDir = args['modelDir'] as String?;
        _cacheDir = args['cacheDir'] as String? ?? '/tmp';
        if (_modelDir != null) {
          final modelKindName = args['modelKind'] as String? ?? 'auto';
          final modelKind = SherpaSttModelKind.values.firstWhere(
            (kind) => kind.name == modelKindName,
            orElse: () => SherpaSttModelKind.auto,
          );
          await _startServer(_modelDir!, modelKind: modelKind);
        }
        reply(command, true);
      case 'startUtterance':
        break;
      case 'endUtterance':
        break;
      case 'decodeBuffer':
        final args = (command.payload as Map).cast<String, Object?>();
        final samples = (args['samples'] as TransferableTypedData)
            .materialize()
            .asFloat32List();
        final sampleRate = (args['sampleRate'] as num?)?.toInt() ?? 16000;

        var recognizedText = '';
        final server = _serverProcess;
        final iterator = _lineIterator;

        if (server != null && iterator != null && samples.isNotEmpty) {
          try {
            final cacheDirObj = Directory(_cacheDir);
            if (!cacheDirObj.existsSync()) {
              cacheDirObj.createSync(recursive: true);
            }
            final tmpPcm = File(
                '$_cacheDir/stt_pcm_${DateTime.now().microsecondsSinceEpoch}.pcm');
            final byteData = ByteData(samples.lengthInBytes);
            for (var i = 0; i < samples.length; i++) {
              byteData.setFloat32(i * 4, samples[i], Endian.little);
            }
            await tmpPcm.writeAsBytes(byteData.buffer.asUint8List());

            final reqJson = jsonEncode({
              'input_path': tmpPcm.path,
              'sample_rate': sampleRate,
            });

            server.stdin.writeln(reqJson);
            await server.stdin.flush();

            if (await iterator.moveNext()) {
              final respLine = iterator.current.trim();
              if (respLine.isNotEmpty) {
                final resp = jsonDecode(respLine) as Map<String, dynamic>;
                if (resp['ok'] == true) {
                  recognizedText = resp['text'] as String? ?? '';
                }
              }
            }
            await tmpPcm.delete().catchError((_) => tmpPcm);
          } catch (_) {}
        }

        reply(command, recognizedText);
    }
  }

  @override
  Future<void> onFrame(Float32List samples) async {}

  @override
  Future<void> onShutdown() async {
    try {
      _serverProcess?.stdin.writeln(jsonEncode({'op': 'stop'}));
      await _serverProcess?.stdin.flush();
    } catch (_) {}
    _serverProcess?.kill();
    _serverProcess = null;
    _lineIterator = null;
  }
}
