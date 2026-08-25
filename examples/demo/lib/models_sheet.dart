import 'package:flutter/material.dart';
import 'package:local_ai_kit/local_ai_kit.dart';
import 'logger.dart';

class ModelsSheet extends StatefulWidget {
  const ModelsSheet({
    super.key,
    required this.ai,
    required this.selectedModelId,
    required this.onSelectModel,
  });

  final LocalAI? ai;
  final String selectedModelId;
  final void Function(String modelId) onSelectModel;

  static void show(
    BuildContext context, {
    required LocalAI? ai,
    required String selectedModelId,
    required void Function(String modelId) onSelectModel,
  }) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.8,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => ModelsSheet(
          ai: ai,
          selectedModelId: selectedModelId,
          onSelectModel: onSelectModel,
        ),
      ),
    );
  }

  @override
  State<ModelsSheet> createState() => _ModelsSheetState();
}

class _ModelsSheetState extends State<ModelsSheet> {
  final Map<String, ModelStatus> _modelStatuses = {};
  final Map<String, double> _downloadProgress = {};
  List<LocalModelManifest> _models = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadCatalog();
  }

  Future<void> _loadCatalog() async {
    final ai = widget.ai;
    if (ai == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final list = await ai.catalog.list();
      setState(() {
        _models = list;
        _loading = false;
      });

      for (final m in list) {
        ai.models.getStatus(m.id).then((status) {
          if (mounted) setState(() => _modelStatuses[m.id] = status);
        }).catchError((_) {});

        ai.models.watchStatus(m.id).listen((status) {
          if (mounted) setState(() => _modelStatuses[m.id] = status);
        });

        ai.models.downloadProgress(m.id).listen((progress) {
          if (mounted) {
            setState(() => _downloadProgress[m.id] = progress.fraction);
          }
        });
      }
    } catch (e, st) {
      AppLogger.error('MODELS', 'Failed to load model catalog', error: e, stackTrace: st);
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _installModel(LocalModelManifest manifest) async {
    final ai = widget.ai;
    if (ai == null) return;
    AppLogger.info('DOWNLOAD', 'Starting install for model: ${manifest.id}');
    try {
      setState(() {
        _downloadProgress[manifest.id] = 0.01;
      });
      await ai.models.install(manifest.id);
      AppLogger.success('DOWNLOAD', 'Model installed successfully: ${manifest.id}');
      final status = await ai.models.getStatus(manifest.id);
      if (mounted) {
        setState(() {
          _modelStatuses[manifest.id] = status;
          _downloadProgress.remove(manifest.id);
        });
      }
    } catch (e, st) {
      AppLogger.error('DOWNLOAD', 'Install failed for ${manifest.id}: $e', error: e, stackTrace: st);
      if (mounted) {
        setState(() => _downloadProgress.remove(manifest.id));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Download failed: $e\n(Tip: Switch to Mock Mode for instant offline testing)'),
            backgroundColor: Theme.of(context).colorScheme.error,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  Future<void> _uninstallModel(String modelId) async {
    final ai = widget.ai;
    if (ai == null) return;
    try {
      AppLogger.info('MODELS', 'Removing model: $modelId');
      await ai.models.remove(modelId);
      final status = await ai.models.getStatus(modelId);
      if (mounted) setState(() => _modelStatuses[modelId] = status);
      AppLogger.success('MODELS', 'Model removed: $modelId');
    } catch (e, st) {
      AppLogger.error('MODELS', 'Failed to remove model $modelId', error: e, stackTrace: st);
    }
  }

  String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  IconData _typeIcon(ModelType type) {
    switch (type) {
      case ModelType.llm:
        return Icons.psychology;
      case ModelType.stt:
        return Icons.record_voice_over;
      case ModelType.tts:
        return Icons.volume_up;
      case ModelType.vad:
        return Icons.graphic_eq;
      case ModelType.embedding:
        return Icons.hub;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        // Handle bar
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        // Header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.hub_outlined),
              const SizedBox(width: 8),
              Text(
                'Model Catalog & Downloader',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh catalog',
                onPressed: _loadCatalog,
              ),
            ],
          ),
        ),
        const Divider(height: 8),
        // Models List
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  itemCount: _models.length,
                  itemBuilder: (context, index) {
                    final model = _models[index];
                    final isSelected = model.id == widget.selectedModelId;
                    final status = _modelStatuses[model.id];
                    final progress = _downloadProgress[model.id];
                    final isInstalled = status?.isInstalled ?? false;
                    final isDownloading = progress != null;

                    return Card(
                      elevation: isSelected ? 2 : 0,
                      margin: const EdgeInsets.only(bottom: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(
                          color: isSelected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outlineVariant,
                          width: isSelected ? 2 : 1,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                CircleAvatar(
                                  radius: 16,
                                  backgroundColor: theme.colorScheme.primaryContainer,
                                  child: Icon(_typeIcon(model.type), size: 18, color: theme.colorScheme.primary),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Text(
                                            model.displayName ?? model.id,
                                            style: theme.textTheme.titleSmall?.copyWith(
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          if (isSelected) ...[
                                            const SizedBox(width: 6),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: theme.colorScheme.primary,
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: Text(
                                                'ACTIVE',
                                                style: TextStyle(
                                                  fontSize: 9,
                                                  fontWeight: FontWeight.bold,
                                                  color: theme.colorScheme.onPrimary,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                      Text(
                                        '${model.id} • ${model.provider} • ${_formatSize(model.totalSizeBytes)}',
                                        style: theme.textTheme.bodySmall?.copyWith(
                                          color: theme.colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            if (model.description != null && model.description!.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(model.description!, style: theme.textTheme.bodySmall),
                            ],
                            if (isDownloading) ...[
                              const SizedBox(height: 8),
                              LinearProgressIndicator(value: progress > 0 ? progress : null),
                              const SizedBox(height: 4),
                              Text(
                                'Downloading ${(progress * 100).toStringAsFixed(0)}%…',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.primary,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                if (!isSelected)
                                  TextButton.icon(
                                    onPressed: () {
                                      widget.onSelectModel(model.id);
                                    },
                                    icon: const Icon(Icons.check, size: 16),
                                    label: const Text('Select'),
                                  ),
                                const SizedBox(width: 8),
                                if (isInstalled)
                                  OutlinedButton.icon(
                                    onPressed: () => _uninstallModel(model.id),
                                    icon: const Icon(Icons.delete_outline, size: 16),
                                    label: const Text('Remove'),
                                  )
                                else
                                  FilledButton.tonalIcon(
                                    onPressed: isDownloading
                                        ? null
                                        : () => _installModel(model),
                                    icon: const Icon(Icons.download, size: 16),
                                    label: Text(isDownloading ? 'Downloading…' : 'Download'),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
