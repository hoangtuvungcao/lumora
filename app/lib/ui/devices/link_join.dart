// The new device's side of linking (onboarding "I already use Lumora on
// another device"): scan the QR code or type / paste the 12-digit code shown
// on the existing device, wait for it to be approved there, then the core
// restarts as part of the account (see AppServices).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/devices_store.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';
import '../widgets/secure_input.dart';
import 'device_ui.dart';
import 'qr_scan.dart';

/// Camera scanning for phones (Android / iOS, see qr_scan.dart). Null hides the
/// "Scan the QR code" button; desktop keeps paste and the 12-digit code. Tests
/// inject a fake.
QrScanner? linkQrScanner = qrScanSupported ? scanLinkQr : null;

enum JoinPhase { enter, checking, waiting, approved, failed }

class LinkJoinView extends StatefulWidget {
  const LinkJoinView({super.key, this.ensureCore, this.onBack, this.initialPhase, this.previewTarget, this.previewCode, this.previewError});

  /// Starts the core in "waiting to be linked" mode (before the first scan).
  final Future<void> Function()? ensureCore;
  final VoidCallback? onBack;

  /// Screenshots/tests: start on this phase / with this device / code / error.
  final JoinPhase? initialPhase;
  final LinkRequest? previewTarget;
  final String? previewCode;
  final String? previewError;

  @override
  State<LinkJoinView> createState() => _LinkJoinViewState();
}

class _LinkJoinViewState extends State<LinkJoinView> {
  late JoinPhase _phase = widget.initialPhase ?? JoinPhase.enter;
  late final _code = TextEditingController(text: widget.previewCode ?? '');
  late String? _error = widget.previewError;
  late LinkRequest? _target = widget.previewTarget;
  StreamSubscription<ApiEvent>? _sub;
  LumoraApi? _api;

  @override
  void initState() {
    super.initState();
    _api = context.read<LumoraApi>();
    // A `lumora://link/…` code is only taken from this screen (scan / paste /
    // type), never from a link another app opened (see core/links.dart).
    _sub = context.read<DevicesStore>().linkEvents.listen(_onEvent);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _code.dispose();
    super.dispose();
  }

  String get _digits => _code.text.replaceAll(RegExp(r'\D'), '');

  void _onEvent(ApiEvent e) {
    if (!mounted || e.name != 'link_state') return;
    final s = S.read(context);
    switch (e.data['state']?.toString()) {
      case 'approved' || 'restart':
        setState(() => _phase = JoinPhase.approved);
      case 'failed' || 'cancelled':
        if (_phase == JoinPhase.enter || _phase == JoinPhase.approved) return;
        final reason = e.data['reason']?.toString() ?? (e.data['state'] == 'cancelled' ? 'cancelled' : '');
        setState(() {
          _phase = JoinPhase.failed;
          _error = s.orElse('dv_join_failed_$reason', s('dv_link_failed'));
        });
    }
  }

  Future<void> _submit({String? qr}) async {
    final s = S.read(context);
    if (qr == null && _digits.length != 12) return;
    setState(() {
      _phase = JoinPhase.checking;
      _error = null;
    });
    try {
      await widget.ensureCore?.call();
      final r = await _api!.linkScan(qr: qr, code: qr == null ? formatLinkCode(_digits) : null);
      if (!mounted) return;
      // approval may already have arrived while the answer was on its way
      if (_phase != JoinPhase.checking) return;
      setState(() {
        _target = r;
        _phase = JoinPhase.waiting;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = JoinPhase.enter;
        _error = deviceError(s, e);
      });
    }
  }

  Future<void> _cancel() async {
    await _api!.linkCancel().catchError((_) {});
    if (!mounted) return;
    setState(() {
      _phase = JoinPhase.enter;
      _target = null;
    });
  }

  Future<void> _paste() async {
    final s = S.read(context);
    final t = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
    if (!mounted) return;
    final link = RegExp(r'lumora://link/\S+').firstMatch(t)?.group(0);
    if (link != null) return _submit(qr: link);
    final d = t.replaceAll(RegExp(r'\D'), '');
    if (d.length != 12) {
      setState(() => _error = s('dv_join_paste_none'));
      return;
    }
    _code.text = d;
    _submit();
  }

  Future<void> _scan() async {
    final scan = linkQrScanner;
    if (scan == null) return;
    String? r;
    try {
      r = await scan(context);
    } catch (_) {
      if (mounted) setState(() => _error = S.read(context)('dv_join_camera_off'));
      return;
    }
    if (r == null || !mounted) return;
    final link = RegExp(r'lumora://link/\S+').firstMatch(r)?.group(0);
    if (link != null) {
      _submit(qr: link);
    } else {
      setState(() => _error = S.read(context)('err_link_code_invalid'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final body = switch (_phase) {
      JoinPhase.enter || JoinPhase.checking => _enter(s),
      JoinPhase.waiting => _waiting(s),
      JoinPhase.approved => _approved(s),
      JoinPhase.failed => _failed(s),
    };
    return AnimatedSwitcher(
      duration: Motion.normal,
      switchInCurve: Motion.curve,
      child: KeyedSubtree(key: ValueKey(_phase == JoinPhase.checking ? JoinPhase.enter : _phase), child: body),
    );
  }

  Widget _enter(S s) {
    final busy = _phase == JoinPhase.checking;
    final phone = !isDesktop(context);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SecureHero(icon: AppIcons.devices, title: s('dv_join_title'), subtitle: s('dv_join_sub'), compact: true),
      const SizedBox(height: 24),
      if (phone && linkQrScanner != null) ...[
        SecureOptionCard(icon: AppIcons.scan, title: s('dv_join_scan'), subtitle: s('dv_join_scan_hint'), onTap: busy ? () {} : _scan),
        const SizedBox(height: 18),
        SecureLabel(s('dv_join_or_code')),
      ] else
        SecureLabel(
          s('dv_join_code_label'),
          trailing: TextButton.icon(
            onPressed: busy ? null : _paste,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
            icon: const Icon(AppIcons.paste, size: 16),
            label: Text(s('dv_join_paste')),
          ),
        ),
      LinkCodeInput(
        controller: _code,
        enabled: !busy,
        autofocus: !phone,
        error: _error != null,
        onChanged: () => setState(() => _error = null),
        onCompleted: () => _submit(),
        onLink: (l) => _submit(qr: l),
      ),
      if (phone && linkQrScanner != null)
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: busy ? null : _paste,
            icon: const Icon(AppIcons.paste, size: 16),
            label: Text(s('dv_join_paste')),
          ),
        ),
      AnimatedSize(
        duration: Motion.fast,
        child: _error == null
            ? const SizedBox(width: double.infinity)
            : Padding(padding: const EdgeInsets.only(top: 12), child: SecureMessage(_error!)),
      ),
      const SizedBox(height: 22),
      SecurePrimaryButton(
        label: busy ? s('dv_join_checking') : s('dv_join_connect'),
        icon: AppIcons.link,
        busy: busy,
        onPressed: _digits.length == 12 ? () => _submit() : null,
      ),
      if (widget.onBack != null) ...[
        const SizedBox(height: 8),
        Center(child: TextButton(onPressed: busy ? null : widget.onBack, child: Text(s('back')))),
      ],
    ]);
  }

  Widget _waiting(S s) {
    final t = _target;
    final name = t == null || t.name.trim().isEmpty ? null : t.name.trim();
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Center(child: _PulsingDevice(kind: t?.kind ?? 0)),
      const SizedBox(height: 22),
      Text(
        name == null ? s('dv_join_wait_title_generic') : s('dv_join_wait_title', {'name': name}),
        textAlign: TextAlign.center,
        style: context.tt.headlineSmall?.copyWith(fontWeight: FontWeight.w700, fontSize: 21, height: 1.3),
      ),
      const SizedBox(height: 8),
      Text(s('dv_join_wait_sub'), textAlign: TextAlign.center, style: context.tt.bodyMedium?.copyWith(color: context.lc.muted, height: 1.5)),
      const SizedBox(height: 22),
      Center(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 10),
          Text(s('dv_join_waiting'), style: context.tt.bodySmall?.copyWith(fontSize: 13)),
        ]),
      ),
      const SizedBox(height: 22),
      Center(child: TextButton(onPressed: _cancel, child: Text(s('cancel')))),
    ]);
  }

  Widget _approved(S s) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SecureHero(icon: AppIcons.checkCircle, tone: LC.success, title: s('dv_join_approved_title'), subtitle: s('dv_join_approved_sub'), compact: true),
        const SizedBox(height: 24),
        const Center(child: SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.4))),
      ]);

  Widget _failed(S s) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SecureHero(icon: AppIcons.devices, tone: LC.danger, title: s('dv_join_failed_title'), subtitle: _error ?? s('dv_link_failed'), compact: true),
        const SizedBox(height: 24),
        SecurePrimaryButton(
          label: s('dv_try_again'),
          icon: AppIcons.retry,
          onPressed: () => setState(() {
            _phase = JoinPhase.enter;
            _error = null;
            _code.clear();
          }),
        ),
        if (widget.onBack != null) ...[
          const SizedBox(height: 8),
          Center(child: TextButton(onPressed: widget.onBack, child: Text(s('back')))),
        ],
      ]);
}

/// The other device's icon with a slow, calm pulse while we wait for it.
class _PulsingDevice extends StatefulWidget {
  const _PulsingDevice({required this.kind});
  final int kind;
  @override
  State<_PulsingDevice> createState() => _PulsingDeviceState();
}

class _PulsingDeviceState extends State<_PulsingDevice> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));

  @override
  void initState() {
    super.initState();
    // no endless animation under reduced motion (and in tests)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !MediaQuery.of(context).disableAnimations && !kNoShadows) _c.repeat();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = deviceKindColor(widget.kind);
    return SizedBox(
      width: 120,
      height: 120,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) => Stack(alignment: Alignment.center, children: [
          for (final k in [0.0, 0.5])
            Builder(builder: (context) {
              final t = (_c.value + k) % 1.0;
              return Container(
                width: 64 + 56 * t,
                height: 64 + 56 * t,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: color.withValues(alpha: 0.35 * (1 - t)), width: 2)),
              );
            }),
          child!,
        ]),
        child: Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: 0.14),
            border: Border.all(color: color.withValues(alpha: 0.32)),
          ),
          child: Center(child: PhosphorIcon(AppIcons.duotone(deviceKindIcon(widget.kind)), size: 34, color: color, duotoneSecondaryOpacity: 0.3)),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------- code input

/// Twelve digit boxes in three groups (1234 – 5678 – 9012). One hidden text
/// field takes the typing, so auto-advance, backspace and paste (Ctrl+V, the
/// long-press menu) work everywhere; a pasted `lumora://link/…` goes to
/// [onLink].
class LinkCodeInput extends StatefulWidget {
  const LinkCodeInput({super.key, required this.controller, this.onChanged, this.onCompleted, this.onLink, this.enabled = true, this.autofocus = false, this.error = false});
  final TextEditingController controller;
  final VoidCallback? onChanged;
  final VoidCallback? onCompleted;
  final ValueChanged<String>? onLink;
  final bool enabled;
  final bool autofocus;
  final bool error;

  @override
  State<LinkCodeInput> createState() => _LinkCodeInputState();
}

class _LinkCodeInputState extends State<LinkCodeInput> {
  final _focus = FocusNode(debugLabel: 'link-code');

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final digits = widget.controller.text.replaceAll(RegExp(r'\D'), '');
    final current = digits.length.clamp(0, 11);
    final focused = _focus.hasFocus && widget.enabled;
    return Semantics(
      label: s('dv_join_code_label'),
      value: digits.split('').join(' '),
      textField: true,
      child: LayoutBuilder(builder: (context, box) {
        const dash = 18.0, gap = 5.0;
        final w = ((box.maxWidth - 2 * dash - 9 * gap) / 12).clamp(18.0, 38.0);
        final h = (w * 1.36).clamp(40.0, 54.0);
        Widget cell(int i) {
          final has = i < digits.length;
          final active = focused && i == current && digits.length < 12;
          final border = widget.error
              ? LC.danger
              : active
                  ? LC.primary
                  : (has ? LC.primary.withValues(alpha: dark ? 0.45 : 0.35) : (dark ? const Color(0xFF2A2F55) : context.lc.divider));
          return AnimatedContainer(
            duration: Motion.fast,
            width: w,
            height: h,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: dark ? const Color(0xFF1B1F3A) : const Color(0xFFF2F3FA),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: border, width: active ? 1.8 : 1.2),
              boxShadow: active ? [BoxShadow(color: LC.primary.withValues(alpha: 0.22), blurRadius: 8, spreadRadius: 1)] : null,
            ),
            child: has
                ? Text(digits[i], style: TextStyle(fontFamily: kFontFamily, fontSize: w * 0.62, fontWeight: FontWeight.w700, color: context.lc.text))
                : (active ? Container(width: 2, height: h * 0.42, color: LC.primary) : null),
          );
        }

        final row = Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          for (var g = 0; g < 3; g++) ...[
            if (g > 0)
              SizedBox(width: dash, child: Center(child: Container(width: 8, height: 2, color: context.lc.muted.withValues(alpha: 0.5)))),
            for (var i = 0; i < 4; i++) ...[
              if (i > 0) const SizedBox(width: gap),
              cell(g * 4 + i),
            ],
          ],
        ]);
        return GestureDetector(
          onTap: widget.enabled ? () => _focus.requestFocus() : null,
          child: Stack(children: [
            row,
            // The real input, invisible, on top of the boxes.
            Positioned.fill(
              child: Opacity(
                opacity: 0,
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focus,
                  enabled: widget.enabled,
                  autofocus: widget.autofocus,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  showCursor: false,
                  autocorrect: false,
                  enableSuggestions: false,
                  inputFormatters: [_LinkCodeFormatter(onLink: widget.onLink)],
                  decoration: const InputDecoration(border: InputBorder.none, isCollapsed: true, filled: false),
                  onChanged: (v) {
                    setState(() {});
                    widget.onChanged?.call();
                    if (v.replaceAll(RegExp(r'\D'), '').length == 12) widget.onCompleted?.call();
                  },
                  onSubmitted: (_) => widget.onCompleted?.call(),
                ),
              ),
            ),
          ]),
        );
      }),
    );
  }
}

/// Keeps at most 12 digits; a pasted link is handed over instead.
class _LinkCodeFormatter extends TextInputFormatter {
  _LinkCodeFormatter({this.onLink});
  final ValueChanged<String>? onLink;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final link = RegExp(r'lumora://link/\S+').firstMatch(newValue.text)?.group(0);
    if (link != null) {
      final cb = onLink;
      if (cb != null) scheduleMicrotask(() => cb(link));
      return oldValue;
    }
    var d = newValue.text.replaceAll(RegExp(r'\D'), '');
    if (d.length > 12) d = d.substring(0, 12);
    return TextEditingValue(text: d, selection: TextSelection.collapsed(offset: d.length));
  }
}
