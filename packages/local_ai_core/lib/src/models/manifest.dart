/// Model manifest: the catalog's declarative description of a model.
library;

import 'device_capabilities.dart';
import 'local_voice.dart';
import 'model_delivery.dart';
import 'model_file.dart';

/// What a model does.
enum ModelType { llm, stt, vad, tts, embedding }

/// Fine-grained capabilities, used for filtering and feature checks.
enum ModelCapability {
  chat,
  functionCalling,
  vision,
  streaming,
  asrStreaming,
  asrOffline,
  vadStreaming,
  ttsStreaming,
  multilingual,
  embedding,
}

/// Declarative description of one downloadable/bundled model.
///
/// Manifests come from the built-in catalog (`Models`), the remote catalog
/// (merged by version, see architecture §5.5), or app-supplied entries.
class LocalModelManifest {
  const LocalModelManifest({
    required this.id,
    required this.type,
    required this.provider,
    required this.files,
    required this.delivery,
    this.languages = const [],
    this.platforms = const ['android', 'ios'],
    this.minMemoryMB = 0,
    this.quantization,
    this.contextLength,
    this.capabilities = const {},
    this.license = 'unknown',
    this.voices,
    this.catalogVersion = 1,
    this.displayName,
    this.description,
    this.requiredAccelerators = const {},
    this.preferredAccelerators = const {},
  });

  /// Unique id, e.g. `gemma-3n-e2b-it-int4`.
  final String id;

  /// Capability category.
  final ModelType type;

  /// Adapter routing key, e.g. `google-gemma` / `sherpa-community`
  /// (see `AdapterRegistry`).
  final String provider;

  /// Downloadable files with integrity info.
  final List<ModelFile> files;

  /// Delivery strategy.
  final ModelDelivery delivery;

  /// BCP-47 language tags supported.
  final List<String> languages;

  /// Platforms this model can run on (`android`, `ios`, `macos`, ...).
  final List<String> platforms;

  /// Minimum free RAM required to load, in MB.
  final int minMemoryMB;

  /// Quantization tag (`int4`, `int8`, `fp16`), informational.
  final String? quantization;

  /// Max context length in tokens (LLM only).
  final int? contextLength;

  /// Declared capabilities.
  final Set<ModelCapability> capabilities;

  /// SPDX license id or human readable license.
  final String license;

  /// TTS only: voices this model can speak with, each independently
  /// installable.
  final List<LocalVoice>? voices;

  /// Monotonic catalog revision of this entry; used by the remote catalog
  /// merge strategy (higher wins).
  final int catalogVersion;

  /// Optional display name for UI.
  final String? displayName;

  /// Optional description for UI.
  final String? description;

  /// Backends this model cannot run without.
  ///
  /// A device missing one of these fails `ModelCompatibilityChecker.check`
  /// with a blocking issue, so the download is never offered. Empty for
  /// every catalog model that has a CPU path (i.e. almost all of them).
  final Set<Accelerator> requiredAccelerators;

  /// Backends this model runs acceptably fast on.
  ///
  /// A device exposing none of them still passes the check, but the report
  /// carries a warning that generation falls back to CPU.
  final Set<Accelerator> preferredAccelerators;

  /// Total size of all [files] in bytes.
  int get totalSizeBytes => files.fold<int>(0, (sum, f) => sum + f.sizeBytes);

  /// Total size in megabytes (rounded).
  int get totalSizeMB => (totalSizeBytes / (1024 * 1024)).round();

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'type': type.name,
        'provider': provider,
        'files': files.map((f) => f.toJson()).toList(),
        'delivery': delivery.name,
        'languages': languages,
        'platforms': platforms,
        'minMemoryMB': minMemoryMB,
        if (quantization != null) 'quantization': quantization,
        if (contextLength != null) 'contextLength': contextLength,
        'capabilities': capabilities.map((c) => c.name).toList(),
        'license': license,
        if (voices != null) 'voices': voices!.map((v) => v.toJson()).toList(),
        'catalogVersion': catalogVersion,
        if (displayName != null) 'displayName': displayName,
        if (description != null) 'description': description,
        if (requiredAccelerators.isNotEmpty)
          'requiredAccelerators':
              requiredAccelerators.map((a) => a.name).toList(),
        if (preferredAccelerators.isNotEmpty)
          'preferredAccelerators':
              preferredAccelerators.map((a) => a.name).toList(),
      };

  factory LocalModelManifest.fromJson(Map<String, Object?> json) {
    return LocalModelManifest(
      id: json['id'] as String,
      type: ModelType.values.byName(json['type'] as String),
      provider: json['provider'] as String,
      files: (json['files'] as List)
          .map((e) => ModelFile.fromJson((e as Map).cast<String, Object?>()))
          .toList(),
      delivery: ModelDelivery.values.byName(json['delivery'] as String),
      languages: (json['languages'] as List?)?.cast<String>() ?? const [],
      platforms: (json['platforms'] as List?)?.cast<String>() ??
          const ['android', 'ios'],
      minMemoryMB: json['minMemoryMB'] as int? ?? 0,
      quantization: json['quantization'] as String?,
      contextLength: json['contextLength'] as int?,
      capabilities:
          ((json['capabilities'] as List?)?.cast<String>() ?? const <String>[])
              .map(ModelCapability.values.byName)
              .toSet(),
      license: json['license'] as String? ?? 'unknown',
      voices: (json['voices'] as List?)
          ?.map((e) => LocalVoice.fromJson((e as Map).cast<String, Object?>()))
          .toList(),
      catalogVersion: json['catalogVersion'] as int? ?? 1,
      displayName: json['displayName'] as String?,
      description: json['description'] as String?,
      requiredAccelerators: _accelerators(json['requiredAccelerators']),
      preferredAccelerators: _accelerators(json['preferredAccelerators']),
    );
  }

  /// Tolerant accelerator decoding: an unknown name from a newer remote
  /// catalog is skipped rather than failing the whole manifest.
  static Set<Accelerator> _accelerators(Object? raw) {
    if (raw is! List) return const {};
    final names = Accelerator.values.map((a) => a.name).toSet();
    return raw
        .whereType<String>()
        .where(names.contains)
        .map(Accelerator.values.byName)
        .toSet();
  }

  @override
  String toString() =>
      'LocalModelManifest($id, ${type.name}, provider=$provider, v$catalogVersion)';
}
