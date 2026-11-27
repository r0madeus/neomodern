import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';
import 'package:neomodern/ui/mobile/cover_tint.dart';
import 'package:neomodern/ui/tinted_backdrop.dart';
import 'package:neomodern/ui/widgets/motion_primitives.dart';

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

String _formatClock(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

/// Opens [NowPlayingSheet] with a `260ms` slide-up transition matching `NowPlaying.svelte`.
Future<void> showNowPlayingSheet(
  BuildContext context, {
  required PlayerController controller,
  ValueChanged<String>? onOpenArtist,
  ValueChanged<int>? onOpenAlbum,
}) {
  return Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      transitionDuration: const Duration(milliseconds: 260),
      reverseTransitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (context, _, _) => NowPlayingSheet(
        controller: controller,
        onOpenArtist: onOpenArtist,
        onOpenAlbum: onOpenAlbum,
      ),
      transitionsBuilder: (context, animation, _, child) {
        final disableAnimations =
            MediaQuery.maybeDisableAnimationsOf(context) ?? false;
        if (disableAnimations) return child;
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeOutCubic,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.0, 1.0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        );
      },
    ),
  );
}

/// Full-screen (`100dvh`) Now Playing sheet matching `NowPlaying.svelte`.
class NowPlayingSheet extends StatefulWidget {
  const NowPlayingSheet({
    super.key,
    required this.controller,
    this.onOpenArtist,
    this.onOpenAlbum,
  });

  final PlayerController controller;
  final ValueChanged<String>? onOpenArtist;
  final ValueChanged<int>? onOpenAlbum;

  @override
  State<NowPlayingSheet> createState() => _NowPlayingSheetState();
}

class _NowPlayingSheetState extends State<NowPlayingSheet>
    with SingleTickerProviderStateMixin {
  final ScrollController _scrollCtrl = ScrollController();
  late final PageController _pageController = PageController(
    initialPage: 1,
    viewportFraction: 1.0,
  );
  late final AnimationController _snapBackCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );

  String? _lastTrackPath;
  String? _lastCoverPath;
  Color? _dominantColor;
  bool _isSnappingCarousel = false;

  // Swipe-down-to-dismiss state
  double _pullY = 0.0;
  double _snapStartY = 0.0;
  bool _pulling = false;
  bool _pointerTracking = false;
  bool _seeking = false;
  Offset _pointerStart = Offset.zero;

  @override
  void initState() {
    super.initState();
    _snapBackCtrl.addListener(() {
      if (!mounted) return;
      final t = Curves.easeOut.transform(_snapBackCtrl.value);
      setState(() {
        _pullY = _snapStartY * (1.0 - t);
      });
    });
    _syncTrackVisuals();
  }

  @override
  void dispose() {
    _snapBackCtrl.dispose();
    _scrollCtrl.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _snapToCenter() {
    if (!_pageController.hasClients) return;
    final currentPage = _pageController.page?.round() ?? 1;
    if (currentPage == 1) return;
    _isSnappingCarousel = true;
    try {
      _pageController.jumpToPage(1);
    } finally {
      _isSnappingCarousel = false;
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
      _dominantColor =
          ctrl.currentCoverColor ?? MobileCoverCache.cachedColor(coverPath);
      if (coverPath != null &&
          coverPath.isNotEmpty &&
          _dominantColor == null) {
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
    if (notification.depth != 0 || _isSnappingCarousel || !hasTrack) {
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

  void _onPointerDown(PointerDownEvent event) {
    if (_seeking) return;
    final atTop = !_scrollCtrl.hasClients || _scrollCtrl.offset <= 0.5;
    if (!atTop) return;
    _snapBackCtrl.stop();
    _pointerTracking = true;
    _pulling = false;
    _pointerStart = event.position;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_pointerTracking || _seeking) return;
    final dx = event.position.dx - _pointerStart.dx;
    final dy = event.position.dy - _pointerStart.dy;
    if (!_pulling) {
      if (dy > 10 && dy.abs() > dx.abs() * 1.2) {
        final atTop = !_scrollCtrl.hasClients || _scrollCtrl.offset <= 0.5;
        if (!atTop) {
          _pointerTracking = false;
          return;
        }
        setState(() {
          _pulling = true;
          _pullY = dy;
        });
      } else if (dx.abs() > 10 || dy < -10) {
        _pointerTracking = false;
      }
      return;
    }
    setState(() {
      _pullY = math.max(0.0, dy);
    });
  }

  void _onPointerUpOrCancel() {
    if (!_pointerTracking) return;
    _pointerTracking = false;
    if (!_pulling) return;
    _pulling = false;
    if (_pullY > 120.0) {
      Navigator.of(context).pop();
      return;
    }
    if (_pullY > 0) {
      _snapStartY = _pullY;
      _snapBackCtrl.forward(from: 0.0);
    }
  }

  void _openFullScreenLyrics() {
    unawaited(
      Navigator.of(context).push<void>(
        PageRouteBuilder<void>(
          transitionDuration: const Duration(milliseconds: 240),
          reverseTransitionDuration: const Duration(milliseconds: 220),
          pageBuilder: (context, _, _) =>
              FullScreenLyricsPage(controller: widget.controller),
          transitionsBuilder: (context, animation, _, child) {
            final disableAnimations =
                MediaQuery.maybeDisableAnimationsOf(context) ?? false;
            if (disableAnimations) return child;
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
            );
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.0, 1.0),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            );
          },
        ),
      ),
    );
  }

  void _openQueueSheet() {
    unawaited(
      showQueueSheet(
        context,
        controller: widget.controller,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final viewportHeight = media.size.height;

    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: (_) => _onPointerUpOrCancel(),
      onPointerCancel: (_) => _onPointerUpOrCancel(),
      child: Transform.translate(
        offset: Offset(0, _pullY),
        child: Material(
          color: AppTheme.zinc950,
          child: ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) {
              final ctrl = widget.controller;
              _syncTrackVisuals();

              final snap = ctrl.snapshot;
              final current = snap.current;
              final hasTrack = current != null;
              final duration = snap.durationSeconds;
              final tint =
                  tintFromColor(ctrl.currentCoverColor ?? _dominantColor);
              final isLocal = current != null &&
                  !current.path.startsWith('http://') &&
                  !current.path.startsWith('https://');

              final panels = <(UiTrackInfo?, String?)>[
                (
                  snap.previousTrack,
                  MobileCoverCache.cachedTrackCover(snap.previousTrack?.path),
                ),
                (current, ctrl.currentCoverPath),
                (
                  snap.nextTrack,
                  MobileCoverCache.cachedTrackCover(snap.nextTrack?.path),
                ),
              ];

              return TintedBackdrop.gradient(
                duration: const Duration(milliseconds: 600),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.0, 0.92],
                  colors: [tint.top, AppTheme.zinc950],
                ),
                child: SingleChildScrollView(
                  controller: _scrollCtrl,
                  physics: _pulling
                      ? const NeverScrollableScrollPhysics()
                      : const ClampingScrollPhysics(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Primary full-screen (100dvh) player section
                      ConstrainedBox(
                        constraints: BoxConstraints(minHeight: viewportHeight),
                        child: Padding(
                          padding: EdgeInsets.only(
                            top: media.padding.top,
                            bottom: media.padding.bottom + 12,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              // 56px Top Bar
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                ),
                                child: SizedBox(
                                  height: 56,
                                  child: Row(
                                    children: [
                                      Transform.translate(
                                        offset: const Offset(-12, 0),
                                        child: IconButton(
                                          tooltip: t('Close'),
                                          padding: const EdgeInsets.all(12),
                                          icon: const Icon(
                                            Icons.keyboard_arrow_down_rounded,
                                            size: 28,
                                            color: Colors.white,
                                          ),
                                          onPressed: () =>
                                              Navigator.of(context).pop(),
                                        ),
                                      ),
                                      Expanded(
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Text(
                                              t('NOW PLAYING'),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w500,
                                                letterSpacing: 1.4,
                                                color: Colors.white
                                                    .withValues(alpha: 0.70),
                                              ),
                                            ),
                                            if (snap.queueLength > 0)
                                              Text(
                                                '${(snap.currentIndex ?? 0) + 1} of ${snap.queueLength}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w700,
                                                  color: Colors.white,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 40),
                                    ],
                                  ),
                                ),
                              ),

                              // 3-panel elastic cover carousel (edge-to-edge)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: SizedBox(
                                  height: math.min(
                                    media.size.width - 48,
                                    (viewportHeight * 0.42).clamp(180.0, 360.0),
                                  ),
                                  child: NotificationListener<
                                      ScrollEndNotification>(
                                    onNotification: (n) =>
                                        _onCarouselScrollEnd(n, hasTrack),
                                    child: PageView.builder(
                                      key: const ValueKey(
                                        'now_playing_cover_carousel',
                                      ),
                                      controller: _pageController,
                                      itemCount: 3,
                                      physics: hasTrack
                                          ? const BouncingScrollPhysics()
                                          : const NeverScrollableScrollPhysics(),
                                      itemBuilder: (context, index) {
                                        final panelTrack = panels[index].$1;
                                        final panelCover = panels[index].$2;
                                        if (panelTrack == null) {
                                          return const SizedBox.shrink();
                                        }
                                        return Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 24,
                                          ),
                                          child: Center(
                                            child: AspectRatio(
                                              aspectRatio: 1,
                                              child: Container(
                                                decoration: BoxDecoration(
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                    8,
                                                  ),
                                                  boxShadow: [
                                                    BoxShadow(
                                                      color: Colors.black
                                                          .withValues(
                                                        alpha: 0.50,
                                                      ),
                                                      blurRadius: 28,
                                                      offset:
                                                          const Offset(0, 12),
                                                    ),
                                                  ],
                                                ),
                                                child: CoverArt(
                                                  path: panelCover,
                                                  borderRadius: 8,
                                                  iconSize: 64,
                                                ),
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ),
                              ),

                              // Bottom controls column
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                  const SizedBox(height: 8),
                                  // Fixed 56px live single-line lyric preview (CurrentLine.svelte)
                                  _CurrentLinePreview(controller: ctrl),
                                  const SizedBox(height: 4),
                                  // Track info row
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              current?.title ??
                                                  t('Nothing playing'),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: AppTheme.displayStyle(
                                                fontSize: 26,
                                                fontWeight: FontWeight.w400,
                                                height: 1.15,
                                                color: hasTrack
                                                    ? AppTheme.editorialPaper
                                                    : AppTheme.zinc400,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            GestureDetector(
                                              onTap: current != null &&
                                                      current.artist.isNotEmpty
                                                  ? () {
                                                      Navigator.of(context)
                                                          .pop();
                                                      widget.onOpenArtist?.call(
                                                        current.artist,
                                                      );
                                                    }
                                                  : null,
                                              child: Text(
                                                current != null &&
                                                        current
                                                            .artist.isNotEmpty
                                                    ? current.artist
                                                    : (hasTrack
                                                        ? t('Unknown Artist')
                                                        : t(
                                                            'Pick a track to play',
                                                          )),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 16,
                                                  color: Colors.white
                                                      .withValues(alpha: 0.70),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (isLocal) ...[
                                        const SizedBox(width: 12),
                                        AnimatedSaveButton(
                                          isSaved: ctrl.isCurrentFavorite,
                                          onPressed: ctrl.toggleCurrentFavorite,
                                          size: 24,
                                          light: true,
                                        ),
                                      ],
                                    ],
                                  ),

                                  const SizedBox(height: 20),

                                  // Seekbar + timestamps
                                  ValueListenableBuilder<double>(
                                    valueListenable: ctrl.positionNotifier,
                                    builder: (context, pos, _) {
                                      final maxDur =
                                          (duration != null && duration > 0)
                                              ? duration
                                              : 1.0;
                                      final clampedPos =
                                          pos.clamp(0.0, maxDur).toDouble();
                                      return Column(
                                        children: [
                                          HoverSeekBar(
                                            value: hasTrack ? clampedPos : 0.0,
                                            min: 0.0,
                                            max: maxDur,
                                            alwaysShowThumb: true,
                                            light: true,
                                            onChangeStart: hasTrack
                                                ? (_) {
                                                    _seeking = true;
                                                    ctrl.beginSeekDrag();
                                                  }
                                                : null,
                                            onChanged: hasTrack
                                                ? (v) => ctrl.updateSeekDrag(v)
                                                : null,
                                            onChangeEnd: hasTrack
                                                ? (v) {
                                                    _seeking = false;
                                                    ctrl.endSeekDrag(v);
                                                  }
                                                : null,
                                          ),
                                          const SizedBox(height: 4),
                                          Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceBetween,
                                            children: [
                                              Text(
                                                hasTrack
                                                    ? formatDuration(clampedPos)
                                                    : '--:--',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.white
                                                      .withValues(alpha: 0.60),
                                                  fontFeatures: const [
                                                    FontFeature.tabularFigures(),
                                                  ],
                                                ),
                                              ),
                                              Text(
                                                hasTrack
                                                    ? formatDuration(duration)
                                                    : '--:--',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.white
                                                      .withValues(alpha: 0.60),
                                                  fontFeatures: const [
                                                    FontFeature.tabularFigures(),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      );
                                    },
                                  ),

                                  const SizedBox(height: 8),

                                  // Main transport controls
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      _ActiveDotIconButton(
                                        icon: Icons.shuffle_rounded,
                                        size: 24,
                                        active: snap.shuffle,
                                        tooltip: t(
                                          snap.shuffle
                                              ? 'Shuffle on'
                                              : 'Shuffle off',
                                        ),
                                        onPressed: ctrl.toggleShuffle,
                                      ),
                                      IconButton(
                                        tooltip: t('Previous'),
                                        padding: const EdgeInsets.all(8),
                                        icon: const Icon(
                                          Icons.skip_previous_rounded,
                                          size: 40,
                                          color: Colors.white,
                                        ),
                                        onPressed:
                                            hasTrack ? ctrl.previous : null,
                                      ),
                                      _WhiteCirclePlayButton(
                                        size: 72,
                                        iconSize: 36,
                                        playing: ctrl.isPlaying,
                                        tooltip: t(
                                          ctrl.isPlaying ? 'Pause' : 'Play',
                                        ),
                                        onPressed: ctrl.togglePause,
                                      ),
                                      IconButton(
                                        tooltip: t('Next'),
                                        padding: const EdgeInsets.all(8),
                                        icon: const Icon(
                                          Icons.skip_next_rounded,
                                          size: 40,
                                          color: Colors.white,
                                        ),
                                        onPressed: hasTrack ? ctrl.next : null,
                                      ),
                                      _ActiveDotIconButton(
                                        icon: snap.repeat == 'one'
                                            ? Icons.repeat_one_rounded
                                            : Icons.repeat_rounded,
                                        size: 24,
                                        active: snap.repeat != 'off',
                                        tooltip: t('Repeat: ${snap.repeat}'),
                                        onPressed: ctrl.cycleRepeat,
                                      ),
                                    ],
                                  ),

                                  const SizedBox(height: 12),

                                  // Bottom 3-icon action row: Lyrics, SleepTimer, Queue
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Transform.translate(
                                        offset: const Offset(-12, 0),
                                        child: IconButton(
                                          tooltip: t('Lyrics'),
                                          padding: const EdgeInsets.all(12),
                                          icon: Icon(
                                            Icons.lyrics_rounded,
                                            size: 24,
                                            color: Colors.white
                                                .withValues(alpha: 0.80),
                                          ),
                                          onPressed: _openFullScreenLyrics,
                                        ),
                                      ),
                                      _MobileSleepTimerButton(controller: ctrl),
                                      Transform.translate(
                                        offset: const Offset(12, 0),
                                        child: IconButton(
                                          tooltip: t('Queue'),
                                          padding: const EdgeInsets.all(12),
                                          icon: Icon(
                                            Icons.queue_music_rounded,
                                            size: 24,
                                            color: Colors.white
                                                .withValues(alpha: 0.80),
                                          ),
                                          onPressed: _openQueueSheet,
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
                      ),

                      // Below the fold: Synced Lyrics Card
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          16,
                          4,
                          16,
                          media.padding.bottom + 24,
                        ),
                        child: _BelowFoldLyricsCard(
                          controller: ctrl,
                          tint: tint,
                          onExpand: _openFullScreenLyrics,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _WhiteCirclePlayButton extends StatefulWidget {
  const _WhiteCirclePlayButton({
    required this.size,
    required this.iconSize,
    required this.playing,
    required this.onPressed,
    required this.tooltip,
  });

  final double size;
  final double iconSize;
  final bool playing;
  final VoidCallback? onPressed;
  final String tooltip;

  @override
  State<_WhiteCirclePlayButton> createState() => _WhiteCirclePlayButtonState();
}

class _WhiteCirclePlayButtonState extends State<_WhiteCirclePlayButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: GestureDetector(
        onTapDown: widget.onPressed == null
            ? null
            : (_) => setState(() => _pressed = true),
        onTapUp: widget.onPressed == null
            ? null
            : (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onPressed,
        child: AnimatedScale(
          scale: _pressed ? 0.95 : 1.0,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
          child: Container(
            width: widget.size,
            height: widget.size,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(
              widget.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: widget.iconSize,
              color: AppTheme.zinc950,
            ),
          ),
        ),
      ),
    );
  }
}

class _ActiveDotIconButton extends StatelessWidget {
  const _ActiveDotIconButton({
    required this.icon,
    required this.size,
    required this.active,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final double size;
  final bool active;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        IconButton(
          tooltip: tooltip,
          padding: const EdgeInsets.all(12),
          icon: Icon(
            icon,
            size: size,
            color: active ? AppTheme.accent400 : Colors.white,
          ),
          onPressed: onPressed,
        ),
        if (active)
          Positioned(
            bottom: 4,
            child: Container(
              width: 4,
              height: 4,
              decoration: const BoxDecoration(
                color: AppTheme.accent400,
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    );
  }
}

/// Fixed `56px` live single-line lyric preview matching `CurrentLine.svelte`.
class _CurrentLinePreview extends StatelessWidget {
  const _CurrentLinePreview({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    final lyrics = controller.currentLyrics;
    if (lyrics == null ||
        !lyrics.found ||
        lyrics.isInstrumental ||
        lyrics.syncedLines.isEmpty) {
      return const SizedBox(height: 56);
    }

    final lines = lyrics.syncedLines;
    return SizedBox(
      height: 56,
      child: ValueListenableBuilder<double>(
        valueListenable: controller.positionNotifier,
        builder: (context, pos, _) {
          final at = _findActiveLineIndex(lines, pos);
          int? displayKey;
          String? displayText;
          var isUpcoming = false;

          if (at >= 0 && lines[at].text.trim().isNotEmpty) {
            displayKey = at;
            displayText = lines[at].text;
          } else {
            for (var j = at + 1; j < lines.length; j++) {
              if (lines[j].text.trim().isNotEmpty) {
                displayKey = j;
                displayText = lines[j].text;
                isUpcoming = true;
                break;
              }
            }
          }

          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            reverseDuration: const Duration(milliseconds: 120),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: displayText == null
                ? const SizedBox.shrink(key: ValueKey(-1))
                : Align(
                    key: ValueKey(displayKey),
                    alignment: Alignment.centerLeft,
                    child: Text(
                      displayText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 17,
                        height: 1.35,
                        fontWeight: FontWeight.w700,
                        color: isUpcoming
                            ? Colors.white.withValues(alpha: 0.45)
                            : Colors.white,
                      ),
                    ),
                  ),
          );
        },
      ),
    );
  }
}

class _BelowFoldLyricsCard extends StatefulWidget {
  const _BelowFoldLyricsCard({
    required this.controller,
    required this.tint,
    required this.onExpand,
  });

  final PlayerController controller;
  final CoverTint tint;
  final VoidCallback onExpand;

  @override
  State<_BelowFoldLyricsCard> createState() => _BelowFoldLyricsCardState();
}

class _BelowFoldLyricsCardState extends State<_BelowFoldLyricsCard> {
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
      if (!mounted || !_scrollCtrl.hasClients) return;
      final ctx = _lineKeys[idx].currentContext;
      final renderObj = ctx?.findRenderObject();
      if (renderObj == null) return;
      final viewport = RenderAbstractViewport.maybeOf(renderObj);
      if (viewport == null) return;
      final reveal = viewport.getOffsetToReveal(renderObj, 0.38);
      final target = reveal.offset.clamp(
        _scrollCtrl.position.minScrollExtent,
        _scrollCtrl.position.maxScrollExtent,
      );
      _scrollCtrl.animateTo(
        target,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final current = ctrl.snapshot.current;
    final lyrics = ctrl.currentLyrics;
    final hasLyrics = lyrics != null &&
        lyrics.found &&
        (lyrics.syncedLines.isNotEmpty ||
            (lyrics.plainText?.isNotEmpty ?? false));

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: TintedBackdrop.solid(
        color: widget.tint.surface,
        duration: const Duration(milliseconds: 500),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 14, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      t('Lyrics'),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  if (current != null)
                    _DarkCircleButton(
                      icon: Icons.refresh_rounded,
                      tooltip: t('Refresh lyrics'),
                      onPressed: ctrl.lyricsLoading ? null : ctrl.refreshLyrics,
                    ),
                  if (hasLyrics) ...[
                    const SizedBox(width: 8),
                    _DarkCircleButton(
                      icon: Icons.open_in_full_rounded,
                      tooltip: 'Expand Lyrics',
                      onPressed: widget.onExpand,
                    ),
                  ],
                ],
              ),
            ),
            if (hasLyrics)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onExpand,
                child: SizedBox(
                  height: 240,
                  child: ShaderMask(
                    shaderCallback: (rect) => const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [0.0, 0.18, 0.78, 1.0],
                      colors: [
                        Colors.transparent,
                        Colors.black,
                        Colors.black,
                        Colors.transparent,
                      ],
                    ).createShader(rect),
                    blendMode: BlendMode.dstIn,
                    child: _buildPreviewBody(ctrl, current!, lyrics),
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                child: _buildEmptyState(ctrl, lyrics),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(PlayerController ctrl, UiLyrics? lyrics) {
    final String text;
    if (ctrl.lyricsLoading && lyrics == null) {
      text = t('Looking for lyrics...');
    } else if (lyrics != null && lyrics.found && lyrics.isInstrumental) {
      text = '♪ ${t('Instrumental')}';
    } else if (ctrl.offlineMode) {
      text = t('No local lyrics found (Offline Mode is on).');
    } else {
      text = t('No lyrics found for this track.');
    }
    return Text(
      text,
      style: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: widget.tint.dim,
      ),
    );
  }

  Widget _buildPreviewBody(
    PlayerController ctrl,
    UiTrackInfo current,
    UiLyrics lyrics,
  ) {
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
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 96),
            itemCount: lines.length,
            itemBuilder: (context, index) {
              final line = lines[index];
              final isActive = index == activeIdx;
              final isPast = activeIdx >= 0 && index < activeIdx;
              final blank = line.text.trim().isEmpty;
              final display = blank ? '♪' : line.text;
              final color = isActive
                  ? Colors.white
                  : isPast
                      ? Colors.white.withValues(alpha: 0.50)
                      : widget.tint.dim;
              return Padding(
                key: _lineKeys[index],
                padding: const EdgeInsets.only(bottom: 14),
                child: AnimatedScale(
                  scale: isActive && !blank ? 1.02 : 1.0,
                  alignment: Alignment.centerLeft,
                  duration: const Duration(milliseconds: 240),
                  child: Text(
                    display,
                    style: AppTheme.displayStyle(
                      fontSize: blank ? 16 : 25,
                      height: 1.22,
                      fontWeight: FontWeight.w400,
                      fontStyle: isActive && !blank
                          ? FontStyle.italic
                          : FontStyle.normal,
                      color: color,
                    ),
                  ),
                ),
              );
            },
          );
        },
      );
    }

    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
      child: Text(
        lyrics.plainText ?? '',
        style: const TextStyle(
          fontSize: 27,
          height: 1.15,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _DarkCircleButton extends StatelessWidget {
  const _DarkCircleButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.black.withValues(alpha: 0.25),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(
              icon,
              size: 16,
              color: onPressed == null
                  ? Colors.white.withValues(alpha: 0.4)
                  : Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileSleepTimerButton extends StatefulWidget {
  const _MobileSleepTimerButton({
    required this.controller,
    this.card = false,
  });

  final PlayerController controller;
  final bool card;

  @override
  State<_MobileSleepTimerButton> createState() =>
      _MobileSleepTimerButtonState();
}

class _MobileSleepTimerButtonState extends State<_MobileSleepTimerButton> {
  Timer? _tickTimer;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant _MobileSleepTimerButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    super.dispose();
  }

  void _syncTicker() {
    final endsAt = widget.controller.snapshot.sleepEndsAt;
    if (endsAt != null && _tickTimer == null) {
      _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (endsAt == null && _tickTimer != null) {
      _tickTimer?.cancel();
      _tickTimer = null;
    }
  }

  int? _remainingSeconds() {
    final endsAt = widget.controller.snapshot.sleepEndsAt;
    if (endsAt == null) return null;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    return math.max(0, ((endsAt.toInt() - nowMs) / 1000.0).round());
  }

  Future<void> _openPicker() async {
    final ctrl = widget.controller;
    final snap = ctrl.snapshot;
    final active = snap.sleepEndsAt != null || snap.sleepEndOfTrack;
    const choices = [15, 30, 45, 60, 90, 120];

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.zinc900,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(
                  t('Sleep timer'),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.zinc400,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
              for (final m in choices)
                ListTile(
                  dense: true,
                  title: Text(
                    m < 60
                        ? '$m minutes'
                        : m == 60
                            ? '1 hour'
                            : '${m ~/ 60} hours',
                    style: const TextStyle(color: AppTheme.zinc100),
                  ),
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    unawaited(ctrl.setSleepTimer(minutes: m.toDouble()));
                  },
                ),
              ListTile(
                dense: true,
                title: const Text(
                  'End of this song',
                  style: TextStyle(color: AppTheme.zinc100),
                ),
                trailing: snap.sleepEndOfTrack
                    ? const Icon(
                        Icons.check_rounded,
                        size: 18,
                        color: AppTheme.accent400,
                      )
                    : null,
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  unawaited(ctrl.setSleepTimer(endOfTrack: true));
                },
              ),
              if (active) ...[
                const Divider(color: AppTheme.zinc800),
                ListTile(
                  dense: true,
                  title: const Text(
                    'Turn off timer',
                    style: TextStyle(color: AppTheme.danger),
                  ),
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    unawaited(ctrl.setSleepTimer());
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _syncTicker();
    final snap = widget.controller.snapshot;
    final left = _remainingSeconds();
    final endOfTrack = snap.sleepEndOfTrack;
    final active = left != null || endOfTrack;

    if (widget.card) {
      return Expanded(
        child: Material(
          color: AppTheme.zinc800,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: _openPicker,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.bedtime_rounded,
                    size: 24,
                    color: active ? AppTheme.accent400 : AppTheme.zinc100,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    left != null
                        ? _formatClock(left)
                        : endOfTrack
                            ? 'End'
                            : 'Timer',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: active ? AppTheme.accent400 : AppTheme.zinc100,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Tooltip(
      message: t('Sleep Timer'),
      child: InkWell(
        borderRadius: BorderRadius.circular(9999),
        onTap: _openPicker,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.bedtime_rounded,
                size: 24,
                color: active
                    ? AppTheme.accent400
                    : Colors.white.withValues(alpha: 0.80),
              ),
              if (left != null) ...[
                const SizedBox(width: 6),
                Text(
                  _formatClock(left),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.accent400,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ] else if (endOfTrack) ...[
                const SizedBox(width: 6),
                const Text(
                  'End',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.accent400,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Full-screen lyrics page matching `LyricsScreen.svelte`.
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
  bool _follow = true;

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
    final ctrl = widget.controller;
    final coverPath = ctrl.currentCoverPath;
    if (coverPath == _lastCoverPath) return;
    _lastCoverPath = coverPath;
    _dominantColor =
        ctrl.currentCoverColor ?? MobileCoverCache.cachedColor(coverPath);
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
      _follow = true;
      _lineKeys = List.generate(count, (_) => GlobalKey());
    }
  }

  void _scrollToActive(int idx, {bool force = false}) {
    if (!_follow && !force) return;
    if (idx < 0 || idx >= _lineKeys.length) return;
    if (!force && idx == _lastActiveIdx) return;
    _lastActiveIdx = idx;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtrl.hasClients) return;
      final ctx = _lineKeys[idx].currentContext;
      final renderObj = ctx?.findRenderObject();
      if (renderObj == null) return;
      final viewport = RenderAbstractViewport.maybeOf(renderObj);
      if (viewport == null) return;
      final reveal = viewport.getOffsetToReveal(renderObj, 1.0 / 3.0);
      final target = reveal.offset.clamp(
        _scrollCtrl.position.minScrollExtent,
        _scrollCtrl.position.maxScrollExtent,
      );
      _scrollCtrl.animateTo(
        target,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _resumeSync() {
    setState(() => _follow = true);
    if (_lastActiveIdx >= 0) {
      _scrollToActive(_lastActiveIdx, force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.zinc950,
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final ctrl = widget.controller;
          _syncCoverTint();
          final snap = ctrl.snapshot;
          final current = snap.current;
          final duration = snap.durationSeconds;
          final tint =
              tintFromColor(ctrl.currentCoverColor ?? _dominantColor);

          return TintedBackdrop.solid(
            color: tint.surface,
            duration: const Duration(milliseconds: 600),
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 64px header
                  SizedBox(
                    height: 64,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: t('Close'),
                            padding: const EdgeInsets.all(12),
                            icon: const Icon(
                              Icons.keyboard_arrow_down_rounded,
                              size: 28,
                              color: Colors.white,
                            ),
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                          Expanded(
                            child: current == null
                                ? const SizedBox.shrink()
                                : Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        current.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w700,
                                          color: Colors.white,
                                        ),
                                      ),
                                      const SizedBox(height: 1),
                                      Text(
                                        current.artist.isNotEmpty
                                            ? current.artist
                                            : t('Unknown Artist'),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: Colors.white
                                              .withValues(alpha: 0.70),
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                          if (current != null)
                            IconButton(
                              tooltip: t('Refresh lyrics'),
                              padding: const EdgeInsets.all(12),
                              icon: Icon(
                                Icons.refresh_rounded,
                                size: 24,
                                color: Colors.white.withValues(alpha: 0.80),
                              ),
                              onPressed: ctrl.lyricsLoading
                                  ? null
                                  : ctrl.refreshLyrics,
                            )
                          else
                            const SizedBox(width: 48),
                        ],
                      ),
                    ),
                  ),

                  // Lyrics body + floating Sync pill
                  Expanded(
                    child: _buildLyricsArea(ctrl, current, tint),
                  ),

                  // Bottom seekbar + 56x56 white Play/Pause button
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
                    child: ValueListenableBuilder<double>(
                      valueListenable: ctrl.positionNotifier,
                      builder: (context, pos, _) {
                        final maxDur = (duration != null && duration > 0)
                            ? duration
                            : 1.0;
                        final clamped = pos.clamp(0.0, maxDur).toDouble();
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            HoverSeekBar(
                              value: current != null ? clamped : 0.0,
                              min: 0.0,
                              max: maxDur,
                              alwaysShowThumb: true,
                              light: true,
                              onChangeStart: current != null
                                  ? (_) => ctrl.beginSeekDrag()
                                  : null,
                              onChanged: current != null
                                  ? (v) => ctrl.updateSeekDrag(v)
                                  : null,
                              onChangeEnd: current != null
                                  ? (v) => ctrl.endSeekDrag(v)
                                  : null,
                            ),
                            const SizedBox(height: 4),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                SizedBox(
                                  width: 48,
                                  child: Text(
                                    current != null
                                        ? formatDuration(clamped)
                                        : '--:--',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.white
                                          .withValues(alpha: 0.60),
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ),
                                _WhiteCirclePlayButton(
                                  size: 56,
                                  iconSize: 28,
                                  playing: ctrl.isPlaying,
                                  tooltip: t(ctrl.isPlaying ? 'Pause' : 'Play'),
                                  onPressed:
                                      current != null ? ctrl.togglePause : null,
                                ),
                                SizedBox(
                                  width: 48,
                                  child: Text(
                                    current != null
                                        ? formatDuration(duration)
                                        : '--:--',
                                    textAlign: TextAlign.right,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.white
                                          .withValues(alpha: 0.60),
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        );
                      },
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

  Widget _buildLyricsArea(
    PlayerController ctrl,
    UiTrackInfo? current,
    CoverTint tint,
  ) {
    if (current == null) {
      return Center(
        child: Text(
          t('Play a track to view lyrics.'),
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: tint.dim,
          ),
        ),
      );
    }

    final lyrics = ctrl.currentLyrics;
    if (ctrl.lyricsLoading && lyrics == null) {
      return Center(
        child: Text(
          t('Looking for lyrics...'),
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: tint.dim,
          ),
        ),
      );
    }

    if (lyrics == null || !lyrics.found) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            ctrl.offlineMode
                ? t('No local lyrics found (Offline Mode is on).')
                : t('No lyrics found for this track.'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: tint.dim,
            ),
          ),
        ),
      );
    }

    if (lyrics.isInstrumental) {
      return Center(
        child: Text(
          '♪ ${t('Instrumental')}',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: tint.dim,
          ),
        ),
      );
    }

    if (lyrics.syncedLines.isNotEmpty) {
      final lines = lyrics.syncedLines;
      _ensureKeys(current.path, lines.length);

      return Stack(
        children: [
          NotificationListener<UserScrollNotification>(
            onNotification: (notification) {
              if (_follow && notification.direction.index != 0) {
                setState(() => _follow = false);
              }
              return false;
            },
            child: ValueListenableBuilder<double>(
              valueListenable: ctrl.positionNotifier,
              builder: (context, pos, _) {
                final activeIdx = _findActiveLineIndex(lines, pos);
                if (activeIdx >= 0) {
                  _scrollToActive(activeIdx);
                }

                return ListView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 200),
                  itemCount: lines.length,
                  itemBuilder: (context, index) {
                    final line = lines[index];
                    final isActive = index == activeIdx;
                    final isPast = activeIdx >= 0 && index < activeIdx;
                    final blank = line.text.trim().isEmpty;
                    final display = blank ? '♪' : line.text;
                    final color = isActive
                        ? Colors.white
                        : isPast
                            ? Colors.white.withValues(alpha: 0.50)
                            : tint.dim;

                    return Padding(
                      key: _lineKeys[index],
                      padding: const EdgeInsets.only(bottom: 20),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          setState(() => _follow = true);
                          ctrl.seek(line.timeMs.toInt() / 1000.0);
                        },
                        child: AnimatedScale(
                          scale: isActive && !blank ? 1.02 : 1.0,
                          alignment: Alignment.centerLeft,
                          duration: const Duration(milliseconds: 220),
                          child: Text(
                            display,
                            style: TextStyle(
                              fontSize: blank ? 16 : 28,
                              height: 1.25,
                              fontWeight: FontWeight.w700,
                              color: color,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          if (!_follow)
            Positioned(
              bottom: 12,
              left: 0,
              right: 0,
              child: Center(
                child: Material(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(9999),
                  elevation: 6,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(9999),
                    onTap: _resumeSync,
                    child: const Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Text(
                        'Sync',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.zinc950,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: SelectableText(
        lyrics.plainText ?? '',
        style: const TextStyle(
          fontSize: 26,
          height: 1.35,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// Shows the `70vh` rounded-t-2xl Queue bottom sheet matching `QueueSheet.svelte`.
Future<void> showQueueSheet(
  BuildContext context, {
  required PlayerController controller,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.50),
    builder: (_) => QueueSheet(controller: controller),
  );
}

class QueueSheet extends StatefulWidget {
  const QueueSheet({super.key, required this.controller});

  final PlayerController controller;

  @override
  State<QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends State<QueueSheet> {
  bool _editing = false;

  @override
  Widget build(BuildContext context) {
    final sheetHeight = MediaQuery.sizeOf(context).height * 0.70;
    return Container(
      height: sheetHeight,
      decoration: const BoxDecoration(
        color: AppTheme.zinc900,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) {
            final ctrl = widget.controller;
            final snap = ctrl.snapshot;
            final count = snap.queueLength;
            final currentIdx = snap.currentIndex;
            final current = snap.current;
            final upNextCount = (currentIdx != null && count > currentIdx + 1)
                ? count - currentIdx - 1
                : 0;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(top: 10, bottom: 6),
                      decoration: BoxDecoration(
                        color: AppTheme.zinc600,
                        borderRadius: BorderRadius.circular(9999),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          t('Queue'),
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      if (count > 0) ...[
                        _QueuePillButton(
                          label: t('Clear'),
                          onTap: ctrl.clearQueuedTracks,
                        ),
                        const SizedBox(width: 8),
                      ],
                      if (upNextCount > 0)
                        _QueuePillButton(
                          label: _editing ? 'Done' : t('Edit'),
                          active: _editing,
                          onTap: () => setState(() => _editing = !_editing),
                        ),
                    ],
                  ),
                ),
                if (snap.context != null && snap.context!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                    child: Text(
                      'Playing ${snap.context!}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        color: AppTheme.zinc400,
                      ),
                    ),
                  )
                else
                  const SizedBox(height: 10),

                // Current track row with EqualizerIndicator
                if (current != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: SizedBox(
                      height: 64,
                      child: Row(
                        children: [
                          CoverArt(
                            path: ctrl.currentCoverPath,
                            size: 48,
                            borderRadius: 6,
                            iconSize: 20,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    if (ctrl.isPlaying) ...[
                                      const EqualizerIndicator(
                                        color: AppTheme.accent400,
                                        height: 13,
                                        playing: true,
                                      ),
                                      const SizedBox(width: 6),
                                    ],
                                    Expanded(
                                      child: Text(
                                        current.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                          color: AppTheme.accent400,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  current.artist.isNotEmpty
                                      ? current.artist
                                      : t('Unknown Artist'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: AppTheme.zinc400,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          _WhiteCirclePlayButton(
                            size: 40,
                            iconSize: 20,
                            playing: ctrl.isPlaying,
                            tooltip: t(ctrl.isPlaying ? 'Pause' : 'Play'),
                            onPressed: ctrl.togglePause,
                          ),
                        ],
                      ),
                    ),
                  ),

                // Up next list
                Expanded(
                  child: upNextCount == 0
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                          child: Text(
                            count == 0
                                ? t('Queue is empty.')
                                : 'Nothing after this song.',
                            style: const TextStyle(
                              fontSize: 14,
                              color: AppTheme.zinc400,
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: upNextCount,
                          itemExtent: 64,
                          itemBuilder: (context, idx) {
                            final queueIndex = (currentIdx ?? -1) + 1 + idx;
                            final item = ctrl.queueTrackAt(queueIndex);
                            if (item == null) {
                              return const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 16),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    'Loading...',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: AppTheme.zinc500,
                                    ),
                                  ),
                                ),
                              );
                            }
                            final cover =
                                MobileCoverCache.cachedTrackCover(item.path);
                            return InkWell(
                              onTap: () => ctrl.playIndex(queueIndex),
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 16),
                                child: Row(
                                  children: [
                                    if (_editing) ...[
                                      IconButton(
                                        icon: const Icon(
                                          Icons.remove_circle_outline_rounded,
                                          size: 22,
                                          color: AppTheme.danger,
                                        ),
                                        onPressed: () =>
                                            ctrl.removeFromQueue(queueIndex),
                                      ),
                                      const SizedBox(width: 4),
                                    ],
                                    CoverArt(
                                      path: cover,
                                      size: 48,
                                      borderRadius: 6,
                                      iconSize: 20,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            item.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 15,
                                              color: AppTheme.zinc100,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Row(
                                            children: [
                                              if (item.queued) ...[
                                                const Icon(
                                                  Icons.queue_music_rounded,
                                                  size: 14,
                                                  color: AppTheme.accent400,
                                                ),
                                                const SizedBox(width: 4),
                                              ],
                                              Expanded(
                                                child: Text(
                                                  item.artist.isNotEmpty
                                                      ? item.artist
                                                      : t('Unknown Artist'),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 13,
                                                    color: AppTheme.zinc400,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (!_editing)
                                      IconButton(
                                        tooltip: t('Remove from queue'),
                                        icon: const Icon(
                                          Icons.close_rounded,
                                          size: 18,
                                          color: AppTheme.zinc400,
                                        ),
                                        onPressed: () =>
                                            ctrl.removeFromQueue(queueIndex),
                                      ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),

                // Bottom 3 action cards: Shuffle, Repeat, Timer
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: _QueueBottomCard(
                          icon: Icons.shuffle_rounded,
                          label: t('Shuffle'),
                          active: snap.shuffle,
                          onTap: ctrl.toggleShuffle,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _QueueBottomCard(
                          icon: snap.repeat == 'one'
                              ? Icons.repeat_one_rounded
                              : Icons.repeat_rounded,
                          label: snap.repeat == 'one'
                              ? 'Repeat one'
                              : snap.repeat == 'all'
                                  ? 'Repeat all'
                                  : 'Repeat',
                          active: snap.repeat != 'off',
                          onTap: ctrl.cycleRepeat,
                        ),
                      ),
                      const SizedBox(width: 12),
                      _MobileSleepTimerButton(controller: ctrl, card: true),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _QueuePillButton extends StatelessWidget {
  const _QueuePillButton({
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? AppTheme.zinc100 : AppTheme.zinc800,
      borderRadius: BorderRadius.circular(9999),
      child: InkWell(
        borderRadius: BorderRadius.circular(9999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: active ? AppTheme.zinc900 : Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

class _QueueBottomCard extends StatelessWidget {
  const _QueueBottomCard({
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
    final color = active ? AppTheme.accent400 : AppTheme.zinc100;
    return Material(
      color: AppTheme.zinc800,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 24, color: color),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
