import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';
import 'package:neomodern/ui/right_panel.dart';
import 'package:neomodern/ui/track_menu.dart';
import 'package:neomodern/ui/widgets/motion_primitives.dart';

class PlayerBar extends StatefulWidget {
  const PlayerBar({
    super.key,
    required this.controller,
    required this.rightPanelOpen,
    required this.rightPanelTab,
    required this.onTogglePanel,
    required this.onOpenArtist,
    this.onOpenAlbum,
  });

  final PlayerController controller;
  final bool rightPanelOpen;
  final RightPanelTab rightPanelTab;
  final ValueChanged<RightPanelTab> onTogglePanel;
  final ValueChanged<String> onOpenArtist;
  final ValueChanged<PlatformInt64>? onOpenAlbum;

  @override
  State<PlayerBar> createState() => _PlayerBarState();
}

class _PlayerBarState extends State<PlayerBar> {
  Color? _lastGlowColor;
  bool _coverHovered = false;

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final snap = ctrl.snapshot;
    final current = snap.current;
    final currentRow = ctrl.currentTrackRow;
    final duration = snap.durationSeconds;
    final hasTrack = current != null;
    final isLocalTrack = current != null &&
        !current.path.startsWith('http://') &&
        !current.path.startsWith('https://');
    final sleepActive = snap.sleepEndOfTrack || snap.sleepEndsAt != null;

    final coverColor = hasTrack ? ctrl.currentCoverColor : null;
    if (coverColor != null) {
      _lastGlowColor = coverColor;
    }
    final activeGlowColor = coverColor ?? _lastGlowColor;

    const bgColor = AppColors.sidebar;
    const borderColor = AppTheme.hairlineStrong;

    return Container(
      decoration: const BoxDecoration(
        color: bgColor,
        border: Border(top: BorderSide(color: borderColor)),
      ),
      child: Stack(
        children: [
          if (activeGlowColor != null)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: coverColor != null ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.ease,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(-0.72, 0.0),
                        radius: 2.0,
                        colors: [
                          Color.fromARGB(
                            24,
                            (activeGlowColor.r * 255).round() & 0xFF,
                            (activeGlowColor.g * 255).round() & 0xFF,
                            (activeGlowColor.b * 255).round() & 0xFF,
                          ),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.72],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(
              children: [
                // Left column (1fr)
                Expanded(
                  flex: 1,
                  child: hasTrack
                      ? GestureDetector(
                          onSecondaryTapDown: (d) {
                            final menuRow = currentRow;
                            if (menuRow != null) {
                              TrackMenu.show(
                                context: context,
                                globalPosition: d.globalPosition,
                                track: menuRow,
                                controller: ctrl,
                                onOpenArtist: widget.onOpenArtist,
                                onOpenAlbum: widget.onOpenAlbum,
                              );
                            }
                          },
                          child: Row(
                            children: [
                              Tooltip(
                                message: t('Now playing'),
                                child: MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  onEnter: (_) =>
                                      setState(() => _coverHovered = true),
                                  onExit: (_) =>
                                      setState(() => _coverHovered = false),
                                  child: GestureDetector(
                                    onTap: () => widget.onTogglePanel(
                                      RightPanelTab.nowPlaying,
                                    ),
                                    child: SizedBox(
                                      width: 48,
                                      height: 48,
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          CoverArt(
                                            path: ctrl.currentCoverPath,
                                            size: 48,
                                            borderRadius: 2,
                                            iconSize: 22,
                                          ),
                                          AnimatedOpacity(
                                            opacity: _coverHovered ? 1.0 : 0.0,
                                            duration: const Duration(
                                              milliseconds: 150,
                                            ),
                                            child: Container(
                                              decoration: BoxDecoration(
                                                color: Colors.black
                                                    .withValues(alpha: 0.50),
                                                borderRadius:
                                                    BorderRadius.circular(2),
                                              ),
                                              alignment: Alignment.center,
                                              child: const Icon(
                                                Icons.smart_display_outlined,
                                                size: 20,
                                                color: Colors.white,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    HoverLinkText(
                                      text: current.title,
                                      onTap: currentRow?.albumId != null &&
                                              widget.onOpenAlbum != null
                                          ? () => widget.onOpenAlbum!(
                                                currentRow!.albumId!,
                                              )
                                          : null,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                        color: AppTheme.zinc100,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    _SubtitleLine(
                                      artist: current.artist,
                                      album: currentRow?.album ?? '',
                                      albumId: currentRow?.albumId,
                                      trackNumber:
                                          (snap.currentIndex ?? 0) + 1,
                                      queueLength: snap.queueLength,
                                      onOpenArtist: widget.onOpenArtist,
                                      onOpenAlbum: widget.onOpenAlbum,
                                    ),
                                  ],
                                ),
                              ),
                              if (isLocalTrack) ...[
                                const SizedBox(width: 6),
                                AnimatedSaveButton(
                                  isSaved: ctrl.isCurrentFavorite,
                                  size: 16,
                                  onPressed: ctrl.toggleCurrentFavorite,
                                ),
                              ],
                            ],
                          ),
                        )
                      : Text(
                          t('Nothing playing'),
                          style: const TextStyle(
                            fontSize: 14,
                            color: AppTheme.zinc400,
                          ),
                        ),
                ),

                const SizedBox(width: 24),

                // Center column (2fr)
                Expanded(
                  flex: 2,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _DotToggleButton(
                            icon: Icons.shuffle_rounded,
                            size: 20,
                            active: snap.shuffle,
                            tooltip: snap.shuffle
                                ? t('Shuffle on')
                                : t('Shuffle off'),
                            onPressed: ctrl.toggleShuffle,
                          ),
                          const SizedBox(width: 8),
                          _TransportIconButton(
                            icon: Icons.skip_previous_rounded,
                            size: 24,
                            tooltip: t('Previous'),
                            onPressed: hasTrack ? ctrl.previous : null,
                          ),
                          const SizedBox(width: 8),
                          HoverPlayButton(
                            size: 44,
                            iconSize: 24,
                            isPlaying: ctrl.isPlaying,
                            onPressed: hasTrack ? ctrl.togglePause : null,
                          ),
                          const SizedBox(width: 8),
                          _TransportIconButton(
                            icon: Icons.skip_next_rounded,
                            size: 24,
                            tooltip: t('Next'),
                            onPressed: hasTrack ? ctrl.next : null,
                          ),
                          const SizedBox(width: 8),
                          _DotToggleButton(
                            icon: snap.repeat == 'one'
                                ? Icons.repeat_one_rounded
                                : Icons.repeat_rounded,
                            size: 20,
                            active: snap.repeat != 'off',
                            tooltip: t('Repeat: ${snap.repeat}'),
                            onPressed: ctrl.cycleRepeat,
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      ValueListenableBuilder<double>(
                        valueListenable: ctrl.positionNotifier,
                        builder: (context, pos, _) {
                          final maxDur =
                              (duration != null && duration > 0) ? duration : 1.0;
                          final clampedPos =
                              math.min(math.max(pos, 0.0), maxDur);
                          return Row(
                            children: [
                              SizedBox(
                                width: 48,
                                child: Text(
                                  hasTrack
                                      ? formatDuration(clampedPos)
                                      : '--:--',
                                  textAlign: TextAlign.right,
                                  style: AppTheme.monoStyle(
                                    fontSize: 11,
                                    color: AppTheme.zinc400,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: HoverSeekBar(
                                  value: hasTrack ? clampedPos : 0.0,
                                  min: 0.0,
                                  max: maxDur,
                                  hitHeight: 16,
                                  onChangeStart: hasTrack
                                      ? (_) => ctrl.beginSeekDrag()
                                      : null,
                                  onChanged: hasTrack
                                      ? (v) => ctrl.updateSeekDrag(v)
                                      : null,
                                  onChangeEnd: hasTrack
                                      ? (v) => ctrl.endSeekDrag(v)
                                      : null,
                                ),
                              ),
                              const SizedBox(width: 12),
                              SizedBox(
                                width: 48,
                                child: Text(
                                  hasTrack
                                      ? formatDuration(duration)
                                      : '--:--',
                                  style: AppTheme.monoStyle(
                                    fontSize: 11,
                                    color: AppTheme.zinc400,
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 24),

                // Right column (1fr)
                Expanded(
                  flex: 1,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (sleepActive) ...[
                        _SleepTimerPill(controller: ctrl),
                        const SizedBox(width: 4),
                      ],
                      _PanelModeIconButton(
                        icon: Icons.lyrics_rounded,
                        tooltip: t('Lyrics'),
                        active: widget.rightPanelOpen &&
                            widget.rightPanelTab == RightPanelTab.lyrics,
                        onPressed: () =>
                            widget.onTogglePanel(RightPanelTab.lyrics),
                      ),
                      const SizedBox(width: 2),
                      _PanelModeIconButton(
                        icon: Icons.queue_music_rounded,
                        tooltip: t('Queue'),
                        active: widget.rightPanelOpen &&
                            widget.rightPanelTab == RightPanelTab.queue,
                        onPressed: () =>
                            widget.onTogglePanel(RightPanelTab.queue),
                      ),
                      const SizedBox(width: 2),
                      _PanelModeIconButton(
                        icon: Icons.smart_display_outlined,
                        tooltip: t('Now playing'),
                        active: widget.rightPanelOpen &&
                            widget.rightPanelTab == RightPanelTab.nowPlaying,
                        onPressed: () =>
                            widget.onTogglePanel(RightPanelTab.nowPlaying),
                      ),
                      const SizedBox(width: 4),
                      _TransportIconButton(
                        icon: snap.volume == 0
                            ? Icons.volume_off_rounded
                            : snap.volume < 50
                                ? Icons.volume_down_rounded
                                : Icons.volume_up_rounded,
                        size: 20,
                        tooltip: snap.volume == 0 ? t('Unmute') : t('Mute'),
                        onPressed: ctrl.toggleMute,
                      ),
                      const SizedBox(width: 4),
                      SizedBox(
                        width: 112,
                        child: HoverSeekBar(
                          value: snap.volume.clamp(0.0, 100.0),
                          min: 0.0,
                          max: 100.0,
                          hitHeight: 18,
                          onChanged: (v) => ctrl.setVolume(v),
                        ),
                      ),
                    ],
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

class _SubtitleLine extends StatelessWidget {
  const _SubtitleLine({
    required this.artist,
    required this.album,
    required this.albumId,
    required this.trackNumber,
    required this.queueLength,
    required this.onOpenArtist,
    this.onOpenAlbum,
  });

  final String artist;
  final String album;
  final PlatformInt64? albumId;
  final int trackNumber;
  final int queueLength;
  final ValueChanged<String> onOpenArtist;
  final ValueChanged<PlatformInt64>? onOpenAlbum;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontSize: 12, color: AppTheme.zinc400);
    return Row(
      children: [
        if (artist.isNotEmpty) ...[
          Flexible(
            child: HoverLinkText(
              text: artist,
              onTap: () => onOpenArtist(artist),
              style: style,
            ),
          ),
          const Text(' · ', style: style),
        ],
        if (album.isNotEmpty) ...[
          Flexible(
            child: HoverLinkText(
              text: album,
              onTap: albumId != null && onOpenAlbum != null
                  ? () => onOpenAlbum!(albumId!)
                  : null,
              style: style,
            ),
          ),
          const Text(' · ', style: style),
        ],
        Text(
          '$trackNumber / $queueLength',
          style: style.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _DotToggleButton extends StatefulWidget {
  const _DotToggleButton({
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
  State<_DotToggleButton> createState() => _DotToggleButtonState();
}

class _DotToggleButtonState extends State<_DotToggleButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.active
        ? (_hovered
            ? AppTheme.accent950.withValues(alpha: 0.60)
            : Colors.transparent)
        : (_hovered ? AppTheme.zinc800 : Colors.transparent);
    final fg = widget.active
        ? AppTheme.accent400
        : (_hovered ? Colors.white : AppTheme.zinc400);

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: bg,
              shape: BoxShape.circle,
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(widget.icon, size: widget.size, color: fg),
                if (widget.active)
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
    );
  }
}

class _TransportIconButton extends StatefulWidget {
  const _TransportIconButton({
    required this.icon,
    required this.size,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final double size;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  State<_TransportIconButton> createState() => _TransportIconButtonState();
}

class _TransportIconButtonState extends State<_TransportIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    return Tooltip(
      message: widget.tooltip,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.4,
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTap: widget.onPressed,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: _hovered && enabled
                    ? AppTheme.zinc800
                    : Colors.transparent,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                widget.icon,
                size: widget.size,
                color: _hovered && enabled ? Colors.white : AppTheme.zinc300,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PanelModeIconButton extends StatefulWidget {
  const _PanelModeIconButton({
    required this.icon,
    required this.tooltip,
    required this.active,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback onPressed;

  @override
  State<_PanelModeIconButton> createState() => _PanelModeIconButtonState();
}

class _PanelModeIconButtonState extends State<_PanelModeIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.active
        ? (_hovered
            ? AppTheme.accent950.withValues(alpha: 0.85)
            : AppTheme.accent950.withValues(alpha: 0.60))
        : (_hovered ? AppTheme.zinc800 : Colors.transparent);
    final fg = widget.active
        ? AppTheme.accent300
        : (_hovered ? Colors.white : AppTheme.zinc400);

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: bg,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(widget.icon, size: 20, color: fg),
          ),
        ),
      ),
    );
  }
}

class _SleepTimerPill extends StatefulWidget {
  const _SleepTimerPill({required this.controller});

  final PlayerController controller;

  @override
  State<_SleepTimerPill> createState() => _SleepTimerPillState();
}

class _SleepTimerPillState extends State<_SleepTimerPill> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant _SleepTimerPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  void _syncTicker() {
    final hasDeadline = widget.controller.snapshot.sleepEndsAt != null;
    if (hasDeadline && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!hasDeadline && _tick != null) {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  String _formatRemaining() {
    final snap = widget.controller.snapshot;
    if (snap.sleepEndOfTrack) return t('End');
    final endsAt = snap.sleepEndsAt;
    if (endsAt == null) return '';
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final secs = math.max(0, ((endsAt.toInt() - nowMs) / 1000).round());
    final h = secs ~/ 3600;
    final m = (secs % 3600) ~/ 60;
    final s = secs % 60;
    final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final label = _formatRemaining();
    return PopupMenuButton<String>(
      tooltip: t('Sleep Timer active'),
      color: AppTheme.zinc900,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppTheme.zinc700),
      ),
      onSelected: (value) {
        if (value == 'off') {
          unawaited(widget.controller.setSleepTimer());
        } else if (value == 'end') {
          unawaited(widget.controller.setSleepTimer(endOfTrack: true));
        } else {
          final mins = double.tryParse(value);
          if (mins != null) {
            unawaited(widget.controller.setSleepTimer(minutes: mins));
          }
        }
      },
      itemBuilder: (_) => [
        for (final mins in const [15, 30, 45, 60, 90, 120])
          PopupMenuItem<String>(
            value: '$mins',
            child: Text(t('{n} min', {'n': mins})),
          ),
        PopupMenuItem<String>(
          value: 'end',
          child: Text(t('End of Track')),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'off',
          child: Text(
            t('Off'),
            style: const TextStyle(color: AppTheme.danger),
          ),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppTheme.accent950.withValues(alpha: 0.60),
          borderRadius: BorderRadius.circular(9999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.bedtime_rounded,
              size: 16,
              color: AppTheme.accent300,
            ),
            if (label.isNotEmpty) ...[
              const SizedBox(width: 5),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: AppTheme.accent300,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
