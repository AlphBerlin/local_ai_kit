/// Built-in offline model catalog.
///
/// These entries are the always-available fallback merged with the remote
/// catalog (architecture §5.5). URLs and sha256 values are placeholders to
/// be replaced at release time; the download manager verifies integrity so
/// a stale placeholder fails closed, never open.
library;

import 'local_voice.dart';
import 'manifest.dart';
import 'model_delivery.dart';
import 'model_file.dart';

/// Placeholder sha256 (64 hex chars) — replaced during release packaging.
const String kPlaceholderSha256 =
    '0000000000000000000000000000000000000000000000000000000000000000';

/// Well-known provider routing keys used by [AdapterRegistry].
abstract final class ModelProviders {
  static const String googleGemma = 'google-gemma';
  static const String sherpaCommunity = 'sherpa-community';
}

/// Built-in model manifests.
abstract final class Models {
  /// DeepSeek R1 Distill Qwen 1.5B model.
  static const LocalModelManifest deepseekR1 = LocalModelManifest(
    id: 'deepseek-r1-1.5b-int4',
    type: ModelType.llm,
    provider: ModelProviders.googleGemma,
    displayName: 'DeepSeek R1 Distill (1.5B)',
    description: 'Fast reasoning on-device LLM with DeepSeek R1 distillation.',
    delivery: ModelDelivery.download,
    quantization: 'int8',
    contextLength: 4096,
    minMemoryMB: 2048,
    languages: ['en', 'zh'],
    platforms: ['android', 'ios', 'macos'],
    capabilities: {
      ModelCapability.chat,
      ModelCapability.streaming,
    },
    license: 'apache-2.0',
    catalogVersion: 1,
    files: [
      ModelFile(
        name: 'deepseek_q8_ekv1280.task',
        url:
            'https://huggingface.co/litert-community/DeepSeek-R1-Distill-Qwen-1.5B/resolve/main/deepseek_q8_ekv1280.task',
        sha256: kPlaceholderSha256,
        sizeBytes: 1860686856,
      ),
    ],
  );

  /// Qwen 2.5 0.5B Instruct model (ultra-fast download ~540MB).
  static const LocalModelManifest qwen25_05b = LocalModelManifest(
    id: 'qwen-2.5-0.5b-instruct',
    type: ModelType.llm,
    provider: ModelProviders.googleGemma,
    displayName: 'Qwen 2.5 0.5B Instruct (Fast)',
    description: 'Lightweight, fast on-device chat model (546 MB download).',
    delivery: ModelDelivery.download,
    quantization: 'int8',
    contextLength: 4096,
    minMemoryMB: 1024,
    languages: ['en', 'zh'],
    platforms: ['android', 'ios', 'macos'],
    capabilities: {
      ModelCapability.chat,
      ModelCapability.streaming,
    },
    license: 'apache-2.0',
    catalogVersion: 1,
    files: [
      ModelFile(
        name: 'Qwen2.5-0.5B-Instruct_multi-prefill-seq_q8_ekv1280.task',
        url:
            'https://huggingface.co/litert-community/Qwen2.5-0.5B-Instruct/resolve/main/Qwen2.5-0.5B-Instruct_multi-prefill-seq_q8_ekv1280.task',
        sha256: kPlaceholderSha256,
        sizeBytes: 546660344,
      ),
    ],
  );

  /// SmolLM2 360M Instruct model (ultra-lightweight ~370MB).
  static const LocalModelManifest smollm2 = LocalModelManifest(
    id: 'smollm2-360m-instruct',
    type: ModelType.llm,
    provider: ModelProviders.googleGemma,
    displayName: 'SmolLM2 360M Instruct (Ultra-Light)',
    description: 'Smallest on-device LLM (373 MB download) for rapid responses.',
    delivery: ModelDelivery.download,
    quantization: 'int8',
    contextLength: 2048,
    minMemoryMB: 512,
    languages: ['en'],
    platforms: ['android', 'ios', 'macos'],
    capabilities: {
      ModelCapability.chat,
      ModelCapability.streaming,
    },
    license: 'apache-2.0',
    catalogVersion: 1,
    files: [
      ModelFile(
        name: 'SmolLM2_360M_instruct.litertlm',
        url:
            'https://huggingface.co/litert-community/SmolLM2-360M-Instruct/resolve/main/SmolLM2_360M_instruct.litertlm',
        sha256: kPlaceholderSha256,
        sizeBytes: 373719040,
      ),
    ],
  );

  /// Gemma 3n E2B instruction-tuned, int4 quantized chat model.
  static const LocalModelManifest gemma3nE2b = LocalModelManifest(
    id: 'gemma-3n-e2b-it-int4',
    type: ModelType.llm,
    provider: ModelProviders.googleGemma,
    displayName: 'Gemma 3n E2B IT (int4)',
    description: 'General purpose on-device chat model.',
    delivery: ModelDelivery.download,
    quantization: 'int4',
    contextLength: 32768,
    minMemoryMB: 3072,
    languages: ['en'],
    platforms: ['android', 'ios'],
    capabilities: {
      ModelCapability.chat,
      ModelCapability.streaming,
      ModelCapability.functionCalling,
    },
    license: 'gemma-terms-of-use',
    catalogVersion: 1,
    files: [
      ModelFile(
        name: 'gemma-3n-E2B-it-int4.task',
        url: 'https://storage.example.com/models/gemma-3n-E2B-it-int4.task',
        sha256: kPlaceholderSha256,
        sizeBytes: 2900000000,
      ),
    ],
  );

  /// Silero VAD (tiny, bundlable below the 25MB smart threshold).
  static const LocalModelManifest sileroVad = LocalModelManifest(
    id: 'silero-vad',
    type: ModelType.vad,
    provider: ModelProviders.sherpaCommunity,
    displayName: 'Silero VAD',
    description: 'Lightweight voice activity detection.',
    delivery: ModelDelivery.bundledIfSmall,
    minMemoryMB: 64,
    languages: ['multilingual'],
    platforms: ['android', 'ios', 'macos'],
    capabilities: {ModelCapability.vadStreaming},
    license: 'MIT',
    catalogVersion: 1,
    files: [
      ModelFile(
        name: 'silero_vad.onnx',
        url:
            'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx',
        sha256: kPlaceholderSha256,
        sizeBytes: 643854,
      ),
    ],
  );

  /// SenseVoice Small multilingual streaming ASR.
  static const LocalModelManifest senseVoiceSmall = LocalModelManifest(
    id: 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue',
    type: ModelType.stt,
    provider: ModelProviders.sherpaCommunity,
    displayName: 'SenseVoice Small',
    description: 'Multilingual streaming speech recognition.',
    delivery: ModelDelivery.download,
    minMemoryMB: 512,
    languages: ['zh', 'en', 'ja', 'ko', 'yue'],
    platforms: ['android', 'ios'],
    capabilities: {ModelCapability.asrStreaming, ModelCapability.multilingual},
    license: 'MIT',
    catalogVersion: 1,
    files: [
      ModelFile(
        name: 'model.int8.onnx',
        url:
            'https://storage.example.com/models/sense-voice-small/model.int8.onnx',
        sha256: kPlaceholderSha256,
        sizeBytes: 234000000,
      ),
      ModelFile(
        name: 'tokens.txt',
        url: 'https://storage.example.com/models/sense-voice-small/tokens.txt',
        sha256: kPlaceholderSha256,
        sizeBytes: 420000,
      ),
    ],
  );

  /// Supertonic streaming TTS base model with two downloadable voices.
  static const LocalModelManifest supertonic = LocalModelManifest(
    id: 'supertonic-tts',
    type: ModelType.tts,
    provider: ModelProviders.sherpaCommunity,
    displayName: 'Supertonic TTS',
    description: 'Fast streaming text-to-speech.',
    delivery: ModelDelivery.download,
    minMemoryMB: 256,
    languages: ['en'],
    platforms: ['android', 'ios'],
    capabilities: {ModelCapability.ttsStreaming},
    license: 'MIT',
    catalogVersion: 1,
    files: [
      ModelFile(
        name: 'supertonic.onnx',
        url: 'https://storage.example.com/models/supertonic/supertonic.onnx',
        sha256: kPlaceholderSha256,
        sizeBytes: 90000000,
      ),
    ],
    voices: [
      LocalVoice(
        id: 'supertonic-en-female-1',
        name: 'Emma (English, female)',
        language: 'en',
        gender: 'female',
        files: [
          ModelFile(
            name: 'voice-emma.bin',
            url: 'https://storage.example.com/models/supertonic/voice-emma.bin',
            sha256: kPlaceholderSha256,
            sizeBytes: 8000000,
          ),
        ],
      ),
      LocalVoice(
        id: 'supertonic-en-male-1',
        name: 'James (English, male)',
        language: 'en',
        gender: 'male',
        files: [
          ModelFile(
            name: 'voice-james.bin',
            url:
                'https://storage.example.com/models/supertonic/voice-james.bin',
            sha256: kPlaceholderSha256,
            sizeBytes: 8000000,
          ),
        ],
      ),
    ],
  );

  /// All built-in manifests, keyed by id.
  static const List<LocalModelManifest> all = [
    qwen25_05b,
    deepseekR1,
    smollm2,
    gemma3nE2b,
    sileroVad,
    senseVoiceSmall,
    supertonic,
  ];

  /// Lookup helper; returns `null` for unknown ids.
  static LocalModelManifest? byId(String id) {
    for (final manifest in all) {
      if (manifest.id == id) return manifest;
    }
    return null;
  }
}
