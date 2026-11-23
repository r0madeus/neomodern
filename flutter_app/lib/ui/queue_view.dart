import 'package:material_ui/material_ui.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';

class QueueView extends StatelessWidget {
  const QueueView({super.key, required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    final snap = controller.snapshot;
    final count = snap.queueLength;
    final currentIndex = snap.currentIndex;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 14),
          child: Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Queue', style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 2),
                  Text(
                    count == 0
                        ? 'Queue is empty'
                        : '$count tracks in queue${currentIndex != null ? ' · playing #${currentIndex + 1}' : ''}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              const Spacer(),
              if (snap.shuffle)
                const _StatusChip(icon: Icons.shuffle_rounded, label: 'Shuffle'),
              if (snap.repeat != 'off') ...[
                const SizedBox(width: 8),
                _StatusChip(
                  icon: snap.repeat == 'one'
                      ? Icons.repeat_one_rounded
                      : Icons.repeat_rounded,
                  label: snap.repeat == 'one' ? 'Repeat One' : 'Repeat All',
                ),
              ],
            ],
          ),
        ),
        const Divider(height: 1, color: AppColors.border),
        Expanded(
          child: count == 0
              ? const Center(
                  child: Text(
                    'Nothing in the queue yet. Pick a song or album to start playback.',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                )
              : ListView.builder(
                  itemCount: count,
                  itemExtent: 52,
                  itemBuilder: (context, index) {
                    final item = controller.queueTrackAt(index);
                    if (item == null) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 24),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Loading...',
                            style: TextStyle(
                              fontSize: 12.5,
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
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        color: isCurrent
                            ? AppColors.accentMuted
                            : Colors.transparent,
                        child: Row(
                          children: [
                            SizedBox(
                              width: 40,
                              child: isCurrent
                                  ? const Icon(
                                      Icons.graphic_eq_rounded,
                                      size: 16,
                                      color: AppColors.accent,
                                    )
                                  : Text(
                                      '${index + 1}',
                                      style: const TextStyle(
                                        fontSize: 12,
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
                                      fontSize: 13.5,
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
                                        fontSize: 12,
                                        color: AppColors.textSecondary,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            if (item.queued)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.surface,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: AppColors.border),
                                ),
                                child: const Text(
                                  'Queued',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
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

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.accentMuted,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppColors.accent),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: AppColors.accent,
            ),
          ),
        ],
      ),
    );
  }
}
