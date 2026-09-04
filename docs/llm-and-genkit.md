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

Set `enableGenkit: true` and register base LLM plugins first, followed by `GenkitAdapterPlugin`. By default, `GenkitAdapterPlugin()` automatically discovers and wraps all registered LLM providers (both `google-gemma` and `llama-cpp`):

```dart
final ai = await LocalAI.initialize(
  LocalAIConfig.offlineChat().copyWith(
    llm: const LlmConfig(
      modelId: 'qwen2.5-0.5b-instruct-gguf', // or 'gemma-3n-e2b-it-int4'
      enableGenkit: true,
    ),
  ),
  plugins: const [
    GemmaAdapterPlugin(),     // provider 'google-gemma'
    LlamaCppAdapterPlugin(),  // provider 'llama-cpp'
    GenkitAdapterPlugin(),    // automatically wraps all registered LLMs
  ],
);
```

You can also target specific providers explicitly:
```dart
// Wrap only llama.cpp:
GenkitAdapterPlugin(provider: ModelProviders.llamaCpp)

// Or wrap a specific list of providers:
GenkitAdapterPlugin(providers: [
  ModelProviders.googleGemma,
  ModelProviders.llamaCpp,
])
```

### The `ai.genkit` escape hatch

With `local_ai_genkit` imported, an extension gives a strongly typed orchestrator (null when not enabled):

```dart
import 'package:local_ai_genkit/local_ai_genkit.dart';

final genkit = ai.genkit; // GenkitOrchestrator?
```

For direct integration with the upstream Genkit runtime, register the adapter
with a caller-owned `Genkit` instance. The bridge targets Genkit `0.14.x`,
forwards text-only messages, sampling configuration and streamed text chunks:

```dart
import 'package:genkit/genkit.dart';
import 'package:local_ai_genkit/local_ai_genkit.dart';

final runtime = Genkit(promptDir: null);
final model = GenkitLlmAdapter(inner: ai.llm!).registerAsGenkitModel(
  genkit: runtime,
  name: 'localai/inner',
);

final response = await model.call(
  ModelRequest(
    messages: [
      Message(role: Role.user, content: [TextPart(text: 'Say hello.')]),
    ],
  ),
);
```

Media, tool-call and other non-text message parts are rejected explicitly by
the bridge because `LocalLlm` currently exposes a text-only contract.

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

## MCP plugins and skills

`local_ai_core` ships a small Model Context Protocol (MCP)-style plugin
architecture for giving any `LocalLlm` callable tools, independent of Genkit:

- `LocalMcpPlugin` — the base contract: a namespaced `name`, `description`,
  a list of `McpToolDefinition`s, and `callTool(name, arguments)`.
- `LocalSkill` — a `LocalMcpPlugin` that can also contribute a
  `systemPromptSnippet` telling the model how/when to use its tools.
  `CustomSkill` builds one inline from a tool list + handler function.
- Four built-in skills ship in `local_ai_core`: `CalculatorSkill`,
  `TimeSkill`, `DeviceInfoSkill`, `WeatherSkill`.
- `SkillRegistry` — registers plugins/skills and tracks which are enabled;
  exposes `enabledTools` (aggregated across all enabled plugins).
- `SkillExecutor` — runs a prompt against any `LocalLlm`, detecting tool
  calls in the model's output, executing them via the registry, and
  feeding results back for up to `maxTurns` round trips before returning
  the final `SkillExecutionResult` (including which tools were called).

```dart
final registry = SkillRegistry(initialPlugins: [CalculatorSkill(), TimeSkill()]);
final executor = SkillExecutor(registry: registry);

final result = await executor.execute(
  llm: someLocalLlm,
  prompt: 'What is 12 * 7, and what time is it?',
);
print(result.text);       // final natural-language answer
print(result.usedTools);  // true if any tool was invoked
```

`local_ai_genkit` bridges this into `GenkitOrchestrator` via the
`GenkitSkillsExtension`:

```dart
genkitOrchestrator.attachSkillRegistry(registry); // or registerSkill(...) one at a time

final result = await genkitOrchestrator.executeWithSkills(
  'What is 12 * 7?',
  registry: registry,
);
```

`registerMcpPlugin`/`registerSkill` turn each tool into a `GenkitTool`, and
`attachSkillRegistry` syncs every currently-enabled plugin in one call —
useful when skills are toggled at runtime (e.g. a settings screen) and you
want Genkit's tool list to stay in sync.
