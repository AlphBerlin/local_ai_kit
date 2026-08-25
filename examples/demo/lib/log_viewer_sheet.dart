import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'logger.dart';

class LogViewerSheet extends StatefulWidget {
  const LogViewerSheet({super.key});

  static void show(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => const LogViewerSheet(),
      ),
    );
  }

  @override
  State<LogViewerSheet> createState() => _LogViewerSheetState();
}

class _LogViewerSheetState extends State<LogViewerSheet> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  LogLevel? _selectedLevel;
  String _searchQuery = '';
  bool _autoScroll = true;

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_autoScroll && _scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  void _copyAllLogs(List<LogEntry> logs) {
    final buffer = StringBuffer();
    for (final l in logs) {
      buffer.writeln(
          '[${l.formatTime()}] [${l.level.name.toUpperCase()}] [${l.tag}] ${l.message}');
      if (l.details != null) {
        buffer.writeln('  Details: ${l.details}');
      }
    }
    Clipboard.setData(ClipboardData(text: buffer.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied ${logs.length} log lines to clipboard')),
    );
  }

  Color _levelColor(LogLevel level, BuildContext context) {
    switch (level) {
      case LogLevel.info:
        return Colors.blue.shade600;
      case LogLevel.success:
        return Colors.green.shade600;
      case LogLevel.warning:
        return Colors.orange.shade700;
      case LogLevel.error:
        return Theme.of(context).colorScheme.error;
    }
  }

  IconData _levelIcon(LogLevel level) {
    switch (level) {
      case LogLevel.info:
        return Icons.info_outline;
      case LogLevel.success:
        return Icons.check_circle_outline;
      case LogLevel.warning:
        return Icons.warning_amber_rounded;
      case LogLevel.error:
        return Icons.error_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return StreamBuilder<List<LogEntry>>(
      stream: AppLogger.stream,
      initialData: AppLogger.logs,
      builder: (context, snapshot) {
        final allLogs = snapshot.data ?? [];
        final filteredLogs = allLogs.where((l) {
          if (_selectedLevel != null && l.level != _selectedLevel) return false;
          if (_searchQuery.isNotEmpty) {
            final query = _searchQuery.toLowerCase();
            final matchMessage = l.message.toLowerCase().contains(query);
            final matchTag = l.tag.toLowerCase().contains(query);
            final matchDetails =
                l.details?.toLowerCase().contains(query) ?? false;
            return matchMessage || matchTag || matchDetails;
          }
          return true;
        }).toList();

        _scrollToBottom();

        return Column(
          children: [
            // Handle bar
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color:
                      theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // Header Row
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  const Icon(Icons.terminal, size: 22),
                  const SizedBox(width: 8),
                  Text(
                    'Debug Log Viewer (${filteredLogs.length}/${allLogs.length})',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Copy all logs',
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () => _copyAllLogs(filteredLogs),
                  ),
                  IconButton(
                    tooltip: 'Clear logs',
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: () {
                      AppLogger.clear();
                      setState(() {});
                    },
                  ),
                  IconButton(
                    tooltip: _autoScroll ? 'Auto-scroll ON' : 'Auto-scroll OFF',
                    icon: Icon(
                      _autoScroll ? Icons.vertical_align_bottom : Icons.pause,
                      color: _autoScroll ? theme.colorScheme.primary : null,
                      size: 18,
                    ),
                    onPressed: () {
                      setState(() => _autoScroll = !_autoScroll);
                    },
                  ),
                ],
              ),
            ),
            // Filter and Search Row
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 36,
                      child: TextField(
                        controller: _searchController,
                        style: const TextStyle(fontSize: 13),
                        decoration: InputDecoration(
                          hintText: 'Filter logs…',
                          prefixIcon: const Icon(Icons.search, size: 16),
                          suffixIcon: _searchQuery.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 14),
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() => _searchQuery = '');
                                  },
                                )
                              : null,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 0),
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                        onChanged: (val) => setState(() => _searchQuery = val),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SegmentedButton<LogLevel?>(
                    segments: const [
                      ButtonSegment(value: null, label: Text('All')),
                      ButtonSegment(value: LogLevel.info, label: Text('Info')),
                      ButtonSegment(
                          value: LogLevel.warning, label: Text('Warn')),
                      ButtonSegment(
                          value: LogLevel.error, label: Text('Error')),
                    ],
                    selected: {_selectedLevel},
                    onSelectionChanged: (set) =>
                        setState(() => _selectedLevel = set.first),
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 12),
            // Logs List
            Expanded(
              child: filteredLogs.isEmpty
                  ? Center(
                      child: Text(
                        'No logs recorded yet.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      itemCount: filteredLogs.length,
                      itemBuilder: (context, index) {
                        final entry = filteredLogs[index];
                        final color = _levelColor(entry.level, context);
                        final hasDetails =
                            entry.details != null && entry.details!.isNotEmpty;

                        return Container(
                          margin: const EdgeInsets.only(bottom: 4),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(6),
                            border:
                                Border.all(color: color.withValues(alpha: 0.2)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(_levelIcon(entry.level),
                                      size: 14, color: color),
                                  const SizedBox(width: 6),
                                  Text(
                                    entry.formatTime(),
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 11,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 5, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: color.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      entry.tag,
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: color,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              SelectableText(
                                entry.message,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                ),
                              ),
                              if (hasDetails) ...[
                                const SizedBox(height: 4),
                                Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: theme
                                        .colorScheme.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: SelectableText(
                                    entry.details!,
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 11,
                                      color: theme.colorScheme.error,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
