# local_ai_kit_all

The one-dependency LocalAI Kit umbrella. It includes the facade, platform
services, Gemma, Sherpa and Genkit adapters.

```yaml
dependencies:
  local_ai_kit_all: ^0.0.1
```

```dart
import 'package:local_ai_kit_all/local_ai_kit_all.dart';

final ai = await LocalAI.initialize(
  LocalAIConfig.offlineChat(),
  plugins: const [GemmaAdapterPlugin()],
);
```

Use the individual packages instead when you want tighter dependency control
and the smallest possible application binary. This umbrella intentionally
brings all first-party adapter runtimes into the dependency graph.

See the [LocalAI Kit repository](https://github.com/AlphBerlin/local_ai_kit)
for the full documentation.
