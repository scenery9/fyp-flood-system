import 'package:material_ui/material_ui.dart';

import '../theme/app_theme.dart';

/// A small set of options as tappable boxes that wrap onto more lines.
/// Used instead of typing wherever the answer is one of a few choices.
/// [selected] holds the chosen value(s); single or multiple choice is up to
/// the caller's [onTap].
class ChoiceBoxes<T> extends StatelessWidget {
  const ChoiceBoxes({
    super.key,
    required this.values,
    required this.selected,
    required this.label,
    required this.onTap,
    required this.keyPrefix,
    this.icon,
    this.multiple = false,
  });
  final List<T> values;
  final Set<T> selected;
  final String Function(T) label;
  final ValueChanged<T> onTap;
  final IconData? Function(T)? icon;

  /// Keys are `$keyPrefix-name` (name = the value's name) for tests.
  final String keyPrefix;

  /// Ticks instead of a single choice (for screen readers).
  final bool multiple;

  static String _name(Object? v) => v is Enum ? v.name : '$v';

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final v in values)
          Semantics(
            selected: multiple ? null : selected.contains(v),
            checked: multiple ? selected.contains(v) : null,
            inMutuallyExclusiveGroup: multiple ? null : true,
            button: true,
            label: label(v),
            excludeSemantics: true,
            child: InkWell(
              key: ValueKey('$keyPrefix-${_name(v)}'),
              borderRadius: BorderRadius.circular(14),
              onTap: () => onTap(v),
              child: Container(
                constraints: const BoxConstraints(minHeight: 48, minWidth: 64),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: selected.contains(v) ? const Color(0xFFEAF1F8) : Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: selected.contains(v) ? c.primary : c.divider, width: 2),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (selected.contains(v)) ...[
                    Icon(Icons.check, size: 20, color: c.primary),
                    const SizedBox(width: 6),
                  ] else if (icon?.call(v) != null) ...[
                    Icon(icon!(v), size: 20, color: c.textMuted),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(label(v),
                        style: TextStyle(
                            fontSize: 16,
                            height: 1.2,
                            fontWeight: selected.contains(v) ? FontWeight.w700 : FontWeight.w500,
                            color: selected.contains(v) ? c.primary : c.text)),
                  ),
                ]),
              ),
            ),
          ),
      ],
    );
  }
}

/// "Babies   −  2  +": a number changed only with buttons (56 x 56).
class CountStepper extends StatelessWidget {
  const CountStepper({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.keyPrefix,
    this.lessLabel,
    this.moreLabel,
  });
  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;
  final String keyPrefix;
  final String? lessLabel;
  final String? moreLabel;

  @override
  Widget build(BuildContext context) {
    Widget button(IconData icon, String name, int next, bool enabled, String key) => Semantics(
          button: true,
          enabled: enabled,
          label: '$name: $label',
          excludeSemantics: true,
          child: IconButton.filledTonal(
            key: ValueKey(key),
            onPressed: enabled ? () => onChanged(next) : null,
            iconSize: 26,
            style: IconButton.styleFrom(minimumSize: const Size(56, 56)),
            icon: Icon(icon),
          ),
        );
    return Container(
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(child: Text(label, style: context.text.bodyLarge)),
        button(Icons.remove, lessLabel ?? 'Fewer', value - 1, value > min, '$keyPrefix-minus'),
        SizedBox(
          width: 52,
          child: Semantics(
            liveRegion: true,
            label: '$label: $value',
            excludeSemantics: true,
            child: Text('$value',
                textAlign: TextAlign.center,
                style: context.text.headlineSmall!.copyWith(fontFeatures: AppText.tabular)),
          ),
        ),
        button(Icons.add, moreLabel ?? 'More', value + 1, value < max, '$keyPrefix-plus'),
      ]),
    );
  }
}

/// Label with an on/off switch; the whole row toggles (like the rows in
/// More). Plain InkWell, so it sits on a white card without ListTile's
/// background warning.
class SwitchRow extends StatelessWidget {
  const SwitchRow({super.key, required this.label, required this.value, required this.onChanged});
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => MergeSemantics(
        child: InkWell(
          onTap: () => onChanged(!value),
          child: Container(
            constraints: const BoxConstraints(minHeight: 64),
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              Expanded(child: Text(label, style: context.text.bodyLarge)),
              const SizedBox(width: 12),
              Switch(value: value, onChanged: onChanged),
            ]),
          ),
        ),
      );
}
