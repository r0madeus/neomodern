import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:path_provider/path_provider.dart';

class PlayerController extends ChangeNotifier {
  static const int _pageSize = 100;
  static const int _albumPageSize = 60;
  static const int _artistPageSize = 60;

  bool _initialized = false;
  String? _initError;
  String? _lastError;

  UiPlayerSnapshot _snapshot = UiPlayerSnapshot(
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
  );

  final ValueNotifier<double> positionNotifier = ValueNotifier<double>(0);

  String? _currentCoverPath;
  String? _coverLookupPath;

  StreamSubscription<UiEvent>? _eventSub;
  Timer? _interpTimer;
  double _anchorPosition = 0;
  DateTime _anchorTime = DateTime.now();
  bool _seeking = false;
  double _lastNonZeroVolume = 100;

  // Library state
  bool _isScanning = false;
  int _scannedCount = 0;
  List<UiFolderInfo> _folders = const [];
  bool _offlineMode = false;

  // Songs cache
  String _trackSearch = '';
  int _trackCount = 0;
  final Map<int, UiTrackRow> _trackCache = {};
  final Set<int> _trackPagesLoading = {};
  int _trackQueryEpoch = 0;

  // Albums cache
  String _albumSearch = '';
  int _albumCount = 0;
  final Map<int, UiAlbumRow> _albumCache = {};
  final Set<int> _albumPagesLoading = {};
  int _albumQueryEpoch = 0;

  // Artists cache
  String _artistSearch = '';
  int _artistCount = 0;
  final Map<int, UiArtistRow> _artistCache = {};
  final Set<int> _artistPagesLoading = {};
  int _artistQueryEpoch = 0;

  // Queue cache
  BigInt _cachedQueueVersion = BigInt.from(-1);
  final Map<int, UiTrackInfo> _queueCache = {};
  final Set<int> _queuePagesLoading = {};

  // Home, Favorites, Playlists
  UiHomeFeed? _homeFeed;
  final Set<int> _favoriteIds = {};
  final Set<String> _favoritePaths = {};
  List<UiTrackRow> _favoriteTracks = const [];
  List<UiPlaylistInfo> _playlists = const [];

  // Lyrics for current track
  UiLyrics? _currentLyrics;
  String? _lyricsTrackPath;
  bool _lyricsLoading = false;

  bool get initialized => _initialized;
  String? get initError => _initError;
  String? get lastError => _lastError;
  UiPlayerSnapshot get snapshot => _snapshot;
  String? get currentCoverPath => _currentCoverPath;
  bool get isPlaying => _snapshot.status == 'playing';
  bool get isScanning => _isScanning;
  int get scannedCount => _scannedCount;
  List<UiFolderInfo> get folders => _folders;
  bool get offlineMode => _offlineMode;
  String get trackSearch => _trackSearch;
  int get trackCount => _trackCount;
  String get albumSearch => _albumSearch;
  int get albumCount => _albumCount;
  String get artistSearch => _artistSearch;
  int get artistCount => _artistCount;

  UiHomeFeed? get homeFeed => _homeFeed;
  List<UiTrackRow> get favoriteTracks => _favoriteTracks;
  int get favoriteCount => _favoriteIds.length;
  List<UiPlaylistInfo> get playlists => _playlists;
  UiLyrics? get currentLyrics => _currentLyrics;
  bool get lyricsLoading => _lyricsLoading;

  bool isFavorite(PlatformInt64 trackId) =>
      _favoriteIds.contains(trackId.toInt());

  bool get isCurrentFavorite {
    final path = _snapshot.current?.path;
    if (path == null) return false;
    return _favoritePaths.contains(path);
  }

  Future<void> init() async {
    try {
      final dirs = await _resolveDirectories();
      final snap = await initCore(dataDir: dirs.$1, cacheDir: dirs.$2);
      _applySnapshot(snap);

      _eventSub = subscribeEvents().listen(
        _handleEvent,
        onError: (Object error) {
          _lastError = error.toString();
          notifyListeners();
        },
      );

      _folders = await libraryFolders();
      _isScanning = await libraryIsScanning();
      _offlineMode = await settingsGetOffline();

      await Future.wait([
        _refreshTracks(),
        _refreshAlbums(),
        _refreshArtists(),
        _refreshFavorites(),
        _refreshPlaylists(),
        _refreshHome(),
      ]);

      _initialized = true;
      _initError = null;
      notifyListeners();
    } catch (e) {
      _initError = e.toString();
      notifyListeners();
    }
  }

  Future<(String, String)> _resolveDirectories() async {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (appData != null &&
          appData.isNotEmpty &&
          localAppData != null &&
          localAppData.isNotEmpty) {
        final dataDir = '$appData\\io.github.r0madeus.neomodern';
        final cacheDir = '$localAppData\\io.github.r0madeus.neomodern';
        return (dataDir, cacheDir);
      }
    }
    final support = await getApplicationSupportDirectory();
    final cache = await getApplicationCacheDirectory();
    return (support.path, cache.path);
  }

  void _handleEvent(UiEvent event) {
    switch (event) {
      case UiEvent_State(:final field0):
        _applySnapshot(field0);
        notifyListeners();
      case UiEvent_Position(:final seconds, :final duration):
        _anchorPosition = seconds;
        _anchorTime = DateTime.now();
        if (duration != null && duration != _snapshot.durationSeconds) {
          _snapshot = _copySnapshotWith(
            positionSeconds: seconds,
            durationSeconds: duration,
          );
          notifyListeners();
        }
        if (!_seeking) {
          positionNotifier.value = seconds;
        }
      case UiEvent_LibraryChanged():
        unawaited(_onLibraryChanged());
      case UiEvent_ScanProgress(:final scanned, :final done):
        _isScanning = !done;
        _scannedCount = scanned.toInt();
        notifyListeners();
      case UiEvent_Error(:final field0):
        _lastError = field0;
        notifyListeners();
    }
  }

  UiPlayerSnapshot _copySnapshotWith({
    double? positionSeconds,
    double? durationSeconds,
  }) {
    return UiPlayerSnapshot(
      status: _snapshot.status,
      currentIndex: _snapshot.currentIndex,
      current: _snapshot.current,
      queueLength: _snapshot.queueLength,
      queueVersion: _snapshot.queueVersion,
      positionSeconds: positionSeconds ?? _snapshot.positionSeconds,
      durationSeconds: durationSeconds ?? _snapshot.durationSeconds,
      volume: _snapshot.volume,
      shuffle: _snapshot.shuffle,
      repeat: _snapshot.repeat,
      replaygain: _snapshot.replaygain,
      gapless: _snapshot.gapless,
      wasapiExclusive: _snapshot.wasapiExclusive,
      eqEnabled: _snapshot.eqEnabled,
      eqPreampDb: _snapshot.eqPreampDb,
      eqGainsDb: _snapshot.eqGainsDb,
      crossfadeSeconds: _snapshot.crossfadeSeconds,
      sleepEndsAt: _snapshot.sleepEndsAt,
      sleepEndOfTrack: _snapshot.sleepEndOfTrack,
      previousTrack: _snapshot.previousTrack,
      nextTrack: _snapshot.nextTrack,
      context: _snapshot.context,
    );
  }

  Future<void> _onLibraryChanged() async {
    try {
      _folders = await libraryFolders();
      _isScanning = await libraryIsScanning();
      await Future.wait([
        _refreshTracks(),
        _refreshAlbums(),
        _refreshArtists(),
        _refreshFavorites(),
        _refreshPlaylists(),
        _refreshHome(),
      ]);
      _refreshCurrentCover(_snapshot.current?.path, force: true);
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  void _applySnapshot(UiPlayerSnapshot snap) {
    final prevPath = _snapshot.current?.path;
    _snapshot = snap;
    if (snap.volume > 0) {
      _lastNonZeroVolume = snap.volume;
    }

    _anchorPosition = snap.positionSeconds;
    _anchorTime = DateTime.now();
    if (!_seeking) {
      positionNotifier.value = snap.positionSeconds;
    }

    if (snap.queueVersion != _cachedQueueVersion) {
      _cachedQueueVersion = snap.queueVersion;
      _queueCache.clear();
      _queuePagesLoading.clear();
    }

    if (snap.status == 'playing') {
      _startInterpTimer();
    } else {
      _stopInterpTimer();
    }

    if (snap.current?.path != prevPath) {
      _refreshCurrentCover(snap.current?.path);
      _currentLyrics = null;
      _lyricsTrackPath = snap.current?.path;
      unawaited(refreshLyrics());
      unawaited(_refreshHome());
    }
  }

  void _startInterpTimer() {
    if (_interpTimer != null) return;
    _interpTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_seeking || _snapshot.status != 'playing') return;
      final elapsed =
          DateTime.now().difference(_anchorTime).inMilliseconds / 1000.0;
      var pos = _anchorPosition + elapsed;
      final dur = _snapshot.durationSeconds;
      if (dur != null && dur > 0 && pos > dur) {
        pos = dur;
      }
      positionNotifier.value = pos;
    });
  }

  void _stopInterpTimer() {
    _interpTimer?.cancel();
    _interpTimer = null;
  }

  void _refreshCurrentCover(String? path, {bool force = false}) {
    if (path == null) {
      _coverLookupPath = null;
      _currentCoverPath = null;
      return;
    }
    if (!force && path == _coverLookupPath) return;
    _coverLookupPath = path;
    unawaited(
      libraryTrackCover(path: path).then((cover) {
        if (_coverLookupPath == path && cover != _currentCoverPath) {
          _currentCoverPath = cover;
          notifyListeners();
        }
      }).catchError((_) {}),
    );
  }

  void clearError() {
    _lastError = null;
    notifyListeners();
  }

  // Player controls
  Future<void> togglePause() async {
    await _runPlayerCmd(playerTogglePause);
  }

  Future<void> next() async {
    await _runPlayerCmd(playerNext);
  }

  Future<void> previous() async {
    await _runPlayerCmd(playerPrevious);
  }

  void beginSeekDrag() {
    _seeking = true;
  }

  void updateSeekDrag(double seconds) {
    positionNotifier.value = seconds;
  }

  Future<void> endSeekDrag(double seconds) async {
    _seeking = false;
    await seek(seconds);
  }

  Future<void> seek(double seconds) async {
    final dur = _snapshot.durationSeconds;
    final clamped =
        dur != null ? seconds.clamp(0.0, dur) : seconds.clamp(0.0, double.infinity);
    await _runPlayerCmd(() => playerSeek(seconds: clamped));
  }

  Future<void> seekRelative(double deltaSeconds) async {
    if (_snapshot.current == null) return;
    await seek(positionNotifier.value + deltaSeconds);
  }

  Future<void> setVolume(double percent) async {
    await _runPlayerCmd(() => playerSetVolume(percent: percent));
  }

  Future<void> toggleMute() async {
    if (_snapshot.volume > 0) {
      _lastNonZeroVolume = _snapshot.volume;
      await setVolume(0);
    } else {
      await setVolume(_lastNonZeroVolume > 0 ? _lastNonZeroVolume : 100);
    }
  }

  Future<void> toggleShuffle() async {
    await _runPlayerCmd(() => playerSetShuffle(enabled: !_snapshot.shuffle));
  }

  Future<void> cycleRepeat() async {
    final nextMode = switch (_snapshot.repeat) {
      'off' => 'all',
      'all' => 'one',
      _ => 'off',
    };
    await _runPlayerCmd(() => playerSetRepeat(mode: nextMode));
  }

  Future<void> playIndex(int index) async {
    await _runPlayerCmd(() => playerPlayIndex(index: index));
  }

  Future<void> playTracks(
    List<String> paths,
    int startIndex, {
    String? context,
  }) async {
    await _runPlayerCmd(
      () => playerPlayTracks(
        paths: paths,
        startIndex: startIndex,
        context: context,
      ),
    );
  }

  Future<void> playAllFromSearch(int startIndex) async {
    final query = _trackSearch.trim();
    await _runPlayerCmd(
      () => libraryPlayAll(
        startIndex: startIndex,
        search: query.isEmpty ? null : query,
      ),
    );
  }

  Future<void> playAlbum(
    PlatformInt64 albumId,
    int startIndex, {
    bool shuffle = false,
  }) async {
    await _runPlayerCmd(
      () => libraryPlayAlbum(
        albumId: albumId,
        startIndex: startIndex,
        shuffle: shuffle,
      ),
    );
  }

  // Queue operations
  Future<void> enqueueTracks(List<String> paths) async {
    await _runPlayerCmd(() => queueEnqueue(paths: paths));
  }

  Future<void> insertNextTracks(List<String> paths) async {
    await _runPlayerCmd(() => queueInsertNext(paths: paths));
  }

  Future<void> removeFromQueue(int index) async {
    await _runPlayerCmd(() => queueRemove(index: index));
  }

  Future<void> clearQueuedTracks() async {
    await _runPlayerCmd(queueClearQueued);
  }

  // Playback settings & offline mode
  Future<void> setReplaygain(String mode) async {
    await _runPlayerCmd(() => playerSetReplaygain(mode: mode));
  }

  Future<void> setGapless(bool enabled) async {
    await _runPlayerCmd(() => playerSetGapless(enabled: enabled));
  }

  Future<void> setWasapiExclusive(bool enabled) async {
    await _runPlayerCmd(() => playerSetWasapiExclusive(enabled: enabled));
  }

  Future<void> setEqualizer({
    required bool enabled,
    required double preampDb,
    required List<double> gainsDb,
  }) async {
    await _runPlayerCmd(
      () => playerSetEqualizer(
        enabled: enabled,
        preampDb: preampDb,
        gainsDb: gainsDb,
      ),
    );
  }

  Future<void> setCrossfade(double seconds) async {
    await _runPlayerCmd(() => playerSetCrossfade(seconds: seconds));
  }

  Future<void> setSleepTimer({double? minutes, bool endOfTrack = false}) async {
    await _runPlayerCmd(
      () => playerSetSleepTimer(minutes: minutes, endOfTrack: endOfTrack),
    );
  }

  Future<void> setOfflineMode(bool offline) async {
    try {
      await settingsSetOffline(offline: offline);
      _offlineMode = offline;
      notifyListeners();
      if (!offline && _snapshot.current != null && _currentLyrics?.found != true) {
        unawaited(refreshLyrics());
      }
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<void> _runPlayerCmd(Future<UiPlayerSnapshot> Function() fn) async {
    try {
      final snap = await fn();
      _applySnapshot(snap);
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  // Home & Mixes
  Future<void> refreshHome() async {
    try {
      await _refreshHome();
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<void> _refreshHome() async {
    _homeFeed = await libraryHome();
  }

  Future<UiHomeMixDetail?> fetchHomeMixDetail(String mixId) {
    return libraryHomeMixDetail(mixId: mixId);
  }

  Future<void> playHomeMix(String mixId, {String? startPath}) async {
    if (startPath == null) {
      await _runPlayerCmd(() => libraryPlayHomeMix(mixId: mixId));
    } else {
      await _runPlayerCmd(
        () => libraryPlayHomeMixFrom(mixId: mixId, startPath: startPath),
      );
    }
  }

  Future<UiPlaylistInfo?> saveHomeMix(String mixId, String name) async {
    try {
      final info = await librarySaveHomeMix(mixId: mixId, name: name);
      await _refreshPlaylists();
      notifyListeners();
      return info;
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
      return null;
    }
  }

  // Favorites
  Future<void> _refreshFavorites() async {
    final ids = await favoritesList();
    final tracks = await favoritesTracks();
    _favoriteIds
      ..clear()
      ..addAll(ids.map((id) => id.toInt()));
    _favoriteTracks = tracks;
    _favoritePaths
      ..clear()
      ..addAll(tracks.map((t) => t.path));
  }

  Future<void> toggleFavorite(PlatformInt64 trackId) async {
    try {
      await favoritesToggle(trackId: trackId);
      await Future.wait([_refreshFavorites(), _refreshHome()]);
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<void> toggleCurrentFavorite() async {
    final path = _snapshot.current?.path;
    if (path == null) return;
    try {
      await favoritesToggleByPath(path: path);
      await Future.wait([_refreshFavorites(), _refreshHome()]);
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<void> playFavorites(int startIndex, {bool shuffle = false}) async {
    if (shuffle) {
      await _runPlayerCmd(() => playerSetShuffle(enabled: true));
    }
    await _runPlayerCmd(() => favoritesPlay(startIndex: startIndex));
  }

  // Playlists
  Future<void> _refreshPlaylists() async {
    _playlists = await playlistsList();
  }

  Future<UiPlaylistInfo?> createPlaylist(String name) async {
    try {
      final info = await playlistsCreate(name: name);
      await _refreshPlaylists();
      notifyListeners();
      return info;
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
      return null;
    }
  }

  Future<void> renamePlaylist(PlatformInt64 id, String name) async {
    try {
      await playlistsRename(id: id, name: name);
      await _refreshPlaylists();
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<void> deletePlaylist(PlatformInt64 id) async {
    try {
      await playlistsDelete(id: id);
      await _refreshPlaylists();
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<List<UiTrackRow>> fetchPlaylistTracks(PlatformInt64 id) {
    return playlistsTracks(id: id);
  }

  Future<void> addTracksToPlaylist(
    PlatformInt64 playlistId,
    List<PlatformInt64> trackIds,
  ) async {
    try {
      await playlistsAddTracks(
        id: playlistId,
        trackIds: Int64List.fromList(trackIds.map((e) => e.toInt()).toList()),
      );
      await _refreshPlaylists();
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<void> removeTrackFromPlaylist(
    PlatformInt64 playlistId,
    int position,
  ) async {
    try {
      await playlistsRemoveTrack(id: playlistId, position: position);
      await _refreshPlaylists();
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<void> playPlaylist(
    PlatformInt64 playlistId,
    int startIndex, {
    bool shuffle = false,
  }) async {
    if (shuffle) {
      await _runPlayerCmd(() => playlistsPlayShuffled(id: playlistId));
    } else {
      await _runPlayerCmd(
        () => playlistsPlay(id: playlistId, startIndex: startIndex),
      );
    }
  }

  // Artists
  Future<void> setArtistSearch(String query) async {
    if (_artistSearch == query) return;
    _artistSearch = query;
    await _refreshArtists();
    notifyListeners();
  }

  Future<void> _refreshArtists() async {
    _artistQueryEpoch++;
    final epoch = _artistQueryEpoch;
    _artistCache.clear();
    _artistPagesLoading.clear();
    final q = _artistSearch.trim();
    final count = await libraryArtistCount(search: q.isEmpty ? null : q);
    if (epoch != _artistQueryEpoch) return;
    _artistCount = count;
    await _loadArtistPage(0, epoch);
  }

  UiArtistRow? artistAt(int index) {
    final cached = _artistCache[index];
    if (cached != null) return cached;
    final pageStart = (index ~/ _artistPageSize) * _artistPageSize;
    if (!_artistPagesLoading.contains(pageStart)) {
      unawaited(_loadArtistPage(pageStart, _artistQueryEpoch));
    }
    return null;
  }

  Future<void> _loadArtistPage(int offset, int epoch) async {
    if (_artistPagesLoading.contains(offset)) return;
    _artistPagesLoading.add(offset);
    try {
      final q = _artistSearch.trim();
      final items = await libraryArtistsPage(
        offset: offset,
        limit: _artistPageSize,
        search: q.isEmpty ? null : q,
      );
      if (epoch != _artistQueryEpoch) return;
      for (var i = 0; i < items.length; i++) {
        _artistCache[offset + i] = items[i];
      }
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    } finally {
      _artistPagesLoading.remove(offset);
    }
  }

  Future<UiArtistDetail?> fetchArtistDetail(String name) {
    return libraryArtistDetail(name: name);
  }

  Future<void> playArtist(
    String name, {
    int startIndex = 0,
    bool shuffle = false,
  }) async {
    await _runPlayerCmd(
      () => libraryPlayArtistFrom(
        name: name,
        startIndex: startIndex,
        shuffle: shuffle,
      ),
    );
  }

  // Lyrics
  Future<void> refreshLyrics() async {
    final current = _snapshot.current;
    if (current == null) {
      _currentLyrics = null;
      _lyricsTrackPath = null;
      _lyricsLoading = false;
      notifyListeners();
      return;
    }
    final targetPath = current.path;
    _lyricsTrackPath = targetPath;
    _lyricsLoading = true;
    notifyListeners();
    try {
      final res = await lyricsForTrack(
        path: current.path,
        title: current.title,
        artist: current.artist,
        album: '',
        durationSecs: _snapshot.durationSeconds,
      );
      if (_lyricsTrackPath != targetPath) return;
      _currentLyrics = res;
    } catch (e) {
      if (_lyricsTrackPath != targetPath) return;
      _currentLyrics = null;
      _lastError = e.toString();
    } finally {
      if (_lyricsTrackPath == targetPath) {
        _lyricsLoading = false;
        notifyListeners();
      }
    }
  }

  // Listening Stats (Recap)
  Future<UiStatsSummary> fetchStats({int? days}) {
    return listeningStats(days: days);
  }

  // Library search & virtualized paging
  Future<void> setTrackSearch(String query) async {
    if (_trackSearch == query) return;
    _trackSearch = query;
    await _refreshTracks();
    notifyListeners();
  }

  Future<void> _refreshTracks() async {
    _trackQueryEpoch++;
    final epoch = _trackQueryEpoch;
    _trackCache.clear();
    _trackPagesLoading.clear();
    final q = _trackSearch.trim();
    final count = await libraryTrackCount(search: q.isEmpty ? null : q);
    if (epoch != _trackQueryEpoch) return;
    _trackCount = count;
    await _loadTrackPage(0, epoch);
  }

  UiTrackRow? trackAt(int index) {
    final cached = _trackCache[index];
    if (cached != null) return cached;
    final pageStart = (index ~/ _pageSize) * _pageSize;
    if (!_trackPagesLoading.contains(pageStart)) {
      unawaited(_loadTrackPage(pageStart, _trackQueryEpoch));
    }
    return null;
  }

  Future<void> _loadTrackPage(int offset, int epoch) async {
    if (_trackPagesLoading.contains(offset)) return;
    _trackPagesLoading.add(offset);
    try {
      final q = _trackSearch.trim();
      final items = await libraryTracksPage(
        offset: offset,
        limit: _pageSize,
        search: q.isEmpty ? null : q,
      );
      if (epoch != _trackQueryEpoch) return;
      for (var i = 0; i < items.length; i++) {
        _trackCache[offset + i] = items[i];
      }
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    } finally {
      _trackPagesLoading.remove(offset);
    }
  }

  Future<void> setAlbumSearch(String query) async {
    if (_albumSearch == query) return;
    _albumSearch = query;
    await _refreshAlbums();
    notifyListeners();
  }

  Future<void> _refreshAlbums() async {
    _albumQueryEpoch++;
    final epoch = _albumQueryEpoch;
    _albumCache.clear();
    _albumPagesLoading.clear();
    final q = _albumSearch.trim();
    final count = await libraryAlbumCount(search: q.isEmpty ? null : q);
    if (epoch != _albumQueryEpoch) return;
    _albumCount = count;
    await _loadAlbumPage(0, epoch);
  }

  UiAlbumRow? albumAt(int index) {
    final cached = _albumCache[index];
    if (cached != null) return cached;
    final pageStart = (index ~/ _albumPageSize) * _albumPageSize;
    if (!_albumPagesLoading.contains(pageStart)) {
      unawaited(_loadAlbumPage(pageStart, _albumQueryEpoch));
    }
    return null;
  }

  Future<void> _loadAlbumPage(int offset, int epoch) async {
    if (_albumPagesLoading.contains(offset)) return;
    _albumPagesLoading.add(offset);
    try {
      final q = _albumSearch.trim();
      final items = await libraryAlbumsPage(
        offset: offset,
        limit: _albumPageSize,
        search: q.isEmpty ? null : q,
      );
      if (epoch != _albumQueryEpoch) return;
      for (var i = 0; i < items.length; i++) {
        _albumCache[offset + i] = items[i];
      }
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    } finally {
      _albumPagesLoading.remove(offset);
    }
  }

  Future<UiAlbumDetail?> fetchAlbumDetail(PlatformInt64 albumId) {
    return libraryAlbumDetail(albumId: albumId);
  }

  UiTrackInfo? queueTrackAt(int index) {
    final cached = _queueCache[index];
    if (cached != null) return cached;
    final pageStart = (index ~/ _pageSize) * _pageSize;
    if (!_queuePagesLoading.contains(pageStart)) {
      unawaited(_loadQueuePage(pageStart, _cachedQueueVersion));
    }
    return null;
  }

  Future<void> _loadQueuePage(int offset, BigInt version) async {
    if (_queuePagesLoading.contains(offset)) return;
    _queuePagesLoading.add(offset);
    try {
      final items = await queuePage(offset: offset, limit: _pageSize);
      if (version != _cachedQueueVersion) return;
      for (var i = 0; i < items.length; i++) {
        _queueCache[offset + i] = items[i];
      }
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    } finally {
      _queuePagesLoading.remove(offset);
    }
  }

  // Folders
  Future<void> addFolder(String path) async {
    try {
      _folders = await libraryAddFolder(path: path);
      _isScanning = await libraryIsScanning();
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<void> removeFolder(PlatformInt64 id) async {
    try {
      _folders = await libraryRemoveFolder(id: id);
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<void> rescanLibrary() async {
    try {
      await libraryScan();
      _isScanning = await libraryIsScanning();
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _stopInterpTimer();
    _eventSub?.cancel();
    positionNotifier.dispose();
    super.dispose();
  }
}
