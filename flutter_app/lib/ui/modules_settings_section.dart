import 'package:material_ui/material_ui.dart';
import 'package:neomodern/i18n/strings.dart';
import 'package:neomodern/state/player_controller.dart';
import 'package:neomodern/theme/app_icons.dart';
import 'package:neomodern/theme/app_theme.dart';
import 'package:neomodern/ui/sources_view.dart';

/// Unified "Modules & Extensions" settings panel (K29/K30).
///
/// Groups built-in Core Modules (Lyrics, Metadata, LAN Sync, Party Queue,
/// Update Checks) alongside user-configured External Providers under a single
/// modular mental model without fragmenting core zero-config features into
/// external binaries.
class ModulesSettingsSection extends StatelessWidget {
  const ModulesSettingsSection({
    super.key,
    required this.controller,
  });

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    final net = controller.netSettings;
    final offline = net?.offlineMode ?? controller.offlineMode;
    final lyricsOn = !offline && (net?.lyrics ?? true);
    final neteaseOn = lyricsOn && (net?.lyricsNetease ?? false);
    final metadataOn = !offline && (net?.metadata ?? true);
    final externalNetOn = !offline && (net?.online ?? true);
    final updatesOn = !offline && (net?.updates ?? true);
    final partyOn = controller.partyStatus?.enabled ?? false;
    final pairedCount = controller.syncStatus?.peers.length ?? 0;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.zinc900,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppTheme.hairline),
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
                      t('Modules & Extensions'),
                      style: AppTheme.displayStyle(
                        fontSize: 22,
                        color: AppTheme.editorialPaper,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      offline
                          ? t('Offline mode active — network modules are paused')
                          : t('Toggle built-in modules and manage external source providers'),
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppTheme.zinc400,
                      ),
                    ),
                  ],
                ),
              ),
              _StatusPill(
                label: offline ? 'OFFLINE' : 'MODULAR',
                active: !offline,
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            'CORE MODULES',
            style: AppTheme.kickerStyle(
              fontSize: 10.5,
              color: AppTheme.zinc500,
            ),
          ),
          const SizedBox(height: 10),
          _ModuleRow(
            icon: AppIcons.lyrics,
            title: t('Synced Lyrics (LRCLIB)'),
            subtitle: t('Fetch synced & plain lyrics and share local .lrc files'),
            badge: offline ? 'OFFLINE' : (lyricsOn ? 'ACTIVE' : 'OFF'),
            badgeActive: lyricsOn,
            trailing: Switch(
              value: net?.lyrics ?? true,
              onChanged: offline
                  ? null
                  : (v) => controller.setNetFeature('lyrics', v),
            ),
          ),
          const Divider(height: 18, color: AppTheme.hairline),
          _ModuleRow(
            icon: AppIcons.lyrics,
            title: t('NetEase Lyrics Fallback'),
            subtitle: t('Secondary lyrics lookup when LRCLIB has no match'),
            badge: neteaseOn ? 'ACTIVE' : 'OFF',
            badgeActive: neteaseOn,
            trailing: Switch(
              value: net?.lyricsNetease ?? false,
              onChanged: offline ? null : controller.setLyricsNetease,
            ),
          ),
          const Divider(height: 18, color: AppTheme.hairline),
          _ModuleRow(
            icon: AppIcons.albums,
            title: t('Metadata & Artist Matching (MusicBrainz)'),
            subtitle: t('Match album tags, tracklists, and artist metadata'),
            badge: offline ? 'OFFLINE' : (metadataOn ? 'ACTIVE' : 'OFF'),
            badgeActive: metadataOn,
            trailing: Switch(
              value: net?.metadata ?? true,
              onChanged: offline
                  ? null
                  : (v) => controller.setNetFeature('metadata', v),
            ),
          ),
          const Divider(height: 18, color: AppTheme.hairline),
          _ModuleRow(
            icon: AppIcons.sources,
            title: t('External Source Access'),
            subtitle: t('Allow configured HTTP/JSON, OpenSubsonic, and CLI providers'),
            badge: offline ? 'OFFLINE' : (externalNetOn ? 'ACTIVE' : 'OFF'),
            badgeActive: externalNetOn,
            trailing: Switch(
              value: net?.online ?? true,
              onChanged: offline
                  ? null
                  : (v) => controller.setNetFeature('online', v),
            ),
          ),
          const Divider(height: 18, color: AppTheme.hairline),
          _ModuleRow(
            icon: AppIcons.queue,
            title: t('Party Queue (LAN · Experimental)'),
            subtitle: t('Let guests on the same Wi-Fi append songs to the queue'),
            badge: partyOn ? 'ACTIVE' : 'OFF',
            badgeActive: partyOn,
            trailing: Switch(
              value: partyOn,
              onChanged: controller.setPartyEnabled,
            ),
          ),
          const Divider(height: 18, color: AppTheme.hairline),
          _ModuleRow(
            icon: AppIcons.refresh,
            title: t('Release Update Checks'),
            subtitle: t('Check GitHub Releases for new NeoModern builds'),
            badge: offline ? 'OFFLINE' : (updatesOn ? 'ACTIVE' : 'OFF'),
            badgeActive: updatesOn,
            trailing: Switch(
              value: net?.updates ?? true,
              onChanged: offline
                  ? null
                  : (v) => controller.setNetFeature('updates', v),
            ),
          ),
          const Divider(height: 18, color: AppTheme.hairline),
          _ModuleRow(
            icon: AppIcons.cloud,
            title: t('LAN Sync & Phone Remote'),
            subtitle: pairedCount > 0
                ? t('{n} paired device(s) configured on local Wi-Fi', {
                    'n': pairedCount,
                  })
                : t('Pair a phone in the LAN Sync section below'),
            badge: pairedCount > 0 ? 'PAIRED' : 'IDLE',
            badgeActive: pairedCount > 0,
            trailing: const SizedBox.shrink(),
          ),
          const SizedBox(height: 22),
          Text(
            'EXTERNAL PROVIDERS',
            style: AppTheme.kickerStyle(
              fontSize: 10.5,
              color: AppTheme.zinc500,
            ),
          ),
          const SizedBox(height: 10),
          ExternalSourcesSettingsSection(controller: controller),
        ],
      ),
    );
  }
}

class _ModuleRow extends StatelessWidget {
  const _ModuleRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.badge,
    required this.badgeActive,
    required this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String badge;
  final bool badgeActive;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppTheme.zinc400),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: AppTheme.zinc100,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _StatusPill(label: badge, active: badgeActive),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.zinc400,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        trailing,
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.label,
    required this.active,
  });

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: active
            ? AppTheme.accent500.withValues(alpha: 0.14)
            : Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(
          color: active
              ? AppTheme.accent500.withValues(alpha: 0.45)
              : AppTheme.hairline,
        ),
      ),
      child: Text(
        label,
        style: AppTheme.monoStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w600,
          color: active ? AppTheme.accent400 : AppTheme.zinc500,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}
