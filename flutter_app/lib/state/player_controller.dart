import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:path_provider/path_provider.dart';

class PlayerController extends ChangeNotifier {
  static const int _pageSize = 100;
  static const int _albumPageSize = 60;

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

  // Queue cache
  BigInt _cachedQueueVersion = BigInt.from(-1);
  final Map<int, UiTrackInfo> _queueCache = {};
  final Set<int> _queuePagesLoading = {};

  bool get initialized => _initialized;
  String? get initError => _initError;
  String? get lastError => _lastError;
  UiPlayerSnapshot get snapshot => _snapshot;
  String? get currentCoverPath => _currentCoverPath;
  bool get isPlaying => _snapshot.status == 'playing';
  bool get isScanning => _isScanning;
  int get scannedCount => _scannedCount;
  List<UiFolderInfo> get folders => _folders;
  String get trackSearch => _trackSearch;
  int get trackCount => _trackCount;
  String get albumSearch => _albumSearch;
  int get albumCount => _albumCount;

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
      await Future.wait([
        _refreshTracks(),
        _refreshAlbums(),
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
          _snapshot = UiPlayerSnapshot(
            status: _snapshot.status,
            currentIndex: _snapshot.currentIndex,
            current: _snapshot.current,
            queueLength: _snapshot.queueLength,
            queueVersion: _snapshot.queueVersion,
            positionSeconds: seconds,
            durationSeconds: duration,
            volume: _snapshot.volume,
            shuffle: _snapshot.shuffle,
            repeat: _snapshot.repeat,
            previousTrack: _snapshot.previousTrack,
            nextTrack: _snapshot.nextTrack,
            context: _snapshot.context,
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

  Future<void> _onLibraryChanged() async {
    try {
      _folders = await libraryFolders();
      _isScanning = await libraryIsScanning();
      await Future.wait([
        _refreshTracks(),
        _refreshAlbums(),
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
