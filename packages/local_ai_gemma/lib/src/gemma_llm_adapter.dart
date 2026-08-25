/// Gemma LLM adapter: flutter_gemma → core `LocalLlm`.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_gemma/flutter_gemma.dart' as fg;
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';
import 'package:flutter_gemma_mediapipe/flutter_gemma_mediapipe.dart';
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

  /// Maps an installed weight filename to the format expected by
  /// `flutter_gemma.createModel`.
  static fg.ModelFileType modelFileTypeForPath(String path) {
    final lowerPath = path.toLowerCase();
    return switch (lowerPath) {
      final p when p.endsWith('.litertlm') => fg.ModelFileType.litertlm,
      final p when p.endsWith('.task') => fg.ModelFileType.task,
      _ => fg.ModelFileType.binary,
    };
  }

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
        await fg.FlutterGemma.initialize(
          inferenceEngines: [
            MediaPipeEngine(),
            LiteRtLmEngine(),
          ],
        );
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
    final directory = Directory(dir);
    if (!directory.existsSync()) {
      throw InvalidStateError(
          'Model files not found for "$modelId" at "$dir". Model is not installed on disk.');
    }
    // The model manager installs files under their manifest names; the LLM
    // manifests in this kit ship exactly one weight file per model.
    final candidates = directory
        .listSync()
        .whereType<File>()
        .where((f) =>
            f.path.endsWith('.task') ||
            f.path.endsWith('.tflite') ||
            f.path.endsWith('.bin') ||
            f.path.endsWith('.litertlm'))
        .toList();
    if (candidates.isEmpty) {
      throw InvalidStateError(
          'No valid model weight files (.litertlm, .task, .bin) found in "$dir" for model "$modelId".');
    }
    return candidates.first;
  }

  Future<dynamic> _nativeCreateModel(
      String path, LlmLoadOptions options) async {
    final gemma = fg.FlutterGemmaPlugin.instance;
    final idLower = options.modelId.toLowerCase();
    final modelType = switch (idLower) {
      final id when id.contains('deepseek') => fg.ModelType.deepSeek,
      final id when id.contains('qwen') => fg.ModelType.qwen,
      final id when id.contains('smollm') => fg.ModelType.llama,
      final id when id.contains('llama') => fg.ModelType.llama,
      _ => fg.ModelType.gemmaIt,
    };
    final fileType = modelFileTypeForPath(path);
    try {
      await fg.FlutterGemma.installModel(
        modelType: modelType,
        fileType: fileType,
      ).fromFile(path).install();
    } catch (e) {
      if (fileType == fg.ModelFileType.task &&
          (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
        throw NativeRuntimeError(
          'Model "${options.modelId}" (.task format) is built for Android, iOS, and Web. '
          'On ${Platform.operatingSystem}, please select a .litertlm model (e.g. Qwen 3.5 0.8B/2B/4B or SmolLM2 360M) for native LiteRT-LM hardware acceleration.',
          cause: e,
        );
      }
      rethrow;
    }
    final backend = switch (options.runtime) {
      RuntimePreference.gpu => fg.PreferredBackend.gpu,
      RuntimePreference.cpu => fg.PreferredBackend.cpu,
      _ => fg.PreferredBackend.gpu,
    };
    try {
      try {
        return await gemma.createModel(
          modelType: modelType,
          fileType: fileType,
          preferredBackend: backend,
          maxTokens: options.maxContextTokens ?? 4096,
        );
      } catch (_) {
        if (backend == fg.PreferredBackend.gpu) {
          return await gemma.createModel(
            modelType: modelType,
            fileType: fileType,
            preferredBackend: fg.PreferredBackend.cpu,
            maxTokens: options.maxContextTokens ?? 4096,
          );
        }
        rethrow;
      }
    } catch (e) {
      if (fileType == fg.ModelFileType.task &&
          (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
        throw NativeRuntimeError(
          'Model "${options.modelId}" (.task format) is built for Android, iOS, and Web. '
          'On ${Platform.operatingSystem}, please select a .litertlm model (e.g. Qwen 3.5 0.8B/2B/4B or SmolLM2 360M) for native LiteRT-LM hardware acceleration.',
          cause: e,
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
        topK: options.topK ?? 40,
        topP: options.topP ?? 0.9,
      );
    }
    return (model as dynamic).createChat(
      temperature: options.temperature,
      topK: options.topK ?? 40,
      topP: options.topP ?? 0.9,
    );
  }

  Stream<String> _nativeGenerate(LlmRequest request) async* {
    final model = _model;
    if (model == null) return;

    // Separate system instruction from conversation turns
    final systemMsgs =
        request.messages.where((m) => m.role == LlmRole.system).toList();
    final systemPrompt = systemMsgs.isNotEmpty
        ? systemMsgs.map((m) => m.content).join('\n').trim()
        : null;

    final turns =
        request.messages.where((m) => m.role != LlmRole.system).toList();

    // Use nucleus top-p / top-k sampling to avoid greedy repetition traps
    final temp = (_options?.temperature ?? 0.7).clamp(0.1, 1.2);
    final topK = _options?.topK ?? 40;
    final topP = _options?.topP ?? 0.9;

    // Create a fresh chat session for this generation request
    dynamic chat;
    if (model is fg.InferenceModel) {
      chat = await model.createChat(
        temperature: temp,
        topK: topK,
        topP: topP,
        systemInstruction: systemPrompt != null && systemPrompt.isNotEmpty
            ? systemPrompt
            : null,
      );
    } else {
      chat = await (model as dynamic).createChat(
        temperature: temp,
        topK: topK,
        topP: topP,
        systemInstruction: systemPrompt != null && systemPrompt.isNotEmpty
            ? systemPrompt
            : null,
      );
    }

    // Add preceding turns in order
    for (var i = 0; i < turns.length - 1; i++) {
      final t = turns[i];
      await chat.addQueryChunk(fg.Message.text(
        text: t.content,
        isUser: t.role == LlmRole.user,
      ));
    }

    // Add the final user query
    final latest =
        turns.isNotEmpty ? turns.last : const LlmMessage.user('Hello');
    await chat.addQueryChunk(fg.Message.text(
      text: latest.content,
      isUser: true,
    ));

    final stream = chat.generateChatResponseAsync();
    final generatedBuffer = StringBuffer();

    await for (final response in stream) {
      if (response == null) continue;
      String? text;
      if (response is fg.TextResponse) {
        text = response.token;
      } else if (response is String) {
        text = response;
      } else {
        try {
          text = (response as dynamic).token?.toString() ?? response.toString();
        } catch (_) {
          text = response.toString();
        }
      }
      if (text.isNotEmpty) {
        generatedBuffer.write(text);
        final full = generatedBuffer.toString();

        // 1. Line-level repetition loop guard (e.g. repeated same line >= 3 times)
        final lines = full
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList();
        if (lines.length >= 3) {
          final last = lines.last;
          if (last.length > 3) {
            final count = lines.where((l) => l == last).length;
            if (count >= 3) {
              break;
            }
          }
        }

        // 2. Multi-word n-gram repetition loop guard (e.g. "with you with you with you" or "1. 1. 1. 1.")
        final words =
            full.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
        if (words.length >= 9) {
          final w1 = words.sublist(words.length - 3).join(' ');
          final w2 =
              words.sublist(words.length - 6, words.length - 3).join(' ');
          final w3 =
              words.sublist(words.length - 9, words.length - 6).join(' ');
          if (w1 == w2 && w2 == w3) {
            break;
          }
        }

        // 3. Single word / token runaway burst guard
        if (words.length >= 6) {
          final lastW = words.last;
          if (words.sublist(words.length - 6).every((w) => w == lastW)) {
            break;
          }
        }

        yield text;
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
