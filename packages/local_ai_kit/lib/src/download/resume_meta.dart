/// Resumable-download metadata persisted per model (architecture §5.1).
///
/// Stored as `<downloadsDir>/<modelId>/meta.json`; written atomically via
/// `meta.json.tmp` → rename so a crash mid-write never corrupts the state.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Per-file resume bookkeeping.
class FileResumeInfo {
  FileResumeInfo({
    required this.name,
    required this.sizeBytes,
    required this.sha256,
    this.relativePath,
    this.received = 0,
    this.verified = false,
  });

  final String name;
  final int sizeBytes;
  final String sha256;
  final String? relativePath;

  /// Bytes already persisted in `<name>.part`.
  int received;

  /// Whether this file already passed its sha256 check this session.
  bool verified;

  bool get isComplete => received >= sizeBytes;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'sizeBytes': sizeBytes,
        'sha256': sha256,
        if (relativePath != null) 'relativePath': relativePath,
        'received': received,
        'verified': verified,
      };

  factory FileResumeInfo.fromJson(Map<String, Object?> json) =>
      FileResumeInfo(
        name: json['name'] as String,
        sizeBytes: json['sizeBytes'] as int,
        sha256: json['sha256'] as String,
        relativePath: json['relativePath'] as String?,
        received: json['received'] as int? ?? 0,
        verified: json['verified'] as bool? ?? false,
      );
}

/// `meta.json` content of an in-progress download.
class ResumeMeta {
  ResumeMeta({
    required this.modelId,
    required this.catalogVersion,
    required this.files,
    this.etag,
  });

  final String modelId;
  final int catalogVersion;
  String? etag;
  final List<FileResumeInfo> files;

  int get totalBytes => files.fold(0, (sum, f) => sum + f.sizeBytes);
  int get receivedBytes => files.fold(0, (sum, f) => sum + f.received);
  bool get isComplete => files.every((f) => f.isComplete);

  Map<String, Object?> toJson() => <String, Object?>{
        'modelId': modelId,
        'catalogVersion': catalogVersion,
        if (etag != null) 'etag': etag,
        'totalBytes': totalBytes,
        'files': files.map((f) => f.toJson()).toList(),
      };

  factory ResumeMeta.fromJson(Map<String, Object?> json) => ResumeMeta(
        modelId: json['modelId'] as String,
        catalogVersion: json['catalogVersion'] as int? ?? 1,
        etag: json['etag'] as String?,
        files: (json['files'] as List)
            .map((e) => FileResumeInfo.fromJson((e as Map).cast<String, Object?>()))
            .toList(),
      );

  /// Loads `meta.json` from [dir]; returns `null` when absent/corrupt.
  static Future<ResumeMeta?> load(Directory dir) async {
    final file = File('${dir.path}/meta.json');
    if (!file.existsSync()) return null;
    try {
      final json = jsonDecode(await file.readAsString());
      return ResumeMeta.fromJson((json as Map).cast<String, Object?>());
    } on Object {
      return null;
    }
  }

  /// Atomically persists to `<dir>/meta.json` (tmp + rename).
  Future<void> save(Directory dir) async {
    await dir.create(recursive: true);
    final tmp = File('${dir.path}/meta.json.tmp');
    await tmp.writeAsString(jsonEncode(toJson()), flush: true);
    await tmp.rename('${dir.path}/meta.json');
  }
}
