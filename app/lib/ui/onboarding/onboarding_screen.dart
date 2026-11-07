import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../app.dart';
import '../../l10n/strings.dart';
import '../../state/settings.dart';
import '../../state/stores.dart';
import '../settings/backup_file.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/logo.dart';
import '../widgets/recovery_phrase.dart';
import '../widgets/secure_input.dart';
import '../../state/password_policy.dart';
import 'appearance_step.dart';
import '../devices/link_join.dart';

enum _Step { welcome, name, passphrase, phrase, restore, verify, setup, link }

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, this.initialStep, this.previewPhrase, this.restoreFromFile = false, this.previewBackupPath, this.previewCheckPositions});

  /// For screenshots/tests: 0 welcome, 1 name, 2 passphrase, 3 phrase, 4 restore,
  /// 5 "check your copy", 7 link to an account on another device. Null (normal
  /// start): the language & theme step (or the link step when it was left open).
  final int? initialStep;

  /// Positions asked in the "check your copy" step (screenshots/tests).
  final List<int>? previewCheckPositions;

  /// Phrase shown when starting directly at step 3 (screenshots).
  final String? previewPhrase;

  /// Restore step opens on the "backup file" tab (screenshots/tests).
  final bool restoreFromFile;
  final String? previewBackupPath;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  late _Step _step = widget.initialStep == null
      ? (context.read<Settings>().linkPending ? _Step.link : _Step.setup)
      : _Step.values[widget.initialStep!];
  final _name = TextEditingController();
  final _pass = TextEditingController();
  final _pass2 = TextEditingController();
  final _restore = TextEditingController();
  bool _usePass = true;

  /// Restore step: false = recovery phrase, true = backup file.
  late bool _fromFile = widget.restoreFromFile;
  late String? _backupPath = widget.previewBackupPath;
  final _backupPw = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _phrase;

  @override
  void dispose() {
    _name.dispose();
    _pass.dispose();
    _pass2.dispose();
    _restore.dispose();
    _backupPw.dispose();
    super.dispose();
  }

  void _go(_Step s) => setState(() {
        _step = s;
        _error = null;
      });

  Future<void> _create() async {
    final s = S.read(context);
    final weak = _usePass ? passwordProblem(_pass.text) : null;
    if (_usePass && (weak != null || _pass.text != _pass2.text)) {
      setState(() => _error = weak != null ? s(weak) : s('pass_mismatch'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final sv = context.read<AppServices>();
      await sv.createIdentity(name: _name.text.trim(), passphrase: _usePass ? _pass.text : null, enter: false);
      final phrase = await sv.api.recoveryPhrase();
      setState(() {
        _phrase = phrase;
        _step = _Step.phrase;
      });
    } catch (e) {
      setState(() => _error = errorMessage(S.read(context), e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Leaves onboarding. [backedUp]: the "check your copy" step passed (the
  /// Security checkup keeps reminding until it has).
  void _finish({required bool backedUp}) {
    context.read<Settings>().update((x) => x
      ..onboarded = true
      ..phraseBackedUp = backedUp || x.phraseBackedUp
      ..showTour = true);
    context.read<SessionStore>().setPhase(SessionPhase.ready);
  }

  Future<void> _doRestore() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AppServices>().createIdentity(
            name: _name.text.trim(),
            passphrase: _usePass && _pass.text.isNotEmpty ? _pass.text : null,
            restorePhrase: _restore.text.trim(),
          );
    } catch (e) {
      setState(() => _error = errorMessage(S.read(context), e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _doRestoreFile() async {
    final path = _backupPath;
    if (path == null || _backupPw.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AppServices>().createIdentity(
            name: '',
            passphrase: _usePass && _pass.text.isNotEmpty ? _pass.text : null,
            restoreBackup: (path, _backupPw.text),
          );
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(S.read(context), e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickBackup() async {
    final p = await pickBackupFile();
    if (p != null && mounted) setState(() => _backupPath = p);
  }

  Widget _restoreFile(S s) {
    final path = _backupPath;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      BackupFileTile(path: path, onTap: _pickBackup),
      const SizedBox(height: 16),
      PasswordField(
        controller: _backupPw,
        label: s('backup_password'),
        onChanged: (_) => setState(() => _error = null),
        onSubmitted: (_) => _doRestoreFile(),
      ),
      const SizedBox(height: 16),
      PasswordField(controller: _pass, label: s('passphrase_optional'), icon: AppIcons.key, newPassword: true, showStrength: true),
      _err(),
      const SizedBox(height: 24),
      SecurePrimaryButton(
        label: s('restore'),
        icon: AppIcons.unarchive,
        busy: _busy,
        onPressed: _backupPath != null && _backupPw.text.isNotEmpty ? _doRestoreFile : null,
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final desktop = isDesktop(context);
    final card = AnimatedSwitcher(
      duration: Motion.slow,
      switchInCurve: Motion.curve,
      transitionBuilder: (w, a) => FadeTransition(
        opacity: a,
        child: SlideTransition(position: Tween(begin: const Offset(0.04, 0), end: Offset.zero).animate(a), child: w),
      ),
      child: KeyedSubtree(key: ValueKey(_step), child: _body(context)),
    );
    return Scaffold(
      body: Stack(children: [
        // Soft brand glow.
        Positioned(
          top: -200,
          right: -160,
          child: Container(
            width: 520,
            height: 520,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [LC.primary.withValues(alpha: 0.28), LC.primary.withValues(alpha: 0)]),
            ),
          ),
        ),
        Positioned(
          bottom: -220,
          left: -160,
          child: Container(
            width: 520,
            height: 520,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [LC.accent.withValues(alpha: 0.18), LC.accent.withValues(alpha: 0)]),
            ),
          ),
        ),
        SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
              child: Row(children: [
                const LumoraWordmark(size: 30),
                const Spacer(),
                // The welcome step has its own large language cards.
                _Hideable(visible: _step != _Step.setup, child: const _LangSwitch()),
              ]),
            ),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: desktop && _step != _Step.setup ? 480 : 520),
                    duration: Motion.slow,
                    curve: Motion.curve,
                    builder: (_, w, child) => ConstrainedBox(constraints: BoxConstraints(maxWidth: w), child: child),
                    child: desktop
                        ? Container(
                            padding: const EdgeInsets.all(32),
                            decoration: BoxDecoration(
                              color: context.lc.surface.withValues(alpha: 0.92),
                              borderRadius: BorderRadius.circular(Radii.xl),
                              border: Border.all(color: context.lc.divider),
                              boxShadow: kNoShadows ? null : [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 40, offset: const Offset(0, 20))],
                            ),
                            child: card,
                          )
                        : card,
                  ),
                ),
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _title(String t, String sub) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t, style: context.tt.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(sub, style: context.tt.bodyMedium?.copyWith(color: context.lc.muted, height: 1.5)),
        const SizedBox(height: 24),
      ]);

  Widget _err() => _error == null ? const SizedBox.shrink() : Padding(padding: const EdgeInsets.only(top: 12), child: SecureMessage(_error!));

  Widget _body(BuildContext context) {
    final s = S.of(context);
    switch (_step) {
      case _Step.setup:
        return OnboardingAppearance(onContinue: () => _go(_Step.welcome));
      case _Step.welcome:
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Center(child: AnimatedLogo(size: 88)),
          const SizedBox(height: 24),
          Text(s('onb_title'), textAlign: TextAlign.center, style: context.tt.headlineMedium?.copyWith(fontWeight: FontWeight.w700, height: 1.2)),
          const SizedBox(height: 12),
          Text(s('onb_sub'), textAlign: TextAlign.center, style: context.tt.bodyMedium?.copyWith(color: context.lc.muted, height: 1.55)),
          const SizedBox(height: 24),
          for (final (i, t) in [(AppIcons.lock, 'onb_f1'), (AppIcons.peerToPeer, 'onb_f2'), (AppIcons.remote, 'onb_f3')])
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(children: [
                IconTile(i, size: IconTileSize.sm),
                const SizedBox(width: 12),
                Expanded(child: Text(s(t), style: context.tt.bodyMedium)),
              ]),
            ),
          const SizedBox(height: 20),
          GradientButton(label: s('create_identity'), icon: AppIcons.sparkle, expand: true, onPressed: () => _go(_Step.name)),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: () => _go(_Step.restore), child: Text(s('restore_identity'))),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: () => _go(_Step.link), child: Text(s('dv_have_account'), textAlign: TextAlign.center)),
          const SizedBox(height: 4),
          TextButton(onPressed: () => _go(_Step.setup), child: Text(s('back'))),
        ]);
      case _Step.name:
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _StepDots(index: 0),
          _title(s('onb_name_title'), s('onb_name_sub')),
          Center(
            child: ValueListenableBuilder(
              valueListenable: _name,
              builder: (_, v, _) => Avatar(name: v.text.isEmpty ? '?' : v.text, size: 80),
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _name,
            autofocus: true,
            maxLength: 40,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _name.text.trim().isNotEmpty ? _go(_Step.passphrase) : null,
            decoration: InputDecoration(labelText: s('display_name'), hintText: s('display_name_hint'), counterText: ''),
          ),
          const SizedBox(height: 8),
          Text(s('onb_name_note'), style: context.tt.bodySmall),
          const SizedBox(height: 24),
          GradientButton(label: s('continue'), expand: true, onPressed: _name.text.trim().isEmpty ? null : () => _go(_Step.passphrase)),
          TextButton(onPressed: () => _go(_Step.welcome), child: Text(s('back'))),
        ]);
      case _Step.passphrase:
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _StepDots(index: 1),
          _title(s('onb_pass_title'), s('onb_pass_sub')),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: LC.primary.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(Radii.md)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(AppIcons.shield, color: LC.primary, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text(s('onb_pass_explain'), style: context.tt.bodySmall?.copyWith(color: context.lc.text, height: 1.5))),
            ]),
          ),
          const SizedBox(height: 12),
          SwitchRow(title: s('use_passphrase'), subtitle: s('use_passphrase_hint'), value: _usePass, onChanged: (v) => setState(() => _usePass = v)),
          AnimatedSize(
            duration: Motion.normal,
            curve: Motion.curve,
            child: _usePass
                ? AutofillGroup(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      const SizedBox(height: 12),
                      PasswordField(
                        controller: _pass,
                        label: s('passphrase'),
                        newPassword: true,
                        showStrength: true,
                        minLength: kMinPasswordLength,
                        onChanged: (_) => _error != null ? setState(() => _error = null) : null,
                      ),
                      const SizedBox(height: 16),
                      PasswordField(
                        controller: _pass2,
                        label: s('passphrase_repeat'),
                        newPassword: true,
                        matchWith: _pass,
                        onChanged: (_) => _error != null ? setState(() => _error = null) : null,
                        onSubmitted: (_) => _create(),
                      ),
                    ]),
                  )
                : const SizedBox(width: double.infinity),
          ),
          _err(),
          const SizedBox(height: 24),
          SecurePrimaryButton(label: s('create_identity'), icon: AppIcons.sparkle, busy: _busy, onPressed: _create),
          const SizedBox(height: 8),
          TextButton(onPressed: () => _go(_Step.name), child: Text(s('back'))),
        ]);
      case _Step.phrase:
        final phrase = _phrase ?? widget.previewPhrase ?? '';
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _StepDots(index: 2),
          _title(s('onb_phrase_title'), s('onb_phrase_sub')),
          PhraseBackupPanel(phrase: phrase),
          const SizedBox(height: 24),
          GradientButton(label: s('phrase_wrote_it'), icon: AppIcons.next, expand: true, onPressed: () => _go(_Step.verify)),
        ]);
      case _Step.verify:
        final phrase = _phrase ?? widget.previewPhrase ?? '';
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _StepDots(index: 2),
          _title(s('phrase_check_title'), s('phrase_check_sub')),
          PhraseVerify(
            phrase: phrase,
            positions: widget.previewCheckPositions,
            onShowAgain: () => _go(_Step.phrase),
            onVerified: () => Future.delayed(const Duration(milliseconds: 700), () {
              if (mounted) _finish(backedUp: true);
            }),
          ),
          const SizedBox(height: 4),
          Center(child: TextButton(onPressed: () => _finish(backedUp: false), child: Text(s('phrase_later')))),
        ]);
      case _Step.link:
        final sv = context.read<AppServices>();
        return LinkJoinView(
          ensureCore: sv.startForLink,
          onBack: () async {
            await sv.abandonLink();
            if (mounted) _go(_Step.welcome);
          },
        );
      case _Step.restore:
        final modes = SecureSegmented<bool>(
          value: _fromFile,
          options: [(false, AppIcons.recoveryPhrase, s('restore_by_phrase')), (true, AppIcons.fileArchive, s('restore_by_file'))],
          onChanged: (v) => setState(() {
            _fromFile = v;
            _error = null;
          }),
        );
        final back = Center(child: TextButton(onPressed: () => _go(_Step.welcome), child: Text(s('back'))));
        final hero = SecureHero(title: s('restore_identity'), subtitle: s('sec_restore_sub'), compact: true, showMark: false);
        return CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => _go(_Step.welcome)},
          child: _fromFile
              ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  hero,
                  const SizedBox(height: 20),
                  modes,
                  const SizedBox(height: 20),
                  _restoreFile(s),
                  const SizedBox(height: 8),
                  back,
                ])
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  hero,
                  const SizedBox(height: 20),
                  modes,
                  const SizedBox(height: 16),
                  // the phrase makes this the MAIN device: the current main device (if the
                  // account is still in use) is signed out — linking keeps both
                  SecureNote(s('restore_takes_over'), icon: AppIcons.warning, color: LC.warning),
                  const SizedBox(height: 16),
                  RecoveryPhraseInput(controller: _restore, onChanged: () => setState(() => _error = null)),
                  const SizedBox(height: 20),
                  SecureTextField(controller: _name, label: s('display_name'), hint: s('display_name_hint'), onChanged: (_) => setState(() {})),
                  const SizedBox(height: 16),
                  PasswordField(controller: _pass, label: s('passphrase_optional'), icon: AppIcons.key, newPassword: true, showStrength: true),
                  _err(),
                  const SizedBox(height: 24),
                  SecurePrimaryButton(
                    label: s('restore'),
                    icon: AppIcons.unarchive,
                    busy: _busy,
                    onPressed: RecoveryPhraseInput.isReady(_restore.text) ? _doRestore : null,
                  ),
                  const SizedBox(height: 8),
                  back,
                ]),
        );
    }
  }
}

class _StepDots extends StatelessWidget {
  const _StepDots({required this.index});
  final int index;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Row(children: [
          for (var i = 0; i < 3; i++)
            AnimatedContainer(
              duration: Motion.normal,
              margin: const EdgeInsets.only(right: 6),
              width: i == index ? 28 : 8,
              height: 8,
              decoration: BoxDecoration(
                gradient: i <= index ? LC.gradient : null,
                color: i <= index ? null : context.lc.surface2,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
        ]),
      );
}

/// Fades a top-bar control out without changing the bar's height (and
/// keeps it out of reach of focus and screen readers while hidden).
class _Hideable extends StatelessWidget {
  const _Hideable({required this.visible, required this.child});
  final bool visible;
  final Widget child;
  @override
  Widget build(BuildContext context) => AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: Motion.normal,
        child: IgnorePointer(ignoring: !visible, child: ExcludeFocus(excluding: !visible, child: ExcludeSemantics(excluding: !visible, child: child))),
      );
}

class _LangSwitch extends StatelessWidget {
  const _LangSwitch();
  @override
  Widget build(BuildContext context) {
    final st = context.watch<Settings>();
    return SegmentedButton<String>(
      showSelectedIcon: false,
      style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
      segments: const [ButtonSegment(value: 'vi', label: Text('VI')), ButtonSegment(value: 'en', label: Text('EN'))],
      selected: {st.locale},
      onSelectionChanged: (v) => st.update((x) => x.locale = v.first),
    );
  }
}
