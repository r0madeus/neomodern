import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';

class QrMatrixView extends StatelessWidget {
  const QrMatrixView({
    super.key,
    required this.matrix,
    required this.qrSize,
    this.displaySize = 152,
  });

  final List<bool> matrix;
  final int qrSize;
  final double displaySize;

  @override
  Widget build(BuildContext context) {
    if (qrSize <= 0 || matrix.length < qrSize * qrSize) {
      return const SizedBox.shrink();
    }
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
      ),
      child: CustomPaint(
        size: Size.square(displaySize),
        painter: _QrPainter(matrix: matrix, qrSize: qrSize),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  const _QrPainter({required this.matrix, required this.qrSize});

  final List<bool> matrix;
  final int qrSize;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = Colors.white;
    canvas.drawRect(Offset.zero & size, bg);

    final fg = Paint()..color = const Color(0xFF0D0F14);
    final cell = size.width / qrSize;
    for (var y = 0; y < qrSize; y++) {
      for (var x = 0; x < qrSize; x++) {
        if (matrix[y * qrSize + x]) {
          canvas.drawRect(
            Rect.fromLTWH(x * cell, y * cell, cell + 0.35, cell + 0.35),
            fg,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter oldDelegate) {
    return oldDelegate.qrSize != qrSize || oldDelegate.matrix != matrix;
  }
}

class SyncSettingsSection extends StatefulWidget {
  const SyncSettingsSection({super.key, required this.controller});

  final PlayerController controller;

  @override
  State<SyncSettingsSection> createState() => _SyncSettingsSectionState();
}

class _SyncSettingsSectionState extends State<SyncSettingsSection> {
  final TextEditingController _deviceNameCtrl = TextEditingController();
  String? _seededDeviceName;
  String? _deviceNameError;
  bool _savingName = false;

  @override
  void dispose() {
    _deviceNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveDeviceName() async {
    final name = _deviceNameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _deviceNameError = 'Device name must not be empty.');
      return;
    }
    setState(() {
      _savingName = true;
      _deviceNameError = null;
    });
    final err = await widget.controller.setDeviceName(name);
    if (!mounted) return;
    setState(() {
      _savingName = false;
      _deviceNameError = err;
      if (err == null) {
        _seededDeviceName = name;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final sync = ctrl.syncStatus;
    final pairing = ctrl.pairingOpen;
    final party = ctrl.partyStatus;

    if (sync != null && _seededDeviceName != sync.deviceName) {
      _seededDeviceName = sync.deviceName;
      _deviceNameCtrl.text = sync.deviceName;
    }

    final allowPhones = sync?.allowPhoneConnections ?? false;
    final peers = sync?.peers ?? const <UiPeerStatus>[];
    final partyEnabled = party?.enabled ?? false;
    final partyRunning = party?.running ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionCard(
          title: t('Phone Sync & Remote Control'),
          subtitle: allowPhones && sync?.listeningPort != null
              ? 'Listening on port ${sync!.listeningPort}'
              : 'LAN-only encrypted sync and remote control',
          trailing: sync != null && peers.isNotEmpty
              ? OutlinedButton.icon(
                  onPressed: ctrl.triggerSyncNow,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textPrimary,
                    side: const BorderSide(color: AppColors.border),
                  ),
                  icon: const Icon(Icons.sync_rounded, size: 16),
                  label: const Text('Sync Now'),
                )
              : null,
          children: [
            _RowToggle(
              title: 'Allow phone connections',
              subtitle:
                  'Listen on your local network so paired phones can sync and control playback',
              value: allowPhones,
              onChanged: ctrl.setAllowPhoneConnections,
            ),
            const Divider(height: 22, color: AppColors.border),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _deviceNameCtrl,
                    enabled: !_savingName,
                    decoration: const InputDecoration(
                      labelText: 'Device name',
                      hintText: 'My Computer',
                    ),
                    onSubmitted: (_) => _saveDeviceName(),
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton(
                  onPressed: _savingName ? null : _saveDeviceName,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textPrimary,
                    side: const BorderSide(color: AppColors.border),
                  ),
                  child: const Text('Save'),
                ),
              ],
            ),
            if (_deviceNameError != null) ...[
              const SizedBox(height: 6),
              Text(
                _deviceNameError!,
                style: const TextStyle(fontSize: 12, color: AppColors.danger),
              ),
            ],
            if (allowPhones) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: ctrl.openPairing,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: AppColors.canvas,
                    ),
                    icon: const Icon(Icons.qr_code_rounded, size: 17),
                    label: Text(
                      pairing != null ? 'Refresh Pairing Code' : 'Pair Phone',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (pairing != null) ...[
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: ctrl.closePairing,
                      child: const Text('Close'),
                    ),
                  ],
                  const Spacer(),
                  if (sync != null && sync.listeningAddresses.isNotEmpty)
                    Flexible(
                      child: Text(
                        '${sync.listeningAddresses.join(', ')}:${sync.listeningPort ?? 47321}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
                ],
              ),
              if (pairing != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.canvas,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (pairing.qrMatrix.isNotEmpty && pairing.qrSize > 0)
                        QrMatrixView(
                          matrix: pairing.qrMatrix,
                          qrSize: pairing.qrSize,
                        ),
                      if (pairing.qrMatrix.isNotEmpty && pairing.qrSize > 0)
                        const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'PAIRING CODE',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.9,
                                color: AppColors.textMuted,
                              ),
                            ),
                            const SizedBox(height: 4),
                            SelectableText(
                              _formatPinCode(pairing.code),
                              style: const TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 3,
                                color: AppColors.accent,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Profile: ${pairing.profileName} · Expires in ${pairing.remainingSecs}s',
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppColors.textSecondary,
                              ),
                            ),
                            if (pairing.addresses.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                'LAN: ${pairing.addresses.map((a) => '$a:${pairing.port}').join(', ')}',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
            const SizedBox(height: 16),
            const Text(
              'PAIRED DEVICES',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.9,
                color: AppColors.textMuted,
              ),
            ),
            const SizedBox(height: 8),
            if (peers.isEmpty)
              const Text(
                'No paired devices yet.',
                style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
              )
            else
              for (var i = 0; i < peers.length; i++) ...[
                if (i > 0) const Divider(height: 12, color: AppColors.border),
                _PeerRow(
                  peer: peers[i],
                  onRemove: () => ctrl.removeSyncPeer(peers[i].id),
                ),
              ],
          ],
        ),
        const SizedBox(height: 20),
        _SectionCard(
          title: t('Experimental — Party Queue'),
          subtitle: partyRunning
              ? 'Session active (${party?.guests.length ?? 0} guests)'
              : 'Let guests on your local network add tracks to the queue',
          trailing: Switch(
            value: partyEnabled,
            onChanged: ctrl.setPartyEnabled,
          ),
          children: [
            if (!partyEnabled)
              Text(
                t('Disabled by default. Turn on to host a local Party Queue session.'),
                style: const TextStyle(
                    fontSize: 12.5, color: AppColors.textSecondary),
              )
            else if (!partyRunning) ...[
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Start a local Party Queue so nearby devices can scan or enter a join code to append tracks.',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: ctrl.startParty,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: AppColors.canvas,
                    ),
                    icon: const Icon(Icons.group_add_rounded, size: 17),
                    label: const Text(
                      'Start Session',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ] else ...[
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.canvas,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.border),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (party != null &&
                        party.qrMatrix.isNotEmpty &&
                        party.qrSize > 0) ...[
                      QrMatrixView(
                        matrix: party.qrMatrix,
                        qrSize: party.qrSize,
                      ),
                      const SizedBox(width: 16),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'JOIN CODE',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.9,
                              color: AppColors.textMuted,
                            ),
                          ),
                          const SizedBox(height: 4),
                          SelectableText(
                            _formatPinCode(party?.code ?? '------'),
                            style: const TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 3,
                              color: AppColors.accent,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                          if (party != null && party.addresses.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              'LAN: ${party.addresses.join(', ')}',
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: AppColors.textMuted,
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton.icon(
                                onPressed: ctrl.newPartyCode,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: AppColors.textPrimary,
                                  side: const BorderSide(color: AppColors.border),
                                ),
                                icon: const Icon(Icons.refresh_rounded, size: 16),
                                label: const Text('New Code'),
                              ),
                              FilledButton.icon(
                                onPressed: ctrl.endParty,
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppColors.danger,
                                  foregroundColor: Colors.white,
                                ),
                                icon: const Icon(Icons.stop_rounded, size: 16),
                                label: const Text('End Session'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'GUESTS',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.9,
                  color: AppColors.textMuted,
                ),
              ),
              const SizedBox(height: 6),
              if (party == null || party.guests.isEmpty)
                const Text(
                  'No guests have joined yet.',
                  style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
                )
              else
                for (final g in party.guests)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: g.connected
                                ? const Color(0xFF30A46C)
                                : AppColors.textMuted,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            g.name,
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                        Text(
                          '${g.added} added',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: () => ctrl.removePartyGuest(g.id),
                          child: const Text(
                            'Remove',
                            style: TextStyle(color: AppColors.danger),
                          ),
                        ),
                      ],
                    ),
                  ),
              if (party != null && party.recent.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  'RECENT GUEST ADDITIONS',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.9,
                    color: AppColors.textMuted,
                  ),
                ),
                const SizedBox(height: 6),
                for (final item in party.recent)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      '${item.title} — ${item.artist} (by ${item.addedBy})',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
              ],
            ],
          ],
        ),
      ],
    );
  }

  String _formatPinCode(String code) {
    if (code.length == 6) {
      return '${code.substring(0, 3)} ${code.substring(3)}';
    }
    return code;
  }
}

class _PeerRow extends StatelessWidget {
  const _PeerRow({required this.peer, required this.onRemove});

  final UiPeerStatus peer;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          peer.kind == 'phone'
              ? Icons.smartphone_rounded
              : Icons.computer_rounded,
          size: 18,
          color: peer.connected ? AppColors.accent : AppColors.textMuted,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      peer.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    peer.syncing
                        ? 'Syncing...'
                        : (peer.connected ? 'Connected' : 'Offline'),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: peer.connected
                          ? const Color(0xFF30A46C)
                          : AppColors.textMuted,
                    ),
                  ),
                ],
              ),
              Text(
                'Profile: ${peer.profileName} · ${peer.rounds} rounds',
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppColors.textSecondary,
                ),
              ),
              if (peer.lastError != null)
                Text(
                  peer.lastError!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppColors.danger,
                  ),
                ),
            ],
          ),
        ),
        TextButton(
          onPressed: onRemove,
          child: const Text(
            'Remove',
            style: TextStyle(color: AppColors.danger),
          ),
        ),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
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

class _RowToggle extends StatelessWidget {
  const _RowToggle({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

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
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}
