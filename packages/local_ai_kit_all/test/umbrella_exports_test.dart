import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_kit_all/local_ai_kit_all.dart';

void main() {
  test('umbrella exposes the facade and all adapter plugins', () {
    final plugins = <AdapterPlugin>[
      const GemmaAdapterPlugin(),
      const SherpaAdapterPlugin(),
      const GenkitAdapterPlugin(),
    ];

    expect(plugins, hasLength(3));
    expect(LocalAIConfig.offlineChat(), isA<LocalAIConfig>());
  });
}
