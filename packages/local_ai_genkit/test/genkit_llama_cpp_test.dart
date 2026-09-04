import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart' as gk;
import 'package:local_ai_core/local_ai_core.dart';
import 'package:local_ai_genkit/local_ai_genkit.dart';

void main() {
  group('Genkit multi-provider and llama.cpp support', () {
    late AdapterRegistry registry;

    setUp(() {
      registry = AdapterRegistry();
      registry.attachContext(
        const AdapterContext(
          paths: _FakePaths(),
          networkPolicy: _FakeNetworkPolicy(),
        ),
      );
    });

    test('GenkitAdapterPlugin automatically wraps both Gemma and llama.cpp',
        () async {
      // Register fake LLMs for Gemma and llama.cpp
      registry.registerLlm(
        ModelProviders.googleGemma,
        (_) => FakeLlm(responseText: 'from-gemma'),
      );
      registry.registerLlm(
        ModelProviders.llamaCpp,
        (_) => FakeLlm(responseText: 'from-llama-cpp'),
      );

      // GenkitAdapterPlugin with no arguments wraps all registered LLMs
      const plugin = GenkitAdapterPlugin();
      plugin.register(registry);

      // Resolve Gemma
      const gemmaManifest = LocalModelManifest(
        id: 'gemma-test',
        displayName: 'Gemma Test',
        type: ModelType.llm,
        provider: ModelProviders.googleGemma,
        delivery: ModelDelivery.download,
        files: [],
      );
      final gemmaLlm = registry.resolveLlm(gemmaManifest);
      expect(gemmaLlm, isA<GenkitLlmAdapter>());
      expect(gemmaLlm, isA<OrchestratorProvider>());
      await gemmaLlm.load(const LlmLoadOptions(modelId: 'gemma-test'));
      final gemmaResp = await gemmaLlm.generate(LlmRequest.prompt('hi'));
      expect(gemmaResp.text, 'from-gemma');

      // Resolve llama.cpp
      const llamaManifest = LocalModelManifest(
        id: 'qwen-test',
        displayName: 'Qwen Test GGUF',
        type: ModelType.llm,
        provider: ModelProviders.llamaCpp,
        delivery: ModelDelivery.download,
        files: [],
      );
      final llamaLlm = registry.resolveLlm(llamaManifest);
      expect(llamaLlm, isA<GenkitLlmAdapter>());
      expect(llamaLlm, isA<OrchestratorProvider>());
      await llamaLlm.load(const LlmLoadOptions(modelId: 'qwen-test'));
      final llamaResp = await llamaLlm.generate(LlmRequest.prompt('hi'));
      expect(llamaResp.text, 'from-llama-cpp');
    });

    test('GenkitAdapterPlugin supports explicit provider: llamaCpp', () async {
      registry.registerLlm(
        ModelProviders.googleGemma,
        (_) => FakeLlm(responseText: 'raw-gemma'),
      );
      registry.registerLlm(
        ModelProviders.llamaCpp,
        (_) => FakeLlm(responseText: 'wrapped-llama'),
      );

      const plugin = GenkitAdapterPlugin(provider: ModelProviders.llamaCpp);
      plugin.register(registry);

      const gemmaManifest = LocalModelManifest(
        id: 'gemma-test',
        displayName: 'Gemma Test',
        type: ModelType.llm,
        provider: ModelProviders.googleGemma,
        delivery: ModelDelivery.download,
        files: [],
      );
      final gemmaLlm = registry.resolveLlm(gemmaManifest);
      expect(gemmaLlm, isNot(isA<GenkitLlmAdapter>()));

      const llamaManifest = LocalModelManifest(
        id: 'llama-test',
        displayName: 'Llama Test GGUF',
        type: ModelType.llm,
        provider: ModelProviders.llamaCpp,
        delivery: ModelDelivery.download,
        files: [],
      );
      final llamaLlm = registry.resolveLlm(llamaManifest);
      expect(llamaLlm, isA<GenkitLlmAdapter>());
    });

    test('GenkitAdapterPlugin supports explicit providers list', () async {
      registry.registerLlm(
        ModelProviders.googleGemma,
        (_) => FakeLlm(responseText: 'gemma'),
      );
      registry.registerLlm(
        ModelProviders.llamaCpp,
        (_) => FakeLlm(responseText: 'llama'),
      );

      const plugin = GenkitAdapterPlugin(
        providers: [ModelProviders.googleGemma, ModelProviders.llamaCpp],
      );
      plugin.register(registry);

      const llamaManifest = LocalModelManifest(
        id: 'llama-test',
        displayName: 'Llama Test',
        type: ModelType.llm,
        provider: ModelProviders.llamaCpp,
        delivery: ModelDelivery.download,
        files: [],
      );
      final llamaLlm = registry.resolveLlm(llamaManifest);
      expect(llamaLlm, isA<GenkitLlmAdapter>());
    });

    test('Genkit tools, flows and skills work on llama.cpp adapter', () async {
      var turnCounter = 0;
      registry.registerLlm(
        ModelProviders.llamaCpp,
        (_) => FakeLlm(
          handler: (req) async* {
            turnCounter++;
            if (turnCounter == 1) {
              yield const LlmChunk(
                textDelta:
                    '```json\n{"tool": "calculate", "arguments": {"expression": "40 + 2"}}\n```',
              );
            } else {
              yield const LlmChunk(
                textDelta: 'The calculation result is 42.',
              );
            }
            yield const LlmChunk(
                isFinal: true, finishReason: LlmFinishReason.stop);
          },
        ),
      );

      const plugin = GenkitAdapterPlugin();
      plugin.register(registry);

      const llamaManifest = LocalModelManifest(
        id: 'qwen35-08b-gguf',
        displayName: 'Qwen 3.5 0.8B GGUF',
        type: ModelType.llm,
        provider: ModelProviders.llamaCpp,
        delivery: ModelDelivery.download,
        files: [],
      );

      final adapter = registry.resolveLlm(llamaManifest) as GenkitLlmAdapter;
      await adapter.load(const LlmLoadOptions(modelId: 'qwen35-08b-gguf'));
      final orchestrator = adapter.orchestrator;

      // 1. Genkit flow execution
      orchestrator.defineFlow(GenkitFlow<String, String>(
        name: 'summarize',
        run: (input) async => 'Summarized: $input',
      ));
      final flowResult = await orchestrator.runFlow('summarize', 'hello');
      expect(flowResult, 'Summarized: hello');

      // 2. Genkit tool definition
      orchestrator.defineTool(GenkitTool<Map<String, dynamic>, String>(
        name: 'customTool',
        description: 'A custom tool',
        inputSchema: JsonSchema.object(),
        handler: (args) async => 'executed with $args',
      ));
      expect(orchestrator.tools.any((t) => t.name == 'customTool'), isTrue);

      // 3. MCP Skills synchronization and execution
      final skillRegistry = SkillRegistry(
        initialPlugins: const [CalculatorSkill(), WeatherSkill()],
      );
      orchestrator.attachSkillRegistry(skillRegistry);
      expect(orchestrator.tools.any((t) => t.name == 'calculate'), isTrue);
      expect(orchestrator.tools.any((t) => t.name == 'get_weather'), isTrue);

      // 4. Multi-turn execution with skills on llama.cpp adapter
      final result = await orchestrator.executeWithSkills(
        'What is 40 + 2?',
        registry: skillRegistry,
      );

      expect(result.usedTools, isTrue);
      expect(result.toolCalls.first.name, 'calculate');
      expect(result.toolResults.first.content, contains('42'));
      expect(result.text, 'The calculation result is 42.');
    });

    test('registerAsGenkitModel bridges llama.cpp adapter to Google Genkit runtime',
        () async {
      registry.registerLlm(
        ModelProviders.llamaCpp,
        (_) => FakeLlm(responseText: 'Hello from llama.cpp GGUF model!'),
      );

      const plugin = GenkitAdapterPlugin();
      plugin.register(registry);

      const llamaManifest = LocalModelManifest(
        id: 'lfm25-12b-gguf',
        displayName: 'LFM 2.5 1.2B',
        type: ModelType.llm,
        provider: ModelProviders.llamaCpp,
        delivery: ModelDelivery.download,
        files: [],
      );

      final adapter = registry.resolveLlm(llamaManifest) as GenkitLlmAdapter;
      await adapter.load(const LlmLoadOptions(modelId: 'lfm25-12b-gguf'));
      final genkit = gk.Genkit(promptDir: null);
      final model = adapter.registerAsGenkitModel(
        genkit: genkit,
        name: 'localai/llama-cpp',
      );

      final response = await model.call(
        gk.ModelRequest(
          messages: [
            gk.Message(role: gk.Role.user, content: [
              gk.TextPart(text: 'Greet me'),
            ]),
          ],
        ),
      );

      expect(model.name, 'localai/llama-cpp');
      expect(response.message!.content.single.toJson()['text'],
          'Hello from llama.cpp GGUF model!');
      expect(response.finishReason, gk.FinishReason.stop);
    });

    test('throws AdapterNotFoundError if targeted provider has no adapter', () {
      const plugin = GenkitAdapterPlugin(provider: 'unknown-provider');
      expect(
        () => plugin.register(registry),
        throwsA(isA<AdapterNotFoundError>()),
      );
    });
  });
}

class _FakePaths implements LocalStoragePaths {
  const _FakePaths();

  @override
  String get rootDir => '/fake';
  @override
  String get modelsDir => '/fake/models';
  @override
  String modelDir(ModelType type, String modelId) =>
      '/fake/models/${type.name}/$modelId';
  @override
  String get downloadsDir => '/fake/downloads';
  @override
  String downloadDir(String modelId) => '/fake/downloads/$modelId';
  @override
  String get voicesDir => '/fake/voices';
  @override
  String voiceDir(String voiceId) => '/fake/voices/$voiceId';
  @override
  String get manifestsDir => '/fake/manifests';
  @override
  String get cacheDir => '/fake/cache';
  @override
  Future<void> ensureInitialized() async {}
}

class _FakeNetworkPolicy implements NetworkPolicy {
  const _FakeNetworkPolicy();

  @override
  Future<bool> canDownload({bool wifiOnly = true}) async => true;
  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;
  @override
  Stream<NetworkStatus> get onStatusChanged => const Stream.empty();
}
