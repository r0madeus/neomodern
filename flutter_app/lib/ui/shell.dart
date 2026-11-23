import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/albums_view.dart';
import 'package:neomodern/ui/folders_view.dart';
import 'package:neomodern/ui/player_bar.dart';
import 'package:neomodern/ui/queue_view.dart';
import 'package:neomodern/ui/songs_view.dart';

enum NavTab { songs, albums, queue, folders }

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.controller});

  final PlayerController controller;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  NavTab _tab = NavTab.songs;

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final primary = FocusManager.instance.primaryFocus;
    final primaryContext = primary?.context;
    final isTyping = primaryContext != null &&
        (primaryContext.widget is EditableText ||
            primaryContext.findAncestorStateOfType<EditableTextState>() !=
                null);
    if (isTyping) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.space) {
      widget.controller.togglePause();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      widget.controller.seekRelative(-5);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      widget.controller.seekRelative(5);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final ctrl = widget.controller;

        if (ctrl.initError != null) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline_rounded,
                        size: 44, color: AppColors.danger),
                    const SizedBox(height: 12),
                    const Text(
                      'Failed to initialize NeoModern core',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      ctrl.initError!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        if (!ctrl.initialized) {
          return const Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 14),
                  Text(
                    'Starting NeoModern...',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
          );
        }

        return Focus(
          autofocus: true,
          onKeyEvent: _handleKeyEvent,
          child: Scaffold(
            body: Column(
              children: [
                if (ctrl.lastError != null)
                  Container(
                    width: double.infinity,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    color: AppColors.danger.withAlpha(36),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_amber_rounded,
                            size: 16, color: AppColors.danger),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            ctrl.lastError!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                        IconButton(
                          iconSize: 16,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: const Icon(Icons.close_rounded),
                          onPressed: ctrl.clearError,
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: Row(
                    children: [
                      _Sidebar(
                        selected: _tab,
                        controller: ctrl,
                        onSelect: (t) => setState(() => _tab = t),
                      ),
                      Expanded(
                        child: IndexedStack(
                          index: _tab.index,
                          children: [
                            SongsView(controller: ctrl),
                            AlbumsView(controller: ctrl),
                            QueueView(controller: ctrl),
                            FoldersView(controller: ctrl),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                PlayerBar(controller: ctrl),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.selected,
    required this.controller,
    required this.onSelect,
  });

  final NavTab selected;
  final PlayerController controller;
  final ValueChanged<NavTab> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 224,
      decoration: const BoxDecoration(
        color: AppColors.sidebar,
        border: Border(right: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
            child: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: AppColors.accentMuted,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.headphones_rounded,
                    size: 18,
                    color: AppColors.accent,
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  'NeoModern',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                    letterSpacing: -0.2,
                  ),
                ),
              ],
            ),
          ),
          _NavItem(
            icon: Icons.music_note_rounded,
            label: 'Songs',
            active: selected == NavTab.songs,
            onTap: () => onSelect(NavTab.songs),
          ),
          _NavItem(
            icon: Icons.album_rounded,
            label: 'Albums',
            active: selected == NavTab.albums,
            onTap: () => onSelect(NavTab.albums),
          ),
          _NavItem(
            icon: Icons.queue_music_rounded,
            label: 'Queue',
            active: selected == NavTab.queue,
            trailing: controller.snapshot.queueLength > 0
                ? '${controller.snapshot.queueLength}'
                : null,
            onTap: () => onSelect(NavTab.queue),
          ),
          _NavItem(
            icon: Icons.folder_rounded,
            label: 'Folders',
            active: selected == NavTab.folders,
            onTap: () => onSelect(NavTab.folders),
          ),
          const Spacer(),
          Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border),
            ),
            child: controller.isScanning
                ? Row(
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.accent,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Scanning (${controller.scannedCount})',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  )
                : Row(
                    children: [
                      const Icon(
                        Icons.library_music_rounded,
                        size: 15,
                        color: AppColors.textMuted,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${controller.trackCount} songs · ${controller.albumCount} albums',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: AppColors.textSecondary,
                          ),
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

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: active ? AppColors.accentMuted : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          hoverColor: active ? AppColors.accentMuted : AppColors.surfaceHover,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 19,
                  color: active ? AppColors.accent : AppColors.textSecondary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                      color: active ? AppColors.accent : AppColors.textPrimary,
                    ),
                  ),
                ),
                if (trailing != null)
                  Text(
                    trailing!,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppColors.textMuted,
                      fontFeatures: [FontFeature.tabularFigures()],
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
