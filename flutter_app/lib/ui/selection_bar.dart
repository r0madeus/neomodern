import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/theme/app_theme.dart';

/// Floating bottom batch action bar for multi-selected tracks.
class TrackSelectionBar extends StatelessWidget {
  const TrackSelectionBar({
    super.key,
    required this.selectedCount,
    required this.allStarred,
    required this.onAddToQueue,
    required this.onToggleStar,
    required this.onAddToPlaylist,
    required this.onClear,
  });

  final int selectedCount;
  final bool allStarred;
  final VoidCallback onAddToQueue;
  final VoidCallback onToggleStar;
  final VoidCallback onAddToPlaylist;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    if (selectedCount <= 0) return const SizedBox.shrink();

    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16, left: 24, right: 24),
        child: Material(
          color: AppColors.surface,
          elevation: 10,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.accent.withAlpha(110)),
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.accentMuted,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    t('{n} selected', {'n': selectedCount}),
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.accent,
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: onAddToQueue,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textPrimary,
                    side: const BorderSide(color: AppColors.border),
                  ),
                  icon: const Icon(Icons.add_to_queue_rounded, size: 16),
                  label: Text(t('Add to Queue')),
                ),
                OutlinedButton.icon(
                  onPressed: onToggleStar,
                  style: OutlinedButton.styleFrom(
                    foregroundColor:
                        allStarred ? AppColors.accent : AppColors.textPrimary,
                    side: const BorderSide(color: AppColors.border),
                  ),
                  icon: Icon(
                    allStarred
                        ? Icons.star_rounded
                        : Icons.star_outline_rounded,
                    size: 16,
                    color: allStarred ? AppColors.accent : null,
                  ),
                  label: Text(allStarred ? t('Unstar') : t('Star')),
                ),
                OutlinedButton.icon(
                  onPressed: onAddToPlaylist,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textPrimary,
                    side: const BorderSide(color: AppColors.border),
                  ),
                  icon: const Icon(Icons.playlist_add_rounded, size: 16),
                  label: Text(t('Add to Playlist ')),
                ),
                TextButton.icon(
                  onPressed: onClear,
                  icon: const Icon(Icons.close_rounded, size: 16),
                  label: Text(t('Clear')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
