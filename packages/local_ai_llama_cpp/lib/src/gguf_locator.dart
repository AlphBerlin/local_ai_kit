/// Resolves the GGUF weight file of an installed model.
///
/// Split into a pure selection rule (unit-testable, no disk) and a thin
/// directory-scanning wrapper, because picking the right file out of a
/// multi-shard / multi-file install is where the bugs live.
library;

import 'dart:io';

import 'package:local_ai_core/local_ai_core.dart';

/// Locates `.gguf` weights under `models/<type>/<modelId>/`.
abstract final class GgufLocator {
  /// Marker in the file names llama.cpp uses for multimodal projectors.
  /// These are companions to a chat model, never the model itself.
  static const String projectorMarker = 'mmproj';

  /// Picks the GGUF file to load from a list of [fileNames].
  ///
  /// * multimodal projector files are never selected as the model;
  /// * for a sharded model (`…-00001-of-00005.gguf`) the first shard is
  ///   selected — llama.cpp loads the remaining shards itself;
  /// * otherwise the alphabetically first `.gguf` wins, so the choice is
  ///   deterministic across platforms whose directory order differs.
  ///
  /// Returns `null` when the list contains no usable GGUF file.
  static String? select(List<String> fileNames) {
    final candidates = fileNames
        .where((name) => name.toLowerCase().endsWith('.gguf'))
        .where((name) => !_isProjector(name))
        .toList()
      ..sort();
    if (candidates.isEmpty) return null;

    final firstShard = candidates.firstWhere(
      (name) => _shardIndex(name) == 1,
      orElse: () => '',
    );
    if (firstShard.isNotEmpty) return firstShard;

    // Every candidate is a later shard of a set whose first shard is
    // missing: refuse rather than load an unusable fragment.
    if (candidates.every((name) => _shardIndex(name) != null)) return null;

    return candidates.firstWhere((name) => _shardIndex(name) == null);
  }

  /// Picks the multimodal projector companion, when the install ships one.
  static String? selectProjector(List<String> fileNames) {
    final candidates = fileNames
        .where((name) => name.toLowerCase().endsWith('.gguf'))
        .where(_isProjector)
        .toList()
      ..sort();
    return candidates.isEmpty ? null : candidates.first;
  }

  /// Resolves the weight file for [modelId] on disk.
  ///
  /// Throws [InvalidStateError] when the model is not installed or its
  /// directory holds no usable GGUF file — the same contract the Gemma
  /// adapter uses, so the kit's error handling is unchanged.
  static File resolve(
    LocalStoragePaths paths,
    ModelType type,
    String modelId,
  ) {
    final dirPath = paths.modelDir(type, modelId);
    final directory = Directory(dirPath);
    if (!directory.existsSync()) {
      throw InvalidStateError(
        'Model files not found for "$modelId" at "$dirPath". '
        'The model is not installed on disk.',
      );
    }
    // followLinks matters: `ModelHub.registerExternalModel` symlinks a
    // user-supplied GGUF into this directory instead of copying it.
    final entries = directory
        .listSync(followLinks: true)
        .map((e) => e.path.split(Platform.pathSeparator).last)
        .toList();
    final selected = select(entries);
    if (selected == null) {
      throw InvalidStateError(
        'No GGUF weight file found in "$dirPath" for model "$modelId". '
        'llama.cpp models must ship a .gguf file.',
      );
    }
    return File('$dirPath${Platform.pathSeparator}$selected');
  }

  static bool _isProjector(String name) =>
      name.toLowerCase().contains(projectorMarker);

  /// 1-based shard index of `…-00003-of-00005.gguf`, or `null`.
  static int? _shardIndex(String name) {
    final match =
        RegExp(r'-(\d{5})-of-(\d{5})\.gguf$', caseSensitive: false)
            .firstMatch(name);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }
}
