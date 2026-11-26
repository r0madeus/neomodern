import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';

typedef ReadTagsCallback = Future<UiTrackTags> Function(String path);
typedef WriteTagsCallback = Future<void> Function(
  String path,
  UiTrackTags tags,
);

Future<bool?> showTagEditorDialog({
  required BuildContext context,
  required PlayerController controller,
  required UiTrackRow track,
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => TagEditorDialog(
      controller: controller,
      track: track,
    ),
  );
}

class TagEditorDialog extends StatefulWidget {
  const TagEditorDialog({
    super.key,
    required this.controller,
    required this.track,
    this.onReadTags,
    this.onWriteTags,
  });

  final PlayerController controller;
  final UiTrackRow track;
  final ReadTagsCallback? onReadTags;
  final WriteTagsCallback? onWriteTags;

  @override
  State<TagEditorDialog> createState() => _TagEditorDialogState();
}

class _TagEditorDialogState extends State<TagEditorDialog> {
  final _titleCtrl = TextEditingController();
  final _artistCtrl = TextEditingController();
  final _albumCtrl = TextEditingController();
  final _albumArtistCtrl = TextEditingController();
  final _trackNoCtrl = TextEditingController();
  final _discNoCtrl = TextEditingController();
  final _yearCtrl = TextEditingController();
  final _genreCtrl = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _artistCtrl.dispose();
    _albumCtrl.dispose();
    _albumArtistCtrl.dispose();
    _trackNoCtrl.dispose();
    _discNoCtrl.dispose();
    _yearCtrl.dispose();
    _genreCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final reader = widget.onReadTags ?? widget.controller.readTrackTags;
      final tags = await reader(widget.track.path);
      if (!mounted) return;
      _titleCtrl.text = tags.title ?? '';
      _artistCtrl.text = tags.artist ?? '';
      _albumCtrl.text = tags.album ?? '';
      _albumArtistCtrl.text = tags.albumArtist ?? '';
      _trackNoCtrl.text = tags.trackNumber?.toString() ?? '';
      _discNoCtrl.text = tags.discNumber?.toString() ?? '';
      _yearCtrl.text = tags.year?.toString() ?? '';
      _genreCtrl.text = tags.genre ?? '';
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  String? _cleanText(TextEditingController ctrl) {
    final v = ctrl.text.trim();
    return v.isEmpty ? null : v;
  }

  (int?, String?) _parseOptionalInt(
    TextEditingController ctrl,
    String errorKey,
  ) {
    final raw = ctrl.text.trim();
    if (raw.isEmpty) return (null, null);
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed < 0) {
      return (null, t(errorKey));
    }
    return (parsed, null);
  }

  Future<void> _save() async {
    final (trackNo, trackErr) =
        _parseOptionalInt(_trackNoCtrl, 'Track # must be a whole number');
    if (trackErr != null) {
      setState(() => _error = trackErr);
      return;
    }
    final (discNo, discErr) =
        _parseOptionalInt(_discNoCtrl, 'Disc # must be a whole number');
    if (discErr != null) {
      setState(() => _error = discErr);
      return;
    }
    final (year, yearErr) =
        _parseOptionalInt(_yearCtrl, 'Year must be a whole number');
    if (yearErr != null) {
      setState(() => _error = yearErr);
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    final tags = UiTrackTags(
      title: _cleanText(_titleCtrl),
      artist: _cleanText(_artistCtrl),
      album: _cleanText(_albumCtrl),
      albumArtist: _cleanText(_albumArtistCtrl),
      trackNumber: trackNo,
      discNumber: discNo,
      year: year,
      genre: _cleanText(_genreCtrl),
    );

    try {
      final writer = widget.onWriteTags ?? widget.controller.writeTrackTags;
      await writer(widget.track.path, tags);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 620),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.sell_outlined,
                    size: 19,
                    color: AppColors.accent,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      t('Edit Tags'),
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
                    onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                widget.track.path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppColors.textMuted,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.danger.withAlpha(32),
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
              const SizedBox(height: 14),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Center(child: CircularProgressIndicator()),
                )
              else
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        _TagField(
                          controller: _titleCtrl,
                          label: t('Track Title'),
                          enabled: !_saving,
                        ),
                        const SizedBox(height: 10),
                        _TagField(
                          controller: _artistCtrl,
                          label: t('Artist'),
                          enabled: !_saving,
                        ),
                        const SizedBox(height: 10),
                        _TagField(
                          controller: _albumCtrl,
                          label: t('Album'),
                          enabled: !_saving,
                        ),
                        const SizedBox(height: 10),
                        _TagField(
                          controller: _albumArtistCtrl,
                          label: t('Album Artist'),
                          enabled: !_saving,
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: _TagField(
                                controller: _trackNoCtrl,
                                label: t('Track #'),
                                enabled: !_saving,
                                keyboardType: TextInputType.number,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _TagField(
                                controller: _discNoCtrl,
                                label: t('Disc #'),
                                enabled: !_saving,
                                keyboardType: TextInputType.number,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _TagField(
                                controller: _yearCtrl,
                                label: t('Year'),
                                enabled: !_saving,
                                keyboardType: TextInputType.number,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        _TagField(
                          controller: _genreCtrl,
                          label: t('Genre'),
                          enabled: !_saving,
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 16),
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
                    onPressed: _loading || _saving ? null : _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: AppColors.canvas,
                    ),
                    child: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.canvas,
                            ),
                          )
                        : Text(t('Save')),
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

class _TagField extends StatelessWidget {
  const _TagField({
    required this.controller,
    required this.label,
    required this.enabled,
    this.keyboardType,
  });

  final TextEditingController controller;
  final String label;
  final bool enabled;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      keyboardType: keyboardType,
      style: const TextStyle(fontSize: 13.5),
      decoration: InputDecoration(labelText: label),
    );
  }
}
