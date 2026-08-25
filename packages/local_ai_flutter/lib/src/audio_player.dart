/// Streaming PCM speaker playback via flutter_soloud.
library;

import 'dart:async';

import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:local_ai_core/local_ai_core.dart';

import 'pcm_audio.dart';

/// Platform seam for testing and for alternate PCM playback engines.
abstract interface class PcmPlaybackBackend {
  Future<void> play(Stream<AudioChunk> audio);

  Future<void> stop();
}

/// LocalAudioOutput backed by a native PCM push stream.
class FlutterAudioPlayer implements LocalAudioOutput {
  FlutterAudioPlayer({
    required this.cacheDir,
    PcmPlaybackBackend? backend,
  }) : _backend = backend ?? SoLoudPcmPlaybackBackend();

  /// Retained for source compatibility with older callers. Streaming playback
  /// no longer creates scratch files in this directory.
  final String cacheDir;

  final PcmPlaybackBackend _backend;

  @override
  Future<void> play(Stream<AudioChunk> audio) => _backend.play(audio);

  @override
  Future<void> stop() => _backend.stop();
}

/// Feeds float32 AudioChunks to SoLoud as released PCM16 stream buffers.
class SoLoudPcmPlaybackBackend implements PcmPlaybackBackend {
  SoLoudPcmPlaybackBackend({SoLoud? engine})
      : _engine = engine ?? SoLoud.instance;

  final SoLoud _engine;
  SoundHandle? _activeHandle;
  AudioSource? _activeSource;
  StreamIterator<AudioChunk>? _activeIterator;
  Future<void>? _initialization;

  @override
  Future<void> play(Stream<AudioChunk> audio) async {
    await stop();
    final iterator = StreamIterator<AudioChunk>(audio);
    _activeIterator = iterator;
    AudioChunk? firstChunk;
    try {
      while (await iterator.moveNext()) {
        final chunk = iterator.current;
        if (chunk.samples.isNotEmpty) {
          firstChunk = chunk;
          break;
        }
      }
      if (firstChunk == null) return;

      await _ensureInitialized();
      final stream = _engine.setBufferStream(
        maxBufferSizeDuration: const Duration(seconds: 2),
        sampleRate: firstChunk.format.sampleRate,
        channels:
            firstChunk.format.channels == 1 ? Channels.mono : Channels.stereo,
        format: BufferType.s16le,
        bufferingType: BufferingType.released,
      );
      _activeSource = stream;
      final handle = _activeHandle = _engine.play(stream);

      try {
        _engine.addAudioDataStream(
          stream,
          float32ToPcm16Bytes(firstChunk.samples),
        );
        while (await iterator.moveNext()) {
          final chunk = iterator.current;
          if (chunk.samples.isNotEmpty) {
            _engine.addAudioDataStream(
              stream,
              float32ToPcm16Bytes(chunk.samples),
            );
          }
        }
        _engine.setDataIsEnded(stream);
        await sourceFinished(stream);
      } finally {
        await _disposeActive(stream, handle);
      }
    } finally {
      if (identical(_activeIterator, iterator)) _activeIterator = null;
      await iterator.cancel();
    }
  }

  Future<void> sourceFinished(AudioSource source) async {
    try {
      await source.allInstancesFinished.first.timeout(
        const Duration(minutes: 5),
      );
    } on Object {
      // Stop/dispose can close the source stream before the completion event.
    }
  }

  @override
  Future<void> stop() async {
    final handle = _activeHandle;
    final source = _activeSource;
    final iterator = _activeIterator;
    _activeHandle = null;
    _activeSource = null;
    _activeIterator = null;
    await iterator?.cancel();
    if (handle != null) await _engine.stop(handle);
    if (source != null) await _engine.disposeSource(source);
  }

  Future<void> _ensureInitialized() {
    final initialized = _initialization;
    if (initialized != null) return initialized;
    final future = _engine.isInitialized
        ? Future<void>.value()
        : _engine.init(sampleRate: 44100, channels: Channels.mono);
    return _initialization = future.whenComplete(() => _initialization = null);
  }

  Future<void> _disposeActive(AudioSource source, SoundHandle handle) async {
    if (identical(_activeHandle, handle)) _activeHandle = null;
    if (identical(_activeSource, source)) _activeSource = null;
    if (_engine.isInitialized) await _engine.disposeSource(source);
  }
}
