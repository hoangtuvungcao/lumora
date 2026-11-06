// "Liên kết thiết bị mới" on the device that already uses the account: a
// large QR code and a 12-digit code (valid 10 minutes) for the new device,
// then the approval sheet, then a short success state.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../widgets/sensitive_gate.dart';
import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/devices_store.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';
import '../widgets/secure_input.dart';
import 'approve_sheet.dart';
import 'device_ui.dart';

Future<void> openLinkDevice(BuildContext context) async {
  // The QR / code lets a new device join this account: owner check first,
  // blocked while the screen is shared, hidden from screenshots.
  if (!await confirmOwner(context, title: S.read(context)('dv_link_new')) || !context.mounted) return;
  await showSecureDialog<void>(context, barrierDismissible: false, builder: (_) => const SensitiveScreen(child: LinkDeviceScreen()));
}

enum _Phase { loading, open, approving, done, failed }

class LinkDeviceScreen extends StatefulWidget {
  const LinkDeviceScreen({super.key, this.showCode = false, this.previewDone});

  /// Opens on the 12-digit code instead of the QR (screenshots/tests).
  final bool showCode;

  /// Starts on the success state for this device name (screenshots).
  final String? previewDone;

  @override
  State<LinkDeviceScreen> createState() => _LinkDeviceScreenState();
}

class _LinkDeviceScreenState extends State<LinkDeviceScreen> {
  late _Phase _phase = widget.previewDone != null ? _Phase.done : _Phase.loading;
  late bool _code = widget.showCode;
  LinkOffer? _offer;
  int _expiresAt = 0;
  String? _error;
  String? _notice;
  late String _doneName = widget.previewDone ?? '';
  String _history = '6m';
  StreamSubscription<ApiEvent>? _sub;
  Timer? _tick;
  LumoraApi? _api;

  @override
  void initState() {
    super.initState();
    _api = context.read<LumoraApi>();
    _sub = context.read<DevicesStore>().linkEvents.listen(_onEvent);
    if (widget.previewDone == null) _open();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _tick?.cancel();
    if (_phase != _Phase.done) _api?.linkCancel().catchError((_) {});
    super.dispose();
  }

  Future<void> _open() async {
    setState(() {
      _phase = _Phase.loading;
      _error = null;
      _notice = null;
    });
    try {
      final o = await _api!.linkInvite();
      if (!mounted) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      setState(() {
        _offer = o;
        _expiresAt = o.expires > now ? o.expires : now + 600000;
        _phase = _Phase.open;
      });
      _tick?.cancel();
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.failed;
          _error = deviceError(S.read(context), e);
        });
      }
    }
  }

  int get _left => ((_expiresAt - DateTime.now().millisecondsSinceEpoch) / 1000).ceil().clamp(0, 3600);
  bool get _expired => _phase == _Phase.open && _left <= 0;

  void _onEvent(ApiEvent e) {
    if (!mounted) return;
    final s = S.read(context);
    final d = e.data;
    if (e.name == 'link_request') {
      if (_phase != _Phase.open) return;
      _approve(LinkRequest.fromJson(d));
      return;
    }
    switch (d['state']?.toString()) {
      case 'code_rotated':
        final c = d['code']?.toString() ?? '';
        setState(() {
          if (c.isNotEmpty) _offer = _offer?.withCode(c);
          _notice = s('dv_link_code_rotated');
        });
      case 'failed':
        if (_phase == _Phase.done) return;
        // a declined request closes the sheet; the screen shows why
        if (_phase == _Phase.approving) Navigator.of(context).popUntil((r) => r.settings.name != kLinkApprovalRoute);
        setState(() {
          _phase = _Phase.failed;
          _error = s.orElse('dv_join_failed_${d['reason']}', s('dv_link_failed'));
        });
    }
  }

  Future<void> _approve(LinkRequest req) async {
    final s = S.read(context);
    setState(() => _phase = _Phase.approving);
    final history = await showLinkApproval(context, req);
    // the request ended meanwhile (cancelled on the new device, timed out)
    if (!mounted || _phase != _Phase.approving) return;
    final api = _api!;
    if (history == null) {
      await api.linkReject(req.device).catchError((_) {});
      if (!mounted) return;
      toast(context, s('dv_denied'));
      // the invite stays open for the right device
      setState(() => _phase = _expired ? _Phase.failed : _Phase.open);
      return;
    }
    try {
      final list = await api.linkApprove(req.device, history: history);
      if (!mounted) return;
      context.read<DevicesStore>()
        ..list = list
        ..load();
      _tick?.cancel();
      setState(() {
        _phase = _Phase.done;
        _history = history;
        _doneName = req.name.trim().isEmpty ? deviceKindName(s, req.kind) : req.name.trim();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = deviceError(s, e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    void close() => Navigator.of(context).pop();
    final Widget body = switch (_phase) {
      _Phase.done => _done(s, close),
      _Phase.failed => _failed(s),
      _ when _expired => _expiredView(s),
      _Phase.loading => const SizedBox(height: 320, child: Center(child: CircularProgressIndicator())),
      _ => _invite(s),
    };
    return SecureDialogFrame(
      trailing: SecureNavButton.close(context, close),
      onEscape: close,
      child: AnimatedSize(
        duration: Motion.normal,
        curve: Motion.curve,
        alignment: Alignment.topCenter,
        child: AnimatedSwitcher(duration: Motion.normal, child: KeyedSubtree(key: ValueKey('$_phase$_expired'), child: body)),
      ),
    );
  }

  Widget _invite(S s) {
    final o = _offer!;
    final left = _left;
    final soon = left < 60;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SecureHero(icon: AppIcons.devices, title: s('dv_link_new'), subtitle: s('dv_link_sub'), compact: true),
      const SizedBox(height: 20),
      SecureSegmented<bool>(
        value: _code,
        options: [(false, AppIcons.qrCode, s('dv_link_qr')), (true, AppIcons.numpad, s('dv_link_code'))],
        onChanged: (v) => setState(() => _code = v),
      ),
      const SizedBox(height: 18),
      AnimatedSwitcher(
        duration: Motion.normal,
        child: _code ? _CodeCard(key: const ValueKey('code'), code: o.code) : _QrCard(key: const ValueKey('qr'), data: o.qr),
      ),
      const SizedBox(height: 14),
      Center(
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 5, 12, 5),
          decoration: BoxDecoration(
            color: (soon ? LC.warning : context.lc.muted).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(AppIcons.timer, size: 15, color: soon ? LC.warning : context.lc.muted),
            const SizedBox(width: 6),
            Text(
              s('dv_link_expires', {'t': formatWait(left)}),
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: soon ? LC.warning : context.lc.muted,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ]),
        ),
      ),
      if (_notice != null) ...[const SizedBox(height: 12), SecureMessage(_notice!, tone: SecureTone.warning)],
      const SizedBox(height: 20),
      NumberedStep(n: 1, text: s('dv_link_step1')),
      NumberedStep(n: 2, text: s('dv_link_step2')),
      NumberedStep(n: 3, text: s(_code ? 'dv_link_step3_code' : 'dv_link_step3_qr')),
      const SizedBox(height: 8),
      SecureNote(s('dv_link_own_only'), icon: AppIcons.shieldCheck),
    ]);
  }

  Widget _expiredView(S s) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SecureHero(icon: AppIcons.timer, tone: LC.warning, title: s('dv_link_expired'), subtitle: s('dv_link_expired_sub'), compact: true),
        const SizedBox(height: 24),
        SecurePrimaryButton(label: s('dv_link_new_code'), icon: AppIcons.refresh, onPressed: _open),
      ]);

  Widget _failed(S s) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SecureHero(icon: AppIcons.devices, tone: LC.danger, title: s('dv_join_failed_title'), subtitle: _error ?? s('dv_link_failed'), compact: true),
        const SizedBox(height: 24),
        SecurePrimaryButton(label: s('dv_try_again'), icon: AppIcons.retry, onPressed: _open),
      ]);

  Widget _done(S s, VoidCallback close) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SecureHero(
          icon: AppIcons.checkCircle,
          tone: LC.success,
          title: s('dv_link_done_title', {'name': _doneName}),
          subtitle: s(_history == 'none' ? 'dv_link_done_none' : 'dv_link_done_sub'),
          compact: true,
        ),
        const SizedBox(height: 24),
        SecurePrimaryButton(label: s('done'), icon: AppIcons.check, onPressed: close),
      ]);
}

/// The QR code on a white tile (scanners need the light background).
class _QrCard extends StatelessWidget {
  const _QrCard({super.key, required this.data});
  final String data;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: dark ? Colors.transparent : context.lc.divider),
          boxShadow: kNoShadows ? null : [BoxShadow(color: LC.primary.withValues(alpha: dark ? 0.28 : 0.12), blurRadius: 30, offset: const Offset(0, 12))],
        ),
        child: Semantics(
          label: S.of(context)('dv_link_qr'),
          image: true,
          child: QrImageView(
            data: data,
            size: 220,
            padding: EdgeInsets.zero,
            backgroundColor: Colors.white,
            eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF14162B)),
            dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Color(0xFF231E5C)),
          ),
        ),
      ),
    );
  }
}

/// The 12-digit code in three large groups.
class _CodeCard extends StatelessWidget {
  const _CodeCard({super.key, required this.code});
  final String code;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final groups = formatLinkCode(code).split('-');
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 22, 12, 14),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF1B1F3A) : const Color(0xFFF2F3FA),
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: dark ? const Color(0xFF2A2F55) : context.lc.divider),
      ),
      child: Column(children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Semantics(
            label: groups.join(' ').split('').join(' '),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              for (final (i, g) in groups.indexed) ...[
                if (i > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text('–', style: TextStyle(fontSize: 26, color: context.lc.muted.withValues(alpha: 0.6))),
                  ),
                Text(
                  g,
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 34,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 3,
                    color: context.lc.text,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ]),
          ),
        ),
        const SizedBox(height: 10),
        TextButton.icon(
          onPressed: () => copyText(context, formatLinkCode(code)),
          icon: const Icon(AppIcons.copy, size: 16),
          label: Text(s('dv_copy_code')),
        ),
      ]),
    );
  }
}
