import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_core/local_ai_core.dart';
import 'package:local_ai_genkit/local_ai_genkit.dart';

void main() {
  group('Genkit Skills and MCP Integration', () {
    test('registers MCP plugin tools into GenkitOrchestrator', () async {
      final fakeLlm = FakeLlm();
      await fakeLlm.load(const LlmLoadOptions(modelId: 'test-model'));

      final orchestrator = GenkitOrchestrator(inner: fakeLlm);
      const calc = CalculatorSkill();

      expect(orchestrator.tools.isEmpty, isTrue);

      orchestrator.registerMcpPlugin(calc);

      expect(orchestrator.tools.length, 1);
      final tool = orchestrator.tools.first;
      expect(tool.name, 'calculate');
      expect(tool.description, contains('mathematical expression'));

      // Execute tool through GenkitTool handler
      final result = await tool.handler({'expression': '12 + 34'});
      expect(result, isNotNull);
    });

    test('synchronizes SkillRegistry into GenkitOrchestrator', () async {
      final fakeLlm = FakeLlm();
      await fakeLlm.load(const LlmLoadOptions(modelId: 'test-model'));

      final orchestrator = GenkitOrchestrator(inner: fakeLlm);
      final registry = SkillRegistry(initialPlugins: const [
        CalculatorSkill(),
        TimeSkill(),
        WeatherSkill(),
      ]);

      orchestrator.attachSkillRegistry(registry);

      expect(orchestrator.tools.length, 3);
      final toolNames = orchestrator.tools.map((t) => t.name).toList();
      expect(toolNames, containsAll(['calculate', 'get_current_time', 'get_weather']));
    });

    test('executes multi-turn prompt with skills via GenkitOrchestrator', () async {
      var turnCounter = 0;
      final fakeLlm = FakeLlm(
        handler: (req) async* {
          turnCounter++;
          if (turnCounter == 1) {
            yield const LlmChunk(
              textDelta:
                  '```json\n{"tool": "get_weather", "arguments": {"city": "Tokyo"}}\n```',
            );
          } else {
            yield const LlmChunk(
              textDelta: 'The current weather in Tokyo is pleasant.',
            );
          }
          yield const LlmChunk(isFinal: true, finishReason: LlmFinishReason.stop);
        },
      );
      await fakeLlm.load(const LlmLoadOptions(modelId: 'test-model'));

      final orchestrator = GenkitOrchestrator(inner: fakeLlm);
      final registry = SkillRegistry(initialPlugins: const [WeatherSkill()]);

      final result = await orchestrator.executeWithSkills(
        'What is the weather in Tokyo?',
        registry: registry,
      );

      expect(result.usedTools, isTrue);
      expect(result.toolCalls.first.name, 'get_weather');
      expect(result.toolResults.first.content, contains('Tokyo'));
      expect(result.text, 'The current weather in Tokyo is pleasant.');
    });
  });
}
