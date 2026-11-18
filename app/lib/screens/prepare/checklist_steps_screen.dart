import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';

/// Step-by-step checklist: one item per page ("Step 3 of 7"), then a finish page.
class ChecklistStepsScreen extends StatefulWidget {
  const ChecklistStepsScreen({super.key, required this.level, this.startAt});
  final RiskLevel level;

  /// Page to open on. Null = the first item not done yet.
  final int? startAt;

  @override
  State<ChecklistStepsScreen> createState() => _ChecklistStepsScreenState();
}

class _ChecklistStepsScreenState extends State<ChecklistStepsScreen> {
  PageController? _pages;
  int _index = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_pages != null) return;
    final app = AppScope.read(context);
    final items = app.checklist(widget.level);
    var start = widget.startAt ?? items.indexWhere((i) => !app.done.contains(i.id));
    if (start < 0) start = items.length; // all done: open the finish page
    _index = start;
    _pages = PageController(initialPage: start);
  }

  @override
  void dispose() {
    _pages?.dispose();
    super.dispose();
  }

  void _go(int i) {
    final reduce = MediaQuery.of(context).disableAnimations;
    if (reduce) {
      _pages!.jumpToPage(i);
    } else {
      _pages!.animateToPage(i, duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final items = app.checklist(widget.level);
    final n = items.length;
    final doneCount = items.where((i) => app.done.contains(i.id)).length;
    final onFinish = _index >= n;
    return Scaffold(
      appBar: AppBar(
        title: Text(onFinish
            ? context.tr('Checklist summary', 'Ringkasan senarai semak')
            : context.tr('Step ${_index + 1} of $n', 'Langkah ${_index + 1} daripada $n', '第 ${_index + 1} 步，共 $n 步')),
      ),
      body: SafeArea(
        top: false,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(kMargin, 8, kMargin, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(context.tr('${context.levelName(widget.level)} · $doneCount of $n done', '${context.levelName(widget.level)} · $doneCount daripada $n selesai', '${context.levelName(widget.level)} · 已完成 $doneCount / $n'),
                  style: context.text.labelMedium!.copyWith(fontFeatures: AppText.tabular)),
              const SizedBox(height: 8),
              ProgressSegments(done: doneCount, total: n),
            ]),
          ),
          Expanded(
            child: PageView.builder(
              controller: _pages,
              itemCount: n + 1,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) => i < n
                  ? _StepPage(
                      item: items[i],
                      number: i + 1,
                      total: n,
                      done: app.done.contains(items[i].id),
                      showReason: app.householdVisible,
                      onDone: () async {
                        await app.setDone(items[i].id, true);
                        _go(i + 1);
                      },
                      onUndo: () => app.setDone(items[i].id, false),
                      onSkip: () => _go(i + 1),
                      onBack: i == 0 ? null : () => _go(i - 1),
                    )
                  : _FinishPage(items: items, onOpen: _go),
            ),
          ),
        ]),
      ),
    );
  }
}

class _StepPage extends StatelessWidget {
  const _StepPage({
    required this.item,
    required this.number,
    required this.total,
    required this.done,
    required this.showReason,
    required this.onDone,
    required this.onUndo,
    required this.onSkip,
    required this.onBack,
  });
  final PrepItem item;
  final int number;
  final int total;
  final bool done;
  final bool showReason;
  final VoidCallback onDone;
  final VoidCallback onUndo;
  final VoidCallback onSkip;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListView(
      primary: false,
      padding: const EdgeInsets.fromLTRB(kMargin, 16, kMargin, 24),
      children: [
        AppCard(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('$number / $total', style: context.text.labelMedium!.copyWith(fontFeatures: AppText.tabular)),
            const SizedBox(height: 8),
            Semantics(header: true, child: Text(item.title, style: context.text.headlineSmall)),
            const SizedBox(height: 12),
            Text(item.howTo, style: context.text.bodyLarge),
            if (showReason && item.reason != null) ...[
              const SizedBox(height: 12),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.home, color: c.primary, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text(item.reason!, style: context.text.bodyLarge!.copyWith(color: c.primary))),
              ]),
            ],
            if (done) ...[
              const SizedBox(height: 16),
              Row(children: [
                const Icon(Icons.check_circle, color: Color(0xFF176B3A)),
                const SizedBox(width: 8),
                Text(context.tr('Done', 'Selesai'), style: context.text.titleMedium!.copyWith(color: const Color(0xFF176B3A))),
              ]),
            ],
          ]),
        ),
        const SizedBox(height: 24),
        if (!done)
          FilledButton.icon(
            key: const ValueKey('step-done'),
            onPressed: onDone,
            icon: const Icon(Icons.check),
            label: Text(context.tr('Mark as done', 'Tanda selesai')),
          )
        else
          OutlinedButton(
            key: const ValueKey('step-undo'),
            onPressed: onUndo,
            child: Text(context.tr('Not done yet', 'Belum selesai')),
          ),
        const SizedBox(height: kGap),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              key: const ValueKey('step-back'),
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back),
              label: Text(context.tr('Back', 'Kembali')),
            ),
          ),
          const SizedBox(width: kGap),
          Expanded(
            child: FilledButton.tonalIcon(
              key: const ValueKey('step-next'),
              onPressed: onSkip,
              icon: const Icon(Icons.arrow_forward),
              label: Text(done ? context.tr('Next', 'Seterusnya') : context.tr('Skip', 'Langkau')),
            ),
          ),
        ]),
      ],
    );
  }
}

class _FinishPage extends StatelessWidget {
  const _FinishPage({required this.items, required this.onOpen});
  final List<PrepItem> items;
  final ValueChanged<int> onOpen;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final left = [for (var i = 0; i < items.length; i++) if (!app.done.contains(items[i].id)) i];
    return ListView(
      primary: false,
      padding: const EdgeInsets.fromLTRB(kMargin, 16, kMargin, 24),
      children: [
        AppCard(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(left.isEmpty ? Icons.verified : Icons.pending_actions, size: 40, color: context.colors.primary),
            const SizedBox(height: 12),
            Text(
              left.isEmpty
                  ? context.tr('All done for this level', 'Semua selesai untuk tahap ini')
                  : context.tr('${left.length} still to do', '${left.length} belum selesai', '尚有 ${left.length} 项未完成'),
              style: context.text.headlineSmall,
            ),
          ]),
        ),
        if (left.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: CardLabel(context.tr('Still to do', 'Belum selesai')),
          ),
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(children: [
              for (var k = 0; k < left.length; k++)
                LinkRow(label: items[left[k]].title, last: k == left.length - 1, onTap: () => onOpen(left[k])),
            ]),
          ),
        ],
        const SizedBox(height: 24),
        FilledButton(
          key: const ValueKey('steps-finish'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.tr('Back to checklist', 'Kembali ke senarai semak')),
        ),
      ],
    );
  }
}
