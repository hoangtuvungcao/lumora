// A newly linked device copies older messages from the account's other
// device. This screen shows the progress (also after an app restart while the
// copy is still running) and lets the user continue right away.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/devices_store.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/secure_input.dart';
import 'device_ui.dart';

class HistorySyncScreen extends StatelessWidget {
  const HistorySyncScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final h = context.select<DevicesStore, HistoryStatus>((d) => d.history);
    final store = context.read<DevicesStore>();
    final done = h.done && !h.active;
    final count = h.messages;
    final fraction = done ? 1.0 : h.fraction;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      body: SecureFrame(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SecureHero(
            icon: done ? AppIcons.checkCircle : AppIcons.history,
            tone: done ? LC.success : LC.primary,
            title: s(done ? 'dv_hist_done_title' : 'dv_hist_title'),
            subtitle: done ? s('dv_hist_done_sub') : null,
            compact: true,
          ),
          const SizedBox(height: 22),
          Container(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
            decoration: BoxDecoration(
              color: dark ? const Color(0xFF1B1F3A) : const Color(0xFFF4F5FB),
              borderRadius: BorderRadius.circular(Radii.lg),
              border: Border.all(color: dark ? const Color(0xFF2A2F55) : context.lc.divider),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TweenAnimationBuilder<double>(
                tween: Tween(end: count.toDouble()),
                duration: const Duration(milliseconds: 600),
                builder: (context, v, _) => Text(
                  s('dv_hist_count', {'n': _thousands(v.round(), s.vi)}),
                  textAlign: TextAlign.center,
                  style: context.tt.headlineSmall?.copyWith(fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ),
              if (h.convsTotal > 0) ...[
                const SizedBox(height: 4),
                Text(
                  s('dv_hist_convs', {'done': h.convsDone.clamp(0, h.convsTotal), 'total': h.convsTotal}),
                  textAlign: TextAlign.center,
                  style: context.tt.bodySmall?.copyWith(fontSize: 13),
                ),
              ],
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: fraction ?? 0),
                  duration: const Duration(milliseconds: 500),
                  builder: (context, v, _) => LinearProgressIndicator(
                    value: fraction == null ? null : v,
                    minHeight: 8,
                    backgroundColor: dark ? const Color(0xFF2A2F55) : const Color(0xFFE3E5F2),
                    color: done ? LC.success : null,
                  ),
                ),
              ),
              if (h.sinceMs > 0) ...[
                const SizedBox(height: 12),
                Text(s('dv_hist_since', {'date': deviceDate(s, h.sinceMs)}), textAlign: TextAlign.center, style: context.tt.bodySmall?.copyWith(fontSize: 12.5)),
              ],
            ]),
          ),
          if (!done) ...[
            const SizedBox(height: 18),
            SecureNote(s('dv_hist_sub'), icon: AppIcons.info),
          ],
          const SizedBox(height: 24),
          SecurePrimaryButton(
            label: s(done ? 'dv_hist_start' : 'dv_hist_use_now'),
            icon: AppIcons.next,
            onPressed: store.dismissHistory,
          ),
        ]),
      ),
    );
  }
}

/// 12345 → "12.345" (vi) / "12,345" (en).
String _thousands(int n, bool vi) {
  final t = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < t.length; i++) {
    if (i > 0 && (t.length - i) % 3 == 0) b.write(vi ? '.' : ',');
    b.write(t[i]);
  }
  return b.toString();
}

