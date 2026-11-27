import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

/// Centralized single-stroke Lucide icon set for the K30 Editorial Catalog UI.
///
/// Keeping all primary navigation, transport, and action icons here guarantees
/// consistent stroke weight across desktop and mobile while avoiding the
/// default Material Icons look.
class AppIcons {
  AppIcons._();

  // Navigation
  static const IconData home = LucideIcons.house;
  static const IconData songs = LucideIcons.music;
  static const IconData albums = LucideIcons.disc3;
  static const IconData artists = LucideIcons.users;
  static const IconData search = LucideIcons.search;
  static const IconData recap = LucideIcons.chartBar;
  static const IconData sources = LucideIcons.globe;
  static const IconData library = LucideIcons.library;
  static const IconData settings = LucideIcons.slidersHorizontal;
  static const IconData sidebarClose = LucideIcons.panelLeftClose;
  static const IconData sidebarOpen = LucideIcons.panelLeftOpen;

  // Transport & Playback
  static const IconData play = LucideIcons.play;
  static const IconData pause = LucideIcons.pause;
  static const IconData previous = LucideIcons.skipBack;
  static const IconData next = LucideIcons.skipForward;
  static const IconData shuffle = LucideIcons.shuffle;
  static const IconData repeat = LucideIcons.repeat;
  static const IconData repeatOne = LucideIcons.repeat1;

  // Audio & Panels
  static const IconData volumeHigh = LucideIcons.volume2;
  static const IconData volumeLow = LucideIcons.volume1;
  static const IconData volumeMute = LucideIcons.volumeX;
  static const IconData queue = LucideIcons.listMusic;
  static const IconData lyrics = LucideIcons.micVocal;
  static const IconData nowPlayingPanel = LucideIcons.panelRight;
  static const IconData sleepTimer = LucideIcons.moon;

  // Actions & Status
  static const IconData saveAdd = LucideIcons.circlePlus;
  static const IconData saveChecked = LucideIcons.circleCheck;
  static const IconData star = LucideIcons.star;
  static const IconData pin = LucideIcons.pin;
  static const IconData pinOff = LucideIcons.pinOff;
  static const IconData more = LucideIcons.ellipsis;
  static const IconData back = LucideIcons.arrowLeft;
  static const IconData close = LucideIcons.x;
  static const IconData chevronDown = LucideIcons.chevronDown;
  static const IconData refresh = LucideIcons.refreshCw;
  static const IconData upload = LucideIcons.upload;
  static const IconData plus = LucideIcons.plus;
  static const IconData download = LucideIcons.download;
  static const IconData cloud = LucideIcons.cloud;
  static const IconData attach = LucideIcons.paperclip;
}
