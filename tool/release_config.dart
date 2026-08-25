class ReleasePackage {
  const ReleasePackage({
    required this.name,
    required this.directory,
    required this.usesFlutter,
  });

  final String name;
  final String directory;
  final bool usesFlutter;
}

const releasePackages = <ReleasePackage>[
  ReleasePackage(
    name: 'local_ai_core',
    directory: 'packages/local_ai_core',
    usesFlutter: false,
  ),
  ReleasePackage(
    name: 'local_ai_flutter',
    directory: 'packages/local_ai_flutter',
    usesFlutter: true,
  ),
  ReleasePackage(
    name: 'local_ai_gemma',
    directory: 'packages/local_ai_gemma',
    usesFlutter: true,
  ),
  ReleasePackage(
    name: 'local_ai_sherpa',
    directory: 'packages/local_ai_sherpa',
    usesFlutter: true,
  ),
  ReleasePackage(
    name: 'local_ai_kit',
    directory: 'packages/local_ai_kit',
    usesFlutter: true,
  ),
  ReleasePackage(
    name: 'local_ai_genkit',
    directory: 'packages/local_ai_genkit',
    usesFlutter: true,
  ),
];

class ReleaseValidationException implements Exception {
  const ReleaseValidationException(this.message);

  final String message;

  @override
  String toString() => 'ReleaseValidationException: $message';
}

String validateReleaseVersion(Map<String, String> versions) {
  if (versions.isEmpty) {
    throw const ReleaseValidationException(
      'No package versions were found.',
    );
  }

  final uniqueVersions = versions.values.toSet();
  if (uniqueVersions.length != 1) {
    throw ReleaseValidationException(
      'All release packages must use one version: ${versions.entries.join(', ')}',
    );
  }

  return uniqueVersions.single;
}
