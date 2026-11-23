import 'dart:async';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';
import 'package:neomodern/ui/track_menu.dart';

class ArtistsView extends StatefulWidget {
  const ArtistsView({
    super.key,
    required this.controller,
    this.externalArtistName,
    this.externalSelectionNonce = 0,
    required this.onOpenAlbum,
    required this.onOpenArtist,
  });

  final PlayerController controller;
  final String? externalArtistName;
  final int externalSelectionNonce;
  final ValueChanged<PlatformInt64> onOpenAlbum;
  final ValueChanged<String> onOpenArtist;

  @override
  State<ArtistsView> createState() => _ArtistsViewState();
}

class _ArtistsViewState extends State<ArtistsView> {
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _debounce;
  UiArtistDetail? _selectedArtist;
  bool _loadingDetail = false;

  @override
  void initState() {
    super.initState();
    if (widget.externalArtistName != null) {
      unawaited(_openArtist(widget.externalArtistName!));
    }
  }

  @override
  void didUpdateWidget(covariant ArtistsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.externalArtistName != null &&
        (widget.externalArtistName != oldWidget.externalArtistName ||
            widget.externalSelectionNonce != oldWidget.externalSelectionNonce)) {
      unawaited(_openArtist(widget.externalArtistName!));
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 180), () {
      widget.controller.setArtistSearch(value);
    });
  }

  Future<void> _openArtist(String name) async {
    setState(() => _loadingDetail = true);
    try {
      final detail = await widget.controller.fetchArtistDetail(name);
      if (mounted) {
        setState(() {
          _selectedArtist = detail;
          _loadingDetail = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loadingDetail = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingDetail) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_selectedArtist != null) {
      return _ArtistDetailView(
        detail: _selectedArtist!,
        controller: widget.controller,
        onBack: () => setState(() => _selectedArtist = null),
        onOpenAlbum: widget.onOpenAlbum,
        onOpenArtist: widget.onOpenArtist,
      );
    }

    final ctrl = widget.controller;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
          child: Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Artists',
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 2),
                  Text(
                    '${ctrl.artistCount} artists',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              const Spacer(),
              SizedBox(
                width: 280,
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: _onSearchChanged,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Search artists...',
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
                              ctrl.setArtistSearch('');
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
        Expanded(
          child: ctrl.artistCount == 0
              ? Center(
                  child: Text(
                    ctrl.artistSearch.isNotEmpty
                        ? 'No matching artists found.'
                        : 'No artists yet. Add a music folder in Settings.',
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 200,
                    childAspectRatio: 0.78,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                  ),
                  itemCount: ctrl.artistCount,
                  itemBuilder: (context, index) {
                    final artist = ctrl.artistAt(index);
                    if (artist == null) {
                      return Container(
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(10),
                        ),
                      );
                    }
                    return _ArtistCard(
                      artist: artist,
                      onTap: () => _openArtist(artist.name),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _ArtistCard extends StatelessWidget {
  const _ArtistCard({required this.artist, required this.onTap});

  final UiArtistRow artist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        hoverColor: AppColors.surfaceHover,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: CoverArt(
                      path: artist.cover,
                      borderRadius: 999,
                      iconSize: 40,
                      fallbackIcon: Icons.person_rounded,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                artist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${artist.albumCount} albums · ${artist.trackCount} tracks',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArtistDetailView extends StatelessWidget {
  const _ArtistDetailView({
    required this.detail,
    required this.controller,
    required this.onBack,
    required this.onOpenAlbum,
    required this.onOpenArtist,
  });

  final UiArtistDetail detail;
  final PlayerController controller;
  final VoidCallback onBack;
  final ValueChanged<PlatformInt64> onOpenAlbum;
  final ValueChanged<String> onOpenArtist;

  @override
  Widget build(BuildContext context) {
    final activePath = controller.snapshot.current?.path;
    final avatarPath = detail.image ?? detail.fallbackCover;

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 28),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onBack,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.textSecondary,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            ),
            icon: const Icon(Icons.arrow_back_rounded, size: 18),
            label: const Text('Back to Artists'),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            CoverArt(
              path: avatarPath,
              size: 144,
              borderRadius: 72,
              iconSize: 52,
              fallbackIcon: Icons.person_rounded,
            ),
            const SizedBox(width: 22),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    detail.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    [
                      '${detail.albumCount} albums',
                      '${detail.trackCount} tracks',
                      if (detail.playCount > BigInt.zero)
                        '${detail.playCount} plays',
                    ].join(' · '),
                    style: const TextStyle(
                      fontSize: 13.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  if (detail.genres.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final g in detail.genres)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.surface,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: AppColors.border),
                            ),
                            child: Text(
                              g,
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: detail.tracks.isNotEmpty
                            ? () => controller.playArtist(detail.name)
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
                      const SizedBox(width: 10),
                      OutlinedButton.icon(
                        onPressed: detail.tracks.isNotEmpty
                            ? () => controller.playArtist(
                                  detail.name,
                                  shuffle: true,
                                )
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

        if (detail.popularTracks.isNotEmpty) ...[
          const SizedBox(height: 28),
          const Text(
            'Popular Tracks',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: [
                for (var i = 0; i < detail.popularTracks.take(5).length; i++) ...[
                  if (i > 0)
                    const Divider(height: 1, color: AppColors.border),
                  _ArtistTrackRow(
                    index: i,
                    track: detail.popularTracks[i].track,
                    playCount: detail.popularTracks[i].playCount,
                    isActive: activePath == detail.popularTracks[i].track.path,
                    controller: controller,
                    onPlay: () => controller.playTracks(
                      detail.popularTracks.map((t) => t.track.path).toList(),
                      i,
                      context: 'artist:${detail.name.toLowerCase()}',
                    ),
                    onOpenAlbum: onOpenAlbum,
                    onOpenArtist: onOpenArtist,
                  ),
                ],
              ],
            ),
          ),
        ],

        if (detail.albums.isNotEmpty) ...[
          const SizedBox(height: 28),
          const Text(
            'Albums',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 224,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: detail.albums.length,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (context, index) {
                final album = detail.albums[index];
                return SizedBox(
                  width: 168,
                  child: Material(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      onTap: () => onOpenAlbum(album.id),
                      borderRadius: BorderRadius.circular(10),
                      hoverColor: AppColors.surfaceHover,
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            CoverArt(
                              path: album.cover,
                              size: 146,
                              borderRadius: 6,
                              iconSize: 36,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              album.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              album.year != null
                                  ? '${album.year} · ${album.trackCount} tracks'
                                  : '${album.trackCount} tracks',
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
                    ),
                  ),
                );
              },
            ),
          ),
        ],

        const SizedBox(height: 28),
        const Text(
          'All Tracks',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children: [
              for (var i = 0; i < detail.tracks.length; i++) ...[
                if (i > 0) const Divider(height: 1, color: AppColors.border),
                _ArtistTrackRow(
                  index: i,
                  track: detail.tracks[i],
                  isActive: activePath == detail.tracks[i].path,
                  controller: controller,
                  onPlay: () => controller.playArtist(
                    detail.name,
                    startIndex: i,
                  ),
                  onOpenAlbum: onOpenAlbum,
                  onOpenArtist: onOpenArtist,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _ArtistTrackRow extends StatelessWidget {
  const _ArtistTrackRow({
    required this.index,
    required this.track,
    required this.isActive,
    required this.controller,
    required this.onPlay,
    required this.onOpenAlbum,
    required this.onOpenArtist,
    this.playCount,
  });

  final int index;
  final UiTrackRow track;
  final bool isActive;
  final PlayerController controller;
  final VoidCallback onPlay;
  final ValueChanged<PlatformInt64> onOpenAlbum;
  final ValueChanged<String> onOpenArtist;
  final BigInt? playCount;

  @override
  Widget build(BuildContext context) {
    final isFav = controller.isFavorite(track.id);

    return GestureDetector(
      onSecondaryTapDown: (d) => TrackMenu.show(
        context: context,
        globalPosition: d.globalPosition,
        track: track,
        controller: controller,
        onPlay: onPlay,
        onOpenArtist: onOpenArtist,
        onOpenAlbum: onOpenAlbum,
      ),
      child: InkWell(
        onTap: onPlay,
        hoverColor: AppColors.surfaceHover,
        child: Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          color: isActive ? AppColors.accentMuted : Colors.transparent,
          child: Row(
            children: [
              SizedBox(
                width: 32,
                child: isActive
                    ? const Icon(Icons.graphic_eq_rounded,
                        size: 16, color: AppColors.accent)
                    : Text(
                        '${index + 1}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textMuted,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
              ),
              CoverArt(
                path: track.cover,
                size: 36,
                borderRadius: 4,
                iconSize: 16,
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 4,
                child: Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                    color: isActive ? AppColors.accent : AppColors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 3,
                child: HoverLinkText(
                  text: track.album.isNotEmpty ? track.album : 'Unknown Album',
                  onTap: track.albumId != null
                      ? () => onOpenAlbum(track.albumId!)
                      : null,
                ),
              ),
              if (playCount != null && playCount! > BigInt.zero)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Text(
                    '$playCount plays',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textMuted,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              StarFavoriteButton(
                isFavorite: isFav,
                onPressed: () => controller.toggleFavorite(track.id),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 48,
                child: Text(
                  formatDurationMs(track.durationMs),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              TrackMoreButton(
                track: track,
                controller: controller,
                onPlay: onPlay,
                onOpenArtist: onOpenArtist,
                onOpenAlbum: onOpenAlbum,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
