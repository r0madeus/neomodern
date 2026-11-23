import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';
import 'package:neomodern/ui/track_menu.dart';

class FavoritesView extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final tracks = controller.favoriteTracks;
    final activePath = controller.snapshot.current?.path;

    return Column(
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
                      'Favorites',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${tracks.length} starred ${tracks.length == 1 ? 'track' : 'tracks'}',
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
                          icon: const Icon(Icons.play_arrow_rounded, size: 18),
                          label: const Text(
                            'Play All',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
                          onPressed: tracks.isNotEmpty
                              ? () => controller.playFavorites(0, shuffle: true)
                              : null,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.textPrimary,
                            side: const BorderSide(color: AppColors.border),
                          ),
                          icon: const Icon(Icons.shuffle_rounded, size: 17),
                          label: const Text('Shuffle'),
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
          child: const Row(
            children: [
              SizedBox(
                width: 40,
                child: Text('#',
                    style: TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
              ),
              Expanded(
                flex: 4,
                child: Text('Title',
                    style: TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
              ),
              Expanded(
                flex: 3,
                child: Text('Artist',
                    style: TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
              ),
              Expanded(
                flex: 3,
                child: Text('Album',
                    style: TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
              ),
              SizedBox(width: 36),
              SizedBox(
                width: 54,
                child: Text(
                  'Time',
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
                ),
              ),
              SizedBox(width: 30),
            ],
          ),
        ),
        Expanded(
          child: tracks.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.star_outline_rounded,
                        size: 44,
                        color: AppColors.textMuted,
                      ),
                      SizedBox(height: 10),
                      Text(
                        'No favorite songs yet.',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Click the star icon on any track to add it here.',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: tracks.length,
                  itemExtent: 54,
                  itemBuilder: (context, index) {
                    final track = tracks[index];
                    final isActive = activePath == track.path;
                    void playHere() => controller.playFavorites(index);

                    return GestureDetector(
                      onSecondaryTapDown: (d) => TrackMenu.show(
                        context: context,
                        globalPosition: d.globalPosition,
                        track: track,
                        controller: controller,
                        onPlay: playHere,
                        onOpenArtist: onOpenArtist,
                        onOpenAlbum: onOpenAlbum,
                      ),
                      child: InkWell(
                        onTap: playHere,
                        hoverColor: AppColors.surfaceHover,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
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
                                      ? () => onOpenArtist(track.artist)
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
                                      ? () => onOpenAlbum(track.albumId!)
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
                                onOpenArtist: onOpenArtist,
                                onOpenAlbum: onOpenAlbum,
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
