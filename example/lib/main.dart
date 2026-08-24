/// Minimal LocalAI Kit demo: offline text chat + a voice-conversation
/// button (Mic → VAD → STT → LLM → TTS with barge-in).
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:local_ai_gemma/local_ai_gemma.dart';
import 'package:local_ai_kit/local_ai_kit.dart';
import 'package:local_ai_sherpa/local_ai_sherpa.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LocalAIDemoApp());
}

class LocalAIDemoApp extends StatelessWidget {
  const LocalAIDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'LocalAI Kit Demo',
      home: DemoHomePage(),
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

  final _promptController = TextEditingController(
      text: 'Explain on-device AI in one sentence.');
  final _output = StringBuffer();
  String _status = 'initializing…';
  double _downloadProgress = 0;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      // 1. Configure: full voice assistant preset + adapter plugins.
      //    Adapters are registered explicitly so unused native runtimes
      //    stay out of the binary (architecture §4.5).
      final ai = await LocalAI.initialize(
        LocalAIConfig.voiceAssistant(),
        plugins: const [
          GemmaAdapterPlugin(),
          SherpaAdapterPlugin(),
        ],
      );

      // 2. Watch model download progress (first run downloads models).
      final modelId = ai.config.llm!.modelId;
      ai.models.downloadProgress(modelId).listen((progress) {
        setState(() {
          _downloadProgress = progress.fraction;
          _status = 'downloading ${progress.currentFile ?? modelId} '
              '${(progress.fraction * 100).toStringAsFixed(0)}%';
        });
      });

      setState(() {
        _ai = ai;
        _status = 'ready (models download lazily on first use)';
      });
    } on LocalAIError catch (e) {
      setState(() => _status = 'init failed: ${e.message}');
    }
  }

  Future<void> _generate() async {
    final ai = _ai;
    if (ai == null) return;
    setState(() {
      _output.clear();
      _status = 'generating…';
    });
    try {
      // 3. Streaming text generation through the facade.
      final chunks = await ai.generateStream(LlmRequest.prompt(
        _promptController.text,
        systemPrompt: 'You are a concise on-device assistant.',
      ));
      await for (final chunk in chunks) {
        setState(() => _output.write(chunk.textDelta));
      }
      setState(() => _status = 'done');
    } on LocalAIError catch (e) {
      setState(() => _status = 'error: ${e.message}');
    }
  }

  Future<void> _toggleVoice() async {
    final ai = _ai;
    if (ai == null) return;
    final existing = _voiceSession;
    if (existing != null) {
      await existing.stop();
      setState(() {
        _voiceSession = null;
        _status = 'voice session stopped';
      });
      return;
    }
    try {
      // 4. Full-duplex voice session with barge-in.
      final session = await ai.voice.start(
        sessionConfig: const VoiceSessionConfig(
          systemPrompt: 'You are a concise voice assistant.',
        ),
      );
      session.events.listen((event) {
        setState(() => _status = switch (event) {
              VoiceListening() => 'listening…',
              VoiceSpeechStarted() => 'speech detected',
              VoiceTranscriptUpdated(:final text) => 'heard: $text',
              VoiceThinking() => 'thinking…',
              VoiceResponseDelta(:final textDelta) => () {
                  _output.write(textDelta);
                  return 'responding…';
                }(),
              VoiceSpeaking() => 'speaking…',
              VoiceInterrupted() => 'interrupted (barge-in)',
              VoiceErrorOccurred(:final error) => 'error: ${error.message}',
              _ => 'voice: ${event.runtimeType}',
            });
      });
      setState(() {
        _voiceSession = session;
        _status = 'listening…';
      });
    } on LocalAIError catch (e) {
      setState(() => _status = 'voice unavailable: ${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _downloadProgress > 0 && _downloadProgress < 1;
    return Scaffold(
      appBar: AppBar(title: const Text('LocalAI Kit Demo')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_status),
            if (busy) LinearProgressIndicator(value: _downloadProgress),
            const SizedBox(height: 12),
            TextField(
              controller: _promptController,
              decoration: const InputDecoration(
                labelText: 'Prompt',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _generate,
                  icon: const Icon(Icons.bolt),
                  label: const Text('Generate'),
                ),
                const SizedBox(width: 12),
                FilledButton.tonalIcon(
                  onPressed: _toggleVoice,
                  icon: Icon(
                      _voiceSession == null ? Icons.mic : Icons.mic_off),
                  label: Text(
                      _voiceSession == null ? 'Voice chat' : 'Stop voice'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(_output.toString()),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _voiceSession?.stop();
    _ai?.dispose();
    _promptController.dispose();
    super.dispose();
  }
}