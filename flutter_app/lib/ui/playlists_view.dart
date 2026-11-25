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
import 'package:neomodern/ui/track_menu.dart';
import 'package:neomodern/ui/widgets/collection_header.dart';
import 'package:neomodern/ui/widgets/track_row.dart';

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
        backgroundColor: AppTheme.zinc900,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppTheme.zinc800),
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
              backgroundColor: AppTheme.danger,
              foregroundColor: AppTheme.zinc950,
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

  CoverTint _headerTint(PlayerController ctrl, UiPlaylistInfo pl) {
    final preset = parsePlaylistCoverPreset(
      pl.cover ?? (pl.coverMode == 'gradient' ? pl.coverValue : null),
    );
    if (preset != null) {
      return CoverTint(
        top: preset.palette.heroTop,
        surface: preset.palette.colors[1],
        dim: AppTheme.zinc300,
      );
    }
    final path = pl.cover != null &&
            !pl.cover!.startsWith('preset:') &&
            pl.cover!.isNotEmpty
        ? pl.cover!
        : (pl.albumCovers.isNotEmpty ? pl.albumCovers.first : null);
    return tintFromColor(ctrl.coverColorCached(path));
  }

  String _formatTotalDuration(List<UiTrackRow> tracks) {
    var totalMs = 0;
    for (final tr in tracks) {
      if (tr.durationMs != null) {
        totalMs += tr.durationMs!.toInt();
      }
    }
    if (totalMs <= 0) return '';
    return formatListeningDuration(BigInt.from(totalMs));
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
          style: const TextStyle(color: AppTheme.zinc400),
        ),
      );
    }

    final activePath = ctrl.snapshot.current?.path;
    final isPinned = ctrl.isPinned('playlist', pl.id);
    final isPlayingContext =
        ctrl.isPlaying && ctrl.snapshot.context == 'playlist:${pl.id}';
    final totalDuration = _formatTotalDuration(_tracks);
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
            CollectionHeader(
              tint: _headerTint(ctrl, pl),
              label: t('PLAYLIST'),
              titleText: pl.name,
              cover: PlaylistCoverWidget(
                playlist: pl,
                size: 208,
                borderRadius: 6,
              ),
              onCoverTap: () => showPlaylistCoverDialog(
                context: context,
                controller: ctrl,
                playlist: pl,
              ),
              meta: Text(
                totalDuration.isNotEmpty
                    ? '${_tracks.length == 1 ? t('{n} track', {'n': _tracks.length}) : t('{n} tracks', {'n': _tracks.length})}, $totalDuration'
                    : (_tracks.length == 1
                        ? t('{n} track', {'n': _tracks.length})
                        : t('{n} tracks', {'n': _tracks.length})),
              ),
              isPlaying: isPlayingContext,
              playEnabled: _tracks.isNotEmpty,
              onPlay: () {
                if (ctrl.snapshot.context == 'playlist:${pl.id}') {
                  ctrl.togglePause();
                } else {
                  ctrl.playPlaylist(pl.id, 0);
                }
              },
              shuffleActive: ctrl.snapshot.shuffle,
              onShuffle: () => ctrl.playPlaylist(pl.id, 0, shuffle: true),
              isPinned: isPinned,
              onTogglePin: () => ctrl.togglePinned('playlist', pl.id),
              extraActions: [
                PopupMenuButton<String>(
                  tooltip: t('More options'),
                  color: AppTheme.zinc900,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: const BorderSide(color: AppTheme.zinc700),
                  ),
                  icon: Icon(
                    Icons.more_horiz_rounded,
                    size: 28,
                    color: Colors.white.withValues(alpha: 0.70),
                  ),
                  onSelected: (value) async {
                    switch (value) {
                      case 'cover':
                        await showPlaylistCoverDialog(
                          context: context,
                          controller: ctrl,
                          playlist: pl,
                        );
                      case 'rename':
                        await _rename(pl);
                      case 'export':
                        await _exportM3u(pl);
                      case 'delete':
                        await _delete(pl);
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem<String>(
                      value: 'cover',
                      child: Row(
                        children: [
                          const Icon(
                            Icons.image_outlined,
                            size: 17,
                            color: AppTheme.zinc400,
                          ),
                          const SizedBox(width: 10),
                          Text(t('Change Cover')),
                        ],
                      ),
                    ),
                    PopupMenuItem<String>(
                      value: 'rename',
                      child: Row(
                        children: [
                          const Icon(
                            Icons.edit_rounded,
                            size: 17,
                            color: AppTheme.zinc400,
                          ),
                          const SizedBox(width: 10),
                          Text(t('Rename')),
                        ],
                      ),
                    ),
                    if (_tracks.isNotEmpty)
                      PopupMenuItem<String>(
                        value: 'export',
                        child: Row(
                          children: [
                            const Icon(
                              Icons.ios_share_rounded,
                              size: 17,
                              color: AppTheme.zinc400,
                            ),
                            const SizedBox(width: 10),
                            Text(t('Export M3U')),
                          ],
                        ),
                      ),
                    const PopupMenuDivider(),
                    PopupMenuItem<String>(
                      value: 'delete',
                      child: Row(
                        children: [
                          const Icon(
                            Icons.delete_outline_rounded,
                            size: 17,
                            color: AppTheme.danger,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            t('Delete'),
                            style: const TextStyle(color: AppTheme.danger),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: AppTheme.zinc800)),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 28),
                  const SizedBox(
                    width: 34,
                    child: Text(
                      '#',
                      style: TextStyle(fontSize: 11.5, color: AppTheme.zinc500),
                    ),
                  ),
                  Expanded(
                    flex: 4,
                    child: Text(
                      t('Title'),
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppTheme.zinc500,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      t('Artist'),
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppTheme.zinc500,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      t('Album'),
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppTheme.zinc500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 36),
                  SizedBox(
                    width: 52,
                    child: Text(
                      t('Time'),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppTheme.zinc500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 60),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _tracks.isEmpty
                      ? Center(
                          child: Text(
                            t('This playlist is empty. Right-click any song or use ... to add tracks.'),
                            style: const TextStyle(color: AppTheme.zinc400),
                          ),
                        )
                      : ReorderableListView.builder(
                          buildDefaultDragHandles: false,
                          padding: EdgeInsets.fromLTRB(
                            16,
                            4,
                            16,
                            selectedTracks.isNotEmpty ? 84 : 16,
                          ),
                          itemCount: _tracks.length,
                          itemExtent: 56,
                          onReorderItem: (oldIndex, newIndex) =>
                              unawaited(_reorderTrack(oldIndex, newIndex)),
                          itemBuilder: (context, index) {
                            final track = _tracks[index];
                            final isActive = activePath == track.path;
                            final isSelected =
                                _selectedIndices.contains(index);
                            void playHere() => ctrl.playPlaylist(pl.id, index);

                            return Material(
                              key: ValueKey('pl-${pl.id}-${track.id}-$index'),
                              color: Colors.transparent,
                              child: DesktopTrackRow(
                                indexLabel: '${index + 1}',
                                track: track,
                                controller: ctrl,
                                isActive: isActive,
                                isSelected: isSelected,
                                horizontalPadding: 14,
                                numberColumnWidth: 34,
                                leadingDragHandle: ReorderableDragStartListener(
                                  index: index,
                                  child: const Padding(
                                    padding: EdgeInsets.only(right: 10),
                                    child: MouseRegion(
                                      cursor: SystemMouseCursors.grab,
                                      child: Icon(
                                        Icons.drag_indicator_rounded,
                                        size: 16,
                                        color: AppTheme.zinc500,
                                      ),
                                    ),
                                  ),
                                ),
                                trailingAction: IconButton(
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
                                    color: AppTheme.zinc400,
                                  ),
                                  onPressed: () => _removeTrackAt(index),
                                ),
                                onTap: () => _handleRowTap(pl, index),
                                onPlay: playHere,
                                onOpenArtist: widget.onOpenArtist,
                                onOpenAlbum: widget.onOpenAlbum,
                                onRemoveFromPlaylist: () =>
                                    _removeTrackAt(index),
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
