/// llama.cpp LLM adapter: any GGUF chat model → core `LocalLlm`.
library;

import 'dart:async';
import 'dart:io';

import 'package:local_ai_core/local_ai_core.dart';

import 'backend_selection.dart';
import 'chat_template.dart';
import 'context_window.dart';
import 'gguf_locator.dart';
import 'isolate/llama_worker.dart';
import 'isolate/llama_worker_protocol.dart';
import 'json_schema_to_gbnf.dart';
import 'llama_cpp_runtime.dart';
import 'prompt_plan.dart';

/// [LocalLlm] implementation backed by llama.cpp, for any GGUF model.
///
/// What it does beyond a "reload per request" implementation:
///  * keeps one `llama_context` (and its KV cache) alive for the whole
///    `load()`…`unload()` lifetime, so an unchanged history prefix is never
///    re-evaluated (see [PromptPlanner] for when that is safe);
///  * constrains structured output with a real GBNF grammar
///    ([JsonSchemaToGbnf]) instead of asking the model nicely for JSON;
///  * delegates repetition control to llama.cpp's native samplers rather
///    than post-hoc Dart heuristics;
///  * reports real `promptTokens` / `completionTokens` and a truthful
///    `finishReason`.
///
/// Every llama.cpp call happens in a worker isolate ([LlamaWorker]); no
/// `llama_cpp_dart` type appears in this class's API.
class LlamaCppLlmAdapter with StructuredOutputSupport implements LocalLlm {
  LlamaCppLlmAdapter({required LocalStoragePaths paths}) : _paths = paths;

  /// Registered provider key (matches `ModelProviders.llamaCpp`).
  static const String provider = ModelProviders.llamaCpp;

  /// Context window used when the manifest and config say nothing.
  static const int defaultContextTokens = 4096;

  /// Repetition penalty handed to llama.cpp's native sampler.
  static const double defaultRepeatPenalty = 1.1;

  final LocalStoragePaths _paths;

  LlamaWorker? _worker;
  LlmLoadOptions? _options;
  LlamaChatFormat _format = LlamaChatFormat.chatml;
  SamplerSpec _baseSampler = const SamplerSpec();
  SamplerSpec? _activeSampler;
  bool _loaded = false;
  bool _supportsCachedContinuation = false;
  int _contextTokens = defaultContextTokens;
  int _effectiveGpuLayers = 0;
  int _requestCounter = 0;

  /// Messages already evaluated into the live KV cache, including the
  /// assistant turns the model produced itself.
  List<LlmMessage> _cachedMessages = const <LlmMessage>[];

  Completer<void>? _inFlight;

  @override
  bool get isLoaded => _loaded;

  /// Chat dialect detected for the loaded model.
  LlamaChatFormat get chatFormat => _format;

  /// Whether llama.cpp was asked to offload layers to the GPU for the model
  /// that is currently loaded (false after an internal CPU fallback).
  bool get usesGpuOffload => _effectiveGpuLayers > 0;

  /// Whether multi-turn requests can continue the live KV cache instead of
  /// re-evaluating the whole prompt. False for models whose tokenizer
  /// prepends special tokens — see [LlamaLoadedEvent.supportsCachedContinuation].
  bool get reusesContextAcrossTurns => _supportsCachedContinuation;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  Future<void> load(LlmLoadOptions options) async {
    if (_loaded) await unload();
    _options = options;

    final modelFile = GgufLocator.resolve(_paths, ModelType.llm, options.modelId);
    _format = ChatTemplate.detect('${options.modelId} ${modelFile.path}');
    _contextTokens = options.maxContextTokens ?? defaultContextTokens;
    _baseSampler = SamplerSpec(
      temperature: options.temperature,
      topK: options.topK ?? 40,
      topP: options.topP ?? 0.9,
      repeatPenalty: defaultRepeatPenalty,
    );

    final plan = BackendSelection.resolve(
      options.runtime,
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
      contextTokens: _contextTokens,
      sampler: _baseSampler,
    ));

    final event = await loaded;
    if (event is LlamaErrorEvent) {
      await worker.dispose();
      _worker = null;
      // The kit's RuntimeScheduler turns a throw here into a CPU retry plus
      // a RuntimeBackendFallback event (spec §2, fallback layer 2).
      throw NativeRuntimeError(
        'llama.cpp could not load "${options.modelId}": ${event.message}',
        cause: event.details,
      );
    }
    final ready = event as LlamaLoadedEvent;
    _effectiveGpuLayers = ready.gpuLayers;
    _supportsCachedContinuation = ready.supportsCachedContinuation;
    _activeSampler = _baseSampler;
    _cachedMessages = const <LlmMessage>[];
    _loaded = true;
  }

  @override
  Future<void> unload() async {
    // Awaited: the worker frees the model on shutdown, and llama.cpp's
    // allocations outlive the isolate.
    await _worker?.dispose();
    _worker = null;
    _loaded = false;
    _activeSampler = null;
    _cachedMessages = const <LlmMessage>[];
    _effectiveGpuLayers = 0;
  }

  // ---------------------------------------------------------------------------
  // Generation
  // ---------------------------------------------------------------------------

  @override
  Stream<LlmChunk> generateStream(LlmRequest request) {
    if (!_loaded || _worker == null) {
      return Stream.error(const InvalidStateError(
          'LlamaCppLlmAdapter: generateStream called before load().'));
    }
    return _generate(request);
  }

  @override
  Future<LlmResponse> generate(LlmRequest request) =>
      LlmResponse.fold(generateStream(request));

  Stream<LlmChunk> _generate(LlmRequest request) async* {
    await _acquire();
    try {
      final worker = _worker;
      if (worker == null) {
        throw const InvalidStateError(
            'LlamaCppLlmAdapter: model was unloaded mid-request.');
      }

      final windowed = ContextWindow.apply(
        request.messages,
        maxContextTokens: _contextTokens,
        maxOutputTokens: request.maxTokens,
      );
      final sampler = _samplerFor(request);
      // A sampler change rebuilds the context inside the worker, truncation
      // rewrites the prefix, and some tokenizers can't be continued at all —
      // each of those makes the cached prefix unusable.
      final mustReset = sampler != _activeSampler ||
          windowed.truncated ||
          !_supportsCachedContinuation;
      final plan = mustReset
          ? PromptPlan.reset(windowed.messages)
          : PromptPlanner.plan(
              cached: _cachedMessages,
              next: windowed.messages,
            );
      final prompt = plan.reusesCache
          ? ChatTemplate.renderContinuation(plan.messages, format: _format)
          : ChatTemplate.render(plan.messages, format: _format);

      final requestId = ++_requestCounter;
      final controller = StreamController<LlmChunk>();
      final answer = StringBuffer();
      late StreamSubscription<LlamaWorkerEvent> subscription;

      subscription = worker.events.listen((event) {
        if (event is LlamaChunkEvent && event.requestId == requestId) {
          answer.write(event.text);
          controller.add(LlmChunk(
            textDelta: event.text,
            contextTruncated: windowed.truncated,
          ));
          return;
        }
        if (event is LlamaDoneEvent && event.requestId == requestId) {
          _cachedMessages = <LlmMessage>[
            ...windowed.messages,
            LlmMessage.assistant(answer.toString()),
          ];
          _activeSampler = sampler;
          controller.add(LlmChunk(
            isFinal: true,
            finishReason: _finishReason(event.reason),
            contextTruncated: windowed.truncated,
            promptTokens: event.promptTokens,
            completionTokens: event.completionTokens,
          ));
          controller.close();
          return;
        }
        if (event is LlamaErrorEvent &&
            (event.requestId == null || event.requestId == requestId)) {
          // The cache state after a native failure is unknown.
          _cachedMessages = const <LlmMessage>[];
          controller.addError(NativeRuntimeError(
            'llama.cpp generation failed: ${event.message}',
            cause: event.details,
          ));
          controller.close();
        }
      });

      controller.onCancel = () async {
        worker.send(LlamaCancelCommand(requestId));
        // A cancelled turn leaves an unknown number of tokens in the cache.
        _cachedMessages = const <LlmMessage>[];
        await subscription.cancel();
      };

      worker.send(LlamaGenerateCommand(
        requestId: requestId,
        prompt: prompt,
        resetContext: !plan.reusesCache,
        sampler: sampler,
        maxTokens: request.maxTokens,
        stopSequences: <String>[
          ...ChatTemplate.stopSequences(_format),
          ...request.stopSequences,
        ],
      ));

      try {
        yield* controller.stream;
      } finally {
        await subscription.cancel();
      }
    } finally {
      _release();
    }
  }

  // ---------------------------------------------------------------------------
  // Structured output (GBNF-constrained, spec §3)
  // ---------------------------------------------------------------------------

  @override
  Future<T> generateStructured<T>(
    String prompt, {
    required JsonSchema schema,
    required T Function(Map<String, dynamic> json) fromJson,
    int maxRetries = 2,
  }) async {
    var raw = '';
    String? lastError;

    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      final request = LlmRequest.prompt(
        attempt == 0 ? prompt : _retryPrompt(prompt, raw, lastError!),
        responseSchema: schema,
      );
      final response = await generate(request);
      raw = response.text;

      // The grammar makes malformed JSON unreachable, so this is a
      // defensive fallback rather than the primary mechanism: it still
      // catches a model that stops mid-object on a token budget.
      final json = StructuredOutputSupport.extractJson(raw);
      if (json is! Map<String, dynamic>) {
        lastError = 'Output did not contain a JSON object.';
        continue;
      }
      final validationError = schema.validate(json);
      if (validationError != null) {
        lastError = 'Schema validation failed: $validationError';
        continue;
      }
      try {
        return fromJson(json);
      } on Object catch (e) {
        lastError = 'fromJson threw: $e';
      }
    }

    throw StructuredOutputError(
      rawOutput: raw,
      attempts: maxRetries + 1,
      reason: 'Grammar-constrained output still failed after '
          '${maxRetries + 1} attempt(s). Last error: $lastError',
    );
  }

  String _retryPrompt(String prompt, String previous, String error) =>
      'Your previous answer was rejected.\n'
      'Error: $error\n'
      'Previous answer:\n$previous\n\n'
      'Answer the original request again, completely.\n\n'
      'Original request: $prompt';

  // ---------------------------------------------------------------------------

  /// Sampling for one request: load-time defaults, overridden per request,
  /// plus the GBNF grammar when the request carries a response schema.
  SamplerSpec _samplerFor(LlmRequest request) {
    final grammar = request.responseSchema == null
        ? ''
        : JsonSchemaToGbnf.convert(request.responseSchema!);
    return _baseSampler.copyWith(
      temperature: request.temperature ?? _options?.temperature,
      topP: request.topP,
      grammar: grammar,
    );
  }

  static LlmFinishReason _finishReason(LlamaStopReason reason) =>
      switch (reason) {
        LlamaStopReason.endOfSequence ||
        LlamaStopReason.stopSequence =>
          LlmFinishReason.stop,
        LlamaStopReason.maxTokens ||
        LlamaStopReason.contextFull =>
          LlmFinishReason.length,
        LlamaStopReason.cancelled => LlmFinishReason.cancelled,
      };

  /// Serializes generations: one `llama_context` means one decode loop.
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
