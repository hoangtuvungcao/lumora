// Shown instead of the app when it cannot start at all (the core component
// failed to load, or there is no place to keep the app's data). Plain
// language first; the raw reason sits behind "Technical details".

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'widgets/app_icons.dart';
import 'widgets/common.dart';

import '../l10n/strings.dart';
import 'theme.dart';
import 'widgets/logo.dart';

enum StartupProblem { core, dataDir }

class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.problem, required this.detail, required this.onRetry});
  final StartupProblem problem;
  final String detail;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final vi = WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'vi';
    return MaterialApp(
      title: 'Lumora',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: StartupErrorScreen(s: vi ? S.vn : S.en, problem: problem, detail: detail, onRetry: onRetry),
    );
  }
}

class StartupErrorScreen extends StatefulWidget {
  const StartupErrorScreen({super.key, required this.s, required this.problem, required this.detail, required this.onRetry});
  final S s;
  final StartupProblem problem;
  final String detail;
  final Future<void> Function() onRetry;
  @override
  State<StartupErrorScreen> createState() => _StartupErrorScreenState();
}

class _StartupErrorScreenState extends State<StartupErrorScreen> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    final key = widget.problem == StartupProblem.core ? 'core_error' : 'data_dir_error';
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Center(child: LumoraLogo(size: 56)),
                const SizedBox(height: 20),
                Center(
                  child: const IconTile(AppIcons.warning, color: LC.warning, size: IconTileSize.lg, circle: true),
                ),
                const SizedBox(height: 16),
                Text(s('${key}_title'), textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(s('${key}_body'), textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.5)),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () async {
                          setState(() => _busy = true);
                          try {
                            await widget.onRetry();
                          } finally {
                            if (mounted) setState(() => _busy = false);
                          }
                        },
                  icon: _busy
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(AppIcons.refresh, size: 18),
                  label: Text(s('retry')),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () => Platform.isAndroid || Platform.isIOS ? SystemNavigator.pop() : exit(1),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                  child: Text(s('quit')),
                ),
                const SizedBox(height: 16),
                Theme(
                  data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    leading: const Icon(AppIcons.code, size: 18),
                    title: Text(s('technical_details'), style: Theme.of(context).textTheme.bodyMedium),
                    children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(Radii.sm)),
                        child: SelectableText(widget.detail, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: () => Clipboard.setData(ClipboardData(text: widget.detail)),
                          icon: const Icon(AppIcons.copy, size: 16),
                          label: Text(s('copy')),
                        ),
                      ),
                    ],
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
