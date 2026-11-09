import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../agent/agent.dart';
import '../../core/recipe.dart';
import '../theme.dart';

String agentWorkLabel(String? status) => switch (status) {
  'probe' || 'hue_histogram' => 'looking',
  'add_color' || 'remove_color' => 'choosing colors',
  'exclude_color' ||
  'set_excluded_color' ||
  'remove_excluded_color' => 'refining excluded colors',
  'set_width' || 'set_softness' || 'set_gate' => 'adjusting reach',
  'set_area' => 'limiting the area',
  'select_subject' => 'selecting the subject',
  'adjust_area' => 'adjusting the boundary',
  'set_mono_tone' => 'setting tone',
  'render' => 'checking',
  'finish' => 'finishing',
  _ => 'looking',
};

/// Follows the run itself, so tool progress remains visible outside Edit.
class AgentWorkStatus extends StatelessWidget {
  const AgentWorkStatus({super.key, required this.run, this.compact = false});
  final AgentRun run;
  final bool compact;

  @override
  Widget build(BuildContext context) => StreamBuilder<Recipe>(
    stream: run.changes,
    builder: (context, _) {
      final label = 'Agent is ${agentWorkLabel(run.status)}…';
      return Semantics(
        label: label,
        excludeSemantics: true,
        child: LayoutBuilder(
          builder: (context, size) {
            final text = compact
                ? (size.maxWidth < 88 ? 'Agent' : 'Agent editing')
                : label;
            final color = compact ? Colors.white : Neutral.primary;
            final row = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CupertinoActivityIndicator(
                  radius: compact ? 5 : 6,
                  color: color,
                  animating: !MediaQuery.disableAnimationsOf(context),
                ),
                SizedBox(width: compact ? 5 : 8),
                Flexible(
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        (compact ? Txt.mono.copyWith(fontSize: 9) : Txt.small)
                            .copyWith(color: color),
                  ),
                ),
              ],
            );
            if (!compact) return row;
            return DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xB31C1C1C),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
                child: row,
              ),
            );
          },
        ),
      );
    },
  );
}
