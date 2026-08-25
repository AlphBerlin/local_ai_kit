/// Execution engine that drives tool calling and skill resolution with any LocalLlm.
library;

import 'dart:async';
import 'dart:convert';
import '../llm/llm_request.dart';
import '../llm/local_llm.dart';
import '../llm/structured_output.dart';
import 'mcp_types.dart';
import 'skill_registry.dart';

/// Result of executing a prompt with skills / MCP tools enabled.
class SkillExecutionResult {
  const SkillExecutionResult({
    required this.prompt,
    required this.response,
    this.toolCalls = const [],
    this.toolResults = const [],
    this.turns = 1,
  });

  /// The original user prompt.
  final String prompt;

  /// The final synthesized LLM response.
  final LlmResponse response;

  /// The sequence of MCP tool calls detected and executed.
  final List<McpToolCall> toolCalls;

  /// The sequence of results produced by the executed tools.
  final List<McpToolResult> toolResults;

  /// Number of model/tool turns taken.
  final int turns;

  /// Convenience getter for the final text output.
  String get text => response.text;

  /// Whether any tools were invoked during this execution.
  bool get usedTools => toolCalls.isNotEmpty;

  @override
  String toString() =>
      'SkillExecutionResult(toolCalls: ${toolCalls.length}, text: $text)';
}

/// Executes prompts with active MCP skills and tools against any [LocalLlm].
///
/// Handles tool definition formatting, tool call detection, tool execution,
/// and feedback loops back into the LLM context.
class SkillExecutor {
  const SkillExecutor({
    required this.registry,
    this.maxTurns = 4,
  });

  /// The registry providing active plugins and tool dispatch.
  final SkillRegistry registry;

  /// Maximum round-trip turns (tool call -> result -> next action) allowed.
  final int maxTurns;

  /// Executes [prompt] against [llm], using any enabled tools in [registry].
  Future<SkillExecutionResult> execute({
    required LocalLlm llm,
    required String prompt,
    String? baseSystemPrompt,
    double? temperature,
    int? maxTokens,
  }) async {
    final tools = registry.enabledTools;
    if (tools.isEmpty) {
      // No tools active; execute standard LLM call directly.
      final response = await llm.generate(LlmRequest.prompt(
        prompt,
        systemPrompt: baseSystemPrompt,
        temperature: temperature,
        maxTokens: maxTokens,
      ));
      return SkillExecutionResult(prompt: prompt, response: response);
    }

    final systemPrompt = _buildSystemPrompt(baseSystemPrompt, tools);
    final executedCalls = <McpToolCall>[];
    final executedResults = <McpToolResult>[];

    final messages = <LlmMessage>[
      if (systemPrompt.isNotEmpty) LlmMessage.system(systemPrompt),
      LlmMessage.user(prompt),
    ];

    LlmResponse? lastResponse;

    for (var turn = 0; turn < maxTurns; turn++) {
      final response = await llm.generate(LlmRequest(
        messages: messages,
        temperature: temperature ?? 0.7,
        maxTokens: maxTokens,
      ));
      lastResponse = response;

      final toolCall = _extractToolCall(response.text);
      if (toolCall == null) {
        // Model provided a direct natural language response.
        return SkillExecutionResult(
          prompt: prompt,
          response: response,
          toolCalls: executedCalls,
          toolResults: executedResults,
          turns: turn + 1,
        );
      }

      // Record call
      executedCalls.add(toolCall);
      messages.add(LlmMessage.assistant(response.text));

      // Execute tool
      final toolResult = await registry.executeTool(
        toolCall.name,
        toolCall.arguments,
        callId: toolCall.id,
      );
      executedResults.add(toolResult);

      // Feed tool result back to the model
      messages.add(LlmMessage.user(
        'TOOL_RESULT for "${toolResult.toolName}":\n${toolResult.content}\n\n'
        'Use this information to answer the user request or provide next steps.',
      ));
    }

    return SkillExecutionResult(
      prompt: prompt,
      response: lastResponse ??
          const LlmResponse(
            text: '',
            finishReason: LlmFinishReason.length,
          ),
      toolCalls: executedCalls,
      toolResults: executedResults,
      turns: maxTurns,
    );
  }

  /// Builds the system prompt describing available tools and invocation format.
  String _buildSystemPrompt(
    String? basePrompt,
    List<McpToolDefinition> tools,
  ) {
    final buffer = StringBuffer();
    if (basePrompt != null && basePrompt.trim().isNotEmpty) {
      buffer.writeln(basePrompt.trim());
      buffer.writeln();
    }

    // Include skill-specific snippets if present
    for (final skill in registry.enabledSkills) {
      final snippet = skill.systemPromptSnippet;
      if (snippet != null && snippet.isNotEmpty) {
        buffer.writeln(snippet);
        buffer.writeln();
      }
    }

    buffer.writeln('## AVAILABLE TOOLS');
    buffer.writeln(
      'You have access to the following tools to help satisfy the user request:',
    );
    buffer.writeln();

    for (final tool in tools) {
      buffer.writeln('### Tool: ${tool.name}');
      buffer.writeln('Description: ${tool.description}');
      buffer.writeln('Parameters Schema:');
      buffer.writeln(tool.inputSchema.toPromptString());
      buffer.writeln();
    }

    buffer.writeln('## INSTRUCTIONS FOR TOOL CALLING');
    buffer.writeln(
      '1. If you need to use a tool, respond ONLY with a JSON object in this format:\n'
      '```json\n'
      '{\n'
      '  "tool": "<tool_name>",\n'
      '  "arguments": { "<arg_name>": <value> }\n'
      '}\n'
      '```\n'
      '2. Do not include commentary when calling a tool.\n'
      '3. When you receive the TOOL_RESULT, formulate a helpful, concise final answer for the user without repeating the raw JSON.',
    );

    return buffer.toString();
  }

  /// Parses text to identify whether the model requested a tool invocation.
  McpToolCall? _extractToolCall(String text) {
    final jsonVal = StructuredOutputSupport.extractJson(text);
    if (jsonVal is Map<String, dynamic>) {
      final toolName = jsonVal['tool'] as String? ?? jsonVal['name'] as String?;
      if (toolName != null && toolName.isNotEmpty) {
        final args = jsonVal['arguments'] as Map<String, dynamic>? ??
            jsonVal['parameters'] as Map<String, dynamic>? ??
            const {};
        final id = jsonVal['id'] as String?;
        return McpToolCall(name: toolName, arguments: args, id: id);
      }
    }

    // Secondary heuristic: check for TOOL_CALL: name({...})
    final toolCallMatch =
        RegExp(r'TOOL_CALL:\s*([a-zA-Z0-9_\-]+)\s*\(([\s\S]*?)\)')
            .firstMatch(text);
    if (toolCallMatch != null) {
      final name = toolCallMatch.group(1)!;
      final rawArgs = toolCallMatch.group(2)!.trim();
      Map<String, dynamic> args = {};
      if (rawArgs.isNotEmpty) {
        try {
          final decoded = jsonDecode(rawArgs);
          if (decoded is Map<String, dynamic>) {
            args = decoded;
          }
        } catch (_) {}
      }
      return McpToolCall(name: name, arguments: args);
    }

    return null;
  }
}
