import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:neomodern/platform/android_audio_bridge.dart';
import 'package:neomodern/src/rust/frb_generated.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/shell.dart';
import 'package:neomodern/ui/widgets/smooth_scroll.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  AndroidAudioBridge.instance.start();
  runApp(const NeoModernApp());
}

class NeoModernApp extends StatefulWidget {
  const NeoModernApp({super.key});

  @override
  State<NeoModernApp> createState() => _NeoModernAppState();
}

class _NeoModernAppState extends State<NeoModernApp> {
  late final PlayerController _controller;

  @override
  void initState() {
    super.initState();
    _controller = PlayerController();
    unawaited(_controller.init());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NeoModern',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      scrollBehavior: const AppScrollBehavior(),
      home: AppShell(controller: _controller),
    );
  }
}
