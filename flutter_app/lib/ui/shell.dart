import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/albums_view.dart';
import 'package:neomodern/ui/artists_view.dart';
import 'package:neomodern/ui/cover_art.dart';
import 'package:neomodern/ui/favorites_view.dart';
import 'package:neomodern/ui/home_view.dart';
import 'package:neomodern/ui/mobile/mobile_shell.dart';
import 'package:neomodern/ui/player_bar.dart';
import 'package:neomodern/ui/playlists_view.dart';
import 'package:neomodern/ui/profiles_dialog.dart';
import 'package:neomodern/ui/recap_view.dart';
import 'package:neomodern/ui/right_panel.dart';
import 'package:neomodern/ui/settings_view.dart';
import 'package:neomodern/ui/songs_view.dart';
import 'package:neomodern/ui/sources_view.dart';
import 'package:neomodern/ui/track_menu.dart';
import 'package:neomodern/ui/welcome_dialog.dart';

enum NavTab {
  home,
  songs,
  albums,
  artists,
  sources,
  recap,
  settings,
  favorites,
  playlist,
}

typedef NeoModernShell = AppShell;

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.controller});

  final PlayerController controller;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  NavTab _tab = NavTab.home;
  PlatformInt64? _selectedPlaylistId;

  PlatformInt64? _externalAlbumId;
  int _externalAlbumNonce = 0;

  String? _externalArtistName;
  int _externalArtistNonce = 0;

  bool _rightPanelOpen = false;
  RightPanelTab _rightPanelTab = RightPanelTab.lyrics;
  bool _welcomeChecked = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_maybePromptWelcome);
    _maybePromptWelcome();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_maybePromptWelcome);
    super.dispose();
  }

  void _maybePromptWelcome() {
    final ctrl = widget.controller;
    if (_welcomeChecked || !ctrl.initialized) return;
    _welcomeChecked = true;
    if (ctrl.folders.isEmpty &&
        !ctrl.welcomeDismissed &&
        !ctrl.isProfileLocked) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(showWelcomeDialog(context: context, controller: ctrl));
      });
    }
  }

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

  void _openAlbum(PlatformInt64 albumId) {
    setState(() {
      _tab = NavTab.albums;
      _externalAlbumId = albumId;
      _externalAlbumNonce++;
    });
  }

  void _openArtist(String name) {
    setState(() {
      _tab = NavTab.artists;
      _externalArtistName = name;
      _externalArtistNonce++;
    });
  }

  void _openPlaylist(PlatformInt64 id) {
    setState(() {
      _tab = NavTab.playlist;
      _selectedPlaylistId = id;
    });
  }

  void _openSettings() {
    setState(() => _tab = NavTab.settings);
  }

  void _openFavorites() {
    setState(() => _tab = NavTab.favorites);
  }

  void _toggleRightPanel(RightPanelTab tab) {
    setState(() {
      if (_rightPanelOpen && _rightPanelTab == tab) {
        _rightPanelOpen = false;
      } else {
        _rightPanelOpen = true;
        _rightPanelTab = tab;
      }
    });
  }

  Future<void> _createPlaylist() async {
    final name = await showTextPromptDialog(
      context: context,
      title: t('Create Playlist'),
      hintText: t('Playlist name'),
      confirmLabel: t('Create'),
    );
    if (name == null) return;
    final created = await widget.controller.createPlaylist(name);
    if (created != null && mounted) {
      _openPlaylist(created.id);
    }
  }

  Future<void> _importM3uPlaylist() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: t('Import M3U Playlist'),
      type: FileType.custom,
      allowedExtensions: const ['m3u', 'm3u8'],
    );
    if (files.isEmpty) return;
    final path = files.first.path;
    if (path == null || path.isEmpty) return;
    final baseName = File(path).uri.pathSegments.last;
    final dotIdx = baseName.lastIndexOf('.');
    final stem = dotIdx > 0 ? baseName.substring(0, dotIdx) : baseName;
    final imported = await widget.controller.importPlaylistM3u(path, stem);
    if (imported != null && mounted) {
      _openPlaylist(imported.id);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t('Imported playlist "{name}"', {'name': imported.name})),
          behavior: SnackBarBehavior.floating,
          width: 320,
        ),
      );
    }
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
                    Text(
                      t('Failed to initialize NeoModern core'),
                      style: const TextStyle(
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
          return Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 14),
                  Text(
                    t('Starting NeoModern...'),
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
          );
        }

        final activeTab =
            (_tab == NavTab.sources && !ctrl.hasEnabledSourceProviders)
                ? NavTab.home
                : _tab;

        final mainIndex = switch (activeTab) {
          NavTab.home => 0,
          NavTab.songs => 1,
          NavTab.albums => 2,
          NavTab.artists => 3,
          NavTab.sources => 4,
          NavTab.recap => 5,
          NavTab.settings => 6,
          NavTab.favorites => 7,
          NavTab.playlist => 8,
        };

        return LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 680) {
              return MobileShell(controller: ctrl);
            }

            return Focus(
              autofocus: true,
              onKeyEvent: _handleKeyEvent,
              child: Scaffold(
                body: Stack(
                  children: [
                    Column(
                      children: [
                        if (ctrl.lastError != null)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8),
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
                                width: ctrl.sidebarWidth.clamp(190.0, 340.0),
                                selected: activeTab,
                                selectedPlaylistId: _selectedPlaylistId,
                                controller: ctrl,
                                onSelect: (t) => setState(() => _tab = t),
                                onSelectPlaylist: _openPlaylist,
                                onOpenAlbum: _openAlbum,
                                onCreatePlaylist: _createPlaylist,
                                onImportM3u: _importM3uPlaylist,
                                onOpenProfiles: () =>
                                    showProfilesDialog(context, ctrl),
                              ),
                              _ResizeHandle(
                                tooltip: t('Resize sidebar'),
                                onDragDelta: (dx) => ctrl.previewSidebarWidth(
                                  ctrl.sidebarWidth + dx,
                                ),
                                onDragEnd: () => unawaited(ctrl.saveUiPrefs()),
                              ),
                              Expanded(
                                child: IndexedStack(
                                  index: mainIndex,
                                  children: [
                                    HomeView(
                                      controller: ctrl,
                                      onOpenAlbum: _openAlbum,
                                      onOpenArtist: _openArtist,
                                      onOpenFavorites: _openFavorites,
                                      onOpenSettings: _openSettings,
                                    ),
                                    SongsView(
                                      controller: ctrl,
                                      onOpenArtist: _openArtist,
                                      onOpenAlbum: _openAlbum,
                                      onOpenSettings: _openSettings,
                                    ),
                                    AlbumsView(
                                      controller: ctrl,
                                      externalAlbumId: _externalAlbumId,
                                      externalSelectionNonce:
                                          _externalAlbumNonce,
                                      onOpenArtist: _openArtist,
                                      onOpenAlbum: _openAlbum,
                                      onOpenSettings: _openSettings,
                                    ),
                                    ArtistsView(
                                      controller: ctrl,
                                      externalArtistName: _externalArtistName,
                                      externalSelectionNonce:
                                          _externalArtistNonce,
                                      onOpenAlbum: _openAlbum,
                                      onOpenArtist: _openArtist,
                                    ),
                                    SourcesView(controller: ctrl),
                                    RecapView(
                                      controller: ctrl,
                                      onOpenArtist: _openArtist,
                                      onOpenAlbum: _openAlbum,
                                    ),
                                    SettingsView(controller: ctrl),
                                    FavoritesView(
                                      controller: ctrl,
                                      onOpenArtist: _openArtist,
                                      onOpenAlbum: _openAlbum,
                                    ),
                                    _selectedPlaylistId != null
                                        ? PlaylistsView(
                                            playlistId: _selectedPlaylistId!,
                                            controller: ctrl,
                                            onPlaylistDeleted: () =>
                                                setState(() {
                                              _selectedPlaylistId = null;
                                              _tab = NavTab.home;
                                            }),
                                            onOpenArtist: _openArtist,
                                            onOpenAlbum: _openAlbum,
                                          )
                                        : const SizedBox.shrink(),
                                  ],
                                ),
                              ),
                              if (_rightPanelOpen) ...[
                                _ResizeHandle(
                                  tooltip: t('Resize right panel'),
                                  onDragDelta: (dx) =>
                                      ctrl.previewRightPanelWidth(
                                    ctrl.rightPanelWidth - dx,
                                  ),
                                  onDragEnd: () => unawaited(ctrl.saveUiPrefs()),
                                ),
                                RightPanel(
                                  width:
                                      ctrl.rightPanelWidth.clamp(280.0, 480.0),
                                  controller: ctrl,
                                  activeTab: _rightPanelTab,
                                  onTabChanged: (t) =>
                                      setState(() => _rightPanelTab = t),
                                  onClose: () =>
                                      setState(() => _rightPanelOpen = false),
                                ),
                              ],
                            ],
                          ),
                        ),
                        PlayerBar(
                          controller: ctrl,
                          rightPanelOpen: _rightPanelOpen,
                          rightPanelTab: _rightPanelTab,
                          onTogglePanel: _toggleRightPanel,
                          onOpenArtist: _openArtist,
                        ),
                      ],
                    ),
                    if (ctrl.isProfileLocked)
                      ProfileLockOverlay(controller: ctrl),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _ResizeHandle extends StatefulWidget {
  const _ResizeHandle({
    required this.tooltip,
    required this.onDragDelta,
    required this.onDragEnd,
  });

  final String tooltip;
  final ValueChanged<double> onDragDelta;
  final VoidCallback onDragEnd;

  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  bool _hovered = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final active = _hovered || _dragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragUpdate: (details) =>
            widget.onDragDelta(details.delta.dx),
        onHorizontalDragEnd: (_) {
          setState(() => _dragging = false);
          widget.onDragEnd();
        },
        onHorizontalDragCancel: () {
          setState(() => _dragging = false);
          widget.onDragEnd();
        },
        child: Tooltip(
          message: widget.tooltip,
          waitDuration: const Duration(milliseconds: 600),
          child: SizedBox(
            width: 5,
            height: double.infinity,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: active ? 2 : 1,
                color: active ? AppColors.accent : AppColors.border,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.width,
    required this.selected,
    required this.selectedPlaylistId,
    required this.controller,
    required this.onSelect,
    required this.onSelectPlaylist,
    required this.onOpenAlbum,
    required this.onCreatePlaylist,
    required this.onImportM3u,
    required this.onOpenProfiles,
  });

  final double width;
  final NavTab selected;
  final PlatformInt64? selectedPlaylistId;
  final PlayerController controller;
  final ValueChanged<NavTab> onSelect;
  final ValueChanged<PlatformInt64> onSelectPlaylist;
  final ValueChanged<PlatformInt64> onOpenAlbum;
  final VoidCallback onCreatePlaylist;
  final VoidCallback onImportM3u;
  final VoidCallback onOpenProfiles;

  @override
  Widget build(BuildContext context) {
    final playlists = controller.playlists;
    final pinned = controller.pinnedItems;

    return Container(
      width: width,
      color: AppColors.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 16),
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
            icon: Icons.home_rounded,
            label: t('Home'),
            active: selected == NavTab.home,
            onTap: () => onSelect(NavTab.home),
          ),
          _NavItem(
            icon: Icons.music_note_rounded,
            label: t('Songs'),
            active: selected == NavTab.songs,
            onTap: () => onSelect(NavTab.songs),
          ),
          _NavItem(
            icon: Icons.album_rounded,
            label: t('Albums'),
            active: selected == NavTab.albums,
            onTap: () => onSelect(NavTab.albums),
          ),
          _NavItem(
            icon: Icons.person_rounded,
            label: t('Artists'),
            active: selected == NavTab.artists,
            onTap: () => onSelect(NavTab.artists),
          ),
          if (controller.hasEnabledSourceProviders)
            _NavItem(
              icon: Icons.hub_rounded,
              label: t('Sources'),
              active: selected == NavTab.sources,
              onTap: () => onSelect(NavTab.sources),
            ),
          _NavItem(
            icon: Icons.bar_chart_rounded,
            label: t('Recap'),
            active: selected == NavTab.recap,
            onTap: () => onSelect(NavTab.recap),
          ),
          _NavItem(
            icon: Icons.settings_rounded,
            label: t('Settings'),
            active: selected == NavTab.settings,
            onTap: () => onSelect(NavTab.settings),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Divider(height: 1, color: AppColors.border),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 10, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    t('YOUR LIBRARY'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.9,
                      color: AppColors.textMuted,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: t('Import M3U Playlist'),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 26, minHeight: 26),
                  icon: const Icon(
                    Icons.file_open_outlined,
                    size: 15,
                    color: AppColors.textSecondary,
                  ),
                  onPressed: onImportM3u,
                ),
                IconButton(
                  tooltip: t('Create Playlist'),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 26, minHeight: 26),
                  icon: const Icon(
                    Icons.add_rounded,
                    size: 17,
                    color: AppColors.textSecondary,
                  ),
                  onPressed: onCreatePlaylist,
                ),
              ],
            ),
          ),
          _NavItem(
            icon: Icons.star_rounded,
            label: t('Favorites'),
            active: selected == NavTab.favorites,
            trailing: controller.favoriteCount > 0
                ? '${controller.favoriteCount}'
                : null,
            onTap: () => onSelect(NavTab.favorites),
          ),
          if (pinned.isNotEmpty) ...[
            for (final item in pinned)
              _PinnedSidebarItem(
                item: item,
                active: item.kind == 'playlist' &&
                    selected == NavTab.playlist &&
                    selectedPlaylistId == item.targetId,
                onTap: () {
                  if (item.kind == 'album') {
                    onOpenAlbum(item.targetId);
                  } else {
                    onSelectPlaylist(item.targetId);
                  }
                },
              ),
          ],
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 8),
              itemCount: playlists.length,
              itemBuilder: (context, index) {
                final pl = playlists[index];
                final active = selected == NavTab.playlist &&
                    selectedPlaylistId == pl.id;
                return _NavItem(
                  icon: Icons.queue_music_rounded,
                  label: pl.name,
                  active: active,
                  trailing: pl.trackCount > 0 ? '${pl.trackCount}' : null,
                  onTap: () => onSelectPlaylist(pl.id),
                );
              },
            ),
          ),
          InkWell(
            onTap: controller.folders.isEmpty
                ? () => onSelect(NavTab.settings)
                : null,
            child: Container(
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
                            t('Scanning ({n})', {'n': controller.scannedCount}),
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
                            controller.folders.isEmpty
                                ? t('Add folder in Settings')
                                : t('{songs} songs · {albums} albums', {
                                    'songs': controller.trackCount,
                                    'albums': controller.albumCount,
                                  }),
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
          ),
          ProfileBadgeButton(
            controller: controller,
            onTap: onOpenProfiles,
          ),
        ],
      ),
    );
  }
}

class _PinnedSidebarItem extends StatelessWidget {
  const _PinnedSidebarItem({
    required this.item,
    required this.active,
    required this.onTap,
  });

  final UiPinnedItem item;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1.5),
      child: Material(
        color: active ? AppColors.accentMuted : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          hoverColor: active ? AppColors.accentMuted : AppColors.surfaceHover,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              children: [
                CoverArt(
                  path: item.coverPath,
                  size: 24,
                  borderRadius: 4,
                  iconSize: 13,
                  fallbackIcon: item.kind == 'album'
                      ? Icons.album_rounded
                      : Icons.queue_music_rounded,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                      color: active ? AppColors.accent : AppColors.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(
                  Icons.push_pin_rounded,
                  size: 12,
                  color: AppColors.accent,
                ),
              ],
            ),
          ),
        ),
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: active ? AppColors.accent : AppColors.textSecondary,
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
