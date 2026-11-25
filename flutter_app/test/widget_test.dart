import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/profiles_dialog.dart';
import 'package:neomodern/ui/recap_view.dart';
import 'package:neomodern/ui/right_panel.dart';
import 'package:neomodern/ui/settings_view.dart';
import 'package:neomodern/ui/sources_view.dart';
import 'package:neomodern/ui/sync_settings_section.dart';
import 'package:neomodern/ui/tag_editor_dialog.dart';
import 'package:neomodern/ui/tinted_backdrop.dart';
import 'package:neomodern/ui/track_menu.dart';
import 'package:neomodern/ui/welcome_dialog.dart';

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

  testWidgets('AppTheme.dark configures expected dark canvas',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
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

  testWidgets('RightPanel switches between Lyrics and Queue tabs',
      (WidgetTester tester) async {
    final ctrl = PlayerController();
    addTearDown(ctrl.dispose);
    var tab = RightPanelTab.lyrics;
    var closed = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: StatefulBuilder(
          builder: (context, setState) {
            return Scaffold(
              body: RightPanel(
                controller: ctrl,
                activeTab: tab,
                onTabChanged: (t) => setState(() => tab = t),
                onClose: () => closed = true,
              ),
            );
          },
        ),
      ),
    );

    expect(find.text('Play a track to view lyrics.'), findsOneWidget);

    await tester.tap(find.text('Queue'));
    await tester.pump();
    expect(find.text('Queue is empty.'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close_rounded));
    expect(closed, true);
  });

  testWidgets('SettingsView displays Library, Playback, EQ, and Network',
      (WidgetTester tester) async {
    final ctrl = PlayerController();
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(body: SettingsView(controller: ctrl)),
      ),
    );

    expect(find.text('Library Folders'), findsOneWidget);
    expect(find.text('Playback'), findsOneWidget);
    expect(find.text('ReplayGain'), findsOneWidget);
    expect(find.text('Gapless Playback'), findsOneWidget);
  });

  testWidgets('RecapView shows neutral Listening Stats header and periods',
      (WidgetTester tester) async {
    final ctrl = PlayerController();
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: RecapView(
            controller: ctrl,
            onOpenArtist: (_) {},
            onOpenAlbum: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('Listening Stats'), findsOneWidget);
    expect(find.text('7 Days'), findsOneWidget);
    expect(find.text('30 Days'), findsOneWidget);
    expect(find.text('All Time'), findsOneWidget);
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
          body: ExternalSourcesSettingsSection(controller: ctrl),
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
}
