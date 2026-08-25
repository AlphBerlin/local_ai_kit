# local_ai_gemma

Gemma/LiteRT-LM adapter for LocalAI Kit. Register `GemmaAdapterPlugin` when
your Flutter app uses Gemma or compatible LiteRT-LM models:

```dart
import 'package:local_ai_gemma/local_ai_gemma.dart';

final plugins = <AdapterPlugin>[GemmaAdapterPlugin()];
```

See the [LocalAI Kit repository](https://github.com/AlphBerlin/local_ai_kit)
for model and configuration documentation.
