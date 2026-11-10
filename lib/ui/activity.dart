import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../data/activity.dart';
import '../l10n/strings.dart';
import '../l10n/cloud_ai_errors.dart';
import '../data/store.dart';
import 'detail.dart';
import 'source_updates.dart';
import 'theme.dart';
import 'widgets/common.dart';

class ActivityScreen extends StatelessWidget {
  const ActivityScreen({super.key});

  String _title(BuildContext context, ActivityEntry entry) {
    if (!context.isJapanese) return entry.title;
    final action = switch (entry.kind) {
      ActivityKind.importBatch => '取り込み',
      ActivityKind.autoImport => '自動取り込み',
      ActivityKind.editRequest => 'AI編集',
      ActivityKind.developBatch => '自動現像',
      ActivityKind.sourceUpdate => '元の写真の更新',
    };
    if (!entry.complete) return '$action中…';
    if (entry.kind == ActivityKind.sourceUpdate) {
      return entry.count(ActivityOutcome.review) > 0 ? '$action · 要確認' : '$action済み';
    }
    final succeeded = entry.count(ActivityOutcome.added) + entry.count(ActivityOutcome.developed);
    final failed = entry.count(ActivityOutcome.failed);
    final cancelled = entry.count(ActivityOutcome.cancelled) + entry.count(ActivityOutcome.removed);
    if (failed > 0 || cancelled > 0) {
      if (succeeded > 0) return '$action · 一部完了';
      return failed > 0 ? '$actionに失敗' : '$actionを中止';
    }
    return succeeded == 0 ? '$actionをスキップ' : '$action完了';
  }

  String _summary(BuildContext context, ActivityEntry entry) {
    if (!entry.complete) {
      return context.tr('${entry.outcomes.length} / ${entry.keys.length} processed', '${entry.outcomes.length} / ${entry.keys.length}枚を処理済み');
    }
    final pieces = <String>[];
    for (final outcome in ActivityOutcome.values) {
      final count = entry.count(outcome);
      if (count > 0) {
        final name = context.isJapanese ? switch (outcome) {
          ActivityOutcome.added => '追加', ActivityOutcome.developed => '現像',
          ActivityOutcome.skipped => 'スキップ', ActivityOutcome.failed => '失敗',
          ActivityOutcome.removed => '削除', ActivityOutcome.cancelled => '中止',
          ActivityOutcome.updated => '更新', ActivityOutcome.review => '要確認',
        } : outcome.name;
        pieces.add(context.isJapanese ? '$name $count枚' : '$count $name');
      }
    }
    return pieces.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final store = Store.instance;
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: store,
          builder: (context, _) => CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 4, 20, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextAction(
                        context.tr('Back', '戻る'),
                        color: Neutral.secondary,
                        onTap: () => Navigator.pop(context),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(left: 10, top: 8),
                        child: Text(context.tr('Activity', 'アクティビティ'), style: Txt.display),
                      ),
                    ],
                  ),
                ),
              ),
              if (store.activity.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Text(
                      context.tr('Imports and agent edits will appear here. Open an activity to find its photos.', '取り込みやAI編集の履歴がここに表示されます。履歴を開くと対象の写真を確認できます。'),
                      style: Txt.body.copyWith(color: Neutral.secondary),
                    ),
                  ),
                )
              else
                SliverList.builder(
                  itemCount: store.activity.length,
                  itemBuilder: (context, index) {
                    final entry = store.activity[index];
                    final photos = entry.keys
                        .map(store.byKey)
                        .whereType<PhotoItem>()
                        .toList();
                    final date = entry.finished ?? entry.started;
                    final time =
                        '${date.month}/${date.day} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
                    return Semantics(
                      button: photos.isNotEmpty,
                      child: InkWell(
                        onTap: () {
                          store.readActivity(entry);
                          if (entry.kind == ActivityKind.sourceUpdate) {
                            Navigator.push(context, MaterialPageRoute(builder: (_) => SourceUpdatesScreen(keys: entry.keys)));
                            return;
                          }
                          if (photos.isNotEmpty) {
                            Navigator.push(
                              context,
                              DetailRoute(
                                items: photos,
                                index: 0,
                                developmentBatch: !entry.complete,
                              ),
                            );
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  ActivityThumbnail(photos: photos),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            if (!entry.complete) ...[
                                              const CupertinoActivityIndicator(
                                                radius: 7,
                                              ),
                                              const SizedBox(width: 10),
                                            ] else if (!entry.read) ...[
                                              Container(
                                                width: 6,
                                                height: 6,
                                                decoration: const BoxDecoration(
                                                  shape: BoxShape.circle,
                                                  color: Neutral.primary,
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                            ],
                                            Expanded(
                                              child: Text(
                                                _title(context, entry),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: Txt.label,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          _summary(context, entry),
                                          style: Txt.body.copyWith(
                                            fontSize: 14,
                                          ),
                                        ),
                                        if (cloudAiErrorText(context, entry.failureReason?.message) case final error?)
                                          Padding(
                                            padding: const EdgeInsets.only(top: 6),
                                            child: Text(error, style: Txt.small),
                                          ),
                                        if (entry.request?.isNotEmpty == true)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              top: 6,
                                            ),
                                            child: Text(
                                              entry.request!,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: Txt.small,
                                            ),
                                          ),
                                        const SizedBox(height: 6),
                                        Text(
                                          time,
                                          style: Txt.small.copyWith(
                                            fontSize: 11,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                photos.isEmpty
                                                    ? context.tr('Photos are no longer in After Hue', '写真はAfter Hueにありません')
                                                    : context.tr('View ${photos.length} ${photos.length == 1 ? 'photo' : 'photos'}', '${photos.length}枚の写真を見る'),
                                                style: Txt.small,
                                              ),
                                            ),
                                            if (photos.isNotEmpty)
                                              const RotatedBox(
                                                quarterTurns: 2,
                                                child: Glyph(
                                                  G.back,
                                                  size: 14,
                                                  color: Neutral.secondary,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 18),
                              const Hairline(),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 32)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A single photo, or a compact contact sheet for one operation.
class ActivityThumbnail extends StatelessWidget {
  const ActivityThumbnail({super.key, required this.photos});
  final List<PhotoItem> photos;

  Widget _photo(PhotoItem item, {bool obscured = false}) {
    final original = OriginalImage(item, size: 240);
    Widget image = item.edit != null && item.hues.isNotEmpty
        ? DevelopedImage(item, size: 240, placeholder: original)
        : original;
    if (obscured) {
      image = ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: image,
      );
    }
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          image,
          if (obscured) ...[
            const ColoredBox(color: Color(0x30000000)),
            Center(
              child: Text(
                '+${photos.length - 3}',
                maxLines: 1,
                style: Txt.label.copyWith(
                  fontSize: 14,
                  color: Colors.white,
                  shadows: const [
                    Shadow(color: Color(0x40000000), blurRadius: 4),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget content;
    if (photos.isEmpty) {
      content = const Center(
        child: Glyph(G.grid, color: Neutral.secondary, size: 24),
      );
    } else if (photos.length == 1) {
      content = _photo(photos.first);
    } else {
      content = Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(child: _photo(photos[0])),
                const SizedBox(width: 2),
                Expanded(child: _photo(photos[1])),
              ],
            ),
          ),
          if (photos.length > 2) ...[
            const SizedBox(height: 2),
            Expanded(
              child: Row(
                children: [
                  Expanded(child: _photo(photos[2])),
                  const SizedBox(width: 2),
                  Expanded(
                    child: photos.length < 4
                        ? const SizedBox()
                        : _photo(photos[3], obscured: photos.length > 4),
                  ),
                ],
              ),
            ),
          ],
        ],
      );
    }
    return Semantics(
      label: context.tr('${photos.length} ${photos.length == 1 ? 'photo' : 'photos'} in this activity', 'この履歴の写真 ${photos.length}枚'),
      image: true,
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: 80,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: ColoredBox(color: const Color(0x08000000), child: content),
        ),
      ),
    );
  }
}
