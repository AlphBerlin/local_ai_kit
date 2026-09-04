# Package Architecture Improvements — Internal Design

> Status: design + first implementation slice landed.
> Audience: maintainers of the eight-package `local_ai_kit` workspace.
> Companion to `docs-internal/architecture.md` (v0.1 draft, Chinese), which
> describes the *original* design. This document describes what we change
> and why, and it is authoritative where the two disagree.

---

## 0. What problem this document solves

Two problems, and they are the same problem seen from two ends.

**From the outside:** the packages are hard to adopt. A developer who finds
`local_ai_kit` on pub.dev has to choose between eight packages, register
adapter plugins by hand, pick a model id from a catalog they cannot see,
wait an unknown number of minutes for a download with no way to know if the
model will even run on their phone, and then wait again — silently — while
the model loads. Every one of those is a place where someone closes the tab.
Downloads (in the pub.dev sense) are a lagging indicator of how many people
get past those steps.

**From the inside:** the same friction shows up as bugs. The compatibility
checker was never wired to a probe, so it always returned "compatible". The
loader had no observable state, so the only way to build a loading UI was to
`await` and hope. Two concurrent calls to the same facade could load the
same model twice. These are not separate from the adoption problem; they are
what the adoption problem looks like in the code.

So: §1–§3 are the architecture changes, §4 is the bug register found while
mapping the code, §5–§6 are the designs for the two requested features, §7
is the agent skill, §8 is what we are not doing yet.

---

## 1. Why adoption is currently expensive

### 1.1 The eight-package decision

The split is technically right — it is what lets an app that only wants text
generation avoid linking `onnxruntime` — and it should not change. But it is
presented as a decision the newcomer has to make on line one of their
`pubspec.yaml`, and they have no information with which to make it.

| Package | Role | Should a newcomer think about it? |
|---|---|---|
| `local_ai_core` | interfaces, manifests, fakes | No — transitive |
| `local_ai_flutter` | platform layer | No — transitive |
| `local_ai_kit` | facade, download, runtime | Yes |
| `local_ai_gemma` | LLM via `flutter_gemma` | Only if choosing a runtime |
| `local_ai_llama_cpp` | LLM + embeddings via GGUF | Only if choosing a runtime |
| `local_ai_sherpa` | VAD/STT/TTS | Only if doing voice |
| `local_ai_genkit` | orchestration | No — advanced |
| `bedge_ai` | umbrella | Yes — the default answer |

Only two rows matter at minute one, and the answer to both is "start with the
umbrella, split later". The README currently presents all eight as a flat
table of equals, which reads as eight decisions rather than one.

**Change:** keep the split; change the presentation. `bedge_ai` is the
documented entry point, with a single "when to split" section explaining the
binary-size argument. The per-package table moves below that. This is a docs
and `README.md` change, not a code change, and it is the cheapest adoption
win available.

### 1.2 The umbrella package has the wrong name

`bedge_ai` does not contain the string `local_ai`. Someone searching pub.dev
for "local ai flutter" finds seven packages and misses the one they should
actually depend on; someone who finds `bedge_ai` has no way to tell it is the
same project. Search is how pub.dev packages get found, and the umbrella —
the package we most want people to install — is the one invisible to it.

**Change (deferred, needs a release decision):** publish `local_ai_kit_all`
as the umbrella name and keep `bedge_ai` as a deprecated alias that
`export`s it, so existing pubspecs keep resolving. Not in this slice: it is a
publishing decision with a one-way door, and it is worth doing deliberately
in a `0.1.0` release rather than folding into a feature change. Tracked here
so it does not get lost. (Note the history: `local_ai_kit_all` was renamed
*to* `bedge_ai` in `37085c1`; this proposes reverting that call.)

### 1.3 Nothing works without ceremony

The current minimum viable program:

```dart
final ai = await LocalAI.initialize(
  LocalAIConfig.offlineChat(),
  plugins: [GemmaAdapterPlugin()],
);
final response = await ai.generate('Hello!');
```

Three concepts before the first token: a config object, a plugin list, and
the fact that `generate` will silently download a gigabyte on its first call.
The `plugins:` list in particular is a footgun — forget it and you get
`AdapterNotFoundError` at the first `generate`, not at `initialize`.

**Change (partially in this slice):** `initialize` should fail fast when the
config names a capability no registered plugin can serve, instead of
deferring to first use. See §4.12 — designed here, not yet implemented.

### 1.4 The download is a black box, and might be wasted

This is the sharpest edge and the reason feature §5 exists. Today:

- `ai.models.ensureInstalled(id)` starts a download of up to several GB.
- Nothing has checked whether the device has the disk to hold it.
  (`DownloadManager._preflight` does check — against a probe that
  `LocalAI.initialize` never supplied, so it compared against a hardcoded
  1 TB. See §4.1.)
- Nothing has checked whether the device has the RAM to load it afterwards.
- `ai.runtime.checkCompatibility(manifest)` existed and was documented as the
  way to pre-check, and it always returned "compatible" for the same reason.

A user on a 3 GB phone could spend 2.5 GB of mobile data on a model that
throws on load. That is the worst possible first experience with a library.

### 1.5 The load is a black box too

Loading a multi-GB model takes seconds to tens of seconds. The only signal
available to an app was "the `Future` has not completed". There was no phase,
no elapsed time, no estimate, and no way to tell a queued load from a
running one. Every app building on this had to write its own
`ValueNotifier<bool> isLoading` and guess. Feature §6.

### 1.6 There is no "does this work" moment

The repo has an example app, but no path that proves the install works
without first downloading a model. A newcomer whose first run is a 2 GB
download and a 40-second load has no way to tell a broken setup from a slow
one.

**Change (deferred):** ship a tiny (<25 MB, within the existing bundle
policy) model in the example, or a `FakeLlm`-backed "smoke test" preset so
`LocalAI.initialize(LocalAIConfig.smokeTest())` returns a working `generate`
in under a second with no network. Designed, not implemented.

---

## 2. Architectural direction

Three principles for the changes in §5 and §6, consistent with the existing
architecture rules in `AGENTS.md`:

**P1 — Decisions move before the expensive step.** Anything that can fail a
model (device too small, disk too full, wrong platform) is checked before
the bytes move, not after. The check is cheap, pure, and returns data rather
than throwing, so the caller can render it.

**P2 — Every long operation is observable as a stream of typed phases.**
Download progress already was. Loading was not. Both now are, and both go
through the same shape: a broadcast per-model stream plus a global event on
`runtime.events`.

**P3 — Policy stays in `local_ai_core`, mechanism in `local_ai_kit`.** The
compatibility rules are a pure function over `(manifest, capabilities)` in
core, unit-testable without a device and without Flutter. `local_ai_kit`
decides *when* to call it and what to do with the answer.

This keeps the dependency direction rule intact: nothing new points from
`core` outwards.

### 2.1 Where the new code lives

```
local_ai_core (pure Dart — testable with `dart test`, no device)
  src/models/model_compatibility.dart      ModelCompatibilityChecker (pure)
                                           ModelCompatibilityPolicy
                                           CompatibilityEnforcement
  src/models/device_capabilities.dart      + CompatibilityIssue/Severity/Check
                                           + CompatibilityReport.fromIssues
  src/models/manifest.dart                 + required/preferredAccelerators
  src/runtime/model_load_progress.dart     ModelLoadPhase, ModelLoadProgress,
                                           ModelCacheStats
  src/runtime/local_model_runtime.dart     + loadProgress/warmUp/setPinned/
                                             cacheStats on the interface
  src/config/local_ai_config.dart          + compatibilityPolicy,
                                             compatibilityEnforcement,
                                             warmUpOnInitialize

local_ai_flutter (platform)
  src/device_probe.dart                    TTL cache instead of forever

local_ai_kit (mechanism)
  src/runtime/runtime_scheduler.dart       load coalescing, phase events,
                                           pins, cache stats, compat gate
  src/download/model_manager_impl.dart     pre-download compat gate, dispose
  src/download/download_manager.dart       throttled + corrected progress
  src/facade/model_hub.dart                checkCompatibility, compatible()
  src/facade/local_ai.dart                 default probes, warmUp, pinning
```

---

## 3. Adoption changes that are documentation, not code

Listed for completeness because they are the highest-leverage items and the
cheapest, and because "improve the architecture to get more downloads" is
answered as much here as in the code.

| Change | Why it moves the number |
|---|---|
| `bedge_ai` (or its renamed successor) presented as *the* install | Removes the eight-way choice at minute one |
| A 10-line quickstart above the package table in `README.md` | pub.dev renders the README; the first screen decides |
| A compatibility + download + load UI snippet in `getting-started.md` | The three things every app must build, currently left as an exercise |
| Honest capability matrix, kept where a reader will see it | `AGENTS.md` already documents that sherpa STT/TTS shells out to Python on desktop and VAD is an RMS heuristic. A newcomer who discovers that *after* integrating does not come back. The README says it; keep it there. |
| Per-package `example/` that runs | pub.dev scores it, and it is the file people read first |

The last one is also a pub.dev *score* item, which feeds search ranking,
which feeds downloads. `local_ai_core` and `local_ai_flutter` have
`example/`; the other six do not.

---

## 4. Bug register

Found while mapping the code for this design. Severity is about user impact,
not about how hard the fix is. "Fixed" means fixed in this slice.

### 4.1 The device probe was never wired — *fixed*

`LocalAI.initialize` took `deviceProbe` and `freeDiskProbe` as optional
parameters and passed them straight through as `null` when the app did not
supply them. Consequences, all silent:

- `RuntimeScheduler.deviceCapabilities()` returned
  `platform: 'unknown', totalMemoryMB: 0`, so `checkCompatibility` compared
  every model against zero and always returned compatible.
- `DownloadManager._preflight` fell back to `_unknownFreeDisk`, which
  reports `1 << 30` MB (1 TB), so the disk pre-flight never failed.
- `RuntimeScheduler.memoryUsage.totalBytes` was always `0`, so
  `usedFraction` was always `0`.

Meanwhile `docs/runtime-memory.md` said "The default probe is
`FlutterDeviceProbe`" and `docs/faq.md` said `checkCompatibility` "compares
`minMemoryMB` with available RAM before you even offer a download". Both
described behaviour that could not happen. `IncompatibleDeviceError` was
declared in core and thrown from nowhere.

**Fix:** `initialize` defaults `deviceProbe` to `FlutterDeviceProbe().probe`
and derives `freeDiskProbe` from it.

### 4.2 Concurrent loads of the same model raced — *fixed*

`RuntimeScheduler.loadModel` checked `_handles[modelId] == null`, then
`await`ed the adapter's `load()`, then wrote `_handles[modelId]`. Two callers
arriving before the first write both passed the check. Both allocated a
native runtime; the second overwrote the first in the map, leaking one
multi-GB allocation with no reference to unload it.

Reachable from ordinary code: `_CapabilityGate.ready` did the same
check-then-act, and `ai.generate(...)` twice without `await`ing the first —
or a voice session starting while a chat request is in flight — hits it.

**Fix:** an `_loading` map of in-flight futures (see §4.3 for the trap this
introduced on the way); the second caller awaits the
first. `_CapabilityGate.ready` now calls `loadModel` unconditionally instead
of branching on `isLoaded`, so the coalescing is the only gate.

### 4.3 `install` and `loadModel` deadlocked against themselves — *fixed*

The sharpest bug in the list, and one this design nearly reproduced.

```dart
final future = _installInternal(modelId, policy)
    .whenComplete(() => _inflight.remove(modelId));   // ← never completes
_inflight[modelId] = future;
return future;
```

`Map.remove` returns the removed value. `_inflight` holds `Future<void>`, so
the arrow callback returns a `Future` — the very future being built — and
`whenComplete` *waits* on a `Future` its callback returns. The operation
waits on itself. `_installInternal` runs to completion, the model installs,
and the `Future` the caller is awaiting never completes.

`ModelManagerImpl.install` has had this since it was written. It went
unnoticed because `ensureInstalled` returns early for an installed model, and
no test exercised a path that actually downloads through the manager — so the
one code path that hangs was the one nobody ran.

The coalescing work in §4.2 introduced the identical line in
`RuntimeScheduler.loadModel`, which *was* on a hot path, and `ai.embed` hung.
That is how the pre-existing one was found.

**Fix:** a block body in both places, so the callback returns `void`. Covered
by `runtime_scheduler_test.dart` ("loadModel returns rather than hanging when
already loaded", plus the coalescing group) and
`download_compatibility_gate_test.dart`, which drives `install` to
completion.

The general shape is worth remembering: `whenComplete(() => anything)` where
`anything` might be a `Future` is a trap, and `Map.remove` returning the
removed value makes it invisible at the call site.

### 4.4 Download speed and ETA were wrong on every resume — *fixed*

`_ProgressTracker` computed `speed = receivedBytes / elapsedThisSession`.
On a resume, `receivedBytes` starts at whatever is already on disk while
`elapsed` starts at zero, so a download resuming at 1.9 GB reported hundreds
of MB/s for its first seconds and an ETA to match, then decayed.

**Fix:** a `_baselineBytes` captured at tracker construction (after disk
reconciliation); throughput is `(received - baseline) / elapsed`.

### 4.5 Download progress fired on every socket chunk — *fixed*

`progress.tick()` ran per chunk, each one building a `ModelDownloadProgress`
and pushing it through a broadcast controller. On a fast link that is tens of
thousands of events per second into whatever `StreamBuilder` the app wired
up. No extra information — a display cannot show it.

**Fix:** 150 ms minimum interval for `downloading` ticks; state transitions
always emit immediately, and an explicit `flush()` when a file finishes and
again before `download()` returns.

The `flush()` is not incidental. Without it the throttle swallows the last
tick of a transfer and the progress bar parks at 97% forever — the existing
download tests caught exactly that, asserting `progressEvents.last.fraction
== 1.0`. A rate limiter on a progress stream must always deliver the final
value.

### 4.6 Stream controllers were never closed — *fixed*

`ModelManagerImpl` created a broadcast `StreamController` per model for
`watchStatus` and another for `downloadProgress`, kept them in maps, and had
no `dispose`. `LocalAI.dispose()` disposed the scheduler and the audio stack
but not the manager. An app that watched 30 catalog rows kept 60 controllers
for the process lifetime. The `HttpClient` in `DownloadManager` was likewise
never closed.

**Fix:** `ModelManagerImpl.dispose()` and `DownloadManager.dispose()`, called
from `LocalAI.dispose()`. Adds also became `isClosed`-guarded — `watchStatus`
does an async `getStatus` and then `controller.add`, which could land after
a close.

### 4.7 `RuntimeScheduler.adapter<T>` masked the real error — *fixed*

`handle.adapter as T` threw a `TypeError` on a mis-registered provider, which
`_CapabilityGate.ready` caught with `on Object` and replaced with "Did you
register the matching AdapterPlugin?" — the one thing that was *not* wrong.

**Fix:** an explicit `is! T` check with a message naming both types, and
`ready` rethrows `LocalAIError` instead of swallowing it.

### 4.8 The idle sweep could run reentrantly — *fixed*

`Timer.periodic(sweepInterval, (_) => _sweepIdle())` does not await the
callback. A sweep whose `unload()` takes longer than the interval overlaps
with the next one; both read the same `_handles` and both call `_unload` on
the same id. `_unload` is idempotent (`remove` returns null the second time),
so the damage was a duplicate `RuntimeModelUnloaded` event rather than a
double free — but it is one refactor away from being worse.

**Fix:** a `_sweeping` guard.

### 4.9 Events could be added to a closed controller — *fixed*

`dispose()` closed `_events` while `_sweepIdle` and in-flight `_unload`
futures could still be running. Guarded with `isClosed`.

### 4.10 `setLocked` silently did nothing for an unloaded model — *fixed*

`setLocked` looks up `_handles[modelId]` and returns if absent. Locking a
model that has not loaded yet — the natural thing to do when starting a
voice session — was a no-op, and the model became evictable the moment it
loaded.

**Fix:** `setPinned` keeps a `_pinned` set consulted by the eviction and
sweep paths and applied at load time. `setLocked` keeps its old
loaded-only semantics and is documented as such.

### 4.11 Device capabilities were cached forever — *fixed*

`FlutterDeviceProbe` cached the first probe for the process lifetime. Two of
its four metrics move: free RAM changes as models load, free disk changes as
models download. Gating a second 2 GB download on a disk reading from app
start would let it start against space the first download already took.

**Fix:** a 30 s TTL in `FlutterDeviceProbe` (configurable, `invalidate()` to
drop it) and a matching TTL in the scheduler's own cache.

### 4.12 `initialize` does not validate that adapters exist — *not fixed*

`LocalAIConfig(llm: LlmConfig(modelId: 'x'))` with an empty `plugins:` list
initializes cleanly and throws `AdapterNotFoundError` at the first
`generate`, possibly minutes later, possibly after a download. The registry
knows its provider keys (`AdapterRegistry` gained key accessors in `80bab71`)
and the catalog knows each configured model's provider, so this is checkable
at wiring time.

**Proposed:** `initialize` resolves every configured model's manifest,
checks the registry has a factory for `(provider, capability)`, and throws
`AdapterNotFoundError` listing what to add. Behind a
`validateAdapters: true` parameter for one release, then default-on.

Not in this slice because it needs a decision about offline behaviour: the
catalog `get` can fail when a remote-only manifest has not been fetched, and
failing `initialize` on a network hiccup is worse than the problem.

### 4.13 `ModelStatus.copyWith` cannot clear fields — *not fixed*

`error: error ?? this.error` means a model that fails and then succeeds keeps
its stale `LocalAIError`. Same for `progress`. `_setStatus` sidesteps it by
constructing a fresh `ModelStatus`, so nothing hits it today. Low severity,
but it is a trap for the next person to use `copyWith`.

**Proposed:** sentinel-based clearing, or drop `copyWith` from the class.

### 4.14 `registerExternalModel` accepts a zero-file manifest — *not fixed*

It rejects `files.length > 1` but not `files.isEmpty`, and then falls back to
deriving the name from the path. A zero-file manifest makes
`ModelInstaller.isInstalled` trivially true (it checks that every declared
file exists — vacuously true for none), so a broken registration reports as
installed. Low severity: it needs a caller to construct a nonsense manifest.

### 4.15 Documentation described unimplemented behaviour

Not a code bug, but the highest-impact defect in the list for adoption:
`docs/faq.md`, `docs/runtime-memory.md` and `docs/platform-layer.md` all
described the compatibility check as working. §4.1 makes them true. Any
future doc claim about a check should point at the test that proves it.

---

## 5. Feature — model/device compatibility checker

### 5.1 Requirement

Validate a model against the device and *return* a verdict before the
download starts, rather than discovering the mismatch at load time.

### 5.2 Shape

A pure function in `local_ai_core`:

```dart
CompatibilityReport ModelCompatibilityChecker.check({
  required LocalModelManifest manifest,
  required DeviceCapabilities device,
  ModelCompatibilityPolicy policy = const ModelCompatibilityPolicy(),
  int? requestedContextTokens,
});
```

No I/O, no Flutter, no `async`. Everything it needs is in its two arguments,
which means it is exhaustively unit-testable with `dart test` and no device —
important, because this is exactly the code that is impossible to test on the
one device a maintainer happens to own.

### 5.3 The checks

| Check | Blocks? | Source of truth |
|---|---|---|
| `platform` | Yes | `manifest.platforms` vs `device.platform` |
| `totalMemory` | Yes | `manifest.minMemoryMB` vs `device.totalMemoryMB` |
| `availableMemory` | Warning (blocking under `.strict()`) | vs `device.availableMemoryMB` |
| `disk` | Yes | `manifest.totalSizeMB × 1.2` vs `device.freeDiskMB` |
| `accelerator` | Yes for `requiredAccelerators`, warning for `preferredAccelerators` | `device.accelerators` |
| `contextWindow` | Warning | `LlmConfig.maxContextTokens` vs `manifest.contextLength` |
| `unknown` | Warning | any probe metric that read `0` |

Three design decisions worth recording:

**Blocking versus warning is a real distinction.** "Not enough disk" is a
fact about the download and blocks it. "Only 200 MB of RAM free right now" is
a fact about this instant — the scheduler can evict a model and change it —
and blocking on it would make the library flaky. So capacity checks against
*total* resources block; checks against *momentary* resources warn. Apps that
want the stricter behaviour ask for `ModelCompatibilityPolicy.strict()`.

**An unprobed metric is neither a pass nor a fail.** `DeviceMetricsSource`
reports `0` for a metric it could not read rather than fabricating one, and
that honesty has to survive into the checker. A `0` produces a
`CompatibilityCheck.unknown` warning saying which check was skipped. It never
blocks: refusing to download because we could not read `/proc/meminfo` on
some Linux distribution is worse than trying and failing.

**`minMemoryMB` defaults to `0`, so most manifests declare nothing.** The
checker falls back to `weights × 1.15 + 256 MB`, which is crude but tracks
reality for quantized weights that a runtime largely maps as-is. Because it
is an estimate, it *only ever warns* — an estimate must never block a
download. Turn it off with `estimateMemoryFromFileSize: false`.

### 5.4 Where it is called

```
ai.models.checkCompatibility(id)      →  app-facing, never throws.
                                          Build your download UI on this.
ai.models.compatible(type: …)         →  the whole catalog, filtered,
                                          each row with its report.

ModelManagerImpl._installInternal     →  gate, runs before the first byte.
RuntimeScheduler._loadInternal        →  gate, runs before adapter.load().
```

Both gates read `LocalAIConfig.compatibilityEnforcement`:

- `enforce` (default) — a blocking issue throws `IncompatibleDeviceError`,
  which carries the whole report.
- `warn` — the report is emitted as `RuntimeCompatibilityChecked` on
  `runtime.events` and the operation proceeds.
- `off` — no probe, no check. For tests and for apps that know better.

`enforce` as the default is a behaviour change: code that previously started
a doomed download now throws. That is the point of the feature, it is a
`0.0.x` package, and the escape hatch is one config field.

### 5.5 Manifest additions

`requiredAccelerators` and `preferredAccelerators`, both defaulting to empty
(so every existing manifest is unchanged) and both JSON-round-tripped. The
decoder skips accelerator names it does not recognise rather than failing the
manifest, so a remote catalog written against a newer core does not break an
older client — which matters because the remote catalog is a shared artifact
whose readers upgrade at their own pace.

---

## 6. Feature — model loader, warm-up and cache management

### 6.1 Requirement

Loading a model takes time and had no loader, no caching strategy the app
could see or influence, and no way to shorten the wait.

### 6.2 Observable loading

`ModelLoadPhase`: `queued → evicting → openingFiles → initializingRuntime →
warmingUp → ready`, or `failed` from anywhere. Each transition produces a
`ModelLoadProgress` carrying `modelId`, `phase`, `elapsed`, an optional
`detail` (backend name, fallback reason), and — the part that makes a real
progress bar possible — `expectedDuration`: how long *this* model took the
last time it loaded on *this* device.

```dart
StreamBuilder<ModelLoadProgress>(
  stream: ai.runtime.loadProgress('gemma-3n-e2b-it-int4'),
  builder: (context, snapshot) {
    final p = snapshot.data;
    if (p == null || p.phase == ModelLoadPhase.ready) return ChatView();
    return LinearProgressIndicator(value: p.fraction);  // null → indeterminate
  },
);
```

`fraction` is `null` on the first ever load — nothing is known, so an honest
indeterminate spinner — and a real ratio on every load after, clamped to
`0.99` while running so the bar never sits full while the user waits.

Two delivery paths, deliberately: `runtime.loadProgress(id)` for one model,
`runtime.events` (as `RuntimeModelLoadProgress`) for a global "loading
models…" banner. `loadProgress` replays the current phase to a late
subscriber, so a widget that mounts mid-load renders a loader rather than a
blank screen until the next transition.

### 6.3 Reducing the wait

Three mechanisms, in increasing order of how much they cost:

**Coalescing (always on, free).** §4.2. N concurrent requests for a model
produce one load.

**Warm-up (opt in, costs start-up time).** `ai.warmUp()` installs and loads
every configured model ahead of first use;
`LocalAIConfig(warmUpOnInitialize: true)` runs it in the background from
`initialize`, which returns immediately regardless. A failure on one model
does not abort the others — `warmUp` returns `Map<String, Object?>` with
`null` for each success and the error for each failure, because a voice
assistant whose TTS voice failed to download should still be able to listen.

**Pinning (opt in, costs RAM).** `ai.pinModel(id)` exempts a model from LRU
eviction, the idle sweep and the background trim. The case it exists for: an
app whose chat LLM is used constantly while a voice session loads and unloads
VAD/STT/TTS around it under `maxLoadedModels: 2`, evicting and reloading the
LLM every cycle.

### 6.4 Making the cache measurable

The eviction policy is two numbers — `maxLoadedModels` and
`unloadUnusedAfter` — and nothing told an app whether its numbers were right.

`ai.runtime.cacheStats` returns `ModelCacheStats`: `hits`, `misses`,
`evictions`, `idleUnloads`, `loadedModelIds`, `maxLoadedModels`, and
`lastLoadDurations` per model. A high `missRate` with high `evictions` over a
small set of ids is thrashing, and says `maxLoadedModels` is too low for the
app's access pattern. `lastLoadDurations` prices it: how many seconds each
miss actually costs this user on this device.

This is diagnostic, not automatic. Auto-tuning `maxLoadedModels` from
observed pressure is a plausible next step and is *not* in this slice —
memory decisions that change themselves are hard to debug from a crash
report.

### 6.5 Load-time memory accounting

`LoadedModel.estimatedBytes` was `manifest.minMemoryMB * 1024 * 1024`, which
is `0` for the majority of manifests, so `memoryUsage.modelBytes` was
usually `0` no matter what was loaded. It now falls back to
`manifest.totalSizeBytes` — the weights, which a runtime maps more or less
as-is. Still an estimate, now a non-zero one.

---

## 7. The installer agent skill

`.claude/skills/local-ai-kit-installer/SKILL.md`.

The reasoning: the integration is documented across eleven files in `docs/`
plus `AGENTS.md`, and the parts that bite — which adapter for which model
format, the native `llama.cpp` build, Android/iOS permission entries, the
`sherpa` desktop-Python caveat — are exactly the parts a newcomer will not
find before hitting them. That is a repeatable procedure with a lot of
lookup, which is what a skill is for.

The skill reads the repo's own docs rather than restating them, so it cannot
drift from the source the way a hardcoded guide would. It produces a working
integration plus a written `LOCAL_AI_KIT_SETUP.md` in the target project.

Layout:

```
.claude/skills/local-ai-kit-installer/
  SKILL.md                          procedure + a table of what to read where
  references/platform-setup.md      Android/iOS/macOS/desktop, from examples/demo
  references/troubleshooting.md     symptom → cause, per LocalAIError
```

The two reference files carry the material that is stable enough to write
down — manifest entries, entitlements, the error table — while `SKILL.md`
sends the agent to the live docs for anything that moves (model ids,
versions, capability status).

Scope boundary: the skill installs and integrates. It does not invent model
ids (it reads the catalog), and it does not claim a capability works on a
platform where the honest answer is "desktop prototype" — the sherpa caveat
in `AGENTS.md` is part of what it must relay.

---

## 8. Explicitly not in this slice

| Item | Why deferred |
|---|---|
| Renaming `bedge_ai` → `local_ai_kit_all` | Publishing decision, one-way door, belongs in a deliberate `0.1.0` |
| `initialize` adapter validation (§4.12) | Needs an offline-behaviour decision first |
| Auto-tuning `maxLoadedModels` | Self-modifying memory policy is hard to debug from the field |
| A `smokeTest()` preset / bundled tiny model | Bundle-policy and licensing review needed |
| `ModelStatus.copyWith` clearing (§4.13) | Unreachable today; would be churn without a caller |
| Real `sherpa_onnx` FFI for STT/TTS/VAD | Large, separate, already tracked in `AGENTS.md` |

---

## 9. Verification

`flutter analyze` is clean across the workspace and every package's suite
passes: 246 tests, up from 174 before this slice.

| Suite | What it covers |
|---|---|
| `local_ai_core/test/model_compatibility_test.dart` (32) | Every check, both severities, the estimate path, the unknown-metric path, the policy presets, manifest JSON round-trip |
| `local_ai_kit/test/runtime_scheduler_test.dart` (28) | Load coalescing (including the deadlock of §4.3), phase progress, late subscribers, pinning, cache stats, warm-up partial failure, the load gate, the capability TTL |
| `local_ai_kit/test/download_compatibility_gate_test.dart` (12) | The pre-download gate: reports without side effects, the throw before the first byte, each enforcement mode, a failing probe |

The compatibility checker is pure — no I/O, no Flutter — so it runs under
`dart test` on any machine, which matters because it is exactly the code that
cannot be tested on the one device a maintainer happens to own.

Three behaviour changes that existing tests caught, recorded because each one
is a real change and not a test artifact:

- `skills_facade_test.dart` now injects a `deviceProbe`. It previously
  asserted against the host OS, and the platform check correctly rejected a
  mobile-only manifest on Linux. A test whose result depends on the CI
  machine's RAM was never right.
- The download tests' `progressEvents.last.fraction == 1.0` assertion caught
  the missing `flush()` in §4.5.
- `getStatus` after a blocked install returns `notInstalled`, not `failed`:
  it deliberately re-derives a failed model from disk rather than serving the
  cached failure. The `failed` status with the attached report is delivered
  on `watchStatus`, which is what an app binds to.

The rule this establishes, and the one §4.15 is about: a documented guarantee
needs a test that fails when the guarantee stops holding. The compatibility
check was documented for two releases while returning a constant.
