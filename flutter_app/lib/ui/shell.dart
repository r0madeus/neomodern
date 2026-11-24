import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/albums_view.dart';
import 'package:neomodern/ui/artists_view.dart';
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
      title: 'Create Playlist',
      hintText: 'Playlist name',
      confirmLabel: 'Create',
    );
    if (name == null) return;
    final created = await widget.controller.createPlaylist(name);
    if (created != null && mounted) {
      _openPlaylist(created.id);
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
                                selected: activeTab,
                                selectedPlaylistId: _selectedPlaylistId,
                                controller: ctrl,
                                onSelect: (t) => setState(() => _tab = t),
                                onSelectPlaylist: _openPlaylist,
                                onCreatePlaylist: _createPlaylist,
                                onOpenProfiles: () =>
                                    showProfilesDialog(context, ctrl),
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
                              if (_rightPanelOpen)
                                RightPanel(
                                  controller: ctrl,
                                  activeTab: _rightPanelTab,
                                  onTabChanged: (t) =>
                                      setState(() => _rightPanelTab = t),
                                  onClose: () =>
                                      setState(() => _rightPanelOpen = false),
                                ),
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

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.selected,
    required this.selectedPlaylistId,
    required this.controller,
    required this.onSelect,
    required this.onSelectPlaylist,
    required this.onCreatePlaylist,
    required this.onOpenProfiles,
  });

  final NavTab selected;
  final PlatformInt64? selectedPlaylistId;
  final PlayerController controller;
  final ValueChanged<NavTab> onSelect;
  final ValueChanged<PlatformInt64> onSelectPlaylist;
  final VoidCallback onCreatePlaylist;
  final VoidCallback onOpenProfiles;

  @override
  Widget build(BuildContext context) {
    final playlists = controller.playlists;

    return Container(
      width: 228,
      decoration: const BoxDecoration(
        color: AppColors.sidebar,
        border: Border(right: BorderSide(color: AppColors.border)),
      ),
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
            label: 'Home',
            active: selected == NavTab.home,
            onTap: () => onSelect(NavTab.home),
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
            icon: Icons.person_rounded,
            label: 'Artists',
            active: selected == NavTab.artists,
            onTap: () => onSelect(NavTab.artists),
          ),
          if (controller.hasEnabledSourceProviders)
            _NavItem(
              icon: Icons.hub_rounded,
              label: 'Sources',
              active: selected == NavTab.sources,
              onTap: () => onSelect(NavTab.sources),
            ),
          _NavItem(
            icon: Icons.bar_chart_rounded,
            label: 'Recap',
            active: selected == NavTab.recap,
            onTap: () => onSelect(NavTab.recap),
          ),
          _NavItem(
            icon: Icons.settings_rounded,
            label: 'Settings',
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
                const Text(
                  'YOUR LIBRARY',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.9,
                    color: AppColors.textMuted,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Create Playlist',
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
            label: 'Favorites',
            active: selected == NavTab.favorites,
            trailing: controller.favoriteCount > 0
                ? '${controller.favoriteCount}'
                : null,
            onTap: () => onSelect(NavTab.favorites),
          ),
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
                            controller.folders.isEmpty
                                ? 'Add folder in Settings'
                                : '${controller.trackCount} songs · ${controller.albumCount} albums',
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
