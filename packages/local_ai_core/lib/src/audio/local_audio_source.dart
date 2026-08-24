/// Microphone / audio input abstraction.
library;

import 'dart:async';
import 'audio_frame.dart';

/// A source of live audio frames (microphone on device; files/streams in
/// tests).
///
/// Implemented by `FlutterAudioRecorder` in `local_ai_flutter`.
abstract interface class LocalAudioSource {
  /// Starts capturing and returns the frame stream.
  ///
  /// The returned stream is single-subscription; call [stop] (or cancel the
  /// subscription) to release the device.
  Stream<AudioFrame> start({AudioFormat format = AudioFormat.pcm16kMono});

  /// Stops capturing and releases the underlying resource.
  Future<void> stop();
}
