import 'package:test/test.dart';

import 'release_config.dart';

void main() {
  test('release packages stay in dependency order', () {
    expect(
      releasePackages.map((package) => package.name).toList(),
      <String>[
        'local_ai_core',
        'local_ai_flutter',
        'local_ai_gemma',
        'local_ai_sherpa',
        'local_ai_kit',
        'local_ai_genkit',
        'bedge_ai',
      ],
    );
  });

  test('release version validation rejects a mismatch', () {
    expect(
      () => validateReleaseVersion(<String, String>{
        'local_ai_core': '0.0.1',
        'local_ai_kit': '0.0.2',
      }),
      throwsA(isA<ReleaseValidationException>()),
    );
  });

  test('release version validation accepts one shared version', () {
    expect(
      validateReleaseVersion(<String, String>{
        'local_ai_core': '0.0.1',
        'local_ai_kit': '0.0.1',
      }),
      '0.0.1',
    );
  });
}
