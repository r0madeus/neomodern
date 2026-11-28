import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/backup_settings_section.dart';
import 'package:neomodern/ui/modules_settings_section.dart';
import 'package:neomodern/ui/move_folder_dialog.dart';
import 'package:neomodern/ui/sync_settings_section.dart';
import 'package:neomodern/ui/widgets/smooth_scroll.dart';

class SettingsView extends StatefulWidget {
  const SettingsView({super.key, required this.controller});

  final PlayerController controller;

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  static const List<String> _bandLabels = [
    '31',
    '62',
    '125',
    '250',
    '500',
    '1k',
    '2k',
    '4k',
    '8k',
    '16k',
  ];

  double? _crossfadeDraft;
  double? _preampDraft;
  List<double>? _gainsDraft;
  bool _savingCachedLyrics = false;
  bool _sharingLyrics = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctrl = widget.controller;
      if (!ctrl.initialized) return;
      if (ctrl.lyricsCoverage == null) {
        unawaited(ctrl.refreshLyricsCoverage());
      }
      if (ctrl.lyricsShareStatus == null) {
        unawaited(ctrl.refreshLyricsShareStatus());
      }
      unawaited(ctrl.libraryMissingFolders());
    });
  }

  Future<void> _openMoveFolderDialog(UiFolderInfo folder) async {
    final result = await showMoveFolderDialog(
      context: context,
      controller: widget.controller,
      folder: folder,
    );
    if (result != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t('Moved folder ({n} tracks updated)', {
              'n': result.rewrittenTracks,
            }),
          ),
          behavior: SnackBarBehavior.floating,
          width: 320,
        ),
      );
    }
  }

  Future<void> _pickAndAddFolder() async {
    final uri = await FilePicker.pickDirectory(
      dialogTitle: t('Select music folder'),
    );
    if (uri != null) {
      final path = uri.isScheme('file') ? uri.toFilePath() : uri.toString();
      if (path.isNotEmpty) {
        await widget.controller.addFolder(path);
      }
    }
  }

  Future<void> _importM3u() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: t('Import M3U Playlist'),
      type: FileType.custom,
      allowedExtensions: const ['m3u', 'm3u8'],
    );
    if (files.isEmpty) return;
    final path = files.first.path;
    if (path == null || path.isEmpty) return;
    final baseName = File(path).uri.pathSegments.last;
    final dotIdx = baseName.lastIndexOf('.');
    final stem = dotIdx > 0 ? baseName.substring(0, dotIdx) : baseName;
    final imported = await widget.controller.importPlaylistM3u(path, stem);
    if (imported != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t('Imported playlist "{name}"', {'name': imported.name})),
          behavior: SnackBarBehavior.floating,
          width: 320,
        ),
      );
    }
  }

  Future<void> _pickDownloadDir() async {
    final uri = await FilePicker.pickDirectory(
      dialogTitle: t('Select download folder'),
    );
    if (uri != null) {
      final path = uri.isScheme('file') ? uri.toFilePath() : uri.toString();
      if (path.isNotEmpty) {
        await widget.controller.setOnlineDownloadDir(path);
      }
    }
  }

  Future<void> _pickYtdlpPath() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: t('Select yt-dlp executable'),
    );
    if (files.isEmpty) return;
    final path = files.first.path;
    if (path != null && path.isNotEmpty) {
      await widget.controller.setOnlineYtdlpPath(path);
    }
  }

  Future<void> _saveCachedLyrics() async {
    if (_savingCachedLyrics) return;
    setState(() => _savingCachedLyrics = true);
    try {
      final outcome = await widget.controller.saveCachedLyrics();
      if (!mounted || outcome == null) return;
      await widget.controller.refreshLyricsCoverage();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t('Saved {saved} lyrics files ({skipped} skipped)', {
              'saved': outcome.saved,
              'skipped': outcome.skipped,
            }),
          ),
          behavior: SnackBarBehavior.floating,
          width: 340,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _savingCachedLyrics = false);
      }
    }
  }

  Future<void> _shareLyrics() async {
    if (_sharingLyrics) return;
    setState(() => _sharingLyrics = true);
    try {
      await widget.controller.shareLyrics();
    } finally {
      if (mounted) {
        setState(() => _sharingLyrics = false);
      }
    }
  }

  Future<void> _copyToClipboard(String text, String feedback) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(feedback),
        behavior: SnackBarBehavior.floating,
        width: 280,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final snap = ctrl.snapshot;
    final folders = ctrl.folders;
    final missingFolders = ctrl.missingFolders;
    final eqGains = _gainsDraft ??
        List<double>.generate(
          10,
          (i) => i < snap.eqGainsDb.length ? snap.eqGainsDb[i] : 0.0,
        );
    final preamp = _preampDraft ?? snap.eqPreampDb;
    final crossfade = _crossfadeDraft ?? snap.crossfadeSeconds;

    return SmoothScrollWrapper(
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 36),
        children: [
          Text(t('Settings'), style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 24),

        // Language Section
        _SettingsSection(
          title: t('Language'),
          children: [
            _SettingRow(
              title: t('Language'),
              subtitle: t('Choose the interface language'),
              stackOnNarrow: true,
              trailing: SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: 'system', label: Text(t('System'))),
                  ButtonSegment(value: 'en', label: Text(t('English'))),
                  ButtonSegment(value: 'tr', label: Text(t('Türkçe'))),
                ],
                selected: {ctrl.language},
                onSelectionChanged: (sel) => ctrl.setLanguage(sel.first),
                style: ButtonStyle(
                  backgroundColor: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.selected)) {
                      return AppColors.accentMuted;
                    }
                    return AppColors.canvas;
                  }),
                  foregroundColor: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.selected)) {
                      return AppColors.accent;
                    }
                    return AppColors.textSecondary;
                  }),
                  side: WidgetStateProperty.all(
                    const BorderSide(color: AppColors.border),
                  ),
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: 20),

        // Library Folders Section
        _SettingsSection(
          title: t('Library Folders'),
          subtitle: folders.length == 1
              ? t('{n} watched folder', {'n': folders.length})
              : t('{n} watched folders', {'n': folders.length}),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton.icon(
                onPressed: ctrl.isScanning || folders.isEmpty
                    ? null
                    : ctrl.rescanLibrary,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.textPrimary,
                  side: const BorderSide(color: AppColors.border),
                ),
                icon: ctrl.isScanning
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded, size: 17),
                label: Text(ctrl.isScanning ? t('Scanning...') : t('Rescan')),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _pickAndAddFolder,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: AppColors.canvas,
                ),
                icon: const Icon(Icons.create_new_folder_rounded, size: 17),
                label: Text(
                  t('Add Folder'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          children: [
            if (missingFolders.isNotEmpty)
              _MissingFoldersBanner(
                folders: missingFolders,
                onMoveFolder: _openMoveFolderDialog,
              ),
            if (ctrl.isScanning)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.accentMuted,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.accent,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      t('Scanning library... {n} files processed',
                          {'n': ctrl.scannedCount}),
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            if (folders.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  t('No music folders added yet. Click "Add Folder" to scan local audio files.'),
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                  ),
                ),
              )
            else
              for (var i = 0; i < folders.length; i++) ...[
                if (i > 0) const Divider(height: 1, color: AppColors.border),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.folder_rounded,
                        size: 18,
                        color: AppColors.accent,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          folders[i].path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: t('Move folder'),
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(
                          Icons.drive_file_move_outlined,
                          size: 18,
                          color: AppColors.textSecondary,
                        ),
                        onPressed: () => _openMoveFolderDialog(folders[i]),
                      ),
                      IconButton(
                        tooltip: t('Remove folder'),
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 18,
                          color: AppColors.textSecondary,
                        ),
                        onPressed: () => ctrl.removeFolder(folders[i].id),
                      ),
                    ],
                  ),
                ),
              ],
          ],
        ),

        const SizedBox(height: 20),

        // Playlists & M3U Section
        _SettingsSection(
          title: t('Playlists & M3U'),
          children: [
            _SettingRow(
              title: t('Import M3U Playlist'),
              subtitle:
                  t('Import an .m3u or .m3u8 playlist file into your library'),
              trailing: OutlinedButton.icon(
                onPressed: _importM3u,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.textPrimary,
                  side: const BorderSide(color: AppColors.border),
                ),
                icon: const Icon(Icons.file_open_outlined, size: 16),
                label: Text(t('Import M3U')),
              ),
            ),
          ],
        ),

        const SizedBox(height: 20),

        // Playback Section
        _SettingsSection(
          title: t('Playback'),
          children: [
            _SettingRow(
              title: t('ReplayGain'),
              subtitle: t('Normalize loudness using embedded ReplayGain tags'),
              stackOnNarrow: true,
              trailing: SegmentedButton<String>(
                segments: [
                  ButtonSegment(value: 'off', label: Text(t('Off'))),
                  ButtonSegment(value: 'track', label: Text(t('Track'))),
                  ButtonSegment(value: 'album', label: Text(t('Album'))),
                ],
                selected: {snap.replaygain},
                onSelectionChanged: (sel) => ctrl.setReplaygain(sel.first),
                style: ButtonStyle(
                  backgroundColor: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.selected)) {
                      return AppColors.accentMuted;
                    }
                    return AppColors.canvas;
                  }),
                  foregroundColor: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.selected)) {
                      return AppColors.accent;
                    }
                    return AppColors.textSecondary;
                  }),
                  side: WidgetStateProperty.all(
                    const BorderSide(color: AppColors.border),
                  ),
                ),
              ),
            ),
            const Divider(height: 20, color: AppColors.border),
            _SettingRow(
              title: t('Gapless Playback'),
              subtitle: t('Seamless transitions between consecutive tracks'),
              trailing: Switch(
                value: snap.gapless,
                onChanged: ctrl.setGapless,
              ),
            ),
            if (Platform.isWindows) ...[
              const Divider(height: 20, color: AppColors.border),
              _SettingRow(
                title: t('WASAPI Exclusive Mode'),
                subtitle: t(
                    'Bypass Windows audio mixer for bit-perfect output (takes effect on next track)'),
                trailing: Switch(
                  value: snap.wasapiExclusive,
                  onChanged: ctrl.setWasapiExclusive,
                ),
              ),
            ],
            const Divider(height: 20, color: AppColors.border),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t('Crossfade'),
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w500,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            t('Smoothly blend into the next local track'),
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      crossfade <= 0
                          ? t('Off')
                          : '${crossfade.toStringAsFixed(1)} s',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.accent,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: crossfade.clamp(0.0, 12.0),
                  min: 0,
                  max: 12,
                  divisions: 24,
                  onChanged: (v) => setState(() => _crossfadeDraft = v),
                  onChangeEnd: (v) async {
                    setState(() => _crossfadeDraft = null);
                    await ctrl.setCrossfade(v);
                  },
                ),
              ],
            ),
            const Divider(height: 20, color: AppColors.border),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t('Sleep Timer'),
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w500,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            t('Automatically fade out and pause playback'),
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (snap.sleepEndOfTrack || snap.sleepEndsAt != null)
                      Text(
                        snap.sleepEndOfTrack
                            ? t('Active: End of track')
                            : _formatSleepRemaining(snap.sleepEndsAt!),
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.accent,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _SleepChip(
                      label: t('Off'),
                      selected:
                          !snap.sleepEndOfTrack && snap.sleepEndsAt == null,
                      onTap: () => ctrl.setSleepTimer(),
                    ),
                    for (final mins in [15, 30, 45, 60])
                      _SleepChip(
                        label: t('{n} min', {'n': mins}),
                        selected: false,
                        onTap: () =>
                            ctrl.setSleepTimer(minutes: mins.toDouble()),
                      ),
                    _SleepChip(
                      label: t('End of Track'),
                      selected: snap.sleepEndOfTrack,
                      onTap: () => ctrl.setSleepTimer(endOfTrack: true),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),

        const SizedBox(height: 20),

        // 10-Band Equalizer Section
        _SettingsSection(
          title: t('10-Band Equalizer'),
          subtitle: snap.eqEnabled ? t('Active') : t('Disabled'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: () {
                  setState(() {
                    _preampDraft = null;
                    _gainsDraft = null;
                  });
                  ctrl.setEqualizer(
                    enabled: snap.eqEnabled,
                    preampDb: 0.0,
                    gainsDb: List<double>.filled(10, 0.0),
                  );
                },
                child: Text(t('Reset Flat')),
              ),
              const SizedBox(width: 6),
              Switch(
                value: snap.eqEnabled,
                onChanged: (enabled) => ctrl.setEqualizer(
                  enabled: enabled,
                  preampDb: preamp,
                  gainsDb: eqGains,
                ),
              ),
            ],
          ),
          children: [
            Row(
              children: [
                SizedBox(
                  width: 84,
                  child: Text(
                    t('Preamp'),
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: preamp.clamp(-12.0, 12.0),
                    min: -12,
                    max: 12,
                    divisions: 48,
                    onChanged: (v) => setState(() => _preampDraft = v),
                    onChangeEnd: (v) async {
                      setState(() => _preampDraft = null);
                      await ctrl.setEqualizer(
                        enabled: snap.eqEnabled,
                        preampDb: v,
                        gainsDb: eqGains,
                      );
                    },
                  ),
                ),
                SizedBox(
                  width: 60,
                  child: Text(
                    '${preamp >= 0 ? '+' : ''}${preamp.toStringAsFixed(1)} dB',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 190,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (var i = 0; i < 10; i++)
                    Expanded(
                      child: Column(
                        children: [
                          Text(
                            '${eqGains[i] >= 0 ? '+' : ''}${eqGains[i].toStringAsFixed(1)}',
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: AppColors.textMuted,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                          Expanded(
                            child: RotatedBox(
                              quarterTurns: 3,
                              child: Slider(
                                value: eqGains[i].clamp(-12.0, 12.0),
                                min: -12,
                                max: 12,
                                divisions: 48,
                                onChanged: (v) {
                                  final next = List<double>.from(eqGains);
                                  next[i] = v;
                                  setState(() => _gainsDraft = next);
                                },
                                onChangeEnd: (v) async {
                                  final next = List<double>.from(eqGains);
                                  next[i] = v;
                                  setState(() => _gainsDraft = null);
                                  await ctrl.setEqualizer(
                                    enabled: snap.eqEnabled,
                                    preampDb: preamp,
                                    gainsDb: next,
                                  );
                                },
                              ),
                            ),
                          ),
                          Text(
                            _bandLabels[i],
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),

        const SizedBox(height: 20),

        _buildNetworkAndPrivacySection(ctrl),

        const SizedBox(height: 20),

        _buildOnlineAndDownloadsSection(ctrl),

        const SizedBox(height: 20),

        _buildArtistInfoSection(ctrl),

        const SizedBox(height: 20),

        _buildLyricsSection(ctrl),

        const SizedBox(height: 20),

        _buildUpdatesSection(ctrl),

        const SizedBox(height: 20),

        BackupSettingsSection(controller: widget.controller),

        const SizedBox(height: 20),

        SyncSettingsSection(controller: ctrl),

        const SizedBox(height: 20),

        ModulesSettingsSection(controller: ctrl),
      ],
      ),
    );
  }

  Widget _buildNetworkAndPrivacySection(PlayerController ctrl) {
    final net = ctrl.netSettings;
    final offline = net?.offlineMode ?? ctrl.offlineMode;
    final rawSaveMode = net?.lyricsSave ?? 'off';
    final saveMode = const {'off', 'sidecar', 'embed'}.contains(rawSaveMode)
        ? rawSaveMode
        : 'off';

    return _SettingsSection(
      title: t('Network & Privacy'),
      subtitle: offline
          ? t('Offline mode active — all external requests blocked')
          : t('Control individual network features and lyrics storage'),
      children: [
        _SettingRow(
          title: t('Offline Mode'),
          subtitle: t(
              'Block all network requests (online search, lyrics, metadata, and updates)'),
          trailing: Switch(
            value: offline,
            onChanged: ctrl.setOfflineMode,
          ),
        ),
        const Divider(height: 20, color: AppColors.border),
        _SettingRow(
          title: t('Online Search & Downloads'),
          subtitle: t('Allow searching and downloading tracks via yt-dlp'),
          trailing: Switch(
            value: net?.online ?? true,
            onChanged: (v) => ctrl.setNetFeature('online', v),
          ),
        ),
        const Divider(height: 20, color: AppColors.border),
        _SettingRow(
          title: t('Lyrics Lookups & Sharing'),
          subtitle: t('Fetch synced lyrics online and share local .lrc files'),
          trailing: Switch(
            value: net?.lyrics ?? true,
            onChanged: (v) => ctrl.setNetFeature('lyrics', v),
          ),
        ),
        const Divider(height: 20, color: AppColors.border),
        _SettingRow(
          title: t('Metadata Matching'),
          subtitle: t('Look up album and track tags from MusicBrainz'),
          trailing: Switch(
            value: net?.metadata ?? true,
            onChanged: (v) => ctrl.setNetFeature('metadata', v),
          ),
        ),
        const Divider(height: 20, color: AppColors.border),
        _SettingRow(
          title: t('Update Checks'),
          subtitle: t('Allow checking for new NeoModern releases'),
          trailing: Switch(
            value: net?.updates ?? true,
            onChanged: (v) => ctrl.setNetFeature('updates', v),
          ),
        ),
        const Divider(height: 20, color: AppColors.border),
        _SettingRow(
          title: t('Auto-Save Fetched Lyrics'),
          subtitle: t('Store online lyrics alongside audio files or in tags'),
          stackOnNarrow: true,
          trailing: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: 'off', label: Text(t('Off'))),
              ButtonSegment(value: 'sidecar', label: Text(t('Sidecar'))),
              ButtonSegment(value: 'embed', label: Text(t('Embedded'))),
            ],
            selected: {saveMode},
            onSelectionChanged: (sel) => ctrl.setLyricsSaveMode(sel.first),
            style: _segmentedButtonStyle(),
          ),
        ),
        const Divider(height: 20, color: AppColors.border),
        _SettingRow(
          title: t('NetEase Lyrics Provider'),
          subtitle: t('Include NetEase Cloud Music as a fallback lyrics source'),
          trailing: Switch(
            value: net?.lyricsNetease ?? false,
            onChanged: ctrl.setLyricsNetease,
          ),
        ),
      ],
    );
  }

  Widget _buildOnlineAndDownloadsSection(PlayerController ctrl) {
    final status = ctrl.onlineStatus;
    final downloads = ctrl.downloads;
    final hasFinishedDownloads = downloads.any(
      (j) =>
          j.state == 'done' || j.state == 'failed' || j.state == 'cancelled',
    );

    return _SettingsSection(
      title: t('Online Search & Downloads'),
      subtitle: t('Manage yt-dlp, ffmpeg, download folder, and active transfers'),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _ToolBadge(
              label: status?.ytdlpVersion != null &&
                      status!.ytdlpVersion!.isNotEmpty
                  ? 'yt-dlp (${status.ytdlpVersion})'
                  : 'yt-dlp',
              available: status?.ytdlpAvailable ?? false,
              managed: status?.managedYtdlp ?? false,
            ),
            _ToolBadge(
              label: 'ffmpeg',
              available: status?.ffmpegAvailable ?? false,
              managed: status?.managedFfmpeg ?? false,
            ),
          ],
        ),
        const Divider(height: 22, color: AppColors.border),
        _SettingRow(
          title: t('Download Folder'),
          subtitle: status?.downloadDir.isNotEmpty == true
              ? status!.downloadDir
              : t('Default music downloads folder'),
          stackOnNarrow: true,
          trailing: OutlinedButton.icon(
            onPressed: _pickDownloadDir,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.textPrimary,
              side: const BorderSide(color: AppColors.border),
            ),
            icon: const Icon(Icons.folder_open_rounded, size: 16),
            label: Text(t('Choose...')),
          ),
        ),
        const Divider(height: 20, color: AppColors.border),
        _SettingRow(
          title: t('Custom yt-dlp Path'),
          subtitle: status?.ytdlpPath?.isNotEmpty == true
              ? status!.ytdlpPath!
              : t('Manual executable path (optional)'),
          stackOnNarrow: true,
          trailing: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (status?.ytdlpPath?.isNotEmpty == true)
                TextButton(
                  onPressed: () => ctrl.setOnlineYtdlpPath(null),
                  child: Text(t('Clear')),
                ),
              OutlinedButton.icon(
                onPressed: _pickYtdlpPath,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.textPrimary,
                  side: const BorderSide(color: AppColors.border),
                ),
                icon: const Icon(Icons.terminal_rounded, size: 16),
                label: Text(t('Browse...')),
              ),
            ],
          ),
        ),
        const Divider(height: 22, color: AppColors.border),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            Text(
              t('Downloads ({n})', {'n': downloads.length}),
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            if (hasFinishedDownloads)
              TextButton.icon(
                onPressed: ctrl.clearFinishedDownloads,
                icon: const Icon(Icons.clear_all_rounded, size: 16),
                label: Text(t('Clear finished')),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (downloads.isEmpty)
          Text(
            t('No active or recent downloads.'),
            style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted),
          )
        else
          for (var i = 0; i < downloads.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _DownloadJobCard(
              job: downloads[i],
              onCancel: () => ctrl.cancelDownload(downloads[i].id),
            ),
          ],
      ],
    );
  }

  Widget _buildArtistInfoSection(PlayerController ctrl) {
    final progress = ctrl.artistScanProgress;
    final running = progress?.running ?? false;
    final done = progress?.done ?? 0;
    final total = progress?.total ?? 0;
    final fraction =
        running && total > 0 ? (done / total).clamp(0.0, 1.0) : null;

    return _SettingsSection(
      title: t('Artist Info'),
      subtitle: t('Fetch biographies and artist artwork for your library'),
      trailing: running
          ? OutlinedButton.icon(
              onPressed: ctrl.cancelArtistEnrich,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.danger,
                side: const BorderSide(color: AppColors.border),
              ),
              icon: const Icon(Icons.close_rounded, size: 16),
              label: Text(t('Cancel')),
            )
          : OutlinedButton.icon(
              onPressed: ctrl.enrichAllArtists,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textPrimary,
                side: const BorderSide(color: AppColors.border),
              ),
              icon: const Icon(Icons.auto_awesome_rounded, size: 16),
              label: Text(t('Enrich all artists')),
            ),
      children: [
        if (running) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  progress?.current?.isNotEmpty == true
                      ? t('Enriching {artist}...', {'artist': progress!.current!})
                      : t('Enriching artists...'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$done / $total',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.accent,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: fraction,
            backgroundColor: AppColors.canvas,
            color: AppColors.accent,
          ),
        ] else if (progress != null &&
            (progress.error != null ||
                progress.cancelled ||
                progress.updated > 0)) ...[
          Text(
            progress.error != null
                ? progress.error!
                : progress.cancelled
                    ? t('Artist enrichment cancelled ({done}/{total}).', {
                        'done': progress.done,
                        'total': progress.total,
                      })
                    : t('Updated {n} artists.', {'n': progress.updated}),
            style: TextStyle(
              fontSize: 12.5,
              color: progress.error != null
                  ? AppColors.danger
                  : AppColors.textSecondary,
            ),
          ),
        ] else
          Text(
            t('Scan all library artists to populate missing biographies and images.'),
            style: const TextStyle(
              fontSize: 12.5,
              color: AppColors.textSecondary,
            ),
          ),
      ],
    );
  }

  Widget _buildLyricsSection(PlayerController ctrl) {
    final coverage = ctrl.lyricsCoverage;
    final shareStatus = ctrl.lyricsShareStatus;
    final currentTrack = ctrl.snapshot.current;
    final sharingBusy = _sharingLyrics || shareStatus?.reason == 'busy';

    return _SettingsSection(
      title: t('Lyrics'),
      subtitle: t('Library lyrics coverage, offline export, and LRCLIB sharing'),
      trailing: IconButton(
        tooltip: t('Refresh'),
        visualDensity: VisualDensity.compact,
        icon: const Icon(
          Icons.refresh_rounded,
          size: 18,
          color: AppColors.textSecondary,
        ),
        onPressed: () {
          unawaited(ctrl.refreshLyricsCoverage());
          unawaited(ctrl.refreshLyricsShareStatus());
        },
      ),
      children: [
        if (coverage == null)
          Text(
            t('Loading lyrics coverage...'),
            style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted),
          )
        else
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              _CoverageChip(
                label: t('With lyrics'),
                count: coverage.withLyrics.toString(),
                accent: true,
              ),
              _CoverageChip(
                label: t('Without lyrics'),
                count: coverage.withoutLyrics.toString(),
              ),
              _CoverageChip(
                label: t('Unchecked'),
                count: coverage.unchecked.toString(),
              ),
            ],
          ),
        const Divider(height: 22, color: AppColors.border),
        _SettingRow(
          title: t('Save Cached Lyrics to Files'),
          subtitle: t(
              'Write cached lyrics to sidecar .lrc files or audio tags according to your save mode'),
          stackOnNarrow: true,
          trailing: OutlinedButton.icon(
            onPressed: _savingCachedLyrics ? null : _saveCachedLyrics,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.textPrimary,
              side: const BorderSide(color: AppColors.border),
            ),
            icon: _savingCachedLyrics
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_alt_rounded, size: 16),
            label: Text(
              _savingCachedLyrics
                  ? t('Saving...')
                  : t('Save cached lyrics to files'),
            ),
          ),
        ),
        const Divider(height: 20, color: AppColors.border),
        _SettingRow(
          title: t('Share Lyrics to LRCLIB'),
          subtitle: _describeShareStatus(currentTrack, shareStatus),
          stackOnNarrow: true,
          trailing: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (sharingBusy)
                OutlinedButton(
                  onPressed: ctrl.cancelLyricsShare,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.danger,
                    side: const BorderSide(color: AppColors.border),
                  ),
                  child: Text(t('Cancel')),
                ),
              FilledButton.icon(
                onPressed: sharingBusy || shareStatus?.available != true
                    ? null
                    : _shareLyrics,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: AppColors.canvas,
                ),
                icon: const Icon(Icons.cloud_upload_outlined, size: 16),
                label: Text(
                  sharingBusy
                      ? t('Sharing...')
                      : t('Share lyrics to LRCLIB'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _describeShareStatus(
    UiTrackInfo? currentTrack,
    UiLyricsShareStatus? status,
  ) {
    if (status?.outcome == 'published') {
      return t('Published current track lyrics to LRCLIB.');
    }
    if (status?.outcome == 'cancelled') {
      return t('Sharing cancelled.');
    }
    if (currentTrack == null) {
      return t('Play a local track with local lyrics to share it with LRCLIB.');
    }
    if (status == null) {
      return currentTrack.title;
    }
    if (status.available) {
      return t('Ready to share "{title}" to LRCLIB.', {
        'title': currentTrack.title,
      });
    }
    return switch (status.reason) {
      'noLocalLyrics' => t('No local lyrics found for "{title}".', {
          'title': currentTrack.title,
        }),
      'needsMetadata' =>
        t('Track needs title, artist, album, and duration metadata to share.'),
      'onLrclib' => t('Lyrics for "{title}" are already on LRCLIB.', {
          'title': currentTrack.title,
        }),
      'otherSource' => t('Only local .lrc or embedded lyrics can be shared.'),
      'offline' => t('Network access for lyrics is currently disabled.'),
      'busy' => t('Sharing lyrics to LRCLIB...'),
      _ => currentTrack.title,
    };
  }

  Widget _buildUpdatesSection(PlayerController ctrl) {
    final info = ctrl.updateInfo;
    final checking = ctrl.checkingUpdate;

    return _SettingsSection(
      title: t('Updates'),
      subtitle: info != null
          ? t('Current version: {v}', {'v': info.currentVersion})
          : t('Check GitHub releases for a newer version of NeoModern'),
      trailing: OutlinedButton.icon(
        onPressed: checking ? null : ctrl.checkForUpdate,
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.textPrimary,
          side: const BorderSide(color: AppColors.border),
        ),
        icon: checking
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.system_update_alt_rounded, size: 16),
        label: Text(checking ? t('Checking...') : t('Check for updates')),
      ),
      children: [
        if (info == null)
          Text(
            t('Click "Check for updates" to verify whether a new version is available.'),
            style: const TextStyle(
              fontSize: 12.5,
              color: AppColors.textSecondary,
            ),
          )
        else ...[
          Row(
            children: [
              Icon(
                info.updateAvailable
                    ? Icons.new_releases_rounded
                    : Icons.check_circle_outline_rounded,
                size: 18,
                color: info.updateAvailable
                    ? AppColors.accent
                    : const Color(0xFF30A46C),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  info.updateAvailable
                      ? t('Update available: {latest} (current {current})', {
                          'latest': info.version ?? t('new version'),
                          'current': info.currentVersion,
                        })
                      : t('You are up to date ({v}).', {
                          'v': info.currentVersion,
                        }),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          if (info.url != null && info.url!.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.canvas,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      info.url!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.accent,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: t('Copy URL'),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(
                      Icons.copy_rounded,
                      size: 16,
                      color: AppColors.textSecondary,
                    ),
                    onPressed: () =>
                        _copyToClipboard(info.url!, t('Release URL copied')),
                  ),
                ],
              ),
            ),
          ],
        ],
      ],
    );
  }

  ButtonStyle _segmentedButtonStyle() {
    return ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return AppColors.accentMuted;
        }
        return AppColors.canvas;
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return AppColors.accent;
        }
        return AppColors.textSecondary;
      }),
      side: WidgetStateProperty.all(
        const BorderSide(color: AppColors.border),
      ),
    );
  }

  String _formatSleepRemaining(Object endsAt) {
    final ms = (endsAt as dynamic).toInt() as int;
    final rem = DateTime.fromMillisecondsSinceEpoch(ms)
        .difference(DateTime.now());
    if (rem.isNegative) return 'Ending soon';
    final mins = rem.inMinutes;
    final secs = rem.inSeconds % 60;
    return '${mins}m ${secs.toString().padLeft(2, '0')}s left';
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.title,
    required this.children,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final titleColumn = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                ],
              );

              if (trailing == null) {
                return titleColumn;
              }
              if (constraints.maxWidth < 460) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    titleColumn,
                    const SizedBox(height: 10),
                    trailing!,
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: titleColumn),
                  const SizedBox(width: 12),
                  trailing!,
                ],
              );
            },
          ),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.stackOnNarrow = false,
  });

  final String title;
  final String subtitle;
  final Widget trailing;
  final bool stackOnNarrow;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final labelColumn = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        );

        if (stackOnNarrow && constraints.maxWidth < 460) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              labelColumn,
              const SizedBox(height: 10),
              trailing,
            ],
          );
        }

        return Row(
          children: [
            Expanded(child: labelColumn),
            const SizedBox(width: 16),
            trailing,
          ],
        );
      },
    );
  }
}

class _ToolBadge extends StatelessWidget {
  const _ToolBadge({
    required this.label,
    required this.available,
    required this.managed,
  });

  final String label;
  final bool available;
  final bool managed;

  @override
  Widget build(BuildContext context) {
    final color = available ? const Color(0xFF30A46C) : AppColors.textMuted;
    final suffix = available
        ? (managed ? ' · ${t('managed')}' : ' · ${t('ready')}')
        : ' · ${t('missing')}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: available
              ? const Color(0xFF30A46C).withAlpha(110)
              : AppColors.border,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            available
                ? Icons.check_circle_rounded
                : Icons.error_outline_rounded,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 6),
          Text(
            '$label$suffix',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: available ? AppColors.textPrimary : AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _DownloadJobCard extends StatelessWidget {
  const _DownloadJobCard({
    required this.job,
    required this.onCancel,
  });

  final UiDownloadJob job;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final isActive = job.state == 'queued' || job.state == 'downloading';
    final total = job.totalTracks;
    final fraction =
        total > 0 ? (job.doneTracks / total).clamp(0.0, 1.0) : null;
    final stateColor = switch (job.state) {
      'done' => const Color(0xFF30A46C),
      'failed' => AppColors.danger,
      'cancelled' => AppColors.textMuted,
      _ => AppColors.accent,
    };

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      job.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (job.artist.isNotEmpty)
                      Text(
                        job.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: AppColors.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  total > 1
                      ? '${job.state} (${job.doneTracks}/$total)'
                      : job.state,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: stateColor,
                  ),
                ),
              ),
              if (isActive) ...[
                const SizedBox(width: 4),
                IconButton(
                  tooltip: t('Cancel'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: AppColors.textSecondary,
                  ),
                  onPressed: onCancel,
                ),
              ],
            ],
          ),
          if (isActive) ...[
            if (job.currentTrack != null && job.currentTrack!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                job.currentTrack!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppColors.textMuted,
                ),
              ),
            ],
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: job.state == 'downloading' && total > 1 ? fraction : null,
              backgroundColor: AppColors.surface,
              color: AppColors.accent,
            ),
          ] else if (job.state == 'failed' &&
              job.error != null &&
              job.error!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              job.error!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, color: AppColors.danger),
            ),
          ],
        ],
      ),
    );
  }
}

class _CoverageChip extends StatelessWidget {
  const _CoverageChip({
    required this.label,
    required this.count,
    this.accent = false,
  });

  final String label;
  final String count;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: accent ? AppColors.accent.withAlpha(90) : AppColors.border,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            count,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: accent ? AppColors.accent : AppColors.textPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _SleepChip extends StatelessWidget {
  const _SleepChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      selectedColor: AppColors.accentMuted,
      backgroundColor: AppColors.canvas,
      side: BorderSide(
        color: selected ? AppColors.accent : AppColors.border,
      ),
      labelStyle: TextStyle(
        fontSize: 12.5,
        color: selected ? AppColors.accent : AppColors.textPrimary,
      ),
    );
  }
}

class _MissingFoldersBanner extends StatelessWidget {
  const _MissingFoldersBanner({
    required this.folders,
    required this.onMoveFolder,
  });

  final List<UiFolderInfo> folders;
  final ValueChanged<UiFolderInfo> onMoveFolder;

  @override
  Widget build(BuildContext context) {
    const amber = Color(0xFFE5A00D);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: amber.withAlpha(22),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: amber.withAlpha(90)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                size: 17,
                color: amber,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t('Music folders not found'),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            t(
              'One or more watched folders could not be found on disk. Move a folder to update its path without losing your stats or playlists.',
            ),
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < folders.length; i++) ...[
            if (i > 0) const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    folders[i].path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => onMoveFolder(folders[i]),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: amber,
                    side: BorderSide(color: amber.withAlpha(110)),
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.drive_file_move_outlined, size: 15),
                  label: Text(t('Move folder…')),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
