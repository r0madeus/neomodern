import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/tinted_backdrop.dart';
import 'package:neomodern/ui/widgets/motion_primitives.dart';

/// Spotify-style collection header matching `src/lib/CollectionHeader.svelte`.
///
/// Renders a full-width [TintedBackdrop.gradient] band with an optional
/// top-left circular back button, a 208x208 cover with optional hover
/// "Change cover" overlay, a large bold tight-tracked title, metadata line,
/// and an action strip featuring a 56x56 [HoverPlayButton], shuffle button
/// with an active indicator dot, optional pin button, and extra actions.
class CollectionHeader extends StatefulWidget {
  const CollectionHeader({
    super.key,
    required this.tint,
    required this.label,
    required this.titleText,
    required this.cover,
    required this.meta,
    required this.onPlay,
    this.titleWidget,
    this.isPlaying = false,
    this.playEnabled = true,
    this.onShuffle,
    this.shuffleActive = false,
    this.isPinned,
    this.onTogglePin,
    this.onMorePressed,
    this.moreTooltip,
    this.extraActions = const [],
    this.onBack,
    this.backLabel,
    this.onCoverTap,
    this.coverSize = 208,
  });

  final CoverTint tint;
  final String label;
  final String titleText;
  final Widget cover;
  final Widget? titleWidget;
  final Widget meta;
  final VoidCallback? onPlay;
  final bool isPlaying;
  final bool playEnabled;
  final VoidCallback? onShuffle;
  final bool shuffleActive;
  final bool? isPinned;
  final VoidCallback? onTogglePin;
  final VoidCallback? onMorePressed;
  final String? moreTooltip;
  final List<Widget> extraActions;
  final VoidCallback? onBack;
  final String? backLabel;
  final VoidCallback? onCoverTap;
  final double coverSize;

  @override
  State<CollectionHeader> createState() => _CollectionHeaderState();
}

class _CollectionHeaderState extends State<CollectionHeader> {
  bool _coverHovered = false;
  bool _backHovered = false;
  bool _shuffleHovered = false;
  bool _pinHovered = false;
  bool _moreHovered = false;

  double get _titleFontSize {
    final len = widget.titleText.length;
    if (len <= 18) return 60;
    if (len <= 32) return 52;
    return 44;
  }

  @override
  Widget build(BuildContext context) {
    final gradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      stops: const [0.0, 0.72, 0.90, 1.0],
      colors: [
        widget.tint.top,
        widget.tint.surface,
        widget.tint.surface.withValues(alpha: 0.40),
        Colors.transparent,
      ],
    );

    Widget coverWidget = Container(
      width: widget.coverSize,
      height: widget.coverSize,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.50),
            blurRadius: 32,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.cover,
            if (widget.onCoverTap != null)
              IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _coverHovered ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 150),
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.55),
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.upload_rounded,
                          size: 24,
                          color: Colors.white,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          t('Change Cover'),
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    if (widget.onCoverTap != null) {
      coverWidget = MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _coverHovered = true),
        onExit: (_) => setState(() => _coverHovered = false),
        child: GestureDetector(
          onTap: widget.onCoverTap,
          child: Tooltip(
            message: t('Change Cover'),
            child: coverWidget,
          ),
        ),
      );
    }

    return TintedBackdrop.gradient(
      gradient: gradient,
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  24,
                  widget.onBack != null ? 56 : 32,
                  24,
                  24,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    coverWidget,
                    const SizedBox(width: 24),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              widget.label,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: Colors.white.withValues(alpha: 0.90),
                              ),
                            ),
                            const SizedBox(height: 4),
                            if (widget.titleWidget != null)
                              widget.titleWidget!
                            else
                              Text(
                                widget.titleText,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: _titleFontSize,
                                  fontWeight: FontWeight.w900,
                                  height: 1.05,
                                  letterSpacing: -1.2,
                                  color: Colors.white,
                                ),
                              ),
                            const SizedBox(height: 10),
                            DefaultTextStyle(
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.white.withValues(alpha: 0.75),
                              ),
                              child: widget.meta,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
                child: Row(
                  children: [
                    HoverPlayButton(
                      size: 56,
                      iconSize: 28,
                      isPlaying: widget.isPlaying,
                      onPressed: widget.playEnabled ? widget.onPlay : null,
                    ),
                    if (widget.onShuffle != null) ...[
                      const SizedBox(width: 16),
                      _HeaderShuffleButton(
                        active: widget.shuffleActive,
                        enabled: widget.playEnabled,
                        hovered: _shuffleHovered,
                        onHoverChanged: (v) =>
                            setState(() => _shuffleHovered = v),
                        onPressed: widget.onShuffle!,
                      ),
                    ],
                    if (widget.isPinned != null &&
                        widget.onTogglePin != null) ...[
                      const SizedBox(width: 16),
                      Tooltip(
                        message: widget.isPinned! ? t('Unpin') : t('Pin'),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          onEnter: (_) => setState(() => _pinHovered = true),
                          onExit: (_) => setState(() => _pinHovered = false),
                          child: GestureDetector(
                            onTap: widget.onTogglePin,
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: _pinHovered
                                    ? Colors.white.withValues(alpha: 0.12)
                                    : Colors.transparent,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                widget.isPinned!
                                    ? Icons.push_pin_rounded
                                    : Icons.push_pin_outlined,
                                size: 24,
                                color: widget.isPinned!
                                    ? AppTheme.accent400
                                    : (_pinHovered
                                        ? Colors.white
                                        : Colors.white.withValues(alpha: 0.70)),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                    if (widget.onMorePressed != null) ...[
                      const SizedBox(width: 16),
                      Tooltip(
                        message: widget.moreTooltip ?? t('More options'),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          onEnter: (_) => setState(() => _moreHovered = true),
                          onExit: (_) => setState(() => _moreHovered = false),
                          child: GestureDetector(
                            onTap: widget.onMorePressed,
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: _moreHovered
                                    ? Colors.white.withValues(alpha: 0.12)
                                    : Colors.transparent,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.more_horiz_rounded,
                                size: 28,
                                color: _moreHovered
                                    ? Colors.white
                                    : Colors.white.withValues(alpha: 0.70),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                    for (final extra in widget.extraActions) ...[
                      const SizedBox(width: 12),
                      extra,
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (widget.onBack != null)
            Positioned(
              top: 16,
              left: 16,
              child: Tooltip(
                message: widget.backLabel ?? t('Back'),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  onEnter: (_) => setState(() => _backHovered = true),
                  onExit: (_) => setState(() => _backHovered = false),
                  child: GestureDetector(
                    onTap: widget.onBack,
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: _backHovered
                            ? Colors.black.withValues(alpha: 0.50)
                            : Colors.black.withValues(alpha: 0.30),
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.arrow_back_rounded,
                        size: 20,
                        color: _backHovered
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.90),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _HeaderShuffleButton extends StatelessWidget {
  const _HeaderShuffleButton({
    required this.active,
    required this.enabled,
    required this.hovered,
    required this.onHoverChanged,
    required this.onPressed,
  });

  final bool active;
  final bool enabled;
  final bool hovered;
  final ValueChanged<bool> onHoverChanged;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: t('Shuffle'),
      child: Opacity(
        opacity: enabled ? 1.0 : 0.4,
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onEnter: (_) => onHoverChanged(true),
          onExit: (_) => onHoverChanged(false),
          child: GestureDetector(
            onTap: enabled ? onPressed : null,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: hovered && enabled
                    ? Colors.white.withValues(alpha: 0.15)
                    : Colors.transparent,
                shape: BoxShape.circle,
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(
                    Icons.shuffle_rounded,
                    size: 22,
                    color: active
                        ? AppTheme.accent400
                        : (hovered
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.80)),
                  ),
                  if (active)
                    Positioned(
                      bottom: 3,
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
              ),
            ),
          ),
        ),
      ),
    );
  }
}
