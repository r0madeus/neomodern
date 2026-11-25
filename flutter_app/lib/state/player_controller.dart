import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/src/rust/api/neomodern.dart' as rust_api;
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

  // Profiles, Sync, Party Queue, and External Sources
  UiProfilesState? _profilesState;
  UiSyncStatus? _syncStatus;
  UiPairingOpen? _pairingOpen;
  UiPartyStatus? _partyStatus;
  List<UiSourceProvider> _sourceProviders = const [];

  // Wave 1 preferences, cover colors, and pinned items
  UiPrefs _uiPrefs = const UiPrefs(
    language: 'system',
    welcomeDismissed: false,
    sidebarWidth: 224.0,
    rightPanelWidth: 340.0,
  );
  final Map<String, Color?> _coverColorCache = {};
  final Set<String> _coverColorLoading = {};
  final Map<String, String?> _trackCoverCache = {};
  final Set<String> _trackCoverLoading = {};
  UiTrackRow? _currentTrackRow;
  String? _currentTrackRowPath;
  List<UiPinnedItem> _pinnedItems = const [];

  bool get initialized => _initialized;
  String? get initError => _initError;
  String? get lastError => _lastError;
  UiPlayerSnapshot get snapshot => _snapshot;
  String? get currentCoverPath => _currentCoverPath;
  Color? get currentCoverColor => coverColorCached(_currentCoverPath);
  UiTrackRow? get currentTrackRow =>
      _currentTrackRowPath == _snapshot.current?.path ? _currentTrackRow : null;
  UiPrefs get uiPrefs => _uiPrefs;
  String get language => _uiPrefs.language;
  bool get welcomeDismissed => _uiPrefs.welcomeDismissed;
  double get sidebarWidth => _uiPrefs.sidebarWidth;
  double get rightPanelWidth => _uiPrefs.rightPanelWidth;
  List<UiPinnedItem> get pinnedItems => _pinnedItems;
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

  UiProfilesState? get profilesState => _profilesState;
  bool get isProfileLocked => _profilesState?.locked ?? false;
  UiProfile? get activeProfile {
    final state = _profilesState;
    if (state == null || state.profiles.isEmpty) return null;
    for (final p in state.profiles) {
      if (p.id == state.active) return p;
    }
    return state.profiles.first;
  }

  UiSyncStatus? get syncStatus => _syncStatus;
  UiPairingOpen? get pairingOpen => _pairingOpen;
  UiPartyStatus? get partyStatus => _partyStatus;
  List<UiSourceProvider> get sourceProviders => _sourceProviders;
  List<UiSourceProvider> get enabledSourceProviders =>
      _sourceProviders.where((p) => p.enabled).toList();
  bool get hasEnabledSourceProviders =>
      _sourceProviders.any((p) => p.enabled);

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
      _uiPrefs = await uiPrefsGet();
      AppStrings.setLanguage(_uiPrefs.language);

      await Future.wait([
        _refreshTracks(),
        _refreshAlbums(),
        _refreshArtists(),
        _refreshFavorites(),
        _refreshPlaylists(),
        _refreshPinned(),
        _refreshHome(),
        _refreshProfiles(),
        _refreshSyncAndParty(),
        _refreshSourceProviders(),
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
      case UiEvent_SyncChanged():
        unawaited(_onSyncChanged());
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
      _coverColorCache.clear();
      _coverColorLoading.clear();
      _trackCoverCache.clear();
      _trackCoverLoading.clear();
      _currentTrackRow = null;
      _currentTrackRowPath = null;
      await Future.wait([
        _refreshTracks(),
        _refreshAlbums(),
        _refreshArtists(),
        _refreshFavorites(),
        _refreshPlaylists(),
        _refreshPinned(),
        _refreshHome(),
        _refreshProfiles(),
        _refreshSyncAndParty(),
        _refreshSourceProviders(),
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
      _currentTrackRow = null;
      _currentTrackRowPath = null;
      return;
    }
    if (!force && path == _coverLookupPath) return;
    _coverLookupPath = path;
    _resolveCurrentTrackRow(path);
    unawaited(
      libraryTrackCover(path: path).then((cover) {
        if (_coverLookupPath == path && cover != _currentCoverPath) {
          _currentCoverPath = cover;
          notifyListeners();
        }
      }).catchError((_) {}),
    );
  }

  void _resolveCurrentTrackRow(String path) {
    _currentTrackRowPath = path;
    for (final row in _trackCache.values) {
      if (row.path == path) {
        _currentTrackRow = row;
        return;
      }
    }
    for (final row in _favoriteTracks) {
      if (row.path == path) {
        _currentTrackRow = row;
        return;
      }
    }
    _currentTrackRow = null;
    final title = _snapshot.current?.title.trim();
    if (title == null || title.isEmpty || !_initialized) return;
    unawaited(
      libraryTracksPage(offset: 0, limit: 25, search: title).then((rows) {
        if (_currentTrackRowPath != path) return;
        for (final row in rows) {
          if (row.path == path) {
            _currentTrackRow = row;
            notifyListeners();
            break;
          }
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

  Future<void> enqueueManyTracks(List<String> paths) async {
    if (paths.isEmpty) return;
    await _runPlayerCmd(() => queueEnqueueMany(paths: paths));
  }

  Future<void> insertNextTracks(List<String> paths) async {
    await _runPlayerCmd(() => queueInsertNext(paths: paths));
  }

  Future<void> removeFromQueue(int index) async {
    await _runPlayerCmd(() => queueRemove(index: index));
  }

  Future<void> moveQueueItem(int from, int to) async {
    if (from == to) return;
    await _runPlayerCmd(() => queueMove(from: from, to: to));
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

  Future<void> setManyFavorites(
    List<PlatformInt64> trackIds,
    bool favorite,
  ) async {
    if (trackIds.isEmpty) return;
    try {
      await favoritesSetMany(
        trackIds: Int64List.fromList(trackIds.map((e) => e.toInt()).toList()),
        favorite: favorite,
      );
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
      await Future.wait([_refreshPlaylists(), _refreshPinned()]);
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<void> deletePlaylist(PlatformInt64 id) async {
    try {
      await playlistsDelete(id: id);
      await Future.wait([_refreshPlaylists(), _refreshPinned()]);
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

  Future<void> movePlaylistTrack(
    PlatformInt64 playlistId,
    int from,
    int to,
  ) async {
    if (from == to) return;
    try {
      await playlistsMoveTrack(playlistId: playlistId, from: from, to: to);
      await _refreshPlaylists();
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<void> setPlaylistCover(
    PlatformInt64 playlistId,
    String mode,
    String? value,
  ) async {
    try {
      await playlistsSetCover(
        playlistId: playlistId,
        mode: mode,
        value: value,
      );
      await Future.wait([_refreshPlaylists(), _refreshPinned()]);
      _coverColorCache.clear();
      _coverColorLoading.clear();
      _trackCoverCache.clear();
      _trackCoverLoading.clear();
      _currentTrackRow = null;
      _currentTrackRowPath = null;
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<int> exportPlaylistM3u(PlatformInt64 playlistId, String destPath) {
    return playlistsExportM3U(playlistId: playlistId, destPath: destPath);
  }

  Future<UiPlaylistInfo?> importPlaylistM3u(
    String srcPath,
    String name,
  ) async {
    try {
      final info = await playlistsImportM3U(srcPath: srcPath, name: name);
      await _refreshPlaylists();
      notifyListeners();
      return info;
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
      return null;
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

  Future<UiStatsSummary> fetchStatsRange({
    int? fromMs,
    int? toMs,
    bool sortByPlays = false,
  }) {
    return listeningStatsRange(
      fromMs: fromMs != null ? PlatformInt64Util.from(fromMs) : null,
      toMs: toMs != null ? PlatformInt64Util.from(toMs) : null,
      sortByPlays: sortByPlays,
    );
  }

  Future<void> clearListeningHistory() async {
    await listeningHistoryClear();
    await _refreshHome();
    notifyListeners();
  }

  Future<UiPlaylistInfo?> saveTracksAsPlaylist(
    String name,
    List<PlatformInt64> trackIds,
  ) async {
    try {
      final info = await playlistsCreate(name: name);
      if (trackIds.isNotEmpty) {
        await playlistsAddTracks(
          id: info.id,
          trackIds:
              Int64List.fromList(trackIds.map((e) => e.toInt()).toList()),
        );
      }
      await _refreshPlaylists();
      notifyListeners();
      return info;
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
      return null;
    }
  }

  // Genres & Search
  Future<List<UiGenreInfo>> fetchGenres() {
    return libraryGenres();
  }

  Future<UiGenreDetail> fetchGenreDetail(String genre) {
    return libraryGenreDetail(genre: genre);
  }

  Future<List<UiTrackRow>> fetchGenreTracksPage(
    String genre, {
    int offset = 0,
    int limit = 100,
  }) {
    return libraryGenreTracksPage(genre: genre, offset: offset, limit: limit);
  }

  Future<void> playGenre(
    String genre, {
    bool shuffle = false,
    int startIndex = 0,
  }) async {
    await _runPlayerCmd(
      () => libraryPlayGenre(
        genre: genre,
        shuffle: shuffle,
        startIndex: startIndex,
      ),
    );
  }

  Future<List<UiArtistRow>> searchArtists(String query, {int limit = 12}) {
    final q = query.trim();
    return libraryArtistsPage(
      offset: 0,
      limit: limit,
      search: q.isEmpty ? null : q,
    );
  }

  Future<List<UiAlbumRow>> searchAlbums(String query, {int limit = 12}) {
    final q = query.trim();
    return libraryAlbumsPage(
      offset: 0,
      limit: limit,
      search: q.isEmpty ? null : q,
    );
  }

  Future<List<UiTrackRow>> searchTracks(String query, {int limit = 25}) {
    final q = query.trim();
    return libraryTracksPage(
      offset: 0,
      limit: limit,
      search: q.isEmpty ? null : q,
    );
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

  // Profiles & PIN
  Future<void> _refreshProfiles() async {
    _profilesState = await profilesList();
  }

  Future<void> refreshProfiles() async {
    try {
      await _refreshProfiles();
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<String?> createProfile(String name) async {
    try {
      _profilesState = await profileCreate(name: name);
      notifyListeners();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> renameProfile(PlatformInt64 id, String name) async {
    try {
      _profilesState = await profileRename(id: id, name: name);
      notifyListeners();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> deleteProfile(PlatformInt64 id) async {
    try {
      _profilesState = await profileDelete(id: id);
      notifyListeners();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> switchProfile(PlatformInt64 id, {String? pin}) async {
    try {
      final snap = await profileSwitch(id: id, pin: pin);
      _applySnapshot(snap);
      await Future.wait([
        _refreshProfiles(),
        _refreshSyncAndParty(),
        _refreshFavorites(),
        _refreshPlaylists(),
        _refreshPinned(),
        _refreshHome(),
      ]);
      notifyListeners();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> setProfilePin(PlatformInt64 id, String? pin) async {
    try {
      _profilesState = await profileSetPin(id: id, pin: pin);
      notifyListeners();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> unlockActiveProfile(String pin) async {
    try {
      _profilesState = await profileUnlock(pin: pin);
      notifyListeners();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  // Local Network Sync & Party Queue
  Future<void> _refreshSyncAndParty() async {
    final results = await Future.wait([
      rust_api.syncStatus(),
      rust_api.partyStatus(),
    ]);
    _syncStatus = results[0] as UiSyncStatus;
    _partyStatus = results[1] as UiPartyStatus;
    if (_syncStatus?.pairingState != 'open') {
      _pairingOpen = null;
    }
  }

  Future<void> _onSyncChanged() async {
    try {
      await _refreshSyncAndParty();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> refreshSyncAndParty() async {
    try {
      await _refreshSyncAndParty();
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<void> setAllowPhoneConnections(bool allow) async {
    try {
      _syncStatus = await syncSetAllowPhoneConnections(allow: allow);
      if (!allow) {
        _pairingOpen = null;
      }
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<String?> setDeviceName(String name) async {
    try {
      _syncStatus = await syncSetDeviceName(name: name);
      notifyListeners();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<void> openPairing() async {
    try {
      _pairingOpen = await syncPairOpen();
      _syncStatus = await rust_api.syncStatus();
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<void> closePairing() async {
    try {
      _pairingOpen = null;
      _syncStatus = await syncPairClose();
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<void> removeSyncPeer(String peerId) async {
    try {
      _syncStatus = await syncRemovePeer(peerId: peerId);
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<void> triggerSyncNow() async {
    try {
      _syncStatus = await syncNow();
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<void> setPartyEnabled(bool enabled) async {
    try {
      _partyStatus = await partySetEnabled(enabled: enabled);
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<void> startParty() async {
    try {
      _partyStatus = await partyStart();
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<void> endParty() async {
    try {
      _partyStatus = await partyEnd();
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<void> newPartyCode() async {
    try {
      _partyStatus = await partyNewCode();
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<void> removePartyGuest(String id) async {
    try {
      _partyStatus = await partyRemoveGuest(id: id);
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  // External Sources
  Future<void> _refreshSourceProviders() async {
    _sourceProviders = await sourceProvidersList();
  }

  Future<String?> addSourceProvider(String name, String baseUrl) async {
    try {
      _sourceProviders = await sourceProviderAdd(name: name, baseUrl: baseUrl);
      notifyListeners();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<void> removeSourceProvider(String id) async {
    try {
      _sourceProviders = await sourceProviderRemove(id: id);
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<void> toggleSourceProvider(String id, bool enabled) async {
    try {
      _sourceProviders = await sourceProviderToggle(id: id, enabled: enabled);
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<List<UiExternalTrack>> searchExternalSource(
    String providerId,
    String query, {
    int limit = 25,
  }) {
    return sourceProviderSearch(
      providerId: providerId,
      query: query,
      limit: limit,
    );
  }

  Future<void> playExternalTrack(UiExternalTrack track) async {
    await _runPlayerCmd(
      () => sourceProviderPlay(
        providerId: track.providerId,
        externalId: track.externalId,
        title: track.title,
        artist: track.artist,
      ),
    );
  }

  // Cover Path & Color Cache
  String? trackCoverCached(String? path) {
    final key = path?.trim();
    if (key == null || key.isEmpty) return null;
    if (_trackCoverCache.containsKey(key)) {
      return _trackCoverCache[key];
    }
    if (_initialized && !_trackCoverLoading.contains(key)) {
      _trackCoverLoading.add(key);
      unawaited(
        libraryTrackCover(path: key).then((cover) {
          _trackCoverCache[key] = cover;
          notifyListeners();
        }).catchError((_) {
          _trackCoverCache[key] = null;
        }).whenComplete(() {
          _trackCoverLoading.remove(key);
        }),
      );
    }
    return null;
  }

  Color? coverColorCached(String? path) {
    final key = path?.trim();
    if (key == null || key.isEmpty) return null;
    if (_coverColorCache.containsKey(key)) {
      return _coverColorCache[key];
    }
    if (!_coverColorLoading.contains(key)) {
      _coverColorLoading.add(key);
      unawaited(
        coverColorForPath(path: key).then((argb) {
          _coverColorCache[key] = argb != null ? Color(argb) : null;
          notifyListeners();
        }).catchError((_) {
          _coverColorCache[key] = null;
        }).whenComplete(() {
          _coverColorLoading.remove(key);
        }),
      );
    }
    return null;
  }

  // Pinned Items
  Future<void> _refreshPinned() async {
    _pinnedItems = await pinnedList();
  }

  bool isPinned(String kind, PlatformInt64 targetId) {
    return _pinnedItems.any((p) => p.kind == kind && p.targetId == targetId);
  }

  Future<bool?> togglePinned(String kind, PlatformInt64 targetId) async {
    try {
      final pinned = await pinnedToggle(kind: kind, targetId: targetId);
      await _refreshPinned();
      notifyListeners();
      return pinned;
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
      return null;
    }
  }

  // UI Preferences & Welcome
  void previewSidebarWidth(double width) {
    final clamped = width.clamp(176.0, 380.0);
    if ((_uiPrefs.sidebarWidth - clamped).abs() < 0.5) return;
    _uiPrefs = UiPrefs(
      language: _uiPrefs.language,
      welcomeDismissed: _uiPrefs.welcomeDismissed,
      sidebarWidth: clamped,
      rightPanelWidth: _uiPrefs.rightPanelWidth,
    );
    notifyListeners();
  }

  void previewRightPanelWidth(double width) {
    final clamped = width.clamp(270.0, 480.0);
    if ((_uiPrefs.rightPanelWidth - clamped).abs() < 0.5) return;
    _uiPrefs = UiPrefs(
      language: _uiPrefs.language,
      welcomeDismissed: _uiPrefs.welcomeDismissed,
      sidebarWidth: _uiPrefs.sidebarWidth,
      rightPanelWidth: clamped,
    );
    notifyListeners();
  }

  Future<void> saveUiPrefs() async {
    try {
      await uiPrefsSave(prefs: _uiPrefs);
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<void> setLanguage(String language) async {
    final normalized = language.trim();
    if (_uiPrefs.language == normalized) return;
    _uiPrefs = UiPrefs(
      language: normalized,
      welcomeDismissed: _uiPrefs.welcomeDismissed,
      sidebarWidth: _uiPrefs.sidebarWidth,
      rightPanelWidth: _uiPrefs.rightPanelWidth,
    );
    AppStrings.setLanguage(normalized);
    notifyListeners();
    await saveUiPrefs();
  }

  Future<void> dismissWelcome() async {
    if (_uiPrefs.welcomeDismissed) return;
    _uiPrefs = UiPrefs(
      language: _uiPrefs.language,
      welcomeDismissed: true,
      sidebarWidth: _uiPrefs.sidebarWidth,
      rightPanelWidth: _uiPrefs.rightPanelWidth,
    );
    notifyListeners();
    await saveUiPrefs();
  }

  Future<String?> fetchDefaultMusicDir() {
    return defaultMusicDir();
  }

  // Lyrics save
  Future<String> saveCurrentLyricsLrc(String trackPath, String content) async {
    final savedPath = await lyricsSaveLrc(
      trackPath: trackPath,
      content: content,
    );
    await refreshLyrics();
    return savedPath;
  }

  // Tag Editor & MusicBrainz Metadata Matching
  Future<UiTrackTags> readTrackTags(String path) {
    return trackTagsRead(path: path);
  }

  Future<void> writeTrackTags(String path, UiTrackTags newTags) async {
    await trackTagsWrite(path: path, newTags: newTags);
    await _onLibraryChanged();
  }

  Future<List<UiAlbumMatchCandidate>> matchAlbumMetadata(
    PlatformInt64 albumId,
  ) {
    return metadataMatchAlbum(albumId: albumId);
  }

  Future<UiMetadataApplyResult> applyAlbumMetadata({
    required PlatformInt64 albumId,
    required String releaseMbid,
    required bool downloadCover,
  }) async {
    final result = await metadataApplyAlbum(
      albumId: albumId,
      releaseMbid: releaseMbid,
      downloadCover: downloadCover,
    );
    await _onLibraryChanged();
    return result;
  }

  Future<int> undoLastMetadata() async {
    final count = await metadataUndoLast();
    await _onLibraryChanged();
    return count;
  }

  Future<bool> canUndoMetadata() {
    return metadataCanUndo();
  }

  @override
  void dispose() {
    _stopInterpTimer();
    _eventSub?.cancel();
    positionNotifier.dispose();
    super.dispose();
  }
}
