import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';

class AlbumsView extends StatefulWidget {
  const AlbumsView({super.key, required this.controller});

  final PlayerController controller;

  @override
  State<AlbumsView> createState() => _AlbumsViewState();
}

class _AlbumsViewState extends State<AlbumsView> {
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _debounce;
  UiAlbumDetail? _selectedAlbum;
  bool _loadingDetail = false;

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
                  Text('Albums',
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 2),
                  Text(
                    '${ctrl.albumCount} albums',
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
                    hintText: 'Search albums or artists...',
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
                  child: Text(
                    ctrl.albumSearch.isNotEmpty
                        ? 'No matching albums found.'
                        : 'No albums yet. Add a music folder under Folders.',
                    style: const TextStyle(color: AppColors.textSecondary),
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
                      onTap: () => _openAlbum(album.id),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({required this.album, required this.onTap});

  final UiAlbumRow album;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final subtitle = album.year != null
        ? '${album.albumArtist} · ${album.year}'
        : album.albumArtist;

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        hoverColor: AppColors.surfaceHover,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: CoverArt(
                  path: album.cover,
                  borderRadius: 6,
                  iconSize: 40,
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
                subtitle.isNotEmpty ? subtitle : 'Unknown Artist',
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
    );
  }
}

class _AlbumDetailView extends StatelessWidget {
  const _AlbumDetailView({
    required this.detail,
    required this.controller,
    required this.onBack,
  });

  final UiAlbumDetail detail;
  final PlayerController controller;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final album = detail.album;
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
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                ),
                icon: const Icon(Icons.arrow_back_rounded, size: 18),
                label: const Text('Back to Albums'),
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
                        Text(
                          [
                            if (album.albumArtist.isNotEmpty) album.albumArtist,
                            if (album.year != null) '${album.year}',
                            '${detail.tracks.length} tracks',
                          ].join(' · '),
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
                                  ? () => controller.playAlbum(album.id, 0)
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
                              label: const Text('Shuffle'),
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
              final trackNo = track.trackNo ?? (index + 1);

              return InkWell(
                onTap: () => controller.playAlbum(album.id, index),
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
                              Text(
                                track.artist,
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
                      SizedBox(
                        width: 60,
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
                    ],
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
