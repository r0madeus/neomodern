import 'dart:math' as math;

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';
import 'package:neomodern/ui/track_menu.dart';
import 'package:neomodern/ui/widgets/collection_header.dart';
import 'package:neomodern/ui/widgets/motion_primitives.dart';
import 'package:neomodern/ui/widgets/smooth_scroll.dart';
import 'package:neomodern/ui/widgets/track_row.dart';

class HomeView extends StatefulWidget {
  const HomeView({
    super.key,
    required this.controller,
    required this.onOpenAlbum,
    required this.onOpenArtist,
    required this.onOpenFavorites,
    required this.onOpenSettings,
    this.onOpenRecap,
  });

  final PlayerController controller;
  final ValueChanged<PlatformInt64> onOpenAlbum;
  final ValueChanged<String> onOpenArtist;
  final VoidCallback onOpenFavorites;
  final VoidCallback onOpenSettings;
  final VoidCallback? onOpenRecap;

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
  UiHomeMixDetail? _selectedMix;
  bool _loadingMix = false;

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour >= 5 && hour < 12) return t('Good morning');
    if (hour >= 12 && hour < 17) return t('Good afternoon');
    if (hour >= 17 && hour < 22) return t('Good evening');
    return t('Good night');
  }

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

  Future<void> _shuffleLibrary(PlayerController ctrl) async {
    if (ctrl.trackCount <= 0) return;
    if (!ctrl.snapshot.shuffle) {
      await ctrl.toggleShuffle();
    }
    final startIdx = math.Random().nextInt(ctrl.trackCount);
    await ctrl.playAllFromSearch(startIdx);
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
                  color: AppTheme.accent950.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.library_music_rounded,
                  size: 32,
                  color: AppTheme.accent400,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                t('Welcome to NeoModern'),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.zinc100,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                t('Add a music folder in Settings to scan your local collection.'),
                style: const TextStyle(
                  fontSize: 13.5,
                  color: AppTheme.zinc400,
                ),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: widget.onOpenSettings,
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.accent500,
                  foregroundColor: AppTheme.zinc950,
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

    return SmoothScrollWrapper(
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        children: [
        // Greeting & toolbar pills
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.end,
          spacing: 16,
          runSpacing: 12,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _greeting(),
                  style: AppTheme.displayStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w400,
                    letterSpacing: -0.4,
                    color: AppTheme.editorialPaper,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  t('{songs} songs · {albums} albums', {
                    'songs': ctrl.trackCount,
                    'albums': ctrl.albumCount,
                  }),
                  style: AppTheme.monoStyle(
                    fontSize: 11.5,
                    color: AppTheme.zinc400,
                  ),
                ),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton.icon(
                  onPressed:
                      ctrl.trackCount > 0 ? () => _shuffleLibrary(ctrl) : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.editorialPaper,
                    foregroundColor: AppTheme.editorialInk,
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                  ),
                  icon: const Icon(Icons.shuffle_rounded, size: 16),
                  label: Text(
                    t('Shuffle'),
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (widget.onOpenRecap != null) ...[
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: widget.onOpenRecap,
                    style: OutlinedButton.styleFrom(
                      backgroundColor: AppTheme.zinc900.withValues(alpha: 0.70),
                      foregroundColor: AppTheme.zinc200,
                      side: const BorderSide(color: AppTheme.zinc800),
                      shape: const StadiumBorder(),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                    ),
                    icon: const Icon(
                      Icons.bar_chart_rounded,
                      size: 16,
                      color: AppTheme.accent400,
                    ),
                    label: Text(
                      t('Listening Stats'),
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 4),
                IconButton(
                  tooltip: t('Refresh Home'),
                  onPressed: ctrl.refreshHome,
                  icon: const Icon(
                    Icons.refresh_rounded,
                    size: 18,
                    color: AppTheme.zinc400,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 22),

        // Quick-Access Grid (4 cols on wide desktop, 56px tall cards)
        LayoutBuilder(
          builder: (context, constraints) {
            final cols = constraints.maxWidth >= 960
                ? 4
                : constraints.maxWidth >= 560
                    ? 2
                    : 1;
            const spacing = 10.0;
            final cardWidth =
                (constraints.maxWidth - spacing * (cols - 1)) / cols;

            final quickCards = <Widget>[
              SizedBox(
                width: cardWidth,
                child: _QuickAccessCard(
                  title: t('Favorites'),
                  subtitle: t('{n} starred tracks', {'n': ctrl.favoriteCount}),
                  isFavorites: true,
                  onTap: widget.onOpenFavorites,
                  onPlay: ctrl.favoriteCount > 0
                      ? () => ctrl.playFavorites(0)
                      : null,
                ),
              ),
              for (final album in recentAlbums.take(7))
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

        // Daily Mixes Shelf
        if (mixes.isNotEmpty) ...[
          const SizedBox(height: 28),
          _SectionHeader(title: t('Daily Mixes')),
          const SizedBox(height: 12),
          SizedBox(
            height: 244,
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

        // Recently Played Albums Shelf (160px wide cards)
        if (recentAlbums.isNotEmpty) ...[
          const SizedBox(height: 28),
          _SectionHeader(title: t('Recently Played')),
          const SizedBox(height: 12),
          SizedBox(
            height: 214,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: recentAlbums.length,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (context, index) {
                final album = recentAlbums[index];
                return _HomeAlbumCard(
                  album: album,
                  onTap: () => widget.onOpenAlbum(album.id),
                  onPlay: () => ctrl.playAlbum(album.id, 0),
                );
              },
            ),
          ),
        ],

        // Recently Added Albums Shelf (160px wide cards)
        if (addedAlbums.isNotEmpty) ...[
          const SizedBox(height: 28),
          _SectionHeader(title: t('Recently Added')),
          const SizedBox(height: 12),
          SizedBox(
            height: 214,
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

        // Recently Played Tracks
        if (recentTracks.isNotEmpty) ...[
          const SizedBox(height: 28),
          _SectionHeader(title: t('Recently Played')),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: AppTheme.zinc900.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.zinc800),
            ),
            child: Column(
              children: [
                for (var i = 0; i < recentTracks.length; i++) ...[
                  if (i > 0)
                    const Divider(height: 1, color: AppTheme.zinc800),
                  SizedBox(
                    height: 54,
                    child: DesktopTrackRow(
                      indexLabel: '${i + 1}',
                      track: recentTracks[i].track,
                      controller: ctrl,
                      isActive: ctrl.snapshot.current?.path ==
                          recentTracks[i].track.path,
                      horizontalPadding: 14,
                      numberColumnWidth: 32,
                      onTap: () => ctrl.playTracks(
                        recentTracks.map((r) => r.track.path).toList(),
                        i,
                        context: 'recent',
                      ),
                      onPlay: () => ctrl.playTracks(
                        recentTracks.map((r) => r.track.path).toList(),
                        i,
                        context: 'recent',
                      ),
                      onOpenArtist: widget.onOpenArtist,
                      onOpenAlbum: widget.onOpenAlbum,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(bottom: 8),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppTheme.hairline),
        ),
      ),
      child: Text(
        title,
        style: AppTheme.displayStyle(
          fontSize: 22,
          fontWeight: FontWeight.w400,
          color: AppTheme.editorialPaper,
          letterSpacing: -0.2,
        ),
      ),
    );
  }
}

class _QuickAccessCard extends StatefulWidget {
  const _QuickAccessCard({
    required this.title,
    required this.subtitle,
    this.coverPath,
    this.isFavorites = false,
    required this.onTap,
    this.onPlay,
  });

  final String title;
  final String subtitle;
  final String? coverPath;
  final bool isFavorites;
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
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: 56,
          decoration: BoxDecoration(
            color: _hovered
                ? AppTheme.zinc800.withValues(alpha: 0.80)
                : AppTheme.zinc900.withValues(alpha: 0.70),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: AppTheme.zinc800.withValues(alpha: 0.80),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(
            children: [
              if (widget.isFavorites)
                Container(
                  width: 56,
                  height: 56,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [AppTheme.accent400, Color(0xFF4F46E5)],
                    ),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.star_rounded,
                    color: Colors.white,
                    size: 24,
                  ),
                )
              else
                CoverArt(
                  path: widget.coverPath,
                  size: 56,
                  borderRadius: 0,
                  iconSize: 22,
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
                        color: AppTheme.zinc50,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      widget.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppTheme.zinc400,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.onPlay != null)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: HoverPlayButton(
                    size: 36,
                    reveal: true,
                    isParentHovered: _hovered,
                    onPressed: widget.onPlay,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MixCard extends StatefulWidget {
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
  State<_MixCard> createState() => _MixCardState();
}

class _MixCardState extends State<_MixCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final mix = widget.mix;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 184,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _hovered
                ? AppTheme.zinc800.withValues(alpha: 0.70)
                : AppTheme.zinc900.withValues(alpha: 0.50),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: AppTheme.zinc800.withValues(alpha: 0.70),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.30),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: MixCoverArt(
                      mix: mix,
                      size: 160,
                      borderRadius: 10,
                    ),
                  ),
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: HoverPlayButton(
                      size: 40,
                      reveal: true,
                      isParentHovered: _hovered,
                      onPressed: widget.onPlay,
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
                        color: AppTheme.zinc50,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: t('Save as Playlist'),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 24, minHeight: 24),
                    icon: const Icon(
                      Icons.playlist_add_rounded,
                      size: 16,
                      color: AppTheme.zinc400,
                    ),
                    onPressed: widget.onSave,
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
                  color: AppTheme.zinc400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeAlbumCard extends StatefulWidget {
  const _HomeAlbumCard({
    required this.album,
    required this.onTap,
    required this.onPlay,
  });

  final UiAlbumRow album;
  final VoidCallback onTap;
  final VoidCallback onPlay;

  @override
  State<_HomeAlbumCard> createState() => _HomeAlbumCardState();
}

class _HomeAlbumCardState extends State<_HomeAlbumCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final album = widget.album;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 160,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: _hovered
                ? AppTheme.zinc800.withValues(alpha: 0.60)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.30),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: CoverArt(
                      path: album.cover,
                      size: 144,
                      borderRadius: 8,
                      iconSize: 38,
                    ),
                  ),
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: HoverPlayButton(
                      size: 36,
                      reveal: true,
                      isParentHovered: _hovered,
                      onPressed: widget.onPlay,
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
                  color: AppTheme.zinc50,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                album.albumArtist.isNotEmpty
                    ? album.albumArtist
                    : t('Unknown Artist'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.zinc400,
                ),
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
    final firstCover =
        mix.coverPaths.isNotEmpty ? mix.coverPaths.first : null;
    final tint = tintFromColor(controller.coverColorCached(firstCover));

    return SmoothScrollWrapper(
      builder: (context, scrollController) => CustomScrollView(
        controller: scrollController,
        slivers: [
        SliverToBoxAdapter(
          child: CollectionHeader(
            tint: tint,
            label: t('Dynamic Mixes'),
            titleText: mix.title,
            onBack: onBack,
            backLabel: t('Back to Home'),
            cover: MixCoverArt(
              mix: mix,
              size: 208,
              borderRadius: 6,
            ),
            meta: Text('${mix.subtitle} • ${t('{n} tracks', {'n': detail.tracks.length})}'),
            playEnabled: detail.tracks.isNotEmpty,
            onPlay: () => controller.playHomeMix(mix.id),
            extraActions: [
              OutlinedButton.icon(
                onPressed: onSavePlaylist,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.25)),
                  shape: const StadiumBorder(),
                ),
                icon: const Icon(Icons.playlist_add_rounded, size: 18),
                label: Text(t('Save as Playlist')),
              ),
            ],
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          sliver: SliverFixedExtentList.builder(
            itemCount: detail.tracks.length,
            itemExtent: 56,
            itemBuilder: (context, index) {
              final track = detail.tracks[index];
              final isActive = activePath == track.path;
              void playHere() =>
                  controller.playHomeMix(mix.id, startPath: track.path);

              return DesktopTrackRow(
                indexLabel: '${index + 1}',
                track: track,
                controller: controller,
                isActive: isActive,
                horizontalPadding: 14,
                numberColumnWidth: 36,
                onTap: playHere,
                onPlay: playHere,
                onOpenArtist: onOpenArtist,
                onOpenAlbum: onOpenAlbum,
              );
            },
          ),
        ),
      ],
      ),
    );
  }
}
