/// Pure-Dart core smoke tests (no device required, see `melos run test:core`).
library;

import 'package:local_ai_core/local_ai_core.dart';
import 'package:test/test.dart';

void main() {
  group('LocalModelManifest', () {
    test('json round-trip preserves fields', () {
      final manifest = Models.senseVoiceSmall;
      final restored = LocalModelManifest.fromJson(manifest.toJson());
      expect(restored.id, manifest.id);
      expect(restored.type, manifest.type);
      expect(restored.provider, manifest.provider);
      expect(restored.files.length, manifest.files.length);
      expect(restored.capabilities, manifest.capabilities);
      expect(restored.catalogVersion, manifest.catalogVersion);
    });

    test('total size is the sum of file sizes', () {
      expect(
        Models.senseVoiceSmall.totalSizeBytes,
        Models.senseVoiceSmall.files.fold<int>(0, (s, f) => s + f.sizeBytes),
      );
    });
  });

  group('ModelDeliveryPolicy.smart', () {
    test('bundles small, downloads large', () {
      const policy = ModelDeliveryPolicy.smart(bundleBelowMB: 25);
      final mb = 1024 * 1024;
      expect(policy.resolve(ModelDelivery.bundledIfSmall, 2 * mb),
          ModelDelivery.bundled);
      expect(policy.resolve(ModelDelivery.bundledIfSmall, 200 * mb),
          ModelDelivery.download);
      expect(policy.resolve(ModelDelivery.download, 1 * mb),
          ModelDelivery.download);
    });
  });

  group('JsonSchema', () {
    test('validates required keys and types', () {
      final schema = JsonSchema.object(
        properties: {'name': JsonSchema.string()},
        required: ['name'],
      );
      expect(schema.validate({'name': 'x'}), isNull);
      expect(schema.validate({}), isNotNull);
      expect(schema.validate({'name': 42}), isNotNull);
    });
  });

  group('AdapterRegistry', () {
    test('routes by provider and reports missing adapters', () {
      final registry = AdapterRegistry();
      registry.registerLlm('fake', (_) => FakeLlm());
      final llm = registry.resolveLlm(const LocalModelManifest(
        id: 'm',
        type: ModelType.llm,
        provider: 'fake',
        files: [],
        delivery: ModelDelivery.download,
      ));
      expect(llm, isA<FakeLlm>());
      expect(
        () => registry.resolveStt(const LocalModelManifest(
          id: 'm2',
          type: ModelType.stt,
          provider: 'fake',
          files: [],
          delivery: ModelDelivery.download,
        )),
        throwsA(isA<AdapterNotFoundError>()),
      );
    });
  });

  group('FakeLlm', () {
    test('streams chunks and folds to a response', () async {
      final llm = FakeLlm(responseText: 'hello world');
      await llm.load(const LlmLoadOptions(modelId: 'fake'));
      final response = await llm.generate(LlmRequest.prompt('hi'));
      expect(response.text, 'hello world');
      expect(response.finishReason, LlmFinishReason.stop);
    });

    test('generateStructured parses and validates JSON', () async {
      final llm = FakeLlm(responseText: '```json\n{"name":"gemma"}\n```');
      await llm.load(const LlmLoadOptions(modelId: 'fake'));
      final result = await llm.generateStructured<String>(
        'name?',
        schema: JsonSchema.object(
          properties: {'name': JsonSchema.string()},
          required: ['name'],
        ),
        fromJson: (json) => json['name'] as String,
      );
      expect(result, 'gemma');
    });

    test('generateStructured throws after retries on invalid JSON', () async {
      final llm = FakeLlm(responseText: 'not json at all');
      await llm.load(const LlmLoadOptions(modelId: 'fake'));
      expect(
        llm.generateStructured<String>(
          'name?',
          schema: JsonSchema.object(properties: const {}),
          fromJson: (json) => 'x',
          maxRetries: 1,
        ),
        throwsA(isA<StructuredOutputError>()),
      );
    });
  });

  group('CancelToken', () {
    test('cancel is idempotent and notifies listeners', () {
      final token = CancelToken();
      var calls = 0;
      token.addListener(() => calls++);
      token.cancel();
      token.cancel();
      expect(calls, 1);
      expect(token.isCancelled, isTrue);
      expect(token.throwIfCancelled, throwsA(isA<CancelledError>()));
    });
  });
}
