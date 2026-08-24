/// One-line registration of all sherpa adapters (architecture §4.5).
library;

import 'package:local_ai_core/local_ai_core.dart';

import 'sherpa_stt_adapter.dart';
import 'sherpa_tts_adapter.dart';
import 'sherpa_vad_adapter.dart';

/// Registers sherpa VAD + STT + TTS factories into an [AdapterRegistry].
///
/// ```dart
/// await LocalAI.initialize(config, plugins: [SherpaAdapterPlugin()]);
/// ```
class SherpaAdapterPlugin implements AdapterPlugin {
  const SherpaAdapterPlugin();

  @override
  void register(AdapterRegistry registry) {
    registry.registerVad(
      ModelProviders.sherpaCommunity,
      (context) => SherpaVadAdapter(paths: context.paths),
    );
    registry.registerStt(
      ModelProviders.sherpaCommunity,
      (context) => SherpaSttAdapter(paths: context.paths),
    );
    registry.registerTts(
      ModelProviders.sherpaCommunity,
      (context) => SherpaTtsAdapter(paths: context.paths),
    );
  }
}
