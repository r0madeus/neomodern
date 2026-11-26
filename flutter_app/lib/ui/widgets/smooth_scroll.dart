import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

/// Application-wide scroll behavior enabling desktop drag & crisp scrollbars.
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
      };
}

/// A [ScrollController] whose [ScrollPosition] intercepts discrete desktop
/// mouse-wheel [PointerScrollEvent]s and smoothly animates (`150ms`,
/// [Curves.easeOutCubic]) toward an accumulated target offset clamped to
/// `[minScrollExtent, maxScrollExtent]`.
///
/// Trackpad and touch scrolling bypasses wheel smoothing and cancels any
/// in-flight wheel animation cleanly.
class SmoothScrollController extends ScrollController {
  SmoothScrollController({
    super.initialScrollOffset,
    super.keepScrollOffset,
    super.debugLabel,
    this.duration = const Duration(milliseconds: 150),
    this.curve = Curves.easeOutCubic,
  });

  final Duration duration;
  final Curve curve;

  PointerDeviceKind? _lastPointerSignalKind;

  /// Records the device kind of the most recent [PointerScrollEvent] so
  /// [_SmoothScrollPosition.pointerScroll] can distinguish mouse wheels from
  /// trackpad/touch pointer signals.
  void notifyPointerSignal(PointerScrollEvent event) {
    _lastPointerSignalKind = event.kind;
  }

  PointerDeviceKind? consumePointerSignalKind() {
    final kind = _lastPointerSignalKind;
    _lastPointerSignalKind = null;
    return kind;
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _SmoothScrollPosition(
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      debugLabel: debugLabel,
      controller: this,
    );
  }
}

class _SmoothScrollPosition extends ScrollPositionWithSingleContext {
  _SmoothScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.debugLabel,
    required this._controller,
  });

  final SmoothScrollController _controller;
  double _smoothTarget = 0.0;
  bool _isSmoothAnimating = false;
  bool _startingSmoothActivity = false;
  int _smoothGeneration = 0;

  @override
  void pointerScroll(double delta) {
    final kind = _controller.consumePointerSignalKind();
    if (delta == 0.0) {
      goBallistic(0.0);
      return;
    }

    // Preserve native instant handling for trackpad/touch pointer signals.
    if (kind != null && kind != PointerDeviceKind.mouse) {
      super.pointerScroll(delta);
      return;
    }

    final base = _isSmoothAnimating ? _smoothTarget : pixels;
    final target =
        (base + delta).clamp(minScrollExtent, maxScrollExtent).toDouble();
    if (target == pixels && !_isSmoothAnimating) {
      return;
    }

    _smoothTarget = target;
    _isSmoothAnimating = true;
    final gen = ++_smoothGeneration;

    _startingSmoothActivity = true;
    final future = animateTo(
      target,
      duration: _controller.duration,
      curve: _controller.curve,
    );
    _startingSmoothActivity = false;

    unawaited(
      future.whenComplete(() {
        if (_smoothGeneration == gen) {
          _isSmoothAnimating = false;
        }
      }),
    );
  }

  @override
  void beginActivity(ScrollActivity? newActivity) {
    if (!_startingSmoothActivity) {
      _isSmoothAnimating = false;
      _smoothGeneration++;
      _smoothTarget = hasPixels ? pixels : 0.0;
    }
    super.beginActivity(newActivity);
  }
}

/// Wraps a desktop scrollable view with [SmoothScrollController] wheel
/// smoothing and mouse/trackpad signal discrimination.
class SmoothScrollWrapper extends StatefulWidget {
  const SmoothScrollWrapper({
    super.key,
    this.controller,
    this.duration = const Duration(milliseconds: 150),
    this.curve = Curves.easeOutCubic,
    this.builder,
    this.child,
  }) : assert(builder != null || child != null);

  final SmoothScrollController? controller;
  final Duration duration;
  final Curve curve;
  final Widget Function(BuildContext context, ScrollController controller)?
      builder;
  final Widget? child;

  @override
  State<SmoothScrollWrapper> createState() => _SmoothScrollWrapperState();
}

class _SmoothScrollWrapperState extends State<SmoothScrollWrapper> {
  SmoothScrollController? _ownedController;

  SmoothScrollController get _effectiveController =>
      widget.controller ?? _ownedController!;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) {
      _ownedController = SmoothScrollController(
        duration: widget.duration,
        curve: widget.curve,
      );
    }
  }

  @override
  void didUpdateWidget(covariant SmoothScrollWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != null && _ownedController != null) {
      _ownedController!.dispose();
      _ownedController = null;
    } else if (widget.controller == null && _ownedController == null) {
      _ownedController = SmoothScrollController(
        duration: widget.duration,
        curve: widget.curve,
      );
    }
  }

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _effectiveController;
    final content = widget.builder != null
        ? widget.builder!(context, ctrl)
        : widget.child!;

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          ctrl.notifyPointerSignal(event);
        }
      },
      child: content,
    );
  }
}
