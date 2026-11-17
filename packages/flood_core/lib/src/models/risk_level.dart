/// Flood risk levels, lowest to highest (same four levels JPS uses).
enum RiskLevel {
  normal('Normal', 'Normal'),
  alert('Alert', 'Waspada'),
  warning('Warning', 'Amaran'),
  danger('Danger', 'Bahaya');

  const RiskLevel(this.labelEn, this.labelBm);
  final String labelEn;
  final String labelBm;

  bool isAtLeast(RiskLevel other) => index >= other.index;
}

/// Rainfall intensity bands (mm per hour).
/// PROVISIONAL cut-offs (10 / 30 / 60): confirm against MetMalaysia before the report.
enum RainIntensity {
  none,
  light,
  moderate,
  heavy,
  veryHeavy;

  /// Returns null when there is no rainfall data.
  static RainIntensity? fromMm(double? mmPerHr) {
    if (mmPerHr == null) return null;
    if (mmPerHr <= 0) return none;
    if (mmPerHr <= 10) return light;
    if (mmPerHr <= 30) return moderate;
    if (mmPerHr <= 60) return heavy;
    return veryHeavy;
  }
}
