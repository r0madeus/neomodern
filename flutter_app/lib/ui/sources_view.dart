import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/src/rust/api/neomodern.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_theme.dart';

class ExternalSourcesSettingsSection extends StatelessWidget {
  const ExternalSourcesSettingsSection({super.key, required this.controller});

  final PlayerController controller;

  Future<void> _showAddDialog(BuildContext context) async {
    final nameCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    String? error;
    var saving = false;

    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('Add External Source'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Configure a neutral HTTP/JSON provider exposing /search, /stream/{id}, and /track/{id}.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  enabled: !saving,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    hintText: 'Self-hosted Bridge',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: urlCtrl,
                  enabled: !saving,
                  decoration: const InputDecoration(
                    labelText: 'Base URL',
                    hintText: 'http://127.0.0.1:8787',
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    error!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.danger,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      setState(() {
                        saving = true;
                        error = null;
                      });
                      final err = await controller.addSourceProvider(
                        nameCtrl.text,
                        urlCtrl.text,
                      );
                      if (!context.mounted) return;
                      if (err != null) {
                        setState(() {
                          saving = false;
                          error = err;
                        });
                      } else {
                        Navigator.of(context).pop();
                      }
                    },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );

    nameCtrl.dispose();
    urlCtrl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final providers = controller.sourceProviders;

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
                      t('External Sources (HTTP/JSON)'),
                      style: const TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    Text(
                      t('Optional external catalog and stream providers'),
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: () => _showAddDialog(context),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: AppColors.canvas,
                ),
                icon: const Icon(Icons.add_rounded, size: 17),
                label: Text(
                  t('Add Source'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (providers.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                t('No external sources configured. Add a neutral HTTP/JSON provider (e.g. self-hosted bridge) to search and stream external catalogs.'),
                style: const TextStyle(
                    fontSize: 13, color: AppColors.textSecondary),
              ),
            )
          else
            for (var i = 0; i < providers.length; i++) ...[
              if (i > 0) const Divider(height: 12, color: AppColors.border),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    const Icon(
                      Icons.hub_rounded,
                      size: 18,
                      color: AppColors.accent,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            providers[i].name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w500,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          Text(
                            providers[i].baseUrl,
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
                    Switch(
                      value: providers[i].enabled,
                      onChanged: (enabled) => controller.toggleSourceProvider(
                        providers[i].id,
                        enabled,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Remove source',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(
                        Icons.delete_outline_rounded,
                        size: 18,
                        color: AppColors.textSecondary,
                      ),
                      onPressed: () =>
                          controller.removeSourceProvider(providers[i].id),
                    ),
                  ],
                ),
              ),
            ],
        ],
      ),
    );
  }
}

class SourcesView extends StatefulWidget {
  const SourcesView({super.key, required this.controller});

  final PlayerController controller;

  @override
  State<SourcesView> createState() => _SourcesViewState();
}

class _SourcesViewState extends State<SourcesView> {
  final TextEditingController _queryCtrl = TextEditingController();
  String? _selectedProviderId;
  bool _searching = false;
  String? _error;
  List<UiExternalTrack> _results = const [];
  bool _searchedOnce = false;

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  String? _activeProviderId(List<UiSourceProvider> enabled) {
    if (enabled.isEmpty) return null;
    if (_selectedProviderId != null &&
        enabled.any((p) => p.id == _selectedProviderId)) {
      return _selectedProviderId;
    }
    return enabled.first.id;
  }

  Future<void> _runSearch(String providerId) async {
    final query = _queryCtrl.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _searching = true;
      _error = null;
      _searchedOnce = true;
    });
    try {
      final items = await widget.controller.searchExternalSource(
        providerId,
        query,
        limit: 30,
      );
      if (!mounted) return;
      setState(() {
        _searching = false;
        _results = items;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = e.toString();
        _results = const [];
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.controller.enabledSourceProviders;
    final activeId = _activeProviderId(enabled);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t('Sources'),
                        style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 2),
                    Text(
                      t('Search and stream from configured HTTP/JSON providers'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              if (enabled.length > 1 && activeId != null)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: DropdownButton<String>(
                    value: activeId,
                    dropdownColor: AppColors.surface,
                    underline: const SizedBox.shrink(),
                    items: [
                      for (final p in enabled)
                        DropdownMenuItem(
                          value: p.id,
                          child: Text(p.name),
                        ),
                    ],
                    onChanged: (id) {
                      if (id != null) {
                        setState(() => _selectedProviderId = id);
                      }
                    },
                  ),
                ),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 280),
                  child: TextField(
                    controller: _queryCtrl,
                    enabled: activeId != null && !_searching,
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      hintText: t('Search external catalog...'),
                      prefixIcon: const Icon(
                        Icons.search_rounded,
                        size: 18,
                        color: AppColors.textMuted,
                      ),
                    ),
                    onSubmitted: (_) {
                      if (activeId != null) _runSearch(activeId);
                    },
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: activeId != null && !_searching
                    ? () => _runSearch(activeId)
                    : null,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: AppColors.canvas,
                ),
                child: Text(
                  t('Search'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: AppColors.border),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
            child: Text(
              _error!,
              style: const TextStyle(fontSize: 13, color: AppColors.danger),
            ),
          ),
        Expanded(
          child: activeId == null
              ? Center(
                  child: Text(
                    t('Enable an external source in Settings to search and stream.'),
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                )
              : _searching
                  ? const Center(child: CircularProgressIndicator())
                  : !_searchedOnce
                      ? Center(
                          child: Text(
                            t('Enter a query above to search this provider.'),
                            style:
                                const TextStyle(color: AppColors.textSecondary),
                          ),
                        )
                      : _results.isEmpty
                          ? Center(
                              child: Text(
                                t('No matching tracks found.'),
                                style: const TextStyle(
                                    color: AppColors.textSecondary),
                              ),
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 12,
                              ),
                              itemCount: _results.length,
                              separatorBuilder: (_, _) => const Divider(
                                height: 1,
                                color: AppColors.border,
                              ),
                              itemBuilder: (context, index) {
                                final track = _results[index];
                                return ListTile(
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  leading: Container(
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: AppColors.surface,
                                      borderRadius: BorderRadius.circular(6),
                                      border:
                                          Border.all(color: AppColors.border),
                                    ),
                                    child: const Icon(
                                      Icons.music_note_rounded,
                                      color: AppColors.accent,
                                      size: 20,
                                    ),
                                  ),
                                  title: Text(
                                    track.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w500,
                                      color: AppColors.textPrimary,
                                    ),
                                  ),
                                  subtitle: Text(
                                    track.album != null &&
                                            track.album!.isNotEmpty
                                        ? '${track.artist} · ${track.album}'
                                        : track.artist,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: AppColors.textSecondary,
                                    ),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (track.durationMs != null)
                                        Text(
                                          formatDurationMs(track.durationMs),
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: AppColors.textMuted,
                                            fontFeatures: [
                                              FontFeature.tabularFigures(),
                                            ],
                                          ),
                                        ),
                                      const SizedBox(width: 8),
                                      IconButton(
                                        tooltip: 'Play stream',
                                        icon: const Icon(
                                          Icons.play_arrow_rounded,
                                          color: AppColors.accent,
                                        ),
                                        onPressed: () => widget.controller
                                            .playExternalTrack(track),
                                      ),
                                    ],
                                  ),
                                  onTap: () => widget.controller
                                      .playExternalTrack(track),
                                );
                              },
                            ),
        ),
      ],
    );
  }
}
