import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/mobile/mini_player.dart';
import 'package:neomodern/ui/mobile/mobile_shell.dart';
import 'package:neomodern/ui/mobile/now_playing_sheet.dart';
import 'package:neomodern/ui/player_bar.dart';
import 'package:neomodern/ui/shell.dart';

class _FakePlayerController extends PlayerController {
  _FakePlayerController({
    UiPlayerSnapshot? initialSnapshot,
    bool isFavorite = false,
  })  : _fakeSnapshot = initialSnapshot ??
            UiPlayerSnapshot(
              status: 'stopped',
              currentIndex: null,
              current: null,
              queueLength: 0,
              queueVersion: BigInt.zero,
              positionSeconds: 0,
              durationSeconds: null,
              volume: 100,
              shuffle: false,
              repeat: 'off',
              replaygain: 'album',
              gapless: true,
              wasapiExclusive: false,
              eqEnabled: false,
              eqPreampDb: 0,
              eqGainsDb: Float64List(10),
              crossfadeSeconds: 0,
              sleepEndsAt: null,
              sleepEndOfTrack: false,
              previousTrack: null,
              nextTrack: null,
              context: null,
            ),
        _fakeFavorite = isFavorite;

  UiPlayerSnapshot _fakeSnapshot;
  bool _fakeFavorite;

  int togglePauseCalls = 0;
  int nextCalls = 0;
  int previousCalls = 0;
  int toggleFavoriteCalls = 0;

  @override
  bool get initialized => true;

  @override
  UiPlayerSnapshot get snapshot => _fakeSnapshot;

  @override
  bool get isPlaying => _fakeSnapshot.status == 'playing';

  @override
  bool get isCurrentFavorite => _fakeFavorite;

  @override
  int get favoriteCount => _fakeFavorite ? 1 : 0;

  @override
  Future<void> togglePause() async {
    togglePauseCalls++;
    _fakeSnapshot = UiPlayerSnapshot(
      status: _fakeSnapshot.status == 'playing' ? 'paused' : 'playing',
      currentIndex: _fakeSnapshot.currentIndex,
      current: _fakeSnapshot.current,
      queueLength: _fakeSnapshot.queueLength,
      queueVersion: _fakeSnapshot.queueVersion,
      positionSeconds: _fakeSnapshot.positionSeconds,
      durationSeconds: _fakeSnapshot.durationSeconds,
      volume: _fakeSnapshot.volume,
      shuffle: _fakeSnapshot.shuffle,
      repeat: _fakeSnapshot.repeat,
      replaygain: _fakeSnapshot.replaygain,
      gapless: _fakeSnapshot.gapless,
      wasapiExclusive: _fakeSnapshot.wasapiExclusive,
      eqEnabled: _fakeSnapshot.eqEnabled,
      eqPreampDb: _fakeSnapshot.eqPreampDb,
      eqGainsDb: _fakeSnapshot.eqGainsDb,
      crossfadeSeconds: _fakeSnapshot.crossfadeSeconds,
      sleepEndsAt: _fakeSnapshot.sleepEndsAt,
      sleepEndOfTrack: _fakeSnapshot.sleepEndOfTrack,
      previousTrack: _fakeSnapshot.previousTrack,
      nextTrack: _fakeSnapshot.nextTrack,
      context: _fakeSnapshot.context,
    );
    notifyListeners();
  }

  @override
  Future<void> next() async {
    nextCalls++;
  }

  @override
  Future<void> previous() async {
    previousCalls++;
  }

  @override
  Future<void> toggleCurrentFavorite() async {
    toggleFavoriteCalls++;
    _fakeFavorite = !_fakeFavorite;
    notifyListeners();
  }

  @override
  Future<void> refreshLyrics() async {}
}

UiPlayerSnapshot _playingSnapshot({
  String status = 'playing',
  String title = 'Midnight City',
  String artist = 'M83',
}) {
  return UiPlayerSnapshot(
    status: status,
    currentIndex: 0,
    current: UiTrackInfo(
      id: BigInt.one,
      path: '/music/midnight_city.flac',
      title: title,
      artist: artist,
      queued: false,
    ),
    queueLength: 1,
    queueVersion: BigInt.one,
    positionSeconds: 42,
    durationSeconds: 243,
    volume: 85,
    shuffle: false,
    repeat: 'off',
    replaygain: 'album',
    gapless: true,
    wasapiExclusive: false,
    eqEnabled: false,
    eqPreampDb: 0,
    eqGainsDb: Float64List(10),
    crossfadeSeconds: 0,
    sleepEndsAt: null,
    sleepEndOfTrack: false,
    previousTrack: null,
    nextTrack: null,
    context: 'Library',
  );
}

void main() {
  testWidgets(
      'NeoModernShell renders MobileShell at 390x844 phone viewport with bottom nav tabs',
      (WidgetTester tester) async {
    final ctrl = _FakePlayerController();
    addTearDown(ctrl.dispose);

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: NeoModernShell(controller: ctrl),
      ),
    );
    await tester.pump();

    expect(find.byType(MobileShell), findsOneWidget);
    expect(find.byType(PlayerBar), findsNothing);

    final bottomNav = find.byType(BottomNavigationBar);
    expect(bottomNav, findsOneWidget);
    expect(find.descendant(of: bottomNav, matching: find.text('Home')),
        findsOneWidget);
    expect(find.descendant(of: bottomNav, matching: find.text('Library')),
        findsOneWidget);
    expect(find.descendant(of: bottomNav, matching: find.text('Recap')),
        findsOneWidget);
    expect(find.descendant(of: bottomNav, matching: find.text('Settings')),
        findsOneWidget);
  });

  testWidgets(
      'NeoModernShell renders desktop sidebar layout at 1280x800 viewport',
      (WidgetTester tester) async {
    final ctrl = _FakePlayerController();
    addTearDown(ctrl.dispose);

    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: NeoModernShell(controller: ctrl),
      ),
    );
    await tester.pump();

    expect(find.byType(MobileShell), findsNothing);
    expect(find.byType(PlayerBar), findsOneWidget);
    expect(find.text('YOUR LIBRARY'), findsOneWidget);
    expect(find.text('Songs'), findsOneWidget);
    expect(find.text('Albums'), findsOneWidget);
  });

  testWidgets(
      'MiniPlayer renders track info, play/pause button, star favorite button, and handles interactions',
      (WidgetTester tester) async {
    final ctrl = _FakePlayerController(
      initialSnapshot: _playingSnapshot(),
      isFavorite: false,
    );
    ctrl.positionNotifier.value = 42;
    addTearDown(ctrl.dispose);

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: ctrl,
            builder: (context, _) => Align(
              alignment: Alignment.bottomCenter,
              child: MiniPlayer(controller: ctrl),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Midnight City'), findsOneWidget);
    expect(find.text('M83'), findsOneWidget);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    expect(find.byIcon(Icons.star_outline_rounded), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await tester.tap(find.byIcon(Icons.pause_rounded));
    await tester.pump();
    expect(ctrl.togglePauseCalls, 1);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.star_outline_rounded));
    await tester.pump();
    expect(ctrl.toggleFavoriteCalls, 1);
    expect(find.byIcon(Icons.star_rounded), findsOneWidget);

    await tester.fling(
      find.byType(MiniPlayer),
      const Offset(-200, 0),
      800,
    );
    await tester.pump();
    expect(ctrl.nextCalls, 1);

    await tester.fling(
      find.byType(MiniPlayer),
      const Offset(200, 0),
      800,
    );
    await tester.pump();
    expect(ctrl.previousCalls, 1);

    await tester.tap(find.text('Midnight City'));
    await tester.pumpAndSettle();
    expect(find.byType(NowPlayingSheet), findsOneWidget);
    expect(find.text('Lyrics'), findsOneWidget);
    expect(find.text('Queue'), findsOneWidget);
  });
}
