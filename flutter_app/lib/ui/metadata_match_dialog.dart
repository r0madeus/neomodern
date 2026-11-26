import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';

Future<bool?> showMetadataMatchDialog({
  required BuildContext context,
  required PlayerController controller,
  required UiAlbumRow album,
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => MetadataMatchDialog(
      controller: controller,
      album: album,
    ),
  );
}

class MetadataMatchDialog extends StatefulWidget {
  const MetadataMatchDialog({
    super.key,
    required this.controller,
    required this.album,
  });

  final PlayerController controller;
  final UiAlbumRow album;

  @override
  State<MetadataMatchDialog> createState() => _MetadataMatchDialogState();
}

class _MetadataMatchDialogState extends State<MetadataMatchDialog> {
  bool _loading = true;
  bool _applying = false;
  bool _undoing = false;
  bool _canUndo = false;
  bool _downloadCover = true;
  String? _error;
  List<UiAlbumMatchCandidate> _candidates = const [];
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        widget.controller.matchAlbumMetadata(widget.album.id),
        widget.controller.canUndoMetadata(),
      ]);
      if (!mounted) return;
      final candidates = results[0] as List<UiAlbumMatchCandidate>;
      final canUndo = results[1] as bool;
      setState(() {
        _candidates = candidates;
        _canUndo = canUndo;
        _selectedIndex = 0;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      var canUndo = false;
      try {
        canUndo = await widget.controller.canUndoMetadata();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _loading = false;
        _canUndo = canUndo;
        _error = e.toString();
      });
    }
  }

  Future<void> _apply() async {
    if (_candidates.isEmpty) return;
    final selected = _candidates[_selectedIndex];
    setState(() {
      _applying = true;
      _error = null;
    });
    try {
      final res = await widget.controller.applyAlbumMetadata(
        albumId: widget.album.id,
        releaseMbid: selected.releaseMbid,
        downloadCover: _downloadCover,
      );
      if (!mounted) return;
      if (res.failed.isNotEmpty && res.updated == 0) {
        setState(() {
          _applying = false;
          _error = res.failed.join('\n');
        });
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t('Applied metadata to {n} tracks', {'n': res.updated})),
          behavior: SnackBarBehavior.floating,
          width: 320,
        ),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _applying = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _undoLast() async {
    setState(() {
      _undoing = true;
      _error = null;
    });
    try {
      final count = await widget.controller.undoLastMetadata();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t('Undid {n} tracks', {'n': count})),
          behavior: SnackBarBehavior.floating,
          width: 300,
        ),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _undoing = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _applying || _undoing;
    final selected =
        _candidates.isNotEmpty && _selectedIndex < _candidates.length
            ? _candidates[_selectedIndex]
            : null;

    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.manage_search_rounded,
                    size: 20,
                    color: AppColors.accent,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t('Match Album Metadata'),
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        Text(
                          '${widget.album.title} · ${widget.album.albumArtist}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_canUndo)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: OutlinedButton.icon(
                        onPressed: busy ? null : _undoLast,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.textPrimary,
                          side: const BorderSide(color: AppColors.border),
                        ),
                        icon: const Icon(Icons.undo_rounded, size: 16),
                        label: Text(t('Undo Last Batch')),
                      ),
                    ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: busy ? null : () => Navigator.of(context).pop(),
                  ),
                ],
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
              Expanded(
                child: _loading
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(),
                            const SizedBox(height: 12),
                            Text(
                              t('Searching MusicBrainz...'),
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      )
                    : _candidates.isEmpty
                        ? Center(
                            child: Text(
                              t('No matching releases found on MusicBrainz.'),
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                              ),
                            ),
                          )
                        : Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SizedBox(
                                width: 280,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      t('Release Candidates'),
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.textSecondary,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Expanded(
                                      child: ListView.separated(
                                        itemCount: _candidates.length,
                                        separatorBuilder: (_, _) =>
                                            const SizedBox(height: 8),
                                        itemBuilder: (context, index) {
                                          final c = _candidates[index];
                                          final isSel = index == _selectedIndex;
                                          final details = [
                                            if (c.year != null) '${c.year}',
                                            if (c.country != null) c.country!,
                                            if (c.format != null) c.format!,
                                            t('{n} tracks', {'n': c.trackCount}),
                                          ].join(' · ');

                                          return Material(
                                            color: isSel
                                                ? AppColors.accentMuted
                                                : AppColors.canvas,
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            child: InkWell(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              onTap: busy
                                                  ? null
                                                  : () => setState(
                                                        () => _selectedIndex =
                                                            index,
                                                      ),
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.all(10),
                                                decoration: BoxDecoration(
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                  border: Border.all(
                                                    color: isSel
                                                        ? AppColors.accent
                                                        : AppColors.border,
                                                  ),
                                                ),
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Row(
                                                      children: [
                                                        Expanded(
                                                          child: Text(
                                                            c.title,
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style:
                                                                const TextStyle(
                                                              fontSize: 13,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w600,
                                                              color: AppColors
                                                                  .textPrimary,
                                                            ),
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                            width: 6),
                                                        Container(
                                                          padding:
                                                              const EdgeInsets
                                                                  .symmetric(
                                                            horizontal: 6,
                                                            vertical: 2,
                                                          ),
                                                          decoration:
                                                              BoxDecoration(
                                                            color: AppColors
                                                                .surface,
                                                            borderRadius:
                                                                BorderRadius
                                                                    .circular(
                                                                        4),
                                                          ),
                                                          child: Text(
                                                            '${c.score}',
                                                            style:
                                                                const TextStyle(
                                                              fontSize: 11,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w600,
                                                              color: AppColors
                                                                  .accent,
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                    const SizedBox(height: 2),
                                                    Text(
                                                      c.artist,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        fontSize: 12,
                                                        color: AppColors
                                                            .textSecondary,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 3),
                                                    Text(
                                                      details,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        fontSize: 11,
                                                        color:
                                                            AppColors.textMuted,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 16),
                              const VerticalDivider(
                                width: 1,
                                color: AppColors.border,
                              ),
                              const SizedBox(width: 16),
                              if (selected != null)
                                Expanded(
                                  child: _CandidateDiffPane(
                                    candidate: selected,
                                  ),
                                ),
                            ],
                          ),
              ),
              const SizedBox(height: 14),
              const Divider(height: 1, color: AppColors.border),
              const SizedBox(height: 12),
              Row(
                children: [
                  Checkbox(
                    value: _downloadCover,
                    onChanged: busy
                        ? null
                        : (v) => setState(() => _downloadCover = v ?? true),
                  ),
                  GestureDetector(
                    onTap: busy
                        ? null
                        : () =>
                            setState(() => _downloadCover = !_downloadCover),
                    child: Text(
                      t('Download cover art'),
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: busy ? null : () => Navigator.of(context).pop(),
                    child: Text(t('Cancel')),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: busy || selected == null ? null : _apply,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: AppColors.canvas,
                    ),
                    child: _applying
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.canvas,
                            ),
                          )
                        : Text(t('Confirm & Apply')),
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

class _CandidateDiffPane extends StatelessWidget {
  const _CandidateDiffPane({required this.candidate});

  final UiAlbumMatchCandidate candidate;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        Text(
          t('Album Field Changes'),
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 8),
        if (candidate.albumFields.isEmpty)
          Text(
            t('No field changes'),
            style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted),
          )
        else
          for (final d in candidate.albumFields) _FieldDiffRow(diff: d),
        const SizedBox(height: 16),
        Text(
          t('Track Changes'),
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 8),
        for (final tr in candidate.tracks)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.canvas,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        tr.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    if (!tr.matched)
                      Text(
                        t('Unmatched'),
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.textMuted,
                        ),
                      ),
                  ],
                ),
                if (tr.fields.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  for (final f in tr.fields) _FieldDiffRow(diff: f),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _FieldDiffRow extends StatelessWidget {
  const _FieldDiffRow({required this.diff});

  final UiMetadataFieldDiff diff;

  @override
  Widget build(BuildContext context) {
    final oldStr = diff.oldValue?.isNotEmpty == true ? diff.oldValue! : '—';
    final newStr = diff.newValue?.isNotEmpty == true ? diff.newValue! : '—';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(
              diff.field,
              style: const TextStyle(
                fontSize: 11.5,
                color: AppColors.textMuted,
              ),
            ),
          ),
          Expanded(
            child: Text(
              oldStr,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 6),
            child: Icon(
              Icons.arrow_forward_rounded,
              size: 13,
              color: AppColors.textMuted,
            ),
          ),
          Expanded(
            child: Text(
              newStr,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppColors.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
