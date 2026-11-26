import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';
import 'package:neomodern/ui/mobile/cover_tint.dart';
import 'package:neomodern/ui/mobile/now_playing_sheet.dart';
import 'package:neomodern/ui/tinted_backdrop.dart';
import 'package:neomodern/ui/widgets/motion_primitives.dart';

/// Floating mini player bar above the bottom navigation matching `MiniPlayer.svelte`.
class MiniPlayer extends StatefulWidget {
  const MiniPlayer({
    super.key,
    required this.controller,
    this.onOpenArtist,
    this.onOpenAlbum,
    this.onTap,
  });

  final PlayerController controller;
  final ValueChanged<String>? onOpenArtist;
  final ValueChanged<int>? onOpenAlbum;
  final VoidCallback? onTap;

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer>
    with SingleTickerProviderStateMixin {
  static const Cubic _settleCurve = Cubic(0.22, 0.8, 0.3, 1);
  static const double _distanceFraction = 0.28;
  static const double _flickVelocityPxPerSec = 450.0;

  late final AnimationController _settleCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  );

  String? _lastTrackPath;
  String? _lastCoverPath;
  Color? _dominantColor;

  double _rawDx = 0.0;
  double _offset = 0.0;
  double _animFrom = 0.0;
  double _animTo = 0.0;
  bool _committing = false;
  double _stripWidth = 1.0;

  @override
  void initState() {
    super.initState();
    _settleCtrl.addListener(_onSettleTick);
    _syncVisuals();
  }

  @override
  void didUpdateWidget(covariant MiniPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncVisuals();
  }

  @override
  void dispose() {
    _settleCtrl.dispose();
    super.dispose();
  }

  void _onSettleTick() {
    if (!mounted) return;
    final t = _settleCurve.transform(_settleCtrl.value);
    setState(() {
      _offset = _animFrom + (_animTo - _animFrom) * t;
    });
  }

  void _syncVisuals() {
    final ctrl = widget.controller;
    final snap = ctrl.snapshot;
    final trackPath = snap.current?.path;
    final coverPath = ctrl.currentCoverPath;

    if (trackPath != _lastTrackPath) {
      _lastTrackPath = trackPath;
      if (!_committing) {
        _settleCtrl.stop();
        _rawDx = 0.0;
        _offset = 0.0;
      }
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

  String? _coverOf(UiTrackInfo track) {
    final snap = widget.controller.snapshot;
    if (snap.current?.path == track.path &&
        widget.controller.currentCoverPath != null) {
      return widget.controller.currentCoverPath;
    }
    return MobileCoverCache.cachedTrackCover(track.path);
  }

  void _onDragStart(DragStartDetails details) {
    if (_committing) return;
    _settleCtrl.stop();
    _rawDx = 0.0;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (_committing) return;
    final snap = widget.controller.snapshot;
    final hasNext = snap.nextTrack != null;
    final hasPrev = snap.previousTrack != null;
    _rawDx += details.delta.dx;
    final blocked = (_rawDx < 0 && !hasNext) || (_rawDx > 0 && !hasPrev);
    setState(() {
      _offset = blocked ? _rawDx * 0.25 : _rawDx;
    });
  }

  void _onDragEnd(DragEndDetails details) {
    if (_committing) return;
    final snap = widget.controller.snapshot;
    final hasNext = snap.nextTrack != null;
    final hasPrev = snap.previousTrack != null;
    final width = _stripWidth > 1.0 ? _stripWidth : 1.0;
    final vx = details.velocity.pixelsPerSecond.dx;
    final dx = _offset;

    final toNext = hasNext &&
        (dx < -width * _distanceFraction ||
            (vx < -_flickVelocityPxPerSec && dx < 0));
    final toPrev = hasPrev &&
        (dx > width * _distanceFraction ||
            (vx > _flickVelocityPxPerSec && dx > 0));

    _rawDx = 0.0;
    if (!toNext && !toPrev) {
      _animateOffsetTo(0.0);
      return;
    }

    _committing = true;
    final target = toNext ? -width : width;
    _animateOffsetTo(target).then((_) async {
      try {
        if (toNext) {
          await widget.controller.next();
        } else {
          await widget.controller.previous();
        }
      } finally {
        if (mounted) {
          setState(() {
            _offset = 0.0;
            _rawDx = 0.0;
            _committing = false;
          });
        } else {
          _committing = false;
        }
      }
    });
  }

  void _onDragCancel() {
    if (_committing) return;
    _rawDx = 0.0;
    _animateOffsetTo(0.0);
  }

  Future<void> _animateOffsetTo(double target) {
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _animFrom = _offset;
    _animTo = target;
    if (disableAnimations) {
      setState(() => _offset = target);
      return Future<void>.value();
    }
    _settleCtrl.duration = const Duration(milliseconds: 240);
    return _settleCtrl.forward(from: 0.0).orCancel.catchError((_) {});
  }

  void _openNowPlaying() {
    if (widget.onTap != null) {
      widget.onTap!();
      return;
    }
    unawaited(
      showNowPlayingSheet(
        context,
        controller: widget.controller,
        onOpenArtist: widget.onOpenArtist,
        onOpenAlbum: widget.onOpenAlbum,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    _syncVisuals();
    final snap = ctrl.snapshot;
    final current = snap.current;
    if (current == null) {
      return const SizedBox.shrink();
    }

    final duration = snap.durationSeconds;
    final tint = tintFromColor(ctrl.currentCoverColor ?? _dominantColor);
    final isLocal = !current.path.startsWith('http://') &&
        !current.path.startsWith('https://');
    final panels = <UiTrackInfo?>[
      snap.previousTrack,
      current,
      snap.nextTrack,
    ];

    return Semantics(
      container: true,
      label: t('Now playing'),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: _onDragStart,
        onHorizontalDragUpdate: _onDragUpdate,
        onHorizontalDragEnd: _onDragEnd,
        onHorizontalDragCancel: _onDragCancel,
        child: Container(
          margin: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          height: 56,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.50),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              fit: StackFit.expand,
              children: [
                TintedBackdrop.solid(
                  color: tint.surface,
                  duration: const Duration(milliseconds: 500),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 8, right: 4),
                  child: Row(
                    children: [
                      // 3-panel horizontal swipe track strip
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final width = constraints.maxWidth.isFinite &&
                                    constraints.maxWidth > 0
                                ? constraints.maxWidth
                                : 1.0;
                            _stripWidth = width;
                            return ClipRect(
                              child: OverflowBox(
                                alignment: Alignment.centerLeft,
                                minWidth: width * 3,
                                maxWidth: width * 3,
                                child: Transform.translate(
                                  offset: Offset(-width + _offset, 0),
                                  child: Row(
                                    children: [
                                      for (var i = 0; i < 3; i++)
                                        SizedBox(
                                          width: width,
                                          height: 56,
                                          child: panels[i] != null
                                              ? _MiniTrackPanel(
                                                  track: panels[i]!,
                                                  coverPath:
                                                      _coverOf(panels[i]!),
                                                  onTap: i == 1
                                                      ? _openNowPlaying
                                                      : null,
                                                )
                                              : const SizedBox.shrink(),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 4),
                      if (isLocal)
                        AnimatedSaveButton(
                          isSaved: ctrl.isCurrentFavorite,
                          onPressed: ctrl.toggleCurrentFavorite,
                          size: 20,
                          light: true,
                        ),
                      IconButton(
                        tooltip: t(ctrl.isPlaying ? 'Pause' : 'Play'),
                        padding: const EdgeInsets.all(10),
                        constraints: const BoxConstraints(
                          minWidth: 44,
                          minHeight: 44,
                        ),
                        icon: Icon(
                          ctrl.isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          size: 28,
                          color: AppTheme.zinc50,
                        ),
                        onPressed: ctrl.togglePause,
                      ),
                    ],
                  ),
                ),
                // Bottom 2px progress line
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 0,
                  height: 2,
                  child: ValueListenableBuilder<double>(
                    valueListenable: ctrl.positionNotifier,
                    builder: (context, pos, _) {
                      final progress = (duration != null && duration > 0)
                          ? math.min(math.max(pos / duration, 0.0), 1.0)
                          : 0.0;
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(9999),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            ColoredBox(
                              color: Colors.white.withValues(alpha: 0.20),
                            ),
                            FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: progress,
                              child: const ColoredBox(color: Colors.white),
                            ),
                          ],
                        ),
                      );
                    },
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

class _MiniTrackPanel extends StatelessWidget {
  const _MiniTrackPanel({
    required this.track,
    required this.coverPath,
    this.onTap,
  });

  final UiTrackInfo track;
  final String? coverPath;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Row(
        children: [
          CoverArt(
            path: coverPath,
            size: 40,
            borderRadius: 4,
            iconSize: 18,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.zinc50,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  track.artist.isNotEmpty
                      ? track.artist
                      : t('Unknown Artist'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
    );
  }
}
