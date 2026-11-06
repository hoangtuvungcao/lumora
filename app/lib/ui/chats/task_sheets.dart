// Creation sheets for "Danh sách việc" (checklist) and "Nhắc hẹn" (reminder),
// plus "Thêm việc" for an existing checklist.

import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'rich_bubbles.dart' show reminderCountdown, reminderWhen;

const _kMaxItems = 50;

/// Shared frame: gradient icon header, scrollable body, Cancel + primary action.
class _TaskSheet extends StatelessWidget {
  const _TaskSheet({
    required this.icon,
    required this.colors,
    required this.title,
    required this.subtitle,
    required this.body,
    required this.action,
    required this.onAction,
    this.busy = false,
  });
  final IconData icon;
  final List<Color> colors;
  final String title;
  final String subtitle;
  final Widget body;
  final String action;
  final VoidCallback? onAction;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: inset),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.88),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Row(children: [
                IconTile(icon, color: colors.first),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: context.tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                    Text(subtitle, style: context.tt.bodySmall),
                  ]),
                ),
              ]),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: body,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Row(children: [
                Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(context), child: Text(s('cancel')))),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: busy ? null : onAction,
                    icon: busy
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(AppIcons.send, size: 18),
                    label: Text(action),
                  ),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

Future<T?> _openSheet<T>(BuildContext context, Widget child) => showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (_) => child,
    );

// --------------------------------------------------------------- checklist

/// Editable list of item rows: Enter adds the next row, × removes one.
class _ItemsEditor extends StatefulWidget {
  const _ItemsEditor({required this.controllers, required this.onChanged, this.max = _kMaxItems, this.autofocusFirst = false});
  final List<TextEditingController> controllers;
  final VoidCallback onChanged;
  final int max;
  final bool autofocusFirst;
  @override
  State<_ItemsEditor> createState() => _ItemsEditorState();
}

class _ItemsEditorState extends State<_ItemsEditor> {
  final List<FocusNode> _focus = [];

  List<TextEditingController> get _c => widget.controllers;

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < _c.length; i++) {
      _focus.add(FocusNode());
    }
  }

  @override
  void dispose() {
    for (final f in _focus) {
      f.dispose();
    }
    super.dispose();
  }

  void _add([int? after]) {
    if (_c.length >= widget.max) return;
    final i = (after ?? _c.length - 1) + 1;
    setState(() {
      _c.insert(i, TextEditingController());
      _focus.insert(i, FocusNode());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus[i].requestFocus());
    widget.onChanged();
  }

  void _remove(int i) {
    setState(() {
      _c.removeAt(i).dispose();
      _focus.removeAt(i).dispose();
    });
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final lc = context.lc;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < _c.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: lc.muted.withValues(alpha: 0.6), width: 1.6),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _c[i],
                focusNode: _focus[i],
                autofocus: widget.autofocusFirst && i == 0,
                maxLength: 200,
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => _add(i),
                onChanged: (_) => widget.onChanged(),
                decoration: InputDecoration(
                  hintText: s('checklist_item_n', {'n': i + 1}),
                  counterText: '',
                  isDense: true,
                  suffixIcon: _c.length > 1
                      ? IconButton(
                          tooltip: s('remove'),
                          icon: Icon(AppIcons.close, size: 16, color: lc.muted),
                          onPressed: () => _remove(i),
                        )
                      : null,
                ),
              ),
            ),
          ]),
        ),
      if (_c.length < widget.max)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(onPressed: _add, icon: const Icon(AppIcons.add, size: 18), label: Text(s('checklist_add_row'))),
        ),
    ]);
  }
}

class _ChecklistComposer extends StatefulWidget {
  const _ChecklistComposer({required this.conv});
  final String conv;
  @override
  State<_ChecklistComposer> createState() => _ChecklistComposerState();
}

class _ChecklistComposerState extends State<_ChecklistComposer> {
  final _title = TextEditingController();
  final _items = [TextEditingController(), TextEditingController(), TextEditingController()];
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    for (final c in _items) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> get _texts => _items.map((c) => c.text.trim()).where((t) => t.isNotEmpty).toList();
  bool get _valid => _title.text.trim().isNotEmpty && _texts.isNotEmpty;

  Future<void> _send() async {
    setState(() => _busy = true);
    try {
      await context.read<ChatStore>().sendChecklist(widget.conv, _title.text.trim(), _texts);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      toastError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return _TaskSheet(
      icon: AppIcons.tasks,
      colors: const [Color(0xFF22C55E), Color(0xFF14B8A6)],
      title: s('checklist_new'),
      subtitle: s('checklist_new_hint'),
      action: s('send'),
      busy: _busy,
      onAction: _valid ? _send : null,
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          controller: _title,
          autofocus: true,
          maxLength: 120,
          textInputAction: TextInputAction.next,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: s('checklist_title'), hintText: s('checklist_title_hint'), counterText: ''),
        ),
        const SizedBox(height: 14),
        Text(s('checklist_items').toUpperCase(), style: context.tt.labelSmall),
        const SizedBox(height: 8),
        _ItemsEditor(controllers: _items, onChanged: () => setState(() {})),
      ]),
    );
  }
}

/// Attach menu › "Danh sách việc". Returns true when sent.
Future<bool> showChecklistComposer(BuildContext context, String conv) async =>
    await _openSheet<bool>(context, _ChecklistComposer(conv: conv)) ?? false;

class _AddItems extends StatefulWidget {
  const _AddItems({required this.message});
  final Message message;
  @override
  State<_AddItems> createState() => _AddItemsState();
}

class _AddItemsState extends State<_AddItems> {
  final _items = [TextEditingController()];
  bool _busy = false;

  @override
  void dispose() {
    for (final c in _items) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> get _texts => _items.map((c) => c.text.trim()).where((t) => t.isNotEmpty).toList();

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await context.read<ChatStore>().addChecklistItems(widget.message.conv, widget.message, _texts);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      toastError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final data = ChecklistData.parse(widget.message);
    final left = _kMaxItems - (data?.items.length ?? 0);
    return _TaskSheet(
      icon: AppIcons.addToList,
      colors: const [Color(0xFF22C55E), Color(0xFF14B8A6)],
      title: s('checklist_add_items'),
      subtitle: data?.title ?? '',
      action: s('add'),
      busy: _busy,
      onAction: _texts.isEmpty ? null : _save,
      body: _ItemsEditor(controllers: _items, onChanged: () => setState(() {}), max: left.clamp(1, _kMaxItems), autofocusFirst: true),
    );
  }
}

/// "Thêm việc" on a checklist the user sent.
Future<void> showChecklistAddItems(BuildContext context, Message m) => _openSheet<void>(context, _AddItems(message: m));

// ---------------------------------------------------------------- reminder

class _ReminderComposer extends StatefulWidget {
  const _ReminderComposer({required this.conv});
  final String conv;
  @override
  State<_ReminderComposer> createState() => _ReminderComposerState();
}

class _ReminderComposerState extends State<_ReminderComposer> {
  final _title = TextEditingController();
  final _note = TextEditingController();
  late DateTime _at = _roundUp(DateTime.now().add(const Duration(hours: 1)));
  int _quick = 0; // index into _quickTimes, -1 = custom
  bool _busy = false;

  static DateTime _roundUp(DateTime d) {
    final m = (d.minute / 5).ceil() * 5;
    return DateTime(d.year, d.month, d.day, d.hour).add(Duration(minutes: m));
  }

  List<(String, DateTime)> _quickTimes(S s) {
    final now = DateTime.now();
    return [
      (s('in_1_hour'), _roundUp(now.add(const Duration(hours: 1)))),
      (s('tonight_20'), DateTime(now.year, now.month, now.day, 20)),
      (s('tomorrow_9'), DateTime(now.year, now.month, now.day + 1, 9)),
    ].where((e) => e.$2.isAfter(now)).toList();
  }

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 730)),
      initialDate: _at.isBefore(now) ? now : _at,
    );
    if (d == null) return;
    setState(() {
      _at = DateTime(d.year, d.month, d.day, _at.hour, _at.minute);
      _quick = -1;
    });
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_at));
    if (t == null) return;
    setState(() {
      _at = DateTime(_at.year, _at.month, _at.day, t.hour, t.minute);
      _quick = -1;
    });
  }

  bool get _future => _at.isAfter(DateTime.now());
  bool get _valid => _title.text.trim().isNotEmpty && _future;

  Future<void> _send() async {
    setState(() => _busy = true);
    try {
      await context.read<ChatStore>().sendReminder(widget.conv, _title.text.trim(), _at, _note.text.trim());
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      toastError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final lc = context.lc;
    final quick = _quickTimes(s);
    Widget tile(IconData icon, String label, String value, VoidCallback onTap) => Expanded(
          child: Material(
            color: lc.surface2,
            borderRadius: BorderRadius.circular(Radii.md),
            child: InkWell(
              borderRadius: BorderRadius.circular(Radii.md),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Row(children: [
                  Icon(icon, size: 18, color: LC.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(label, style: context.tt.bodySmall),
                      Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        );
    final now = DateTime.now();
    final dateLabel = reminderWhen(s, _at).split(' · ').first;
    return _TaskSheet(
      icon: AppIcons.reminder,
      colors: const [Color(0xFFF59E0B), Color(0xFFF97316)],
      title: s('reminder_new'),
      subtitle: s('reminder_new_hint'),
      action: s('send'),
      busy: _busy,
      onAction: _valid ? _send : null,
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          controller: _title,
          autofocus: true,
          maxLength: 120,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: s('reminder_title'), hintText: s('reminder_title_hint'), counterText: ''),
        ),
        const SizedBox(height: 14),
        Text(s('reminder_when').toUpperCase(), style: context.tt.labelSmall),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (var i = 0; i < quick.length; i++)
            ChoiceChip(
              label: Text(quick[i].$1),
              selected: _quick == i,
              onSelected: (_) => setState(() {
                _quick = i;
                _at = quick[i].$2;
              }),
            ),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          tile(AppIcons.calendar, s('reminder_date'), dateLabel, _pickDate),
          const SizedBox(width: 8),
          tile(AppIcons.clock, s('reminder_time'), s.hhmm(_at), _pickTime),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Icon(_future ? AppIcons.hourglass : AppIcons.error, size: 14, color: _future ? lc.muted : LC.danger),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _future ? '${reminderWhen(s, _at)} · ${reminderCountdown(s, _at.difference(now))}' : s('reminder_past'),
              style: context.tt.bodySmall?.copyWith(color: _future ? null : LC.danger),
            ),
          ),
        ]),
        const SizedBox(height: 14),
        TextField(
          controller: _note,
          minLines: 1,
          maxLines: 4,
          maxLength: 500,
          decoration: InputDecoration(labelText: s('reminder_note'), hintText: s('reminder_note_hint'), counterText: ''),
        ),
        const SizedBox(height: 4),
        Row(children: [
          Icon(AppIcons.bellRinging, size: 14, color: lc.muted),
          const SizedBox(width: 6),
          Expanded(child: Text(s('reminder_everyone'), style: context.tt.bodySmall)),
        ]),
      ]),
    );
  }
}

/// Attach menu › "Nhắc hẹn". Returns true when sent.
Future<bool> showReminderComposer(BuildContext context, String conv) async =>
    await _openSheet<bool>(context, _ReminderComposer(conv: conv)) ?? false;
