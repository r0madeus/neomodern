import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';
import 'package:neomodern/ui/mobile/cover_tint.dart';
import 'package:neomodern/ui/track_menu.dart';

enum _SheetBottomTab { lyrics, queue }

int _findActiveLineIndex(List<UiSyncedLine> lines, double posSeconds) {
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
  static const double _carouselViewportFraction = 0.72;

  _SheetBottomTab _bottomTab = _SheetBottomTab.lyrics;
  late final PageController _pageController = PageController(
    initialPage: 1,
    viewportFraction: _carouselViewportFraction,
  );

  String? _lastTrackPath;
  String? _lastCoverPath;
  Color? _dominantColor;
  bool _isSnappingBack = false;

  @override
  void initState() {
    super.initState();
    _syncTrackVisuals();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _snapToCenter() {
    if (!_pageController.hasClients) return;
    final currentPage = _pageController.page?.round() ?? 1;
    if (currentPage == 1) return;
    _isSnappingBack = true;
    try {
      _pageController.jumpToPage(1);
    } finally {
      _isSnappingBack = false;
    }
  }

  void _syncTrackVisuals() {
    final ctrl = widget.controller;
    final snap = ctrl.snapshot;
    final trackPath = snap.current?.path;
    final coverPath = ctrl.currentCoverPath;

    if (trackPath != _lastTrackPath) {
      _lastTrackPath = trackPath;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _snapToCenter();
      });
    }

    if (coverPath != _lastCoverPath) {
      _lastCoverPath = coverPath;
      _dominantColor = MobileCoverCache.cachedColor(coverPath);
      if (coverPath != null && coverPath.isNotEmpty && _dominantColor == null) {
        unawaited(
          MobileCoverCache.resolveColor(coverPath).then((color) {
            if (!mounted || _lastCoverPath != coverPath || color == null) return;
            setState(() => _dominantColor = color);
          }),
        );
      }
    }

    _preloadAdjacentCover(snap.previousTrack?.path);
    _preloadAdjacentCover(snap.nextTrack?.path);
  }

  void _preloadAdjacentCover(String? trackPath) {
    if (trackPath == null || trackPath.isEmpty) return;
    if (MobileCoverCache.cachedTrackCover(trackPath) != null) return;
    unawaited(
      MobileCoverCache.resolveTrackCover(trackPath).then((cover) {
        if (!mounted || cover == null) return;
        setState(() {});
      }),
    );
  }

  bool _onCarouselScrollEnd(
    ScrollEndNotification notification,
    bool hasTrack,
  ) {
    if (notification.depth != 0 || _isSnappingBack || !hasTrack) {
      return false;
    }
    final settledPage = _pageController.hasClients
        ? (_pageController.page?.round() ?? 1)
        : 1;
    if (settledPage == 2) {
      _snapToCenter();
      widget.controller.next();
    } else if (settledPage == 0) {
      _snapToCenter();
      widget.controller.previous();
    }
    return false;
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
          _syncTrackVisuals();

          final snap = ctrl.snapshot;
          final current = snap.current;
          final hasTrack = current != null;
          final duration = snap.durationSeconds;
          final sleepActive = snap.sleepEndOfTrack || snap.sleepEndsAt != null;

          return AnimatedContainer(
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              gradient: buildCoverGradient(_dominantColor),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(18)),
            ),
            child: SafeArea(
              top: false,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final maxPageCover =
                      constraints.maxWidth * _carouselViewportFraction - 16;
                  final coverSize = math
                      .min(
                        math.min(constraints.maxWidth - 72, maxPageCover),
                        (constraints.maxHeight * 0.27).clamp(96.0, 248.0),
                      )
                      .clamp(80.0, 248.0);
                  final compact = constraints.maxHeight < 620;

                  final panels = <(UiTrackInfo?, String?)>[
                    (
                      snap.previousTrack,
                      MobileCoverCache.cachedTrackCover(
                        snap.previousTrack?.path,
                      ),
                    ),
                    (current, ctrl.currentCoverPath),
                    (
                      snap.nextTrack,
                      MobileCoverCache.cachedTrackCover(snap.nextTrack?.path),
                    ),
                  ];

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

                      SizedBox(height: compact ? 4 : 8),

                      // 3-panel elastic cover carousel [previous, current, next]
                      SizedBox(
                        height: coverSize + 12,
                        child: NotificationListener<ScrollEndNotification>(
                          onNotification: (n) =>
                              _onCarouselScrollEnd(n, hasTrack),
                          child: PageView.builder(
                            key: const ValueKey('now_playing_cover_carousel'),
                            controller: _pageController,
                            itemCount: 3,
                            physics: hasTrack
                                ? const BouncingScrollPhysics()
                                : const NeverScrollableScrollPhysics(),
                            itemBuilder: (context, index) {
                              final panelTrack = panels[index].$1;
                              final panelCover = panels[index].$2;

                              return AnimatedBuilder(
                                animation: _pageController,
                                builder: (context, child) {
                                  final page = _pageController.hasClients &&
                                          _pageController
                                              .position.haveDimensions
                                      ? (_pageController.page ?? 1.0)
                                      : 1.0;
                                  final distance =
                                      (page - index).abs().clamp(0.0, 1.0);
                                  final scale = 1.0 - (distance * 0.14);
                                  final baseOpacity = 1.0 - (distance * 0.52);
                                  final effectiveOpacity = panelTrack == null
                                      ? baseOpacity * 0.35
                                      : baseOpacity;

                                  return Center(
                                    child: Opacity(
                                      opacity: effectiveOpacity.clamp(0.0, 1.0),
                                      child: Transform.scale(
                                        scale: scale,
                                        child: child,
                                      ),
                                    ),
                                  );
                                },
                                child: Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: index == 1
                                          ? AppColors.border
                                          : AppColors.border.withAlpha(120),
                                    ),
                                    boxShadow: index == 1
                                        ? [
                                            BoxShadow(
                                              color: Colors.black.withAlpha(85),
                                              blurRadius: 16,
                                              offset: const Offset(0, 6),
                                            ),
                                          ]
                                        : null,
                                  ),
                                  child: CoverArt(
                                    path: panelCover,
                                    size: coverSize,
                                    borderRadius: 12,
                                    iconSize: coverSize * 0.34,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),

                      SizedBox(height: compact ? 8 : 14),

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
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                  ),
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
                            color: AppColors.sidebar.withAlpha(220),
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
                            color: AppColors.sidebar.withAlpha(220),
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

  void _openFullScreenLyrics(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FullScreenLyricsPage(controller: widget.controller),
      ),
    );
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 6, 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  lyrics != null && lyrics.syncedLines.isNotEmpty
                      ? 'Synced Lyrics'
                      : 'Lyrics',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              TextButton.icon(
                onPressed: () => _openFullScreenLyrics(context),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.accent,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(Icons.open_in_full_rounded, size: 14),
                label: const Text(
                  'Expand Lyrics',
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: AppColors.border),
        Expanded(
          child: _buildLyricsBody(ctrl, current, lyrics),
        ),
      ],
    );
  }

  Widget _buildLyricsBody(
    PlayerController ctrl,
    UiTrackInfo current,
    UiLyrics? lyrics,
  ) {
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
          final activeIdx = _findActiveLineIndex(lines, pos);
          if (activeIdx >= 0) {
            _scrollToActive(activeIdx);
          }

          return ListView.builder(
            controller: _scrollCtrl,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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

/// Dedicated full-screen synced lyrics view with large typography, tap-to-seek,
/// cover-tinted gradient backdrop, and compact playback/close controls.
class FullScreenLyricsPage extends StatefulWidget {
  const FullScreenLyricsPage({
    super.key,
    required this.controller,
  });

  final PlayerController controller;

  @override
  State<FullScreenLyricsPage> createState() => _FullScreenLyricsPageState();
}

class _FullScreenLyricsPageState extends State<FullScreenLyricsPage> {
  final ScrollController _scrollCtrl = ScrollController();
  List<GlobalKey> _lineKeys = const [];
  String? _lastKeyedTrack;
  int _lastKeyCount = 0;
  int _lastActiveIdx = -1;

  String? _lastCoverPath;
  Color? _dominantColor;

  @override
  void initState() {
    super.initState();
    _syncCoverTint();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _syncCoverTint() {
    final coverPath = widget.controller.currentCoverPath;
    if (coverPath == _lastCoverPath) return;
    _lastCoverPath = coverPath;
    _dominantColor = MobileCoverCache.cachedColor(coverPath);
    if (coverPath == null || coverPath.isEmpty || _dominantColor != null) {
      return;
    }
    unawaited(
      MobileCoverCache.resolveColor(coverPath).then((color) {
        if (!mounted || _lastCoverPath != coverPath || color == null) return;
        setState(() => _dominantColor = color);
      }),
    );
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
          alignment: 0.38,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final ctrl = widget.controller;
          _syncCoverTint();

          final snap = ctrl.snapshot;
          final current = snap.current;
          final duration = snap.durationSeconds;

          return AnimatedContainer(
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              gradient: buildCoverGradient(_dominantColor),
            ),
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Header with cover thumbnail, track title/artist, and close button
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
                    child: Row(
                      children: [
                        CoverArt(
                          path: ctrl.currentCoverPath,
                          size: 40,
                          borderRadius: 8,
                          iconSize: 18,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                current?.title ?? 'Nothing playing',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                current != null && current.artist.isNotEmpty
                                    ? current.artist
                                    : 'Unknown Artist',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close full-screen lyrics',
                          icon: const Icon(
                            Icons.close_rounded,
                            size: 24,
                            color: AppColors.textPrimary,
                          ),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),

                  const Divider(height: 1, color: AppColors.border),

                  // Lyrics content
                  Expanded(
                    child: _buildFullScreenLyricsContent(ctrl, current),
                  ),

                  // Compact bottom progress + play/pause & close controls
                  Container(
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 14),
                    decoration: BoxDecoration(
                      color: AppColors.canvas.withAlpha(180),
                      border: const Border(
                        top: BorderSide(color: AppColors.border),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ValueListenableBuilder<double>(
                          valueListenable: ctrl.positionNotifier,
                          builder: (context, pos, _) {
                            final maxDur = (duration != null && duration > 0)
                                ? duration
                                : 1.0;
                            final clamped =
                                math.min(math.max(pos, 0.0), maxDur);
                            final progress =
                                (duration != null && duration > 0)
                                    ? math.min(
                                        math.max(clamped / duration, 0.0),
                                        1.0,
                                      )
                                    : 0.0;
                            return Column(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(2),
                                  child: LinearProgressIndicator(
                                    value: current != null ? progress : 0.0,
                                    minHeight: 3,
                                    backgroundColor: AppColors.border,
                                    valueColor:
                                        const AlwaysStoppedAnimation<Color>(
                                      AppColors.accent,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      current != null
                                          ? formatDuration(clamped)
                                          : '--:--',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: AppColors.textSecondary,
                                        fontFeatures: [
                                          FontFeature.tabularFigures()
                                        ],
                                      ),
                                    ),
                                    Text(
                                      current != null
                                          ? formatDuration(duration)
                                          : '--:--',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: AppColors.textSecondary,
                                        fontFeatures: [
                                          FontFeature.tabularFigures()
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            TextButton.icon(
                              onPressed: () => Navigator.of(context).pop(),
                              style: TextButton.styleFrom(
                                foregroundColor: AppColors.textSecondary,
                              ),
                              icon: const Icon(
                                Icons.keyboard_arrow_down_rounded,
                                size: 20,
                              ),
                              label: const Text('Close'),
                            ),
                            const SizedBox(width: 24),
                            Material(
                              color: AppColors.accent,
                              shape: const CircleBorder(),
                              child: InkWell(
                                customBorder: const CircleBorder(),
                                onTap:
                                    current != null ? ctrl.togglePause : null,
                                child: SizedBox(
                                  width: 48,
                                  height: 48,
                                  child: Icon(
                                    ctrl.isPlaying
                                        ? Icons.pause_rounded
                                        : Icons.play_arrow_rounded,
                                    color: AppColors.canvas,
                                    size: 28,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildFullScreenLyricsContent(
    PlayerController ctrl,
    UiTrackInfo? current,
  ) {
    if (current == null) {
      return const Center(
        child: Text(
          'Play a track to view lyrics.',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 16),
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
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.lyrics_outlined,
                size: 40,
                color: AppColors.textMuted,
              ),
              const SizedBox(height: 12),
              Text(
                ctrl.offlineMode
                    ? 'No local lyrics found (Offline Mode is on).'
                    : 'No lyrics found for this track.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 16,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: ctrl.lyricsLoading ? null : ctrl.refreshLyrics,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.textPrimary,
                  side: const BorderSide(color: AppColors.border),
                ),
                icon: const Icon(Icons.refresh_rounded, size: 16),
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
            Icon(Icons.piano_rounded, size: 42, color: AppColors.accent),
            SizedBox(height: 10),
            Text(
              'Instrumental',
              style: TextStyle(
                fontSize: 22,
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
          final activeIdx = _findActiveLineIndex(lines, pos);
          if (activeIdx >= 0) {
            _scrollToActive(activeIdx);
          }

          return ListView.builder(
            controller: _scrollCtrl,
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 28),
            itemCount: lines.length,
            itemBuilder: (context, index) {
              final line = lines[index];
              final isActive = index == activeIdx;
              final isPast = activeIdx >= 0 && index < activeIdx;
              final display = line.text.trim().isEmpty ? '♪' : line.text;

              return Padding(
                key: _lineKeys[index],
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => ctrl.seek(line.timeMs.toInt() / 1000.0),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 180),
                      style: TextStyle(
                        fontSize: isActive ? 26 : 20,
                        height: 1.35,
                        fontWeight:
                            isActive ? FontWeight.w700 : FontWeight.w600,
                        color: isActive
                            ? AppColors.textPrimary
                            : isPast
                                ? AppColors.textMuted.withAlpha(155)
                                : AppColors.textSecondary.withAlpha(180),
                      ),
                      child: Text(display),
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
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: SelectableText(
        plain,
        style: const TextStyle(
          fontSize: 21,
          height: 1.6,
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
