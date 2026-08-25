# local_ai_kit

The LocalAI Kit Flutter facade for offline-first, streaming on-device AI.
It provides model downloads, runtime scheduling, voice sessions and a typed
pipeline DSL. Register only the adapters your app uses.

```dart
import 'package:local_ai_kit/local_ai_kit.dart';
import 'package:local_ai_gemma/local_ai_gemma.dart';

final ai = await LocalAI.initialize(
  LocalAIConfig.offlineChat(),
  plugins: const [GemmaAdapterPlugin()],
);
final response = await ai.generate('Hello from on-device AI.');
```

Read the [getting started guide](https://github.com/AlphBerlin/local_ai_kit/blob/main/docs/getting-started.md)
and the [full repository documentation](https://github.com/AlphBerlin/local_ai_kit).
