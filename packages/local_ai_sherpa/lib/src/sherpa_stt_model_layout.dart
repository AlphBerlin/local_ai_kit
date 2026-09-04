/// Model families understood by the Sherpa subprocess bridge.
enum SherpaSttModelKind {
  auto,
  dolphin,
  moonshineV1,
  moonshineV2,
}

/// Classifies built-in Sherpa model ids before filesystem heuristics run.
SherpaSttModelKind sherpaSttModelKindForId(String modelId) {
  if (modelId.startsWith('sherpa-onnx-dolphin-')) {
    return SherpaSttModelKind.dolphin;
  }
  if (modelId.startsWith('sherpa-onnx-moonshine-') &&
      modelId.contains('-quantized-2026-02-27')) {
    return SherpaSttModelKind.moonshineV2;
  }
  if (modelId.startsWith('sherpa-onnx-moonshine-')) {
    return SherpaSttModelKind.moonshineV1;
  }
  return SherpaSttModelKind.auto;
}
