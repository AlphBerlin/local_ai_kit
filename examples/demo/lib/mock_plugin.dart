import 'dart:async';
import 'dart:typed_data';
import 'package:local_ai_kit/local_ai_kit.dart';
import 'logger.dart';

/// In-memory fake plugin for immediate zero-download demo & unit testing.
class MockAdapterPlugin implements AdapterPlugin {
  const MockAdapterPlugin();

  @override
  void register(AdapterRegistry registry) {
    AppLogger.info('PLUGIN',
        'Registering MockAdapterPlugin for Google Gemma & Sherpa providers');

    // Register LLM adapter for both Gemma and Mock providers
    registry.registerLlm(
      ModelProviders.googleGemma,
      (context) => _DemoMockLlm(provider: ModelProviders.googleGemma),
    );
    registry.registerLlm(
      'mock',
      (context) => _DemoMockLlm(provider: 'mock'),
    );

    // Register STT adapter
    registry.registerStt(
      ModelProviders.sherpaCommunity,
      (context) => _DemoMockStt(),
    );
    registry.registerStt(
      'mock',
      (context) => _DemoMockStt(),
    );

    // Register TTS adapter
    registry.registerTts(
      ModelProviders.sherpaCommunity,
      (context) => _DemoMockTts(),
    );
    registry.registerTts(
      'mock',
      (context) => _DemoMockTts(),
    );

    // Register VAD adapter
    registry.registerVad(
      ModelProviders.sherpaCommunity,
      (context) => _DemoMockVad(),
    );
    registry.registerVad(
      'mock',
      (context) => _DemoMockVad(),
    );
  }
}

class _DemoMockLlm with StructuredOutputSupport implements LocalLlm {
  _DemoMockLlm({required this.provider});

  final String provider;
  bool _loaded = false;

  @override
  bool get isLoaded => _loaded;

  @override
  Future<void> load(LlmLoadOptions options) async {
    AppLogger.info('LLM_MOCK',
        'Loaded mock LLM model: ${options.modelId} (provider: $provider)');
    _loaded = true;
  }

  @override
  Future<void> unload() async {
    AppLogger.info('LLM_MOCK', 'Unloaded mock LLM model');
    _loaded = false;
  }

  @override
  Stream<LlmChunk> generateStream(LlmRequest request) async* {
    final prompt =
        request.messages.lastOrNull?.content ?? 'Explain on-device AI';
    AppLogger.info('LLM_MOCK', 'generateStream requested: "$prompt"');

    final response = _generateMockResponse(prompt);
    final words = response.split(' ');

    for (var i = 0; i < words.length; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 35));
      final space = i < words.length - 1 ? ' ' : '';
      yield LlmChunk(textDelta: '${words[i]}$space');
    }

    yield const LlmChunk(isFinal: true, finishReason: LlmFinishReason.stop);
    AppLogger.success(
        'LLM_MOCK', 'Generation complete (${words.length} tokens emitted)');
  }

  @override
  Future<LlmResponse> generate(LlmRequest request) =>
      LlmResponse.fold(generateStream(request));

  String _generateMockResponse(String prompt) {
    final lower = prompt.toLowerCase();
    if (lower.contains('one sentence') ||
        lower.contains('explain on-device ai')) {
      return 'On-device AI executes intelligent neural network models directly on your local hardware, ensuring private, offline, zero-latency processing without cloud dependencies.';
    }
    if (lower.contains('haiku')) {
      return 'Silicon computes,\nThoughts bloom in local circuits,\nPrivate and serene.';
    }
    if (lower.contains('hello') || lower.contains('hi')) {
      return 'Hello! I am your offline on-device assistant running locally on this device via LocalAI Kit.';
    }
    return 'On-device AI allows machine learning models to run entirely on the local device processor (CPU/GPU/NPU). This preserves privacy, eliminates cloud API fees, and functions seamlessly without an active internet connection.';
  }
}

class _DemoMockStt implements LocalStt {
  @override
  Future<void> load(SttLoadOptions options) async {
    AppLogger.info('STT_MOCK', 'Loaded mock STT model: ${options.modelId}');
  }

  @override
  Future<void> unload() async {
    AppLogger.info('STT_MOCK', 'Unloaded mock STT model');
  }

  @override
  Stream<TranscriptEvent> transcribeStream(
    Stream<AudioFrame> audio, {
    SttOptions? options,
  }) async* {
    AppLogger.info(
        'STT_MOCK', 'Transcribing streaming audio frame sequence...');
    yield const TranscriptPartial('Transcribing user voice...');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    yield const TranscriptPartial('Explain on-device AI in one sentence.');
    yield const TranscriptFinal(
      Transcript(text: 'Explain on-device AI in one sentence.'),
    );
  }

  @override
  Future<Transcript> transcribe(AudioBuffer audio,
      {SttOptions? options}) async {
    return const Transcript(text: 'Explain on-device AI in one sentence.');
  }
}

class _DemoMockTts implements LocalTts {
  @override
  Future<void> load(TtsLoadOptions options) async {
    AppLogger.info('TTS_MOCK', 'Loaded mock TTS model: ${options.modelId}');
  }

  @override
  Future<void> unload() async {
    AppLogger.info('TTS_MOCK', 'Unloaded mock TTS model');
  }

  @override
  List<LocalVoice> get installedVoices => const [
        LocalVoice(
          id: 'demo-voice-en-1',
          name: 'Demo Assistant Voice (English)',
          language: 'en',
          gender: 'female',
          files: [],
        ),
      ];

  @override
  Stream<AudioChunk> synthesizeStream(SpeakRequest request) async* {
    AppLogger.info('TTS_MOCK', 'Synthesizing speech for: "${request.text}"');
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      yield AudioChunk(
        samples: Float32List(1600),
        format: AudioFormat.pcm16kMono,
        isLast: i == 2,
      );
    }
  }
}

class _DemoMockVad implements LocalVad {
  @override
  Future<void> load(VadConfig config) async {
    AppLogger.info('VAD_MOCK', 'Loaded mock VAD model: ${config.modelId}');
  }

  @override
  Future<void> unload() async {
    AppLogger.info('VAD_MOCK', 'Unloaded mock VAD model');
  }

  @override
  Stream<VadEvent> analyze(Stream<AudioFrame> audio) async* {
    AppLogger.info(
        'VAD_MOCK', 'Analyzing microphone audio frames for voice activity');
    var count = 0;
    await for (final frame in audio) {
      count++;
      if (count == 3) {
        yield VadSpeechStarted(timestamp: frame.timestamp, confidence: 0.98);
      } else if (count == 12) {
        yield VadSpeechEnded(
          timestamp: frame.timestamp,
          speechDuration: const Duration(seconds: 2),
        );
        break;
      }
    }
  }
}
