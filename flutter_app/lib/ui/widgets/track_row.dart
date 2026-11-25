import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';
import 'package:neomodern/ui/track_menu.dart';
import 'package:neomodern/ui/widgets/motion_primitives.dart';

/// Shared hover-aware desktop track row matching Spotify/Svelte track lists.
///
/// Renders [EqualizerIndicator] in `accent400` in the `#` column while playing,
/// highlights active titles in `accent400`, reveals [AnimatedSaveButton] on row
/// hover (always visible if saved), and reveals [TrackMoreButton] on hover.
class DesktopTrackRow extends StatefulWidget {
  const DesktopTrackRow({
    super.key,
    required this.indexLabel,
    required this.track,
    required this.controller,
    required this.onTap,
    required this.onPlay,
    this.isActive = false,
    this.isSelected = false,
    this.showCover = true,
    this.showArtist = true,
    this.showArtistUnderTitle = false,
    this.showAlbum = true,
    this.playCount,
    this.horizontalPadding = 24,
    this.numberColumnWidth = 40,
    this.leadingDragHandle,
    this.trailingAction,
    this.onOpenArtist,
    this.onOpenAlbum,
    this.onRemoveFromPlaylist,
  });

  final String indexLabel;
  final UiTrackRow track;
  final PlayerController controller;
  final VoidCallback onTap;
  final VoidCallback onPlay;
  final bool isActive;
  final bool isSelected;
  final bool showCover;
  final bool showArtist;
  final bool showArtistUnderTitle;
  final bool showAlbum;
  final BigInt? playCount;
  final double horizontalPadding;
  final double numberColumnWidth;
  final Widget? leadingDragHandle;
  final Widget? trailingAction;
  final ValueChanged<String>? onOpenArtist;
  final ValueChanged<PlatformInt64>? onOpenAlbum;
  final VoidCallback? onRemoveFromPlaylist;

  @override
  State<DesktopTrackRow> createState() => _DesktopTrackRowState();
}

class _DesktopTrackRowState extends State<DesktopTrackRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final isFav = ctrl.isFavorite(widget.track.id);
    final isPlayingHere = widget.isActive && ctrl.isPlaying;

    final Color rowBg;
    if (widget.isSelected) {
      rowBg = AppTheme.accent500.withValues(alpha: 0.18);
    } else if (widget.isActive) {
      rowBg = AppTheme.accent950.withValues(alpha: 0.40);
    } else if (_hovered) {
      rowBg = AppTheme.zinc800.withValues(alpha: 0.50);
    } else {
      rowBg = Colors.transparent;
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onSecondaryTapDown: (d) => TrackMenu.show(
          context: context,
          globalPosition: d.globalPosition,
          track: widget.track,
          controller: ctrl,
          onPlay: widget.onPlay,
          onOpenArtist: widget.onOpenArtist,
          onOpenAlbum: widget.onOpenAlbum,
          onRemoveFromPlaylist: widget.onRemoveFromPlaylist,
        ),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: widget.horizontalPadding),
          decoration: BoxDecoration(
            color: rowBg,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              if (widget.leadingDragHandle != null) widget.leadingDragHandle!,
              SizedBox(
                width: widget.numberColumnWidth,
                child: isPlayingHere
                    ? const Align(
                        alignment: Alignment.centerLeft,
                        child: EqualizerIndicator(
                          playing: true,
                          color: AppTheme.accent400,
                          height: 14,
                        ),
                      )
                    : Text(
                        widget.indexLabel,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: widget.isActive
                              ? AppTheme.accent400
                              : AppTheme.zinc400,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
              ),
              Expanded(
                flex: 4,
                child: Row(
                  children: [
                    if (widget.showCover) ...[
                      CoverArt(
                        path: widget.track.cover,
                        size: 38,
                        borderRadius: 4,
                        iconSize: 16,
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: widget.isActive
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              color: widget.isActive
                                  ? AppTheme.accent400
                                  : AppTheme.zinc100,
                            ),
                          ),
                          if (widget.showArtistUnderTitle &&
                              widget.track.artist.isNotEmpty)
                            HoverLinkText(
                              text: widget.track.artist,
                              onTap: widget.onOpenArtist != null
                                  ? () => widget.onOpenArtist!(
                                        widget.track.artist,
                                      )
                                  : null,
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.zinc400,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.showArtist) ...[
                const SizedBox(width: 12),
                Expanded(
                  flex: 3,
                  child: HoverLinkText(
                    text: widget.track.artist.isNotEmpty
                        ? widget.track.artist
                        : t('Unknown Artist'),
                    onTap: widget.track.artist.isNotEmpty &&
                            widget.onOpenArtist != null
                        ? () => widget.onOpenArtist!(widget.track.artist)
                        : null,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppTheme.zinc400,
                    ),
                  ),
                ),
              ],
              if (widget.showAlbum) ...[
                const SizedBox(width: 12),
                Expanded(
                  flex: 3,
                  child: HoverLinkText(
                    text: widget.track.album.isNotEmpty
                        ? widget.track.album
                        : t('Unknown Album'),
                    onTap: widget.track.albumId != null &&
                            widget.onOpenAlbum != null
                        ? () => widget.onOpenAlbum!(widget.track.albumId!)
                        : null,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppTheme.zinc400,
                    ),
                  ),
                ),
              ],
              if (widget.playCount != null && widget.playCount! > BigInt.zero)
                Padding(
                  padding: const EdgeInsets.only(right: 14),
                  child: Text(
                    t('{n} plays', {'n': widget.playCount}),
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.zinc400,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              AnimatedSaveButton(
                isSaved: isFav,
                size: 16,
                revealOnHover: true,
                isRowHovered: _hovered,
                onPressed: () => ctrl.toggleFavorite(widget.track.id),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 52,
                child: Text(
                  formatDurationMs(widget.track.durationMs),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppTheme.zinc400,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              if (widget.trailingAction != null)
                AnimatedOpacity(
                  opacity: _hovered ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 140),
                  child: widget.trailingAction!,
                ),
              AnimatedOpacity(
                opacity: _hovered ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 140),
                child: TrackMoreButton(
                  track: widget.track,
                  controller: ctrl,
                  onPlay: widget.onPlay,
                  onOpenArtist: widget.onOpenArtist,
                  onOpenAlbum: widget.onOpenAlbum,
                  onRemoveFromPlaylist: widget.onRemoveFromPlaylist,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
