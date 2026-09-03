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

  /// Any GGUF model run through llama.cpp (`local_ai_llama_cpp`), chat and
  /// embedding alike.
  static const String llamaCpp = 'llama-cpp';
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

  /// Qwen 3.5 0.8B int8 LiteRT-LM model (fast on-device LLM ~960MB).
  static const LocalModelManifest qwen35_08b = LocalModelManifest(
    id: 'qwen-3.5-0.8b-instruct',
    type: ModelType.llm,
    provider: ModelProviders.googleGemma,
    displayName: 'Qwen 3.5 0.8B Instruct (LiteRT-LM)',
    description: 'Fast, high-quality on-device reasoning LLM (963 MB).',
    delivery: ModelDelivery.download,
    quantization: 'int8',
    contextLength: 4096,
    minMemoryMB: 1024,
    languages: ['en', 'zh', 'multilingual'],
    platforms: ['android', 'ios', 'macos'],
    capabilities: {
      ModelCapability.chat,
      ModelCapability.streaming,
    },
    license: 'apache-2.0',
    catalogVersion: 1,
    files: [
      ModelFile(
        name: 'Qwen3.5-0.8B_int8.litertlm',
        url:
            'https://huggingface.co/litert-community/Qwen3.5-0.8B/resolve/main/Qwen3.5-0.8B_int8.litertlm',
        sha256: kPlaceholderSha256,
        sizeBytes: 963184864,
      ),
    ],
  );

  /// Qwen 3.5 2B int8 LiteRT-LM model (balanced on-device LLM ~2.1GB).
  static const LocalModelManifest qwen35_2b = LocalModelManifest(
    id: 'qwen-3.5-2b-instruct',
    type: ModelType.llm,
    provider: ModelProviders.googleGemma,
    displayName: 'Qwen 3.5 2B Instruct (LiteRT-LM)',
    description: 'Balanced on-device instruction LLM (2.11 GB).',
    delivery: ModelDelivery.download,
    quantization: 'int8',
    contextLength: 4096,
    minMemoryMB: 3072,
    languages: ['en', 'zh', 'multilingual'],
    platforms: ['android', 'ios', 'macos'],
    capabilities: {
      ModelCapability.chat,
      ModelCapability.streaming,
    },
    license: 'apache-2.0',
    catalogVersion: 1,
    files: [
      ModelFile(
        name: 'Qwen3.5-2B_int8.litertlm',
        url:
            'https://huggingface.co/litert-community/Qwen3.5-2B/resolve/main/Qwen3.5-2B_int8.litertlm',
        sha256: kPlaceholderSha256,
        sizeBytes: 2116592816,
      ),
    ],
  );

  /// Qwen 3.5 4B int8 LiteRT-LM model (high capability on-device LLM ~4.4GB).
  static const LocalModelManifest qwen35_4b = LocalModelManifest(
    id: 'qwen-3.5-4b-instruct',
    type: ModelType.llm,
    provider: ModelProviders.googleGemma,
    displayName: 'Qwen 3.5 4B Instruct (LiteRT-LM)',
    description: 'High-capability on-device reasoning LLM (4.40 GB).',
    delivery: ModelDelivery.download,
    quantization: 'int8',
    contextLength: 4096,
    minMemoryMB: 6144,
    languages: ['en', 'zh', 'multilingual'],
    platforms: ['android', 'ios', 'macos'],
    capabilities: {
      ModelCapability.chat,
      ModelCapability.streaming,
    },
    license: 'apache-2.0',
    catalogVersion: 1,
    files: [
      ModelFile(
        name: 'Qwen3.5-4B_int8.litertlm',
        url:
            'https://huggingface.co/litert-community/Qwen3.5-4B/resolve/main/Qwen3.5-4B_int8.litertlm',
        sha256: kPlaceholderSha256,
        sizeBytes: 4407428464,
      ),
    ],
  );

  /// SmolLM2 360M Instruct model (ultra-lightweight ~370MB).
  static const LocalModelManifest smollm2 = LocalModelManifest(
    id: 'smollm2-360m-instruct',
    type: ModelType.llm,
    provider: ModelProviders.googleGemma,
    displayName: 'SmolLM2 360M Instruct (Ultra-Light)',
    description:
        'Smallest on-device LLM (373 MB download) for rapid responses.',
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

  /// Gemma 4 E2B instruction-tuned LiteRT-LM model (~2.59 GB).
  static const LocalModelManifest gemma4E2b = LocalModelManifest(
    id: 'gemma-4-e2b-it',
    type: ModelType.llm,
    provider: ModelProviders.googleGemma,
    displayName: 'Gemma 4 E2B IT (LiteRT-LM)',
    description:
        'Fast, high-quality on-device reasoning LLM (2.59 GB) with LiteRT-LM acceleration.',
    delivery: ModelDelivery.download,
    quantization: 'int8',
    contextLength: 8192,
    minMemoryMB: 3072,
    languages: ['en'],
    platforms: ['android', 'ios', 'macos'],
    capabilities: {
      ModelCapability.chat,
      ModelCapability.streaming,
      ModelCapability.functionCalling,
    },
    license: 'gemma-terms-of-use',
    catalogVersion: 1,
    files: [
      ModelFile(
        name: 'gemma-4-E2B-it.litertlm',
        url:
            'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
        sha256: kPlaceholderSha256,
        sizeBytes: 2588147712,
      ),
    ],
  );

  /// Gemma 4 E4B instruction-tuned LiteRT-LM model (~3.66 GB).
  static const LocalModelManifest gemma4E4b = LocalModelManifest(
    id: 'gemma-4-e4b-it',
    type: ModelType.llm,
    provider: ModelProviders.googleGemma,
    displayName: 'Gemma 4 E4B IT (LiteRT-LM)',
    description:
        'High-capability on-device reasoning LLM (3.66 GB) with LiteRT-LM acceleration.',
    delivery: ModelDelivery.download,
    quantization: 'int8',
    contextLength: 8192,
    minMemoryMB: 5120,
    languages: ['en'],
    platforms: ['android', 'ios', 'macos'],
    capabilities: {
      ModelCapability.chat,
      ModelCapability.streaming,
      ModelCapability.functionCalling,
    },
    license: 'gemma-terms-of-use',
    catalogVersion: 1,
    files: [
      ModelFile(
        name: 'gemma-4-E4B-it.litertlm',
        url:
            'https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it.litertlm',
        sha256: kPlaceholderSha256,
        sizeBytes: 3659530240,
      ),
    ],
  );

  /// Gemma 3n E2B instruction-tuned, int4 quantized chat model.
  static const LocalModelManifest gemma3nE2b = LocalModelManifest(
    id: 'gemma-3n-e2b-it-int4',
    type: ModelType.llm,
    provider: ModelProviders.googleGemma,
    displayName: 'Gemma 3n E2B IT (LiteRT-LM)',
    description: 'General purpose on-device chat model (2.59 GB download).',
    delivery: ModelDelivery.download,
    quantization: 'int4',
    contextLength: 32768,
    minMemoryMB: 3072,
    languages: ['en'],
    platforms: ['android', 'ios', 'macos'],
    capabilities: {
      ModelCapability.chat,
      ModelCapability.streaming,
      ModelCapability.functionCalling,
    },
    license: 'gemma-terms-of-use',
    catalogVersion: 1,
    files: [
      ModelFile(
        name: 'gemma-4-E2B-it.litertlm',
        url:
            'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
        sha256: kPlaceholderSha256,
        sizeBytes: 2588147712,
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

  /// Zipformer Small English streaming speech recognition.
  static const LocalModelManifest zipformerSmall = LocalModelManifest(
    id: 'sherpa-onnx-streaming-zipformer-en-20m',
    type: ModelType.stt,
    provider: ModelProviders.sherpaCommunity,
    displayName: 'Zipformer Small ASR (20M)',
    description: 'English streaming speech recognition (70 MB).',
    delivery: ModelDelivery.download,
    minMemoryMB: 128,
    languages: ['en'],
    platforms: ['android', 'ios', 'macos'],
    capabilities: {ModelCapability.asrStreaming},
    license: 'Apache-2.0',
    catalogVersion: 1,
    files: [
      ModelFile(
        name: 'sherpa-onnx-streaming-zipformer-en-20M-2023-02-17.tar.bz2',
        url:
            'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17.tar.bz2',
        sha256: kPlaceholderSha256,
        sizeBytes: 70000000,
      ),
    ],
  );

  /// SenseVoice Small multilingual streaming ASR.
  static const LocalModelManifest senseVoiceSmall = LocalModelManifest(
    id: 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue',
    type: ModelType.stt,
    provider: ModelProviders.sherpaCommunity,
    displayName: 'SenseVoice Small Multilingual',
    description:
        'High-accuracy multilingual speech recognition (EN, JA, ZH, KO, YUE - 234 MB).',
    delivery: ModelDelivery.download,
    minMemoryMB: 512,
    languages: ['zh', 'en', 'ja', 'ko', 'yue'],
    platforms: ['android', 'ios', 'macos'],
    capabilities: {ModelCapability.asrStreaming, ModelCapability.multilingual},
    license: 'MIT',
    catalogVersion: 1,
    files: [
      ModelFile(
        name: 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2',
        url:
            'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2',
        sha256: kPlaceholderSha256,
        sizeBytes: 245366784,
      ),
    ],
  );

  /// Whisper Base English speech recognition.
  static const LocalModelManifest whisperBase = LocalModelManifest(
    id: 'sherpa-onnx-whisper-base.en',
    type: ModelType.stt,
    provider: ModelProviders.sherpaCommunity,
    displayName: 'Whisper Base English',
    description: 'High-accuracy speech recognition by OpenAI (75 MB).',
    delivery: ModelDelivery.download,
    minMemoryMB: 256,
    languages: ['en'],
    platforms: ['android', 'ios', 'macos'],
    capabilities: {ModelCapability.asrStreaming},
    license: 'MIT',
    catalogVersion: 1,
    files: [
      ModelFile(
        name: 'sherpa-onnx-whisper-base.en.tar.bz2',
        url:
            'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-base.en.tar.bz2',
        sha256: kPlaceholderSha256,
        sizeBytes: 74846467,
      ),
    ],
  );

  /// Whisper Tiny English speech recognition.
  static const LocalModelManifest whisperTiny = LocalModelManifest(
    id: 'sherpa-onnx-whisper-tiny.en',
    type: ModelType.stt,
    provider: ModelProviders.sherpaCommunity,
    displayName: 'Whisper Tiny English',
    description: 'Ultra-fast speech recognition by OpenAI (40 MB).',
    delivery: ModelDelivery.download,
    minMemoryMB: 128,
    languages: ['en'],
    platforms: ['android', 'ios', 'macos'],
    capabilities: {ModelCapability.asrStreaming},
    license: 'MIT',
    catalogVersion: 1,
    files: [
      ModelFile(
        name: 'sherpa-onnx-whisper-tiny.en.tar.bz2',
        url:
            'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-tiny.en.tar.bz2',
        sha256: kPlaceholderSha256,
        sizeBytes: 39828551,
      ),
    ],
  );

  /// Moonshine Tiny English next-generation speech recognition.
  static const LocalModelManifest moonshineTiny = LocalModelManifest(
    id: 'sherpa-onnx-moonshine-tiny-en',
    type: ModelType.stt,
    provider: ModelProviders.sherpaCommunity,
    displayName: 'Moonshine Tiny English',
    description: 'Next-gen sub-100ms speech recognition (30 MB).',
    delivery: ModelDelivery.download,
    minMemoryMB: 128,
    languages: ['en'],
    platforms: ['android', 'ios', 'macos'],
    capabilities: {ModelCapability.asrStreaming},
    license: 'MIT',
    catalogVersion: 1,
    files: [
      ModelFile(
        name: 'sherpa-onnx-moonshine-tiny-en-int8.tar.bz2',
        url:
            'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-moonshine-tiny-en-int8.tar.bz2',
        sha256: kPlaceholderSha256,
        sizeBytes: 30000000,
      ),
    ],
  );

  /// Piper fast streaming TTS model.
  static const LocalModelManifest vitsPiper = LocalModelManifest(
    id: 'vits-piper-en-lessac',
    type: ModelType.tts,
    provider: ModelProviders.sherpaCommunity,
    displayName: 'Piper TTS (Lessac Low)',
    description: 'Fast streaming text-to-speech (67 MB).',
    delivery: ModelDelivery.download,
    minMemoryMB: 128,
    languages: ['en'],
    platforms: ['android', 'ios', 'macos'],
    capabilities: {ModelCapability.ttsStreaming},
    license: 'MIT',
    catalogVersion: 1,
    files: [
      ModelFile(
        name: 'vits-piper-en_US-lessac-low.tar.bz2',
        url:
            'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-lessac-low.tar.bz2',
        sha256: kPlaceholderSha256,
        sizeBytes: 67097098,
      ),
    ],
  );

  /// Supertonic 3 multilingual on-device TTS model (Supertone Inc.).
  static const LocalModelManifest supertonic = LocalModelManifest(
    id: 'supertonic-tts',
    type: ModelType.tts,
    provider: ModelProviders.sherpaCommunity,
    displayName: 'Supertonic 3 (Supertone Inc. • 31+ Languages)',
    description:
        'Ultra-fast on-device neural TTS with 31+ languages and 10 voice styles (F1-F5, M1-M5).',
    delivery: ModelDelivery.download,
    minMemoryMB: 256,
    languages: [
      'en',
      'ko',
      'es',
      'ja',
      'zh',
      'fr',
      'de',
      'pt',
      'it',
      'ru',
      'ar',
      'hi',
      'nl',
      'pl',
      'tr',
      'sv',
      'id',
      'vi',
      'tl',
      'th',
      'el',
      'cs',
      'ro',
      'hu',
      'da',
      'fi',
      'no',
      'sk',
      'uk',
      'ms',
      'bn',
    ],
    platforms: ['android', 'ios', 'macos'],
    capabilities: {ModelCapability.ttsStreaming},
    license: 'Supertone Community License',
    catalogVersion: 2,
    voices: [
      LocalVoice(
          id: 'f1',
          name: 'Female Voice 1 (F1 • Soft Natural)',
          gender: 'female',
          language: 'mul',
          sampleRate: 44100),
      LocalVoice(
          id: 'f2',
          name: 'Female Voice 2 (F2 • Bright Expressive)',
          gender: 'female',
          language: 'mul',
          sampleRate: 44100),
      LocalVoice(
          id: 'f3',
          name: 'Female Voice 3 (F3 • Calm Narrative)',
          gender: 'female',
          language: 'mul',
          sampleRate: 44100),
      LocalVoice(
          id: 'f4',
          name: 'Female Voice 4 (F4 • Warm Friendly)',
          gender: 'female',
          language: 'mul',
          sampleRate: 44100),
      LocalVoice(
          id: 'f5',
          name: 'Female Voice 5 (F5 • Clear Professional)',
          gender: 'female',
          language: 'mul',
          sampleRate: 44100),
      LocalVoice(
          id: 'm1',
          name: 'Male Voice 1 (M1 • Deep Resonant)',
          gender: 'male',
          language: 'mul',
          sampleRate: 44100),
      LocalVoice(
          id: 'm2',
          name: 'Male Voice 2 (M2 • Friendly Casual)',
          gender: 'male',
          language: 'mul',
          sampleRate: 44100),
      LocalVoice(
          id: 'm3',
          name: 'Male Voice 3 (M3 • Confident Dynamic)',
          gender: 'male',
          language: 'mul',
          sampleRate: 44100),
      LocalVoice(
          id: 'm4',
          name: 'Male Voice 4 (M4 • Warm Storyteller)',
          gender: 'male',
          language: 'mul',
          sampleRate: 44100),
      LocalVoice(
          id: 'm5',
          name: 'Male Voice 5 (M5 • Clear Anchor)',
          gender: 'male',
          language: 'mul',
          sampleRate: 44100),
    ],
    files: [
      ModelFile(
        name: 'duration_predictor.onnx',
        url:
            'https://huggingface.co/Supertone/supertonic-3/resolve/main/onnx/duration_predictor.onnx',
        sha256: kPlaceholderSha256,
        sizeBytes: 3700147,
      ),
      ModelFile(
        name: 'text_encoder.onnx',
        url:
            'https://huggingface.co/Supertone/supertonic-3/resolve/main/onnx/text_encoder.onnx',
        sha256: kPlaceholderSha256,
        sizeBytes: 36416150,
      ),
      ModelFile(
        name: 'vector_estimator.onnx',
        url:
            'https://huggingface.co/Supertone/supertonic-3/resolve/main/onnx/vector_estimator.onnx',
        sha256: kPlaceholderSha256,
        sizeBytes: 256534781,
      ),
      ModelFile(
        name: 'vocoder.onnx',
        url:
            'https://huggingface.co/Supertone/supertonic-3/resolve/main/onnx/vocoder.onnx',
        sha256: kPlaceholderSha256,
        sizeBytes: 101424195,
      ),
      ModelFile(
        name: 'tts.json',
        url:
            'https://huggingface.co/Supertone/supertonic-3/resolve/main/onnx/tts.json',
        sha256: kPlaceholderSha256,
        sizeBytes: 8253,
      ),
      ModelFile(
        name: 'unicode_indexer.json',
        url:
            'https://huggingface.co/Supertone/supertonic-3/resolve/main/onnx/unicode_indexer.json',
        sha256: kPlaceholderSha256,
        sizeBytes: 277676,
      ),
      ModelFile(
        name: 'voice_style_F1.json',
        url:
            'https://huggingface.co/Supertone/supertonic-3/resolve/main/voice_styles/F1.json',
        sha256: kPlaceholderSha256,
        sizeBytes: 292046,
      ),
      ModelFile(
        name: 'voice_style_F2.json',
        url:
            'https://huggingface.co/Supertone/supertonic-3/resolve/main/voice_styles/F2.json',
        sha256: kPlaceholderSha256,
        sizeBytes: 292046,
      ),
      ModelFile(
        name: 'voice_style_F3.json',
        url:
            'https://huggingface.co/Supertone/supertonic-3/resolve/main/voice_styles/F3.json',
        sha256: kPlaceholderSha256,
        sizeBytes: 292046,
      ),
      ModelFile(
        name: 'voice_style_F4.json',
        url:
            'https://huggingface.co/Supertone/supertonic-3/resolve/main/voice_styles/F4.json',
        sha256: kPlaceholderSha256,
        sizeBytes: 292046,
      ),
      ModelFile(
        name: 'voice_style_F5.json',
        url:
            'https://huggingface.co/Supertone/supertonic-3/resolve/main/voice_styles/F5.json',
        sha256: kPlaceholderSha256,
        sizeBytes: 292046,
      ),
      ModelFile(
        name: 'voice_style_M1.json',
        url:
            'https://huggingface.co/Supertone/supertonic-3/resolve/main/voice_styles/M1.json',
        sha256: kPlaceholderSha256,
        sizeBytes: 291748,
      ),
      ModelFile(
        name: 'voice_style_M2.json',
        url:
            'https://huggingface.co/Supertone/supertonic-3/resolve/main/voice_styles/M2.json',
        sha256: kPlaceholderSha256,
        sizeBytes: 291748,
      ),
      ModelFile(
        name: 'voice_style_M3.json',
        url:
            'https://huggingface.co/Supertone/supertonic-3/resolve/main/voice_styles/M3.json',
        sha256: kPlaceholderSha256,
        sizeBytes: 291748,
      ),
      ModelFile(
        name: 'voice_style_M4.json',
        url:
            'https://huggingface.co/Supertone/supertonic-3/resolve/main/voice_styles/M4.json',
        sha256: kPlaceholderSha256,
        sizeBytes: 291748,
      ),
      ModelFile(
        name: 'voice_style_M5.json',
        url:
            'https://huggingface.co/Supertone/supertonic-3/resolve/main/voice_styles/M5.json',
        sha256: kPlaceholderSha256,
        sizeBytes: 291748,
      ),
      ModelFile(
        name: 'config.json',
        url:
            'https://huggingface.co/Supertone/supertonic-3/resolve/main/config.json',
        sha256: kPlaceholderSha256,
        sizeBytes: 174,
      ),
    ],
  );

  /// Kokoro streaming TTS high-quality multi-voice model.
  static const LocalModelManifest kokoroTts = LocalModelManifest(
    id: 'kokoro-en-tts',
    type: ModelType.tts,
    provider: ModelProviders.sherpaCommunity,
    displayName: 'Kokoro TTS (v0.19)',
    description: 'High-quality fast streaming text-to-speech (319 MB).',
    delivery: ModelDelivery.download,
    minMemoryMB: 256,
    languages: ['en'],
    platforms: ['android', 'ios', 'macos'],
    capabilities: {ModelCapability.ttsStreaming},
    license: 'Apache-2.0',
    catalogVersion: 1,
    files: [
      ModelFile(
        name: 'kokoro-en-v0_19.tar.bz2',
        url:
            'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-en-v0_19.tar.bz2',
        sha256: kPlaceholderSha256,
        sizeBytes: 319625534,
      ),
    ],
  );

  // ---------------------------------------------------------------------------
  // GGUF models (llama.cpp adapter, `local_ai_llama_cpp`)
  // ---------------------------------------------------------------------------

  /// Qwen 2.5 0.5B Instruct in GGUF, for the llama.cpp adapter.
  static const LocalModelManifest qwen25_05bGguf = LocalModelManifest(
    id: 'qwen-2.5-0.5b-instruct-gguf',
    type: ModelType.llm,
    provider: ModelProviders.llamaCpp,
    displayName: 'Qwen 2.5 0.5B Instruct (GGUF)',
    description:
        'Small ChatML chat model in GGUF Q4_K_M, run through llama.cpp.',
    delivery: ModelDelivery.download,
    quantization: 'q4_k_m',
    contextLength: 32768,
    minMemoryMB: 1024,
    languages: ['en', 'zh'],
    platforms: ['android', 'ios', 'macos', 'windows', 'linux'],
    capabilities: {
      ModelCapability.chat,
      ModelCapability.streaming,
      ModelCapability.multilingual,
    },
    license: 'apache-2.0',
    catalogVersion: 1,
    files: [
      ModelFile(
        name: 'qwen2.5-0.5b-instruct-q4_k_m.gguf',
        url:
            'https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf',
        sha256: kPlaceholderSha256,
        sizeBytes: 491000000,
      ),
    ],
  );

  /// Nomic Embed Text v1.5 in GGUF — the embedding counterpart of the
  /// llama.cpp chat models. Supports Matryoshka truncation down to 64 dims
  /// through `EmbeddingConfig.dimensions`.
  static const LocalModelManifest nomicEmbedText = LocalModelManifest(
    id: 'nomic-embed-text-v1.5-gguf',
    type: ModelType.embedding,
    provider: ModelProviders.llamaCpp,
    displayName: 'Nomic Embed Text v1.5 (GGUF)',
    description: '768-dimension text embeddings for on-device RAG '
        '(Matryoshka-truncatable).',
    delivery: ModelDelivery.download,
    quantization: 'q4_k_m',
    contextLength: 2048,
    minMemoryMB: 512,
    languages: ['en'],
    platforms: ['android', 'ios', 'macos', 'windows', 'linux'],
    capabilities: {ModelCapability.embedding},
    license: 'apache-2.0',
    catalogVersion: 1,
    files: [
      ModelFile(
        name: 'nomic-embed-text-v1.5.Q4_K_M.gguf',
        url:
            'https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q4_K_M.gguf',
        sha256: kPlaceholderSha256,
        sizeBytes: 84110000,
      ),
    ],
  );

  /// All built-in manifests, keyed by id.
  static const List<LocalModelManifest> all = [
    qwen35_08b,
    qwen35_2b,
    qwen35_4b,
    smollm2,
    gemma4E2b,
    gemma4E4b,
    qwen25_05b,
    deepseekR1,
    gemma3nE2b,
    sileroVad,
    zipformerSmall,
    senseVoiceSmall,
    whisperBase,
    whisperTiny,
    moonshineTiny,
    vitsPiper,
    supertonic,
    kokoroTts,
    qwen25_05bGguf,
    nomicEmbedText,
  ];

  /// Lookup helper; returns `null` for unknown ids.
  static LocalModelManifest? byId(String id) {
    for (final manifest in all) {
      if (manifest.id == id) return manifest;
    }
    return null;
  }
}
