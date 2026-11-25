import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';
import 'package:neomodern/ui/genre_view.dart';
import 'package:neomodern/ui/widgets/motion_primitives.dart';
import 'package:neomodern/ui/widgets/smooth_scroll.dart';
import 'package:neomodern/ui/widgets/track_row.dart';

class SearchView extends StatefulWidget {
  const SearchView({
    super.key,
    required this.controller,
    required this.onOpenAlbum,
    required this.onOpenArtist,
    this.focusNonce = 0,
    this.onFetchGenres,
    this.onSearchArtists,
    this.onSearchAlbums,
    this.onSearchTracks,
    this.onSearchExternal,
  });

  final PlayerController controller;
  final ValueChanged<PlatformInt64> onOpenAlbum;
  final ValueChanged<String> onOpenArtist;
  final int focusNonce;
  final Future<List<UiGenreInfo>> Function()? onFetchGenres;
  final Future<List<UiArtistRow>> Function(String query)? onSearchArtists;
  final Future<List<UiAlbumRow>> Function(String query)? onSearchAlbums;
  final Future<List<UiTrackRow>> Function(String query)? onSearchTracks;
  final Future<List<UiExternalTrack>> Function(
    String providerId,
    String query,
  )? onSearchExternal;

  @override
  State<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<SearchView> {
  final TextEditingController _queryCtrl = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  Timer? _debounce;

  List<UiGenreInfo> _genres = const [];
  bool _genresLoaded = false;
  String? _selectedGenre;

  String _debouncedQuery = '';
  String _loadedQuery = '';
  List<UiArtistRow> _artists = const [];
  List<UiAlbumRow> _albums = const [];
  List<UiTrackRow> _tracks = const [];
  List<UiExternalTrack> _externalTracks = const [];
  bool _searchingExternal = false;
  int _searchEpoch = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadGenres());
    if (widget.focusNonce > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(covariant SearchView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNonce != oldWidget.focusNonce) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _queryCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadGenres() async {
    if (widget.onFetchGenres == null && !widget.controller.initialized) {
      if (mounted) setState(() => _genresLoaded = true);
      return;
    }
    try {
      final fetcher = widget.onFetchGenres ?? widget.controller.fetchGenres;
      final rows = await fetcher();
      if (!mounted) return;
      setState(() {
        _genres = rows;
        _genresLoaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _genresLoaded = true);
    }
  }

  void _onQueryChanged(String value) {
    final trimmed = value.trim();
    if (trimmed.isNotEmpty && _selectedGenre != null) {
      _selectedGenre = null;
    }
    setState(() {});
    _debounce?.cancel();
    if (trimmed.isEmpty) {
      _searchEpoch++;
      setState(() {
        _debouncedQuery = '';
        _loadedQuery = '';
        _artists = const [];
        _albums = const [];
        _tracks = const [];
        _externalTracks = const [];
        _searchingExternal = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      setState(() => _debouncedQuery = trimmed);
      unawaited(_runSearch(trimmed));
    });
  }

  void _clearSearch() {
    _queryCtrl.clear();
    _onQueryChanged('');
    _focusNode.requestFocus();
  }

  Future<void> _runSearch(String query) async {
    final epoch = ++_searchEpoch;
    final ctrl = widget.controller;
    final hasCustomLocal = widget.onSearchArtists != null ||
        widget.onSearchAlbums != null ||
        widget.onSearchTracks != null;

    if (!ctrl.initialized && !hasCustomLocal) {
      setState(() {
        _loadedQuery = query;
        _artists = const [];
        _albums = const [];
        _tracks = const [];
        _externalTracks = const [];
      });
      return;
    }

    try {
      final artistsFut = (widget.onSearchArtists ??
              (q) => ctrl.searchArtists(q, limit: 12))(query)
          .catchError((_) => const <UiArtistRow>[]);
      final albumsFut = (widget.onSearchAlbums ??
              (q) => ctrl.searchAlbums(q, limit: 12))(query)
          .catchError((_) => const <UiAlbumRow>[]);
      final tracksFut = (widget.onSearchTracks ??
              (q) => ctrl.searchTracks(q, limit: 25))(query)
          .catchError((_) => const <UiTrackRow>[]);

      final results = await Future.wait([artistsFut, albumsFut, tracksFut]);
      if (!mounted || epoch != _searchEpoch) return;
      setState(() {
        _artists = results[0] as List<UiArtistRow>;
        _albums = results[1] as List<UiAlbumRow>;
        _tracks = results[2] as List<UiTrackRow>;
        _loadedQuery = query;
      });
    } catch (_) {}

    final enabledProviders = ctrl.enabledSourceProviders;
    if (enabledProviders.isEmpty && widget.onSearchExternal == null) {
      return;
    }

    if (mounted && epoch == _searchEpoch) {
      setState(() => _searchingExternal = true);
    }
    try {
      final extLists = await Future.wait([
        for (final p in enabledProviders)
          (widget.onSearchExternal ??
                  (pid, q) => ctrl.searchExternalSource(pid, q, limit: 15))(
                p.id,
                query,
              )
              .catchError((_) => const <UiExternalTrack>[]),
      ]);
      if (!mounted || epoch != _searchEpoch) return;
      final merged = <UiExternalTrack>[
        for (final list in extLists) ...list,
      ];
      setState(() {
        _externalTracks = merged;
        _searchingExternal = false;
      });
    } catch (_) {
      if (!mounted || epoch != _searchEpoch) return;
      setState(() => _searchingExternal = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final trimmed = _queryCtrl.text.trim();
    final ctrl = widget.controller;

    if (trimmed.isEmpty && _selectedGenre != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSearchHeader(),
          Expanded(
            child: GenreView(
              name: _selectedGenre!,
              controller: ctrl,
              onBack: () => setState(() => _selectedGenre = null),
              onOpenAlbum: widget.onOpenAlbum,
              onOpenArtist: widget.onOpenArtist,
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSearchHeader(),
        Expanded(
          child: trimmed.isEmpty
              ? _buildBrowseView()
              : _buildResultsView(ctrl, trimmed),
        ),
      ],
    );
  }

  Widget _buildSearchHeader() {
    final hasText = _queryCtrl.text.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 14),
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          color: AppTheme.zinc900,
          borderRadius: BorderRadius.circular(9999),
          border: Border.all(
            color: _focusNode.hasFocus ? AppTheme.accent500 : AppTheme.zinc800,
          ),
        ),
        child: Row(
          children: [
            const SizedBox(width: 14),
            const Icon(
              Icons.search_rounded,
              size: 18,
              color: AppTheme.zinc400,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _queryCtrl,
                focusNode: _focusNode,
                onChanged: _onQueryChanged,
                style: const TextStyle(
                  fontSize: 13.5,
                  color: AppTheme.zinc100,
                ),
                decoration: InputDecoration(
                  hintText: t('Search songs, artists, albums...'),
                  hintStyle: const TextStyle(
                    fontSize: 13.5,
                    color: AppTheme.zinc500,
                  ),
                  filled: false,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
              ),
            ),
            if (hasText)
              IconButton(
                tooltip: t('Clear search'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(
                  Icons.close_rounded,
                  size: 16,
                  color: AppTheme.zinc400,
                ),
                onPressed: _clearSearch,
              )
            else
              Container(
                margin: const EdgeInsets.only(right: 12),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTheme.zinc800.withValues(alpha: 0.70),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: AppTheme.zinc700),
                ),
                child: const Text(
                  'Ctrl K',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.zinc400,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBrowseView() {
    if (!_genresLoaded) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_genres.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.zinc800.withValues(alpha: 0.70),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.search_rounded,
                  size: 28,
                  color: AppTheme.zinc400,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                t('Search your library'),
                style: const TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.zinc100,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                t('Type to search your local library.'),
                style: const TextStyle(
                  fontSize: 13.5,
                  color: AppTheme.zinc400,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return SmoothScrollWrapper(
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
        children: [
          Text(
            t('Browse all'),
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
              color: AppTheme.zinc100,
            ),
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              final cols = w >= 980
                  ? 5
                  : w >= 740
                      ? 4
                      : w >= 500
                          ? 3
                          : 2;
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: cols,
                  mainAxisExtent: 128,
                  crossAxisSpacing: 14,
                  mainAxisSpacing: 14,
                ),
                itemCount: _genres.length,
                itemBuilder: (context, index) {
                  final genre = _genres[index];
                  return _GenreBrowseCard(
                    genre: genre,
                    onTap: () => setState(() => _selectedGenre = genre.name),
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildResultsView(PlayerController ctrl, String trimmed) {
    final hasAnyLocal =
        _artists.isNotEmpty || _albums.isNotEmpty || _tracks.isNotEmpty;
    final doneLocal =
        _loadedQuery == _debouncedQuery && _debouncedQuery == trimmed;
    final activePath = ctrl.snapshot.current?.path;

    return SmoothScrollWrapper(
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
        children: [
          Text(
            t('In your library').toUpperCase(),
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.9,
              color: AppTheme.zinc400,
            ),
          ),
          const SizedBox(height: 12),
          if (!hasAnyLocal && doneLocal)
            Text(
              t('No matches in your library.'),
              style: const TextStyle(fontSize: 13.5, color: AppTheme.zinc400),
            ),
          if (_artists.isNotEmpty) ...[
            Text(
              t('Artists'),
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppTheme.zinc300,
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 176,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _artists.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final artist = _artists[index];
                  return _SearchArtistCard(
                    artist: artist,
                    onTap: () => widget.onOpenArtist(artist.name),
                    onPlay: () => ctrl.playArtist(artist.name),
                  );
                },
              ),
            ),
            const SizedBox(height: 22),
          ],
          if (_albums.isNotEmpty) ...[
            Text(
              t('Albums'),
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppTheme.zinc300,
              ),
            ),
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (context, constraints) {
                final w = constraints.maxWidth;
                final cols = w >= 1000
                    ? 6
                    : w >= 800
                        ? 5
                        : w >= 600
                            ? 4
                            : w >= 420
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
                  itemCount: _albums.length,
                  itemBuilder: (context, index) {
                    final album = _albums[index];
                    return _SearchAlbumCard(
                      album: album,
                      onTap: () => widget.onOpenAlbum(album.id),
                      onPlay: () => ctrl.playAlbum(album.id, 0),
                    );
                  },
                );
              },
            ),
            const SizedBox(height: 22),
          ],
          if (_tracks.isNotEmpty) ...[
            Text(
              t('Songs'),
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppTheme.zinc300,
              ),
            ),
            const SizedBox(height: 8),
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
                  onTap: () => ctrl.playTracks(
                    _tracks.map((tr) => tr.path).toList(),
                    i,
                  ),
                  onPlay: () => ctrl.playTracks(
                    _tracks.map((tr) => tr.path).toList(),
                    i,
                  ),
                  onOpenArtist: widget.onOpenArtist,
                  onOpenAlbum: widget.onOpenAlbum,
                ),
              ),
          ],
          if (ctrl.hasEnabledSourceProviders ||
              _externalTracks.isNotEmpty ||
              _searchingExternal) ...[
            const SizedBox(height: 28),
            Text(
              t('External Sources').toUpperCase(),
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.9,
                color: AppTheme.zinc400,
              ),
            ),
            const SizedBox(height: 10),
            if (_searchingExternal)
              Text(
                t('Searching...'),
                style: const TextStyle(fontSize: 13, color: AppTheme.zinc400),
              )
            else if (_externalTracks.isEmpty)
              Text(
                t('No matching tracks found.'),
                style: const TextStyle(fontSize: 13, color: AppTheme.zinc400),
              )
            else
              for (final tr in _externalTracks)
                ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  leading: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppTheme.zinc900,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AppTheme.zinc800),
                    ),
                    child: const Icon(
                      Icons.music_note_rounded,
                      size: 20,
                      color: AppTheme.accent400,
                    ),
                  ),
                  title: Text(
                    tr.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.zinc100,
                    ),
                  ),
                  subtitle: Text(
                    tr.album != null && tr.album!.isNotEmpty
                        ? '${tr.artist} · ${tr.album}'
                        : tr.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.zinc400,
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (tr.durationMs != null)
                        Text(
                          formatDurationMs(tr.durationMs),
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.zinc400,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: t('Play'),
                        icon: const Icon(
                          Icons.play_arrow_rounded,
                          color: AppTheme.accent400,
                        ),
                        onPressed: () => ctrl.playExternalTrack(tr),
                      ),
                    ],
                  ),
                  onTap: () => ctrl.playExternalTrack(tr),
                ),
          ],
        ],
      ),
    );
  }
}

class _GenreBrowseCard extends StatefulWidget {
  const _GenreBrowseCard({
    required this.genre,
    required this.onTap,
  });

  final UiGenreInfo genre;
  final VoidCallback onTap;

  @override
  State<_GenreBrowseCard> createState() => _GenreBrowseCardState();
}

class _GenreBrowseCardState extends State<_GenreBrowseCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final g = widget.genre;
    final bg = genreColor(g.name);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _hovered ? 1.02 : 1.0,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          child: Container(
            height: 128,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Stack(
              children: [
                if (_hovered)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                  ),
                if (g.coverPath != null && g.coverPath!.isNotEmpty)
                  Positioned(
                    right: -12,
                    bottom: -8,
                    child: Transform.rotate(
                      angle: 24 * math.pi / 180,
                      child: AnimatedScale(
                        scale: _hovered ? 1.05 : 1.0,
                        duration: const Duration(milliseconds: 150),
                        child: Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.45),
                                blurRadius: 14,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: CoverArt(
                            path: g.coverPath,
                            size: 80,
                            borderRadius: 8,
                            iconSize: 28,
                          ),
                        ),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 56, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        g.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        g.trackCount == 1
                            ? t('{n} track', {'n': g.trackCount})
                            : t('{n} tracks', {'n': g.trackCount}),
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.80),
                        ),
                      ),
                    ],
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

class _SearchArtistCard extends StatefulWidget {
  const _SearchArtistCard({
    required this.artist,
    required this.onTap,
    required this.onPlay,
  });

  final UiArtistRow artist;
  final VoidCallback onTap;
  final VoidCallback onPlay;

  @override
  State<_SearchArtistCard> createState() => _SearchArtistCardState();
}

class _SearchArtistCardState extends State<_SearchArtistCard> {
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
            ? AppTheme.zinc800.withValues(alpha: 0.70)
            : AppTheme.zinc900.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: 148,
            padding: const EdgeInsets.all(10),
            child: Column(
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
                            iconSize: 34,
                            fallbackIcon: Icons.person_rounded,
                          ),
                        ),
                      ),
                      Positioned(
                        right: 2,
                        bottom: 2,
                        child: HoverPlayButton(
                          size: 34,
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
                  artist.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.zinc100,
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

class _SearchAlbumCard extends StatefulWidget {
  const _SearchAlbumCard({
    required this.album,
    required this.onTap,
    required this.onPlay,
  });

  final UiAlbumRow album;
  final VoidCallback onTap;
  final VoidCallback onPlay;

  @override
  State<_SearchAlbumCard> createState() => _SearchAlbumCardState();
}

class _SearchAlbumCardState extends State<_SearchAlbumCard> {
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
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(12),
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
                    fontWeight: FontWeight.w600,
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
