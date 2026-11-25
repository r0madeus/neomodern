import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/platform/android_audio_bridge.dart';
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
    UiLyrics? initialLyrics,
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
        _fakeFavorite = isFavorite,
        _fakeLyrics = initialLyrics;

  UiPlayerSnapshot _fakeSnapshot;
  bool _fakeFavorite;
  final UiLyrics? _fakeLyrics;

  int togglePauseCalls = 0;
  int nextCalls = 0;
  int previousCalls = 0;
  int toggleFavoriteCalls = 0;
  int rescanCalls = 0;
  final List<double> seekCalls = [];

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
  UiLyrics? get currentLyrics => _fakeLyrics;

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
  Future<void> seek(double seconds) async {
    seekCalls.add(seconds);
    positionNotifier.value = seconds;
  }

  @override
  Future<void> toggleCurrentFavorite() async {
    toggleFavoriteCalls++;
    _fakeFavorite = !_fakeFavorite;
    notifyListeners();
  }

  @override
  Future<void> rescanLibrary() async {
    rescanCalls++;
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
    expect(find.text('Lyrics'), findsWidgets);
    expect(find.text('Queue'), findsOneWidget);
  });

  testWidgets(
      'NowPlayingSheet supports 3-panel cover carousel swipe and full-screen lyrics mode',
      (WidgetTester tester) async {
    final lyrics = UiLyrics(
      found: true,
      source: 'lrc',
      isInstrumental: false,
      syncedLines: [
        UiSyncedLine(timeMs: 10000, text: 'Waiting in a car'),
        UiSyncedLine(timeMs: 40000, text: 'Waiting for a ride in the dark'),
        UiSyncedLine(timeMs: 80000, text: 'The night city grows'),
      ],
      plainText: null,
    );

    final snap = UiPlayerSnapshot(
      status: 'playing',
      currentIndex: 1,
      current: UiTrackInfo(
        id: BigInt.from(2),
        path: '/music/midnight_city.flac',
        title: 'Midnight City',
        artist: 'M83',
        queued: false,
      ),
      queueLength: 3,
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
      previousTrack: UiTrackInfo(
        id: BigInt.one,
        path: '/music/intro.flac',
        title: 'Intro',
        artist: 'M83',
        queued: false,
      ),
      nextTrack: UiTrackInfo(
        id: BigInt.from(3),
        path: '/music/reunion.flac',
        title: 'Reunion',
        artist: 'M83',
        queued: false,
      ),
      context: 'Hurry Up, We\'re Dreaming',
    );

    final ctrl = _FakePlayerController(
      initialSnapshot: snap,
      initialLyrics: lyrics,
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
          body: NowPlayingSheet(controller: ctrl),
        ),
      ),
    );
    await tester.pump();

    final carousel = find.byKey(const ValueKey('now_playing_cover_carousel'));
    expect(carousel, findsOneWidget);
    final pageView = tester.widget<PageView>(carousel);
    expect(pageView.controller?.initialPage, 1);

    // Swipe left to page 2 -> triggers next() and snaps back to page 1
    await tester.fling(carousel, const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(ctrl.nextCalls, 1);
    expect(pageView.controller?.page?.round(), 1);

    // Swipe right to page 0 -> triggers previous() and snaps back to page 1
    await tester.fling(carousel, const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(ctrl.previousCalls, 1);
    expect(pageView.controller?.page?.round(), 1);

    // Open full-screen lyrics mode
    expect(find.text('Expand Lyrics'), findsOneWidget);
    await tester.tap(find.text('Expand Lyrics'));
    await tester.pumpAndSettle();

    expect(find.byType(FullScreenLyricsPage), findsOneWidget);
    expect(find.text('The night city grows'), findsOneWidget);

    // Tap a synced line to seek
    await tester.tap(find.text('The night city grows'));
    await tester.pump();
    expect(ctrl.seekCalls, [80.0]);

    // Toggle play/pause inside full-screen lyrics
    await tester.tap(find.byIcon(Icons.pause_rounded));
    await tester.pump();
    expect(ctrl.togglePauseCalls, 1);

    // Close full-screen lyrics
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(FullScreenLyricsPage), findsNothing);
    expect(find.byType(NowPlayingSheet), findsOneWidget);
  });

  testWidgets(
      'MobileShell shows Android storage permission banner and QR scanner shortcut',
      (WidgetTester tester) async {
    AndroidPlatformBridge.debugIsAndroidOverride = true;
    addTearDown(() {
      AndroidPlatformBridge.debugIsAndroidOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidPlatformBridge.channel, null);
    });

    var granted = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      AndroidPlatformBridge.channel,
      (MethodCall call) async {
        switch (call.method) {
          case 'checkAudioPermission':
            return granted;
          case 'requestAudioPermission':
            granted = true;
            return true;
          case 'scanQrCode':
            return 'PARTY-9942';
          default:
            return null;
        }
      },
    );

    final ctrl = _FakePlayerController();
    addTearDown(ctrl.dispose);

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: MobileShell(controller: ctrl),
      ),
    );
    await tester.pumpAndSettle();

    // Permission prompt appears when Android audio permission is denied
    expect(find.text('Allow access to your music files'), findsOneWidget);
    expect(find.text('Allow'), findsOneWidget);

    await tester.tap(find.text('Allow'));
    await tester.pumpAndSettle();

    expect(ctrl.rescanCalls, 1);
    expect(find.text('Allow access to your music files'), findsNothing);

    // Scan QR shortcut in top bar invokes scanQrCode and displays feedback dialog
    final qrButton = find.byTooltip('Scan QR');
    expect(qrButton, findsOneWidget);
    await tester.tap(qrButton);
    await tester.pumpAndSettle();

    expect(find.text('Scanned QR Code'), findsOneWidget);
    expect(find.text('PARTY-9942'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Scanned QR Code'), findsNothing);
  });
}
