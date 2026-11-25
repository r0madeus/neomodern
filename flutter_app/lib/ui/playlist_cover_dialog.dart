import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';

Future<void> showPlaylistCoverDialog({
  required BuildContext context,
  required PlayerController controller,
  required UiPlaylistInfo playlist,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => PlaylistCoverDialog(
      controller: controller,
      playlist: playlist,
    ),
  );
}

class PlaylistCoverDialog extends StatefulWidget {
  const PlaylistCoverDialog({
    super.key,
    required this.controller,
    required this.playlist,
  });

  final PlayerController controller;
  final UiPlaylistInfo playlist;

  @override
  State<PlaylistCoverDialog> createState() => _PlaylistCoverDialogState();
}

class _PlaylistCoverDialogState extends State<PlaylistCoverDialog> {
  late String _mode;
  late String _paletteId;
  late String _iconId;
  String? _imagePath;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final pl = widget.playlist;
    final preset = parsePlaylistCoverPreset(pl.cover ?? pl.coverValue);
    if (preset != null) {
      _mode = 'gradient';
      _paletteId = preset.palette.id;
      _iconId = preset.icon.id;
    } else if (pl.cover != null &&
        !pl.cover!.startsWith('preset:') &&
        pl.cover!.isNotEmpty) {
      _mode = 'image';
      _paletteId = kPlaylistCoverPalettes.first.id;
      _iconId = kPlaylistCoverIcons.first.id;
      _imagePath = pl.cover;
    } else {
      _mode = 'auto';
      _paletteId = kPlaylistCoverPalettes.first.id;
      _iconId = kPlaylistCoverIcons.first.id;
    }
  }

  Future<void> _pickImage() async {
    final file = await FilePicker.pickFile(
      dialogTitle: t('Select cover image'),
      type: FileType.image,
    );
    final path = file?.path;
    if (path != null && path.isNotEmpty && mounted) {
      setState(() {
        _mode = 'image';
        _imagePath = path;
      });
    }
  }

  Future<void> _save() async {
    String? value;
    if (_mode == 'gradient') {
      value = buildPlaylistCoverPreset(_paletteId, _iconId);
    } else if (_mode == 'image') {
      if (_imagePath == null || _imagePath!.isEmpty) return;
      value = _imagePath;
    }

    setState(() => _saving = true);
    await widget.controller.setPlaylistCover(widget.playlist.id, _mode, value);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final previewPlaylist = UiPlaylistInfo(
      id: widget.playlist.id,
      name: widget.playlist.name,
      trackCount: widget.playlist.trackCount,
      cover: _mode == 'auto'
          ? null
          : _mode == 'gradient'
              ? buildPlaylistCoverPreset(_paletteId, _iconId)
              : _imagePath,
      albumCovers: widget.playlist.albumCovers,
      coverMode: _mode,
      coverValue: _mode == 'gradient'
          ? buildPlaylistCoverPreset(_paletteId, _iconId)
          : _imagePath,
    );

    final canSave = !_saving && (_mode != 'image' || (_imagePath?.isNotEmpty ?? false));

    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.border),
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
                  Text(
                    t('Playlist Cover'),
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  PlaylistCoverWidget(
                    playlist: previewPlaylist,
                    size: 96,
                    borderRadius: 10,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _ModeChip(
                          label: t('Auto 4-cover collage'),
                          selected: _mode == 'auto',
                          icon: Icons.grid_view_rounded,
                          onTap: () => setState(() => _mode = 'auto'),
                        ),
                        const SizedBox(height: 6),
                        _ModeChip(
                          label: t('Gradient + Icon'),
                          selected: _mode == 'gradient',
                          icon: Icons.gradient_rounded,
                          onTap: () => setState(() => _mode = 'gradient'),
                        ),
                        const SizedBox(height: 6),
                        _ModeChip(
                          label: t('Custom Image'),
                          selected: _mode == 'image',
                          icon: Icons.image_rounded,
                          onTap: () => setState(() => _mode = 'image'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (_mode == 'gradient') ...[
                const SizedBox(height: 16),
                Text(
                  t('Color Palette'),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final p in kPlaylistCoverPalettes)
                      GestureDetector(
                        onTap: () => setState(() => _paletteId = p.id),
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(colors: p.colors),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _paletteId == p.id
                                  ? Colors.white
                                  : AppColors.border,
                              width: _paletteId == p.id ? 2.5 : 1,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  t('Music Icon'),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final iconOpt in kPlaylistCoverIcons)
                      ChoiceChip(
                        label: Icon(iconOpt.icon, size: 18),
                        selected: _iconId == iconOpt.id,
                        onSelected: (_) => setState(() => _iconId = iconOpt.id),
                        selectedColor: AppColors.accentMuted,
                        backgroundColor: AppColors.canvas,
                        side: BorderSide(
                          color: _iconId == iconOpt.id
                              ? AppColors.accent
                              : AppColors.border,
                        ),
                      ),
                  ],
                ),
              ],
              if (_mode == 'image') ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _imagePath != null
                            ? t('Selected: {path}', {'path': _imagePath!})
                            : t('No image selected yet.'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton.icon(
                      onPressed: _saving ? null : _pickImage,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.textPrimary,
                        side: const BorderSide(color: AppColors.border),
                      ),
                      icon: const Icon(Icons.folder_open_rounded, size: 16),
                      label: Text(t('Choose Image...')),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed:
                        _saving ? null : () => Navigator.of(context).pop(),
                    child: Text(t('Cancel')),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: canSave ? _save : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: AppColors.canvas,
                    ),
                    child: Text(t('Save')),
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

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.label,
    required this.selected,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.accentMuted : AppColors.canvas,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? AppColors.accent : AppColors.border,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 16,
                color: selected ? AppColors.accent : AppColors.textSecondary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected ? AppColors.accent : AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
