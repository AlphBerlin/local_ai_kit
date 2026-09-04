import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_kit/local_ai_kit.dart';
import 'package:local_ai_kit_example/main.dart';

void main() {
  test('STT capture buffer preserves frames for one-shot transcription', () {
    final capture = SttCaptureBuffer();
    final timestamp = DateTime(2026, 1, 1);
    capture.add(AudioFrame(
      samples: Float32List.fromList([0.1, 0.2]),
      format: AudioFormat.pcm16kMono,
      timestamp: timestamp,
    ));
    capture.add(AudioFrame(
      samples: Float32List.fromList([0.3]),
      format: AudioFormat.pcm16kMono,
      timestamp: timestamp.add(const Duration(milliseconds: 1)),
    ));

    final buffer = capture.toAudioBuffer();

    expect(capture.frameCount, 2);
    expect(buffer.samples[0], closeTo(0.1, 0.000001));
    expect(buffer.samples[1], closeTo(0.2, 0.000001));
    expect(buffer.samples[2], closeTo(0.3, 0.000001));
    expect(buffer.format, AudioFormat.pcm16kMono);
  });

  test('demo STT options include every catalog STT model', () {
    final catalogSttIds = Models.all
        .where((manifest) => manifest.type == ModelType.stt)
        .map((manifest) => manifest.id)
        .toSet();
    final demoSttIds =
        demoSttModelManifests.map((manifest) => manifest.id).toSet();

    expect(demoSttIds, catalogSttIds);
    expect(
      demoSttIds,
      containsAll(<String>[
        Models.moonshineTinyV2En.id,
        Models.moonshineTinyV2Ja.id,
        Models.moonshineTinyV2Ko.id,
        Models.moonshineBaseV2Ar.id,
        Models.moonshineBaseV2En.id,
        Models.moonshineBaseV2Es.id,
        Models.moonshineBaseV2Ja.id,
        Models.moonshineBaseV2Uk.id,
        Models.moonshineBaseV2Vi.id,
        Models.moonshineBaseV2Zh.id,
        Models.dolphinBase.id,
        Models.dolphinBaseInt8.id,
      ]),
    );
  });

  test('demo LLM options include every catalog LLM model', () {
    final catalogLlmIds = Models.all
        .where((manifest) => manifest.type == ModelType.llm)
        .map((manifest) => manifest.id)
        .toSet();
    final demoLlmIds =
        demoLlmModelManifests.map((manifest) => manifest.id).toSet();

    expect(demoLlmIds, catalogLlmIds);
    expect(
      demoLlmIds,
      containsAll(<String>[
        Models.qwen25_05bGguf.id,
        Models.llama32_1bGguf.id,
        Models.smollm2_360mGguf.id,
      ]),
    );
  });

  testWidgets('LocalAIDemoApp renders initial UI elements and MCP controls',
      (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const LocalAIDemoApp());

    // Verify title and main tabs are rendered.
    expect(find.text('LocalAI Kit'), findsOneWidget);
    expect(find.text('Text Generation'), findsOneWidget);
    expect(find.text('Text-to-Speech'), findsOneWidget);
    expect(find.text('Speech-to-Text'), findsOneWidget);
    expect(find.text('Voice Assistant'), findsOneWidget);
    expect(find.text('Model Catalog'), findsOneWidget);
    expect(find.text('Live Logs'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Generate'), findsOneWidget);
    expect(find.byIcon(Icons.hub_rounded), findsOneWidget);

    // Verify Genkit & MCP Skills Orchestration controls
    expect(find.textContaining('Genkit Orchestrator'), findsOneWidget);
    expect(find.textContaining('MCP Plugins / Skills'), findsOneWidget);
    expect(find.textContaining('Calculator (calculate)'), findsOneWidget);
    expect(
        find.textContaining('Device Clock (get_current_time)'), findsOneWidget);
    expect(
        find.textContaining('System Specs (get_device_info)'), findsOneWidget);
    expect(find.textContaining('Weather Mock (get_weather)'), findsOneWidget);

    // Tap to disable MCP skills and ensure chips hide
    await tester.tap(find.textContaining('MCP Plugins / Skills'));
    await tester.pump();
    expect(find.textContaining('Calculator (calculate)'), findsNothing);

    // Tap to re-enable MCP skills
    await tester.tap(find.textContaining('MCP Plugins / Skills'));
    await tester.pump();
    expect(find.textContaining('Calculator (calculate)'), findsOneWidget);
  });

  testWidgets('STT tab exposes microphone and transcript controls',
      (WidgetTester tester) async {
    await tester.pumpWidget(const LocalAIDemoApp());

    final sttTab = find.text('Speech-to-Text');
    await tester.ensureVisible(sttTab);
    await tester.tap(sttTab);
    await tester.pumpAndSettle();

    expect(find.text('STT Model & Microphone'), findsOneWidget);
    expect(find.text('Start Recording'), findsOneWidget);
    expect(find.text('Final Transcript'), findsOneWidget);
    expect(
      find.text(
          'Capture 16 kHz mono microphone audio. Stop recording to produce one stable transcription for the captured utterance.'),
      findsOneWidget,
    );
    expect(find.textContaining('Live hypothesis'), findsNothing);
    expect(find.text('Clear Transcript'), findsOneWidget);
  });

  testWidgets('LLM Dropdown contains gemma-4-e2b-it and allows selection',
      (WidgetTester tester) async {
    await tester.pumpWidget(const LocalAIDemoApp());

    // Find LLM DropdownButton
    final dropdown = find.byType(DropdownButton<String>).first;
    expect(dropdown, findsOneWidget);

    // Open Dropdown
    await tester.tap(dropdown);
    await tester.pumpAndSettle();

    // Verify Gemma 4 E2B is an option and select it
    final gemmaOption = find.textContaining('Gemma 4 E2B').last;
    expect(gemmaOption, findsOneWidget);
    await tester.tap(gemmaOption);
    await tester.pump();
  });

  testWidgets(
      'LLM Dropdown contains llama.cpp GGUF models and allows selection',
      (WidgetTester tester) async {
    await tester.pumpWidget(const LocalAIDemoApp());

    // Find LLM DropdownButton
    final dropdown = find.byType(DropdownButton<String>).first;
    expect(dropdown, findsOneWidget);

    // Open Dropdown
    await tester.tap(dropdown);
    await tester.pumpAndSettle();

    // Verify Llama 3.2 1B (GGUF • llama.cpp) is an option and select it
    final llamaOption = find.textContaining('Llama 3.2 1B').last;
    expect(llamaOption, findsOneWidget);
    await tester.tap(llamaOption);
    await tester.pump();
  });

  testWidgets('Toggling Genkit Orchestrator updates UI state',
      (WidgetTester tester) async {
    await tester.pumpWidget(const LocalAIDemoApp());

    // 1. Verify initial Genkit state
    expect(find.textContaining('Genkit Orchestrator: OFF'), findsOneWidget);

    // 2. Tap to enable Genkit Orchestrator
    final genkitChip = find.textContaining('Genkit Orchestrator');
    await tester.tap(genkitChip);
    await tester.pump();
    expect(find.textContaining('Genkit Orchestrator: ON'), findsOneWidget);

    // 3. Tap to disable Genkit Orchestrator
    await tester.tap(find.textContaining('Genkit Orchestrator'));
    await tester.pump();
    expect(find.textContaining('Genkit Orchestrator: OFF'), findsOneWidget);
  });
}
