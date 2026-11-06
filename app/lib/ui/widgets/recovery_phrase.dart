// Showing the recovery phrase and checking the user's copy of it:
//
//  * [PhraseGrid]: the 24 words, numbered, in 3 columns × 8 (desktop) or
//    2 × 12 (phones), read top-to-bottom like the paper copy.
//  * [PhraseBackupPanel]: grid + copy button + "anyone with these words…"
//    warning.
//  * [PhraseVerify]: "Check your copy" — asks for 3 random words by position.
//    Only a passed check marks the phrase as backed up.
//  * [RecoveryPhraseDialog]: both steps in a secure dialog (Settings,
//    Security checkup).

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/bip39.dart';
import '../../l10n/strings.dart';
import '../theme.dart';
import 'app_icons.dart';
import 'common.dart';
import 'secure_input.dart';

/// Numbered word grid for a recovery phrase (column by column: 1–8, 9–16, 17–24).
class PhraseGrid extends StatelessWidget {
  const PhraseGrid({super.key, required this.phrase, this.columns});
  final String phrase;

  /// Force 2 or 3 columns (default: 3 on desktop, 2 on phones).
  final int? columns;

  @override
  Widget build(BuildContext context) {
    final words = phrase.split(RegExp(r'[\s\-]+')).where((w) => w.isNotEmpty).toList();
    final dark = Theme.of(context).brightness == Brightness.dark;
    return LayoutBuilder(builder: (context, box) {
      final cols = columns ?? (isDesktop(context) && box.maxWidth >= 300 ? 3 : 2);
      final rows = (words.length / cols).ceil();
      // Room for an 8-letter word in each column: shrink the type a little in
      // narrow dialogs, and never cut a word off.
      final colW = (box.maxWidth - 16 - (cols - 1) * 12) / cols;
      final fontSize = ((colW - 32) / 4.6).clamp(14.0, 16.0);
      Widget cell(int i) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(children: [
              SizedBox(
                width: 22,
                child: Text(
                  '${i + 1}',
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.visible,
                  textAlign: TextAlign.right,
                  style: TextStyle(fontFamily: kFontFamily, fontSize: 12.5, fontWeight: FontWeight.w600, color: context.lc.muted, fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  heightFactor: 1,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      words[i],
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(fontFamily: kFontFamily, fontSize: fontSize, fontWeight: FontWeight.w600, letterSpacing: 0.2, height: 1.3, color: context.lc.text),
                    ),
                  ),
                ),
              ),
            ]),
          );
      return Semantics(
        label: S.of(context)('recovery_phrase'),
        child: Container(
          padding: const EdgeInsets.fromLTRB(4, 10, 12, 10),
          decoration: BoxDecoration(
            color: dark ? const Color(0xFF1B1F3A) : const Color(0xFFF6F7FC),
            borderRadius: BorderRadius.circular(Radii.lg),
            border: Border.all(color: dark ? const Color(0xFF2A2F55) : const Color(0xFFE1E4F0)),
          ),
          child: IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (var c = 0; c < cols; c++) ...[
                if (c > 0) VerticalDivider(width: 12, thickness: 1, color: dark ? const Color(0xFF2A2F55) : const Color(0xFFE1E4F0)),
                Expanded(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    for (var r = 0; r < rows; r++)
                      if (c * rows + r < words.length) cell(c * rows + r),
                  ]),
                ),
              ],
            ]),
          ),
        ),
      );
    });
  }
}

/// The phrase grid with a copy button and the "keep it secret" warning.
class PhraseBackupPanel extends StatelessWidget {
  const PhraseBackupPanel({super.key, required this.phrase, this.columns});
  final String phrase;
  final int? columns;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      PhraseGrid(phrase: phrase, columns: columns),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: () => copyText(context, phrase, message: s('phrase_copied')),
          icon: const Icon(AppIcons.copy, size: 17),
          label: Text(s('copy')),
        ),
      ),
      const SizedBox(height: 4),
      SecureNote(s('phrase_warning'), icon: AppIcons.warning, color: LC.warning),
    ]);
  }
}

/// "Check your copy": three random words, asked by position.
class PhraseVerify extends StatefulWidget {
  const PhraseVerify({super.key, required this.phrase, required this.onVerified, this.onShowAgain, this.positions, this.autofocus = true});
  final String phrase;
  final VoidCallback onVerified;
  final VoidCallback? onShowAgain;

  /// 0-based positions to ask for (tests / screenshots); random otherwise.
  final List<int>? positions;
  final bool autofocus;

  /// Three distinct random positions, in order.
  static List<int> randomPositions(int count, [math.Random? rng]) {
    final r = rng ?? math.Random.secure();
    final all = List.generate(count, (i) => i)..shuffle(r);
    return (all.take(3).toList()..sort());
  }

  @override
  State<PhraseVerify> createState() => _PhraseVerifyState();
}

class _PhraseVerifyState extends State<PhraseVerify> {
  late final List<String> _words = widget.phrase.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  late final List<int> _pos = widget.positions ?? PhraseVerify.randomPositions(_words.length);
  late final List<TextEditingController> _ctl = List.generate(_pos.length, (_) => TextEditingController());
  late final List<FocusNode> _nodes = List.generate(_pos.length, (i) => FocusNode(debugLabel: 'verify-$i', onKeyEvent: (n, e) => _onKey(i, e)));
  late final List<LayerLink> _links = List.generate(_pos.length, (_) => LayerLink());
  final Set<int> _wrong = {};
  bool _passed = false;

  @override
  void initState() {
    super.initState();
    for (final n in _nodes) {
      n.addListener(() => mounted ? setState(() {}) : null);
    }
  }

  @override
  void dispose() {
    for (final c in _ctl) {
      c.dispose();
    }
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  int? get _active {
    for (var i = 0; i < _nodes.length; i++) {
      if (_nodes[i].hasFocus) return i;
    }
    return null;
  }

  bool get _ready => _ctl.every((c) => c.text.trim().isNotEmpty);

  void _pick(int i, String w) {
    _ctl[i].value = TextEditingValue(text: w, selection: TextSelection.collapsed(offset: w.length));
    _wrong.remove(i);
    if (i < _nodes.length - 1) {
      _nodes[i + 1].requestFocus();
    }
    setState(() {});
  }

  KeyEventResult _onKey(int i, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final enter = k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter;
    final pickKey = (k == LogicalKeyboardKey.tab && !HardwareKeyboard.instance.isShiftPressed) || enter;
    if (!pickKey) return KeyEventResult.ignored;
    final sug = phraseSuggestionsFor(_ctl[i].text);
    if (sug.isNotEmpty) {
      _pick(i, sug.first);
      return KeyEventResult.handled;
    }
    if (enter) {
      _submitted(i);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Enter / "next" in box [i]: take the suggestion, else move on (or check).
  void _submitted(int i) {
    final sug = phraseSuggestionsFor(_ctl[i].text);
    if (sug.isNotEmpty) {
      _pick(i, sug.first);
    } else if (i < _pos.length - 1) {
      _nodes[i + 1].requestFocus();
    } else {
      _check();
    }
  }

  void _check() {
    if (!_ready || _passed) return;
    _wrong.clear();
    for (var i = 0; i < _pos.length; i++) {
      final typed = _ctl[i].text.trim().toLowerCase();
      final word = bip39Word(typed) ?? typed;
      if (word != _words[_pos[i]]) _wrong.add(i);
    }
    setState(() => _passed = _wrong.isEmpty);
    if (_passed) widget.onVerified();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final active = _active;
    final sug = active == null ? const <String>[] : phraseSuggestionsFor(_ctl[active].text);
    return PhraseSuggestPortal(
      link: active == null ? null : _links[active],
      words: _passed ? const [] : sug,
      number: active == null ? null : _pos[active] + 1,
      onPick: (w) {
        if (active != null) _pick(active, w);
      },
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < _pos.length; i++) ...[
          if (i > 0) const SizedBox(height: 14),
          SecureLabel(s('sec_phrase_word', {'n': _pos[i] + 1})),
          CompositedTransformTarget(
            link: _links[i],
            child: PhraseWordBox(
              number: _pos[i] + 1,
              controller: _ctl[i],
              focusNode: _nodes[i],
              large: true,
              enabled: !_passed,
              autofocus: widget.autofocus && i == 0,
              last: i == _pos.length - 1,
              state: _wrong.contains(i)
                  ? PhraseBoxState.bad
                  : (_passed
                      ? PhraseBoxState.ok
                      : (_ctl[i].text.trim().isNotEmpty && !_nodes[i].hasFocus && bip39Index(_ctl[i].text) == null ? PhraseBoxState.bad : PhraseBoxState.neutral)),
              onChanged: (v) {
                final t = v.trim().toLowerCase().split(RegExp(r'\s+')).first;
                if (t != v) _ctl[i].value = TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
                setState(() => _wrong.remove(i));
                // a space or line break after the word: next box
                if (t.isNotEmpty && RegExp(r'\s').hasMatch(v) && i < _pos.length - 1) _nodes[i + 1].requestFocus();
              },
              onSubmitted: () => _submitted(i),
            ),
          ),
        ],
        const SizedBox(height: 16),
        AnimatedSwitcher(
          duration: Motion.fast,
          child: _passed
              ? SecureMessage(s('phrase_check_ok'), tone: SecureTone.ok, key: const ValueKey('ok'))
              : _wrong.isNotEmpty
                  ? SecureMessage(s('phrase_check_wrong', {'n': _pos[_wrong.first] + 1}), key: const ValueKey('wrong'))
                  : const SizedBox(width: double.infinity, key: ValueKey('none')),
        ),
        const SizedBox(height: 16),
        SecurePrimaryButton(label: s('phrase_check_go'), icon: AppIcons.shieldCheck, onPressed: _ready && !_passed ? _check : null),
        if (widget.onShowAgain != null && !_passed) ...[
          const SizedBox(height: 8),
          Center(
            child: TextButton.icon(
              onPressed: widget.onShowAgain,
              icon: const Icon(AppIcons.back, size: 16),
              label: Text(s('phrase_show_again')),
            ),
          ),
        ],
      ]),
    );
  }
}

/// Settings / Security checkup: shows the phrase, then "Check your copy".
/// Pops `true` once the check passed (the caller marks the phrase as backed up).
class RecoveryPhraseDialog extends StatefulWidget {
  const RecoveryPhraseDialog({super.key, required this.phrase, this.startWithCheck = false, this.checkPositions});
  final String phrase;

  /// Screenshots / tests: open on the check step with these positions.
  final bool startWithCheck;
  final List<int>? checkPositions;

  @override
  State<RecoveryPhraseDialog> createState() => _RecoveryPhraseDialogState();
}

class _RecoveryPhraseDialogState extends State<RecoveryPhraseDialog> {
  late bool _checking = widget.startWithCheck;
  bool _passed = false;

  Future<void> _verified() async {
    setState(() => _passed = true);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    void close() => Navigator.of(context).pop(_passed);
    return SecureDialogFrame(
      leading: _checking && !_passed ? SecureNavButton.back(context, () => setState(() => _checking = false)) : null,
      trailing: SecureNavButton.close(context, close),
      onEscape: _checking && !_passed ? () => setState(() => _checking = false) : close,
      child: AnimatedSwitcher(
        duration: Motion.normal,
        switchInCurve: Motion.curve,
        transitionBuilder: (w, a) => FadeTransition(
          opacity: a,
          child: SlideTransition(position: Tween(begin: const Offset(0.03, 0), end: Offset.zero).animate(a), child: w),
        ),
        child: _checking
            ? Column(key: const ValueKey('check'), mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SecureHero(
                  icon: AppIcons.shieldCheck,
                  title: s('phrase_check_title'),
                  subtitle: s('phrase_check_sub'),
                  compact: true,
                  below: SecureSteps(index: 1, label: s('phrase_check_step', {'n': 2})),
                ),
                const SizedBox(height: 24),
                PhraseVerify(
                  phrase: widget.phrase,
                  positions: widget.checkPositions,
                  onShowAgain: () => setState(() => _checking = false),
                  onVerified: _verified,
                ),
              ])
            : Column(key: const ValueKey('show'), mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SecureHero(
                  icon: AppIcons.recoveryPhrase,
                  title: s('recovery_phrase'),
                  subtitle: s('onb_phrase_sub'),
                  compact: true,
                  below: SecureSteps(index: 0, label: s('phrase_check_step', {'n': 1})),
                ),
                const SizedBox(height: 24),
                PhraseBackupPanel(phrase: widget.phrase),
                const SizedBox(height: 24),
                SecurePrimaryButton(label: s('phrase_wrote_it'), icon: AppIcons.next, onPressed: () => setState(() => _checking = true)),
              ]),
      ),
    );
  }
}
