/// Messages exchanged with the llama.cpp worker isolate.
///
/// Deliberately free of `llama_cpp_dart` imports: these objects cross the
/// isolate boundary, so they hold primitives only and can be constructed
/// (and asserted on) from tests that never touch the native runtime.
library;

/// Sampling configuration for one request.
///
/// llama.cpp builds its sampler chain when the context is created and
/// `llama_cpp_dart` exposes no way to swap it afterwards, so changing any
/// of these values forces the worker to rebuild the `Llama` instance —
/// which also drops the KV cache. Equality is therefore load-bearing: the
/// adapter compares specs to decide whether a request can reuse the cache.
class SamplerSpec {
  const SamplerSpec({
    this.temperature = 0.8,
    this.topK = 40,
    this.topP = 0.9,
    this.repeatPenalty = 1.1,
    this.repeatLastN = 64,
    this.grammar = '',
    this.seed,
  });

  final double temperature;
  final int topK;
  final double topP;
  final double repeatPenalty;
  final int repeatLastN;

  /// GBNF grammar constraining generation; empty = unconstrained.
  final String grammar;

  /// Fixed sampling seed, or `null` for a random one per load.
  final int? seed;

  SamplerSpec copyWith({
    double? temperature,
    int? topK,
    double? topP,
    String? grammar,
  }) {
    return SamplerSpec(
      temperature: temperature ?? this.temperature,
      topK: topK ?? this.topK,
      topP: topP ?? this.topP,
      repeatPenalty: repeatPenalty,
      repeatLastN: repeatLastN,
      grammar: grammar ?? this.grammar,
      seed: seed,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SamplerSpec &&
      other.temperature == temperature &&
      other.topK == topK &&
      other.topP == topP &&
      other.repeatPenalty == repeatPenalty &&
      other.repeatLastN == repeatLastN &&
      other.grammar == grammar &&
      other.seed == seed;

  @override
  int get hashCode => Object.hash(
      temperature, topK, topP, repeatPenalty, repeatLastN, grammar, seed);

  @override
  String toString() => 'SamplerSpec(temp: $temperature, topK: $topK, '
      'topP: $topP, grammar: ${grammar.isEmpty ? 'none' : '${grammar.length} chars'})';
}

/// Base class of everything sent *to* the worker.
sealed class LlamaCommand {
  const LlamaCommand();
}

/// Loads the model. Sent once, right after the isolate handshake.
class LlamaLoadCommand extends LlamaCommand {
  const LlamaLoadCommand({
    required this.modelPath,
    required this.libraryPath,
    required this.gpuLayers,
    required this.threads,
    required this.contextTokens,
    required this.sampler,
    this.embeddingMode = false,
  });

  final String modelPath;

  /// Shared library to open, or `null` to resolve from the process.
  final String? libraryPath;

  final int gpuLayers;
  final int threads;
  final int contextTokens;
  final SamplerSpec sampler;

  /// True for the embedding adapter: enables llama.cpp's embedding output
  /// with mean pooling instead of causal generation.
  final bool embeddingMode;
}

/// Starts one generation.
class LlamaGenerateCommand extends LlamaCommand {
  const LlamaGenerateCommand({
    required this.requestId,
    required this.prompt,
    required this.resetContext,
    required this.sampler,
    this.maxTokens,
    this.stopSequences = const <String>[],
  });

  final int requestId;

  /// Text to tokenize. When [resetContext] is false this is only the new
  /// tail of the conversation — the rest is already in the KV cache.
  final String prompt;

  /// Clear the KV cache before feeding [prompt].
  final bool resetContext;

  /// Sampling for this request; a change from the loaded spec makes the
  /// worker rebuild the `Llama` instance (and implies [resetContext]).
  final SamplerSpec sampler;

  final int? maxTokens;
  final List<String> stopSequences;
}

/// Embeds one or more texts.
class LlamaEmbedCommand extends LlamaCommand {
  const LlamaEmbedCommand({required this.requestId, required this.texts});

  final int requestId;
  final List<String> texts;
}

/// Asks the worker to stop the in-flight generation.
class LlamaCancelCommand extends LlamaCommand {
  const LlamaCancelCommand(this.requestId);

  final int requestId;
}

/// Frees the model and lets the isolate exit.
class LlamaShutdownCommand extends LlamaCommand {
  const LlamaShutdownCommand();
}

/// Base class of everything sent *from* the worker.
sealed class LlamaWorkerEvent {
  const LlamaWorkerEvent();
}

/// The model finished loading.
class LlamaLoadedEvent extends LlamaWorkerEvent {
  const LlamaLoadedEvent({
    required this.contextTokens,
    required this.embeddingDimensions,
    required this.gpuLayers,
    required this.supportsCachedContinuation,
  });

  final int contextTokens;

  /// Embedding width, or `0` when the model was not loaded in embedding
  /// mode.
  final int embeddingDimensions;

  /// Layers actually requested for GPU offload — `0` after the worker's
  /// internal CPU retry, so the adapter can report the effective backend.
  final int gpuLayers;

  /// False when this model's tokenizer prepends special tokens, which makes
  /// continuing a cached context unsafe with `llama_cpp_dart`'s always-on
  /// `add_special` tokenization. The adapter then re-evaluates the full
  /// prompt on every turn instead of extending the KV cache.
  final bool supportsCachedContinuation;
}

/// One piece of generated text.
class LlamaChunkEvent extends LlamaWorkerEvent {
  const LlamaChunkEvent(this.requestId, this.text);

  final int requestId;
  final String text;
}

/// Why a generation ended, mirroring `LlmFinishReason` without importing it
/// into the isolate protocol.
enum LlamaStopReason { endOfSequence, maxTokens, contextFull, stopSequence, cancelled }

/// Terminal event of a generation.
class LlamaDoneEvent extends LlamaWorkerEvent {
  const LlamaDoneEvent({
    required this.requestId,
    required this.reason,
    required this.promptTokens,
    required this.completionTokens,
  });

  final int requestId;
  final LlamaStopReason reason;
  final int promptTokens;
  final int completionTokens;
}

/// Result of a [LlamaEmbedCommand].
class LlamaEmbeddingsEvent extends LlamaWorkerEvent {
  const LlamaEmbeddingsEvent(this.requestId, this.vectors);

  final int requestId;
  final List<List<double>> vectors;
}

/// A failure inside the worker. [requestId] is `null` for load failures.
class LlamaErrorEvent extends LlamaWorkerEvent {
  const LlamaErrorEvent(this.message, {this.requestId, this.details});

  final String message;
  final int? requestId;
  final String? details;
}
