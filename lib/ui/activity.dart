import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../data/activity.dart';
import '../data/store.dart';
import 'detail.dart';
import 'theme.dart';
import 'widgets/common.dart';

class ActivityScreen extends StatelessWidget {
  const ActivityScreen({super.key});

  String _summary(ActivityEntry entry) {
    if (!entry.complete) {
      return '${entry.outcomes.length} / ${entry.keys.length} processed';
    }
    final pieces = <String>[];
    for (final outcome in ActivityOutcome.values) {
      final count = entry.count(outcome);
      if (count > 0) pieces.add('$count ${outcome.name}');
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
                        'Back',
                        color: Neutral.secondary,
                        onTap: () => Navigator.pop(context),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(left: 10, top: 8),
                        child: Text('Activity', style: Txt.display),
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
                      'Imports and agent edits will appear here. Open an activity to find its photos.',
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
                                                entry.title,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: Txt.label,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          _summary(entry),
                                          style: Txt.body.copyWith(
                                            fontSize: 14,
                                          ),
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
                                                    ? 'Photos are no longer in After Hue'
                                                    : 'View ${photos.length} ${photos.length == 1 ? 'photo' : 'photos'}',
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
      label: '${photos.length} ${photos.length == 1 ? 'photo' : 'photos'} in this activity',
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
