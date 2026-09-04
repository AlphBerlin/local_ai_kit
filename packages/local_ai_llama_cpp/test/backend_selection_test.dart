import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_core/local_ai_core.dart';
import 'package:local_ai_llama_cpp/local_ai_llama_cpp.dart';

void main() {
  test('cpu keeps every layer off the GPU', () {
    final plan = BackendSelection.resolve(RuntimePreference.cpu);
    expect(plan.gpuLayers, 0);
    expect(plan.usesGpu, isFalse);
  });

  test('auto, gpu and npu all ask for full offload', () {
    for (final preference in const [
      RuntimePreference.auto,
      RuntimePreference.gpu,
      RuntimePreference.npu,
    ]) {
      final plan = BackendSelection.resolve(preference);
      expect(plan.gpuLayers, BackendSelection.maxOffloadLayers,
          reason: '${preference.name} should offload');
      expect(plan.usesGpu, isTrue);
    }
  });

  test('the CPU fallback of a GPU plan keeps the thread count', () {
    final plan =
        BackendSelection.resolve(RuntimePreference.gpu, processorCount: 8);
    final fallback = plan.cpuFallback;
    expect(fallback.gpuLayers, 0);
    expect(fallback.threads, plan.threads);
    expect(fallback.preference, RuntimePreference.cpu);
  });

  test('threads are half the cores, clamped to [2, 8]', () {
    expect(BackendSelection.threadsFor(1), 2);
    expect(BackendSelection.threadsFor(4), 2);
    expect(BackendSelection.threadsFor(12), 6);
    expect(BackendSelection.threadsFor(64), BackendSelection.maxThreads);
  });

  test('an unknown core count falls back to a safe default', () {
    expect(BackendSelection.threadsFor(null), 2);
    expect(BackendSelection.threadsFor(0), 2);
  });
}
