/// Pluggable adapter mechanism (architecture §4.5).
///
/// `local_ai_kit` never depends on adapter packages directly; apps register
/// the ones they use, keeping unused native runtimes out of the binary.
library;

import 'dart:async';
import '../audio/local_audio_output.dart';
import '../audio/local_audio_source.dart';
import '../common/local_storage_paths.dart';
import '../common/network_policy.dart';
import '../embedding/local_embedding.dart';
import '../errors/local_ai_error.dart';
import '../llm/local_llm.dart';
import '../models/manifest.dart';
import '../stt/local_stt.dart';
import '../tts/local_tts.dart';
import '../vad/local_vad.dart';

/// Everything an adapter needs at construction time, supplied by the kit.
class AdapterContext {
  const AdapterContext({
    required this.paths,
    required this.networkPolicy,
    this.audioSource,
    this.audioOutput,
  });

  /// Resolved on-disk storage layout.
  final LocalStoragePaths paths;

  /// Active network policy (for adapters that download auxiliary data).
  final NetworkPolicy networkPolicy;

  /// Shared microphone source, when the app enabled audio input.
  final LocalAudioSource? audioSource;

  /// Shared speaker output, when the app enabled audio output.
  final LocalAudioOutput? audioOutput;
}

typedef LlmAdapterFactory = LocalLlm Function(AdapterContext context);
typedef SttAdapterFactory = LocalStt Function(AdapterContext context);
typedef TtsAdapterFactory = LocalTts Function(AdapterContext context);
typedef VadAdapterFactory = LocalVad Function(AdapterContext context);
typedef EmbeddingAdapterFactory = LocalEmbedding Function(
    AdapterContext context);

/// An adapter package's registration hook, e.g. `GemmaAdapterPlugin`.
abstract interface class AdapterPlugin {
  /// Registers this plugin's factories into [registry].
  void register(AdapterRegistry registry);
}

/// Routes manifests to adapter factories by `manifest.provider`.
class AdapterRegistry {
  final Map<String, LlmAdapterFactory> _llm = {};
  final Map<String, SttAdapterFactory> _stt = {};
  final Map<String, TtsAdapterFactory> _tts = {};
  final Map<String, VadAdapterFactory> _vad = {};
  final Map<String, EmbeddingAdapterFactory> _embedding = {};

  AdapterContext _context = const AdapterContext(
    paths: _UninitializedPaths(),
    networkPolicy: _UninitializedNetworkPolicy(),
  );
  bool _contextSet = false;

  /// Called once by the kit before any resolution. Adapter plugins usually
  /// don't need to touch this.
  void attachContext(AdapterContext context) {
    _context = context;
    _contextSet = true;
  }

  void registerLlm(String provider, LlmAdapterFactory factory) =>
      _llm[provider] = factory;
  void registerStt(String provider, SttAdapterFactory factory) =>
      _stt[provider] = factory;
  void registerTts(String provider, TtsAdapterFactory factory) =>
      _tts[provider] = factory;
  void registerVad(String provider, VadAdapterFactory factory) =>
      _vad[provider] = factory;
  void registerEmbedding(String provider, EmbeddingAdapterFactory factory) =>
      _embedding[provider] = factory;

  /// Looks up a previously registered LLM factory (used by decorator
  /// plugins such as the Genkit layer to wrap an existing adapter).
  LlmAdapterFactory? llmFactory(String provider) => _llm[provider];

  SttAdapterFactory? sttFactory(String provider) => _stt[provider];
  TtsAdapterFactory? ttsFactory(String provider) => _tts[provider];
  VadAdapterFactory? vadFactory(String provider) => _vad[provider];
  EmbeddingAdapterFactory? embeddingFactory(String provider) =>
      _embedding[provider];

  /// Whether an adapter exists for [provider] + capability [type].
  bool supports(String provider, ModelType type) => switch (type) {
        ModelType.llm => _llm.containsKey(provider),
        ModelType.stt => _stt.containsKey(provider),
        ModelType.tts => _tts.containsKey(provider),
        ModelType.vad => _vad.containsKey(provider),
        ModelType.embedding => _embedding.containsKey(provider),
      };

  /// Resolves the LLM adapter for [manifest] by its provider.
  LocalLlm resolveLlm(LocalModelManifest manifest) =>
      _resolve(_llm, manifest, 'llm');

  LocalStt resolveStt(LocalModelManifest manifest) =>
      _resolve(_stt, manifest, 'stt');

  LocalTts resolveTts(LocalModelManifest manifest) =>
      _resolve(_tts, manifest, 'tts');

  LocalVad resolveVad(LocalModelManifest manifest) =>
      _resolve(_vad, manifest, 'vad');

  LocalEmbedding resolveEmbedding(LocalModelManifest manifest) =>
      _resolve(_embedding, manifest, 'embedding');

  T _resolve<T>(Map<String, T Function(AdapterContext)> factories,
      LocalModelManifest manifest, String capability) {
    final factory = factories[manifest.provider];
    if (factory == null) {
      throw AdapterNotFoundError(
        provider: manifest.provider,
        capability: capability,
      );
    }
    return factory(_context);
  }

  bool get hasContext => _contextSet;
}

class _UninitializedPaths implements LocalStoragePaths {
  const _UninitializedPaths();

  Never _fail() => throw StateError(
      'AdapterRegistry.attachContext() was not called before resolution.');

  @override
  String get rootDir => _fail();
  @override
  String get modelsDir => _fail();
  @override
  String modelDir(ModelType type, String modelId) => _fail();
  @override
  String get downloadsDir => _fail();
  @override
  String downloadDir(String modelId) => _fail();
  @override
  String get voicesDir => _fail();
  @override
  String voiceDir(String voiceId) => _fail();
  @override
  String get manifestsDir => _fail();
  @override
  String get cacheDir => _fail();
  @override
  Future<void> ensureInitialized() => _fail();
}

class _UninitializedNetworkPolicy implements NetworkPolicy {
  const _UninitializedNetworkPolicy();

  Never _fail() => throw StateError(
      'AdapterRegistry.attachContext() was not called before resolution.');

  @override
  Future<bool> canDownload({bool wifiOnly = true}) => _fail();
  @override
  Future<NetworkStatus> currentStatus() => _fail();
  @override
  Stream<NetworkStatus> get onStatusChanged => _fail();
}
