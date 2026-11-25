import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';

Future<void> showWelcomeDialog({
  required BuildContext context,
  required PlayerController controller,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => WelcomeDialog(controller: controller),
  );
}

class WelcomeDialog extends StatefulWidget {
  const WelcomeDialog({
    super.key,
    required this.controller,
    this.onFetchDefaultDir,
    this.onAddAndScan,
    this.onPickDirectory,
    this.onDismiss,
  });

  final PlayerController controller;
  final Future<String?> Function()? onFetchDefaultDir;
  final Future<void> Function(String path)? onAddAndScan;
  final Future<String?> Function()? onPickDirectory;
  final Future<void> Function()? onDismiss;

  @override
  State<WelcomeDialog> createState() => _WelcomeDialogState();
}

class _WelcomeDialogState extends State<WelcomeDialog> {
  String? _defaultDir;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDefaultDir());
  }

  Future<void> _loadDefaultDir() async {
    try {
      final fetcher =
          widget.onFetchDefaultDir ?? widget.controller.fetchDefaultMusicDir;
      final dir = await fetcher();
      if (mounted) {
        setState(() {
          _defaultDir = dir;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _addAndScan(String path) async {
    setState(() => _busy = true);
    final adder = widget.onAddAndScan ?? widget.controller.addFolder;
    await adder(path);
    final dismisser = widget.onDismiss ?? widget.controller.dismissWelcome;
    await dismisser();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _chooseFolder() async {
    String? path;
    if (widget.onPickDirectory != null) {
      path = await widget.onPickDirectory!();
    } else {
      final uri = await FilePicker.pickDirectory(
        dialogTitle: t('Select music folder'),
      );
      if (uri != null) {
        path = uri.isScheme('file') ? uri.toFilePath() : uri.toString();
      }
    }
    if (path != null && path.isNotEmpty) {
      await _addAndScan(path);
    }
  }

  Future<void> _skip() async {
    setState(() => _busy = true);
    final dismisser = widget.onDismiss ?? widget.controller.dismissWelcome;
    await dismisser();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.accentMuted,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.headphones_rounded,
                      size: 24,
                      color: AppColors.accent,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t('Welcome to NeoModern'),
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          t('Set up your music library'),
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                t('Choose where NeoModern should scan your local music files. Your files stay in place.'),
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 16),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_defaultDir != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.canvas,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.folder_rounded,
                        size: 20,
                        color: AppColors.accent,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              t('Detected Music Folder'),
                              style: const TextStyle(
                                fontSize: 11,
                                color: AppColors.textMuted,
                              ),
                            ),
                            Text(
                              _defaultDir!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                )
              else
                Text(
                  t('No default Music folder was detected automatically.'),
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppColors.textMuted,
                  ),
                ),
              const SizedBox(height: 20),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    onPressed: _busy ? null : _skip,
                    child: Text(t('Skip')),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _chooseFolder,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.textPrimary,
                      side: const BorderSide(color: AppColors.border),
                    ),
                    icon: const Icon(Icons.folder_open_rounded, size: 17),
                    label: Text(t('Choose Folder')),
                  ),
                  if (_defaultDir != null)
                    FilledButton.icon(
                      onPressed:
                          _busy ? null : () => _addAndScan(_defaultDir!),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: AppColors.canvas,
                      ),
                      icon: const Icon(Icons.play_arrow_rounded, size: 18),
                      label: Text(t('Add & Scan')),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
