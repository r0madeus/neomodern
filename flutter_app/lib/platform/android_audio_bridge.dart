import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:neomodern/src/rust/android_engine.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';

/// Bridges Rust `AudioEngine` commands and Kotlin Media3/ExoPlayer events
/// over Flutter platform channels on Android. No-op on other platforms.
class AndroidAudioBridge {
  AndroidAudioBridge._();

  static final AndroidAudioBridge instance = AndroidAudioBridge._();

  static const MethodChannel _methodChannel = MethodChannel(
    'io.github.r0madeus.neomodern/audio',
  );
  static const EventChannel _eventChannel = EventChannel(
    'io.github.r0madeus.neomodern/audio_events',
  );

  bool _started = false;
  StreamSubscription<UiAndroidAudioCmd>? _cmdSub;
  StreamSubscription<dynamic>? _eventSub;
  Future<void> _cmdChain = Future<void>.value();

  void start() {
    if (!Platform.isAndroid || _started) return;
    _started = true;

    _eventSub = _eventChannel.receiveBroadcastStream().listen(
      _onPlatformEvent,
      onError: (Object error) {
        _reportSafely(UiAndroidAudioEvent.error(error.toString()));
      },
    );

    _cmdSub = subscribeAndroidAudioCmds().listen(
      (cmd) {
        _cmdChain = _cmdChain.then((_) => _dispatchCmd(cmd));
      },
      onError: (Object error) {
        _reportSafely(UiAndroidAudioEvent.error(error.toString()));
      },
    );
  }

  Future<void> stop() async {
    _started = false;
    await _cmdSub?.cancel();
    _cmdSub = null;
    await _eventSub?.cancel();
    _eventSub = null;
  }

  Future<void> _dispatchCmd(UiAndroidAudioCmd cmd) async {
    final encoded = encodeAndroidAudioCmd(cmd);
    try {
      await _methodChannel.invokeMethod<dynamic>(encoded.$1, encoded.$2);
    } catch (error) {
      await _reportSafely(UiAndroidAudioEvent.error(error.toString()));
    }
  }

  void _onPlatformEvent(dynamic raw) {
    final parsed = parseAndroidAudioEvent(raw);
    if (parsed != null) {
      unawaited(_reportSafely(parsed));
    }
  }

  Future<void> _reportSafely(UiAndroidAudioEvent event) async {
    try {
      await androidAudioReportEvent(event: event);
    } catch (error) {
      debugPrint('AndroidAudioBridge report error: $error');
    }
  }
}

@visibleForTesting
(String, Map<String, Object?>?) encodeAndroidAudioCmd(UiAndroidAudioCmd cmd) {
  return switch (cmd) {
    UiAndroidAudioCmd_Load(:final path, :final gain) => (
      'loadTrack',
      <String, Object?>{'path': path, 'gain': gain},
    ),
    UiAndroidAudioCmd_SetNext(:final path, :final gain) => (
      'setNextTrack',
      <String, Object?>{'path': path, 'gain': gain},
    ),
    UiAndroidAudioCmd_ClearNext() => (
      'setNextTrack',
      <String, Object?>{'path': null},
    ),
    UiAndroidAudioCmd_Play() => ('play', null),
    UiAndroidAudioCmd_Pause() => ('pause', null),
    UiAndroidAudioCmd_Stop() => ('stop', null),
    UiAndroidAudioCmd_Seek(:final seconds) => (
      'seek',
      <String, Object?>{'seconds': seconds},
    ),
    UiAndroidAudioCmd_SetVolume(:final percent) => (
      'setVolume',
      <String, Object?>{'percent': percent},
    ),
    UiAndroidAudioCmd_SetReplayGain(:final path, :final gain) => (
      'setGain',
      <String, Object?>{'path': path, 'gain': gain},
    ),
    UiAndroidAudioCmd_SetGapless(:final enabled) => (
      'setGapless',
      <String, Object?>{'enabled': enabled},
    ),
    UiAndroidAudioCmd_SetEqualizer(
      :final enabled,
      :final preampDb,
      :final gainsDb,
    ) =>
      (
        'setEqualizer',
        <String, Object?>{
          'enabled': enabled,
          'preampDb': preampDb,
          'gainsDb': gainsDb,
        },
      ),
    UiAndroidAudioCmd_SetCrossfade(:final seconds) => (
      'beginCrossfade',
      <String, Object?>{'seconds': seconds},
    ),
  };
}

@visibleForTesting
UiAndroidAudioEvent? parseAndroidAudioEvent(dynamic raw) {
  if (raw is! Map) return null;
  final type = raw['type'];
  if (type is! String) return null;

  switch (type) {
    case 'position':
      final seconds = (raw['seconds'] as num?)?.toDouble();
      if (seconds == null) return null;
      final duration = (raw['duration'] as num?)?.toDouble();
      return UiAndroidAudioEvent.position(seconds: seconds, duration: duration);
    case 'started':
      final path = raw['path'];
      final auto = raw['auto'];
      if (path is! String || auto is! bool) return null;
      return UiAndroidAudioEvent.trackStarted(path: path, autoAdvanced: auto);
    case 'ended':
      final path = raw['path'];
      final reason = raw['reason'];
      if (path is! String || reason is! String) return null;
      return UiAndroidAudioEvent.trackEnded(path: path, reason: reason);
    case 'paused':
      final paused = raw['paused'];
      if (paused is! bool) return null;
      return UiAndroidAudioEvent.paused(paused: paused);
    case 'idle':
      return const UiAndroidAudioEvent.idle();
    case 'error':
      final message = raw['message'];
      if (message is! String) return null;
      return UiAndroidAudioEvent.error(message);
    case 'media':
      return switch (raw['action']) {
        'play' => const UiAndroidAudioEvent.mediaPlay(),
        'pause' => const UiAndroidAudioEvent.mediaPause(),
        'toggle' => const UiAndroidAudioEvent.mediaToggle(),
        'next' => const UiAndroidAudioEvent.mediaNext(),
        'previous' => const UiAndroidAudioEvent.mediaPrevious(),
        _ => null,
      };
    default:
      return null;
  }
}
