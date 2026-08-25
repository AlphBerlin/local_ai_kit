import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/main.dart';

void main() {
  testWidgets('LocalAIDemoApp renders initial UI elements',
      (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const LocalAIDemoApp());

    // Verify title and main tabs are rendered.
    expect(find.text('LocalAI Kit'), findsOneWidget);
    expect(find.text('Text Generation (LLM)'), findsOneWidget);
    expect(find.text('Text-to-Speech (TTS)'), findsOneWidget);
    expect(find.text('Voice Assistant'), findsOneWidget);
    expect(find.text('Model Catalog'), findsOneWidget);
    expect(find.text('Live Logs'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Generate'), findsOneWidget);
    expect(find.byIcon(Icons.hub_outlined), findsOneWidget);
  });
}
