# local_ai_sherpa

sherpa_onnx adapters for LocalAI Kit, providing on-device VAD, streaming STT
and TTS. Register `SherpaAdapterPlugin` to enable these capabilities:

```dart
import 'package:local_ai_sherpa/local_ai_sherpa.dart';

final plugins = <AdapterPlugin>[SherpaAdapterPlugin()];
```

FFI work is isolated from the UI isolate. See the
[LocalAI Kit repository](https://github.com/AlphBerlin/local_ai_kit) for
configuration and model documentation.
