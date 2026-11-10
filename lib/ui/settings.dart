import 'package:flutter/material.dart';

import '../data/store.dart';
import '../l10n/strings.dart';
import 'licenses.dart';
import 'privacy.dart';
import 'terms.dart';
import 'cloud_ai_consent.dart';
import 'source_updates.dart';
import 'onboarding.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/swatch_examples.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _demoTools = bool.fromEnvironment('AFTER_HUE_DEMO_TOOLS');
  final s = Store.instance;
  bool _resetting = false;
  late final Future<String> _judge = s.judgeName();

  Future<void> _resetForDemo() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.tr('Reset After Hue?', 'After Hueを初期化しますか？')),
        content: Text(
          context.tr(
            'This clears edits, favorites, and settings and returns to onboarding. Your photo library and system permissions stay as they are.',
            '編集内容、お気に入り、設定を消去して、はじめの案内に戻ります。写真ライブラリと端末のアクセス許可は変更されません。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.tr('Cancel', 'キャンセル')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.tr('Reset', '初期化')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _resetting) return;
    setState(() => _resetting = true);
    try {
      await s.resetForDemo();
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (_) {
      if (!mounted) return;
      setState(() => _resetting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr('Could not reset After Hue.', '初期化できませんでした。'),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    return Scaffold(
      body: ListView(
        padding: EdgeInsets.fromLTRB(20, pad.top + 4, 20, pad.bottom + 40),
        children: [
          Row(
            children: [
              Transform.translate(
                offset: const Offset(-10, 0),
                child: TextAction(
                  context.tr('Back', '戻る'),
                  color: Neutral.secondary,
                  onTap: () => Navigator.pop(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(context.tr('Settings', '設定'), style: Txt.display),
          const SizedBox(height: 28),
          _section(context.tr('Gallery', 'ギャラリー')),
          _switch(
            context.tr('Group by month', '月ごとにまとめる'),
            s.groupByMonth,
            (v) => setState(() => s.setGroupByMonth(v)),
          ),
          _switch(
            context.tr('Group similar photos', '似た写真をまとめる'),
            s.groupSimilarPhotos,
            (v) => setState(() => s.setGroupSimilarPhotos(v)),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 8),
            child: Text(
              context.tr(
                'Group similar shots taken moments apart. Originals and edits stay separate.',
                '短い間隔で撮った似た写真をまとめます。原本と編集内容はそれぞれ保持されます。',
              ),
              style: Txt.small,
            ),
          ),
          _row(
            context.tr('Swatches', '色のバッジ'),
            switch (s.swatches) {
              SwatchStyle.photo => context.tr('From the photo', '写真から'),
              SwatchStyle.soft => context.tr('Soft', 'やわらかく'),
              SwatchStyle.flat => context.tr('Flat', '単色'),
            },
            () {
              Haptics.tick();
              setState(
                () => s.setSwatches(
                  SwatchStyle.values[(s.swatches.index + 1) %
                      SwatchStyle.values.length],
                ),
              );
            },
            preview: SwatchExamples(style: s.swatches),
          ),
          const SizedBox(height: 36),
          _section(context.tr('Originals', '原本')),
          _switch(
            context.tr('Follow changes in Photos', '写真アプリの変更を反映'),
            s.followSourceChanges,
            (v) => setState(() => s.setFollowSourceChanges(v)),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 8),
            child: Text(
              context.tr(
                'Match the same colors on this device. Uncertain changes wait for review. Updates can be undone.',
                '同じ色の変化を端末内で追跡します。判断が難しい変更は確認してから反映でき、更新を元に戻すこともできます。',
              ),
              style: Txt.small,
            ),
          ),
          _row(
            context.tr('Review original updates', '原本の更新を確認'),
            '${s.items.where((it) => it.pendingSource != null).length}',
            () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SourceUpdatesScreen()),
              );
              if (mounted) setState(() {});
            },
          ),
          const SizedBox(height: 36),
          _section(context.tr('Developing', '現像')),
          if (s.cloudAiConfigured) ...[
            _switch(context.tr('Use cloud AI', 'クラウドAIを使う'), s.cloudAiConsent, (
              enabled,
            ) async {
              if (enabled) {
                await requestCloudAiConsent(context);
              } else {
                final saved = s.setCloudAiConsent(false);
                if (!saved && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        context.tr(
                          'Cloud AI is off for now, but this setting could not be saved. Please try again before closing the app.',
                          'クラウドAIは停止しましたが、設定を保存できませんでした。アプリを閉じる前にもう一度お試しください。',
                        ),
                      ),
                    ),
                  );
                }
              }
              if (mounted) setState(() {});
            }),
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 8),
              child: Text(
                context.tr(
                  'Send photos and edit instructions to Google Cloud for AI processing. You can turn this off at any time.',
                  '写真と編集の指示をGoogle Cloudへ送ってAIで処理します。いつでもオフにできます。',
                ),
                style: Txt.small,
              ),
            ),
          ],
          _switch(
            context.tr('Develop new photos automatically', '新しい写真を自動で現像'),
            s.autoDevelop,
            (v) async {
              if (v &&
                  s.cloudAiBlocked &&
                  !await requestCloudAiConsent(context)) {
                return;
              }
              if (mounted) setState(() => s.setAutoDevelop(v));
            },
          ),
          _row(
            context.tr('Photos to show', '表示する写真'),
            s.months >= 1200
                ? context.tr('All photos', 'すべての写真')
                : context.tr('Last ${s.months} months', '過去${s.months}か月'),
            () async {
              final m = await showModalBottomSheet<int>(
                context: context,
                backgroundColor: Neutral.surface,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                ),
                builder: (_) => const RangeSheet(),
              );
              if (m != null) setState(() => s.setMonths(m));
            },
          ),
          _switch(
            context.tr('Skip screenshots', 'スクリーンショットを除外'),
            s.skipScreenshots,
            (v) => setState(() => s.setSkipScreenshots(v)),
          ),
          _row(
            context.tr('Developed today', '今日の現像枚数'),
            context.tr(
              '${s.developedToday} of ${Store.dailyLimit}',
              '${s.developedToday} / ${Store.dailyLimit}',
            ),
            null,
          ),
          _row(context.tr('Model', 'モデル'), s.agent.name, null),
          FutureBuilder<String>(
            future: _judge,
            builder: (_, snap) =>
                _row(context.tr('Screening', '写真の選別'), snap.data ?? '…', null),
          ),
          const SizedBox(height: 36),
          _section(context.tr('Account', 'アカウント')),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Neutral.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Neutral.hairline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      context.tr('After Hue account', 'After Hue アカウント'),
                      style: Txt.label,
                    ),
                    const Spacer(),
                    Text(context.tr('Coming soon', '準備中'), style: Txt.mono),
                  ],
                ),
                const SizedBox(height: 14),
                for (final t in [
                  context.tr('Sync across your devices', 'デバイス間の同期'),
                  context.tr(
                    'Cloud backup of your photos and edits',
                    '写真と編集のクラウドバックアップ',
                  ),
                  context.tr('More AI edits each month', 'AI編集の利用回数を追加'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Container(
                          width: 4,
                          height: 4,
                          decoration: const BoxDecoration(
                            color: Neutral.secondary,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            t,
                            style: Txt.small.copyWith(color: Neutral.primary),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 36),
          _section(context.tr('About', 'このアプリについて')),
          _row(context.tr('Version', 'バージョン'), '0.1.0', null),
          _row(
            context.tr('Privacy', 'プライバシー'),
            context.tr('View', '確認'),
            () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PrivacyScreen()),
            ),
          ),
          _row(
            context.tr('Terms of use', '利用について'),
            context.tr('View', '確認'),
            () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TermsScreen()),
            ),
          ),
          const LicenseSettingsTile(),
          _row(
            context.tr('Photos developed', '現像した写真'),
            '${s.doneCount}',
            null,
          ),
          _row(
            context.tr('Agent log', 'エージェントの記録'),
            '${s.agentLog.length}',
            () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const _AgentLog()),
            ),
          ),
          if (_demoTools) ...[
            const SizedBox(height: 36),
            _section(context.tr('Development', '開発')),
            _row(
              context.tr('Reset for demo', 'デモ用に初期化'),
              _resetting
                  ? context.tr('Resetting…', '初期化中…')
                  : context.tr('Reset', '初期化'),
              _resetting ? null : _resetForDemo,
            ),
          ],
        ],
      ),
    );
  }

  Widget _section(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(t.toUpperCase(), style: Txt.mono.copyWith(letterSpacing: 1.2)),
  );

  Widget _switch(String label, bool v, ValueChanged<bool> on) => Container(
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: Neutral.hairline, width: 0.6)),
    ),
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: Txt.label.copyWith(fontWeight: FontWeight.w400),
          ),
        ),
        Switch.adaptive(
          value: v,
          onChanged: (x) {
            Haptics.tick();
            on(x);
          },
        ),
      ],
    ),
  );

  Widget _row(
    String label,
    String value,
    VoidCallback? onTap, {
    Widget? preview,
  }) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Neutral.hairline, width: 0.6)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: Txt.label.copyWith(fontWeight: FontWeight.w400),
                ),
              ),
              Text(value, style: Txt.small),
            ],
          ),
          if (preview != null) ...[const SizedBox(height: 10), preview],
        ],
      ),
    ),
  );
}

/// What the agent did, newest first: which photos it judged, skipped, or developed.
class _AgentLog extends StatelessWidget {
  const _AgentLog();

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    final lines = Store.instance.agentLog.reversed.toList();
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(10, pad.top + 4, 20, 8),
            child: TextAction(
              context.tr('Back', '戻る'),
              color: Neutral.secondary,
              onTap: () => Navigator.pop(context),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.fromLTRB(20, 0, 20, pad.bottom + 20),
              itemCount: lines.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  lines[i],
                  style: Txt.mono.copyWith(
                    fontSize: 11,
                    color: Neutral.primary,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
