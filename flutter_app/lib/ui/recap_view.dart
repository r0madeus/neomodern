import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';
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

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 16,
          runSpacing: 12,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Listening Stats',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  'Recap of your local listening activity',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SegmentedButton<StatsPeriod>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: StatsPeriod.sevenDays,
                      label: Text('7 Days'),
                    ),
                    ButtonSegment(
                      value: StatsPeriod.thirtyDays,
                      label: Text('30 Days'),
                    ),
                    ButtonSegment(
                      value: StatsPeriod.allTime,
                      label: Text('All Time'),
                    ),
                  ],
                  selected: {_period},
                  onSelectionChanged: (sel) {
                    setState(() => _period = sel.first);
                    unawaited(_load());
                  },
                  style: ButtonStyle(
                    backgroundColor: WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.selected)) {
                        return AppColors.accentMuted;
                      }
                      return AppColors.surface;
                    }),
                    foregroundColor: WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.selected)) {
                        return AppColors.accent;
                      }
                      return AppColors.textSecondary;
                    }),
                    side: WidgetStateProperty.all(
                      const BorderSide(color: AppColors.border),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Refresh Stats',
                  onPressed: _load,
                  icon: const Icon(
                    Icons.refresh_rounded,
                    size: 19,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 20),
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
                style: const TextStyle(color: AppColors.danger),
              ),
            ),
          )
        else if (_stats == null ||
            (_stats!.playCount == BigInt.zero &&
                _stats!.totalListenedMs == BigInt.zero))
          Container(
            padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 24),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: const Column(
              children: [
                Icon(
                  Icons.bar_chart_rounded,
                  size: 44,
                  color: AppColors.textMuted,
                ),
                SizedBox(height: 12),
                Text(
                  'No listening history for this period yet.',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Play tracks to build up your local listening recap.',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          )
        else
          _buildContent(_stats!),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final cards = [
              _SummaryCard(
                label: 'Listening Time',
                value: formatListeningDuration(s.totalListenedMs),
                icon: Icons.schedule_rounded,
              ),
              _SummaryCard(
                label: 'Total Plays',
                value: '${s.playCount}',
                icon: Icons.play_circle_outline_rounded,
              ),
              _SummaryCard(
                label: 'Unique Tracks',
                value: '${s.uniqueTracks}',
                icon: Icons.music_note_rounded,
              ),
              _SummaryCard(
                label: 'Unique Artists',
                value: '${s.uniqueArtists}',
                icon: Icons.person_outline_rounded,
              ),
              _SummaryCard(
                label: 'Active Days',
                value: '${s.activeDays}',
                subtitle: s.currentStreakDays > BigInt.zero
                    ? '${s.currentStreakDays}d streak'
                    : null,
                icon: Icons.local_fire_department_rounded,
              ),
            ];
            const spacing = 12.0;
            final cols = constraints.maxWidth >= 900 ? 5 : 2;
            final cardW =
                (constraints.maxWidth - spacing * (cols - 1)) / cols;
            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (final c in cards) SizedBox(width: cardW, child: c),
              ],
            );
          },
        ),
        const SizedBox(height: 24),
        LayoutBuilder(
          builder: (context, constraints) {
            final sideBySide = constraints.maxWidth >= 940;
            final tracksCard = _RankedCard(
              title: 'Top Tracks',
              emptyText: 'No track plays recorded.',
              children: [
                for (var i = 0; i < s.topTracks.take(10).length; i++)
                  _RankedRow(
                    rank: i + 1,
                    coverPath: s.topTracks[i].cover,
                    title: s.topTracks[i].title,
                    subtitle: s.topTracks[i].artist.isNotEmpty
                        ? s.topTracks[i].artist
                        : 'Unknown Artist',
                    trailing:
                        '${s.topTracks[i].playCount} plays · ${formatListeningDuration(s.topTracks[i].listenedMs)}',
                    ratio:
                        s.topTracks[i].listenedMs.toDouble() / maxTrackMs,
                    onTap: () => widget.controller
                        .playTracks([s.topTracks[i].path], 0),
                  ),
              ],
            );

            final artistsCard = _RankedCard(
              title: 'Top Artists',
              emptyText: 'No artist plays recorded.',
              children: [
                for (var i = 0; i < s.topArtists.take(10).length; i++)
                  _RankedRow(
                    rank: i + 1,
                    coverPath: s.topArtists[i].cover,
                    circleCover: true,
                    fallbackIcon: Icons.person_rounded,
                    title: s.topArtists[i].artist,
                    subtitle: '${s.topArtists[i].uniqueTracks} tracks',
                    trailing:
                        '${s.topArtists[i].playCount} plays · ${formatListeningDuration(s.topArtists[i].listenedMs)}',
                    ratio:
                        s.topArtists[i].listenedMs.toDouble() / maxArtistMs,
                    onTap: () => widget.onOpenArtist(s.topArtists[i].artist),
                  ),
              ],
            );

            final albumsCard = _RankedCard(
              title: 'Top Albums',
              emptyText: 'No album plays recorded.',
              children: [
                for (var i = 0; i < s.topAlbums.take(10).length; i++)
                  _RankedRow(
                    rank: i + 1,
                    coverPath: s.topAlbums[i].cover,
                    title: s.topAlbums[i].album,
                    subtitle: s.topAlbums[i].artist.isNotEmpty
                        ? s.topAlbums[i].artist
                        : 'Unknown Artist',
                    trailing:
                        '${s.topAlbums[i].playCount} plays · ${formatListeningDuration(s.topAlbums[i].listenedMs)}',
                    ratio:
                        s.topAlbums[i].listenedMs.toDouble() / maxAlbumMs,
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
        ),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.label,
    required this.value,
    required this.icon,
    this.subtitle,
  });

  final String label;
  final String value;
  final IconData icon;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: AppColors.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              style: const TextStyle(
                fontSize: 11.5,
                color: AppColors.accent,
              ),
            ),
          ],
        ],
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
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          if (children.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text(
                emptyText,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
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

class _RankedRow extends StatelessWidget {
  const _RankedRow({
    required this.rank,
    required this.coverPath,
    required this.title,
    required this.subtitle,
    required this.trailing,
    required this.ratio,
    this.circleCover = false,
    this.fallbackIcon = Icons.music_note_rounded,
    this.onTap,
  });

  final int rank;
  final String? coverPath;
  final String title;
  final String subtitle;
  final String trailing;
  final double ratio;
  final bool circleCover;
  final IconData fallbackIcon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final clamped = ratio.clamp(0.0, 1.0);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      hoverColor: AppColors.surfaceHover,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        child: Column(
          children: [
            Row(
              children: [
                SizedBox(
                  width: 24,
                  child: Text(
                    '$rank',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight:
                          rank <= 3 ? FontWeight.w700 : FontWeight.w500,
                      color: rank <= 3 ? AppColors.accent : AppColors.textMuted,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                CoverArt(
                  path: coverPath,
                  size: 36,
                  borderRadius: circleCover ? 18 : 5,
                  iconSize: 16,
                  fallbackIcon: fallbackIcon,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  trailing,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppColors.textSecondary,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: clamped,
                minHeight: 3,
                backgroundColor: AppColors.border,
                valueColor: const AlwaysStoppedAnimation<Color>(
                  AppColors.accent,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
