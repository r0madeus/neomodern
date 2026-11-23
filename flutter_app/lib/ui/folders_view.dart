import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';

class FoldersView extends StatelessWidget {
  const FoldersView({super.key, required this.controller});

  final PlayerController controller;

  Future<void> _pickAndAddFolder() async {
    final uri = await FilePicker.pickDirectory(
      dialogTitle: 'Select music folder',
    );
    if (uri != null) {
      final path = uri.isScheme('file') ? uri.toFilePath() : uri.toString();
      if (path.isNotEmpty) {
        await controller.addFolder(path);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final folders = controller.folders;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
          child: Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Folders',
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 2),
                  Text(
                    '${folders.length} watched ${folders.length == 1 ? 'folder' : 'folders'}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: controller.isScanning || folders.isEmpty
                    ? null
                    : controller.rescanLibrary,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.textPrimary,
                  side: const BorderSide(color: AppColors.border),
                ),
                icon: controller.isScanning
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded, size: 17),
                label: Text(
                  controller.isScanning ? 'Scanning...' : 'Rescan Library',
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: _pickAndAddFolder,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: AppColors.canvas,
                ),
                icon: const Icon(Icons.create_new_folder_rounded, size: 18),
                label: const Text(
                  'Add Folder',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
        if (controller.isScanning)
          Container(
            margin: const EdgeInsets.fromLTRB(24, 0, 24, 14),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.accentMuted,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.accent.withAlpha(80)),
            ),
            child: Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.accent,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  'Scanning library... ${controller.scannedCount} files processed',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        const Divider(height: 1, color: AppColors.border),
        Expanded(
          child: folders.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.folder_open_rounded,
                        size: 48,
                        color: AppColors.textMuted,
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'No music folders added yet.',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Add a folder containing MP3, FLAC, OGG, WAV, or M4A files.',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _pickAndAddFolder,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: AppColors.canvas,
                        ),
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text(
                          'Add Music Folder',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(24),
                  itemCount: folders.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final folder = folders[index];
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.folder_rounded,
                            color: AppColors.accent,
                            size: 20,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              folder.path,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13.5,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Remove folder',
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              size: 19,
                              color: AppColors.textSecondary,
                            ),
                            onPressed: () => controller.removeFolder(folder.id),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
