/// SenseVoice / Zipformer / Whisper (sherpa_onnx) STT adapter.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:local_ai_core/local_ai_core.dart';

import 'isolate/sherpa_worker.dart';

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
    recognizer = None
    engine_type = 'none'
    is_online = False

    if model_dir and os.path.exists(model_dir):
        try:
            import sherpa_onnx
            
            # 1. Zipformer / Transducer (Online Recognizer)
            encoders = glob.glob(os.path.join(model_dir, '**', '*encoder*.onnx'), recursive=True)
            decoders = glob.glob(os.path.join(model_dir, '**', '*decoder*.onnx'), recursive=True)
            joiners = glob.glob(os.path.join(model_dir, '**', '*joiner*.onnx'), recursive=True)
            tokens = glob.glob(os.path.join(model_dir, '**', '*tokens*.txt'), recursive=True)
            
            if encoders and decoders and joiners and tokens:
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
                )
                engine_type = 'transducer'
                is_online = True
            
            # 2. SenseVoice (Offline Recognizer)
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
            
            # 3. Whisper (Offline Recognizer)
            if recognizer is None and encoders and decoders and tokens:
                recognizer = sherpa_onnx.OfflineRecognizer.from_whisper(
                    encoder=encoders[0],
                    decoder=decoders[0],
                    tokens=tokens[0],
                    num_threads=4,
                )
                engine_type = 'whisper'
                is_online = False

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
            
            text = ''
            if recognizer is not None and len(samples) > 0:
                stream = recognizer.create_stream()
                if is_online:
                    pre_silence = np.zeros(int(sample_rate * 0.25), dtype=np.float32)
                    stream.accept_waveform(sample_rate, pre_silence)
                    stream.accept_waveform(sample_rate, samples)
                    post_silence = np.zeros(int(sample_rate * 0.4), dtype=np.float32)
                    stream.accept_waveform(sample_rate, post_silence)
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

  Future<void> _startServer(String modelDir) async {
    try {
      final scriptFile = File('/tmp/sherpa_stt_server.py');
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
        '/tmp/sherpa_stt_server.py',
        modelDir,
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
        if (_modelDir != null) {
          await _startServer(_modelDir!);
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
            final tmpPcm = File(
                '/tmp/stt_pcm_${DateTime.now().microsecondsSinceEpoch}.pcm');
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
