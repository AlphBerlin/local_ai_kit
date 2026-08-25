/// Model Context Protocol (MCP) data models and tool definitions.
library;

import '../llm/json_schema.dart';

/// Definition of an MCP tool exposed by a plugin or skill.
class McpToolDefinition {
  const McpToolDefinition({
    required this.name,
    required this.description,
    required this.inputSchema,
    this.metadata = const {},
  });

  /// Name of the tool (e.g. 'calculator', 'get_current_time').
  final String name;

  /// Human- and LLM-readable description of what the tool does.
  final String description;

  /// JSON Schema describing the input arguments expected by this tool.
  final JsonSchema inputSchema;

  /// Optional extra metadata for the tool (e.g. tags, version, categories).
  final Map<String, dynamic> metadata;

  /// Converts this definition to a standard MCP JSON representation.
  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'inputSchema': inputSchema.toMap(),
        if (metadata.isNotEmpty) 'metadata': metadata,
      };

  /// Constructs a definition from an MCP JSON map.
  factory McpToolDefinition.fromJson(Map<String, dynamic> json) {
    return McpToolDefinition(
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      inputSchema: JsonSchema.fromMap(
        json['inputSchema'] as Map<String, dynamic>? ?? const {},
      ),
      metadata: json['metadata'] as Map<String, dynamic>? ?? const {},
    );
  }

  @override
  String toString() => 'McpToolDefinition(name: $name, description: $description)';
}

/// A request to invoke a specific tool with arguments.
class McpToolCall {
  const McpToolCall({
    required this.name,
    this.arguments = const {},
    this.id,
  });

  /// The name of the target tool to invoke.
  final String name;

  /// Arguments provided for the tool execution.
  final Map<String, dynamic> arguments;

  /// Optional call identifier (for correlating multi-tool calls).
  final String? id;

  Map<String, dynamic> toJson() => {
        'name': name,
        'arguments': arguments,
        if (id != null) 'id': id,
      };

  factory McpToolCall.fromJson(Map<String, dynamic> json) {
    return McpToolCall(
      name: json['name'] as String? ?? json['tool'] as String? ?? '',
      arguments: json['arguments'] as Map<String, dynamic>? ??
          json['parameters'] as Map<String, dynamic>? ??
          const {},
      id: json['id'] as String?,
    );
  }

  @override
  String toString() => 'McpToolCall(name: $name, arguments: $arguments, id: $id)';
}

/// The result produced by invoking an MCP tool.
class McpToolResult {
  const McpToolResult({
    required this.toolName,
    required this.content,
    this.isError = false,
    this.callId,
    this.structuredData,
  });

  /// Convenience factory for a successful text result.
  factory McpToolResult.success(
    String toolName,
    String content, {
    String? callId,
    Map<String, dynamic>? structuredData,
  }) =>
      McpToolResult(
        toolName: toolName,
        content: content,
        isError: false,
        callId: callId,
        structuredData: structuredData,
      );

  /// Convenience factory for an error result.
  factory McpToolResult.error(
    String toolName,
    String errorMessage, {
    String? callId,
  }) =>
      McpToolResult(
        toolName: toolName,
        content: errorMessage,
        isError: true,
        callId: callId,
      );

  /// The name of the tool that generated this result.
  final String toolName;

  /// Text output / summary of the tool execution.
  final String content;

  /// Whether the tool execution resulted in an error.
  final bool isError;

  /// Optional call identifier.
  final String? callId;

  /// Optional structured JSON object resulting from the call.
  final Map<String, dynamic>? structuredData;

  Map<String, dynamic> toJson() => {
        'toolName': toolName,
        'content': content,
        'isError': isError,
        if (callId != null) 'callId': callId,
        if (structuredData != null) 'structuredData': structuredData,
      };

  @override
  String toString() =>
      'McpToolResult(toolName: $toolName, content: $content, isError: $isError)';
}
