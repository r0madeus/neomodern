import 'package:material_ui/material_ui.dart';
import 'package:neomodern/theme/app_theme.dart';

/// Cross-fades gradient or solid backgrounds via two ping-ponged opacity layers
/// (matching `TintedBackdrop.svelte`), avoiding jarring jumps or per-frame
/// gradient interpolation artifacts.
class TintedBackdrop extends StatefulWidget {
  const TintedBackdrop({
    super.key,
    this.child,
    this.tintColor,
    this.color,
    this.gradient,
    this.baseColor,
    this.padding,
    this.borderRadius,
    this.tintAlpha = 72,
    this.duration = const Duration(milliseconds: 650),
  });

  const TintedBackdrop.gradient({
    super.key,
    required Gradient this.gradient,
    this.child,
    this.padding,
    this.borderRadius,
    this.duration = const Duration(milliseconds: 650),
  })  : tintColor = null,
        color = null,
        baseColor = null,
        tintAlpha = 72;

  const TintedBackdrop.solid({
    super.key,
    required Color this.color,
    this.child,
    this.padding,
    this.borderRadius,
    this.duration = const Duration(milliseconds: 650),
  })  : tintColor = null,
        gradient = null,
        baseColor = null,
        tintAlpha = 72;

  final Widget? child;
  final Color? tintColor;
  final Color? color;
  final Gradient? gradient;
  final Color? baseColor;
  final EdgeInsetsGeometry? padding;
  final BorderRadius? borderRadius;
  final int tintAlpha;
  final Duration duration;

  @override
  State<TintedBackdrop> createState() => _TintedBackdropState();
}

class _TintedBackdropState extends State<TintedBackdrop> {
  BoxDecoration? _bottomDecoration;
  BoxDecoration? _topDecoration;
  bool _showTop = false;

  BoxDecoration _resolveDecoration(BuildContext context) {
    if (widget.gradient != null) {
      return BoxDecoration(gradient: widget.gradient);
    }
    if (widget.color != null) {
      return BoxDecoration(color: widget.color);
    }

    final base = widget.baseColor ??
        (Theme.of(context).brightness == Brightness.dark
            ? AppColors.canvas
            : Theme.of(context).scaffoldBackgroundColor);
    final tint = widget.tintColor;
    final effectiveTint = tint != null
        ? Color.lerp(base, tint, widget.tintAlpha / 255.0) ?? base
        : base;
    final midTint = tint != null
        ? Color.lerp(base, tint, (widget.tintAlpha * 0.35) / 255.0) ?? base
        : base;

    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomCenter,
        stops: const [0.0, 0.55, 1.0],
        colors: [
          effectiveTint,
          midTint,
          base,
        ],
      ),
    );
  }

  void _syncBackdrop(BuildContext context) {
    final next = _resolveDecoration(context);
    if (_bottomDecoration == null) {
      _bottomDecoration = next;
      _topDecoration = next;
      _showTop = false;
      return;
    }

    if (!_showTop) {
      if (next != _bottomDecoration) {
        _topDecoration = next;
        _showTop = true;
      }
    } else if (next != _topDecoration) {
      _bottomDecoration = next;
      _showTop = false;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncBackdrop(context);
  }

  @override
  void didUpdateWidget(covariant TintedBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncBackdrop(context);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = _bottomDecoration ?? _resolveDecoration(context);
    final top = _topDecoration ?? bottom;

    Widget content;
    if (widget.child != null) {
      final inner = widget.padding != null
          ? Padding(padding: widget.padding!, child: widget.child)
          : widget.child!;
      content = Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(decoration: bottom),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _showTop ? 1.0 : 0.0,
                duration: widget.duration,
                curve: Curves.ease,
                child: DecoratedBox(decoration: top),
              ),
            ),
          ),
          inner,
        ],
      );
    } else {
      content = Stack(
        fit: StackFit.expand,
        children: [
          IgnorePointer(
            child: DecoratedBox(decoration: bottom),
          ),
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: _showTop ? 1.0 : 0.0,
              duration: widget.duration,
              curve: Curves.ease,
              child: DecoratedBox(decoration: top),
            ),
          ),
        ],
      );
    }

    if (widget.borderRadius != null) {
      return ClipRRect(
        borderRadius: widget.borderRadius!,
        child: content,
      );
    }
    return content;
  }
}
