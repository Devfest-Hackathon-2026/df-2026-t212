import 'package:flutter/material.dart';

import '../data/store.dart';
import 'onboarding.dart';
import 'theme.dart';
import 'widgets/common.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final s = Store.instance;
  bool _auto = true, _wifi = false, _screens = true;

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    return Scaffold(
      body: ListView(
        padding: EdgeInsets.fromLTRB(20, pad.top + 4, 20, pad.bottom + 40),
        children: [
          Row(children: [
            Transform.translate(offset: const Offset(-10, 0), child: TextAction('Back', color: Neutral.secondary, onTap: () => Navigator.pop(context))),
          ]),
          const SizedBox(height: 4),
          Text('Settings', style: Txt.display),
          const SizedBox(height: 28),
          _section('Developing'),
          _switch('Import new photos automatically', _auto, (v) => setState(() => _auto = v)),
          _row('Photos to develop', s.months >= 1200 ? 'All photos' : 'Last ${s.months} months', () async {
            final m = await showModalBottomSheet<int>(
              context: context,
              backgroundColor: Neutral.surface,
              shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
              builder: (_) => const RangeSheet(),
            );
            if (m != null) setState(() => s.setMonths(m));
          }),
          _switch('Develop on Wi-Fi only', _wifi, (v) => setState(() => _wifi = v)),
          _switch('Skip screenshots', _screens, (v) => setState(() => _screens = v)),
          _row('Model', s.agent.name, null),
          const SizedBox(height: 36),
          _section('Account'),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(color: Neutral.surface, borderRadius: BorderRadius.circular(18), border: Border.all(color: Neutral.hairline)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text('After Hue account', style: Txt.label),
                const Spacer(),
                Text('Coming soon', style: Txt.mono),
              ]),
              const SizedBox(height: 14),
              for (final t in const ['Sync across your devices', 'Cloud backup of your photos and edits', 'More AI edits each month'])
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(children: [
                    Container(width: 4, height: 4, decoration: const BoxDecoration(color: Neutral.secondary, shape: BoxShape.circle)),
                    const SizedBox(width: 10),
                    Text(t, style: Txt.small.copyWith(color: Neutral.primary)),
                  ]),
                ),
            ]),
          ),
          const SizedBox(height: 36),
          _section('About'),
          _row('Version', '0.1.0', null),
          _row('Photos developed', '${s.doneCount}', null),
        ],
      ),
    );
  }

  Widget _section(String t) => Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(t.toUpperCase(), style: Txt.mono.copyWith(letterSpacing: 1.2)));

  Widget _switch(String label, bool v, ValueChanged<bool> on) => Container(
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Neutral.hairline, width: 0.6))),
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Expanded(child: Text(label, style: Txt.label.copyWith(fontWeight: FontWeight.w400))),
          Switch.adaptive(value: v, onChanged: (x) {
            Haptics.tick();
            on(x);
          }),
        ]),
      );

  Widget _row(String label, String value, VoidCallback? onTap) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Neutral.hairline, width: 0.6))),
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(children: [
            Expanded(child: Text(label, style: Txt.label.copyWith(fontWeight: FontWeight.w400))),
            Text(value, style: Txt.small),
          ]),
        ),
      );
}
