import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';

typedef RelocatePreviewCallback = Future<UiRelocatePreview> Function(
  int folderId,
  String newPath,
);
typedef RelocateApplyCallback = Future<UiRelocateResult> Function(
  int folderId,
  String newPath,
);
typedef PickRelocateDirectoryCallback = Future<String?> Function();

/// Opens [MoveFolderDialog] for [folder] and returns the relocation result on apply.
Future<UiRelocateResult?> showMoveFolderDialog({
  required BuildContext context,
  required PlayerController controller,
  required UiFolderInfo folder,
}) {
  return showDialog<UiRelocateResult>(
    context: context,
    builder: (ctx) => MoveFolderDialog(
      controller: controller,
      folder: folder,
    ),
  );
}

/// Dialog for relocating a watched music folder without losing stats, playlists, or favorites.
class MoveFolderDialog extends StatefulWidget {
  const MoveFolderDialog({
    super.key,
    required this.controller,
    required this.folder,
    this.onPreviewRelocate,
    this.onApplyRelocate,
    this.onPickDirectory,
  });

  final PlayerController controller;
  final UiFolderInfo folder;
  final RelocatePreviewCallback? onPreviewRelocate;
  final RelocateApplyCallback? onApplyRelocate;
  final PickRelocateDirectoryCallback? onPickDirectory;

  @override
  State<MoveFolderDialog> createState() => _MoveFolderDialogState();
}

class _MoveFolderDialogState extends State<MoveFolderDialog> {
  String? _newPath;
  UiRelocatePreview? _preview;
  bool _previewing = false;
  bool _applying = false;
  String? _error;

  Future<void> _chooseNewFolder() async {
    String? picked;
    if (widget.onPickDirectory != null) {
      picked = await widget.onPickDirectory!();
    } else {
      final uri = await FilePicker.pickDirectory(
        dialogTitle: t('Select new music folder'),
      );
      if (uri != null) {
        final path = uri.isScheme('file') ? uri.toFilePath() : uri.toString();
        if (path.isNotEmpty) {
          picked = path;
        }
      }
    }

    if (picked == null || picked.isEmpty || !mounted) return;

    setState(() {
      _newPath = picked;
      _preview = null;
      _previewing = true;
      _error = null;
    });

    try {
      final previewFn =
          widget.onPreviewRelocate ?? widget.controller.folderRelocatePreview;
      final preview = await previewFn(widget.folder.id.toInt(), picked);
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _previewing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _previewing = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _applyMove() async {
    final target = _newPath;
    if (target == null || target.isEmpty || _applying || _previewing) return;

    setState(() {
      _applying = true;
      _error = null;
    });

    try {
      final applyFn =
          widget.onApplyRelocate ?? widget.controller.folderRelocateApply;
      final result = await applyFn(widget.folder.id.toInt(), target);
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _applying = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final canApply =
        _newPath != null && _newPath!.isNotEmpty && !_previewing && !_applying;
    final preview = _preview;
    final foundNone = preview != null && preview.foundTracks == BigInt.zero;

    return Dialog(
      backgroundColor: AppTheme.zinc900,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppTheme.zinc800),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.drive_file_move_outlined,
                    size: 20,
                    color: AppTheme.accent500,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      t('Move music folder'),
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: _applying
                        ? null
                        : () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                t(
                  'Update the folder path in your library without losing favorites, playlists, or listening history. Audio files on disk are not moved.',
                ),
                style: const TextStyle(
                  fontSize: 12.5,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 14),
              _PathBox(
                label: t('Current location'),
                path: preview?.oldPath ?? widget.folder.path,
              ),
              const SizedBox(height: 12),
              _PathBox(
                label: t('New location'),
                path: _newPath ?? t('No new folder selected'),
                muted: _newPath == null,
                trailing: OutlinedButton.icon(
                  onPressed: (_previewing || _applying)
                      ? null
                      : _chooseNewFolder,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textPrimary,
                    side: const BorderSide(color: AppTheme.zinc800),
                  ),
                  icon: const Icon(Icons.folder_open_rounded, size: 16),
                  label: Text(t('Choose new folder…')),
                ),
              ),
              if (_previewing) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      t('Checking folder...'),
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ] else if (preview != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: (foundNone
                            ? const Color(0xFFE5A00D)
                            : const Color(0xFF30A46C))
                        .withAlpha(24),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: (foundNone
                              ? const Color(0xFFE5A00D)
                              : const Color(0xFF30A46C))
                          .withAlpha(90),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            foundNone
                                ? Icons.warning_amber_rounded
                                : Icons.check_circle_outline_rounded,
                            size: 16,
                            color: foundNone
                                ? const Color(0xFFE5A00D)
                                : const Color(0xFF30A46C),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              t('Found {found} of {total} songs', {
                                'found': preview.foundTracks,
                                'total': preview.totalTracks,
                              }),
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (foundNone) ...[
                        const SizedBox(height: 6),
                        Text(
                          t(
                            'No known songs were found in this folder. Make sure you selected the right location before applying.',
                          ),
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ] else if (preview.missingTracks > BigInt.zero) ...[
                        const SizedBox(height: 4),
                        Text(
                          t('{n} songs were not found in the new location.', {
                            'n': preview.missingTracks,
                          }),
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.danger.withAlpha(26),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.danger.withAlpha(90)),
                  ),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppColors.danger,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _applying
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: Text(t('Cancel')),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: canApply ? _applyMove : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.accent500,
                      foregroundColor: AppColors.canvas,
                    ),
                    child: _applying
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.canvas,
                            ),
                          )
                        : Text(
                            t('Move folder'),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
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

class _PathBox extends StatelessWidget {
  const _PathBox({
    required this.label,
    required this.path,
    this.muted = false,
    this.trailing,
  });

  final String label;
  final String path;
  final bool muted;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.zinc800),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textMuted,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  path,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: muted ? AppColors.textMuted : AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 12),
            trailing!,
          ],
        ],
      ),
    );
  }
}
