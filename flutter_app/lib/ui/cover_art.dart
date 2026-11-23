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
  });

  final String? path;
  final double? size;
  final double borderRadius;
  final double iconSize;

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
        Icons.music_note_rounded,
        size: iconSize,
        color: AppColors.textMuted,
      ),
    );
  }
}
