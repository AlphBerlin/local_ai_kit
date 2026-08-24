/// In-memory fake LLM for unit tests (architecture §1: adapters must be
/// replaceable with fakes).
library;

import 'dart:async';
import '../../llm/llm_request.dart';
import '../../llm/local_llm.dart';
import '../../llm/structured_output.dart';

/// Deterministic fake: echoes a canned or scripted response.
class FakeLlm with StructuredOutputSupport implements LocalLlm {
  FakeLlm({this.responseText = 'fake response', this.chunkSize = 8});

  /// Text returned by generation, split into [chunkSize]-char chunks.
  String responseText;

  /// Characters per emitted [LlmChunk].
  final int chunkSize;

  /// Set to make [load] throw (e.g. to test backend fallback).
  Object? loadError;

  bool _loaded = false;
  int loadCount = 0;
  int unloadCount = 0;

  @override
  bool get isLoaded => _loaded;

  @override
  Future<void> load(LlmLoadOptions options) async {
    if (loadError != null) throw loadError!;
    loadCount++;
    _loaded = true;
  }

  @override
  Future<void> unload() async {
    unloadCount++;
    _loaded = false;
  }

  @override
  Stream<LlmChunk> generateStream(LlmRequest request) async* {
    if (!_loaded) {
      throw StateError('FakeLlm.generateStream called before load()');
    }
    for (var i = 0; i < responseText.length; i += chunkSize) {
      final end =
          (i + chunkSize > responseText.length) ? responseText.length : i + chunkSize;
      yield LlmChunk(textDelta: responseText.substring(i, end));
    }
    yield const LlmChunk(isFinal: true, finishReason: LlmFinishReason.stop);
  }

  @override
  Future<LlmResponse> generate(LlmRequest request) =>
      LlmResponse.fold(generateStream(request));
}