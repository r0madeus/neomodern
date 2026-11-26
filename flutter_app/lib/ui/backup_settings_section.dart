import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';

/// Formats a byte count into a human-readable string.
String formatBackupBytes(BigInt bytes) {
  final value = bytes.toDouble();
  if (value < 1024) return '${bytes.toInt()} B';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
  if (value < 1024 * 1024 * 1024) {
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// Formats a Unix millisecond timestamp as `YYYY-MM-DD HH:mm`.
String formatBackupTimestamp(int epochMs) {
  final dt = DateTime.fromMillisecondsSinceEpoch(epochMs).toLocal();
  final y = dt.year.toString().padLeft(4, '0');
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  final hh = dt.hour.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');
  return '$y-$m-$d $hh:$mm';
}

/// Builds the default backup filename for export dialogs.
String defaultBackupFileName([DateTime? now]) {
  final dt = now ?? DateTime.now();
  final y = dt.year.toString().padLeft(4, '0');
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  final hh = dt.hour.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');
  return 'NeoModern-backup-$y-$m-$d-$hh$mm.nmbackup';
}

typedef BackupExportCallback = Future<UiBackupExportResult> Function(
  String destPath,
);
typedef BackupInspectCallback = Future<UiBackupPreview> Function(
  String srcPath,
);
typedef BackupStageImportCallback = Future<UiBackupImportResult> Function(
  String srcPath,
);
typedef BackupAutoStatusCallback = Future<UiAutoBackupStatus> Function();
typedef BackupSetAutoCallback = Future<UiAutoBackupStatus> Function({
  required bool enabled,
  String? folder,
  required String cadence,
  required int keep,
});
typedef BackupRunAutoNowCallback = Future<UiAutoBackupStatus> Function();
typedef PickSaveBackupCallback = Future<String?> Function(String fileName);
typedef PickOpenBackupCallback = Future<String?> Function();
typedef PickBackupFolderCallback = Future<String?> Function();

/// Settings cards for manual backup export/import and desktop automatic backups.
class BackupSettingsSection extends StatefulWidget {
  const BackupSettingsSection({
    super.key,
    required this.controller,
    this.onExport,
    this.onInspect,
    this.onStageImport,
    this.onFetchAutoStatus,
    this.onSetAuto,
    this.onRunAutoNow,
    this.onPickSaveFile,
    this.onPickOpenFile,
    this.onPickFolder,
    this.onCloseApp,
  });

  final PlayerController controller;
  final BackupExportCallback? onExport;
  final BackupInspectCallback? onInspect;
  final BackupStageImportCallback? onStageImport;
  final BackupAutoStatusCallback? onFetchAutoStatus;
  final BackupSetAutoCallback? onSetAuto;
  final BackupRunAutoNowCallback? onRunAutoNow;
  final PickSaveBackupCallback? onPickSaveFile;
  final PickOpenBackupCallback? onPickOpenFile;
  final PickBackupFolderCallback? onPickFolder;
  final VoidCallback? onCloseApp;

  @override
  State<BackupSettingsSection> createState() => _BackupSettingsSectionState();
}

class _BackupSettingsSectionState extends State<BackupSettingsSection> {
  bool _exporting = false;
  bool _inspecting = false;
  bool _importing = false;
  bool _savingAuto = false;
  bool _runningAutoNow = false;
  String? _statusMessage;
  String? _errorMessage;
  String? _autoError;
  UiAutoBackupStatus? _autoStatusOverride;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.onFetchAutoStatus != null) {
        unawaited(_refreshAutoStatus());
        return;
      }
      if (!widget.controller.initialized) return;
      if (widget.controller.autoBackupStatus == null) {
        unawaited(_refreshAutoStatus());
      }
    });
  }

  UiAutoBackupStatus? get _effectiveAutoStatus =>
      _autoStatusOverride ?? widget.controller.autoBackupStatus;

  Future<void> _refreshAutoStatus() async {
    try {
      final status = await (widget.onFetchAutoStatus ??
          widget.controller.backupAutoStatus)();
      if (!mounted) return;
      setState(() {
        _autoStatusOverride = status;
        _autoError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _autoError = e.toString());
    }
  }

  Future<String?> _pickSavePath(String fileName) async {
    if (widget.onPickSaveFile != null) {
      return widget.onPickSaveFile!(fileName);
    }
    final uri = await FilePicker.saveFile(
      dialogTitle: t('Export backup'),
      fileName: fileName,
      bytes: Uint8List(0),
    );
    if (uri == null) return null;
    final destPath = uri.isScheme('file') ? uri.toFilePath() : uri.toString();
    return destPath.isEmpty ? null : destPath;
  }

  Future<String?> _pickOpenPath() async {
    if (widget.onPickOpenFile != null) {
      return widget.onPickOpenFile!();
    }
    final files = await FilePicker.pickFiles(
      dialogTitle: t('Select backup file'),
      type: FileType.custom,
      allowedExtensions: const ['nmbackup', 'zip'],
    );
    if (files.isEmpty) return null;
    final path = files.first.path;
    return (path == null || path.isEmpty) ? null : path;
  }

  Future<String?> _pickDirectoryPath() async {
    if (widget.onPickFolder != null) {
      return widget.onPickFolder!();
    }
    final uri = await FilePicker.pickDirectory(
      dialogTitle: t('Select backup folder'),
    );
    if (uri == null) return null;
    final path = uri.isScheme('file') ? uri.toFilePath() : uri.toString();
    return path.isEmpty ? null : path;
  }

  Future<void> _handleExport() async {
    if (_exporting || _inspecting || _importing) return;
    final destPath = await _pickSavePath(defaultBackupFileName());
    if (destPath == null || !mounted) return;

    setState(() {
      _exporting = true;
      _statusMessage = null;
      _errorMessage = null;
    });

    try {
      final exportFn = widget.onExport ?? widget.controller.backupExport;
      final result = await exportFn(destPath);
      if (!mounted) return;
      final message = t('Backup exported ({size}, {n} items)', {
        'size': formatBackupBytes(result.sizeBytes),
        'n': result.entryCount,
      });
      setState(() {
        _exporting = false;
        _statusMessage = message;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          width: 360,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _exporting = false;
        _errorMessage = e.toString();
      });
    }
  }

  Future<void> _handleImport() async {
    if (_exporting || _inspecting || _importing) return;
    final srcPath = await _pickOpenPath();
    if (srcPath == null || !mounted) return;

    setState(() {
      _inspecting = true;
      _statusMessage = null;
      _errorMessage = null;
    });

    try {
      final inspectFn = widget.onInspect ?? widget.controller.backupInspect;
      final preview = await inspectFn(srcPath);
      if (!mounted) return;
      setState(() => _inspecting = false);

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => _ImportPreviewDialog(preview: preview),
      );
      if (confirmed != true || !mounted) return;

      setState(() {
        _importing = true;
        _errorMessage = null;
      });
      final stageFn =
          widget.onStageImport ?? widget.controller.backupStageImport;
      final importResult = await stageFn(srcPath);
      if (!mounted) return;
      setState(() => _importing = false);

      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => _RestartRequiredDialog(
          safetyBackupDir: importResult.safetyBackupDir,
          onCloseApp: widget.onCloseApp ?? () => exit(0),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _inspecting = false;
        _importing = false;
        _errorMessage = e.toString();
      });
    }
  }

  Future<void> _updateAuto({
    required bool enabled,
    String? folder,
    required String cadence,
    required int keep,
  }) async {
    if (_savingAuto) return;
    setState(() {
      _savingAuto = true;
      _autoError = null;
    });
    try {
      final setter = widget.onSetAuto ?? widget.controller.backupSetAuto;
      final status = await setter(
        enabled: enabled,
        folder: folder,
        cadence: cadence,
        keep: keep,
      );
      if (!mounted) return;
      setState(() {
        _savingAuto = false;
        _autoStatusOverride = status;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _savingAuto = false;
        _autoError = e.toString();
      });
    }
  }

  Future<void> _toggleAutoEnabled(bool enabled) async {
    final current = _effectiveAutoStatus;
    var folder = current?.folder;
    final cadence = current?.cadence ?? 'daily';
    final keep = current?.keep ?? 5;

    if (enabled && (folder == null || folder.trim().isEmpty)) {
      final picked = await _pickDirectoryPath();
      if (!mounted) return;
      if (picked == null) {
        setState(() {
          _autoError =
              t('Choose a target folder first to enable automatic backups.');
        });
        return;
      }
      folder = picked;
    }

    await _updateAuto(
      enabled: enabled,
      folder: folder,
      cadence: cadence,
      keep: keep,
    );
  }

  Future<void> _pickAutoFolder() async {
    final picked = await _pickDirectoryPath();
    if (picked == null || !mounted) return;
    final current = _effectiveAutoStatus;
    await _updateAuto(
      enabled: current?.enabled ?? false,
      folder: picked,
      cadence: current?.cadence ?? 'daily',
      keep: current?.keep ?? 5,
    );
  }

  Future<void> _runAutoNow() async {
    if (_runningAutoNow || _savingAuto) return;
    setState(() {
      _runningAutoNow = true;
      _autoError = null;
    });
    try {
      final runFn = widget.onRunAutoNow ?? widget.controller.backupRunAutoNow;
      final status = await runFn();
      if (!mounted) return;
      setState(() {
        _runningAutoNow = false;
        _autoStatusOverride = status;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _runningAutoNow = false;
        _autoError = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final auto = _effectiveAutoStatus;
    final autoEnabled = auto?.enabled ?? false;
    final autoFolder = auto?.folder;
    final autoCadence =
        (auto?.cadence == 'weekly') ? 'weekly' : 'daily';
    final autoKeep =
        const {3, 5, 10}.contains(auto?.keep) ? auto!.keep : 5;
    final manualBusy = _exporting || _inspecting || _importing;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BackupCard(
          title: t('Backup & Restore'),
          subtitle: t(
            'Export or restore your profiles, favorites, playlists, history, settings, and artwork. Music files are not included.',
          ),
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: manualBusy ? null : _handleExport,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.accent500,
                    foregroundColor: AppColors.canvas,
                  ),
                  icon: _exporting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.canvas,
                          ),
                        )
                      : const Icon(Icons.upload_file_rounded, size: 17),
                  label: Text(
                    _exporting ? t('Exporting...') : t('Export backup'),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: manualBusy ? null : _handleImport,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textPrimary,
                    side: const BorderSide(color: AppTheme.zinc800),
                  ),
                  icon: (_inspecting || _importing)
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.restore_rounded, size: 17),
                  label: Text(
                    _importing
                        ? t('Importing...')
                        : _inspecting
                            ? t('Inspecting...')
                            : t('Import backup…'),
                  ),
                ),
              ],
            ),
            if (_statusMessage != null) ...[
              const SizedBox(height: 12),
              _StatusBanner(
                message: _statusMessage!,
                isError: false,
              ),
            ],
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              _StatusBanner(
                message: _errorMessage!,
                isError: true,
              ),
            ],
          ],
        ),
        if (!Platform.isAndroid) ...[
          const SizedBox(height: 20),
          _BackupCard(
            title: t('Automatic backup'),
            subtitle: t(
              'Periodically save a backup to a local or cloud-synced folder',
            ),
            trailing: Switch(
              value: autoEnabled,
              onChanged: _savingAuto ? null : _toggleAutoEnabled,
            ),
            children: [
              _BackupRow(
                title: t('Target folder'),
                subtitle: (autoFolder != null && autoFolder.isNotEmpty)
                    ? autoFolder
                    : t('No folder selected'),
                stackOnNarrow: true,
                trailing: OutlinedButton.icon(
                  onPressed: _savingAuto ? null : _pickAutoFolder,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textPrimary,
                    side: const BorderSide(color: AppTheme.zinc800),
                  ),
                  icon: const Icon(Icons.folder_open_rounded, size: 16),
                  label: Text(t('Choose…')),
                ),
              ),
              const Divider(height: 20, color: AppTheme.zinc800),
              _BackupRow(
                title: t('Cadence'),
                subtitle: t('How often automatic backups run when due'),
                stackOnNarrow: true,
                trailing: SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(value: 'daily', label: Text(t('Daily'))),
                    ButtonSegment(value: 'weekly', label: Text(t('Weekly'))),
                  ],
                  selected: {autoCadence},
                  onSelectionChanged: _savingAuto
                      ? null
                      : (sel) => _updateAuto(
                            enabled: autoEnabled,
                            folder: autoFolder,
                            cadence: sel.first,
                            keep: autoKeep,
                          ),
                  style: _segmentedButtonStyle(),
                ),
              ),
              const Divider(height: 20, color: AppTheme.zinc800),
              _BackupRow(
                title: t('Keep backups'),
                subtitle: t('Oldest automatic backups beyond this count are removed'),
                stackOnNarrow: true,
                trailing: SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 3, label: Text('3')),
                    ButtonSegment(value: 5, label: Text('5')),
                    ButtonSegment(value: 10, label: Text('10')),
                  ],
                  selected: {autoKeep},
                  onSelectionChanged: _savingAuto
                      ? null
                      : (sel) => _updateAuto(
                            enabled: autoEnabled,
                            folder: autoFolder,
                            cadence: autoCadence,
                            keep: sel.first,
                          ),
                  style: _segmentedButtonStyle(),
                ),
              ),
              const Divider(height: 20, color: AppTheme.zinc800),
              LayoutBuilder(
                builder: (context, constraints) {
                  final statusWidget = _buildAutoStatusLine(auto);
                  final actionBtn = OutlinedButton.icon(
                    onPressed: (_runningAutoNow ||
                            _savingAuto ||
                            autoFolder == null ||
                            autoFolder.isEmpty)
                        ? null
                        : _runAutoNow,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.textPrimary,
                      side: const BorderSide(color: AppTheme.zinc800),
                    ),
                    icon: _runningAutoNow
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.backup_rounded, size: 16),
                    label: Text(
                      _runningAutoNow
                          ? t('Backing up...')
                          : t('Back up now'),
                    ),
                  );

                  if (constraints.maxWidth < 460) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        statusWidget,
                        const SizedBox(height: 10),
                        actionBtn,
                      ],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: statusWidget),
                      const SizedBox(width: 12),
                      actionBtn,
                    ],
                  );
                },
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildAutoStatusLine(UiAutoBackupStatus? auto) {
    final err = _autoError ?? auto?.lastError;
    if (err != null && err.isNotEmpty) {
      return Text(
        err,
        style: const TextStyle(fontSize: 12.5, color: AppColors.danger),
      );
    }
    if (auto?.lastBackupAt != null) {
      final formattedTime = formatBackupTimestamp(auto!.lastBackupAt!.toInt());
      final formattedSize =
          formatBackupBytes(auto.lastBackupSize ?? BigInt.zero);
      return Text(
        t('Last backup: {time} ({size})', {
          'time': formattedTime,
          'size': formattedSize,
        }),
        style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
      );
    }
    return Text(
      t('No automatic backup run yet.'),
      style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted),
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
          return AppTheme.accent500;
        }
        return AppColors.textSecondary;
      }),
      side: WidgetStateProperty.all(
        const BorderSide(color: AppTheme.zinc800),
      ),
    );
  }
}

class _ImportPreviewDialog extends StatelessWidget {
  const _ImportPreviewDialog({required this.preview});

  final UiBackupPreview preview;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.zinc900,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppTheme.zinc800),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.restore_rounded,
                    size: 20,
                    color: AppTheme.accent500,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      t('Restore Backup'),
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.canvas,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.zinc800),
                ),
                child: Column(
                  children: [
                    _MetaLine(
                      label: t('Created at'),
                      value: formatBackupTimestamp(preview.createdAt.toInt()),
                    ),
                    const SizedBox(height: 6),
                    _MetaLine(
                      label: t('App version'),
                      value: preview.appVersion,
                    ),
                    const SizedBox(height: 6),
                    _MetaLine(
                      label: t('Source platform'),
                      value: preview.sourcePlatform,
                    ),
                    const SizedBox(height: 6),
                    _MetaLine(
                      label: t('File size'),
                      value: formatBackupBytes(preview.sizeBytes),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _CountBadge(
                    label: t('Profiles'),
                    count: '${preview.profilesCount}',
                  ),
                  _CountBadge(
                    label: t('Tracks'),
                    count: '${preview.tracksCount}',
                  ),
                  _CountBadge(
                    label: t('Playlists'),
                    count: '${preview.playlistsCount}',
                  ),
                  _CountBadge(
                    label: t('Listening events'),
                    count: '${preview.listensCount}',
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.danger.withAlpha(26),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.danger.withAlpha(90)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: AppColors.danger,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        t(
                          'Replace all data on this device? Your current data will be copied to a safety backup first.',
                        ),
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(t('Cancel')),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.danger,
                      foregroundColor: Colors.white,
                    ),
                    child: Text(
                      t('Replace & Import'),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RestartRequiredDialog extends StatelessWidget {
  const _RestartRequiredDialog({
    required this.safetyBackupDir,
    required this.onCloseApp,
  });

  final String safetyBackupDir;
  final VoidCallback onCloseApp;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.zinc900,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppTheme.zinc800),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.check_circle_rounded,
                    size: 20,
                    color: Color(0xFF30A46C),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      t('Import staged'),
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                t('Import staged. Restart NeoModern to apply.'),
                style: const TextStyle(
                  fontSize: 13.5,
                  color: AppColors.textPrimary,
                ),
              ),
              if (safetyBackupDir.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  t('Safety backup saved to: {path}', {
                    'path': safetyBackupDir,
                  }),
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(t('Later')),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: onCloseApp,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.accent500,
                      foregroundColor: AppColors.canvas,
                    ),
                    child: Text(
                      t('Close app'),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
            color: AppColors.textPrimary,
          ),
        ),
      ],
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.label, required this.count});

  final String label;
  final String count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.zinc800),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            count,
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: AppTheme.accent500,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final color = isError ? AppColors.danger : const Color(0xFF30A46C);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withAlpha(24),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(90)),
      ),
      child: Text(
        message,
        style: TextStyle(
          fontSize: 12.5,
          color: isError ? AppColors.danger : AppColors.textPrimary,
        ),
      ),
    );
  }
}

class _BackupCard extends StatelessWidget {
  const _BackupCard({
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
        color: AppTheme.zinc900,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.zinc800),
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
              ),
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

class _BackupRow extends StatelessWidget {
  const _BackupRow({
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
