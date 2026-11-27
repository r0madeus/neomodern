import 'dart:ui' show PointerDeviceKind;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/cover_art.dart';
import 'package:neomodern/ui/tinted_backdrop.dart';
import 'package:neomodern/ui/widgets/motion_primitives.dart';

void main() {
  group('AppTheme color scales & theme data', () {
    test('exposes Editorial Catalog accent and warm ink/paper scales', () {
      expect(AppTheme.accent50, const Color(0xFFF3F6F3));
      expect(AppTheme.accent500, const Color(0xFFA3C4A8));
      expect(AppTheme.accent600, const Color(0xFF2D4F3E));
      expect(AppTheme.accent950, const Color(0xFF121A16));

      expect(AppTheme.zinc50, const Color(0xFFF7F5F0));
      expect(AppTheme.zinc100, const Color(0xFFF5F3EE));
      expect(AppTheme.zinc200, const Color(0xFFE5E1D8));
      expect(AppTheme.zinc700, const Color(0xFF333338));
      expect(AppTheme.zinc800, const Color(0xFF232327));
      expect(AppTheme.zinc900, const Color(0xFF17171A));
      expect(AppTheme.zinc950, const Color(0xFF101012));
    });

    test('darkTheme and lightTheme configure expected scaffolds and scrollbars',
        () {
      final dark = AppTheme.darkTheme;
      expect(dark.brightness, Brightness.dark);
      expect(dark.scaffoldBackgroundColor, const Color(0xFF101012));
      expect(dark.colorScheme.surface, const Color(0xFF17171A));
      expect(dark.dividerColor, const Color(0xFF232327));
      expect(dark.scrollbarTheme.thickness?.resolve({}), 3.5);

      final light = AppTheme.lightTheme;
      expect(light.brightness, Brightness.light);
      expect(light.scaffoldBackgroundColor, const Color(0xFFF7F5F0));
      expect(light.colorScheme.surface, Colors.white);
      expect(light.dividerColor, const Color(0xFFE5E1D8));
      expect(light.scrollbarTheme.thickness?.resolve({}), 3.5);
    });
  });

  group('tintFromArgb', () {
    test('returns CoverTint.neutral for null or low-saturation colors', () {
      expect(tintFromArgb(null), CoverTint.neutral);
      expect(tintFromArgb(0xFF808080), CoverTint.neutral);
      expect(tintFromArgb(0xFF828488), CoverTint.neutral);
    });

    test('derives restrained editorial HSL top, surface, and dim colors for saturated RGB',
        () {
      final tint = tintFromArgb(0xFFFF0000);
      expect(tint, isNot(CoverTint.neutral));
      expect(
        tint.top,
        HSLColor.fromAHSL(1.0, 0.0, 0.28, 0.19).toColor(),
      );
      expect(
        tint.surface,
        HSLColor.fromAHSL(1.0, 0.0, 0.28 * 0.85, 0.14).toColor(),
      );
      expect(
        tint.dim,
        HSLColor.fromAHSL(1.0, 0.0, 0.36, 0.70).toColor(),
      );

      final blueTint = tintFromArgb(0xFF336699);
      expect(
        blueTint.top,
        HSLColor.fromAHSL(1.0, 210.0, 0.28, 0.19).toColor(),
      );
    });
  });

  group('genreColor', () {
    test('matches deterministic 32-bit FNV-1a editorial palette mapping', () {
      expect(genreColor('Rock'), kGenrePalette[0]);
      expect(genreColor('Electronic'), kGenrePalette[3]);
      expect(genreColor('  jazz  '), kGenrePalette[4]);
      expect(genreColor('Jazz'), kGenrePalette[4]);
      expect(genreColor('Ambient'), kGenrePalette[3]);
      expect(genreColor('Synthwave'), kGenrePalette[0]);
      expect(genreColor(''), kGenrePalette[1]);
    });
  });

  group('TintedBackdrop', () {
    testWidgets('crossfades between solid/gradient changes using ping-pong layers',
        (WidgetTester tester) async {
      Color bg = const Color(0xFF112233);
      late StateSetter setOuterState;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: StatefulBuilder(
            builder: (context, setState) {
              setOuterState = setState;
              return Scaffold(
                body: TintedBackdrop.solid(
                  color: bg,
                  child: const Text('Backdrop Child'),
                ),
              );
            },
          ),
        ),
      );

      expect(find.text('Backdrop Child'), findsOneWidget);
      var animated =
          tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
      expect(animated.opacity, 0.0);

      setOuterState(() => bg = const Color(0xFF445566));
      await tester.pump();
      animated = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
      expect(animated.opacity, 1.0);

      setOuterState(() => bg = const Color(0xFF778899));
      await tester.pump();
      animated = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
      expect(animated.opacity, 0.0);
    });

    testWidgets('supports TintedBackdrop.gradient without child',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 120,
              height: 120,
              child: TintedBackdrop.gradient(
                gradient: LinearGradient(
                  colors: [Color(0xFF19C3A1), Color(0xFF06302E)],
                ),
              ),
            ),
          ),
        ),
      );

      final boxes = tester.widgetList<DecoratedBox>(find.byType(DecoratedBox));
      expect(
        boxes.any((b) =>
            b.decoration is BoxDecoration &&
            (b.decoration as BoxDecoration).gradient is LinearGradient),
        isTrue,
      );
    });
  });

  group('Motion primitives', () {
    testWidgets('EqualizerIndicator renders 3 pill bars and animates when playing',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: const Scaffold(
            body: EqualizerIndicator(playing: true),
          ),
        ),
      );

      expect(
        find.descendant(
          of: find.byType(EqualizerIndicator),
          matching: find.byType(Transform),
        ),
        findsNWidgets(3),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(EqualizerIndicator), findsOneWidget);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: const Scaffold(
            body: EqualizerIndicator(playing: false),
          ),
        ),
      );
      expect(
        find.descendant(
          of: find.byType(EqualizerIndicator),
          matching: find.byType(Transform),
        ),
        findsNWidgets(3),
      );
    });

    testWidgets('HoverSeekBar reveals 12px thumb on hover and seeks on tap/drag',
        (WidgetTester tester) async {
      double current = 0.25;
      double? started;
      double? ended;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                child: StatefulBuilder(
                  builder: (context, setState) {
                    return HoverSeekBar(
                      value: current,
                      min: 0,
                      max: 100,
                      onChangeStart: (v) => started = v,
                      onChanged: (v) => setState(() => current = v),
                      onChangeEnd: (v) => ended = v,
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );

      var thumbOpacity =
          tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
      expect(thumbOpacity.opacity, 0.0);

      final gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.byType(HoverSeekBar)));
      await tester.pumpAndSettle();

      thumbOpacity =
          tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
      expect(thumbOpacity.opacity, 1.0);

      await tester.tapAt(tester.getCenter(find.byType(HoverSeekBar)));
      await tester.pump();
      expect(started, closeTo(50.0, 2.0));
      expect(current, closeTo(50.0, 2.0));
      expect(ended, closeTo(50.0, 2.0));

      await tester.drag(find.byType(HoverSeekBar), const Offset(50, 0));
      await tester.pumpAndSettle();
      expect(current, greaterThan(60.0));
    });

    testWidgets('HoverSeekBar alwaysShowThumb shows 16px thumb for touch',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: Scaffold(
            body: SizedBox(
              width: 200,
              child: HoverSeekBar(
                value: 0.5,
                alwaysShowThumb: true,
                light: true,
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );

      final thumbOpacity =
          tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
      expect(thumbOpacity.opacity, 1.0);
    });

    testWidgets('AnimatedSaveButton toggles icons and supports revealOnHover',
        (WidgetTester tester) async {
      var saved = false;
      var rowHovered = false;
      late StateSetter setOuterState;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                setOuterState = setState;
                return AnimatedSaveButton(
                  isSaved: saved,
                  revealOnHover: true,
                  isRowHovered: rowHovered,
                  onPressed: () => setState(() => saved = !saved),
                );
              },
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.add_circle_outline_rounded), findsOneWidget);
      var opacity =
          tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
      expect(opacity.opacity, 0.0);

      setOuterState(() => rowHovered = true);
      await tester.pump();
      opacity = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
      expect(opacity.opacity, 1.0);

      await tester.tap(find.byType(AnimatedSaveButton));
      await tester.pump();
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 280));
    });

    testWidgets('HoverPlayButton handles play/pause and reveal mode',
        (WidgetTester tester) async {
      var tapped = 0;
      var playing = false;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return HoverPlayButton(
                  isPlaying: playing,
                  reveal: true,
                  isParentHovered: true,
                  onPressed: () {
                    tapped++;
                    setState(() => playing = !playing);
                  },
                );
              },
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      await tester.tap(find.byType(HoverPlayButton));
      await tester.pumpAndSettle();
      expect(tapped, 1);
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    });

    testWidgets('ViewFadeIn fades child into view',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ViewFadeIn(child: Text('Faded View')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Faded View'), findsOneWidget);
    });
  });

  group('MixCoverArt', () {
    testWidgets('renders weekly-favorites, on-repeat, rediscover, focus-mix, and fallback',
        (WidgetTester tester) async {
      const weekly = UiDynamicMix(
        id: 'weekly-favorites',
        title: 'Weekly Favorites',
        subtitle: 'Most played over 7 days',
        trackCount: 12,
        coverPaths: [],
      );
      const onRepeat = UiDynamicMix(
        id: 'on-repeat',
        title: 'On Repeat',
        subtitle: 'Songs you kept coming back to',
        trackCount: 15,
        coverPaths: [],
      );
      const rediscover = UiDynamicMix(
        id: 'rediscover',
        title: 'Rediscover',
        subtitle: 'Past listens',
        trackCount: 10,
        coverPaths: [],
      );
      const artistMix = UiDynamicMix(
        id: 'focus-mix',
        title: 'Radiohead Mix',
        subtitle: 'Inspired by your plays',
        trackCount: 20,
        coverPaths: [],
      );
      const genreMix = UiDynamicMix(
        id: 'focus-mix',
        title: 'Electronic Mix',
        subtitle: 'Inspired by your plays',
        trackCount: 20,
        coverPaths: [],
      );
      const customMix = UiDynamicMix(
        id: 'custom-other',
        title: 'Custom Mix',
        subtitle: 'Other',
        trackCount: 5,
        coverPaths: [],
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: Scaffold(
            body: SingleChildScrollView(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: const [
                  MixCoverArt(mix: weekly, size: 120),
                  MixCoverArt(mix: onRepeat, size: 120),
                  MixCoverArt(mix: rediscover, size: 120),
                  MixCoverArt(
                    mix: artistMix,
                    subject: 'Radiohead',
                    subjectKind: 'artist',
                    size: 120,
                  ),
                  MixCoverArt(
                    mix: genreMix,
                    subject: 'Electronic',
                    subjectKind: 'genre',
                    size: 120,
                  ),
                  MixCoverArt(mix: customMix, size: 120),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.text('7'), findsOneWidget);
      expect(find.text('Weekly Favorites'), findsOneWidget);
      expect(find.text('On Repeat'), findsOneWidget);
      expect(find.byIcon(Icons.repeat_rounded), findsOneWidget);
      expect(find.text('Rediscover'), findsOneWidget);
      expect(find.text('✦'), findsNWidgets(3));
      expect(find.text('MIX'), findsOneWidget);
      expect(find.text('Radiohead Mix'), findsOneWidget);
      expect(find.text('Electronic Mix'), findsOneWidget);
      expect(find.byType(CollageCover), findsOneWidget);
    });
  });
}
