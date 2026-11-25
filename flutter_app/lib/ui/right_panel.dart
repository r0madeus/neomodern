import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';
import 'package:neomodern/ui/tinted_backdrop.dart';

enum RightPanelTab { lyrics, queue }

class RightPanel extends StatelessWidget {
  const RightPanel({
    super.key,
    required this.controller,
    required this.activeTab,
    required this.onTabChanged,
    required this.onClose,
    this.width = 328,
  });

  final PlayerController controller;
  final RightPanelTab activeTab;
  final ValueChanged<RightPanelTab> onTabChanged;
  final VoidCallback onClose;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      decoration: const BoxDecoration(
        color: AppColors.sidebar,
        border: Border(left: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TintedBackdrop(
            tintColor: controller.currentCoverColor,
            baseColor: AppColors.sidebar,
            tintAlpha: 64,
            child: Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: AppColors.border)),
              ),
              child: Row(
                children: [
                  _PanelTabButton(
                    icon: Icons.lyrics_rounded,
                    label: t('Lyrics'),
                    active: activeTab == RightPanelTab.lyrics,
                    onTap: () => onTabChanged(RightPanelTab.lyrics),
                  ),
                  const SizedBox(width: 4),
                  _PanelTabButton(
                    icon: Icons.queue_music_rounded,
                    label: t('Queue'),
                    active: activeTab == RightPanelTab.queue,
                    onTap: () => onTabChanged(RightPanelTab.queue),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: t('Close panel'),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: AppColors.textSecondary,
                    ),
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: activeTab == RightPanelTab.lyrics
                ? _LyricsTab(controller: controller)
                : _QueueTab(controller: controller),
          ),
        ],
      ),
    );
  }
}

class _PanelTabButton extends StatelessWidget {
  const _PanelTabButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? AppColors.accentMuted : Colors.transparent,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        hoverColor: active ? AppColors.accentMuted : AppColors.surfaceHover,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            children: [
              Icon(
                icon,
                size: 16,
                color: active ? AppColors.accent : AppColors.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color: active ? AppColors.accent : AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LyricsTab extends StatefulWidget {
  const _LyricsTab({required this.controller});

  final PlayerController controller;

  @override
  State<_LyricsTab> createState() => _LyricsTabState();
}

class _LyricsTabState extends State<_LyricsTab> {
  final ScrollController _scrollCtrl = ScrollController();
  List<GlobalKey> _lineKeys = const [];
  String? _lastKeyedTrack;
  int _lastKeyCount = 0;
  int _lastActiveIdx = -1;

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
      _lineKeys = List.generate(count, (_) => GlobalKey());
    }
  }

  void _scrollToActive(int idx) {
    if (idx < 0 || idx >= _lineKeys.length || idx == _lastActiveIdx) return;
    _lastActiveIdx = idx;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _lineKeys[idx].currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.38,
          duration: const Duration(milliseconds: 220),
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

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final current = ctrl.snapshot.current;

    if (current == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            t('Play a track to view lyrics.'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
        ),
      );
    }

    final lyrics = ctrl.currentLyrics;
    final canSaveLrc = lyrics != null &&
        lyrics.found &&
        !lyrics.isInstrumental &&
        lyrics.source != 'Local .lrc' &&
        (lyrics.syncedLines.isNotEmpty ||
            (lyrics.plainText?.trim().isNotEmpty ?? false)) &&
        !current.path.startsWith('http://') &&
        !current.path.startsWith('https://');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      current.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      current.artist.isNotEmpty
                          ? current.artist
                          : t('Unknown Artist'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (lyrics?.source != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Text(
                    lyrics!.source!,
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              if (canSaveLrc)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: TextButton.icon(
                    onPressed: () => _saveLrc(context, ctrl, current.path, lyrics),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.accent,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      minimumSize: const Size(0, 28),
                    ),
                    icon: const Icon(Icons.save_alt_rounded, size: 14),
                    label: Text(
                      t('Save .lrc'),
                      style: const TextStyle(fontSize: 11.5),
                    ),
                  ),
                ),
              IconButton(
                tooltip: t('Reload lyrics'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(
                  Icons.refresh_rounded,
                  size: 16,
                  color: AppColors.textSecondary,
                ),
                onPressed: ctrl.lyricsLoading ? null : ctrl.refreshLyrics,
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: AppColors.border),
        Expanded(
          child: _buildLyricsBody(ctrl, current.path, lyrics),
        ),
      ],
    );
  }

  Widget _buildLyricsBody(
    PlayerController ctrl,
    String path,
    UiLyrics? lyrics,
  ) {
    if (ctrl.lyricsLoading && lyrics == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (lyrics == null || !lyrics.found) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.lyrics_outlined,
                size: 36,
                color: AppColors.textMuted,
              ),
              const SizedBox(height: 10),
              Text(
                ctrl.offlineMode
                    ? t('No local lyrics found (Offline Mode is on).')
                    : t('No lyrics found for this track.'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: ctrl.lyricsLoading ? null : ctrl.refreshLyrics,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.textPrimary,
                  side: const BorderSide(color: AppColors.border),
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.piano_rounded, size: 36, color: AppColors.accent),
              const SizedBox(height: 10),
              Text(
                t('Instrumental'),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
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
          if (activeIdx >= 0) {
            _scrollToActive(activeIdx);
          }

          return ListView.builder(
            controller: _scrollCtrl,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
            itemCount: lines.length,
            itemBuilder: (context, index) {
              final line = lines[index];
              final isActive = index == activeIdx;
              final isPast = activeIdx >= 0 && index < activeIdx;
              final display = line.text.trim().isEmpty ? '♪' : line.text;

              return Padding(
                key: _lineKeys[index],
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => ctrl.seek(line.timeMs.toInt() / 1000.0),
                  hoverColor: AppColors.surfaceHover,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: isActive
                          ? AppColors.accentMuted
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      display,
                      style: TextStyle(
                        fontSize: isActive ? 14.5 : 13.5,
                        height: 1.4,
                        fontWeight:
                            isActive ? FontWeight.w600 : FontWeight.w400,
                        color: isActive
                            ? AppColors.accent
                            : isPast
                                ? AppColors.textSecondary
                                : AppColors.textPrimary,
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      );
    }

    final plain = lyrics.plainText ?? '';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: SelectableText(
        plain,
        style: const TextStyle(
          fontSize: 13.5,
          height: 1.65,
          color: AppColors.textPrimary,
        ),
      ),
    );
  }
}

class _QueueTab extends StatelessWidget {
  const _QueueTab({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    final snap = controller.snapshot;
    final count = snap.queueLength;
    final currentIndex = snap.currentIndex;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (snap.current != null)
          TintedBackdrop(
            tintColor: controller.currentCoverColor,
            baseColor: AppColors.sidebar,
            tintAlpha: 54,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: AppColors.border)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t('NOW PLAYING'),
                    style: const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.9,
                      color: AppColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      CoverArt(
                        path: controller.currentCoverPath,
                        size: 40,
                        borderRadius: 5,
                        iconSize: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              snap.current!.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppColors.accent,
                              ),
                            ),
                            Text(
                              snap.current!.artist.isNotEmpty
                                  ? snap.current!.artist
                                  : t('Unknown Artist'),
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
                    ],
                  ),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 6),
          child: Row(
            children: [
              Text(
                t('Queue ({n})', {'n': count}),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary,
                ),
              ),
              const Spacer(),
              if (count > 0)
                TextButton(
                  onPressed: controller.clearQueuedTracks,
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
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
        Expanded(
          child: count == 0
              ? Center(
                  child: Text(
                    t('Queue is empty.'),
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                )
              : ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: count,
                  itemExtent: 50,
                  onReorderItem: (oldIndex, newIndex) {
                    controller.moveQueueItem(oldIndex, newIndex);
                  },
                  itemBuilder: (context, index) {
                    final item = controller.queueTrackAt(index);
                    if (item == null) {
                      return Padding(
                        key: ValueKey('queue-loading-$index'),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            t('Loading...'),
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ),
                      );
                    }
                    final isCurrent = currentIndex == index;
                    return Material(
                      key: ValueKey('queue-${item.id}-$index'),
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => controller.playIndex(index),
                        hoverColor: AppColors.surfaceHover,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          color: isCurrent
                              ? AppColors.accentMuted
                              : Colors.transparent,
                          child: Row(
                            children: [
                              ReorderableDragStartListener(
                                index: index,
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 8,
                                  ),
                                  child: Icon(
                                    Icons.drag_indicator_rounded,
                                    size: 15,
                                    color: AppColors.textMuted,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 22,
                                child: isCurrent
                                    ? const Icon(
                                        Icons.graphic_eq_rounded,
                                        size: 14,
                                        color: AppColors.accent,
                                      )
                                    : Text(
                                        '${index + 1}',
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: AppColors.textMuted,
                                          fontFeatures: [
                                            FontFeature.tabularFigures()
                                          ],
                                        ),
                                      ),
                              ),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        fontWeight: isCurrent
                                            ? FontWeight.w600
                                            : FontWeight.w500,
                                        color: isCurrent
                                            ? AppColors.accent
                                            : AppColors.textPrimary,
                                      ),
                                    ),
                                    if (item.artist.isNotEmpty)
                                      Text(
                                        item.artist,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: AppColors.textSecondary,
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
                                    color: AppColors.surface,
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(color: AppColors.border),
                                  ),
                                  child: const Text(
                                    'Q',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: AppColors.accent,
                                    ),
                                  ),
                                ),
                              IconButton(
                                tooltip: t('Remove from queue'),
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 26,
                                  minHeight: 26,
                                ),
                                icon: const Icon(
                                  Icons.close_rounded,
                                  size: 14,
                                  color: AppColors.textMuted,
                                ),
                                onPressed: () =>
                                    controller.removeFromQueue(index),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
