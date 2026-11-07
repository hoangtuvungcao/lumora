// Settings › "Thiết bị của tôi" / "My devices": the account's devices, the
// per-device actions (rename, sign out, make main) and the entry to link a
// new device.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/devices_store.dart';
import '../../state/settings.dart';
import '../../state/stores.dart' show SessionStore;
import '../settings/security_checkup.dart' show showRecoveryPhraseDialog;
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';
import '../widgets/secure_input.dart';
import 'device_ui.dart';
import 'link_device.dart';

class MyDevicesPage extends StatefulWidget {
  const MyDevicesPage({super.key});
  @override
  State<MyDevicesPage> createState() => _MyDevicesPageState();
}

class _MyDevicesPageState extends State<MyDevicesPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<DevicesStore>().load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final store = context.watch<DevicesStore>();
    final list = store.list;
    if (list == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 48),
        child: store.error != null
            ? EmptyState(
                icon: AppIcons.devices,
                title: s('load_failed'),
                subtitle: store.error,
                action: OutlinedButton(onPressed: store.load, child: Text(s('dv_try_again'))),
              )
            : const Center(child: CircularProgressIndicator()),
      );
    }
    final now = DateTime.now();
    final devices = [...list.devices]..sort((a, b) {
        int rank(DeviceInfo d) => d.isThis ? 0 : (d.primary ? 1 : 2);
        final r = rank(a).compareTo(rank(b));
        return r != 0 ? r : b.lastSeen.compareTo(a.lastSeen);
      });
    final main = list.mainDevice;
    final history = store.history;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Summary(count: devices.length, primary: list.primary, mainName: main == null ? null : deviceTitle(s, main)),
      if (history.active) ...[const SizedBox(height: 12), _HistoryRow(status: history)],
      if (list.primary && store.relist.isNotEmpty) ...[
        SectionLabel(s('dv_relist_section'), padding: const EdgeInsets.fromLTRB(4, 20, 4, 8)),
        LCard(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: [
            for (final (i, r) in store.relist.indexed) ...[
              if (i > 0) Divider(height: 1, indent: 72, color: context.lc.divider),
              ListTile(
                key: ValueKey('relist-${r.device}'),
                leading: IconTile(deviceKindIcon(r.kind), color: deviceKindColor(r.kind), size: IconTileSize.sm),
                title: Text(relistName(s, r)),
                subtitle: Text(deviceKindName(s, r.kind)),
                trailing: const Icon(AppIcons.chevronRight, size: 18),
                onTap: () => showRelistPrompt(context, r),
              ),
            ],
          ]),
        ),
      ],
      SectionLabel(s('dv_list_title'), padding: const EdgeInsets.fromLTRB(4, 20, 4, 8)),
      LCard(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(children: [
          for (final (i, d) in devices.indexed) ...[
            if (i > 0) Divider(height: 1, indent: 72, color: context.lc.divider),
            _DeviceRow(device: d, now: now, onTap: () => showDeviceSheet(context, d)),
          ],
        ]),
      ),
      if (!list.primary) ...[
        const SizedBox(height: 16),
        LCard(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: [
            ListTile(
              leading: const IconTile(AppIcons.owner, color: Color(0xFFF59E0B), size: IconTileSize.sm),
              title: Text(s('dv_make_main')),
              subtitle: Text(s('dv_make_main_hint')),
              trailing: const Icon(AppIcons.chevronRight, size: 18),
              onTap: () => showPromoteDialog(context),
            ),
            ListTile(
              leading: const IconTile(AppIcons.signOut, color: LC.danger, size: IconTileSize.sm),
              title: Text(s('dv_signout_device'), style: const TextStyle(color: LC.danger)),
              onTap: () => signOutThisDevice(context),
            ),
          ]),
        ),
      ],
      if (list.primary) ...[
        const SizedBox(height: 16),
        LCard(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: ListTile(
            leading: const IconTile(AppIcons.signOut, color: LC.danger, size: IconTileSize.sm),
            title: Text(s('sign_out'), style: const TextStyle(color: LC.danger)),
            subtitle: Text(s('sign_out_hint')),
            onTap: () => signOutHere(context),
          ),
        ),
      ],
      if (list.primary && devices.length > 1) ...[
        const SizedBox(height: 16),
        SecureNote('${s('dv_lost_title')} ${s('dv_lost_body')}', icon: AppIcons.shieldCheck, color: LC.success),
      ],
    ]);
  }
}

String relistName(S s, RelistRequest r) => r.name.trim().isNotEmpty ? r.name.trim() : deviceKindName(s, r.kind);

/// "A device wants to rejoin your account": after a restore with the recovery
/// phrase, an old device of the account asks to be listed again. It is only
/// listed when the user allows it; "Not mine" signs it out (a lost or stolen
/// device that was signed out while offline must never come back by itself).
Future<void> showRelistPrompt(BuildContext context, RelistRequest r) async {
  final s = S.read(context);
  final store = context.read<DevicesStore>();
  final name = relistName(s, r);
  final overlay = Navigator.of(context, rootNavigator: true).overlay;
  final approve = await showDialog<bool>(
    context: context,
    routeSettings: RouteSettings(name: 'relist-${r.device}'),
    builder: (c) => AlertDialog(
      icon: IconTile(deviceKindIcon(r.kind), color: deviceKindColor(r.kind)),
      title: Text(s('dv_relist_title')),
      content: Text(s('dv_relist_body', {'name': name, 'kind': deviceKindName(s, r.kind)})),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(c).pop(false),
          style: TextButton.styleFrom(foregroundColor: LC.danger),
          child: Text(s('dv_relist_refuse')),
        ),
        FilledButton(onPressed: () => Navigator.of(c).pop(true), child: Text(s('dv_relist_allow'))),
      ],
    ),
  );
  if (approve == null || !context.mounted) return; // dismissed: stays in My devices
  try {
    await store.answerRelist(r.device, approve: approve);
    showTopToast(null, s(approve ? 'dv_relist_allowed' : 'dv_relist_refused', {'name': name}), duration: const Duration(seconds: 3), overlay: overlay);
  } catch (e) {
    if (context.mounted) toastError(context, e);
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.count, required this.primary, this.mainName});
  final int count;
  final bool primary;
  final String? mainName;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: context.lc.divider),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(LC.primary.withValues(alpha: dark ? 0.16 : 0.07), context.lc.surface),
            Color.alphaBlend(LC.accent.withValues(alpha: dark ? 0.08 : 0.05), context.lc.surface),
          ],
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          IconTile(AppIcons.devices, size: isDesktop(context) ? IconTileSize.lg : IconTileSize.md),
          SizedBox(width: isDesktop(context) ? 16 : 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s('dv_summary', {'n': count}), style: context.tt.titleMedium?.copyWith(fontWeight: FontWeight.w700, height: 1.3)),
              const SizedBox(height: 6),
              Text(s('dv_summary_sub'), style: context.tt.bodySmall?.copyWith(height: 1.5, fontSize: 13)),
            ]),
          ),
        ]),
        const SizedBox(height: 18),
        if (primary)
          Align(
            alignment: isDesktop(context) ? Alignment.centerLeft : Alignment.center,
            child: GradientButton(label: s('dv_link_new'), icon: AppIcons.qrCode, expand: !isDesktop(context), onPressed: () => openLinkDevice(context)),
          )
        else
          SecureNote(mainName == null ? s('dv_linked_note_generic') : s('dv_linked_note', {'name': mainName})),
      ]),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.status});
  final HistoryStatus status;
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return LCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const IconTile(AppIcons.history, size: IconTileSize.sm, color: LC.accent),
          const SizedBox(width: 12),
          Expanded(child: Text(s('dv_history_row', {'n': status.messages}), style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
        ]),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: status.fraction, minHeight: 6, backgroundColor: context.lc.surface2),
        ),
      ]),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.device, required this.now, required this.onTap});
  final DeviceInfo device;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final d = device;
    final activity = deviceActivity(s, d, now);
    final active = activity == s('dv_active_now');
    final added = d.added > 0 ? s('dv_added', {'date': deviceDate(s, d.added)}) : '';
    final narrow = MediaQuery.sizeOf(context).width < 420;
    final badges = DeviceBadges(device: d);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
        child: Row(children: [
          DeviceGlyph(kind: d.kind, online: d.online || d.isThis),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(deviceTitle(s, d), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.bodyLarge?.copyWith(fontWeight: FontWeight.w600, fontSize: 15)),
                ),
                if (!narrow && (d.isThis || d.primary)) ...[const SizedBox(width: 8), badges],
              ]),
              if (narrow && (d.isThis || d.primary)) ...[const SizedBox(height: 4), badges],
              const SizedBox(height: 3),
              Text.rich(
                TextSpan(children: [
                  TextSpan(text: activity, style: TextStyle(color: active ? LC.success : context.lc.muted, fontWeight: active ? FontWeight.w600 : FontWeight.w400)),
                  if (added.isNotEmpty) TextSpan(text: narrow ? '\n$added' : '  ·  $added'),
                ]),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.tt.bodySmall?.copyWith(fontSize: 12.5, height: 1.45),
              ),
            ]),
          ),
          const SizedBox(width: 6),
          Icon(AppIcons.chevronRight, size: 18, color: context.lc.muted),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------ device sheet

/// Details and actions for one of my devices (bottom sheet on phones,
/// dialog on desktop).
Future<void> showDeviceSheet(BuildContext context, DeviceInfo device) {
  final content = _DeviceSheet(device: device);
  if (isDesktop(context)) {
    return showDialog<void>(
      context: context,
      builder: (c) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: content),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (c) => content,
  );
}

class _DeviceSheet extends StatelessWidget {
  const _DeviceSheet({required this.device});
  final DeviceInfo device;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    // Follow renames while the sheet is open.
    final d = context.select<DevicesStore, DeviceInfo>((x) => x.list?.devices.where((e) => e.device == device.device).firstOrNull ?? device);
    final primaryHere = context.select<DevicesStore, bool>((x) => x.isPrimary);
    final desktop = isDesktop(context);
    final os = deviceOsName(d.os);
    final kind = [deviceKindName(s, d.kind), if (os.isNotEmpty) os].join(' · ');
    void close() => Navigator.of(context).pop();

    Widget info(String label, String value, {bool copy = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(children: [
            Expanded(child: Text(label, style: context.tt.bodySmall?.copyWith(fontSize: 13))),
            Text(value, style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()])),
            if (copy) ...[
              const SizedBox(width: 4),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => copyText(context, value),
                child: Padding(padding: const EdgeInsets.all(4), child: Icon(AppIcons.copy, size: 15, color: context.lc.muted)),
              ),
            ],
          ]),
        );

    final actions = <Widget>[
      if (primaryHere)
        _SheetAction(
          icon: AppIcons.edit,
          label: s('dv_rename'),
          onTap: () async {
            final name = await promptText(context, title: s('dv_rename_title'), initial: d.name, hint: s('dv_rename_hint'), action: s('save'));
            if (name == null || name.trim().isEmpty || !context.mounted) return;
            try {
              await context.read<DevicesStore>().rename(d.device, name.trim().characters.take(32).toString());
              if (context.mounted) toast(context, s('dv_renamed'));
            } catch (e) {
              if (context.mounted) toast(context, deviceError(s, e));
            }
          },
        ),
      if (primaryHere && !d.isThis)
        _SheetAction(
          icon: AppIcons.signOut,
          label: s('dv_signout_device'),
          danger: true,
          onTap: () async {
            final done = await confirmRevoke(context, d);
            if (done && context.mounted) close();
          },
        ),
      if (!primaryHere && d.isThis) ...[
        _SheetAction(
          icon: AppIcons.owner,
          label: s('dv_make_main'),
          sub: s('dv_make_main_hint'),
          onTap: () {
            close();
            showPromoteDialog(context);
          },
        ),
        _SheetAction(
          icon: AppIcons.signOut,
          label: s('dv_signout_device'),
          danger: true,
          onTap: () {
            close();
            signOutThisDevice(context);
          },
        ),
      ],
    ];

    final sheet = SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(24, desktop ? 32 : 0, 24, desktop ? 24 : 20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Center(child: DeviceGlyph(kind: d.kind, online: d.online || d.isThis, size: IconTileSize.lg)),
        const SizedBox(height: 14),
        Text(deviceTitle(s, d), textAlign: TextAlign.center, style: context.tt.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(kind, textAlign: TextAlign.center, style: context.tt.bodySmall?.copyWith(fontSize: 13)),
        if (d.isThis || d.primary) ...[const SizedBox(height: 10), Center(child: DeviceBadges(device: d))],
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(color: context.lc.surface2.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(Radii.md)),
          child: Column(children: [
            info(s('dv_last_active'), deviceActivity(s, d, DateTime.now())),
            if (d.added > 0) info(s('dv_added_label'), deviceDate(s, d.added)),
            if (d.shortId.isNotEmpty) info(s('dv_remote_id'), d.shortId, copy: true),
          ]),
        ),
        if (actions.isNotEmpty) ...[const SizedBox(height: 14), ...actions],
      ]),
    );
    if (!desktop) return sheet;
    return Stack(children: [
      sheet,
      Positioned(top: 12, right: 12, child: SecureNavButton.close(context, close)),
    ]);
  }
}

class _SheetAction extends StatelessWidget {
  const _SheetAction({required this.icon, required this.label, required this.onTap, this.sub, this.danger = false});
  final IconData icon;
  final String label;
  final String? sub;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = danger ? LC.danger : context.lc.text;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Material(
        color: danger ? LC.danger.withValues(alpha: 0.08) : context.lc.surface2.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(Radii.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.md),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(children: [
              Icon(icon, size: 20, color: c),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: TextStyle(fontFamily: kFontFamily, color: c, fontWeight: FontWeight.w600, fontSize: 14.5)),
                  if (sub != null) Text(sub!, style: context.tt.bodySmall?.copyWith(fontSize: 12)),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------- sign out

/// Main device: sign another device out (with "also delete downloads").
Future<bool> confirmRevoke(BuildContext context, DeviceInfo d) async {
  final s = S.read(context);
  final name = deviceTitle(s, d);
  var wipe = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        icon: const IconTile(AppIcons.signOut, color: LC.danger, size: IconTileSize.lg, circle: true),
        title: Text(s('dv_signout_title', {'name': name}), textAlign: TextAlign.center),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(s('dv_signout_body'), style: c.tt.bodyMedium?.copyWith(height: 1.5, color: c.lc.muted)),
            const SizedBox(height: 14),
            Material(
              color: c.lc.surface2.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(Radii.md),
              child: CheckboxListTile(
                value: wipe,
                onChanged: (v) => set(() => wipe = v ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
                title: Text(s('dv_signout_wipe'), style: c.tt.bodyMedium?.copyWith(fontSize: 13.5)),
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(s('cancel'))),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: LC.danger), onPressed: () => Navigator.pop(c, true), child: Text(s('dv_signout_action'))),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted) return false;
  try {
    await context.read<DevicesStore>().revoke(d.device, wipeMedia: wipe);
    if (context.mounted) toast(context, s('dv_signed_out_done', {'name': name}));
    return true;
  } catch (e) {
    if (context.mounted) toast(context, deviceError(s, e));
    return false;
  }
}

/// "Đăng xuất" (Settings, My devices). Confirmed with the account password when the install has
/// one. A linked device asks the main one to revoke it; the main device forgets the account here
/// (linked devices keep working). Signing back in needs the recovery phrase, a backup file or a
/// link from another signed-in device — there is no server that knows the password.
Future<void> signOutHere(BuildContext context) async {
  final devices = context.read<DevicesStore>();
  if (devices.list == null) await devices.load().catchError((_) {});
  if (!context.mounted) return;
  final s = S.read(context);
  final primary = devices.isPrimary;
  final session = context.read<SessionStore>();
  final protection = session.me?.protection ?? '';
  final needsPass = protection.isNotEmpty ? protection == 'passphrase' : context.read<Settings>().hasPassphrase;
  final api = context.read<LumoraApi>();
  final pass = TextEditingController();
  String? error;
  var busy = false;
  final done = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) {
        Future<void> go() async {
          if (busy || (needsPass && pass.text.isEmpty)) return;
          set(() {
            busy = true;
            error = null;
          });
          try {
            await api.deviceLogout(primaryOk: primary, passphrase: needsPass ? pass.text : null);
            if (c.mounted) Navigator.pop(c, true);
          } catch (e) {
            if (!c.mounted) return;
            set(() {
              busy = false;
              error = e is ApiException && e.code == 'err.wrong_passphrase' ? s('err_wrong_passphrase') : deviceError(s, e);
            });
          }
        }

        // no dismissing (barrier tap, back) while the sign-out runs
        return PopScope(
          canPop: !busy,
          child: AlertDialog(
            icon: const IconTile(AppIcons.signOut, color: LC.danger, size: IconTileSize.lg, circle: true),
            title: Text(s(primary ? 'dv_logout_main_title' : 'dv_logout_self_title'), textAlign: TextAlign.center),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(s(primary ? 'dv_logout_main_body' : 'dv_logout_self_body'), style: c.tt.bodyMedium?.copyWith(height: 1.5, color: c.lc.muted)),
                  if (needsPass) ...[
                    const SizedBox(height: 14),
                    PasswordField(
                      controller: pass,
                      label: s('dv_logout_password'),
                      autofocus: true,
                      policy: false,
                      errorText: error,
                      onChanged: (_) => set(() => error = null),
                      onSubmitted: (_) => go(),
                    ),
                  ] else if (error != null) ...[
                    const SizedBox(height: 10),
                    Text(error!, style: const TextStyle(color: LC.danger)),
                  ],
                  if (primary)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => showRecoveryPhraseDialog(c),
                        icon: const Icon(AppIcons.recoveryPhrase, size: 18),
                        label: Text(s('dv_logout_main_show')),
                      ),
                    ),
                ]),
              ),
            ),
            actions: [
              TextButton(onPressed: busy ? null : () => Navigator.pop(c, false), child: Text(s('cancel'))),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: LC.danger),
                onPressed: busy || (needsPass && pass.text.isEmpty) ? null : go,
                child: Text(s('dv_signout_action')),
              ),
            ],
          ),
        );
      },
    ),
  );
  // `device_revoked {by_self}` follows and shows the signed-out notice (the dialog's field is
  // disposed with it; the controller is left to the GC so a closing animation never reads a
  // disposed one).
  if (done != true) return;
}

/// Linked device: sign this device out of the account.
Future<void> signOutThisDevice(BuildContext context) => signOutHere(context);

// ---------------------------------------------------------- make main

Future<void> showPromoteDialog(BuildContext context) async {
  final s = S.read(context);
  final done = await showSecureDialog<bool>(context, builder: (_) => const PromoteDialog());
  if (done == true && context.mounted) toast(context, s('dv_promoted'));
}

/// "Đặt làm thiết bị chính": the 24-word recovery phrase confirms it.
class PromoteDialog extends StatefulWidget {
  const PromoteDialog({super.key});
  @override
  State<PromoteDialog> createState() => _PromoteDialogState();
}

class _PromoteDialogState extends State<PromoteDialog> {
  final _phrase = TextEditingController();
  final _pass = TextEditingController();

  /// This install is protected with a passphrase: the core needs it to move the data
  /// over to the account key (asked again if the core says so).
  late bool _needPass = context.read<SessionStore>().me?.protection == 'passphrase';
  bool _passError = false;
  bool _busy = false;
  bool _switching = false;
  String? _error;
  Timer? _giveUp;
  DevicesStore? _store;

  @override
  void dispose() {
    _phrase.dispose();
    _pass.dispose();
    _giveUp?.cancel();
    _store?.removeListener(_watch);
    super.dispose();
  }

  /// The core restarts as the main device; the store reloads → done.
  void _watch() {
    if (!mounted) return;
    if (context.read<DevicesStore>().isPrimary) Navigator.of(context).pop(true);
  }

  Future<void> _go() async {
    final s = S.read(context);
    final store = context.read<DevicesStore>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<LumoraApi>().devicePromote(_phrase.text.trim(), passphrase: _needPass ? _pass.text : null);
      if (!mounted) return;
      _phrase.clear();
      _pass.clear();
      setState(() => _switching = true);
      _store = store..addListener(_watch);
      _giveUp = Timer(const Duration(seconds: 45), () {
        if (mounted) Navigator.of(context).pop(store.isPrimary);
      });
    } catch (e) {
      if (!mounted) return;
      final code = e is ApiException ? e.code : null;
      final passIssue = code == 'err.wrong_passphrase' || code == 'err.passphrase_required';
      setState(() {
        _error = deviceError(s, e);
        _passError = passIssue;
        if (passIssue) _needPass = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final main = context.select<DevicesStore, DeviceInfo?>((d) => d.list?.mainDevice);
    final ready = RecoveryPhraseInput.isReady(_phrase.text) && (!_needPass || _pass.text.isNotEmpty);
    void close() => Navigator.pop(context);
    return SecureDialogFrame(
      trailing: _switching ? null : SecureNavButton.close(context, close),
      onEscape: _switching ? () {} : close,
      child: _switching
          ? Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SecureHero(icon: AppIcons.owner, tone: const Color(0xFFF59E0B), title: s('dv_switching'), compact: true),
              const SizedBox(height: 24),
              const Center(child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.6))),
            ])
          : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SecureHero(icon: AppIcons.owner, tone: const Color(0xFFF59E0B), title: s('dv_make_main'), subtitle: s('dv_promote_sub'), compact: true),
              const SizedBox(height: 18),
              SecureNote(
                main == null ? s('dv_promote_note_generic') : s('dv_promote_note', {'name': deviceTitle(s, main)}),
                icon: AppIcons.warning,
                color: LC.warning,
              ),
              const SizedBox(height: 18),
              RecoveryPhraseInput(
                controller: _phrase,
                enabled: !_busy,
                onChanged: () => setState(() => _error = null),
                onSubmitted: () => ready && !_busy ? _go() : null,
              ),
              if (_needPass) ...[
                const SizedBox(height: 16),
                PasswordField(
                  controller: _pass,
                  label: s('dv_promote_pass'),
                  hint: s('dv_promote_pass_hint'),
                  icon: AppIcons.key,
                  enabled: !_busy,
                  policy: false,
                  errorText: _passError ? _error : null,
                  onChanged: (_) => setState(() {
                    _error = null;
                    _passError = false;
                  }),
                  onSubmitted: (_) => ready && !_busy ? _go() : null,
                ),
              ],
              if (_error != null && !_passError) ...[const SizedBox(height: 12), SecureMessage(_error!)],
              const SizedBox(height: 22),
              SecurePrimaryButton(label: s('dv_make_main'), icon: AppIcons.owner, busy: _busy, onPressed: ready ? _go : null),
            ]),
    );
  }
}
