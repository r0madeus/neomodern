import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/tinted_backdrop.dart';

/// Editorial Catalog collection header (K30).
///
/// Renders a restrained cover-tinted wash band, a framed 2px-radius sleeve
/// cover, an uppercase monospace kicker, a Lora serif display title, metadata
/// line, and an editorial Play pill CTA alongside hairline secondary controls.
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
    if (len <= 18) return 54;
    if (len <= 32) return 46;
    return 38;
  }

  @override
  Widget build(BuildContext context) {
    final gradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      stops: const [0.0, 0.72, 0.92, 1.0],
      colors: [
        widget.tint.top.withValues(alpha: 0.75),
        widget.tint.surface.withValues(alpha: 0.45),
        widget.tint.surface.withValues(alpha: 0.14),
        Colors.transparent,
      ],
    );

    Widget coverWidget = Container(
      width: widget.coverSize,
      height: widget.coverSize,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppTheme.zinc900,
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: AppTheme.hairlineStrong),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(1),
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
                    color: Colors.black.withValues(alpha: 0.58),
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.upload_rounded,
                          size: 24,
                          color: AppTheme.editorialPaper,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          t('Change Cover'),
                          style: AppTheme.monoStyle(
                            fontSize: 11,
                            color: AppTheme.editorialPaper,
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

    return Container(
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppTheme.hairlineStrong),
        ),
      ),
      child: TintedBackdrop.gradient(
        gradient: gradient,
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    28,
                    widget.onBack != null ? 56 : 32,
                    28,
                    22,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      coverWidget,
                      const SizedBox(width: 26),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                widget.label.toUpperCase(),
                                style: AppTheme.kickerStyle(
                                  fontSize: 11,
                                  color: AppTheme.zinc400,
                                ),
                              ),
                              const SizedBox(height: 8),
                              if (widget.titleWidget != null)
                                widget.titleWidget!
                              else
                                Text(
                                  widget.titleText,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTheme.displayStyle(
                                    fontSize: _titleFontSize,
                                    fontWeight: FontWeight.w400,
                                    height: 1.04,
                                    letterSpacing: -0.5,
                                    color: AppTheme.editorialPaper,
                                  ),
                                ),
                              const SizedBox(height: 12),
                              DefaultTextStyle(
                                style: const TextStyle(
                                  fontFamily: AppTheme.fontSans,
                                  fontSize: 13.5,
                                  color: AppTheme.zinc400,
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
                  padding: const EdgeInsets.fromLTRB(28, 2, 28, 22),
                  child: Row(
                    children: [
                      _EditorialPlayPill(
                        isPlaying: widget.isPlaying,
                        onPressed: widget.playEnabled ? widget.onPlay : null,
                      ),
                      if (widget.onShuffle != null) ...[
                        const SizedBox(width: 12),
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
                        const SizedBox(width: 10),
                        Tooltip(
                          message: widget.isPinned! ? t('Unpin') : t('Pin'),
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            onEnter: (_) => setState(() => _pinHovered = true),
                            onExit: (_) => setState(() => _pinHovered = false),
                            child: GestureDetector(
                              onTap: widget.onTogglePin,
                              child: Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: _pinHovered
                                      ? Colors.white.withValues(alpha: 0.08)
                                      : Colors.transparent,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: widget.isPinned!
                                        ? AppTheme.accent400.withValues(alpha: 0.55)
                                        : AppTheme.hairline,
                                  ),
                                ),
                                alignment: Alignment.center,
                                child: Icon(
                                  widget.isPinned!
                                      ? Icons.push_pin_rounded
                                      : Icons.push_pin_outlined,
                                  size: 19,
                                  color: widget.isPinned!
                                      ? AppTheme.accent400
                                      : (_pinHovered
                                          ? AppTheme.editorialPaper
                                          : AppTheme.zinc400),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                      if (widget.onMorePressed != null) ...[
                        const SizedBox(width: 10),
                        Tooltip(
                          message: widget.moreTooltip ?? t('More options'),
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            onEnter: (_) => setState(() => _moreHovered = true),
                            onExit: (_) => setState(() => _moreHovered = false),
                            child: GestureDetector(
                              onTap: widget.onMorePressed,
                              child: Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: _moreHovered
                                      ? Colors.white.withValues(alpha: 0.08)
                                      : Colors.transparent,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: AppTheme.hairline),
                                ),
                                alignment: Alignment.center,
                                child: Icon(
                                  Icons.more_horiz_rounded,
                                  size: 20,
                                  color: _moreHovered
                                      ? AppTheme.editorialPaper
                                      : AppTheme.zinc400,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                      for (final extra in widget.extraActions) ...[
                        const SizedBox(width: 10),
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
                              ? Colors.black.withValues(alpha: 0.55)
                              : Colors.black.withValues(alpha: 0.35),
                          shape: BoxShape.circle,
                          border: Border.all(color: AppTheme.hairline),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.arrow_back_rounded,
                          size: 18,
                          color: _backHovered
                              ? AppTheme.editorialPaper
                              : AppTheme.zinc300,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EditorialPlayPill extends StatefulWidget {
  const _EditorialPlayPill({
    required this.isPlaying,
    required this.onPressed,
  });

  final bool isPlaying;
  final VoidCallback? onPressed;

  @override
  State<_EditorialPlayPill> createState() => _EditorialPlayPillState();
}

class _EditorialPlayPillState extends State<_EditorialPlayPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final label = widget.isPlaying ? t('Pause') : t('Play');

    return Tooltip(
      message: label,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.4,
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTap: widget.onPressed,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOut,
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              decoration: BoxDecoration(
                color: _hovered && enabled
                    ? Colors.white
                    : AppTheme.editorialPaper,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    widget.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    size: 18,
                    color: AppTheme.editorialInk,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    label.toUpperCase(),
                    style: AppTheme.monoStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.editorialInk,
                      letterSpacing: 1.0,
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
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(
                  color: active
                      ? AppTheme.accent400.withValues(alpha: 0.55)
                      : AppTheme.hairline,
                ),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(
                    Icons.shuffle_rounded,
                    size: 19,
                    color: active
                        ? AppTheme.accent400
                        : (hovered
                            ? AppTheme.editorialPaper
                            : AppTheme.zinc400),
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
