/// Gemma LLM adapter: flutter_gemma → core `LocalLlm`.
library;

import 'dart:async';
import 'dart:io';

// Prefixed to avoid clashes with core types (e.g. core `ModelType`).
import 'package:flutter_gemma/flutter_gemma.dart' as fg;
import 'package:local_ai_core/local_ai_core.dart';

/// [LocalLlm] implementation backed by Google's flutter_gemma runtime.
///
/// Responsibilities (architecture §3.3):
///  * model file path mapping via [LocalStoragePaths]
///  * `RuntimePreference` → backend selection (CPU/GPU)
///  * session reuse and context window management (sliding window
///    truncation, flagged via [LlmChunk.contextTruncated])
///
/// All flutter_gemma API calls are isolated in the private `_native*`
/// methods so upstream API drift only touches a few small functions.
class GemmaLlmAdapter with StructuredOutputSupport implements LocalLlm {
  GemmaLlmAdapter({required LocalStoragePaths paths}) : _paths = paths;

  /// Registered provider key (matches `ModelProviders.googleGemma`).
  static const String provider = ModelProviders.googleGemma;

  final LocalStoragePaths _paths;

  // TODO(verify): flutter_gemma API — the concrete session/model types
  // below follow flutter_gemma 0.10 naming; adjust to the pinned version.
  dynamic _model; // flutter_gemma InferenceModel
  dynamic _session; // flutter_gemma InferenceChat / InferenceModelSession

  LlmLoadOptions? _options;
  bool _loaded = false;

  @override
  bool get isLoaded => _loaded;

  @override
  Future<void> load(LlmLoadOptions options) async {
    if (_loaded) await unload();
    _options = options;
    final modelFile = _resolveModelFile(options.modelId);
    _model = await _nativeCreateModel(modelFile.path, options);
    _session = await _nativeCreateSession(_model, options);
    _loaded = true;
  }

  @override
  Future<void> unload() async {
    await _nativeCloseSession(_session);
    await _nativeCloseModel(_model);
    _session = null;
    _model = null;
    _loaded = false;
  }

  @override
  Stream<LlmChunk> generateStream(LlmRequest request) {
    if (!_loaded || _session == null) {
      return Stream.error(const InvalidStateError(
          'GemmaLlmAdapter: generateStream called before load().'));
    }
    final effective = _applyContextWindow(request);
    final truncated = effective.messages.length != request.messages.length;
    return _nativeGenerate(effective)
        .map((delta) => LlmChunk(textDelta: delta, contextTruncated: truncated))
        .concatWith([
      LlmChunk(
        isFinal: true,
        finishReason: LlmFinishReason.stop,
        contextTruncated: truncated,
      ),
    ]);
  }

  @override
  Future<LlmResponse> generate(LlmRequest request) =>
      LlmResponse.fold(generateStream(request));

  // ---------------------------------------------------------------------------
  // Context window management (architecture §7.3)
  // ---------------------------------------------------------------------------

  /// Keeps the system message plus as many recent turns as fit in
  /// `maxContextTokens` (rough 4 chars/token estimate). Dropping turns sets
  /// the `contextTruncated` flag on the emitted chunks.
  LlmRequest _applyContextWindow(LlmRequest request) {
    final maxTokens = _options?.maxContextTokens;
    if (maxTokens == null) return request;

    const charsPerToken = 4;
    final budgetChars = maxTokens * charsPerToken;

    final system = request.messages
        .where((m) => m.role == LlmRole.system)
        .toList(growable: false);
    final turns = request.messages
        .where((m) => m.role != LlmRole.system)
        .toList(growable: false);

    var used = system.fold<int>(0, (sum, m) => sum + m.content.length);
    final kept = <LlmMessage>[];
    for (final message in turns.reversed) {
      if (used + message.content.length > budgetChars && kept.isNotEmpty) {
        break;
      }
      used += message.content.length;
      kept.insert(0, message);
    }
    if (kept.length == turns.length) return request;
    return request.copyWith(messages: [...system, ...kept]);
  }

  // ---------------------------------------------------------------------------
  // flutter_gemma boundary — the ONLY place flutter_gemma types appear.
  // ---------------------------------------------------------------------------

  File _resolveModelFile(String modelId) {
    final dir = _paths.modelDir(ModelType.llm, modelId);
    // The model manager installs files under their manifest names; the LLM
    // manifests in this kit ship exactly one weight file per model.
    final candidates = Directory(dir)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.task') || f.path.endsWith('.tflite'))
        .toList();
    if (candidates.isEmpty) {
      throw ModelNotFoundError(modelId);
    }
    return candidates.first;
  }

  // TODO(verify): flutter_gemma API — model creation entry point.
  Future<dynamic> _nativeCreateModel(String path, LlmLoadOptions options) async {
    final gemma = fg.FlutterGemmaPlugin.instance;
    final backend = switch (options.runtime) {
      RuntimePreference.gpu => 'gpu',
      RuntimePreference.cpu => 'cpu',
      _ => 'gpu', // auto / npu → gpu, scheduler handles fallback to cpu
    };
    return gemma.createModel(
      modelType: fg.ModelType.gemmaIt,
      preferredBackend: backend,
      maxTokens: options.maxContextTokens ?? 4096,
      filePath: path,
    );
  }

  // TODO(verify): flutter_gemma API — session creation.
  Future<dynamic> _nativeCreateSession(
      dynamic model, LlmLoadOptions options) async {
    return model.createSession(
      temperature: options.temperature,
      maxTokens: options.maxContextTokens ?? 4096,
    );
  }

  // TODO(verify): flutter_gemma API — streaming chat completion.
  Stream<String> _nativeGenerate(LlmRequest request) async* {
    final chat = _session;
    for (final message in request.messages) {
      await chat.addQueryChunk(_toNativeMessage(message));
    }
    final stream = chat.generateChatResponseAsync();
    await for (final token in stream) {
      yield token is String ? token : token.toString();
    }
  }

  // TODO(verify): flutter_gemma API — message mapping.
  dynamic _toNativeMessage(LlmMessage message) {
    // flutter_gemma exposes Message.text / Message.withImage style helpers.
    return message.content;
  }

  // TODO(verify): flutter_gemma API — resource release.
  Future<void> _nativeCloseSession(dynamic session) async {
    await session?.close();
  }

  Future<void> _nativeCloseModel(dynamic model) async {
    await model?.close();
  }
}

/// Small stream extension used to append the terminal chunk.
extension<T> on Stream<T> {
  Stream<T> concatWith(List<T> tail) async* {
    await for (final item in this) {
      yield item;
    }
    for (final item in tail) {
      yield item;
    }
  }
}
