// ignore_for_file: avoid_print
import 'package:flutter/widgets.dart';
import 'package:local_ai_flutter/local_ai_flutter.dart';

/// Minimal usage of the platform services in `local_ai_flutter`.
///
/// Run with `flutter run example/local_ai_flutter_example.dart` from an app
/// shell, or copy the calls below into your own `main()`.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Resolve on-device storage for downloaded models.
  final storage = await FlutterStoragePaths.resolve();
  print('Model root: ${storage.rootDir}');

  // Request microphone access before starting a voice session.
  final permissions = PermissionGate();
  if (!await permissions.hasMicrophone()) {
    await permissions.ensureMicrophone();
  }

  // Probe the device for LLM/runtime capability hints (RAM, accelerators).
  final probe = FlutterDeviceProbe();
  final capabilities = await probe.probe();
  print('Detected accelerators: ${capabilities.accelerators}');

  // React to connectivity changes when deciding whether to fetch a model.
  final network = FlutterNetworkPolicy();
  final canDownload = await network.canDownload(wifiOnly: true);
  print('Wi-Fi download allowed: $canDownload');
}
