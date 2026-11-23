import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';

class StarFavoriteButton extends StatelessWidget {
  const StarFavoriteButton({
    super.key,
    required this.isFavorite,
    required this.onPressed,
    this.size = 18,
    this.tooltip,
  });

  final bool isFavorite;
  final VoidCallback? onPressed;
  final double size;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip:
          tooltip ?? (isFavorite ? 'Remove from Favorites' : 'Add to Favorites'),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
      icon: Icon(
        isFavorite ? Icons.star_rounded : Icons.star_outline_rounded,
        size: size,
        color: isFavorite ? AppColors.accent : AppColors.textMuted,
      ),
      onPressed: onPressed,
    );
  }
}

class HoverLinkText extends StatefulWidget {
  const HoverLinkText({
    super.key,
    required this.text,
    this.onTap,
    this.style,
    this.maxLines = 1,
  });

  final String text;
  final VoidCallback? onTap;
  final TextStyle? style;
  final int maxLines;

  @override
  State<HoverLinkText> createState() => _HoverLinkTextState();
}

class _HoverLinkTextState extends State<HoverLinkText> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final baseStyle = widget.style ??
        const TextStyle(fontSize: 13, color: AppColors.textSecondary);
    if (widget.onTap == null) {
      return Text(
        widget.text,
        maxLines: widget.maxLines,
        overflow: TextOverflow.ellipsis,
        style: baseStyle,
      );
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Text(
          widget.text,
          maxLines: widget.maxLines,
          overflow: TextOverflow.ellipsis,
          style: baseStyle.copyWith(
            decoration:
                _hovered ? TextDecoration.underline : TextDecoration.none,
            color: _hovered ? AppColors.textPrimary : baseStyle.color,
          ),
        ),
      ),
    );
  }
}

class TrackMenu {
  TrackMenu._();

  static Future<void> show({
    required BuildContext context,
    required Offset globalPosition,
    required UiTrackRow track,
    required PlayerController controller,
    VoidCallback? onPlay,
    ValueChanged<String>? onOpenArtist,
    ValueChanged<PlatformInt64>? onOpenAlbum,
    VoidCallback? onRemoveFromPlaylist,
  }) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final position = RelativeRect.fromRect(
      Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 1, 1),
      Offset.zero & overlay.size,
    );
    final isFav = controller.isFavorite(track.id);

    final action = await showMenu<String>(
      context: context,
      position: position,
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: AppColors.border),
      ),
      items: [
        const PopupMenuItem<String>(
          value: 'play',
          child: _MenuRow(icon: Icons.play_arrow_rounded, label: 'Play'),
        ),
        const PopupMenuItem<String>(
          value: 'play_next',
          child: _MenuRow(
              icon: Icons.playlist_play_rounded, label: 'Play Next'),
        ),
        const PopupMenuItem<String>(
          value: 'enqueue',
          child: _MenuRow(
              icon: Icons.add_to_queue_rounded, label: 'Add to Queue'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'favorite',
          child: _MenuRow(
            icon: isFav ? Icons.star_rounded : Icons.star_outline_rounded,
            label: isFav ? 'Remove from Favorites' : 'Add to Favorites',
            accent: isFav,
          ),
        ),
        const PopupMenuItem<String>(
          value: 'playlist',
          child: _MenuRow(
            icon: Icons.playlist_add_rounded,
            label: 'Add to Playlist...',
          ),
        ),
        if (onRemoveFromPlaylist != null)
          const PopupMenuItem<String>(
            value: 'remove_playlist',
            child: _MenuRow(
              icon: Icons.remove_circle_outline_rounded,
              label: 'Remove from Playlist',
            ),
          ),
        if (track.artist.isNotEmpty && onOpenArtist != null) ...[
          const PopupMenuDivider(),
          const PopupMenuItem<String>(
            value: 'artist',
            child: _MenuRow(
              icon: Icons.person_rounded,
              label: 'Go to Artist',
            ),
          ),
        ],
        if (track.albumId != null && onOpenAlbum != null)
          const PopupMenuItem<String>(
            value: 'album',
            child: _MenuRow(
              icon: Icons.album_rounded,
              label: 'Go to Album',
            ),
          ),
      ],
    );

    if (action == null) return;
    switch (action) {
      case 'play':
        if (onPlay != null) {
          onPlay();
        } else {
          await controller.playTracks([track.path], 0);
        }
      case 'play_next':
        await controller.insertNextTracks([track.path]);
      case 'enqueue':
        await controller.enqueueTracks([track.path]);
      case 'favorite':
        await controller.toggleFavorite(track.id);
      case 'playlist':
        if (context.mounted) {
          await showAddToPlaylistDialog(
            context: context,
            controller: controller,
            trackIds: [track.id],
          );
        }
      case 'remove_playlist':
        onRemoveFromPlaylist?.call();
      case 'artist':
        if (track.artist.isNotEmpty) {
          onOpenArtist?.call(track.artist);
        }
      case 'album':
        if (track.albumId != null) {
          onOpenAlbum?.call(track.albumId!);
        }
    }
  }
}

class TrackMoreButton extends StatelessWidget {
  const TrackMoreButton({
    super.key,
    required this.track,
    required this.controller,
    this.onPlay,
    this.onOpenArtist,
    this.onOpenAlbum,
    this.onRemoveFromPlaylist,
  });

  final UiTrackRow track;
  final PlayerController controller;
  final VoidCallback? onPlay;
  final ValueChanged<String>? onOpenArtist;
  final ValueChanged<PlatformInt64>? onOpenAlbum;
  final VoidCallback? onRemoveFromPlaylist;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'More options',
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
      icon: const Icon(
        Icons.more_horiz_rounded,
        size: 18,
        color: AppColors.textMuted,
      ),
      onPressed: () {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        final pos = box.localToGlobal(box.size.bottomRight(Offset.zero));
        TrackMenu.show(
          context: context,
          globalPosition: pos,
          track: track,
          controller: controller,
          onPlay: onPlay,
          onOpenArtist: onOpenArtist,
          onOpenAlbum: onOpenAlbum,
          onRemoveFromPlaylist: onRemoveFromPlaylist,
        );
      },
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    this.accent = false,
  });

  final IconData icon;
  final String label;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 17,
          color: accent ? AppColors.accent : AppColors.textSecondary,
        ),
        const SizedBox(width: 10),
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: accent ? AppColors.accent : AppColors.textPrimary,
          ),
        ),
      ],
    );
  }
}

Future<String?> showTextPromptDialog({
  required BuildContext context,
  required String title,
  required String hintText,
  required String confirmLabel,
  String initialValue = '',
}) async {
  final textCtrl = TextEditingController(text: initialValue);
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.border),
      ),
      title: Text(title, style: const TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 340,
        child: TextField(
          controller: textCtrl,
          autofocus: true,
          decoration: InputDecoration(hintText: hintText),
          onSubmitted: (v) {
            final trimmed = v.trim();
            if (trimmed.isNotEmpty) {
              Navigator.of(ctx).pop(trimmed);
            }
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final trimmed = textCtrl.text.trim();
            if (trimmed.isNotEmpty) {
              Navigator.of(ctx).pop(trimmed);
            }
          },
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.accent,
            foregroundColor: AppColors.canvas,
          ),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  textCtrl.dispose();
  return result;
}

Future<void> showAddToPlaylistDialog({
  required BuildContext context,
  required PlayerController controller,
  required List<PlatformInt64> trackIds,
}) async {
  if (trackIds.isEmpty) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.border),
      ),
      title: const Text('Add to Playlist', style: TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OutlinedButton.icon(
              onPressed: () async {
                final name = await showTextPromptDialog(
                  context: ctx,
                  title: 'New Playlist',
                  hintText: 'Playlist name',
                  confirmLabel: 'Create',
                );
                if (name != null) {
                  final created = await controller.createPlaylist(name);
                  if (created != null) {
                    await controller.addTracksToPlaylist(created.id, trackIds);
                    if (ctx.mounted) Navigator.of(ctx).pop();
                  }
                }
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.accent,
                side: const BorderSide(color: AppColors.border),
              ),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Create New Playlist'),
            ),
            const SizedBox(height: 10),
            if (controller.playlists.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'No playlists yet.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: controller.playlists.length,
                  itemBuilder: (_, idx) {
                    final pl = controller.playlists[idx];
                    return ListTile(
                      dense: true,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      leading: const Icon(
                        Icons.queue_music_rounded,
                        size: 18,
                        color: AppColors.textSecondary,
                      ),
                      title: Text(
                        pl.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Text(
                        '${pl.trackCount} tracks',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textMuted,
                        ),
                      ),
                      onTap: () async {
                        await controller.addTracksToPlaylist(pl.id, trackIds);
                        if (ctx.mounted) Navigator.of(ctx).pop();
                      },
                    );
                  },
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
