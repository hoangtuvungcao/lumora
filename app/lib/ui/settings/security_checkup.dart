// Settings › Security: "Security checkup" card (passphrase, recovery
// phrase, app lock, verified friends) and the passphrase / recovery phrase
// dialogs its buttons open.

import 'package:flutter/material.dart';
import '../widgets/sensitive_gate.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/app_lock.dart';
import '../../state/settings.dart';
import '../../state/stores.dart';
import '../friends/safety_number.dart';
import '../lock/app_lock_screen.dart' show askNewPin;
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/peer_avatar.dart';
import '../widgets/secure_input.dart';
import '../widgets/recovery_phrase.dart';
import '../../state/password_policy.dart';

/// Whether local data is protected by a passphrase (core's answer first).
bool hasPassphrase(BuildContext context) {
  final p = context.select<SessionStore, String>((x) => x.me?.protection ?? '');
  final local = context.select<Settings, bool>((x) => x.hasPassphrase);
  return p.isNotEmpty ? p == 'passphrase' : local;
}

class SecurityCheckupCard extends StatelessWidget {
  const SecurityCheckupCard({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final pass = hasPassphrase(context);
    final phrase = context.select<Settings, bool>((x) => x.phraseBackedUp);
    final lock = context.select<Settings, bool>((x) => x.appLock);
    final unverified = context.select<ContactsStore, int>((c) => c.friends.where((f) => !f.verified && !f.isBot).length);
    final items = [
      _Item(
        ok: pass,
        icon: AppIcons.password,
        title: pass ? s('sc_pass_ok') : s('sc_pass_no'),
        hint: s('sc_pass_hint'),
        action: s('sc_pass_action'),
        onAction: () => showPassphraseDialog(context),
      ),
      _Item(
        ok: phrase,
        icon: AppIcons.recoveryPhrase,
        title: phrase ? s('sc_phrase_ok') : s('sc_phrase_no'),
        hint: s('sc_phrase_hint'),
        action: s('sc_phrase_action'),
        onAction: () => showRecoveryPhraseDialog(context),
      ),
      _Item(
        ok: lock,
        icon: AppIcons.lockKey,
        title: lock ? s('sc_lock_ok') : s('sc_lock_no'),
        hint: s('sc_lock_hint'),
        action: s('sc_lock_action'),
        onAction: () async {
          final pin = await askNewPin(context);
          if (pin == null || !context.mounted) return;
          try {
            await context.read<AppLock>().setPin(pin);
          } catch (e) {
            if (context.mounted) toastError(context, e, fallbackKey: 'pin_save_failed');
            return;
          }
          if (context.mounted) toast(context, s('app_lock_on'));
        },
      ),
      _Item(
        ok: unverified == 0,
        icon: AppIcons.verified,
        title: unverified == 0 ? s('sc_verify_ok') : s('sc_verify_no', {'n': unverified}),
        hint: s('sc_verify_hint'),
        action: s('sc_verify_action'),
        onAction: () => showUnverifiedFriends(context),
      ),
    ];
    final done = items.where((i) => i.ok).length;
    final left = items.length - done;
    final color = left == 0 ? LC.success : (done >= 2 ? LC.warning : LC.danger);
    return LCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          SizedBox(
            width: 52,
            height: 52,
            child: Stack(alignment: Alignment.center, children: [
              SizedBox.expand(
                child: CircularProgressIndicator(
                  value: done / items.length,
                  strokeWidth: 5,
                  strokeCap: StrokeCap.round,
                  color: color,
                  backgroundColor: context.lc.surface2,
                ),
              ),
              Icon(left == 0 ? AppIcons.shieldCheck : AppIcons.shield, color: color, size: 22),
            ]),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s('sc_title'), style: context.tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(
                '${s('sc_score', {'n': done, 't': items.length})} · ${left == 0 ? s('sc_all_good') : s('sc_left', {'n': left})}',
                style: context.tt.bodySmall?.copyWith(color: left == 0 ? LC.success : null),
              ),
            ]),
          ),
        ]),
        const SizedBox(height: 10),
        for (final (i, it) in items.indexed) ...[
          if (i > 0) Divider(height: 1, indent: 46, color: context.lc.divider),
          it,
        ],
      ]),
    );
  }
}

class _Item extends StatelessWidget {
  const _Item({required this.ok, required this.icon, required this.title, required this.hint, required this.action, required this.onAction});
  final bool ok;
  final IconData icon;
  final String title, hint, action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final c = ok ? LC.success : LC.warning;
    final button = TextButton(
      style: TextButton.styleFrom(
        foregroundColor: LC.primary,
        backgroundColor: LC.primary.withValues(alpha: 0.13),
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.sm)),
      ),
      onPressed: onAction,
      child: Text(action, style: const TextStyle(fontWeight: FontWeight.w600)),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: LayoutBuilder(builder: (context, box) {
        // Phones: the button sits under the text instead of squeezing it.
        final narrow = box.maxWidth < 460;
        final text = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(hint, style: context.tt.bodySmall),
          if (!ok && narrow) ...[const SizedBox(height: 8), button],
        ]);
        return Row(crossAxisAlignment: narrow ? CrossAxisAlignment.start : CrossAxisAlignment.center, children: [
          IconTile(ok ? AppIcons.check : icon, color: c, size: IconTileSize.sm, circle: true),
          const SizedBox(width: 14),
          Expanded(child: text),
          if (!ok && !narrow) ...[const SizedBox(width: 10), button],
        ]);
      }),
    );
  }
}

/// Shows the recovery phrase, then "Check your copy" (3 words by position).
/// Only a passed check marks it as backed up.
Future<void> showRecoveryPhraseDialog(BuildContext context) async {
  final s = S.read(context);
  if (isRemoteHosting(context.read<RemoteStore>())) {
    await showBlockedWhileControlled(context);
    return;
  }
  final ok = await confirm(context, title: s('recovery_phrase'), body: s('show_phrase_warning'), action: s('show'));
  if (!ok || !context.mounted) return;
  // The phrase is the whole account: the owner proves it's them first.
  if (!await confirmOwner(context, title: s('recovery_phrase')) || !context.mounted) return;
  final String phrase;
  try {
    phrase = await context.read<LumoraApi>().recoveryPhrase();
  } catch (e) {
    if (context.mounted) toastError(context, e);
    return;
  }
  if (!context.mounted) return;
  final settings = context.read<Settings>();
  final checked = await showSecureDialog<bool>(context, builder: (_) => SensitiveScreen(child: RecoveryPhraseDialog(phrase: phrase)));
  if (checked == true) settings.update((x) => x.phraseBackedUp = true);
}

/// Set, change or remove the passphrase that locks this device's data.
Future<void> showPassphraseDialog(BuildContext context) => showSecureDialog<void>(context, builder: (_) => const _PassphraseDialog());

class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog();
  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final _old = TextEditingController();
  final _new = TextEditingController();
  final _new2 = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _old.dispose();
    _new.dispose();
    _new2.dispose();
    super.dispose();
  }

  Future<void> _apply({required bool remove}) async {
    final s = S.read(context);
    final has = _hasPass();
    final weak = remove ? null : passwordProblem(_new.text);
    if (!remove && (weak != null || _new.text != _new2.text)) {
      setState(() => _error = weak != null ? s(weak) : s('pass_mismatch'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = context.read<LumoraApi>();
    final settings = context.read<Settings>();
    final session = context.read<SessionStore>();
    try {
      await api.changePassphrase(has ? _old.text : '', remove ? '' : _new.text);
      settings.update((x) => x.hasPassphrase = !remove);
      await session.reloadMe().catchError((_) {});
      if (!mounted) return;
      Navigator.pop(context);
      toast(context, remove ? s('pp_removed') : s('pp_saved'));
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(S.read(context), e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _hasPass() {
    final p = context.read<SessionStore>().me?.protection ?? '';
    return p.isNotEmpty ? p == 'passphrase' : context.read<Settings>().hasPassphrase;
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final has = _hasPass();
    void close() => Navigator.pop(context);
    return SecureDialogFrame(
      trailing: SecureNavButton.close(context, close),
      onEscape: _busy ? () {} : close,
      child: AutofillGroup(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SecureHero(icon: AppIcons.lock, title: has ? s('change_passphrase') : s('set_passphrase'), subtitle: s('sec_pp_sub'), compact: true),
          const SizedBox(height: 24),
          if (has) ...[
            PasswordField(controller: _old, label: s('pp_current'), icon: AppIcons.key, autofocus: true),
            const SizedBox(height: 16),
          ],
          PasswordField(
            controller: _new,
            label: has ? s('pp_new') : s('passphrase'),
            autofocus: !has,
            newPassword: true,
            showStrength: true,
            minLength: kMinPasswordLength,
            onChanged: (_) => _error != null ? setState(() => _error = null) : null,
          ),
          const SizedBox(height: 16),
          PasswordField(
            controller: _new2,
            label: s('passphrase_repeat'),
            newPassword: true,
            matchWith: _new,
            onChanged: (_) => _error != null ? setState(() => _error = null) : null,
            onSubmitted: (_) => _busy ? null : _apply(remove: false),
          ),
          const SizedBox(height: 16),
          SecureNote(s('sec_pp_note'), icon: AppIcons.recoveryPhrase),
          if (_error != null) ...[const SizedBox(height: 12), SecureMessage(_error!)],
          const SizedBox(height: 24),
          SecurePrimaryButton(label: s('sec_pp_save'), icon: AppIcons.lockKey, busy: _busy, onPressed: _busy ? null : () => _apply(remove: false)),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (has)
              TextButton(
                style: TextButton.styleFrom(foregroundColor: LC.danger),
                onPressed: _busy ? null : () => _apply(remove: true),
                child: Text(s('pp_remove')),
              ),
            TextButton(onPressed: _busy ? null : close, child: Text(s('cancel'))),
          ]),
        ]),
      ),
    );
  }
}

/// Friends whose safety number hasn't been compared yet.
Future<void> showUnverifiedFriends(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (c) {
      final s = S.of(c);
      final list = c.select<ContactsStore, List<Contact>>((x) => x.friends.where((f) => !f.verified && !f.isBot).toList());
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.7),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(s('sc_unverified_title'), style: c.tt.titleMedium),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(s('sc_unverified_hint'), style: c.tt.bodySmall),
            ),
            if (list.isEmpty)
              Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(s('sc_verify_ok'), style: c.tt.bodyMedium?.copyWith(color: LC.success))))
            else
              Flexible(
                child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(8, 0, 8, 12), children: [
                  for (final f in list)
                    ListTile(
                      leading: PeerAvatar(peer: f.peer, fallbackName: f.displayName, size: 40),
                      title: Text(f.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('ID ${f.shortId}', style: c.tt.bodySmall),
                      trailing: const Icon(AppIcons.chevronRight, size: 18),
                      onTap: () => openSafetyNumber(c, f),
                    ),
                ]),
              ),
          ]),
        ),
      );
    },
  );
}
