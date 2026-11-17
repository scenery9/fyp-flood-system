import 'risk_level.dart';

enum AppLanguage { en, ms, zh }

enum TextSize { small, medium, large }

class AppSettings {
  const AppSettings({
    this.language = AppLanguage.en,
    this.textSize = TextSize.medium,
    this.highContrast = false,
    this.region,
    this.notificationThreshold = RiskLevel.alert,
  });
  final AppLanguage language;
  final TextSize textSize;
  final bool highContrast;

  /// State to show by default (null = all states).
  final String? region;

  /// Lowest risk level that sends a notification.
  final RiskLevel notificationThreshold;

  AppSettings copyWith({
    AppLanguage? language,
    TextSize? textSize,
    bool? highContrast,
    String? region,
    bool clearRegion = false,
    RiskLevel? notificationThreshold,
  }) =>
      AppSettings(
          language: language ?? this.language,
          textSize: textSize ?? this.textSize,
          highContrast: highContrast ?? this.highContrast,
          region: clearRegion ? null : (region ?? this.region),
          notificationThreshold: notificationThreshold ?? this.notificationThreshold);

  Map<String, String> toMap() => {
        'language': language.name,
        'textSize': textSize.name,
        'highContrast': '$highContrast',
        if (region != null) 'region': region!,
        'notificationThreshold': notificationThreshold.name,
      };

  /// Reads saved settings. Anything missing or unreadable falls back to the default.
  factory AppSettings.fromMap(Map<String, String> m) {
    T pick<T extends Enum>(List<T> values, String? name, T fallback) {
      for (final v in values) {
        if (v.name == name) return v;
      }
      return fallback;
    }

    const d = AppSettings();
    final threshold = pick(RiskLevel.values, m['notificationThreshold'], d.notificationThreshold);
    final region = m['region']?.trim();
    return AppSettings(
        language: pick(AppLanguage.values, m['language'], d.language),
        textSize: pick(TextSize.values, m['textSize'], d.textSize),
        highContrast: m['highContrast'] == 'true',
        region: (region == null || region.isEmpty) ? null : region,
        notificationThreshold:
            threshold == RiskLevel.normal ? d.notificationThreshold : threshold);
  }
}
