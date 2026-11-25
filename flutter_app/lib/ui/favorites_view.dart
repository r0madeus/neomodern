import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';
import 'package:neomodern/ui/selection_bar.dart';
import 'package:neomodern/ui/track_menu.dart';

class FavoritesView extends StatefulWidget {
  const FavoritesView({
    super.key,
    required this.controller,
    required this.onOpenArtist,
    required this.onOpenAlbum,
  });

  final PlayerController controller;
  final ValueChanged<String> onOpenArtist;
  final ValueChanged<PlatformInt64> onOpenAlbum;

  @override
  State<FavoritesView> createState() => _FavoritesViewState();
}

class _FavoritesViewState extends State<FavoritesView> {
  final Set<int> _selectedIndices = {};
  int? _selectionAnchor;

  void _handleRowTap(int index) {
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
    unawaited(widget.controller.playFavorites(index));
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final tracks = controller.favoriteTracks;
    final activePath = controller.snapshot.current?.path;
    final selectedTracks = _selectedIndices
        .where((i) => i >= 0 && i < tracks.length)
        .map((i) => tracks[i])
        .toList();

    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    width: 112,
                    height: 112,
                    decoration: BoxDecoration(
                      color: AppColors.accentMuted,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.accent.withAlpha(64)),
                    ),
                    child: const Icon(
                      Icons.star_rounded,
                      size: 52,
                      color: AppColors.accent,
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t('Favorites'),
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          tracks.length == 1
                              ? t('{n} starred track', {'n': tracks.length})
                              : t('{n} starred tracks', {'n': tracks.length}),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            FilledButton.icon(
                              onPressed: tracks.isNotEmpty
                                  ? () => controller.playFavorites(0)
                                  : null,
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.accent,
                                foregroundColor: AppColors.canvas,
                              ),
                              icon: const Icon(Icons.play_arrow_rounded,
                                  size: 18),
                              label: Text(
                                t('Play All'),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                            const SizedBox(width: 10),
                            OutlinedButton.icon(
                              onPressed: tracks.isNotEmpty
                                  ? () => controller.playFavorites(0,
                                      shuffle: true)
                                  : null,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.textPrimary,
                                side: const BorderSide(color: AppColors.border),
                              ),
                              icon:
                                  const Icon(Icons.shuffle_rounded, size: 17),
                              label: Text(t('Shuffle')),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: AppColors.border),
                  bottom: BorderSide(color: AppColors.border),
                ),
              ),
              child: Row(
                children: [
                  const SizedBox(
                    width: 40,
                    child: Text('#',
                        style: TextStyle(
                            fontSize: 11.5, color: AppColors.textMuted)),
                  ),
                  Expanded(
                    flex: 4,
                    child: Text(t('Title'),
                        style: const TextStyle(
                            fontSize: 11.5, color: AppColors.textMuted)),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(t('Artist'),
                        style: const TextStyle(
                            fontSize: 11.5, color: AppColors.textMuted)),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(t('Album'),
                        style: const TextStyle(
                            fontSize: 11.5, color: AppColors.textMuted)),
                  ),
                  const SizedBox(width: 36),
                  SizedBox(
                    width: 54,
                    child: Text(
                      t('Time'),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontSize: 11.5, color: AppColors.textMuted),
                    ),
                  ),
                  const SizedBox(width: 30),
                ],
              ),
            ),
            Expanded(
              child: tracks.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.star_outline_rounded,
                            size: 44,
                            color: AppColors.textMuted,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            t('No favorite songs yet.'),
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            t('Click the star icon on any track to add it here.'),
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.only(
                        bottom: selectedTracks.isNotEmpty ? 76 : 0,
                      ),
                      itemCount: tracks.length,
                      itemExtent: 54,
                      itemBuilder: (context, index) {
                        final track = tracks[index];
                        final isActive = activePath == track.path;
                        final isSelected = _selectedIndices.contains(index);
                        void playHere() => controller.playFavorites(index);

                        return GestureDetector(
                          onSecondaryTapDown: (d) => TrackMenu.show(
                            context: context,
                            globalPosition: d.globalPosition,
                            track: track,
                            controller: controller,
                            onPlay: playHere,
                            onOpenArtist: widget.onOpenArtist,
                            onOpenAlbum: widget.onOpenAlbum,
                          ),
                          child: InkWell(
                            onTap: () => _handleRowTap(index),
                            hoverColor: AppColors.surfaceHover,
                            child: Container(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 24),
                              color: isSelected
                                  ? AppColors.accent.withAlpha(42)
                                  : isActive
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
                                          : t('Unknown Artist'),
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
                                          : t('Unknown Album'),
                                      onTap: track.albumId != null
                                          ? () =>
                                              widget.onOpenAlbum(track.albumId!)
                                          : null,
                                    ),
                                  ),
                                  StarFavoriteButton(
                                    isFavorite: true,
                                    onPressed: () =>
                                        controller.toggleFavorite(track.id),
                                  ),
                                  const SizedBox(width: 6),
                                  SizedBox(
                                    width: 54,
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
                                  TrackMoreButton(
                                    track: track,
                                    controller: controller,
                                    onPlay: playHere,
                                    onOpenArtist: widget.onOpenArtist,
                                    onOpenAlbum: widget.onOpenAlbum,
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
        TrackSelectionBar(
          selectedCount: selectedTracks.length,
          allStarred: true,
          onAddToQueue: () async {
            await controller.enqueueManyTracks(
              selectedTracks.map((tr) => tr.path).toList(),
            );
            setState(() {
              _selectedIndices.clear();
              _selectionAnchor = null;
            });
          },
          onToggleStar: () async {
            await controller.setManyFavorites(
              selectedTracks.map((tr) => tr.id).toList(),
              false,
            );
            setState(() {
              _selectedIndices.clear();
              _selectionAnchor = null;
            });
          },
          onAddToPlaylist: () async {
            await showAddToPlaylistDialog(
              context: context,
              controller: controller,
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
