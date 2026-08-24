/// One downloadable file belonging to a model (or a TTS voice).
library;

class ModelFile {
  const ModelFile({
    required this.name,
    required this.url,
    required this.sha256,
    required this.sizeBytes,
    this.relativePath,
  });

  /// File name, unique within the model (e.g. `model.onnx`).
  final String name;

  /// HTTPS download URL.
  final String url;

  /// Lowercase hex sha256 of the complete file.
  final String sha256;

  /// Total file size in bytes.
  final int sizeBytes;

  /// Subdirectory inside the model folder; `null` = model root.
  final String? relativePath;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'url': url,
        'sha256': sha256,
        'sizeBytes': sizeBytes,
        if (relativePath != null) 'relativePath': relativePath,
      };

  factory ModelFile.fromJson(Map<String, Object?> json) => ModelFile(
        name: json['name'] as String,
        url: json['url'] as String,
        sha256: json['sha256'] as String,
        sizeBytes: json['sizeBytes'] as int,
        relativePath: json['relativePath'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is ModelFile &&
      other.name == name &&
      other.url == url &&
      other.sha256 == sha256 &&
      other.sizeBytes == sizeBytes &&
      other.relativePath == relativePath;

  @override
  int get hashCode => Object.hash(name, url, sha256, sizeBytes, relativePath);

  @override
  String toString() => 'ModelFile($name, $sizeBytes bytes)';
}
