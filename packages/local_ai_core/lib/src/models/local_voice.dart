/// A TTS voice descriptor.
///
/// Voices are installed independently of the base TTS model so users can
/// download only the voices they need (see storage layout §5.1).
library;

import 'model_file.dart';

class LocalVoice {
  const LocalVoice({
    required this.id,
    required this.name,
    required this.language,
    this.gender,
    this.sampleRate = 22050,
    this.files = const [],
  });

  /// Unique voice id, e.g. `supertonic-en-female-1`.
  final String id;

  /// Human readable display name.
  final String name;

  /// BCP-47 language tag.
  final String language;

  /// Optional gender hint (`female` / `male` / `neutral`).
  final String? gender;

  /// Native output sample rate of this voice.
  final int sampleRate;

  /// Voice-specific downloadable files; empty when the voice ships inside
  /// the base TTS model.
  final List<ModelFile> files;

  /// Total size of [files] in bytes.
  int get sizeBytes => files.fold<int>(0, (sum, f) => sum + f.sizeBytes);

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'language': language,
        if (gender != null) 'gender': gender,
        'sampleRate': sampleRate,
        'files': files.map((f) => f.toJson()).toList(),
      };

  factory LocalVoice.fromJson(Map<String, Object?> json) => LocalVoice(
        id: json['id'] as String,
        name: json['name'] as String,
        language: json['language'] as String? ?? 'en',
        gender: json['gender'] as String?,
        sampleRate: json['sampleRate'] as int? ?? 22050,
        files: (json['files'] as List?)
                ?.map((e) => ModelFile.fromJson((e as Map).cast<String, Object?>()))
                .toList() ??
            const [],
      );

  @override
  String toString() => 'LocalVoice($id, $language)';
}
