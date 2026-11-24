import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';
import 'package:neomodern/ui/mobile/now_playing_sheet.dart';
import 'package:neomodern/ui/track_menu.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({
    super.key,
    required this.controller,
    this.onOpenArtist,
    this.onTap,
  });

  static const double _swipeVelocityThreshold = 120.0;

  final PlayerController controller;
  final ValueChanged<String>? onOpenArtist;
  final VoidCallback? onTap;

  void _handleHorizontalDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity < -_swipeVelocityThreshold) {
      controller.next();
    } else if (velocity > _swipeVelocityThreshold) {
      controller.previous();
    }
  }

  @override
  Widget build(BuildContext context) {
    final snap = controller.snapshot;
    final current = snap.current;
    if (current == null) {
      return const SizedBox.shrink();
    }

    final duration = snap.durationSeconds;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragEnd: _handleHorizontalDragEnd,
      child: Material(
        color: AppColors.sidebar,
        child: InkWell(
          onTap: onTap ??
              () => showNowPlayingSheet(
                    context,
                    controller: controller,
                    onOpenArtist: onOpenArtist,
                  ),
          child: Container(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.border)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Thin progress indicator driven by positionNotifier
                ValueListenableBuilder<double>(
                  valueListenable: controller.positionNotifier,
                  builder: (context, pos, _) {
                    final progress = (duration != null && duration > 0)
                        ? math.min(math.max(pos / duration, 0.0), 1.0)
                        : 0.0;
                    return LinearProgressIndicator(
                      value: progress,
                      minHeight: 2.5,
                      backgroundColor: AppColors.border,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        AppColors.accent,
                      ),
                    );
                  },
                ),
                SizedBox(
                  height: 60,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        CoverArt(
                          path: controller.currentCoverPath,
                          size: 42,
                          borderRadius: 6,
                          iconSize: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                current.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 1),
                              Text(
                                current.artist.isNotEmpty
                                    ? current.artist
                                    : 'Unknown Artist',
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
                        StarFavoriteButton(
                          isFavorite: controller.isCurrentFavorite,
                          onPressed: controller.toggleCurrentFavorite,
                        ),
                        const SizedBox(width: 2),
                        IconButton(
                          tooltip: controller.isPlaying ? 'Pause' : 'Play',
                          icon: Icon(
                            controller.isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: 26,
                            color: AppColors.textPrimary,
                          ),
                          onPressed: controller.togglePause,
                        ),
                      ],
                    ),
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
