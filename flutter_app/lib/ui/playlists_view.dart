import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant PlaylistsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playlistId != widget.playlistId) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final rows = await widget.controller.fetchPlaylistTracks(widget.playlistId);
      if (mounted) {
        setState(() {
          _tracks = rows;
          _loading = false;
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
      title: 'Rename Playlist',
      hintText: 'Playlist name',
      confirmLabel: 'Save',
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
        title: const Text('Delete Playlist', style: TextStyle(fontSize: 16)),
        content: Text('Delete "${pl.name}"? Your audio files will not be touched.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              foregroundColor: AppColors.canvas,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.controller.deletePlaylist(pl.id);
      widget.onPlaylistDeleted();
    }
  }

  Future<void> _removeTrackAt(int position) async {
    await widget.controller.removeTrackFromPlaylist(widget.playlistId, position);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final pl = ctrl.playlists.cast<UiPlaylistInfo?>().firstWhere(
          (p) => p?.id == widget.playlistId,
          orElse: () => null,
        );

    if (pl == null) {
      return const Center(
        child: Text(
          'Playlist not found.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
      );
    }

    final coverPaths = pl.cover != null && !pl.cover!.startsWith('preset:')
        ? [pl.cover!]
        : pl.albumCovers;
    final activePath = ctrl.snapshot.current?.path;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              CollageCover(
                coverPaths: coverPaths,
                size: 132,
                borderRadius: 10,
              ),
              const SizedBox(width: 22),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'PLAYLIST',
                      style: TextStyle(
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
                      '${_tracks.length} ${_tracks.length == 1 ? 'track' : 'tracks'}',
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
                          icon: const Icon(Icons.play_arrow_rounded, size: 18),
                          label: const Text(
                            'Play',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: _tracks.isNotEmpty
                              ? () => ctrl.playPlaylist(pl.id, 0, shuffle: true)
                              : null,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.textPrimary,
                            side: const BorderSide(color: AppColors.border),
                          ),
                          icon: const Icon(Icons.shuffle_rounded, size: 17),
                          label: const Text('Shuffle'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _rename(pl),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.textSecondary,
                            side: const BorderSide(color: AppColors.border),
                          ),
                          icon: const Icon(Icons.edit_rounded, size: 16),
                          label: const Text('Rename'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _delete(pl),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.danger,
                            side: const BorderSide(color: AppColors.border),
                          ),
                          icon: const Icon(Icons.delete_outline_rounded, size: 17),
                          label: const Text('Delete'),
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
                  ? const Center(
                      child: Text(
                        'This playlist is empty. Right-click any song or use ... to add tracks.',
                        style: TextStyle(color: AppColors.textSecondary),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _tracks.length,
                      itemExtent: 54,
                      itemBuilder: (context, index) {
                        final track = _tracks[index];
                        final isActive = activePath == track.path;
                        final isFav = ctrl.isFavorite(track.id);
                        void playHere() => ctrl.playPlaylist(pl.id, index);

                        return GestureDetector(
                          onSecondaryTapDown: (d) => TrackMenu.show(
                            context: context,
                            globalPosition: d.globalPosition,
                            track: track,
                            controller: ctrl,
                            onPlay: playHere,
                            onOpenArtist: widget.onOpenArtist,
                            onOpenAlbum: widget.onOpenAlbum,
                            onRemoveFromPlaylist: () => _removeTrackAt(index),
                          ),
                          child: InkWell(
                            onTap: playHere,
                            hoverColor: AppColors.surfaceHover,
                            child: Container(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 24),
                              color: isActive
                                  ? AppColors.accentMuted
                                  : Colors.transparent,
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 40,
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
                                                FontFeature.tabularFigures()
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
                                            overflow: TextOverflow.ellipsis,
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
                                          : 'Unknown Artist',
                                      onTap: track.artist.isNotEmpty
                                          ? () =>
                                              widget.onOpenArtist(track.artist)
                                          : null,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    flex: 3,
                                    child: HoverLinkText(
                                      text: track.album.isNotEmpty
                                          ? track.album
                                          : 'Unknown Album',
                                      onTap: track.albumId != null
                                          ? () =>
                                              widget.onOpenAlbum(track.albumId!)
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
                                    tooltip: 'Remove from Playlist',
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
                                    onPressed: () => _removeTrackAt(index),
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
                        );
                      },
                    ),
        ),
      ],
    );
  }
}
