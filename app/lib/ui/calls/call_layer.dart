import 'dart:math' as math;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../platform/camera_bridge.dart';
import '../../state/app_lock.dart';
import '../../state/settings.dart';
import '../../state/stores.dart';
import '../theme.dart';
import '../widgets/peer_avatar.dart';
import '../widgets/common.dart';
import '../chats/chat_view.dart';
import '../flows.dart';
import '../shell/reminder_banner.dart' show appNavigatorKey;
import '../../platform/android_bridge.dart';
import 'call_effects.dart';
import '../devices/answered_elsewhere.dart';
import 'video_view.dart';
import 'video_codec_note.dart';

/// Global layer above the app: incoming-call overlay, full call screen or
/// minimised call pill.
class CallLayer extends StatelessWidget {
  const CallLayer({super.key});

  @override
  Widget build(BuildContext context) {
    final phase = context.select<CallStore, CallPhase?>((c) => c.call?.phase);
    final minimized = context.select<CallStore, bool>((c) => c.minimized);
    final ready = context.select<SessionStore, bool>((s) => s.phase == SessionPhase.ready);
    if (phase == null || !ready) return const SizedBox.shrink();
    if (phase == CallPhase.incoming) return const Positioned.fill(child: LayerHost(key: ValueKey('incoming'), child: IncomingCallOverlay()));
    // Android picture-in-picture (Lumora left during a video call): a tiny window — the
    // other person's video only, no controls.
    final size = MediaQuery.sizeOf(context);
    final video = context.select<CallStore, bool>((c) => c.call?.video ?? false);
    if (video && phase == CallPhase.active && size.shortestSide > 0 && size.shortestSide < 260) {
      return const Positioned.fill(child: _PipVideo());
    }
    // A minimised video call: a small floating video window (Messenger-style), voice: the pill.
    if (minimized && video && phase == CallPhase.active) return const _FloatingVideo();
    // Below the status bar: Android hands touches there to the system (pull-down
    // shade), so the pill and its hang-up button could not be tapped on phones.
    if (minimized) return Positioned(top: math.max(12, MediaQuery.paddingOf(context).top + 6), left: 0, right: 0, child: const Center(child: _CallPill()));
    // Back on the call screen (nothing open on it): back to the app, the call
    // goes on in the pill — not Lumora sent to the background.
    return const Positioned.fill(child: LayerHost(key: ValueKey('call'), onBack: _minimizeCall, child: CallScreen()));
  }
}

bool _minimizeCall(BuildContext context) {
  final store = context.read<CallStore>();
  if (store.chatOpen) {
    store.toggleChat(); // the in-call chat panel closes first
  } else {
    store.setMinimized(true);
  }
  return true;
}

class _Pulse extends StatefulWidget {
  const _Pulse({required this.child, this.size = 120});
  final Widget child;
  final double size;
  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return SizedBox(
      width: s * 1.9,
      height: s * 1.9,
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, child) => Stack(alignment: Alignment.center, children: [
            for (var i = 0; i < 2; i++)
              Builder(builder: (_) {
                final t = (_c.value + i * 0.5) % 1.0;
                return Container(
                  width: s * (1 + 0.85 * t),
                  height: s * (1 + 0.85 * t),
                  decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: LC.accent.withValues(alpha: (1 - t) * 0.5), width: 2)),
                );
              }),
            child!,
          ]),
          child: widget.child,
        ),
      ),
    );
  }
}

class IncomingCallOverlay extends StatelessWidget {
  const IncomingCallOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final call = context.select<CallStore, CallState?>((c) => c.call);
    if (call == null) return const SizedBox.shrink();
    final contacts = context.read<ContactsStore>();
    final chat = context.read<ChatStore>();
    // A locked chat never shows who is calling until it is opened.
    final hidden = context.read<AppLock>().isChatHidden(call.conv);
    final name = hidden ? s('locked_incoming_call') : (call.conv.startsWith('g:') ? (chat.convs[call.conv]?.title ?? '') : contacts.nameOf(call.peer));
    final store = context.read<CallStore>();
    final desktop = isDesktop(context);
    final answerError = context.select<CallStore, Object?>((c) => c.answerError);
    // answered on another of my devices: a short note instead of the buttons
    final elsewhere = context.select<CallStore, String?>((c) => c.answeredElsewhere);
    final content = Column(mainAxisSize: MainAxisSize.min, children: [
      _Pulse(
        size: 108,
        child: hidden
            ? const CircleAvatar(radius: 54, backgroundColor: Colors.white24, child: Icon(AppIcons.lock, size: 40, color: Colors.white))
            : PeerAvatar(peer: call.peer, fallbackName: name, size: 108, presence: false),
      ),
      Text(name, style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w700), textAlign: TextAlign.center),
      const SizedBox(height: 8),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(call.video ? AppIcons.video : AppIcons.call, size: 16, color: Colors.white70),
        const SizedBox(width: 6),
        Text(call.video ? s('incoming_video_call') : s('incoming_voice_call'), style: const TextStyle(color: Colors.white70, fontSize: 15)),
      ]),
      const SizedBox(height: 10),
      Pill(s('e2e_short'), color: LC.success, icon: AppIcons.lock),
      SizedBox(height: desktop ? 32 : 48),
      if (answerError != null) ...[
        Text(errorMessage(s, answerError, fallbackKey: 'call_answer_failed'), textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 14)),
        const SizedBox(height: 16),
      ],
      if (elsewhere != null) AnsweredElsewhereNote(device: elsewhere),
      if (!desktop && elsewhere == null) ...[
        Text(s('slide_to_answer'), style: const TextStyle(color: Colors.white60, fontSize: 13)),
        const SizedBox(height: 10),
        _SlideToAnswer(label: s('slide_to_answer'), onAccept: () => store.answer(true), onDecline: () => store.answer(false)),
        const SizedBox(height: 28),
      ],
      if (elsewhere == null) Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, mainAxisSize: desktop ? MainAxisSize.min : MainAxisSize.max, children: [
        _RoundAction(icon: AppIcons.hangUp, color: LC.danger, label: s('decline'), onTap: () => store.answer(false)),
        if (desktop) const SizedBox(width: 28),
        _RoundAction(icon: AppIcons.chat, color: Colors.white24, label: s('reply_message'), onTap: () {
          // decline, then open the chat with the caller — on phones as its own page (the
          // call screen sits above the app's navigator, so push through the app's key)
          final conv = call.conv;
          final phone = !isDesktop(context);
          store.answer(false);
          context.read<NavStore>().openConv(conv);
          if (phone) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              appNavigatorKey.currentState?.push(MaterialPageRoute<void>(builder: (_) => ChatView(conv: conv)));
            });
          }
        }),
        if (call.video) ...[
          if (desktop) const SizedBox(width: 28),
          _RoundAction(
            icon: AppIcons.call,
            color: Colors.white24,
            label: s('audio_only'),
            onTap: () {
              store.answer(true);
              store.toggle(cam: false);
            },
          ),
        ],
        if (desktop) ...[
          const SizedBox(width: 28),
          _RoundAction(icon: call.video ? AppIcons.video : AppIcons.call, color: LC.success, label: s('accept'), onTap: () => store.answer(true)),
        ],
      ]),
    ]);
    return Material(
      color: Colors.black,
      child: Stack(fit: StackFit.expand, children: [
        // Blurred avatar backdrop.
        Transform.scale(
          scale: 1.4,
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 40, sigmaY: 40),
            child: FittedBox(fit: BoxFit.cover, child: PeerAvatar(peer: call.peer, fallbackName: name, size: 200, presence: false)),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xCC0F1020), Color(0xEE0A0B16)]),
          ),
        ),
        SafeArea(child: Center(child: Padding(padding: const EdgeInsets.all(24), child: content))),
      ]),
    );
  }
}

/// Mobile slide-to-answer track: drag right to accept, left to decline.
class _SlideToAnswer extends StatefulWidget {
  const _SlideToAnswer({required this.label, required this.onAccept, required this.onDecline});
  final String label;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  @override
  State<_SlideToAnswer> createState() => _SlideToAnswerState();
}

class _SlideToAnswerState extends State<_SlideToAnswer> {
  double _dx = 0;
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth.clamp(240.0, 340.0);
      const knob = 60.0;
      final maxDx = (w - knob) / 2 - 6;
      final t = (_dx / maxDx).clamp(-1.0, 1.0);
      return Container(
        width: w,
        height: knob + 12,
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(40), border: Border.all(color: Colors.white12)),
        child: Stack(alignment: Alignment.center, children: [
          Opacity(
            opacity: (1 - t.abs()).clamp(0.0, 1.0),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Row(children: [
                Icon(AppIcons.hangUp, color: Color(0x99EF4444), size: 20),
                SizedBox(width: 6),
                Icon(AppIcons.chevronsLeft, color: Colors.white38, size: 18),
                Spacer(),
                Icon(AppIcons.chevronsRight, color: Colors.white38, size: 18),
                SizedBox(width: 6),
                Icon(AppIcons.call, color: Color(0x9922C55E), size: 20),
              ]),
            ),
          ),
          Transform.translate(
            offset: Offset(_dx, 0),
            child: GestureDetector(
              onHorizontalDragUpdate: (d) => setState(() => _dx = (_dx + d.delta.dx).clamp(-maxDx, maxDx)),
              onHorizontalDragEnd: (_) {
                if (_dx > maxDx * 0.8) {
                  HapticFeedback.mediumImpact();
                  widget.onAccept();
                } else if (_dx < -maxDx * 0.8) {
                  widget.onDecline();
                }
                setState(() => _dx = 0);
              },
              child: Container(
                width: knob,
                height: knob,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color.lerp(Color.lerp(Colors.white, LC.success, t.clamp(0, 1))!, LC.danger, (-t).clamp(0, 1)),
                ),
                child: Icon(t < -0.2 ? AppIcons.hangUp : AppIcons.call, color: t.abs() > 0.2 ? Colors.white : LC.success),
              ),
            ),
          ),
        ]),
      );
    });
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({required this.icon, required this.color, required this.label, required this.onTap});
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;
  static const size = 60.0;
  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
        Tooltip(
          message: label,
          child: Material(
            color: color,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox(width: size, height: size, child: Icon(icon, color: Colors.white, size: size * 0.43)),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: LC.darkMuted, fontSize: 12.5)),
      ]);
}

class CallScreen extends StatelessWidget {
  const CallScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final store = context.watch<CallStore>();
    final call = store.call;
    if (call == null) return const SizedBox.shrink();
    final me = context.read<SessionStore>().me;
    final contacts = context.read<ContactsStore>();
    final chat = context.read<ChatStore>();
    final group = call.conv.startsWith('g:');
    final title = group ? (chat.convs[call.conv]?.title ?? '') : contacts.nameOf(call.peer);
    final active = call.phase == CallPhase.active;
    final beauty = context.select<Settings, int>((x) => x.videoBeauty) > 0;
    final cam = _cameraOf(context);
    final bridge = cam;
    // The core's self-view is mirrored; un-mirror it for the back camera.
    final flipSelf = cam != null && cam.flipSelfView;

    Widget stage;
    final screens = store.liveScreenStreams;
    if (screens.isNotEmpty) {
      // Someone shares a screen: big screen view + camera strip.
      final sp = screens.entries.first;
      stage = Padding(
        padding: const EdgeInsets.fromLTRB(16, 80, 16, 120),
        child: Column(children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Radii.lg),
              child: ColoredBox(color: Colors.black, child: VideoView(stream: sp.value, fit: BoxFit.contain, placeholder: const Center(child: CircularProgressIndicator()))),
            ),
          ),
          const SizedBox(height: 8),
          Text(s('screen_of', {'name': sp.key == me?.peer ? s('you') : _participantName(contacts, call, sp.key)}), style: const TextStyle(color: Colors.white70)),
        ]),
      );
    } else if (!group) {
      // Only a stream the core announced for this peer: guessing an id could
      // show another stream (e.g. our own self-view) when they have no camera.
      // (by account: a friend on a linked device sends frames under that device's key)
      final remoteStream = call.streamOf(call.peer);
      stage = Stack(children: [
        Positioned.fill(
          child: call.video && active && remoteStream != null
              ? VideoView(stream: remoteStream, placeholder: _AvatarStage(name: title, seed: call.peer, active: active))
              : _AvatarStage(name: title, seed: call.peer, active: active),
        ),
        if (call.video && store.cam)
          Positioned(
            right: 20,
            bottom: 120,
            child: _Pip(
              child: Stack(fit: StackFit.expand, children: [
                VideoView(
                  stream: call.streams[me?.peer] ?? 0,
                  maxFps: 30,
                  flipX: flipSelf,
                  placeholder: Center(child: PeerAvatar(peer: me?.peer ?? '', size: 48, presence: false)),
                ),
                if (beauty) const Positioned(left: 8, top: 8, child: EffectsBadge(size: 22)),
                if (cam != null && cam.canSwitch) Positioned(right: 6, bottom: 6, child: _SwitchCameraButton(camera: cam)),
              ]),
            ),
          ),
      ]);
    } else {
      final parts = [me?.peer ?? '', ...call.participants.where((p) => p != me?.peer)];
      stage = Padding(
        padding: const EdgeInsets.fromLTRB(16, 80, 16, 120),
        child: LayoutBuilder(builder: (context, c) {
          final n = parts.length;
          final cols = n <= 1 ? 1 : (n <= 4 ? 2 : 3);
          final rows = (n / cols).ceil();
          final w = (c.maxWidth - (cols - 1) * 12) / cols;
          final h = (c.maxHeight - (rows - 1) * 12) / rows;
          final aspect = (w / h).clamp(0.6, 2.2);
          return Center(
            child: Wrap(spacing: 12, runSpacing: 12, alignment: WrapAlignment.center, children: [
              for (final p in parts)
                SizedBox(
                  width: math.min(w, h * aspect),
                  height: math.min(h, w / aspect),
                  child: _Tile(
                    name: p == me?.peer ? (me?.name ?? '') : _participantName(contacts, call, p),
                    label: p == me?.peer ? '${me?.name ?? ''} (${s('you')})' : _participantName(contacts, call, p),
                    seed: call.accountOf(p),
                    speaking: call.speaking.contains(p),
                    muted: p == me?.peer ? !store.mic : store.peerMuted(p),
                    video: call.video && (p == me?.peer ? store.cam : !store.peerCamOff(p)) && call.streams.containsKey(p),
                    stream: call.streams[p] ?? -1,
                    effects: beauty && p == me?.peer && store.cam,
                    flip: p == me?.peer && cam != null && cam.flipSelfView,
                    camera: p == me?.peer && cam != null && cam.canSwitch ? cam : null,
                  ),
                ),
            ]),
          );
        }),
      );
    }

    return Material(
      color: const Color(0xFF0A0B16),
      child: Stack(children: [
        Positioned.fill(child: stage),
        // Top bar.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black.withValues(alpha: 0.6), Colors.transparent],
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Row(children: [
                IconButton(
                  tooltip: s('minimize'),
                  onPressed: () => store.setMinimized(true),
                  icon: const Icon(AppIcons.minimize, color: Colors.white),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Row(children: [
                      const Icon(AppIcons.lock, size: 12, color: LC.success),
                      const SizedBox(width: 4),
                      if (active && call.startedAt != null)
                        ElapsedText(since: call.startedAt!, format: s.duration, style: const TextStyle(color: LC.darkMuted, fontSize: 13))
                      else
                        Text(s('calling'), style: const TextStyle(color: LC.darkMuted, fontSize: 13)),
                    ]),
                  ]),
                ),
                if (active)
                  Tooltip(
                    message: [s('call_quality_${call.quality}'), if (store.videoCodec != null) videoCodecLine(s, store.videoCodec!)].join('\n'),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: SignalBars(level: call.quality, color: call.quality >= 3 ? LC.success : LC.warning, height: 16),
                    ),
                  ),
              ]),
            ),
          ),
        ),
        // Floating reactions.
        const Positioned.fill(child: IgnorePointer(child: _ReactionBurst())),
        // Camera permission / problem (the call itself goes on with voice).
        // (Under the top bar, so it never hides the self-view or the controls.)
        if (cam != null && cam.issue != null && call.video && store.cam && active)
          Positioned(
            left: 16,
            right: 16,
            top: 84,
            child: SafeArea(bottom: false, child: Center(child: _CameraNotice(camera: cam, onTurnOff: () => store.toggle(cam: false)))),
          ),
        // Older Lumora on the other side, no H.264 here: no picture, voice goes on.
        if (store.videoNeedsPeerUpdate && active)
          const Positioned(
            left: 16,
            right: 16,
            top: 84,
            child: SafeArea(bottom: false, child: Center(child: VideoPeerUpdateNote())),
          ),
        // In-call chat with the same conversation.
        AnimatedPositioned(
          duration: Motion.normal,
          curve: Motion.curve,
          top: 0,
          bottom: 0,
          right: store.chatOpen ? 0.0 : -(isDesktop(context) ? 380.0 : MediaQuery.sizeOf(context).width),
          width: isDesktop(context) ? 360 : MediaQuery.sizeOf(context).width,
          child: store.chatOpen
              ? Material(
                  elevation: 12,
                  child: Column(children: [
                    // Phones: the chat covers the call — a clear way back to it (the
                    // call's control dock is hidden meanwhile, it sat over the composer)
                    if (!isDesktop(context))
                      SafeArea(
                        bottom: false,
                        child: Material(
                          color: LC.primary,
                          child: InkWell(
                            key: const ValueKey('back_to_call'),
                            onTap: store.toggleChat,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              child: Row(children: [
                                const Icon(AppIcons.back, color: Colors.white, size: 20),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(s('back_to_call'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                                ),
                                const Icon(AppIcons.call, color: Colors.white, size: 18),
                              ]),
                            ),
                          ),
                        ),
                      ),
                    // (no Scaffold in a layer: keep the composer above the keyboard)
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
                        child: MediaQuery.removeViewInsets(context: context, removeBottom: true, child: ChatView(conv: call.conv, embedded: true)),
                      ),
                    ),
                  ]),
                )
              : const SizedBox.shrink(),
        ),
        // Controls (glass dock). Not over the in-call chat on a phone (it hid the composer).
        if (isDesktop(context) || !store.chatOpen)
        Positioned(
          left: 0,
          right: 0,
          bottom: 22,
          child: SafeArea(
            top: false,
            child: Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(36),
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: MediaQuery.sizeOf(context).width < 360 ? 8 : 12, vertical: 10),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [Colors.white.withValues(alpha: 0.10), Colors.white.withValues(alpha: 0.04)]),
                      borderRadius: BorderRadius.circular(36),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                    ),
                    child: Builder(builder: (context) {
                      final desktop = isDesktop(context);
                      final compact = MediaQuery.sizeOf(context).width < 600;
                      final mic = CallControl(icon: store.mic ? AppIcons.mic : AppIcons.micOff, on: store.mic, label: s('ctl_mic'), tip: store.mic ? s('mute_mic') : s('unmute_mic'), onTap: () => store.toggle(mic: !store.mic));
                      final cam = CallControl(icon: store.cam ? AppIcons.video : AppIcons.videoOff, on: store.cam, label: s('ctl_camera'), tip: store.cam ? s('camera_off') : s('camera_on'), onTap: () => store.toggle(cam: !store.cam));
                      final controls = <Widget>[
                        mic,
                        cam,
                        if (desktop)
                          CallControl(
                            icon: store.screen ? AppIcons.screenShareOff : AppIcons.screenShare,
                            on: true,
                            active: store.screen,
                            label: s('ctl_share'),
                            tip: store.screen ? s('stop_share') : s('share_screen'),
                            onTap: () => store.toggle(screen: !store.screen),
                          )
                        else
                          CallControl(icon: store.speaker ? AppIcons.speaker : AppIcons.earpiece, on: true, active: store.speaker, label: s('speaker'), tip: s('speaker'), onTap: store.toggleSpeaker),
                        if (compact)
                          CallControl(
                            icon: AppIcons.more,
                            on: true,
                            active: store.chatOpen || store.handRaised || store.screen,
                            label: s('more'),
                            tip: s('more'),
                            onTap: () => _moreSheet(context, call, group: group),
                          )
                        else ...[
                          if (call.video)
                            CallControl(icon: AppIcons.effects, on: true, active: beauty, label: s('ctl_effects'), tip: s('call_effects'), onTap: () => showCallEffects(context)),
                          if (call.video && bridge != null && bridge.canSwitch)
                            CallControl(icon: AppIcons.switchCamera, on: true, label: s('ctl_camera'), tip: s('cam_switch'), onTap: bridge.switchCamera),
                          if (group)
                            CallControl(icon: AppIcons.raiseHand, on: true, active: store.handRaised, label: s('ctl_hand'), tip: s('raise_hand'), onTap: store.toggleHand),
                          CallControl(icon: AppIcons.chat, on: true, active: store.chatOpen, label: s('chat'), tip: s('call_chat'), onTap: store.toggleChat),
                          CallControl(icon: AppIcons.react, on: true, label: s('ctl_react'), tip: s('react'), onTap: () => _pickReaction(context, call.conv)),
                          CallControl(icon: AppIcons.sliders, on: true, label: s('ctl_audio'), tip: s('call_audio'), onTap: () => showCallAudioSettings(context)),
                          if (desktop && !group) ...[
                            CallControl(icon: AppIcons.remote, on: true, label: s('ctl_control'), tip: s('request_control'), onTap: () => Flows.requestControl(context, call.peer)),
                            CallControl(icon: AppIcons.attach, on: true, label: s('ctl_file'), tip: s('send_file'), onTap: () => Flows.sendFile(context, call.conv)),
                          ],
                        ],
                      ];
                      // Hang up stays pinned outside the scrollable part so it
                      // is always reachable, whatever the window width.
                      return Row(mainAxisSize: MainAxisSize.min, children: [
                        Flexible(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(mainAxisSize: MainAxisSize.min, children: controls),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _EndPill(onTap: store.hangup, tip: s('hang_up')),
                      ]);
                    }),
                  ),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Glass circular call control with press animation and on/off/active states.
class CallControl extends StatefulWidget {
  const CallControl({super.key, required this.icon, required this.on, required this.tip, required this.onTap, this.active = false, this.label});
  final IconData icon;

  /// false = muted/off (inverted white button).
  final bool on;

  /// Accent gradient (e.g. sharing, hand raised).
  final bool active;
  final String tip;
  final String? label;
  final VoidCallback onTap;
  @override
  State<CallControl> createState() => _CallControlState();
}

class _CallControlState extends State<CallControl> {
  bool _down = false;
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final off = !widget.on;
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 420;
    // Small phones (320 dp): every control incl. "More" and hang-up fits.
    final tiny = width < 360;
    final d = tiny ? 44.0 : (compact ? 50.0 : 54.0);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tiny ? 2 : (compact ? 3 : 5)),
      child: Tooltip(
        message: widget.tip,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTapDown: (_) => setState(() => _down = true),
            onTapCancel: () => setState(() => _down = false),
            onTapUp: (_) {
              setState(() => _down = false);
              HapticFeedback.selectionClick();
              widget.onTap();
            },
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              AnimatedScale(
                scale: _down ? 0.9 : (_hover ? 1.06 : 1),
                duration: Motion.fast,
                child: AnimatedContainer(
                  duration: Motion.normal,
                  width: d,
                  height: d,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.active ? LC.primary : (off ? Colors.white : Colors.white.withValues(alpha: _hover ? 0.20 : 0.12)),
                    border: Border.all(color: Colors.white.withValues(alpha: off || widget.active ? 0 : 0.14)),
                    boxShadow: kNoShadows || !widget.active ? null : [BoxShadow(color: LC.primary.withValues(alpha: 0.45), blurRadius: 16)],
                  ),
                  // Filled cut: reads as a solid control on the dark stage.
                  child: Center(
                    child: SizedBox.square(
                      dimension: 24,
                      child: Icon(AppIcons.fill(widget.icon), size: 24, color: off ? const Color(0xFF14162B) : Colors.white),
                    ),
                  ),
                ),
              ),
              if (widget.label != null) ...[
                const SizedBox(height: 4),
                // Fixed slot so every control is spaced the same whatever its label.
                SizedBox(
                  width: d + (tiny ? 8 : 14),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(widget.label!, maxLines: 1, softWrap: false, style: const TextStyle(color: Colors.white70, fontSize: 11)),
                  ),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

class _EndPill extends StatefulWidget {
  const _EndPill({required this.onTap, required this.tip});
  final VoidCallback onTap;
  final String tip;
  @override
  State<_EndPill> createState() => _EndPillState();
}

class _EndPillState extends State<_EndPill> {
  bool _down = false;
  @override
  Widget build(BuildContext context) => Tooltip(
        message: widget.tip,
        child: GestureDetector(
          onTapDown: (_) => setState(() => _down = true),
          onTapCancel: () => setState(() => _down = false),
          onTapUp: (_) {
            setState(() => _down = false);
            widget.onTap();
          },
          child: AnimatedScale(
            scale: _down ? 0.92 : 1,
            duration: Motion.fast,
            child: Container(
              width: MediaQuery.sizeOf(context).width < 360 ? 60 : 76,
              height: MediaQuery.sizeOf(context).width < 360 ? 48 : 54,
              margin: const EdgeInsets.only(bottom: 15),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [Color(0xFFFF5A5A), Color(0xFFE11D48)]),
                borderRadius: BorderRadius.circular(27),
                boxShadow: kNoShadows ? null : [BoxShadow(color: LC.danger.withValues(alpha: 0.45), blurRadius: 16, offset: const Offset(0, 4))],
              ),
              child: const Center(child: SizedBox.square(dimension: 26, child: Icon(AppIcons.hangUpFill, color: Colors.white, size: 26))),
            ),
          ),
        ),
      );
}

class _AvatarStage extends StatelessWidget {
  const _AvatarStage({required this.name, required this.seed, required this.active});
  final String name;
  final String seed;
  final bool active;
  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(center: Alignment(0, -0.2), radius: 1.1, colors: [Color(0xFF2B2470), Color(0xFF0A0B16)]),
      ),
      child: Center(
        child: active
            ? _SpeakingRing(peer: seed, child: PeerAvatar(peer: seed, fallbackName: name, size: 132, presence: false))
            : _Pulse(size: 132, child: PeerAvatar(peer: seed, fallbackName: name, size: 132, presence: false)),
      ),
    );
  }
}

class _Pip extends StatelessWidget {
  const _Pip({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final mobile = !isDesktop(context);
    return Container(
      width: mobile ? 110 : 220,
      height: mobile ? 160 : 124,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2), width: 1.5),
        boxShadow: kNoShadows ? null : const [BoxShadow(color: Colors.black54, blurRadius: 16)],
      ),
      clipBehavior: Clip.antiAlias,
      child: ColoredBox(color: const Color(0xFF1F2340), child: child),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.name, required this.label, required this.seed, required this.speaking, required this.muted, required this.video, required this.stream, this.effects = false, this.flip = false, this.camera});
  final String name;
  final String label;
  final String seed;
  final bool speaking;
  final bool muted;
  final bool video;
  final int stream;

  /// Own tile with "Làm đẹp" on: shows the sparkle badge.
  final bool effects;

  /// Own tile on the back camera: undo the self-view mirror.
  final bool flip;

  /// Own tile with several cameras: front/back switch button.
  final CameraBridge? camera;
  @override
  Widget build(BuildContext context) {
    final avatar = ColoredBox(
      color: const Color(0xFF1F2340),
      child: Center(child: LayoutBuilder(builder: (_, c) => PeerAvatar(peer: seed, fallbackName: name, size: math.min(96, c.maxHeight * 0.4), presence: false))),
    );
    return AnimatedContainer(
      duration: Motion.fast,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: speaking ? LC.success : Colors.white.withValues(alpha: 0.06), width: speaking ? 3 : 1),
        boxShadow: kNoShadows || !speaking ? null : [BoxShadow(color: LC.success.withValues(alpha: 0.35), blurRadius: 16)],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(fit: StackFit.expand, children: [
        video ? VideoView(stream: stream, maxFps: 30, flipX: flip, placeholder: avatar) : avatar,
        if (effects && video) const Positioned(left: 10, top: 10, child: EffectsBadge()),
        if (camera != null && video) Positioned(right: 8, top: 8, child: _SwitchCameraButton(camera: camera!)),
        Positioned(
          left: 10,
          right: 10,
          bottom: 10,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(Radii.sm)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (muted) ...[const Icon(AppIcons.micOff, size: 14, color: LC.danger), const SizedBox(width: 4)],
              if (speaking && !muted) ...[const Icon(AppIcons.voice, size: 14, color: LC.success), const SizedBox(width: 4)],
              Flexible(
                child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
          ),
        ),
      ]),
    );
  }
}

class _CallPill extends StatelessWidget {
  const _CallPill();
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final store = context.watch<CallStore>();
    final call = store.call!;
    final contacts = context.read<ContactsStore>();
    final name = call.conv.startsWith('g:') ? (context.read<ChatStore>().convs[call.conv]?.title ?? '') : contacts.nameOf(call.peer);
    return Material(
      color: LC.success,
      borderRadius: BorderRadius.circular(24),
      elevation: 6,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => store.setMinimized(false),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(AppIcons.call, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            if (call.startedAt != null)
              ElapsedText(since: call.startedAt!, format: s.duration, style: const TextStyle(color: Colors.white70))
            else
              Text(s('calling'), style: const TextStyle(color: Colors.white70)),
            const SizedBox(width: 6),
            InkWell(
              customBorder: const CircleBorder(),
              onTap: store.hangup,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: const BoxDecoration(color: LC.danger, shape: BoxShape.circle),
                child: const Icon(AppIcons.hangUp, color: Colors.white, size: 16),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}


/// Animated ring around a participant while they are speaking.
class _SpeakingRing extends StatelessWidget {
  const _SpeakingRing({required this.peer, required this.child});
  final String peer;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final speaking = context.select<CallStore, bool>((c) => c.call?.speaking.contains(peer) ?? false);
    return AnimatedContainer(
      duration: Motion.normal,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: speaking ? LC.success : Colors.transparent, width: 3),
        boxShadow: kNoShadows || !speaking ? null : [BoxShadow(color: LC.success.withValues(alpha: 0.45), blurRadius: 28, spreadRadius: 4)],
      ),
      child: child,
    );
  }
}


/// Secondary call actions on narrow screens.
Future<void> _moreSheet(BuildContext context, CallState call, {required bool group}) async {
  final s = S.read(context);
  final store = context.read<CallStore>();
  final cam = _cameraOf(context, listen: false);
  final desktop = isDesktop(context);
  Widget item(BuildContext c, IconData icon, String label, VoidCallback onTap, {bool active = false}) => ListTile(
        leading: Icon(icon, color: active ? LC.primary : null),
        title: Text(label),
        trailing: active ? const Icon(AppIcons.check, color: LC.primary, size: 18) : null,
        onTap: () {
          Navigator.pop(c);
          onTap();
        },
      );
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 480),
    builder: (c) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (call.video && cam != null && cam.canSwitch) item(c, AppIcons.switchCamera, s('cam_switch'), cam.switchCamera),
        if (call.video) item(c, AppIcons.effects, s('call_effects'), () => showCallEffects(context), active: context.read<Settings>().videoBeauty > 0),
        // Phones: the dock has no share button (desktop only) — sharing (Android:
        // MediaProjection) is started and stopped from here.
        if (!desktop && AndroidBridge.isAndroid)
          item(c, store.screen ? AppIcons.screenShareOff : AppIcons.screenShare, store.screen ? s('stop_share') : s('share_screen'),
              () => store.toggle(screen: !store.screen), active: store.screen),
        item(c, AppIcons.chat, s('call_chat'), store.toggleChat, active: store.chatOpen),
        item(c, AppIcons.react, s('react'), () => _pickReaction(context, call.conv)),
        item(c, AppIcons.sliders, s('call_audio'), () => showCallAudioSettings(context)),
        if (group) item(c, AppIcons.raiseHand, s('raise_hand'), store.toggleHand, active: store.handRaised),
        if (desktop && !group) ...[
          item(c, AppIcons.remote, s('request_control'), () => Flows.requestControl(context, call.peer)),
          item(c, AppIcons.attach, s('send_file'), () => Flows.sendFile(context, call.conv)),
        ],
        const SizedBox(height: 8),
      ]),
    ),
  );
}

/// In-call sound settings: noise suppression and echo cancellation
/// (applied by the core within half a second, no need to hang up).
Future<void> showCallAudioSettings(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (c) {
        final s = S.of(c);
        final st = c.watch<Settings>();
        return SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 8), child: Text(s('call_audio'), style: c.tt.titleMedium)),
            SwitchListTile(
              secondary: const Icon(AppIcons.voiceWave),
              title: Text(s('noise_suppression')),
              subtitle: Text(s('noise_suppression_hint')),
              value: st.noiseSuppression,
              onChanged: (v) => st.update((x) => x.noiseSuppression = v),
            ),
            SwitchListTile(
              secondary: const Icon(AppIcons.voice),
              title: Text(s('echo_cancel')),
              subtitle: Text(s('echo_cancel_hint')),
              value: st.echoCancel,
              onChanged: (v) => st.update((x) => x.echoCancel = v),
            ),
            const SizedBox(height: 8),
          ]),
        );
      },
    );

const _callReactions = ['👍', '❤️', '😂', '👏', '🎉', '😮'];

Future<void> _pickReaction(BuildContext context, String conv) async {
  final calls = context.read<CallStore>();
  final chat = context.read<ChatStore>();
  final e = await showModalBottomSheet<String>(
    context: context,
    constraints: const BoxConstraints(maxWidth: 420),
    builder: (c) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          for (final r in _callReactions)
            InkWell(
              borderRadius: BorderRadius.circular(24),
              onTap: () => Navigator.pop(c, r),
              child: Padding(padding: const EdgeInsets.all(8), child: Text(r, style: const TextStyle(fontSize: 30))),
            ),
        ]),
      ),
    ),
  );
  if (e == null) return;
  calls.burst(e);
  chat.send(conv, e).catchError((_) => chat.thread(conv).messages.first);
}

/// Emojis floating up over the call stage.
class _ReactionBurst extends StatelessWidget {
  const _ReactionBurst();
  @override
  Widget build(BuildContext context) {
    final items = context.select<CallStore, List<(int, String)>>((c) => List.of(c.bursts));
    return Stack(children: [
      for (final (id, e) in items)
        TweenAnimationBuilder<double>(
          key: ValueKey(id),
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 2200),
          curve: Curves.easeOut,
          builder: (context, t, _) => Positioned(
            left: MediaQuery.sizeOf(context).width * (0.3 + (id % 5) * 0.1),
            bottom: 120 + 360 * t,
            child: Opacity(opacity: (1 - t).clamp(0.0, 1.0), child: Text(e, style: TextStyle(fontSize: 36 + 12 * t))),
          ),
        ),
    ]);
  }
}


/// The camera bridge, or null where it isn't provided (widget tests, demo).
CameraBridge? _cameraOf(BuildContext context, {bool listen = true}) {
  try {
    return Provider.of<CameraBridge>(context, listen: listen);
  } on ProviderNotFoundException {
    return null;
  }
}

/// Small round "switch camera" button on the self-view.
class _SwitchCameraButton extends StatelessWidget {
  const _SwitchCameraButton({required this.camera});
  final CameraBridge camera;
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: S.of(context)('cam_switch'),
      child: Material(
        color: Colors.black.withValues(alpha: 0.45),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: camera.switchCamera,
          child: const Padding(padding: EdgeInsets.all(7), child: Icon(AppIcons.switchCamera, color: Colors.white, size: 18)),
        ),
      ),
    );
  }
}

/// Friendly card when the camera can't run: explains why in plain words and
/// offers the one action that fixes it (allow / open settings / try again).
class _CameraNotice extends StatelessWidget {
  const _CameraNotice({required this.camera, required this.onTurnOff});
  final CameraBridge camera;
  final VoidCallback onTurnOff;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final (String title, String body, String? action, VoidCallback? onAction) = switch (camera.issue!) {
      CameraIssue.ask => (s('cam_ask_title'), s('cam_ask_body'), s('cam_allow'), camera.allow),
      CameraIssue.denied => (s('cam_denied_title'), s('cam_denied_body'), s('cam_allow'), camera.allow),
      CameraIssue.blocked => (s('cam_blocked_title'), s('cam_blocked_body'), s('cam_open_settings'), camera.openSettings),
      CameraIssue.busy => (s('cam_failed'), s('cam_busy'), s('cam_retry'), camera.retry),
      CameraIssue.none => (s('cam_none'), '', null, null),
      CameraIssue.failed => (s('cam_failed'), '', s('cam_retry'), camera.retry),
    };
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.lg),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(Radii.lg),
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(AppIcons.videoOff, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Expanded(child: Text(title, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700))),
              ]),
              if (body.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(body, style: const TextStyle(color: Colors.white70, fontSize: 13.5, height: 1.35)),
              ],
              const SizedBox(height: 6),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(onPressed: onTurnOff, style: TextButton.styleFrom(foregroundColor: Colors.white70), child: Text(s('cam_turn_off'))),
                if (action != null) ...[
                  const SizedBox(width: 4),
                  FilledButton(onPressed: onAction, child: Text(action)),
                ],
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A call participant's name: the name I saved for their account (they may
/// be on a linked device), else the one the core knows, else a short id.
String _participantName(ContactsStore contacts, CallState call, String participant) {
  final account = call.accountOf(participant);
  final saved = contacts[account]?.displayName ?? '';
  if (saved.isNotEmpty) return saved;
  final known = call.names[participant] ?? '';
  return known.isNotEmpty ? known : contacts.nameOf(account);
}


/// The other person's video, or their avatar (picture-in-picture, floating window).
class _RemoteVideo extends StatelessWidget {
  const _RemoteVideo();
  @override
  Widget build(BuildContext context) {
    final store = context.watch<CallStore>();
    final call = store.call;
    if (call == null) return const ColoredBox(color: Colors.black);
    final stream = call.streamOf(call.peer);
    final avatar = ColoredBox(color: Colors.black, child: Center(child: PeerAvatar(peer: call.peer, size: 56, presence: false)));
    return ColoredBox(
      color: Colors.black,
      child: stream == null ? avatar : VideoView(stream: stream, maxFps: 30, placeholder: avatar),
    );
  }
}

class _PipVideo extends StatelessWidget {
  const _PipVideo();
  @override
  Widget build(BuildContext context) => const _RemoteVideo();
}

/// Minimised video call inside the app: a draggable window with the other person's video;
/// tap → back to the call, red button → hang up. Snaps to the nearest side.
class _FloatingVideo extends StatefulWidget {
  const _FloatingVideo();
  @override
  State<_FloatingVideo> createState() => _FloatingVideoState();
}

class _FloatingVideoState extends State<_FloatingVideo> {
  Offset? _pos;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final screen = mq.size;
    final w = screen.shortestSide < 600 ? 112.0 : 160.0;
    final h = w * 16 / 9;
    final pad = mq.padding;
    final minX = 8.0, maxX = screen.width - w - 8;
    final minY = pad.top + 8, maxY = screen.height - h - pad.bottom - 80;
    final pos = _pos ?? Offset(maxX, minY + 56);
    final store = context.read<CallStore>();
    return Positioned(
      left: pos.dx.clamp(minX, math.max(minX, maxX)),
      top: pos.dy.clamp(minY, math.max(minY, maxY)),
      child: GestureDetector(
        key: const ValueKey('floating_video'),
        onTap: () => store.setMinimized(false),
        onPanUpdate: (d) => setState(() => _pos = (_pos ?? pos) + d.delta),
        onPanEnd: (_) => setState(() {
          final p = _pos ?? pos;
          _pos = Offset(p.dx + w / 2 < screen.width / 2 ? minX : maxX, p.dy.clamp(minY, math.max(minY, maxY)));
        }),
        child: Material(
          elevation: 10,
          color: Colors.black,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: w,
            height: h,
            child: Stack(children: [
              const Positioned.fill(child: _RemoteVideo()),
              Positioned(
                right: 6,
                bottom: 6,
                child: Material(
                  color: LC.danger,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: store.hangup,
                    // (no Tooltip: the call layer floats outside the app's Overlay)
                    child: Semantics(
                      button: true,
                      label: S.of(context)('hang_up'),
                      child: const Padding(padding: EdgeInsets.all(7), child: Icon(AppIcons.hangUp, color: Colors.white, size: 16)),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
