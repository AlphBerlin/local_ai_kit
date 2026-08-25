/// Extensions and bridges connecting MCP plugins and Skills with Genkit orchestration.
library;

import 'package:local_ai_core/local_ai_core.dart';
import 'genkit_orchestrator.dart';

extension GenkitSkillsExtension on GenkitOrchestrator {
  /// Registers all tools from an [McpPlugin] into this [GenkitOrchestrator] as [GenkitTool]s.
  void registerMcpPlugin(LocalMcpPlugin plugin) {
    for (final tool in plugin.tools) {
      defineTool(GenkitTool<Map<String, dynamic>, Object?>(
        name: tool.name,
        description: tool.description,
        inputSchema: tool.inputSchema,
        handler: (input) async {
          final result = await plugin.callTool(tool.name, input);
          return result.structuredData ?? result.content;
        },
      ));
    }
  }

  /// Registers a [LocalSkill] into this [GenkitOrchestrator].
  void registerSkill(LocalSkill skill) {
    registerMcpPlugin(skill);
  }

  /// Synchronizes all currently enabled tools from a [SkillRegistry] into this orchestrator.
  void attachSkillRegistry(SkillRegistry registry) {
    for (final plugin in registry.enabledPlugins) {
      registerMcpPlugin(plugin);
    }
  }

  /// Runs a prompt through [SkillExecutor] using this orchestrator's inner LLM.
  Future<SkillExecutionResult> executeWithSkills(
    String prompt, {
    required SkillRegistry registry,
    String? systemPrompt,
    double? temperature,
    int? maxTokens,
  }) {
    final executor = SkillExecutor(registry: registry);
    return executor.execute(
      llm: inner,
      prompt: prompt,
      baseSystemPrompt: systemPrompt,
      temperature: temperature,
      maxTokens: maxTokens,
    );
  }
}
