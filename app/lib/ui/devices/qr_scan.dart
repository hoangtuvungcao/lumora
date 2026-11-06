// Phone camera QR scanner (Android / iOS): linking a device, and every other
// Lumora QR code (add a friend, join a group, remote control — see
// lib/core/links.dart and Flows.scanQr).
//
// `mobile_scanner` does the camera + decoding natively: CameraX + the Google Play
// services barcode model on Android (unbundled: nothing big ships in the APK), Apple
// Vision on iOS (built into the OS). Only QR codes are looked for, and the first
// code the caller accepts (`lumora://link/…` for device linking, any Lumora link
// for [scanLumoraQr]) closes the screen with it. Anything else gets a short
// "That isn't a Lumora code" and scanning goes on.
//
// No camera permission (refused, or blocked in the system settings) or no usable
// camera: a calm panel explains it and offers "Open Settings" / "Type the 12-digit
// code" — closing returns null, so the join screen keeps the code input.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/links.dart';
import '../../l10n/strings.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/secure_input.dart';

final _linkRe = RegExp(r'lumora://link/\S+');

/// Opens a camera QR scanner and returns the scanned text (null = cancelled).
typedef QrScanner = Future<String?> Function(BuildContext context);

/// Phones only (desktop keeps paste / the 12-digit code).
bool get qrScanSupported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// Opens the scanner; the scanned `lumora://link/…` text, or null when closed.
Future<String?> scanLinkQr(BuildContext context) => Navigator.of(context).push<String>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => const QrScanScreen()),
    );

/// Opens the scanner for any Lumora QR code (friend, group invite, remote
/// control, device link); the scanned link text, or null when closed.
Future<String?> scanLumoraQr(BuildContext context) => Navigator.of(context).push<String>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => QrScanScreen.any()),
    );

/// The "Scan QR code" entries outside device linking (Add friend, Join group,
/// Remote control, the "+" menu). Null hides them (desktop). Tests inject a fake.
QrScanner? lumoraQrScanner = qrScanSupported ? scanLumoraQr : null;

String? _deviceLink(String raw) => _linkRe.firstMatch(raw)?.group(0);

String? _anyLumoraLink(String raw) {
  final l = LumoraLink.find(raw);
  return l == null ? null : (l.kind == LinkKind.device ? l.raw : l.https);
}

class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key}) : pick = _deviceLink, titleKey = 'qr_scan_title', notLinkKey = 'qr_scan_not_link', bottomKey = 'qr_scan_type_code';

  /// Any Lumora QR code.
  const QrScanScreen.any({super.key}) : pick = _anyLumoraLink, titleKey = 'qr_any_title', notLinkKey = 'qr_any_not_lumora', bottomKey = 'qr_any_type_instead';

  /// The text to return for a scanned code, or null to keep scanning.
  final String? Function(String raw) pick;
  final String titleKey;
  final String notLinkKey;
  final String bottomKey;
  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
  );
  bool _done = false;
  bool _notLink = false;
  Timer? _notLinkTimer;

  @override
  void dispose() {
    _notLinkTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue ?? '';
      final link = widget.pick(raw);
      if (link != null) {
        _done = true;
        HapticFeedback.mediumImpact();
        Navigator.of(context).pop(link);
        return;
      }
    }
    if (capture.barcodes.isEmpty) return;
    _notLinkTimer?.cancel();
    if (!_notLink) setState(() => _notLink = true);
    _notLinkTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _notLink = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(builder: (context, box) {
        final side = (box.maxWidth * 0.7).clamp(200.0, 300.0);
        final window = Rect.fromCenter(center: Offset(box.maxWidth / 2, box.maxHeight * 0.44), width: side, height: side);
        return Stack(fit: StackFit.expand, children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            scanWindow: window,
            errorBuilder: (context, e) => QrCameraIssue(denied: e.errorCode == MobileScannerErrorCode.permissionDenied, backKey: widget.bottomKey),
            overlayBuilder: (context, _) => _Overlay(window: window, notLink: _notLink, screen: widget),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: ValueListenableBuilder<MobileScannerState>(
                valueListenable: _controller,
                builder: (context, st, _) {
                  // the issue panel uses the app's own (light or dark) background
                  final fg = st.error != null ? context.lc.text : Colors.white;
                  final torch = st.isInitialized && st.error == null && st.torchState != TorchState.unavailable;
                  final on = st.torchState == TorchState.on;
                  return Row(children: [
                    IconButton(tooltip: s('close'), onPressed: () => Navigator.of(context).pop(), icon: Icon(AppIcons.close, color: fg)),
                    const Spacer(),
                    if (torch)
                      IconButton(
                        tooltip: s('qr_scan_torch'),
                        onPressed: _controller.toggleTorch,
                        icon: Icon(on ? AppIcons.sun : AppIcons.moon, color: on ? const Color(0xFFFFD166) : Colors.white),
                      ),
                  ]);
                },
              ),
            ),
          ),
        ]);
      }),
    );
  }
}

/// Dimmed surroundings, a rounded window with corner marks, title + hint.
class _Overlay extends StatelessWidget {
  const _Overlay({required this.window, required this.notLink, required this.screen});
  final Rect window;
  final bool notLink;
  final QrScanScreen screen;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Stack(fit: StackFit.expand, children: [
      IgnorePointer(child: CustomPaint(painter: _WindowPainter(window))),
      Positioned(
        left: 24,
        right: 24,
        bottom: MediaQuery.sizeOf(context).height - window.top + 28,
        child: Text(
          s(screen.titleKey),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w700, height: 1.3),
        ),
      ),
      Positioned(
        left: 24,
        right: 24,
        top: window.bottom + 24,
        child: AnimatedSwitcher(
          duration: Motion.fast,
          child: notLink
              ? Container(
                  key: const ValueKey('not'),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(color: const Color(0xCC1F2937), borderRadius: BorderRadius.circular(Radii.xl)),
                  child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(AppIcons.warning, size: 16, color: Color(0xFFFBBF24)),
                    const SizedBox(width: 8),
                    Flexible(child: Text(s(screen.notLinkKey), style: const TextStyle(color: Colors.white, fontSize: 14))),
                  ]),
                )
              : Text(
                  s('qr_scan_hint'),
                  key: const ValueKey('hint'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.82), fontSize: 14.5),
                ),
        ),
      ),
      Positioned(
        left: 24,
        right: 24,
        bottom: 24 + MediaQuery.paddingOf(context).bottom,
        child: Center(
          child: TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(AppIcons.numpad, size: 18),
            label: Text(s(screen.bottomKey)),
          ),
        ),
      ),
    ]);
  }
}

class _WindowPainter extends CustomPainter {
  _WindowPainter(this.window);
  final Rect window;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(window, const Radius.circular(22));
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(r);
    canvas.drawPath(outside, Paint()..color = Colors.black.withValues(alpha: 0.55));
    canvas.drawRRect(r, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: 0.35));
    // corner marks
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..color = LC.primary;
    const len = 30.0, rad = 22.0;
    final w = window;
    for (final (cx, cy, sx, sy) in [(w.left, w.top, 1.0, 1.0), (w.right, w.top, -1.0, 1.0), (w.left, w.bottom, 1.0, -1.0), (w.right, w.bottom, -1.0, -1.0)]) {
      final path = Path()
        ..moveTo(cx, cy + sy * len)
        ..lineTo(cx, cy + sy * rad)
        ..arcToPoint(Offset(cx + sx * rad, cy), radius: const Radius.circular(rad), clockwise: sx * sy > 0)
        ..lineTo(cx + sx * len, cy);
      canvas.drawPath(path, p);
    }
  }

  @override
  bool shouldRepaint(_WindowPainter old) => old.window != window;
}

/// No camera permission / no usable camera: what to do, in plain words.
class QrCameraIssue extends StatelessWidget {
  const QrCameraIssue({super.key, required this.denied, this.backKey = 'qr_scan_type_code'});
  final bool denied;

  /// Label of the "go back and type it instead" button.
  final String backKey;

  static const _ch = MethodChannel('lumora/camera');

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return ColoredBox(
      color: context.lc.bg,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 56, 28, 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SecureHero(
                  icon: AppIcons.camera,
                  tone: denied ? LC.warning : LC.danger,
                  title: s(denied ? 'qr_cam_denied_title' : 'qr_cam_failed_title'),
                  subtitle: s(denied ? 'qr_cam_denied_sub' : 'qr_cam_failed_sub'),
                  compact: true,
                ),
                const SizedBox(height: 26),
                if (denied) ...[
                  SecurePrimaryButton(
                    label: s('qr_cam_open_settings'),
                    icon: AppIcons.settings,
                    onPressed: () => _ch.invokeMethod<bool>('openSettings').catchError((_) => false),
                  ),
                  const SizedBox(height: 10),
                ],
                Center(
                  child: TextButton.icon(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(AppIcons.numpad, size: 18),
                    label: Text(s(backKey)),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
