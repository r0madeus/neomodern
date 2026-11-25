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
import 'package:neomodern/ui/widgets/motion_primitives.dart';

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
  static const double _collapsedWidth = 68.0;
  static const double _collapseThreshold = 125.0;

  NavTab _tab = NavTab.home;
  PlatformInt64? _selectedPlaylistId;

  PlatformInt64? _externalAlbumId;
  int _externalAlbumNonce = 0;

  String? _externalArtistName;
  int _externalArtistNonce = 0;

  bool _sidebarCollapsed = false;
  bool _draggingSidebar = false;
  double? _sidebarDragRawWidth;

  bool _rightPanelOpen = false;
  RightPanelTab _rightPanelTab = RightPanelTab.nowPlaying;
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

  void _openRecap() {
    setState(() => _tab = NavTab.recap);
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

  void _handleSidebarDragStart() {
    final ctrl = widget.controller;
    setState(() {
      _draggingSidebar = true;
      _sidebarDragRawWidth = _sidebarCollapsed
          ? _collapsedWidth
          : ctrl.sidebarWidth.clamp(176.0, 380.0);
    });
  }

  void _handleSidebarDragDelta(double dx) {
    final ctrl = widget.controller;
    final nextRaw = (_sidebarDragRawWidth ?? ctrl.sidebarWidth) + dx;
    _sidebarDragRawWidth = nextRaw.clamp(40.0, 380.0);
    if (_sidebarDragRawWidth! < _collapseThreshold) {
      if (!_sidebarCollapsed) {
        setState(() => _sidebarCollapsed = true);
      }
    } else {
      if (_sidebarCollapsed) {
        setState(() => _sidebarCollapsed = false);
      }
      ctrl.previewSidebarWidth(_sidebarDragRawWidth!.clamp(176.0, 380.0));
    }
  }

  void _handleSidebarDragEnd() {
    setState(() {
      _draggingSidebar = false;
      _sidebarDragRawWidth = null;
    });
    unawaited(widget.controller.saveUiPrefs());
  }

  Widget _buildActiveView(NavTab activeTab, PlayerController ctrl) {
    return switch (activeTab) {
      NavTab.home => HomeView(
          controller: ctrl,
          onOpenAlbum: _openAlbum,
          onOpenArtist: _openArtist,
          onOpenFavorites: _openFavorites,
          onOpenSettings: _openSettings,
          onOpenRecap: _openRecap,
        ),
      NavTab.songs => SongsView(
          controller: ctrl,
          onOpenArtist: _openArtist,
          onOpenAlbum: _openAlbum,
          onOpenSettings: _openSettings,
        ),
      NavTab.albums => AlbumsView(
          controller: ctrl,
          externalAlbumId: _externalAlbumId,
          externalSelectionNonce: _externalAlbumNonce,
          onOpenArtist: _openArtist,
          onOpenAlbum: _openAlbum,
          onOpenSettings: _openSettings,
        ),
      NavTab.artists => ArtistsView(
          controller: ctrl,
          externalArtistName: _externalArtistName,
          externalSelectionNonce: _externalArtistNonce,
          onOpenAlbum: _openAlbum,
          onOpenArtist: _openArtist,
        ),
      NavTab.sources => SourcesView(controller: ctrl),
      NavTab.recap => RecapView(
          controller: ctrl,
          onOpenArtist: _openArtist,
          onOpenAlbum: _openAlbum,
        ),
      NavTab.settings => SettingsView(controller: ctrl),
      NavTab.favorites => FavoritesView(
          controller: ctrl,
          onOpenArtist: _openArtist,
          onOpenAlbum: _openAlbum,
        ),
      NavTab.playlist => _selectedPlaylistId != null
          ? PlaylistsView(
              playlistId: _selectedPlaylistId!,
              controller: ctrl,
              onPlaylistDeleted: () => setState(() {
                _selectedPlaylistId = null;
                _tab = NavTab.home;
              }),
              onOpenArtist: _openArtist,
              onOpenAlbum: _openAlbum,
            )
          : const SizedBox.shrink(),
    };
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
                        size: 44, color: AppTheme.danger),
                    const SizedBox(height: 12),
                    Text(
                      t('Failed to initialize NeoModern core'),
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.zinc100,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      ctrl.initError!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppTheme.zinc400),
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
                    style: const TextStyle(color: AppTheme.zinc400),
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

        final routeKey = activeTab == NavTab.playlist
            ? 'playlist:${_selectedPlaylistId ?? ''}'
            : activeTab.name;

        final sidebarWidth = _sidebarCollapsed
            ? _collapsedWidth
            : ctrl.sidebarWidth.clamp(176.0, 380.0);

        return LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 680) {
              return MobileShell(controller: ctrl);
            }

            return Focus(
              autofocus: true,
              onKeyEvent: _handleKeyEvent,
              child: Scaffold(
                backgroundColor: AppTheme.zinc950,
                body: Stack(
                  children: [
                    Column(
                      children: [
                        if (ctrl.lastError != null)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8),
                            color: AppTheme.danger.withValues(alpha: 0.14),
                            child: Row(
                              children: [
                                const Icon(Icons.warning_amber_rounded,
                                    size: 16, color: AppTheme.danger),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    ctrl.lastError!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12.5,
                                      color: AppTheme.zinc100,
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
                                width: sidebarWidth,
                                collapsed: _sidebarCollapsed,
                                dragging: _draggingSidebar,
                                selected: activeTab,
                                selectedPlaylistId: _selectedPlaylistId,
                                externalAlbumId: _externalAlbumId,
                                controller: ctrl,
                                onToggleCollapse: () => setState(
                                  () => _sidebarCollapsed = !_sidebarCollapsed,
                                ),
                                onSelect: (nav) => setState(() {
                                  if (nav == NavTab.albums) {
                                    _externalAlbumId = null;
                                  }
                                  if (nav == NavTab.artists) {
                                    _externalArtistName = null;
                                  }
                                  _tab = nav;
                                }),
                                onSelectPlaylist: _openPlaylist,
                                onOpenAlbum: _openAlbum,
                                onCreatePlaylist: _createPlaylist,
                                onImportM3u: _importM3uPlaylist,
                                onOpenProfiles: () =>
                                    showProfilesDialog(context, ctrl),
                              ),
                              _ResizeHandle(
                                tooltip: t('Resize sidebar'),
                                onDragStart: _handleSidebarDragStart,
                                onDragDelta: _handleSidebarDragDelta,
                                onDragEnd: _handleSidebarDragEnd,
                              ),
                              Expanded(
                                child: ViewFadeIn(
                                  key: ValueKey(routeKey),
                                  child: _buildActiveView(activeTab, ctrl),
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
                                      ctrl.rightPanelWidth.clamp(270.0, 480.0),
                                  controller: ctrl,
                                  activeTab: _rightPanelTab,
                                  onTabChanged: (t) =>
                                      setState(() => _rightPanelTab = t),
                                  onClose: () =>
                                      setState(() => _rightPanelOpen = false),
                                  onOpenArtist: _openArtist,
                                  onOpenAlbum: _openAlbum,
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
                          onOpenAlbum: _openAlbum,
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
    this.onDragStart,
  });

  final String tooltip;
  final VoidCallback? onDragStart;
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
        onHorizontalDragStart: (_) {
          setState(() => _dragging = true);
          widget.onDragStart?.call();
        },
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
                color: active
                    ? AppTheme.accent500
                    : AppTheme.zinc800.withValues(alpha: 0.80),
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
    required this.collapsed,
    required this.dragging,
    required this.selected,
    required this.selectedPlaylistId,
    required this.externalAlbumId,
    required this.controller,
    required this.onToggleCollapse,
    required this.onSelect,
    required this.onSelectPlaylist,
    required this.onOpenAlbum,
    required this.onCreatePlaylist,
    required this.onImportM3u,
    required this.onOpenProfiles,
  });

  final double width;
  final bool collapsed;
  final bool dragging;
  final NavTab selected;
  final PlatformInt64? selectedPlaylistId;
  final PlatformInt64? externalAlbumId;
  final PlayerController controller;
  final VoidCallback onToggleCollapse;
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
    final unpinnedPlaylists = playlists
        .where((p) => !controller.isPinned('playlist', p.id))
        .toList();
    final activeContext = controller.snapshot.context;

    return AnimatedContainer(
      duration: dragging ? Duration.zero : const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      width: width,
      padding: EdgeInsets.symmetric(
        horizontal: collapsed ? 8 : 12,
        vertical: 16,
      ),
      color: AppTheme.zinc900.withValues(alpha: 0.50),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top Header
          if (collapsed)
            Column(
              children: [
                const _LogoBadge(),
                const SizedBox(height: 10),
                _CollapseButton(
                  collapsed: true,
                  onPressed: onToggleCollapse,
                ),
              ],
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                children: [
                  const _LogoBadge(),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'NeoModern',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.zinc100,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),
                  _CollapseButton(
                    collapsed: false,
                    onPressed: onToggleCollapse,
                  ),
                ],
              ),
            ),

          const SizedBox(height: 16),

          // Primary Nav
          _NavItem(
            icon: Icons.home_rounded,
            label: t('Home'),
            collapsed: collapsed,
            active: selected == NavTab.home,
            onTap: () => onSelect(NavTab.home),
          ),
          const SizedBox(height: 2),
          _NavItem(
            icon: Icons.music_note_rounded,
            label: t('Songs'),
            collapsed: collapsed,
            active: selected == NavTab.songs,
            trailing:
                controller.trackCount > 0 ? '${controller.trackCount}' : null,
            onTap: () => onSelect(NavTab.songs),
          ),
          const SizedBox(height: 2),
          _NavItem(
            icon: Icons.album_rounded,
            label: t('Albums'),
            collapsed: collapsed,
            active: selected == NavTab.albums && externalAlbumId == null,
            trailing:
                controller.albumCount > 0 ? '${controller.albumCount}' : null,
            onTap: () => onSelect(NavTab.albums),
          ),
          const SizedBox(height: 2),
          _NavItem(
            icon: Icons.person_rounded,
            label: t('Artists'),
            collapsed: collapsed,
            active: selected == NavTab.artists,
            onTap: () => onSelect(NavTab.artists),
          ),
          const SizedBox(height: 2),
          _NavItem(
            icon: Icons.bar_chart_rounded,
            label: t('Recap'),
            collapsed: collapsed,
            active: selected == NavTab.recap,
            onTap: () => onSelect(NavTab.recap),
          ),
          if (controller.hasEnabledSourceProviders) ...[
            const SizedBox(height: 2),
            _NavItem(
              icon: Icons.hub_rounded,
              label: t('Sources'),
              collapsed: collapsed,
              active: selected == NavTab.sources,
              onTap: () => onSelect(NavTab.sources),
            ),
          ],

          const SizedBox(height: 16),

          // YOUR LIBRARY header
          if (!collapsed)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 2, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      t('YOUR LIBRARY'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.7,
                        color: AppTheme.zinc400,
                      ),
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: t('Create'),
                    padding: EdgeInsets.zero,
                    color: AppTheme.zinc900,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: const BorderSide(color: AppTheme.zinc700),
                    ),
                    onSelected: (val) {
                      if (val == 'new') {
                        onCreatePlaylist();
                      } else if (val == 'import') {
                        onImportM3u();
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem<String>(
                        value: 'new',
                        child: Row(
                          children: [
                            const Icon(
                              Icons.queue_music_rounded,
                              size: 16,
                              color: AppTheme.zinc400,
                            ),
                            const SizedBox(width: 10),
                            Text(t('Create Playlist')),
                          ],
                        ),
                      ),
                      PopupMenuItem<String>(
                        value: 'import',
                        child: Row(
                          children: [
                            const Icon(
                              Icons.file_open_outlined,
                              size: 16,
                              color: AppTheme.zinc400,
                            ),
                            const SizedBox(width: 10),
                            Text(t('Import M3U Playlist')),
                          ],
                        ),
                      ),
                    ],
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(
                        Icons.add_rounded,
                        size: 18,
                        color: AppTheme.zinc400,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // Spotify-style library list
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 8),
              children: [
                _SidebarLibraryRow(
                  title: t('Favorites'),
                  subtitle: controller.favoriteCount > 0
                      ? '${t('Playlist')} · ${controller.favoriteCount}'
                      : t('Playlist'),
                  collapsed: collapsed,
                  active: selected == NavTab.favorites,
                  isPlayingContext: activeContext == 'favorites',
                  isGlobalPlaying: controller.isPlaying,
                  onTap: () => onSelect(NavTab.favorites),
                  onPlayToggle: () {
                    if (activeContext == 'favorites') {
                      controller.togglePause();
                    } else if (controller.favoriteCount > 0) {
                      controller.playFavorites(0);
                    } else {
                      onSelect(NavTab.favorites);
                    }
                  },
                  cover: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          AppTheme.accent400,
                          Color(0xFF4F46E5),
                        ],
                      ),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.star_rounded,
                      size: 20,
                      color: Colors.white,
                    ),
                  ),
                ),
                for (final item in pinned)
                  _buildPinnedRow(
                    item: item,
                    playlists: playlists,
                    activeContext: activeContext,
                  ),
                for (final pl in unpinnedPlaylists)
                  _SidebarLibraryRow(
                    title: pl.name,
                    subtitle: pl.trackCount > 0
                        ? '${t('Playlist')} · ${pl.trackCount}'
                        : t('Playlist'),
                    collapsed: collapsed,
                    active: selected == NavTab.playlist &&
                        selectedPlaylistId == pl.id,
                    isPlayingContext: activeContext == 'playlist:${pl.id}',
                    isGlobalPlaying: controller.isPlaying,
                    onTap: () => onSelectPlaylist(pl.id),
                    onPlayToggle: () {
                      if (activeContext == 'playlist:${pl.id}') {
                        controller.togglePause();
                      } else {
                        controller.playPlaylist(pl.id, 0);
                      }
                    },
                    cover: PlaylistCoverWidget(
                      playlist: pl,
                      size: 48,
                      borderRadius: 6,
                    ),
                  ),
              ],
            ),
          ),

          // Footer: scan status, Profile, Settings
          if (controller.isScanning)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                mainAxisAlignment: collapsed
                    ? MainAxisAlignment.center
                    : MainAxisAlignment.start,
                children: [
                  const SizedBox(
                    width: 8,
                    height: 8,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppTheme.accent500,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  if (!collapsed) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        t('Scanning ({n})', {'n': controller.scannedCount}),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppTheme.accent400,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),

          if (!collapsed)
            ProfileBadgeButton(
              controller: controller,
              onTap: onOpenProfiles,
            )
          else
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Tooltip(
                message: controller.activeProfile?.name ?? t('Profile'),
                child: Center(
                  child: InkWell(
                    onTap: onOpenProfiles,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: controller.activeProfile != null
                              ? parseProfileColor(
                                  controller.activeProfile!.color)
                              : AppTheme.accent500,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

          _NavItem(
            icon: Icons.tune_rounded,
            label: t('Settings'),
            collapsed: collapsed,
            active: selected == NavTab.settings,
            onTap: () => onSelect(NavTab.settings),
          ),
        ],
      ),
    );
  }

  Widget _buildPinnedRow({
    required UiPinnedItem item,
    required List<UiPlaylistInfo> playlists,
    required String? activeContext,
  }) {
    final isAlbum = item.kind == 'album';
    final contextKey = '${item.kind}:${item.targetId}';
    final matchingPlaylist = isAlbum
        ? null
        : playlists.cast<UiPlaylistInfo?>().firstWhere(
              (p) => p?.id == item.targetId,
              orElse: () => null,
            );

    final Widget coverWidget = matchingPlaylist != null
        ? PlaylistCoverWidget(
            playlist: matchingPlaylist,
            size: 48,
            borderRadius: 6,
          )
        : CoverArt(
            path: item.coverPath,
            size: 48,
            borderRadius: 6,
            iconSize: 20,
            fallbackIcon:
                isAlbum ? Icons.album_rounded : Icons.queue_music_rounded,
          );

    final active = isAlbum
        ? (selected == NavTab.albums && externalAlbumId == item.targetId)
        : (selected == NavTab.playlist && selectedPlaylistId == item.targetId);

    final subtitle = isAlbum
        ? (item.subtitle.isNotEmpty
            ? '${t('Album')} · ${item.subtitle}'
            : t('Album'))
        : t('Playlist');

    return _SidebarLibraryRow(
      title: item.title,
      subtitle: subtitle,
      collapsed: collapsed,
      active: active,
      isPinned: true,
      isPlayingContext: activeContext == contextKey,
      isGlobalPlaying: controller.isPlaying,
      onTap: () {
        if (isAlbum) {
          onOpenAlbum(item.targetId);
        } else {
          onSelectPlaylist(item.targetId);
        }
      },
      onPlayToggle: () {
        if (activeContext == contextKey) {
          controller.togglePause();
        } else if (isAlbum) {
          controller.playAlbum(item.targetId, 0);
        } else {
          controller.playPlaylist(item.targetId, 0);
        }
      },
      cover: coverWidget,
    );
  }
}

class _LogoBadge extends StatelessWidget {
  const _LogoBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppTheme.accent400, AppTheme.accent700],
        ),
      ),
      alignment: Alignment.center,
      child: const Icon(
        Icons.headphones_rounded,
        size: 16,
        color: Colors.white,
      ),
    );
  }
}

class _CollapseButton extends StatefulWidget {
  const _CollapseButton({
    required this.collapsed,
    required this.onPressed,
  });

  final bool collapsed;
  final VoidCallback onPressed;

  @override
  State<_CollapseButton> createState() => _CollapseButtonState();
}

class _CollapseButtonState extends State<_CollapseButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.collapsed ? t('Expand sidebar') : t('Collapse sidebar'),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: _hovered ? AppTheme.zinc800 : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              widget.collapsed
                  ? Icons.chevron_right_rounded
                  : Icons.view_sidebar_outlined,
              size: 16,
              color: _hovered ? AppTheme.zinc100 : AppTheme.zinc400,
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.collapsed,
    required this.active,
    required this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final bool collapsed;
  final bool active;
  final VoidCallback onTap;
  final String? trailing;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.active
        ? AppTheme.accent950.withValues(alpha: 0.50)
        : (_hovered
            ? AppTheme.zinc800.withValues(alpha: 0.70)
            : Colors.transparent);
    final fg = widget.active ? AppTheme.accent100 : AppTheme.zinc300;

    Widget tile = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisAlignment: widget.collapsed
                ? MainAxisAlignment.center
                : MainAxisAlignment.start,
            children: [
              Icon(
                widget.icon,
                size: 18,
                color: fg.withValues(alpha: 0.90),
              ),
              if (!widget.collapsed) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight:
                          widget.active ? FontWeight.w500 : FontWeight.w400,
                      color: fg,
                    ),
                  ),
                ),
                if (widget.trailing != null)
                  Text(
                    widget.trailing!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.zinc400,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );

    if (widget.collapsed) {
      tile = Tooltip(message: widget.label, child: tile);
    }

    return tile;
  }
}

class _SidebarLibraryRow extends StatefulWidget {
  const _SidebarLibraryRow({
    required this.title,
    required this.subtitle,
    required this.collapsed,
    required this.active,
    required this.cover,
    required this.onTap,
    required this.onPlayToggle,
    this.isPinned = false,
    this.isPlayingContext = false,
    this.isGlobalPlaying = false,
  });

  final String title;
  final String subtitle;
  final bool collapsed;
  final bool active;
  final Widget cover;
  final VoidCallback onTap;
  final VoidCallback onPlayToggle;
  final bool isPinned;
  final bool isPlayingContext;
  final bool isGlobalPlaying;

  @override
  State<_SidebarLibraryRow> createState() => _SidebarLibraryRowState();
}

class _SidebarLibraryRowState extends State<_SidebarLibraryRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.active
        ? AppTheme.zinc800
        : (_hovered
            ? AppTheme.zinc800.withValues(alpha: 0.60)
            : Colors.transparent);

    final showPause = widget.isPlayingContext && widget.isGlobalPlaying;

    Widget coverWithOverlay = SizedBox(
      width: 48,
      height: 48,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.cover,
          IgnorePointer(
            ignoring: !_hovered,
            child: AnimatedOpacity(
              opacity: _hovered ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 150),
              child: GestureDetector(
                onTap: widget.onPlayToggle,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    showPause ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: 24,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    Widget row = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(6),
          ),
          child: widget.collapsed
              ? Center(child: coverWithOverlay)
              : Row(
                  children: [
                    coverWithOverlay,
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              height: 1.3,
                              fontWeight: widget.isPlayingContext
                                  ? FontWeight.w500
                                  : FontWeight.w400,
                              color: widget.isPlayingContext
                                  ? AppTheme.accent400
                                  : AppTheme.zinc50,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              if (widget.isPinned) ...[
                                const Icon(
                                  Icons.push_pin_rounded,
                                  size: 14,
                                  color: AppTheme.accent400,
                                ),
                                const SizedBox(width: 4),
                              ],
                              Expanded(
                                child: Text(
                                  widget.subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    height: 1.3,
                                    color: AppTheme.zinc400,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (widget.isPlayingContext) ...[
                      const SizedBox(width: 6),
                      const Icon(
                        Icons.volume_up_rounded,
                        size: 16,
                        color: AppTheme.accent400,
                      ),
                    ],
                  ],
                ),
        ),
      ),
    );

    if (widget.collapsed) {
      row = Tooltip(message: widget.title, child: row);
    }

    return row;
  }
}
