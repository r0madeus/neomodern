import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/theme/app_theme.dart';

class PlaylistCoverPalette {
  const PlaylistCoverPalette({
    required this.id,
    required this.label,
    required this.colors,
    required this.heroTop,
    required this.swatch,
  });

  final String id;
  final String label;
  final List<Color> colors;
  final Color heroTop;
  final Color swatch;
}

class PlaylistCoverIconOption {
  const PlaylistCoverIconOption({
    required this.id,
    required this.icon,
  });

  final String id;
  final IconData icon;
}

class PlaylistCoverPreset {
  const PlaylistCoverPreset({
    required this.palette,
    required this.icon,
  });

  final PlaylistCoverPalette palette;
  final PlaylistCoverIconOption icon;
}

const List<PlaylistCoverPalette> kPlaylistCoverPalettes = [
  PlaylistCoverPalette(
    id: 'teal',
    label: 'Teal',
    colors: [Color(0xFF14B8A6), Color(0xFF0F766E), Color(0xFF134E4A)],
    heroTop: Color(0xFF0D9488),
    swatch: Color(0xFF14B8A6),
  ),
  PlaylistCoverPalette(
    id: 'ocean',
    label: 'Ocean',
    colors: [Color(0xFF38BDF8), Color(0xFF1D4ED8), Color(0xFF1E1B4B)],
    heroTop: Color(0xFF0284C7),
    swatch: Color(0xFF38BDF8),
  ),
  PlaylistCoverPalette(
    id: 'indigo',
    label: 'Indigo',
    colors: [Color(0xFF6366F1), Color(0xFF4338CA), Color(0xFF1E1B4B)],
    heroTop: Color(0xFF4F46E5),
    swatch: Color(0xFF6366F1),
  ),
  PlaylistCoverPalette(
    id: 'violet',
    label: 'Violet',
    colors: [Color(0xFFC084FC), Color(0xFF7E22CE), Color(0xFF3B0764)],
    heroTop: Color(0xFF9333EA),
    swatch: Color(0xFFA855F7),
  ),
  PlaylistCoverPalette(
    id: 'rose',
    label: 'Rose',
    colors: [Color(0xFFFB7185), Color(0xFFBE123C), Color(0xFF4C0519)],
    heroTop: Color(0xFFE11D48),
    swatch: Color(0xFFF43F5E),
  ),
  PlaylistCoverPalette(
    id: 'sunset',
    label: 'Sunset',
    colors: [Color(0xFFFB923C), Color(0xFFEA580C), Color(0xFF7C2D12)],
    heroTop: Color(0xFFEA580C),
    swatch: Color(0xFFF97316),
  ),
  PlaylistCoverPalette(
    id: 'emerald',
    label: 'Emerald',
    colors: [Color(0xFF34D399), Color(0xFF059669), Color(0xFF064E3B)],
    heroTop: Color(0xFF059669),
    swatch: Color(0xFF10B981),
  ),
  PlaylistCoverPalette(
    id: 'slate',
    label: 'Slate',
    colors: [Color(0xFF64748B), Color(0xFF334155), Color(0xFF0F172A)],
    heroTop: Color(0xFF475569),
    swatch: Color(0xFF64748B),
  ),
];

const List<PlaylistCoverIconOption> kPlaylistCoverIcons = [
  PlaylistCoverIconOption(id: 'music', icon: Icons.music_note_rounded),
  PlaylistCoverIconOption(id: 'star', icon: Icons.star_rounded),
  PlaylistCoverIconOption(id: 'album', icon: Icons.album_rounded),
  PlaylistCoverIconOption(id: 'lyrics', icon: Icons.lyrics_rounded),
  PlaylistCoverIconOption(id: 'play', icon: Icons.play_arrow_rounded),
  PlaylistCoverIconOption(id: 'queue', icon: Icons.queue_music_rounded),
];

PlaylistCoverPalette findPlaylistCoverPalette(String id) {
  for (final p in kPlaylistCoverPalettes) {
    if (p.id == id) return p;
  }
  return kPlaylistCoverPalettes.first;
}

PlaylistCoverIconOption findPlaylistCoverIcon(String id) {
  for (final icon in kPlaylistCoverIcons) {
    if (icon.id == id) return icon;
  }
  return kPlaylistCoverIcons.first;
}

PlaylistCoverPreset? parsePlaylistCoverPreset(String? cover) {
  if (cover == null || !cover.startsWith('preset:')) return null;
  final parts = cover.split(':');
  final paletteId = parts.length > 1 ? parts[1] : 'teal';
  final iconId = parts.length > 2 ? parts[2] : 'music';
  return PlaylistCoverPreset(
    palette: findPlaylistCoverPalette(paletteId),
    icon: findPlaylistCoverIcon(iconId),
  );
}

String buildPlaylistCoverPreset(String paletteId, String iconId) {
  final palette = findPlaylistCoverPalette(paletteId);
  final icon = findPlaylistCoverIcon(iconId);
  return 'preset:${palette.id}:${icon.id}';
}

class PlaylistCoverWidget extends StatelessWidget {
  const PlaylistCoverWidget({
    super.key,
    required this.playlist,
    this.size,
    this.borderRadius = 10,
  });

  final UiPlaylistInfo playlist;
  final double? size;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final preset = parsePlaylistCoverPreset(
      playlist.cover ??
          (playlist.coverMode == 'gradient' ? playlist.coverValue : null),
    );
    if (preset != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: preset.palette.colors,
            ),
          ),
          alignment: Alignment.center,
          child: Icon(
            preset.icon.icon,
            size: size != null ? size! * 0.42 : 44,
            color: Colors.white.withAlpha(235),
          ),
        ),
      );
    }

    final customPath = playlist.cover != null &&
            !playlist.cover!.startsWith('preset:') &&
            playlist.cover!.isNotEmpty
        ? playlist.cover!
        : null;
    if (customPath != null) {
      return CoverArt(
        path: customPath,
        size: size,
        borderRadius: borderRadius,
        iconSize: size != null ? size! * 0.36 : 36,
        fallbackIcon: Icons.queue_music_rounded,
      );
    }

    return CollageCover(
      coverPaths: playlist.albumCovers,
      size: size,
      borderRadius: borderRadius,
    );
  }
}

class CoverArt extends StatelessWidget {
  const CoverArt({
    super.key,
    required this.path,
    this.size,
    this.borderRadius = 6,
    this.iconSize = 22,
    this.fallbackIcon = Icons.music_note_rounded,
  });

  final String? path;
  final double? size;
  final double borderRadius;
  final double iconSize;
  final IconData fallbackIcon;

  @override
  Widget build(BuildContext context) {
    final p = path;
    Widget child;
    if (p != null && p.isNotEmpty) {
      final cacheWidth = size != null ? (size! * 2).round() : 360;
      child = Image.file(
        File(p),
        fit: BoxFit.cover,
        cacheWidth: cacheWidth,
        errorBuilder: (_, _, _) => _placeholder(),
      );
    } else {
      child = _placeholder();
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(
        width: size,
        height: size,
        child: child,
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      color: AppColors.surface,
      alignment: Alignment.center,
      child: Icon(
        fallbackIcon,
        size: iconSize,
        color: AppColors.textMuted,
      ),
    );
  }
}

class CollageCover extends StatelessWidget {
  const CollageCover({
    super.key,
    required this.coverPaths,
    this.size,
    this.borderRadius = 8,
    this.fallbackIcon = Icons.queue_music_rounded,
  });

  final List<String> coverPaths;
  final double? size;
  final double borderRadius;
  final IconData fallbackIcon;

  @override
  Widget build(BuildContext context) {
    if (coverPaths.length < 4) {
      return CoverArt(
        path: coverPaths.isNotEmpty ? coverPaths.first : null,
        size: size,
        borderRadius: borderRadius,
        iconSize: size != null ? size! * 0.36 : 36,
        fallbackIcon: fallbackIcon,
      );
    }

    final tileSize = size != null ? size! / 2 : null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(
        width: size,
        height: size,
        child: Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: CoverArt(
                      path: coverPaths[0],
                      size: tileSize,
                      borderRadius: 0,
                      iconSize: 18,
                    ),
                  ),
                  Expanded(
                    child: CoverArt(
                      path: coverPaths[1],
                      size: tileSize,
                      borderRadius: 0,
                      iconSize: 18,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: CoverArt(
                      path: coverPaths[2],
                      size: tileSize,
                      borderRadius: 0,
                      iconSize: 18,
                    ),
                  ),
                  Expanded(
                    child: CoverArt(
                      path: coverPaths[3],
                      size: tileSize,
                      borderRadius: 0,
                      iconSize: 18,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
