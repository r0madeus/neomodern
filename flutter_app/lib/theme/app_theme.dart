import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Legacy color aliases preserved for existing views while aligning values
/// with the cool-tinted zinc & soft-blue accent palette from `app.css`.
class AppColors {
  AppColors._();

  static const Color canvas = AppTheme.zinc950;
  static const Color sidebar = Color(0xFF14161D);
  static const Color surface = AppTheme.zinc900;
  static const Color surfaceHover = AppTheme.zinc800;
  static const Color border = AppTheme.zinc800;

  static const Color accent = AppTheme.accent500;
  static const Color accentMuted = Color(0x267CAAFF);

  static const Color textPrimary = AppTheme.zinc100;
  static const Color textSecondary = AppTheme.zinc400;
  static const Color textMuted = AppTheme.zinc500;
  static const Color danger = Color(0xFFE06C75);
}

/// Cover-derived tint colors matching `src/lib/tint.ts`.
@immutable
class CoverTint {
  const CoverTint({
    required this.top,
    required this.surface,
    required this.dim,
  });

  /// Top of the player or detail header gradient.
  final Color top;

  /// Mini player and lyrics card background.
  final Color surface;

  /// Inactive lyric lines or muted foreground accents on tinted surfaces.
  final Color dim;

  static const CoverTint neutral = CoverTint(
    top: Color(0xFF3D414E),
    surface: Color(0xFF262933),
    dim: Color(0xFF9FA3B2),
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CoverTint &&
          runtimeType == other.runtimeType &&
          top == other.top &&
          surface == other.surface &&
          dim == other.dim;

  @override
  int get hashCode => Object.hash(top, surface, dim);
}

/// Converts a 32-bit ARGB color integer into clamped HSL cover tint colors,
/// matching `tintFrom` in `src/lib/tint.ts`.
CoverTint tintFromArgb(int? argb) {
  if (argb == null) return CoverTint.neutral;

  final r = ((argb >> 16) & 0xFF) / 255.0;
  final g = ((argb >> 8) & 0xFF) / 255.0;
  final b = (argb & 0xFF) / 255.0;

  final maxChannel = math.max(r, math.max(g, b));
  final minChannel = math.min(r, math.min(g, b));
  final l = (maxChannel + minChannel) / 2.0;

  double h;
  double s;
  if (maxChannel == minChannel) {
    h = 0.0;
    s = 0.0;
  } else {
    final d = maxChannel - minChannel;
    s = d / (1.0 - (2.0 * l - 1.0).abs());
    if (maxChannel == r) {
      h = ((g - b) / d) % 6.0;
    } else if (maxChannel == g) {
      h = (b - r) / d + 2.0;
    } else {
      h = (r - g) / d + 4.0;
    }
    h = (h * 60.0 + 360.0) % 360.0;
  }

  final sat = math.min(s, 0.5);
  if (sat < 0.08) return CoverTint.neutral;

  return CoverTint(
    top: HSLColor.fromAHSL(1.0, h, sat, 0.30).toColor(),
    surface: HSLColor.fromAHSL(1.0, h, sat * 0.9, 0.24).toColor(),
    dim: HSLColor.fromAHSL(1.0, h, math.min(sat + 0.15, 0.6), 0.72).toColor(),
  );
}

/// Convenience helper converting an optional [Color] into a [CoverTint].
CoverTint tintFromColor(Color? color) =>
    color == null ? CoverTint.neutral : tintFromArgb(color.toARGB32());

const List<Color> kGenrePalette = [
  Color(0xFF0D7A5F),
  Color(0xFFA1263D),
  Color(0xFF3E46A3),
  Color(0xFFA65A18),
  Color(0xFF146C78),
  Color(0xFF6D2D80),
  Color(0xFF1E5C99),
  Color(0xFF9C2754),
  Color(0xFF456E28),
  Color(0xFF32506D),
  Color(0xFFB0442A),
  Color(0xFF58339C),
];

/// Deterministic Spotify-style card background color for a genre or mix label,
/// matching `genreColor` in `src/lib/genreColor.ts` using 32-bit FNV-1a.
Color genreColor(String name) {
  final key = name.trim().toLowerCase();
  var hash = 2166136261;
  for (var i = 0; i < key.length; i++) {
    hash ^= key.codeUnitAt(i);
    // 32-bit multiply via low/high 16-bit split so native and web behave identically.
    final lo = (hash & 0xFFFF) * 16777619;
    final hi = (((hash >> 16) & 0xFFFF) * 16777619) << 16;
    hash = (lo + hi) & 0xFFFFFFFF;
  }
  return kGenrePalette[hash % kGenrePalette.length];
}

class AppTheme {
  AppTheme._();

  // Accent scale (`src/app.css`)
  static const Color accent50 = Color(0xFFF0F5FF);
  static const Color accent100 = Color(0xFFE2ECFF);
  static const Color accent200 = Color(0xFFC9DCFF);
  static const Color accent300 = Color(0xFFA8C6FF);
  static const Color accent400 = Color(0xFF92B8FF);
  static const Color accent500 = Color(0xFF7CAAFF);
  static const Color accent600 = Color(0xFF3A68D0);
  static const Color accent700 = Color(0xFF335CC0);
  static const Color accent800 = Color(0xFF2B4B99);
  static const Color accent900 = Color(0xFF263F78);
  static const Color accent950 = Color(0xFF172647);

  // Cool-tinted zinc scale (`src/app.css`)
  static const Color zinc50 = Color(0xFFFAFAFB);
  static const Color zinc100 = Color(0xFFF3F4F6);
  static const Color zinc200 = Color(0xFFE5E6EB);
  static const Color zinc300 = Color(0xFFD2D4DC);
  static const Color zinc400 = Color(0xFF9FA3B2);
  static const Color zinc500 = Color(0xFF71768A);
  static const Color zinc600 = Color(0xFF535868);
  static const Color zinc700 = Color(0xFF3D414E);
  static const Color zinc800 = Color(0xFF262933);
  static const Color zinc900 = Color(0xFF1A1C23);
  static const Color zinc950 = Color(0xFF111318);

  static const Color danger = Color(0xFFE06C75);

  static ThemeData get darkTheme => dark();
  static ThemeData get lightTheme => light();

  static ThemeData dark() {
    const colorScheme = ColorScheme.dark(
      primary: accent500,
      onPrimary: zinc950,
      secondary: accent400,
      onSecondary: zinc950,
      surface: zinc900,
      onSurface: zinc100,
      outline: zinc800,
      error: danger,
      onError: zinc950,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: zinc950,
      cardColor: zinc900,
      dividerColor: zinc800,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      textTheme: const TextTheme(
        headlineSmall: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: zinc100,
          letterSpacing: -0.3,
        ),
        titleMedium: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: zinc100,
        ),
        bodyMedium: TextStyle(
          fontSize: 13.5,
          color: zinc100,
        ),
        bodySmall: TextStyle(
          fontSize: 12,
          color: zinc400,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: zinc900,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        hintStyle: const TextStyle(color: zinc500, fontSize: 13),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: zinc800),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: zinc800),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: accent500),
        ),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 4,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
        activeTrackColor: accent500,
        inactiveTrackColor: zinc700,
        thumbColor: Colors.white,
        overlayColor: accent500.withValues(alpha: 0.18),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.dragged)) {
            return const Color(0x61FFFFFF);
          }
          return const Color(0x33FFFFFF);
        }),
        trackColor: WidgetStateProperty.all(Colors.transparent),
        trackBorderColor: WidgetStateProperty.all(Colors.transparent),
        radius: const Radius.circular(9999),
        thickness: WidgetStateProperty.all(4),
      ),
    );
  }

  static ThemeData light() {
    const colorScheme = ColorScheme.light(
      primary: accent600,
      onPrimary: Colors.white,
      secondary: accent500,
      onSecondary: Colors.white,
      surface: Colors.white,
      onSurface: zinc950,
      surfaceContainerHighest: zinc100,
      outline: zinc200,
      error: Color(0xFFDC2626),
      onError: Colors.white,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: zinc50,
      cardColor: Colors.white,
      dividerColor: zinc200,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      textTheme: const TextTheme(
        headlineSmall: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: zinc950,
          letterSpacing: -0.3,
        ),
        titleMedium: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: zinc950,
        ),
        bodyMedium: TextStyle(
          fontSize: 13.5,
          color: zinc950,
        ),
        bodySmall: TextStyle(
          fontSize: 12,
          color: zinc600,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: zinc100,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        hintStyle: const TextStyle(color: zinc500, fontSize: 13),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: zinc200),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: zinc200),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: accent600),
        ),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 4,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
        activeTrackColor: accent600,
        inactiveTrackColor: zinc300,
        thumbColor: Colors.white,
        overlayColor: accent600.withValues(alpha: 0.16),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.dragged)) {
            return const Color(0x6B18181B);
          }
          return const Color(0x3818181B);
        }),
        trackColor: WidgetStateProperty.all(Colors.transparent),
        trackBorderColor: WidgetStateProperty.all(Colors.transparent),
        radius: const Radius.circular(9999),
        thickness: WidgetStateProperty.all(4),
      ),
    );
  }
}

String formatDuration(double? seconds) {
  if (seconds == null || !seconds.isFinite || seconds < 0) {
    return '--:--';
  }
  final totalSeconds = seconds.floor();
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final secs = totalSeconds % 60;
  final mm = minutes.toString().padLeft(hours > 0 ? 2 : 1, '0');
  final ss = secs.toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:$mm:$ss';
  }
  return '$mm:$ss';
}

String formatDurationMs(BigInt? ms) {
  if (ms == null) return '--:--';
  return formatDuration(ms.toDouble() / 1000.0);
}

String formatListeningDuration(BigInt ms) {
  final totalSeconds = ms.toInt() ~/ 1000;
  if (totalSeconds <= 0) return '0m';
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  if (hours > 0) {
    return '${hours}h ${minutes}m';
  }
  if (minutes > 0) {
    return '${minutes}m';
  }
  return '${totalSeconds}s';
}
