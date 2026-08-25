import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_kit_example/main.dart';

void main() {
  testWidgets('LocalAIDemoApp renders initial UI elements and MCP controls',
      (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const LocalAIDemoApp());

    // Verify title and main tabs are rendered.
    expect(find.text('LocalAI Kit'), findsOneWidget);
    expect(find.text('Text Generation (LLM)'), findsOneWidget);
    expect(find.text('Text-to-Speech (TTS)'), findsOneWidget);
    expect(find.text('Speech-to-Text (STT)'), findsOneWidget);
    expect(find.text('Voice Assistant'), findsOneWidget);
    expect(find.text('Model Catalog'), findsOneWidget);
    expect(find.text('Live Logs'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Generate'), findsOneWidget);
    expect(find.byIcon(Icons.hub_outlined), findsOneWidget);

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

    final sttTab = find.text('Speech-to-Text (STT)');
    await tester.ensureVisible(sttTab);
    await tester.tap(sttTab);
    await tester.pumpAndSettle();

    expect(find.text('STT Model & Microphone'), findsOneWidget);
    expect(find.text('Start Recording'), findsOneWidget);
    expect(find.text('Live Transcript'), findsOneWidget);
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
}
