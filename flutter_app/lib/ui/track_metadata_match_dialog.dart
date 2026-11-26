import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';

Future<bool?> showTrackMetadataMatchDialog(
  BuildContext context,
  PlayerController controller,
  UiTrackRow track,
) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => TrackMetadataMatchDialog(
      controller: controller,
      track: track,
    ),
  );
}

class TrackMetadataMatchDialog extends StatefulWidget {
  const TrackMetadataMatchDialog({
    super.key,
    required this.controller,
    required this.track,
  });

  final PlayerController controller;
  final UiTrackRow track;

  @override
  State<TrackMetadataMatchDialog> createState() =>
      _TrackMetadataMatchDialogState();
}

class _TrackMetadataMatchDialogState extends State<TrackMetadataMatchDialog> {
  bool _loading = true;
  bool _applying = false;
  String? _error;
  List<UiTrackMatchCandidate> _candidates = const [];
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final candidates =
          await widget.controller.matchTrackMetadata(widget.track.id);
      if (!mounted) return;
      setState(() {
        _candidates = candidates;
        _selectedIndex = 0;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _apply() async {
    if (_candidates.isEmpty || _selectedIndex >= _candidates.length) return;
    final selected = _candidates[_selectedIndex];
    setState(() {
      _applying = true;
      _error = null;
    });
    try {
      final updated = await widget.controller.applyTrackMetadata(
        widget.track.id,
        selected.candidateId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t('Applied metadata to {n} tracks', {'n': updated})),
          behavior: SnackBarBehavior.floating,
          width: 320,
        ),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _applying = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected =
        _candidates.isNotEmpty && _selectedIndex < _candidates.length
            ? _candidates[_selectedIndex]
            : null;
    final subtitleParts = [
      widget.track.title,
      if (widget.track.artist.isNotEmpty) widget.track.artist,
      if (widget.track.album.isNotEmpty) widget.track.album,
    ];

    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 600),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.manage_search_rounded,
                    size: 20,
                    color: AppColors.accent,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t('Match Track Metadata'),
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        Text(
                          subtitleParts.join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed:
                        _applying ? null : () => Navigator.of(context).pop(),
                  ),
                ],
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
                    border: Border.all(color: AppColors.danger.withAlpha(90)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _error!,
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: AppColors.danger,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: _loading || _applying ? null : _load,
                        child: Text(t('Retry')),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Expanded(
                child: _loading
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(),
                            const SizedBox(height: 12),
                            Text(
                              t('Searching MusicBrainz...'),
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      )
                    : _candidates.isEmpty
                        ? Center(
                            child: Text(
                              t('No matching tracks found on MusicBrainz.'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                              ),
                            ),
                          )
                        : LayoutBuilder(
                            builder: (context, constraints) {
                              final narrow = constraints.maxWidth < 560;
                              final listPane = Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    t('Track Candidates'),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.textSecondary,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Expanded(
                                    child: ListView.separated(
                                      itemCount: _candidates.length,
                                      separatorBuilder: (_, _) =>
                                          const SizedBox(height: 8),
                                      itemBuilder: (context, index) {
                                        return _TrackCandidateCard(
                                          candidate: _candidates[index],
                                          selected: index == _selectedIndex,
                                          enabled: !_applying,
                                          onTap: () => setState(
                                            () => _selectedIndex = index,
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              );

                              final diffPane = selected == null
                                  ? const SizedBox.shrink()
                                  : _TrackDiffPane(candidate: selected);

                              if (narrow) {
                                return Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Expanded(flex: 3, child: listPane),
                                    const Divider(
                                      height: 20,
                                      color: AppColors.border,
                                    ),
                                    Expanded(flex: 2, child: diffPane),
                                  ],
                                );
                              }

                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  SizedBox(width: 300, child: listPane),
                                  const SizedBox(width: 16),
                                  const VerticalDivider(
                                    width: 1,
                                    color: AppColors.border,
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(child: diffPane),
                                ],
                              );
                            },
                          ),
              ),
              const SizedBox(height: 14),
              const Divider(height: 1, color: AppColors.border),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed:
                        _applying ? null : () => Navigator.of(context).pop(),
                    child: Text(t('Cancel')),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _applying || selected == null ? null : _apply,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: AppColors.canvas,
                    ),
                    child: _applying
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.canvas,
                            ),
                          )
                        : Text(t('Apply')),
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

class _TrackCandidateCard extends StatelessWidget {
  const _TrackCandidateCard({
    required this.candidate,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final UiTrackMatchCandidate candidate;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final details = [
      if (candidate.album.isNotEmpty) candidate.album,
      if (candidate.year != null) '${candidate.year}',
      if (candidate.country != null && candidate.country!.isNotEmpty)
        candidate.country!,
      if (candidate.format != null && candidate.format!.isNotEmpty)
        candidate.format!,
    ].join(' · ');

    return Material(
      color: selected ? AppColors.accentMuted : AppColors.canvas,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? AppColors.accent : AppColors.border,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      candidate.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '${candidate.score}%',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.accent,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                candidate.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
              if (details.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  details,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TrackDiffPane extends StatelessWidget {
  const _TrackDiffPane({required this.candidate});

  final UiTrackMatchCandidate candidate;

  @override
  Widget build(BuildContext context) {
    final fields = candidate.track.fields;
    return ListView(
      children: [
        Text(
          t('Field Changes'),
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 8),
        if (fields.isEmpty)
          Text(
            t('No field changes'),
            style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted),
          )
        else
          for (final diff in fields)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 84,
                    child: Text(
                      diff.field,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      diff.oldValue?.isNotEmpty == true ? diff.oldValue! : '—',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: Icon(
                      Icons.arrow_forward_rounded,
                      size: 13,
                      color: AppColors.textMuted,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      diff.newValue?.isNotEmpty == true ? diff.newValue! : '—',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: AppColors.accent,
                      ),
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}
