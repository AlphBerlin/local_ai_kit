/// Gemma LLM adapter: flutter_gemma → core `LocalLlm`.
library;

import 'dart:async';
import 'dart:io';

// Prefixed to avoid clashes with core types (e.g. core `ModelType`).
import 'package:flutter_gemma/core/model.dart' as fg_model;
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

  static bool _gemmaInitialized = false;

  Future<void> _ensureInitialized() async {
    if (!_gemmaInitialized) {
      try {
        await fg.FlutterGemma.initialize();
        _gemmaInitialized = true;
      } catch (_) {
        // Already initialized or platform fallback
      }
    }
  }

  @override
  bool get isLoaded => _loaded;

  @override
  Future<void> load(LlmLoadOptions options) async {
    if (_loaded) await unload();
    _options = options;
    await _ensureInitialized();
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
        .where((f) =>
            f.path.endsWith('.task') ||
            f.path.endsWith('.tflite') ||
            f.path.endsWith('.bin') ||
            f.path.endsWith('.litertlm'))
        .toList();
    if (candidates.isEmpty) {
      throw ModelNotFoundError(modelId);
    }
    return candidates.first;
  }

  Future<dynamic> _nativeCreateModel(
      String path, LlmLoadOptions options) async {
    final gemma = fg.FlutterGemmaPlugin.instance;
    // ignore: deprecated_member_use
    await gemma.modelManager.setModelPath(path);
    final backend = switch (options.runtime) {
      RuntimePreference.gpu => fg.PreferredBackend.gpu,
      RuntimePreference.cpu => fg.PreferredBackend.cpu,
      _ => fg.PreferredBackend.gpu,
    };
    final idLower = options.modelId.toLowerCase();
    final modelType = switch (idLower) {
      final id when id.contains('deepseek') => fg_model.ModelType.deepSeek,
      final id when id.contains('qwen') => fg_model.ModelType.qwen,
      final id when id.contains('llama') => fg_model.ModelType.llama,
      _ => fg_model.ModelType.gemmaIt,
    };
    try {
      return await gemma.createModel(
        modelType: modelType,
        preferredBackend: backend,
        maxTokens: options.maxContextTokens ?? 4096,
      );
    } catch (_) {
      if (backend == fg.PreferredBackend.gpu) {
        return await gemma.createModel(
          modelType: modelType,
          preferredBackend: fg.PreferredBackend.cpu,
          maxTokens: options.maxContextTokens ?? 4096,
        );
      }
      rethrow;
    }
  }

  Future<dynamic> _nativeCreateSession(
      dynamic model, LlmLoadOptions options) async {
    if (model is fg.InferenceModel) {
      return model.createChat(
        temperature: options.temperature,
      );
    }
    return (model as dynamic).createChat(
      temperature: options.temperature,
    );
  }

  Stream<String> _nativeGenerate(LlmRequest request) async* {
    final chat = _session;
    if (chat == null) return;

    final promptBuffer = StringBuffer();
    for (final message in request.messages) {
      if (message.role == LlmRole.system) {
        promptBuffer.writeln('[System]: ${message.content}\n');
      } else {
        promptBuffer.writeln(message.content);
      }
    }

    final queryText = promptBuffer.toString().trim();
    await chat.addQueryChunk(fg.Message.text(
      text: queryText.isNotEmpty ? queryText : 'Hello',
      isUser: true,
    ));

    final stream = chat.generateChatResponseAsync();
    await for (final token in stream) {
      if (token != null && token.isNotEmpty) {
        yield token;
      }
    }
  }

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
