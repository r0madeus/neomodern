import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';
import 'package:neomodern/ui/widgets/smooth_scroll.dart';

enum StatsPeriod { sevenDays, thirtyDays, thisYear, allTime, custom }

class RecapView extends StatefulWidget {
  const RecapView({
    super.key,
    required this.controller,
    required this.onOpenArtist,
    required this.onOpenAlbum,
    this.onFetchStatsRange,
    this.onClearHistory,
  });

  final PlayerController controller;
  final ValueChanged<String> onOpenArtist;
  final ValueChanged<PlatformInt64> onOpenAlbum;
  final Future<UiStatsSummary> Function({
    int? fromMs,
    int? toMs,
    bool sortByPlays,
  })? onFetchStatsRange;
  final Future<void> Function()? onClearHistory;

  @override
  State<RecapView> createState() => _RecapViewState();
}

class _RecapViewState extends State<RecapView> {
  static const List<String> _weekdaysShort = [
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];
  static const List<String> _weekdaysFull = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  StatsPeriod _period = StatsPeriod.thirtyDays;
  int _selectedYear = DateTime.now().year;
  late DateTime _customFrom = DateTime.now().subtract(const Duration(days: 30));
  late DateTime _customTo = DateTime.now();
  bool _sortByPlays = false;
  bool _savingPlaylist = false;
  bool _clearing = false;

  UiStatsSummary? _stats;
  bool _loading = true;
  String? _error;
  int _statsGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  (int?, int?) _rangeBounds() {
    final now = DateTime.now();
    switch (_period) {
      case StatsPeriod.sevenDays:
        final start = DateTime(now.year, now.month, now.day - 6);
        return (start.millisecondsSinceEpoch, null);
      case StatsPeriod.thirtyDays:
        final start = DateTime(now.year, now.month, now.day - 29);
        return (start.millisecondsSinceEpoch, null);
      case StatsPeriod.thisYear:
        final start = DateTime(_selectedYear, 1, 1);
        final end = DateTime(_selectedYear + 1, 1, 1);
        return (start.millisecondsSinceEpoch, end.millisecondsSinceEpoch);
      case StatsPeriod.allTime:
        return (null, null);
      case StatsPeriod.custom:
        final start = DateTime(_customFrom.year, _customFrom.month, _customFrom.day);
        final end = DateTime(_customTo.year, _customTo.month, _customTo.day + 1);
        return (start.millisecondsSinceEpoch, end.millisecondsSinceEpoch);
    }
  }

  Future<void> _load() async {
    final gen = ++_statsGeneration;
    if (widget.onFetchStatsRange == null && !widget.controller.initialized) {
      setState(() {
        _loading = false;
        _error = null;
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    final (fromMs, toMs) = _rangeBounds();
    try {
      final fetcher =
          widget.onFetchStatsRange ?? widget.controller.fetchStatsRange;
      final res = await fetcher(
        fromMs: fromMs,
        toMs: toMs,
        sortByPlays: _sortByPlays,
      );
      if (!mounted || gen != _statsGeneration) return;
      setState(() {
        _stats = res;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || gen != _statsGeneration) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _selectPeriod(StatsPeriod next) {
    if (next == StatsPeriod.custom) {
      setState(() => _period = StatsPeriod.custom);
      unawaited(_pickCustomRange());
      return;
    }
    if (_period == next) return;
    setState(() => _period = next);
    unawaited(_load());
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final pickedStart = await showDatePicker(
      context: context,
      initialDate: _customFrom,
      firstDate: DateTime(2000),
      lastDate: now,
      helpText: t('Select start date'),
    );
    if (!mounted || pickedStart == null) {
      unawaited(_load());
      return;
    }
    final pickedEnd = await showDatePicker(
      context: context,
      initialDate: _customTo.isBefore(pickedStart) ? pickedStart : _customTo,
      firstDate: pickedStart,
      lastDate: now,
      helpText: t('Select end date'),
    );
    if (!mounted) return;
    setState(() {
      _customFrom = pickedStart;
      _customTo = pickedEnd ?? pickedStart;
    });
    await _load();
  }

  String _formatDate(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  String _periodLabel() {
    switch (_period) {
      case StatsPeriod.sevenDays:
        return t('7 Days');
      case StatsPeriod.thirtyDays:
        return t('30 Days');
      case StatsPeriod.thisYear:
        return '$_selectedYear';
      case StatsPeriod.allTime:
        return t('All Time');
      case StatsPeriod.custom:
        return '${_formatDate(_customFrom)} – ${_formatDate(_customTo)}';
    }
  }

  String _hourPersona(int hour) {
    if (hour >= 5 && hour < 12) return t('Morning listener');
    if (hour >= 12 && hour < 17) return t('Afternoon listener');
    if (hour >= 17 && hour < 22) return t('Evening listener');
    return t('Night owl');
  }

  String _formatShortTime(PlatformInt64 ms) {
    final secs = (ms.toInt() / 1000).round();
    final m = secs ~/ 60;
    final r = secs % 60;
    return '$m:${r.toString().padLeft(2, '0')}';
  }

  String _formatTimestamp(PlatformInt64 epochVal) {
    final raw = epochVal.toInt();
    // Support seconds or milliseconds timestamps cleanly.
    final ms = raw > 1000000000000 ? raw : raw * 1000;
    final dt = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final mon = months[(dt.month - 1).clamp(0, 11)];
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$mon ${dt.day}, $hh:$mm';
  }

  Future<void> _saveTopAsPlaylist(UiStatsSummary s) async {
    final ids = s.topTracks
        .map((tr) => tr.trackId)
        .whereType<PlatformInt64>()
        .toList();
    if (ids.isEmpty || _savingPlaylist) return;
    setState(() => _savingPlaylist = true);
    try {
      final name = '${t('Top tracks')} · ${_periodLabel()}';
      final made = await widget.controller.saveTracksAsPlaylist(name, ids);
      if (made != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(t('Saved "{name}"', {'name': made.name})),
            behavior: SnackBarBehavior.floating,
            width: 300,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _savingPlaylist = false);
    }
  }

  Future<void> _confirmAndClearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.zinc900,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppTheme.zinc800),
        ),
        title: Text(
          t('Clear history'),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        content: Text(
          t('Clear all listening history?'),
          style: const TextStyle(fontSize: 13.5, color: AppTheme.zinc300),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.danger,
              foregroundColor: AppTheme.zinc950,
            ),
            child: Text(t('Clear')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _clearing = true);
    try {
      final clearer =
          widget.onClearHistory ?? widget.controller.clearListeningHistory;
      await clearer();
      if (mounted) await _load();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _stats;
    final hasData = s != null &&
        (s.rawEventCount > BigInt.zero ||
            s.playCount > BigInt.zero ||
            s.totalListenedMs > BigInt.zero);

    final yearSet = <int>{
      DateTime.now().year,
      if (s != null) ...s.availableYears,
    };
    final yearOptions = yearSet.toList()..sort((a, b) => b.compareTo(a));

    return SmoothScrollWrapper(
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 36),
        children: [
          // Gradient hero card
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
                              t('Your Wrapped').toUpperCase(),
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
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _PeriodPill(
                          label: t('7 Days'),
                          selected: _period == StatsPeriod.sevenDays,
                          onTap: () => _selectPeriod(StatsPeriod.sevenDays),
                        ),
                        _PeriodPill(
                          label: t('30 Days'),
                          selected: _period == StatsPeriod.thirtyDays,
                          onTap: () => _selectPeriod(StatsPeriod.thirtyDays),
                        ),
                        _PeriodPill(
                          label: t('This Year'),
                          selected: _period == StatsPeriod.thisYear,
                          onTap: () => _selectPeriod(StatsPeriod.thisYear),
                        ),
                        _PeriodPill(
                          label: t('All Time'),
                          selected: _period == StatsPeriod.allTime,
                          onTap: () => _selectPeriod(StatsPeriod.allTime),
                        ),
                        _PeriodPill(
                          label: t('Custom'),
                          selected: _period == StatsPeriod.custom,
                          onTap: () => _selectPeriod(StatsPeriod.custom),
                        ),
                        if (_period == StatsPeriod.thisYear)
                          Container(
                            height: 30,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(9999),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<int>(
                                value: yearOptions.contains(_selectedYear)
                                    ? _selectedYear
                                    : yearOptions.first,
                                dropdownColor: AppTheme.zinc900,
                                iconEnabledColor: Colors.white,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                                items: [
                                  for (final y in yearOptions)
                                    DropdownMenuItem<int>(
                                      value: y,
                                      child: Text('$y'),
                                    ),
                                ],
                                onChanged: (y) {
                                  if (y == null) return;
                                  setState(() => _selectedYear = y);
                                  unawaited(_load());
                                },
                              ),
                            ),
                          ),
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
                if (_period == StatsPeriod.custom) ...[
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _DateRangeChip(
                        label: '${t('From')}: ${_formatDate(_customFrom)}',
                        onTap: _pickCustomRange,
                      ),
                      _DateRangeChip(
                        label: '${t('To')}: ${_formatDate(_customTo)}',
                        onTap: _pickCustomRange,
                      ),
                    ],
                  ),
                ],
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
                        final cols = constraints.maxWidth >= 780
                            ? 6
                            : (constraints.maxWidth >= 480 ? 3 : 2);
                        const spacing = 14.0;
                        final itemW =
                            (constraints.maxWidth - spacing * (cols - 1)) /
                                cols;
                        final donePct = (s.completionRate * 100).round();
                        final metrics = [
                          (
                            t('Listening time'),
                            formatListeningDuration(s.totalListenedMs),
                          ),
                          (t('Plays'), '${s.playCount}'),
                          (t('Unique tracks'), '${s.uniqueTracks}'),
                          (t('Unique artists'), '${s.uniqueArtists}'),
                          (
                            t('Longest streak'),
                            s.longestStreakDays == BigInt.one
                                ? t('{n} day', {'n': s.longestStreakDays})
                                : t('{n} days', {'n': s.longestStreakDays}),
                          ),
                          (t('Completion rate'), '$donePct%'),
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
                                        color: Colors.white
                                            .withValues(alpha: 0.60),
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
      ),
    );
  }

  Widget _buildContent(UiStatsSummary s) {
    final maxTrackVal = s.topTracks.isEmpty
        ? 1.0
        : math.max(
            1.0,
            _sortByPlays
                ? s.topTracks.first.playCount.toDouble()
                : s.topTracks.first.listenedMs.toDouble(),
          );
    final maxArtistMs = s.topArtists.isEmpty
        ? 1.0
        : math.max(1.0, s.topArtists.first.listenedMs.toDouble());
    final maxAlbumMs = s.topAlbums.isEmpty
        ? 1.0
        : math.max(1.0, s.topAlbums.first.listenedMs.toDouble());
    final maxGenreMs = s.topGenres.isEmpty
        ? 1.0
        : math.max(1.0, s.topGenres.first.listenedMs.toDouble());
    var totalGenreMs = 0;
    for (final g in s.topGenres) {
      totalGenreMs += g.listenedMs.toInt();
    }
    if (totalGenreMs <= 0) totalGenreMs = 1;

    final peakHour = s.peakHour;
    final favWeekday = s.favoriteWeekday;

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final insightCols = constraints.maxWidth >= 640 ? 3 : 1;

        final insightCards = [
          _InsightCard(
            label: t('Peak hour'),
            value: peakHour != null
                ? '${peakHour.toString().padLeft(2, '0')}:00'
                : '—',
            subtitle: peakHour != null ? _hourPersona(peakHour) : null,
            subtitleColor: AppTheme.accent400,
          ),
          _InsightCard(
            label: t('Favorite day'),
            value: favWeekday != null && favWeekday >= 0 && favWeekday < 7
                ? t(_weekdaysFull[favWeekday])
                : '—',
            subtitle:
                '${t('Current streak')}: ${s.currentStreakDays == BigInt.one ? t('{n} day', {'n': s.currentStreakDays}) : t('{n} days', {'n': s.currentStreakDays})}',
          ),
          _InsightCard(
            label: t('Completed / Skipped'),
            value: '${s.completedCount} / ${s.skipCount}',
            subtitle: t('{done} finished · {skipped} skipped', {
              'done': s.completedCount,
              'skipped': s.skipCount,
            }),
          ),
        ];

        final tracksCard = _RankedCard(
          title: t('Top tracks'),
          emptyText: t('No track plays recorded.'),
          headerTrailing: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: AppTheme.zinc800,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _SortTogglePill(
                      label: t('By time'),
                      active: !_sortByPlays,
                      onTap: () {
                        if (_sortByPlays) {
                          setState(() => _sortByPlays = false);
                          unawaited(_load());
                        }
                      },
                    ),
                    _SortTogglePill(
                      label: t('By plays'),
                      active: _sortByPlays,
                      onTap: () {
                        if (!_sortByPlays) {
                          setState(() => _sortByPlays = true);
                          unawaited(_load());
                        }
                      },
                    ),
                  ],
                ),
              ),
              if (s.topTracks.any((tr) => tr.trackId != null))
                FilledButton(
                  onPressed:
                      _savingPlaylist ? null : () => _saveTopAsPlaylist(s),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.accent600,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    minimumSize: const Size(0, 28),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Text(
                    t('Save as playlist'),
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
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
                trailing: _sortByPlays
                    ? '${t('{n} plays', {'n': s.topTracks[i].playCount})} · ${formatListeningDuration(s.topTracks[i].listenedMs)}'
                    : '${formatListeningDuration(s.topTracks[i].listenedMs)} · ${t('{n} plays', {'n': s.topTracks[i].playCount})}',
                ratio: (_sortByPlays
                        ? s.topTracks[i].playCount.toDouble()
                        : s.topTracks[i].listenedMs.toDouble()) /
                    maxTrackVal,
                barColor: AppTheme.accent500,
                onTap: () =>
                    widget.controller.playTracks([s.topTracks[i].path], 0),
              ),
          ],
        );

        final artistsCard = _RankedCard(
          title: t('Top artists'),
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
                    '${formatListeningDuration(s.topArtists[i].listenedMs)} · ${t('{n} plays', {'n': s.topArtists[i].playCount})}',
                ratio: s.topArtists[i].listenedMs.toDouble() / maxArtistMs,
                barColor: AppTheme.accent400,
                onTap: () => widget.onOpenArtist(s.topArtists[i].artist),
              ),
          ],
        );

        final albumsCard = _RankedCard(
          title: t('Top albums'),
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
                    '${formatListeningDuration(s.topAlbums[i].listenedMs)} · ${t('{n} plays', {'n': s.topAlbums[i].playCount})}',
                ratio: s.topAlbums[i].listenedMs.toDouble() / maxAlbumMs,
                barColor: const Color(0xFF38BDF8),
                onTap: s.topAlbums[i].albumId != null
                    ? () => widget.onOpenAlbum(s.topAlbums[i].albumId!)
                    : null,
              ),
          ],
        );

        final genresCard = _RankedCard(
          title: t('Top genres'),
          emptyText: t('No genres recorded.'),
          children: [
            for (var i = 0; i < s.topGenres.take(10).length; i++)
              _GenreStatRow(
                index: i,
                rank: i + 1,
                genre: s.topGenres[i],
                sharePercent: math.max(
                  1,
                  ((s.topGenres[i].listenedMs.toInt() / totalGenreMs) * 100)
                      .round(),
                ),
                ratio: s.topGenres[i].listenedMs.toDouble() / maxGenreMs,
              ),
          ],
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 3 Insight cards
            if (insightCols == 3)
              Row(
                children: [
                  Expanded(child: insightCards[0]),
                  const SizedBox(width: 14),
                  Expanded(child: insightCards[1]),
                  const SizedBox(width: 14),
                  Expanded(child: insightCards[2]),
                ],
              )
            else
              Column(
                children: [
                  insightCards[0],
                  const SizedBox(height: 12),
                  insightCards[1],
                  const SizedBox(height: 12),
                  insightCards[2],
                ],
              ),
            const SizedBox(height: 18),

            // Top tracks & Top artists
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: tracksCard),
                  const SizedBox(width: 16),
                  Expanded(child: artistsCard),
                ],
              )
            else ...[
              tracksCard,
              const SizedBox(height: 16),
              artistsCard,
            ],
            const SizedBox(height: 16),

            // Top albums & Top genres
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: albumsCard),
                  const SizedBox(width: 16),
                  Expanded(child: genresCard),
                ],
              )
            else ...[
              albumsCard,
              const SizedBox(height: 16),
              genresCard,
            ],
            const SizedBox(height: 16),

            // 3 Staggered Animated Charts
            _ListeningRhythmCard(
              stats: s,
              weekdaysShort: _weekdaysShort,
              wide: wide,
            ),
            const SizedBox(height: 16),

            // Recent activity + Clear history
            _RecentActivityCard(
              events: s.recentEvents,
              clearing: _clearing,
              onClearHistory: _confirmAndClearHistory,
              onPlayPath: (path) => widget.controller.playTracks([path], 0),
              formatShortTime: _formatShortTime,
              formatTimestamp: _formatTimestamp,
            ),
          ],
        );
      },
    );
  }
}

class _DateRangeChip extends StatelessWidget {
  const _DateRangeChip({
    required this.label,
    required this.onTap,
  });

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.30),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white.withValues(alpha: 0.20)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.calendar_today_rounded,
                  size: 13, color: Colors.white70),
              const SizedBox(width: 6),
              Text(
                label,
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
    );
  }
}

class _InsightCard extends StatelessWidget {
  const _InsightCard({
    required this.label,
    required this.value,
    this.subtitle,
    this.subtitleColor,
  });

  final String label;
  final String value;
  final String? subtitle;
  final Color? subtitleColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.zinc900.withValues(alpha: 0.60),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.zinc800),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.7,
              color: AppTheme.zinc400,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: AppTheme.zinc100,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: subtitleColor ?? AppTheme.zinc400,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SortTogglePill extends StatelessWidget {
  const _SortTogglePill({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: active ? AppTheme.zinc700 : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              color: active ? Colors.white : AppTheme.zinc400,
            ),
          ),
        ),
      ),
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
    this.headerTrailing,
  });

  final String title;
  final String emptyText;
  final List<Widget> children;
  final Widget? headerTrailing;

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
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 10,
            runSpacing: 8,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.zinc100,
                ),
              ),
              ?headerTrailing,
            ],
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
                      height: 4,
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

class _GenreStatRow extends StatelessWidget {
  const _GenreStatRow({
    required this.index,
    required this.rank,
    required this.genre,
    required this.sharePercent,
    required this.ratio,
  });

  final int index;
  final int rank;
  final UiGenreStat genre;
  final int sharePercent;
  final double ratio;

  @override
  Widget build(BuildContext context) {
    final clamped = ratio.clamp(0.04, 1.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '$rank',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.zinc400,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  genre.genre,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.zinc100,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '$sharePercent% · ${formatListeningDuration(BigInt.from(genre.listenedMs.toInt()))}',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.zinc400,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _AnimatedProgressBar(
            ratio: clamped,
            color: AppTheme.accent500,
            delayMs: index * 30,
            height: 8,
          ),
        ],
      ),
    );
  }
}

class _ListeningRhythmCard extends StatelessWidget {
  const _ListeningRhythmCard({
    required this.stats,
    required this.weekdaysShort,
    required this.wide,
  });

  final UiStatsSummary stats;
  final List<String> weekdaysShort;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    var maxHourMs = 1;
    for (final v in stats.hourlyMs) {
      final val = v.toInt();
      if (val > maxHourMs) maxHourMs = val;
    }

    var maxWdayMs = 1;
    for (final v in stats.weekdayMs) {
      final val = v.toInt();
      if (val > maxWdayMs) maxWdayMs = val;
    }

    var maxMonthMs = 1;
    for (final m in stats.monthly) {
      final val = m.listenedMs.toInt();
      if (val > maxMonthMs) maxMonthMs = val;
    }

    final hoursChart = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          t('Hours of the day').toUpperCase(),
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.7,
            color: AppTheme.zinc400,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 144,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var h = 0; h < 24; h++) ...[
                if (h > 0) const SizedBox(width: 4),
                Expanded(
                  child: _HourlyBar(
                    hour: h,
                    ms: h < stats.hourlyMs.length
                        ? stats.hourlyMs[h].toInt()
                        : 0,
                    maxMs: maxHourMs,
                    delayMs: h * 14,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 6),
        const Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '00:00',
              style: TextStyle(fontSize: 10, color: AppTheme.zinc400),
            ),
            Text(
              '06:00',
              style: TextStyle(fontSize: 10, color: AppTheme.zinc400),
            ),
            Text(
              '12:00',
              style: TextStyle(fontSize: 10, color: AppTheme.zinc400),
            ),
            Text(
              '18:00',
              style: TextStyle(fontSize: 10, color: AppTheme.zinc400),
            ),
            Text(
              '23:00',
              style: TextStyle(fontSize: 10, color: AppTheme.zinc400),
            ),
          ],
        ),
      ],
    );

    final weekdaysChart = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          t('Weekdays').toUpperCase(),
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.7,
            color: AppTheme.zinc400,
          ),
        ),
        const SizedBox(height: 12),
        for (var w = 0; w < 7; w++) ...[
          if (w > 0) const SizedBox(height: 8),
          Builder(
            builder: (context) {
              final wMs = w < stats.weekdayMs.length
                  ? stats.weekdayMs[w].toInt()
                  : 0;
              return Row(
                children: [
                  SizedBox(
                    width: 34,
                    child: Text(
                      t(weekdaysShort[w]),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: AppTheme.zinc400,
                      ),
                    ),
                  ),
                  Expanded(
                    child: _AnimatedProgressBar(
                      ratio: wMs > 0
                          ? (wMs / maxWdayMs).clamp(0.03, 1.0)
                          : 0.0,
                      color: AppTheme.accent500.withValues(alpha: 0.85),
                      delayMs: w * 35,
                      height: 10,
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 72,
                    child: Text(
                      wMs > 0
                          ? formatListeningDuration(BigInt.from(wMs))
                          : '—',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.zinc400,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ],
    );

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
            t('Listening rhythm'),
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppTheme.zinc100,
            ),
          ),
          const SizedBox(height: 18),
          if (wide)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: hoursChart),
                const SizedBox(width: 28),
                Expanded(child: weekdaysChart),
              ],
            )
          else ...[
            hoursChart,
            const SizedBox(height: 24),
            weekdaysChart,
          ],
          if (stats.monthly.isNotEmpty) ...[
            const SizedBox(height: 24),
            const Divider(height: 1, color: AppTheme.zinc800),
            const SizedBox(height: 18),
            Text(
              t('Monthly trend').toUpperCase(),
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.7,
                color: AppTheme.zinc400,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 148,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var m = 0; m < stats.monthly.length; m++) ...[
                    if (m > 0) const SizedBox(width: 8),
                    Expanded(
                      child: _MonthlyBar(
                        stat: stats.monthly[m],
                        maxMs: maxMonthMs,
                        delayMs: m * 24,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _HourlyBar extends StatelessWidget {
  const _HourlyBar({
    required this.hour,
    required this.ms,
    required this.maxMs,
    required this.delayMs,
  });

  final int hour;
  final int ms;
  final int maxMs;
  final int delayMs;

  @override
  Widget build(BuildContext context) {
    final ratio = ms > 0 ? (ms / maxMs).clamp(0.06, 1.0) : 0.03;
    final hh = hour.toString().padLeft(2, '0');
    final tip = '$hh:00 · ${formatListeningDuration(BigInt.from(ms))}';
    return Tooltip(
      message: tip,
      child: _AnimatedVerticalBar(
        ratio: ratio,
        height: 144,
        color: ms > 0
            ? AppTheme.accent500.withValues(alpha: 0.85)
            : AppTheme.zinc800,
        delayMs: delayMs,
      ),
    );
  }
}

class _MonthlyBar extends StatelessWidget {
  const _MonthlyBar({
    required this.stat,
    required this.maxMs,
    required this.delayMs,
  });

  final UiMonthlyStat stat;
  final int maxMs;
  final int delayMs;

  @override
  Widget build(BuildContext context) {
    final ms = stat.listenedMs.toInt();
    final ratio = ms > 0 ? (ms / maxMs).clamp(0.08, 1.0) : 0.04;
    final shortLabel =
        stat.label.length > 2 ? stat.label.substring(2) : stat.label;
    return Tooltip(
      message:
          '${stat.label} · ${formatListeningDuration(BigInt.from(ms))} (${t('{n} plays', {'n': stat.plays})})',
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          _AnimatedVerticalBar(
            ratio: ratio,
            height: 128,
            maxWidth: 40,
            color: AppTheme.accent500.withValues(alpha: 0.85),
            delayMs: delayMs,
          ),
          const SizedBox(height: 6),
          Text(
            shortLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 10,
              color: AppTheme.zinc400,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentActivityCard extends StatelessWidget {
  const _RecentActivityCard({
    required this.events,
    required this.clearing,
    required this.onClearHistory,
    required this.onPlayPath,
    required this.formatShortTime,
    required this.formatTimestamp,
  });

  final List<UiRecentListenEvent> events;
  final bool clearing;
  final VoidCallback onClearHistory;
  final ValueChanged<String> onPlayPath;
  final String Function(PlatformInt64 ms) formatShortTime;
  final String Function(PlatformInt64 epochVal) formatTimestamp;

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
          Row(
            children: [
              Expanded(
                child: Text(
                  t('Recent activity'),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.zinc100,
                  ),
                ),
              ),
              TextButton(
                onPressed: clearing ? null : onClearHistory,
                style: TextButton.styleFrom(
                  foregroundColor: AppTheme.danger,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                ),
                child: Text(
                  t('Clear history'),
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (events.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                t('No listening history for this period yet.'),
                style: const TextStyle(fontSize: 13, color: AppTheme.zinc400),
              ),
            )
          else
            for (var i = 0; i < events.length; i++) ...[
              if (i > 0) const Divider(height: 1, color: AppTheme.zinc800),
              _RecentActivityRow(
                event: events[i],
                onPlayPath: onPlayPath,
                formatShortTime: formatShortTime,
                formatTimestamp: formatTimestamp,
              ),
            ],
        ],
      ),
    );
  }
}

class _RecentActivityRow extends StatefulWidget {
  const _RecentActivityRow({
    required this.event,
    required this.onPlayPath,
    required this.formatShortTime,
    required this.formatTimestamp,
  });

  final UiRecentListenEvent event;
  final ValueChanged<String> onPlayPath;
  final String Function(PlatformInt64 ms) formatShortTime;
  final String Function(PlatformInt64 epochVal) formatTimestamp;

  @override
  State<_RecentActivityRow> createState() => _RecentActivityRowState();
}

class _RecentActivityRowState extends State<_RecentActivityRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ev = widget.event;
    final isLocal =
        !ev.path.startsWith('http://') && !ev.path.startsWith('https://');
    final (statusLabel, statusBg, statusFg) = ev.completed
        ? (
            t('Completed'),
            const Color(0x2610B981),
            const Color(0xFF6EE7B7),
          )
        : ev.skipped
            ? (
                t('Skipped'),
                const Color(0x26F59E0B),
                const Color(0xFFFCD34D),
              )
            : (
                t('Partial'),
                AppTheme.zinc800,
                AppTheme.zinc300,
              );

    return MouseRegion(
      cursor: isLocal ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: isLocal ? () => widget.onPlayPath(ev.path) : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          decoration: BoxDecoration(
            color: _hovered && isLocal
                ? AppTheme.zinc800.withValues(alpha: 0.55)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              CoverArt(
                path: ev.cover,
                size: 36,
                borderRadius: 6,
                iconSize: 14,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ev.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: AppTheme.zinc100,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      ev.album.isNotEmpty
                          ? '${ev.artist.isNotEmpty ? ev.artist : '—'} · ${ev.album}'
                          : (ev.artist.isNotEmpty ? ev.artist : '—'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.zinc400,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (ev.source == 'online') ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0x260EA5E9),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    t('Online'),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF38BDF8),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: statusBg,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  statusLabel,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: statusFg,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 44,
                child: Text(
                  widget.formatShortTime(ev.listenedMs),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.zinc300,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 96,
                child: Text(
                  widget.formatTimestamp(ev.startedAt),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppTheme.zinc400,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Staggered `420ms` `Cubic(0.22, 1, 0.36, 1)` vertical bar matching
/// `@keyframes bar-grow-y` in `src/app.css`.
class _AnimatedVerticalBar extends StatefulWidget {
  const _AnimatedVerticalBar({
    required this.ratio,
    required this.height,
    required this.color,
    this.maxWidth,
    this.delayMs = 0,
  });

  final double ratio;
  final double height;
  final Color color;
  final double? maxWidth;
  final int delayMs;

  @override
  State<_AnimatedVerticalBar> createState() => _AnimatedVerticalBarState();
}

class _AnimatedVerticalBarState extends State<_AnimatedVerticalBar>
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
  void didUpdateWidget(covariant _AnimatedVerticalBar oldWidget) {
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
    final bar = disableAnimations
        ? FractionallySizedBox(
            heightFactor: widget.ratio.clamp(0.0, 1.0),
            alignment: Alignment.bottomCenter,
            child: Container(
              decoration: BoxDecoration(
                color: widget.color,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(3)),
              ),
            ),
          )
        : AnimatedBuilder(
            animation: _progress,
            builder: (context, _) {
              final factor = (widget.ratio * _progress.value).clamp(0.0, 1.0);
              return Align(
                alignment: Alignment.bottomCenter,
                child: FractionallySizedBox(
                  heightFactor: factor,
                  widthFactor: 1.0,
                  child: Container(
                    decoration: BoxDecoration(
                      color: widget.color,
                      borderRadius:
                          const BorderRadius.vertical(top: Radius.circular(3)),
                    ),
                  ),
                ),
              );
            },
          );

    return SizedBox(
      height: widget.height,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: widget.maxWidth ?? double.infinity,
          ),
          child: SizedBox.expand(child: bar),
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
    this.height = 4,
  });

  final double ratio;
  final Color color;
  final int delayMs;
  final double height;

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
        height: widget.height,
        color: AppTheme.zinc800,
        alignment: Alignment.centerLeft,
        child: disableAnimations
            ? FractionallySizedBox(
                widthFactor: widget.ratio,
                child: SizedBox(
                  height: widget.height,
                  child: ColoredBox(color: widget.color),
                ),
              )
            : AnimatedBuilder(
                animation: _progress,
                builder: (context, _) {
                  return FractionallySizedBox(
                    widthFactor:
                        (widget.ratio * _progress.value).clamp(0.0, 1.0),
                    child: SizedBox(
                      height: widget.height,
                      child: ColoredBox(color: widget.color),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
