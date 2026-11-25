import 'package:material_ui/material_ui.dart';
import 'package:neomodern/theme/app_theme.dart';

/// Horizontal push route matching `MobileSheet.svelte`:
/// - `230ms cubicOut` slide-in
/// - `200ms cubicOut` slide-out
/// - Left-edge (`<= 28px`) swipe-back gesture (`> 90px` dismiss, `200ms easeOut` snap-back)
class MobileSheetRoute<T> extends PageRoute<T> {
  MobileSheetRoute({
    required this.builder,
    super.settings,
    this.maintainState = true,
  });

  static const double edgePx = 28.0;
  static const double triggerPx = 90.0;

  final WidgetBuilder builder;

  @override
  final bool maintainState;

  @override
  bool get opaque => false;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 230);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 200);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _MobileSheetEdgeSwipeHost(
      enabled: !isFirst,
      onDismiss: () {
        if (isCurrent && navigator != null) {
          navigator!.pop();
        }
      },
      onSyncRouteProgress: (double pullX, double width) {
        if (controller != null && width > 0) {
          controller!.value = (1.0 - pullX / width).clamp(0.0, 1.0);
        }
      },
      child: builder(context),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (disableAnimations) {
      return child;
    }

    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeOutCubic,
    );

    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1.0, 0.0),
        end: Offset.zero,
      ).animate(curved),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppTheme.zinc950,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.50),
              blurRadius: 24,
              offset: const Offset(-6, 0),
            ),
          ],
        ),
        child: child,
      ),
    );
  }
}

/// Pushes [builder] inside a [MobileSheetRoute].
Future<T?> pushMobileSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  return Navigator.of(context).push<T>(
    MobileSheetRoute<T>(builder: builder),
  );
}

class _MobileSheetEdgeSwipeHost extends StatefulWidget {
  const _MobileSheetEdgeSwipeHost({
    required this.enabled,
    required this.onDismiss,
    required this.onSyncRouteProgress,
    required this.child,
  });

  final bool enabled;
  final VoidCallback onDismiss;
  final void Function(double pullX, double width) onSyncRouteProgress;
  final Widget child;

  @override
  State<_MobileSheetEdgeSwipeHost> createState() =>
      _MobileSheetEdgeSwipeHostState();
}

class _MobileSheetEdgeSwipeHostState extends State<_MobileSheetEdgeSwipeHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _snapController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );

  double _pullX = 0.0;
  double _snapStart = 0.0;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _snapController.addListener(() {
      if (!mounted) return;
      final t = Curves.easeOut.transform(_snapController.value);
      setState(() {
        _pullX = _snapStart * (1.0 - t);
      });
    });
  }

  @override
  void dispose() {
    _snapController.dispose();
    super.dispose();
  }

  void _onDragStart(DragStartDetails details) {
    if (!widget.enabled) return;
    _snapController.stop();
    setState(() {
      _dragging = true;
      _pullX = 0.0;
    });
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (!_dragging) return;
    setState(() {
      _pullX = (_pullX + details.delta.dx).clamp(0.0, double.infinity);
    });
  }

  void _onDragEnd(DragEndDetails details, double width) {
    if (!_dragging) return;
    _dragging = false;
    if (_pullX > MobileSheetRoute.triggerPx) {
      widget.onSyncRouteProgress(_pullX, width);
      _pullX = 0.0;
      widget.onDismiss();
      return;
    }
    _snapBack();
  }

  void _onDragCancel() {
    if (!_dragging) return;
    _dragging = false;
    _snapBack();
  }

  void _snapBack() {
    if (_pullX <= 0) return;
    _snapStart = _pullX;
    _snapController.forward(from: 0.0);
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return Transform.translate(
      offset: Offset(_pullX, 0),
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (widget.enabled)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: MobileSheetRoute.edgePx,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragStart: _onDragStart,
                onHorizontalDragUpdate: _onDragUpdate,
                onHorizontalDragEnd: (d) => _onDragEnd(d, width),
                onHorizontalDragCancel: _onDragCancel,
              ),
            ),
        ],
      ),
    );
  }
}
