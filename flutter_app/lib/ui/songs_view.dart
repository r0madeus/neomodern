import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/selection_bar.dart';
import 'package:neomodern/ui/track_menu.dart';
import 'package:neomodern/ui/widgets/track_row.dart';

class SongsView extends StatefulWidget {
  const SongsView({
    super.key,
    required this.controller,
    required this.onOpenArtist,
    required this.onOpenAlbum,
    required this.onOpenSettings,
  });

  final PlayerController controller;
  final ValueChanged<String> onOpenArtist;
  final ValueChanged<PlatformInt64> onOpenAlbum;
  final VoidCallback onOpenSettings;

  @override
  State<SongsView> createState() => _SongsViewState();
}

class _SongsViewState extends State<SongsView> {
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _debounce;
  final Set<int> _selectedIndices = {};
  int? _selectionAnchor;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 180), () {
      _selectedIndices.clear();
      _selectionAnchor = null;
      widget.controller.setTrackSearch(value);
    });
  }

  void _handleRowTap(int index) {
    final keys = HardwareKeyboard.instance;
    final ctrlHeld = keys.isControlPressed || keys.isMetaPressed;
    final shiftHeld = keys.isShiftPressed;

    if (shiftHeld) {
      final anchor = _selectionAnchor ?? index;
      final start = anchor < index ? anchor : index;
      final end = anchor > index ? anchor : index;
      setState(() {
        if (!ctrlHeld) _selectedIndices.clear();
        for (var i = start; i <= end; i++) {
          _selectedIndices.add(i);
        }
      });
      return;
    }

    if (ctrlHeld) {
      setState(() {
        if (_selectedIndices.contains(index)) {
          _selectedIndices.remove(index);
        } else {
          _selectedIndices.add(index);
        }
        _selectionAnchor = index;
      });
      return;
    }

    if (_selectedIndices.isNotEmpty) {
      setState(() {
        _selectedIndices.clear();
        _selectionAnchor = null;
      });
    }
    unawaited(widget.controller.playAllFromSearch(index));
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final activePath = ctrl.snapshot.current?.path;

    final selectedTracks = <UiTrackRow>[];
    for (final idx in _selectedIndices) {
      if (idx >= 0 && idx < ctrl.trackCount) {
        final tr = ctrl.trackAt(idx);
        if (tr != null) selectedTracks.add(tr);
      }
    }
    final allStarred = selectedTracks.isNotEmpty &&
        selectedTracks.every((tr) => ctrl.isFavorite(tr.id));

    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 14),
              child: Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t('Songs'),
                          style: Theme.of(context).textTheme.headlineSmall),
                      const SizedBox(height: 2),
                      Text(
                        t('{n} tracks', {'n': ctrl.trackCount}),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                  const SizedBox(width: 18),
                  FilledButton.icon(
                    onPressed: ctrl.trackCount > 0
                        ? () => ctrl.playAllFromSearch(0)
                        : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.accent500,
                      foregroundColor: AppTheme.zinc950,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                    ),
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: Text(
                      t('Play All'),
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const Spacer(),
                  SizedBox(
                    width: 280,
                    child: TextField(
                      controller: _searchCtrl,
                      onChanged: _onSearchChanged,
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        hintText: t('Search songs, artists, albums...'),
                        prefixIcon: const Icon(
                          Icons.search_rounded,
                          size: 18,
                          color: AppTheme.zinc500,
                        ),
                        suffixIcon: _searchCtrl.text.isNotEmpty
                            ? IconButton(
                                icon:
                                    const Icon(Icons.close_rounded, size: 16),
                                onPressed: () {
                                  _searchCtrl.clear();
                                  _selectedIndices.clear();
                                  _selectionAnchor = null;
                                  ctrl.setTrackSearch('');
                                  setState(() {});
                                },
                              )
                            : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: AppTheme.zinc800)),
              ),
              child: Row(
                children: [
                  const SizedBox(
                    width: 40,
                    child: Text('#',
                        style:
                            TextStyle(fontSize: 11.5, color: AppTheme.zinc500)),
                  ),
                  Expanded(
                    flex: 4,
                    child: Text(t('Title'),
                        style: const TextStyle(
                            fontSize: 11.5, color: AppTheme.zinc500)),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(t('Artist'),
                        style: const TextStyle(
                            fontSize: 11.5, color: AppTheme.zinc500)),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(t('Album'),
                        style: const TextStyle(
                            fontSize: 11.5, color: AppTheme.zinc500)),
                  ),
                  const SizedBox(width: 36),
                  SizedBox(
                    width: 52,
                    child: Text(
                      t('Time'),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontSize: 11.5, color: AppTheme.zinc500),
                    ),
                  ),
                  const SizedBox(width: 30),
                ],
              ),
            ),
            Expanded(
              child: ctrl.trackCount == 0
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            ctrl.trackSearch.isNotEmpty
                                ? t('No matching songs found.')
                                : t('No songs in library yet.'),
                            style: const TextStyle(color: AppTheme.zinc400),
                          ),
                          if (ctrl.trackSearch.isEmpty) ...[
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                              onPressed: widget.onOpenSettings,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppTheme.accent400,
                                side: const BorderSide(color: AppTheme.zinc800),
                              ),
                              icon: const Icon(Icons.folder_open_rounded,
                                  size: 17),
                              label: Text(t('Add Music Folder in Settings')),
                            ),
                          ],
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.only(
                        bottom: selectedTracks.isNotEmpty ? 76 : 12,
                      ),
                      itemCount: ctrl.trackCount,
                      itemExtent: 56,
                      itemBuilder: (context, index) {
                        final track = ctrl.trackAt(index);
                        if (track == null) {
                          return const _TrackRowSkeleton();
                        }
                        final isActive = activePath == track.path;
                        final isSelected = _selectedIndices.contains(index);
                        void playHere() => ctrl.playAllFromSearch(index);

                        return DesktopTrackRow(
                          indexLabel: '${index + 1}',
                          track: track,
                          controller: ctrl,
                          isActive: isActive,
                          isSelected: isSelected,
                          onTap: () => _handleRowTap(index),
                          onPlay: playHere,
                          onOpenArtist: widget.onOpenArtist,
                          onOpenAlbum: widget.onOpenAlbum,
                        );
                      },
                    ),
            ),
          ],
        ),
        TrackSelectionBar(
          selectedCount: selectedTracks.length,
          allStarred: allStarred,
          onAddToQueue: () async {
            await ctrl.enqueueManyTracks(
              selectedTracks.map((tr) => tr.path).toList(),
            );
            setState(() {
              _selectedIndices.clear();
              _selectionAnchor = null;
            });
          },
          onToggleStar: () async {
            await ctrl.setManyFavorites(
              selectedTracks.map((tr) => tr.id).toList(),
              !allStarred,
            );
          },
          onAddToPlaylist: () async {
            await showAddToPlaylistDialog(
              context: context,
              controller: ctrl,
              trackIds: selectedTracks.map((tr) => tr.id).toList(),
            );
          },
          onClear: () => setState(() {
            _selectedIndices.clear();
            _selectionAnchor = null;
          }),
        ),
      ],
    );
  }
}

class _TrackRowSkeleton extends StatelessWidget {
  const _TrackRowSkeleton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          t('Loading...'),
          style: const TextStyle(fontSize: 12.5, color: AppTheme.zinc500),
        ),
      ),
    );
  }
}
