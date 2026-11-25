import 'dart:async';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';
import 'package:neomodern/ui/online_album_dialog.dart';
import 'package:neomodern/ui/tinted_backdrop.dart';
import 'package:neomodern/ui/widgets/motion_primitives.dart';
import 'package:neomodern/ui/widgets/smooth_scroll.dart';
import 'package:neomodern/ui/widgets/track_row.dart';

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
    if (widget.externalArtistName == null &&
        oldWidget.externalArtistName != null) {
      setState(() => _selectedArtist = null);
    } else if (widget.externalArtistName != null &&
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
        onDetailUpdated: (updated) => setState(() => _selectedArtist = updated),
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
                  Text(t('Artists'),
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 2),
                  Text(
                    t('{n} artists', {'n': ctrl.artistCount}),
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
                    hintText: t('Search artists...'),
                    prefixIcon: const Icon(
                      Icons.search_rounded,
                      size: 18,
                      color: AppTheme.zinc500,
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
                        ? t('No matching artists found.')
                        : t('No artists yet. Add a music folder in Settings.'),
                    style: const TextStyle(color: AppTheme.zinc400),
                  ),
                )
              : SmoothScrollWrapper(
                  builder: (context, scrollController) => GridView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
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
                            color: AppTheme.zinc900,
                            borderRadius: BorderRadius.circular(10),
                          ),
                        );
                      }
                      return _ArtistCard(
                        artist: artist,
                        onTap: () => _openArtist(artist.name),
                        onPlay: () => ctrl.playArtist(artist.name),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

class _ArtistCard extends StatefulWidget {
  const _ArtistCard({
    required this.artist,
    required this.onTap,
    required this.onPlay,
  });

  final UiArtistRow artist;
  final VoidCallback onTap;
  final VoidCallback onPlay;

  @override
  State<_ArtistCard> createState() => _ArtistCardState();
}

class _ArtistCardState extends State<_ArtistCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final artist = widget.artist;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Material(
        color: _hovered
            ? AppTheme.zinc800.withValues(alpha: 0.75)
            : AppTheme.zinc900.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      Center(
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
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: HoverPlayButton(
                          size: 38,
                          reveal: true,
                          isParentHovered: _hovered,
                          onPressed: widget.onPlay,
                        ),
                      ),
                    ],
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
                    color: AppTheme.zinc100,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  t('{albums} albums · {tracks} tracks', {
                    'albums': artist.albumCount,
                    'tracks': artist.trackCount,
                  }),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppTheme.zinc400,
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

class _ArtistDetailView extends StatefulWidget {
  const _ArtistDetailView({
    required this.detail,
    required this.controller,
    required this.onBack,
    this.onDetailUpdated,
    required this.onOpenAlbum,
    required this.onOpenArtist,
  });

  final UiArtistDetail detail;
  final PlayerController controller;
  final VoidCallback onBack;
  final ValueChanged<UiArtistDetail>? onDetailUpdated;
  final ValueChanged<PlatformInt64> onOpenAlbum;
  final ValueChanged<String> onOpenArtist;

  @override
  State<_ArtistDetailView> createState() => _ArtistDetailViewState();
}

class _ArtistDetailViewState extends State<_ArtistDetailView> {
  late UiArtistDetail _detail;
  bool _backHovered = false;
  bool _shuffleHovered = false;
  bool _enriching = false;
  bool _bioExpanded = false;

  @override
  void initState() {
    super.initState();
    _detail = widget.detail;
  }

  @override
  void didUpdateWidget(covariant _ArtistDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.detail != oldWidget.detail) {
      _detail = widget.detail;
      if (widget.detail.name != oldWidget.detail.name) {
        _enriching = false;
        _bioExpanded = false;
      }
    }
  }

  double _titleFontSize(String name) {
    if (name.length <= 14) return 64;
    if (name.length <= 28) return 52;
    return 40;
  }

  Future<void> _enrichArtist() async {
    if (_enriching) return;
    setState(() => _enriching = true);
    try {
      final enriched = await widget.controller.enrichArtist(_detail.name);
      if (!mounted) return;
      setState(() {
        if (enriched != null) {
          _detail = enriched;
        }
        _enriching = false;
      });
      if (enriched != null) {
        widget.onDetailUpdated?.call(enriched);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _enriching = false);
      }
    }
  }

  Widget _buildHeroImage(String? avatarPath, CoverTint tint) {
    final p = avatarPath?.trim();
    if (p != null && p.isNotEmpty) {
      if (p.startsWith('http://') || p.startsWith('https://')) {
        return Image.network(
          p,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => TintedBackdrop.gradient(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [tint.top, tint.surface],
            ),
          ),
        );
      }
      return CoverArt(
        path: p,
        borderRadius: 0,
        iconSize: 96,
        fallbackIcon: Icons.person_rounded,
      );
    }
    return TintedBackdrop.gradient(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [tint.top, tint.surface],
      ),
    );
  }

  Widget _buildAboutSection(String bio) {
    final trimmed = bio.trim();
    const bioStyle = TextStyle(
      fontSize: 14,
      height: 1.6,
      color: AppTheme.zinc300,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 28),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(
            t('About'),
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: AppTheme.zinc100,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppTheme.zinc900.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppTheme.zinc800),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final painter = TextPainter(
                      text: TextSpan(text: trimmed, style: bioStyle),
                      maxLines: 5,
                      textDirection: Directionality.of(context),
                    )..layout(maxWidth: constraints.maxWidth);
                    final overflows = painter.didExceedMaxLines;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          trimmed,
                          maxLines: _bioExpanded ? null : 5,
                          overflow: _bioExpanded
                              ? TextOverflow.visible
                              : TextOverflow.ellipsis,
                          style: bioStyle,
                        ),
                        if (overflows) ...[
                          const SizedBox(height: 10),
                          TextButton(
                            onPressed: () =>
                                setState(() => _bioExpanded = !_bioExpanded),
                            style: TextButton.styleFrom(
                              foregroundColor: AppTheme.accent400,
                              padding: EdgeInsets.zero,
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: Text(
                              _bioExpanded ? t('Show less') : t('Show more'),
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    final ctrl = widget.controller;
    final activePath = ctrl.snapshot.current?.path;
    final avatarPath = detail.image ?? detail.cover ?? detail.fallbackCover;
    final tintColor = ctrl.coverColorCached(avatarPath);
    final tint = tintFromColor(tintColor);
    final contextKey = 'artist:${detail.name.toLowerCase()}';
    final isPlayingArtist =
        ctrl.isPlaying && ctrl.snapshot.context == contextKey;

    return SmoothScrollWrapper(
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.only(bottom: 32),
        children: [
        // Full-bleed 290px hero banner with gradient overlay
        SizedBox(
          height: 290,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildHeroImage(avatarPath, tint),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0.0, 0.35, 1.0],
                    colors: [
                      Colors.black.withValues(alpha: 0.10),
                      Colors.black.withValues(alpha: 0.25),
                      Colors.black.withValues(alpha: 0.78),
                    ],
                  ),
                ),
              ),
              Positioned(
                top: 16,
                left: 16,
                child: Tooltip(
                  message: t('Back to Artists'),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    onEnter: (_) => setState(() => _backHovered = true),
                    onExit: (_) => setState(() => _backHovered = false),
                    child: GestureDetector(
                      onTap: widget.onBack,
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: _backHovered
                              ? Colors.black.withValues(alpha: 0.60)
                              : Colors.black.withValues(alpha: 0.40),
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.arrow_back_rounded,
                          size: 20,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 24,
                right: 24,
                bottom: 24,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      t('Artist'),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Colors.white.withValues(alpha: 0.90),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detail.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: _titleFontSize(detail.name),
                        fontWeight: FontWeight.w900,
                        height: 1.05,
                        letterSpacing: -1.4,
                        color: Colors.white,
                        shadows: [
                          Shadow(
                            color: Colors.black.withValues(alpha: 0.45),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      [
                        t('{n} albums', {'n': detail.albumCount}),
                        t('{n} tracks', {'n': detail.trackCount}),
                        if (detail.playCount > BigInt.zero)
                          t('{n} plays', {'n': detail.playCount}),
                      ].join(' • '),
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.white.withValues(alpha: 0.85),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // Tinted controls strip
        TintedBackdrop.gradient(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [tint.surface, Colors.transparent],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
            child: Row(
              children: [
                HoverPlayButton(
                  size: 56,
                  iconSize: 28,
                  isPlaying: isPlayingArtist,
                  onPressed: detail.tracks.isNotEmpty
                      ? () {
                          if (ctrl.snapshot.context == contextKey) {
                            ctrl.togglePause();
                          } else {
                            ctrl.playArtist(detail.name);
                          }
                        }
                      : null,
                ),
                const SizedBox(width: 16),
                Tooltip(
                  message: t('Shuffle'),
                  child: MouseRegion(
                    cursor: detail.tracks.isNotEmpty
                        ? SystemMouseCursors.click
                        : SystemMouseCursors.basic,
                    onEnter: (_) => setState(() => _shuffleHovered = true),
                    onExit: (_) => setState(() => _shuffleHovered = false),
                    child: GestureDetector(
                      onTap: detail.tracks.isNotEmpty
                          ? () => ctrl.playArtist(detail.name, shuffle: true)
                          : null,
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: _shuffleHovered
                              ? Colors.white.withValues(alpha: 0.15)
                              : Colors.transparent,
                          shape: BoxShape.circle,
                        ),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Icon(
                              Icons.shuffle_rounded,
                              size: 22,
                              color: ctrl.snapshot.shuffle
                                  ? AppTheme.accent400
                                  : Colors.white.withValues(alpha: 0.80),
                            ),
                            if (ctrl.snapshot.shuffle)
                              Positioned(
                                bottom: 3,
                                child: Container(
                                  width: 4,
                                  height: 4,
                                  decoration: const BoxDecoration(
                                    color: AppTheme.accent400,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (detail.genres.isNotEmpty) ...[
                  const SizedBox(width: 16),
                  Expanded(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final g in detail.genres)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(9999),
                            ),
                            child: Text(
                              g,
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.white.withValues(alpha: 0.85),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ] else
                  const Spacer(),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _enriching ? null : _enrichArtist,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white.withValues(alpha: 0.90),
                    disabledForegroundColor:
                        Colors.white.withValues(alpha: 0.60),
                    backgroundColor: Colors.white.withValues(alpha: 0.06),
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.18),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    shape: const StadiumBorder(),
                  ),
                  icon: _enriching
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.refresh_rounded, size: 16),
                  label: Text(
                    t('Fetch artist info'),
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (detail.popularTracks.isNotEmpty) ...[
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    t('Popular Tracks'),
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.zinc100,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                for (var i = 0;
                    i < detail.popularTracks.take(5).length;
                    i++)
                  SizedBox(
                    height: 56,
                    child: DesktopTrackRow(
                      indexLabel: '${i + 1}',
                      track: detail.popularTracks[i].track,
                      controller: ctrl,
                      isActive:
                          activePath == detail.popularTracks[i].track.path,
                      showCover: true,
                      showArtist: false,
                      showArtistUnderTitle: true,
                      showAlbum: true,
                      playCount: detail.popularTracks[i].playCount,
                      horizontalPadding: 10,
                      numberColumnWidth: 30,
                      onTap: () => ctrl.playTracks(
                        detail.popularTracks
                            .map((t) => t.track.path)
                            .toList(),
                        i,
                        context: contextKey,
                      ),
                      onPlay: () => ctrl.playTracks(
                        detail.popularTracks
                            .map((t) => t.track.path)
                            .toList(),
                        i,
                        context: contextKey,
                      ),
                      onOpenAlbum: widget.onOpenAlbum,
                      onOpenArtist: widget.onOpenArtist,
                    ),
                  ),
              ],
              if (detail.albums.isNotEmpty) ...[
                const SizedBox(height: 28),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    t('Albums'),
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.zinc100,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 214,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    itemCount: detail.albums.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (context, index) {
                      final album = detail.albums[index];
                      return _ArtistAlbumShelfCard(
                        album: album,
                        onTap: () => widget.onOpenAlbum(album.id),
                        onPlay: () => ctrl.playAlbum(album.id, 0),
                      );
                    },
                  ),
                ),
              ],
              if (detail.onlineAlbums.isNotEmpty) ...[
                const SizedBox(height: 28),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    t('Online Albums'),
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.zinc100,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 214,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    itemCount: detail.onlineAlbums.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (context, index) {
                      final album = detail.onlineAlbums[index];
                      return _OnlineAlbumShelfCard(
                        album: album,
                        onTap: () => showOnlineAlbumModal(
                          context,
                          controller: ctrl,
                          album: album,
                        ),
                      );
                    },
                  ),
                ),
              ],
              if (detail.bio != null && detail.bio!.trim().isNotEmpty)
                _buildAboutSection(detail.bio!),
              const SizedBox(height: 28),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  t('All Tracks'),
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.zinc100,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              for (var i = 0; i < detail.tracks.length; i++)
                SizedBox(
                  height: 56,
                  child: DesktopTrackRow(
                    indexLabel: '${i + 1}',
                    track: detail.tracks[i],
                    controller: ctrl,
                    isActive: activePath == detail.tracks[i].path,
                    showCover: true,
                    showArtist: false,
                    showArtistUnderTitle: true,
                    showAlbum: true,
                    horizontalPadding: 10,
                    numberColumnWidth: 30,
                    onTap: () => ctrl.playArtist(detail.name, startIndex: i),
                    onPlay: () => ctrl.playArtist(detail.name, startIndex: i),
                    onOpenAlbum: widget.onOpenAlbum,
                    onOpenArtist: widget.onOpenArtist,
                  ),
                ),
            ],
          ),
        ),
      ],
      ),
    );
  }
}

class _ArtistAlbumShelfCard extends StatefulWidget {
  const _ArtistAlbumShelfCard({
    required this.album,
    required this.onTap,
    required this.onPlay,
  });

  final UiAlbumRow album;
  final VoidCallback onTap;
  final VoidCallback onPlay;

  @override
  State<_ArtistAlbumShelfCard> createState() => _ArtistAlbumShelfCardState();
}

class _ArtistAlbumShelfCardState extends State<_ArtistAlbumShelfCard> {
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
        child: Container(
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
                      iconSize: 36,
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
                  color: AppTheme.zinc100,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                album.year != null
                    ? '${album.year} · ${t('{n} tracks', {'n': album.trackCount})}'
                    : t('{n} tracks', {'n': album.trackCount}),
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

class _OnlineAlbumShelfCard extends StatefulWidget {
  const _OnlineAlbumShelfCard({
    required this.album,
    required this.onTap,
  });

  final UiOnlineAlbum album;
  final VoidCallback onTap;

  @override
  State<_OnlineAlbumShelfCard> createState() => _OnlineAlbumShelfCardState();
}

class _OnlineAlbumShelfCardState extends State<_OnlineAlbumShelfCard> {
  bool _hovered = false;

  String _subtitle(UiOnlineAlbum album) {
    final parts = <String>[
      if (album.year != null) '${album.year}',
      if (album.trackCount > 0) t('{n} tracks', {'n': album.trackCount}),
    ];
    if (parts.isNotEmpty) return parts.join(' · ');
    return album.artist;
  }

  @override
  Widget build(BuildContext context) {
    final album = widget.album;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
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
                child: _OnlineAlbumCover(
                  cover: album.cover,
                  coverUrl: album.coverUrl,
                  size: 144,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                album.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.zinc100,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _subtitle(album),
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

class _OnlineAlbumCover extends StatelessWidget {
  const _OnlineAlbumCover({
    required this.cover,
    required this.coverUrl,
    required this.size,
  });

  final String? cover;
  final String? coverUrl;
  final double size;

  Widget _placeholder() {
    return Container(
      width: size,
      height: size,
      color: AppTheme.zinc900,
      alignment: Alignment.center,
      child: const Icon(
        Icons.album_rounded,
        size: 36,
        color: AppTheme.zinc500,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final localOrPath = cover?.trim();
    final remote = coverUrl?.trim();
    if (localOrPath != null &&
        localOrPath.isNotEmpty &&
        !localOrPath.startsWith('http://') &&
        !localOrPath.startsWith('https://')) {
      return CoverArt(
        path: localOrPath,
        size: size,
        borderRadius: 8,
        iconSize: 36,
      );
    }

    final url = (localOrPath != null &&
            (localOrPath.startsWith('http://') ||
                localOrPath.startsWith('https://')))
        ? localOrPath
        : remote;
    if (url != null && url.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          url,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _placeholder(),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: _placeholder(),
    );
  }
}
