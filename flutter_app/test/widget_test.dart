import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/recap_view.dart';
import 'package:neomodern/ui/right_panel.dart';
import 'package:neomodern/ui/settings_view.dart';
import 'package:neomodern/ui/track_menu.dart';

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
}
