import 'package:material_ui/material_ui.dart';
import 'package:neomodern/theme/app_theme.dart';

/// Smooth cover-tinted gradient backdrop tailored for the dark `#0D0F14` canvas.
class TintedBackdrop extends StatelessWidget {
  const TintedBackdrop({
    super.key,
    required this.child,
    this.tintColor,
    this.baseColor = AppColors.canvas,
    this.padding,
    this.borderRadius,
    this.tintAlpha = 72,
    this.duration = const Duration(milliseconds: 380),
  });

  final Widget child;
  final Color? tintColor;
  final Color baseColor;
  final EdgeInsetsGeometry? padding;
  final BorderRadius? borderRadius;
  final int tintAlpha;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final effectiveTint = tintColor != null
        ? Color.lerp(baseColor, tintColor, tintAlpha / 255.0) ?? baseColor
        : baseColor;
    final midTint = tintColor != null
        ? Color.lerp(baseColor, tintColor, (tintAlpha * 0.35) / 255.0) ??
            baseColor
        : baseColor;

    return AnimatedContainer(
      duration: duration,
      curve: Curves.easeOutCubic,
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomCenter,
          stops: const [0.0, 0.55, 1.0],
          colors: [
            effectiveTint,
            midTint,
            baseColor,
          ],
        ),
      ),
      child: child,
    );
  }
}
