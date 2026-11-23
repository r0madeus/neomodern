import 'dart:async';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';
import 'package:neomodern/ui/track_menu.dart';

class SongsView extends StatefulWidget {
  const SongsView({
    super.key,
    required this.controller,
    required this.onOpenArtist,
    required this.onOpenAlbum,
    required this.onOpenSettings,
  });

  final PlayerController controller;
  final ValueChanged<String> onOpenArtist;
  final ValueChanged<PlatformInt64> onOpenAlbum;
  final VoidCallback onOpenSettings;

  @override
  State<SongsView> createState() => _SongsViewState();
}

class _SongsViewState extends State<SongsView> {
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 180), () {
      widget.controller.setTrackSearch(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final activePath = ctrl.snapshot.current?.path;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 14),
          child: Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Songs', style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 2),
                  Text(
                    '${ctrl.trackCount} tracks',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              const SizedBox(width: 18),
              FilledButton.icon(
                onPressed: ctrl.trackCount > 0
                    ? () => ctrl.playAllFromSearch(0)
                    : null,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: AppColors.canvas,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                ),
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: const Text(
                  'Play All',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
              const Spacer(),
              SizedBox(
                width: 280,
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: _onSearchChanged,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Search songs, artists, albums...',
                    prefixIcon: const Icon(
                      Icons.search_rounded,
                      size: 18,
                      color: AppColors.textMuted,
                    ),
                    suffixIcon: _searchCtrl.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.close_rounded, size: 16),
                            onPressed: () {
                              _searchCtrl.clear();
                              ctrl.setTrackSearch('');
                              setState(() {});
                            },
                          )
                        : null,
                  ),
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppColors.border)),
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
          child: ctrl.trackCount == 0
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        ctrl.trackSearch.isNotEmpty
                            ? 'No matching songs found.'
                            : 'No songs in library yet.',
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                      if (ctrl.trackSearch.isEmpty) ...[
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: widget.onOpenSettings,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.accent,
                            side: const BorderSide(color: AppColors.border),
                          ),
                          icon: const Icon(Icons.folder_open_rounded, size: 17),
                          label: const Text('Add Music Folder in Settings'),
                        ),
                      ],
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: ctrl.trackCount,
                  itemExtent: 54,
                  itemBuilder: (context, index) {
                    final track = ctrl.trackAt(index);
                    if (track == null) {
                      return const _TrackRowSkeleton();
                    }
                    final isActive = activePath == track.path;
                    final isFav = ctrl.isFavorite(track.id);
                    void playHere() => ctrl.playAllFromSearch(index);

                    return GestureDetector(
                      onSecondaryTapDown: (d) => TrackMenu.show(
                        context: context,
                        globalPosition: d.globalPosition,
                        track: track,
                        controller: ctrl,
                        onPlay: playHere,
                        onOpenArtist: widget.onOpenArtist,
                        onOpenAlbum: widget.onOpenAlbum,
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
                                      ? () => widget.onOpenArtist(track.artist)
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
                                      ? () => widget.onOpenAlbum(track.albumId!)
                                      : null,
                                ),
                              ),
                              StarFavoriteButton(
                                isFavorite: isFav,
                                onPressed: () => ctrl.toggleFavorite(track.id),
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
                                    fontFeatures: [FontFeature.tabularFigures()],
                                  ),
                                ),
                              ),
                              TrackMoreButton(
                                track: track,
                                controller: ctrl,
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
    );
  }
}

class _TrackRowSkeleton extends StatelessWidget {
  const _TrackRowSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 24),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'Loading...',
          style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
        ),
      ),
    );
  }
}
