/// sherpa_onnx adapters for LocalAI Kit (VAD / STT / TTS).
///
/// All sherpa_onnx FFI calls run inside dedicated worker isolates
/// (architecture §5.6); sherpa types never cross the package boundary.
library;

export 'src/sherpa_adapter_plugin.dart';
export 'src/sherpa_stt_adapter.dart';
export 'src/sherpa_tts_adapter.dart';
export 'src/sherpa_vad_adapter.dart';
