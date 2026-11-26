import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';

/// Opens a responsive modal showing an online album's details, track list,
/// playback, and download actions.
Future<void> showOnlineAlbumModal(
  BuildContext context, {
  required PlayerController controller,
  required UiOnlineAlbum album,
}) {
  final isWide = MediaQuery.sizeOf(context).width >= 640;
  if (isWide) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: AppTheme.zinc900,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppTheme.zinc800),
        ),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 680),
          child: _OnlineAlbumModalBody(
            controller: controller,
            album: album,
            isBottomSheet: false,
          ),
        ),
      ),
    );
  }

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppTheme.zinc900,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    clipBehavior: Clip.antiAlias,
    builder: (ctx) => FractionallySizedBox(
      heightFactor: 0.88,
      child: _OnlineAlbumModalBody(
        controller: controller,
        album: album,
        isBottomSheet: true,
      ),
    ),
  );
}

/// Displays remote artwork via [Image.network] with graceful fallback to
/// [CoverArt] for local cached paths or placeholder icons.
class OnlineCoverArt extends StatelessWidget {
  const OnlineCoverArt({
    super.key,
    this.coverUrl,
    this.coverPath,
    this.size,
    this.borderRadius = 8,
    this.iconSize = 24,
    this.fallbackIcon = Icons.album_rounded,
  });

  final String? coverUrl;
  final String? coverPath;
  final double? size;
  final double borderRadius;
  final double iconSize;
  final IconData fallbackIcon;

  @override
  Widget build(BuildContext context) {
    final url = coverUrl?.trim();
    if (url != null && url.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: SizedBox(
          width: size,
          height: size,
          child: Image.network(
            url,
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => CoverArt(
              path: coverPath,
              size: size,
              borderRadius: 0,
              iconSize: iconSize,
              fallbackIcon: fallbackIcon,
            ),
          ),
        ),
      );
    }

    return CoverArt(
      path: coverPath,
      size: size,
      borderRadius: borderRadius,
      iconSize: iconSize,
      fallbackIcon: fallbackIcon,
    );
  }
}

/// Styled error banner for online search and album detail failures.
class OnlineErrorBanner extends StatelessWidget {
  const OnlineErrorBanner({
    super.key,
    required this.message,
    this.onRetry,
  });

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.danger.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: AppTheme.danger.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: AppTheme.danger,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 13,
                color: AppTheme.zinc100,
              ),
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(width: 8),
            TextButton(
              onPressed: onRetry,
              child: Text(t('Retry')),
            ),
          ],
        ],
      ),
    );
  }
}

/// Shows consistent snackbar feedback after queuing or failing an online download.
void showOnlineDownloadSnackBar(
  BuildContext context, {
  required bool queued,
  required String label,
  String? error,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final isWide = MediaQuery.sizeOf(context).width >= 640;
  final text = queued
      ? t('Queued download: {name}', {'name': label})
      : (error != null && error.isNotEmpty
          ? error
          : t('Failed to start download.'));
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(text),
      behavior: SnackBarBehavior.floating,
      width: isWide ? 360 : null,
    ),
  );
}

class _OnlineAlbumModalBody extends StatefulWidget {
  const _OnlineAlbumModalBody({
    required this.controller,
    required this.album,
    required this.isBottomSheet,
  });

  final PlayerController controller;
  final UiOnlineAlbum album;
  final bool isBottomSheet;

  @override
  State<_OnlineAlbumModalBody> createState() => _OnlineAlbumModalBodyState();
}

class _OnlineAlbumModalBodyState extends State<_OnlineAlbumModalBody> {
  bool _loading = true;
  String? _error;
  UiOnlineAlbumDetail? _detail;
  bool _downloadingAlbum = false;
  final Set<String> _downloadingTrackIds = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await widget.controller.fetchOnlineAlbumDetail(widget.album);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _downloadAlbum() async {
    final detail = _detail;
    if (detail == null || detail.tracks.isEmpty || _downloadingAlbum) return;
    final activeAlbum = detail.album;
    setState(() => _downloadingAlbum = true);
    final job = await widget.controller.downloadOnlineAlbum(
      activeAlbum,
      detail.tracks,
    );
    if (!mounted) return;
    setState(() => _downloadingAlbum = false);
    showOnlineDownloadSnackBar(
      context,
      queued: job != null,
      label: activeAlbum.title,
      error: widget.controller.lastError,
    );
  }

  Future<void> _downloadTrack(UiOnlineTrack track) async {
    if (_downloadingTrackIds.contains(track.id)) return;
    setState(() => _downloadingTrackIds.add(track.id));
    final job = await widget.controller.downloadOnlineTrack(track);
    if (!mounted) return;
    setState(() => _downloadingTrackIds.remove(track.id));
    showOnlineDownloadSnackBar(
      context,
      queued: job != null,
      label: track.title,
      error: widget.controller.lastError,
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeAlbum = _detail?.album ?? widget.album;
    final tracks = _detail?.tracks ?? const <UiOnlineTrack>[];
    final count = _detail != null ? tracks.length : activeAlbum.trackCount;
    final countLabel = count == 1
        ? t('{n} track', {'n': count})
        : t('{n} tracks', {'n': count});
    final metaLine = activeAlbum.year != null
        ? '${activeAlbum.year} · $countLabel'
        : countLabel;
    final coverSize = widget.isBottomSheet ? 88.0 : 112.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.isBottomSheet)
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 4),
            child: Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.zinc700,
                  borderRadius: BorderRadius.circular(9999),
                ),
              ),
            ),
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            widget.isBottomSheet ? 10 : 18,
            16,
            16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  OnlineCoverArt(
                    coverUrl: activeAlbum.coverUrl,
                    coverPath: activeAlbum.cover,
                    size: coverSize,
                    borderRadius: 10,
                    iconSize: 36,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          activeAlbum.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.3,
                            color: AppTheme.zinc50,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          activeAlbum.artist.isNotEmpty
                              ? activeAlbum.artist
                              : t('Unknown Artist'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: AppTheme.zinc300,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          metaLine,
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: AppTheme.zinc400,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!widget.isBottomSheet)
                    IconButton(
                      tooltip: t('Close'),
                      icon: const Icon(
                        Icons.close_rounded,
                        color: AppTheme.zinc400,
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _loading || tracks.isEmpty
                        ? null
                        : () => unawaited(
                              widget.controller.playOnlineTracks(
                                tracks,
                                startIndex: 0,
                              ),
                            ),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.accent500,
                      foregroundColor: AppTheme.zinc950,
                      disabledBackgroundColor: AppTheme.zinc800,
                      disabledForegroundColor: AppTheme.zinc500,
                      shape: const StadiumBorder(),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 10,
                      ),
                    ),
                    icon: const Icon(Icons.play_arrow_rounded, size: 20),
                    label: Text(
                      t('Play'),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _loading || tracks.isEmpty || _downloadingAlbum
                        ? null
                        : () => unawaited(_downloadAlbum()),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.zinc100,
                      side: const BorderSide(color: AppTheme.zinc700),
                      shape: const StadiumBorder(),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                    ),
                    icon: _downloadingAlbum
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download_rounded, size: 18),
                    label: Text(t('Download album')),
                  ),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: AppTheme.zinc800),
        Expanded(
          child: _buildTrackBody(tracks),
        ),
      ],
    );
  }

  Widget _buildTrackBody(List<UiOnlineTrack> tracks) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            OnlineErrorBanner(
              message: _error!,
              onRetry: () => unawaited(_load()),
            ),
          ],
        ),
      );
    }
    if (tracks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            t('No matching tracks found.'),
            style: const TextStyle(fontSize: 13.5, color: AppTheme.zinc400),
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        final track = tracks[index];
        final trackNumber = track.trackNo ?? (index + 1);
        final downloading = _downloadingTrackIds.contains(track.id);
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 2,
          ),
          leading: SizedBox(
            width: 28,
            child: Text(
              '$trackNumber',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                color: AppTheme.zinc400,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          title: Text(
            track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: AppTheme.zinc100,
            ),
          ),
          subtitle: Text(
            track.artist.isNotEmpty ? track.artist : t('Unknown Artist'),
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
              Text(
                formatDuration(track.durationSeconds),
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.zinc400,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                tooltip: t('Download Track'),
                icon: downloading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(
                        Icons.download_rounded,
                        size: 19,
                        color: AppTheme.zinc300,
                      ),
                onPressed: downloading
                    ? null
                    : () => unawaited(_downloadTrack(track)),
              ),
            ],
          ),
          onTap: () => unawaited(
            widget.controller.playOnlineTracks(tracks, startIndex: index),
          ),
        );
      },
    );
  }
}
