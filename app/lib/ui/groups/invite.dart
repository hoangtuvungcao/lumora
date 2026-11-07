import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'community/community_common.dart' show timeLabel;

import '../../core/api.dart';
import '../../core/links.dart';
import '../../l10n/strings.dart';
import '../../state/community_defaults.dart';
import '../../state/group_invites.dart';
import '../../state/stores.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../devices/qr_scan.dart' show lumoraQrScanner;
import '../flows.dart';

/// Shows an invite link with QR + copy (my newest live one, else a new one),
/// my other live links with "Revoke", and "Revoke all links".
Future<void> showInvite(BuildContext context, {required String gid, required String name}) {
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(child: SizedBox(width: 420, child: SingleChildScrollView(child: _InviteView(gid: gid, name: name)))),
  );
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

  /// The link shown above (its id; "" from an older core).
  String _shownId = '';

  /// My live links (`group_invite_links`); null: not known (older core).
  List<InviteLink>? _links;

  @override
  void initState() {
    super.initState();
    _open();
  }

  /// Shows my newest live link when there is one (opening the sheet doesn't
  /// make a new link each time), else makes one.
  Future<void> _open() async {
    await _loadLinks();
    final newest = (_links ?? const <InviteLink>[]).fold<InviteLink?>(null, (a, b) => a == null || b.created > a.created ? b : a);
    if (newest != null && mounted) {
      setState(() {
        _link = LumoraLink.shareInvite(newest.link);
        _shownId = newest.id;
      });
    } else if (mounted) {
      await _create();
    }
  }

  Future<void> _loadLinks() async {
    try {
      final l = await context.read<LumoraApi>().groupInviteLinks(widget.gid);
      if (mounted) setState(() => _links = l);
    } catch (_) {
      // an older core: just the link made here
    }
  }

  /// Every link was just revoked: no new one until asked for.
  bool _cleared = false;

  Future<void> _create() async {
    setState(() {
      _link = null;
      _error = null;
      _cleared = false;
    });
    try {
      // shared as https on Lumora's site: any camera / chat app can open it
      final made = await context.read<LumoraApi>().createInviteLink(widget.gid, hours: _hours);
      if (mounted) {
        setState(() {
          _link = LumoraLink.shareInvite(made.link);
          _shownId = made.id;
        });
      }
      if (mounted && _links != null) await _loadLinks();
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(S.read(context), e));
    }
  }

  Future<void> _revoke(InviteLink l) async {
    final s = S.read(context);
    try {
      await context.read<LumoraApi>().groupRevokeInvite(widget.gid, id: l.id);
      if (!mounted) return;
      toast(context, s('il_revoked'));
      await _loadLinks();
      // the link on screen no longer works: show a fresh one
      if (l.id == _shownId && mounted) await _create();
    } catch (e) {
      if (mounted) toastError(context, e);
    }
  }

  Future<void> _revokeAll() async {
    final s = S.read(context);
    if (!await confirm(context, title: s('il_revoke_all'), body: s('il_revoke_all_body'), action: s('il_revoke'), danger: true)) return;
    if (!mounted) return;
    try {
      await context.read<LumoraApi>().groupRevokeInvite(widget.gid);
      if (!mounted) return;
      toast(context, s('il_revoked_all'));
      setState(() {
        _link = null;
        _shownId = '';
        _cleared = true;
        _links = _links == null ? null : const [];
      });
    } catch (e) {
      if (mounted) toastError(context, e);
    }
  }

  String _short(String link) {
    final i = link.lastIndexOf('/');
    final tail = i < 0 ? link : link.substring(i + 1);
    return '…/${tail.length > 10 ? tail.substring(0, 10) : tail}';
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
                  ? Center(
                      child: _cleared
                          ? FilledButton.tonalIcon(
                              key: const ValueKey('invite_new_link'),
                              onPressed: _create,
                              icon: const Icon(AppIcons.add, size: 18),
                              label: Text(s('il_new')),
                            )
                          : (_error == null ? const CircularProgressIndicator() : Text(_error!, style: const TextStyle(color: LC.danger))),
                    )
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
        if (_links != null) ...[
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: Text(s('il_active'), style: context.tt.labelLarge)),
          ]),
          const SizedBox(height: 4),
          if (_links!.isEmpty)
            Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text(s('il_none'), style: context.tt.bodySmall)),
          for (final l in _links!)
            Container(
              key: ValueKey('invite_link_${l.id}'),
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
              decoration: BoxDecoration(
                color: context.lc.surface2,
                borderRadius: BorderRadius.circular(Radii.md),
                border: l.id == _shownId ? Border.all(color: LC.primary.withValues(alpha: 0.5)) : null,
              ),
              child: Row(children: [
                const Icon(AppIcons.link, size: 16),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_short(l.link), maxLines: 1, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                    Text(
                      [if (l.id == _shownId) s('il_this_one'), if (l.expires > 0) s('il_expires', {'time': timeLabel(l.expires)})].join(' · '),
                      style: context.tt.bodySmall,
                    ),
                  ]),
                ),
                TextButton(
                  key: ValueKey('invite_revoke_${l.id}'),
                  style: TextButton.styleFrom(foregroundColor: LC.danger),
                  onPressed: () => _revoke(l),
                  child: Text(s('il_revoke')),
                ),
              ]),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('invite_revoke_all'),
              style: TextButton.styleFrom(foregroundColor: LC.danger),
              onPressed: _revokeAll,
              icon: const Icon(AppIcons.block, size: 16),
              label: Text(s('il_revoke_all')),
            ),
          ),
        ],
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
    final defaults = context.read<CommunityDefaults>();
    final community = _info?.community ?? false;
    final invites = GroupInvitesStore.of(api);
    try {
      final r = await api.joinInviteResult(_coreLink ?? _link.text.trim());
      final conv = r.conv;
      if (r.pending && (chat.convs[conv] == null)) {
        // the real core only sends the request: the group comes when an admin lets me in
        invites.joinRequested(r.gid, r.name.isNotEmpty ? r.name : (_info?.name ?? ''));
        if (mounted) {
          toast(context, S.read(context)('jd_sent'));
          Navigator.pop(context);
        }
        return;
      }
      await Future.wait([chat.load(), spaces.load()]);
      // "Default history retention for communities" (Settings › Privacy)
      final space = conv.length > 2 ? spaces.byId(conv.substring(2)) : null;
      if (community || space != null) await defaults.adopt(conv, channels: [for (final c in space?.channels ?? const <Channel>[]) c.conv]);
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
                    // the link itself carries no member count (members: 0 = unknown)
                    Text(i.alreadyMember ? s('already_member') : (i.members > 0 ? s('n_members', {'n': i.members}) : s(i.community ? 'invite_valid_community' : 'invite_valid_group')),
                        style: context.tt.bodySmall),
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
