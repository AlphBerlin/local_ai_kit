import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_core/local_ai_core.dart';
import 'package:local_ai_flutter/src/audio_player.dart';

void main() {
  test('FlutterAudioPlayer delegates a live chunk stream to its backend',
      () async {
    final backend = _FakePlaybackBackend();
    final player = FlutterAudioPlayer(cacheDir: '/unused', backend: backend);

    await player.play(Stream.fromIterable([
      AudioChunk(
        samples: Float32List.fromList([0.1, 0.2]),
        format: AudioFormat.pcm24kMonoFloat,
      ),
    ]));

    expect(backend.chunks.single.sampleCount, 2);
    expect(backend.stopCount, 0);
  });

  test('stop delegates immediately to the playback backend', () async {
    final backend = _FakePlaybackBackend(blockPlayback: true);
    final player = FlutterAudioPlayer(cacheDir: '/unused', backend: backend);
    final playback = player.play(const Stream<AudioChunk>.empty());

    await backend.started.future;
    await player.stop();
    backend.finish();
    await playback;

    expect(backend.stopCount, 1);
  });
}

final class _FakePlaybackBackend implements PcmPlaybackBackend {
  _FakePlaybackBackend({this.blockPlayback = false});

  final bool blockPlayback;
  final started = Completer<void>();
  final finished = Completer<void>();
  final chunks = <AudioChunk>[];
  var stopCount = 0;

  @override
  Future<void> play(Stream<AudioChunk> audio) async {
    await for (final chunk in audio) {
      chunks.add(chunk);
    }
    if (blockPlayback) {
      started.complete();
      await finished.future;
    }
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }

  void finish() => finished.complete();
}
