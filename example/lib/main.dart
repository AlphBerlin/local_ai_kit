/// LocalAI Kit interactive demo:
/// - Fast on-device LLMs: Qwen 2.5 0.5B (Fast 546MB), DeepSeek R1 1.5B, SmolLM2 360M, Gemma 3n
/// - Real-time model downloader with live MB / speed / ETA tracking
/// - Embedded live Debug Log Viewer directly on the main screen
/// - Full-duplex voice chat session (Mic -> VAD -> STT -> LLM -> TTS)
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_ai_gemma/local_ai_gemma.dart';
import 'package:local_ai_kit/local_ai_kit.dart';
import 'package:local_ai_sherpa/local_ai_sherpa.dart';

import 'log_viewer_sheet.dart';
import 'logger.dart';
import 'models_sheet.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await FlutterGemma.initialize();
  } catch (_) {}
  AppLogger.info('BOOTSTRAP', 'LocalAI Kit demo application starting…');
  runApp(const LocalAIDemoApp());
}

class LocalAIDemoApp extends StatelessWidget {
  const LocalAIDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LocalAI Kit Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6750A4),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFD0BCFF),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: const DemoHomePage(),
    );
  }
}

class DemoHomePage extends StatefulWidget {
  const DemoHomePage({super.key});

  @override
  State<DemoHomePage> createState() => _DemoHomePageState();
}

class _DemoHomePageState extends State<DemoHomePage> {
  LocalAI? _ai;
  VoiceSession? _voiceSession;

  final TextEditingController _promptController = TextEditingController(
    text: 'Explain on-device AI in one sentence.',
  );
  final TextEditingController _systemPromptController = TextEditingController(
    text: 'You are a concise on-device assistant.',
  );
  final ScrollController _logScrollController = ScrollController();

  final StringBuffer _output = StringBuffer();
  String _status = 'Initializing LocalAI Kit…';
  double _downloadProgress = 0.0;
  String _downloadFile = '';
  bool _isDownloading = false;
  bool _isInstalled = false;
  bool _isGenerating = false;
  bool _showLogs = true;

  String _selectedModelId = 'qwen-2.5-0.5b-instruct'; // Default to fast 0.5B model

  int _tokenCount = 0;
  DateTime? _generationStartTime;
  double _tokensPerSecond = 0.0;

  StreamSubscription<ModelDownloadProgress>? _downloadSub;
  StreamSubscription<ModelStatus>? _statusSub;
  CancelToken? _currentCancelToken;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _status = 'Initializing LocalAI engine…';
      _downloadProgress = 0.0;
      _isDownloading = false;
    });
    AppLogger.info('INIT', 'Bootstrapping LocalAI for model: $_selectedModelId');

    try {
      await _downloadSub?.cancel();
      await _statusSub?.cancel();
      await _voiceSession?.stop();
      _voiceSession = null;
      await _ai?.dispose();

      // Configure kit with selected LLM model
      final config = LocalAIConfig(
        llm: LlmConfig(
          modelId: _selectedModelId,
          runtime: RuntimePreference.auto,
        ),
        vad: const VadConfig(modelId: 'silero-vad'),
        stt: const SttConfig(modelId: 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue'),
        tts: const TtsConfig(modelId: 'supertonic-tts'),
      );

      final ai = await LocalAI.initialize(
        config,
        plugins: const [
          GemmaAdapterPlugin(),
          SherpaAdapterPlugin(),
        ],
      );

      // Check if current model is already installed
      final installed = await ai.models.isInstalled(_selectedModelId);
      final initialStatus = await ai.models.getStatus(_selectedModelId);

      _statusSub = ai.models.watchStatus(_selectedModelId).listen((status) {
        if (!mounted) return;
        AppLogger.info('STATUS', 'Model "$_selectedModelId" state -> ${status.state.name}');
        setState(() {
          _isInstalled = status.isInstalled;
          if (status.state == ModelInstallState.installed) {
            _status = 'Model $_selectedModelId is installed & ready';
            _isDownloading = false;
            _downloadProgress = 0.0;
          } else if (status.state == ModelInstallState.failed) {
            _status = 'Download failed: ${status.error?.message ?? 'Network error'}';
            _isDownloading = false;
            _downloadProgress = 0.0;
          }
        });
      });

      _downloadSub = ai.models.downloadProgress(_selectedModelId).listen((progress) {
        if (!mounted) return;
        final speedMB = progress.bytesPerSecond > 0
            ? '${(progress.bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s'
            : '';
        final receivedMB = (progress.receivedBytes / (1024 * 1024)).toStringAsFixed(1);
        final totalMB = (progress.totalBytes / (1024 * 1024)).toStringAsFixed(1);

        setState(() {
          _isDownloading = progress.fraction < 1.0;
          _downloadProgress = progress.fraction;
          _downloadFile = progress.currentFile ?? _selectedModelId;
          _status = 'Downloading $_downloadFile: $receivedMB / $totalMB MB '
              '(${(progress.fraction * 100).toStringAsFixed(0)}%) $speedMB';
        });
        AppLogger.info('DOWNLOAD', '$_downloadFile: $receivedMB/$totalMB MB (${(progress.fraction * 100).toStringAsFixed(1)}%) $speedMB');
      });

      if (mounted) {
        setState(() {
          _ai = ai;
          _isInstalled = installed || initialStatus.isInstalled;
          _status = _isInstalled
              ? 'Ready (Model $_selectedModelId is installed)'
              : 'Model not installed yet. Click "Download Model" to install.';
        });
        AppLogger.success('INIT', 'LocalAI initialized (installed: $_isInstalled)');
      }
    } on LocalAIError catch (e, st) {
      AppLogger.error('INIT', 'LocalAI initialization failed: ${e.message}', error: e, stackTrace: st);
      if (mounted) {
        setState(() => _status = 'Init failed: ${e.message}');
      }
    } catch (e, st) {
      AppLogger.error('INIT', 'Unexpected init error', error: e, stackTrace: st);
      if (mounted) {
        setState(() => _status = 'Unexpected error: $e');
      }
    }
  }

  Future<void> _downloadCurrentModel() async {
    final ai = _ai;
    if (ai == null) return;

    setState(() {
      _isDownloading = true;
      _downloadProgress = 0.01;
      _status = 'Starting download for $_selectedModelId…';
    });

    AppLogger.info('DOWNLOAD', 'Starting direct model download: $_selectedModelId');
    try {
      await ai.models.install(_selectedModelId);
      final installed = await ai.models.isInstalled(_selectedModelId);
      if (mounted) {
        setState(() {
          _isInstalled = installed;
          _isDownloading = false;
          _status = 'Model $_selectedModelId downloaded & installed successfully!';
        });
        AppLogger.success('DOWNLOAD', 'Installation finished for $_selectedModelId');
      }
    } catch (e, st) {
      AppLogger.error('DOWNLOAD', 'Download failed: $e', error: e, stackTrace: st);
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _downloadProgress = 0.0;
          _status = 'Download failed: $e';
        });
      }
    }
  }

  Future<void> _generate() async {
    final ai = _ai;
    if (ai == null) {
      AppLogger.warn('GENERATE', 'Generate called before LocalAI initialization');
      return;
    }

    if (_isGenerating) {
      _currentCancelToken?.cancel();
      setState(() => _isGenerating = false);
      AppLogger.info('GENERATE', 'Generation aborted by user');
      return;
    }

    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) return;

    setState(() {
      _output.clear();
      _status = 'Generating response from $_selectedModelId…';
      _isGenerating = true;
      _tokenCount = 0;
      _tokensPerSecond = 0.0;
      _generationStartTime = DateTime.now();
    });

    AppLogger.info('GENERATE', 'Prompt: "$prompt" (Model: $_selectedModelId)');
    final cancelToken = _currentCancelToken = CancelToken();

    try {
      final chunks = await ai.generateStream(LlmRequest.prompt(
        prompt,
        systemPrompt: _systemPromptController.text.isNotEmpty
            ? _systemPromptController.text
            : 'You are a concise on-device assistant.',
      ));

      await for (final chunk in chunks) {
        if (cancelToken.isCancelled) break;
        if (chunk.textDelta.isNotEmpty) {
          setState(() {
            _output.write(chunk.textDelta);
            _tokenCount++;
            final elapsed = DateTime.now().difference(_generationStartTime!).inMilliseconds;
            if (elapsed > 0) {
              _tokensPerSecond = (_tokenCount / (elapsed / 1000.0));
            }
          });
        }
      }

      if (mounted) {
        setState(() {
          _status = 'Generation complete ($_tokenCount tokens, ${_tokensPerSecond.toStringAsFixed(1)} tok/s)';
          _isGenerating = false;
        });
        AppLogger.success('GENERATE', 'Completed: $_tokenCount tokens emitted');
      }
    } on LocalAIError catch (e, st) {
      AppLogger.error('GENERATE', 'Generation failed: ${e.message}', error: e, stackTrace: st);
      if (mounted) {
        setState(() {
          _status = 'Error: ${e.message}';
          _isGenerating = false;
        });
      }
    } catch (e, st) {
      AppLogger.error('GENERATE', 'Unexpected generation error', error: e, stackTrace: st);
      if (mounted) {
        setState(() {
          _status = 'Error: $e';
          _isGenerating = false;
        });
      }
    }
  }

  Future<void> _toggleVoice() async {
    final ai = _ai;
    if (ai == null) return;

    final existing = _voiceSession;
    if (existing != null) {
      AppLogger.info('VOICE', 'Stopping voice session…');
      await existing.stop();
      if (mounted) {
        setState(() {
          _voiceSession = null;
          _status = 'Voice session stopped';
        });
      }
      return;
    }

    try {
      AppLogger.info('VOICE', 'Starting voice session with barge-in…');
      setState(() {
        _status = 'Starting voice session…';
      });

      final session = await ai.voice.start(
        sessionConfig: VoiceSessionConfig(
          systemPrompt: _systemPromptController.text.isNotEmpty
              ? _systemPromptController.text
              : 'You are a concise voice assistant.',
        ),
      );

      session.events.listen((event) {
        if (!mounted) return;
        AppLogger.info('VOICE', 'Voice event: ${event.runtimeType}');
        setState(() {
          _status = switch (event) {
            VoiceListening() => '🎙️ Listening for speech…',
            VoiceSpeechStarted() => '🗣️ Speech detected (VAD active)',
            VoiceTranscriptUpdated(:final text) => '📝 Heard: "$text"',
            VoiceThinking() => '🧠 Thinking / LLM inference…',
            VoiceResponseDelta(:final textDelta) => () {
                _output.write(textDelta);
                return '🔊 Synthesizing & speaking…';
              }(),
            VoiceSpeaking() => '🔊 Assistant speaking',
            VoiceInterrupted() => '⚡ Interrupted by user (barge-in triggered)',
            VoiceErrorOccurred(:final error) => '❌ Voice error: ${error.message}',
            _ => 'Voice: ${event.runtimeType}',
          };
        });
      });

      if (mounted) {
        setState(() {
          _voiceSession = session;
          _status = '🎙️ Listening (Speak into your microphone)…';
        });
      }
    } on LocalAIError catch (e, st) {
      AppLogger.error('VOICE', 'Voice session failed: ${e.message}', error: e, stackTrace: st);
      if (mounted) {
        setState(() => _status = 'Voice unavailable: ${e.message}');
      }
    } catch (e, st) {
      AppLogger.error('VOICE', 'Voice error', error: e, stackTrace: st);
      if (mounted) {
        setState(() => _status = 'Voice error: $e');
      }
    }
  }

  @override
  void dispose() {
    _downloadSub?.cancel();
    _statusSub?.cancel();
    _voiceSession?.stop();
    _ai?.dispose();
    _promptController.dispose();
    _systemPromptController.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('LocalAI Kit Demo'),
        actions: [
          // Toggle Live Log Console visibility
          IconButton(
            tooltip: _showLogs ? 'Hide Live Terminal' : 'Show Live Terminal',
            icon: Icon(_showLogs ? Icons.terminal : Icons.terminal_outlined),
            onPressed: () => setState(() => _showLogs = !_showLogs),
          ),
          // Manage Models Catalog Sheet
          IconButton(
            tooltip: 'Model Catalog & Downloader',
            icon: const Icon(Icons.hub_outlined),
            onPressed: () {
              ModelsSheet.show(
                context,
                ai: _ai,
                selectedModelId: _selectedModelId,
                onSelectModel: (modelId) {
                  setState(() => _selectedModelId = modelId);
                  Navigator.pop(context);
                  _bootstrap();
                },
              );
            },
          ),
          // Debug Logs Full Screen Sheet
          ValueListenableBuilder<int>(
            valueListenable: AppLogger.errorCountNotifier,
            builder: (context, errorCount, child) {
              return Stack(
                alignment: Alignment.center,
                children: [
                  IconButton(
                    tooltip: 'Full Debug Log Viewer',
                    icon: const Icon(Icons.receipt_long),
                    onPressed: () => LogViewerSheet.show(context),
                  ),
                  if (errorCount > 0)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                        ),
                        constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                        child: Text(
                          '$errorCount',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. Model Selector Dropdown
            Card(
              elevation: 0,
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Row(
                  children: [
                    const Icon(Icons.psychology, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: _selectedModelId,
                          items: const [
                            DropdownMenuItem(
                              value: 'qwen-2.5-0.5b-instruct',
                              child: Text('⚡ Qwen 2.5 0.5B Instruct (Fast 546 MB Download)'),
                            ),
                            DropdownMenuItem(
                              value: 'deepseek-r1-1.5b-int4',
                              child: Text('🧠 DeepSeek R1 Distill (1.5B Reasoning - 1.86 GB)'),
                            ),
                            DropdownMenuItem(
                              value: 'smollm2-360m-instruct',
                              child: Text('🚀 SmolLM2 360M Instruct (Ultra-Light 373 MB)'),
                            ),
                            DropdownMenuItem(
                              value: 'gemma-3n-e2b-it-int4',
                              child: Text('💎 Google Gemma 3n E2B (2.7 GB)'),
                            ),
                          ],
                          onChanged: (val) {
                            if (val == null || val == _selectedModelId) return;
                            setState(() => _selectedModelId = val);
                            _bootstrap();
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),

            // 2. Status & Download / Progress Banner
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _isGenerating || _voiceSession != null
                              ? Colors.green
                              : (_isDownloading
                                  ? Colors.orange
                                  : (_isInstalled ? Colors.blue : Colors.grey)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _status,
                          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                        ),
                      ),
                      if (!_isInstalled && !_isDownloading)
                        FilledButton.tonalIcon(
                          onPressed: _downloadCurrentModel,
                          icon: const Icon(Icons.download, size: 16),
                          label: const Text('Download Model'),
                        ),
                    ],
                  ),
                  if (_isDownloading) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: _downloadProgress > 0 ? _downloadProgress : null),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),

            // 3. Prompt Input
            TextField(
              controller: _promptController,
              decoration: InputDecoration(
                labelText: 'Prompt',
                hintText: 'Enter a prompt for the on-device AI…',
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                suffixIcon: IconButton(
                  tooltip: 'Clear prompt',
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () => _promptController.clear(),
                ),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 6),

            // 4. Sample Prompt Chips
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ActionChip(
                    label: const Text('Explain on-device AI'),
                    onPressed: () =>
                        _promptController.text = 'Explain on-device AI in one sentence.',
                  ),
                  const SizedBox(width: 6),
                  ActionChip(
                    label: const Text('Write a Haiku'),
                    onPressed: () => _promptController.text = 'Write a haiku about local AI.',
                  ),
                  const SizedBox(width: 6),
                  ActionChip(
                    label: const Text('Why offline privacy?'),
                    onPressed: () => _promptController.text =
                        'Why is offline on-device AI better for privacy and security?',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),

            // 5. Action Buttons (Generate, Voice Chat, Clear)
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _isDownloading ? null : _generate,
                  icon: Icon(_isGenerating ? Icons.stop : Icons.bolt),
                  label: Text(_isGenerating ? 'Stop' : 'Generate'),
                ),
                const SizedBox(width: 10),
                FilledButton.tonalIcon(
                  onPressed: _isDownloading ? null : _toggleVoice,
                  icon: Icon(_voiceSession == null ? Icons.mic : Icons.mic_off),
                  label: Text(_voiceSession == null ? 'Voice Chat' : 'Stop Voice'),
                ),
                const Spacer(),
                if (_output.isNotEmpty)
                  IconButton(
                    tooltip: 'Copy Output',
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _output.toString()));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Copied response to clipboard')),
                      );
                    },
                  ),
                IconButton(
                  tooltip: 'Clear Output',
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: () => setState(() => _output.clear()),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // 6. Response Output Area
            Expanded(
              flex: 3,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: _output.isEmpty
                    ? Center(
                        child: Text(
                          _isDownloading
                              ? 'Model is downloading… Output will appear once download completes.'
                              : 'AI response output will stream here…',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : SingleChildScrollView(
                        child: SelectableText(
                          _output.toString(),
                          style: const TextStyle(fontSize: 14, height: 1.4),
                        ),
                      ),
              ),
            ),

            // 7. Embedded Live Debug Log Viewer (Always visible on-screen!)
            if (_showLogs) ...[
              const SizedBox(height: 8),
              Expanded(
                flex: 2,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade900,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.terminal, color: Colors.greenAccent, size: 16),
                            const SizedBox(width: 6),
                            const Text(
                              'Live Debug Log Console',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                fontFamily: 'monospace',
                              ),
                            ),
                            const Spacer(),
                            IconButton(
                              tooltip: 'Clear Console',
                              icon: const Icon(Icons.clear_all, color: Colors.white70, size: 16),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: () => AppLogger.clear(),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: 'Full Screen Logs',
                              icon: const Icon(Icons.open_in_full, color: Colors.white70, size: 14),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: () => LogViewerSheet.show(context),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: StreamBuilder<List<LogEntry>>(
                          stream: AppLogger.stream,
                          initialData: AppLogger.logs,
                          builder: (context, snapshot) {
                            final logs = snapshot.data ?? [];
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (_logScrollController.hasClients) {
                                _logScrollController.jumpTo(
                                  _logScrollController.position.maxScrollExtent,
                                );
                              }
                            });
                            return ListView.builder(
                              controller: _logScrollController,
                              padding: const EdgeInsets.all(8),
                              itemCount: logs.length,
                              itemBuilder: (context, index) {
                                final l = logs[index];
                                final color = switch (l.level) {
                                  LogLevel.info => Colors.lightBlueAccent,
                                  LogLevel.success => Colors.greenAccent,
                                  LogLevel.warning => Colors.orangeAccent,
                                  LogLevel.error => Colors.redAccent,
                                };
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 2),
                                  child: SelectableText.rich(
                                    TextSpan(
                                      children: [
                                        TextSpan(
                                          text: '[${l.formatTime()}] ',
                                          style: const TextStyle(
                                            color: Colors.grey,
                                            fontSize: 11,
                                            fontFamily: 'monospace',
                                          ),
                                        ),
                                        TextSpan(
                                          text: '[${l.tag}] ',
                                          style: TextStyle(
                                            color: color,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 11,
                                            fontFamily: 'monospace',
                                          ),
                                        ),
                                        TextSpan(
                                          text: l.message,
                                          style: TextStyle(
                                            color: Colors.white.withValues(alpha: 0.9),
                                            fontSize: 11,
                                            fontFamily: 'monospace',
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
