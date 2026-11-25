import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/platform/android_audio_bridge.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/albums_view.dart';
import 'package:neomodern/ui/artists_view.dart';
import 'package:neomodern/ui/cover_art.dart';
import 'package:neomodern/ui/favorites_view.dart';
import 'package:neomodern/ui/home_view.dart';
import 'package:neomodern/ui/mobile/mini_player.dart';
import 'package:neomodern/ui/playlists_view.dart';
import 'package:neomodern/ui/profiles_dialog.dart';
import 'package:neomodern/ui/recap_view.dart';
import 'package:neomodern/ui/settings_view.dart';
import 'package:neomodern/ui/songs_view.dart';
import 'package:neomodern/ui/sources_view.dart';
import 'package:neomodern/ui/track_menu.dart';

enum MobileNavTab {
  home,
  library,
  recap,
  settings,
}

enum MobileLibrarySection {
  songs,
  albums,
  artists,
  favorites,
  playlists,
  sources,
}

class MobileShell extends StatefulWidget {
  const MobileShell({super.key, required this.controller});

  final PlayerController controller;

  @override
  State<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<MobileShell> {
  MobileNavTab _tab = MobileNavTab.home;
  MobileLibrarySection _librarySection = MobileLibrarySection.songs;
  PlatformInt64? _selectedPlaylistId;

  PlatformInt64? _externalAlbumId;
  int _externalAlbumNonce = 0;

  String? _externalArtistName;
  int _externalArtistNonce = 0;

  bool _hasAudioPermission = true;
  bool _requestingPermission = false;

  @override
  void initState() {
    super.initState();
    if (AndroidPlatformBridge.isAndroid) {
      unawaited(_checkAudioPermission());
    }
  }

  Future<void> _checkAudioPermission() async {
    try {
      final granted = await AndroidPlatformBridge.checkAudioPermission();
      if (mounted && granted != _hasAudioPermission) {
        setState(() => _hasAudioPermission = granted);
      }
    } catch (_) {}
  }

  Future<void> _requestAudioPermissionAndScan() async {
    if (_requestingPermission) return;
    setState(() => _requestingPermission = true);
    try {
      final granted = await AndroidPlatformBridge.requestAudioPermission();
      if (!mounted) return;
      setState(() {
        _hasAudioPermission = granted;
        _requestingPermission = false;
      });
      if (!granted) return;

      String? musicDir;
      try {
        musicDir = await defaultMusicDir();
      } catch (_) {}

      final ctrl = widget.controller;
      if (musicDir != null &&
          musicDir.isNotEmpty &&
          !ctrl.folders.any((f) => f.path == musicDir)) {
        await ctrl.addFolder(musicDir);
      }
      await ctrl.rescanLibrary();
    } catch (_) {
      if (mounted) {
        setState(() => _requestingPermission = false);
      }
    }
  }

  Future<void> _scanQrCode() async {
    String? scanned;
    try {
      scanned = await AndroidPlatformBridge.scanQrCode();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('QR scan failed: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final code = scanned?.trim();
    if (code == null || code.isEmpty || !mounted) return;

    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Row(
          children: [
            Icon(
              Icons.qr_code_scanner_rounded,
              size: 20,
              color: AppColors.accent,
            ),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Scanned QR Code',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Pairing / party code detected:',
              style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.canvas,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.border),
              ),
              child: SelectableText(
                code,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              unawaited(Clipboard.setData(ClipboardData(text: code)));
              Navigator.of(dialogCtx).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Copied QR code to clipboard.'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: AppColors.canvas,
            ),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  void _openAlbum(PlatformInt64 albumId) {
    setState(() {
      _tab = MobileNavTab.library;
      _librarySection = MobileLibrarySection.albums;
      _externalAlbumId = albumId;
      _externalAlbumNonce++;
    });
  }

  void _openArtist(String name) {
    setState(() {
      _tab = MobileNavTab.library;
      _librarySection = MobileLibrarySection.artists;
      _externalArtistName = name;
      _externalArtistNonce++;
    });
  }

  void _openFavorites() {
    setState(() {
      _tab = MobileNavTab.library;
      _librarySection = MobileLibrarySection.favorites;
    });
  }

  void _openSettings() {
    setState(() => _tab = MobileNavTab.settings);
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
      setState(() {
        _tab = MobileNavTab.library;
        _librarySection = MobileLibrarySection.playlists;
        _selectedPlaylistId = created.id;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final sourcesEnabled = ctrl.hasEnabledSourceProviders;
    final effectiveLibrarySection =
        (_librarySection == MobileLibrarySection.sources && !sourcesEnabled)
            ? MobileLibrarySection.songs
            : _librarySection;

    return Scaffold(
      body: Stack(
        children: [
          Column(
            children: [
              // Compact mobile top app bar
              SafeArea(
                bottom: false,
                child: Container(
                  height: 56,
                  padding: const EdgeInsets.only(left: 14, right: 2),
                  decoration: const BoxDecoration(
                    color: AppColors.sidebar,
                    border: Border(
                      bottom: BorderSide(color: AppColors.border),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: AppColors.accentMuted,
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: const Icon(
                          Icons.headphones_rounded,
                          size: 16,
                          color: AppColors.accent,
                        ),
                      ),
                      const SizedBox(width: 9),
                      const Expanded(
                        child: Text(
                          'NeoModern',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                      if (AndroidPlatformBridge.isAndroid)
                        IconButton(
                          tooltip: 'Scan QR',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 36,
                            minHeight: 36,
                          ),
                          icon: const Icon(
                            Icons.qr_code_scanner_rounded,
                            size: 20,
                            color: AppColors.textPrimary,
                          ),
                          onPressed: _scanQrCode,
                        ),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 148),
                        child: Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: ProfileBadgeButton(
                            controller: ctrl,
                            onTap: () => showProfilesDialog(context, ctrl),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              if (!_hasAudioPermission)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.accent.withAlpha(110)),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.library_music_rounded,
                        size: 20,
                        color: AppColors.accent,
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Allow access to your music files',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Grant audio permission to scan and play songs on your device.',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      FilledButton(
                        onPressed: _requestingPermission
                            ? null
                            : _requestAudioPermissionAndScan,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: AppColors.canvas,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          minimumSize: const Size(0, 34),
                        ),
                        child: Text(
                          _requestingPermission ? 'Waiting...' : 'Allow',
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

              if (ctrl.lastError != null)
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  color: AppColors.danger.withAlpha(36),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        size: 16,
                        color: AppColors.danger,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          ctrl.lastError!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
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

              // Main content area
              Expanded(
                child: switch (_tab) {
                  MobileNavTab.home => HomeView(
                      controller: ctrl,
                      onOpenAlbum: _openAlbum,
                      onOpenArtist: _openArtist,
                      onOpenFavorites: _openFavorites,
                      onOpenSettings: _openSettings,
                    ),
                  MobileNavTab.library => Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _LibraryFilterBar(
                          selected: effectiveLibrarySection,
                          sourcesEnabled: sourcesEnabled,
                          onSelect: (section) =>
                              setState(() => _librarySection = section),
                        ),
                        Expanded(
                          child: switch (effectiveLibrarySection) {
                            MobileLibrarySection.songs => SongsView(
                                controller: ctrl,
                                onOpenArtist: _openArtist,
                                onOpenAlbum: _openAlbum,
                                onOpenSettings: _openSettings,
                              ),
                            MobileLibrarySection.albums => AlbumsView(
                                controller: ctrl,
                                externalAlbumId: _externalAlbumId,
                                externalSelectionNonce: _externalAlbumNonce,
                                onOpenArtist: _openArtist,
                                onOpenAlbum: _openAlbum,
                                onOpenSettings: _openSettings,
                              ),
                            MobileLibrarySection.artists => ArtistsView(
                                controller: ctrl,
                                externalArtistName: _externalArtistName,
                                externalSelectionNonce: _externalArtistNonce,
                                onOpenAlbum: _openAlbum,
                                onOpenArtist: _openArtist,
                              ),
                            MobileLibrarySection.favorites => FavoritesView(
                                controller: ctrl,
                                onOpenArtist: _openArtist,
                                onOpenAlbum: _openAlbum,
                              ),
                            MobileLibrarySection.playlists =>
                              _buildPlaylistsContent(ctrl),
                            MobileLibrarySection.sources =>
                              SourcesView(controller: ctrl),
                          },
                        ),
                      ],
                    ),
                  MobileNavTab.recap => RecapView(
                      controller: ctrl,
                      onOpenArtist: _openArtist,
                      onOpenAlbum: _openAlbum,
                    ),
                  MobileNavTab.settings => SettingsView(controller: ctrl),
                },
              ),

              // Docked MiniPlayer directly above the bottom navigation bar
              MiniPlayer(
                controller: ctrl,
                onOpenArtist: _openArtist,
              ),
            ],
          ),
          if (ctrl.isProfileLocked) ProfileLockOverlay(controller: ctrl),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: AppColors.sidebar,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: BottomNavigationBar(
          type: BottomNavigationBarType.fixed,
          backgroundColor: AppColors.sidebar,
          elevation: 0,
          currentIndex: _tab.index,
          selectedItemColor: AppColors.accent,
          unselectedItemColor: AppColors.textSecondary,
          selectedFontSize: 11.5,
          unselectedFontSize: 11.5,
          onTap: (index) => setState(() => _tab = MobileNavTab.values[index]),
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.home_rounded),
              label: 'Home',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.library_music_rounded),
              label: 'Library',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.bar_chart_rounded),
              label: 'Recap',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.settings_rounded),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaylistsContent(PlayerController ctrl) {
    final playlists = ctrl.playlists;
    final selectedExists = _selectedPlaylistId != null &&
        playlists.any((p) => p.id == _selectedPlaylistId);

    if (selectedExists) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.border)),
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => _selectedPlaylistId = null),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.textSecondary,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                ),
                icon: const Icon(Icons.arrow_back_rounded, size: 17),
                label: const Text('All Playlists'),
              ),
            ),
          ),
          Expanded(
            child: PlaylistsView(
              playlistId: _selectedPlaylistId!,
              controller: ctrl,
              onPlaylistDeleted: () =>
                  setState(() => _selectedPlaylistId = null),
              onOpenArtist: _openArtist,
              onOpenAlbum: _openAlbum,
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Playlists',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  Text(
                    '${playlists.length} ${playlists.length == 1 ? 'playlist' : 'playlists'}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _createPlaylist,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: AppColors.canvas,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text(
                  'New Playlist',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: AppColors.border),
        Expanded(
          child: playlists.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No playlists yet. Tap "New Playlist" to create one.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: playlists.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, color: AppColors.border),
                  itemBuilder: (context, index) {
                    final pl = playlists[index];
                    return ListTile(
                      leading: CollageCover(
                        coverPaths: pl.albumCovers,
                        size: 46,
                        borderRadius: 6,
                      ),
                      title: Text(
                        pl.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      subtitle: Text(
                        '${pl.trackCount} ${pl.trackCount == 1 ? 'track' : 'tracks'}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      trailing: const Icon(
                        Icons.chevron_right_rounded,
                        color: AppColors.textMuted,
                      ),
                      onTap: () => setState(() => _selectedPlaylistId = pl.id),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _LibraryFilterBar extends StatelessWidget {
  const _LibraryFilterBar({
    required this.selected,
    required this.sourcesEnabled,
    required this.onSelect,
  });

  final MobileLibrarySection selected;
  final bool sourcesEnabled;
  final ValueChanged<MobileLibrarySection> onSelect;

  @override
  Widget build(BuildContext context) {
    final pills = <(MobileLibrarySection, String)>[
      (MobileLibrarySection.songs, 'Songs'),
      (MobileLibrarySection.albums, 'Albums'),
      (MobileLibrarySection.artists, 'Artists'),
      (MobileLibrarySection.favorites, 'Favorites'),
      (MobileLibrarySection.playlists, 'Playlists'),
      if (sourcesEnabled) (MobileLibrarySection.sources, 'Sources'),
    ];

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.canvas,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            for (var i = 0; i < pills.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              _FilterPill(
                label: pills[i].$2,
                active: selected == pills[i].$1,
                onTap: () => onSelect(pills[i].$1),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  const _FilterPill({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? AppColors.accentMuted : AppColors.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: active ? AppColors.accent : AppColors.border,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              color: active ? AppColors.accent : AppColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
