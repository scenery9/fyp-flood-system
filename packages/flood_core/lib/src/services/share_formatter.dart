import '../models/station_status.dart';

/// Builds the plain text for the Share button.
class ShareFormatter {
  const ShareFormatter();

  String statusText(StationStatus s) {
    final lines = <String>[
      '${s.station.name} (${s.station.district}, ${s.station.state})',
      s.level == null
          ? 'Status: Unknown'
          : 'Status: ${s.level!.labelEn} (${s.level!.labelBm})',
    ];
    if (s.riverLevel != null) {
      final pct = s.percentToTarget == null
          ? ''
          : ' (${s.percentToTarget!.round()}% to ${s.targetLevel!.labelEn} level)';
      lines.add('River level: ${s.riverLevel!.toStringAsFixed(2)} m$pct');
    }
    if (s.rainfall != null) {
      lines.add('Rainfall: ${s.rainfall!.toStringAsFixed(1)} mm/hr');
    }
    if (s.reading != null) {
      lines.add('Updated: ${_myt(s.reading!.time)}${s.isStale ? ' (old data)' : ''}');
    } else {
      lines.add('No readings yet');
    }
    lines.add('Not an official warning. Check publicinfobanjir.water.gov.my');
    return lines.join('\n');
  }

  /// Malaysia time (UTC+8), e.g. "2026-11-17 03:10 MYT".
  String _myt(DateTime t) {
    final m = t.toUtc().add(const Duration(hours: 8));
    String two(int n) => n.toString().padLeft(2, '0');
    return '${m.year}-${two(m.month)}-${two(m.day)} ${two(m.hour)}:${two(m.minute)} MYT';
  }
}
