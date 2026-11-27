import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';

/// Three GPU-animated equalizer bars replacing a static play triangle,
/// matching `src/lib/Equalizer.svelte` and `@keyframes eq-bar` in `src/app.css`.
class EqualizerIndicator extends StatefulWidget {
  const EqualizerIndicator({
    super.key,
    this.color,
    this.height = 14,
    this.barWidth = 2,
    this.gap = 2,
    this.playing = true,
    this.label,
  });

  final Color? color;
  final double height;
  final double barWidth;
  final double gap;
  final bool playing;
  final String? label;

  @override
  State<EqualizerIndicator> createState() => _EqualizerIndicatorState();
}

class _EqualizerIndicatorState extends State<EqualizerIndicator>
    with SingleTickerProviderStateMixin {
  static const Duration _cycle = Duration(milliseconds: 900);
  static const List<double> _phaseOffsets = [
    0.0,
    320.0 / 900.0,
    620.0 / 900.0,
  ];

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _cycle,
  );

  @override
  void initState() {
    super.initState();
    if (widget.playing) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant EqualizerIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing != oldWidget.playing) {
      if (widget.playing) {
        _controller.repeat();
      } else {
        _controller.stop();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double _scaleForPhase(double phase) {
    final p = phase % 1.0;
    final half = p < 0.5 ? p * 2.0 : (1.0 - p) * 2.0;
    final eased = Curves.easeInOut.transform(half);
    return 0.28 + (1.0 - 0.28) * eased;
  }

  @override
  Widget build(BuildContext context) {
    final effectiveColor = widget.color ?? IconTheme.of(context).color ?? AppTheme.accent500;
    final disableAnimations = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    return Semantics(
      image: true,
      label: widget.label ?? t('Playing'),
      child: SizedBox(
        height: widget.height,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < _phaseOffsets.length; i++) ...[
                  if (i > 0) SizedBox(width: widget.gap),
                  Transform.scale(
                    scaleY: disableAnimations || !widget.playing
                        ? (i == 1 ? 0.85 : 0.48)
                        : _scaleForPhase(_controller.value + _phaseOffsets[i]),
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      width: widget.barWidth,
                      height: widget.height,
                      decoration: BoxDecoration(
                        color: effectiveColor,
                        borderRadius: BorderRadius.circular(9999),
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Spotify/Svelte-style pill seek bar matching `input.seek` in `src/app.css`.
///
/// Desktop mode shows a `4px` rounded track whose `12px` white thumb fades in
/// and scales (`0.6 -> 1.0`) over `120ms` only on hover/drag. Touch mode
/// (`alwaysShowThumb: true`) renders an always-visible `16px` thumb.
class HoverSeekBar extends StatefulWidget {
  const HoverSeekBar({
    super.key,
    required this.value,
    this.min = 0.0,
    this.max = 1.0,
    this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.light = false,
    this.alwaysShowThumb = false,
    this.trackHeight = 4.0,
    this.hitHeight = 24.0,
  });

  final double value;
  final double min;
  final double max;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;
  final bool light;
  final bool alwaysShowThumb;
  final double trackHeight;
  final double hitHeight;

  @override
  State<HoverSeekBar> createState() => _HoverSeekBarState();
}

class _HoverSeekBarState extends State<HoverSeekBar> {
  bool _hovered = false;
  bool _dragging = false;
  bool _focused = false;
  double? _dragValue;

  bool get _enabled => widget.onChanged != null;

  double get _fraction {
    final span = widget.max - widget.min;
    if (span <= 0) return 0.0;
    final current = _dragging && _dragValue != null ? _dragValue! : widget.value;
    return ((current - widget.min) / span).clamp(0.0, 1.0);
  }

  double _valueFromLocalDx(double dx, double width) {
    if (width <= 0) return widget.min;
    final frac = (dx / width).clamp(0.0, 1.0);
    return widget.min + frac * (widget.max - widget.min);
  }

  void _handleTapDown(TapDownDetails details, double width) {
    if (!_enabled) return;
    final next = _valueFromLocalDx(details.localPosition.dx, width);
    widget.onChangeStart?.call(next);
    widget.onChanged?.call(next);
    widget.onChangeEnd?.call(next);
  }

  void _handleDragStart(DragStartDetails details, double width) {
    if (!_enabled) return;
    final next = _valueFromLocalDx(details.localPosition.dx, width);
    setState(() {
      _dragging = true;
      _dragValue = next;
    });
    widget.onChangeStart?.call(next);
    widget.onChanged?.call(next);
  }

  void _handleDragUpdate(DragUpdateDetails details, double width) {
    if (!_enabled || !_dragging) return;
    final next = _valueFromLocalDx(details.localPosition.dx, width);
    setState(() => _dragValue = next);
    widget.onChanged?.call(next);
  }

  void _handleDragEnd() {
    if (!_dragging) return;
    final finalValue = _dragValue ?? widget.value;
    setState(() {
      _dragging = false;
      _dragValue = null;
    });
    widget.onChangeEnd?.call(finalValue);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final showThumb =
        _enabled && (widget.alwaysShowThumb || _hovered || _dragging || _focused);
    final thumbDiameter = widget.alwaysShowThumb ? 16.0 : 12.0;

    final Color fillColor;
    final Color trackColor;
    if (widget.light) {
      fillColor = AppTheme.editorialPaper;
      trackColor = AppTheme.editorialPaper.withValues(alpha: 0.24);
    } else if (isDark) {
      fillColor = (_hovered || _dragging) && _enabled
          ? Colors.white
          : AppTheme.editorialPaper;
      trackColor = AppTheme.zinc700;
    } else {
      fillColor = (_hovered || _dragging) && _enabled
          ? AppTheme.editorialInk
          : AppTheme.zinc700;
      trackColor = AppTheme.zinc300;
    }

    return FocusableActionDetector(
      enabled: _enabled,
      onShowFocusHighlight: (focused) => setState(() => _focused = focused),
      child: MouseRegion(
        cursor: _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Opacity(
          opacity: _enabled ? 1.0 : 0.5,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth.isFinite
                  ? constraints.maxWidth
                  : 120.0;
              final frac = _fraction;
              final maxLeft = math.max<double>(0.0, width - thumbDiameter);
              final thumbLeft =
                  (frac * width - thumbDiameter / 2).clamp(0.0, maxLeft).toDouble();

              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: _enabled ? (d) => _handleTapDown(d, width) : null,
                onHorizontalDragStart:
                    _enabled ? (d) => _handleDragStart(d, width) : null,
                onHorizontalDragUpdate:
                    _enabled ? (d) => _handleDragUpdate(d, width) : null,
                onHorizontalDragEnd: _enabled ? (_) => _handleDragEnd() : null,
                onHorizontalDragCancel: _enabled ? _handleDragEnd : null,
                child: SizedBox(
                  height: widget.hitHeight,
                  width: double.infinity,
                  child: Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.centerLeft,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(9999),
                        child: SizedBox(
                          height: widget.trackHeight,
                          width: width,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ColoredBox(color: trackColor),
                              FractionallySizedBox(
                                alignment: Alignment.centerLeft,
                                widthFactor: frac,
                                child: ColoredBox(color: fillColor),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        left: thumbLeft,
                        child: AnimatedOpacity(
                          opacity: showThumb ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 120),
                          curve: Curves.ease,
                          child: AnimatedScale(
                            scale: showThumb ? 1.0 : 0.6,
                            duration: const Duration(milliseconds: 120),
                            curve: Curves.ease,
                            child: Container(
                              width: thumbDiameter,
                              height: thumbDiameter,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.20),
                                    spreadRadius: 1,
                                  ),
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.30),
                                    blurRadius: 2,
                                    offset: const Offset(0, 1),
                                  ),
                                ],
                              ),
                            ),
                          ),
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

/// Spotify-style save button matching `src/lib/FavoriteButton.svelte` and
/// `@keyframes star-pop` (`280ms cubic-bezier(0.22, 1, 0.36, 1)`).
class AnimatedSaveButton extends StatefulWidget {
  const AnimatedSaveButton({
    super.key,
    required this.isSaved,
    required this.onPressed,
    this.size = 18,
    this.light = false,
    this.revealOnHover = false,
    this.isRowHovered = false,
    this.tooltip,
  });

  final bool isSaved;
  final VoidCallback? onPressed;
  final double size;
  final bool light;
  final bool revealOnHover;
  final bool isRowHovered;
  final String? tooltip;

  @override
  State<AnimatedSaveButton> createState() => _AnimatedSaveButtonState();
}

class _AnimatedSaveButtonState extends State<AnimatedSaveButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _popController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );

  late final Animation<double> _popScale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween<double>(begin: 1.0, end: 1.32),
      weight: 45,
    ),
    TweenSequenceItem(
      tween: Tween<double>(begin: 1.32, end: 1.0),
      weight: 55,
    ),
  ]).animate(
    CurvedAnimation(
      parent: _popController,
      curve: const Cubic(0.22, 1, 0.36, 1),
    ),
  );

  bool _hovered = false;
  bool _pressed = false;

  @override
  void didUpdateWidget(covariant AnimatedSaveButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isSaved && widget.isSaved) {
      _popController.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _popController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final savedColor = widget.light
        ? AppTheme.accent300
        : (isDark ? AppTheme.accent400 : AppTheme.accent500);
    final unsavedColor = widget.light
        ? (_hovered ? Colors.white : Colors.white.withValues(alpha: 0.6))
        : (_hovered
            ? (isDark ? AppTheme.zinc100 : AppTheme.zinc700)
            : AppTheme.zinc400);
    final hoverBg = widget.light
        ? Colors.white.withValues(alpha: 0.10)
        : (isDark
            ? AppTheme.zinc800
            : AppTheme.zinc200.withValues(alpha: 0.70));

    final visible = widget.isSaved ||
        !widget.revealOnHover ||
        widget.isRowHovered ||
        _hovered;
    final tip = widget.tooltip ??
        (widget.isSaved ? t('Remove from Favorites') : t('Add to Favorites'));

    Widget button = MouseRegion(
      cursor: widget.onPressed != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.onPressed != null
            ? (_) => setState(() => _pressed = true)
            : null,
        onTapUp: widget.onPressed != null
            ? (_) => setState(() => _pressed = false)
            : null,
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onPressed,
        child: AnimatedOpacity(
          opacity: visible ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 140),
          child: AnimatedScale(
            scale: _pressed ? 0.90 : 1.0,
            duration: const Duration(milliseconds: 100),
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: _hovered ? hoverBg : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: AnimatedBuilder(
                animation: _popScale,
                builder: (context, child) {
                  return Transform.scale(
                    scale: _popScale.value,
                    child: child,
                  );
                },
                child: Icon(
                  widget.isSaved
                      ? Icons.check_circle_rounded
                      : Icons.add_circle_outline_rounded,
                  size: widget.size,
                  color: widget.isSaved ? savedColor : unsavedColor,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    if (tip.isNotEmpty) {
      button = Tooltip(message: tip, child: button);
    }

    return Semantics(
      button: true,
      toggled: widget.isSaved,
      label: tip,
      child: button,
    );
  }
}

/// Spotify-style circular Play/Pause button (`#7CAAFF` bg, `#111318` icon,
/// `shadow-lg`) with `150ms` hover scale (`1.06`), `0.95` tap-down, and
/// optional card-hover reveal (`opacity 0->1` + `translateY 6px->0` over `180ms`).
class HoverPlayButton extends StatefulWidget {
  const HoverPlayButton({
    super.key,
    required this.onPressed,
    this.isPlaying = false,
    this.size = 40,
    this.iconSize,
    this.reveal = false,
    this.isParentHovered = false,
    this.tooltip,
  });

  final VoidCallback? onPressed;
  final bool isPlaying;
  final double size;
  final double? iconSize;
  final bool reveal;
  final bool isParentHovered;
  final String? tooltip;

  @override
  State<HoverPlayButton> createState() => _HoverPlayButtonState();
}

class _HoverPlayButtonState extends State<HoverPlayButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final visible = !widget.reveal || widget.isParentHovered || _hovered;
    final scale = _pressed ? 0.95 : (_hovered ? 1.06 : 1.0);
    final effectiveIconSize = widget.iconSize ?? (widget.size * 0.56);

    Widget button = IgnorePointer(
      ignoring: !visible || widget.onPressed == null,
      child: AnimatedOpacity(
        opacity: visible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        child: AnimatedSlide(
          offset: visible ? Offset.zero : const Offset(0, 0.15),
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          child: MouseRegion(
            cursor: widget.onPressed != null
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() {
              _hovered = false;
              _pressed = false;
            }),
            child: GestureDetector(
              onTapDown: widget.onPressed != null
                  ? (_) => setState(() => _pressed = true)
                  : null,
              onTapUp: widget.onPressed != null
                  ? (_) => setState(() => _pressed = false)
                  : null,
              onTapCancel: () => setState(() => _pressed = false),
              onTap: widget.onPressed,
              child: AnimatedScale(
                scale: scale,
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOut,
                child: Container(
                  width: widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(
                    color: AppTheme.editorialPaper,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.black.withValues(alpha: 0.12),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.28),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    widget.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    size: effectiveIconSize,
                    color: AppTheme.editorialInk,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final tip = widget.tooltip;
    if (tip != null && tip.isNotEmpty) {
      button = Tooltip(message: tip, child: button);
    }

    return Semantics(
      button: true,
      label: tip ?? (widget.isPlaying ? t('Pause') : t('Play')),
      child: button,
    );
  }
}

/// `140ms easeOut` opacity fade-in wrapper matching `.animate-view-enter`
/// in `src/app.css`.
class ViewFadeIn extends StatefulWidget {
  const ViewFadeIn({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 140),
  });

  final Widget child;
  final Duration duration;

  @override
  State<ViewFadeIn> createState() => _ViewFadeInState();
}

class _ViewFadeInState extends State<ViewFadeIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  late final Animation<double> _opacity = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
  );

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      return widget.child;
    }
    return FadeTransition(
      opacity: _opacity,
      child: widget.child,
    );
  }
}

/// Exact artwork renderer matching `src/lib/MixCover.svelte` for dynamic mixes:
/// `weekly-favorites`, `on-repeat`, `rediscover`, `focus-mix` (artist & genre),
/// falling back to a 2x2 [CollageCover].
class MixCoverArt extends StatelessWidget {
  const MixCoverArt({
    super.key,
    required this.mix,
    this.kind,
    this.subject,
    this.subjectKind,
    this.artistPortraitPath,
    this.size,
    this.borderRadius = 8,
  });

  final UiDynamicMix mix;
  final String? kind;
  final String? subject;
  final String? subjectKind;
  final String? artistPortraitPath;
  final double? size;
  final double borderRadius;

  String get _resolvedKind {
    if (kind != null && kind!.isNotEmpty) return kind!;
    if (mix.id == 'weekly-favorites' ||
        mix.id == 'on-repeat' ||
        mix.id == 'rediscover' ||
        mix.id == 'focus-mix') {
      return mix.id;
    }
    if (mix.id.startsWith('focus')) return 'focus-mix';
    return 'collage';
  }

  String get _resolvedSubject {
    if (subject != null && subject!.isNotEmpty) return subject!;
    if (mix.title.endsWith(' Mix') && mix.title.length > 4) {
      return mix.title.substring(0, mix.title.length - 4);
    }
    return mix.title;
  }

  @override
  Widget build(BuildContext context) {
    Widget artwork = LayoutBuilder(
      builder: (context, constraints) {
        final w = size ??
            (constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : (constraints.maxHeight.isFinite ? constraints.maxHeight : 160.0));
        return SizedBox(
          width: w,
          height: w,
          child: _buildForWidth(w),
        );
      },
    );

    if (size != null) {
      artwork = SizedBox(width: size, height: size, child: artwork);
    } else {
      artwork = AspectRatio(aspectRatio: 1, child: artwork);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: artwork,
    );
  }

  Widget _buildForWidth(double w) {
    final covers = mix.coverPaths;
    final first = covers.isNotEmpty ? covers[0] : null;
    final second = covers.length > 1 ? covers[1] : first;
    final third = covers.length > 2 ? covers[2] : second;
    final resolvedKind = _resolvedKind;

    if (resolvedKind == 'weekly-favorites') {
      return _buildWeeklyFavorites(w, first);
    }
    if (resolvedKind == 'on-repeat') {
      return _buildOnRepeat(w, first);
    }
    if (resolvedKind == 'rediscover') {
      return _buildRediscover(w, first);
    }
    if (resolvedKind == 'focus-mix') {
      final tint = genreColor(_resolvedSubject);
      if (subjectKind == 'artist') {
        return _buildArtistFocusMix(w, tint, artistPortraitPath ?? first);
      }
      return _buildGenreFocusMix(w, tint, [third, second, first]);
    }

    return CollageCover(
      coverPaths: covers,
      size: w,
      borderRadius: 0,
    );
  }

  Widget _buildWeeklyFavorites(double w, String? first) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(-0.75, -1.0),
              end: Alignment(0.75, 1.0),
              stops: [0.0, 0.55, 1.0],
              colors: [
                Color(0xFF19C3A1),
                Color(0xFF0B6E63),
                Color(0xFF06302E),
              ],
            ),
          ),
        ),
        Positioned(
          top: -0.10 * w,
          left: -0.03 * w,
          child: Text(
            '7',
            style: TextStyle(
              fontSize: 0.78 * w,
              fontWeight: FontWeight.w900,
              height: 1.0,
              color: Colors.white.withValues(alpha: 0.15),
            ),
          ),
        ),
        if (first != null)
          Positioned(
            top: 0.12 * w,
            right: 0.09 * w,
            child: Transform.rotate(
              angle: 7 * math.pi / 180,
              child: Container(
                width: 0.52 * w,
                height: 0.52 * w,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(0.03 * w),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.50),
                      blurRadius: 0.10 * w,
                      offset: Offset(0, 0.04 * w),
                    ),
                  ],
                ),
                child: CoverArt(
                  path: first,
                  size: 0.52 * w,
                  borderRadius: 0.03 * w,
                  iconSize: 0.18 * w,
                ),
              ),
            ),
          ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            padding: EdgeInsets.fromLTRB(
              0.07 * w,
              0.14 * w,
              0.07 * w,
              0.06 * w,
            ),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.60),
                  Colors.transparent,
                ],
              ),
            ),
            child: Text(
              mix.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 0.11 * w,
                fontWeight: FontWeight.w800,
                height: 1.05,
                letterSpacing: -0.025 * (0.11 * w),
                color: Colors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOnRepeat(double w, String? first) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(-0.5, -1.0),
              end: Alignment(0.5, 1.0),
              stops: [0.0, 0.55, 1.0],
              colors: [
                Color(0xFF6D5BF0),
                Color(0xFF3A2AA8),
                Color(0xFF150F4A),
              ],
            ),
          ),
        ),
        CustomPaint(
          painter: _ConcentricRingsPainter(),
        ),
        if (first != null)
          Positioned(
            top: 0.19 * w,
            left: (w - 0.50 * w) / 2,
            child: Container(
              width: 0.50 * w,
              height: 0.50 * w,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.80),
                  width: 0.016 * w,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.50),
                    blurRadius: 0.10 * w,
                    offset: Offset(0, 0.04 * w),
                  ),
                ],
              ),
              child: ClipOval(
                child: CoverArt(
                  path: first,
                  size: 0.50 * w,
                  borderRadius: 0,
                  iconSize: 0.18 * w,
                ),
              ),
            ),
          ),
        Positioned(
          top: 0.07 * w,
          right: 0.07 * w,
          child: Container(
            width: 0.11 * w,
            height: 0.11 * w,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.20),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.repeat_rounded,
              size: 0.065 * w,
              color: Colors.white,
            ),
          ),
        ),
        Positioned(
          left: 0.07 * w,
          right: 0.07 * w,
          bottom: 0.06 * w,
          child: Text(
            mix.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 0.11 * w,
              fontWeight: FontWeight.w800,
              height: 1.05,
              letterSpacing: -0.025 * (0.11 * w),
              color: Colors.white,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRediscover(double w, String? first) {
    final polaroidInner = 0.44 * w;
    final padSide = 0.026 * w;
    final padBottom = 0.07 * w;
    final frameWidth = polaroidInner + padSide * 2;

    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(-0.85, -1.0),
              end: Alignment(0.85, 1.0),
              stops: [0.0, 0.60, 1.0],
              colors: [
                Color(0xFFFFB347),
                Color(0xFFE0701F),
                Color(0xFF8F3A12),
              ],
            ),
          ),
        ),
        Positioned(
          top: 0.08 * w,
          left: 0.09 * w,
          child: Text(
            '✦',
            style: TextStyle(
              fontSize: 0.12 * w,
              height: 1.0,
              color: Colors.white.withValues(alpha: 0.80),
            ),
          ),
        ),
        Positioned(
          top: 0.30 * w,
          right: 0.08 * w,
          child: Text(
            '✦',
            style: TextStyle(
              fontSize: 0.08 * w,
              height: 1.0,
              color: Colors.white.withValues(alpha: 0.60),
            ),
          ),
        ),
        Positioned(
          top: 0.52 * w,
          left: 0.06 * w,
          child: Text(
            '✦',
            style: TextStyle(
              fontSize: 0.06 * w,
              height: 1.0,
              color: Colors.white.withValues(alpha: 0.50),
            ),
          ),
        ),
        if (first != null)
          Positioned(
            top: 0.10 * w,
            left: (w - frameWidth) / 2,
            child: Transform.rotate(
              angle: -6 * math.pi / 180,
              child: Container(
                padding: EdgeInsets.fromLTRB(
                  padSide,
                  padSide,
                  padSide,
                  padBottom,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFFAF0),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.40),
                      blurRadius: 0.08 * w,
                      offset: Offset(0, 0.04 * w),
                    ),
                  ],
                ),
                child: CoverArt(
                  path: first,
                  size: polaroidInner,
                  borderRadius: 0,
                  iconSize: 0.16 * w,
                ),
              ),
            ),
          ),
        Positioned(
          left: 0.07 * w,
          right: 0.07 * w,
          bottom: 0.06 * w,
          child: Text(
            mix.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 0.11 * w,
              fontWeight: FontWeight.w800,
              height: 1.05,
              letterSpacing: -0.025 * (0.11 * w),
              color: const Color(0xFF2B1304),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildArtistFocusMix(double w, Color tint, String? photo) {
    final portraitSize = 0.56 * w;
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Color(0xFFF4F1EA)),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 0.38 * w,
          child: ColoredBox(color: tint),
        ),
        Positioned(
          top: 0.06 * w,
          left: 0.07 * w,
          child: Text(
            'MIX',
            style: TextStyle(
              fontSize: 0.05 * w,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.18 * (0.05 * w),
              color: Colors.black.withValues(alpha: 0.70),
            ),
          ),
        ),
        Positioned(
          top: 0.11 * w,
          left: (w - portraitSize) / 2,
          child: Container(
            width: portraitSize,
            height: portraitSize,
            decoration: BoxDecoration(
              color: tint,
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white,
                width: 0.014 * w,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.30),
                  blurRadius: 0.07 * w,
                  offset: Offset(0, 0.03 * w),
                ),
              ],
            ),
            child: ClipOval(
              child: photo != null
                  ? CoverArt(
                      path: photo,
                      size: portraitSize,
                      borderRadius: 0,
                      iconSize: 0.24 * w,
                    )
                  : Center(
                      child: Icon(
                        Icons.music_note_rounded,
                        size: 0.24 * w,
                        color: Colors.white,
                      ),
                    ),
            ),
          ),
        ),
        Positioned(
          left: 0.07 * w,
          right: 0.07 * w,
          bottom: 0.05 * w,
          child: Text(
            mix.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 0.11 * w,
              fontWeight: FontWeight.w800,
              height: 1.05,
              letterSpacing: -0.025 * (0.11 * w),
              color: Colors.white,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGenreFocusMix(double w, Color tint, List<String?> layers) {
    const anglesDeg = [-8.0, 4.0, 16.0];
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: tint),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white.withValues(alpha: 0.10),
                Colors.black.withValues(alpha: 0.25),
              ],
            ),
          ),
        ),
        for (var i = 0; i < layers.length; i++)
          if (layers[i] != null)
            Positioned(
              top: (0.08 + i * 0.06) * w,
              right: (-0.04 + (2 - i) * 0.14) * w,
              child: Transform.rotate(
                angle: anglesDeg[i] * math.pi / 180,
                child: Container(
                  width: 0.40 * w,
                  height: 0.40 * w,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(0.025 * w),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.45),
                        blurRadius: 0.08 * w,
                        offset: Offset(0, 0.03 * w),
                      ),
                    ],
                  ),
                  child: CoverArt(
                    path: layers[i],
                    size: 0.40 * w,
                    borderRadius: 0.025 * w,
                    iconSize: 0.14 * w,
                  ),
                ),
              ),
            ),
        Positioned(
          left: 0.07 * w,
          right: 0.07 * w,
          bottom: 0.06 * w,
          child: Text(
            mix.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 0.12 * w,
              fontWeight: FontWeight.w800,
              height: 1.05,
              letterSpacing: -0.025 * (0.12 * w),
              color: Colors.white,
              shadows: [
                Shadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 2,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ConcentricRingsPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.50, size.height * 0.44);
    final unit = size.width / 100.0;

    void drawRing(double radius, double opacity, double strokeWidth) {
      final paint = Paint()
        ..color = Colors.white.withValues(alpha: opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth * unit;
      canvas.drawCircle(center, radius * unit, paint);
    }

    drawRing(42, 0.08, 6);
    drawRing(33, 0.13, 4);
    drawRing(26, 0.20, 2);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
