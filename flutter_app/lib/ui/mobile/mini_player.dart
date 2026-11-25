import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';
import 'package:neomodern/ui/mobile/cover_tint.dart';
import 'package:neomodern/ui/mobile/now_playing_sheet.dart';
import 'package:neomodern/ui/track_menu.dart';

class MiniPlayer extends StatefulWidget {
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

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  String? _lastCoverPath;
  Color? _coverTint;

  @override
  void initState() {
    super.initState();
    _syncCoverTint();
  }

  @override
  void didUpdateWidget(covariant MiniPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncCoverTint();
  }

  void _syncCoverTint() {
    final coverPath = widget.controller.currentCoverPath;
    if (coverPath == _lastCoverPath) return;
    _lastCoverPath = coverPath;
    _coverTint = MobileCoverCache.cachedColor(coverPath);
    if (coverPath == null || coverPath.isEmpty || _coverTint != null) {
      return;
    }
    unawaited(
      MobileCoverCache.resolveColor(coverPath).then((color) {
        if (!mounted || _lastCoverPath != coverPath || color == null) return;
        setState(() => _coverTint = color);
      }),
    );
  }

  void _handleHorizontalDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity < -MiniPlayer._swipeVelocityThreshold) {
      widget.controller.next();
    } else if (velocity > MiniPlayer._swipeVelocityThreshold) {
      widget.controller.previous();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    _syncCoverTint();
    final snap = ctrl.snapshot;
    final current = snap.current;
    if (current == null) {
      return const SizedBox.shrink();
    }

    final duration = snap.durationSeconds;
    final bgColor = blendCoverTint(AppColors.sidebar, _coverTint, 44);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragEnd: _handleHorizontalDragEnd,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        color: bgColor,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap ??
                () => showNowPlayingSheet(
                      context,
                      controller: ctrl,
                      onOpenArtist: widget.onOpenArtist,
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
                    valueListenable: ctrl.positionNotifier,
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
                            path: ctrl.currentCoverPath,
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
                            isFavorite: ctrl.isCurrentFavorite,
                            onPressed: ctrl.toggleCurrentFavorite,
                          ),
                          const SizedBox(width: 2),
                          IconButton(
                            tooltip: ctrl.isPlaying ? 'Pause' : 'Play',
                            icon: Icon(
                              ctrl.isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              size: 26,
                              color: AppColors.textPrimary,
                            ),
                            onPressed: ctrl.togglePause,
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
      ),
    );
  }
}
