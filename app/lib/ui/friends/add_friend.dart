import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../theme.dart';
import '../widgets/common.dart';

Future<void> showAddFriend(BuildContext context) {
  if (isDesktop(context)) {
    return showDialog<void>(
      context: context,
      builder: (_) => const Dialog(child: SizedBox(width: 480, child: AddFriendForm())),
    );
  }
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => const Scaffold(body: SafeArea(child: SingleChildScrollView(child: AddFriendForm()))),
  ));
}

class AddFriendForm extends StatefulWidget {
  const AddFriendForm({super.key});
  @override
  State<AddFriendForm> createState() => _AddFriendFormState();
}

class _AddFriendFormState extends State<AddFriendForm> {
  final _id = TextEditingController();
  final _note = TextEditingController();
  int _tab = 0;
  bool _busy = false;
  String? _error;
  List<Map<String, dynamic>>? _found;

  @override
  void dispose() {
    _id.dispose();
    _note.dispose();
    super.dispose();
  }

  String get _raw => _id.text.replaceAll(RegExp(r'\s'), '').toLowerCase();
  bool get _isHandle => _id.text.trim().startsWith('@') && _id.text.trim().length > 3;
  bool get _valid => RegExp(r'^\d{9}$').hasMatch(_raw) || RegExp(r'^[a-z2-7]{52}$').hasMatch(_raw) || (_isHandle && (_found?.isNotEmpty ?? false));

  Future<void> _lookup() async {
    if (_isHandle) {
      try {
        final r = await context.read<LumoraApi>().resolveUsername(_id.text.trim().substring(1));
        if (mounted) setState(() => _found = r);
      } catch (_) {
        if (mounted) setState(() => _found = const []);
      }
      return;
    }
    if (!RegExp(r'^\d{9}$').hasMatch(_raw)) {
      setState(() => _found = null);
      return;
    }
    try {
      final r = await context.read<LumoraApi>().lookup(formatShortId(_raw));
      if (mounted) setState(() => _found = r);
    } catch (_) {}
  }

  Future<void> _send() async {
    final s = S.read(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final target = _isHandle ? _found!.first['peer'].toString() : (_raw.length == 9 ? formatShortId(_raw) : _raw);
      await context.read<ContactsStore>().add(target, note: _note.text.trim().isEmpty ? null : _note.text.trim());
      if (!mounted) return;
      Navigator.of(context).maybePop();
      toast(context, s('request_sent_toast'));
    } catch (e) {
      setState(() => _error = errorMessage(S.read(context), e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PaneHeader(title: Text(s('add_friend')), onBack: () => Navigator.of(context).maybePop()),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        child: SegmentedButton<int>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: 0, icon: const Icon(AppIcons.keypad, size: 18), label: Text(s('enter_id'))),
            ButtonSegment(value: 1, icon: const Icon(AppIcons.qrCode, size: 18), label: Text(s('my_qr'))),
          ],
          selected: {_tab},
          onSelectionChanged: (v) => setState(() => _tab = v.first),
        ),
      ),
      AnimatedSize(
        duration: Motion.normal,
        curve: Motion.curve,
        alignment: Alignment.topCenter,
        child: _tab == 1
            ? const Padding(padding: EdgeInsets.all(20), child: MyIdCard(compact: true))
            : Padding(
                padding: const EdgeInsets.all(20),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(s('add_friend_hint'), style: context.tt.bodySmall?.copyWith(height: 1.5)),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _id,
                    autofocus: true,
                    style: const TextStyle(fontSize: 18, letterSpacing: 1.2, fontWeight: FontWeight.w600),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9a-zA-Z @_·]')), LengthLimitingTextInputFormatter(60)],
                    onChanged: (_) {
                      setState(() => _error = null);
                      _lookup();
                    },
                    decoration: InputDecoration(
                      hintText: '123 456 789',
                      labelText: s('friend_id'),
                      prefixIcon: const Icon(AppIcons.channel),
                      suffixIcon: IconButton(
                        tooltip: s('paste'),
                        icon: const Icon(AppIcons.paste, size: 20),
                        onPressed: () async {
                          final d = await Clipboard.getData('text/plain');
                          if (d?.text != null) {
                            _id.text = d!.text!.trim();
                            setState(() {});
                            _lookup();
                          }
                        },
                      ),
                    ),
                  ),
                  if (_found != null && _found!.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    LCard(
                      padding: const EdgeInsets.all(10),
                      child: Row(children: [
                        Avatar(name: '${_found!.first['name']}', seed: '${_found!.first['peer']}', size: 36),
                        const SizedBox(width: 10),
                        Expanded(child: Text('${_found!.first['name']}', style: context.tt.titleSmall)),
                        const Icon(AppIcons.checkCircle, color: LC.success, size: 20),
                      ]),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: _note,
                    maxLength: 120,
                    decoration: InputDecoration(labelText: s('friend_note'), hintText: s('friend_note_hint'), counterText: ''),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(_error!, style: const TextStyle(color: LC.danger)),
                  ],
                  const SizedBox(height: 18),
                  GradientButton(
                    label: s('send_request'),
                    icon: AppIcons.send,
                    expand: true,
                    busy: _busy,
                    onPressed: _valid ? _send : null,
                  ),
                ]),
              ),
      ),
    ]);
  }
}

/// "My ID" card with QR code (encodes a lumora:// add link).
class MyIdCard extends StatelessWidget {
  const MyIdCard({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final me = context.select<SessionStore, Me?>((x) => x.me);
    if (me == null) return const SizedBox.shrink();
    final link = 'lumora://add/${me.peer}?id=${me.shortId.replaceAll(' ', '')}';
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (!compact) ...[
        Text(s('your_id'), style: context.tt.titleMedium),
        const SizedBox(height: 4),
        Text(s('your_id_hint'), style: context.tt.bodySmall?.copyWith(height: 1.45)),
        const SizedBox(height: 16),
      ],
      Center(
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(Radii.lg)),
          child: QrImageView(
            data: link,
            size: compact ? 180 : 200,
            padding: EdgeInsets.zero,
            eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.circle, color: Color(0xFF14162B)),
            dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.circle, color: Color(0xFF2B2470)),
          ),
        ),
      ),
      const SizedBox(height: 16),
      Center(
        child: Text(me.shortId,
            style: context.tt.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 2, fontFeatures: const [FontFeature.tabularFigures()])),
      ),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => copyText(context, me.shortId),
            icon: const Icon(AppIcons.copy, size: 17),
            label: Text(s('copy_id')),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => copyText(context, me.peer),
            icon: const Icon(AppIcons.key, size: 17),
            label: Text(s('copy_long_id')),
          ),
        ),
      ]),
    ]);
  }
}
