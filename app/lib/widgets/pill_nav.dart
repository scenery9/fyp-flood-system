import 'package:material_ui/material_ui.dart';

import '../theme/app_theme.dart';

class PillNavItem {
  const PillNavItem(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// Floating pill menu with a sliding highlight. Always visible: it does not
/// hide on scroll or when idle. Each tab is at least 52 x 52.
class PillNav extends StatelessWidget {
  const PillNav({super.key, required this.items, required this.index, required this.onTap});
  final List<PillNavItem> items;
  final int index;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    // Labels may grow with the text size setting, but not past 1.3x, so 4 tabs still fit.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(36),
          border: c.cardBorder == null ? null : Border.all(color: c.cardBorder!, width: 1.5),
          boxShadow: const [
            BoxShadow(color: Color(0x1A111418), blurRadius: 24, offset: Offset(0, 6)),
            BoxShadow(color: Color(0x14111418), blurRadius: 3, offset: Offset(0, 1)),
          ],
        ),
        child: LayoutBuilder(builder: (context, box) {
          final w = box.maxWidth / items.length;
          return Stack(
            children: [
              AnimatedPositioned(
                duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 380),
                curve: Curves.easeOutBack,
                left: index * w,
                top: 0,
                bottom: 0,
                width: w,
                child: Container(
                  decoration: BoxDecoration(color: c.primaryTint, borderRadius: BorderRadius.circular(30)),
                ),
              ),
              Row(
                children: [
                  for (var i = 0; i < items.length; i++)
                    Expanded(
                      child: Semantics(
                        button: true,
                        selected: i == index,
                        label: items[i].label,
                        excludeSemantics: true,
                        child: InkWell(
                          key: ValueKey('tab-${items[i].label}'),
                          borderRadius: BorderRadius.circular(30),
                          onTap: () => onTap(i),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 60),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(i == index ? items[i].selectedIcon : items[i].icon,
                                    size: 24, color: i == index ? c.primary : c.textMuted),
                                const SizedBox(height: 2),
                                Text(
                                  items[i].label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 15,
                                    height: 1.1,
                                    fontWeight: i == index ? FontWeight.w700 : FontWeight.w500,
                                    color: i == index ? c.primary : c.textMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        }),
      ),
    );
  }
}
