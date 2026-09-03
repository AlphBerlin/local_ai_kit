/// llama.cpp embedding adapter: a GGUF embedding model → core
/// `LocalEmbedding` (spec §4).
///
/// This is the first real [LocalEmbedding] implementation in the kit; until
/// now the interface, the config, the `models/embedding/` directory and
/// `AdapterRegistry.registerEmbedding` existed with nothing behind them.
library;

import 'dart:async';
import 'dart:io';

import 'package:local_ai_core/local_ai_core.dart';

import 'backend_selection.dart';
import 'embedding_vectors.dart';
import 'gguf_locator.dart';
import 'isolate/llama_worker.dart';
import 'isolate/llama_worker_protocol.dart';
import 'llama_cpp_runtime.dart';

/// Embeds text with an embedding-mode GGUF model (nomic-embed, bge, e5, …).
///
/// The model is a *separate* file from the chat model and gets its own
/// worker isolate, because llama.cpp decides between causal generation and
/// pooled embedding output when the context is created. Loading both
/// capabilities at once therefore costs two resident contexts — the kit's
/// `RuntimeMemoryPolicy` LRU applies to each of them independently.
class LlamaCppEmbeddingAdapter implements LocalEmbedding {
  LlamaCppEmbeddingAdapter({required LocalStoragePaths paths})
      : _paths = paths;

  /// Registered provider key (matches `ModelProviders.llamaCpp`).
  static const String provider = ModelProviders.llamaCpp;

  /// Context window for embedding models; longer inputs are truncated by
  /// llama.cpp to the batch size.
  static const int defaultContextTokens = 2048;

  final LocalStoragePaths _paths;

  LlamaWorker? _worker;
  EmbeddingLoadOptions? _options;
  int _dimensions = 0;
  int _requestCounter = 0;
  bool _loaded = false;

  Completer<void>? _inFlight;

  /// Whether the embedding model is loaded.
  bool get isLoaded => _loaded;

  /// Native embedding width of the loaded model, before any truncation
  /// requested through [EmbeddingLoadOptions.dimensions]. `0` when not
  /// loaded.
  int get nativeDimensions => _dimensions;

  @override
  Future<void> load(EmbeddingLoadOptions options) async {
    if (_loaded) await unload();
    _options = options;

    final modelFile =
        GgufLocator.resolve(_paths, ModelType.embedding, options.modelId);
    final plan = BackendSelection.resolve(
      RuntimePreference.auto,
      processorCount: Platform.numberOfProcessors,
    );

    final worker = await LlamaWorker.spawn();
    _worker = worker;
    final loaded = worker.events.firstWhere(
      (event) => event is LlamaLoadedEvent || event is LlamaErrorEvent,
    );
    worker.send(LlamaLoadCommand(
      modelPath: modelFile.path,
      libraryPath: LlamaCppRuntime.libraryPath,
      gpuLayers: plan.gpuLayers,
      threads: plan.threads,
      contextTokens: defaultContextTokens,
      sampler: const SamplerSpec(),
      embeddingMode: true,
    ));

    final event = await loaded;
    if (event is LlamaErrorEvent) {
      await worker.dispose();
      _worker = null;
      throw NativeRuntimeError(
        'llama.cpp could not load embedding model "${options.modelId}": '
        '${event.message}',
        cause: event.details,
      );
    }
    _dimensions = (event as LlamaLoadedEvent).embeddingDimensions;
    _loaded = true;
  }

  @override
  Future<void> unload() async {
    await _worker?.dispose();
    _worker = null;
    _loaded = false;
    _dimensions = 0;
  }

  @override
  Future<List<double>> embed(String text) async {
    final vectors = await embedBatch(<String>[text]);
    return vectors.first;
  }

  @override
  Future<List<List<double>>> embedBatch(List<String> texts) async {
    final worker = _worker;
    if (!_loaded || worker == null) {
      throw const InvalidStateError(
          'LlamaCppEmbeddingAdapter: embed called before load().');
    }
    if (texts.isEmpty) return const <List<double>>[];

    await _acquire();
    try {
      final requestId = ++_requestCounter;
      final result = worker.events.firstWhere((event) =>
          (event is LlamaEmbeddingsEvent && event.requestId == requestId) ||
          (event is LlamaErrorEvent &&
              (event.requestId == null || event.requestId == requestId)));
      worker.send(LlamaEmbedCommand(requestId: requestId, texts: texts));

      final event = await result;
      if (event is LlamaErrorEvent) {
        throw NativeRuntimeError(
          'llama.cpp embedding failed: ${event.message}',
          cause: event.details,
        );
      }
      final vectors = (event as LlamaEmbeddingsEvent).vectors;
      final dimensions = _options?.dimensions;
      return <List<double>>[
        for (final vector in vectors)
          EmbeddingVectors.truncate(vector, dimensions),
      ];
    } finally {
      _release();
    }
  }

  /// One `llama_context` means one decode at a time.
  Future<void> _acquire() async {
    while (_inFlight != null) {
      await _inFlight!.future;
    }
    _inFlight = Completer<void>();
  }

  void _release() {
    final completer = _inFlight;
    _inFlight = null;
    completer?.complete();
  }
}
