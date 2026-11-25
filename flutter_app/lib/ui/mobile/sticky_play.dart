import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/theme/app_theme.dart';

/// Spotify-style floating circular Play/Pause button matching `StickyPlay.svelte`.
///
/// Renders a `56x56` circular `#7CAAFF` (`AppTheme.accent500`) button with a
/// `#111318` (`AppTheme.zinc950`) `28px` icon and `shadow-lg`. When [docked] is
/// true, it smoothly animates (`160ms easeOut`) to `0.79x` scale (`~44px`) and
/// shifts left by [dockShift] so it sits inside the `56px` top bar.
class StickyPlayButton extends StatefulWidget {
  const StickyPlayButton({
    super.key,
    required this.playing,
    required this.onPressed,
    this.disabled = false,
    this.docked = false,
    this.dockShift = 0.0,
    this.tooltip,
  });

  final bool playing;
  final VoidCallback? onPressed;
  final bool disabled;
  final bool docked;
  final double dockShift;
  final String? tooltip;

  @override
  State<StickyPlayButton> createState() => _StickyPlayButtonState();
}

class _StickyPlayButtonState extends State<StickyPlayButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final duration = disableAnimations
        ? Duration.zero
        : const Duration(milliseconds: 160);
    final effectiveDisabled = widget.disabled || widget.onPressed == null;
    final targetScale = widget.docked ? 0.79 : (_pressed ? 0.95 : 1.0);
    final targetShift = widget.docked ? -widget.dockShift : 0.0;
    final label = widget.tooltip ?? t(widget.playing ? 'Pause' : 'Play');

    Widget button = Semantics(
      button: true,
      enabled: !effectiveDisabled,
      label: label,
      child: Opacity(
        opacity: effectiveDisabled ? 0.5 : 1.0,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: targetShift, end: targetShift),
          duration: duration,
          curve: Curves.easeOut,
          builder: (context, shiftX, child) {
            return Transform.translate(
              offset: Offset(shiftX, 0),
              child: child,
            );
          },
          child: AnimatedScale(
            scale: targetScale,
            duration: duration,
            curve: Curves.easeOut,
            child: GestureDetector(
              onTapDown: effectiveDisabled
                  ? null
                  : (_) => setState(() => _pressed = true),
              onTapUp: effectiveDisabled
                  ? null
                  : (_) => setState(() => _pressed = false),
              onTapCancel: () => setState(() => _pressed = false),
              onTap: effectiveDisabled ? null : widget.onPressed,
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: _pressed
                      ? AppTheme.accent600
                      : AppTheme.accent500,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.40),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: Icon(
                  widget.playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  size: 28,
                  color: AppTheme.zinc950,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    if (label.isNotEmpty) {
      button = Tooltip(message: label, child: button);
    }
    return button;
  }
}
