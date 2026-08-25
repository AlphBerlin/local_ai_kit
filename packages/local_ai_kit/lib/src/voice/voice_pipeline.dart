/// Full-duplex voice session: Mic → VAD → STT → LLM → TTS → Speaker with
/// barge-in (architecture §5.3).
library;

import 'dart:async';
import 'dart:math';

import 'package:local_ai_core/local_ai_core.dart';

import '../runtime/runtime_scheduler.dart';

/// Extracts complete sentences from [buffer] — text ending in `.`/`!`/`?`
/// immediately followed by whitespace. Returns the sentences found, in
/// order, and the unconsumed remainder so the caller can keep accumulating
/// it against the next chunk of streamed text.
///
/// Not `_`-prefixed so `sentence_extraction_test.dart` can exercise it
/// directly; it is an internal pipelining detail, not intended as stable
/// public API beyond this package.
({List<String> sentences, String remainder}) extractSentences(String buffer) {
  final boundary = RegExp(r'[.!?]+(?=\s)');
  final sentences = <String>[];
  var consumedUpTo = 0;
  for (final match in boundary.allMatches(buffer)) {
    final sentence = buffer.substring(consumedUpTo, match.end).trim();
    if (sentence.isNotEmpty) sentences.add(sentence);
    consumedUpTo = match.end;
  }
  return (
    sentences: sentences,
    remainder: buffer.substring(consumedUpTo).trimRight(),
  );
}

/// Creates [VoiceSession]s bound to the configured audio + model stack.
class VoiceSessionFactory {
  VoiceSessionFactory({
    required LocalAIConfig config,
    required RuntimeScheduler runtime,
    required LocalAudioSource? audioSource,
    required LocalAudioOutput? audioOutput,
  })  : _config = config,
        _runtime = runtime,
        _audioSource = audioSource,
        _audioOutput = audioOutput;

  final LocalAIConfig _config;
  final RuntimeScheduler _runtime;
  final LocalAudioSource? _audioSource;
  final LocalAudioOutput? _audioOutput;

  /// Whether a voice session can be started (all components configured).
  bool get isAvailable =>
      _config.vad != null &&
      _config.stt != null &&
      _config.llm != null &&
      _config.tts != null &&
      _audioSource != null &&
      _audioOutput != null;

  /// Starts a voice session. Throws [InvalidStateError] when the config or
  /// audio stack is incomplete.
  Future<VoiceSession> start({
    VoiceSessionConfig sessionConfig = const VoiceSessionConfig(),
  }) async {
    if (!isAvailable) {
      throw const InvalidStateError(
        'Voice session requires vad+stt+llm+tts config and microphone/'
        'speaker access (LocalAI.initialize with audio enabled).',
      );
    }
    final session = VoiceSession._(
      config: _config,
      sessionConfig: sessionConfig,
      runtime: _runtime,
      audioSource: _audioSource!,
      audioOutput: _audioOutput!,
    );
    await session._start();
    return session;
  }
}

/// A running voice session. Dispose with [stop].
class VoiceSession {
  VoiceSession._({
    required LocalAIConfig config,
    required this.sessionConfig,
    required RuntimeScheduler runtime,
    required LocalAudioSource audioSource,
    required LocalAudioOutput audioOutput,
  })  : _config = config,
        _runtime = runtime,
        _audioSource = audioSource,
        _audioOutput = audioOutput;

  final LocalAIConfig _config;
  final VoiceSessionConfig sessionConfig;
  final RuntimeScheduler _runtime;
  final LocalAudioSource _audioSource;
  final LocalAudioOutput _audioOutput;

  final _events = StreamController<VoiceEvent>.broadcast();

  /// Broadcast event stream for the UI (architecture §5.3 event bus).
  Stream<VoiceEvent> get events => _events.stream;

  final List<String> _lockedModelIds = [];
  CancelToken? _turnToken;
  Timer? _maxTurnTimer;
  bool _speaking = false;
  bool _stopped = false;

  // Continuous ring buffer so speech onset and offset are never clipped
  final List<AudioFrame> _rollingRing = [];
  final List<AudioFrame> _utterance = [];
  bool _inSpeech = false;
  DateTime? _speechStartedAt;
  DateTime _ignoreAudioUntil = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _start() async {
    final vadConfig = _config.vad!;
    final sttConfig = _config.stt!;
    final llmConfig = _config.llm!;
    final ttsConfig = _config.tts!;

    // Load all components and lock them against LRU eviction for the
    // session lifetime (architecture §5.2).
    final ids = <String>[
      vadConfig.modelId,
      sttConfig.modelId,
      llmConfig.modelId,
      ttsConfig.modelId,
    ];
    for (final id in ids) {
      await _runtime.loadModel(id);
      _runtime.setLocked(id, locked: true);
    }
    _lockedModelIds.addAll(ids);

    final micStream =
        _audioSource.start(format: AudioFormat.pcm16kMono).asBroadcastStream();
    final vad = _runtime.adapter<LocalVad>(vadConfig.modelId);

    _events.add(const VoiceListening());

    // VAD drives both utterance segmentation and barge-in detection.
    vad.analyze(micStream).listen(
          _onVadEvent,
          onError: (Object e) => _emitError(e),
        );

    // Frame buffering for STT runs on the same broadcast mic stream.
    micStream.listen(_onAudioFrame);
  }

  // ---------------------------------------------------------------------------
  // Stage wiring
  // ---------------------------------------------------------------------------

  void _onAudioFrame(AudioFrame frame) {
    if (_speaking || DateTime.now().isBefore(_ignoreAudioUntil)) {
      return; // Suppress microphone audio during assistant playback and room echo cooldown
    }
    _rollingRing.add(frame);
    if (_rollingRing.length > 80) {
      _rollingRing.removeAt(0); // ~2.5s continuous history
    }
    if (_inSpeech) _utterance.add(frame);
  }

  void _onVadEvent(VadEvent event) {
    if (_stopped || DateTime.now().isBefore(_ignoreAudioUntil)) {
      return;
    }
    if (_speaking) {
      if (event is VadSpeechStarted) {
        unawaited(_maybeBargeIn(event.timestamp, event.confidence));
      }
      return;
    }
    switch (event) {
      case VadSpeechStarted():
        _inSpeech = true;

        _speechStartedAt = event.timestamp;
        _utterance.clear();
        // Grab pre-roll: up to 6 frames (~400-600ms) leading up to speech start
        final preRollCount = min(6, _rollingRing.length);
        final preRoll =
            _rollingRing.sublist(_rollingRing.length - preRollCount);
        _utterance.addAll(preRoll);
        _events.add(const VoiceSpeechStarted());
      case VadSpeechEnded():
        if (!_inSpeech) return;
        _inSpeech = false;
        _speechStartedAt = null;
        _events.add(const VoiceSpeechEnded());
        // Add trailing post-roll: up to 4 frames (~300ms)
        final postRollCount = min(4, _rollingRing.length);
        final postRoll =
            _rollingRing.sublist(_rollingRing.length - postRollCount);
        for (final f in postRoll) {
          if (!_utterance.contains(f)) _utterance.add(f);
        }
        final frames = List<AudioFrame>.of(_utterance);
        _utterance.clear();
        if (frames.isNotEmpty) {
          unawaited(_runTurn(frames));
        }
      case VadSpeechConfidence():
        break;
    }
  }

  /// One full assistant turn for a captured utterance.
  Future<void> _runTurn(List<AudioFrame> frames) async {
    final turnToken = _turnToken = CancelToken();
    _maxTurnTimer = Timer(sessionConfig.maxTurnDuration, () {
      turnToken.cancel();
      _events.add(const VoiceInterrupted(reason: InterruptReason.timeout));
    });
    try {
      // STT ---------------------------------------------------------------
      final stt = _runtime.adapter<LocalStt>(_config.stt!.modelId);
      _runtime.touch(_config.stt!.modelId);
      final transcript = await stt.transcribe(AudioBuffer.fromFrames(frames));
      turnToken.throwIfCancelled();
      if (transcript.isEmpty) {
        _events.add(const VoiceListening());
        return;
      }
      final cleanedText = collapseRepeatedWords(transcript.text);
      _events.add(VoiceTranscriptUpdated(text: cleanedText, isFinal: true));

      // LLM ---------------------------------------------------------------
      _events.add(const VoiceThinking());
      final llm = _runtime.adapter<LocalLlm>(_config.llm!.modelId);
      _runtime.touch(_config.llm!.modelId);
      final chunks = llm.generateStream(LlmRequest.prompt(
        cleanedText,
        systemPrompt: sessionConfig.systemPrompt,
      ));

      // LLM -> TTS pipelining: each completed sentence is queued for
      // synthesis/playback as soon as it's detected, while the LLM keeps
      // generating the rest in the background (architecture §5.3 extension).
      var sentenceBuffer = '';
      var playbackChain = Future<void>.value();
      var hasSentence = false;
      var first = true;
      await for (final chunk in chunks) {
        turnToken.throwIfCancelled();
        if (first) {
          first = false;
          _events.add(const VoiceResponseStarted());
        }
        if (chunk.textDelta.isNotEmpty) {
          _events.add(VoiceResponseDelta(chunk.textDelta));
          sentenceBuffer += chunk.textDelta;
          final extracted = extractSentences(sentenceBuffer);
          sentenceBuffer = extracted.remainder;
          for (final sentence in extracted.sentences) {
            hasSentence = true;
            playbackChain =
                playbackChain.then((_) => _speakSentence(sentence, turnToken));
          }
        }
      }
      turnToken.throwIfCancelled();
      final remainder = sentenceBuffer.trim();
      if (remainder.isNotEmpty) {
        hasSentence = true;
        playbackChain =
            playbackChain.then((_) => _speakSentence(remainder, turnToken));
      }
      if (!hasSentence) {
        _events.add(const VoiceListening());
        return;
      }

      // TTS playback (queued above as sentences were detected) ------------
      await playbackChain;
      turnToken.throwIfCancelled();
      _events.add(const VoiceFinished());
    } on CancelledError {
      // Interruption already emitted by the canceller.
    } on Object catch (e) {
      _emitError(e);
    } finally {
      _maxTurnTimer?.cancel();
      _speaking = false;
      _rollingRing.clear();
      _utterance.clear();
      _inSpeech = false;
      _ignoreAudioUntil = DateTime.now().add(const Duration(milliseconds: 500));
      _turnToken = null;
      if (!_stopped) _events.add(const VoiceListening());
    }
  }

  /// Synthesizes and plays one sentence, racing playback against [turnToken]
  /// exactly as the single-call path used to. On the first sentence of a
  /// turn, flips the session into "speaking" state (mic suppression, ring
  /// buffer reset) — later sentences in the same chain skip that since it's
  /// already true.
  Future<void> _speakSentence(String sentence, CancelToken turnToken) async {
    turnToken.throwIfCancelled();
    if (!_speaking) {
      _speaking = true;
      _rollingRing.clear();
      _utterance.clear();
      _inSpeech = false;
    }
    _events.add(VoiceSpeaking(text: sentence));
    final tts = _runtime.adapter<LocalTts>(_config.tts!.modelId);
    _runtime.touch(_config.tts!.modelId);
    final audio = tts.synthesizeStream(SpeakRequest(
      text: sentence,
      voiceId: _config.tts!.voiceId,
      speed: _config.tts!.speed,
    ));
    // Cancellation races playback: barge-in stops the output and cancels
    // this token, so the play() future is abandoned via the race.
    await Future.any<void>([
      _audioOutput.play(audio),
      _cancelled(turnToken),
    ]);
    // Let a concurrent barge-in finish cancelling after it has stopped the
    // output, before the next queued sentence can begin.
    await Future<void>.delayed(Duration.zero);
    turnToken.throwIfCancelled();
  }

  // ---------------------------------------------------------------------------
  // Barge-in (architecture §5.3)
  // ---------------------------------------------------------------------------

  Future<void> _maybeBargeIn(DateTime at, double confidence) async {
    if (!sessionConfig.bargeIn || !_speaking) return;
    // Echo mitigation without AEC: require higher confidence + persistence.
    final threshold = sessionConfig.interruptConfidenceThreshold +
        sessionConfig.speakingVadThresholdBoost;
    if (confidence < threshold.clamp(0.0, 1.0)) return;

    _speechStartedAt ??= at;
    final persisted = DateTime.now().difference(_speechStartedAt!);
    if (persisted.inMilliseconds < sessionConfig.interruptMinSpeechMs) {
      return; // wait for speech to persist (filters clicks/echo blips)
    }

    // 1. Truncate playback. 2. Cancel LLM/TTS via the turn token.
    // 3. Emit interrupted; the loop returns to Listening.
    await _audioOutput.stop();
    _turnToken?.cancel();
    _speaking = false;
    _inSpeech = true; // the interrupting speech becomes the next utterance
    final preRoll = _rollingRing.length > 30
        ? _rollingRing.sublist(_rollingRing.length - 30)
        : List<AudioFrame>.of(_rollingRing);
    _utterance
      ..clear()
      ..addAll(preRoll);
    _events.add(const VoiceInterrupted(reason: InterruptReason.bargeIn));
    _events.add(const VoiceSpeechStarted());
  }

  Future<void> _cancelled(CancelToken token) {
    final completer = Completer<void>();
    token.addListener(completer.complete);
    return completer.future;
  }

  void _emitError(Object error) {
    final wrapped = error is LocalAIError
        ? error
        : NativeRuntimeError('voice session stage failed', cause: error);
    _events.add(VoiceErrorOccurred(wrapped));
  }

  /// Ends the session: stops the mic, cancels any in-flight turn and
  /// unlocks the session's models in the runtime.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _maxTurnTimer?.cancel();
    _turnToken?.cancel();
    await _audioOutput.stop();
    await _audioSource.stop();
    for (final id in _lockedModelIds) {
      _runtime.setLocked(id, locked: false);
    }
    _lockedModelIds.clear();
    await _events.close();
  }
}
