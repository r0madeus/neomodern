import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/platform/android_audio_bridge.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_icons.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';
import 'package:neomodern/ui/mobile/mini_player.dart';
import 'package:neomodern/ui/mobile/mobile_detail_pages.dart';
import 'package:neomodern/ui/mobile/mobile_sheet.dart';
import 'package:neomodern/ui/online_album_dialog.dart';
import 'package:neomodern/ui/profiles_dialog.dart';
import 'package:neomodern/ui/sources_view.dart';
import 'package:neomodern/ui/track_menu.dart';
import 'package:neomodern/ui/widgets/motion_primitives.dart';
import 'package:neomodern/ui/widgets/neomodern_logo.dart';

enum MobileNavTab {
  home,
  search,
  library,
}

enum _HomeFilter { all, mixes, albums }

enum _LibraryFilter { all, playlists, albums, artists, songs, favorites, sources }

enum _LibrarySort { recents, alpha }

class MobileShell extends StatefulWidget {
  const MobileShell({super.key, required this.controller});

  final PlayerController controller;

  @override
  State<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<MobileShell> {
  MobileNavTab _tab = MobileNavTab.home;
  String _searchInitialQuery = '';

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
        backgroundColor: AppTheme.zinc900,
        title: const Row(
          children: [
            Icon(
              Icons.qr_code_scanner_rounded,
              size: 20,
              color: AppTheme.accent500,
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
              style: TextStyle(fontSize: 12.5, color: AppTheme.zinc400),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.zinc950,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.zinc800),
              ),
              child: SelectableText(
                code,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.zinc100,
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
              backgroundColor: AppTheme.accent500,
              foregroundColor: AppTheme.zinc950,
            ),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  void _openAlbum(PlatformInt64 albumId) {
    unawaited(
      pushMobileSheet<void>(
        context,
        builder: (_) => MobileAlbumPage(
          controller: widget.controller,
          albumId: albumId,
          onOpenArtist: _openArtist,
        ),
      ),
    );
  }

  void _openArtist(String name) {
    unawaited(
      pushMobileSheet<void>(
        context,
        builder: (_) => MobileArtistPage(
          controller: widget.controller,
          artistName: name,
          onOpenAlbum: _openAlbum,
        ),
      ),
    );
  }

  void _openPlaylist(PlatformInt64 id) {
    unawaited(
      pushMobileSheet<void>(
        context,
        builder: (_) => MobilePlaylistPage(
          controller: widget.controller,
          playlistId: id,
          onOpenArtist: _openArtist,
          onOpenAlbum: _openAlbum,
        ),
      ),
    );
  }

  void _openMix(String mixId) {
    unawaited(
      pushMobileSheet<void>(
        context,
        builder: (_) => MobileMixPage(
          controller: widget.controller,
          mixId: mixId,
          onOpenArtist: _openArtist,
          onOpenAlbum: _openAlbum,
        ),
      ),
    );
  }

  void _openFavorites() {
    unawaited(
      pushMobileSheet<void>(
        context,
        builder: (_) => MobileFavoritesPage(
          controller: widget.controller,
          onOpenArtist: _openArtist,
          onOpenAlbum: _openAlbum,
        ),
      ),
    );
  }

  void _openSongs() {
    unawaited(
      pushMobileSheet<void>(
        context,
        builder: (_) => MobileSongsPage(
          controller: widget.controller,
          onOpenArtist: _openArtist,
          onOpenAlbum: _openAlbum,
        ),
      ),
    );
  }

  void _openRecap() {
    unawaited(
      pushMobileSheet<void>(
        context,
        builder: (_) => MobileRecapPage(
          controller: widget.controller,
          onOpenArtist: _openArtist,
          onOpenAlbum: _openAlbum,
        ),
      ),
    );
  }

  void _openSettings() {
    unawaited(
      pushMobileSheet<void>(
        context,
        builder: (_) => MobileSettingsPage(controller: widget.controller),
      ),
    );
  }

  void _openGenre(String genre) {
    unawaited(
      pushMobileSheet<void>(
        context,
        builder: (_) => MobileGenrePage(
          name: genre,
          controller: widget.controller,
          onOpenArtist: _openArtist,
          onOpenAlbum: _openAlbum,
        ),
      ),
    );
  }

  void _selectTab(MobileNavTab next) {
    if (_tab == next) return;
    setState(() {
      if (next != MobileNavTab.search) {
        _searchInitialQuery = '';
      }
      _tab = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: AppTheme.zinc950,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Column(
            children: [
              if (!_hasAudioPermission)
                SafeArea(
                  bottom: false,
                  child: Container(
                    width: double.infinity,
                    margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.zinc900,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: AppTheme.accent500.withAlpha(110),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          AppIcons.library,
                          size: 20,
                          color: AppTheme.accent500,
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
                                  color: AppTheme.zinc100,
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'Grant audio permission to scan and play songs on your device.',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: AppTheme.zinc400,
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
                            backgroundColor: AppTheme.accent500,
                            foregroundColor: AppTheme.zinc950,
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
                ),

              if (ctrl.lastError != null)
                SafeArea(
                  bottom: false,
                  top: _hasAudioPermission,
                  child: Container(
                    width: double.infinity,
                    margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppTheme.danger.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.warning_amber_rounded,
                          size: 16,
                          color: AppTheme.danger,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            ctrl.lastError!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppTheme.zinc100,
                            ),
                          ),
                        ),
                        IconButton(
                          iconSize: 16,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: const Icon(AppIcons.close),
                          onPressed: ctrl.clearError,
                        ),
                      ],
                    ),
                  ),
                ),

              // Active tab view wrapped in ViewFadeIn
              Expanded(
                child: ViewFadeIn(
                  key: ValueKey(_tab),
                  child: switch (_tab) {
                    MobileNavTab.home => _HomeTab(
                        controller: ctrl,
                        hasPermissionBanner: !_hasAudioPermission,
                        onOpenAlbum: _openAlbum,
                        onOpenPlaylist: _openPlaylist,
                        onOpenMix: _openMix,
                        onOpenFavorites: _openFavorites,
                        onOpenSongs: _openSongs,
                        onOpenRecap: _openRecap,
                        onOpenSettings: _openSettings,
                        onScanQr:
                            AndroidPlatformBridge.isAndroid ? _scanQrCode : null,
                      ),
                    MobileNavTab.search => _SearchTab(
                        controller: ctrl,
                        initialQuery: _searchInitialQuery,
                        onOpenAlbum: _openAlbum,
                        onOpenArtist: _openArtist,
                        onOpenGenre: _openGenre,
                      ),
                    MobileNavTab.library => _LibraryTab(
                        controller: ctrl,
                        onOpenPlaylist: _openPlaylist,
                        onOpenAlbum: _openAlbum,
                        onOpenArtist: _openArtist,
                        onOpenFavorites: _openFavorites,
                        onOpenSongs: _openSongs,
                        onOpenSettings: _openSettings,
                      ),
                  },
                ),
              ),
            ],
          ),

          // Floating bottom gradient scrim + MiniPlayer + 3-tab bottom bar
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.0, 0.45, 1.0],
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.75),
                    Colors.black.withValues(alpha: 0.95),
                  ],
                ),
              ),
              child: Padding(
                padding: EdgeInsets.only(top: 40, bottom: bottomInset),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MiniPlayer(
                      controller: ctrl,
                      onOpenArtist: _openArtist,
                      onOpenAlbum: (id) =>
                          _openAlbum(PlatformInt64Util.from(id)),
                    ),
                    _MobileBottomTabBar(
                      key: const ValueKey('mobile_bottom_nav'),
                      current: _tab,
                      onSelect: _selectTab,
                    ),
                  ],
                ),
              ),
            ),
          ),

          if (ctrl.isProfileLocked) ProfileLockOverlay(controller: ctrl),
        ],
      ),
    );
  }
}

class _MobileBottomTabBar extends StatelessWidget {
  const _MobileBottomTabBar({
    super.key,
    required this.current,
    required this.onSelect,
  });

  final MobileNavTab current;
  final ValueChanged<MobileNavTab> onSelect;

  @override
  Widget build(BuildContext context) {
    const items = [
      (MobileNavTab.home, AppIcons.home, AppIcons.home, 'Home'),
      (
        MobileNavTab.search,
        AppIcons.search,
        AppIcons.search,
        'Search',
      ),
      (
        MobileNavTab.library,
        AppIcons.library,
        AppIcons.library,
        'Library',
      ),
    ];

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          for (final entry in items)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onSelect(entry.$1),
                child: Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        current == entry.$1 ? entry.$2 : entry.$3,
                        size: 24,
                        color: current == entry.$1
                            ? Colors.white
                            : AppTheme.zinc400,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        t(entry.$4),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: current == entry.$1
                              ? FontWeight.w500
                              : FontWeight.w400,
                          color: current == entry.$1
                              ? Colors.white
                              : AppTheme.zinc400,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 1: Home (HomeTab.svelte parity)
// ---------------------------------------------------------------------------

class _HomeQuickTile {
  const _HomeQuickTile({
    required this.key,
    required this.isAlbum,
    required this.id,
    required this.title,
    this.cover,
    this.playlist,
  });

  final String key;
  final bool isAlbum;
  final PlatformInt64 id;
  final String title;
  final String? cover;
  final UiPlaylistInfo? playlist;
}

class _HomeTab extends StatefulWidget {
  const _HomeTab({
    required this.controller,
    required this.hasPermissionBanner,
    required this.onOpenAlbum,
    required this.onOpenPlaylist,
    required this.onOpenMix,
    required this.onOpenFavorites,
    required this.onOpenSongs,
    required this.onOpenRecap,
    required this.onOpenSettings,
    this.onScanQr,
  });

  final PlayerController controller;
  final bool hasPermissionBanner;
  final ValueChanged<PlatformInt64> onOpenAlbum;
  final ValueChanged<PlatformInt64> onOpenPlaylist;
  final ValueChanged<String> onOpenMix;
  final VoidCallback onOpenFavorites;
  final VoidCallback onOpenSongs;
  final VoidCallback onOpenRecap;
  final VoidCallback onOpenSettings;
  final VoidCallback? onScanQr;

  @override
  State<_HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<_HomeTab> {
  _HomeFilter _filter = _HomeFilter.all;

  List<_HomeQuickTile> _buildQuickTiles(
    PlayerController ctrl,
    UiHomeFeed? feed,
  ) {
    final tiles = <_HomeQuickTile>[];
    final seen = <String>{};

    for (final p in ctrl.pinnedItems) {
      final key = '${p.kind}:${p.targetId}';
      if (seen.contains(key)) continue;
      seen.add(key);
      UiPlaylistInfo? matchedPl;
      if (p.kind == 'playlist') {
        for (final pl in ctrl.playlists) {
          if (pl.id == p.targetId) {
            matchedPl = pl;
            break;
          }
        }
      }
      tiles.add(
        _HomeQuickTile(
          key: key,
          isAlbum: p.kind == 'album',
          id: p.targetId,
          title: p.title,
          cover: p.coverPath,
          playlist: matchedPl,
        ),
      );
      if (tiles.length >= 7) return tiles;
    }

    for (final pl in ctrl.playlists) {
      final key = 'playlist:${pl.id}';
      if (seen.contains(key)) continue;
      seen.add(key);
      tiles.add(
        _HomeQuickTile(
          key: key,
          isAlbum: false,
          id: pl.id,
          title: pl.name,
          cover: pl.cover,
          playlist: pl,
        ),
      );
      if (tiles.length >= 7) return tiles;
    }

    final albumSource = (feed != null && feed.recentlyPlayedAlbums.isNotEmpty)
        ? feed.recentlyPlayedAlbums
        : (feed?.recentlyAddedAlbums ?? const <UiAlbumRow>[]);
    for (final a in albumSource) {
      final key = 'album:${a.id}';
      if (seen.contains(key)) continue;
      seen.add(key);
      tiles.add(
        _HomeQuickTile(
          key: key,
          isAlbum: true,
          id: a.id,
          title: a.title,
          cover: a.cover,
        ),
      );
      if (tiles.length >= 7) break;
    }
    return tiles;
  }

  Future<void> _shuffleAll() async {
    final ctrl = widget.controller;
    if (ctrl.trackCount == 0) return;
    if (!ctrl.snapshot.shuffle) {
      await ctrl.toggleShuffle();
    }
    final startIdx = math.Random().nextInt(ctrl.trackCount);
    await ctrl.playAllFromSearch(startIdx);
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final feed = ctrl.homeFeed;
    final topInset =
        widget.hasPermissionBanner ? 0.0 : MediaQuery.paddingOf(context).top;
    final screenW = MediaQuery.sizeOf(context).width;
    final cardWidth = (screenW * 0.42).clamp(132.0, 176.0);
    final hasAnyContent = ctrl.trackCount > 0 ||
        (feed?.hasHistory ?? false) ||
        ctrl.favoriteCount > 0 ||
        (feed?.mixes.isNotEmpty ?? false);

    return CustomScrollView(
      slivers: [
        // Sticky #111318 top bar with ProfileBadgeButton + scrollable chips
        SliverPersistentHeader(
          pinned: true,
          delegate: _StickyHomeBarDelegate(
            height: topInset + 64,
            topInset: topInset,
            child: Container(
              color: AppTheme.zinc950,
              padding: EdgeInsets.fromLTRB(12, topInset + 10, 8, 8),
              child: Row(
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 124),
                    child: Transform.translate(
                      offset: const Offset(0, 6),
                      child: ProfileBadgeButton(
                        controller: ctrl,
                        onTap: () => showProfilesDialog(context, ctrl),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: ShaderMask(
                      shaderCallback: (rect) => const LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        stops: [0.0, 0.88, 1.0],
                        colors: [
                          Colors.black,
                          Colors.black,
                          Colors.transparent,
                        ],
                      ).createShader(rect),
                      blendMode: BlendMode.dstIn,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.only(right: 20),
                        child: Row(
                          children: [
                            _HomeChip(
                              label: 'All',
                              active: _filter == _HomeFilter.all,
                              onTap: () =>
                                  setState(() => _filter = _HomeFilter.all),
                            ),
                            const SizedBox(width: 8),
                            _HomeChip(
                              label: 'Mixes',
                              active: _filter == _HomeFilter.mixes,
                              onTap: () =>
                                  setState(() => _filter = _HomeFilter.mixes),
                            ),
                            const SizedBox(width: 8),
                            _HomeChip(
                              label: t('Albums'),
                              active: _filter == _HomeFilter.albums,
                              onTap: () =>
                                  setState(() => _filter = _HomeFilter.albums),
                            ),
                            const SizedBox(width: 8),
                            _HomeChip(
                              label: t('Songs'),
                              onTap: widget.onOpenSongs,
                            ),
                            const SizedBox(width: 8),
                            _HomeChip(
                              label: t('Shuffle'),
                              icon: AppIcons.shuffle,
                              onTap: _shuffleAll,
                            ),
                            const SizedBox(width: 8),
                            _HomeChip(
                              label: t('Recap'),
                              icon: AppIcons.recap,
                              onTap: widget.onOpenRecap,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (widget.onScanQr != null)
                    IconButton(
                      tooltip: 'Scan QR',
                      padding: const EdgeInsets.all(6),
                      constraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 36,
                      ),
                      icon: const Icon(
                        Icons.qr_code_scanner_rounded,
                        size: 20,
                        color: AppTheme.zinc100,
                      ),
                      onPressed: widget.onScanQr,
                    ),
                ],
              ),
            ),
          ),
        ),

        if (!hasAnyContent)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                28,
                24,
                28,
                mobileBottomClearance(context, ctrl),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: AppTheme.accent500.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    alignment: Alignment.center,
                    child: const NeoModernLogo(
                      size: 32,
                      color: AppTheme.accent500,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    t('Welcome to NeoModern'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.zinc50,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    t(
                      'Add a music folder in Settings to scan your local collection.',
                    ),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 13.5,
                      color: AppTheme.zinc400,
                    ),
                  ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: widget.onOpenSettings,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.accent500,
                      foregroundColor: AppTheme.zinc950,
                    ),
                    icon: const Icon(Icons.folder_open_rounded, size: 18),
                    label: Text(t('Open Folder Settings')),
                  ),
                ],
              ),
            ),
          )
        else
          SliverPadding(
            padding: EdgeInsets.only(
              bottom: mobileBottomClearance(context, ctrl),
            ),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                // 2-column 56px quick access grid
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 22),
                  child: _buildQuickGrid(ctrl, feed),
                ),

                // Daily Mixes carousel
                if (_filter == _HomeFilter.all || _filter == _HomeFilter.mixes)
                  if (feed != null && feed.mixes.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Container(
                        padding: const EdgeInsets.only(bottom: 6),
                        decoration: const BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: AppTheme.hairline),
                          ),
                        ),
                        child: Text(
                          'Daily Mixes',
                          style: AppTheme.displayStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w400,
                            color: AppTheme.editorialPaper,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      height: cardWidth + 62,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: feed.mixes.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 14),
                        itemBuilder: (context, i) {
                          final mix = feed.mixes[i];
                          return GestureDetector(
                            onTap: () => widget.onOpenMix(mix.id),
                            child: SizedBox(
                              width: cardWidth,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  MixCoverArt(
                                    mix: mix,
                                    size: cardWidth,
                                    borderRadius: 3,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    mix.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: AppTheme.zinc50,
                                    ),
                                  ),
                                  if (mix.subtitle.isNotEmpty)
                                    Text(
                                      mix.subtitle,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: AppTheme.zinc400,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],

                // Recently Played albums shelf
                if ((_filter == _HomeFilter.all ||
                        _filter == _HomeFilter.albums) &&
                    feed != null &&
                    feed.recentlyPlayedAlbums.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Container(
                      padding: const EdgeInsets.only(bottom: 6),
                      decoration: const BoxDecoration(
                        border: Border(
                          bottom: BorderSide(color: AppTheme.hairline),
                        ),
                      ),
                      child: Text(
                        t('Recently Played'),
                        style: AppTheme.displayStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w400,
                          color: AppTheme.editorialPaper,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                  ),
                  _AlbumShelf(
                    albums: feed.recentlyPlayedAlbums,
                    cardWidth: cardWidth,
                    onTap: widget.onOpenAlbum,
                  ),
                  const SizedBox(height: 22),
                ],

                // Recently Played tracks
                if (_filter == _HomeFilter.all &&
                    feed != null &&
                    feed.recentlyPlayedTracks.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Text(
                      'Recently played tracks',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.zinc50,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),
                  for (final item in feed.recentlyPlayedTracks.take(6))
                    MobileTrackTile(
                      controller: ctrl,
                      track: item.track,
                      onTap: () => ctrl.playTracks([item.track.path], 0),
                      onOpenAlbum: widget.onOpenAlbum,
                    ),
                  const SizedBox(height: 16),
                ],

                // Favorites preview
                if ((_filter == _HomeFilter.all ||
                        _filter == _HomeFilter.mixes) &&
                    ctrl.favoriteTracks.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            t('Favorites'),
                            style: const TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.zinc50,
                              letterSpacing: -0.3,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: widget.onOpenFavorites,
                          style: TextButton.styleFrom(
                            foregroundColor: AppTheme.accent400,
                          ),
                          child: const Text('See all'),
                        ),
                      ],
                    ),
                  ),
                  for (var i = 0;
                      i < math.min(4, ctrl.favoriteTracks.length);
                      i++)
                    MobileTrackTile(
                      controller: ctrl,
                      track: ctrl.favoriteTracks[i],
                      onTap: () => ctrl.playFavorites(i),
                      onOpenAlbum: widget.onOpenAlbum,
                    ),
                  const SizedBox(height: 16),
                ],

                // Recently Added albums shelf
                if ((_filter == _HomeFilter.all ||
                        _filter == _HomeFilter.albums) &&
                    feed != null &&
                    feed.recentlyAddedAlbums.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Text(
                      t('Recently Added'),
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.zinc50,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),
                  _AlbumShelf(
                    albums: feed.recentlyAddedAlbums,
                    cardWidth: cardWidth,
                    onTap: widget.onOpenAlbum,
                  ),
                ],
              ]),
            ),
          ),
      ],
    );
  }

  Widget _buildQuickGrid(PlayerController ctrl, UiHomeFeed? feed) {
    final tiles = _buildQuickTiles(ctrl, feed);
    final entries = <Widget>[
      _QuickGridButton(
        title: t('Favorites'),
        leading: Container(
          width: 56,
          height: 56,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF4F46E5),
                AppTheme.accent500,
                AppTheme.accent300,
              ],
            ),
          ),
          alignment: Alignment.center,
          child: const Icon(Icons.star_rounded, size: 24, color: Colors.white),
        ),
        onTap: widget.onOpenFavorites,
      ),
      for (final tile in tiles)
        _QuickGridButton(
          title: tile.title,
          leading: tile.isAlbum
              ? CoverArt(
                  path: tile.cover,
                  size: 56,
                  borderRadius: 0,
                  iconSize: 20,
                )
              : (tile.playlist != null
                  ? PlaylistCoverWidget(
                      playlist: tile.playlist!,
                      size: 56,
                      borderRadius: 0,
                    )
                  : CoverArt(
                      path: tile.cover,
                      size: 56,
                      borderRadius: 0,
                      iconSize: 20,
                      fallbackIcon: AppIcons.queue,
                    )),
          onTap: () => tile.isAlbum
              ? widget.onOpenAlbum(tile.id)
              : widget.onOpenPlaylist(tile.id),
        ),
    ];

    final rows = <Widget>[];
    for (var i = 0; i < entries.length; i += 2) {
      rows.add(
        Row(
          children: [
            Expanded(child: entries[i]),
            const SizedBox(width: 8),
            Expanded(
              child: i + 1 < entries.length
                  ? entries[i + 1]
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      );
      if (i + 2 < entries.length) {
        rows.add(const SizedBox(height: 8));
      }
    }
    return Column(children: rows);
  }
}

class _StickyHomeBarDelegate extends SliverPersistentHeaderDelegate {
  const _StickyHomeBarDelegate({
    required this.height,
    required this.topInset,
    required this.child,
  });

  final double height;
  final double topInset;
  final Widget child;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return child;
  }

  @override
  bool shouldRebuild(covariant _StickyHomeBarDelegate oldDelegate) =>
      height != oldDelegate.height ||
      topInset != oldDelegate.topInset ||
      child != oldDelegate.child;
}

class _HomeChip extends StatelessWidget {
  const _HomeChip({
    required this.label,
    required this.onTap,
    this.active = false,
    this.icon,
  });

  final String label;
  final VoidCallback onTap;
  final bool active;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active
          ? AppTheme.accent500
          : AppTheme.zinc800.withValues(alpha: 0.90),
      borderRadius: BorderRadius.circular(9999),
      child: InkWell(
        borderRadius: BorderRadius.circular(9999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 14,
                  color: active ? AppTheme.zinc950 : AppTheme.accent400,
                ),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color: active ? AppTheme.zinc950 : AppTheme.zinc100,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickGridButton extends StatelessWidget {
  const _QuickGridButton({
    required this.title,
    required this.leading,
    required this.onTap,
  });

  final String title;
  final Widget leading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.zinc900,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              leading,
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.15,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.zinc50,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlbumShelf extends StatelessWidget {
  const _AlbumShelf({
    required this.albums,
    required this.cardWidth,
    required this.onTap,
  });

  final List<UiAlbumRow> albums;
  final double cardWidth;
  final ValueChanged<PlatformInt64> onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: cardWidth + 54,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: albums.length,
        separatorBuilder: (_, _) => const SizedBox(width: 14),
        itemBuilder: (context, i) {
          final album = albums[i];
          return GestureDetector(
            onTap: () => onTap(album.id),
            child: SizedBox(
              width: cardWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CoverArt(
                    path: album.cover,
                    size: cardWidth,
                    borderRadius: 8,
                    iconSize: 36,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    album.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.zinc50,
                    ),
                  ),
                  if (album.albumArtist.isNotEmpty)
                    Text(
                      album.albumArtist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.zinc400,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 2: Search (SearchTab.svelte parity)
// ---------------------------------------------------------------------------

class _BrowseCategory {
  const _BrowseCategory({
    required this.name,
    required this.subtitle,
    this.coverPath,
  });

  final String name;
  final String subtitle;
  final String? coverPath;
}

class _SearchTab extends StatefulWidget {
  const _SearchTab({
    required this.controller,
    required this.initialQuery,
    required this.onOpenAlbum,
    required this.onOpenArtist,
    required this.onOpenGenre,
  });

  final PlayerController controller;
  final String initialQuery;
  final ValueChanged<PlatformInt64> onOpenAlbum;
  final ValueChanged<String> onOpenArtist;
  final ValueChanged<String> onOpenGenre;

  @override
  State<_SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<_SearchTab> {
  static const List<String> _defaultCategories = [
    'Electronic',
    'Rock',
    'Indie',
    'Pop',
    'Jazz',
    'Hip-Hop',
    'Ambient',
    'Classical',
    'Synthwave',
    'Lo-Fi',
  ];

  late final TextEditingController _searchCtrl = TextEditingController(
    text: widget.initialQuery,
  );
  Timer? _debounce;
  List<UiGenreInfo> _genres = const [];
  String _loadedQuery = '';
  List<UiArtistRow> _artists = const [];
  List<UiAlbumRow> _albums = const [];
  List<UiTrackRow> _tracks = const [];
  List<UiExternalTrack> _externalTracks = const [];
  bool _searchingExternal = false;
  int _searchEpoch = 0;

  String _onlineQuery = '';
  List<UiOnlineAlbum> _onlineAlbums = const [];
  List<UiOnlineTrack> _onlineTracks = const [];
  bool _searchingOnline = false;
  String? _onlineError;
  int _onlineSearchEpoch = 0;
  final Set<String> _downloadingTrackIds = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_loadGenres());
    if (widget.initialQuery.isNotEmpty) {
      unawaited(_runSearch(widget.initialQuery.trim()));
    }
  }

  @override
  void didUpdateWidget(covariant _SearchTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialQuery != oldWidget.initialQuery &&
        widget.initialQuery != _searchCtrl.text) {
      _searchCtrl.text = widget.initialQuery;
      unawaited(_runSearch(widget.initialQuery.trim()));
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadGenres() async {
    if (!widget.controller.initialized) return;
    try {
      final rows = await widget.controller.fetchGenres();
      if (!mounted) return;
      setState(() => _genres = rows);
    } catch (_) {}
  }

  void _onChanged(String value) {
    final trimmed = value.trim();
    setState(() {});
    _debounce?.cancel();
    if (trimmed.isEmpty) {
      _searchEpoch++;
      _onlineSearchEpoch++;
      setState(() {
        _loadedQuery = '';
        _artists = const [];
        _albums = const [];
        _tracks = const [];
        _externalTracks = const [];
        _searchingExternal = false;
        _onlineQuery = '';
        _onlineAlbums = const [];
        _onlineTracks = const [];
        _searchingOnline = false;
        _onlineError = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 160), () {
      if (!mounted) return;
      unawaited(_runSearch(trimmed));
    });
  }

  Future<void> _runSearch(String query) async {
    final epoch = ++_searchEpoch;
    final ctrl = widget.controller;
    if (query.isEmpty || !ctrl.initialized) {
      if (!mounted) return;
      setState(() {
        _loadedQuery = query;
        _artists = const [];
        _albums = const [];
        _tracks = const [];
        _externalTracks = const [];
        _searchingExternal = false;
      });
      return;
    }

    try {
      final results = await Future.wait([
        ctrl.searchArtists(query, limit: 12)
            .catchError((_) => const <UiArtistRow>[]),
        ctrl.searchAlbums(query, limit: 12)
            .catchError((_) => const <UiAlbumRow>[]),
        ctrl.searchTracks(query, limit: 25)
            .catchError((_) => const <UiTrackRow>[]),
      ]);
      if (!mounted || epoch != _searchEpoch) return;
      setState(() {
        _artists = results[0] as List<UiArtistRow>;
        _albums = results[1] as List<UiAlbumRow>;
        _tracks = results[2] as List<UiTrackRow>;
        _loadedQuery = query;
      });
    } catch (_) {}

    final enabledProviders = ctrl.enabledSourceProviders;
    if (enabledProviders.isEmpty) return;

    if (mounted && epoch == _searchEpoch) {
      setState(() => _searchingExternal = true);
    }
    try {
      final extLists = await Future.wait([
        for (final p in enabledProviders)
          ctrl
              .searchExternalSource(p.id, query, limit: 15)
              .catchError((_) => const <UiExternalTrack>[]),
      ]);
      if (!mounted || epoch != _searchEpoch) return;
      setState(() {
        _externalTracks = [for (final list in extLists) ...list];
        _searchingExternal = false;
      });
    } catch (_) {
      if (!mounted || epoch != _searchEpoch) return;
      setState(() => _searchingExternal = false);
    }
  }

  void _clear() {
    _debounce?.cancel();
    _searchCtrl.clear();
    _onChanged('');
  }

  Future<void> _runOnlineSearch([String? explicitQuery]) async {
    final query = (explicitQuery ?? _searchCtrl.text).trim();
    if (query.isEmpty) return;
    final epoch = ++_onlineSearchEpoch;
    setState(() {
      _onlineQuery = query;
      _searchingOnline = true;
      _onlineError = null;
    });
    try {
      final result = await widget.controller.searchOnline(query);
      if (!mounted || epoch != _onlineSearchEpoch) return;
      setState(() {
        _onlineAlbums = result.albums;
        _onlineTracks = result.tracks;
        _searchingOnline = false;
      });
    } catch (e) {
      if (!mounted || epoch != _onlineSearchEpoch) return;
      setState(() {
        _onlineAlbums = const [];
        _onlineTracks = const [];
        _onlineError = e.toString();
        _searchingOnline = false;
      });
    }
  }

  Future<void> _downloadOnlineTrack(UiOnlineTrack track) async {
    if (_downloadingTrackIds.contains(track.id)) return;
    setState(() => _downloadingTrackIds.add(track.id));
    final job = await widget.controller.downloadOnlineTrack(track);
    if (!mounted) return;
    setState(() => _downloadingTrackIds.remove(track.id));
    showOnlineDownloadSnackBar(
      context,
      queued: job != null,
      label: track.title,
      error: widget.controller.lastError,
    );
  }

  List<_BrowseCategory> _buildCategories(PlayerController ctrl) {
    if (_genres.isNotEmpty) {
      return [
        for (final g in _genres)
          _BrowseCategory(
            name: g.name,
            subtitle: g.trackCount == 1
                ? t('{n} track', {'n': g.trackCount})
                : t('{n} tracks', {'n': g.trackCount}),
            coverPath: g.coverPath,
          ),
      ];
    }

    final covers = <String>[];
    final feed = ctrl.homeFeed;
    if (feed != null) {
      for (final a in feed.recentlyPlayedAlbums) {
        if (a.cover != null && a.cover!.isNotEmpty) covers.add(a.cover!);
      }
      for (final a in feed.recentlyAddedAlbums) {
        if (a.cover != null && a.cover!.isNotEmpty) covers.add(a.cover!);
      }
    }
    for (var i = 0; i < math.min(ctrl.albumCount, 12); i++) {
      final a = ctrl.albumAt(i);
      if (a?.cover != null && a!.cover!.isNotEmpty) {
        covers.add(a.cover!);
      }
    }

    return [
      for (var i = 0; i < _defaultCategories.length; i++)
        _BrowseCategory(
          name: _defaultCategories[i],
          subtitle: t('Genre'),
          coverPath: covers.isNotEmpty ? covers[i % covers.length] : null,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final topInset = MediaQuery.paddingOf(context).top;
    final query = _searchCtrl.text.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16, topInset + 14, 16, 12),
          child: Text(
            t('Search'),
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: AppTheme.zinc50,
              letterSpacing: -0.4,
            ),
          ),
        ),
        // Crisp light search input bar (#F3F4F6 bg, #1A1C23 text, 8px radius)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Container(
            height: 46,
            decoration: BoxDecoration(
              color: AppTheme.zinc100,
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                const Icon(
                  AppIcons.search,
                  size: 20,
                  color: AppTheme.zinc600,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    onChanged: _onChanged,
                    onSubmitted: (_) => unawaited(_runOnlineSearch()),
                    style: const TextStyle(
                      fontSize: 15,
                      color: AppTheme.zinc900,
                    ),
                    cursorColor: AppTheme.zinc900,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                      hintText: 'Songs, artists or albums',
                      hintStyle: TextStyle(
                        fontSize: 15,
                        color: AppTheme.zinc500,
                      ),
                    ),
                  ),
                ),
                if (_searchCtrl.text.isNotEmpty)
                  IconButton(
                    tooltip: 'Clear search',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    icon: const Icon(
                      AppIcons.close,
                      size: 20,
                      color: AppTheme.zinc600,
                    ),
                    onPressed: _clear,
                  ),
              ],
            ),
          ),
        ),
        if (query.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: _searchingOnline
                    ? null
                    : () => unawaited(_runOnlineSearch(query)),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.accent500,
                  foregroundColor: AppTheme.zinc950,
                  disabledBackgroundColor: AppTheme.zinc800,
                  disabledForegroundColor: AppTheme.zinc400,
                  shape: const StadiumBorder(),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  minimumSize: const Size(0, 36),
                ),
                icon: _searchingOnline
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppTheme.zinc400,
                        ),
                      )
                    : const Icon(Icons.travel_explore_rounded, size: 17),
                label: Text(
                  _searchingOnline ? t('Searching...') : t('Search online'),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        Expanded(
          child: query.isEmpty
              ? _buildBrowseAll(context, ctrl)
              : _buildSearchResults(context, ctrl, query),
        ),
      ],
    );
  }

  Widget _buildBrowseAll(BuildContext context, PlayerController ctrl) {
    final categories = _buildCategories(ctrl);
    return ListView(
      padding: EdgeInsets.fromLTRB(
        16,
        4,
        16,
        mobileBottomClearance(context, ctrl),
      ),
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text(
            'Browse all',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppTheme.zinc50,
              letterSpacing: -0.2,
            ),
          ),
        ),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisExtent: 96,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: categories.length,
          itemBuilder: (context, index) {
            final cat = categories[index];
            return _GenreBrowseCard(
              category: cat,
              onTap: () => widget.onOpenGenre(cat.name),
            );
          },
        ),
      ],
    );
  }

  Widget _buildSearchResults(
    BuildContext context,
    PlayerController ctrl,
    String query,
  ) {
    final hasAnyLocal =
        _artists.isNotEmpty || _albums.isNotEmpty || _tracks.isNotEmpty;
    final hasExternalSection = ctrl.hasEnabledSourceProviders ||
        _externalTracks.isNotEmpty ||
        _searchingExternal;
    final hasOnlineSection =
        _searchingOnline || _onlineError != null || _onlineQuery.isNotEmpty;

    if (!hasAnyLocal &&
        !hasExternalSection &&
        !hasOnlineSection &&
        _loadedQuery == query) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No results for "$query"',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppTheme.zinc400,
            ),
          ),
        ),
      );
    }

    return ListView(
      padding: EdgeInsets.only(bottom: mobileBottomClearance(context, ctrl)),
      children: [
        if (!hasAnyLocal && _loadedQuery == query)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(
              t('No matches in your library.'),
              style: const TextStyle(
                fontSize: 13.5,
                color: AppTheme.zinc400,
              ),
            ),
          ),
        if (_artists.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              t('Artists'),
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppTheme.zinc50,
              ),
            ),
          ),
          SizedBox(
            height: 124,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _artists.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, i) {
                final ar = _artists[i];
                return GestureDetector(
                  onTap: () => widget.onOpenArtist(ar.name),
                  child: SizedBox(
                    width: 96,
                    child: Column(
                      children: [
                        ClipOval(
                          child: CoverArt(
                            path: ar.cover,
                            size: 92,
                            borderRadius: 0,
                            iconSize: 32,
                            fallbackIcon: AppIcons.artists,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          ar.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: AppTheme.zinc50,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (_albums.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              t('Albums'),
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppTheme.zinc50,
              ),
            ),
          ),
          SizedBox(
            height: 158,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _albums.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, i) {
                final a = _albums[i];
                return GestureDetector(
                  onTap: () => widget.onOpenAlbum(a.id),
                  child: SizedBox(
                    width: 112,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CoverArt(
                          path: a.cover,
                          size: 112,
                          borderRadius: 6,
                          iconSize: 32,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          a.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: AppTheme.zinc50,
                          ),
                        ),
                        Text(
                          a.albumArtist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: AppTheme.zinc400,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (_tracks.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              t('Songs'),
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppTheme.zinc50,
              ),
            ),
          ),
          for (var i = 0; i < _tracks.length; i++)
            MobileTrackTile(
              controller: ctrl,
              track: _tracks[i],
              onTap: () => ctrl.playTracks(
                _tracks.map((tr) => tr.path).toList(),
                i,
              ),
              onOpenArtist: widget.onOpenArtist,
              onOpenAlbum: widget.onOpenAlbum,
            ),
        ],
        if (hasExternalSection) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
            child: Text(
              t('External Sources'),
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppTheme.zinc50,
              ),
            ),
          ),
          if (_searchingExternal)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                t('Searching...'),
                style: const TextStyle(fontSize: 13, color: AppTheme.zinc400),
              ),
            )
          else if (_externalTracks.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                t('No matching tracks found.'),
                style: const TextStyle(fontSize: 13, color: AppTheme.zinc400),
              ),
            )
          else
            for (final tr in _externalTracks)
              ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                leading: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppTheme.zinc900,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppTheme.zinc800),
                  ),
                  child: const Icon(
                    AppIcons.songs,
                    size: 20,
                    color: AppTheme.accent400,
                  ),
                ),
                title: Text(
                  tr.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.zinc100,
                  ),
                ),
                subtitle: Text(
                  tr.album != null && tr.album!.isNotEmpty
                      ? '${tr.artist} · ${tr.album}'
                      : tr.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.zinc400,
                  ),
                ),
                trailing: IconButton(
                  tooltip: t('Play'),
                  icon: const Icon(
                    AppIcons.play,
                    color: AppTheme.accent400,
                  ),
                  onPressed: () => ctrl.playExternalTrack(tr),
                ),
                onTap: () => ctrl.playExternalTrack(tr),
              ),
        ],
        if (hasOnlineSection) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              t('Online'),
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppTheme.zinc50,
              ),
            ),
          ),
          if (_searchingOnline)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    t('Searching...'),
                    style: const TextStyle(
                      fontSize: 13.5,
                      color: AppTheme.zinc400,
                    ),
                  ),
                ],
              ),
            )
          else if (_onlineError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: OnlineErrorBanner(
                message: _onlineError!,
                onRetry: _onlineQuery.isNotEmpty
                    ? () => unawaited(_runOnlineSearch(_onlineQuery))
                    : null,
              ),
            )
          else if (_onlineAlbums.isEmpty && _onlineTracks.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                t('No matching tracks found.'),
                style: const TextStyle(
                  fontSize: 13.5,
                  color: AppTheme.zinc400,
                ),
              ),
            )
          else ...[
            if (_onlineAlbums.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  t('Online Albums'),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.zinc200,
                  ),
                ),
              ),
              SizedBox(
                height: 164,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _onlineAlbums.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 12),
                  itemBuilder: (context, i) {
                    final album = _onlineAlbums[i];
                    return GestureDetector(
                      onTap: () => unawaited(
                        showOnlineAlbumModal(
                          context,
                          controller: ctrl,
                          album: album,
                        ),
                      ),
                      child: SizedBox(
                        width: 112,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            OnlineCoverArt(
                              coverUrl: album.coverUrl,
                              coverPath: album.cover,
                              size: 112,
                              borderRadius: 6,
                              iconSize: 32,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              album.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: AppTheme.zinc50,
                              ),
                            ),
                            Text(
                              album.artist.isNotEmpty
                                  ? album.artist
                                  : t('Unknown Artist'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: AppTheme.zinc400,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 14),
            ],
            if (_onlineTracks.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text(
                  t('Online Songs'),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.zinc200,
                  ),
                ),
              ),
              for (var i = 0; i < _onlineTracks.length; i++)
                Builder(
                  builder: (context) {
                    final track = _onlineTracks[i];
                    final downloading = _downloadingTrackIds.contains(track.id);
                    final artist = track.artist.isNotEmpty
                        ? track.artist
                        : t('Unknown Artist');
                    final duration = track.durationSeconds != null
                        ? ' · ${formatDuration(track.durationSeconds)}'
                        : '';
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 2,
                      ),
                      leading: OnlineCoverArt(
                        coverUrl: track.coverUrl,
                        coverPath: track.cover,
                        size: 44,
                        borderRadius: 6,
                        iconSize: 20,
                        fallbackIcon: AppIcons.songs,
                      ),
                      title: Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: AppTheme.zinc100,
                        ),
                      ),
                      subtitle: Text(
                        '$artist$duration',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppTheme.zinc400,
                        ),
                      ),
                      trailing: IconButton(
                        tooltip: t('Download Track'),
                        icon: downloading
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(
                                AppIcons.download,
                                size: 20,
                                color: AppTheme.zinc300,
                              ),
                        onPressed: downloading
                            ? null
                            : () => unawaited(_downloadOnlineTrack(track)),
                      ),
                      onTap: () => unawaited(
                        ctrl.playOnlineTracks(_onlineTracks, startIndex: i),
                      ),
                    );
                  },
                ),
            ],
          ],
        ],
      ],
    );
  }
}

class _GenreBrowseCard extends StatelessWidget {
  const _GenreBrowseCard({
    required this.category,
    required this.onTap,
  });

  final _BrowseCategory category;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bg = genreColor(category.name);
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          children: [
            Positioned(
              top: 12,
              left: 12,
              right: 52,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    category.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      height: 1.15,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    category.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withValues(alpha: 0.80),
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              right: -12,
              bottom: -8,
              child: Transform.rotate(
                angle: 24 * math.pi / 180,
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    color: Colors.black.withValues(alpha: 0.25),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.45),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: CoverArt(
                    path: category.coverPath,
                    size: 64,
                    borderRadius: 6,
                    iconSize: 22,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 3: Library (LibraryTab.svelte parity)
// ---------------------------------------------------------------------------

class _LibraryEntry {
  const _LibraryEntry({
    required this.key,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.pinned,
    required this.onTap,
    this.cover,
    this.playlist,
  });

  final String key;
  final String kind; // 'favorites' | 'playlist' | 'album' | 'artist'
  final String title;
  final String subtitle;
  final bool pinned;
  final VoidCallback onTap;
  final String? cover;
  final UiPlaylistInfo? playlist;
}

class _LibraryTab extends StatefulWidget {
  const _LibraryTab({
    required this.controller,
    required this.onOpenPlaylist,
    required this.onOpenAlbum,
    required this.onOpenArtist,
    required this.onOpenFavorites,
    required this.onOpenSongs,
    required this.onOpenSettings,
  });

  final PlayerController controller;
  final ValueChanged<PlatformInt64> onOpenPlaylist;
  final ValueChanged<PlatformInt64> onOpenAlbum;
  final ValueChanged<String> onOpenArtist;
  final VoidCallback onOpenFavorites;
  final VoidCallback onOpenSongs;
  final VoidCallback onOpenSettings;

  @override
  State<_LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<_LibraryTab> {
  _LibraryFilter _filter = _LibraryFilter.all;
  _LibrarySort _sort = _LibrarySort.recents;
  bool _gridView = true;
  bool _searching = false;
  final TextEditingController _filterCtrl = TextEditingController();

  @override
  void dispose() {
    _filterCtrl.dispose();
    super.dispose();
  }

  void _toggleFilter(_LibraryFilter next) {
    setState(() {
      _filter = _filter == next ? _LibraryFilter.all : next;
    });
  }

  Future<void> _openCreateSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.zinc900,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(
                  Icons.playlist_add_rounded,
                  color: AppTheme.zinc100,
                ),
                title: const Text(
                  'New Playlist',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppTheme.zinc50,
                  ),
                ),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  unawaited(_createPlaylist());
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.file_open_rounded,
                  color: AppTheme.zinc100,
                ),
                title: Text(
                  t('Import M3U Playlist'),
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppTheme.zinc50,
                  ),
                ),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  unawaited(_importM3u());
                },
              ),
            ],
          ),
        ),
      ),
    );
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
      widget.onOpenPlaylist(created.id);
    }
  }

  Future<void> _importM3u() async {
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
      widget.onOpenPlaylist(imported.id);
    }
  }

  List<_LibraryEntry> _buildItems(PlayerController ctrl) {
    final out = <_LibraryEntry>[];
    final q = _filterCtrl.text.trim().toLowerCase();
    bool matches(String text, [String sub = '']) =>
        q.isEmpty ||
        text.toLowerCase().contains(q) ||
        sub.toLowerCase().contains(q);

    if (_filter == _LibraryFilter.all ||
        _filter == _LibraryFilter.playlists ||
        _filter == _LibraryFilter.favorites) {
      if (matches(t('Favorites'), 'Playlist')) {
        out.add(
          _LibraryEntry(
            key: 'favorites',
            kind: 'favorites',
            title: t('Favorites'),
            subtitle: '${ctrl.favoriteCount} tracks',
            pinned: true,
            onTap: widget.onOpenFavorites,
          ),
        );
      }
    }

    if (_filter == _LibraryFilter.all || _filter == _LibraryFilter.playlists) {
      for (final pl in ctrl.playlists) {
        if (!matches(pl.name, 'Playlist')) continue;
        out.add(
          _LibraryEntry(
            key: 'playlist:${pl.id}',
            kind: 'playlist',
            title: pl.name,
            subtitle: 'Playlist · ${pl.trackCount} tracks',
            pinned: ctrl.isPinned('playlist', pl.id),
            cover: pl.cover,
            playlist: pl,
            onTap: () => widget.onOpenPlaylist(pl.id),
          ),
        );
      }
    }

    if (_filter == _LibraryFilter.all || _filter == _LibraryFilter.albums) {
      for (var i = 0; i < ctrl.albumCount; i++) {
        final a = ctrl.albumAt(i);
        if (a == null) continue;
        if (!matches(a.title, a.albumArtist)) continue;
        out.add(
          _LibraryEntry(
            key: 'album:${a.id}',
            kind: 'album',
            title: a.title,
            subtitle: 'Album · ${a.albumArtist}',
            pinned: ctrl.isPinned('album', a.id),
            cover: a.cover,
            onTap: () => widget.onOpenAlbum(a.id),
          ),
        );
      }
    }

    if (_filter == _LibraryFilter.all || _filter == _LibraryFilter.artists) {
      for (var i = 0; i < ctrl.artistCount; i++) {
        final ar = ctrl.artistAt(i);
        if (ar == null) continue;
        if (!matches(ar.name, 'Artist')) continue;
        out.add(
          _LibraryEntry(
            key: 'artist:${ar.name}',
            kind: 'artist',
            title: ar.name,
            subtitle: t('Artist'),
            pinned: false,
            cover: ar.cover,
            onTap: () => widget.onOpenArtist(ar.name),
          ),
        );
      }
    }

    if (_sort == _LibrarySort.alpha) {
      out.sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );
    } else {
      int rank(_LibraryEntry e) {
        if (e.kind == 'favorites') return 0;
        if (e.pinned) return 1;
        if (e.kind == 'playlist') return 2;
        if (e.kind == 'album') return 3;
        return 4;
      }

      out.sort((a, b) => rank(a).compareTo(rank(b)));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final topInset = MediaQuery.paddingOf(context).top;
    final sourcesEnabled = ctrl.hasEnabledSourceProviders;
    final items = _buildItems(ctrl);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Spotify-style "Your Library" header
        Padding(
          padding: EdgeInsets.fromLTRB(16, topInset + 14, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: const BoxDecoration(
                      color: AppTheme.zinc800,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: const Icon(
                      AppIcons.library,
                      size: 16,
                      color: AppTheme.accent400,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Your Library',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.zinc50,
                        letterSpacing: -0.4,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Search your library',
                    icon: const Icon(
                      AppIcons.search,
                      size: 24,
                      color: AppTheme.zinc200,
                    ),
                    onPressed: () {
                      setState(() {
                        _searching = !_searching;
                        if (!_searching) _filterCtrl.clear();
                      });
                    },
                  ),
                  IconButton(
                    tooltip: t('Create'),
                    icon: const Icon(
                      AppIcons.plus,
                      size: 26,
                      color: AppTheme.zinc200,
                    ),
                    onPressed: _openCreateSheet,
                  ),
                  IconButton(
                    tooltip: t('Settings'),
                    icon: const Icon(
                      Icons.settings_rounded,
                      size: 22,
                      color: AppTheme.zinc400,
                    ),
                    onPressed: widget.onOpenSettings,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // Filter chips row
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    if (_filter != _LibraryFilter.all) ...[
                      GestureDetector(
                        onTap: () =>
                            setState(() => _filter = _LibraryFilter.all),
                        child: Container(
                          width: 32,
                          height: 32,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: const BoxDecoration(
                            color: AppTheme.zinc800,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            AppIcons.close,
                            size: 16,
                            color: AppTheme.zinc200,
                          ),
                        ),
                      ),
                    ],
                    _HomeChip(
                      label: 'Playlists',
                      active: _filter == _LibraryFilter.playlists,
                      onTap: () => _toggleFilter(_LibraryFilter.playlists),
                    ),
                    const SizedBox(width: 8),
                    _HomeChip(
                      label: t('Albums'),
                      active: _filter == _LibraryFilter.albums,
                      onTap: () => _toggleFilter(_LibraryFilter.albums),
                    ),
                    const SizedBox(width: 8),
                    _HomeChip(
                      label: t('Artists'),
                      active: _filter == _LibraryFilter.artists,
                      onTap: () => _toggleFilter(_LibraryFilter.artists),
                    ),
                    const SizedBox(width: 8),
                    _HomeChip(
                      label: t('Songs'),
                      active: _filter == _LibraryFilter.songs,
                      onTap: () => _toggleFilter(_LibraryFilter.songs),
                    ),
                    const SizedBox(width: 8),
                    _HomeChip(
                      label: t('Favorites'),
                      active: _filter == _LibraryFilter.favorites,
                      onTap: () => _toggleFilter(_LibraryFilter.favorites),
                    ),
                    if (sourcesEnabled) ...[
                      const SizedBox(width: 8),
                      _HomeChip(
                        label: t('Sources'),
                        active: _filter == _LibraryFilter.sources,
                        onTap: () => _toggleFilter(_LibraryFilter.sources),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),

        if (_searching)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Container(
              height: 40,
              decoration: BoxDecoration(
                color: AppTheme.zinc800.withValues(alpha: 0.90),
                borderRadius: BorderRadius.circular(9999),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  const Icon(
                    AppIcons.search,
                    size: 18,
                    color: AppTheme.zinc400,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _filterCtrl,
                      autofocus: true,
                      onChanged: (_) => setState(() {}),
                      style: const TextStyle(
                        fontSize: 14,
                        color: AppTheme.zinc100,
                      ),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                        hintText: 'Filter your library...',
                        hintStyle: TextStyle(
                          fontSize: 14,
                          color: AppTheme.zinc400,
                        ),
                      ),
                    ),
                  ),
                  if (_filterCtrl.text.isNotEmpty)
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 24,
                        minHeight: 24,
                      ),
                      icon: const Icon(
                        AppIcons.close,
                        size: 16,
                        color: AppTheme.zinc400,
                      ),
                      onPressed: () {
                        _filterCtrl.clear();
                        setState(() {});
                      },
                    ),
                ],
              ),
            ),
          ),

        if (_filter == _LibraryFilter.songs)
          Expanded(
            child: ctrl.trackCount == 0
                ? Center(
                    child: Text(
                      t('No songs in library yet.'),
                      style: const TextStyle(color: AppTheme.zinc400),
                    ),
                  )
                : ListView.builder(
                    padding: EdgeInsets.only(
                      bottom: mobileBottomClearance(context, ctrl),
                    ),
                    itemCount: ctrl.trackCount,
                    itemBuilder: (context, index) {
                      final tr = ctrl.trackAt(index);
                      if (tr == null) return const SizedBox(height: 64);
                      return MobileTrackTile(
                        controller: ctrl,
                        track: tr,
                        onTap: () => ctrl.playAllFromSearch(index),
                        onOpenArtist: widget.onOpenArtist,
                        onOpenAlbum: widget.onOpenAlbum,
                      );
                    },
                  ),
          )
        else if (_filter == _LibraryFilter.sources && sourcesEnabled)
          Expanded(
            child: SourcesView(controller: ctrl),
          )
        else ...[
          // Sort + Grid/List toggle bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 10, 6),
            child: Row(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() {
                    _sort = _sort == _LibrarySort.recents
                        ? _LibrarySort.alpha
                        : _LibrarySort.recents;
                  }),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.swap_vert_rounded,
                          size: 18,
                          color: AppTheme.zinc300,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _sort == _LibrarySort.recents
                              ? 'Recents'
                              : 'Alphabetical',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: AppTheme.zinc200,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: _gridView ? 'List view' : 'Grid view',
                  icon: Icon(
                    _gridView
                        ? Icons.view_list_rounded
                        : Icons.grid_view_rounded,
                    size: 20,
                    color: AppTheme.zinc200,
                  ),
                  onPressed: () => setState(() => _gridView = !_gridView),
                ),
              ],
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Text(
                      _filterCtrl.text.trim().isNotEmpty
                          ? 'No results for "${_filterCtrl.text.trim()}"'
                          : 'Your library is empty.',
                      style: const TextStyle(
                        fontSize: 14,
                        color: AppTheme.zinc400,
                      ),
                    ),
                  )
                : _gridView
                    ? GridView.builder(
                        padding: EdgeInsets.fromLTRB(
                          16,
                          4,
                          16,
                          mobileBottomClearance(context, ctrl),
                        ),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 16,
                          childAspectRatio: 0.72,
                        ),
                        itemCount: items.length,
                        itemBuilder: (context, index) =>
                            _LibraryGridTile(entry: items[index]),
                      )
                    : ListView.builder(
                        padding: EdgeInsets.only(
                          bottom: mobileBottomClearance(context, ctrl),
                        ),
                        itemCount: items.length,
                        itemBuilder: (context, index) =>
                            _LibraryListTile(entry: items[index]),
                      ),
          ),
        ],
      ],
    );
  }
}

class _LibraryGridTile extends StatelessWidget {
  const _LibraryGridTile({required this.entry});

  final _LibraryEntry entry;

  @override
  Widget build(BuildContext context) {
    Widget artwork;
    if (entry.kind == 'favorites') {
      artwork = AspectRatio(
        aspectRatio: 1,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF4F46E5),
                AppTheme.accent500,
                AppTheme.accent300,
              ],
            ),
          ),
          alignment: Alignment.center,
          child: const Icon(Icons.star_rounded, size: 36, color: Colors.white),
        ),
      );
    } else if (entry.kind == 'playlist' && entry.playlist != null) {
      artwork = AspectRatio(
        aspectRatio: 1,
        child: PlaylistCoverWidget(
          playlist: entry.playlist!,
          borderRadius: 6,
        ),
      );
    } else if (entry.kind == 'artist') {
      artwork = AspectRatio(
        aspectRatio: 1,
        child: ClipOval(
          child: CoverArt(
            path: entry.cover,
            borderRadius: 0,
            iconSize: 28,
            fallbackIcon: AppIcons.artists,
          ),
        ),
      );
    } else {
      artwork = AspectRatio(
        aspectRatio: 1,
        child: CoverArt(
          path: entry.cover,
          borderRadius: 6,
          iconSize: 28,
        ),
      );
    }

    return GestureDetector(
      onTap: entry.onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          artwork,
          const SizedBox(height: 6),
          Text(
            entry.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: entry.kind == 'favorites'
                  ? AppTheme.accent400
                  : AppTheme.zinc50,
            ),
          ),
          Text(
            entry.subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              color: AppTheme.zinc400,
            ),
          ),
        ],
      ),
    );
  }
}

class _LibraryListTile extends StatelessWidget {
  const _LibraryListTile({required this.entry});

  final _LibraryEntry entry;

  @override
  Widget build(BuildContext context) {
    Widget leading;
    if (entry.kind == 'favorites') {
      leading = Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF4F46E5),
              AppTheme.accent500,
              AppTheme.accent300,
            ],
          ),
        ),
        alignment: Alignment.center,
        child: const Icon(Icons.star_rounded, size: 24, color: Colors.white),
      );
    } else if (entry.kind == 'playlist' && entry.playlist != null) {
      leading = PlaylistCoverWidget(
        playlist: entry.playlist!,
        size: 52,
        borderRadius: 6,
      );
    } else if (entry.kind == 'artist') {
      leading = ClipOval(
        child: CoverArt(
          path: entry.cover,
          size: 52,
          borderRadius: 0,
          iconSize: 22,
          fallbackIcon: AppIcons.artists,
        ),
      );
    } else {
      leading = CoverArt(
        path: entry.cover,
        size: 52,
        borderRadius: 6,
        iconSize: 22,
      );
    }

    return InkWell(
      onTap: entry.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: entry.kind == 'favorites'
                          ? AppTheme.accent400
                          : AppTheme.zinc50,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    entry.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppTheme.zinc400,
                    ),
                  ),
                ],
              ),
            ),
            if (entry.pinned)
              const Icon(
                AppIcons.pin,
                size: 16,
                color: AppTheme.accent400,
              ),
          ],
        ),
      ),
    );
  }
}
