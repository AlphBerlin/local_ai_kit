/// Unified error model. Every failure crossing a package boundary is a
/// [LocalAIError]; adapter-native exceptions must be wrapped at the adapter
/// edge.
library;

import '../models/device_capabilities.dart';

/// Base class of all LocalAI errors.
sealed class LocalAIError implements Exception {
  const LocalAIError(this.message);

  /// Human-readable description, safe to show in logs.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The requested model id is not present in the catalog.
final class ModelNotFoundError extends LocalAIError {
  const ModelNotFoundError(this.modelId)
      : super('Model "$modelId" not found in catalog.');

  final String modelId;
}

/// A downloaded or installed file failed its sha256 check.
final class ModelCorruptedError extends LocalAIError {
  const ModelCorruptedError({
    required this.modelId,
    required this.fileName,
    required this.expectedSha256,
    required this.actualSha256,
  }) : super(
          'File "$fileName" of model "$modelId" failed sha256 verification '
          '(expected $expectedSha256, got $actualSha256).',
        );

  final String modelId;
  final String fileName;
  final String expectedSha256;
  final String actualSha256;
}

/// Not enough free disk space to download/install a model.
final class InsufficientDiskError extends LocalAIError {
  const InsufficientDiskError({required this.requiredMB, required this.freeMB})
      : super(
          'Insufficient disk space: need ${requiredMB}MB '
          '(incl. headroom) but only ${freeMB}MB free.',
        );

  final int requiredMB;
  final int freeMB;
}

/// The device does not meet the model requirements (RAM / platform / SoC).
final class IncompatibleDeviceError extends LocalAIError {
  IncompatibleDeviceError(this.report)
      : super('Device is not compatible: ${report.summary}');

  final CompatibilityReport report;
}

/// Download was blocked by the active [NetworkPolicy] (e.g. Wi-Fi only on
/// a cellular connection and no resume callback was possible).
final class NetworkPolicyViolationError extends LocalAIError {
  const NetworkPolicyViolationError([String? reason])
      : super(reason ?? 'Download blocked by network policy.');
}

/// Operation was cancelled through a `CancelToken` or by the user.
final class CancelledError extends LocalAIError {
  const CancelledError([String? reason]) : super(reason ?? 'Cancelled.');
}

/// A native runtime (onnxruntime / LiteRT / ...) crashed or threw.
///
/// [cause] is the original error object; it is intentionally typed as
/// [Object] so core never references native SDK types.
final class NativeRuntimeError extends LocalAIError {
  const NativeRuntimeError(super.message, {this.cause, this.stackTrace});

  final Object? cause;
  final StackTrace? stackTrace;
}

/// Structured output (`generateStructured`) failed to produce JSON matching
/// the requested schema after all retries.
final class StructuredOutputError extends LocalAIError {
  const StructuredOutputError({
    required this.rawOutput,
    required this.attempts,
    String? reason,
  }) : super(reason ??
            'Model failed to produce schema-valid JSON '
                'after $attempts attempt(s).');

  /// Last raw model output, for debugging.
  final String rawOutput;

  /// How many attempts were made (including the first).
  final int attempts;
}

/// No adapter was registered for the requested provider/capability pair.
final class AdapterNotFoundError extends LocalAIError {
  const AdapterNotFoundError({required this.provider, required this.capability})
      : super(
          'No adapter registered for provider "$provider" '
          'and capability "$capability". Pass the matching AdapterPlugin to '
          'LocalAI.initialize().',
        );

  final String provider;
  final String capability;
}

/// The provider could not serve a request in its current state
/// (e.g. `generate` before `load`).
///
/// Named `InvalidStateError` (not `IllegalStateError`) to avoid clashing
/// with `dart:core`'s `IllegalStateError`.
final class InvalidStateError extends LocalAIError {
  const InvalidStateError(super.message);
}
