import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';
import 'package:neomodern/ui/tinted_backdrop.dart';
import 'package:neomodern/ui/track_menu.dart';
import 'package:neomodern/ui/widgets/motion_primitives.dart';
import 'package:neomodern/ui/widgets/smooth_scroll.dart';

enum RightPanelTab { nowPlaying, queue, lyrics }

class RightPanel extends StatefulWidget {
  const RightPanel({
    super.key,
    required this.controller,
    required this.activeTab,
    required this.onTabChanged,
    required this.onClose,
    this.onOpenArtist,
    this.onOpenAlbum,
    this.width = 340,
  });

  final PlayerController controller;
  final RightPanelTab activeTab;
  final ValueChanged<RightPanelTab> onTabChanged;
  final VoidCallback onClose;
  final ValueChanged<String>? onOpenArtist;
  final ValueChanged<PlatformInt64>? onOpenAlbum;
  final double width;

  @override
  State<RightPanel> createState() => _RightPanelState();
}

class _RightPanelState extends State<RightPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _enterController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );

  late final Animation<double> _fade = CurvedAnimation(
    parent: _enterController,
    curve: Curves.easeOut,
  );

  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0.03, 0),
    end: Offset.zero,
  ).animate(
    CurvedAnimation(
      parent: _enterController,
      curve: Curves.easeOutCubic,
    ),
  );

  @override
  void initState() {
    super.initState();
    _enterController.forward();
  }

  @override
  void dispose() {
    _enterController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    Widget panel = Container(
      width: widget.width,
      decoration: BoxDecoration(
        color: AppTheme.zinc900.withValues(alpha: 0.50),
        border: Border(
          left: BorderSide(color: AppTheme.zinc800.withValues(alpha: 0.80)),
        ),
      ),
      child: switch (widget.activeTab) {
        RightPanelTab.nowPlaying => _NowPlayingSide(
            controller: widget.controller,
            onShowLyrics: () => widget.onTabChanged(RightPanelTab.lyrics),
            onOpenQueue: () => widget.onTabChanged(RightPanelTab.queue),
            onClose: widget.onClose,
            onOpenArtist: widget.onOpenArtist,
            onOpenAlbum: widget.onOpenAlbum,
          ),
        RightPanelTab.queue => _QueueSide(
            controller: widget.controller,
            onClose: widget.onClose,
            onOpenArtist: widget.onOpenArtist,
            onOpenAlbum: widget.onOpenAlbum,
          ),
        RightPanelTab.lyrics => _LyricsSide(
            controller: widget.controller,
            onClose: widget.onClose,
          ),
      },
    );

    if (!disableAnimations) {
      panel = FadeTransition(
        opacity: _fade,
        child: SlideTransition(
          position: _slide,
          child: panel,
        ),
      );
    }

    return panel;
  }
}

class _NowPlayingSide extends StatefulWidget {
  const _NowPlayingSide({
    required this.controller,
    required this.onShowLyrics,
    required this.onOpenQueue,
    required this.onClose,
    this.onOpenArtist,
    this.onOpenAlbum,
  });

  final PlayerController controller;
  final VoidCallback onShowLyrics;
  final VoidCallback onOpenQueue;
  final VoidCallback onClose;
  final ValueChanged<String>? onOpenArtist;
  final ValueChanged<PlatformInt64>? onOpenAlbum;

  @override
  State<_NowPlayingSide> createState() => _NowPlayingSideState();
}

class _NowPlayingSideState extends State<_NowPlayingSide> {
  bool _nextHovered = false;
  bool _showLyricsHovered = false;

  int _findActiveIndex(List<UiSyncedLine> lines, double posSeconds) {
    final posMs = (posSeconds * 1000).round();
    var active = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].timeMs.toInt() <= posMs) {
        active = i;
      } else {
        break;
      }
    }
    return active;
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final snap = ctrl.snapshot;
    final cur = snap.current;
    final currentRow = ctrl.currentTrackRow;
    final albumTitle = (currentRow != null && currentRow.album.isNotEmpty)
        ? currentRow.album
        : t('Now Playing');
    final albumId = currentRow?.albumId;

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 6),
      child: Row(
        children: [
          Expanded(
            child: HoverLinkText(
              text: albumTitle,
              onTap: albumId != null && widget.onOpenAlbum != null
                  ? () => widget.onOpenAlbum!(albumId)
                  : null,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppTheme.zinc100,
              ),
            ),
          ),
          IconButton(
            tooltip: t('Close panel'),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            icon: const Icon(
              Icons.close_rounded,
              size: 18,
              color: AppTheme.zinc400,
            ),
            onPressed: widget.onClose,
          ),
        ],
      ),
    );

    if (cur == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  t('Nothing playing'),
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(color: AppTheme.zinc400, fontSize: 13.5),
                ),
              ),
            ),
          ),
        ],
      );
    }

    final tint = tintFromColor(ctrl.currentCoverColor);
    final isLocalTrack =
        !cur.path.startsWith('http://') && !cur.path.startsWith('https://');
    final lyrics = ctrl.currentLyrics;
    final hasLyrics = lyrics != null &&
        lyrics.found &&
        !lyrics.isInstrumental &&
        (lyrics.syncedLines.isNotEmpty ||
            (lyrics.plainText?.trim().isNotEmpty ?? false));
    final next = snap.nextTrack;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Expanded(
          child: SmoothScrollWrapper(
            builder: (context, scrollController) => ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
              children: [
                Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.40),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: AspectRatio(
            aspectRatio: 1,
            child: CoverArt(
              path: ctrl.currentCoverPath,
              borderRadius: 12,
              iconSize: 64,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  HoverLinkText(
                    text: cur.title,
                    maxLines: 2,
                    onTap: currentRow?.albumId != null &&
                            widget.onOpenAlbum != null
                        ? () => widget.onOpenAlbum!(currentRow!.albumId!)
                        : null,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      height: 1.25,
                      color: AppTheme.zinc50,
                    ),
                  ),
                  const SizedBox(height: 3),
                  HoverLinkText(
                    text: cur.artist.isNotEmpty
                        ? cur.artist
                        : t('Unknown Artist'),
                    onTap: cur.artist.isNotEmpty && widget.onOpenArtist != null
                        ? () => widget.onOpenArtist!(cur.artist)
                        : null,
                    style: const TextStyle(
                      fontSize: 14,
                      color: AppTheme.zinc400,
                    ),
                  ),
                ],
              ),
            ),
            if (isLocalTrack) ...[
              const SizedBox(width: 8),
              AnimatedSaveButton(
                isSaved: ctrl.isCurrentFavorite,
                size: 20,
                onPressed: ctrl.toggleCurrentFavorite,
              ),
            ],
          ],
        ),
        if (hasLyrics) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: tint.surface,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.20),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text(
                      t('Lyrics preview'),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.white.withValues(alpha: 0.90),
                      ),
                    ),
                    const Spacer(),
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      onEnter: (_) => setState(() => _showLyricsHovered = true),
                      onExit: (_) => setState(() => _showLyricsHovered = false),
                      child: GestureDetector(
                        onTap: widget.onShowLyrics,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: _showLyricsHovered
                                ? Colors.black.withValues(alpha: 0.40)
                                : Colors.black.withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(9999),
                          ),
                          child: Text(
                            t('Show lyrics'),
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.white.withValues(alpha: 0.92),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onShowLyrics,
                  child: _LyricsPreviewLines(
                    lyrics: lyrics,
                    positionNotifier: ctrl.positionNotifier,
                    dimColor: tint.dim,
                    findActiveIndex: _findActiveIndex,
                  ),
                ),
              ],
            ),
          ),
        ],
        if (next != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.zinc900.withValues(alpha: 0.90),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.zinc800),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text(
                      t('Next in queue'),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.zinc100,
                      ),
                    ),
                    const Spacer(),
                    HoverLinkText(
                      text: t('Open queue'),
                      onTap: widget.onOpenQueue,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.zinc400,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  onEnter: (_) => setState(() => _nextHovered = true),
                  onExit: (_) => setState(() => _nextHovered = false),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: ctrl.next,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: _nextHovered
                            ? AppTheme.zinc800.withValues(alpha: 0.80)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 48,
                            height: 48,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                CoverArt(
                                  path: ctrl.trackCoverCached(next.path),
                                  size: 48,
                                  borderRadius: 6,
                                  iconSize: 20,
                                ),
                                AnimatedOpacity(
                                  opacity: _nextHovered ? 1.0 : 0.0,
                                  duration: const Duration(milliseconds: 150),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color:
                                          Colors.black.withValues(alpha: 0.50),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    alignment: Alignment.center,
                                    child: const Icon(
                                      Icons.play_arrow_rounded,
                                      size: 22,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  next.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: AppTheme.zinc100,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  next.artist.isNotEmpty
                                      ? next.artist
                                      : t('Unknown Artist'),
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
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
            ),
          ),
        ),
      ],
    );
  }
}

class _LyricsPreviewLines extends StatelessWidget {
  const _LyricsPreviewLines({
    required this.lyrics,
    required this.positionNotifier,
    required this.dimColor,
    required this.findActiveIndex,
  });

  final UiLyrics lyrics;
  final ValueNotifier<double> positionNotifier;
  final Color dimColor;
  final int Function(List<UiSyncedLine>, double) findActiveIndex;

  @override
  Widget build(BuildContext context) {
    if (lyrics.syncedLines.isEmpty) {
      final plainLines = (lyrics.plainText ?? '')
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .take(4)
          .toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < plainLines.length; i++) ...[
            if (i > 0) const SizedBox(height: 6),
            Text(
              plainLines[i],
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                height: 1.35,
                fontWeight: FontWeight.w700,
                color: i == 0 ? Colors.white : dimColor,
              ),
            ),
          ],
        ],
      );
    }

    return ValueListenableBuilder<double>(
      valueListenable: positionNotifier,
      builder: (context, pos, _) {
        final lines = lyrics.syncedLines;
        final activeIdx = findActiveIndex(lines, pos);
        final start = activeIdx < 0 ? 0 : activeIdx;
        final end = (start + 4).clamp(0, lines.length);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = start; i < end; i++) ...[
              if (i > start) const SizedBox(height: 6),
              Text(
                lines[i].text.trim().isEmpty ? '♪' : lines[i].text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.35,
                  fontWeight: FontWeight.w700,
                  color: (activeIdx >= 0 && i == activeIdx)
                      ? Colors.white
                      : dimColor,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _LyricsSide extends StatefulWidget {
  const _LyricsSide({
    required this.controller,
    required this.onClose,
  });

  final PlayerController controller;
  final VoidCallback onClose;

  @override
  State<_LyricsSide> createState() => _LyricsSideState();
}

class _LyricsSideState extends State<_LyricsSide> {
  final SmoothScrollController _scrollCtrl = SmoothScrollController();
  List<GlobalKey> _lineKeys = const [];
  String? _lastKeyedTrack;
  int _lastKeyCount = 0;
  int _lastActiveIdx = -1;
  bool _follow = true;
  bool _sharingLyrics = false;

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _ensureKeys(String? path, int count) {
    if (path != _lastKeyedTrack || count != _lastKeyCount) {
      _lastKeyedTrack = path;
      _lastKeyCount = count;
      _lastActiveIdx = -1;
      _follow = true;
      _lineKeys = List.generate(count, (_) => GlobalKey());
    }
  }

  void _scrollToActive(int idx, {bool force = false}) {
    if (!_follow && !force) return;
    if (idx < 0 || idx >= _lineKeys.length) return;
    if (!force && idx == _lastActiveIdx) return;
    _lastActiveIdx = idx;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _lineKeys[idx].currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.35,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  int _findActiveIndex(List<UiSyncedLine> lines, double posSeconds) {
    final posMs = (posSeconds * 1000).round();
    var active = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].timeMs.toInt() <= posMs) {
        active = i;
      } else {
        break;
      }
    }
    return active;
  }

  String _formatLrcContent(UiLyrics lyrics) {
    if (lyrics.syncedLines.isNotEmpty) {
      final buf = StringBuffer();
      for (final line in lyrics.syncedLines) {
        final msTotal = line.timeMs.toInt().clamp(0, 359999999);
        final mins = msTotal ~/ 60000;
        final secs = (msTotal % 60000) ~/ 1000;
        final hundredths = (msTotal % 1000) ~/ 10;
        buf.writeln(
          '[${mins.toString().padLeft(2, '0')}:'
          '${secs.toString().padLeft(2, '0')}.'
          '${hundredths.toString().padLeft(2, '0')}]${line.text}',
        );
      }
      return buf.toString();
    }
    return lyrics.plainText ?? '';
  }

  Future<void> _saveLrc(
    BuildContext context,
    PlayerController ctrl,
    String trackPath,
    UiLyrics lyrics,
  ) async {
    final content = _formatLrcContent(lyrics).trim();
    if (content.isEmpty) return;
    try {
      final savedPath = await ctrl.saveCurrentLyricsLrc(trackPath, content);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t('Saved .lrc to {path}', {'path': savedPath})),
          behavior: SnackBarBehavior.floating,
          width: 360,
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString()),
          behavior: SnackBarBehavior.floating,
          width: 360,
        ),
      );
    }
  }

  Future<void> _attachLrcFile(
    BuildContext context,
    PlayerController ctrl,
    String audioPath,
  ) async {
    final files = await FilePicker.pickFiles(
      dialogTitle: t('Attach .lrc file'),
      type: FileType.custom,
      allowedExtensions: const ['lrc', 'txt'],
    );
    if (files.isEmpty) return;
    final lrcPath = files.first.path;
    if (lrcPath == null || lrcPath.isEmpty) return;
    await ctrl.attachLyricsFile(audioPath, lrcPath);
    if (!context.mounted) return;
    final err = ctrl.lastError;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          err ?? t('Attached .lrc file'),
        ),
        behavior: SnackBarBehavior.floating,
        width: 340,
      ),
    );
  }

  Future<void> _shareLyrics(
    BuildContext context,
    PlayerController ctrl,
  ) async {
    if (_sharingLyrics) return;
    setState(() => _sharingLyrics = true);
    try {
      await ctrl.shareLyrics();
      if (!context.mounted) return;
      final status = ctrl.lyricsShareStatus;
      final msg = switch (status?.outcome) {
        'published' => t('Shared lyrics to LRCLIB'),
        'cancelled' => t('Lyrics sharing cancelled'),
        _ => ctrl.lastError ??
            (status?.reason != null
                ? t('Cannot share lyrics: {reason}', {'reason': status!.reason!})
                : t('Lyrics share finished')),
      };
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          width: 340,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _sharingLyrics = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final current = ctrl.snapshot.current;

    if (current == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 10, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    t('Lyrics'),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.zinc100,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: t('Close panel'),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: AppTheme.zinc400,
                  ),
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  t('Play a track to view lyrics.'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppTheme.zinc400, fontSize: 13),
                ),
              ),
            ),
          ),
        ],
      );
    }

    final tint = tintFromColor(ctrl.currentCoverColor);
    final isLocalTrack = !current.path.startsWith('http://') &&
        !current.path.startsWith('https://');
    final lyrics = ctrl.currentLyrics;
    final canSaveLrc = isLocalTrack &&
        lyrics != null &&
        lyrics.found &&
        !lyrics.isInstrumental &&
        lyrics.source != 'Local .lrc' &&
        (lyrics.syncedLines.isNotEmpty ||
            (lyrics.plainText?.trim().isNotEmpty ?? false));

    return TintedBackdrop.solid(
      color: tint.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          current.artist.isNotEmpty
                              ? '${current.title} · ${current.artist}'
                              : current.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.white.withValues(alpha: 0.90),
                          ),
                        ),
                      ),
                      if (lyrics?.source != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            lyrics!.source!,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: Colors.white.withValues(alpha: 0.80),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                if (canSaveLrc)
                  IconButton(
                    tooltip: t('Save .lrc'),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    icon: Icon(
                      Icons.save_alt_rounded,
                      size: 17,
                      color: Colors.white.withValues(alpha: 0.80),
                    ),
                    onPressed: () =>
                        _saveLrc(context, ctrl, current.path, lyrics),
                  ),
                if (isLocalTrack)
                  IconButton(
                    tooltip: t('Attach .lrc file'),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    icon: Icon(
                      Icons.attach_file_rounded,
                      size: 17,
                      color: Colors.white.withValues(alpha: 0.80),
                    ),
                    onPressed: () =>
                        _attachLrcFile(context, ctrl, current.path),
                  ),
                if (isLocalTrack)
                  IconButton(
                    tooltip: t('Share lyrics to LRCLIB'),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    icon: _sharingLyrics
                        ? SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white.withValues(alpha: 0.80),
                            ),
                          )
                        : Icon(
                            Icons.cloud_upload_outlined,
                            size: 17,
                            color: Colors.white.withValues(alpha: 0.80),
                          ),
                    onPressed: _sharingLyrics
                        ? null
                        : () => _shareLyrics(context, ctrl),
                  ),
                IconButton(
                  tooltip: t('Refresh lyrics'),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: Icon(
                    Icons.refresh_rounded,
                    size: 17,
                    color: Colors.white.withValues(alpha: 0.80),
                  ),
                  onPressed:
                      ctrl.lyricsLoading ? null : ctrl.refreshLyricsForCurrent,
                ),
                IconButton(
                  tooltip: t('Close panel'),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: Colors.white.withValues(alpha: 0.80),
                  ),
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
          Expanded(
            child: _buildLyricsBody(ctrl, current.path, lyrics, tint),
          ),
        ],
      ),
    );
  }

  Widget _buildLyricsBody(
    PlayerController ctrl,
    String path,
    UiLyrics? lyrics,
    CoverTint tint,
  ) {
    if (ctrl.lyricsLoading && lyrics == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    if (lyrics == null || !lyrics.found) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lyrics_outlined,
                size: 36,
                color: tint.dim,
              ),
              const SizedBox(height: 10),
              Text(
                ctrl.offlineMode
                    ? t('No local lyrics found (Offline Mode is on).')
                    : t('No lyrics found for this track.'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.white.withValues(alpha: 0.80),
                ),
              ),
              const SizedBox(height: 14),
              TextButton.icon(
                onPressed: ctrl.lyricsLoading ? null : ctrl.refreshLyrics,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor: Colors.black.withValues(alpha: 0.25),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                ),
                icon: const Icon(Icons.refresh_rounded, size: 15),
                label: Text(t('Retry')),
              ),
            ],
          ),
        ),
      );
    }

    if (lyrics.isInstrumental) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '♪ ${t('Instrumental')}',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: tint.dim,
            ),
          ),
        ),
      );
    }

    if (lyrics.syncedLines.isNotEmpty) {
      final lines = lyrics.syncedLines;
      _ensureKeys(path, lines.length);

      return ValueListenableBuilder<double>(
        valueListenable: ctrl.positionNotifier,
        builder: (context, pos, _) {
          final activeIdx = _findActiveIndex(lines, pos);
          if (activeIdx >= 0 && _follow) {
            _scrollToActive(activeIdx);
          }

          return Stack(
            children: [
              Listener(
                onPointerSignal: (event) {
                  if (event is PointerScrollEvent && _follow) {
                    setState(() => _follow = false);
                  }
                },
                child: NotificationListener<UserScrollNotification>(
                  onNotification: (notification) {
                    if (_follow) {
                      setState(() => _follow = false);
                    }
                    return false;
                  },
                  child: ShaderMask(
                    shaderCallback: (bounds) => const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black,
                        Colors.black,
                        Colors.transparent,
                      ],
                      stops: [0.0, 0.05, 0.88, 1.0],
                    ).createShader(bounds),
                    blendMode: BlendMode.dstIn,
                    child: SmoothScrollWrapper(
                      controller: _scrollCtrl,
                      child: ListView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.fromLTRB(18, 22, 18, 140),
                      itemCount: lines.length,
                      itemBuilder: (context, index) {
                        final line = lines[index];
                        final isActive = index == activeIdx;
                        final isPast = activeIdx >= 0 && index < activeIdx;
                        final isBlank = line.text.trim().isEmpty;
                        final display = isBlank ? '♪' : line.text;

                        final color = isActive
                            ? Colors.white
                            : isPast
                                ? Colors.white.withValues(alpha: 0.50)
                                : tint.dim;

                        return Padding(
                          key: _lineKeys[index],
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                setState(() => _follow = true);
                                unawaited(
                                  ctrl.seek(line.timeMs.toInt() / 1000.0),
                                );
                              },
                              child: AnimatedScale(
                                scale: isActive && !isBlank ? 1.02 : 1.0,
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeOutCubic,
                                alignment: Alignment.centerLeft,
                                child: AnimatedDefaultTextStyle(
                                  duration: const Duration(milliseconds: 300),
                                  style: TextStyle(
                                    fontSize: isBlank ? 18 : 24,
                                    height: 1.24,
                                    fontWeight: FontWeight.w700,
                                    color: color,
                                  ),
                                  child: Text(display),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 14,
                child: Center(
                  child: AnimatedSlide(
                    offset: _follow ? const Offset(0, 1.5) : Offset.zero,
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    child: AnimatedOpacity(
                      opacity: _follow ? 0.0 : 1.0,
                      duration: const Duration(milliseconds: 180),
                      child: IgnorePointer(
                        ignoring: _follow,
                        child: Material(
                          color: Colors.white,
                          elevation: 8,
                          borderRadius: BorderRadius.circular(9999),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(9999),
                            onTap: () {
                              setState(() => _follow = true);
                              if (activeIdx >= 0) {
                                _scrollToActive(activeIdx, force: true);
                              }
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              child: Text(
                                t('Sync'),
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.zinc950,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );
    }

    final plainLines = (lyrics.plainText ?? '').split('\n');
    return ShaderMask(
      shaderCallback: (bounds) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.transparent,
          Colors.black,
          Colors.black,
          Colors.transparent,
        ],
        stops: [0.0, 0.05, 0.88, 1.0],
      ).createShader(bounds),
      blendMode: BlendMode.dstIn,
      child: SmoothScrollWrapper(
        builder: (context, scrollController) => ListView.builder(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(18, 22, 18, 36),
          itemCount: plainLines.length,
          itemBuilder: (context, index) {
            final line = plainLines[index].trim();
            if (line.isEmpty) {
              return const SizedBox(height: 12);
            }
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: SelectableText(
                line,
                style: const TextStyle(
                  fontSize: 22,
                  height: 1.32,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

enum _QueueSubTab { queue, recent }

class _QueueSide extends StatefulWidget {
  const _QueueSide({
    required this.controller,
    required this.onClose,
    this.onOpenArtist,
    this.onOpenAlbum,
  });

  final PlayerController controller;
  final VoidCallback onClose;
  final ValueChanged<String>? onOpenArtist;
  final ValueChanged<PlatformInt64>? onOpenAlbum;

  @override
  State<_QueueSide> createState() => _QueueSideState();
}

class _QueueSideState extends State<_QueueSide> {
  _QueueSubTab _subTab = _QueueSubTab.queue;
  List<UiRecentListenEvent>? _fallbackRecent;
  bool _loadingRecent = false;

  void _selectSubTab(_QueueSubTab next) {
    if (_subTab == next) return;
    setState(() => _subTab = next);
    if (next == _QueueSubTab.recent) {
      unawaited(_ensureRecentLoaded());
    }
  }

  Future<void> _ensureRecentLoaded() async {
    final ctrl = widget.controller;
    final homeRecent = ctrl.homeFeed?.recentlyPlayedTracks;
    if ((homeRecent != null && homeRecent.isNotEmpty) || !ctrl.initialized) {
      return;
    }
    setState(() => _loadingRecent = true);
    try {
      final summary = await ctrl.fetchStatsRange();
      if (mounted) {
        setState(() {
          _fallbackRecent = summary.recentEvents.take(30).toList();
          _loadingRecent = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loadingRecent = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 10, 0),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: AppTheme.zinc800.withValues(alpha: 0.80),
              ),
            ),
          ),
          child: Row(
            children: [
              _QueueTabHeaderButton(
                label: t('Queue'),
                active: _subTab == _QueueSubTab.queue,
                onTap: () => _selectSubTab(_QueueSubTab.queue),
              ),
              const SizedBox(width: 16),
              _QueueTabHeaderButton(
                label: t('Recently played'),
                active: _subTab == _QueueSubTab.recent,
                onTap: () => _selectSubTab(_QueueSubTab.recent),
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: IconButton(
                  tooltip: t('Close panel'),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: AppTheme.zinc400,
                  ),
                  onPressed: widget.onClose,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _subTab == _QueueSubTab.queue
              ? _buildQueueBody(ctrl)
              : _buildRecentBody(ctrl),
        ),
      ],
    );
  }

  Widget _buildQueueBody(PlayerController controller) {
    final snap = controller.snapshot;
    final count = snap.queueLength;
    final currentIndex = snap.currentIndex;

    if (count == 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            t('Queue is empty.'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppTheme.zinc400,
              fontSize: 13.5,
            ),
          ),
        ),
      );
    }

    final upNextStart = currentIndex != null ? currentIndex + 1 : 0;
    final upNextCount = (count - upNextStart).clamp(0, count);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 6),
          child: Row(
            children: [
              Text(
                t('Queue ({n})', {'n': count}),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.zinc400,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: controller.clearQueuedTracks,
                style: TextButton.styleFrom(
                  foregroundColor: AppTheme.zinc400,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 28),
                ),
                child: Text(
                  t('Clear Added'),
                  style: const TextStyle(fontSize: 11.5),
                ),
              ),
            ],
          ),
        ),
        if (snap.current != null) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
            child: Text(
              t('Now playing'),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppTheme.zinc400,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Container(
              height: 56,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: AppTheme.accent950.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  CoverArt(
                    path: controller.currentCoverPath,
                    size: 40,
                    borderRadius: 4,
                    iconSize: 18,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          snap.current!.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: AppTheme.accent400,
                          ),
                        ),
                        const SizedBox(height: 1),
                        HoverLinkText(
                          text: snap.current!.artist.isNotEmpty
                              ? snap.current!.artist
                              : t('Unknown Artist'),
                          onTap: snap.current!.artist.isNotEmpty &&
                                  widget.onOpenArtist != null
                              ? () => widget.onOpenArtist!(snap.current!.artist)
                              : null,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.zinc400,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (controller.isPlaying) ...[
                    const SizedBox(width: 8),
                    const EqualizerIndicator(
                      playing: true,
                      color: AppTheme.accent400,
                      height: 14,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
          child: Text(
            t('Next up'),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppTheme.zinc400,
            ),
          ),
        ),
        Expanded(
          child: upNextCount == 0
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
                  child: Text(
                    t('Nothing after this song.'),
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.zinc500,
                    ),
                  ),
                )
              : SmoothScrollWrapper(
                  builder: (context, scrollController) =>
                      ReorderableListView.builder(
                    scrollController: scrollController,
                    buildDefaultDragHandles: false,
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                    itemCount: upNextCount,
                    itemExtent: 56,
                    onReorderItem: (oldIdx, newIdx) {
                      final from = upNextStart + oldIdx;
                      final to = upNextStart + newIdx;
                      controller.moveQueueItem(from, to);
                    },
                    itemBuilder: (context, localIdx) {
                      final queueIdx = upNextStart + localIdx;
                      final item = controller.queueTrackAt(queueIdx);
                      if (item == null) {
                        return Padding(
                          key: ValueKey('queue-loading-$queueIdx'),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              t('Loading...'),
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.zinc500,
                              ),
                            ),
                          ),
                        );
                      }
                      return _QueueUpNextRow(
                        key: ValueKey('queue-${item.id}-$queueIdx'),
                        dragIndex: localIdx,
                        item: item,
                        coverPath: controller.trackCoverCached(item.path),
                        onPlay: () => controller.playIndex(queueIdx),
                        onRemove: () => controller.removeFromQueue(queueIdx),
                        onOpenArtist: widget.onOpenArtist,
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildRecentBody(PlayerController ctrl) {
    final homeRecent = ctrl.homeFeed?.recentlyPlayedTracks ?? const [];
    if (_loadingRecent && homeRecent.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (homeRecent.isNotEmpty) {
      return SmoothScrollWrapper(
        builder: (context, scrollController) => ListView.builder(
          controller: scrollController,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          itemCount: homeRecent.length,
          itemExtent: 56,
          itemBuilder: (context, index) {
            final row = homeRecent[index].track;
            return _RecentSideRow(
              title: row.title,
              artist: row.artist,
              coverPath: row.cover,
              path: row.path,
              track: row,
              controller: ctrl,
              onPlay: () => ctrl.playTracks([row.path], 0),
              onOpenArtist: widget.onOpenArtist,
              onOpenAlbum: widget.onOpenAlbum,
            );
          },
        ),
      );
    }

    final events = _fallbackRecent ?? const [];
    if (events.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            t('Nothing playing.'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppTheme.zinc400,
              fontSize: 13.5,
            ),
          ),
        ),
      );
    }

    return SmoothScrollWrapper(
      builder: (context, scrollController) => ListView.builder(
        controller: scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        itemCount: events.length,
        itemExtent: 56,
        itemBuilder: (context, index) {
          final ev = events[index];
          final isLocal =
              !ev.path.startsWith('http://') && !ev.path.startsWith('https://');
          final fallbackRow = UiTrackRow(
            id: ev.trackId ?? -1,
            title: ev.title,
            artist: ev.artist,
            album: ev.album,
            path: ev.path,
            cover: ev.cover,
            plays: 0,
          );
          return _RecentSideRow(
            title: ev.title,
            artist: ev.artist,
            coverPath: ev.cover,
            path: ev.path,
            track: fallbackRow,
            controller: ctrl,
            onPlay: isLocal ? () => ctrl.playTracks([ev.path], 0) : null,
            onOpenArtist: widget.onOpenArtist,
            onOpenAlbum: widget.onOpenAlbum,
          );
        },
      ),
    );
  }
}

class _QueueTabHeaderButton extends StatefulWidget {
  const _QueueTabHeaderButton({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_QueueTabHeaderButton> createState() => _QueueTabHeaderButtonState();
}

class _QueueTabHeaderButtonState extends State<_QueueTabHeaderButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                width: 2,
                color:
                    widget.active ? AppTheme.accent500 : Colors.transparent,
              ),
            ),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
              color: widget.active
                  ? Colors.white
                  : (_hovered ? AppTheme.zinc200 : AppTheme.zinc400),
            ),
          ),
        ),
      ),
    );
  }
}

class _RecentSideRow extends StatefulWidget {
  const _RecentSideRow({
    required this.title,
    required this.artist,
    required this.coverPath,
    required this.path,
    required this.track,
    required this.controller,
    required this.onPlay,
    this.onOpenArtist,
    this.onOpenAlbum,
  });

  final String title;
  final String artist;
  final String? coverPath;
  final String path;
  final UiTrackRow track;
  final PlayerController controller;
  final VoidCallback? onPlay;
  final ValueChanged<String>? onOpenArtist;
  final ValueChanged<PlatformInt64>? onOpenAlbum;

  @override
  State<_RecentSideRow> createState() => _RecentSideRowState();
}

class _RecentSideRowState extends State<_RecentSideRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.onPlay != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPlay,
        onSecondaryTapDown: (d) => TrackMenu.show(
          context: context,
          globalPosition: d.globalPosition,
          track: widget.track,
          controller: widget.controller,
          onPlay: widget.onPlay,
          onOpenArtist: widget.onOpenArtist,
          onOpenAlbum: widget.onOpenAlbum,
        ),
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: _hovered
                ? AppTheme.zinc800.withValues(alpha: 0.60)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              CoverArt(
                path: widget.coverPath,
                size: 40,
                borderRadius: 4,
                iconSize: 16,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    HoverLinkText(
                      text: widget.title,
                      onTap: widget.track.albumId != null &&
                              widget.onOpenAlbum != null
                          ? () => widget.onOpenAlbum!(widget.track.albumId!)
                          : widget.onPlay,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: AppTheme.zinc200,
                      ),
                    ),
                    const SizedBox(height: 1),
                    HoverLinkText(
                      text: widget.artist.isNotEmpty
                          ? widget.artist
                          : t('Unknown Artist'),
                      onTap: widget.artist.isNotEmpty &&
                              widget.onOpenArtist != null
                          ? () => widget.onOpenArtist!(widget.artist)
                          : null,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.zinc400,
                      ),
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

class _QueueUpNextRow extends StatefulWidget {
  const _QueueUpNextRow({
    super.key,
    required this.dragIndex,
    required this.item,
    required this.coverPath,
    required this.onPlay,
    required this.onRemove,
    this.onOpenArtist,
  });

  final int dragIndex;
  final UiTrackInfo item;
  final String? coverPath;
  final VoidCallback onPlay;
  final VoidCallback onRemove;
  final ValueChanged<String>? onOpenArtist;

  @override
  State<_QueueUpNextRow> createState() => _QueueUpNextRowState();
}

class _QueueUpNextRowState extends State<_QueueUpNextRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Material(
        color: Colors.transparent,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPlay,
          child: Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: _hovered
                  ? AppTheme.zinc800.withValues(alpha: 0.60)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                ReorderableDragStartListener(
                  index: widget.dragIndex,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.grab,
                      child: CoverArt(
                        path: widget.coverPath,
                        size: 40,
                        borderRadius: 4,
                        iconSize: 16,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: AppTheme.zinc200,
                        ),
                      ),
                      const SizedBox(height: 1),
                      HoverLinkText(
                        text: item.artist.isNotEmpty
                            ? item.artist
                            : t('Unknown Artist'),
                        onTap: item.artist.isNotEmpty &&
                                widget.onOpenArtist != null
                            ? () => widget.onOpenArtist!(item.artist)
                            : null,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppTheme.zinc400,
                        ),
                      ),
                    ],
                  ),
                ),
                if (item.queued)
                  Container(
                    margin: const EdgeInsets.only(right: 4),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.zinc900,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: AppTheme.zinc800),
                    ),
                    child: const Text(
                      'Q',
                      style: TextStyle(
                        fontSize: 10,
                        color: AppTheme.accent400,
                      ),
                    ),
                  ),
                AnimatedOpacity(
                  opacity: _hovered ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 120),
                  child: IgnorePointer(
                    ignoring: !_hovered,
                    child: IconButton(
                      tooltip: t('Remove from queue'),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 26,
                        minHeight: 26,
                      ),
                      icon: const Icon(
                        Icons.close_rounded,
                        size: 16,
                        color: AppTheme.zinc400,
                      ),
                      onPressed: widget.onRemove,
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
