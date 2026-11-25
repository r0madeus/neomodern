import 'dart:async';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';
import 'package:neomodern/ui/metadata_match_dialog.dart';
import 'package:neomodern/ui/tinted_backdrop.dart';
import 'package:neomodern/ui/track_menu.dart';

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
    if (widget.externalAlbumId != null &&
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
                      color: AppColors.textMuted,
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
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                      if (ctrl.albumSearch.isEmpty) ...[
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: widget.onOpenSettings,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.accent,
                            side: const BorderSide(color: AppColors.border),
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
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(10),
                        ),
                      );
                    }
                    return _AlbumCard(
                      album: album,
                      isPinned: ctrl.isPinned('album', album.id),
                      onTogglePin: () => ctrl.togglePinned('album', album.id),
                      onTap: () => _openAlbum(album.id),
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
  });

  final UiAlbumRow album;
  final bool isPinned;
  final VoidCallback onTogglePin;
  final VoidCallback onTap;

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
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(10),
          hoverColor: AppColors.surfaceHover,
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
                        borderRadius: 6,
                        iconSize: 40,
                      ),
                      if (widget.isPinned || _hovered)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Material(
                            color: AppColors.canvas.withAlpha(195),
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
                                        ? AppColors.accent
                                        : AppColors.textPrimary,
                                  ),
                                ),
                              ),
                            ),
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
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle.isNotEmpty ? subtitle : t('Unknown Artist'),
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

  @override
  Widget build(BuildContext context) {
    final album = detail.album;
    final activePath = controller.snapshot.current?.path;
    final isPinned = controller.isPinned('album', album.id);
    final tintColor = album.coverColor != null
        ? Color(album.coverColor!)
        : controller.coverColorCached(album.cover);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TintedBackdrop(
          tintColor: tintColor,
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
                label: Text(t('Back to Albums')),
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  CoverArt(
                    path: album.cover,
                    size: 148,
                    borderRadius: 10,
                    iconSize: 48,
                  ),
                  const SizedBox(width: 22),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          album.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                            letterSpacing: -0.4,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            if (album.albumArtist.isNotEmpty) ...[
                              HoverLinkText(
                                text: album.albumArtist,
                                onTap: () => onOpenArtist(album.albumArtist),
                                style: const TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w500,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              const Text(
                                ' · ',
                                style: TextStyle(
                                  fontSize: 13.5,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ],
                            Text(
                              [
                                if (album.year != null) '${album.year}',
                                t('{n} tracks', {'n': detail.tracks.length}),
                              ].join(' · '),
                              style: const TextStyle(
                                fontSize: 13.5,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 10,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              onPressed: detail.tracks.isNotEmpty
                                  ? () => controller.playAlbum(album.id, 0)
                                  : null,
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.accent,
                                foregroundColor: AppColors.canvas,
                              ),
                              icon:
                                  const Icon(Icons.play_arrow_rounded, size: 18),
                              label: Text(
                                t('Play'),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            OutlinedButton.icon(
                              onPressed: detail.tracks.isNotEmpty
                                  ? () => controller.playAlbum(
                                        album.id,
                                        0,
                                        shuffle: true,
                                      )
                                  : null,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.textPrimary,
                                side: const BorderSide(color: AppColors.border),
                              ),
                              icon: const Icon(Icons.shuffle_rounded, size: 17),
                              label: Text(t('Shuffle')),
                            ),
                            OutlinedButton.icon(
                              onPressed: () =>
                                  controller.togglePinned('album', album.id),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: isPinned
                                    ? AppColors.accent
                                    : AppColors.textPrimary,
                                side: BorderSide(
                                  color: isPinned
                                      ? AppColors.accent
                                      : AppColors.border,
                                ),
                              ),
                              icon: Icon(
                                isPinned
                                    ? Icons.push_pin_rounded
                                    : Icons.push_pin_outlined,
                                size: 16,
                              ),
                              label: Text(isPinned ? t('Unpin') : t('Pin')),
                            ),
                            OutlinedButton.icon(
                              onPressed: () async {
                                final updated = await showMetadataMatchDialog(
                                  context: context,
                                  controller: controller,
                                  album: album,
                                );
                                if (updated == true) {
                                  onReloadAlbum();
                                }
                              },
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.textSecondary,
                                side: const BorderSide(color: AppColors.border),
                              ),
                              icon: const Icon(
                                Icons.manage_search_rounded,
                                size: 17,
                              ),
                              label: Text(t('Match Metadata')),
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
            itemExtent: 50,
            itemBuilder: (context, index) {
              final track = detail.tracks[index];
              final isActive = activePath == track.path;
              final isFav = controller.isFavorite(track.id);
              final trackNo = track.trackNo ?? (index + 1);
              void playHere() => controller.playAlbum(album.id, index);

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
                    color: isActive ? AppColors.accentMuted : Colors.transparent,
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
                                  '$trackNo',
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    color: AppColors.textMuted,
                                    fontFeatures: [FontFeature.tabularFigures()],
                                  ),
                                ),
                        ),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
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
                              if (track.artist.isNotEmpty)
                                HoverLinkText(
                                  text: track.artist,
                                  onTap: () => onOpenArtist(track.artist),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        StarFavoriteButton(
                          isFavorite: isFav,
                          onPressed: () => controller.toggleFavorite(track.id),
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
