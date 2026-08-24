/// Minimal mustache-style prompt templating (`{{var}}` interpolation).
library;

/// A reusable prompt template with `{{variable}}` placeholders.
class PromptTemplate {
  const PromptTemplate(this.template);

  final String template;

  static final RegExp _placeholder = RegExp(r'\{\{\s*(\w+)\s*\}\}');

  /// Renders the template with [variables].
  ///
  /// Unknown placeholders are left intact so missing data is visible
  /// instead of silently dropped.
  String render(Map<String, Object?> variables) {
    return template.replaceAllMapped(_placeholder, (match) {
      final key = match.group(1)!;
      final value = variables[key];
      return value?.toString() ?? match.group(0)!;
    });
  }

  /// Variables referenced by this template.
  List<String> get variables =>
      _placeholder.allMatches(template).map((m) => m.group(1)!).toSet().toList();
}
