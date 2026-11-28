import 'dart:async';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_icons.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';
import 'package:neomodern/ui/genre_view.dart';
import 'package:neomodern/ui/mobile/sticky_play.dart';
import 'package:neomodern/ui/online_album_dialog.dart';
import 'package:neomodern/ui/recap_view.dart';
import 'package:neomodern/ui/settings_view.dart';
import 'package:neomodern/ui/sources_view.dart';
import 'package:neomodern/ui/tinted_backdrop.dart';
import 'package:neomodern/ui/track_menu.dart';
import 'package:neomodern/ui/widgets/motion_primitives.dart';

double mobileBottomClearance(BuildContext context, PlayerController ctrl) {
  final bottomInset = MediaQuery.paddingOf(context).bottom;
  final base = ctrl.snapshot.current != null ? 140.0 : 76.0;
  return base + bottomInset;
}

class MobilePageHeader extends StatelessWidget {
  const MobilePageHeader({
    super.key,
    required this.title,
    this.scrolled = false,
    this.dockedPlay,
    this.trailing,
  });

  final String title;
  final bool scrolled;
  final Widget? dockedPlay;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      color: scrolled
          ? AppTheme.zinc950.withValues(alpha: 0.94)
          : Colors.transparent,
      padding: EdgeInsets.only(top: topInset),
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            IconButton(
              tooltip: t('Back'),
              icon: const Icon(
                AppIcons.back,
                size: 24,
                color: Colors.white,
              ),
              onPressed: () => Navigator.of(context).pop(),
            ),
            Expanded(
              child: AnimatedOpacity(
                opacity: scrolled ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 140),
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            ?dockedPlay,
            ?trailing,
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

class MobileSimplePage extends StatelessWidget {
  const MobileSimplePage({
    super.key,
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.zinc950,
      body: Column(
        children: [
          Container(
            color: AppTheme.zinc950,
            padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
            child: SizedBox(
              height: 56,
              child: Row(
                children: [
                  IconButton(
                    tooltip: t('Back'),
                    icon: const Icon(
                      AppIcons.back,
                      size: 24,
                      color: Colors.white,
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.zinc50,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class MobileTrackTile extends StatelessWidget {
  const MobileTrackTile({
    super.key,
    required this.controller,
    required this.track,
    required this.onTap,
    this.onOpenArtist,
    this.onOpenAlbum,
    this.showCover = true,
    this.indexNumber,
  });

  final PlayerController controller;
  final UiTrackRow track;
  final VoidCallback onTap;
  final ValueChanged<String>? onOpenArtist;
  final ValueChanged<PlatformInt64>? onOpenAlbum;
  final bool showCover;
  final int? indexNumber;

  @override
  Widget build(BuildContext context) {
    final isCurrent = controller.snapshot.current?.path == track.path;
    final subtitleParts = <String>[
      if (track.artist.isNotEmpty) track.artist,
      if (track.album.isNotEmpty) track.album,
    ];
    final subtitle = subtitleParts.join(' · ');

    return InkWell(
      onTap: onTap,
      onLongPress: () => _showMenu(context, Offset.zero),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            if (indexNumber != null)
              SizedBox(
                width: 28,
                child: isCurrent
                    ? Center(
                        child: EqualizerIndicator(
                          color: AppTheme.accent400,
                          height: 14,
                          playing: controller.isPlaying,
                        ),
                      )
                    : Text(
                        '$indexNumber',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppTheme.zinc400,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
              )
            else if (showCover) ...[
              Stack(
                alignment: Alignment.center,
                children: [
                  CoverArt(
                    path: track.cover,
                    size: 48,
                    borderRadius: 6,
                    iconSize: 20,
                  ),
                  if (isCurrent)
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      alignment: Alignment.center,
                      child: EqualizerIndicator(
                        color: AppTheme.accent400,
                        height: 14,
                        playing: controller.isPlaying,
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 12),
            ],
            if (indexNumber != null) const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w500,
                      color: isCurrent ? AppTheme.accent400 : AppTheme.zinc50,
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppTheme.zinc400,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            AnimatedSaveButton(
              isSaved: controller.isFavorite(track.id),
              onPressed: () => controller.toggleFavorite(track.id),
              size: 18,
            ),
            Builder(
              builder: (btnCtx) => IconButton(
                tooltip: 'More',
                visualDensity: VisualDensity.compact,
                icon: const Icon(
                  AppIcons.more,
                  size: 18,
                  color: AppTheme.zinc400,
                ),
                onPressed: () {
                  final box = btnCtx.findRenderObject() as RenderBox?;
                  final pos = box != null
                      ? box.localToGlobal(box.size.center(Offset.zero))
                      : Offset.zero;
                  _showMenu(btnCtx, pos);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showMenu(BuildContext context, Offset pos) {
    unawaited(
      TrackMenu.show(
        context: context,
        globalPosition: pos,
        track: track,
        controller: controller,
        onPlay: onTap,
        onOpenArtist: onOpenArtist,
        onOpenAlbum: onOpenAlbum,
      ),
    );
  }
}

class MobileAlbumPage extends StatefulWidget {
  const MobileAlbumPage({
    super.key,
    required this.controller,
    required this.albumId,
    required this.onOpenArtist,
  });

  final PlayerController controller;
  final PlatformInt64 albumId;
  final ValueChanged<String> onOpenArtist;

  @override
  State<MobileAlbumPage> createState() => _MobileAlbumPageState();
}

class _MobileAlbumPageState extends State<MobileAlbumPage> {
  final ScrollController _scrollCtrl = ScrollController();
  UiAlbumDetail? _detail;
  bool _loading = true;
  bool _docked = false;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    unawaited(_load());
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    final docked = _scrollCtrl.hasClients && _scrollCtrl.offset > 240;
    if (docked != _docked) {
      setState(() => _docked = docked);
    }
  }

  Future<void> _load() async {
    try {
      final d = await widget.controller.fetchAlbumDetail(widget.albumId);
      if (mounted) {
        setState(() {
          _detail = d;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final detail = _detail;
    final tint = tintFromArgb(detail?.album.coverColor);
    final topInset = MediaQuery.paddingOf(context).top;

    return Scaffold(
      backgroundColor: AppTheme.zinc950,
      body: Stack(
        children: [
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (detail == null)
            Center(
              child: Text(
                t('Album not found.'),
                style: const TextStyle(color: AppTheme.zinc400),
              ),
            )
          else
            TintedBackdrop.gradient(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0.0, 0.55],
                colors: [tint.top, AppTheme.zinc950],
              ),
              child: ListView(
                controller: _scrollCtrl,
                padding: EdgeInsets.only(
                  top: topInset + 56,
                  bottom: mobileBottomClearance(context, ctrl),
                ),
                children: [
                  Center(
                    child: Container(
                      width: 210,
                      height: 210,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.45),
                            blurRadius: 24,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: CoverArt(
                        path: detail.album.cover,
                        size: 210,
                        borderRadius: 10,
                        iconSize: 64,
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      detail.album.title,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: GestureDetector(
                      onTap: detail.album.albumArtist.isNotEmpty
                          ? () => widget.onOpenArtist(detail.album.albumArtist)
                          : null,
                      child: Text(
                        detail.album.year != null
                            ? '${detail.album.albumArtist} · ${detail.album.year}'
                            : detail.album.albumArtist,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                          color: AppTheme.zinc300,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: ctrl.isPinned('album', detail.album.id)
                              ? t('Unpin')
                              : t('Pin'),
                          icon: Icon(
                            ctrl.isPinned('album', detail.album.id)
                                ? AppIcons.pin
                                : AppIcons.pin,
                            color: ctrl.isPinned('album', detail.album.id)
                                ? AppTheme.accent400
                                : AppTheme.zinc300,
                          ),
                          onPressed: () =>
                              ctrl.togglePinned('album', detail.album.id),
                        ),
                        IconButton(
                          tooltip: t('Shuffle'),
                          icon: const Icon(
                            AppIcons.shuffle,
                            color: AppTheme.zinc300,
                          ),
                          onPressed: detail.tracks.isEmpty
                              ? null
                              : () => ctrl.playAlbum(
                                    detail.album.id,
                                    0,
                                    shuffle: true,
                                  ),
                        ),
                        const Spacer(),
                        if (!_docked)
                          StickyPlayButton(
                            playing: ctrl.isPlaying &&
                                detail.tracks.any(
                                  (tr) =>
                                      tr.path == ctrl.snapshot.current?.path,
                                ),
                            disabled: detail.tracks.isEmpty,
                            onPressed: () => ctrl.playAlbum(detail.album.id, 0),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (var i = 0; i < detail.tracks.length; i++)
                    MobileTrackTile(
                      controller: ctrl,
                      track: detail.tracks[i],
                      indexNumber: detail.tracks[i].trackNo ?? (i + 1),
                      showCover: false,
                      onTap: () => ctrl.playAlbum(detail.album.id, i),
                      onOpenArtist: widget.onOpenArtist,
                    ),
                ],
              ),
            ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: MobilePageHeader(
              title: detail?.album.title ?? t('Albums'),
              scrolled: _docked,
              dockedPlay: _docked && detail != null
                  ? StickyPlayButton(
                      playing: ctrl.isPlaying,
                      docked: true,
                      onPressed: () => ctrl.playAlbum(detail.album.id, 0),
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

class MobileArtistPage extends StatefulWidget {
  const MobileArtistPage({
    super.key,
    required this.controller,
    required this.artistName,
    required this.onOpenAlbum,
  });

  final PlayerController controller;
  final String artistName;
  final ValueChanged<PlatformInt64> onOpenAlbum;

  @override
  State<MobileArtistPage> createState() => _MobileArtistPageState();
}

class _MobileArtistPageState extends State<MobileArtistPage> {
  final ScrollController _scrollCtrl = ScrollController();
  UiArtistDetail? _detail;
  bool _loading = true;
  bool _enriching = false;
  bool _bioExpanded = false;
  bool _docked = false;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    unawaited(_load());
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    final docked = _scrollCtrl.hasClients && _scrollCtrl.offset > 210;
    if (docked != _docked) {
      setState(() => _docked = docked);
    }
  }

  Future<void> _load() async {
    try {
      final d = await widget.controller.fetchArtistDetail(widget.artistName);
      if (mounted) {
        setState(() {
          _detail = d;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _enrichArtist() async {
    final current = _detail;
    if (current == null || _enriching) return;
    setState(() => _enriching = true);
    try {
      final enriched = await widget.controller.enrichArtist(current.name);
      if (!mounted) return;
      setState(() {
        if (enriched != null) {
          _detail = enriched;
        }
        _enriching = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _enriching = false);
      }
    }
  }

  Widget _buildArtistAvatar(String? path) {
    final p = path?.trim();
    if (p != null && (p.startsWith('http://') || p.startsWith('https://'))) {
      return Image.network(
        p,
        width: 164,
        height: 164,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const CoverArt(
          path: null,
          size: 164,
          borderRadius: 0,
          iconSize: 56,
          fallbackIcon: Icons.person_rounded,
        ),
      );
    }
    return CoverArt(
      path: p,
      size: 164,
      borderRadius: 0,
      iconSize: 56,
      fallbackIcon: Icons.person_rounded,
    );
  }

  Widget _buildAboutSection(String bio) {
    final trimmed = bio.trim();
    const bioStyle = TextStyle(
      fontSize: 13.5,
      height: 1.55,
      color: AppTheme.zinc300,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
          child: Text(
            t('About'),
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.zinc900,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.zinc800),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final painter = TextPainter(
                  text: TextSpan(text: trimmed, style: bioStyle),
                  maxLines: 5,
                  textDirection: Directionality.of(context),
                )..layout(maxWidth: constraints.maxWidth);
                final overflows = painter.didExceedMaxLines;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      trimmed,
                      maxLines: _bioExpanded ? null : 5,
                      overflow: _bioExpanded
                          ? TextOverflow.visible
                          : TextOverflow.ellipsis,
                      style: bioStyle,
                    ),
                    if (overflows) ...[
                      const SizedBox(height: 8),
                      GestureDetector(
                        onTap: () =>
                            setState(() => _bioExpanded = !_bioExpanded),
                        child: Text(
                          _bioExpanded ? t('Show less') : t('Show more'),
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.accent400,
                          ),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final detail = _detail;
    final topInset = MediaQuery.paddingOf(context).top;

    return Scaffold(
      backgroundColor: AppTheme.zinc950,
      body: Stack(
        children: [
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (detail == null)
            Center(
              child: Text(
                widget.artistName,
                style: const TextStyle(color: AppTheme.zinc400),
              ),
            )
          else
            ListView(
              controller: _scrollCtrl,
              padding: EdgeInsets.only(
                top: topInset + 56,
                bottom: mobileBottomClearance(context, ctrl),
              ),
              children: [
                Center(
                  child: ClipOval(
                    child: _buildArtistAvatar(
                      detail.image ?? detail.cover ?? detail.fallbackCover,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    detail.name,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                  child: Text(
                    t('{albums} albums · {tracks} tracks', {
                      'albums': detail.albumCount,
                      'tracks': detail.trackCount,
                    }),
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppTheme.zinc400,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: t('Shuffle'),
                        icon: const Icon(
                          AppIcons.shuffle,
                          color: AppTheme.zinc300,
                        ),
                        onPressed: detail.tracks.isEmpty
                            ? null
                            : () => ctrl.playArtist(detail.name, shuffle: true),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: OutlinedButton.icon(
                          onPressed: _enriching ? null : _enrichArtist,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.zinc200,
                            disabledForegroundColor: AppTheme.zinc500,
                            side: const BorderSide(color: AppTheme.zinc700),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            visualDensity: VisualDensity.compact,
                            shape: const StadiumBorder(),
                          ),
                          icon: _enriching
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppTheme.zinc300,
                                  ),
                                )
                              : const Icon(Icons.refresh_rounded, size: 16),
                          label: Text(
                            t('Fetch artist info'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                      const Spacer(),
                      if (!_docked)
                        StickyPlayButton(
                          playing: ctrl.isPlaying &&
                              detail.tracks.any(
                                (tr) => tr.path == ctrl.snapshot.current?.path,
                              ),
                          disabled: detail.tracks.isEmpty,
                          onPressed: () => ctrl.playArtist(detail.name),
                        ),
                    ],
                  ),
                ),
                if (detail.albums.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                    child: Text(
                      t('Albums'),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 186,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: detail.albums.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 12),
                      itemBuilder: (context, idx) {
                        final a = detail.albums[idx];
                        return GestureDetector(
                          onTap: () => widget.onOpenAlbum(a.id),
                          child: SizedBox(
                            width: 132,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                CoverArt(
                                  path: a.cover,
                                  size: 132,
                                  borderRadius: 8,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  a.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.zinc50,
                                  ),
                                ),
                                if (a.year != null)
                                  Text(
                                    '${a.year}',
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
                ],
                if (detail.onlineAlbums.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                    child: Text(
                      t('Online Albums'),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 186,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: detail.onlineAlbums.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 12),
                      itemBuilder: (context, idx) {
                        final album = detail.onlineAlbums[idx];
                        return GestureDetector(
                          onTap: () => showOnlineAlbumModal(
                            context,
                            controller: ctrl,
                            album: album,
                          ),
                          child: SizedBox(
                            width: 132,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _MobileOnlineAlbumCover(
                                  cover: album.cover,
                                  coverUrl: album.coverUrl,
                                  size: 132,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  album.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.zinc50,
                                  ),
                                ),
                                if (album.year != null)
                                  Text(
                                    '${album.year}',
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
                ],
                if (detail.bio != null && detail.bio!.trim().isNotEmpty)
                  _buildAboutSection(detail.bio!),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                  child: Text(
                    t('All Tracks'),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
                for (var i = 0; i < detail.tracks.length; i++)
                  MobileTrackTile(
                    controller: ctrl,
                    track: detail.tracks[i],
                    onTap: () => ctrl.playArtist(detail.name, startIndex: i),
                    onOpenAlbum: widget.onOpenAlbum,
                  ),
              ],
            ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: MobilePageHeader(
              title: detail?.name ?? widget.artistName,
              scrolled: _docked,
              dockedPlay: _docked && detail != null
                  ? StickyPlayButton(
                      playing: ctrl.isPlaying,
                      docked: true,
                      onPressed: () => ctrl.playArtist(detail.name),
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileOnlineAlbumCover extends StatelessWidget {
  const _MobileOnlineAlbumCover({
    required this.cover,
    required this.coverUrl,
    required this.size,
  });

  final String? cover;
  final String? coverUrl;
  final double size;

  Widget _placeholder() {
    return Container(
      width: size,
      height: size,
      color: AppTheme.zinc900,
      alignment: Alignment.center,
      child: const Icon(
        Icons.album_rounded,
        size: 34,
        color: AppTheme.zinc500,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final localOrPath = cover?.trim();
    final remote = coverUrl?.trim();
    if (localOrPath != null &&
        localOrPath.isNotEmpty &&
        !localOrPath.startsWith('http://') &&
        !localOrPath.startsWith('https://')) {
      return CoverArt(
        path: localOrPath,
        size: size,
        borderRadius: 8,
        iconSize: 34,
      );
    }

    final url = (localOrPath != null &&
            (localOrPath.startsWith('http://') ||
                localOrPath.startsWith('https://')))
        ? localOrPath
        : remote;
    if (url != null && url.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          url,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _placeholder(),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: _placeholder(),
    );
  }
}

class MobilePlaylistPage extends StatefulWidget {
  const MobilePlaylistPage({
    super.key,
    required this.controller,
    required this.playlistId,
    required this.onOpenArtist,
    required this.onOpenAlbum,
  });

  final PlayerController controller;
  final PlatformInt64 playlistId;
  final ValueChanged<String> onOpenArtist;
  final ValueChanged<PlatformInt64> onOpenAlbum;

  @override
  State<MobilePlaylistPage> createState() => _MobilePlaylistPageState();
}

class _MobilePlaylistPageState extends State<MobilePlaylistPage> {
  final ScrollController _scrollCtrl = ScrollController();
  List<UiTrackRow> _tracks = const [];
  bool _loading = true;
  bool _docked = false;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    unawaited(_load());
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    final docked = _scrollCtrl.hasClients && _scrollCtrl.offset > 220;
    if (docked != _docked) {
      setState(() => _docked = docked);
    }
  }

  Future<void> _load() async {
    try {
      final rows =
          await widget.controller.fetchPlaylistTracks(widget.playlistId);
      if (mounted) {
        setState(() {
          _tracks = rows;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  UiPlaylistInfo? _findPlaylist() {
    for (final p in widget.controller.playlists) {
      if (p.id == widget.playlistId) return p;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final pl = _findPlaylist();
    final topInset = MediaQuery.paddingOf(context).top;

    return Scaffold(
      backgroundColor: AppTheme.zinc950,
      body: Stack(
        children: [
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (pl == null)
            Center(
              child: Text(
                t('Playlist not found.'),
                style: const TextStyle(color: AppTheme.zinc400),
              ),
            )
          else
            ListView(
              controller: _scrollCtrl,
              padding: EdgeInsets.only(
                top: topInset + 56,
                bottom: mobileBottomClearance(context, ctrl),
              ),
              children: [
                Center(
                  child: PlaylistCoverWidget(
                    playlist: pl,
                    size: 200,
                    borderRadius: 10,
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    pl.name,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                  child: Text(
                    '${_tracks.length} tracks',
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppTheme.zinc400,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: ctrl.isPinned('playlist', pl.id)
                            ? t('Unpin')
                            : t('Pin'),
                        icon: Icon(
                          ctrl.isPinned('playlist', pl.id)
                              ? AppIcons.pin
                              : AppIcons.pin,
                          color: ctrl.isPinned('playlist', pl.id)
                              ? AppTheme.accent400
                              : AppTheme.zinc300,
                        ),
                        onPressed: () => ctrl.togglePinned('playlist', pl.id),
                      ),
                      IconButton(
                        tooltip: t('Shuffle'),
                        icon: const Icon(
                          AppIcons.shuffle,
                          color: AppTheme.zinc300,
                        ),
                        onPressed: _tracks.isEmpty
                            ? null
                            : () => ctrl.playPlaylist(pl.id, 0, shuffle: true),
                      ),
                      const Spacer(),
                      if (!_docked)
                        StickyPlayButton(
                          playing: ctrl.isPlaying &&
                              _tracks.any(
                                (tr) => tr.path == ctrl.snapshot.current?.path,
                              ),
                          disabled: _tracks.isEmpty,
                          onPressed: () => ctrl.playPlaylist(pl.id, 0),
                        ),
                    ],
                  ),
                ),
                for (var i = 0; i < _tracks.length; i++)
                  MobileTrackTile(
                    controller: ctrl,
                    track: _tracks[i],
                    onTap: () => ctrl.playPlaylist(pl.id, i),
                    onOpenArtist: widget.onOpenArtist,
                    onOpenAlbum: widget.onOpenAlbum,
                  ),
              ],
            ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: MobilePageHeader(
              title: pl?.name ?? 'Playlist',
              scrolled: _docked,
              dockedPlay: _docked && pl != null
                  ? StickyPlayButton(
                      playing: ctrl.isPlaying,
                      docked: true,
                      onPressed: () => ctrl.playPlaylist(pl.id, 0),
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

class MobileMixPage extends StatefulWidget {
  const MobileMixPage({
    super.key,
    required this.controller,
    required this.mixId,
    required this.onOpenArtist,
    required this.onOpenAlbum,
  });

  final PlayerController controller;
  final String mixId;
  final ValueChanged<String> onOpenArtist;
  final ValueChanged<PlatformInt64> onOpenAlbum;

  @override
  State<MobileMixPage> createState() => _MobileMixPageState();
}

class _MobileMixPageState extends State<MobileMixPage> {
  final ScrollController _scrollCtrl = ScrollController();
  UiHomeMixDetail? _detail;
  bool _loading = true;
  bool _docked = false;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    unawaited(_load());
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    final docked = _scrollCtrl.hasClients && _scrollCtrl.offset > 220;
    if (docked != _docked) {
      setState(() => _docked = docked);
    }
  }

  Future<void> _load() async {
    try {
      final d = await widget.controller.fetchHomeMixDetail(widget.mixId);
      if (mounted) {
        setState(() {
          _detail = d;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final detail = _detail;
    final topInset = MediaQuery.paddingOf(context).top;

    return Scaffold(
      backgroundColor: AppTheme.zinc950,
      body: Stack(
        children: [
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (detail == null)
            const Center(
              child: Text(
                'Mix not found.',
                style: TextStyle(color: AppTheme.zinc400),
              ),
            )
          else
            ListView(
              controller: _scrollCtrl,
              padding: EdgeInsets.only(
                top: topInset + 56,
                bottom: mobileBottomClearance(context, ctrl),
              ),
              children: [
                Center(
                  child: MixCoverArt(
                    mix: detail.mix,
                    size: 200,
                    borderRadius: 10,
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    detail.mix.title,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
                if (detail.mix.subtitle.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                    child: Text(
                      detail.mix.subtitle,
                      style: const TextStyle(
                        fontSize: 13.5,
                        color: AppTheme.zinc400,
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => ctrl.saveHomeMix(
                          detail.mix.id,
                          detail.mix.title,
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.zinc100,
                          side: const BorderSide(color: AppTheme.zinc700),
                        ),
                        icon: const Icon(Icons.playlist_add_rounded, size: 18),
                        label: Text(t('Save as Playlist')),
                      ),
                      const Spacer(),
                      if (!_docked)
                        StickyPlayButton(
                          playing: ctrl.isPlaying,
                          disabled: detail.tracks.isEmpty,
                          onPressed: () => ctrl.playHomeMix(detail.mix.id),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                for (final track in detail.tracks)
                  MobileTrackTile(
                    controller: ctrl,
                    track: track,
                    onTap: () => ctrl.playHomeMix(
                      detail.mix.id,
                      startPath: track.path,
                    ),
                    onOpenArtist: widget.onOpenArtist,
                    onOpenAlbum: widget.onOpenAlbum,
                  ),
              ],
            ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: MobilePageHeader(
              title: detail?.mix.title ?? 'Mix',
              scrolled: _docked,
              dockedPlay: _docked && detail != null
                  ? StickyPlayButton(
                      playing: ctrl.isPlaying,
                      docked: true,
                      onPressed: () => ctrl.playHomeMix(detail.mix.id),
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

class MobileFavoritesPage extends StatefulWidget {
  const MobileFavoritesPage({
    super.key,
    required this.controller,
    required this.onOpenArtist,
    required this.onOpenAlbum,
  });

  final PlayerController controller;
  final ValueChanged<String> onOpenArtist;
  final ValueChanged<PlatformInt64> onOpenAlbum;

  @override
  State<MobileFavoritesPage> createState() => _MobileFavoritesPageState();
}

class _MobileFavoritesPageState extends State<MobileFavoritesPage> {
  final ScrollController _scrollCtrl = ScrollController();
  bool _docked = false;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    final docked = _scrollCtrl.hasClients && _scrollCtrl.offset > 160;
    if (docked != _docked) {
      setState(() => _docked = docked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final tracks = ctrl.favoriteTracks;
    final topInset = MediaQuery.paddingOf(context).top;

    return Scaffold(
      backgroundColor: AppTheme.zinc950,
      body: Stack(
        children: [
          TintedBackdrop.gradient(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: const [0.0, 0.45],
              colors: [
                AppTheme.accent800.withValues(alpha: 0.70),
                AppTheme.zinc950,
              ],
            ),
            child: ListView(
              controller: _scrollCtrl,
              padding: EdgeInsets.only(
                top: topInset + 56,
                bottom: mobileBottomClearance(context, ctrl),
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Text(
                    t('Favorites'),
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Text(
                        '${tracks.length} tracks',
                        style: const TextStyle(
                          fontSize: 13.5,
                          color: AppTheme.zinc300,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: t('Shuffle'),
                        icon: const Icon(
                          AppIcons.shuffle,
                          color: AppTheme.zinc200,
                        ),
                        onPressed: tracks.isEmpty
                            ? null
                            : () => ctrl.playFavorites(0, shuffle: true),
                      ),
                      if (!_docked)
                        StickyPlayButton(
                          playing: ctrl.isPlaying,
                          disabled: tracks.isEmpty,
                          onPressed: () => ctrl.playFavorites(0),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                if (tracks.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      t('No favorite songs yet.'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppTheme.zinc400),
                    ),
                  )
                else
                  for (var i = 0; i < tracks.length; i++)
                    MobileTrackTile(
                      controller: ctrl,
                      track: tracks[i],
                      onTap: () => ctrl.playFavorites(i),
                      onOpenArtist: widget.onOpenArtist,
                      onOpenAlbum: widget.onOpenAlbum,
                    ),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: MobilePageHeader(
              title: t('Favorites'),
              scrolled: _docked,
              dockedPlay: _docked
                  ? StickyPlayButton(
                      playing: ctrl.isPlaying,
                      docked: true,
                      disabled: tracks.isEmpty,
                      onPressed: () => ctrl.playFavorites(0),
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

class MobileSongsPage extends StatelessWidget {
  const MobileSongsPage({
    super.key,
    required this.controller,
    required this.onOpenArtist,
    required this.onOpenAlbum,
  });

  final PlayerController controller;
  final ValueChanged<String> onOpenArtist;
  final ValueChanged<PlatformInt64> onOpenAlbum;

  @override
  Widget build(BuildContext context) {
    return MobileSimplePage(
      title: t('Songs'),
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final count = controller.trackCount;
          if (count == 0) {
            return Center(
              child: Text(
                t('No songs in library yet.'),
                style: const TextStyle(color: AppTheme.zinc400),
              ),
            );
          }
          return ListView.builder(
            padding: EdgeInsets.only(
              bottom: mobileBottomClearance(context, controller),
            ),
            itemCount: count,
            itemBuilder: (context, index) {
              final tr = controller.trackAt(index);
              if (tr == null) {
                return const SizedBox(height: 64);
              }
              return MobileTrackTile(
                controller: controller,
                track: tr,
                onTap: () => controller.playAllFromSearch(index),
                onOpenArtist: onOpenArtist,
                onOpenAlbum: onOpenAlbum,
              );
            },
          );
        },
      ),
    );
  }
}

class MobileRecapPage extends StatelessWidget {
  const MobileRecapPage({
    super.key,
    required this.controller,
    required this.onOpenArtist,
    required this.onOpenAlbum,
  });

  final PlayerController controller;
  final ValueChanged<String> onOpenArtist;
  final ValueChanged<PlatformInt64> onOpenAlbum;

  @override
  Widget build(BuildContext context) {
    return MobileSimplePage(
      title: t('Recap'),
      child: RecapView(
        controller: controller,
        onOpenArtist: onOpenArtist,
        onOpenAlbum: onOpenAlbum,
      ),
    );
  }
}

class MobileSettingsPage extends StatelessWidget {
  const MobileSettingsPage({super.key, required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    return MobileSimplePage(
      title: t('Settings'),
      child: SettingsView(controller: controller),
    );
  }
}

class MobileSourcesPage extends StatelessWidget {
  const MobileSourcesPage({super.key, required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    return MobileSimplePage(
      title: t('Sources'),
      child: SourcesView(controller: controller),
    );
  }
}

class MobileGenrePage extends StatelessWidget {
  const MobileGenrePage({
    super.key,
    required this.name,
    required this.controller,
    required this.onOpenArtist,
    required this.onOpenAlbum,
  });

  final String name;
  final PlayerController controller;
  final ValueChanged<String> onOpenArtist;
  final ValueChanged<PlatformInt64> onOpenAlbum;

  @override
  Widget build(BuildContext context) {
    return MobileSimplePage(
      title: name,
      child: GenreView(
        name: name,
        controller: controller,
        onBack: () => Navigator.of(context).pop(),
        onOpenArtist: onOpenArtist,
        onOpenAlbum: onOpenAlbum,
        showBackButton: false,
        compact: true,
        bottomPadding: mobileBottomClearance(context, controller),
        trackRowBuilder: (context, index, track, onTap) => MobileTrackTile(
          controller: controller,
          track: track,
          onTap: onTap,
          onOpenArtist: onOpenArtist,
          onOpenAlbum: onOpenAlbum,
        ),
      ),
    );
  }
}
