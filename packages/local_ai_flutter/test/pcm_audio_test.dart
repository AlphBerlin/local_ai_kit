import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_flutter/src/pcm_audio.dart';

void main() {
  test('converts normalized float samples to little-endian PCM16', () {
    final bytes = float32ToPcm16Bytes(
      Float32List.fromList([-1.0, -0.5, 0.0, 0.5, 1.0, 2.0]),
    );
    final data = ByteData.sublistView(bytes);

    expect(bytes.length, 12);
    expect(List.generate(6, (i) => data.getInt16(i * 2, Endian.little)), [
      -32767,
      -16384,
      0,
      16384,
      32767,
      32767,
    ]);
  });
}
