/// LocalAI Kit interactive demo:
/// - Categorized tabs: Text Generation (LLM), Text-to-Speech (TTS), Voice Pipeline (VAD+STT+LLM+TTS), Model Catalog & Storage, Live Terminal
/// - Fast on-device LLMs: SmolLM2 360M (LiteRT-LM for macOS & Mobile), Qwen 2.5 0.5B, DeepSeek R1 1.5B
/// - On-device TTS: Piper TTS Lessac Low, Supertonic TTS, Kokoro TTS v0.19 with Audio Player
/// - Real-time model downloader with live MB / speed / ETA tracking & uninstalled model notifications
/// - Full-duplex voice chat session (Mic -> VAD -> STT -> LLM -> TTS)
library;

import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_ai_gemma/local_ai_gemma.dart';
import 'package:local_ai_genkit/local_ai_genkit.dart';
import 'package:local_ai_kit/local_ai_kit.dart';
import 'package:local_ai_sherpa/local_ai_sherpa.dart';

import 'logger.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await FlutterGemma.initialize(
      inferenceEngines: [
        MediaPipeEngine(),
        LiteRtLmEngine(),
      ],
    );
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

class _DemoHomePageState extends State<DemoHomePage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  LocalAI? _ai;
  VoiceSession? _voiceSession;

  // Selected Model IDs for different subsystems
  String _selectedLlmId = 'smollm2-360m-instruct';
  String _selectedVadId = 'silero-vad';
  String _selectedSttId = 'sherpa-onnx-streaming-zipformer-en-20m';
  String _selectedTtsId = 'supertonic-tts';

  // 1. Text generation & Orchestration (Genkit / MCP Skills) state
  bool _enableGenkit = false;
  bool _enableSkills = true;
  final Map<String, bool> _skillToggles = {
    'calculator': true,
    'device_time': true,
    'device_info': true,
    'weather': true,
  };
  List<McpToolCall> _lastToolCalls = [];
  List<McpToolResult> _lastToolResults = [];

  final TextEditingController _promptController = TextEditingController(
    text: 'What is 45 * 18 + sqrt(144)?',
  );
  final TextEditingController _systemPromptController = TextEditingController(
    text: 'You are a concise on-device assistant.',
  );
  final ScrollController _outputScrollController = ScrollController();
  final StringBuffer _output = StringBuffer();
  String _outputText = '';
  bool _isGenerating = false;
  int _tokenCount = 0;
  DateTime? _generationStartTime;
  double _tokensPerSecond = 0.0;
  CancelToken? _currentCancelToken;

  // 2. TTS Generation & Audio Player state
  final TextEditingController _ttsTextController = TextEditingController(
    text:
        'Welcome to LocalAI Kit! Running ultra fast on-device neural text to speech.',
  );
  double _ttsSpeed = 1.0;
  double _ttsPitch = 1.0;
  String _ttsLanguage = 'ja';
  String _ttsVoiceStyle = 'default';
  bool _isTtsSynthesizing = false;
  bool _isTtsPlaying = false;
  int _ttsAudioChunks = 0;
  int _ttsSampleCount = 0;
  String _ttsStatus = 'Ready to synthesize speech.';
  double _ttsPlaybackProgress = 0.0;
  Timer? _ttsProgressTimer;

  static const Map<String, String> _samplePhrases = {
    'ja': 'こんにちは！ 今日は「ありがとう」の使い方を勉強しましょう。',
    'en':
        'Welcome to LocalAI Kit! Running ultra fast on-device neural text to speech.',
    'ko': '안녕하세요! 온디바이스 음성 합성 LocalAI Kit에 오신 것을 환영합니다.',
    'zh': '你好！欢迎使用LocalAI Kit端侧语音合成。',
    'es':
        '¡Hola! Bienvenido a LocalAI Kit con síntesis de voz en el dispositivo.',
    'fr':
        'Bonjour! Bienvenue sur LocalAI Kit avec synthèse vocale sur appareil.',
    'de': 'Hallo! Willkommen bei LocalAI Kit für lokale Sprachsynthese.',
    'it': 'Ciao! Benvenuto in LocalAI Kit con sintesi vocale sul dispositivo.',
    'pt': 'Olá! Bem-vindo ao LocalAI Kit com síntese de voz no dispositivo.',
    'ru':
        'Привет! Добро пожаловать в LocalAI Kit с синтезом речи на устройстве.',
    'hi': 'नमस्ते! लोकल एआई किट में आपका स्वागत है।',
    'ar': 'مرحبا بك في LocalAI Kit لتحويل النص إلى كلام محليا.',
    'nl': 'Hallo! Welkom bij LocalAI Kit met spraaksynthese op het apparaat.',
    'pl': 'Cześć! Witamy w LocalAI Kit z syntezą mowy na urządzeniu.',
    'tr': 'Merhaba! Cihaz içi ses sentezi ile LocalAI Kit\'e hoş geldiniz.',
    'sv': 'Hej! Välkommen till LocalAI Kit med talsyntes på enheten.',
    'vi': 'Xin chào! Chào mừng đến với LocalAI Kit tổng hợp giọng nói.',
    'id':
        'Halo! Selamat datang di LocalAI Kit dengan sintesis suara di perangkat.',
    'th': 'สวัสดี! ยินดีต้อนรับสู่ LocalAI Kit ระบบสังเคราะห์เสียงบนอุปกรณ์',
  };

  // 3. Voice session state
  String _voiceStatus = 'Voice session idle. Press Start to speak.';
  String _voiceTranscript = '';
  String _voiceReply = '';
  bool _isVoiceDownloading = false;
  String _voiceDownloadStatus = '';

  // App status & model management
  String _status = 'Initializing LocalAI Kit…';
  bool _isLlmInstalled = false;
  bool _isLlmDownloading = false;
  double _llmDownloadProgress = 0.0;
  String _llmDownloadFile = '';

  // Catalog status cache for all models
  List<LocalModelManifest> _catalogModels = [];
  final Map<String, ModelStatus> _modelStatuses = {};
  final Map<String, double> _modelDownloadProgress = {};
  final Map<String, String> _modelDownloadSpeed = {};

  // Logs & stream subscriptions
  final ScrollController _logScrollController = ScrollController();
  final TextEditingController _logSearchController = TextEditingController();
  String _logFilter = '';
  StreamSubscription<ModelDownloadProgress>? _downloadSub;
  StreamSubscription<ModelStatus>? _statusSub;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _bootstrap();
  }

  bool _isModelInstalled(String modelId) {
    return _modelStatuses[modelId]?.isInstalled ?? false;
  }

  Future<void> _bootstrap() async {
    setState(() {
      _status = 'Initializing LocalAI for $_selectedLlmId…';
      _isLlmDownloading = false;
      _llmDownloadProgress = 0.0;
    });
    AppLogger.info('INIT',
        'Bootstrapping LocalAI: LLM=$_selectedLlmId, VAD=$_selectedVadId, STT=$_selectedSttId, TTS=$_selectedTtsId');

    try {
      await _downloadSub?.cancel();
      await _statusSub?.cancel();
      await _voiceSession?.stop();
      _voiceSession = null;
      await _ai?.dispose();

      final config = LocalAIConfig(
        llm: LlmConfig(
          modelId: _selectedLlmId,
          enableGenkit: _enableGenkit,
          runtime: RuntimePreference.auto,
        ),
        vad: VadConfig(modelId: _selectedVadId),
        stt: SttConfig(modelId: _selectedSttId),
        tts: TtsConfig(modelId: _selectedTtsId),
      );

      final ai = await LocalAI.initialize(
        config,
        plugins: [
          const GemmaAdapterPlugin(),
          if (_enableGenkit) const GenkitAdapterPlugin(),
          const SherpaAdapterPlugin(),
        ],
      );

      // Synchronize skill active toggles
      for (final entry in _skillToggles.entries) {
        if (entry.value) {
          try {
            ai.skills.enable(entry.key);
          } catch (_) {}
        } else {
          try {
            ai.skills.disable(entry.key);
          } catch (_) {}
        }
      }

      if (!mounted) return;
      _ai = ai;
      await _refreshCatalog();

      // Check current LLM status
      final installed = await ai.models.isInstalled(_selectedLlmId);
      final initialStatus = await ai.models.getStatus(_selectedLlmId);

      _statusSub = ai.models.watchStatus(_selectedLlmId).listen((status) {
        if (!mounted) return;
        AppLogger.info(
            'STATUS', 'LLM "$_selectedLlmId" state -> ${status.state.name}');
        setState(() {
          _isLlmInstalled = status.isInstalled;
          if (status.state == ModelInstallState.installed) {
            _status = '$_selectedLlmId is installed & ready';
            _isLlmDownloading = false;
            _llmDownloadProgress = 0.0;
          } else if (status.state == ModelInstallState.failed) {
            _status =
                'Download failed: ${status.error?.message ?? 'Network error'}';
            _isLlmDownloading = false;
            _llmDownloadProgress = 0.0;
          }
        });
      });

      _downloadSub =
          ai.models.downloadProgress(_selectedLlmId).listen((progress) {
        if (!mounted) return;
        final speedMB = progress.bytesPerSecond > 0
            ? '${(progress.bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s'
            : '';
        final receivedMB =
            (progress.receivedBytes / (1024 * 1024)).toStringAsFixed(1);
        final totalMB =
            (progress.totalBytes / (1024 * 1024)).toStringAsFixed(1);

        setState(() {
          _isLlmDownloading = progress.fraction < 1.0;
          _llmDownloadProgress = progress.fraction;
          _llmDownloadFile = progress.currentFile ?? _selectedLlmId;
          _status = 'Downloading $_llmDownloadFile: $receivedMB / $totalMB MB '
              '(${(progress.fraction * 100).toStringAsFixed(0)}%) $speedMB';
        });
        AppLogger.info('DOWNLOAD',
            '$_llmDownloadFile: $receivedMB/$totalMB MB (${(progress.fraction * 100).toStringAsFixed(1)}%) $speedMB');
      });

      setState(() {
        _isLlmInstalled = installed || initialStatus.isInstalled;
        _status = _isLlmInstalled
            ? 'Ready (Model $_selectedLlmId installed)'
            : 'Model $_selectedLlmId not installed. Click "Download" to install.';
      });
      AppLogger.success('INIT', 'LocalAI initialization complete');
    } on LocalAIError catch (e, st) {
      AppLogger.error('INIT', 'LocalAI initialization failed: ${e.message}',
          error: e, stackTrace: st);
      if (mounted) setState(() => _status = 'Init failed: ${e.message}');
    } catch (e, st) {
      AppLogger.error('INIT', 'Unexpected init error',
          error: e, stackTrace: st);
      if (mounted) setState(() => _status = 'Unexpected error: $e');
    }
  }

  Future<void> _refreshCatalog() async {
    final ai = _ai;
    if (ai == null) return;
    try {
      final list = await ai.catalog.list();
      if (!mounted) return;
      setState(() => _catalogModels = list);

      for (final m in list) {
        ai.models.getStatus(m.id).then((status) {
          if (mounted) setState(() => _modelStatuses[m.id] = status);
        }).catchError((_) {});

        ai.models.watchStatus(m.id).listen((status) {
          if (mounted) setState(() => _modelStatuses[m.id] = status);
        });

        ai.models.downloadProgress(m.id).listen((progress) {
          if (mounted) {
            final speed = progress.bytesPerSecond > 0
                ? '${(progress.bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s'
                : '';
            setState(() {
              _modelDownloadProgress[m.id] = progress.fraction;
              _modelDownloadSpeed[m.id] = speed;
            });
          }
        });
      }
    } catch (e, st) {
      AppLogger.error('CATALOG', 'Failed to refresh catalog',
          error: e, stackTrace: st);
    }
  }

  Future<void> _installModel(String modelId) async {
    final ai = _ai;
    if (ai == null) return;
    AppLogger.info('DOWNLOAD', 'Starting download for: $modelId');
    try {
      setState(() => _modelDownloadProgress[modelId] = 0.01);
      await ai.models.install(modelId);
      final status = await ai.models.getStatus(modelId);
      if (mounted) {
        setState(() {
          _modelStatuses[modelId] = status;
          _modelDownloadProgress.remove(modelId);
          _modelDownloadSpeed.remove(modelId);
          if (modelId == _selectedLlmId) {
            _isLlmInstalled = status.isInstalled;
            _status = 'Model $modelId installed successfully!';
          }
        });
        AppLogger.success('DOWNLOAD', 'Model installed: $modelId');
      }
    } catch (e, st) {
      AppLogger.error('DOWNLOAD', 'Install failed for $modelId: $e',
          error: e, stackTrace: st);
      if (mounted) {
        setState(() => _modelDownloadProgress.remove(modelId));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Download failed for $modelId: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _downloadMissingVoiceModels() async {
    final ai = _ai;
    if (ai == null) return;

    final missingModels = <String>[];
    if (!_isModelInstalled(_selectedVadId)) missingModels.add(_selectedVadId);
    if (!_isModelInstalled(_selectedSttId)) missingModels.add(_selectedSttId);
    if (!_isModelInstalled(_selectedLlmId)) missingModels.add(_selectedLlmId);
    if (!_isModelInstalled(_selectedTtsId)) missingModels.add(_selectedTtsId);

    if (missingModels.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('All voice models are already installed!')),
      );
      return;
    }

    setState(() {
      _isVoiceDownloading = true;
      _voiceDownloadStatus =
          'Downloading ${missingModels.length} missing models…';
    });

    for (var i = 0; i < missingModels.length; i++) {
      final id = missingModels[i];
      setState(() {
        _voiceDownloadStatus =
            'Downloading [${i + 1}/${missingModels.length}]: $id…';
      });
      AppLogger.info('VOICE_INIT', 'Downloading voice model: $id');
      try {
        await _installModel(id);
      } catch (e) {
        AppLogger.error('VOICE_INIT', 'Failed to install $id: $e');
      }
    }

    setState(() {
      _isVoiceDownloading = false;
      _voiceDownloadStatus = 'All missing voice models installed successfully!';
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('All required voice models downloaded and ready!')),
    );
  }

  Future<void> _uninstallModel(String modelId) async {
    final ai = _ai;
    if (ai == null) return;
    try {
      AppLogger.info('MODELS', 'Removing model: $modelId');
      await ai.models.remove(modelId);
      final status = await ai.models.getStatus(modelId);
      if (mounted) {
        setState(() {
          _modelStatuses[modelId] = status;
          if (modelId == _selectedLlmId) {
            _isLlmInstalled = false;
            _status = 'Model $modelId removed';
          }
        });
        AppLogger.success('MODELS', 'Model removed: $modelId');
      }
    } catch (e, st) {
      AppLogger.error('MODELS', 'Failed to remove model $modelId',
          error: e, stackTrace: st);
    }
  }

  Future<void> _generate() async {
    final ai = _ai;
    if (ai == null) return;

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
      _outputText = '';
      _lastToolCalls = [];
      _lastToolResults = [];
      _status = _enableSkills
          ? 'Executing with MCP skills from $_selectedLlmId…'
          : 'Generating response from $_selectedLlmId…';
      _isGenerating = true;
      _tokenCount = 0;
      _tokensPerSecond = 0.0;
      _generationStartTime = DateTime.now();
    });

    AppLogger.info('GENERATE',
        'Prompt: "$prompt" (Model: $_selectedLlmId, Skills: $_enableSkills, Genkit: $_enableGenkit)');
    final cancelToken = _currentCancelToken = CancelToken();

    try {
      if (_enableSkills) {
        final sysPrompt = _systemPromptController.text.isNotEmpty
            ? _systemPromptController.text
            : 'You are a concise on-device assistant.';

        AppLogger.info('MCP',
            'Active skills: ${ai.skills.enabledPlugins.map((p) => p.name).join(", ")}');
        final result = await ai.generateWithSkills(
          prompt,
          systemPrompt: sysPrompt,
        );

        if (!mounted) return;
        setState(() {
          _lastToolCalls = result.toolCalls;
          _lastToolResults = result.toolResults;
          _outputText = result.text;
          _status =
              'Execution complete (${result.toolCalls.length} tool calls, ${result.turns} turns)';
          _isGenerating = false;
        });

        if (result.usedTools) {
          AppLogger.success('MCP',
              'Tools invoked: ${result.toolCalls.map((c) => "${c.name}(${c.arguments})").join("; ")}');
        }
        AppLogger.success('GENERATE', 'Response: "${result.text}"');
        return;
      }

      final chunks = await ai.generateStream(LlmRequest.prompt(
        prompt,
        systemPrompt: _systemPromptController.text.isNotEmpty
            ? _systemPromptController.text
            : 'You are a concise on-device assistant.',
      ));

      await for (final chunk in chunks) {
        if (cancelToken.isCancelled) break;
        if (chunk.textDelta.isNotEmpty) {
          _output.write(chunk.textDelta);
          final currentText = _output.toString();
          _tokenCount++;
          final elapsed =
              DateTime.now().difference(_generationStartTime!).inMilliseconds;
          final tps = elapsed > 0 ? (_tokenCount / (elapsed / 1000.0)) : 0.0;

          setState(() {
            _outputText = currentText;
            _tokensPerSecond = tps;
            _status =
                'Streaming ($_tokenCount tokens, ${tps.toStringAsFixed(1)} tok/s)…';
          });

          if (_outputScrollController.hasClients) {
            _outputScrollController
                .jumpTo(_outputScrollController.position.maxScrollExtent);
          }
        }
      }

      if (mounted) {
        setState(() {
          _status =
              'Generation complete ($_tokenCount tokens, ${_tokensPerSecond.toStringAsFixed(1)} tok/s)';
          _isGenerating = false;
        });
        AppLogger.success('GENERATE', 'Completed: $_tokenCount tokens emitted');
      }
    } on LocalAIError catch (e, st) {
      AppLogger.error('GENERATE', 'Generation failed: ${e.message}',
          error: e, stackTrace: st);
      if (mounted) {
        setState(() {
          _status = 'Error: ${e.message}';
          _isGenerating = false;
        });
      }
    } catch (e, st) {
      AppLogger.error('GENERATE', 'Unexpected generation error',
          error: e, stackTrace: st);
      if (mounted) {
        setState(() {
          _status = 'Error: $e';
          _isGenerating = false;
        });
      }
    }
  }

  Future<void> _synthesizeTts() async {
    final ai = _ai;
    if (ai == null) return;

    final text = _ttsTextController.text.trim();
    if (text.isEmpty) return;

    // Check if TTS model is installed
    if (!_isModelInstalled(_selectedTtsId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Model "$_selectedTtsId" is not installed. Please download it first.'),
          action: SnackBarAction(
            label: 'Download',
            onPressed: () => _installModel(_selectedTtsId),
          ),
        ),
      );
      return;
    }

    setState(() {
      _isTtsSynthesizing = true;
      _isTtsPlaying = true;
      _ttsAudioChunks = 0;
      _ttsSampleCount = 0;
      _ttsPlaybackProgress = 0.0;
      _ttsStatus = 'Synthesizing speech with $_selectedTtsId…';
    });

    AppLogger.info('TTS',
        'Speaking: "$text" (Model: $_selectedTtsId, Speed: $_ttsSpeed, Pitch: $_ttsPitch)');
    final stopwatch = Stopwatch()..start();

    // Start progress simulation for visual audio player
    _ttsProgressTimer?.cancel();
    _ttsProgressTimer = Timer.periodic(const Duration(milliseconds: 100), (t) {
      if (!mounted || !_isTtsPlaying) {
        t.cancel();
        return;
      }
      setState(() {
        _ttsPlaybackProgress = min(1.0, _ttsPlaybackProgress + 0.04);
      });
    });

    try {
      setState(() => _ttsStatus = '🔊 Synthesizing & playing speech…');
      await ai.tts.speak(
        text,
        language: _ttsLanguage,
        voiceId: _ttsVoiceStyle != 'default' ? _ttsVoiceStyle : null,
        speed: _ttsSpeed,
        pitch: _ttsPitch,
      );

      stopwatch.stop();
      _ttsProgressTimer?.cancel();
      if (mounted) {
        setState(() {
          _isTtsSynthesizing = false;
          _isTtsPlaying = false;
          _ttsPlaybackProgress = 1.0;
          _ttsStatus =
              'Speech playback complete in ${stopwatch.elapsedMilliseconds}ms.';
        });
        AppLogger.success('TTS',
            'Speech playback finished in ${stopwatch.elapsedMilliseconds}ms');
      }
    } on LocalAIError catch (e, st) {
      AppLogger.error('TTS', 'TTS synthesis failed: ${e.message}',
          error: e, stackTrace: st);
      _ttsProgressTimer?.cancel();
      if (mounted) {
        setState(() {
          _isTtsSynthesizing = false;
          _isTtsPlaying = false;
          _ttsStatus = 'TTS error: ${e.message}';
        });
      }
    } catch (e, st) {
      AppLogger.error('TTS', 'Unexpected TTS error: $e',
          error: e, stackTrace: st);
      _ttsProgressTimer?.cancel();
      if (mounted) {
        setState(() {
          _isTtsSynthesizing = false;
          _isTtsPlaying = false;
          _ttsStatus = 'TTS error: $e';
        });
      }
    }
  }

  Future<void> _stopTts() async {
    final ai = _ai;
    if (ai == null) return;
    _ttsProgressTimer?.cancel();
    try {
      await ai.tts.stopSpeaking();
      if (mounted) {
        setState(() {
          _isTtsSynthesizing = false;
          _isTtsPlaying = false;
          _ttsStatus = 'Audio playback stopped.';
        });
      }
      AppLogger.info('TTS', 'Audio playback stopped by user');
    } catch (e) {
      AppLogger.error('TTS', 'Failed to stop TTS: $e');
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
          _voiceStatus = 'Voice session stopped.';
        });
      }
      return;
    }

    // Check all 4 models before starting
    final uninstalled = <String>[];
    if (!_isModelInstalled(_selectedVadId)) {
      uninstalled.add('VAD ($_selectedVadId)');
    }
    if (!_isModelInstalled(_selectedSttId)) {
      uninstalled.add('STT ($_selectedSttId)');
    }
    if (!_isModelInstalled(_selectedLlmId)) {
      uninstalled.add('LLM ($_selectedLlmId)');
    }
    if (!_isModelInstalled(_selectedTtsId)) {
      uninstalled.add('TTS ($_selectedTtsId)');
    }

    if (uninstalled.isNotEmpty) {
      final msg =
          'Cannot start Voice Assistant: ${uninstalled.join(', ')} not installed yet. Click "Download Missing Voice Models" above.';
      AppLogger.warn('VOICE', msg);
      setState(() => _voiceStatus = '⚠️ $msg');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: Theme.of(context).colorScheme.error,
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'Download All',
            textColor: Colors.white,
            onPressed: _downloadMissingVoiceModels,
          ),
        ),
      );
      return;
    }

    try {
      AppLogger.info('VOICE', 'Starting voice session with barge-in…');
      setState(() {
        _voiceStatus = 'Starting voice session…';
        _voiceTranscript = '';
        _voiceReply = '';
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
        AppLogger.info('VOICE', 'Event: ${event.runtimeType}');
        setState(() {
          switch (event) {
            case VoiceListening():
              _voiceStatus = '🎙️ Listening: Speak into your microphone now.';
            case VoiceSpeechStarted():
              _voiceStatus = '🗣️ User speaking… recording utterance';
            case VoiceSpeechEnded():
              _voiceStatus = '⏳ Transcribing speech (STT)…';
            case VoiceTranscriptUpdated(:final text):
              _voiceTranscript = text;
              _voiceStatus = '📝 Heard: "$text"';
            case VoiceThinking():
              _voiceStatus = '🧠 Generating reply with LLM…';
              _voiceReply = '';
            case VoiceResponseStarted():
              _voiceStatus = '🔊 Assistant replying…';
            case VoiceResponseDelta(:final textDelta):
              _voiceReply += textDelta;
              _voiceStatus = '🔊 Assistant replying…';
            case VoiceSpeaking():
              _voiceStatus = '🔊 Speaking response…';
            case VoiceFinished():
              _voiceStatus = '🎙️ Listening: Speak into your microphone now.';
            case VoiceInterrupted():
              _voiceStatus = '⚡ Barge-in: Interrupted by user!';
            case VoiceErrorOccurred(:final error):
              _voiceStatus = '❌ Voice error: ${error.message}';
          }
        });
      });

      if (mounted) {
        setState(() {
          _voiceSession = session;
          _voiceStatus = '🎙️ Listening: Speak into your microphone now.';
        });
      }
    } on LocalAIError catch (e, st) {
      AppLogger.error('VOICE', 'Voice session failed: ${e.message}',
          error: e, stackTrace: st);
      if (mounted) setState(() => _voiceStatus = 'Voice error: ${e.message}');
    } catch (e, st) {
      AppLogger.error('VOICE', 'Voice error', error: e, stackTrace: st);
      if (mounted) setState(() => _voiceStatus = 'Voice error: $e');
    }
  }

  @override
  void dispose() {
    _ttsProgressTimer?.cancel();
    _tabController.dispose();
    _downloadSub?.cancel();
    _statusSub?.cancel();
    _voiceSession?.stop();
    _ai?.dispose();
    _promptController.dispose();
    _systemPromptController.dispose();
    _ttsTextController.dispose();
    _outputScrollController.dispose();
    _logScrollController.dispose();
    _logSearchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.hub_outlined, color: Colors.deepPurpleAccent),
            SizedBox(width: 8),
            Text('LocalAI Kit', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: const [
            Tab(
                icon: Icon(Icons.chat_bubble_outline),
                text: 'Text Generation (LLM)'),
            Tab(icon: Icon(Icons.volume_up), text: 'Text-to-Speech (TTS)'),
            Tab(icon: Icon(Icons.mic), text: 'Voice Assistant'),
            Tab(icon: Icon(Icons.inventory_2_outlined), text: 'Model Catalog'),
            Tab(icon: Icon(Icons.terminal), text: 'Live Logs'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildLlmChatTab(theme),
          _buildTtsTab(theme),
          _buildVoiceTab(theme),
          _buildCatalogTab(theme),
          _buildLogsTab(theme),
        ],
      ),
    );
  }

  // ===========================================================================
  // 1. LLM Chat Tab
  // ===========================================================================
  Widget _buildLlmChatTab(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // LLM Dropdown Selector
          Card(
            elevation: 0,
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.5),
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
                        value: _selectedLlmId,
                        items: const [
                          DropdownMenuItem(
                            value: 'smollm2-360m-instruct',
                            child: Text(
                                '⚡ SmolLM2 360M (LiteRT-LM • macOS/iOS/Android • 373 MB)'),
                          ),
                          DropdownMenuItem(
                            value: 'qwen-3.5-0.8b-instruct',
                            child: Text(
                                '🚀 Qwen 3.5 0.8B (LiteRT-LM • macOS/iOS/Android • 963 MB)'),
                          ),
                          DropdownMenuItem(
                            value: 'qwen-3.5-2b-instruct',
                            child: Text(
                                '🧠 Qwen 3.5 2B (LiteRT-LM • macOS/iOS/Android • 2.11 GB)'),
                          ),
                          DropdownMenuItem(
                            value: 'qwen-3.5-4b-instruct',
                            child: Text(
                                '🔥 Qwen 3.5 4B (LiteRT-LM • macOS/iOS/Android • 4.40 GB)'),
                          ),
                          DropdownMenuItem(
                            value: 'qwen-2.5-0.5b-instruct',
                            child: Text(
                                '📱 Qwen 2.5 0.5B (MediaPipe • Android/iOS/Web • 546 MB)'),
                          ),
                          DropdownMenuItem(
                            value: 'deepseek-r1-1.5b-int4',
                            child: Text(
                                '📱 DeepSeek R1 1.5B (MediaPipe • Android/iOS/Web • 1.86 GB)'),
                          ),
                          DropdownMenuItem(
                            value: 'gemma-4-e2b-it',
                            child: Text(
                                '💎 Gemma 4 E2B (LiteRT-LM • macOS/iOS/Android • 2.59 GB)'),
                          ),
                          DropdownMenuItem(
                            value: 'gemma-4-e4b-it',
                            child: Text(
                                '💎 Gemma 4 E4B (LiteRT-LM • macOS/iOS/Android • 3.66 GB)'),
                          ),
                          DropdownMenuItem(
                            value: 'gemma-3n-e2b-it-int4',
                            child: Text(
                                '💎 Gemma 3n E2B (LiteRT-LM • macOS/iOS/Android • 2.59 GB)'),
                          ),
                        ],
                        onChanged: (val) {
                          if (val == null || val == _selectedLlmId) return;
                          setState(() => _selectedLlmId = val);
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

          // Status & Download Banner
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: _status.startsWith('Error')
                  ? theme.colorScheme.errorContainer
                  : theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _isLlmDownloading
                          ? Icons.downloading
                          : _isLlmInstalled
                              ? Icons.check_circle_outline
                              : Icons.info_outline,
                      size: 16,
                      color: _status.startsWith('Error')
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _status,
                        style: TextStyle(
                          fontSize: 12,
                          color: _status.startsWith('Error')
                              ? theme.colorScheme.onErrorContainer
                              : theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (!_isLlmInstalled && !_isLlmDownloading)
                      FilledButton.tonal(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 4),
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () => _installModel(_selectedLlmId),
                        child: const Text('Download Model'),
                      ),
                  ],
                ),
                if (_isLlmDownloading) ...[
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                      value: _llmDownloadProgress > 0
                          ? _llmDownloadProgress
                          : null),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),

          // Orchestration & MCP Plugins / Skills Bar
          Card(
            elevation: 0,
            color: theme.colorScheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      FilterChip(
                        avatar: Icon(
                          _enableGenkit
                              ? Icons.account_tree
                              : Icons.account_tree_outlined,
                          size: 16,
                        ),
                        label: Text(
                          'Genkit Orchestrator: ${_enableGenkit ? "ON" : "OFF"}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        selected: _enableGenkit,
                        onSelected: (val) {
                          setState(() => _enableGenkit = val);
                          AppLogger.info('CONFIG',
                              'Toggled Genkit Orchestrator -> ${_enableGenkit ? "ENABLED" : "DISABLED"}');
                          _bootstrap();
                        },
                      ),
                      const SizedBox(width: 8),
                      FilterChip(
                        avatar: Icon(
                          _enableSkills
                              ? Icons.extension
                              : Icons.extension_outlined,
                          size: 16,
                        ),
                        label: Text(
                          'MCP Plugins / Skills: ${_enableSkills ? "ON" : "OFF"}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        selected: _enableSkills,
                        onSelected: (val) {
                          setState(() => _enableSkills = val);
                          AppLogger.info('CONFIG',
                              'Toggled MCP Skills -> ${_enableSkills ? "ENABLED" : "DISABLED"}');
                        },
                      ),
                    ],
                  ),
                  if (_enableSkills) ...[
                    const SizedBox(height: 8),
                    const Text(
                      'Active MCP Skills & Tool Providers:',
                      style:
                          TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        FilterChip(
                          avatar:
                              const Text('🧮', style: TextStyle(fontSize: 12)),
                          label: const Text('Calculator (calculate)',
                              style: TextStyle(fontSize: 11)),
                          selected: _skillToggles['calculator'] ?? true,
                          onSelected: (val) {
                            setState(() => _skillToggles['calculator'] = val);
                            if (val) {
                              _ai?.skills.enable('calculator');
                            } else {
                              _ai?.skills.disable('calculator');
                            }
                          },
                        ),
                        FilterChip(
                          avatar:
                              const Text('🕒', style: TextStyle(fontSize: 12)),
                          label: const Text('Device Clock (get_current_time)',
                              style: TextStyle(fontSize: 11)),
                          selected: _skillToggles['device_time'] ?? true,
                          onSelected: (val) {
                            setState(() => _skillToggles['device_time'] = val);
                            if (val) {
                              _ai?.skills.enable('device_time');
                            } else {
                              _ai?.skills.disable('device_time');
                            }
                          },
                        ),
                        FilterChip(
                          avatar:
                              const Text('📱', style: TextStyle(fontSize: 12)),
                          label: const Text('System Specs (get_device_info)',
                              style: TextStyle(fontSize: 11)),
                          selected: _skillToggles['device_info'] ?? true,
                          onSelected: (val) {
                            setState(() => _skillToggles['device_info'] = val);
                            if (val) {
                              _ai?.skills.enable('device_info');
                            } else {
                              _ai?.skills.disable('device_info');
                            }
                          },
                        ),
                        FilterChip(
                          avatar:
                              const Text('🌤️', style: TextStyle(fontSize: 12)),
                          label: const Text('Weather Mock (get_weather)',
                              style: TextStyle(fontSize: 11)),
                          selected: _skillToggles['weather'] ?? true,
                          onSelected: (val) {
                            setState(() => _skillToggles['weather'] = val);
                            if (val) {
                              _ai?.skills.enable('weather');
                            } else {
                              _ai?.skills.disable('weather');
                            }
                          },
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),

          // Prompt Input Field
          TextField(
            controller: _promptController,
            decoration: InputDecoration(
              labelText: 'Prompt',
              border: const OutlineInputBorder(),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              suffixIcon: IconButton(
                icon: const Icon(Icons.clear, size: 18),
                onPressed: () => _promptController.clear(),
              ),
            ),
            maxLines: 2,
          ),
          const SizedBox(height: 6),

          // Preset prompt chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                if (_enableSkills) ...[
                  ActionChip(
                    avatar: const Text('🧮'),
                    label: const Text('Math: 45 * 18 + sqrt(144)'),
                    onPressed: () =>
                        _promptController.text = 'What is 45 * 18 + sqrt(144)?',
                  ),
                  const SizedBox(width: 6),
                  ActionChip(
                    avatar: const Text('🕒'),
                    label: const Text('Clock: Current device time'),
                    onPressed: () => _promptController.text =
                        'What is the current device time and day of week?',
                  ),
                  const SizedBox(width: 6),
                  ActionChip(
                    avatar: const Text('🌤️'),
                    label: const Text('Weather: Tokyo forecast'),
                    onPressed: () => _promptController.text =
                        'What is the current weather in Tokyo?',
                  ),
                  const SizedBox(width: 6),
                  ActionChip(
                    avatar: const Text('📱'),
                    label: const Text('System: Device specs'),
                    onPressed: () => _promptController.text =
                        'Show device specifications and runtime info.',
                  ),
                  const SizedBox(width: 6),
                ] else ...[
                  ActionChip(
                    label: const Text('Explain on-device AI'),
                    onPressed: () => _promptController.text =
                        'Explain on-device AI in one sentence.',
                  ),
                  const SizedBox(width: 6),
                  ActionChip(
                    label: const Text('Write a Haiku'),
                    onPressed: () => _promptController.text =
                        'Write a haiku about local AI.',
                  ),
                  const SizedBox(width: 6),
                  ActionChip(
                    label: const Text('Why offline privacy?'),
                    onPressed: () => _promptController.text =
                        'Why is offline on-device AI better for privacy and security?',
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),

          // Action Buttons
          Row(
            children: [
              FilledButton.icon(
                onPressed: _isLlmDownloading ? null : _generate,
                icon: Icon(_isGenerating ? Icons.stop : Icons.bolt),
                label: Text(_isGenerating ? 'Stop' : 'Generate'),
              ),
              const Spacer(),
              if (_outputText.isNotEmpty)
                IconButton(
                  tooltip: 'Copy Output',
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _outputText));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Copied response to clipboard')),
                    );
                  },
                ),
              IconButton(
                tooltip: 'Clear Output',
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: () => setState(() {
                  _output.clear();
                  _outputText = '';
                  _lastToolCalls = [];
                  _lastToolResults = [];
                }),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Response output container
          Container(
            constraints: const BoxConstraints(minHeight: 220),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: _outputText.isEmpty && _lastToolCalls.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _isLlmDownloading
                            ? 'Model is downloading… Output will appear once download completes.'
                            : 'AI response output will stream here…',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_lastToolCalls.isNotEmpty) ...[
                        Container(
                          padding: const EdgeInsets.all(10),
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.secondaryContainer
                                .withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: theme.colorScheme.secondary
                                  .withValues(alpha: 0.3),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.handyman,
                                      size: 16,
                                      color: theme.colorScheme.secondary),
                                  const SizedBox(width: 6),
                                  Text(
                                    'MCP Tool Execution Trace (${_lastToolCalls.length} calls)',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: theme.colorScheme.secondary,
                                    ),
                                  ),
                                ],
                              ),
                              const Divider(height: 12),
                              for (var i = 0;
                                  i < _lastToolCalls.length;
                                  i++) ...[
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text('⚙️ ',
                                        style: TextStyle(fontSize: 12)),
                                    Expanded(
                                      child: Text(
                                        'Tool: ${_lastToolCalls[i].name} | Args: ${_lastToolCalls[i].arguments}',
                                        style: const TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                if (i < _lastToolResults.length) ...[
                                  const SizedBox(height: 2),
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text('📦 ',
                                          style: TextStyle(fontSize: 12)),
                                      Expanded(
                                        child: Text(
                                          'Output: ${_lastToolResults[i].content}',
                                          style: TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 11,
                                            color: theme
                                                .colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                                if (i < _lastToolCalls.length - 1)
                                  const SizedBox(height: 6),
                              ],
                            ],
                          ),
                        ),
                      ],
                      SelectableText(
                        _outputText,
                        style: const TextStyle(fontSize: 14, height: 1.4),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // 2. Text-to-Speech (TTS) Tab with Audio Player
  // ===========================================================================
  Widget _buildTtsTab(ThemeData theme) {
    final isTtsInstalled = _isModelInstalled(_selectedTtsId);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // TTS Model Selector Card
          Card(
            elevation: 0,
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.5),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.volume_up,
                          color: Colors.deepPurpleAccent),
                      const SizedBox(width: 8),
                      Text('Text-to-Speech Model & Parameters',
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _buildDropdownRow(
                    label: 'TTS Model',
                    icon: Icons.graphic_eq,
                    value: _selectedTtsId,
                    items: const [
                      DropdownMenuItem(
                          value: 'supertonic-tts',
                          child: Text(
                              'Supertonic 3 (Supertone Inc. • 31+ Languages • 398 MB)')),
                      DropdownMenuItem(
                          value: 'vits-piper-en-lessac',
                          child: Text('Piper TTS Lessac Low (67 MB)')),
                      DropdownMenuItem(
                          value: 'kokoro-en-tts',
                          child: Text('Kokoro TTS v0.19 (319 MB)')),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setState(() => _selectedTtsId = val);
                        _bootstrap();
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  // Model installation badge & download button
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: isTtsInstalled
                          ? Colors.green.withValues(alpha: 0.1)
                          : Colors.amber.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: isTtsInstalled
                              ? Colors.green.withValues(alpha: 0.3)
                              : Colors.amber.withValues(alpha: 0.5)),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          isTtsInstalled
                              ? Icons.check_circle
                              : Icons.warning_amber_rounded,
                          size: 16,
                          color: isTtsInstalled
                              ? Colors.green
                              : Colors.amber.shade800,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            isTtsInstalled
                                ? '$_selectedTtsId is installed and ready for speech playback.'
                                : '⚠️ $_selectedTtsId is not downloaded yet.',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: isTtsInstalled
                                  ? Colors.green.shade800
                                  : Colors.amber.shade900,
                            ),
                          ),
                        ),
                        if (!isTtsInstalled)
                          FilledButton.tonal(
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 2),
                            ),
                            onPressed: () => _installModel(_selectedTtsId),
                            child: const Text('Download Model',
                                style: TextStyle(fontSize: 11)),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Language & Voice Style Selectors
                  Row(
                    children: [
                      // Language Dropdown
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          key: ValueKey('lang-$_ttsLanguage'),
                          initialValue: _ttsLanguage,
                          decoration: InputDecoration(
                            labelText: 'Spoken Language',
                            prefixIcon: const Icon(Icons.language, size: 20),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8)),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                          ),
                          items: const [
                            DropdownMenuItem(
                                value: 'ja',
                                child: Text('🇯🇵 Japanese (日本語)')),
                            DropdownMenuItem(
                                value: 'en', child: Text('🇺🇸 English (US)')),
                            DropdownMenuItem(
                                value: 'ko', child: Text('🇰🇷 Korean (한국어)')),
                            DropdownMenuItem(
                                value: 'zh', child: Text('🇨🇳 Chinese (中文)')),
                            DropdownMenuItem(
                                value: 'es',
                                child: Text('🇪🇸 Spanish (Español)')),
                            DropdownMenuItem(
                                value: 'fr',
                                child: Text('🇫🇷 French (Français)')),
                            DropdownMenuItem(
                                value: 'de',
                                child: Text('🇩🇪 German (Deutsch)')),
                            DropdownMenuItem(
                                value: 'it',
                                child: Text('🇮🇹 Italian (Italiano)')),
                            DropdownMenuItem(
                                value: 'pt',
                                child: Text('🇵🇹 Portuguese (Português)')),
                            DropdownMenuItem(
                                value: 'ru',
                                child: Text('🇷🇺 Russian (Русский)')),
                            DropdownMenuItem(
                                value: 'hi',
                                child: Text('🇮🇳 Hindi (हिन्दी)')),
                            DropdownMenuItem(
                                value: 'ar',
                                child: Text('🇦🇪 Arabic (العربية)')),
                            DropdownMenuItem(
                                value: 'nl',
                                child: Text('🇳🇱 Dutch (Nederlands)')),
                            DropdownMenuItem(
                                value: 'pl',
                                child: Text('🇵🇱 Polish (Polski)')),
                            DropdownMenuItem(
                                value: 'tr',
                                child: Text('🇹🇷 Turkish (Türkçe)')),
                            DropdownMenuItem(
                                value: 'sv',
                                child: Text('🇸🇪 Swedish (Svenska)')),
                            DropdownMenuItem(
                                value: 'vi',
                                child: Text('🇻🇳 Vietnamese (Tiếng Việt)')),
                            DropdownMenuItem(
                                value: 'id',
                                child: Text('🇮🇩 Indonesian (Bahasa)')),
                            DropdownMenuItem(
                                value: 'th', child: Text('🇹🇭 Thai (ไทย)')),
                          ],
                          onChanged: (val) {
                            if (val != null) {
                              setState(() {
                                _ttsLanguage = val;
                                if (_samplePhrases.containsKey(val)) {
                                  _ttsTextController.text =
                                      _samplePhrases[val]!;
                                }
                              });
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 12),

                      // Speaker / Voice Style Dropdown
                      Builder(
                        builder: (context) {
                          final List<DropdownMenuItem<String>> voiceItems =
                              _selectedTtsId == 'supertonic-tts'
                                  ? const [
                                      DropdownMenuItem(
                                          value: 'default',
                                          child:
                                              Text('Auto Matching (Default)')),
                                      DropdownMenuItem(
                                          value: 'f1',
                                          child: Text(
                                              'F1 (Female • Soft Natural)')),
                                      DropdownMenuItem(
                                          value: 'f2',
                                          child: Text(
                                              'F2 (Female • Bright Expressive)')),
                                      DropdownMenuItem(
                                          value: 'f3',
                                          child: Text(
                                              'F3 (Female • Calm Narrative)')),
                                      DropdownMenuItem(
                                          value: 'f4',
                                          child: Text(
                                              'F4 (Female • Warm Friendly)')),
                                      DropdownMenuItem(
                                          value: 'f5',
                                          child: Text(
                                              'F5 (Female • Clear Professional)')),
                                      DropdownMenuItem(
                                          value: 'm1',
                                          child: Text(
                                              'M1 (Male • Deep Resonant)')),
                                      DropdownMenuItem(
                                          value: 'm2',
                                          child: Text(
                                              'M2 (Male • Friendly Casual)')),
                                      DropdownMenuItem(
                                          value: 'm3',
                                          child: Text(
                                              'M3 (Male • Confident Dynamic)')),
                                      DropdownMenuItem(
                                          value: 'm4',
                                          child: Text(
                                              'M4 (Male • Warm Storyteller)')),
                                      DropdownMenuItem(
                                          value: 'm5',
                                          child:
                                              Text('M5 (Male • Clear Anchor)')),
                                    ]
                                  : (_selectedTtsId == 'kokoro-en-tts'
                                      ? const [
                                          DropdownMenuItem(
                                              value: 'default',
                                              child: Text('Heart (Default)')),
                                          DropdownMenuItem(
                                              value: 'bella',
                                              child: Text('Bella (Female)')),
                                          DropdownMenuItem(
                                              value: 'nicole',
                                              child: Text('Nicole (Female)')),
                                          DropdownMenuItem(
                                              value: 'sarah',
                                              child: Text('Sarah (Female)')),
                                          DropdownMenuItem(
                                              value: 'adam',
                                              child: Text('Adam (Male)')),
                                          DropdownMenuItem(
                                              value: 'michael',
                                              child: Text('Michael (Male)')),
                                        ]
                                      : const [
                                          DropdownMenuItem(
                                              value: 'default',
                                              child:
                                                  Text('Lessac Low (Default)')),
                                        ]);

                          final effectiveVoice = voiceItems
                                  .any((item) => item.value == _ttsVoiceStyle)
                              ? _ttsVoiceStyle
                              : 'default';

                          return Expanded(
                            child: DropdownButtonFormField<String>(
                              key: ValueKey(
                                  'style-$_selectedTtsId-$effectiveVoice'),
                              initialValue: effectiveVoice,
                              decoration: InputDecoration(
                                labelText: 'Speaker Voice Style',
                                prefixIcon: const Icon(Icons.record_voice_over,
                                    size: 20),
                                border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8)),
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
                              ),
                              items: voiceItems,
                              onChanged: (val) {
                                if (val != null) {
                                  setState(() => _ttsVoiceStyle = val);
                                }
                              },
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Speed slider
                  Row(
                    children: [
                      const Icon(Icons.speed, size: 18),
                      const SizedBox(width: 8),
                      Text('Speed: ${_ttsSpeed.toStringAsFixed(1)}x',
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 13)),
                      Expanded(
                        child: Slider(
                          value: _ttsSpeed,
                          min: 0.5,
                          max: 2.0,
                          divisions: 15,
                          label: '${_ttsSpeed.toStringAsFixed(1)}x',
                          onChanged: (val) => setState(() => _ttsSpeed = val),
                        ),
                      ),
                    ],
                  ),
                  // Pitch slider
                  Row(
                    children: [
                      const Icon(Icons.tune, size: 18),
                      const SizedBox(width: 8),
                      Text('Pitch: ${_ttsPitch.toStringAsFixed(1)}x',
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 13)),
                      Expanded(
                        child: Slider(
                          value: _ttsPitch,
                          min: 0.5,
                          max: 1.5,
                          divisions: 10,
                          label: '${_ttsPitch.toStringAsFixed(1)}x',
                          onChanged: (val) => setState(() => _ttsPitch = val),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Text to synthesize input
          TextField(
            controller: _ttsTextController,
            decoration: InputDecoration(
              labelText: 'Text to Synthesize',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.clear, size: 18),
                onPressed: () => _ttsTextController.clear(),
              ),
            ),
            maxLines: 3,
          ),
          const SizedBox(height: 8),

          // Multilingual Quick Sample Chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ActionChip(
                  avatar: const Text('🇯🇵'),
                  label: const Text('日本語 Japanese'),
                  onPressed: () => setState(() {
                    _ttsLanguage = 'ja';
                    _ttsTextController.text = _samplePhrases['ja']!;
                  }),
                ),
                const SizedBox(width: 6),
                ActionChip(
                  avatar: const Text('🇺🇸'),
                  label: const Text('English (US)'),
                  onPressed: () => setState(() {
                    _ttsLanguage = 'en';
                    _ttsTextController.text = _samplePhrases['en']!;
                  }),
                ),
                const SizedBox(width: 6),
                ActionChip(
                  avatar: const Text('🇰🇷'),
                  label: const Text('한국어 Korean'),
                  onPressed: () => setState(() {
                    _ttsLanguage = 'ko';
                    _ttsTextController.text = _samplePhrases['ko']!;
                  }),
                ),
                const SizedBox(width: 6),
                ActionChip(
                  avatar: const Text('🇨🇳'),
                  label: const Text('中文 Chinese'),
                  onPressed: () => setState(() {
                    _ttsLanguage = 'zh';
                    _ttsTextController.text = _samplePhrases['zh']!;
                  }),
                ),
                const SizedBox(width: 6),
                ActionChip(
                  avatar: const Text('🇪🇸'),
                  label: const Text('Español Spanish'),
                  onPressed: () => setState(() {
                    _ttsLanguage = 'es';
                    _ttsTextController.text = _samplePhrases['es']!;
                  }),
                ),
                const SizedBox(width: 6),
                ActionChip(
                  avatar: const Text('🇫🇷'),
                  label: const Text('Français French'),
                  onPressed: () => setState(() {
                    _ttsLanguage = 'fr';
                    _ttsTextController.text = _samplePhrases['fr']!;
                  }),
                ),
                const SizedBox(width: 6),
                ActionChip(
                  avatar: const Text('🇩🇪'),
                  label: const Text('Deutsch German'),
                  onPressed: () => setState(() {
                    _ttsLanguage = 'de';
                    _ttsTextController.text = _samplePhrases['de']!;
                  }),
                ),
                const SizedBox(width: 6),
                ActionChip(
                  avatar: const Text('🇮🇹'),
                  label: const Text('Italiano Italian'),
                  onPressed: () => setState(() {
                    _ttsLanguage = 'it';
                    _ttsTextController.text = _samplePhrases['it']!;
                  }),
                ),
                const SizedBox(width: 6),
                ActionChip(
                  avatar: const Text('🇮🇳'),
                  label: const Text('हिन्दी Hindi'),
                  onPressed: () => setState(() {
                    _ttsLanguage = 'hi';
                    _ttsTextController.text = _samplePhrases['hi']!;
                  }),
                ),
                const SizedBox(width: 6),
                ActionChip(
                  avatar: const Text('🇷🇺'),
                  label: const Text('Русский Russian'),
                  onPressed: () => setState(() {
                    _ttsLanguage = 'ru';
                    _ttsTextController.text = _samplePhrases['ru']!;
                  }),
                ),
                const SizedBox(width: 6),
                ActionChip(
                  avatar: const Text('🇦🇪'),
                  label: const Text('العربية Arabic'),
                  onPressed: () => setState(() {
                    _ttsLanguage = 'ar';
                    _ttsTextController.text = _samplePhrases['ar']!;
                  }),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Action Buttons
          Row(
            children: [
              FilledButton.icon(
                onPressed: _isTtsSynthesizing ? _stopTts : _synthesizeTts,
                icon: Icon(_isTtsSynthesizing ? Icons.stop : Icons.volume_up),
                label: Text(_isTtsSynthesizing
                    ? 'Stop Playback'
                    : 'Synthesize & Play Speech'),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: () => setState(() {
                  _ttsTextController.clear();
                  _ttsAudioChunks = 0;
                  _ttsSampleCount = 0;
                  _ttsPlaybackProgress = 0.0;
                  _ttsStatus = 'Ready to synthesize speech.';
                }),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Clear'),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Dedicated Interactive Audio Player Card
          Card(
            elevation: 2,
            color: theme.colorScheme.surfaceContainerLowest,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                color: _isTtsPlaying
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outlineVariant,
                width: _isTtsPlaying ? 2 : 1,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _isTtsPlaying
                              ? Colors.deepPurpleAccent
                              : theme.colorScheme.primaryContainer,
                        ),
                        child: Icon(
                          _isTtsPlaying ? Icons.graphic_eq : Icons.play_arrow,
                          color: _isTtsPlaying
                              ? Colors.white
                              : theme.colorScheme.onPrimaryContainer,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _isTtsPlaying
                                  ? '🔊 Audio Player: Playing Speech…'
                                  : 'Audio Player: Ready',
                              style: theme.textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            Text(
                              _ttsStatus,
                              style: TextStyle(
                                fontSize: 12,
                                color: _isTtsPlaying
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Animated Waveform Display
                  Container(
                    height: 48,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: List.generate(28, (index) {
                        final factor =
                            sin((index * 0.4) + (_ttsPlaybackProgress * 12))
                                .abs();
                        final barHeight =
                            _isTtsPlaying ? (8.0 + (factor * 32.0)) : 10.0;
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 100),
                          width: 4,
                          height: barHeight,
                          decoration: BoxDecoration(
                            color: _isTtsPlaying
                                ? (index / 28 <= _ttsPlaybackProgress
                                    ? Colors.deepPurpleAccent
                                    : Colors.deepPurple.shade200)
                                : theme.colorScheme.outlineVariant,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        );
                      }),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // Player Progress Bar
                  LinearProgressIndicator(
                    value:
                        _ttsPlaybackProgress > 0 ? _ttsPlaybackProgress : 0.0,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      _isTtsPlaying
                          ? Colors.deepPurpleAccent
                          : theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Stat Badges
                  Row(
                    children: [
                      _buildStatChip('Audio Chunks', '$_ttsAudioChunks'),
                      const SizedBox(width: 8),
                      _buildStatChip('Float32 Samples', '$_ttsSampleCount'),
                      const SizedBox(width: 8),
                      _buildStatChip('Format', 'PCM 22kHz Mono'),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatChip(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.deepPurpleAccent.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
          Text(value,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.deepPurpleAccent)),
        ],
      ),
    );
  }

  // ===========================================================================
  // 3. Voice Pipeline Tab (VAD -> STT -> LLM -> TTS)
  // ===========================================================================
  Widget _buildVoiceTab(ThemeData theme) {
    final isVoiceActive = _voiceSession != null;

    final isVadInstalled = _isModelInstalled(_selectedVadId);
    final isSttInstalled = _isModelInstalled(_selectedSttId);
    final isLlmInstalled = _isModelInstalled(_selectedLlmId);
    final isTtsInstalled = _isModelInstalled(_selectedTtsId);
    final allVoiceModelsInstalled =
        isVadInstalled && isSttInstalled && isLlmInstalled && isTtsInstalled;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Voice Pipeline Setup Card
          Card(
            elevation: 0,
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.5),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.settings_voice,
                          color: Colors.deepPurpleAccent),
                      const SizedBox(width: 8),
                      Text('Voice Pipeline Configuration',
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // VAD Selector
                  _buildDropdownRow(
                    label: '1. Voice Activity Detection (VAD)',
                    icon: Icons.graphic_eq,
                    value: _selectedVadId,
                    items: const [
                      DropdownMenuItem(
                          value: 'silero-vad',
                          child: Text('Silero VAD (643 KB)')),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setState(() => _selectedVadId = val);
                        _bootstrap();
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  // STT Selector
                  _buildDropdownRow(
                    label: '2. Speech-to-Text (STT)',
                    icon: Icons.record_voice_over,
                    value: _selectedSttId,
                    items: const [
                      DropdownMenuItem(
                          value: 'sherpa-onnx-whisper-base.en',
                          child: Text('Whisper Base English (75 MB - OpenAI)')),
                      DropdownMenuItem(
                          value: 'sherpa-onnx-whisper-tiny.en',
                          child: Text('Whisper Tiny English (40 MB - OpenAI)')),
                      DropdownMenuItem(
                          value: 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue',
                          child: Text(
                              'SenseVoice Small (234 MB - Multilingual EN/JA/ZH/KO)')),
                      DropdownMenuItem(
                          value: 'sherpa-onnx-moonshine-tiny-en',
                          child:
                              Text('Moonshine Tiny English (30 MB - NextGen)')),
                      DropdownMenuItem(
                          value: 'sherpa-onnx-streaming-zipformer-en-20m',
                          child: Text('Zipformer Small English (70 MB)')),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setState(() => _selectedSttId = val);
                        _bootstrap();
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  // LLM Selector
                  _buildDropdownRow(
                    label: '3. LLM Reasoning',
                    icon: Icons.psychology,
                    value: _selectedLlmId,
                    items: const [
                      DropdownMenuItem(
                          value: 'smollm2-360m-instruct',
                          child: Text('SmolLM2 360M (LiteRT-LM 373 MB)')),
                      DropdownMenuItem(
                          value: 'qwen-3.5-0.8b-instruct',
                          child: Text('Qwen 3.5 0.8B (LiteRT-LM 963 MB)')),
                      DropdownMenuItem(
                          value: 'qwen-3.5-2b-instruct',
                          child: Text('Qwen 3.5 2B (LiteRT-LM 2.11 GB)')),
                      DropdownMenuItem(
                          value: 'qwen-3.5-4b-instruct',
                          child: Text('Qwen 3.5 4B (LiteRT-LM 4.40 GB)')),
                      DropdownMenuItem(
                          value: 'qwen-2.5-0.5b-instruct',
                          child: Text('Qwen 2.5 0.5B (MediaPipe 546 MB)')),
                      DropdownMenuItem(
                          value: 'deepseek-r1-1.5b-int4',
                          child: Text('DeepSeek R1 1.5B (MediaPipe 1.86 GB)')),
                      DropdownMenuItem(
                          value: 'gemma-4-e2b-it',
                          child: Text('Gemma 4 E2B (LiteRT-LM 2.59 GB)')),
                      DropdownMenuItem(
                          value: 'gemma-4-e4b-it',
                          child: Text('Gemma 4 E4B (LiteRT-LM 3.66 GB)')),
                      DropdownMenuItem(
                          value: 'gemma-3n-e2b-it-int4',
                          child: Text('Gemma 3n E2B (LiteRT-LM 2.59 GB)')),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setState(() => _selectedLlmId = val);
                        _bootstrap();
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  // TTS Selector
                  _buildDropdownRow(
                    label: '4. Text-to-Speech (TTS)',
                    icon: Icons.volume_up,
                    value: _selectedTtsId,
                    items: const [
                      DropdownMenuItem(
                          value: 'supertonic-tts',
                          child: Text('Supertonic 3 (31+ Langs • 398 MB)')),
                      DropdownMenuItem(
                          value: 'vits-piper-en-lessac',
                          child: Text('Piper TTS Lessac (67 MB)')),
                      DropdownMenuItem(
                          value: 'kokoro-en-tts',
                          child: Text('Kokoro TTS v0.19 (319 MB)')),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setState(() => _selectedTtsId = val);
                        _bootstrap();
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Model Readiness Checks & Notification Card
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: allVoiceModelsInstalled
                  ? Colors.green.withValues(alpha: 0.1)
                  : Colors.amber.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: allVoiceModelsInstalled
                    ? Colors.green.withValues(alpha: 0.3)
                    : Colors.amber.withValues(alpha: 0.5),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      allVoiceModelsInstalled
                          ? Icons.check_circle
                          : Icons.warning_amber_rounded,
                      color: allVoiceModelsInstalled
                          ? Colors.green
                          : Colors.amber.shade800,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        allVoiceModelsInstalled
                            ? 'All voice pipeline models are installed and ready!'
                            : '⚠️ Some voice pipeline models are missing. Download required to start.',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: allVoiceModelsInstalled
                              ? Colors.green.shade800
                              : Colors.amber.shade900,
                        ),
                      ),
                    ),
                    if (!allVoiceModelsInstalled)
                      FilledButton.tonal(
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 2),
                        ),
                        onPressed: _isVoiceDownloading
                            ? null
                            : _downloadMissingVoiceModels,
                        child: Text(_isVoiceDownloading
                            ? 'Downloading…'
                            : 'Download Missing'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    _buildModelStatusPill('VAD', isVadInstalled),
                    _buildModelStatusPill('STT', isSttInstalled),
                    _buildModelStatusPill('LLM', isLlmInstalled),
                    _buildModelStatusPill('TTS', isTtsInstalled),
                  ],
                ),
                if (_isVoiceDownloading) ...[
                  const SizedBox(height: 8),
                  const LinearProgressIndicator(),
                  const SizedBox(height: 4),
                  Text(_voiceDownloadStatus,
                      style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.bold)),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Central Microphone Action Orb
          Center(
            child: Column(
              children: [
                GestureDetector(
                  onTap: _toggleVoice,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    width: 90,
                    height: 90,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isVoiceActive
                          ? Colors.redAccent
                          : (allVoiceModelsInstalled
                              ? theme.colorScheme.primary
                              : Colors.grey),
                      boxShadow: [
                        BoxShadow(
                          color: (isVoiceActive
                                  ? Colors.redAccent
                                  : theme.colorScheme.primary)
                              .withValues(alpha: 0.4),
                          blurRadius: isVoiceActive ? 20 : 8,
                          spreadRadius: isVoiceActive ? 4 : 1,
                        ),
                      ],
                    ),
                    child: Icon(
                      isVoiceActive ? Icons.stop : Icons.mic,
                      color: Colors.white,
                      size: 42,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  isVoiceActive
                      ? 'Voice Assistant Active (Click to Stop)'
                      : (allVoiceModelsInstalled
                          ? 'Tap Microphone to Start Voice Chat'
                          : 'Download Missing Models to Enable Voice Chat'),
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  _voiceStatus,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: isVoiceActive
                        ? Colors.greenAccent.shade700
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Live Transcript & Assistant Spoken Output Box
          Card(
            elevation: 0,
            color: theme.colorScheme.surfaceContainerLowest,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.record_voice_over,
                          size: 18, color: Colors.blueAccent),
                      const SizedBox(width: 8),
                      Text('User Transcript',
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _voiceTranscript.isNotEmpty
                        ? _voiceTranscript
                        : 'Awaiting speech input…',
                    style: TextStyle(
                      fontSize: 14,
                      color: _voiceTranscript.isNotEmpty
                          ? theme.colorScheme.onSurface
                          : theme.colorScheme.onSurfaceVariant,
                      fontStyle: _voiceTranscript.isEmpty
                          ? FontStyle.italic
                          : FontStyle.normal,
                    ),
                  ),
                  const Divider(height: 24),
                  Row(
                    children: [
                      const Icon(Icons.volume_up,
                          size: 18, color: Colors.deepPurpleAccent),
                      const SizedBox(width: 8),
                      Text('Assistant Spoken Response',
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _voiceReply.isNotEmpty
                        ? _voiceReply
                        : 'Awaiting response synthesis…',
                    style: TextStyle(
                      fontSize: 14,
                      color: _voiceReply.isNotEmpty
                          ? theme.colorScheme.onSurface
                          : theme.colorScheme.onSurfaceVariant,
                      fontStyle: _voiceReply.isEmpty
                          ? FontStyle.italic
                          : FontStyle.normal,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModelStatusPill(String component, bool installed) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: installed
            ? Colors.green.withValues(alpha: 0.15)
            : Colors.red.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
            color: installed
                ? Colors.green.withValues(alpha: 0.4)
                : Colors.red.withValues(alpha: 0.4)),
      ),
      child: Text(
        '$component: ${installed ? 'Installed ✅' : 'Missing ⚠️'}',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: installed ? Colors.green.shade900 : Colors.red.shade900,
        ),
      ),
    );
  }

  Widget _buildDropdownRow({
    required String label,
    required IconData icon,
    required String value,
    required List<DropdownMenuItem<String>> items,
    required void Function(String?) onChanged,
  }) {
    return Row(
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 8),
        Text(label,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        const Spacer(),
        DropdownButton<String>(
          value: items.any((i) => i.value == value) ? value : items.first.value,
          items: items,
          onChanged: onChanged,
          isDense: true,
        ),
      ],
    );
  }

  // ===========================================================================
  // 4. Model Catalog & Storage Manager Tab
  // ===========================================================================
  Widget _buildCatalogTab(ThemeData theme) {
    if (_catalogModels.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            const Text('Loading model catalog…'),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: _refreshCatalog,
              child: const Text('Reload Catalog'),
            ),
          ],
        ),
      );
    }

    final llmModels =
        _catalogModels.where((m) => m.type == ModelType.llm).toList();
    final vadModels =
        _catalogModels.where((m) => m.type == ModelType.vad).toList();
    final sttModels =
        _catalogModels.where((m) => m.type == ModelType.stt).toList();
    final ttsModels =
        _catalogModels.where((m) => m.type == ModelType.tts).toList();

    return RefreshIndicator(
      onRefresh: _refreshCatalog,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _buildCategorySection(
              '🧠 Large Language Models (LLM)', llmModels, theme),
          const SizedBox(height: 12),
          _buildCategorySection(
              '🎙️ Voice Activity Detection (VAD)', vadModels, theme),
          const SizedBox(height: 12),
          _buildCategorySection(
              '🗣️ Speech Recognition (STT)', sttModels, theme),
          const SizedBox(height: 12),
          _buildCategorySection('📢 Text-to-Speech (TTS)', ttsModels, theme),
        ],
      ),
    );
  }

  Widget _buildCategorySection(
      String title, List<LocalModelManifest> models, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          child: Text(
            '$title (${models.length})',
            style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold, color: theme.colorScheme.primary),
          ),
        ),
        ...models.map((model) => _buildModelCard(model, theme)),
      ],
    );
  }

  Widget _buildModelCard(LocalModelManifest model, ThemeData theme) {
    final status = _modelStatuses[model.id];
    final progress = _modelDownloadProgress[model.id];
    final speed = _modelDownloadSpeed[model.id] ?? '';
    final isInstalled = status?.isInstalled ?? false;
    final isDownloading = progress != null;

    final sizeMB = (model.totalSizeBytes / (1024 * 1024))
        .toStringAsFixed(model.totalSizeBytes > 100 * 1024 * 1024 ? 0 : 1);

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        model.displayName ?? model.id,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                      Text(
                        'ID: ${model.id} • Provider: ${model.provider} • Size: $sizeMB MB',
                        style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (isInstalled)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text('Installed ✅',
                        style: TextStyle(
                            color: Colors.green,
                            fontSize: 11,
                            fontWeight: FontWeight.bold)),
                  ),
              ],
            ),
            if (model.description != null) ...[
              const SizedBox(height: 4),
              Text(model.description!,
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
            ],
            if (isDownloading) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: progress > 0 ? progress : null),
              const SizedBox(height: 4),
              Text(
                'Downloading ${(progress * 100).toStringAsFixed(0)}% $speed',
                style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.bold),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (isInstalled)
                  OutlinedButton.icon(
                    onPressed: () => _uninstallModel(model.id),
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('Delete / Free Space'),
                  )
                else
                  FilledButton.tonalIcon(
                    onPressed:
                        isDownloading ? null : () => _installModel(model.id),
                    icon: const Icon(Icons.download, size: 16),
                    label: Text(isDownloading
                        ? 'Downloading…'
                        : 'Download ($sizeMB MB)'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // 5. Live Debug Terminal Tab
  // ===========================================================================
  Widget _buildLogsTab(ThemeData theme) {
    return StreamBuilder<List<LogEntry>>(
      stream: AppLogger.stream,
      initialData: AppLogger.logs,
      builder: (context, snapshot) {
        final logs = snapshot.data ?? [];
        final filteredLogs = _logFilter.isEmpty
            ? logs
            : logs
                .where((l) =>
                    l.tag.toLowerCase().contains(_logFilter.toLowerCase()) ||
                    l.message.toLowerCase().contains(_logFilter.toLowerCase()))
                .toList();

        return Container(
          color: Colors.black,
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              // Search / Action toolbar
              Row(
                children: [
                  const Icon(Icons.terminal, color: Colors.greenAccent),
                  const SizedBox(width: 8),
                  const Text('Live Debug Terminal',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Copy all logs',
                    icon:
                        const Icon(Icons.copy, color: Colors.white70, size: 18),
                    onPressed: () {
                      final text = logs
                          .map((l) =>
                              '[${l.formatTime()}] [${l.tag}] ${l.message}')
                          .join('\n');
                      Clipboard.setData(ClipboardData(text: text));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('All logs copied to clipboard')),
                      );
                    },
                  ),
                  IconButton(
                    tooltip: 'Clear terminal',
                    icon: const Icon(Icons.delete_outline,
                        color: Colors.white70, size: 18),
                    onPressed: () {
                      AppLogger.clear();
                      setState(() {});
                    },
                  ),
                ],
              ),
              const Divider(color: Colors.white24),
              // Search input
              TextField(
                controller: _logSearchController,
                style: const TextStyle(color: Colors.white, fontSize: 12),
                decoration: InputDecoration(
                  hintText:
                      'Filter logs by tag (INIT, GENERATE, VOICE, TTS, DOWNLOAD, ERROR)…',
                  hintStyle:
                      const TextStyle(color: Colors.white38, fontSize: 12),
                  isDense: true,
                  prefixIcon:
                      const Icon(Icons.search, color: Colors.white38, size: 16),
                  suffixIcon: _logFilter.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear,
                              color: Colors.white38, size: 16),
                          onPressed: () {
                            _logSearchController.clear();
                            setState(() => _logFilter = '');
                          },
                        )
                      : null,
                ),
                onChanged: (val) => setState(() => _logFilter = val),
              ),
              const SizedBox(height: 8),
              // Log content
              Expanded(
                child: filteredLogs.isEmpty
                    ? const Center(
                        child: Text('No logs matching filter',
                            style: TextStyle(color: Colors.white38)))
                    : ListView.builder(
                        controller: _logScrollController,
                        itemCount: filteredLogs.length,
                        itemBuilder: (context, index) {
                          final log = filteredLogs[index];
                          final color = switch (log.level) {
                            LogLevel.error => Colors.redAccent,
                            LogLevel.warning => Colors.orangeAccent,
                            LogLevel.success => Colors.greenAccent,
                            LogLevel.info => Colors.lightBlueAccent,
                          };

                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '[${log.formatTime()}] ',
                                  style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 11,
                                      color: Colors.grey),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 4, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: color.withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Text(
                                    log.tag,
                                    style: TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: color),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    log.message,
                                    style: const TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 11,
                                        color: Colors.white),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
