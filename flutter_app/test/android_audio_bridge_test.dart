import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neomodern/platform/android_audio_bridge.dart';
import 'package:neomodern/src/rust/android_engine.dart';

void expectCmd(
  UiAndroidAudioCmd cmd,
  String expectedMethod,
  Map<String, Object?>? expectedArgs,
) {
  final actual = encodeAndroidAudioCmd(cmd);
  expect(actual.$1, expectedMethod);
  expect(actual.$2, expectedArgs);
}

void main() {
  test('encodeAndroidAudioCmd maps every command to MethodChannel payload', () {
    expectCmd(
      const UiAndroidAudioCmd.load(path: '/music/a.flac', gain: 0.75),
      'loadTrack',
      {'path': '/music/a.flac', 'gain': 0.75},
    );
    expectCmd(
      const UiAndroidAudioCmd.setNext(path: '/music/b.flac', gain: 0.9),
      'setNextTrack',
      {'path': '/music/b.flac', 'gain': 0.9},
    );
    expectCmd(
      const UiAndroidAudioCmd.clearNext(),
      'setNextTrack',
      {'path': null},
    );
    expectCmd(const UiAndroidAudioCmd.play(), 'play', null);
    expectCmd(const UiAndroidAudioCmd.pause(), 'pause', null);
    expectCmd(const UiAndroidAudioCmd.stop(), 'stop', null);
    expectCmd(
      const UiAndroidAudioCmd.seek(seconds: 12.5),
      'seek',
      {'seconds': 12.5},
    );
    expectCmd(
      const UiAndroidAudioCmd.setVolume(percent: 60.0),
      'setVolume',
      {'percent': 60.0},
    );
    expectCmd(
      const UiAndroidAudioCmd.setReplayGain(path: '/music/a.flac', gain: 0.5),
      'setGain',
      {'path': '/music/a.flac', 'gain': 0.5},
    );
    expectCmd(
      const UiAndroidAudioCmd.setGapless(enabled: false),
      'setGapless',
      {'enabled': false},
    );
    final eqGains = Float64List.fromList(List<double>.filled(10, 1.5));
    expectCmd(
      UiAndroidAudioCmd.setEqualizer(
        enabled: true,
        preampDb: -3.0,
        gainsDb: eqGains,
      ),
      'setEqualizer',
      {'enabled': true, 'preampDb': -3.0, 'gainsDb': eqGains},
    );
    expectCmd(
      const UiAndroidAudioCmd.setCrossfade(seconds: 4.0),
      'beginCrossfade',
      {'seconds': 4.0},
    );
  });

  test('parseAndroidAudioEvent maps valid platform maps and rejects invalid', () {
    expect(
      parseAndroidAudioEvent({'type': 'position', 'seconds': 3, 'duration': 200}),
      const UiAndroidAudioEvent.position(seconds: 3.0, duration: 200.0),
    );
    expect(
      parseAndroidAudioEvent({'type': 'started', 'path': '/a.mp3', 'auto': true}),
      const UiAndroidAudioEvent.trackStarted(path: '/a.mp3', autoAdvanced: true),
    );
    expect(
      parseAndroidAudioEvent({'type': 'ended', 'path': '/a.mp3', 'reason': 'eof'}),
      const UiAndroidAudioEvent.trackEnded(path: '/a.mp3', reason: 'eof'),
    );
    expect(
      parseAndroidAudioEvent({'type': 'paused', 'paused': true}),
      const UiAndroidAudioEvent.paused(paused: true),
    );
    expect(
      parseAndroidAudioEvent({'type': 'idle'}),
      const UiAndroidAudioEvent.idle(),
    );
    expect(
      parseAndroidAudioEvent({'type': 'error', 'message': 'decoder failed'}),
      const UiAndroidAudioEvent.error('decoder failed'),
    );
    expect(
      parseAndroidAudioEvent({'type': 'media', 'action': 'play'}),
      const UiAndroidAudioEvent.mediaPlay(),
    );
    expect(
      parseAndroidAudioEvent({'type': 'media', 'action': 'pause'}),
      const UiAndroidAudioEvent.mediaPause(),
    );
    expect(
      parseAndroidAudioEvent({'type': 'media', 'action': 'toggle'}),
      const UiAndroidAudioEvent.mediaToggle(),
    );
    expect(
      parseAndroidAudioEvent({'type': 'media', 'action': 'next'}),
      const UiAndroidAudioEvent.mediaNext(),
    );
    expect(
      parseAndroidAudioEvent({'type': 'media', 'action': 'previous'}),
      const UiAndroidAudioEvent.mediaPrevious(),
    );

    expect(parseAndroidAudioEvent(null), isNull);
    expect(parseAndroidAudioEvent({'type': 'unknown'}), isNull);
    expect(parseAndroidAudioEvent({'type': 'position'}), isNull);
    expect(parseAndroidAudioEvent({'type': 'media', 'action': 'shuffle'}), isNull);
  });

  test('AndroidAudioBridge.start is a no-op on non-Android hosts', () async {
    AndroidAudioBridge.instance.start();
    await AndroidAudioBridge.instance.stop();
  });

  test('AndroidPlatformBridge returns safe defaults on non-Android hosts',
      () async {
    AndroidPlatformBridge.debugIsAndroidOverride = false;
    addTearDown(() => AndroidPlatformBridge.debugIsAndroidOverride = null);

    expect(await AndroidPlatformBridge.checkAudioPermission(), isTrue);
    expect(await AndroidPlatformBridge.requestAudioPermission(), isTrue);
    expect(await AndroidPlatformBridge.scanQrCode(), isNull);
  });

  test('AndroidPlatformBridge invokes platform MethodChannel on Android',
      () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    AndroidPlatformBridge.debugIsAndroidOverride = true;
    addTearDown(() {
      AndroidPlatformBridge.debugIsAndroidOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidPlatformBridge.channel, null);
    });

    final calls = <String>[];
    var permissionGranted = false;
    String? qrPayload = 'neomodern://pair?code=482910';

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      AndroidPlatformBridge.channel,
      (MethodCall call) async {
        calls.add(call.method);
        switch (call.method) {
          case 'checkAudioPermission':
            return permissionGranted;
          case 'requestAudioPermission':
            permissionGranted = true;
            return true;
          case 'scanQrCode':
            return qrPayload;
          default:
            return null;
        }
      },
    );

    expect(await AndroidPlatformBridge.checkAudioPermission(), isFalse);
    expect(await AndroidPlatformBridge.requestAudioPermission(), isTrue);
    expect(await AndroidPlatformBridge.checkAudioPermission(), isTrue);
    expect(
      await AndroidPlatformBridge.scanQrCode(),
      'neomodern://pair?code=482910',
    );

    qrPayload = null;
    expect(await AndroidPlatformBridge.scanQrCode(), isNull);

    expect(calls, [
      'checkAudioPermission',
      'requestAudioPermission',
      'checkAudioPermission',
      'scanQrCode',
      'scanQrCode',
    ]);
  });
}
