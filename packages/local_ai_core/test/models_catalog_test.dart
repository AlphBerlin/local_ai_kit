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
  });
}
