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
      expect(manifest.files.first.url, contains('github.com/k2-fsa/sherpa-onnx'));
    });

    test('Sherpa SenseVoice Small manifest is configured properly', () {
      final manifest = Models.senseVoiceSmall;
      expect(manifest.id, 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue');
      expect(manifest.type, ModelType.stt);
      expect(manifest.provider, ModelProviders.sherpaCommunity);
      expect(manifest.files, isNotEmpty);
      expect(manifest.files.first.url, startsWith('https://'));
    });

    test('Supertonic TTS manifest is configured properly', () {
      final manifest = Models.supertonic;
      expect(manifest.id, 'supertonic-tts');
      expect(manifest.type, ModelType.tts);
      expect(manifest.provider, ModelProviders.sherpaCommunity);
      expect(manifest.files, isNotEmpty);
      expect(manifest.files.first.url, startsWith('https://'));
    });
  });
}
