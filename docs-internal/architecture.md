# LocalAI Kit 架构设计文档

> 端侧 AI Flutter 模块：可插拔、offline-first、流式优先。
> 标识符统一英文，叙述中文。版本：v0.1（草案）。

---

## 1. 设计目标与原则

| 原则 | 落地方式 |
|---|---|
| 解耦 | `local_ai_core` 只含抽象 + 纯 Dart 模型，**禁止**依赖 flutter_gemma / genkit / sherpa_onnx / Flutter SDK |
| 组件可选 | 每个能力（LLM/STT/TTS/VAD/Genkit）独立 adapter 包，App 按需添加依赖并注册 |
| 强类型 | 配置、manifest、状态、事件全部强类型枚举/sealed class，杜绝 `dynamic` 透传 |
| 流式优先 | 所有推理/识别/合成/下载进度均为 `Stream`；一次性结果由流折叠而来 |
| 最少集成代码 | 单一 `LocalAI.initialize(LocalAIConfig)` + 门面 API + 预设配置 |
| 无业务逻辑 | Kit 只做运行时编排与资源管理，不含任何 App 业务 |
| 可测试 | adapter 可替换为 Fake 实现；core 提供 in-memory fake 便于单测 |
| 禁止巨型类 | 无 `AIService` god-class；按能力拆接口，门面只做委托 |

---

## 2. 整体分层与依赖方向

```
┌────────────────────────────────────────────────────┐
│                      App                           │
└──────────────────────┬─────────────────────────────┘
                       ▼
┌────────────────────────────────────────────────────┐
│  local_ai_kit（门面 / 配置装配 / 管线 DSL / 预设）  │
└───┬──────────┬──────────┬───────────┬──────────────┘
    ▼          ▼          ▼           ▼
┌────────┐┌────────┐┌─────────┐┌──────────────┐
│ gemma  ││ genkit ││ sherpa  ││ local_ai_    │
│ adapter││ adapter││ adapter ││ flutter(平台)│
└───┬────┘└───┬────┘└────┬────┘└──────┬───────┘
    └─────────┴────┬─────┴────────────┘
                   ▼
        ┌──────────────────────┐
        │    local_ai_core     │  ← 唯一被所有人依赖；自身零第三方 AI 依赖
        └──────────────────────┘
                   ▲
        外部运行时：flutter_gemma / genkit / sherpa_onnx
        （只被各自 adapter 包依赖，类型绝不外泄到 core）
```

**依赖规则（硬性）**：
1. `core` 只依赖 Dart SDK + `meta`/`collection`。
2. adapter 包依赖 `core` + 各自的运行时 SDK；运行时类型不得出现在 adapter 的公共 API 签名中（例外见 §7 Genkit 逃生舱）。
3. `local_ai_flutter` 是**唯一**允许依赖 Flutter SDK 平台插件（path_provider、permission_handler、录音、音频播放、connectivity、Wakelock、AppLifecycle）的包；它把这些平台能力实现为 core 中定义的抽象（如 `LocalStoragePaths`、`LocalAudioSource`、`NetworkPolicy`）。
4. `kit` 依赖 `core` + `local_ai_flutter`；**不直接依赖任何 adapter 包**，adapter 由 App 显式传入注册（见 §4.8 `AdapterRegistry`），保证未使用的运行时可被完全裁剪（tree-shaking + 不打包原生库）。

---

## 3. 各包职责与公共导出 API

### 3.1 local_ai_core（纯 Dart，零 AI 依赖）
职责：接口、数据模型、状态枚举、配置模型、管线事件模型、错误模型。
导出（详见 §4 完整签名）：
```
LocalLlm, LocalStt, LocalTts, LocalVad, LocalEmbedding,
LocalModelRuntime, LocalModelManager, LocalModelCatalog,
LocalAudioSource, LocalAudioOutput, LocalStoragePaths, NetworkPolicy, Clock,
LlmRequest/LlmChunk/LlmResponse, JsonSchema, Transcript/TranscriptEvent,
SpeakRequest/AudioChunk/AudioFrame/AudioBuffer, VadEvent,
LocalVoice, LocalModelManifest, ModelFile, ModelType, ModelCapability,
ModelDelivery, ModelDeliveryPolicy, ModelInstallState, ModelStatus,
ModelDownloadProgress, RuntimePreference, RuntimeMemoryPolicy, MemoryUsage,
DeviceCapabilities, CompatibilityReport, ModelPack,
PipelineEvent(sealed), VoiceEvent(sealed), LocalAIError(sealed), CancelToken,
AdapterRegistry, LlmAdapterFactory/SttAdapterFactory/... 
FakeLlm/FakeStt/FakeTts/FakeVad（测试用）
```

### 3.2 local_ai_flutter（Flutter 平台层）
职责：平台原语实现，供 kit 与 adapter 使用。
```
FlutterStoragePaths      // path_provider → app-support/local_ai/...
FlutterAudioRecorder     // 麦克风 → Stream<AudioFrame>（16kHz mono f32/pcm16 可配）
FlutterAudioPlayer       // 流式播放 + stop()（barge-in 用）
FlutterNetworkPolicy     // connectivity_plus → Wi-Fi only 判定
FlutterDeviceProbe       // 内存/SoC/Android NNAPI・iOS NeuralEngine 探测 → DeviceCapabilities
AppLifecycleObserver     // 前后台事件 → 内存策略 trim
PermissionGate           // mic/storage 权限请求封装
```

### 3.3 local_ai_gemma
职责：flutter_gemma → `LocalLlm`。
```
GemmaLlmAdapter implements LocalLlm
  factory GemmaLlmAdapter({required LocalStoragePaths paths})
GemmaAdapterPlugin.register(AdapterRegistry r)   // 一行注册
```
内部负责：模型文件路径映射、RuntimePreference→backend 选择（CPU/GPU）、session 复用与上下文窗口管理。

### 3.4 local_ai_sherpa
职责：sherpa_onnx → `LocalStt`/`LocalVad`/`LocalTts`。
```
SherpaSttAdapter implements LocalStt
SherpaVadAdapter implements LocalVad
SherpaTtsAdapter implements LocalTts
SherpaAdapterPlugin.register(AdapterRegistry r)  // 一次注册三者
```
内部：所有 FFI 调用封装在专用 `Isolate`（见 §5.6），音频帧经 `TransferableTypedData` 零拷贝传递。

### 3.5 local_ai_genkit（可选编排层）
职责：Genkit flows/tools/结构化输出 → `LocalLlm` 增强。
```
GenkitLlmAdapter implements LocalLlm      // 包装任意内层 LocalLlm
GenkitOrchestrator                        // flows/tools 注册与执行
GenkitAdapterPlugin.register(...)
extension LocalAIGenkitX on LocalAI { GenkitOrchestrator get genkit; }  // 逃生舱
```

### 3.6 local_ai_kit（门面）
职责：装配、门面 API、管线 DSL、预设、语音会话编排。
```
class LocalAI {
  static Future<LocalAI> initialize(LocalAIConfig config, {List<AdapterPlugin> adapters});
  LocalLlmFacade get llm;              // ai.llm.generate / generateStream / generateStructured
  LocalSttFacade get stt;              // ai.stt.transcribe / transcribeStream
  LocalTtsFacade get tts;              // ai.tts.speak / synthesizeStream / voices / installVoice
  VoiceSessionFactory get voice;       // ai.voice.start(config)
  ModelHub get models;                 // ai.models.ensureInstalled / install / remove / status / downloadProgress
  RuntimeController get runtime;       // ai.runtime.memoryUsage / loadedModels / load / unload / checkCompatibility
}
LocalPipeline（§5.4 管线 DSL）
预设：LocalAIConfig.lowMemory() / .voiceAssistant() / .offlineChat() / .transcription()
ModelCatalogService（远程目录合并，§5.5）
```

门面内部只是委托 + 装配，**禁止**在 kit 内实现推理逻辑。

---

## 4. core 接口定义草案

### 4.1 能力接口

```dart
/// LLM 推理
abstract interface class LocalLlm {
  Future<void> load(LlmLoadOptions options);
  Future<void> unload();
  bool get isLoaded;
  Stream<LlmChunk> generateStream(LlmRequest request);
  /// 非流式 = generateStream 折叠
  Future<LlmResponse> generate(LlmRequest request);
  /// 结构化输出：schema 注入 prompt/grammar，失败重试 N 次后抛 StructuredOutputError
  Future<T> generateStructured<T>(
    String prompt, {
    required JsonSchema schema,
    required T Function(Map<String, dynamic> json) fromJson,
    int maxRetries = 2,
  });
}

abstract interface class LocalStt {
  Future<void> load(SttLoadOptions options);
  Future<void> unload();
  /// 流式识别：输入音频帧流，输出增量转写事件（partial/final）
  Stream<TranscriptEvent> transcribeStream(Stream<AudioFrame> audio, {SttOptions? options});
  Future<Transcript> transcribe(AudioBuffer audio, {SttOptions? options});
}

abstract interface class LocalTts {
  Future<void> load(TtsLoadOptions options);
  Future<void> unload();
  List<LocalVoice> get installedVoices;
  /// 流式合成：边生成边播
  Stream<AudioChunk> synthesizeStream(SpeakRequest request);
}

abstract interface class LocalVad {
  Future<void> load(VadConfig config);
  Future<void> unload();
  /// 对音频帧流产出 speechStarted/speechEnded/confidence 事件
  Stream<VadEvent> analyze(Stream<AudioFrame> audio);
}

abstract interface class LocalEmbedding {
  Future<void> load(EmbeddingLoadOptions options);
  Future<void> unload();
  Future<List<double>> embed(String text);
  Future<List<List<double>>> embedBatch(List<String> texts);
}
```

### 4.2 运行时与模型管理

```dart
abstract interface class LocalModelRuntime {
  Future<void> loadModel(String modelId, {RuntimePreference? preference});
  Future<void> unloadModel(String modelId);
  List<LoadedModel> get loadedModels;
  MemoryUsage get memoryUsage;
  Future<DeviceCapabilities> deviceCapabilities();
  Future<CompatibilityReport> checkCompatibility(LocalModelManifest manifest);
  Stream<RuntimeEvent> get events;
}

abstract interface class LocalModelManager {
  Future<bool> isInstalled(String modelId);
  Future<ModelStatus> getStatus(String modelId);
  /// 幂等：已安装且校验通过则直接返回；否则排队下载
  Future<void> ensureInstalled(String modelId, {DownloadPolicy policy = const DownloadPolicy()});
  Future<void> install(String modelId, {DownloadPolicy policy});
  Future<void> update(String modelId);          // 目录版本更高时升级
  Future<void> remove(String modelId);
  Future<bool> verify(String modelId);          // sha256 全量校验
  Stream<ModelDownloadProgress> downloadProgress(String modelId);
  Stream<ModelStatus> watchStatus(String modelId);
}

abstract interface class LocalModelCatalog {
  Future<List<LocalModelManifest>> list({ModelType? type, String? language});
  Future<LocalModelManifest> get(String modelId);
  Future<void> refresh();                        // 拉远程目录并合并（§5.5）
  List<ModelPack> get packs;
  Future<void> installPack(String packId);       // ModelPack → 批量 ensureInstalled
}

abstract interface class LocalAudioSource {
  Stream<AudioFrame> start({AudioFormat format = AudioFormat.pcm16kMono});
  Future<void> stop();
}
abstract interface class LocalAudioOutput {
  Future<void> play(Stream<AudioChunk> audio);
  Future<void> stop();          // barge-in：立即截断播放
}
```

### 4.3 配置与 manifest

```dart
class LocalAIConfig {
  final LlmConfig? llm;      // 各组件均可选：null = 不启用
  final VadConfig? vad;
  final SttConfig? stt;
  final TtsConfig? tts;
  final ModelDeliveryPolicy deliveryPolicy;
  final RuntimeMemoryPolicy memoryPolicy;
  final RuntimePreference runtimePreference;
  final Uri? remoteCatalogUrl;
  const LocalAIConfig({this.llm, this.vad, this.stt, this.tts, ...});
  factory LocalAIConfig.lowMemory();       // 小模型 + aggressive 卸载 + cpu
  factory LocalAIConfig.voiceAssistant();  // vad+stt+llm+tts 全套
  factory LocalAIConfig.offlineChat();     // 仅 llm，bundled 交付
  factory LocalAIConfig.transcription();   // 仅 vad+stt
}

class LlmConfig {
  final String modelId;                 // 引用 manifest
  final RuntimePreference runtime;      // auto/cpu/gpu/npu
  final int? maxContextTokens;
  final double temperature;
  final bool enableGenkit;              // 是否叠加编排层
}

class LocalModelManifest {
  final String id;                    // e.g. "gemma-3n-e2b-it-int4"
  final ModelType type;               // llm/stt/vad/tts/embedding
  final String provider;              // google/sherpa-community/...
  final List<ModelFile> files;        // name/url/sha256/sizeBytes/relativePath
  final ModelDelivery delivery;
  final List<String> languages;
  final List<String> platforms;       // android/ios/macos...
  final int minMemoryMB;
  final String? quantization;         // int4/int8/fp16
  final int? contextLength;
  final Set<ModelCapability> capabilities; // chat/functionCalling/asrStreaming/...
  final String license;
  final List<LocalVoice>? voices;     // tts 专用：每个 voice 独立 files/sha256
  final int catalogVersion;           // 合并策略用
}

enum ModelDelivery { bundled, download, bundledIfSmall, external }
class ModelDeliveryPolicy {
  const ModelDeliveryPolicy.smart({this.bundleBelowMB = 25});
  final int bundleBelowMB;   // <阈值→打 bundle，否则下载；构建期由 melos 任务校验资产
}
```

### 4.4 状态与事件

```dart
enum ModelInstallState {
  notInstalled, queued, downloading, paused, verifying,
  extracting, installing, installed, loading, ready, updating, failed,
}
sealed class VoiceEvent {
  ... Listening / SpeechStarted / SpeechEnded / TranscriptUpdated(text,isFinal)
    / Thinking / ResponseStarted / ResponseDelta / Speaking / Finished
    / Interrupted(reason: bargeIn) / ErrorOccurred
}
sealed class LocalAIError {
  ModelNotFound / ModelCorrupted(shaMismatch) / InsufficientDisk(needMB, freeMB)
  / IncompatibleDevice(report) / NetworkPolicyViolation / Cancelled / NativeRuntimeError
}
```

### 4.5 AdapterRegistry（可插拔关键）

```dart
abstract interface class AdapterPlugin { void register(AdapterRegistry r); }
class AdapterRegistry {
  void registerLlm(String provider, LlmAdapterFactory f);
  void registerStt(String provider, SttAdapterFactory f); ... // vad/tts/embedding
  LocalLlm resolveLlm(LocalModelManifest m);   // 按 manifest.provider 路由
}
// App 侧：
LocalAI.initialize(config, adapters: [GemmaAdapterPlugin(), SherpaAdapterPlugin()]);
```
收益：kit 零 adapter 依赖；App 不加 sherpa 包则二进制中完全没有 onnxruntime。

---

## 5. 关键机制设计

### 5.1 下载状态机与断点续传

状态机（单向推进，失败可回退重试）：
```
notInstalled → queued → downloading ⇄ paused → verifying
             → extracting → installing → installed → loading → ready
任意状态 → failed(reason)；installed → updating → verifying → ... → ready
```
持久化：`app-support/local_ai/downloads/<id>/` 内存放 `*.part` + `meta.json`：
```json
{ "modelId":"...", "catalogVersion":3, "etag":"...", "totalBytes":..., 
  "files":[{"name":"model.tflite","received":12345,"sha256":null}] }
```
流程要点：
1. **预检**：`InsufficientDisk` 检查（sizeBytes × 1.2 余量）+ `NetworkPolicy`（Wi-Fi only 时蜂窝网络直接入 queued 等待回调）。
2. **断点续传**：每个文件读取 `received`，发 `Range: bytes=<received>-`；服务器 200（不支持 Range）则清零重来。写文件用 `IOSink(mode: append)`，每 N MB flush + 更新 meta（原子写：`meta.json.tmp` → rename）。
3. **重试**：指数退避（1s/2s/4s，cap 30s，最多 5 次），网络错误可续传，4xx 立即 failed。
4. **校验**：逐文件 sha256 流式计算（chunked digest，边下边算）；任一份不符 → 该文件删除重下，整体最多 2 轮。
5. **原子安装**：全部校验通过 → `downloads/<id>` 整体 `rename` 到 `models/<type>/<id>/`（同分区 rename 原子）；最后写 `installed.json`（含 catalogVersion、installedAt）。崩溃恢复：启动时扫描 downloads/ 续传、清理 models/ 下无 installed.json 的半成品目录。
6. 进度流：`ModelDownloadProgress{state, receivedBytes, totalBytes, bytesPerSecond, eta, currentFile}`，经 `StreamController.broadcast` 分发，支持多订阅。

统一存储布局：
```
<app-support>/local_ai/
  models/{llm,stt,vad,tts,embedding}/<modelId>/   ← 含 installed.json
  voices/<voiceId>/                                ← TTS 声音独立安装
  manifests/catalog.remote.json, catalog.merged.json
  downloads/<modelId>/                             ← 临时，安装后删除
  cache/                                           ← KV 缓存、临时音频，可被系统清理
```

### 5.2 内存策略调度

```dart
class RuntimeMemoryPolicy {
  final Duration unloadUnusedAfter;  // 默认 5min
  final int maxLoadedModels;         // 默认 2
  final bool trimOnBackground;       // 默认 true
}
```
`ModelRuntimeScheduler`（kit 内部）：
- 每个 `LoadedModel` 记录 `lastUsedAt`；任何 generate/transcribe/speak 调用刷新。
- 加载新模型前：`loadedModels.length >= maxLoadedModels` → 按 LRU 逐出（voice 会话进行中锁定其组件，不可逐出）。
- 周期 Timer（30s）扫描空闲超时模型并 unload；App 进入后台（`AppLifecycleObserver`）且 `trimOnBackground` → 卸载全部非锁定模型。
- `npu/gpu` 后端加载失败 → 自动降级 `cpu` 并在 `RuntimeEvent.backendFallback` 中上报。

### 5.3 语音管线事件流与 barge-in

```
Mic ─▶ VAD ─▶ STT ─▶ LLM/Genkit ─▶ TTS ─▶ Speaker
 │       │       │          │           │        │
 └───────┴───────┴──────────┴───────────┴────────┴──▶ VoiceEvent bus (broadcast)
```
`VoiceSession` 实现要点：
- 单一 `StreamController<VoiceEvent>.broadcast` 对外 `session.events`；内部各阶段用 `CancelToken` 协作。
- **barge-in**：TTS 播放期间 VAD 持续分析（AEC 可选、默认不做）；`SpeechStarted` 置信度 > 阈值且持续 ≥ 120ms → 触发 `Interrupt`：
  1. `audioOutput.stop()` 截断播放；
  2. 取消 LLM 生成流与 TTS 合成流（CancelToken）；
  3. 发出 `VoiceEvent.interrupted`，状态回到 Listening，新语音继续进入 STT。
- 回声误触发缓解（无 AEC 时）：播放期间提高 VAD 触发阈值 + 对 STT 输出与 TTS 文本做前缀相似度过滤，文档注明“建议耳机模式”。
- 半双工/全双工可配：`VoiceSessionConfig{bargeIn: true, duplex: DuplexMode.full}`。

### 5.4 管线组合 DSL（builder 链）可行性

采用**类型化阶段 builder**：每个方法返回新类型，编译期约束顺序合法性。
```dart
final pipeline = await LocalPipeline(ai)
    .input.microphone()          // → MicStage
    .vad()                     // MicStage → VadStage（仅音频输入可接）
    .stt()                     // → TextStage
    .llm(systemPrompt: '...')  // TextStage → LlmStage（也可 .genkit(flow:...)）
    .tts()                     // LlmStage → TtsStage
    .output.speaker()          // → BuiltPipeline
    .build();
await for (final e in pipeline.run()) { /* PipelineEvent */ }
```
实现方式：各 Stage 内部就是 `StreamTransformer`，`build()` 把 stage 链表组装成单条 `Stream` 变换链并注入 pipeline 作用域的 `CancelToken` + 事件总线。预置：
```dart
LocalPipeline.presets.textChat(ai) / transcription(ai) / voiceChat(ai) / voiceCommand(ai)
```
可行性结论：Dart 无扩展方法链式类型推断问题，用具体 Stage 类链即可，编译期约束成立；复杂度可控（每 stage 一个小类）。

### 5.5 远程模型目录合并策略

- 内置 `assets/catalog.json`（随包发布，offline fallback，永远可用）。
- 远程 JSON：`{catalogVersion, updatedAt, models:[...manifest]}`，启动时 `refresh()` 拉取，成功后缓存到 `manifests/catalog.remote.json`。
- 合并规则（按 `modelId`）：
  1. 远程 `catalogVersion` > 本地 → 远程条目覆盖内置；
  2. 远程新增 id → 追加；远程不删除本地已安装模型的条目（防止已装模型失去 manifest）；
  3. 已安装模型的 `files[].sha256` 若被远程修改且版本更高 → 状态转 `updating`，提示可 `update()`，**不**自动覆盖；
  4. 合并结果落盘 `catalog.merged.json`，远程拉取失败用上次缓存，缓存无则用内置。
- 完整性：远程目录可附 `sha256`/签名字段（v1 先支持 sha256 自描述；签名留作 v2 决策点）。

### 5.6 sherpa_onnx FFI 线程模型（机制性决策）

- 每个 sherpa 组件常驻一个 `Isolate`（`Isolate.spawn` + `SendPort` 命令通道），FFI 调用全部在 isolate 内执行，UI isolate 零阻塞。
- 音频下行：`TransferableTypedData.fromList` 零拷贝发送 `Float32List` 帧；上行事件为轻量对象（文本/时间戳）。
- Isolate 生命周期跟随 adapter load/unload；崩溃隔离：isolate error → `LocalAIError.nativeRuntime` 并允许重建。

---

## 6. 目录结构（melos monorepo）

```
local_ai_kit/
├── melos.yaml                    # bootstrap / analyze / test / bundle-models 脚本
├── pubspec.yaml                  # workspace 根
├── docs-internal/architecture.md
├── packages/
│   ├── local_ai_core/
│   │   └── lib/
│   │       ├── local_ai_core.dart            # barrel export
│   │       └── src/
│   │           ├── llm/        # local_llm.dart, llm_request.dart, json_schema.dart
│   │           ├── stt/  tts/  vad/  embedding/
│   │           ├── audio/      # audio_frame.dart, local_audio_source/output.dart
│   │           ├── models/     # manifest.dart, model_delivery.dart, model_status.dart
│   │           ├── runtime/    # local_model_runtime.dart, memory_policy.dart
│   │           ├── catalog/    # local_model_catalog.dart, model_pack.dart
│   │           ├── pipeline/   # pipeline_event.dart, voice_event.dart, stage.dart
│   │           ├── registry/   # adapter_registry.dart
│   │           ├── errors/     # local_ai_error.dart
│   │           └── testing/    # fake_llm.dart, fake_stt.dart ...
│   ├── local_ai_flutter/
│   │   └── lib/src/  # storage_paths, audio_recorder, audio_player,
│   │                 # network_policy, device_probe, lifecycle
│   ├── local_ai_gemma/     lib/src/gemma_llm_adapter.dart
│   ├── local_ai_genkit/    lib/src/genkit_llm_adapter.dart, orchestrator.dart
│   ├── local_ai_sherpa/    lib/src/{sherpa_stt,sherpa_vad,sherpa_tts}_adapter.dart,
│   │                           lib/src/isolate/sherpa_worker.dart
│   └── local_ai_kit/
│       ├── assets/catalog.json            # 内置离线目录
│       └── lib/
│           ├── local_ai_kit.dart          # export LocalAI, LocalAIConfig, LocalPipeline
│           └── src/
│               ├── facade/    # local_ai.dart, model_hub.dart, voice_session.dart
│               ├── download/  # download_manager.dart, resume_meta.dart, installer.dart
│               ├── catalog/   # catalog_service.dart, catalog_merger.dart
│               ├── pipeline/  # local_pipeline.dart, stages/, presets.dart
│               ├── runtime/   # runtime_scheduler.dart
│               └── config/    # local_ai_config.dart（含预设工厂）
└── examples/
    ├── chat_demo/  transcription_demo/  voice_assistant_demo/
```

melos 脚本要点：`analyze`（全包）、`test:core`（纯 Dart 可在 CI 无设备跑）、`verify:bundle-policy`（校验 bundled 模型资产 < bundleBelowMB 阈值）。

---

## 7. 风险与权衡

| # | 议题 | 风险 | 取舍 / 缓解 |
|---|---|---|---|
| 1 | **Genkit 端侧价值** | Genkit (Dart) 主要面向服务端编排，端侧无模型推理能力，仅提供 flows/tools/prompt 模板；引入增加包体积与概念复杂度 | 设为**完全可选**包；定位为“编排层 + 结构化输出 + 未来云端混合”而非推理；core 不出现 Genkit 类型；`ai.genkit` 逃生舱仅 genkit 包存在时可用。若用户不需要编排，直接用 `GemmaLlmAdapter` |
| 2 | **sherpa_onnx FFI 线程** | FFI 同步调用阻塞 UI isolate；isolate 间大音频帧拷贝开销；isolate 内崩溃难调试 | 常驻 worker isolate（§5.6）+ TransferableTypedData；接受常驻 isolate 的少量内存常驻成本 |
| 3 | **Gemma 上下文管理** | flutter_gemma session 有固定 context window，长对话 KV cache 撑爆内存；多轮对话截断策略属业务灰色地带 | adapter 内提供 `maxContextTokens` + 滑动窗口截断（保 system + 最近 N 轮），并在 `LlmChunk` 暴露 `contextTruncated` 标记；不做摘要压缩（属业务） |
| 4 | **可选 adapter 注册 vs 开箱即用** | 显式 `adapters: [...]` 增加一行集成成本；但隐式依赖会导致所有原生运行时强制打包 | 选显式注册（§4.5）；kit 提供 `LocalAI.adapters.recommended()` 便捷常量降低门槛 |
| 5 | **bundled 模型体积** | int4 小模型仍数百 MB，打进 IPA/APK 不现实 | `bundledIfSmall` + `smart(bundleBelowMB:25)` 只捆绑 VAD/小 STT；LLM/TTS 默认 download + 首启引导下载 UX（examples 提供） |
| 6 | **无 AEC 的 barge-in** | 扬声器回声被 VAD 误判为打断 | 阈值提升 + 文本相似过滤 + 文档建议耳机；AEC 留作后续平台层增强 |
| 7 | **原子安装跨平台** | rename 原子性在 iOS/Android app-support 目录内成立，但跨目录 move 需拷贝 | 强制 downloads/ 与 models/ 同根目录，保证同分区 rename |
| 8 | **结构化输出可靠性** | 小模型 JSON 遵循率低 | schema 注入 + 解析失败自动重试（带错误反馈 prompt）+ `maxRetries` 后抛错；grammar/ constrained decoding 依赖 flutter_gemma 能力，未支持时降级为 prompt 方案 |
| 9 | **远程目录安全** | 中间人篡改 manifest → 下载恶意模型 | HTTPS + 目录 sha256；v2 决策：Ed25519 签名校验 |
| 10 | **多包发布成本** | 6 包版本联动 | melos 统一版本策略；core 采用 semver 严格化（adapter 依赖 core 用窄区间） |

---

## 8. 实施顺序建议

1. `local_ai_core`（接口 + 模型 + fakes）→ 2. `local_ai_flutter`（平台原语）→ 3. `local_ai_sherpa`（VAD/STT 先行，可独立演示 transcription）→ 4. `local_ai_gemma` → 5. `local_ai_kit`（下载管理器 → 门面 → 语音会话 → 管线 DSL → 预设）→ 6. `local_ai_genkit`（最后，依赖稳定 core）→ 7. examples + 远程目录。
验收：examples/voice_assistant_demo 全链路 Mic→VAD→STT→LLM→TTS 可 barge-in；`flutter test` core 无设备绿。
