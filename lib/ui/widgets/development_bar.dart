import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../data/store.dart';
import '../theme.dart';
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
        final busy = items.where((it) => it.picked && it.asked &&
            (it.state == Develop.pending || it.state == Develop.developing)).length;
        final progress = store.developmentProgress(scope);
        final automatic = scope == null ? store.items.where((it) => !it.picked &&
          (it.state == Develop.pending || it.state == Develop.developing)).length : 0;
        final autoProgress = store.automaticProgress();
        final autoLabel = autoProgress.active > 0
            ? 'Auto · ${autoProgress.done} / ${autoProgress.total} processed'
            : 'Auto · $automatic queued';
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
                  label: onReview != null && remaining.isNotEmpty ? 'Review ${remaining.length} undeveloped photos' : null,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onReview == null || remaining.isEmpty ? null : () => onReview!(remaining),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                      child: Row(children: [
                        if (busy > 0 || autoProgress.active > 0) ...[
                          const CupertinoActivityIndicator(radius: 6, color: Colors.black),
                          const SizedBox(width: 8),
                        ],
                        Flexible(child: Text(
                          busy > 0 ? '${progress.done} / ${progress.total} developed' : automatic > 0 ? autoLabel : '${remaining.length} undeveloped',
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
                TextAction(scope == null ? 'Auto all' : 'Auto remaining', onTap: () {
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
