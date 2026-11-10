import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../data/store.dart';
import '../../l10n/strings.dart';
import '../theme.dart';
import '../cloud_ai_consent.dart';
import 'common.dart';

/// A continuation of the person's batch, beside the other photo actions.
class DevelopmentBar extends StatelessWidget {
  const DevelopmentBar({super.key, this.scope, this.onReview});
  final List<PhotoItem>? scope;
  final ValueChanged<List<PhotoItem>>? onReview;

  @override
  Widget build(BuildContext context) {
    final store = Store.instance;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final items = (scope ?? store.items).where((it) => store.byKey(it.key) == it && it.shown);
        final remaining = items.where((it) => it.isUndeveloped).toList();
        final busy = store.cloudAiBlocked ? 0 : items.where((it) => it.picked && it.asked &&
            (it.state == Develop.pending || it.state == Develop.developing)).length;
        final progress = store.developmentProgress(scope);
        final automatic = !store.cloudAiBlocked && scope == null ? store.items.where((it) => !it.picked &&
          (it.state == Develop.pending || it.state == Develop.developing)).length : 0;
        final autoProgress = store.automaticProgress();
        final autoLabel = autoProgress.active > 0
            ? context.tr('Auto · ${autoProgress.done} / ${autoProgress.total} processed', '自動 · ${autoProgress.done} / ${autoProgress.total}枚処理済み')
            : context.tr('Auto · $automatic queued', '自動 · $automatic枚待機中');
        return AnimatedSize(
          duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 220),
          curve: Motion.settle,
          alignment: Alignment.bottomCenter,
          child: remaining.isEmpty && busy == 0 && automatic == 0 ? const SizedBox.shrink() : Glass(
            dock: true,
            radius: 24,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(children: [
              Expanded(
                child: Semantics(
                  button: onReview != null && remaining.isNotEmpty,
                  label: onReview != null && remaining.isNotEmpty ? context.tr('Review ${remaining.length} undeveloped photos', '未現像${remaining.length}枚を確認') : null,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onReview == null || remaining.isEmpty ? null : () => onReview!(remaining),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                      child: Row(children: [
                        if (busy > 0 || (!store.cloudAiBlocked && autoProgress.active > 0)) ...[
                          const CupertinoActivityIndicator(radius: 6, color: Colors.black),
                          const SizedBox(width: 8),
                        ],
                        Flexible(child: Text(
                          busy > 0 ? context.tr('${progress.done} / ${progress.total} developed', '${progress.done} / ${progress.total}枚を現像済み') : automatic > 0 ? autoLabel : context.tr('${remaining.length} undeveloped', '未現像 ${remaining.length}枚'),
                          style: Txt.small.copyWith(color: Neutral.secondary),
                        )),
                        if (onReview != null && remaining.isNotEmpty) ...[
                          const SizedBox(width: 5),
                          const RotatedBox(quarterTurns: 2, child: Glyph(G.back, size: 12, color: Neutral.secondary, weight: 1.2)),
                        ],
                      ]),
                    ),
                  ),
                ),
              ),
              if (remaining.isNotEmpty)
                TextAction(scope == null ? context.tr('Auto all', 'すべて自動現像') : context.tr('Auto remaining', '残りを自動現像'), onTap: () async {
                  if (store.cloudAiBlocked && !await requestCloudAiConsent(context)) return;
                  if (!context.mounted) return;
                  Haptics.light();
                  store.autoDevelopUndeveloped(remaining);
                }),
            ]),
          ),
        );
      },
    );
  }
}
