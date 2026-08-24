/// path_provider backed [LocalStoragePaths] implementation.
library;

import 'dart:async';
import 'dart:io';

import 'package:local_ai_core/local_ai_core.dart';
import 'package:path_provider/path_provider.dart';

/// Resolves `<app-support>/local_ai/...` (see architecture §5.1 layout).
class FlutterStoragePaths implements LocalStoragePaths {
  FlutterStoragePaths._(this._root);

  final Directory _root;

  /// Resolves the app-support directory. Call once at startup.
  static Future<FlutterStoragePaths> resolve({String subdir = 'local_ai'}) async {
    final support = await getApplicationSupportDirectory();
    return FlutterStoragePaths._(Directory('${support.path}/$subdir'));
  }

  /// Testing hook: build on an arbitrary root directory.
  factory FlutterStoragePaths.at(Directory root) => FlutterStoragePaths._(root);

  static String _typeDir(ModelType type) => type.name;

  @override
  String get rootDir => _root.path;

  @override
  String get modelsDir => '${_root.path}/models';

  @override
  String modelDir(ModelType type, String modelId) =>
      '${_root.path}/models/${_typeDir(type)}/$modelId';

  @override
  String get downloadsDir => '${_root.path}/downloads';

  @override
  String downloadDir(String modelId) => '${_root.path}/downloads/$modelId';

  @override
  String get voicesDir => '${_root.path}/voices';

  @override
  String voiceDir(String voiceId) => '${_root.path}/voices/$voiceId';

  @override
  String get manifestsDir => '${_root.path}/manifests';

  @override
  String get cacheDir => '${_root.path}/cache';

  @override
  Future<void> ensureInitialized() async {
    for (final dir in [
      _root.path,
      modelsDir,
      downloadsDir,
      voicesDir,
      manifestsDir,
      cacheDir,
    ]) {
      await Directory(dir).create(recursive: true);
    }
    for (final type in ModelType.values) {
      await Directory('$modelsDir/${_typeDir(type)}').create(recursive: true);
    }
  }
}