import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/api.dart';
import '../../core/links.dart';
import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../devices/qr_scan.dart' show lumoraQrScanner;
import '../flows.dart';

/// Creates an invite link and shows it with QR + copy.
Future<void> showInvite(BuildContext context, {required String gid, required String name}) {
  return showDialog<void>(context: context, builder: (_) => Dialog(child: SizedBox(width: 420, child: _InviteView(gid: gid, name: name))));
}

class _InviteView extends StatefulWidget {
  const _InviteView({required this.gid, required this.name});
  final String gid;
  final String name;
  @override
  State<_InviteView> createState() => _InviteViewState();
}

class _InviteViewState extends State<_InviteView> {
  int _hours = 24;
  String? _link;
  String? _error;

  @override
  void initState() {
    super.initState();
    _create();
  }

  Future<void> _create() async {
    setState(() {
      _link = null;
      _error = null;
    });
    try {
      // shared as https on Lumora's site: any camera / chat app can open it
      final l = LumoraLink.shareInvite(await context.read<LumoraApi>().createInvite(widget.gid, hours: _hours));
      if (mounted) setState(() => _link = l);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(S.read(context), e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(s('invite_to', {'name': widget.name}), style: context.tt.titleLarge),
        const SizedBox(height: 4),
        Text(s('invite_hint'), style: context.tt.bodySmall),
        const SizedBox(height: 16),
        Center(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(Radii.lg)),
            child: SizedBox(
              width: 180,
              height: 180,
              child: _link == null
                  ? Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!, style: const TextStyle(color: LC.danger)))
                  : QrImageView(
                      key: ValueKey('qr:$_link'),
                      data: _link!,
                      padding: EdgeInsets.zero,
                      eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.circle, color: Color(0xFF14162B)),
                      dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.circle, color: Color(0xFF2B2470)),
                    ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          decoration: BoxDecoration(color: context.lc.surface2, borderRadius: BorderRadius.circular(Radii.md)),
          child: Row(children: [
            Expanded(
              child: SelectableText(_link ?? '…', maxLines: 1, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
            ),
            IconButton(onPressed: _link == null ? null : () => copyText(context, _link!), icon: const Icon(AppIcons.copy, size: 18), tooltip: s('copy')),
          ]),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Text(s('invite_expires'), style: context.tt.bodySmall),
          const Spacer(),
          DropdownButton<int>(
            value: _hours,
            underline: const SizedBox.shrink(),
            borderRadius: BorderRadius.circular(Radii.md),
            items: [
              for (final h in [1, 24, 168, 720]) DropdownMenuItem(value: h, child: Text(h < 24 ? s('ttl_hour', {'n': h}) : s('ttl_day', {'n': h ~/ 24}))),
            ],
            onChanged: (v) {
              if (v == null) return;
              _hours = v;
              _create();
            },
          ),
        ]),
        const SizedBox(height: 12),
        Align(alignment: Alignment.centerRight, child: FilledButton(onPressed: () => Navigator.pop(context), child: Text(s('done')))),
      ]),
    );
  }
}

/// Paste-a-link join flow: inspect → preview → join.
Future<void> showJoinByLink(BuildContext context, {String? initial}) {
  return showDialog<void>(context: context, builder: (_) => Dialog(child: SizedBox(width: 440, child: _JoinView(initial: initial))));
}

class _JoinView extends StatefulWidget {
  const _JoinView({this.initial});
  final String? initial;
  @override
  State<_JoinView> createState() => _JoinViewState();
}

class _JoinViewState extends State<_JoinView> {
  late final _link = TextEditingController(text: widget.initial);

  @override
  void initState() {
    super.initState();
    if (widget.initial != null) WidgetsBinding.instance.addPostFrameCallback((_) => _inspect());
  }

  InviteInfo? _info;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  /// The invite in the field, in the form the core reads (`lumora://join/…`);
  /// the https form, the app form and a link inside pasted text all work.
  String? get _coreLink {
    final l = LumoraLink.find(_link.text);
    return l != null && l.kind == LinkKind.join ? l.app : null;
  }

  Future<void> _scan() async {
    final l = await Flows.scanQr(context);
    if (l == null || !mounted) return;
    if (l.kind != LinkKind.join) return Flows.openElsewhere(context, l);
    _link.text = l.https;
    setState(() => _error = null);
    _inspect();
  }

  Future<void> _inspect() async {
    final t = _coreLink;
    if (t == null) {
      setState(() => _info = null);
      return;
    }
    try {
      final i = await context.read<LumoraApi>().inspectInvite(t);
      if (mounted) setState(() => _info = i);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(S.read(context), e));
    }
  }

  Future<void> _join() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = context.read<LumoraApi>();
    final chat = context.read<ChatStore>();
    final spaces = context.read<SpacesStore>();
    try {
      await api.joinInvite(_coreLink ?? _link.text.trim());
      await Future.wait([chat.load(), spaces.load()]);
      if (mounted) {
        toast(context, S.read(context)('joined'));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(S.read(context), e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final i = _info;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(s('join_by_link'), style: context.tt.titleLarge),
        const SizedBox(height: 4),
        Text(s('join_by_link_hint'), style: context.tt.bodySmall),
        const SizedBox(height: 16),
        TextField(
          controller: _link,
          autofocus: true,
          onChanged: (_) => _inspect(),
          decoration: InputDecoration(
            hintText: '$kLinkHost/join/…',
            prefixIcon: const Icon(AppIcons.link),
            suffixIcon: IconButton(
              tooltip: s('paste'),
              icon: const Icon(AppIcons.paste, size: 20),
              onPressed: () async {
                final d = await Clipboard.getData('text/plain');
                if (d?.text != null) {
                  _link.text = d!.text!.trim();
                  _inspect();
                }
              },
            ),
          ),
        ),
        if (lumoraQrScanner != null) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(onPressed: _scan, icon: const Icon(AppIcons.scan, size: 18), label: Text(s('scan_qr'))),
        ],
        if (i != null) ...[
          const SizedBox(height: 12),
          LCard(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Avatar(name: i.name.isEmpty ? '?' : i.name, size: 44, group: true),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(i.valid ? i.name : s('invite_invalid'), style: context.tt.titleSmall),
                  if (i.valid && i.blocked)
                    Text(s('invite_group_blocked'), style: context.tt.bodySmall?.copyWith(color: LC.danger))
                  else if (i.valid)
                    Text(i.alreadyMember ? s('already_member') : s('n_members', {'n': i.members}), style: context.tt.bodySmall),
                ]),
              ),
              Icon(i.valid ? AppIcons.checkCircle : AppIcons.error, color: i.valid ? LC.success : LC.danger),
            ]),
          ),
        ],
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: const TextStyle(color: LC.danger))),
        const SizedBox(height: 20),
        GradientButton(
          label: s('join'),
          icon: AppIcons.signIn,
          expand: true,
          busy: _busy,
          onPressed: i != null && i.valid && !i.alreadyMember && !i.blocked ? _join : null,
        ),
      ]),
    );
  }
}
