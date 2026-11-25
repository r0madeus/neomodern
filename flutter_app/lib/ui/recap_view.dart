import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';

enum StatsPeriod { sevenDays, thirtyDays, allTime }

class RecapView extends StatefulWidget {
  const RecapView({
    super.key,
    required this.controller,
    required this.onOpenArtist,
    required this.onOpenAlbum,
  });

  final PlayerController controller;
  final ValueChanged<String> onOpenArtist;
  final ValueChanged<PlatformInt64> onOpenAlbum;

  @override
  State<RecapView> createState() => _RecapViewState();
}

class _RecapViewState extends State<RecapView> {
  StatsPeriod _period = StatsPeriod.thirtyDays;
  UiStatsSummary? _stats;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  int? _daysForPeriod(StatsPeriod p) => switch (p) {
        StatsPeriod.sevenDays => 7,
        StatsPeriod.thirtyDays => 30,
        StatsPeriod.allTime => null,
      };

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res =
          await widget.controller.fetchStats(days: _daysForPeriod(_period));
      if (mounted) {
        setState(() {
          _stats = res;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  void _selectPeriod(StatsPeriod next) {
    if (_period == next) return;
    setState(() => _period = next);
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final s = _stats;
    final hasData = s != null &&
        (s.playCount > BigInt.zero || s.totalListenedMs > BigInt.zero);

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      children: [
        // Wrapped-style gradient hero card
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                AppTheme.accent700,
                AppTheme.accent900,
                AppTheme.zinc950,
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.start,
                spacing: 16,
                runSpacing: 12,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.bar_chart_rounded,
                            size: 14,
                            color: Colors.white.withValues(alpha: 0.70),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            t('Recap of your local listening activity')
                                .toUpperCase(),
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 1.1,
                              color: Colors.white.withValues(alpha: 0.70),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        t('Listening Stats'),
                        style: const TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.6,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _PeriodPill(
                        label: t('7 Days'),
                        selected: _period == StatsPeriod.sevenDays,
                        onTap: () => _selectPeriod(StatsPeriod.sevenDays),
                      ),
                      const SizedBox(width: 6),
                      _PeriodPill(
                        label: t('30 Days'),
                        selected: _period == StatsPeriod.thirtyDays,
                        onTap: () => _selectPeriod(StatsPeriod.thirtyDays),
                      ),
                      const SizedBox(width: 6),
                      _PeriodPill(
                        label: t('All Time'),
                        selected: _period == StatsPeriod.allTime,
                        onTap: () => _selectPeriod(StatsPeriod.allTime),
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        tooltip: t('Refresh Stats'),
                        onPressed: _load,
                        icon: Icon(
                          Icons.refresh_rounded,
                          size: 19,
                          color: Colors.white.withValues(alpha: 0.80),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              if (hasData) ...[
                const SizedBox(height: 22),
                Container(
                  padding: const EdgeInsets.only(top: 18),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: Colors.white.withValues(alpha: 0.15),
                      ),
                    ),
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final cols = constraints.maxWidth >= 780 ? 6 : 3;
                      const spacing = 14.0;
                      final itemW =
                          (constraints.maxWidth - spacing * (cols - 1)) / cols;
                      final metrics = [
                        (
                          t('Listening Time'),
                          formatListeningDuration(s.totalListenedMs)
                        ),
                        (t('Total Plays'), '${s.playCount}'),
                        (t('Unique Tracks'), '${s.uniqueTracks}'),
                        (t('Unique Artists'), '${s.uniqueArtists}'),
                        (
                          t('Active Days'),
                          s.currentStreakDays > BigInt.zero
                              ? '${s.activeDays} (${t('{n}d streak', {
                                      'n': s.currentStreakDays
                                    })})'
                              : '${s.activeDays}'
                        ),
                        (t('Longest Streak'), '${s.longestStreakDays}d'),
                      ];
                      return Wrap(
                        spacing: spacing,
                        runSpacing: 14,
                        children: [
                          for (final m in metrics)
                            SizedBox(
                              width: itemW,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    m.$1.toUpperCase(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w500,
                                      letterSpacing: 0.6,
                                      color:
                                          Colors.white.withValues(alpha: 0.60),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    m.$2,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                      fontFeatures: [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 22),

        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 80),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 60),
            child: Center(
              child: Text(
                _error!,
                style: const TextStyle(color: AppTheme.danger),
              ),
            ),
          )
        else if (!hasData)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 24),
            decoration: BoxDecoration(
              color: AppTheme.zinc900.withValues(alpha: 0.60),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppTheme.zinc800),
            ),
            child: Column(
              children: [
                const Icon(
                  Icons.bar_chart_rounded,
                  size: 44,
                  color: AppTheme.accent400,
                ),
                const SizedBox(height: 12),
                Text(
                  t('No listening history for this period yet.'),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.zinc100,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  t('Play tracks to build up your local listening recap.'),
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppTheme.zinc400,
                  ),
                ),
              ],
            ),
          )
        else
          _buildContent(s),
      ],
    );
  }

  Widget _buildContent(UiStatsSummary s) {
    final maxTrackMs = s.topTracks.isEmpty
        ? 1.0
        : math.max(1.0, s.topTracks.first.listenedMs.toDouble());
    final maxArtistMs = s.topArtists.isEmpty
        ? 1.0
        : math.max(1.0, s.topArtists.first.listenedMs.toDouble());
    final maxAlbumMs = s.topAlbums.isEmpty
        ? 1.0
        : math.max(1.0, s.topAlbums.first.listenedMs.toDouble());

    return LayoutBuilder(
      builder: (context, constraints) {
        final sideBySide = constraints.maxWidth >= 940;
        final tracksCard = _RankedCard(
          title: t('Top Tracks'),
          emptyText: t('No track plays recorded.'),
          children: [
            for (var i = 0; i < s.topTracks.take(10).length; i++)
              _RankedRow(
                index: i,
                rank: i + 1,
                coverPath: s.topTracks[i].cover,
                title: s.topTracks[i].title,
                subtitle: s.topTracks[i].artist.isNotEmpty
                    ? s.topTracks[i].artist
                    : t('Unknown Artist'),
                trailing:
                    '${t('{n} plays', {'n': s.topTracks[i].playCount})} · ${formatListeningDuration(s.topTracks[i].listenedMs)}',
                ratio: s.topTracks[i].listenedMs.toDouble() / maxTrackMs,
                barColor: AppTheme.accent500,
                onTap: () =>
                    widget.controller.playTracks([s.topTracks[i].path], 0),
              ),
          ],
        );

        final artistsCard = _RankedCard(
          title: t('Top Artists'),
          emptyText: t('No artist plays recorded.'),
          children: [
            for (var i = 0; i < s.topArtists.take(10).length; i++)
              _RankedRow(
                index: i,
                rank: i + 1,
                coverPath: s.topArtists[i].cover,
                circleCover: true,
                fallbackIcon: Icons.person_rounded,
                title: s.topArtists[i].artist,
                subtitle: t('{n} tracks', {'n': s.topArtists[i].uniqueTracks}),
                trailing:
                    '${t('{n} plays', {'n': s.topArtists[i].playCount})} · ${formatListeningDuration(s.topArtists[i].listenedMs)}',
                ratio: s.topArtists[i].listenedMs.toDouble() / maxArtistMs,
                barColor: AppTheme.accent400,
                onTap: () => widget.onOpenArtist(s.topArtists[i].artist),
              ),
          ],
        );

        final albumsCard = _RankedCard(
          title: t('Top Albums'),
          emptyText: t('No album plays recorded.'),
          children: [
            for (var i = 0; i < s.topAlbums.take(10).length; i++)
              _RankedRow(
                index: i,
                rank: i + 1,
                coverPath: s.topAlbums[i].cover,
                title: s.topAlbums[i].album,
                subtitle: s.topAlbums[i].artist.isNotEmpty
                    ? s.topAlbums[i].artist
                    : t('Unknown Artist'),
                trailing:
                    '${t('{n} plays', {'n': s.topAlbums[i].playCount})} · ${formatListeningDuration(s.topAlbums[i].listenedMs)}',
                ratio: s.topAlbums[i].listenedMs.toDouble() / maxAlbumMs,
                barColor: const Color(0xFF38BDF8),
                onTap: s.topAlbums[i].albumId != null
                    ? () => widget.onOpenAlbum(s.topAlbums[i].albumId!)
                    : null,
              ),
          ],
        );

        if (sideBySide) {
          return Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: tracksCard),
                  const SizedBox(width: 16),
                  Expanded(child: artistsCard),
                ],
              ),
              const SizedBox(height: 16),
              albumsCard,
            ],
          );
        }
        return Column(
          children: [
            tracksCard,
            const SizedBox(height: 16),
            artistsCard,
            const SizedBox(height: 16),
            albumsCard,
          ],
        );
      },
    );
  }
}

class _PeriodPill extends StatefulWidget {
  const _PeriodPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_PeriodPill> createState() => _PeriodPillState();
}

class _PeriodPillState extends State<_PeriodPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.selected
        ? AppTheme.accent400
        : (_hovered
            ? Colors.white.withValues(alpha: 0.20)
            : Colors.white.withValues(alpha: 0.10));
    final fg = widget.selected
        ? AppTheme.zinc950
        : Colors.white.withValues(alpha: 0.88);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(9999),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}

class _RankedCard extends StatelessWidget {
  const _RankedCard({
    required this.title,
    required this.emptyText,
    required this.children,
  });

  final String title;
  final String emptyText;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.zinc900.withValues(alpha: 0.60),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.zinc800),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppTheme.zinc100,
            ),
          ),
          const SizedBox(height: 14),
          if (children.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text(
                emptyText,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppTheme.zinc400,
                ),
              ),
            )
          else
            ...children,
        ],
      ),
    );
  }
}

class _RankedRow extends StatefulWidget {
  const _RankedRow({
    required this.index,
    required this.rank,
    required this.coverPath,
    required this.title,
    required this.subtitle,
    required this.trailing,
    required this.ratio,
    required this.barColor,
    this.circleCover = false,
    this.fallbackIcon = Icons.music_note_rounded,
    this.onTap,
  });

  final int index;
  final int rank;
  final String? coverPath;
  final String title;
  final String subtitle;
  final String trailing;
  final double ratio;
  final Color barColor;
  final bool circleCover;
  final IconData fallbackIcon;
  final VoidCallback? onTap;

  @override
  State<_RankedRow> createState() => _RankedRowState();
}

class _RankedRowState extends State<_RankedRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final clamped = widget.ratio.clamp(0.04, 1.0);
    return MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: _hovered && widget.onTap != null
                ? AppTheme.zinc800.withValues(alpha: 0.70)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 24,
                child: Text(
                  '${widget.rank}',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: widget.rank <= 3
                        ? AppTheme.accent400
                        : AppTheme.zinc400,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              CoverArt(
                path: widget.coverPath,
                size: 40,
                borderRadius: widget.circleCover ? 20 : 8,
                iconSize: 16,
                fallbackIcon: widget.fallbackIcon,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: AppTheme.zinc100,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          widget.trailing,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: AppTheme.zinc300,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.zinc400,
                      ),
                    ),
                    const SizedBox(height: 6),
                    _AnimatedProgressBar(
                      ratio: clamped,
                      color: widget.barColor.withValues(alpha: 0.85),
                      delayMs: widget.index * 30,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Staggered `420ms` `Cubic(0.22, 1, 0.36, 1)` progress bar matching
/// `@keyframes bar-grow-x` in `src/app.css`.
class _AnimatedProgressBar extends StatefulWidget {
  const _AnimatedProgressBar({
    required this.ratio,
    required this.color,
    this.delayMs = 0,
  });

  final double ratio;
  final Color color;
  final int delayMs;

  @override
  State<_AnimatedProgressBar> createState() => _AnimatedProgressBarState();
}

class _AnimatedProgressBarState extends State<_AnimatedProgressBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  late final Animation<double> _progress = CurvedAnimation(
    parent: _controller,
    curve: const Cubic(0.22, 1, 0.36, 1),
  );
  Timer? _delayTimer;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(covariant _AnimatedProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ratio != widget.ratio) {
      _start();
    }
  }

  void _start() {
    _delayTimer?.cancel();
    _controller.value = 0.0;
    if (widget.delayMs <= 0) {
      _controller.forward();
    } else {
      _delayTimer = Timer(Duration(milliseconds: widget.delayMs), () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    return ClipRRect(
      borderRadius: BorderRadius.circular(9999),
      child: Container(
        height: 4,
        color: AppTheme.zinc800,
        alignment: Alignment.centerLeft,
        child: disableAnimations
            ? FractionallySizedBox(
                widthFactor: widget.ratio,
                child: ColoredBox(color: widget.color),
              )
            : AnimatedBuilder(
                animation: _progress,
                builder: (context, _) {
                  return FractionallySizedBox(
                    widthFactor: (widget.ratio * _progress.value).clamp(0.0, 1.0),
                    child: SizedBox(
                      height: 4,
                      child: ColoredBox(color: widget.color),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
