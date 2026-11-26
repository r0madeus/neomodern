import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';

Color parseProfileColor(String hex) {
  final cleaned = hex.trim().replaceFirst('#', '');
  if (cleaned.length == 6) {
    final value = int.tryParse('FF$cleaned', radix: 16);
    if (value != null) return Color(value);
  }
  return AppColors.accent;
}

class ProfileBadgeButton extends StatelessWidget {
  const ProfileBadgeButton({
    super.key,
    required this.controller,
    required this.onTap,
  });

  final PlayerController controller;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final active = controller.activeProfile;
    final name = active?.name ?? 'Profile';
    final dotColor =
        active != null ? parseProfileColor(active.color) : AppColors.accent;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          hoverColor: AppColors.surfaceHover,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: dotColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                if (active?.hasPin == true) ...[
                  const Icon(
                    Icons.lock_outline_rounded,
                    size: 13.5,
                    color: AppColors.textMuted,
                  ),
                  const SizedBox(width: 6),
                ],
                const Icon(
                  Icons.swap_horiz_rounded,
                  size: 16,
                  color: AppColors.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showProfilesDialog(
  BuildContext context,
  PlayerController controller,
) {
  return showDialog<void>(
    context: context,
    builder: (context) => ProfilesDialog(controller: controller),
  );
}

class ProfilesDialog extends StatefulWidget {
  const ProfilesDialog({super.key, required this.controller});

  final PlayerController controller;

  @override
  State<ProfilesDialog> createState() => _ProfilesDialogState();
}

class _ProfilesDialogState extends State<ProfilesDialog> {
  final TextEditingController _newNameCtrl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _newNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _createProfile() async {
    final name = _newNameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a profile name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await widget.controller.createProfile(name);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
      if (err == null) {
        _newNameCtrl.clear();
      }
    });
  }

  Future<void> _switchTo(UiProfile profile) async {
    String? pin;
    if (profile.hasPin) {
      pin = await _promptForPin(
        context,
        title: 'Enter PIN for ${profile.name}',
        confirmLabel: 'Switch',
      );
      if (pin == null || !mounted) return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await widget.controller.switchProfile(profile.id, pin: pin);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _error = err;
      });
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _renameProfile(UiProfile profile) async {
    final ctrl = TextEditingController(text: profile.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Rename Profile'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Profile name'),
          onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (newName == null || newName.isEmpty || newName == profile.name) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await widget.controller.renameProfile(profile.id, newName);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  Future<void> _managePin(UiProfile profile) async {
    final result = await _showPinManageDialog(context, profile);
    if (result == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await widget.controller.setProfilePin(
      profile.id,
      result.clearPin ? null : result.pin,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  Future<void> _deleteProfile(UiProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Delete Profile'),
        content: Text(
          'Delete "${profile.name}" and its favorites, playlists, and listening history?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await widget.controller.deleteProfile(profile.id);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final state = widget.controller.profilesState;
        final profiles = state?.profiles ?? const <UiProfile>[];
        final activeId = state?.active;
        final maxProfiles = state?.maxProfiles ?? 8;
        final canCreate = profiles.length < maxProfiles;

        return Dialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: AppColors.border),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460, maxHeight: 580),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Text(
                        'Profiles',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Each profile keeps its own queue, favorites, playlists, and listening history.',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.danger.withAlpha(32),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: AppColors.danger.withAlpha(90),
                        ),
                      ),
                      child: Text(
                        _error!,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: AppColors.danger,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: profiles.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 6),
                      itemBuilder: (context, index) {
                        final p = profiles[index];
                        final isActive = p.id == activeId;
                        final color = parseProfileColor(p.color);
                        return Container(
                          decoration: BoxDecoration(
                            color: isActive
                                ? AppColors.accentMuted
                                : AppColors.canvas,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isActive
                                  ? AppColors.accent
                                  : AppColors.border,
                            ),
                          ),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: _busy || isActive ? null : () => _switchTo(p),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 12,
                                    height: 12,
                                    decoration: BoxDecoration(
                                      color: color,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Flexible(
                                              child: Text(
                                                p.name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 13.5,
                                                  fontWeight: FontWeight.w600,
                                                  color: AppColors.textPrimary,
                                                ),
                                              ),
                                            ),
                                            if (isActive) ...[
                                              const SizedBox(width: 8),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 6,
                                                      vertical: 2,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: AppColors.accentMuted,
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                ),
                                                child: const Text(
                                                  'Active',
                                                  style: TextStyle(
                                                    fontSize: 10.5,
                                                    fontWeight: FontWeight.w600,
                                                    color: AppColors.accent,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                        if (p.hasPin)
                                          const Text(
                                            'PIN protected',
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: AppColors.textMuted,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Rename',
                                    visualDensity: VisualDensity.compact,
                                    icon: const Icon(
                                      Icons.edit_outlined,
                                      size: 16,
                                      color: AppColors.textSecondary,
                                    ),
                                    onPressed:
                                        _busy ? null : () => _renameProfile(p),
                                  ),
                                  IconButton(
                                    tooltip: p.hasPin ? 'Change / Clear PIN' : 'Set PIN',
                                    visualDensity: VisualDensity.compact,
                                    icon: Icon(
                                      p.hasPin
                                          ? Icons.lock_rounded
                                          : Icons.lock_open_rounded,
                                      size: 16,
                                      color: p.hasPin
                                          ? AppColors.accent
                                          : AppColors.textSecondary,
                                    ),
                                    onPressed:
                                        _busy ? null : () => _managePin(p),
                                  ),
                                  IconButton(
                                    tooltip: isActive
                                        ? 'Switch away before deleting'
                                        : 'Delete profile',
                                    visualDensity: VisualDensity.compact,
                                    icon: Icon(
                                      Icons.delete_outline_rounded,
                                      size: 16,
                                      color: isActive || profiles.length <= 1
                                          ? AppColors.textMuted
                                          : AppColors.textSecondary,
                                    ),
                                    onPressed: _busy ||
                                            isActive ||
                                            profiles.length <= 1
                                        ? null
                                        : () => _deleteProfile(p),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Divider(height: 1, color: AppColors.border),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _newNameCtrl,
                          enabled: canCreate && !_busy,
                          decoration: InputDecoration(
                            hintText: canCreate
                                ? 'New profile name'
                                : 'Maximum of $maxProfiles profiles reached',
                          ),
                          onSubmitted: (_) {
                            if (canCreate && !_busy) {
                              _createProfile();
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed:
                            canCreate && !_busy ? _createProfile : null,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: AppColors.canvas,
                        ),
                        icon: const Icon(Icons.person_add_rounded, size: 16),
                        label: const Text('Add'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

Future<String?> _promptForPin(
  BuildContext context, {
  required String title,
  required String confirmLabel,
}) async {
  final ctrl = TextEditingController();
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        obscureText: true,
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(8),
        ],
        decoration: const InputDecoration(hintText: '4 to 8 digits'),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(ctrl.text),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  ctrl.dispose();
  return result;
}

class _PinDialogResult {
  const _PinDialogResult({this.pin, this.clearPin = false});
  final String? pin;
  final bool clearPin;
}

Future<_PinDialogResult?> _showPinManageDialog(
  BuildContext context,
  UiProfile profile,
) async {
  final ctrl = TextEditingController();
  String? validation;
  final result = await showDialog<_PinDialogResult>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(profile.hasPin ? 'Manage PIN (${profile.name})' : 'Set PIN (${profile.name})'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(8),
              ],
              decoration: const InputDecoration(
                hintText: 'Enter 4–8 digit PIN',
              ),
            ),
            if (validation != null) ...[
              const SizedBox(height: 8),
              Text(
                validation!,
                style: const TextStyle(fontSize: 12, color: AppColors.danger),
              ),
            ],
          ],
        ),
        actions: [
          if (profile.hasPin)
            TextButton(
              onPressed: () => Navigator.of(context).pop(
                const _PinDialogResult(clearPin: true),
              ),
              child: const Text(
                'Remove PIN',
                style: TextStyle(color: AppColors.danger),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final pin = ctrl.text.trim();
              if (pin.length < 4 || pin.length > 8) {
                setState(() => validation = 'PIN must be 4 to 8 digits.');
                return;
              }
              Navigator.of(context).pop(_PinDialogResult(pin: pin));
            },
            child: const Text('Save PIN'),
          ),
        ],
      ),
    ),
  );
  ctrl.dispose();
  return result;
}

class ProfileLockOverlay extends StatefulWidget {
  const ProfileLockOverlay({super.key, required this.controller});

  final PlayerController controller;

  @override
  State<ProfileLockOverlay> createState() => _ProfileLockOverlayState();
}

class _ProfileLockOverlayState extends State<ProfileLockOverlay> {
  final TextEditingController _pinCtrl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pinCtrl.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    final pin = _pinCtrl.text.trim();
    if (pin.isEmpty) {
      setState(() => _error = 'Enter your PIN.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await widget.controller.unlockActiveProfile(pin);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
      if (err == null) {
        _pinCtrl.clear();
      }
    });
  }

  Future<void> _switchProfile(UiProfile profile) async {
    String? pin;
    if (profile.hasPin) {
      pin = await _promptForPin(
        context,
        title: 'Enter PIN for ${profile.name}',
        confirmLabel: 'Switch',
      );
      if (pin == null || !mounted) return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await widget.controller.switchProfile(profile.id, pin: pin);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
      if (err == null) {
        _pinCtrl.clear();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.controller.activeProfile;
    final profiles = widget.controller.profilesState?.profiles ?? const [];
    final others = profiles.where((p) => p.id != active?.id).toList();
    final dotColor =
        active != null ? parseProfileColor(active.color) : AppColors.accent;

    return Positioned.fill(
      child: Material(
        color: AppColors.canvas.withAlpha(246),
        child: Center(
          child: Container(
            width: 380,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: dotColor.withAlpha(36),
                      shape: BoxShape.circle,
                      border: Border.all(color: dotColor),
                    ),
                    child: Icon(Icons.lock_rounded, color: dotColor, size: 22),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  active?.name ?? 'Locked Profile',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Enter PIN to unlock this profile',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _pinCtrl,
                  autofocus: true,
                  obscureText: true,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(8),
                  ],
                  decoration: const InputDecoration(hintText: 'PIN (4–8 digits)'),
                  onSubmitted: (_) {
                    if (!_busy) _unlock();
                  },
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.danger,
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                FilledButton(
                  onPressed: _busy ? null : _unlock,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: AppColors.canvas,
                  ),
                  child: const Text(
                    'Unlock',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (others.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  const Divider(height: 1, color: AppColors.border),
                  const SizedBox(height: 12),
                  const Text(
                    'Or switch profile',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final p in others)
                        OutlinedButton.icon(
                          onPressed: _busy ? null : () => _switchProfile(p),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.textPrimary,
                            side: const BorderSide(color: AppColors.border),
                          ),
                          icon: Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: parseProfileColor(p.color),
                              shape: BoxShape.circle,
                            ),
                          ),
                          label: Text(p.name),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
