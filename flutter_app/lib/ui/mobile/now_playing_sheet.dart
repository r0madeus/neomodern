import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';
import 'package:neomodern/ui/track_menu.dart';

enum _SheetBottomTab { lyrics, queue }

Future<void> showNowPlayingSheet(
  BuildContext context, {
  required PlayerController controller,
  ValueChanged<String>? onOpenArtist,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    enableDrag: true,
    backgroundColor: AppColors.canvas,
    barrierColor: Colors.black.withAlpha(190),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (_) => NowPlayingSheet(
      controller: controller,
      onOpenArtist: onOpenArtist,
    ),
  );
}

class NowPlayingSheet extends StatefulWidget {
  const NowPlayingSheet({
    super.key,
    required this.controller,
    this.onOpenArtist,
  });

  final PlayerController controller;
  final ValueChanged<String>? onOpenArtist;

  @override
  State<NowPlayingSheet> createState() => _NowPlayingSheetState();
}

class _NowPlayingSheetState extends State<NowPlayingSheet> {
  static const double _swipeVelocityThreshold = 120.0;
  _SheetBottomTab _bottomTab = _SheetBottomTab.lyrics;

  void _handleHorizontalSwipe(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity < -_swipeVelocityThreshold) {
      widget.controller.next();
    } else if (velocity > _swipeVelocityThreshold) {
      widget.controller.previous();
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final sheetHeight = screenSize.height * 0.94;

    return SizedBox(
      height: sheetHeight,
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final ctrl = widget.controller;
          final snap = ctrl.snapshot;
          final current = snap.current;
          final hasTrack = current != null;
          final duration = snap.durationSeconds;
          final sleepActive = snap.sleepEndOfTrack || snap.sleepEndsAt != null;

          return SafeArea(
            top: false,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final coverSize = math.min(
                  constraints.maxWidth - 72,
                  (constraints.maxHeight * 0.27).clamp(96.0, 248.0),
                );
                final compact = constraints.maxHeight < 620;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Drag handle
                    Center(
                      child: Container(
                        width: 38,
                        height: 4,
                        margin: const EdgeInsets.only(top: 10, bottom: 4),
                        decoration: BoxDecoration(
                          color: AppColors.border,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),

                    // Header row
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: 'Close',
                            icon: const Icon(
                              Icons.keyboard_arrow_down_rounded,
                              size: 26,
                              color: AppColors.textPrimary,
                            ),
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                          Expanded(
                            child: Text(
                              snap.context != null && snap.context!.isNotEmpty
                                  ? snap.context!
                                  : 'Now Playing',
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.4,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 48,
                            child: sleepActive
                                ? const Icon(
                                    Icons.bedtime_rounded,
                                    size: 18,
                                    color: AppColors.accent,
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ),
                    ),

                    SizedBox(height: compact ? 6 : 10),

                    // Large cover art with horizontal swipe
                    Center(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragEnd:
                            hasTrack ? _handleHorizontalSwipe : null,
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: CoverArt(
                            path: ctrl.currentCoverPath,
                            size: coverSize,
                            borderRadius: 12,
                            iconSize: coverSize * 0.34,
                          ),
                        ),
                      ),
                    ),

                    SizedBox(height: compact ? 10 : 16),

                    // Track title, clickable artist, and star favorite toggle
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 22),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  current?.title ?? 'Nothing playing',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                    color: hasTrack
                                        ? AppColors.textPrimary
                                        : AppColors.textMuted,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                HoverLinkText(
                                  text: current != null &&
                                          current.artist.isNotEmpty
                                      ? current.artist
                                      : (hasTrack
                                          ? 'Unknown Artist'
                                          : 'Pick a track to play'),
                                  onTap: current != null &&
                                          current.artist.isNotEmpty
                                      ? () {
                                          Navigator.of(context).pop();
                                          widget.onOpenArtist
                                              ?.call(current.artist);
                                        }
                                      : null,
                                  style: const TextStyle(
                                    fontSize: 13.5,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (hasTrack) ...[
                            const SizedBox(width: 8),
                            StarFavoriteButton(
                              isFavorite: ctrl.isCurrentFavorite,
                              onPressed: ctrl.toggleCurrentFavorite,
                              size: 24,
                            ),
                          ],
                        ],
                      ),
                    ),

                    SizedBox(height: compact ? 4 : 8),

                    // Live 10 Hz seekbar + timestamps
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: ValueListenableBuilder<double>(
                        valueListenable: ctrl.positionNotifier,
                        builder: (context, pos, _) {
                          final maxDur = (duration != null && duration > 0)
                              ? duration
                              : 1.0;
                          final clampedPos =
                              math.min(math.max(pos, 0.0), maxDur);
                          return Column(
                            children: [
                              SliderTheme(
                                data: Theme.of(context).sliderTheme.copyWith(
                                      trackHeight: 3.5,
                                      thumbShape: const RoundSliderThumbShape(
                                        enabledThumbRadius: 6,
                                      ),
                                    ),
                                child: Slider(
                                  value: hasTrack ? clampedPos : 0,
                                  max: maxDur,
                                  onChangeStart: hasTrack
                                      ? (_) => ctrl.beginSeekDrag()
                                      : null,
                                  onChanged: hasTrack
                                      ? (v) => ctrl.updateSeekDrag(v)
                                      : null,
                                  onChangeEnd: hasTrack
                                      ? (v) => ctrl.endSeekDrag(v)
                                      : null,
                                ),
                              ),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 10),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      hasTrack
                                          ? formatDuration(clampedPos)
                                          : '--:--',
                                      style: const TextStyle(
                                        fontSize: 11.5,
                                        color: AppColors.textSecondary,
                                        fontFeatures: [
                                          FontFeature.tabularFigures()
                                        ],
                                      ),
                                    ),
                                    Text(
                                      hasTrack
                                          ? formatDuration(duration)
                                          : '--:--',
                                      style: const TextStyle(
                                        fontSize: 11.5,
                                        color: AppColors.textSecondary,
                                        fontFeatures: [
                                          FontFeature.tabularFigures()
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),

                    SizedBox(height: compact ? 2 : 6),

                    // Transport controls
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          IconButton(
                            tooltip:
                                snap.shuffle ? 'Shuffle on' : 'Shuffle off',
                            icon: Icon(
                              Icons.shuffle_rounded,
                              size: 21,
                              color: snap.shuffle
                                  ? AppColors.accent
                                  : AppColors.textSecondary,
                            ),
                            onPressed: ctrl.toggleShuffle,
                          ),
                          IconButton(
                            tooltip: 'Previous',
                            icon: const Icon(
                              Icons.skip_previous_rounded,
                              size: 32,
                              color: AppColors.textPrimary,
                            ),
                            onPressed: hasTrack ? ctrl.previous : null,
                          ),
                          Material(
                            color: AppColors.accent,
                            shape: const CircleBorder(),
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: ctrl.togglePause,
                              child: SizedBox(
                                width: 54,
                                height: 54,
                                child: Icon(
                                  ctrl.isPlaying
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  color: AppColors.canvas,
                                  size: 32,
                                ),
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Next',
                            icon: const Icon(
                              Icons.skip_next_rounded,
                              size: 32,
                              color: AppColors.textPrimary,
                            ),
                            onPressed: hasTrack ? ctrl.next : null,
                          ),
                          IconButton(
                            tooltip: 'Repeat: ${snap.repeat}',
                            icon: Icon(
                              snap.repeat == 'one'
                                  ? Icons.repeat_one_rounded
                                  : Icons.repeat_rounded,
                              size: 21,
                              color: snap.repeat == 'off'
                                  ? AppColors.textSecondary
                                  : AppColors.accent,
                            ),
                            onPressed: ctrl.cycleRepeat,
                          ),
                        ],
                      ),
                    ),

                    SizedBox(height: compact ? 8 : 12),

                    // Segmented toggle for Lyrics & Queue
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: AppColors.sidebar,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: _SegmentButton(
                                icon: Icons.lyrics_rounded,
                                label: 'Lyrics',
                                active: _bottomTab == _SheetBottomTab.lyrics,
                                onTap: () => setState(
                                  () => _bottomTab = _SheetBottomTab.lyrics,
                                ),
                              ),
                            ),
                            Expanded(
                              child: _SegmentButton(
                                icon: Icons.queue_music_rounded,
                                label: 'Queue',
                                active: _bottomTab == _SheetBottomTab.queue,
                                onTap: () => setState(
                                  () => _bottomTab = _SheetBottomTab.queue,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 8),

                    // Lyrics or Queue body
                    Expanded(
                      child: Container(
                        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        decoration: BoxDecoration(
                          color: AppColors.sidebar,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: _bottomTab == _SheetBottomTab.lyrics
                              ? _MobileLyricsPanel(controller: ctrl)
                              : _MobileQueuePanel(controller: ctrl),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _SegmentButton extends StatelessWidget {
  const _SegmentButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? AppColors.accentMuted : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: active ? AppColors.accent : AppColors.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color: active ? AppColors.accent : AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileLyricsPanel extends StatefulWidget {
  const _MobileLyricsPanel({required this.controller});

  final PlayerController controller;

  @override
  State<_MobileLyricsPanel> createState() => _MobileLyricsPanelState();
}

class _MobileLyricsPanelState extends State<_MobileLyricsPanel> {
  final ScrollController _scrollCtrl = ScrollController();
  List<GlobalKey> _lineKeys = const [];
  String? _lastKeyedTrack;
  int _lastKeyCount = 0;
  int _lastActiveIdx = -1;

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _ensureKeys(String? path, int count) {
    if (path != _lastKeyedTrack || count != _lastKeyCount) {
      _lastKeyedTrack = path;
      _lastKeyCount = count;
      _lastActiveIdx = -1;
      _lineKeys = List.generate(count, (_) => GlobalKey());
    }
  }

  void _scrollToActive(int idx) {
    if (idx < 0 || idx >= _lineKeys.length || idx == _lastActiveIdx) return;
    _lastActiveIdx = idx;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _lineKeys[idx].currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.35,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  int _findActiveIndex(List<UiSyncedLine> lines, double posSeconds) {
    final posMs = (posSeconds * 1000).round();
    var active = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].timeMs.toInt() <= posMs) {
        active = i;
      } else {
        break;
      }
    }
    return active;
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final current = ctrl.snapshot.current;

    if (current == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            'Play a track to view lyrics.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
        ),
      );
    }

    final lyrics = ctrl.currentLyrics;
    if (ctrl.lyricsLoading && lyrics == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (lyrics == null || !lyrics.found) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.lyrics_outlined,
                size: 30,
                color: AppColors.textMuted,
              ),
              const SizedBox(height: 8),
              Text(
                ctrl.offlineMode
                    ? 'No local lyrics found (Offline Mode is on).'
                    : 'No lyrics found for this track.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: ctrl.lyricsLoading ? null : ctrl.refreshLyrics,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.textPrimary,
                  side: const BorderSide(color: AppColors.border),
                ),
                icon: const Icon(Icons.refresh_rounded, size: 15),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (lyrics.isInstrumental) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.piano_rounded, size: 32, color: AppColors.accent),
            SizedBox(height: 8),
            Text(
              'Instrumental',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ],
        ),
      );
    }

    if (lyrics.syncedLines.isNotEmpty) {
      final lines = lyrics.syncedLines;
      _ensureKeys(current.path, lines.length);

      return ValueListenableBuilder<double>(
        valueListenable: ctrl.positionNotifier,
        builder: (context, pos, _) {
          final activeIdx = _findActiveIndex(lines, pos);
          if (activeIdx >= 0) {
            _scrollToActive(activeIdx);
          }

          return ListView.builder(
            controller: _scrollCtrl,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            itemCount: lines.length,
            itemBuilder: (context, index) {
              final line = lines[index];
              final isActive = index == activeIdx;
              final isPast = activeIdx >= 0 && index < activeIdx;
              final display = line.text.trim().isEmpty ? '♪' : line.text;

              return Padding(
                key: _lineKeys[index],
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => ctrl.seek(line.timeMs.toInt() / 1000.0),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: isActive
                          ? AppColors.accentMuted
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      display,
                      style: TextStyle(
                        fontSize: isActive ? 15 : 13.5,
                        height: 1.4,
                        fontWeight:
                            isActive ? FontWeight.w600 : FontWeight.w400,
                        color: isActive
                            ? AppColors.accent
                            : isPast
                                ? AppColors.textSecondary
                                : AppColors.textPrimary,
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      );
    }

    final plain = lyrics.plainText ?? '';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SelectableText(
        plain,
        style: const TextStyle(
          fontSize: 13.5,
          height: 1.65,
          color: AppColors.textPrimary,
        ),
      ),
    );
  }
}

class _MobileQueuePanel extends StatelessWidget {
  const _MobileQueuePanel({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    final snap = controller.snapshot;
    final count = snap.queueLength;
    final currentIndex = snap.currentIndex;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 6),
          child: Row(
            children: [
              Text(
                'Queue ($count)',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary,
                ),
              ),
              const Spacer(),
              if (count > 0)
                TextButton(
                  onPressed: controller.clearQueuedTracks,
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 28),
                  ),
                  child: const Text(
                    'Clear Added',
                    style: TextStyle(fontSize: 11.5),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1, color: AppColors.border),
        Expanded(
          child: count == 0
              ? const Center(
                  child: Text(
                    'Queue is empty.',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: count,
                  itemExtent: 52,
                  itemBuilder: (context, index) {
                    final item = controller.queueTrackAt(index);
                    if (item == null) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 14),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Loading...',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ),
                      );
                    }
                    final isCurrent = currentIndex == index;
                    final isUpNext =
                        currentIndex != null && index > currentIndex;
                    return InkWell(
                      onTap: () => controller.playIndex(index),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        color: isCurrent
                            ? AppColors.accentMuted
                            : Colors.transparent,
                        child: Row(
                          children: [
                            SizedBox(
                              width: 26,
                              child: isCurrent
                                  ? const Icon(
                                      Icons.graphic_eq_rounded,
                                      size: 16,
                                      color: AppColors.accent,
                                    )
                                  : Text(
                                      '${index + 1}',
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        color: isUpNext
                                            ? AppColors.textSecondary
                                            : AppColors.textMuted,
                                        fontFeatures: const [
                                          FontFeature.tabularFigures()
                                        ],
                                      ),
                                    ),
                            ),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: isCurrent
                                          ? FontWeight.w600
                                          : FontWeight.w500,
                                      color: isCurrent
                                          ? AppColors.accent
                                          : AppColors.textPrimary,
                                    ),
                                  ),
                                  if (item.artist.isNotEmpty)
                                    Text(
                                      item.artist,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 11.5,
                                        color: AppColors.textSecondary,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            if (item.queued)
                              Container(
                                margin: const EdgeInsets.only(right: 4),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.surface,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: AppColors.border),
                                ),
                                child: const Text(
                                  'Q',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: AppColors.accent,
                                  ),
                                ),
                              ),
                            IconButton(
                              tooltip: 'Remove from queue',
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 28,
                                minHeight: 28,
                              ),
                              icon: const Icon(
                                Icons.close_rounded,
                                size: 15,
                                color: AppColors.textMuted,
                              ),
                              onPressed: () =>
                                  controller.removeFromQueue(index),
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
