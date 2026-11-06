import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';

import '../../l10n/strings.dart';
import '../flows.dart';
import '../friends/add_friend.dart';
import '../theme.dart';

/// First-run guided tour (3 steps), each with a clear call to action.
Future<void> showWelcomeTour(BuildContext context) {
  return showDialog<void>(context: context, builder: (_) => const Dialog(child: SizedBox(width: 460, child: _Tour())));
}

class _Tour extends StatefulWidget {
  const _Tour();
  @override
  State<_Tour> createState() => _TourState();
}

class _TourState extends State<_Tour> {
  int _i = 0;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final steps = [
      (AppIcons.addFriend, s('tour1_title'), s('tour1_body'), s('add_friend'), () => showAddFriend(context)),
      (AppIcons.direct, s('tour2_title'), s('tour2_body'), s('create_new'), () => Flows.showCreateMenu(context)),
      (AppIcons.search, s('tour3_title'), s('tour3_body'), null, null),
    ];
    final st = steps[_i];
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AnimatedSwitcher(
          duration: Motion.normal,
          child: Column(key: ValueKey(_i), children: [
            IconTile(st.$1, size: IconTileSize.lg),
            const SizedBox(height: 18),
            Text(st.$2, textAlign: TextAlign.center, style: context.tt.titleLarge),
            const SizedBox(height: 8),
            Text(st.$3, textAlign: TextAlign.center, style: context.tt.bodyMedium?.copyWith(color: context.lc.muted, height: 1.5)),
          ]),
        ),
        const SizedBox(height: 20),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          for (var k = 0; k < steps.length; k++)
            AnimatedContainer(
              duration: Motion.normal,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: k == _i ? 24 : 8,
              height: 8,
              decoration: BoxDecoration(color: k == _i ? LC.primary : context.lc.surface2, borderRadius: BorderRadius.circular(4)),
            ),
        ]),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: () => _i < steps.length - 1 ? setState(() => _i++) : Navigator.pop(context),
          child: Text(_i < steps.length - 1 ? s('next') : s('start_using')),
        ),
        const SizedBox(height: 4),
        Row(children: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(s('skip'))),
          const Spacer(),
          if (st.$4 != null)
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                st.$5!();
              },
              child: Text(st.$4!),
            ),
        ]),
      ]),
    );
  }
}
