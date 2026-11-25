import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';
import 'package:neomodern/ui/right_panel.dart';
import 'package:neomodern/ui/track_menu.dart';

class PlayerBar extends StatelessWidget {
  const PlayerBar({
    super.key,
    required this.controller,
    required this.rightPanelOpen,
    required this.rightPanelTab,
    required this.onTogglePanel,
    required this.onOpenArtist,
  });

  final PlayerController controller;
  final bool rightPanelOpen;
  final RightPanelTab rightPanelTab;
  final ValueChanged<RightPanelTab> onTogglePanel;
  final ValueChanged<String> onOpenArtist;

  @override
  Widget build(BuildContext context) {
    final snap = controller.snapshot;
    final current = snap.current;
    final duration = snap.durationSeconds;
    final hasTrack = current != null;
    final sleepActive = snap.sleepEndOfTrack || snap.sleepEndsAt != null;

    return Container(
      height: 88,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: const BoxDecoration(
        color: AppColors.sidebar,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          // Left: Current track info + star favorite
          Expanded(
            flex: 3,
            child: Row(
              children: [
                CoverArt(
                  path: controller.currentCoverPath,
                  size: 52,
                  borderRadius: 6,
                  iconSize: 22,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        current?.title ?? t('Nothing playing'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: hasTrack
                              ? AppColors.textPrimary
                              : AppColors.textMuted,
                        ),
                      ),
                      const SizedBox(height: 2),
                      HoverLinkText(
                        text: current != null && current.artist.isNotEmpty
                            ? current.artist
                            : (hasTrack
                                ? t('Unknown Artist')
                                : t('Pick a track to play')),
                        onTap: current != null && current.artist.isNotEmpty
                            ? () => onOpenArtist(current.artist)
                            : null,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (hasTrack) ...[
                  const SizedBox(width: 4),
                  StarFavoriteButton(
                    isFavorite: controller.isCurrentFavorite,
                    onPressed: controller.toggleCurrentFavorite,
                  ),
                ],
              ],
            ),
          ),

          // Center: Transport + seekbar
          Expanded(
            flex: 5,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: snap.shuffle ? t('Shuffle on') : t('Shuffle off'),
                      icon: Icon(
                        Icons.shuffle_rounded,
                        size: 18,
                        color: snap.shuffle
                            ? AppColors.accent
                            : AppColors.textSecondary,
                      ),
                      onPressed: controller.toggleShuffle,
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: t('Previous'),
                      icon: const Icon(
                        Icons.skip_previous_rounded,
                        size: 24,
                        color: AppColors.textPrimary,
                      ),
                      onPressed: hasTrack ? controller.previous : null,
                    ),
                    const SizedBox(width: 6),
                    Material(
                      color: AppColors.accent,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: controller.togglePause,
                        child: SizedBox(
                          width: 36,
                          height: 36,
                          child: Icon(
                            controller.isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            color: AppColors.canvas,
                            size: 22,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    IconButton(
                      tooltip: t('Next'),
                      icon: const Icon(
                        Icons.skip_next_rounded,
                        size: 24,
                        color: AppColors.textPrimary,
                      ),
                      onPressed: hasTrack ? controller.next : null,
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: t('Repeat: ${snap.repeat}'),
                      icon: Icon(
                        snap.repeat == 'one'
                            ? Icons.repeat_one_rounded
                            : Icons.repeat_rounded,
                        size: 18,
                        color: snap.repeat == 'off'
                            ? AppColors.textSecondary
                            : AppColors.accent,
                      ),
                      onPressed: controller.cycleRepeat,
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                ValueListenableBuilder<double>(
                  valueListenable: controller.positionNotifier,
                  builder: (context, pos, _) {
                    final maxDur =
                        (duration != null && duration > 0) ? duration : 1.0;
                    final clampedPos = math.min(math.max(pos, 0.0), maxDur);
                    return Row(
                      children: [
                        SizedBox(
                          width: 44,
                          child: Text(
                            hasTrack ? formatDuration(clampedPos) : '--:--',
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.textSecondary,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                        Expanded(
                          child: SliderTheme(
                            data: Theme.of(context).sliderTheme.copyWith(
                                  trackHeight: 3,
                                  thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 5,
                                  ),
                                ),
                            child: Slider(
                              value: hasTrack ? clampedPos : 0,
                              max: maxDur,
                              onChangeStart: hasTrack
                                  ? (_) => controller.beginSeekDrag()
                                  : null,
                              onChanged: hasTrack
                                  ? (v) => controller.updateSeekDrag(v)
                                  : null,
                              onChangeEnd: hasTrack
                                  ? (v) => controller.endSeekDrag(v)
                                  : null,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 44,
                          child: Text(
                            hasTrack ? formatDuration(duration) : '--:--',
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.textSecondary,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),

          // Right: Sleep indicator, Lyrics & Queue toggles, Volume
          Expanded(
            flex: 3,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (sleepActive)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Tooltip(
                      message: t('Sleep Timer active'),
                      child: const Icon(
                        Icons.bedtime_rounded,
                        size: 17,
                        color: AppColors.accent,
                      ),
                    ),
                  ),
                IconButton(
                  tooltip: t('Lyrics'),
                  icon: Icon(
                    Icons.lyrics_rounded,
                    size: 19,
                    color: rightPanelOpen &&
                            rightPanelTab == RightPanelTab.lyrics
                        ? AppColors.accent
                        : AppColors.textSecondary,
                  ),
                  onPressed: () => onTogglePanel(RightPanelTab.lyrics),
                ),
                IconButton(
                  tooltip: t('Queue'),
                  icon: Icon(
                    Icons.queue_music_rounded,
                    size: 19,
                    color: rightPanelOpen &&
                            rightPanelTab == RightPanelTab.queue
                        ? AppColors.accent
                        : AppColors.textSecondary,
                  ),
                  onPressed: () => onTogglePanel(RightPanelTab.queue),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: snap.volume == 0 ? t('Unmute') : t('Mute'),
                  icon: Icon(
                    snap.volume == 0
                        ? Icons.volume_off_rounded
                        : snap.volume < 50
                            ? Icons.volume_down_rounded
                            : Icons.volume_up_rounded,
                    size: 19,
                    color: AppColors.textSecondary,
                  ),
                  onPressed: controller.toggleMute,
                ),
                SizedBox(
                  width: 96,
                  child: Slider(
                    value: snap.volume.clamp(0.0, 100.0),
                    max: 100.0,
                    onChanged: (v) => controller.setVolume(v),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
