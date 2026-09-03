/// Worker isolate hosting every llama.cpp call (spec §2).
///
/// Threading model:
///  * one worker per loaded model — the chat adapter and the embedding
///    adapter each get their own, so a `LlamaCppLlmAdapter` and a
///    `LlamaCppEmbeddingAdapter` never contend for one `llama_context`;
///  * the `Llama` handle, its `llama_context` and its KV cache live inside
///    the isolate for the whole lifetime of `load()`…`unload()`, which is
///    what makes multi-turn generation cheap: an unchanged history prefix
///    is never re-evaluated;
///  * the UI isolate only ever sees the primitives in
///    `llama_worker_protocol.dart` — no FFI pointer, no `llama_cpp_dart`
///    type, crosses back;
///  * generation yields to the isolate event loop between tokens so a
///    `LlamaCancelCommand` can land mid-stream.
library;

import 'dart:async';
import 'dart:isolate';

// Prefixed so llama_cpp_dart's own names (it also exports a `LlamaCommand`)
// never collide with this package's isolate protocol.
import 'package:llama_cpp_dart/llama_cpp_dart.dart' as llama;

import '../stop_sequences.dart';
import 'llama_worker_protocol.dart';

/// Handle to a running llama.cpp worker isolate.
class LlamaWorker {
  LlamaWorker._({
    required Isolate isolate,
    required SendPort commands,
    required Stream<LlamaWorkerEvent> events,
    required ReceivePort receivePort,
    required RawReceivePort errorPort,
    required RawReceivePort exitPort,
    required Completer<void> exited,
  })  : _isolate = isolate,
        _commands = commands,
        _events = events,
        _receivePort = receivePort,
        _errorPort = errorPort,
        _exitPort = exitPort,
        _exited = exited;

  /// How long [dispose] waits for the worker to free the model before
  /// killing the isolate outright.
  static const Duration shutdownGrace = Duration(seconds: 10);

  final Isolate _isolate;
  final SendPort _commands;
  final Stream<LlamaWorkerEvent> _events;
  final ReceivePort _receivePort;
  final RawReceivePort _errorPort;
  final RawReceivePort _exitPort;
  final Completer<void> _exited;

  void Function()? _onDisposeStarted;
  bool _disposed = false;

  /// Broadcast stream of everything the worker reports.
  Stream<LlamaWorkerEvent> get events => _events;

  /// Spawns the isolate and completes once it is ready for commands.
  static Future<LlamaWorker> spawn() async {
    final receivePort = ReceivePort();
    final controller = StreamController<LlamaWorkerEvent>.broadcast();
    final ready = Completer<SendPort>();
    final exited = Completer<void>();
    var disposing = false;

    receivePort.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
      } else if (message is LlamaWorkerEvent) {
        controller.add(message);
      }
    });

    final isolate = await Isolate.spawn(
      llamaWorkerEntrypoint,
      receivePort.sendPort,
      debugName: 'llama.cpp worker',
    );
    // Crash isolation: an uncaught error (including a native call that
    // throws) surfaces as an error event instead of hanging every pending
    // request forever.
    isolate.setErrorsFatal(false);
    final errorPort = RawReceivePort((message) {
      controller.add(LlamaErrorEvent(
        'llama.cpp worker isolate raised an uncaught error',
        details: '$message',
      ));
    });
    isolate.addErrorListener(errorPort.sendPort);

    final exitPort = RawReceivePort((_) {
      if (!exited.isCompleted) exited.complete();
      // An exit nobody asked for means the isolate died mid-request; without
      // this the pending generation would never terminate.
      if (!disposing) {
        controller.add(const LlamaErrorEvent(
          'llama.cpp worker isolate stopped unexpectedly',
        ));
      }
    });
    isolate.addOnExitListener(exitPort.sendPort);

    final commands = await ready.future;
    return LlamaWorker._(
      isolate: isolate,
      commands: commands,
      events: controller.stream,
      receivePort: receivePort,
      errorPort: errorPort,
      exitPort: exitPort,
      exited: exited,
    ).._onDisposeStarted = () => disposing = true;
  }

  /// Sends [command] to the worker.
  void send(LlamaCommand command) {
    if (_disposed) return;
    _commands.send(command);
  }

  /// Shuts the worker down and releases its ports. Idempotent.
  ///
  /// The shutdown command is what actually frees the model: llama.cpp's
  /// allocations belong to the *process*, not to the isolate, so killing the
  /// isolate outright would leak gigabytes. The kill below is only the
  /// fallback for a worker wedged in a native call that never returns to its
  /// message loop.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _onDisposeStarted?.call();
    try {
      _commands.send(const LlamaShutdownCommand());
      await _exited.future.timeout(shutdownGrace, onTimeout: () {});
    } on Object {
      // The isolate may already be gone; the kill below covers it.
    }
    _isolate.kill(priority: Isolate.beforeNextEvent);
    _receivePort.close();
    _errorPort.close();
    _exitPort.close();
  }
}

/// Isolate entrypoint. Must be a top-level function to cross the boundary.
void llamaWorkerEntrypoint(SendPort host) {
  final commands = ReceivePort();
  host.send(commands.sendPort);
  final worker = _LlamaWorkerLoop(host: host, commands: commands);
  worker.run();
}

/// The command loop running inside the worker isolate.
class _LlamaWorkerLoop {
  _LlamaWorkerLoop({required this.host, required this.commands});

  final SendPort host;
  final ReceivePort commands;

  llama.Llama? _llama;
  LlamaLoadCommand? _load;
  SamplerSpec? _activeSampler;

  /// Tokens currently committed to the KV cache (prompt + generated).
  int _tokensInContext = 0;

  /// See [_probeAddsSpecialTokens].
  bool _addsSpecialTokens = true;

  int? _cancelRequested;
  bool _generating = false;

  void run() {
    commands.listen((message) async {
      try {
        switch (message) {
          case LlamaLoadCommand():
            _handleLoad(message);
          case LlamaGenerateCommand():
            await _handleGenerate(message);
          case LlamaEmbedCommand():
            _handleEmbed(message);
          case LlamaCancelCommand():
            _cancelRequested = message.requestId;
          case LlamaShutdownCommand():
            _disposeLlama();
            commands.close();
          default:
            break;
        }
      } on Object catch (error, stackTrace) {
        host.send(LlamaErrorEvent(
          '$error',
          requestId: switch (message) {
            LlamaGenerateCommand() => message.requestId,
            LlamaEmbedCommand() => message.requestId,
            _ => null,
          },
          details: '$stackTrace',
        ));
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Load
  // ---------------------------------------------------------------------------

  void _handleLoad(LlamaLoadCommand command) {
    _load = command;
    llama.Llama.libraryPath = command.libraryPath;
    var gpuLayers = command.gpuLayers;
    try {
      _llama = _createLlama(command, command.sampler, gpuLayers);
    } on Object catch (error) {
      if (gpuLayers == 0) {
        host.send(LlamaErrorEvent(
          'llama.cpp failed to load "${command.modelPath}"',
          details: '$error',
        ));
        return;
      }
      // Fallback layer 1 (spec §2): retry on CPU inside the adapter before
      // letting the kit's RuntimeScheduler see a failure.
      gpuLayers = 0;
      try {
        _llama = _createLlama(command, command.sampler, gpuLayers);
      } on Object catch (cpuError) {
        host.send(LlamaErrorEvent(
          'llama.cpp failed to load "${command.modelPath}" on GPU and CPU',
          details: 'gpu: $error\ncpu: $cpuError',
        ));
        return;
      }
    }
    _activeSampler = command.sampler;
    _tokensInContext = 0;
    _addsSpecialTokens = _probeAddsSpecialTokens(_llama!);
    host.send(LlamaLoadedEvent(
      contextTokens: command.contextTokens,
      embeddingDimensions:
          command.embeddingMode ? llama.Llama.lib.llama_n_embd(_llama!.model) : 0,
      gpuLayers: gpuLayers,
      supportsCachedContinuation: !_addsSpecialTokens,
    ));
  }

  /// Whether this model's tokenizer prepends a BOS (or other special) token.
  ///
  /// `llama_cpp_dart`'s `setPrompt` always tokenizes with `add_special =
  /// true`, so for such a model every continuation would inject a second BOS
  /// in the middle of the sequence. Rather than corrupt the history, the
  /// adapter re-evaluates the full prompt for those models — see
  /// [LlamaLoadedEvent.supportsCachedContinuation].
  bool _probeAddsSpecialTokens(llama.Llama handle) {
    try {
      return handle.tokenize('a', true).length !=
          handle.tokenize('a', false).length;
    } on Object {
      return true; // Unknown → take the safe path.
    }
  }

  llama.Llama _createLlama(
    LlamaLoadCommand command,
    SamplerSpec sampler,
    int gpuLayers,
  ) {
    final modelParams = llama.ModelParams()..nGpuLayers = gpuLayers;

    final contextParams = llama.ContextParams()
      ..nCtx = command.contextTokens
      // The whole prompt is submitted as one logical batch, so n_batch has
      // to cover the context; n_ubatch stays at llama.cpp's default so the
      // compute buffer doesn't grow with the context size.
      ..nBatch = command.contextTokens
      ..nUbatch = command.contextTokens < 512 ? command.contextTokens : 512
      ..nThreads = command.threads
      ..nThreadsBatch = command.threads
      // Token budgets are enforced per request in the generation loop.
      ..nPredict = -1
      ..embeddings = command.embeddingMode;
    if (command.embeddingMode) {
      contextParams.poolingType = llama.LlamaPoolingType.mean;
    }

    return llama.Llama(
      command.modelPath,
      modelParams: modelParams,
      contextParams: contextParams,
      samplerParams: _samplerParams(sampler),
    );
  }

  llama.SamplerParams _samplerParams(SamplerSpec spec) {
    final params = llama.SamplerParams()
      ..temp = spec.temperature
      ..topK = spec.topK
      ..topP = spec.topP
      ..penaltyRepeat = spec.repeatPenalty
      ..penaltyLastTokens = spec.repeatLastN
      ..grammarStr = spec.grammar
      ..grammarRoot = spec.grammar.isEmpty ? '' : 'root';
    if (spec.seed != null) params.seed = spec.seed!;
    return params;
  }

  /// Rebuilds the `Llama` instance when a request needs different sampling.
  ///
  /// llama.cpp builds its sampler chain with the context and
  /// `llama_cpp_dart` exposes no way to replace it, so a grammar (or a
  /// changed temperature) costs a rebuild. Weights come back from the OS
  /// page cache, but the KV cache is gone — which is why the adapter treats
  /// a sampler change as a forced context reset.
  bool _ensureSampler(SamplerSpec spec) {
    if (_activeSampler == spec) return false;
    final load = _load;
    if (load == null) throw StateError('llama.cpp worker: load() first');
    final previous = _llama;
    _llama = null;
    previous?.dispose();
    _llama = _createLlama(load, spec, load.gpuLayers);
    _activeSampler = spec;
    _tokensInContext = 0;
    return true;
  }

  // ---------------------------------------------------------------------------
  // Generation
  // ---------------------------------------------------------------------------

  Future<void> _handleGenerate(LlamaGenerateCommand command) async {
    if (_llama == null) {
      host.send(LlamaErrorEvent(
        'llama.cpp worker: generate before load',
        requestId: command.requestId,
      ));
      return;
    }
    if (_generating) {
      host.send(LlamaErrorEvent(
        'llama.cpp worker: a generation is already running',
        requestId: command.requestId,
      ));
      return;
    }

    _generating = true;
    _cancelRequested = null;
    final scanner = StopSequenceScanner(command.stopSequences);
    var completionTokens = 0;
    var reason = LlamaStopReason.endOfSequence;

    try {
      if (command.prompt.isEmpty) {
        throw StateError('llama.cpp worker: empty prompt');
      }
      final rebuilt = _ensureSampler(command.sampler);
      final active = _llama!;
      // A sampler rebuild dropped the context, and an empty context can
      // never be continued — either forces a reset whatever the adapter
      // asked for.
      if (command.resetContext || rebuilt || _tokensInContext == 0) {
        active.clear();
        _tokensInContext = 0;
      }

      _tokensInContext +=
          active.tokenize(command.prompt, _tokensInContext == 0).length;
      final promptTokens = _tokensInContext;
      active.setPrompt(command.prompt);

      while (true) {
        if (_cancelRequested == command.requestId) {
          reason = LlamaStopReason.cancelled;
          break;
        }
        final (piece, isDone, contextLimitReached) = active.getNextWithStatus();
        if (contextLimitReached) {
          reason = LlamaStopReason.contextFull;
          break;
        }
        if (!isDone) {
          completionTokens++;
          _tokensInContext++;
        }
        if (piece.isNotEmpty) {
          final scan = scanner.add(piece);
          if (scan.text.isNotEmpty) {
            host.send(LlamaChunkEvent(command.requestId, scan.text));
          }
          if (scan.stopped) {
            reason = LlamaStopReason.stopSequence;
            break;
          }
        }
        if (isDone) {
          reason = LlamaStopReason.endOfSequence;
          break;
        }
        final maxTokens = command.maxTokens;
        if (maxTokens != null && completionTokens >= maxTokens) {
          reason = LlamaStopReason.maxTokens;
          break;
        }
        // Let queued commands (notably cancel) run between tokens.
        await Future<void>.delayed(Duration.zero);
      }

      final tail = scanner.flush();
      if (tail.isNotEmpty) host.send(LlamaChunkEvent(command.requestId, tail));

      host.send(LlamaDoneEvent(
        requestId: command.requestId,
        reason: reason,
        promptTokens: promptTokens,
        completionTokens: completionTokens,
      ));
    } on Object catch (error, stackTrace) {
      // The KV cache state after a native failure is unknown; force the next
      // request to start from a clean context.
      _tokensInContext = 0;
      host.send(LlamaErrorEvent(
        '$error',
        requestId: command.requestId,
        details: '$stackTrace',
      ));
    } finally {
      _generating = false;
      _cancelRequested = null;
    }
  }

  // ---------------------------------------------------------------------------
  // Embeddings
  // ---------------------------------------------------------------------------

  void _handleEmbed(LlamaEmbedCommand command) {
    final handle = _llama;
    if (handle == null) {
      host.send(LlamaErrorEvent(
        'llama.cpp worker: embed before load',
        requestId: command.requestId,
      ));
      return;
    }
    final vectors = <List<double>>[];
    for (final text in command.texts) {
      // getEmbeddings clears the context itself, so batching here is a plain
      // loop rather than a shared-context optimisation.
      vectors.add(text.isEmpty
          ? const <double>[]
          : handle.getEmbeddings(text, normalize: true));
    }
    host.send(LlamaEmbeddingsEvent(command.requestId, vectors));
  }

  void _disposeLlama() {
    final handle = _llama;
    _llama = null;
    _activeSampler = null;
    _tokensInContext = 0;
    handle?.dispose();
  }
}
