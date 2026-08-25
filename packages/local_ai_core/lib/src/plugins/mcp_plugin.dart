/// MCP plugin and skill abstractions (architecture §3.5, §7.1).
library;

import 'dart:async';
import 'mcp_types.dart';

/// Abstract interface for a Model Context Protocol (MCP) plugin.
///
/// Implementations can provide tools locally in-process or bridge to an
/// external MCP server.
abstract interface class LocalMcpPlugin {
  /// Unique identifier / namespace for this plugin (e.g. 'calculator', 'system').
  String get name;

  /// Human-readable description of what this plugin provides.
  String get description;

  /// List of tools exposed by this plugin.
  List<McpToolDefinition> get tools;

  /// Executes an exposed tool by name with the given arguments.
  Future<McpToolResult> callTool(String name, Map<String, dynamic> arguments);
}

/// A high-level skill module that equips LLMs with specific abilities and context.
///
/// A [LocalSkill] provides both callable tools and optional prompt guidance
/// ([systemPromptSnippet]) to help the LLM know how and when to use its tools.
abstract class LocalSkill implements LocalMcpPlugin {
  const LocalSkill();

  /// Extra prompt instructions or guidelines injected when this skill is active.
  String? get systemPromptSnippet => null;
}

/// A flexible in-process skill defined with a tool list and execution handler.
class CustomSkill extends LocalSkill {
  CustomSkill({
    required this.name,
    required this.description,
    required this.tools,
    required this.handler,
    this.systemPromptSnippet,
  });

  @override
  final String name;

  @override
  final String description;

  @override
  final List<McpToolDefinition> tools;

  @override
  final String? systemPromptSnippet;

  final Future<McpToolResult> Function(
    String name,
    Map<String, dynamic> arguments,
  ) handler;

  @override
  Future<McpToolResult> callTool(String name, Map<String, dynamic> arguments) =>
      handler(name, arguments);
}
