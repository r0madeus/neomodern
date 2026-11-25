import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';
import 'package:neomodern/ui/playlist_cover_dialog.dart';
import 'package:neomodern/ui/selection_bar.dart';
import 'package:neomodern/ui/tinted_backdrop.dart';
import 'package:neomodern/ui/track_menu.dart';

class PlaylistsView extends StatefulWidget {
  const PlaylistsView({
    super.key,
    required this.playlistId,
    required this.controller,
    required this.onPlaylistDeleted,
    required this.onOpenArtist,
    required this.onOpenAlbum,
  });

  final PlatformInt64 playlistId;
  final PlayerController controller;
  final VoidCallback onPlaylistDeleted;
  final ValueChanged<String> onOpenArtist;
  final ValueChanged<PlatformInt64> onOpenAlbum;

  @override
  State<PlaylistsView> createState() => _PlaylistsViewState();
}

class _PlaylistsViewState extends State<PlaylistsView> {
  List<UiTrackRow> _tracks = const [];
  bool _loading = true;
  final Set<int> _selectedIndices = {};
  int? _selectionAnchor;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant PlaylistsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playlistId != widget.playlistId) {
      _selectedIndices.clear();
      _selectionAnchor = null;
      _load();
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final rows =
          await widget.controller.fetchPlaylistTracks(widget.playlistId);
      if (mounted) {
        setState(() {
          _tracks = rows;
          _loading = false;
          _selectedIndices.removeWhere((i) => i >= rows.length);
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _rename(UiPlaylistInfo pl) async {
    final name = await showTextPromptDialog(
      context: context,
      title: t('Rename Playlist'),
      hintText: t('Playlist name'),
      confirmLabel: t('Save'),
      initialValue: pl.name,
    );
    if (name != null) {
      await widget.controller.renamePlaylist(pl.id, name);
    }
  }

  Future<void> _delete(UiPlaylistInfo pl) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.border),
        ),
        title: Text(t('Delete Playlist'), style: const TextStyle(fontSize: 16)),
        content: Text(
          t('Delete "{name}"? Your audio files will not be touched.',
              {'name': pl.name}),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              foregroundColor: AppColors.canvas,
            ),
            child: Text(t('Delete')),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.controller.deletePlaylist(pl.id);
      widget.onPlaylistDeleted();
    }
  }

  Future<void> _exportM3u(UiPlaylistInfo pl) async {
    final sanitized = pl.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    final fileName = '${sanitized.isEmpty ? 'playlist' : sanitized}.m3u';
    final uri = await FilePicker.saveFile(
      dialogTitle: t('Export M3U'),
      fileName: fileName,
      bytes: Uint8List(0),
    );
    if (uri == null) return;
    final destPath = uri.isScheme('file') ? uri.toFilePath() : uri.toString();
    if (destPath.isEmpty) return;
    try {
      final count = await widget.controller.exportPlaylistM3u(pl.id, destPath);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t('Exported {n} tracks to M3U', {'n': count})),
          behavior: SnackBarBehavior.floating,
          width: 300,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString()),
          behavior: SnackBarBehavior.floating,
          width: 340,
        ),
      );
    }
  }

  Future<void> _removeTrackAt(int position) async {
    await widget.controller.removeTrackFromPlaylist(widget.playlistId, position);
    await _load();
  }

  Future<void> _reorderTrack(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex ||
        oldIndex < 0 ||
        newIndex < 0 ||
        oldIndex >= _tracks.length ||
        newIndex >= _tracks.length) {
      return;
    }
    final next = List<UiTrackRow>.from(_tracks);
    final moved = next.removeAt(oldIndex);
    next.insert(newIndex, moved);
    setState(() {
      _tracks = next;
      _selectedIndices.clear();
      _selectionAnchor = null;
    });
    await widget.controller.movePlaylistTrack(
      widget.playlistId,
      oldIndex,
      newIndex,
    );
  }

  void _handleRowTap(UiPlaylistInfo pl, int index) {
    final keys = HardwareKeyboard.instance;
    final ctrlHeld = keys.isControlPressed || keys.isMetaPressed;
    final shiftHeld = keys.isShiftPressed;

    if (shiftHeld) {
      final anchor = _selectionAnchor ?? index;
      final start = anchor < index ? anchor : index;
      final end = anchor > index ? anchor : index;
      setState(() {
        if (!ctrlHeld) _selectedIndices.clear();
        for (var i = start; i <= end; i++) {
          _selectedIndices.add(i);
        }
      });
      return;
    }

    if (ctrlHeld) {
      setState(() {
        if (_selectedIndices.contains(index)) {
          _selectedIndices.remove(index);
        } else {
          _selectedIndices.add(index);
        }
        _selectionAnchor = index;
      });
      return;
    }

    if (_selectedIndices.isNotEmpty) {
      setState(() {
        _selectedIndices.clear();
        _selectionAnchor = null;
      });
    }
    unawaited(widget.controller.playPlaylist(pl.id, index));
  }

  Color? _headerTint(PlayerController ctrl, UiPlaylistInfo pl) {
    final preset = parsePlaylistCoverPreset(pl.cover ?? pl.coverValue);
    if (preset != null) return preset.palette.heroTop;
    final path = pl.cover != null &&
            !pl.cover!.startsWith('preset:') &&
            pl.cover!.isNotEmpty
        ? pl.cover!
        : (pl.albumCovers.isNotEmpty ? pl.albumCovers.first : null);
    return ctrl.coverColorCached(path);
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final pl = ctrl.playlists.cast<UiPlaylistInfo?>().firstWhere(
          (p) => p?.id == widget.playlistId,
          orElse: () => null,
        );

    if (pl == null) {
      return Center(
        child: Text(
          t('Playlist not found.'),
          style: const TextStyle(color: AppColors.textSecondary),
        ),
      );
    }

    final activePath = ctrl.snapshot.current?.path;
    final isPinned = ctrl.isPinned('playlist', pl.id);
    final selectedTracks = _selectedIndices
        .where((i) => i >= 0 && i < _tracks.length)
        .map((i) => _tracks[i])
        .toList();
    final allStarred = selectedTracks.isNotEmpty &&
        selectedTracks.every((tr) => ctrl.isFavorite(tr.id));

    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TintedBackdrop(
              tintColor: _headerTint(ctrl, pl),
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  PlaylistCoverWidget(
                    playlist: pl,
                    size: 132,
                    borderRadius: 10,
                  ),
                  const SizedBox(width: 22),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t('PLAYLIST'),
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.0,
                            color: AppColors.textMuted,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          pl.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                            letterSpacing: -0.4,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _tracks.length == 1
                              ? t('{n} track', {'n': _tracks.length})
                              : t('{n} tracks', {'n': _tracks.length}),
                          style: const TextStyle(
                            fontSize: 13.5,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 10,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              onPressed: _tracks.isNotEmpty
                                  ? () => ctrl.playPlaylist(pl.id, 0)
                                  : null,
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.accent,
                                foregroundColor: AppColors.canvas,
                              ),
                              icon:
                                  const Icon(Icons.play_arrow_rounded, size: 18),
                              label: Text(
                                t('Play'),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            OutlinedButton.icon(
                              onPressed: _tracks.isNotEmpty
                                  ? () =>
                                      ctrl.playPlaylist(pl.id, 0, shuffle: true)
                                  : null,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.textPrimary,
                                side: const BorderSide(color: AppColors.border),
                              ),
                              icon: const Icon(Icons.shuffle_rounded, size: 17),
                              label: Text(t('Shuffle')),
                            ),
                            OutlinedButton.icon(
                              onPressed: () =>
                                  ctrl.togglePinned('playlist', pl.id),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: isPinned
                                    ? AppColors.accent
                                    : AppColors.textPrimary,
                                side: BorderSide(
                                  color: isPinned
                                      ? AppColors.accent
                                      : AppColors.border,
                                ),
                              ),
                              icon: Icon(
                                isPinned
                                    ? Icons.push_pin_rounded
                                    : Icons.push_pin_outlined,
                                size: 16,
                              ),
                              label: Text(isPinned ? t('Unpin') : t('Pin')),
                            ),
                            OutlinedButton.icon(
                              onPressed: () => showPlaylistCoverDialog(
                                context: context,
                                controller: ctrl,
                                playlist: pl,
                              ),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.textSecondary,
                                side: const BorderSide(color: AppColors.border),
                              ),
                              icon: const Icon(Icons.image_outlined, size: 16),
                              label: Text(t('Change Cover')),
                            ),
                            OutlinedButton.icon(
                              onPressed:
                                  _tracks.isNotEmpty ? () => _exportM3u(pl) : null,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.textSecondary,
                                side: const BorderSide(color: AppColors.border),
                              ),
                              icon: const Icon(Icons.ios_share_rounded, size: 16),
                              label: Text(t('Export M3U')),
                            ),
                            OutlinedButton.icon(
                              onPressed: () => _rename(pl),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.textSecondary,
                                side: const BorderSide(color: AppColors.border),
                              ),
                              icon: const Icon(Icons.edit_rounded, size: 16),
                              label: Text(t('Rename')),
                            ),
                            OutlinedButton.icon(
                              onPressed: () => _delete(pl),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.danger,
                                side: const BorderSide(color: AppColors.border),
                              ),
                              icon: const Icon(
                                Icons.delete_outline_rounded,
                                size: 17,
                              ),
                              label: Text(t('Delete')),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.border),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _tracks.isEmpty
                      ? Center(
                          child: Text(
                            t('This playlist is empty. Right-click any song or use ... to add tracks.'),
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                            ),
                          ),
                        )
                      : ReorderableListView.builder(
                          buildDefaultDragHandles: false,
                          padding: EdgeInsets.only(
                            bottom: selectedTracks.isNotEmpty ? 76 : 0,
                          ),
                          itemCount: _tracks.length,
                          itemExtent: 54,
                          onReorderItem: (oldIndex, newIndex) =>
                              unawaited(_reorderTrack(oldIndex, newIndex)),
                          itemBuilder: (context, index) {
                            final track = _tracks[index];
                            final isActive = activePath == track.path;
                            final isSelected =
                                _selectedIndices.contains(index);
                            final isFav = ctrl.isFavorite(track.id);
                            void playHere() => ctrl.playPlaylist(pl.id, index);

                            return Material(
                              key: ValueKey('pl-${pl.id}-${track.id}-$index'),
                              color: Colors.transparent,
                              child: GestureDetector(
                                onSecondaryTapDown: (d) => TrackMenu.show(
                                  context: context,
                                  globalPosition: d.globalPosition,
                                  track: track,
                                  controller: ctrl,
                                  onPlay: playHere,
                                  onOpenArtist: widget.onOpenArtist,
                                  onOpenAlbum: widget.onOpenAlbum,
                                  onRemoveFromPlaylist: () =>
                                      _removeTrackAt(index),
                                ),
                                child: InkWell(
                                  onTap: () => _handleRowTap(pl, index),
                                  hoverColor: AppColors.surfaceHover,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                    ),
                                    color: isSelected
                                        ? AppColors.accent.withAlpha(42)
                                        : isActive
                                            ? AppColors.accentMuted
                                            : Colors.transparent,
                                    child: Row(
                                      children: [
                                        ReorderableDragStartListener(
                                          index: index,
                                          child: const Padding(
                                            padding: EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 12,
                                            ),
                                            child: Icon(
                                              Icons.drag_indicator_rounded,
                                              size: 16,
                                              color: AppColors.textMuted,
                                            ),
                                          ),
                                        ),
                                        SizedBox(
                                          width: 34,
                                          child: isActive
                                              ? const Icon(
                                                  Icons.graphic_eq_rounded,
                                                  size: 16,
                                                  color: AppColors.accent,
                                                )
                                              : Text(
                                                  '${index + 1}',
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                    color: AppColors.textMuted,
                                                    fontFeatures: [
                                                      FontFeature
                                                          .tabularFigures()
                                                    ],
                                                  ),
                                                ),
                                        ),
                                        Expanded(
                                          flex: 4,
                                          child: Row(
                                            children: [
                                              CoverArt(
                                                path: track.cover,
                                                size: 36,
                                                borderRadius: 4,
                                                iconSize: 16,
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Text(
                                                  track.title,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 13.5,
                                                    fontWeight: isActive
                                                        ? FontWeight.w600
                                                        : FontWeight.w500,
                                                    color: isActive
                                                        ? AppColors.accent
                                                        : AppColors.textPrimary,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          flex: 3,
                                          child: HoverLinkText(
                                            text: track.artist.isNotEmpty
                                                ? track.artist
                                                : t('Unknown Artist'),
                                            onTap: track.artist.isNotEmpty
                                                ? () => widget.onOpenArtist(
                                                      track.artist,
                                                    )
                                                : null,
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          flex: 3,
                                          child: HoverLinkText(
                                            text: track.album.isNotEmpty
                                                ? track.album
                                                : t('Unknown Album'),
                                            onTap: track.albumId != null
                                                ? () => widget.onOpenAlbum(
                                                      track.albumId!,
                                                    )
                                                : null,
                                          ),
                                        ),
                                        StarFavoriteButton(
                                          isFavorite: isFav,
                                          onPressed: () =>
                                              ctrl.toggleFavorite(track.id),
                                        ),
                                        const SizedBox(width: 4),
                                        SizedBox(
                                          width: 52,
                                          child: Text(
                                            formatDurationMs(track.durationMs),
                                            textAlign: TextAlign.right,
                                            style: const TextStyle(
                                              fontSize: 12.5,
                                              color: AppColors.textMuted,
                                              fontFeatures: [
                                                FontFeature.tabularFigures()
                                              ],
                                            ),
                                          ),
                                        ),
                                        IconButton(
                                          tooltip: t('Remove from Playlist'),
                                          visualDensity: VisualDensity.compact,
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(
                                            minWidth: 30,
                                            minHeight: 30,
                                          ),
                                          icon: const Icon(
                                            Icons.close_rounded,
                                            size: 16,
                                            color: AppColors.textMuted,
                                          ),
                                          onPressed: () =>
                                              _removeTrackAt(index),
                                        ),
                                        TrackMoreButton(
                                          track: track,
                                          controller: ctrl,
                                          onPlay: playHere,
                                          onOpenArtist: widget.onOpenArtist,
                                          onOpenAlbum: widget.onOpenAlbum,
                                          onRemoveFromPlaylist: () =>
                                              _removeTrackAt(index),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
        TrackSelectionBar(
          selectedCount: selectedTracks.length,
          allStarred: allStarred,
          onAddToQueue: () async {
            await ctrl.enqueueManyTracks(
              selectedTracks.map((tr) => tr.path).toList(),
            );
            setState(() {
              _selectedIndices.clear();
              _selectionAnchor = null;
            });
          },
          onToggleStar: () async {
            await ctrl.setManyFavorites(
              selectedTracks.map((tr) => tr.id).toList(),
              !allStarred,
            );
          },
          onAddToPlaylist: () async {
            await showAddToPlaylistDialog(
              context: context,
              controller: ctrl,
              trackIds: selectedTracks.map((tr) => tr.id).toList(),
            );
          },
          onClear: () => setState(() {
            _selectedIndices.clear();
            _selectionAnchor = null;
          }),
        ),
      ],
    );
  }
}
