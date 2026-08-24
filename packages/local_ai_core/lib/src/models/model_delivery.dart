/// Model delivery strategy + app-level delivery policy.
library;

/// How a model's files reach the device.
enum ModelDelivery {
  /// Files ship inside the app bundle (only viable for tiny models).
  bundled,

  /// Files are downloaded on first use.
  download,

  /// Resolved at build/packaging time via [ModelDeliveryPolicy.smart]:
  /// files smaller than the threshold are bundled, larger ones download.
  bundledIfSmall,

  /// User supplies the files (sideload / enterprise MDM).
  external,
}

/// App-wide policy deciding how `bundledIfSmall` manifests resolve.
class ModelDeliveryPolicy {
  /// Smart policy: models with total size below [bundleBelowMB] are bundled
  /// into the app; everything else downloads on demand. The
  /// `verify:bundle-policy` melos task enforces the threshold at build time.
  const ModelDeliveryPolicy.smart({this.bundleBelowMB = 25});

  /// Threshold in megabytes for [ModelDeliveryPolicy.smart].
  final int bundleBelowMB;

  /// Effective delivery for a model of [totalSizeBytes] whose manifest
  /// declares [declared].
  ModelDelivery resolve(ModelDelivery declared, int totalSizeBytes) {
    if (declared == ModelDelivery.bundledIfSmall) {
      final belowThreshold = totalSizeBytes < bundleBelowMB * 1024 * 1024;
      return belowThreshold ? ModelDelivery.bundled : ModelDelivery.download;
    }
    return declared;
  }
}
