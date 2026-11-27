import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/state/system_tools.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/backup_settings_section.dart';
import 'package:neomodern/ui/genre_view.dart';
import 'package:neomodern/ui/move_folder_dialog.dart';
import 'package:neomodern/ui/profiles_dialog.dart';
import 'package:neomodern/ui/recap_view.dart';
import 'package:neomodern/ui/right_panel.dart';
import 'package:neomodern/ui/search_view.dart';
import 'package:neomodern/ui/settings_view.dart';
import 'package:neomodern/ui/sources_view.dart';
import 'package:neomodern/ui/sync_settings_section.dart';
import 'package:neomodern/ui/tag_editor_dialog.dart';
import 'package:neomodern/ui/tinted_backdrop.dart';
import 'package:neomodern/ui/track_menu.dart';
import 'package:neomodern/ui/welcome_dialog.dart';
import 'package:neomodern/ui/widgets/neomodern_logo.dart';
import 'package:neomodern/ui/widgets/smooth_scroll.dart';
import 'package:neomodern/ui/widgets/track_row.dart';

void main() {
  test('formatDuration formats seconds cleanly', () {
    expect(formatDuration(null), '--:--');
    expect(formatDuration(0), '0:00');
    expect(formatDuration(65), '1:05');
    expect(formatDuration(3661), '1:01:01');
  });

  test('formatListeningDuration formats milliseconds cleanly', () {
    expect(formatListeningDuration(BigInt.zero), '0m');
    expect(formatListeningDuration(BigInt.from(45000)), '45s');
    expect(formatListeningDuration(BigInt.from(5 * 60 * 1000)), '5m');
    expect(formatListeningDuration(BigInt.from(125 * 60 * 1000)), '2h 5m');
  });

  test('PlayerController defaults match K29 playback settings', () {
    final ctrl = PlayerController();
    addTearDown(ctrl.dispose);

    expect(ctrl.snapshot.status, 'stopped');
    expect(ctrl.snapshot.replaygain, 'album');
    expect(ctrl.snapshot.gapless, true);
    expect(ctrl.snapshot.wasapiExclusive, false);
    expect(ctrl.snapshot.eqEnabled, false);
    expect(ctrl.snapshot.eqGainsDb.length, 10);
    expect(ctrl.snapshot.crossfadeSeconds, 0);
    expect(ctrl.offlineMode, false);
    expect(ctrl.hasEnabledSourceProviders, false);
    expect(ctrl.isProfileLocked, false);
  });

  test('parseProfileColor parses valid hex and falls back on invalid input', () {
    expect(parseProfileColor('#3e63dd'), const Color(0xFF3E63DD));
    expect(parseProfileColor('invalid'), AppColors.accent);
  });

  testWidgets('AppTheme configures Editorial Catalog dark and light tokens',
      (WidgetTester tester) async {
    final dark = AppTheme.dark();
    final light = AppTheme.light();

    expect(dark.scaffoldBackgroundColor, AppTheme.zinc950);
    expect(dark.colorScheme.primary, AppTheme.editorialPaper);
    expect(dark.colorScheme.onPrimary, AppTheme.editorialInk);
    expect(dark.textTheme.headlineSmall?.fontFamily, AppTheme.fontSerif);
    expect(dark.textTheme.bodyMedium?.fontFamily, AppTheme.fontSans);

    expect(light.scaffoldBackgroundColor, AppTheme.zinc50);
    expect(light.colorScheme.primary, AppTheme.editorialInk);
    expect(light.textTheme.headlineSmall?.fontFamily, AppTheme.fontSerif);

    final display = AppTheme.displayStyle(fontSize: 32);
    expect(display.fontFamily, AppTheme.fontSerif);
    final mono = AppTheme.monoStyle();
    expect(mono.fontFamily, AppTheme.fontMono);
    expect(mono.fontFeatures, contains(const FontFeature.tabularFigures()));
    final kicker = AppTheme.kickerStyle();
    expect(kicker.fontFamily, AppTheme.fontMono);

    // Restrained cover tint should cap saturation at editorial ink-wash levels
    final vibrantBlueTint = tintFromArgb(0xFF0055FF);
    final hslTop = HSLColor.fromColor(vibrantBlueTint.top);
    expect(hslTop.saturation, lessThanOrEqualTo(0.30));
    expect(hslTop.lightness, lessThanOrEqualTo(0.22));

    await tester.pumpWidget(
      MaterialApp(
        theme: dark,
        home: const Scaffold(body: Text('NeoModern')),
      ),
    );
    expect(find.text('NeoModern'), findsOneWidget);
  });

  testWidgets('StarFavoriteButton renders star icons and triggers callback',
      (WidgetTester tester) async {
    var toggled = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Row(
            children: [
              StarFavoriteButton(
                isFavorite: false,
                onPressed: () => toggled++,
              ),
              StarFavoriteButton(
                isFavorite: true,
                onPressed: () => toggled++,
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.star_outline_rounded), findsOneWidget);
    expect(find.byIcon(Icons.star_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.star_outline_rounded));
    await tester.pump();
    expect(toggled, 1);
  });

  testWidgets('RightPanel renders mode-specific headers without 3-tab pill bar',
      (WidgetTester tester) async {
    final ctrl = PlayerController();
    addTearDown(ctrl.dispose);
    var tab = RightPanelTab.nowPlaying;
    var closeCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: StatefulBuilder(
          builder: (context, setState) {
            return Scaffold(
              body: Column(
                children: [
                  Row(
                    children: [
                      TextButton(
                        onPressed: () =>
                            setState(() => tab = RightPanelTab.nowPlaying),
                        child: const Text('SwitchNP'),
                      ),
                      TextButton(
                        onPressed: () =>
                            setState(() => tab = RightPanelTab.queue),
                        child: const Text('SwitchQ'),
                      ),
                      TextButton(
                        onPressed: () =>
                            setState(() => tab = RightPanelTab.lyrics),
                        child: const Text('SwitchLyr'),
                      ),
                    ],
                  ),
                  Expanded(
                    child: RightPanel(
                      controller: ctrl,
                      activeTab: tab,
                      onTabChanged: (t) => setState(() => tab = t),
                      onClose: () => closeCount++,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );

    // NowPlaying mode header: "Now Playing" + Close (X), no redundant 3-tab pill bar.
    expect(find.text('Now Playing'), findsOneWidget);
    expect(find.text('Nothing playing'), findsOneWidget);
    expect(find.text('Now playing'), findsNothing);
    await tester.tap(find.byIcon(Icons.close_rounded));
    expect(closeCount, 1);

    // Queue mode header: ONLY 2 underline tabs ("Queue" and "Recently played") + Close (X).
    await tester.tap(find.text('SwitchQ'));
    await tester.pump();
    expect(find.text('Queue'), findsOneWidget);
    expect(find.text('Recently played'), findsOneWidget);
    expect(find.text('Queue is empty.'), findsOneWidget);
    await tester.tap(find.text('Recently played'));
    await tester.pump();
    expect(find.text('Nothing playing.'), findsOneWidget);

    // Lyrics mode header: "Lyrics" + Close (X).
    await tester.tap(find.text('SwitchLyr'));
    await tester.pump();
    expect(find.text('Lyrics'), findsOneWidget);
    expect(find.text('Play a track to view lyrics.'), findsOneWidget);
  });

  testWidgets('SettingsView displays clean Settings title without subtitle',
      (WidgetTester tester) async {
    final ctrl = PlayerController();
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(body: SettingsView(controller: ctrl)),
      ),
    );

    expect(find.text('Settings'), findsOneWidget);
    expect(
      find.text('Audio playback, watched folders, and offline privacy'),
      findsNothing,
    );
    expect(find.text('Library Folders'), findsOneWidget);
    expect(find.text('Playback'), findsOneWidget);
    expect(find.text('ReplayGain'), findsOneWidget);
    expect(find.text('Gapless Playback'), findsOneWidget);
  });

  testWidgets('RecapView shows 5 period pills, KPIs, insights, charts, and activity',
      (WidgetTester tester) async {
    final ctrl = PlayerController();
    addTearDown(ctrl.dispose);

    final summary = UiStatsSummary(
      totalListenedMs: BigInt.from(3660000),
      playCount: BigInt.from(18),
      rawEventCount: BigInt.from(20),
      skipCount: BigInt.from(2),
      completedCount: BigInt.from(16),
      uniqueTracks: BigInt.from(10),
      uniqueArtists: BigInt.from(4),
      uniqueAlbums: BigInt.from(5),
      activeDays: BigInt.from(6),
      longestStreakDays: BigInt.from(5),
      currentStreakDays: BigInt.from(3),
      completionRate: 0.80,
      peakHour: 21,
      favoriteWeekday: 4,
      firstListenAt: 1700000000,
      hourlyMs: Int64List.fromList(
        List<int>.generate(24, (h) => h == 21 ? 900000 : 60000),
      ),
      weekdayMs: Int64List.fromList(
        List<int>.generate(7, (d) => d == 4 ? 1200000 : 300000),
      ),
      monthly: [
        UiMonthlyStat(
          label: '2026-10',
          listenedMs: 1200000,
          plays: 6,
        ),
        UiMonthlyStat(
          label: '2026-11',
          listenedMs: 2460000,
          plays: 12,
        ),
      ],
      topGenres: [
        UiGenreStat(genre: 'Electronic', listenedMs: 2000000, plays: 10),
      ],
      topTracks: [
        UiTopTrackStat(
          trackId: 1,
          path: '/music/track1.flac',
          title: 'Daydreaming',
          artist: 'Radiohead',
          album: 'A Moon Shaped Pool',
          playCount: BigInt.from(9),
          listenedMs: BigInt.from(1800000),
          skipCount: BigInt.zero,
        ),
      ],
      topArtists: [
        UiTopArtistStat(
          artist: 'Radiohead',
          playCount: BigInt.from(12),
          listenedMs: BigInt.from(2400000),
          uniqueTracks: BigInt.from(4),
          skipCount: BigInt.zero,
        ),
      ],
      topAlbums: [
        UiTopAlbumStat(
          album: 'A Moon Shaped Pool',
          artist: 'Radiohead',
          albumId: 10,
          playCount: BigInt.from(9),
          listenedMs: BigInt.from(1800000),
        ),
      ],
      recentEvents: [
        UiRecentListenEvent(
          id: 1,
          trackId: 1,
          path: '/music/track1.flac',
          title: 'Daydreaming',
          artist: 'Radiohead',
          album: 'A Moon Shaped Pool',
          startedAt: 1700000000,
          listenedMs: 300000,
          completed: true,
          skipped: false,
          source: 'local',
        ),
      ],
      availableYears: Int32List.fromList([2026]),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: RecapView(
            controller: ctrl,
            onOpenArtist: (_) {},
            onOpenAlbum: (_) {},
            onFetchStatsRange: ({fromMs, toMs, sortByPlays = false}) async =>
                summary,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Listening Stats'), findsOneWidget);
    expect(find.text('7 Days'), findsOneWidget);
    expect(find.text('30 Days'), findsOneWidget);
    expect(find.text('This Year'), findsOneWidget);
    expect(find.text('All Time'), findsOneWidget);
    expect(find.text('Custom'), findsOneWidget);

    expect(find.text('80%'), findsOneWidget);
    expect(find.text('21:00'), findsOneWidget);
    expect(find.text('Friday'), findsOneWidget);
    expect(find.text('16 / 2'), findsOneWidget);
    expect(find.text('Electronic'), findsOneWidget);
    expect(find.text('Listening rhythm'), findsOneWidget);
    expect(find.text('Recent activity'), findsOneWidget);
    expect(find.text('Clear history'), findsOneWidget);
  });

  testWidgets('SyncSettingsSection keeps Party Queue disabled by default',
      (WidgetTester tester) async {
    final ctrl = PlayerController();
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: SyncSettingsSection(controller: ctrl),
          ),
        ),
      ),
    );

    expect(find.text('Phone Sync & Remote Control'), findsOneWidget);
    expect(find.text('Experimental — Party Queue'), findsOneWidget);
    expect(
      find.text(
          'Disabled by default. Turn on to host a local Party Queue session.'),
      findsOneWidget,
    );
    expect(find.text('Start Session'), findsNothing);
  });

  testWidgets('ExternalSourcesSettingsSection shows neutral empty state',
      (WidgetTester tester) async {
    final ctrl = PlayerController();
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: ExternalSourcesSettingsSection(
            controller: ctrl,
            onDetectSystemTools: () => const DetectedSystemTools(),
          ),
        ),
      ),
    );

    expect(find.text('External Sources (HTTP/JSON)'), findsOneWidget);
    expect(
      find.text(
        'No external sources configured. Add a neutral HTTP/JSON provider (e.g. self-hosted bridge) to search and stream external catalogs.',
      ),
      findsOneWidget,
    );
    expect(find.text('Add detected tools'), findsNothing);
    expect(find.text('Auto-install'), findsNothing);
  });

  testWidgets('ProfileBadgeButton and QrMatrixView render cleanly',
      (WidgetTester tester) async {
    final ctrl = PlayerController();
    addTearDown(ctrl.dispose);
    var tapped = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Column(
            children: [
              ProfileBadgeButton(
                controller: ctrl,
                onTap: () => tapped++,
              ),
              const QrMatrixView(
                matrix: [true, false, false, true],
                qrSize: 2,
                displaySize: 40,
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Profile'), findsOneWidget);
    await tester.tap(find.text('Profile'));
    expect(tapped, 1);
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('SourcesView prompts to enable a source when none configured',
      (WidgetTester tester) async {
    final ctrl = PlayerController();
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(body: SourcesView(controller: ctrl)),
      ),
    );

    expect(find.text('Sources'), findsOneWidget);
    expect(
      find.text('Enable an external source in Settings to search and stream.'),
      findsOneWidget,
    );
  });

  test('AppStrings resolves EN, TR, and system locale cleanly', () {
    addTearDown(() => AppStrings.setLanguage('system'));

    AppStrings.setLanguage('en');
    expect(AppStrings.resolveLanguage(const Locale('tr', 'TR')), 'en');
    expect(t('Songs'), 'Songs');
    expect(t('Queue ({n})', {'n': 4}), 'Queue (4)');

    AppStrings.setLanguage('tr');
    expect(AppStrings.resolveLanguage(const Locale('en', 'US')), 'tr');
    expect(t('Songs'), 'Şarkılar');
    expect(t('Queue ({n})', {'n': 4}), 'Sıra (4)');

    AppStrings.setLanguage('system');
    expect(AppStrings.resolveLanguage(const Locale('tr', 'TR')), 'tr');
    expect(AppStrings.resolveLanguage(const Locale('en', 'US')), 'en');
  });

  testWidgets('TintedBackdrop renders two ping-pong AnimatedOpacity layers and child',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: const Scaffold(
          body: TintedBackdrop(
            tintColor: Color(0xFF336699),
            child: Text('Header Content'),
          ),
        ),
      ),
    );

    expect(find.text('Header Content'), findsOneWidget);
    expect(find.byType(AnimatedOpacity), findsOneWidget);
    final boxes = tester.widgetList<DecoratedBox>(find.byType(DecoratedBox));
    expect(
      boxes.any((b) =>
          b.decoration is BoxDecoration &&
          (b.decoration as BoxDecoration).gradient is LinearGradient),
      isTrue,
    );
  });

  testWidgets('WelcomeDialog shows detected Music folder and handles Add & Scan',
      (WidgetTester tester) async {
    final ctrl = PlayerController();
    addTearDown(ctrl.dispose);
    String? addedPath;
    var dismissed = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: WelcomeDialog(
            controller: ctrl,
            onFetchDefaultDir: () async => r'C:\Users\Test\Music',
            onAddAndScan: (path) async => addedPath = path,
            onDismiss: () async => dismissed = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Welcome to NeoModern'), findsOneWidget);
    expect(find.text(r'C:\Users\Test\Music'), findsOneWidget);
    expect(find.text('Add & Scan'), findsOneWidget);

    await tester.tap(find.text('Add & Scan'));
    await tester.pumpAndSettle();

    expect(addedPath, r'C:\Users\Test\Music');
    expect(dismissed, true);
  });

  testWidgets('TagEditorDialog loads tags, saves edits, and surfaces errors',
      (WidgetTester tester) async {
    final ctrl = PlayerController();
    addTearDown(ctrl.dispose);

    const track = UiTrackRow(
      id: 1,
      title: 'Old Title',
      artist: 'Old Artist',
      album: 'Old Album',
      path: r'C:\Music\track.flac',
      plays: 0,
    );
    UiTrackTags? written;
    var failWrite = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: TagEditorDialog(
            controller: ctrl,
            track: track,
            onReadTags: (_) async => const UiTrackTags(
              title: 'Old Title',
              artist: 'Old Artist',
              album: 'Old Album',
              albumArtist: 'Album Artist',
              trackNumber: 3,
              discNumber: 1,
              year: 2024,
              genre: 'Electronic',
            ),
            onWriteTags: (_, tags) async {
              if (failWrite) {
                throw StateError('Track is currently playing');
              }
              written = tags;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Edit Tags'), findsOneWidget);
    expect(find.text('Old Title'), findsOneWidget);
    expect(find.text('Electronic'), findsOneWidget);

    failWrite = true;
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Track is currently playing'), findsOneWidget);

    failWrite = false;
    await tester.enterText(find.byType(TextField).first, 'New Title');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(written?.title, 'New Title');
    expect(written?.year, 2024);
  });

  testWidgets('NeoModernLogo renders vector CustomPaint at requested size',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: NeoModernLogo(size: 32, color: Colors.white),
          ),
        ),
      ),
    );

    final logoBox = tester.widget<SizedBox>(
      find.descendant(
        of: find.byType(NeoModernLogo),
        matching: find.byType(SizedBox),
      ),
    );
    expect(logoBox.width, 32);
    expect(logoBox.height, 32);
    expect(
      find.descendant(
        of: find.byType(NeoModernLogo),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );
  });

  testWidgets('SmoothScrollWrapper animates mouse wheel scroll smoothly',
      (WidgetTester tester) async {
    final scrollCtrl = SmoothScrollController();
    addTearDown(scrollCtrl.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: SizedBox(
            height: 200,
            child: SmoothScrollWrapper(
              controller: scrollCtrl,
              child: ListView.builder(
                controller: scrollCtrl,
                itemExtent: 50,
                itemCount: 40,
                itemBuilder: (_, i) => Text('Item $i'),
              ),
            ),
          ),
        ),
      ),
    );

    expect(scrollCtrl.offset, 0.0);
    final center = tester.getCenter(find.byType(ListView));
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: center,
        kind: PointerDeviceKind.mouse,
        scrollDelta: const Offset(0, 120),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(scrollCtrl.offset, greaterThan(0.0));
    expect(scrollCtrl.offset, lessThan(120.0));

    await tester.pumpAndSettle();
    expect(scrollCtrl.offset, closeTo(120.0, 0.1));
  });

  testWidgets('DesktopTrackRow TitleLink navigates to track albumId on click',
      (WidgetTester tester) async {
    final ctrl = PlayerController();
    addTearDown(ctrl.dispose);
    PlatformInt64? openedAlbum;

    const track = UiTrackRow(
      id: 1,
      title: 'Click Title To Album',
      artist: 'Some Artist',
      album: 'Some Album',
      albumId: 42,
      path: '/music/a.flac',
      plays: 0,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: SizedBox(
            height: 56,
            child: DesktopTrackRow(
              indexLabel: '1',
              track: track,
              controller: ctrl,
              onTap: () {},
              onPlay: () {},
              onOpenAlbum: (id) => openedAlbum = id,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Click Title To Album'));
    await tester.pump();
    expect(openedAlbum, 42);
  });

  testWidgets('SearchView displays Browse all genre cards and searches library',
      (WidgetTester tester) async {
    final ctrl = PlayerController();
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: SearchView(
            controller: ctrl,
            onOpenAlbum: (_) {},
            onOpenArtist: (_) {},
            onFetchGenres: () async => const [
              UiGenreInfo(name: 'Electronic', trackCount: 24, albumCount: 3),
              UiGenreInfo(name: 'Jazz', trackCount: 12, albumCount: 2),
            ],
            onSearchArtists: (q) async => [
              UiArtistRow(
                name: 'Boards of Canada',
                trackCount: 10,
                albumCount: 2,
                playCount: BigInt.zero,
                listenedMs: BigInt.zero,
              ),
            ]
                .where((a) => a.name.toLowerCase().contains(q.toLowerCase()))
                .toList(),
            onSearchAlbums: (_) async => const [],
            onSearchTracks: (_) async => const [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Browse all'), findsOneWidget);
    expect(find.text('Electronic'), findsOneWidget);
    expect(find.text('Jazz'), findsOneWidget);
    expect(find.text('Ctrl K'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Boards');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(find.text('Boards of Canada'), findsOneWidget);
  });

  testWidgets('GenreView renders hero banner, albums, and paginated tracks',
      (WidgetTester tester) async {
    final ctrl = PlayerController();
    addTearDown(ctrl.dispose);
    PlatformInt64? openedAlbum;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: GenreView(
            name: 'Electronic',
            controller: ctrl,
            onBack: () {},
            onOpenAlbum: (id) => openedAlbum = id,
            onOpenArtist: (_) {},
            onFetchGenreDetail: (genre) async => UiGenreDetail(
              name: genre,
              trackCount: 1,
              albumCount: 1,
              totalDurationMs: BigInt.from(240000),
              albums: const [
                UiAlbumRow(
                  id: 77,
                  title: 'Music Has the Right to Children',
                  albumArtist: 'Boards of Canada',
                  year: 1998,
                  trackCount: 18,
                ),
              ],
            ),
            onFetchGenreTracksPage: (genre, offset, limit) async => const [
              UiTrackRow(
                id: 99,
                title: 'Roygbiv',
                artist: 'Boards of Canada',
                album: 'Music Has the Right to Children',
                albumId: 77,
                path: '/music/roygbiv.flac',
                plays: 0,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Electronic'), findsOneWidget);
    expect(find.text('Music Has the Right to Children'), findsWidgets);

    await tester.scrollUntilVisible(
      find.text('Roygbiv'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Roygbiv'), findsOneWidget);

    await tester.tap(find.text('Roygbiv'));
    await tester.pump();
    expect(openedAlbum, 77);
  });

  testWidgets(
      'BackupSettingsSection renders export/import buttons, auto-backup toggle, and import flow',
      (WidgetTester tester) async {
    final ctrl = PlayerController();
    addTearDown(ctrl.dispose);

    String? exportedPath;
    String? stagedPath;
    var closedApp = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: BackupSettingsSection(
              controller: ctrl,
              onFetchAutoStatus: () async => const UiAutoBackupStatus(
                enabled: false,
                cadence: 'daily',
                keep: 5,
              ),
              onPickSaveFile: (name) async => 'C:\\Backups\\$name',
              onExport: (destPath) async {
                exportedPath = destPath;
                return UiBackupExportResult(
                  path: destPath,
                  sizeBytes: BigInt.from(2 * 1024 * 1024),
                  entryCount: BigInt.from(12),
                );
              },
              onPickOpenFile: () async => r'C:\Backups\sample.nmbackup',
              onInspect: (srcPath) async => UiBackupPreview(
                appVersion: '2.5.0',
                createdAt: PlatformInt64Util.from(1700000000000),
                sourcePlatform: 'windows',
                profilesCount: 2,
                tracksCount: BigInt.from(150),
                playlistsCount: BigInt.from(4),
                listensCount: BigInt.from(300),
                sizeBytes: BigInt.from(2 * 1024 * 1024),
                entryCount: BigInt.from(12),
              ),
              onStageImport: (srcPath) async {
                stagedPath = srcPath;
                return const UiBackupImportResult(
                  safetyBackupDir: r'C:\Data\before-import',
                  restartRequired: true,
                );
              },
              onCloseApp: () => closedApp = true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Backup & Restore'), findsOneWidget);
    expect(find.text('Export backup'), findsOneWidget);
    expect(find.text('Import backup…'), findsOneWidget);
    expect(find.text('Automatic backup'), findsOneWidget);
    expect(find.text('Back up now'), findsOneWidget);

    final autoSwitch = tester.widget<Switch>(find.byType(Switch));
    expect(autoSwitch.value, isFalse);

    await tester.tap(find.text('Export backup'));
    await tester.pumpAndSettle();
    expect(exportedPath, contains('NeoModern-backup-'));
    expect(find.text('Backup exported (2.0 MB, 12 items)'), findsWidgets);

    await tester.tap(find.text('Import backup…'));
    await tester.pumpAndSettle();

    expect(find.text('Restore Backup'), findsOneWidget);
    expect(find.text('2.5.0'), findsOneWidget);
    expect(find.text('windows'), findsOneWidget);
    expect(find.text('150'), findsOneWidget);
    expect(
      find.text(
        'Replace all data on this device? Your current data will be copied to a safety backup first.',
      ),
      findsOneWidget,
    );
    expect(find.text('Replace & Import'), findsOneWidget);

    await tester.tap(find.text('Replace & Import'));
    await tester.pumpAndSettle();

    expect(stagedPath, r'C:\Backups\sample.nmbackup');
    expect(find.text('Import staged. Restart NeoModern to apply.'), findsOneWidget);
    expect(find.text('Close app'), findsOneWidget);
    expect(find.text('Later'), findsOneWidget);

    await tester.tap(find.text('Close app'));
    await tester.pump();
    expect(closedApp, isTrue);
  });

  testWidgets(
      'MoveFolderDialog shows old path, folder picker button, and relocate preview',
      (WidgetTester tester) async {
    final ctrl = PlayerController();
    addTearDown(ctrl.dispose);

    int? previewFolderId;
    String? previewNewPath;
    int? appliedFolderId;
    String? appliedNewPath;
    UiRelocateResult? poppedResult;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  poppedResult = await showDialog<UiRelocateResult>(
                    context: context,
                    builder: (_) => MoveFolderDialog(
                      controller: ctrl,
                      folder: UiFolderInfo(
                        id: PlatformInt64Util.from(7),
                        path: r'C:\Old\Music',
                      ),
                      onPickDirectory: () async => r'D:\New\Music',
                      onPreviewRelocate: (id, newPath) async {
                        previewFolderId = id;
                        previewNewPath = newPath;
                        return UiRelocatePreview(
                          oldPath: r'C:\Old\Music',
                          newPath: newPath,
                          totalTracks: BigInt.from(45),
                          foundTracks: BigInt.from(42),
                          missingTracks: BigInt.from(3),
                        );
                      },
                      onApplyRelocate: (id, newPath) async {
                        appliedFolderId = id;
                        appliedNewPath = newPath;
                        return UiRelocateResult(
                          rewrittenTracks: BigInt.from(45),
                        );
                      },
                    ),
                  );
                },
                child: const Text('OpenMoveDialog'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('OpenMoveDialog'));
    await tester.pumpAndSettle();

    expect(find.text('Move music folder'), findsOneWidget);
    expect(find.text(r'C:\Old\Music'), findsOneWidget);
    expect(find.text('Choose new folder…'), findsOneWidget);

    await tester.tap(find.text('Choose new folder…'));
    await tester.pumpAndSettle();

    expect(previewFolderId, 7);
    expect(previewNewPath, r'D:\New\Music');
    expect(find.text(r'D:\New\Music'), findsOneWidget);
    expect(find.text('Found 42 of 45 songs'), findsOneWidget);

    await tester.tap(find.text('Move folder'));
    await tester.pumpAndSettle();

    expect(appliedFolderId, 7);
    expect(appliedNewPath, r'D:\New\Music');
    expect(poppedResult?.rewrittenTracks, BigInt.from(45));
  });

  test('detectSystemToolsOnPath finds tools on PATH read-only', () async {
    final tempDir = await Directory.systemTemp.createTemp('neomodern_path_test_');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final ytdlpFile = File('${tempDir.path}${Platform.pathSeparator}yt-dlp.exe');
    final ffmpegFile = File('${tempDir.path}${Platform.pathSeparator}ffmpeg.exe');
    await ytdlpFile.writeAsString('');
    await ffmpegFile.writeAsString('');

    final detected = detectSystemToolsOnPath(
      pathEnv: '${tempDir.path};C:\\NonExistentDir',
      isWindows: true,
      isAndroid: false,
    );
    expect(detected.ytdlpPath, ytdlpFile.path);
    expect(detected.ffmpegPath, ffmpegFile.path);
    expect(detected.names, ['yt-dlp', 'ffmpeg']);

    final androidDetected = detectSystemToolsOnPath(
      pathEnv: tempDir.path,
      isWindows: true,
      isAndroid: true,
    );
    expect(androidDetected.hasAny, isFalse);

    final emptyDetected = detectSystemToolsOnPath(
      pathEnv: '',
      isWindows: true,
      isAndroid: false,
    );
    expect(emptyDetected.hasAny, isFalse);
  });

  testWidgets(
      'ExternalSourcesSettingsSection shows opt-in card for detected PATH tools and attaches on accept',
      (WidgetTester tester) async {
    final ctrl = PlayerController();
    addTearDown(ctrl.dispose);

    DetectedSystemTools? attached;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ExternalSourcesSettingsSection(
              controller: ctrl,
              isAndroidOverride: false,
              onDetectSystemTools: () => const DetectedSystemTools(
                ytdlpPath: r'C:\Tools\yt-dlp.exe',
                ffmpegPath: r'C:\Tools\ffmpeg.exe',
              ),
              onAttachDetectedTools: (tools) async {
                attached = tools;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Detected on this system: yt-dlp / ffmpeg'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Add as external tool? NeoModern never downloads these tools automatically.',
      ),
      findsOneWidget,
    );
    expect(find.text('Add detected tools'), findsOneWidget);
    expect(find.text('Dismiss'), findsOneWidget);
    expect(find.text('Auto-install'), findsNothing);

    await tester.tap(find.text('Add detected tools'));
    await tester.pumpAndSettle();

    expect(attached?.ytdlpPath, r'C:\Tools\yt-dlp.exe');
    expect(attached?.ffmpegPath, r'C:\Tools\ffmpeg.exe');
    expect(
      find.text('Detected on this system: yt-dlp / ffmpeg'),
      findsNothing,
    );
  });

  testWidgets(
      'ExternalSourcesSettingsSection dismisses opt-in card and stays hidden on Android',
      (WidgetTester tester) async {
    final ctrl = PlayerController();
    addTearDown(ctrl.dispose);
    var attachCalled = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ExternalSourcesSettingsSection(
              controller: ctrl,
              isAndroidOverride: false,
              onDetectSystemTools: () => const DetectedSystemTools(
                ytdlpPath: r'C:\Tools\yt-dlp.exe',
              ),
              onAttachDetectedTools: (_) async {
                attachCalled = true;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Detected on this system: yt-dlp'), findsOneWidget);
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();

    expect(attachCalled, isFalse);
    expect(find.text('Detected on this system: yt-dlp'), findsNothing);

    final androidCtrl = PlayerController();
    addTearDown(androidCtrl.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ExternalSourcesSettingsSection(
              controller: androidCtrl,
              isAndroidOverride: true,
              onDetectSystemTools: () => const DetectedSystemTools(
                ytdlpPath: r'C:\Tools\yt-dlp.exe',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Detected on this system: yt-dlp'), findsNothing);
  });

  testWidgets(
      'SettingsView never shows Auto-install and displays manual picker + detected opt-in card',
      (WidgetTester tester) async {
    final ctrl = PlayerController();
    addTearDown(ctrl.dispose);
    ctrl.refreshDetectedSystemTools(
      detector: () => const DetectedSystemTools(
        ytdlpPath: r'C:\Tools\yt-dlp.exe',
        ffmpegPath: r'C:\Tools\ffmpeg.exe',
      ),
      notify: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: SettingsView(controller: ctrl),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Auto-install'), findsNothing);
    expect(find.text('Installing...'), findsNothing);

    await tester.scrollUntilVisible(
      find.text('Browse...'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Browse...'), findsOneWidget);
    expect(find.text('Auto-install'), findsNothing);

    await tester.scrollUntilVisible(
      find.text('Detected on this system: yt-dlp / ffmpeg'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.text('Detected on this system: yt-dlp / ffmpeg'),
      findsOneWidget,
    );
    expect(find.text('Add detected tools'), findsOneWidget);
  });
}
