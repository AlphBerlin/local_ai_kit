# LLM & Genkit

Text generation is available through the `ai.llm` facade (and top-level `ai.*` shortcuts); the optional Genkit package adds flows, tools and prompt templates on top of any `LocalLlm`.

## generate / generateStream

```dart
// One-shot (folded stream):
final response = await ai.generate(
  'Summarize the plot of Hamlet in two sentences.',
  systemPrompt: 'You are concise.',
  temperature: 0.7,   // overrides LlmConfig.temperature
  maxTokens: 256,
);
print(response.text);
print(response.finishReason);   // stop / length / cancelled / error / contentFiltered

// Streaming with a full request:
final chunks = await ai.generateStream(LlmRequest(
  messages: const [
    LlmMessage.system('You are a pirate.'),
    LlmMessage.user('Where is the treasure?'),
  ],
  maxTokens: 128,
  stopSequences: const ['\n\n'],
));
await for (final chunk in chunks) {
  stdout.write(chunk.textDelta);
  if (chunk.contextTruncated) {
    // The adapter dropped older turns to fit the context window.
  }
}
```

`LlmRequest.prompt(...)` is a convenience factory for single-turn prompts. Token accounting (`promptTokens` / `completionTokens`) is reported on the final chunk when the runtime provides it. `ai.llm.isLoaded` reports whether the model is currently in memory; `ai.llm.unload()` releases it (it reloads lazily on the next call).

## Sampling parameters & repetition control

`LlmLoadOptions` provides fine-grained control over generation dynamics across all models:

| Parameter | Type | Default | Description |
|---|---|---|---|
| `topK` | `int` | `40` | Limits sampling to top K most probable tokens (filters low-probability tail). |
| `topP` | `double` | `0.9` | Nucleus sampling threshold (cumulative probability mass). |
| `temperature` | `double` | `0.8` | Controls randomness (lower = deterministic, higher = creative). |

`maxTokens` is a per-request field on `LlmRequest`, not on `LlmLoadOptions` — see `generateStream` above (`null` = model default).

### Streaming repetition guard
To prevent smaller quantized models (0.5B–4B) from falling into degenerative loops or repeat loops, the Gemma adapter integrates an automated 3-tier streaming guard:
1. **Line-level repetition detector**: Truncates repetitive phrases across multi-line outputs.
2. **N-gram cycle breaker**: Detects repeating 3-word cycles (three consecutive matching 3-word windows) and terminates the turn cleanly.
3. **Repeated-word guard**: Prevents runaway loops where the last 6 words are all identical.

Note: the shipped `GemmaLlmAdapter` always reports `finishReason: stop` on the final chunk (even when the repetition guard cut generation short) and never populates `promptTokens`/`completionTokens` — those fields are part of the interface for adapters that can provide them, not guarantees from every adapter.

## Structured output & JsonSchema

`generateStructured` injects the schema into the prompt (or grammar, when the runtime supports constrained decoding), parses the result and retries with error feedback up to `maxRetries` times before throwing `StructuredOutputError`:

```dart
final schema = JsonSchema.object(
  properties: {
    'city': JsonSchema.string(description: 'City name'),
    'tempCelsius': JsonSchema.number(),
    'conditions': JsonSchema.string(
      enumValues: ['sunny', 'cloudy', 'rain', 'snow'],
    ),
  },
  required: ['city', 'tempCelsius', 'conditions'],
);

final weather = await ai.generateStructured<Map<String, dynamic>>(
  'What is the weather in Paris right now? Answer as JSON.',
  schema: schema,
  fromJson: (json) => json,
  maxRetries: 2, // default
);
```

`JsonSchema` factories: `object` (with `properties`/`required`), `string` (with `enumValues`), `number`, `integer`, `boolean`, `array(items: …)`, and `fromMap` for raw schema maps. `toPromptString()` renders the schema for prompt injection; `validate(value)` returns an error string or `null`.

Small models sometimes ignore schemas — prefer `int4`-friendly prompts, keep schemas shallow, and rely on the retry loop. For a full intent pipeline from voice, see `LocalPipeline.presets.voiceCommand`.

## Genkit orchestration layer

Genkit on device is an **orchestration layer** — flows, tools, prompt templates, schema-validated output — not an inference runtime. It is a fully optional package; the core never exposes Genkit types.

### Wiring

Set `enableGenkit` and register the plugins in order (Genkit wraps the base adapter by provider):

```dart
final ai = await LocalAI.initialize(
  LocalAIConfig.offlineChat().copyWith(
    llm: const LlmConfig(
      modelId: 'gemma-3n-e2b-it-int4',
      enableGenkit: true,
    ),
  ),
  plugins: const [
    GemmaAdapterPlugin(),   // base LLM first
    GenkitAdapterPlugin(),  // wraps provider 'google-gemma'
  ],
);
```

### The `ai.genkit` escape hatch

With `local_ai_genkit` imported, an extension gives a strongly typed orchestrator (null when not enabled):

```dart
import 'package:local_ai_genkit/local_ai_genkit.dart';

final genkit = ai.genkit; // GenkitOrchestrator?
```

### Flows and tools

```dart
genkit?.defineTool(GenkitTool<Map<String, dynamic>, String>(
  name: 'get_weather',
  description: 'Returns current weather for a city.',
  inputSchema: JsonSchema.object(
    properties: {'city': JsonSchema.string()},
    required: ['city'],
  ),
  handler: (input) async => 'Sunny, 22°C in ${input['city']}',
));

genkit?.defineFlow(GenkitFlow<String, String>(
  name: 'summarize',
  run: (text) async {
    final res = await genkit!.inner.generate(
      LlmRequest.prompt('Summarize: $text'),
    );
    return res.text;
  },
));

final summary = await genkit?.runFlow<String, String>('summarize', longText);

// Prompt templates:
final response = await genkit?.generateFromTemplate(
  PromptTemplate('Translate "{{text}}" to {{language}}.'),
  {'text': 'hello', 'language': 'French'},
);
```

- `defineFlow` / `runFlow` — named, replayable units; inputs/outputs are validated against optional `inputSchema`/`outputSchema` (failures throw `StructuredOutputError`).
- `defineTool` — function-calling primitives advertised to the model with a `JsonSchema` argument spec.
- `generateStructured` — delegates to the inner LLM's retry loop.
- `inner` — direct access to the wrapped `LocalLlm`.

If you don't need orchestration, skip `local_ai_genkit` entirely and use `GemmaLlmAdapter` directly — nothing about Genkit will be in your binary.
