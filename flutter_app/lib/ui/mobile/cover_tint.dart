import 'package:material_ui/material_ui.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/theme/app_theme.dart';

/// Shared bounded cache for cover dominant colors and adjacent track cover paths.
///
/// All Rust FFI calls are guarded with try/catch so widget tests without an
/// initialized Rust core gracefully fall back to default theme colors.
class MobileCoverCache {
  MobileCoverCache._();

  static const int _maxEntries = 256;

  static final Map<String, Color?> _colorCache = {};
  static final Map<String, Future<Color?>> _pendingColors = {};

  static final Map<String, String?> _trackCoverCache = {};
  static final Map<String, Future<String?>> _pendingTrackCovers = {};

  static Color? cachedColor(String? coverPath) {
    if (coverPath == null || coverPath.isEmpty) return null;
    return _colorCache[coverPath];
  }

  static Future<Color?> resolveColor(String? coverPath) {
    if (coverPath == null || coverPath.isEmpty) {
      return Future<Color?>.value(null);
    }
    if (_colorCache.containsKey(coverPath)) {
      return Future<Color?>.value(_colorCache[coverPath]);
    }
    return _pendingColors.putIfAbsent(coverPath, () async {
      try {
        final argb = await coverColorForPath(path: coverPath);
        final color = argb != null ? Color(argb) : null;
        if (_colorCache.length >= _maxEntries) {
          _colorCache.clear();
        }
        _colorCache[coverPath] = color;
        return color;
      } catch (_) {
        return null;
      } finally {
        _pendingColors.remove(coverPath);
      }
    });
  }

  static String? cachedTrackCover(String? trackPath) {
    if (trackPath == null || trackPath.isEmpty) return null;
    return _trackCoverCache[trackPath];
  }

  static Future<String?> resolveTrackCover(String? trackPath) {
    if (trackPath == null || trackPath.isEmpty) {
      return Future<String?>.value(null);
    }
    if (_trackCoverCache.containsKey(trackPath)) {
      return Future<String?>.value(_trackCoverCache[trackPath]);
    }
    return _pendingTrackCovers.putIfAbsent(trackPath, () async {
      try {
        final cover = await libraryTrackCover(path: trackPath);
        if (_trackCoverCache.length >= _maxEntries) {
          _trackCoverCache.clear();
        }
        _trackCoverCache[trackPath] = cover;
        return cover;
      } catch (_) {
        return null;
      } finally {
        _pendingTrackCovers.remove(trackPath);
      }
    });
  }

  @visibleForTesting
  static void clear() {
    _colorCache.clear();
    _pendingColors.clear();
    _trackCoverCache.clear();
    _pendingTrackCovers.clear();
  }
}

/// Blends an optional cover accent color softly over [base] so dark surfaces
/// stay high-contrast and readable.
Color blendCoverTint(Color base, Color? accent, int alpha) {
  if (accent == null) return base;
  return Color.alphaBlend(accent.withAlpha(alpha), base);
}

/// Builds the rich dark vertical gradient used behind Now Playing and Full-Screen Lyrics.
LinearGradient buildCoverGradient(Color? dominantColor) {
  final top = blendCoverTint(AppColors.canvas, dominantColor, 96);
  final mid = blendCoverTint(AppColors.canvas, dominantColor, 40);
  return LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [top, mid, AppColors.canvas],
    stops: const [0.0, 0.48, 1.0],
  );
}
