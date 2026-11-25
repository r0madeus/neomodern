import 'dart:async';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';
import 'package:neomodern/ui/metadata_match_dialog.dart';
import 'package:neomodern/ui/track_menu.dart';
import 'package:neomodern/ui/widgets/collection_header.dart';
import 'package:neomodern/ui/widgets/motion_primitives.dart';
import 'package:neomodern/ui/widgets/track_row.dart';

class AlbumsView extends StatefulWidget {
  const AlbumsView({
    super.key,
    required this.controller,
    this.externalAlbumId,
    this.externalSelectionNonce = 0,
    required this.onOpenArtist,
    required this.onOpenAlbum,
    required this.onOpenSettings,
  });

  final PlayerController controller;
  final PlatformInt64? externalAlbumId;
  final int externalSelectionNonce;
  final ValueChanged<String> onOpenArtist;
  final ValueChanged<PlatformInt64> onOpenAlbum;
  final VoidCallback onOpenSettings;

  @override
  State<AlbumsView> createState() => _AlbumsViewState();
}

class _AlbumsViewState extends State<AlbumsView> {
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _debounce;
  UiAlbumDetail? _selectedAlbum;
  bool _loadingDetail = false;

  @override
  void initState() {
    super.initState();
    if (widget.externalAlbumId != null) {
      unawaited(_openAlbum(widget.externalAlbumId!));
    }
  }

  @override
  void didUpdateWidget(covariant AlbumsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.externalAlbumId == null && oldWidget.externalAlbumId != null) {
      setState(() => _selectedAlbum = null);
    } else if (widget.externalAlbumId != null &&
        (widget.externalAlbumId != oldWidget.externalAlbumId ||
            widget.externalSelectionNonce != oldWidget.externalSelectionNonce)) {
      unawaited(_openAlbum(widget.externalAlbumId!));
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
      widget.controller.setAlbumSearch(value);
    });
  }

  Future<void> _openAlbum(PlatformInt64 albumId) async {
    setState(() => _loadingDetail = true);
    try {
      final detail = await widget.controller.fetchAlbumDetail(albumId);
      if (mounted) {
        setState(() {
          _selectedAlbum = detail;
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
    if (_selectedAlbum != null) {
      return _AlbumDetailView(
        detail: _selectedAlbum!,
        controller: widget.controller,
        onBack: () => setState(() => _selectedAlbum = null),
        onReloadAlbum: () => _openAlbum(_selectedAlbum!.album.id),
        onOpenArtist: widget.onOpenArtist,
        onOpenAlbum: widget.onOpenAlbum,
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
                  Text(t('Albums'),
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 2),
                  Text(
                    t('{n} albums', {'n': ctrl.albumCount}),
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
                    hintText: t('Search albums or artists...'),
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
                              ctrl.setAlbumSearch('');
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
          child: ctrl.albumCount == 0
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        ctrl.albumSearch.isNotEmpty
                            ? t('No matching albums found.')
                            : t('No albums yet.'),
                        style: const TextStyle(color: AppTheme.zinc400),
                      ),
                      if (ctrl.albumSearch.isEmpty) ...[
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: widget.onOpenSettings,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.accent400,
                            side: const BorderSide(color: AppTheme.zinc800),
                          ),
                          icon: const Icon(Icons.folder_open_rounded, size: 17),
                          label: Text(t('Add Music Folder in Settings')),
                        ),
                      ],
                    ],
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 200,
                    childAspectRatio: 0.76,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                  ),
                  itemCount: ctrl.albumCount,
                  itemBuilder: (context, index) {
                    final album = ctrl.albumAt(index);
                    if (album == null) {
                      return Container(
                        decoration: BoxDecoration(
                          color: AppTheme.zinc900,
                          borderRadius: BorderRadius.circular(10),
                        ),
                      );
                    }
                    return _AlbumCard(
                      album: album,
                      isPinned: ctrl.isPinned('album', album.id),
                      onTogglePin: () => ctrl.togglePinned('album', album.id),
                      onTap: () => _openAlbum(album.id),
                      onPlay: () => ctrl.playAlbum(album.id, 0),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _AlbumCard extends StatefulWidget {
  const _AlbumCard({
    required this.album,
    required this.isPinned,
    required this.onTogglePin,
    required this.onTap,
    required this.onPlay,
  });

  final UiAlbumRow album;
  final bool isPinned;
  final VoidCallback onTogglePin;
  final VoidCallback onTap;
  final VoidCallback onPlay;

  @override
  State<_AlbumCard> createState() => _AlbumCardState();
}

class _AlbumCardState extends State<_AlbumCard> {
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
            ? AppTheme.zinc800.withValues(alpha: 0.75)
            : AppTheme.zinc900.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(10),
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
                        iconSize: 40,
                      ),
                      if (widget.isPinned || _hovered)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Material(
                            color: AppTheme.zinc950.withValues(alpha: 0.78),
                            shape: const CircleBorder(),
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: widget.onTogglePin,
                              child: Tooltip(
                                message: widget.isPinned ? t('Unpin') : t('Pin'),
                                child: SizedBox(
                                  width: 28,
                                  height: 28,
                                  child: Icon(
                                    widget.isPinned
                                        ? Icons.push_pin_rounded
                                        : Icons.push_pin_outlined,
                                    size: 15,
                                    color: widget.isPinned
                                        ? AppTheme.accent400
                                        : AppTheme.zinc100,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      Positioned(
                        right: 6,
                        bottom: 6,
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

class _AlbumDetailView extends StatelessWidget {
  const _AlbumDetailView({
    required this.detail,
    required this.controller,
    required this.onBack,
    required this.onReloadAlbum,
    required this.onOpenArtist,
    required this.onOpenAlbum,
  });

  final UiAlbumDetail detail;
  final PlayerController controller;
  final VoidCallback onBack;
  final VoidCallback onReloadAlbum;
  final ValueChanged<String> onOpenArtist;
  final ValueChanged<PlatformInt64> onOpenAlbum;

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
    final album = detail.album;
    final activePath = controller.snapshot.current?.path;
    final isPinned = controller.isPinned('album', album.id);
    final tintColor = album.coverColor != null
        ? Color(album.coverColor!)
        : controller.coverColorCached(album.cover);
    final tint = tintFromColor(tintColor);
    final isAlbumPlaying = controller.isPlaying &&
        controller.snapshot.context == 'album:${album.id}';
    final totalDuration = _formatTotalDuration(detail.tracks);

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: CollectionHeader(
            tint: tint,
            label: t('Album'),
            titleText: album.title,
            onBack: onBack,
            backLabel: t('Back to Albums'),
            cover: CoverArt(
              path: album.cover,
              size: 208,
              borderRadius: 6,
              iconSize: 60,
            ),
            meta: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (album.albumArtist.isNotEmpty) ...[
                  HoverLinkText(
                    text: album.albumArtist,
                    onTap: () => onOpenArtist(album.albumArtist),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  const Text(' • '),
                ],
                if (album.year != null) ...[
                  Text('${album.year}'),
                  const Text(' • '),
                ],
                Text(
                  totalDuration.isNotEmpty
                      ? '${t('{n} tracks', {'n': detail.tracks.length})}, $totalDuration'
                      : t('{n} tracks', {'n': detail.tracks.length}),
                ),
              ],
            ),
            isPlaying: isAlbumPlaying,
            playEnabled: detail.tracks.isNotEmpty,
            onPlay: () {
              if (controller.snapshot.context == 'album:${album.id}') {
                controller.togglePause();
              } else {
                controller.playAlbum(album.id, 0);
              }
            },
            shuffleActive: controller.snapshot.shuffle,
            onShuffle: () =>
                controller.playAlbum(album.id, 0, shuffle: true),
            isPinned: isPinned,
            onTogglePin: () => controller.togglePinned('album', album.id),
            extraActions: [
              PopupMenuButton<String>(
                tooltip: t('More options'),
                color: AppTheme.zinc900,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: const BorderSide(color: AppTheme.zinc700),
                ),
                icon: Icon(
                  Icons.more_horiz_rounded,
                  size: 28,
                  color: Colors.white.withValues(alpha: 0.70),
                ),
                onSelected: (value) async {
                  if (value == 'playlist') {
                    await showAddToPlaylistDialog(
                      context: context,
                      controller: controller,
                      trackIds: detail.tracks.map((tr) => tr.id).toList(),
                    );
                  } else if (value == 'match') {
                    final updated = await showMetadataMatchDialog(
                      context: context,
                      controller: controller,
                      album: album,
                    );
                    if (updated == true) {
                      onReloadAlbum();
                    }
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem<String>(
                    value: 'playlist',
                    child: Row(
                      children: [
                        const Icon(
                          Icons.playlist_add_rounded,
                          size: 17,
                          color: AppTheme.zinc400,
                        ),
                        const SizedBox(width: 10),
                        Text(t('Add to Playlist...')),
                      ],
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'match',
                    child: Row(
                      children: [
                        const Icon(
                          Icons.manage_search_rounded,
                          size: 17,
                          color: AppTheme.zinc400,
                        ),
                        const SizedBox(width: 10),
                        Text(t('Match Metadata')),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        SliverToBoxAdapter(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 20),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppTheme.zinc800)),
            ),
            child: Row(
              children: [
                const SizedBox(
                  width: 38,
                  child: Text(
                    '#',
                    style: TextStyle(fontSize: 11.5, color: AppTheme.zinc500),
                  ),
                ),
                Expanded(
                  flex: 4,
                  child: Text(
                    t('Title'),
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppTheme.zinc500,
                    ),
                  ),
                ),
                const SizedBox(width: 110),
                SizedBox(
                  width: 52,
                  child: Text(
                    t('Time'),
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppTheme.zinc500,
                    ),
                  ),
                ),
                const SizedBox(width: 30),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          sliver: SliverFixedExtentList.builder(
            itemCount: detail.tracks.length,
            itemExtent: 56,
            itemBuilder: (context, index) {
              final track = detail.tracks[index];
              final isActive = activePath == track.path;
              final trackNo = track.trackNo ?? (index + 1);
              void playHere() => controller.playAlbum(album.id, index);

              return DesktopTrackRow(
                indexLabel: '$trackNo',
                track: track,
                controller: controller,
                isActive: isActive,
                showCover: false,
                showArtist: false,
                showArtistUnderTitle: true,
                showAlbum: false,
                playCount: BigInt.from(track.plays),
                horizontalPadding: 14,
                numberColumnWidth: 38,
                onTap: playHere,
                onPlay: playHere,
                onOpenArtist: onOpenArtist,
                onOpenAlbum: onOpenAlbum,
              );
            },
          ),
        ),
      ],
    );
  }
}
