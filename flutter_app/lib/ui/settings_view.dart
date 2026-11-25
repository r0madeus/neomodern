import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/sources_view.dart';
import 'package:neomodern/ui/sync_settings_section.dart';

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

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final snap = ctrl.snapshot;
    final folders = ctrl.folders;
    final eqGains = _gainsDraft ??
        List<double>.generate(
          10,
          (i) => i < snap.eqGainsDb.length ? snap.eqGainsDb[i] : 0.0,
        );
    final preamp = _preampDraft ?? snap.eqPreampDb;
    final crossfade = _crossfadeDraft ?? snap.crossfadeSeconds;

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 36),
      children: [
        Text(t('Settings'), style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 2),
        Text(
          t('Audio playback, watched folders, and offline privacy'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 24),

        // Language Section
        _SettingsSection(
          title: t('Language'),
          children: [
            _SettingRow(
              title: t('Language'),
              subtitle: t('Choose the interface language'),
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

        // Network Section
        _SettingsSection(
          title: t('Network'),
          children: [
            _SettingRow(
              title: t('Offline Mode'),
              subtitle: t(
                  'Block all network requests (online lyrics lookups remain disabled)'),
              trailing: Switch(
                value: ctrl.offlineMode,
                onChanged: ctrl.setOfflineMode,
              ),
            ),
          ],
        ),

        const SizedBox(height: 20),

        SyncSettingsSection(controller: ctrl),

        const SizedBox(height: 20),

        ExternalSourcesSettingsSection(controller: ctrl),
      ],
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
          Row(
            children: [
              Column(
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
              ),
              const Spacer(),
              ?trailing,
            ],
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
  });

  final String title;
  final String subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
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
          ),
        ),
        const SizedBox(width: 16),
        trailing,
      ],
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
