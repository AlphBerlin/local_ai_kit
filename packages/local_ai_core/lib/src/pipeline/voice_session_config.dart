/// Voice session tuning knobs (architecture §5.3).
library;

/// Half duplex = mic muted while speaking; full duplex = barge-in possible.
enum DuplexMode { half, full }

/// Configuration for `VoiceSession`.
class VoiceSessionConfig {
  const VoiceSessionConfig({
    this.bargeIn = true,
    this.duplex = DuplexMode.full,
    this.systemPrompt,
    this.interruptConfidenceThreshold = 0.7,
    this.interruptMinSpeechMs = 120,
    this.speakingVadThresholdBoost = 0.25,
    this.maxTurnDuration = const Duration(seconds: 60),
  });

  /// Allow the user to interrupt TTS playback by speaking.
  final bool bargeIn;

  /// Full duplex keeps the mic+VAD active during playback.
  final DuplexMode duplex;

  /// Optional system prompt prepended to every turn.
  final String? systemPrompt;

  /// VAD confidence needed to trigger a barge-in while speaking.
  final double interruptConfidenceThreshold;

  /// Speech must persist at least this long to count as barge-in
  /// (filters clicks / echo blips). Architecture default: 120ms.
  final int interruptMinSpeechMs;

  /// Amount added to the VAD threshold while TTS is playing, mitigating
  /// echo false-triggers when no AEC is available. Headphones recommended.
  final double speakingVadThresholdBoost;

  /// Hard cap on one turn (mic-on to playback-end).
  final Duration maxTurnDuration;
}
