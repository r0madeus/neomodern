import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Legacy color aliases preserved for existing views while adopting the
/// Editorial Catalog warm-neutral ink & paper palette (K30).
class AppColors {
  AppColors._();

  static const Color canvas = AppTheme.zinc950;
  static const Color sidebar = Color(0xFF131315);
  static const Color surface = AppTheme.zinc900;
  static const Color surfaceHover = AppTheme.zinc800;
  static const Color border = AppTheme.zinc800;

  static const Color accent = AppTheme.accent500;
  static const Color accentMuted = Color(0x24A3C4A8);

  static const Color textPrimary = AppTheme.zinc100;
  static const Color textSecondary = AppTheme.zinc400;
  static const Color textMuted = AppTheme.zinc500;
  static const Color danger = Color(0xFFD96B70);
}

/// Cover-derived tint colors with restrained editorial ink-wash saturation.
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
    top: Color(0xFF232327),
    surface: Color(0xFF17171A),
    dim: Color(0xFFA7A49C),
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

/// Converts a 32-bit ARGB color integer into restrained editorial ink-wash
/// HSL cover tint colors so cover art colors the atmosphere without harsh blocks.
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

  final sat = math.min(s, 0.28);
  if (sat < 0.06) return CoverTint.neutral;

  return CoverTint(
    top: HSLColor.fromAHSL(1.0, h, sat, 0.19).toColor(),
    surface: HSLColor.fromAHSL(1.0, h, sat * 0.85, 0.14).toColor(),
    dim: HSLColor.fromAHSL(1.0, h, math.min(sat + 0.08, 0.36), 0.70).toColor(),
  );
}

/// Convenience helper converting an optional [Color] into a [CoverTint].
CoverTint tintFromColor(Color? color) =>
    color == null ? CoverTint.neutral : tintFromArgb(color.toARGB32());

const List<Color> kGenrePalette = [
  Color(0xFF1F4E46),
  Color(0xFF6E2D3A),
  Color(0xFF343B6E),
  Color(0xFF6B4626),
  Color(0xFF214E58),
  Color(0xFF4F2F5E),
  Color(0xFF244566),
  Color(0xFF6B2B47),
  Color(0xFF39522B),
  Color(0xFF2E4254),
  Color(0xFF73392A),
  Color(0xFF42316E),
];

/// Deterministic editorial card background color for a genre or mix label,
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

  // Bundled offline SIL OFL font families (K30 Editorial Catalog)
  static const String fontSans = 'EditorialSans';
  static const String fontSerif = 'EditorialSerif';
  static const String fontMono = 'EditorialMono';

  // Editorial paper & ink signature tones
  static const Color editorialPaper = Color(0xFFF5F3EE);
  static const Color editorialInk = Color(0xFF101012);
  static const Color hairline = Color(0x1CFFFFFF);
  static const Color hairlineStrong = Color(0x36FFFFFF);

  // Restrained sage-mineral accent scale (distinct from Spotify green & SaaS blue)
  static const Color accent50 = Color(0xFFF3F6F3);
  static const Color accent100 = Color(0xFFE3EBE4);
  static const Color accent200 = Color(0xFFC8D7CA);
  static const Color accent300 = Color(0xFFB3CBB7);
  static const Color accent400 = Color(0xFFBDD4C0);
  static const Color accent500 = Color(0xFFA3C4A8);
  static const Color accent600 = Color(0xFF2D4F3E);
  static const Color accent700 = Color(0xFF244032);
  static const Color accent800 = Color(0xFF1C3227);
  static const Color accent900 = Color(0xFF17261F);
  static const Color accent950 = Color(0xFF121A16);

  // Warm-neutral editorial ink & paper neutral scale
  static const Color zinc50 = Color(0xFFF7F5F0);
  static const Color zinc100 = Color(0xFFF5F3EE);
  static const Color zinc200 = Color(0xFFE5E1D8);
  static const Color zinc300 = Color(0xFFD5D2CA);
  static const Color zinc400 = Color(0xFFA7A49C);
  static const Color zinc500 = Color(0xFF75726B);
  static const Color zinc600 = Color(0xFF55534E);
  static const Color zinc700 = Color(0xFF333338);
  static const Color zinc800 = Color(0xFF232327);
  static const Color zinc900 = Color(0xFF17171A);
  static const Color zinc950 = Color(0xFF101012);

  static const Color danger = Color(0xFFD96B70);

  /// Editorial serif style for display titles, section headers, and active lyrics.
  static TextStyle displayStyle({
    double fontSize = 24,
    FontWeight fontWeight = FontWeight.w400,
    FontStyle fontStyle = FontStyle.normal,
    Color color = zinc100,
    double? height,
    double letterSpacing = -0.2,
  }) {
    return TextStyle(
      fontFamily: fontSerif,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontStyle: fontStyle,
      color: color,
      height: height,
      letterSpacing: letterSpacing,
    );
  }

  /// Tabular monospace style for track numbers, durations, and technical metadata.
  static TextStyle monoStyle({
    double fontSize = 11.5,
    FontWeight fontWeight = FontWeight.w400,
    Color color = zinc400,
    double letterSpacing = 0.0,
    double? height,
  }) {
    return TextStyle(
      fontFamily: fontMono,
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      letterSpacing: letterSpacing,
      height: height,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
  }

  /// Uppercase tracked catalog kicker label (e.g. `ALBUM · 2018`, `LIBRARY`).
  static TextStyle kickerStyle({
    double fontSize = 10.5,
    Color color = zinc500,
    FontWeight fontWeight = FontWeight.w500,
  }) {
    return TextStyle(
      fontFamily: fontMono,
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      letterSpacing: 1.2,
    );
  }

  static ThemeData get darkTheme => dark();
  static ThemeData get lightTheme => light();

  static ThemeData dark() {
    const colorScheme = ColorScheme.dark(
      primary: editorialPaper,
      onPrimary: editorialInk,
      secondary: accent500,
      onSecondary: editorialInk,
      surface: zinc900,
      onSurface: zinc100,
      outline: zinc800,
      error: danger,
      onError: zinc950,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: fontSans,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: zinc950,
      cardColor: zinc900,
      dividerColor: zinc800,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      textTheme: const TextTheme(
        headlineSmall: TextStyle(
          fontFamily: fontSerif,
          fontSize: 25,
          fontWeight: FontWeight.w400,
          color: zinc100,
          letterSpacing: -0.2,
        ),
        titleMedium: TextStyle(
          fontFamily: fontSans,
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: zinc100,
        ),
        bodyMedium: TextStyle(
          fontFamily: fontSans,
          fontSize: 13.5,
          color: zinc100,
        ),
        bodySmall: TextStyle(
          fontFamily: fontSans,
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
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: zinc800),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: zinc800),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: zinc400),
        ),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 3.5,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5.5),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
        activeTrackColor: editorialPaper,
        inactiveTrackColor: zinc700,
        thumbColor: editorialPaper,
        overlayColor: editorialPaper.withValues(alpha: 0.16),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.dragged)) {
            return const Color(0x5CEAE6DC);
          }
          return const Color(0x2CEAE6DC);
        }),
        trackColor: WidgetStateProperty.all(Colors.transparent),
        trackBorderColor: WidgetStateProperty.all(Colors.transparent),
        radius: const Radius.circular(9999),
        thickness: WidgetStateProperty.all(3.5),
      ),
    );
  }

  static ThemeData light() {
    const colorScheme = ColorScheme.light(
      primary: editorialInk,
      onPrimary: editorialPaper,
      secondary: accent600,
      onSecondary: Colors.white,
      surface: Colors.white,
      onSurface: zinc950,
      surfaceContainerHighest: zinc100,
      outline: zinc200,
      error: Color(0xFFB9383E),
      onError: Colors.white,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      fontFamily: fontSans,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: zinc50,
      cardColor: Colors.white,
      dividerColor: zinc200,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      textTheme: const TextTheme(
        headlineSmall: TextStyle(
          fontFamily: fontSerif,
          fontSize: 25,
          fontWeight: FontWeight.w400,
          color: zinc950,
          letterSpacing: -0.2,
        ),
        titleMedium: TextStyle(
          fontFamily: fontSans,
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: zinc950,
        ),
        bodyMedium: TextStyle(
          fontFamily: fontSans,
          fontSize: 13.5,
          color: zinc950,
        ),
        bodySmall: TextStyle(
          fontFamily: fontSans,
          fontSize: 12,
          color: zinc600,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        hintStyle: const TextStyle(color: zinc500, fontSize: 13),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: zinc200),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: zinc200),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: editorialInk),
        ),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 3.5,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5.5),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
        activeTrackColor: editorialInk,
        inactiveTrackColor: zinc300,
        thumbColor: editorialInk,
        overlayColor: editorialInk.withValues(alpha: 0.14),
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
        thickness: WidgetStateProperty.all(3.5),
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
