import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';
import 'package:neomodern/ui/tinted_backdrop.dart';
import 'package:neomodern/ui/widgets/motion_primitives.dart';
import 'package:neomodern/ui/widgets/smooth_scroll.dart';
import 'package:neomodern/ui/widgets/track_row.dart';

class GenreView extends StatefulWidget {
  const GenreView({
    super.key,
    required this.name,
    required this.controller,
    required this.onBack,
    required this.onOpenAlbum,
    required this.onOpenArtist,
    this.onFetchGenreDetail,
    this.onFetchGenreTracksPage,
  });

  final String name;
  final PlayerController controller;
  final VoidCallback onBack;
  final ValueChanged<PlatformInt64> onOpenAlbum;
  final ValueChanged<String> onOpenArtist;
  final Future<UiGenreDetail> Function(String genre)? onFetchGenreDetail;
  final Future<List<UiTrackRow>> Function(String genre, int offset, int limit)?
      onFetchGenreTracksPage;

  @override
  State<GenreView> createState() => _GenreViewState();
}

class _GenreViewState extends State<GenreView> {
  static const int _trackPageSize = 100;

  final SmoothScrollController _scrollCtrl = SmoothScrollController();
  UiGenreDetail? _detail;
  bool _loading = true;
  bool _loadingMore = false;
  List<UiTrackRow> _tracks = const [];
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant GenreView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.name != widget.name) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients || _loadingMore) return;
    final pos = _scrollCtrl.position;
    if (pos.pixels >= pos.maxScrollExtent - 400) {
      unawaited(_loadMore());
    }
  }

  Future<void> _load() async {
    final gen = ++_generation;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _tracks = const [];
      _error = null;
    });
    try {
      final fetcher =
          widget.onFetchGenreDetail ?? widget.controller.fetchGenreDetail;
      final detail = await fetcher(widget.name);
      if (!mounted || gen != _generation) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
      await _loadMore(expectedGen: gen);
    } catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadMore({int? expectedGen}) async {
    final d = _detail;
    if (d == null || _loadingMore || _tracks.length >= d.trackCount) return;
    final gen = expectedGen ?? _generation;
    setState(() => _loadingMore = true);
    try {
      final pageFetcher = widget.onFetchGenreTracksPage ??
          (String g, int offset, int limit) =>
              widget.controller.fetchGenreTracksPage(
                g,
                offset: offset,
                limit: limit,
              );
      final page = await pageFetcher(d.name, _tracks.length, _trackPageSize);
      if (!mounted || gen != _generation) return;
      setState(() {
        _tracks = [..._tracks, ...page];
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _error = e.toString();
        _loadingMore = false;
      });
    }
  }

  String _formatDurationSummary(BigInt ms) {
    final mins = ms.toInt() ~/ 60000;
    if (mins < 1) return t('< 1 min');
    final h = mins ~/ 60;
    final m = mins % 60;
    if (h == 0) return t('{m} min', {'m': m});
    return t('{h} hr {m} min', {'h': h, 'm': m});
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final d = _detail;
    final title = d?.name ?? widget.name;
    final baseColor = genreColor(title);
    final activePath = ctrl.snapshot.current?.path;
    final isPlayingGenre =
        ctrl.isPlaying && ctrl.snapshot.context == 'genre:$title';

    String? heroCover = d?.coverPath;
    if (heroCover == null || heroCover.isEmpty) {
      for (final a in d?.albums ?? const <UiAlbumRow>[]) {
        if (a.cover != null && a.cover!.isNotEmpty) {
          heroCover = a.cover;
          break;
        }
      }
    }
    if (heroCover == null || heroCover.isEmpty) {
      for (final tr in _tracks) {
        if (tr.cover != null && tr.cover!.isNotEmpty) {
          heroCover = tr.cover;
          break;
        }
      }
    }

    return SmoothScrollWrapper(
      controller: _scrollCtrl,
      child: ListView(
        controller: _scrollCtrl,
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: widget.onBack,
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.zinc300,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              ),
              icon: const Icon(Icons.arrow_back_rounded, size: 17),
              label: Text(t('Search')),
            ),
          ),
          const SizedBox(height: 10),
          TintedBackdrop.gradient(
            borderRadius: BorderRadius.circular(16),
            padding: const EdgeInsets.all(24),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [baseColor, AppTheme.zinc950],
            ),
            child: Wrap(
              spacing: 24,
              runSpacing: 16,
              crossAxisAlignment: WrapCrossAlignment.end,
              children: [
                Container(
                  width: 160,
                  height: 160,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: Colors.white.withValues(alpha: 0.15),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.40),
                        blurRadius: 24,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: heroCover != null && heroCover.isNotEmpty
                      ? CoverArt(
                          path: heroCover,
                          size: 160,
                          borderRadius: 12,
                          iconSize: 56,
                        )
                      : Center(
                          child: Icon(
                            Icons.music_note_rounded,
                            size: 64,
                            color: Colors.white.withValues(alpha: 0.85),
                          ),
                        ),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 260, maxWidth: 680),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t('Genre').toUpperCase(),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.2,
                          color: Colors.white.withValues(alpha: 0.75),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 40,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -1.0,
                          height: 1.1,
                          color: Colors.white,
                        ),
                      ),
                      if (d != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          [
                            d.trackCount == 1
                                ? t('{n} track', {'n': d.trackCount})
                                : t('{n} tracks', {'n': d.trackCount}),
                            if (d.albumCount > 0)
                              d.albumCount == 1
                                  ? t('{n} album', {'n': d.albumCount})
                                  : t('{n} albums', {'n': d.albumCount}),
                            if (d.totalDurationMs > BigInt.zero)
                              _formatDurationSummary(d.totalDurationMs),
                          ].join(' · '),
                          style: TextStyle(
                            fontSize: 13.5,
                            color: Colors.white.withValues(alpha: 0.75),
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          HoverPlayButton(
                            size: 48,
                            iconSize: 26,
                            isPlaying: isPlayingGenre,
                            onPressed: d != null && d.trackCount > 0
                                ? () {
                                    if (ctrl.snapshot.context ==
                                        'genre:${d.name}') {
                                      ctrl.togglePause();
                                    } else {
                                      ctrl.playGenre(d.name);
                                    }
                                  }
                                : null,
                          ),
                          const SizedBox(width: 12),
                          OutlinedButton.icon(
                            onPressed: d != null && d.trackCount > 0
                                ? () {
                                    final start =
                                        math.Random().nextInt(d.trackCount);
                                    ctrl.playGenre(
                                      d.name,
                                      shuffle: true,
                                      startIndex: start,
                                    );
                                  }
                                : null,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: BorderSide(
                                color: Colors.white.withValues(alpha: 0.25),
                              ),
                              shape: const StadiumBorder(),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 10,
                              ),
                            ),
                            icon: const Icon(Icons.shuffle_rounded, size: 17),
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
          const SizedBox(height: 24),
          if (_loading && d == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null && d == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Text(
                _error!,
                style: const TextStyle(color: AppTheme.danger),
              ),
            )
          else if (d != null && d.trackCount == 0)
            Text(
              t('No tracks found for this genre.'),
              style: const TextStyle(color: AppTheme.zinc400),
            )
          else if (d != null) ...[
            if (d.albums.isNotEmpty) ...[
              Text(
                t('Albums'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.zinc100,
                ),
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final w = constraints.maxWidth;
                  final cols = w >= 1040
                      ? 6
                      : w >= 840
                          ? 5
                          : w >= 640
                              ? 4
                              : w >= 440
                                  ? 3
                                  : 2;
                  return GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: cols,
                      childAspectRatio: 0.76,
                      crossAxisSpacing: 14,
                      mainAxisSpacing: 14,
                    ),
                    itemCount: d.albums.length,
                    itemBuilder: (context, index) {
                      final album = d.albums[index];
                      return _GenreAlbumCard(
                        album: album,
                        onTap: () => widget.onOpenAlbum(album.id),
                        onPlay: () => ctrl.playAlbum(album.id, 0),
                      );
                    },
                  );
                },
              ),
              const SizedBox(height: 28),
            ],
            Text(
              t('Songs'),
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppTheme.zinc100,
              ),
            ),
            const SizedBox(height: 10),
            for (var i = 0; i < _tracks.length; i++)
              SizedBox(
                height: 56,
                child: DesktopTrackRow(
                  indexLabel: '${i + 1}',
                  track: _tracks[i],
                  controller: ctrl,
                  isActive: activePath == _tracks[i].path,
                  horizontalPadding: 10,
                  numberColumnWidth: 36,
                  onTap: () => ctrl.playGenre(d.name, startIndex: i),
                  onPlay: () => ctrl.playGenre(d.name, startIndex: i),
                  onOpenArtist: widget.onOpenArtist,
                  onOpenAlbum: widget.onOpenAlbum,
                ),
              ),
            if (_loadingMore)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else if (_tracks.length < d.trackCount)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: OutlinedButton(
                    onPressed: _loadMore,
                    child: Text(t('Load more')),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _GenreAlbumCard extends StatefulWidget {
  const _GenreAlbumCard({
    required this.album,
    required this.onTap,
    required this.onPlay,
  });

  final UiAlbumRow album;
  final VoidCallback onTap;
  final VoidCallback onPlay;

  @override
  State<_GenreAlbumCard> createState() => _GenreAlbumCardState();
}

class _GenreAlbumCardState extends State<_GenreAlbumCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final album = widget.album;
    final subtitle = album.year != null
        ? '${album.albumArtist} · ${album.year}'
        : album.albumArtist;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Material(
        color: _hovered
            ? AppTheme.zinc800.withValues(alpha: 0.70)
            : AppTheme.zinc900.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CoverArt(
                        path: album.cover,
                        borderRadius: 8,
                        iconSize: 36,
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
                ),
                const SizedBox(height: 8),
                Text(
                  album.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.zinc100,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle.isNotEmpty ? subtitle : t('Unknown Artist'),
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
      ),
    );
  }
}
