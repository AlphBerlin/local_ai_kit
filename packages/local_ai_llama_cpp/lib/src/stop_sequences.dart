/// Streaming stop-sequence detection (pure).
///
/// llama.cpp stops on the model's end-of-generation token, but chat
/// templates also end a turn with a literal marker (`<|im_end|>`,
/// `<end_of_turn>`, …) that some quantized models emit as ordinary text.
/// Scanning for those markers has to happen on the *streamed* text, and it
/// has to hold back any tail that might still turn into a marker — emitting
/// `<|im_` to the UI and retracting it later is not possible on a stream.
library;

/// Text that can be emitted now, plus whether generation should stop.
class StopScanResult {
  const StopScanResult({required this.text, required this.stopped});

  /// Safe to emit downstream (never contains part of a stop sequence).
  final String text;

  /// True once a complete stop sequence was seen.
  final bool stopped;
}

/// Incremental scanner for a fixed set of stop sequences.
class StopSequenceScanner {
  StopSequenceScanner(Iterable<String> stopSequences)
      : _stops = stopSequences
            .where((s) => s.isNotEmpty)
            .toList(growable: false);

  final List<String> _stops;
  final StringBuffer _pending = StringBuffer();
  bool _stopped = false;

  /// Whether a stop sequence has already been matched.
  bool get stopped => _stopped;

  /// Feeds one streamed [delta] and returns what may be emitted.
  StopScanResult add(String delta) {
    if (_stopped) return const StopScanResult(text: '', stopped: true);
    if (_stops.isEmpty) {
      return StopScanResult(text: delta, stopped: false);
    }

    _pending.write(delta);
    final buffered = _pending.toString();

    var cut = -1;
    for (final stop in _stops) {
      final index = buffered.indexOf(stop);
      if (index >= 0 && (cut < 0 || index < cut)) cut = index;
    }
    if (cut >= 0) {
      _stopped = true;
      _pending.clear();
      return StopScanResult(text: buffered.substring(0, cut), stopped: true);
    }

    // Hold back the longest tail that could still grow into a stop sequence.
    final hold = _partialMatchLength(buffered);
    final emit = buffered.substring(0, buffered.length - hold);
    _pending
      ..clear()
      ..write(buffered.substring(buffered.length - hold));
    return StopScanResult(text: emit, stopped: false);
  }

  /// Returns the held-back tail at end of generation. Once generation ended
  /// without a stop sequence, a partial match was just ordinary text.
  String flush() {
    if (_stopped) return '';
    final remaining = _pending.toString();
    _pending.clear();
    return remaining;
  }

  /// Length of the longest suffix of [text] that is a proper prefix of any
  /// stop sequence.
  int _partialMatchLength(String text) {
    var longest = 0;
    for (final stop in _stops) {
      final max = stop.length - 1 < text.length ? stop.length - 1 : text.length;
      for (var length = max; length > longest; length--) {
        if (text.endsWith(stop.substring(0, length))) {
          longest = length;
          break;
        }
      }
    }
    return longest;
  }
}
