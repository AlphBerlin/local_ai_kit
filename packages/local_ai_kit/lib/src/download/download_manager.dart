/// Resumable model downloader (architecture §5.1).
///
/// Pure Dart (`dart:io` + `crypto`) so it is fully unit-testable:
///  * preflight: network policy + disk headroom (sizeBytes × 1.2)
///  * resumable: per-file `*.part` + `meta.json`, HTTP `Range` resume,
///    server without Range support restarts that file from scratch
///  * retry: exponential backoff 1s/2s/4s capped at 30s; HTTP 4xx fails
///    immediately
///  * integrity: streamed sha256 per file; mismatch → delete & redownload,
///    at most 2 rounds overall
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:local_ai_core/local_ai_core.dart';

import 'resume_meta.dart';

/// Computes free disk space in MB for [path]. Injectable because dart:io
/// has no cross-platform free-space API (wired to a platform channel probe
/// by the kit at runtime).
typedef FreeDiskProbe = Future<int> Function(String path);

/// Default probe used when no platform integration is available: reports
/// plenty of space so preflight does not hard-fail on desktop/tests.
Future<int> _unknownFreeDisk(String path) async => 1 << 30;

class DownloadManager {
  DownloadManager({
    required LocalStoragePaths paths,
    required NetworkPolicy networkPolicy,
    FreeDiskProbe? freeDiskProbe,
    HttpClient? httpClient,
  })  : _paths = paths,
        _networkPolicy = networkPolicy,
        _freeDiskProbe = freeDiskProbe ?? _unknownFreeDisk,
        _ownsClient = httpClient == null,
        _client = httpClient ?? HttpClient();

  final LocalStoragePaths _paths;
  final NetworkPolicy _networkPolicy;
  final FreeDiskProbe _freeDiskProbe;
  final HttpClient _client;

  /// Only a client we created is ours to close in [dispose].
  final bool _ownsClient;

  static const _backoffCap = Duration(seconds: 30);
  static const _flushEveryBytes = 4 * 1024 * 1024; // flush + meta every 4MB

  /// Downloads (resuming when possible) all files of [manifest] into
  /// `downloads/<modelId>/`, verifies them, and leaves the directory ready
  /// for the installer to atomically rename.
  ///
  /// [onProgress] receives progress snapshots; [cancelToken] cooperatively
  /// aborts (on-disk state stays resumable).
  Future<Directory> download(
    LocalModelManifest manifest, {
    DownloadPolicy policy = const DownloadPolicy(),
    void Function(ModelDownloadProgress progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    await _preflight(manifest, policy);

    final dir = Directory(_paths.downloadDir(manifest.id));
    await dir.create(recursive: true);

    // Load or rebuild resume metadata; a newer catalog version invalidates
    // any partial state from an older manifest.
    var meta = await ResumeMeta.load(dir);
    if (meta == null || meta.catalogVersion != manifest.catalogVersion) {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
        await dir.create(recursive: true);
      }
      meta = ResumeMeta(
        modelId: manifest.id,
        catalogVersion: manifest.catalogVersion,
        files: manifest.files
            .map((f) => FileResumeInfo(
                  name: f.name,
                  sizeBytes: f.sizeBytes,
                  sha256: f.sha256,
                  relativePath: f.relativePath,
                ))
            .toList(),
      );
    }
    await _reconcileWithDisk(dir, meta);

    final progress = _ProgressTracker(manifest.id, meta, onProgress);
    progress.emit(ModelInstallState.downloading);

    // Up to 2 full verification rounds: a sha mismatch restarts that file.
    for (var round = 0; round < 2; round++) {
      for (var i = 0; i < manifest.files.length; i++) {
        cancelToken?.throwIfCancelled();
        final file = manifest.files[i];
        final info = meta.files[i];
        if (info.verified) continue;

        progress.currentFile = file.name;
        if (!info.isComplete) {
          // `tick()` re-emits the tracker's current state, which the
          // previous file left on `verifying`. Without this, every chunk of
          // file 2..n reports `verifying` while it is plainly downloading.
          progress.emit(ModelInstallState.downloading);
          await _downloadFile(
            file,
            info,
            meta,
            dir,
            policy: policy,
            progress: progress,
            cancelToken: cancelToken,
          );
        }

        final isPlaceholderSha = file.sha256.isEmpty ||
            file.sha256 == kPlaceholderSha256 ||
            file.sha256.startsWith('00000000');
        if (!policy.verifySha256 || isPlaceholderSha) {
          info.verified = true;
          await meta.save(dir);
          continue;
        }

        progress.emit(ModelInstallState.verifying);
        final actual = await sha256OfFile(_partFile(dir, info));
        if (actual.toLowerCase() != file.sha256.toLowerCase()) {
          // Integrity failure: drop the file and let the next round retry.
          await _partFile(dir, info).delete();
          info
            ..received = 0
            ..verified = false;
          await meta.save(dir);
          if (round == 1) {
            throw ModelCorruptedError(
              modelId: manifest.id,
              fileName: file.name,
              expectedSha256: file.sha256,
              actualSha256: actual,
            );
          }
          continue;
        }
        info.verified = true;
        await meta.save(dir);
      }
      if (meta.files.every((f) => f.verified)) {
        progress.currentFile = null;
        progress.flush();
        return dir;
      }
    }

    final failed = meta.files.firstWhere((f) => !f.verified);
    throw ModelCorruptedError(
      modelId: manifest.id,
      fileName: failed.name,
      expectedSha256: failed.sha256,
      actualSha256: 'unverified',
    );
  }

  // ---------------------------------------------------------------------------

  Future<void> _preflight(
      LocalModelManifest manifest, DownloadPolicy policy) async {
    final allowed = await _networkPolicy.canDownload(wifiOnly: policy.wifiOnly);
    if (!allowed) {
      throw const NetworkPolicyViolationError(
          'Wi-Fi-only policy: waiting for an unmetered connection.');
    }
    final freeMB = await _freeDiskProbe(_paths.downloadsDir);
    final requiredMB = (manifest.totalSizeBytes * 1.2 / (1024 * 1024)).ceil();
    if (freeMB < requiredMB) {
      throw InsufficientDiskError(requiredMB: requiredMB, freeMB: freeMB);
    }
  }

  /// Trusts the file system over meta.json after a crash.
  Future<void> _reconcileWithDisk(Directory dir, ResumeMeta meta) async {
    for (final info in meta.files) {
      final part = _partFile(dir, info);
      final onDisk = part.existsSync() ? part.lengthSync() : 0;
      if (onDisk != info.received) {
        if (onDisk > info.sizeBytes) {
          await part.delete(); // corrupt overshoot: restart file
          info.received = 0;
        } else {
          info.received = onDisk;
        }
      }
      if (info.received < info.sizeBytes) info.verified = false;
    }
    await meta.save(dir);
  }

  Future<void> _downloadFile(
    ModelFile file,
    FileResumeInfo info,
    ResumeMeta meta,
    Directory dir, {
    required DownloadPolicy policy,
    required _ProgressTracker progress,
    CancelToken? cancelToken,
  }) async {
    var attempt = 0;
    while (true) {
      cancelToken?.throwIfCancelled();
      try {
        await _downloadFileOnce(file, info, meta, dir, progress, cancelToken);
        return;
      } on CancelledError {
        rethrow;
      } on _HttpStatusException catch (e) {
        // 4xx: permanent, fail immediately (architecture §5.1.3).
        if (e.statusCode >= 400 && e.statusCode < 500) {
          throw NativeRuntimeError(
            'HTTP ${e.statusCode} downloading ${file.url}',
            cause: e,
          );
        }
        attempt = await _backoffOrRethrow(attempt, policy, e);
      } on SocketException catch (e) {
        attempt = await _backoffOrRethrow(attempt, policy, e);
      } on HttpException catch (e) {
        attempt = await _backoffOrRethrow(attempt, policy, e);
      }
    }
  }

  Future<int> _backoffOrRethrow(
      int attempt, DownloadPolicy policy, Object error) async {
    attempt++;
    if (attempt > policy.maxRetries) {
      throw NativeRuntimeError(
        'Download failed after ${policy.maxRetries} retries',
        cause: error,
      );
    }
    final delaySeconds = 1 << (attempt - 1); // 1s, 2s, 4s, ...
    final delay = Duration(seconds: delaySeconds) > _backoffCap
        ? _backoffCap
        : Duration(seconds: delaySeconds);
    await Future<void>.delayed(delay);
    return attempt;
  }

  Future<void> _downloadFileOnce(
    ModelFile file,
    FileResumeInfo info,
    ResumeMeta meta,
    Directory dir,
    _ProgressTracker progress,
    CancelToken? cancelToken,
  ) async {
    final request = await _client.getUrl(Uri.parse(file.url));
    request.followRedirects = true;
    request.maxRedirects = 10;
    final resumeFrom = info.received;
    if (resumeFrom > 0) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$resumeFrom-');
    }
    final response = await request.close();
    if (response.statusCode >= 400) {
      await response.drain<void>();
      throw _HttpStatusException(response.statusCode);
    }

    var append = true;
    if (resumeFrom > 0 && response.statusCode != HttpStatus.partialContent) {
      // Server ignored Range: restart this file from scratch.
      info.received = 0;
      append = false;
    }

    if (resumeFrom > 0 && response.statusCode == HttpStatus.partialContent) {
      final range = _parseContentRange(
          response.headers.value(HttpHeaders.contentRangeHeader));
      final contentLength = response.contentLength;
      final rangeIsValid = range != null &&
          range.start == resumeFrom &&
          (contentLength < 0 || range.end - range.start + 1 == contentLength) &&
          (range.total == null || range.total! > range.end);
      if (!rangeIsValid) {
        // A proxy/CDN can return a partial response for the wrong offset.
        // Discard it before restarting, otherwise the archive is duplicated
        // and progress can grow far beyond 100%.
        await response.drain<void>();
        info.received = 0;
        await meta.save(dir);
        return _downloadFileOnce(file, info, meta, dir, progress, cancelToken);
      }
      if (range.total != null) info.sizeBytes = range.total!;
    } else if (response.statusCode == HttpStatus.ok &&
        response.contentLength >= 0) {
      // Catalog sizes may be estimates. The final HTTP payload is the
      // authoritative total for progress and resumable state.
      info.sizeBytes = response.contentLength;
    }

    final part = _partFile(dir, info);
    await part.parent.create(recursive: true);
    final sink =
        part.openWrite(mode: append ? FileMode.append : FileMode.writeOnly);

    var sinceFlush = 0;
    try {
      await for (final chunk in response) {
        cancelToken?.throwIfCancelled();
        sink.add(chunk);
        info.received += chunk.length;
        progress.tick(chunk.length);
        sinceFlush += chunk.length;
        if (sinceFlush >= _flushEveryBytes) {
          await sink.flush();
          // Atomic meta update: a crash loses at most one flush window.
          await meta.save(dir);
          sinceFlush = 0;
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
      await meta.save(dir);
      // The byte counts are final for this file; make sure they are seen
      // even if the last chunk landed inside the throttle window.
      progress.flush();
    }
  }

  _ContentRange? _parseContentRange(String? value) {
    if (value == null) return null;
    final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$').firstMatch(value);
    if (match == null) return null;
    return _ContentRange(
      start: int.parse(match.group(1)!),
      end: int.parse(match.group(2)!),
      total: match.group(3) == '*' ? null : int.parse(match.group(3)!),
    );
  }

  File _partFile(Directory dir, FileResumeInfo info) {
    final sub = info.relativePath != null ? '${info.relativePath}/' : '';
    return File('${dir.path}/$sub${info.name}.part');
  }

  /// Streamed sha256 of [file] (chunked digest, constant memory).
  static Future<String> sha256OfFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  /// Releases the HTTP connection pool. Only closes a client this manager
  /// created; an injected one stays the caller's to manage.
  void dispose() {
    if (_ownsClient) _client.close(force: true);
  }
}

class _HttpStatusException implements Exception {
  _HttpStatusException(this.statusCode);
  final int statusCode;
  @override
  String toString() => 'HTTP $statusCode';
}

class _ContentRange {
  const _ContentRange({required this.start, required this.end, this.total});

  final int start;
  final int end;
  final int? total;
}

/// Smoothed throughput / ETA computation + progress fan-out.
///
/// Two things this deliberately does not do:
///  * it does not count bytes that were already on disk when the download
///    resumed towards throughput. Dividing *total* received bytes by time
///    spent *this session* reports a 900MB/s "download" the moment a
///    resumed transfer starts, and an ETA to match.
///  * it does not emit on every socket chunk. A 2GB download over a fast
///    link delivers tens of thousands of chunks per second; forwarding
///    each one to a `StreamBuilder` rebuilds the UI far more often than a
///    display can show, for no extra information.
class _ProgressTracker {
  _ProgressTracker(this.modelId, this.meta, this.onProgress)
      : _startedAt = DateTime.now();

  /// Minimum wall time between two `downloading` progress events. State
  /// changes always emit immediately, regardless of this.
  static const _minEmitInterval = Duration(milliseconds: 150);

  final String modelId;
  final ResumeMeta meta;
  final void Function(ModelDownloadProgress progress)? onProgress;
  final DateTime _startedAt;

  /// Bytes this session actually pulled over the network.
  ///
  /// Counted per chunk rather than derived as `received - baseline`: when a
  /// server ignores `Range`, the file restarts and `meta.receivedBytes`
  /// falls back to zero, so the derived figure would report a 1GB re-download
  /// of a 900MB partial as 100MB transferred.
  int _sessionBytes = 0;

  String? currentFile;

  ModelInstallState _state = ModelInstallState.downloading;
  DateTime? _lastEmitAt;

  /// Progress from a received chunk of [chunkBytes]: rate-limited.
  void tick(int chunkBytes) {
    _sessionBytes += chunkBytes;
    _emit(_state, throttle: true);
  }

  /// Progress from a state change: always delivered.
  void emit(ModelInstallState state) => _emit(state, throttle: false);

  /// Delivers the current byte counts regardless of the rate limit.
  ///
  /// Called when a file finishes and once more before `download` returns:
  /// without it the throttle can swallow the last tick of a transfer and
  /// leave a progress bar parked short of 100%.
  void flush() => _emit(_state, throttle: false);

  void _emit(ModelInstallState state, {required bool throttle}) {
    final stateChanged = state != _state;
    _state = state;
    final emit = onProgress;
    if (emit == null) return;

    final now = DateTime.now();
    final lastEmitAt = _lastEmitAt;
    if (throttle &&
        !stateChanged &&
        lastEmitAt != null &&
        now.difference(lastEmitAt) < _minEmitInterval) {
      return;
    }
    _lastEmitAt = now;

    final elapsed = now.difference(_startedAt).inMilliseconds / 1000.0;
    final received = meta.receivedBytes;
    final total = meta.totalBytes;
    final speed = elapsed > 0.05 && _sessionBytes > 0
        ? (_sessionBytes / elapsed).round()
        : 0;
    final remaining = total - received;
    emit(ModelDownloadProgress(
      modelId: modelId,
      state: state,
      receivedBytes: received,
      totalBytes: total,
      bytesPerSecond: speed,
      eta: speed > 0 && remaining > 0
          ? Duration(milliseconds: (remaining / speed * 1000).round())
          : null,
      currentFile: currentFile,
    ));
  }
}
