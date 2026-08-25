/// Registry for managing MCP plugins and skills.
library;

import 'dart:async';
import '../errors/local_ai_error.dart';
import 'mcp_plugin.dart';
import 'mcp_types.dart';

/// Registry that manages MCP plugins and skills, controlling their
/// registration, runtime enablement, and tool dispatching.
class SkillRegistry {
  SkillRegistry({List<LocalMcpPlugin> initialPlugins = const []}) {
    for (final plugin in initialPlugins) {
      register(plugin);
    }
  }

  final Map<String, LocalMcpPlugin> _plugins = {};
  final Set<String> _disabledPlugins = {};

  /// All registered plugins (both enabled and disabled).
  List<LocalMcpPlugin> get allPlugins => List.unmodifiable(_plugins.values);

  /// Currently enabled plugins.
  List<LocalMcpPlugin> get enabledPlugins => List.unmodifiable(
        _plugins.values.where((p) => !_disabledPlugins.contains(p.name)),
      );

  /// Currently enabled skills.
  List<LocalSkill> get enabledSkills => List.unmodifiable(
        enabledPlugins.whereType<LocalSkill>(),
      );

  /// Aggregated list of all tools from currently enabled plugins.
  List<McpToolDefinition> get enabledTools {
    final tools = <McpToolDefinition>[];
    for (final plugin in enabledPlugins) {
      tools.addAll(plugin.tools);
    }
    return List.unmodifiable(tools);
  }

  /// Registers an MCP plugin or skill.
  ///
  /// If a plugin with the same name already exists, it is replaced.
  void register(LocalMcpPlugin plugin, {bool enabled = true}) {
    _plugins[plugin.name] = plugin;
    if (enabled) {
      _disabledPlugins.remove(plugin.name);
    } else {
      _disabledPlugins.add(plugin.name);
    }
  }

  /// Unregisters a plugin by name.
  void unregister(String pluginName) {
    _plugins.remove(pluginName);
    _disabledPlugins.remove(pluginName);
  }

  /// Enables a registered plugin.
  void enable(String pluginName) {
    if (!_plugins.containsKey(pluginName)) {
      throw InvalidStateError('Plugin "$pluginName" is not registered.');
    }
    _disabledPlugins.remove(pluginName);
  }

  /// Disables a registered plugin.
  void disable(String pluginName) {
    if (!_plugins.containsKey(pluginName)) {
      throw InvalidStateError('Plugin "$pluginName" is not registered.');
    }
    _disabledPlugins.add(pluginName);
  }

  /// Toggles the enablement of a plugin and returns the new enabled state.
  bool toggle(String pluginName) {
    if (isEnabled(pluginName)) {
      disable(pluginName);
      return false;
    } else {
      enable(pluginName);
      return true;
    }
  }

  /// Whether the specified plugin is registered and enabled.
  bool isEnabled(String pluginName) {
    return _plugins.containsKey(pluginName) &&
        !_disabledPlugins.contains(pluginName);
  }

  /// Looks up a plugin by name.
  LocalMcpPlugin? getPlugin(String name) => _plugins[name];

  /// Finds the tool definition and owner plugin for a given tool name.
  (McpToolDefinition, LocalMcpPlugin)? findTool(String toolName) {
    for (final plugin in enabledPlugins) {
      for (final tool in plugin.tools) {
        if (tool.name == toolName) {
          return (tool, plugin);
        }
      }
    }
    return null;
  }

  /// Executes a tool across all enabled plugins.
  ///
  /// Validates input arguments against the tool's [inputSchema] before calling.
  Future<McpToolResult> executeTool(
    String toolName,
    Map<String, dynamic> arguments, {
    String? callId,
  }) async {
    final match = findTool(toolName);
    if (match == null) {
      return McpToolResult.error(
        toolName,
        'Tool "$toolName" was not found in any enabled plugin.',
        callId: callId,
      );
    }

    final (tool, plugin) = match;
    final validationError = tool.inputSchema.validate(arguments);
    if (validationError != null) {
      return McpToolResult.error(
        toolName,
        'Invalid arguments for tool "$toolName": $validationError',
        callId: callId,
      );
    }

    try {
      final result = await plugin.callTool(toolName, arguments);
      return callId != null && result.callId == null
          ? McpToolResult(
              toolName: result.toolName,
              content: result.content,
              isError: result.isError,
              callId: callId,
              structuredData: result.structuredData,
            )
          : result;
    } catch (e) {
      return McpToolResult.error(
        toolName,
        'Error executing tool "$toolName": $e',
        callId: callId,
      );
    }
  }
}
