import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../core/bip39.dart';
import '../../l10n/strings.dart';
import '../../state/app_lock.dart';
import '../../state/settings.dart';
import '../../state/stores.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/logo.dart';
import '../widgets/secure_input.dart';

export '../widgets/secure_input.dart' show PinPad;

/// Covers the whole app (above calls and remote screens) while the app lock
/// is engaged.
class AppLockLayer extends StatelessWidget {
  const AppLockLayer({super.key});

  @override
  Widget build(BuildContext context) {
    final locked = context.select<AppLock, bool>((l) => l.locked && l.enabled);
    final obscured = context.select<AppLock, bool>((l) => l.obscured && l.enabled);
    final ready = context.select<SessionStore, bool>((s) => s.phase == SessionPhase.ready);
    if (!ready) return const SizedBox.shrink();
    if (locked) return const Positioned.fill(child: LayerHost(key: ValueKey('app-lock'), child: PinLockScreen()));
    // In the app switcher (mobile): a plain cover, so the preview shows no chats.
    if (obscured) return Positioned.fill(child: ColoredBox(color: context.lc.bg, child: const Center(child: LumoraLogo(size: 72))));
    return const SizedBox.shrink();
  }
}

/// Wraps everything under the lock screen: while it shows, nothing below can
/// hold keyboard focus (so no shortcut, text field or remote-desktop viewer
/// receives keys) and nothing is exposed to screen readers.
class LockShield extends StatelessWidget {
  const LockShield({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final locked = context.select<AppLock, bool>((l) => l.locked && l.enabled);
    final ready = context.select<SessionStore, bool>((s) => s.phase == SessionPhase.ready);
    final on = locked && ready;
    return ExcludeFocus(excluding: on, child: ExcludeSemantics(excluding: on, child: child));
  }
}

String _mmss(int sec) => '${sec ~/ 60}:${(sec % 60).toString().padLeft(2, '0')}';

/// Lock screen: logo, PIN dots and a keypad (the physical keyboard works too).
class PinLockScreen extends StatefulWidget {
  const PinLockScreen({super.key});
  @override
  State<PinLockScreen> createState() => _PinLockScreenState();
}

class _PinLockScreenState extends State<PinLockScreen> {
  bool _wrong = false;

  @override
  void initState() {
    super.initState();
    context.read<AppLock>().resumeCountdown();
    // Close the on-screen keyboard of whatever was being typed underneath.
    FocusManager.instance.primaryFocus?.unfocus();
  }

  Future<bool> _submit(String pin) async {
    final ok = await context.read<AppLock>().tryUnlock(pin);
    if (mounted) setState(() => _wrong = !ok);
    return ok;
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final lock = context.watch<AppLock>();
    final length = context.select<Settings, int>((x) => x.pinLength);
    final incoming = context.select<CallStore, bool>((c) => c.call?.phase == CallPhase.incoming);
    // Someone controls this device: stopping them never needs the PIN.
    final hostSession = context.select<RemoteStore, String?>((r) => r.host?.session);
    final wait = lock.waitSeconds;
    final exhausted = lock.exhausted;
    context.select<Settings, int>((x) => x.pinFails); // wait length follows the count
    final String? status;
    final SecureTone tone;
    if (lock.verifying) {
      status = s('pin_checking');
      tone = SecureTone.info;
    } else if (exhausted) {
      status = s('pin_exhausted');
      tone = SecureTone.error;
    } else if (wait > 0) {
      status = s('pin_wait_phrase', {'t': _mmss(wait)});
      tone = SecureTone.warning;
    } else if (_wrong) {
      status = s('pin_wrong_again');
      tone = SecureTone.error;
    } else {
      status = null;
      tone = SecureTone.error;
    }
    final desktop = isDesktop(context);
    // Short phones: compact header so "Forgot PIN?" stays on screen.
    final short = MediaQuery.sizeOf(context).height < 700;
    return Material(
      color: context.lc.bg,
      child: SecureFrame(
        cardPadding: const EdgeInsets.fromLTRB(32, 32, 32, 20),
        footer: desktop
            ? Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(AppIcons.keyboard, size: 16, color: context.lc.muted),
                const SizedBox(width: 8),
                Text(s('sec_pin_keyboard'), style: context.tt.bodySmall),
              ])
            : null,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SecureHero(
            title: s('pin_enter'),
            subtitle: s('pin_locked_sub'),
            compact: desktop || short,
            below: incoming ? Pill(s('pin_incoming_call'), color: LC.success, icon: AppIcons.callIncoming) : null,
          ),
          SizedBox(height: desktop || short ? 16 : 28),
          // While someone watches this screen remotely, key presses
          // leave no visible trace (a lit key would give the PIN away).
          PinPad(
            length: length,
            enabled: wait == 0 && !exhausted,
            captureKeyboard: true,
            hideTaps: hostSession != null,
            onSubmit: _submit,
            onChanged: () => _wrong ? setState(() => _wrong = false) : null,
            message: status,
            messageTone: tone,
            lockoutSeconds: exhausted || lock.verifying ? 0 : wait,
            lockoutTotal: lock.currentWaitSec,
          ),
          _CheckingBar(on: lock.verifying),
          SizedBox(height: desktop || short ? 8 : 20),
          Center(child: TextButton(onPressed: () => showForgotPin(context), child: Text(s('pin_forgot')))),
          if (hostSession != null) ...[
            const SizedBox(height: 4),
            Center(
              child: TextButton.icon(
                onPressed: () => context.read<RemoteStore>().end(hostSession),
                style: TextButton.styleFrom(foregroundColor: LC.danger),
                icon: const Icon(AppIcons.stop, size: 16),
                label: Text(s('pin_stop_remote')),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------ forgot PIN

Future<void> showForgotPin(BuildContext context) =>
    showSecureDialog<void>(context, builder: (_) => const _ForgotPinDialog());

class _ForgotPinDialog extends StatefulWidget {
  const _ForgotPinDialog();
  @override
  State<_ForgotPinDialog> createState() => _ForgotPinDialogState();
}

class _ForgotPinDialogState extends State<_ForgotPinDialog> {
  final _ctl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final s = S.read(context);
    final typed = AppLock.normalizePhrase(_ctl.text);
    if (typed.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final lock = context.read<AppLock>();
    final api = context.read<LumoraApi>();
    try {
      // The core checks the phrase against the account (also on a linked
      // device, which never holds the phrase itself). Older core: compare
      // with the phrase of the main device.
      var same = await api.phraseCheck(_ctl.text);
      if (same == null) {
        final realPhrase = await api.recoveryPhrase();
        final real = AppLock.normalizePhrase(realPhrase);
        // Same account secret, whichever format was typed (24 words, 4-letter
        // starts, or the older-style code of the same account).
        final key = phraseSecretKey(_ctl.text);
        same = real.isNotEmpty && (key != null ? key == phraseSecretKey(realPhrase) : real == typed);
      }
      if (!mounted) return;
      if (same) {
        lock.removePin();
        Navigator.of(context).pop();
        toast(context, s('pin_removed'));
        return;
      }
      setState(() => _error = s('pin_phrase_wrong'));
    } catch (_) {
      if (mounted) setState(() => _error = s('pin_phrase_unavailable'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    void close() => Navigator.of(context).pop();
    return SecureDialogFrame(
      trailing: SecureNavButton.close(context, close),
      onEscape: close,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SecureHero(icon: AppIcons.key, title: s('pin_forgot_title'), subtitle: s('sec_pin_forgot_sub'), compact: true),
        const SizedBox(height: 24),
        SecureLabel(s('recovery_phrase')),
        RecoveryPhraseInput(
          controller: _ctl,
          autofocus: true,
          onChanged: () => _error != null ? setState(() => _error = null) : null,
          onSubmitted: _check,
        ),
        if (_error != null) ...[const SizedBox(height: 12), SecureMessage(_error!)],
        const SizedBox(height: 24),
        SecurePrimaryButton(label: s('pin_remove_with_phrase'), icon: AppIcons.unlock, busy: _busy, onPressed: _busy ? null : _check),
        const SizedBox(height: 8),
        Center(child: TextButton(onPressed: close, child: Text(s('cancel')))),
      ]),
    );
  }
}

// ------------------------------------------------------------ set / check PIN

/// Asks for a new PIN twice. Returns it, or null when cancelled.
Future<String?> askNewPin(BuildContext context) => _showPinPrompt<String>(context, const _PinPrompt(newPin: true));

/// Asks for the current PIN (wrong tries count towards the wait).
Future<bool> askCurrentPin(BuildContext context, {required String title}) async =>
    await _showPinPrompt<bool>(context, _PinPrompt(newPin: false, title: title)) ?? false;

Future<T?> _showPinPrompt<T>(BuildContext context, Widget child) => showSecureDialog<T>(context, builder: (_) => child);

class _PinPrompt extends StatefulWidget {
  const _PinPrompt({required this.newPin, this.title});
  final bool newPin;
  final String? title;
  @override
  State<_PinPrompt> createState() => _PinPromptState();
}

class _PinPromptState extends State<_PinPrompt> {
  String? _first;
  String? _error;
  int _round = 0; // rebuilds the pad between steps

  Future<bool> _submit(String pin) async {
    final s = S.read(context);
    if (!widget.newPin) {
      final lock = context.read<AppLock>();
      if (await lock.tryUnlock(pin)) {
        if (mounted) Navigator.of(context).pop(true);
        return true;
      }
      if (!mounted) return false;
      setState(() => _error = lock.waitSeconds > 0 ? s('pin_wait_phrase', {'t': _mmss(lock.waitSeconds)}) : s('pin_wrong_again'));
      return false;
    }
    if (_first == null) {
      setState(() {
        _first = pin;
        _error = null;
        _round++;
      });
      return true;
    }
    if (pin == _first) {
      Navigator.of(context).pop(pin);
      return true;
    }
    setState(() {
      _first = null;
      _error = s('pin_mismatch');
      _round++;
    });
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final lock = context.watch<AppLock>();
    final confirming = widget.newPin && _first != null;
    final title = widget.title ?? (confirming ? s('pin_confirm_title') : s('pin_new_title'));
    final sub = widget.newPin ? (confirming ? s('pin_confirm_sub') : s('pin_new_sub')) : s('pin_current_sub');
    final wait = widget.newPin ? 0 : lock.waitSeconds;
    final exhausted = !widget.newPin && lock.exhausted;
    context.select<Settings, int>((x) => x.pinFails); // wait length follows the count
    void close() => Navigator.of(context).pop();
    final checking = !widget.newPin && lock.verifying;
    final String? message =
        checking ? s('pin_checking') : (exhausted ? s('pin_exhausted') : (wait > 0 ? s('pin_wait_phrase', {'t': _mmss(wait)}) : _error));
    return SecureDialogFrame(
      trailing: SecureNavButton.close(context, close),
      onEscape: close,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SecureHero(
          icon: confirming ? AppIcons.shieldCheck : AppIcons.lockKey,
          title: title,
          subtitle: sub,
          compact: true,
          below: widget.newPin ? SecureSteps(index: confirming ? 1 : 0, label: s('sec_pin_step', {'n': confirming ? 2 : 1})) : null,
        ),
        const SizedBox(height: 20),
        PinPad(
          key: ValueKey(_round),
          length: widget.newPin ? (confirming ? _first!.length : null) : context.read<Settings>().pinLength,
          enabled: wait == 0 && !exhausted,
          onSubmit: _submit,
          onChanged: () => _error != null && wait == 0 ? setState(() => _error = null) : null,
          message: message,
          messageTone: checking ? SecureTone.info : (wait > 0 && !exhausted ? SecureTone.warning : SecureTone.error),
          lockoutSeconds: exhausted || checking ? 0 : wait,
          lockoutTotal: lock.currentWaitSec,
        ),
        _CheckingBar(on: checking),
        // "Forgot PIN" is always there during a wait, not only at the end
        if (exhausted || wait > 0) ...[
          const SizedBox(height: 8),
          Center(child: TextButton(onPressed: () => showForgotPin(context), child: Text(s('pin_forgot')))),
        ],
      ]),
    );
  }
}

// ------------------------------------------------------------ chat lock

/// Opens the "Locked" folder after the PIN. True when open.
Future<bool> openLockedChats(BuildContext context) async {
  final lock = context.read<AppLock>();
  if (lock.chatsOpen) return true;
  if (!lock.hasPin) {
    lock.openLockedChats();
    return true;
  }
  final ok = await askCurrentPin(context, title: S.read(context)('locked_chats_open_title'));
  if (ok) lock.openLockedChats();
  return ok;
}

/// Locks / unlocks a chat. Locking needs a PIN: one is created first when
/// none exists (it does not turn the whole-app lock on).
Future<void> toggleChatLock(BuildContext context, String conv) async {
  final s = S.read(context);
  final lock = context.read<AppLock>();
  if (lock.isChatLocked(conv)) {
    if (lock.hasPin && !await askCurrentPin(context, title: s('chat_unlock'))) return;
    lock.setChatLocked(conv, false);
    if (context.mounted) toast(context, s('chat_unlocked_toast'));
    return;
  }
  if (!lock.hasPin) {
    final go = await confirm(context, title: s('chat_lock_need_pin'), body: s('chat_lock_need_pin_body'), action: s('chat_lock_set_pin'));
    if (!go || !context.mounted) return;
    final pin = await askNewPin(context);
    if (pin == null || !context.mounted) return;
    // The PIN must be saved before any chat is locked with it.
    try {
      await lock.setPin(pin, appLock: context.read<Settings>().appLock);
    } catch (e) {
      if (context.mounted) toastError(context, e, fallbackKey: 'pin_save_failed');
      return;
    }
  }
  lock.setChatLocked(conv, true);
  lock.hideLockedChats();
  if (context.mounted) toast(context, s('chat_locked_toast'));
}

/// Shown instead of a locked chat's messages until the PIN is entered.
class LockedChatGate extends StatelessWidget {
  const LockedChatGate({super.key, this.onBack});
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Material(
      color: context.lc.bg,
      child: SecureFrame(
        leading: onBack == null ? null : SecureNavButton.back(context, onBack!),
        onEscape: onBack,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SecureHero(icon: AppIcons.lockKey, title: s('locked_chats'), subtitle: s('sec_locked_chat_sub')),
          const SizedBox(height: 28),
          SecurePrimaryButton(label: s('pin_enter'), icon: AppIcons.unlock, onPressed: () => openLockedChats(context)),
        ]),
      ),
    );
  }
}

/// "Locked" folder row at the top of the chat list.
class LockedChatsFolder extends StatelessWidget {
  const LockedChatsFolder({super.key, required this.count, this.unread = false});
  final int count;

  /// A locked chat has unread messages: a plain dot, never a number.
  final bool unread;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final open = context.select<AppLock, bool>((l) => l.chatsOpen);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: ListTile(
        dense: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
        leading: IconTile(open ? AppIcons.unlock : AppIcons.lockKey, circle: true),
        title: Text(s('locked_chats'), style: context.tt.titleSmall),
        subtitle: Text(s(open ? 'locked_chats_open_hint' : 'locked_chats_hint', {'n': count}), style: context.tt.bodySmall),
        trailing: open
            ? TextButton(onPressed: context.read<AppLock>().hideLockedChats, child: Text(s('locked_chats_hide')))
            : Row(mainAxisSize: MainAxisSize.min, children: [
                if (unread)
                  Container(
                    key: const ValueKey('locked-unread-dot'),
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(color: context.lc.muted, shape: BoxShape.circle),
                  ),
                Icon(AppIcons.chevronRight, color: context.lc.muted, size: 18),
              ]),
        onTap: () => open ? context.read<AppLock>().hideLockedChats() : openLockedChats(context),
      ),
    );
  }
}

/// Thin progress line while the PIN is checked (the key derivation takes
/// a moment on purpose).
class _CheckingBar extends StatelessWidget {
  const _CheckingBar({required this.on});
  final bool on;
  @override
  Widget build(BuildContext context) => SizedBox(
        height: 2,
        child: on
            ? Center(
                child: SizedBox(
                  width: 120,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(1),
                    child: LinearProgressIndicator(minHeight: 2, color: LC.primary, backgroundColor: LC.primary.withValues(alpha: 0.12)),
                  ),
                ),
              )
            : null,
      );
}
