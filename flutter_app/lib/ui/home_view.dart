import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';
import 'package:neomodern/ui/track_menu.dart';

class HomeView extends StatefulWidget {
  const HomeView({
    super.key,
    required this.controller,
    required this.onOpenAlbum,
    required this.onOpenArtist,
    required this.onOpenFavorites,
    required this.onOpenSettings,
  });

  final PlayerController controller;
  final ValueChanged<PlatformInt64> onOpenAlbum;
  final ValueChanged<String> onOpenArtist;
  final VoidCallback onOpenFavorites;
  final VoidCallback onOpenSettings;

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
  UiHomeMixDetail? _selectedMix;
  bool _loadingMix = false;

  Future<void> _openMix(String mixId) async {
    setState(() => _loadingMix = true);
    try {
      final detail = await widget.controller.fetchHomeMixDetail(mixId);
      if (mounted) {
        setState(() {
          _selectedMix = detail;
          _loadingMix = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loadingMix = false);
      }
    }
  }

  Future<void> _saveMixAsPlaylist(UiDynamicMix mix) async {
    final name = await showTextPromptDialog(
      context: context,
      title: t('Save Mix as Playlist'),
      hintText: t('Playlist name'),
      confirmLabel: t('Save'),
      initialValue: mix.title,
    );
    if (name == null) return;
    final created = await widget.controller.saveHomeMix(mix.id, name);
    if (created != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t('Saved "{name}"', {'name': created.name})),
          behavior: SnackBarBehavior.floating,
          width: 300,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingMix) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_selectedMix != null) {
      return _MixDetailView(
        detail: _selectedMix!,
        controller: widget.controller,
        onBack: () => setState(() => _selectedMix = null),
        onSavePlaylist: () => _saveMixAsPlaylist(_selectedMix!.mix),
        onOpenArtist: widget.onOpenArtist,
        onOpenAlbum: widget.onOpenAlbum,
      );
    }

    final ctrl = widget.controller;
    final feed = ctrl.homeFeed;

    if (ctrl.folders.isEmpty && ctrl.trackCount == 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: AppColors.accentMuted,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.library_music_rounded,
                  size: 32,
                  color: AppColors.accent,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                t('Welcome to NeoModern'),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                t('Add a music folder in Settings to scan your local collection.'),
                style: const TextStyle(
                  fontSize: 13.5,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: widget.onOpenSettings,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: AppColors.canvas,
                ),
                icon: const Icon(Icons.folder_open_rounded, size: 18),
                label: Text(
                  t('Open Folder Settings'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (feed == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final recentAlbums = feed.recentlyPlayedAlbums;
    final recentTracks = feed.recentlyPlayedTracks;
    final addedAlbums = feed.recentlyAddedAlbums;
    final mixes = feed.mixes;

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 28),
      children: [
        Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t('Home'),
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 2),
                Text(
                  t('{songs} songs · {albums} albums', {
                    'songs': ctrl.trackCount,
                    'albums': ctrl.albumCount,
                  }),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            const Spacer(),
            IconButton(
              tooltip: t('Refresh Home'),
              onPressed: ctrl.refreshHome,
              icon: const Icon(
                Icons.refresh_rounded,
                size: 19,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),

        // Quick Access Grid
        LayoutBuilder(
          builder: (context, constraints) {
            final cols = constraints.maxWidth >= 900
                ? 3
                : constraints.maxWidth >= 560
                    ? 2
                    : 1;
            const spacing = 12.0;
            final cardWidth =
                (constraints.maxWidth - spacing * (cols - 1)) / cols;

            final quickCards = <Widget>[
              SizedBox(
                width: cardWidth,
                child: _QuickAccessCard(
                  title: t('Favorites'),
                  subtitle: t('{n} starred tracks', {'n': ctrl.favoriteCount}),
                  icon: Icons.star_rounded,
                  onTap: widget.onOpenFavorites,
                  onPlay: ctrl.favoriteCount > 0
                      ? () => ctrl.playFavorites(0)
                      : null,
                ),
              ),
              for (final album in recentAlbums.take(5))
                SizedBox(
                  width: cardWidth,
                  child: _QuickAccessCard(
                    title: album.title,
                    subtitle: album.albumArtist.isNotEmpty
                        ? album.albumArtist
                        : t('Album'),
                    coverPath: album.cover,
                    onTap: () => widget.onOpenAlbum(album.id),
                    onPlay: () => ctrl.playAlbum(album.id, 0),
                  ),
                ),
            ];

            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: quickCards,
            );
          },
        ),

        if (mixes.isNotEmpty) ...[
          const SizedBox(height: 28),
          _SectionHeader(title: t('Dynamic Mixes')),
          const SizedBox(height: 12),
          SizedBox(
            height: 248,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: mixes.length,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (context, index) {
                final mix = mixes[index];
                return _MixCard(
                  mix: mix,
                  onTap: () => _openMix(mix.id),
                  onPlay: () => ctrl.playHomeMix(mix.id),
                  onSave: () => _saveMixAsPlaylist(mix),
                );
              },
            ),
          ),
        ],

        if (addedAlbums.isNotEmpty) ...[
          const SizedBox(height: 28),
          _SectionHeader(title: t('Recently Added')),
          const SizedBox(height: 12),
          SizedBox(
            height: 224,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: addedAlbums.length,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (context, index) {
                final album = addedAlbums[index];
                return _HomeAlbumCard(
                  album: album,
                  onTap: () => widget.onOpenAlbum(album.id),
                  onPlay: () => ctrl.playAlbum(album.id, 0),
                );
              },
            ),
          ),
        ],

        if (recentTracks.isNotEmpty) ...[
          const SizedBox(height: 28),
          _SectionHeader(title: t('Recently Played')),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: [
                for (var i = 0; i < recentTracks.length; i++) ...[
                  if (i > 0)
                    const Divider(height: 1, color: AppColors.border),
                  _RecentTrackRow(
                    track: recentTracks[i].track,
                    controller: ctrl,
                    onPlay: () => ctrl.playTracks(
                      recentTracks.map((r) => r.track.path).toList(),
                      i,
                      context: 'recent',
                    ),
                    onOpenArtist: widget.onOpenArtist,
                    onOpenAlbum: widget.onOpenAlbum,
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
        letterSpacing: -0.2,
      ),
    );
  }
}

class _QuickAccessCard extends StatefulWidget {
  const _QuickAccessCard({
    required this.title,
    required this.subtitle,
    this.coverPath,
    this.icon,
    required this.onTap,
    this.onPlay,
  });

  final String title;
  final String subtitle;
  final String? coverPath;
  final IconData? icon;
  final VoidCallback onTap;
  final VoidCallback? onPlay;

  @override
  State<_QuickAccessCard> createState() => _QuickAccessCardState();
}

class _QuickAccessCardState extends State<_QuickAccessCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Material(
        color: _hovered ? AppColors.surfaceHover : AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: 62,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                if (widget.icon != null)
                  Container(
                    width: 60,
                    height: 60,
                    decoration: const BoxDecoration(
                      color: AppColors.accentMuted,
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(7),
                        bottomLeft: Radius.circular(7),
                      ),
                    ),
                    child: Icon(widget.icon, color: AppColors.accent, size: 24),
                  )
                else
                  ClipRRect(
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(7),
                      bottomLeft: Radius.circular(7),
                    ),
                    child: CoverArt(
                      path: widget.coverPath,
                      size: 60,
                      borderRadius: 0,
                      iconSize: 22,
                    ),
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
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
                        widget.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_hovered && widget.onPlay != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: IconButton(
                      tooltip: 'Play',
                      style: IconButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: AppColors.canvas,
                      ),
                      icon: const Icon(Icons.play_arrow_rounded, size: 18),
                      onPressed: widget.onPlay,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MixCard extends StatelessWidget {
  const _MixCard({
    required this.mix,
    required this.onTap,
    required this.onPlay,
    required this.onSave,
  });

  final UiDynamicMix mix;
  final VoidCallback onTap;
  final VoidCallback onPlay;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 186,
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          hoverColor: AppColors.surfaceHover,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Stack(
                  children: [
                    CollageCover(
                      coverPaths: mix.coverPaths,
                      size: 160,
                      borderRadius: 6,
                    ),
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: Material(
                        color: AppColors.accent,
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: onPlay,
                          child: const SizedBox(
                            width: 34,
                            height: 34,
                            child: Icon(
                              Icons.play_arrow_rounded,
                              size: 20,
                              color: AppColors.canvas,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        mix.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Save as Playlist',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 26, minHeight: 26),
                      icon: const Icon(
                        Icons.playlist_add_rounded,
                        size: 17,
                        color: AppColors.textSecondary,
                      ),
                      onPressed: onSave,
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${mix.trackCount} tracks · ${mix.subtitle}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeAlbumCard extends StatelessWidget {
  const _HomeAlbumCard({
    required this.album,
    required this.onTap,
    required this.onPlay,
  });

  final UiAlbumRow album;
  final VoidCallback onTap;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 168,
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
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
                Stack(
                  children: [
                    CoverArt(
                      path: album.cover,
                      size: 146,
                      borderRadius: 6,
                      iconSize: 38,
                    ),
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: Material(
                        color: AppColors.accent,
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: onPlay,
                          child: const SizedBox(
                            width: 32,
                            height: 32,
                            child: Icon(
                              Icons.play_arrow_rounded,
                              size: 18,
                              color: AppColors.canvas,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
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
                  album.albumArtist.isNotEmpty
                      ? album.albumArtist
                      : 'Unknown Artist',
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
  }
}

class _RecentTrackRow extends StatelessWidget {
  const _RecentTrackRow({
    required this.track,
    required this.controller,
    required this.onPlay,
    required this.onOpenArtist,
    required this.onOpenAlbum,
  });

  final UiTrackRow track;
  final PlayerController controller;
  final VoidCallback onPlay;
  final ValueChanged<String> onOpenArtist;
  final ValueChanged<PlatformInt64> onOpenAlbum;

  @override
  Widget build(BuildContext context) {
    final isActive = controller.snapshot.current?.path == track.path;
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
                  text:
                      track.album.isNotEmpty ? track.album : 'Unknown Album',
                  onTap: track.albumId != null
                      ? () => onOpenAlbum(track.albumId!)
                      : null,
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

class _MixDetailView extends StatelessWidget {
  const _MixDetailView({
    required this.detail,
    required this.controller,
    required this.onBack,
    required this.onSavePlaylist,
    required this.onOpenArtist,
    required this.onOpenAlbum,
  });

  final UiHomeMixDetail detail;
  final PlayerController controller;
  final VoidCallback onBack;
  final VoidCallback onSavePlaylist;
  final ValueChanged<String> onOpenArtist;
  final ValueChanged<PlatformInt64> onOpenAlbum;

  @override
  Widget build(BuildContext context) {
    final mix = detail.mix;
    final activePath = controller.snapshot.current?.path;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextButton.icon(
                onPressed: onBack,
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.textSecondary,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                ),
                icon: const Icon(Icons.arrow_back_rounded, size: 18),
                label: const Text('Back to Home'),
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  CollageCover(
                    coverPaths: mix.coverPaths,
                    size: 140,
                    borderRadius: 10,
                  ),
                  const SizedBox(width: 22),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          mix.title,
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${mix.subtitle} · ${detail.tracks.length} tracks',
                          style: const TextStyle(
                            fontSize: 13.5,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            FilledButton.icon(
                              onPressed: detail.tracks.isNotEmpty
                                  ? () => controller.playHomeMix(mix.id)
                                  : null,
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.accent,
                                foregroundColor: AppColors.canvas,
                              ),
                              icon: const Icon(Icons.play_arrow_rounded,
                                  size: 18),
                              label: const Text(
                                'Play Mix',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                            ),
                            const SizedBox(width: 10),
                            OutlinedButton.icon(
                              onPressed: onSavePlaylist,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.textPrimary,
                                side: const BorderSide(color: AppColors.border),
                              ),
                              icon: const Icon(Icons.playlist_add_rounded,
                                  size: 18),
                              label: const Text('Save as Playlist'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: AppColors.border),
        Expanded(
          child: ListView.builder(
            itemCount: detail.tracks.length,
            itemExtent: 54,
            itemBuilder: (context, index) {
              final track = detail.tracks[index];
              final isActive = activePath == track.path;
              final isFav = controller.isFavorite(track.id);
              void playHere() =>
                  controller.playHomeMix(mix.id, startPath: track.path);

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
                    color:
                        isActive ? AppColors.accentMuted : Colors.transparent,
                    child: Row(
                      children: [
                        SizedBox(
                          width: 36,
                          child: isActive
                              ? const Icon(Icons.graphic_eq_rounded,
                                  size: 16, color: AppColors.accent)
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
                              fontWeight:
                                  isActive ? FontWeight.w600 : FontWeight.w500,
                              color: isActive
                                  ? AppColors.accent
                                  : AppColors.textPrimary,
                            ),
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
                          isFavorite: isFav,
                          onPressed: () => controller.toggleFavorite(track.id),
                        ),
                        const SizedBox(width: 6),
                        SizedBox(
                          width: 50,
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
