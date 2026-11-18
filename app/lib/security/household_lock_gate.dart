import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

import 'phone_lock.dart';

/// Shows [child] (the household details) only when the lock rules allow it.
/// The rules themselves are in flood_core's HouseholdLockService.
class HouseholdLockGate extends StatefulWidget {
  const HouseholdLockGate({super.key, required this.lock, required this.phone, required this.child});
  final HouseholdLockService lock;
  final PhoneLockChecker phone;
  final Widget child;

  @override
  State<HouseholdLockGate> createState() => _HouseholdLockGateState();
}

class _HouseholdLockGateState extends State<HouseholdLockGate> {
  static const _reason = 'Confirm it is you to see your household details';

  LockStep? _step; // null while working out what to show
  bool _dontAskAgain = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (_step != null) setState(() => _step = null);
    var step = await widget.lock.nextStep(await widget.phone.status());
    if (step == LockStep.checkIdentity) {
      final ok = await widget.phone.confirm(_reason);
      widget.lock.identityChecked(success: ok);
      if (ok) step = LockStep.open;
    }
    if (mounted) setState(() => _step = step);
  }

  Future<void> _answer(bool turnOn) async {
    await widget.lock.answerPermission(turnOn: turnOn, dontAskAgain: _dontAskAgain);
    if (turnOn) {
      await _refresh();
    } else if (mounted) {
      setState(() => _step = LockStep.open); // said no: show the details this time
    }
  }

  @override
  Widget build(BuildContext context) {
    return switch (_step) {
      null => const Center(child: CircularProgressIndicator()),
      LockStep.open => widget.child,
      LockStep.askPermission => _Message(
          title: 'Lock your household details?',
          body: 'Use your fingerprint or phone PIN to open this page. '
              'You only need to do this once each time you open the app.',
          extra: CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text("Don't ask me again"),
            value: _dontAskAgain,
            onChanged: (v) => setState(() => _dontAskAgain = v ?? false),
          ),
          mainLabel: 'Turn on',
          onMain: () => _answer(true),
          otherLabel: 'Not now',
          onOther: () => _answer(false),
        ),
      LockStep.checkIdentity => _Message(
          title: 'Household details are locked',
          body: 'Use your fingerprint or phone PIN to open them.',
          mainLabel: 'Unlock',
          onMain: _refresh,
        ),
      LockStep.setUpPhoneLock => _Message(
          title: 'Set up a phone lock first',
          body: 'Your phone has no screen lock yet. Open your phone Settings, '
              'then Security, then Screen lock, and add a PIN or fingerprint.',
          mainLabel: "I've set it up",
          onMain: _refresh,
          otherLabel: 'Skip for now',
          onOther: () {
            widget.lock.skipPhoneLockSetup();
            setState(() => _step = LockStep.open);
          },
        ),
    };
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.title,
    required this.body,
    required this.mainLabel,
    required this.onMain,
    this.extra,
    this.otherLabel,
    this.onOther,
  });
  final String title;
  final String body;
  final Widget? extra;
  final String mainLabel;
  final VoidCallback onMain;
  final String? otherLabel;
  final VoidCallback? onOther;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(title, style: text.headlineSmall),
        const SizedBox(height: 12),
        Text(body, style: text.bodyLarge),
        if (extra != null) ...[const SizedBox(height: 12), extra!],
        const SizedBox(height: 24),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: onMain,
          child: Text(mainLabel),
        ),
        if (otherLabel != null) ...[
          const SizedBox(height: 8),
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: onOther,
            child: Text(otherLabel!),
          ),
        ],
      ],
    );
  }
}
