import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/selection_bar.dart';
import 'package:neomodern/ui/track_menu.dart';
import 'package:neomodern/ui/widgets/collection_header.dart';
import 'package:neomodern/ui/widgets/track_row.dart';

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
    final controller = widget.controller;
    final tracks = controller.favoriteTracks;
    final activePath = controller.snapshot.current?.path;
    final isPlayingFavorites =
        controller.isPlaying && controller.snapshot.context == 'favorites';
    final totalDuration = _formatTotalDuration(tracks);
    final selectedTracks = _selectedIndices
        .where((i) => i >= 0 && i < tracks.length)
        .map((i) => tracks[i])
        .toList();

    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CollectionHeader(
              tint: const CoverTint(
                top: AppTheme.accent700,
                surface: Color(0xFF312E81),
                dim: AppTheme.accent200,
              ),
              label: t('PLAYLIST'),
              titleText: t('Favorites'),
              cover: Container(
                width: 208,
                height: 208,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      AppTheme.accent400,
                      Color(0xFF4F46E5),
                    ],
                  ),
                ),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.star_rounded,
                  size: 76,
                  color: Colors.white,
                ),
              ),
              meta: Text(
                totalDuration.isNotEmpty
                    ? '${tracks.length == 1 ? t('{n} starred track', {'n': tracks.length}) : t('{n} starred tracks', {'n': tracks.length})}, $totalDuration'
                    : (tracks.length == 1
                        ? t('{n} starred track', {'n': tracks.length})
                        : t('{n} starred tracks', {'n': tracks.length})),
              ),
              isPlaying: isPlayingFavorites,
              playEnabled: tracks.isNotEmpty,
              onPlay: () {
                if (controller.snapshot.context == 'favorites') {
                  controller.togglePause();
                } else {
                  controller.playFavorites(0);
                }
              },
              shuffleActive: controller.snapshot.shuffle,
              onShuffle: () => controller.playFavorites(0, shuffle: true),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: AppTheme.zinc800),
                ),
              ),
              child: Row(
                children: [
                  const SizedBox(
                    width: 40,
                    child: Text('#',
                        style:
                            TextStyle(fontSize: 11.5, color: AppTheme.zinc500)),
                  ),
                  Expanded(
                    flex: 4,
                    child: Text(t('Title'),
                        style: const TextStyle(
                            fontSize: 11.5, color: AppTheme.zinc500)),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(t('Artist'),
                        style: const TextStyle(
                            fontSize: 11.5, color: AppTheme.zinc500)),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(t('Album'),
                        style: const TextStyle(
                            fontSize: 11.5, color: AppTheme.zinc500)),
                  ),
                  const SizedBox(width: 36),
                  SizedBox(
                    width: 52,
                    child: Text(
                      t('Time'),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontSize: 11.5, color: AppTheme.zinc500),
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
                            color: AppTheme.zinc500,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            t('No favorite songs yet.'),
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: AppTheme.zinc100,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            t('Click the star icon on any track to add it here.'),
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppTheme.zinc400,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.only(
                        bottom: selectedTracks.isNotEmpty ? 76 : 12,
                      ),
                      itemCount: tracks.length,
                      itemExtent: 56,
                      itemBuilder: (context, index) {
                        final track = tracks[index];
                        final isActive = activePath == track.path;
                        final isSelected = _selectedIndices.contains(index);
                        void playHere() => controller.playFavorites(index);

                        return DesktopTrackRow(
                          indexLabel: '${index + 1}',
                          track: track,
                          controller: controller,
                          isActive: isActive,
                          isSelected: isSelected,
                          onTap: () => _handleRowTap(index),
                          onPlay: playHere,
                          onOpenArtist: widget.onOpenArtist,
                          onOpenAlbum: widget.onOpenAlbum,
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
