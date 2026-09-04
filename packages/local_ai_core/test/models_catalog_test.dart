import 'package:local_ai_core/local_ai_core.dart';
import 'package:test/test.dart';

void main() {
  group('Models Catalog Definition & Integrity', () {
    test('Qwen 2.5 0.5B manifest has correct properties', () {
      final manifest = Models.qwen25_05b;
      expect(manifest.id, 'qwen-2.5-0.5b-instruct');
      expect(manifest.type, ModelType.llm);
      expect(manifest.provider, ModelProviders.googleGemma);
      expect(manifest.files, isNotEmpty);
      expect(manifest.files.first.url, startsWith('https://'));
      expect(manifest.files.first.url, contains('Qwen2.5-0.5B'));
      expect(manifest.contextLength, 4096);
      expect(manifest.quantization, 'int8');
    });

    test('DeepSeek R1 Distill manifest has correct properties', () {
      final manifest = Models.deepseekR1;
      expect(manifest.id, 'deepseek-r1-1.5b-int4');
      expect(manifest.type, ModelType.llm);
      expect(manifest.provider, ModelProviders.googleGemma);
      expect(manifest.files, isNotEmpty);
      expect(manifest.files.first.url, startsWith('https://'));
      expect(manifest.files.first.url, contains('DeepSeek-R1'));
      expect(manifest.contextLength, 4096);
      expect(manifest.quantization, 'int8');
    });

    test('SmolLM2 360M manifest has correct properties', () {
      final manifest = Models.smollm2;
      expect(manifest.id, 'smollm2-360m-instruct');
      expect(manifest.type, ModelType.llm);
      expect(manifest.provider, ModelProviders.googleGemma);
      expect(manifest.files, isNotEmpty);
      expect(manifest.files.first.url, endsWith('.litertlm'));
      expect(manifest.contextLength, 2048);
    });

    test('Gemma 4 E2B & E4B manifests have valid LiteRT-LM configuration', () {
      final e2b = Models.gemma4E2b;
      expect(e2b.id, 'gemma-4-e2b-it');
      expect(e2b.type, ModelType.llm);
      expect(e2b.provider, ModelProviders.googleGemma);
      expect(e2b.files, isNotEmpty);
      expect(e2b.files.first.url, contains('gemma-4-E2B-it.litertlm'));

      final e4b = Models.gemma4E4b;
      expect(e4b.id, 'gemma-4-e4b-it');
      expect(e4b.type, ModelType.llm);
      expect(e4b.provider, ModelProviders.googleGemma);
      expect(e4b.files, isNotEmpty);
      expect(e4b.files.first.url, contains('gemma-4-E4B-it.litertlm'));
    });

    test('Gemma 3n E2B manifest has valid configuration', () {
      final manifest = Models.gemma3nE2b;
      expect(manifest.id, 'gemma-3n-e2b-it-int4');
      expect(manifest.type, ModelType.llm);
      expect(manifest.provider, ModelProviders.googleGemma);
      expect(manifest.files, isNotEmpty);
      expect(manifest.files.first.sizeBytes, greaterThan(1000000));
    });

    test('Sherpa Silero VAD manifest is configured properly', () {
      final manifest = Models.sileroVad;
      expect(manifest.id, 'silero-vad');
      expect(manifest.type, ModelType.vad);
      expect(manifest.provider, ModelProviders.sherpaCommunity);
      expect(manifest.files, isNotEmpty);
      expect(manifest.files.first.name, 'silero_vad.onnx');
      expect(
          manifest.files.first.url, contains('github.com/k2-fsa/sherpa-onnx'));
    });

    test('Sherpa SenseVoice Small manifest is configured properly', () {
      final manifest = Models.senseVoiceSmall;
      expect(manifest.id, 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue');
      expect(manifest.type, ModelType.stt);
      expect(manifest.provider, ModelProviders.sherpaCommunity);
      expect(manifest.files, isNotEmpty);
      expect(manifest.files.first.url, startsWith('https://'));
      expect(manifest.files.first.url, contains('-int8-'));
      expect(manifest.files.first.sizeBytes, 245366784);
    });

    test('Dolphin Base manifests cover fp32 and int8 CTC archives', () {
      for (final manifest in [Models.dolphinBase, Models.dolphinBaseInt8]) {
        expect(manifest.type, ModelType.stt);
        expect(manifest.provider, ModelProviders.sherpaCommunity);
        expect(manifest.capabilities, contains(ModelCapability.asrOffline));
        expect(manifest.languages, contains('ja'));
        expect(manifest.languages, contains('zh-WU'));
        expect(manifest.files.single.name, endsWith('.tar.bz2'));
        expect(manifest.files.single.name, contains('dolphin-base'));
      }
    });

    test('Moonshine v2 manifests include every published language variant', () {
      final manifests = <LocalModelManifest>[
        Models.moonshineTinyV2En,
        Models.moonshineTinyV2Ja,
        Models.moonshineTinyV2Ko,
        Models.moonshineBaseV2Ar,
        Models.moonshineBaseV2En,
        Models.moonshineBaseV2Es,
        Models.moonshineBaseV2Ja,
        Models.moonshineBaseV2Uk,
        Models.moonshineBaseV2Vi,
        Models.moonshineBaseV2Zh,
      ];

      expect(manifests.map((manifest) => manifest.languages.single),
          containsAll(['ar', 'en', 'es', 'ja', 'ko', 'uk', 'vi', 'zh']));
      expect(
        manifests
            .map((manifest) => manifest.id)
            .every((id) => Models.byId(id) != null),
        isTrue,
      );
      for (final manifest in manifests) {
        expect(manifest.type, ModelType.stt);
        expect(manifest.capabilities, contains(ModelCapability.asrOffline));
        expect(manifest.files.single.name, endsWith('.tar.bz2'));
        expect(manifest.files.single.name, contains('quantized-2026-02-27'));
      }
    });

    test('legacy Moonshine v1 English manifest remains available', () {
      expect(Models.moonshineTiny.id, 'sherpa-onnx-moonshine-tiny-en');
      expect(Models.moonshineTiny.files.single.name,
          'sherpa-onnx-moonshine-tiny-en-int8.tar.bz2');
      expect(Models.byId(Models.moonshineTiny.id), isNotNull);
    });

    test('Supertonic & Kokoro TTS manifests are configured properly', () {
      final supertonic = Models.supertonic;
      expect(supertonic.id, 'supertonic-tts');
      expect(supertonic.type, ModelType.tts);
      expect(supertonic.provider, ModelProviders.sherpaCommunity);
      expect(supertonic.files.length, 17);
      expect(supertonic.voices?.length, 10);
      final fileNames = supertonic.files.map((f) => f.name).toSet();
      expect(
          fileNames,
          containsAll([
            'duration_predictor.onnx',
            'text_encoder.onnx',
            'vector_estimator.onnx',
            'vocoder.onnx',
            'tts.json',
            'unicode_indexer.json',
            'voice_style_F1.json',
            'voice_style_F2.json',
            'voice_style_F3.json',
            'voice_style_F4.json',
            'voice_style_F5.json',
            'voice_style_M1.json',
            'voice_style_M2.json',
            'voice_style_M3.json',
            'voice_style_M4.json',
            'voice_style_M5.json',
            'config.json',
          ]));

      final kokoro = Models.kokoroTts;
      expect(kokoro.id, 'kokoro-en-tts');
      expect(kokoro.type, ModelType.tts);
      expect(kokoro.provider, ModelProviders.sherpaCommunity);
      expect(kokoro.files, isNotEmpty);
    });

    test(
        'SpeakRequest stores text, language, voiceId, and speed/pitch parameters',
        () {
      const request = SpeakRequest(
        text: 'こんにちは！ 今日は「ありがとう」の使い方を勉強しましょう。',
        language: 'ja',
        voiceId: 'f1',
        speed: 1.2,
        pitch: 1.1,
      );

      expect(request.text, 'こんにちは！ 今日は「ありがとう」の使い方を勉強しましょう。');
      expect(request.language, 'ja');
      expect(request.voiceId, 'f1');
      expect(request.speed, 1.2);
      expect(request.pitch, 1.1);
    });

    test('LlmLoadOptions default sampling topK=40 and topP=0.9', () {
      const options = LlmLoadOptions(
        modelId: 'qwen-3.5-0.8b-instruct',
      );

      expect(options.modelId, 'qwen-3.5-0.8b-instruct');
      expect(options.temperature, 0.8);
      expect(options.topK, 40);
      expect(options.topP, 0.9);
    });

    test('Qwen 3.5 manifests exist and have correct LiteRT-LM configuration',
        () {
      final qwen08 = Models.qwen35_08b;
      expect(qwen08.id, 'qwen-3.5-0.8b-instruct');
      expect(qwen08.files.first.url, contains('Qwen3.5-0.8B_int8.litertlm'));

      final qwen2 = Models.qwen35_2b;
      expect(qwen2.id, 'qwen-3.5-2b-instruct');
      expect(qwen2.files.first.url, contains('Qwen3.5-2B_int8.litertlm'));

      final qwen4 = Models.qwen35_4b;
      expect(qwen4.id, 'qwen-3.5-4b-instruct');
      expect(qwen4.files.first.url, contains('Qwen3.5-4B_int8.litertlm'));
    });

    test('llama.cpp GGUF manifests exist and have valid configuration', () {
      final qwenGguf = Models.qwen25_05bGguf;
      expect(qwenGguf.id, 'qwen-2.5-0.5b-instruct-gguf');
      expect(qwenGguf.type, ModelType.llm);
      expect(qwenGguf.provider, ModelProviders.llamaCpp);
      expect(qwenGguf.quantization, 'q4_k_m');
      expect(qwenGguf.files.single.name, endsWith('.gguf'));

      final llamaGguf = Models.llama32_1bGguf;
      expect(llamaGguf.id, 'llama-3.2-1b-instruct-gguf');
      expect(llamaGguf.type, ModelType.llm);
      expect(llamaGguf.provider, ModelProviders.llamaCpp);
      expect(llamaGguf.quantization, 'q4_k_m');
      expect(llamaGguf.files.single.name, endsWith('.gguf'));
      expect(llamaGguf.files.single.url, contains('Llama-3.2-1B-Instruct'));

      final smolGguf = Models.smollm2_360mGguf;
      expect(smolGguf.id, 'smollm2-360m-instruct-gguf');
      expect(smolGguf.type, ModelType.llm);
      expect(smolGguf.provider, ModelProviders.llamaCpp);
      expect(smolGguf.quantization, 'q4_k_m');
      expect(smolGguf.files.single.name, endsWith('.gguf'));

      final nomicGguf = Models.nomicEmbedText;
      expect(nomicGguf.id, 'nomic-embed-text-v1.5-gguf');
      expect(nomicGguf.type, ModelType.embedding);
      expect(nomicGguf.provider, ModelProviders.llamaCpp);
      expect(nomicGguf.quantization, 'q4_k_m');
      expect(nomicGguf.files.single.name, endsWith('.gguf'));

      final lfmJp = Models.lfm25_12bJp;
      expect(lfmJp.id, 'lfm2.5-1.2b-jp-gguf');
      expect(lfmJp.languages, contains('ja'));
      expect(lfmJp.files.single.name, contains('LFM2.5-1.2B-JP'));

      final qwen35_08 = Models.qwen35_08bGguf;
      expect(qwen35_08.id, 'qwen-3.5-0.8b-instruct-gguf');
      expect(qwen35_08.files.single.name, contains('qwen3.5-0.8b'));

      final lfmInstruct = Models.lfm25_12bInstruct;
      expect(lfmInstruct.id, 'lfm2.5-1.2b-instruct-gguf');
      expect(lfmInstruct.files.single.name, contains('LFM2.5-1.2B-Instruct'));

      final lfm26 = Models.lfm25_26b;
      expect(lfm26.id, 'lfm2.5-2.6b-gguf');
      expect(lfm26.files.single.name, contains('LFM2.5-2.6B'));

      final qwen35_4 = Models.qwen35_4bGguf;
      expect(qwen35_4.id, 'qwen-3.5-4b-instruct-gguf');
      expect(qwen35_4.files.single.name, contains('qwen3.5-4b'));

      final ministral = Models.ministral3_3b;
      expect(ministral.id, 'ministral-3-3b-instruct-gguf');
      expect(ministral.files.single.name, contains('Ministral-3-3B'));

      final lfm8b = Models.lfm25_8bA1b;
      expect(lfm8b.id, 'lfm2.5-8b-a1b-gguf');
      expect(lfm8b.files.single.name, contains('LFM2.5-8B-A1B'));

      expect(Models.byId('qwen-2.5-0.5b-instruct-gguf'), isNotNull);
      expect(Models.byId('llama-3.2-1b-instruct-gguf'), isNotNull);
      expect(Models.byId('smollm2-360m-instruct-gguf'), isNotNull);
      expect(Models.byId('lfm2.5-1.2b-jp-gguf'), isNotNull);
      expect(Models.byId('qwen-3.5-0.8b-instruct-gguf'), isNotNull);
      expect(Models.byId('lfm2.5-1.2b-instruct-gguf'), isNotNull);
      expect(Models.byId('lfm2.5-2.6b-gguf'), isNotNull);
      expect(Models.byId('qwen-3.5-4b-instruct-gguf'), isNotNull);
      expect(Models.byId('ministral-3-3b-instruct-gguf'), isNotNull);
      expect(Models.byId('lfm2.5-8b-a1b-gguf'), isNotNull);
      expect(Models.byId('nomic-embed-text-v1.5-gguf'), isNotNull);
    });
  });
}
