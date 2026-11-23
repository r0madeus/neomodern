import 'package:material_ui/material_ui.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';

enum RightPanelTab { lyrics, queue }

class RightPanel extends StatelessWidget {
  const RightPanel({
    super.key,
    required this.controller,
    required this.activeTab,
    required this.onTabChanged,
    required this.onClose,
  });

  final PlayerController controller;
  final RightPanelTab activeTab;
  final ValueChanged<RightPanelTab> onTabChanged;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 328,
      decoration: const BoxDecoration(
        color: AppColors.sidebar,
        border: Border(left: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.border)),
            ),
            child: Row(
              children: [
                _PanelTabButton(
                  icon: Icons.lyrics_rounded,
                  label: 'Lyrics',
                  active: activeTab == RightPanelTab.lyrics,
                  onTap: () => onTabChanged(RightPanelTab.lyrics),
                ),
                const SizedBox(width: 4),
                _PanelTabButton(
                  icon: Icons.queue_music_rounded,
                  label: 'Queue',
                  active: activeTab == RightPanelTab.queue,
                  onTap: () => onTabChanged(RightPanelTab.queue),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Close panel',
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

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final current = ctrl.snapshot.current;

    if (current == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Play a track to view lyrics.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
        ),
      );
    }

    final lyrics = ctrl.currentLyrics;

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
                          : 'Unknown Artist',
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
              IconButton(
                tooltip: 'Reload lyrics',
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
                    ? 'No local lyrics found (Offline Mode is on).'
                    : 'No lyrics found for this track.',
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
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (lyrics.isInstrumental) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.piano_rounded, size: 36, color: AppColors.accent),
              SizedBox(height: 10),
              Text(
                'Instrumental',
                style: TextStyle(
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
          Container(
            padding: const EdgeInsets.all(14),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.border)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'NOW PLAYING',
                  style: TextStyle(
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
                                : 'Unknown Artist',
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
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 6),
          child: Row(
            children: [
              Text(
                'Queue ($count)',
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
                  child: const Text(
                    'Clear Added',
                    style: TextStyle(fontSize: 11.5),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: count == 0
              ? const Center(
                  child: Text(
                    'Queue is empty.',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: count,
                  itemExtent: 50,
                  itemBuilder: (context, index) {
                    final item = controller.queueTrackAt(index);
                    if (item == null) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 14),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Loading...',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ),
                      );
                    }
                    final isCurrent = currentIndex == index;
                    return InkWell(
                      onTap: () => controller.playIndex(index),
                      hoverColor: AppColors.surfaceHover,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        color: isCurrent
                            ? AppColors.accentMuted
                            : Colors.transparent,
                        child: Row(
                          children: [
                            SizedBox(
                              width: 24,
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
                              tooltip: 'Remove from queue',
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
                    );
                  },
                ),
        ),
      ],
    );
  }
}
