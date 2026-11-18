import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

/// Colours, type scale and spacing for the whole app.
/// Spacing follows an 8-point grid: 4 for fine steps, then 8, 12, 16, 24, 32.
class AppColors {
  const AppColors({
    required this.background,
    required this.surface,
    required this.text,
    required this.textMuted,
    required this.divider,
    required this.primary,
    required this.primaryTint,
    required this.cardBorder,
  });

  final Color background;
  final Color surface;
  final Color text;
  final Color textMuted;
  final Color divider;
  final Color primary;
  final Color primaryTint;

  /// Null in the normal theme (cards have no border); a strong border in high contrast.
  final Color? cardBorder;

  static const normal = AppColors(
    background: Color(0xFFEAF1F8),
    surface: Color(0xFFFFFFFF),
    text: Color(0xFF111418),
    textMuted: Color(0xFF4F5966), // 7.1:1 on white
    divider: Color(0xFFE3E5E8),
    primary: Color(0xFF1F5FA8), // 6.4:1 on white
    primaryTint: Color(0xFFDCE8F6),
    cardBorder: null,
  );

  static const highContrast = AppColors(
    background: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    text: Color(0xFF000000),
    textMuted: Color(0xFF2B323B),
    divider: Color(0xFF4F5966),
    primary: Color(0xFF123F75),
    primaryTint: Color(0xFFDCE8F6),
    cardBorder: Color(0xFF111418),
  );

  /// SOS red: white text on it is 6.5:1.
  static const sos = Color(0xFFB3261E);
  static const chevron = Color(0xFFAEB8C4); // decorative only
}

/// How each risk level looks. Colour is never used alone: every badge also
/// has an icon and a word.
class RiskStyle {
  const RiskStyle(this.color, this.onTint, this.tint, this.icon);
  final Color color; // text or pin colour on white (all >= 5:1)
  final Color onTint; // text colour on [tint] (all >= 5:1)
  final Color tint;
  final IconData icon;

  static RiskStyle of(RiskLevel? level) => switch (level) {
        RiskLevel.normal => const RiskStyle(Color(0xFF176B3A), Color(0xFF176B3A), Color(0xFFE3F2E8), Icons.check_circle),
        RiskLevel.alert => const RiskStyle(Color(0xFF8A6100), Color(0xFF8A6100), Color(0xFFFFF4D6), Icons.info),
        RiskLevel.warning => const RiskStyle(Color(0xFFB45309), Color(0xFF9A3F06), Color(0xFFFDEBDD), Icons.warning),
        RiskLevel.danger => const RiskStyle(Color(0xFFC4281C), Color(0xFFA8221A), Color(0xFFFBE3DF), Icons.dangerous),
        null => const RiskStyle(Color(0xFF4F5966), Color(0xFF4F5966), Color(0xFFEEF0F2), Icons.help),
      };
}

/// Text sizes. Body text is 17 (Apple's default body size).
class AppText {
  static const tabular = [FontFeature.tabularFigures()];

  static TextTheme textTheme(AppColors c) => TextTheme(
        // Display: the big risk word on the status card.
        displayMedium: TextStyle(fontSize: 64, height: 1.05, fontWeight: FontWeight.w700, letterSpacing: -1.5, color: c.text),
        // Headline: screen titles and big readings.
        headlineLarge: TextStyle(fontSize: 34, height: 1.2, fontWeight: FontWeight.w700, letterSpacing: -0.5, color: c.text),
        headlineSmall: TextStyle(fontSize: 28, height: 1.2, fontWeight: FontWeight.w700, color: c.text),
        // Title: card headings.
        titleLarge: TextStyle(fontSize: 20, height: 1.3, fontWeight: FontWeight.w600, color: c.text),
        titleMedium: TextStyle(fontSize: 17, height: 1.3, fontWeight: FontWeight.w600, color: c.text),
        // Body.
        bodyLarge: TextStyle(fontSize: 17, height: 1.35, color: c.text),
        bodyMedium: TextStyle(fontSize: 15, height: 1.35, color: c.textMuted),
        // Label: buttons and section labels.
        labelLarge: const TextStyle(fontSize: 17, height: 1, fontWeight: FontWeight.w600),
        labelMedium: TextStyle(fontSize: 15, height: 1.3, fontWeight: FontWeight.w600, color: c.textMuted),
        labelSmall: TextStyle(fontSize: 13, height: 1.2, fontWeight: FontWeight.w600, color: c.textMuted),
      );
}

/// Extra theme values the widgets read.
class AppThemeExt extends ThemeExtension<AppThemeExt> {
  const AppThemeExt(this.colors);
  final AppColors colors;

  @override
  AppThemeExt copyWith({AppColors? colors}) => AppThemeExt(colors ?? this.colors);

  @override
  AppThemeExt lerp(covariant ThemeExtension<AppThemeExt>? other, double t) =>
      other is AppThemeExt && t >= 0.5 ? other : this;
}

extension AppThemeX on BuildContext {
  AppColors get colors => Theme.of(this).extension<AppThemeExt>()!.colors;
  TextTheme get text => Theme.of(this).textTheme;
}

const double kCardRadius = 20;
const double kButtonRadius = 16;
const double kMinTap = 48;

ThemeData buildTheme({required bool highContrast}) {
  final c = highContrast ? AppColors.highContrast : AppColors.normal;
  final scheme = ColorScheme.fromSeed(seedColor: c.primary).copyWith(
    primary: c.primary,
    onPrimary: Colors.white,
    surface: c.surface,
    onSurface: c.text,
    error: AppColors.sos,
  );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(kButtonRadius));
  const size = Size(kMinTap, 56);
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: c.background,
    textTheme: AppText.textTheme(c),
    dividerColor: c.divider,
    extensions: [AppThemeExt(c)],
    appBarTheme: AppBarTheme(
      backgroundColor: c.background,
      foregroundColor: c.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: c.text),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: size, shape: shape, textStyle: AppText.textTheme(c).labelLarge),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: size,
        shape: shape,
        foregroundColor: c.primary,
        side: BorderSide(color: c.primary, width: 1.5),
        textStyle: AppText.textTheme(c).labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: const Size(kMinTap, kMinTap), foregroundColor: c.primary, textStyle: AppText.textTheme(c).labelLarge),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
