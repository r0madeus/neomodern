import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/platform/android_audio_bridge.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/genre_view.dart';
import 'package:neomodern/ui/mobile/mini_player.dart';
import 'package:neomodern/ui/mobile/mobile_detail_pages.dart';
import 'package:neomodern/ui/mobile/mobile_sheet.dart';
import 'package:neomodern/ui/mobile/mobile_shell.dart';
import 'package:neomodern/ui/mobile/now_playing_sheet.dart';
import 'package:neomodern/ui/mobile/sticky_play.dart';
import 'package:neomodern/ui/widgets/motion_primitives.dart';

class _FakePlayerController extends PlayerController {
  _FakePlayerController({
    UiPlayerSnapshot? initialSnapshot,
    bool isFavorite = false,
    UiLyrics? initialLyrics,
    this.fakeGenres = const [],
    this.fakeGenreDetail,
    this.fakeGenreTracks = const [],
    this.fakeSearchTracks = const [],
    this.fakeProviders = const [],
    this.fakeExternalTracks = const [],
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
  final List<UiGenreInfo> fakeGenres;
  final UiGenreDetail? fakeGenreDetail;
  final List<UiTrackRow> fakeGenreTracks;
  final List<UiTrackRow> fakeSearchTracks;
  final List<UiSourceProvider> fakeProviders;
  final List<UiExternalTrack> fakeExternalTracks;

  int togglePauseCalls = 0;
  int nextCalls = 0;
  int previousCalls = 0;
  int toggleFavoriteCalls = 0;
  int rescanCalls = 0;
  final List<double> seekCalls = [];
  final List<String> playedExternalIds = [];

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

  @override
  Future<List<UiGenreInfo>> fetchGenres() async => fakeGenres;

  @override
  Future<UiGenreDetail> fetchGenreDetail(String genre) async {
    return fakeGenreDetail ??
        UiGenreDetail(
          name: genre,
          trackCount: fakeGenreTracks.length,
          albumCount: 0,
          totalDurationMs: BigInt.zero,
          coverPath: null,
          albums: const [],
        );
  }

  @override
  Future<List<UiTrackRow>> fetchGenreTracksPage(
    String genre, {
    int offset = 0,
    int limit = 100,
  }) async {
    if (offset >= fakeGenreTracks.length) return const [];
    return fakeGenreTracks.skip(offset).take(limit).toList();
  }

  @override
  Future<List<UiArtistRow>> searchArtists(
    String query, {
    int limit = 12,
  }) async =>
      const [];

  @override
  Future<List<UiAlbumRow>> searchAlbums(
    String query, {
    int limit = 12,
  }) async =>
      const [];

  @override
  Future<List<UiTrackRow>> searchTracks(
    String query, {
    int limit = 25,
  }) async =>
      fakeSearchTracks;

  @override
  List<UiSourceProvider> get enabledSourceProviders => fakeProviders;

  @override
  bool get hasEnabledSourceProviders => fakeProviders.isNotEmpty;

  @override
  Future<List<UiExternalTrack>> searchExternalSource(
    String providerId,
    String query, {
    int limit = 15,
  }) async =>
      fakeExternalTracks;

  @override
  Future<void> playExternalTrack(UiExternalTrack track) async {
    playedExternalIds.add(track.externalId);
  }

  @override
  UiTrackInfo? queueTrackAt(int index) {
    final tracks = [
      _fakeSnapshot.previousTrack,
      _fakeSnapshot.current,
      _fakeSnapshot.nextTrack,
    ].whereType<UiTrackInfo>().toList();
    if (index >= 0 && index < tracks.length) {
      return tracks[index];
    }
    return null;
  }
}

UiPlayerSnapshot _playingSnapshot({
  String status = 'playing',
  String title = 'Midnight City',
  String artist = 'M83',
  bool withNeighbors = true,
}) {
  return UiPlayerSnapshot(
    status: status,
    currentIndex: withNeighbors ? 1 : 0,
    current: UiTrackInfo(
      id: BigInt.from(2),
      path: '/music/midnight_city.flac',
      title: title,
      artist: artist,
      queued: false,
    ),
    queueLength: withNeighbors ? 3 : 1,
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
    previousTrack: withNeighbors
        ? UiTrackInfo(
            id: BigInt.one,
            path: '/music/intro.flac',
            title: 'Intro',
            artist: 'M83',
            queued: false,
          )
        : null,
    nextTrack: withNeighbors
        ? UiTrackInfo(
            id: BigInt.from(3),
            path: '/music/reunion.flac',
            title: 'Reunion',
            artist: 'M83',
            queued: false,
          )
        : null,
    context: 'Hurry Up, We\'re Dreaming',
  );
}

void main() {
  testWidgets(
      'MobileShell renders 3-tab nav (Home, Search, Library), Browse all genres, and Your Library',
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
        home: MobileShell(controller: ctrl),
      ),
    );
    await tester.pumpAndSettle();

    final bottomNav = find.byKey(const ValueKey('mobile_bottom_nav'));
    expect(bottomNav, findsOneWidget);
    expect(find.descendant(of: bottomNav, matching: find.text('Home')),
        findsOneWidget);
    expect(find.descendant(of: bottomNav, matching: find.text('Search')),
        findsOneWidget);
    expect(find.descendant(of: bottomNav, matching: find.text('Library')),
        findsOneWidget);
    expect(find.descendant(of: bottomNav, matching: find.text('Recap')),
        findsNothing);
    expect(find.descendant(of: bottomNav, matching: find.text('Settings')),
        findsNothing);

    // Switch to Search tab -> light search bar + Browse all colored genre cards
    await tester.tap(find.descendant(of: bottomNav, matching: find.text('Search')));
    await tester.pumpAndSettle();
    expect(find.text('Browse all'), findsOneWidget);
    expect(find.text('Electronic'), findsOneWidget);
    expect(find.text('Rock'), findsOneWidget);

    // Switch to Library tab -> Your Library header + filter chips
    await tester.tap(find.descendant(of: bottomNav, matching: find.text('Library')));
    await tester.pumpAndSettle();
    expect(find.text('Your Library'), findsOneWidget);
    expect(find.text('Playlists'), findsOneWidget);
    expect(find.text('Albums'), findsOneWidget);
    expect(find.text('Artists'), findsOneWidget);
    expect(find.text('Songs'), findsOneWidget);
    expect(find.text('Favorites'), findsNWidgets(2));
  });

  testWidgets(
      'MiniPlayer renders 3-panel swipe strip, AnimatedSaveButton, Play/Pause, and rubber-band edge behavior',
      (WidgetTester tester) async {
    final ctrl = _FakePlayerController(
      initialSnapshot: _playingSnapshot(withNeighbors: true),
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
    expect(find.text('M83'), findsWidgets);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    expect(find.byType(AnimatedSaveButton), findsOneWidget);
    expect(find.byIcon(Icons.add_circle_outline_rounded), findsOneWidget);

    // Play/Pause
    await tester.tap(find.byIcon(Icons.pause_rounded));
    await tester.pump();
    expect(ctrl.togglePauseCalls, 1);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

    // Save button
    await tester.tap(find.byType(AnimatedSaveButton));
    await tester.pump();
    expect(ctrl.toggleFavoriteCalls, 1);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);

    // Horizontal swipe next & previous
    await tester.fling(
      find.byType(MiniPlayer),
      const Offset(-200, 0),
      800,
    );
    await tester.pumpAndSettle();
    expect(ctrl.nextCalls, 1);

    await tester.fling(
      find.byType(MiniPlayer),
      const Offset(200, 0),
      800,
    );
    await tester.pumpAndSettle();
    expect(ctrl.previousCalls, 1);

    // Tap center panel -> opens NowPlayingSheet with 260ms slide-up
    await tester.tap(find.text('Midnight City'));
    await tester.pumpAndSettle();
    expect(find.byType(NowPlayingSheet), findsOneWidget);
    expect(find.text('NOW PLAYING'), findsOneWidget);
    expect(find.text('2 of 3'), findsOneWidget);
    expect(find.text('Lyrics'), findsOneWidget);
  });

  testWidgets('MiniPlayer blocks swipe when no adjacent tracks exist',
      (WidgetTester tester) async {
    final ctrl = _FakePlayerController(
      initialSnapshot: _playingSnapshot(withNeighbors: false),
    );
    addTearDown(ctrl.dispose);

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: MiniPlayer(controller: ctrl),
          ),
        ),
      ),
    );

    await tester.fling(find.byType(MiniPlayer), const Offset(-200, 0), 800);
    await tester.pumpAndSettle();
    expect(ctrl.nextCalls, 0);

    await tester.fling(find.byType(MiniPlayer), const Offset(200, 0), 800);
    await tester.pumpAndSettle();
    expect(ctrl.previousCalls, 0);
  });

  testWidgets(
      'NowPlayingSheet supports 3-panel cover carousel, CurrentLine, below-the-fold lyrics card, FullScreenLyricsPage, and QueueSheet',
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

    final ctrl = _FakePlayerController(
      initialSnapshot: _playingSnapshot(withNeighbors: true),
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

    // CurrentLine single-line preview under the cover shows active lyric
    expect(find.text('Waiting for a ride in the dark'), findsWidgets);

    // 3-panel cover carousel
    final carousel = find.byKey(const ValueKey('now_playing_cover_carousel'));
    expect(carousel, findsOneWidget);
    final pageView = tester.widget<PageView>(carousel);
    expect(pageView.controller?.initialPage, 1);

    await tester.fling(carousel, const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(ctrl.nextCalls, 1);
    expect(pageView.controller?.page?.round(), 1);

    await tester.fling(carousel, const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(ctrl.previousCalls, 1);
    expect(pageView.controller?.page?.round(), 1);

    // Open QueueSheet
    await tester.tap(find.byTooltip('Queue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(QueueSheet), findsOneWidget);
    expect(find.byType(EqualizerIndicator), findsOneWidget);

    // Dismiss QueueSheet
    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(QueueSheet), findsNothing);

    // Scroll down to below-the-fold lyrics card and open FullScreenLyricsPage
    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -350));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Expand Lyrics'), findsOneWidget);
    await tester.tap(find.byTooltip('Expand Lyrics'));
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

    // Close full-screen lyrics via header down chevron
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(FullScreenLyricsPage), findsNothing);
    expect(find.byType(NowPlayingSheet), findsOneWidget);
  });

  testWidgets('StickyPlayButton scales to 0.79 when docked and handles tap',
      (WidgetTester tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Center(
            child: StickyPlayButton(
              playing: false,
              docked: false,
              onPressed: () => tapped++,
            ),
          ),
        ),
      ),
    );

    final animatedScale =
        tester.widget<AnimatedScale>(find.byType(AnimatedScale));
    expect(animatedScale.scale, 1.0);

    await tester.tap(find.byType(StickyPlayButton));
    expect(tapped, 1);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Center(
            child: StickyPlayButton(
              playing: true,
              docked: true,
              dockShift: 24,
              onPressed: () => tapped++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final dockedScale =
        tester.widget<AnimatedScale>(find.byType(AnimatedScale));
    expect(dockedScale.scale, 0.79);
  });

  testWidgets('MobileSheetRoute supports left-edge swipe back (> 90px dismiss)',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => pushMobileSheet<void>(
                  context,
                  builder: (_) => const Scaffold(
                    body: Center(child: Text('Pushed Sheet')),
                  ),
                ),
                child: const Text('Push'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Push'));
    await tester.pumpAndSettle();
    expect(find.text('Pushed Sheet'), findsOneWidget);

    // Small edge drag (<= 90px) snaps back
    await tester.dragFrom(const Offset(12, 300), const Offset(50, 0));
    await tester.pumpAndSettle();
    expect(find.text('Pushed Sheet'), findsOneWidget);

    // Edge drag (> 90px) dismisses
    await tester.dragFrom(const Offset(12, 300), const Offset(150, 0));
    await tester.pumpAndSettle();
    expect(find.text('Pushed Sheet'), findsNothing);
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

  testWidgets(
      'MobileShell Search opens real library genres in MobileGenrePage and searches external sources',
      (WidgetTester tester) async {
    final genreTrack = UiTrackRow(
      id: PlatformInt64Util.from(11),
      path: '/music/nightcall.flac',
      title: 'Nightcall',
      artist: 'Kavinsky',
      album: 'OutRun',
      albumId: PlatformInt64Util.from(7),
      trackNo: 1,
      durationMs: BigInt.from(258000),
      cover: null,
      plays: 0,
    );
    final extTrack = UiExternalTrack(
      providerId: 'demo-ext',
      externalId: 'ext-42',
      title: 'Pacific Coast Highway',
      artist: 'Kavinsky',
      album: 'OutRun',
      durationMs: BigInt.from(379000),
      coverUrl: null,
    );
    final ctrl = _FakePlayerController(
      fakeGenres: const [
        UiGenreInfo(
          name: 'Synthwave',
          trackCount: 2,
          albumCount: 1,
          coverPath: null,
        ),
      ],
      fakeGenreDetail: UiGenreDetail(
        name: 'Synthwave',
        trackCount: 1,
        albumCount: 0,
        totalDurationMs: BigInt.from(258000),
        coverPath: null,
        albums: const [],
      ),
      fakeGenreTracks: [genreTrack],
      fakeSearchTracks: [genreTrack],
      fakeProviders: const [
        UiSourceProvider(
          id: 'demo-ext',
          name: 'Demo Source',
          baseUrl: 'https://example.test',
          enabled: true,
        ),
      ],
      fakeExternalTracks: [extTrack],
    );
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

    final bottomNav = find.byKey(const ValueKey('mobile_bottom_nav'));
    await tester.tap(find.descendant(of: bottomNav, matching: find.text('Search')));
    await tester.pumpAndSettle();

    // Real library genre card appears with track count
    expect(find.text('Synthwave'), findsOneWidget);
    expect(find.text('2 tracks'), findsOneWidget);

    // Tapping a genre opens MobileGenrePage (GenreView) with MobileTrackTile
    await tester.tap(find.text('Synthwave'));
    await tester.pumpAndSettle();
    expect(find.byType(MobileGenrePage), findsOneWidget);
    expect(find.byType(GenreView), findsOneWidget);
    expect(find.text('Nightcall'), findsOneWidget);

    // Pop back to Search tab
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(MobileGenrePage), findsNothing);

    // Typing a query renders both local and external results
    await tester.enterText(find.byType(TextField), 'kavinsky');
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();

    expect(find.text('Nightcall'), findsOneWidget);
    expect(find.text('External Sources'), findsOneWidget);
    expect(find.text('Pacific Coast Highway'), findsOneWidget);

    await tester.tap(find.text('Pacific Coast Highway'));
    await tester.pump();
    expect(ctrl.playedExternalIds, ['ext-42']);
  });
}
