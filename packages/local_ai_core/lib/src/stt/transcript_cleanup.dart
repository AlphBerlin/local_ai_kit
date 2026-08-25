/// STT transcript post-processing: removes decoding repetition artifacts.
library;

/// Collapses immediately-repeated words or short phrases in [text], such as
/// STT decoding/silence-padding artifacts (e.g. "production production" ->
/// "production"). Case-insensitive; considers window sizes of 1-4 words;
/// iterates to a fixed point so triple-or-more repeats collapse fully.
///
/// Does not attempt to distinguish decoding artifacts from a speaker's
/// genuine repeated words — both collapse the same way.
String collapseRepeatedWords(String text) {
  if (text.trim().isEmpty) return text;
  var tokens = text.split(RegExp(r'\s+'));
  var changed = true;
  while (changed) {
    changed = false;
    final maxWindow = (tokens.length ~/ 2).clamp(0, 4);
    for (var w = maxWindow; w >= 1 && !changed; w--) {
      for (var i = 0; i + 2 * w <= tokens.length; i++) {
        final a = tokens.sublist(i, i + w).map(_normalize).join(' ');
        final b = tokens.sublist(i + w, i + 2 * w).map(_normalize).join(' ');
        if (a.isNotEmpty && a == b) {
          tokens = [
            ...tokens.sublist(0, i + w),
            ...tokens.sublist(i + 2 * w),
          ];
          changed = true;
          break;
        }
      }
    }
  }
  return tokens.join(' ');
}

String _normalize(String token) =>
    token.toLowerCase().replaceAll(RegExp(r'[^\w]+$'), '');
