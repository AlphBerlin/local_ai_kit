import 'package:local_ai_core/local_ai_core.dart';
import 'package:test/test.dart';

void main() {
  group('MCP Tool Definitions and Results', () {
    test('McpToolDefinition serializes and deserializes cleanly', () {
      final tool = McpToolDefinition(
        name: 'custom_search',
        description: 'Searches local documents.',
        inputSchema: JsonSchema.object(
          properties: {
            'query': JsonSchema.string(description: 'Search keyword'),
            'limit': JsonSchema.integer(description: 'Max results'),
          },
          required: ['query'],
        ),
        metadata: {'category': 'search', 'version': '1.0'},
      );

      final json = tool.toJson();
      expect(json['name'], 'custom_search');
      expect(json['description'], 'Searches local documents.');
      expect(json['metadata']['category'], 'search');

      final reconstructed = McpToolDefinition.fromJson(json);
      expect(reconstructed.name, tool.name);
      expect(reconstructed.description, tool.description);
      expect(reconstructed.metadata['category'], 'search');
    });

    test('McpToolResult success and error factories', () {
      final success = McpToolResult.success('calc', '42',
          callId: 'call-1', structuredData: {'val': 42});
      expect(success.isError, isFalse);
      expect(success.content, '42');
      expect(success.callId, 'call-1');
      expect(success.structuredData?['val'], 42);

      final error =
          McpToolResult.error('calc', 'Divide by zero', callId: 'call-2');
      expect(error.isError, isTrue);
      expect(error.content, 'Divide by zero');
      expect(error.callId, 'call-2');
    });
  });

  group('SkillRegistry', () {
    test('registers, enables, disables, and toggles plugins', () {
      final registry = SkillRegistry();
      const calc = CalculatorSkill();
      const time = TimeSkill();

      registry.register(calc);
      registry.register(time);

      expect(registry.allPlugins.length, 2);
      expect(registry.enabledPlugins.length, 2);
      expect(registry.enabledTools.length, 2);
      expect(registry.isEnabled('calculator'), isTrue);
      expect(registry.isEnabled('device_time'), isTrue);

      // Disable calculator
      registry.disable('calculator');
      expect(registry.isEnabled('calculator'), isFalse);
      expect(registry.enabledPlugins.length, 1);
      expect(registry.enabledTools.length, 1);
      expect(registry.enabledTools.first.name, 'get_current_time');

      // Toggle calculator back on
      final newState = registry.toggle('calculator');
      expect(newState, isTrue);
      expect(registry.isEnabled('calculator'), isTrue);
      expect(registry.enabledPlugins.length, 2);

      // Unregister time
      registry.unregister('device_time');
      expect(registry.allPlugins.length, 1);
      expect(registry.getPlugin('device_time'), isNull);
    });

    test('executes tool across registered plugins with argument validation',
        () async {
      final registry = SkillRegistry(initialPlugins: const [
        CalculatorSkill(),
        WeatherSkill(),
      ]);

      // Valid execution
      final result = await registry.executeTool(
        'calculate',
        {'expression': '15 * 4'},
        callId: 'test-1',
      );
      expect(result.isError, isFalse);
      expect(result.content, contains('60'));
      expect(result.callId, 'test-1');

      // Execution with missing parameter
      final invalidResult = await registry.executeTool(
        'get_weather',
        {}, // missing required 'city'
      );
      expect(invalidResult.isError, isTrue);
      expect(invalidResult.content, contains('Invalid arguments'));

      // Execution of disabled tool
      registry.disable('calculator');
      final disabledResult = await registry.executeTool(
        'calculate',
        {'expression': '10 + 10'},
      );
      expect(disabledResult.isError, isTrue);
      expect(
          disabledResult.content, contains('not found in any enabled plugin'));
    });
  });

  group('Builtin Skills', () {
    test('CalculatorSkill computes arithmetic, power, and sqrt', () async {
      const calc = CalculatorSkill();

      final res1 =
          await calc.callTool('calculate', {'expression': '100 + 25 * 4'});
      expect(res1.isError, isFalse);
      expect(res1.structuredData?['result'], 200.0);

      final res2 =
          await calc.callTool('calculate', {'expression': 'sqrt(144) + 2^3'});
      expect(res2.isError, isFalse);
      expect(res2.structuredData?['result'], 20.0);

      final res3 =
          await calc.callTool('calculate', {'expression': '(50 - 10) / 2'});
      expect(res3.isError, isFalse);
      expect(res3.structuredData?['result'], 20.0);
    });

    test('TimeSkill formats local time and iso strings', () async {
      const time = TimeSkill();
      final res = await time.callTool('get_current_time', {'format': 'iso'});
      expect(res.isError, isFalse);
      expect(res.structuredData?['iso'], isNotNull);
      expect(res.structuredData?['weekday'], isNotNull);
    });

    test('DeviceInfoSkill returns device specs', () async {
      const device = DeviceInfoSkill(platformOverride: 'test_platform');
      final res = await device.callTool('get_device_info', {});
      expect(res.isError, isFalse);
      expect(res.structuredData?['platform'], 'test_platform');
      expect(res.structuredData?['offlineReady'], isTrue);
    });

    test('WeatherSkill returns forecast for city', () async {
      const weather = WeatherSkill();
      final res = await weather
          .callTool('get_weather', {'city': 'Berlin', 'unit': 'celsius'});
      expect(res.isError, isFalse);
      expect(res.structuredData?['city'], 'Berlin');
      expect(res.structuredData?['condition'], isNotNull);
    });
  });

  group('SkillExecutor', () {
    test('executes directly when no tools are invoked', () async {
      final registry = SkillRegistry(initialPlugins: const [CalculatorSkill()]);
      final fakeLlm = FakeLlm(
        handler: (req) async* {
          yield const LlmChunk(textDelta: 'Hello, how can I help you today?');
          yield const LlmChunk(
              isFinal: true, finishReason: LlmFinishReason.stop);
        },
      );
      await fakeLlm.load(const LlmLoadOptions(modelId: 'fake'));

      final executor = SkillExecutor(registry: registry);
      final result = await executor.execute(
        llm: fakeLlm,
        prompt: 'Hi!',
      );

      expect(result.usedTools, isFalse);
      expect(result.text, 'Hello, how can I help you today?');
      expect(result.turns, 1);
    });

    test('detects tool call, executes tool, and synthesizes final answer',
        () async {
      final registry = SkillRegistry(initialPlugins: const [CalculatorSkill()]);
      var turnCounter = 0;

      final fakeLlm = FakeLlm(
        handler: (req) async* {
          turnCounter++;
          if (turnCounter == 1) {
            // Model produces a tool call on turn 1
            yield const LlmChunk(
              textDelta:
                  '```json\n{"tool": "calculate", "arguments": {"expression": "25 * 40 + 15"}}\n```',
            );
          } else {
            // Model produces final answer with the tool result on turn 2
            yield const LlmChunk(
              textDelta: 'The result of 25 * 40 + 15 is 1015.',
            );
          }
          yield const LlmChunk(
              isFinal: true, finishReason: LlmFinishReason.stop);
        },
      );
      await fakeLlm.load(const LlmLoadOptions(modelId: 'fake'));

      final executor = SkillExecutor(registry: registry);
      final result = await executor.execute(
        llm: fakeLlm,
        prompt: 'What is 25 * 40 + 15?',
      );

      expect(result.usedTools, isTrue);
      expect(result.toolCalls.length, 1);
      expect(result.toolCalls.first.name, 'calculate');
      expect(result.toolCalls.first.arguments['expression'], '25 * 40 + 15');
      expect(result.toolResults.length, 1);
      expect(result.toolResults.first.content, contains('1015'));
      expect(result.text, 'The result of 25 * 40 + 15 is 1015.');
      expect(result.turns, 2);
    });
  });
}
