import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

import '../app/app_controller.dart';
import '../theme/app_theme.dart';

/// Space between cards (12) and the screen's side margin (16).
const double kGap = 12;
const double kMargin = 16;

/// Rounded white card (radius 20, padding 16). In high contrast it gets a border.
/// With [onTap] the whole card is a button (with the usual ripple).
class AppCard extends StatelessWidget {
  const AppCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.onTap});
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (onTap != null) {
      return Material(
        color: c.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kCardRadius),
          side: c.cardBorder == null ? BorderSide.none : BorderSide(color: c.cardBorder!, width: 1.5),
        ),
        child: InkWell(
          onTap: onTap,
          child: Container(width: double.infinity, padding: padding, child: child),
        ),
      );
    }
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(kCardRadius),
        border: c.cardBorder == null ? null : Border.all(color: c.cardBorder!, width: 1.5),
      ),
      child: child,
    );
  }
}

/// Large screen title with an optional line under it.
class ScreenTitle extends StatelessWidget {
  const ScreenTitle(this.title, {super.key, this.subtitle, this.trailing});
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(kMargin, 16, kMargin, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(header: true, child: Text(title, style: context.text.headlineLarge)),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(subtitle!, style: context.text.bodyLarge!.copyWith(color: context.colors.textMuted)),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Small grey heading above a group card (24 above, 8 below, lined up with card text).
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(kMargin + 16, 24, kMargin + 16, 8),
        child: Semantics(header: true, child: Text(text, style: context.text.labelMedium)),
      );
}

/// Small grey label inside a card.
class CardLabel extends StatelessWidget {
  const CardLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Text(text, style: context.text.labelMedium);
}

class Chevron extends StatelessWidget {
  const Chevron({super.key});
  @override
  Widget build(BuildContext context) =>
      const ExcludeSemantics(child: Icon(Icons.chevron_right, color: AppColors.chevron, size: 28));
}

/// A row inside a grouped card that opens another page. At least 56 high.
class LinkRow extends StatelessWidget {
  const LinkRow({super.key, required this.label, this.value, this.subtitle, required this.onTap, this.last = false, this.icon});
  final String label;
  final String? value;
  final String? subtitle;
  final VoidCallback onTap;
  final bool last;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: c.divider))),
          child: Row(
            children: [
              if (icon != null) ...[Icon(icon, color: c.primary, size: 24), const SizedBox(width: 12)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label, style: context.text.bodyLarge),
                    if (subtitle != null) Text(subtitle!, style: context.text.bodyMedium),
                  ],
                ),
              ),
              if (value != null) ...[
                const SizedBox(width: 8),
                Text(value!, style: context.text.bodyLarge!.copyWith(color: c.textMuted, fontFeatures: AppText.tabular)),
              ],
              const SizedBox(width: 4),
              const Chevron(),
            ],
          ),
        ),
      ),
    );
  }
}

/// A group of rows in one card (padding 0 16).
class GroupCard extends StatelessWidget {
  const GroupCard({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: kMargin),
        child: AppCard(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(children: children),
        ),
      );
}

/// Status badge: icon + word on a tinted background. Never colour alone.
class RiskBadge extends StatelessWidget {
  const RiskBadge(this.level, {super.key, this.label});
  final RiskLevel? level;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final s = RiskStyle.of(level);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: s.tint, borderRadius: BorderRadius.circular(14)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(s.icon, size: 18, color: s.onTint),
          const SizedBox(width: 6),
          Text(label ?? context.levelName(level),
              style: TextStyle(fontSize: 15, height: 1.2, fontWeight: FontWeight.w700, color: s.onTint)),
        ],
      ),
    );
  }
}

/// A plain badge with its own colours (for relief centre status).
class TagBadge extends StatelessWidget {
  const TagBadge({super.key, required this.text, required this.color, required this.tint, required this.icon});
  final String text;
  final Color color;
  final Color tint;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(14)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(fontSize: 15, height: 1.2, fontWeight: FontWeight.w700, color: color)),
        ]),
      );
}

/// "3 of 7" shown as 7 segments with 3 filled.
class ProgressSegments extends StatelessWidget {
  const ProgressSegments({super.key, required this.done, required this.total});
  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ExcludeSemantics(
      child: Row(
        children: [
          for (var i = 0; i < total; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            Expanded(
              child: Container(
                height: 8,
                decoration: BoxDecoration(
                  color: i < done ? c.primary : c.divider,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Pill-shaped segmented control (52 high, 44-high segments), like the
/// Map/List switch in the designs. [colorFor] lets a segment use its own colour.
class PillSegments<T> extends StatelessWidget {
  const PillSegments({
    super.key,
    required this.values,
    required this.selected,
    required this.label,
    required this.onChanged,
    this.colorFor,
    this.semanticsLabel,
  });
  final List<T> values;
  final T selected;
  final String Function(T) label;
  final ValueChanged<T> onChanged;
  final Color Function(T)? colorFor;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      label: semanticsLabel,
      container: true,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: c.background == Colors.white ? c.primaryTint : const Color(0xFFDCE4EC), borderRadius: BorderRadius.circular(26)),
        child: Row(
          children: [
            for (final v in values)
              Expanded(
                child: Semantics(
                  selected: v == selected,
                  button: true,
                  inMutuallyExclusiveGroup: true,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onChanged(v),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      constraints: const BoxConstraints(minHeight: 44),
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                      decoration: BoxDecoration(
                        color: v == selected ? Colors.white : Colors.transparent,
                        borderRadius: BorderRadius.circular(22),
                        boxShadow: v == selected
                            ? const [BoxShadow(color: Color(0x24111418), blurRadius: 3, offset: Offset(0, 1))]
                            : null,
                      ),
                      child: Text(
                        label(v),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          height: 1,
                          fontWeight: v == selected ? FontWeight.w700 : FontWeight.w500,
                          color: v == selected ? (colorFor?.call(v) ?? c.primary) : c.textMuted,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Grey note text (15), lined up with card text.
class NoteText extends StatelessWidget {
  const NoteText(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(kMargin + 16, 16, kMargin + 16, 0),
        child: Text(text, style: context.text.bodyMedium),
      );
}

/// Standard page for sub-screens: back button, title, scrolling body.
class SubPage extends StatelessWidget {
  const SubPage({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: SafeArea(
          top: false,
          child: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: children,
          ),
        ),
      );
}

String formatAge(BuildContext context, Duration? d) {
  if (d == null) return context.tr('no readings', 'tiada bacaan');
  if (d.inMinutes < 1) return context.tr('just now', 'sebentar tadi');
  if (d.inHours < 1) return context.tr('${d.inMinutes} min ago', '${d.inMinutes} min lalu', '${d.inMinutes} 分钟前');
  if (d.inDays < 1) return context.tr('${d.inHours} h ago', '${d.inHours} jam lalu', '${d.inHours} 小时前');
  return context.tr('${d.inDays} days ago', '${d.inDays} hari lalu', '${d.inDays} 天前');
}

String metres(double v) => '${v.toStringAsFixed(2)} m';

/// Height of a JPS line ("8.20 m"), for "91% to Warning (8.20 m)".
String? lineHeight(StationStatus s, RiskLevel? level) {
  final t = s.station.thresholds;
  if (t == null || level == null) return null;
  return metres(switch (level) {
    RiskLevel.normal => t.normal,
    RiskLevel.alert => t.alert,
    RiskLevel.warning => t.warning,
    RiskLevel.danger => t.danger,
  });
}

/// "91% to Warning (8.20 m)", or "Above the Danger line (19.95 m)" once
/// the river is at Danger. Same words on the list and the station page.
String? towardsText(BuildContext context, StationStatus s) {
  final p = s.percentToTarget, l = s.targetLevel;
  if (s.level == RiskLevel.danger) {
    final h = lineHeight(s, RiskLevel.danger);
    return context.tr('Above the Danger line${h == null ? '' : ' ($h)'}', 'Di atas garis Bahaya${h == null ? '' : ' ($h)'}',
        '高于危险线${h == null ? '' : '（$h）'}');
  }
  if (p == null || l == null) return null;
  final h = lineHeight(s, l);
  final at = h == null ? '' : ' ($h)';
  return context.tr('${p.round()}% to ${context.levelName(l)}$at', '${p.round()}% ke ${context.levelName(l)}$at', '距${context.levelName(l)} ${p.round()}%${h == null ? '' : '（$h）'}');
}
