import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:neomodern/theme/app_theme.dart';

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
