import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_kit/local_ai_kit.dart';

class _FakePaths implements LocalStoragePaths {
  const _FakePaths();
  @override
  String get rootDir => '/fake';
  @override
  String get modelsDir => '/fake/models';
  @override
  String modelDir(ModelType type, String modelId) =>
      '/fake/models/${type.name}/$modelId';
  @override
  String get downloadsDir => '/fake/downloads';
  @override
  String downloadDir(String modelId) => '/fake/downloads/$modelId';
  @override
  String get voicesDir => '/fake/voices';
  @override
  String voiceDir(String voiceId) => '/fake/voices/$voiceId';
  @override
  String get manifestsDir => '/fake/manifests';
  @override
  String get cacheDir => '/fake/cache';
  @override
  Future<void> ensureInitialized() async {}
}

class _FakeNetworkPolicy implements NetworkPolicy {
  const _FakeNetworkPolicy();
  @override
  Future<bool> canDownload({bool wifiOnly = true}) async => true;
  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;
  @override
  Stream<NetworkStatus> get onStatusChanged => const Stream.empty();
}

class _FakeCatalog implements LocalModelCatalog {
  _FakeCatalog(this._manifests);
  final Map<String, LocalModelManifest> _manifests;

  @override
  Future<LocalModelManifest> get(String modelId) async {
    final manifest = _manifests[modelId];
    if (manifest == null) throw StateError('no manifest for $modelId');
    return manifest;
  }

  @override
  Future<List<LocalModelManifest>> list(
          {ModelType? type, String? language}) async =>
      _manifests.values.toList();

  @override
  Future<void> refresh() async {}

  @override
  List<ModelPack> get packs => const [];

  @override
  Future<void> installPack(String packId) async {}
}

LocalModelManifest _fakeManifest(String id, ModelType type) =>
    LocalModelManifest(
      id: id,
      type: type,
      provider: 'fake',
      files: const [],
      delivery: ModelDelivery.bundled,
    );

/// VAD whose events are pushed manually by the test instead of derived from
/// audio content, so tests can script utterance/barge-in timing precisely.
class _ScriptedVad implements LocalVad {
  final _controller = StreamController<VadEvent>.broadcast();

  @override
  Future<void> load(VadConfig config) async {}

  @override
  Future<void> unload() async {}

  @override
  Stream<VadEvent> analyze(Stream<AudioFrame> audio) => _controller.stream;

  void push(VadEvent event) => _controller.add(event);

  Future<void> dispose() => _controller.close();
}

/// Mic source whose frames are pushed manually by the test.
class _ScriptedAudioSource implements LocalAudioSource {
  final _controller = StreamController<AudioFrame>.broadcast();

  @override
  Stream<AudioFrame> start({AudioFormat format = AudioFormat.pcm16kMono}) =>
      _controller.stream;

  @override
  Future<void> stop() async {}

  void pushFrame() {
    _controller.add(AudioFrame(
      samples: Float32List(160),
      format: AudioFormat.pcm16kMono,
      timestamp: DateTime.now(),
    ));
  }

  Future<void> dispose() => _controller.close();
}

/// Plays back instantly — used where the test doesn't need to observe
/// playback still being "in progress".
class _InstantAudioOutput implements LocalAudioOutput {
  @override
  Future<void> play(Stream<AudioChunk> audio) async {
    await audio.drain<void>();
  }

  @override
  Future<void> stop() async {}
}

/// Blocks each play() call until [stop] (or the test) releases it, so a
/// test can deterministically interrupt mid-playback.
class _GatedAudioOutput implements LocalAudioOutput {
  Completer<void>? _gate;

  @override
  Future<void> play(Stream<AudioChunk> audio) async {
    await audio.drain<void>();
    final gate = _gate = Completer<void>();
    await gate.future;
  }

  @override
  Future<void> stop() async {
    final gate = _gate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }
}

/// Allows playback to finish while [stop] is still pending, reproducing the
/// ordering window between an asynchronous output stop and token cancellation.
class _DelayedStopAudioOutput implements LocalAudioOutput {
  final stopStarted = Completer<void>();
  final _stopGate = Completer<void>();
  Completer<void>? _playbackGate;

  @override
  Future<void> play(Stream<AudioChunk> audio) async {
    await audio.drain<void>();
    final gate = _playbackGate = Completer<void>();
    await gate.future;
  }

  @override
  Future<void> stop() async {
    if (!stopStarted.isCompleted) stopStarted.complete();
    await _stopGate.future;
    final gate = _playbackGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  void finishPlayback() {
    final gate = _playbackGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  void finishStop() {
    if (!_stopGate.isCompleted) _stopGate.complete();
  }
}

/// Records every synthesis request's text, in call order.
class _RecordingTts implements LocalTts {
  final List<String> synthesizedTexts = [];

  @override
  Future<void> load(TtsLoadOptions options) async {}

  @override
  Future<void> unload() async {}

  @override
  List<LocalVoice> get installedVoices => const [];

  @override
  Stream<AudioChunk> synthesizeStream(SpeakRequest request) async* {
    synthesizedTexts.add(request.text);
    yield AudioChunk(
      samples: Float32List(160),
      format: AudioFormat.pcm16kMono,
      isLast: true,
    );
  }
}

/// Polls [predicate] until it's true, or fails fast after [maxTries] — used
/// instead of a fixed delay so tests run quickly and fail clearly rather
/// than hanging when the pipelining behavior isn't implemented yet.
Future<void> _waitUntil(bool Function() predicate, {int maxTries = 500}) async {
  for (var i = 0; i < maxTries; i++) {
    if (predicate()) return;
    await Future<void>.delayed(Duration.zero);
  }
  throw StateError('condition not met after $maxTries polls');
}

class _Harness {
  _Harness({required LocalLlm llm, required LocalAudioOutput audioOutput})
      : vad = _ScriptedVad(),
        source = _ScriptedAudioSource(),
        tts = _RecordingTts(),
        stt = FakeStt(transcriptText: 'hello there'),
        output = audioOutput,
        llm = llm;

  final _ScriptedVad vad;
  final _ScriptedAudioSource source;
  final _RecordingTts tts;
  final FakeStt stt;
  final LocalAudioOutput output;
  final LocalLlm llm;
  late final RuntimeScheduler runtime;
  late final VoiceSession session;
  final events = <VoiceEvent>[];
  StreamSubscription<VoiceEvent>? _sub;

  Future<void> start() async {
    final catalog = _FakeCatalog({
      'vad-1': _fakeManifest('vad-1', ModelType.vad),
      'stt-1': _fakeManifest('stt-1', ModelType.stt),
      'llm-1': _fakeManifest('llm-1', ModelType.llm),
      'tts-1': _fakeManifest('tts-1', ModelType.tts),
    });
    final registry = AdapterRegistry()
      ..registerVad('fake', (_) => vad)
      ..registerStt('fake', (_) => stt)
      ..registerLlm('fake', (_) => llm)
      ..registerTts('fake', (_) => tts)
      ..attachContext(const AdapterContext(
        paths: _FakePaths(),
        networkPolicy: _FakeNetworkPolicy(),
      ));
    runtime = RuntimeScheduler(catalog: catalog, registry: registry);

    final factory = VoiceSessionFactory(
      config: const LocalAIConfig(
        vad: VadConfig(modelId: 'vad-1'),
        stt: SttConfig(modelId: 'stt-1'),
        llm: LlmConfig(modelId: 'llm-1'),
        tts: TtsConfig(modelId: 'tts-1'),
      ),
      runtime: runtime,
      audioSource: source,
      audioOutput: output,
    );
    session = await factory.start();
    _sub = session.events.listen(events.add);
  }

  /// Drives one utterance through the scripted VAD/mic.
  void driveOneUtterance() {
    vad.push(VadSpeechStarted(timestamp: DateTime.now(), confidence: 1.0));
    source.pushFrame();
    vad.push(VadSpeechEnded(
      timestamp: DateTime.now(),
      speechDuration: const Duration(milliseconds: 300),
    ));
  }

  /// Pushes a high-confidence, already-persisted speech-start event so
  /// [VoiceSession._maybeBargeIn]'s persistence check passes immediately.
  void triggerBargeIn() {
    vad.push(VadSpeechStarted(
      timestamp: DateTime.now().subtract(const Duration(milliseconds: 200)),
      confidence: 0.99,
    ));
  }

  Future<void> dispose() async {
    await session.stop();
    await _sub?.cancel();
    await runtime.dispose();
    await vad.dispose();
    await source.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('pipelines LLM output into TTS as sentences arrive', () async {
    final secondSentenceGate = Completer<void>();
    final llm = FakeLlm(handler: (request) async* {
      yield const LlmChunk(textDelta: 'Sentence one. ');
      await secondSentenceGate.future;
      yield const LlmChunk(textDelta: 'Sentence two.');
      yield const LlmChunk(isFinal: true, finishReason: LlmFinishReason.stop);
    });
    final harness = _Harness(llm: llm, audioOutput: _InstantAudioOutput());
    await harness.start();

    harness.driveOneUtterance();

    // Sentence one should be synthesized without waiting for the LLM to
    // finish generating sentence two.
    await _waitUntil(() => harness.tts.synthesizedTexts.isNotEmpty);
    expect(harness.tts.synthesizedTexts, ['Sentence one.']);

    secondSentenceGate.complete();
    await _waitUntil(() => harness.tts.synthesizedTexts.length >= 2);
    expect(harness.tts.synthesizedTexts, ['Sentence one.', 'Sentence two.']);

    await _waitUntil(
        () => harness.events.whereType<VoiceFinished>().isNotEmpty);

    await harness.dispose();
  });

  test('barge-in mid-chain cancels remaining queued sentences', () async {
    final llm = FakeLlm(handler: (request) async* {
      yield const LlmChunk(textDelta: 'One. Two.');
      yield const LlmChunk(isFinal: true, finishReason: LlmFinishReason.stop);
    });
    final output = _GatedAudioOutput();
    final harness = _Harness(llm: llm, audioOutput: output);
    await harness.start();

    harness.driveOneUtterance();

    // Sentence "One." starts playing and blocks (gated); "Two." is already
    // generated and queued behind it at this point.
    await _waitUntil(() => harness.tts.synthesizedTexts.isNotEmpty);
    expect(harness.tts.synthesizedTexts, ['One.']);

    harness.triggerBargeIn();
    await _waitUntil(
        () => harness.events.whereType<VoiceInterrupted>().isNotEmpty);

    expect(
      harness.events.whereType<VoiceInterrupted>().single.reason,
      InterruptReason.bargeIn,
    );
    // "Two." must never have started synthesis.
    expect(harness.tts.synthesizedTexts, ['One.']);

    await harness.dispose();
  });

  test('barge-in cancels queued sentences before delayed output stop completes',
      () async {
    final llm = FakeLlm(handler: (request) async* {
      yield const LlmChunk(textDelta: 'One. Two.');
      yield const LlmChunk(isFinal: true, finishReason: LlmFinishReason.stop);
    });
    final output = _DelayedStopAudioOutput();
    final harness = _Harness(llm: llm, audioOutput: output);
    await harness.start();

    harness.driveOneUtterance();
    await _waitUntil(() => harness.tts.synthesizedTexts.isNotEmpty);
    expect(harness.tts.synthesizedTexts, ['One.']);

    harness.triggerBargeIn();
    await output.stopStarted.future;
    output.finishPlayback();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // Playback has ended, but stop is deliberately pending: token
    // cancellation must already prevent the queued sentence from starting.
    expect(harness.tts.synthesizedTexts, ['One.']);

    output.finishStop();
    await _waitUntil(
        () => harness.events.whereType<VoiceInterrupted>().isNotEmpty);
    await harness.dispose();
  });
}
