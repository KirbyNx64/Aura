import 'package:flutter/material.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

class _DependencyInfo {
  final String url;
  final String version;
  const _DependencyInfo(this.url, this.version);
}

class DependenciesScreen extends StatelessWidget {
  const DependenciesScreen({super.key});

  final Map<String, _DependencyInfo> _dependencies = const {
    'flutter': _DependencyInfo('https://flutter.dev', 'sdk'),
    'flutter_localizations': _DependencyInfo('https://flutter.dev', 'sdk'),
    'hive_ce': _DependencyInfo('https://pub.dev/packages/hive_ce', '^2.2.3'),
    'hive_ce_flutter': _DependencyInfo(
      'https://pub.dev/packages/hive_ce_flutter',
      '^1.1.0',
    ),
    'on_audio_query': _DependencyInfo(
      'https://pub.dev/packages/on_audio_query',
      '2.9.0',
    ),
    'just_audio': _DependencyInfo(
      'https://pub.dev/packages/just_audio',
      '^0.10.5',
    ),
    'audio_session': _DependencyInfo(
      'https://pub.dev/packages/audio_session',
      '^0.2.2',
    ),
    'audio_service': _DependencyInfo(
      'https://pub.dev/packages/audio_service',
      '^0.18.18',
    ),
    'path': _DependencyInfo('https://pub.dev/packages/path', '^1.9.1'),
    'shared_preferences': _DependencyInfo(
      'https://pub.dev/packages/shared_preferences',
      '^2.5.4',
    ),
    'path_provider': _DependencyInfo(
      'https://pub.dev/packages/path_provider',
      '^2.1.5',
    ),
    'permission_handler': _DependencyInfo(
      'https://pub.dev/packages/permission_handler',
      '^12.0.1',
    ),
    'share_plus': _DependencyInfo(
      'https://pub.dev/packages/share_plus',
      '^11.1.0',
    ),
    'cross_file': _DependencyInfo(
      'https://pub.dev/packages/cross_file',
      '^0.3.4+2',
    ),
    'connectivity_plus': _DependencyInfo(
      'https://pub.dev/packages/connectivity_plus',
      '^7.0.0',
    ),
    'http': _DependencyInfo('https://pub.dev/packages/http', '^1.6.0'),
    'youtube_explode_dart': _DependencyInfo(
      'https://github.com/anandnet/youtube_explode_dart',
      'git: 1d9ec9baa80',
    ),
    'file_selector': _DependencyInfo(
      'https://pub.dev/packages/file_selector',
      '^1.0.3',
    ),
    'audiotags': _DependencyInfo(
      'https://pub.dev/packages/audiotags',
      '^1.4.5',
    ),
    'url_launcher': _DependencyInfo(
      'https://pub.dev/packages/url_launcher',
      '^6.3.2',
    ),
    'device_info_plus': _DependencyInfo(
      'https://pub.dev/packages/device_info_plus',
      '^12.3.0',
    ),
    'dio': _DependencyInfo('https://pub.dev/packages/dio', '^5.9.1'),
    'open_file': _DependencyInfo(
      'https://pub.dev/packages/open_file',
      '^3.5.11',
    ),
    'smooth_page_indicator': _DependencyInfo(
      'https://pub.dev/packages/smooth_page_indicator',
      '^2.0.1',
    ),
    'squiggly_slider': _DependencyInfo(
      'https://pub.dev/packages/squiggly_slider',
      '^1.0.5',
    ),
    'android_intent_plus': _DependencyInfo(
      'https://pub.dev/packages/android_intent_plus',
      '^6.0.0',
    ),
    'package_info_plus': _DependencyInfo(
      'https://pub.dev/packages/package_info_plus',
      '^9.0.0',
    ),
    'ota_update': _DependencyInfo(
      'https://pub.dev/packages/ota_update',
      '^7.1.0',
    ),
    'scroll_to_index': _DependencyInfo(
      'https://pub.dev/packages/scroll_to_index',
      '^3.0.1',
    ),
    'mini_music_visualizer': _DependencyInfo(
      'https://pub.dev/packages/mini_music_visualizer',
      '^1.1.4',
    ),
    'flutter_local_notifications': _DependencyInfo(
      'https://pub.dev/packages/flutter_local_notifications',
      '^19.5.0',
    ),
    'flutter_svg': _DependencyInfo(
      'https://pub.dev/packages/flutter_svg',
      '^2.2.3',
    ),
    'flutter_audio_toolkit': _DependencyInfo(
      'https://pub.dev/packages/flutter_audio_toolkit',
      '^1.0.0',
    ),
    'fading_edge_scrollview': _DependencyInfo(
      'https://pub.dev/packages/fading_edge_scrollview',
      '^4.1.1',
    ),
    'sqflite': _DependencyInfo('https://pub.dev/packages/sqflite', '^2.4.2'),
    'dynamic_color': _DependencyInfo(
      'https://pub.dev/packages/dynamic_color',
      '^1.8.1',
    ),
    'flutter_sharing_intent': _DependencyInfo(
      'https://pub.dev/packages/flutter_sharing_intent',
      '^1.1.1',
    ),
    'like_button': _DependencyInfo(
      'https://pub.dev/packages/like_button',
      '^2.1.0',
    ),
    'translator': _DependencyInfo(
      'https://pub.dev/packages/translator',
      '^1.0.4+1',
    ),
    'buttons_tabbar': _DependencyInfo(
      'https://pub.dev/packages/buttons_tabbar',
      '^1.3.15',
    ),
    'image': _DependencyInfo('https://pub.dev/packages/image', '^4.7.2'),
    'cached_network_image': _DependencyInfo(
      'https://pub.dev/packages/cached_network_image',
      '^3.4.1',
    ),
    'material_loading_indicator': _DependencyInfo(
      'https://pub.dev/packages/material_loading_indicator',
      '^1.0.0',
    ),
    'palette_generator_master': _DependencyInfo(
      'https://pub.dev/packages/palette_generator_master',
      '^1.0.1',
    ),
    'flutter_m3shapes': _DependencyInfo(
      'https://pub.dev/packages/flutter_m3shapes',
      '^1.0.0+2',
    ),
    'material_symbols_icons': _DependencyInfo(
      'https://pub.dev/packages/material_symbols_icons',
      '^4.2906.0',
    ),
    'sliding_up_panel': _DependencyInfo(
      'https://pub.dev/packages/sliding_up_panel',
      '^2.0.0+1',
    ),
    'wakelock_plus': _DependencyInfo(
      'https://pub.dev/packages/wakelock_plus',
      '^1.4.0',
    ),
    'marquee': _DependencyInfo('https://pub.dev/packages/marquee', '^2.3.0'),
    'open_settings_plus': _DependencyInfo(
      'https://pub.dev/packages/open_settings_plus',
      '^0.4.0',
    ),
    'android_nav_setting': _DependencyInfo(
      'https://pub.dev/packages/android_nav_setting',
      '^0.0.2+2',
    ),
    'expressive_refresh': _DependencyInfo(
      'https://pub.dev/packages/expressive_refresh',
      '^0.1.2',
    ),
  };

  Future<void> _launchUrl(String urlString) async {
    if (urlString.isEmpty) return;
    final Uri url = Uri.parse(urlString);
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppColorScheme>(
      valueListenable: colorSchemeNotifier,
      builder: (context, colorScheme, child) {
        final isAmoled = colorScheme == AppColorScheme.amoled;
        final isDark = Theme.of(context).brightness == Brightness.dark;

        return Scaffold(
          appBar: AppBar(
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            leading: IconButton(
              constraints: const BoxConstraints(
                minWidth: 40,
                minHeight: 40,
                maxWidth: 40,
                maxHeight: 40,
              ),
              padding: EdgeInsets.zero,
              icon: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDark
                      ? Theme.of(
                          context,
                        ).colorScheme.secondary.withValues(alpha: 0.06)
                      : Theme.of(
                          context,
                        ).colorScheme.secondary.withValues(alpha: 0.06),
                ),
                child: const Icon(Icons.arrow_back, size: 24),
              ),
              onPressed: () => Navigator.of(context).pop(),
            ),
            title: Text(
              LocaleProvider.tr('dependencies'),
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          body: ListView.separated(
            padding: EdgeInsets.fromLTRB(
              16,
              16,
              16,
              16 + MediaQuery.of(context).padding.bottom,
            ),
            physics: const ClampingScrollPhysics(),
            itemCount: _dependencies.length,
            separatorBuilder: (context, index) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final key = _dependencies.keys.elementAt(index);
              final info = _dependencies[key]!;

              return Card(
                color: isAmoled && isDark
                    ? Colors.white.withAlpha(20)
                    : isDark
                    ? Theme.of(
                        context,
                      ).colorScheme.secondary.withValues(alpha: 0.06)
                    : Theme.of(
                        context,
                      ).colorScheme.secondary.withValues(alpha: 0.07),
                margin: EdgeInsets.zero,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  onTap: info.url.isNotEmpty
                      ? () => _launchUrl(info.url)
                      : null,
                  leading: Icon(
                    Icons.extension_rounded,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                  title: Text(
                    key,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  subtitle: Text(
                    info.version,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                  trailing: info.url.isNotEmpty
                      ? const Icon(Icons.open_in_new_rounded, size: 18)
                      : null,
                ),
              );
            },
          ),
        );
      },
    );
  }
}
