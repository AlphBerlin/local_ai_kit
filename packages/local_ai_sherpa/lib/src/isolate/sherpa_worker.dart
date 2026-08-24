/// Worker isolate hosting all sherpa_onnx FFI calls (architecture §5.6).
///
/// Threading model:
///  * One [SherpaWorker] per component (vad/stt/tts), spawned on
///    `load()` and killed on `unload()`.
///  * Commands are sent over a [SendPort]; audio frames travel as
///    `TransferableTypedData` (zero-copy `Float32List` ownership transfer).
///  * Events coming back are lightweight objects (text / timestamps /
///    confidence) — never sherpa types.
///  * Isolate errors are surfaced as [NativeRuntimeError] and the worker
///    can be respawned on the next `load()`.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:local_ai_core/local_ai_core.dart';

/// Command envelope sent to the worker isolate.
class SherpaCommand {
  SherpaCommand(this.op, {this.payload, this.replyTo});

  /// Operation name, e.g. `initVad`, `acceptWaveform`, `decode`, `synthesize`.
  final String op;

  /// Operation arguments (primitive types / maps / TransferableTypedData).
  final Object? payload;

  /// Port the worker replies on for request/response style ops.
  final SendPort? replyTo;
}

/// Event envelope emitted by the worker isolate.
class SherpaWorkerEvent {
  SherpaWorkerEvent(this.kind, {this.data});

  /// `ready` / `result` / `speechStart` / `speechEnd` / `partial` /
  /// `audio` / `error` / `done`.
  final String kind;
  final Object? data;
}

/// Handle to a running worker isolate.
class SherpaWorker {
  SherpaWorker._(this._isolate, this._commands, this._events);

  final Isolate _isolate;
  final SendPort _commands;
  final Stream<SherpaWorkerEvent> _events;

  /// Events from the worker (broadcast within this handle).
  Stream<SherpaWorkerEvent> get events => _events;

  /// Spawns a worker running [entrypoint] with [initPayload].
  ///
  /// The entrypoint is provided by each adapter and is the only place where
  /// sherpa_onnx is touched; it must be a top-level/static function so it
  /// can cross the isolate boundary.
  static Future<SherpaWorker> spawn(
    void Function(SendPort) entrypoint,
  ) async {
    final ready = Completer<SendPort>();
    final events = StreamController<SherpaWorkerEvent>.broadcast();
    final errors = Completer<void>();

    final receivePort = ReceivePort();
    receivePort.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
      } else if (message is SherpaWorkerEvent) {
        events.add(message);
      }
    });

    final isolate = await Isolate.spawn(entrypoint, receivePort.sendPort);
    // Crash isolation: an isolate error becomes a NativeRuntimeError event.
    final errorPort = ReceivePort()
      ..listen((message) {
        if (!errors.isCompleted) errors.complete();
        events.add(SherpaWorkerEvent(
          'error',
          data: NativeRuntimeError('sherpa worker isolate crashed: $message'),
        ));
      });
    isolate.addOnExitListener(errorPort.sendPort);
    isolate.setErrorsFatal(false);

    final commands = await ready.future;
    return SherpaWorker._(isolate, commands, events.stream);
  }

  /// Fire-and-forget command.
  void send(String op, {Object? payload}) {
    _commands.send(SherpaCommand(op, payload: payload));
  }

  /// Request/response command.
  Future<Object?> request(String op, {Object? payload}) {
    final replyPort = ReceivePort();
    _commands
        .send(SherpaCommand(op, payload: payload, replyTo: replyPort.sendPort));
    return replyPort.first.then((value) {
      replyPort.close();
      return value;
    });
  }

  /// Zero-copy audio frame downlink: transfers ownership of the samples
  /// buffer instead of copying it.
  void sendFrame(Float32List samples) {
    _commands.send(SherpaCommand(
      'frame',
      payload: TransferableTypedData.fromList([samples]),
    ));
  }

  /// Kills the isolate. Idempotent.
  void dispose() {
    send('shutdown');
    _isolate.kill(priority: Isolate.immediate);
  }
}

/// Base class for worker entrypoints: implements the command loop and
/// replies to `frame` / request ops. Each adapter subclasses this and
/// overrides [onCommand] with its sherpa_onnx calls.
///
/// Runs entirely inside the worker isolate — sherpa_onnx may be imported
/// here and in subclasses, but types must not leak into reply payloads.
abstract class SherpaWorkerLoop {
  // Public parameter name so subclasses in other libraries can use
  // `SherpaXxxWorkerLoop(super.mainPort)` super-parameters.
  SherpaWorkerLoop(SendPort mainPort) : _mainPort = mainPort {
    _inbox.listen(_dispatch);
  }

  final SendPort _mainPort;
  final ReceivePort _inbox = ReceivePort();

  /// Starts the loop; call once from the entrypoint.
  void run() {
    _mainPort.send(_inbox.sendPort);
  }

  /// Emits an event to the UI isolate.
  void emit(String kind, {Object? data}) {
    _mainPort.send(SherpaWorkerEvent(kind, data: data));
  }

  /// Replies to a request/response command.
  void reply(SherpaCommand command, Object? value) {
    command.replyTo?.send(value);
  }

  Future<void> _dispatch(dynamic raw) async {
    if (raw is! SherpaCommand) return;
    if (raw.op == 'shutdown') {
      await onShutdown();
      _inbox.close();
      return;
    }
    if (raw.op == 'frame' && raw.payload is TransferableTypedData) {
      final data = (raw.payload as TransferableTypedData).materialize();
      await onFrame(data.asFloat32List());
      return;
    }
    await onCommand(raw);
  }

  /// Handle one audio frame (zero-copy downlink).
  Future<void> onFrame(Float32List samples);

  /// Handle a named command.
  Future<void> onCommand(SherpaCommand command);

  /// Cleanup before the isolate exits.
  Future<void> onShutdown();
}
