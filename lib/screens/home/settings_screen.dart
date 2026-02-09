import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:music/screens/home/ota_update_screen.dart';
import 'package:music/screens/home/about_screen.dart';
import 'package:music/screens/home/equalizer_screen.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:permission_handler/permission_handler.dart';
//import 'package:music/utils/db/artwork_db.dart';
import 'package:music/utils/db/favorites_db.dart';
import 'package:music/utils/db/playlists_db.dart';
import 'package:music/utils/db/recent_db.dart';
import 'package:music/utils/db/mostplayer_db.dart';
import 'package:music/utils/db/shortcuts_db.dart';
import 'package:music/utils/db/artwork_db.dart';
import 'package:music/utils/db/songs_index_db.dart';
import 'package:music/utils/db/artists_db.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_selector/file_selector.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/audio/synced_lyrics_service.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'dart:convert';
import 'package:music/utils/db/playlist_model.dart' as hive_model;
import 'package:music/widgets/gesture_settings_dialog.dart';

class SettingsScreen extends StatefulWidget {
  final void Function(AppThemeMode)? setThemeMode;
  final void Function(AppColorScheme)? setColorScheme;

  const SettingsScreen({super.key, this.setThemeMode, this.setColorScheme});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _batteryOptDisabled = false;
  bool _checkingBatteryOpt = false;
  String _currentLanguage = 'es';
  String? _downloadDirectory;
  bool _downloadTypeExplode = false; // true: Explode, false: Directo
  bool _coverQualityHigh = true; // true: Alto, false: Bajo
  String _audioQuality = 'high'; // 'high', 'medium', 'low'
  AppColorScheme _currentColorScheme = AppColorScheme.system;
  int _artworkQuality = 410; // 80% por defecto
  int? _availableBytesAtDownloadDir;
  int? _totalBytesAtDownloadDir;

  @override
  void initState() {
    super.initState();
    _checkBatteryOptimization();
    _loadLanguage();
    _loadDownloadDirectory();
    _loadDownloadType();
    _loadCoverQuality();
    _loadAudioQuality();
    _loadColorScheme();
    _loadArtworkQuality();
    _initHeroAnimationSetting();
    _loadOverlayNextButtonSetting();
    _loadTranslationLanguageSetting();
    _loadArtworkBackgroundSetting();
  }

  Future<void> _initHeroAnimationSetting() async {
    final prefs = await SharedPreferences.getInstance();
    final useHero = prefs.getBool('use_hero_animation') ?? true;
    heroAnimationNotifier.value = useHero;
  }

  Future<void> _loadOverlayNextButtonSetting() async {
    final prefs = await SharedPreferences.getInstance();
    final nextButtonEnabled =
        prefs.getBool('overlay_next_button_enabled') ?? false;
    overlayNextButtonEnabled.value = nextButtonEnabled;
  }

  Future<void> _loadTranslationLanguageSetting() async {
    final prefs = await SharedPreferences.getInstance();
    final language = prefs.getString('translation_language') ?? 'auto';
    translationLanguageNotifier.value = language;
  }

  Future<void> _loadArtworkBackgroundSetting() async {
    final prefs = await SharedPreferences.getInstance();
    final usePlayer = prefs.getBool('use_artwork_background_player') ?? true;
    final useOverlay = prefs.getBool('use_artwork_background_overlay') ?? true;
    useArtworkAsBackgroundPlayerNotifier.value = usePlayer;
    useArtworkAsBackgroundOverlayNotifier.value = useOverlay;
  }

  Future<void> _setArtworkBackgroundPlayer(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('use_artwork_background_player', value);
    useArtworkAsBackgroundPlayerNotifier.value = value;
    setState(() {});
  }

  Future<void> _setArtworkBackgroundOverlay(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('use_artwork_background_overlay', value);
    useArtworkAsBackgroundOverlayNotifier.value = value;
    setState(() {});
  }

  void _showArtworkBackgroundDialog() {
    final isAmoled = _currentColorScheme == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
            side: isAmoled && isDark
                ? const BorderSide(color: Colors.white24, width: 1)
                : BorderSide.none,
          ),
          backgroundColor: isAmoled && isDark
              ? Colors.black
              : Theme.of(context).colorScheme.surface,
          surfaceTintColor: Colors.transparent,
          title: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.image_outlined,
                size: 32,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              const SizedBox(height: 16),
              TranslatedText(
                'use_artwork_as_background',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: useArtworkAsBackgroundPlayerNotifier,
                builder: (context, value, _) {
                  return SwitchListTile(
                    title: TranslatedText('player'),
                    value: value,
                    onChanged: (v) => _setArtworkBackgroundPlayer(v),
                  );
                },
              ),
              ValueListenableBuilder<bool>(
                valueListenable: useArtworkAsBackgroundOverlayNotifier,
                builder: (context, value, _) {
                  return SwitchListTile(
                    title: TranslatedText('overlay'),
                    value: value,
                    onChanged: (v) => _setArtworkBackgroundOverlay(v),
                  );
                },
              ),
            ],
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 8, bottom: 8),
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  LocaleProvider.tr('ok'),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _loadArtworkQuality() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _artworkQuality =
          prefs.getInt('artwork_quality') ?? 410; // 80% por defecto
    });
  }

  Future<void> _setArtworkQuality(int quality) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('artwork_quality', quality);
    setState(() {
      _artworkQuality = quality;
    });
  }

  void _showInfoDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final primaryColor = Theme.of(context).colorScheme.primary;

            return AlertDialog(
              backgroundColor: isAmoled && isDark
                  ? Colors.black
                  : Theme.of(context).colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white24, width: 1)
                    : BorderSide.none,
              ),
              contentPadding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 400,
                  maxHeight: MediaQuery.of(context).size.height * 0.8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.info_rounded,
                      size: 32,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    const SizedBox(height: 16),
                    TranslatedText(
                      'info',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: TranslatedText(
                        'settings_info',
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withAlpha(180),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Padding(
                      padding: const EdgeInsets.only(right: 24, bottom: 8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: TranslatedText(
                            'ok',
                            style: TextStyle(
                              color: primaryColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showArtworkQualityDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final primaryColor = Theme.of(context).colorScheme.primary;

            return AlertDialog(
              backgroundColor: isAmoled && isDark
                  ? Colors.black
                  : Theme.of(context).colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white24, width: 1)
                    : BorderSide.none,
              ),
              contentPadding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 400,
                  maxHeight: MediaQuery.of(context).size.height * 0.8,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.image_rounded,
                        size: 32,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      const SizedBox(height: 16),
                      TranslatedText(
                        'artwork_quality',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w500,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: TranslatedText(
                          'artwork_quality_description',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withAlpha(180),
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 24),
                      _buildArtworkQualityOption(
                        context: context,
                        title: LocaleProvider.tr('100_percent_maximum'),
                        icon: Icons.high_quality,
                        value: 1024,
                        isSelected: _artworkQuality == 1024,
                      ),
                      _buildArtworkQualityOption(
                        context: context,
                        title: LocaleProvider.tr('80_percent_recommended'),
                        icon: Icons.recommend,
                        value: 410,
                        isSelected: _artworkQuality == 410,
                      ),
                      _buildArtworkQualityOption(
                        context: context,
                        title: LocaleProvider.tr('60_percent_performance'),
                        icon: Icons.speed,
                        value: 307,
                        isSelected: _artworkQuality == 307,
                      ),
                      _buildArtworkQualityOption(
                        context: context,
                        title: LocaleProvider.tr('40_percent_low'),
                        icon: Icons.low_priority,
                        value: 205,
                        isSelected: _artworkQuality == 205,
                      ),
                      _buildArtworkQualityOption(
                        context: context,
                        title: LocaleProvider.tr('20_percent_minimum'),
                        icon: Icons.compress,
                        value: 102,
                        isSelected: _artworkQuality == 102,
                      ),
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.only(right: 24, bottom: 8),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: TranslatedText(
                              'cancel',
                              style: TextStyle(
                                color: primaryColor,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildArtworkQualityOption({
    required BuildContext context,
    required String title,
    required IconData icon,
    required int value,
    required bool isSelected,
  }) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    final onPrimaryColor = Theme.of(context).colorScheme.onPrimary;
    final onSurfaceColor = Theme.of(context).colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: InkWell(
        onTap: () async {
          if (!isSelected) {
            await _setArtworkQuality(value);
          }
          if (context.mounted) Navigator.of(context).pop();
        },
        borderRadius: BorderRadius.circular(28),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            color: isSelected ? primaryColor : Colors.transparent,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                color: isSelected ? onPrimaryColor : onSurfaceColor,
                size: 24,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: isSelected
                        ? FontWeight.w600
                        : FontWeight.normal,
                    color: isSelected ? onPrimaryColor : onSurfaceColor,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isSelected)
                Icon(Icons.check_circle, color: onPrimaryColor, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _loadLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _currentLanguage = prefs.getString('app_language') ?? 'es';
    });
  }

  Future<void> _setLanguage(String lang) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_language', lang);
    LocaleProvider.setLanguage(lang);
    setState(() {
      _currentLanguage = lang;
    });
  }

  Future<void> _checkBatteryOptimization() async {
    if (!Platform.isAndroid) return;
    setState(() => _checkingBatteryOpt = true);
    final status = await Permission.ignoreBatteryOptimizations.status;
    setState(() {
      _batteryOptDisabled = status.isGranted;
      _checkingBatteryOpt = false;
    });
  }

  Future<void> _solicitarIgnorarOptimizacionDeBateria(
    BuildContext context,
  ) async {
    if (Platform.isAndroid) {
      final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
      final isDark = Theme.of(context).brightness == Brightness.dark;

      final status = await Permission.ignoreBatteryOptimizations.status;
      if (!status.isGranted) {
        final intent = AndroidIntent(
          action: 'android.settings.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
          data: 'package:com.kirby.aura',
          flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
        );
        await intent.launch();
        await Future.delayed(const Duration(seconds: 2));
        _checkBatteryOptimization();
      } else {
        if (context.mounted) {
          showDialog(
            context: context,
            builder: (context) {
              final primaryColor = Theme.of(context).colorScheme.primary;

              return AlertDialog(
                backgroundColor: isAmoled && isDark
                    ? Colors.black
                    : Theme.of(context).colorScheme.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                  side: isAmoled && isDark
                      ? const BorderSide(color: Colors.white24, width: 1)
                      : BorderSide.none,
                ),
                contentPadding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
                content: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: 400,
                    maxHeight: MediaQuery.of(context).size.height * 0.8,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.battery_saver_rounded,
                        size: 32,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      const SizedBox(height: 16),
                      TranslatedText(
                        'information',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w500,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: TranslatedText(
                          'battery_optimization_info',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withAlpha(180),
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Padding(
                        padding: const EdgeInsets.only(right: 24, bottom: 8),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: TranslatedText(
                              'ok',
                              style: TextStyle(
                                color: primaryColor,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        }
      }
    }
  }

  void _showThemeSelectionDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final primaryColor = Theme.of(context).colorScheme.primary;

            return AlertDialog(
              backgroundColor: isAmoled && isDark
                  ? Colors.black
                  : Theme.of(context).colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white24, width: 1)
                    : BorderSide.none,
              ),
              contentPadding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 400,
                  maxHeight: MediaQuery.of(context).size.height * 0.8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.palette_rounded,
                      size: 32,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    const SizedBox(height: 16),
                    TranslatedText(
                      'select_theme',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _buildThemeOption(
                      context: context,
                      title: LocaleProvider.tr('system_default'),
                      mode: AppThemeMode.system,
                      icon: Icons.brightness_auto_rounded,
                    ),
                    _buildThemeOption(
                      context: context,
                      title: LocaleProvider.tr('light_mode'),
                      mode: AppThemeMode.light,
                      icon: Icons.light_mode_rounded,
                    ),
                    _buildThemeOption(
                      context: context,
                      title: LocaleProvider.tr('dark_mode'),
                      mode: AppThemeMode.dark,
                      icon: Icons.dark_mode_rounded,
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.only(right: 24, bottom: 8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: TranslatedText(
                            'cancel',
                            style: TextStyle(
                              color: primaryColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildThemeOption({
    required BuildContext context,
    required String title,
    required AppThemeMode mode,
    required IconData icon,
  }) {
    final currentThemeText = _getCurrentThemeText(context);
    final isSelected = currentThemeText == title;
    final primaryColor = Theme.of(context).colorScheme.primary;
    final onPrimaryColor = Theme.of(context).colorScheme.onPrimary;
    final onSurfaceColor = Theme.of(context).colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: InkWell(
        onTap: () {
          if (!isSelected) {
            widget.setThemeMode?.call(mode);
          }
          Navigator.of(context).pop();
        },
        borderRadius: BorderRadius.circular(28),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            color: isSelected ? primaryColor : Colors.transparent,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Row(
            children: [
              Icon(
                isSelected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                color: isSelected ? onPrimaryColor : onSurfaceColor,
                size: 24,
              ),
              const SizedBox(width: 16),
              Icon(
                icon,
                color: isSelected ? onPrimaryColor : onSurfaceColor,
                size: 24,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: isSelected
                        ? FontWeight.w600
                        : FontWeight.normal,
                    color: isSelected ? onPrimaryColor : onSurfaceColor,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _getCurrentThemeText(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final platformBrightness = MediaQuery.of(context).platformBrightness;
    if (brightness == platformBrightness) {
      return LocaleProvider.tr('system_default');
    } else if (brightness == Brightness.light) {
      return LocaleProvider.tr('light_mode');
    } else {
      return LocaleProvider.tr('dark_mode');
    }
  }

  Future<void> _loadDownloadDirectory() async {
    final prefs = await SharedPreferences.getInstance();
    final savedPath =
        prefs.getString('download_directory') ?? '/storage/emulated/0/Music';

    // Guardar el directorio por defecto si no existe
    if (!prefs.containsKey('download_directory')) {
      await prefs.setString('download_directory', '/storage/emulated/0/Music');
    }

    setState(() {
      _downloadDirectory = savedPath;
    });
    downloadDirectoryNotifier.value = savedPath;
    _refreshAvailableSpace();
  }

  Future<void> _setDownloadDirectory(String? path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('download_directory', path ?? '');
    setState(() {
      _downloadDirectory = path;
    });
    downloadDirectoryNotifier.value = path;
    _refreshAvailableSpace();
  }

  // Métodos para manejar carpetas más usadas
  Future<void> _incrementFolderUsage(String path) async {
    final prefs = await SharedPreferences.getInstance();
    Map<String, int> folderUsage = {};

    // Obtener el mapa actual de uso de carpetas
    final usageList = prefs.getStringList('folder_usage') ?? [];

    if (usageList.isNotEmpty) {
      // Convertir la lista de vuelta a un mapa
      for (int i = 0; i < usageList.length - 1; i += 2) {
        final path = usageList[i];
        final usage = int.tryParse(usageList[i + 1]) ?? 0;
        folderUsage[path] = usage;
      }
    }

    // Incrementar el contador para esta carpeta
    folderUsage[path] = (folderUsage[path] ?? 0) + 1;

    // Guardar como lista de pares key-value
    final List<String> newUsageList = [];
    folderUsage.forEach((key, value) {
      newUsageList.add(key);
      newUsageList.add(value.toString());
    });

    await prefs.setStringList('folder_usage', newUsageList);
  }

  Future<List<String>> _getMostUsedFolders() async {
    final prefs = await SharedPreferences.getInstance();
    final usageList = prefs.getStringList('folder_usage') ?? [];

    if (usageList.isEmpty) return [];

    // Convertir la lista de vuelta a un mapa
    Map<String, int> folderUsage = {};
    for (int i = 0; i < usageList.length - 1; i += 2) {
      final path = usageList[i];
      final usage = int.tryParse(usageList[i + 1]) ?? 0;
      folderUsage[path] = usage;
    }

    // Ordenar por uso (mayor a menor) y tomar las 5 más usadas
    final sortedFolders = folderUsage.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return sortedFolders.take(5).map((e) => e.key).toList();
  }

  Future<void> _selectFolder(String path) async {
    await _setDownloadDirectory(path);
    await _incrementFolderUsage(path);
  }

  Future<void> _showFolderSelectionDialog() async {
    final commonFolders = await _getMostUsedFolders();

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final primaryColor = Theme.of(context).colorScheme.primary;

            return AlertDialog(
              backgroundColor: isAmoled && isDark
                  ? Colors.black
                  : Theme.of(context).colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white24, width: 1)
                    : BorderSide.none,
              ),
              contentPadding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 400,
                  maxHeight: MediaQuery.of(context).size.height * 0.8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.folder_special_rounded,
                      size: 32,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    const SizedBox(height: 16),
                    TranslatedText(
                      'select_common_folder',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (commonFolders.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 16,
                        ),
                        child: Text(
                          LocaleProvider.tr('no_common_folders'),
                          style: Theme.of(context).textTheme.bodyMedium,
                          textAlign: TextAlign.center,
                        ),
                      )
                    else
                      Flexible(
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: commonFolders
                                .map(
                                  (folder) => _buildFolderTile(
                                    context: context,
                                    folder: folder,
                                    isAmoled: isAmoled,
                                    isDark: isDark,
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: InkWell(
                        onTap: () async {
                          Navigator.of(context).pop();
                          await _pickNewFolder();
                        },
                        borderRadius: BorderRadius.circular(28),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 16,
                          ),
                          decoration: BoxDecoration(
                            color: isAmoled && isDark
                                ? Colors.white.withAlpha(20)
                                : Theme.of(context).colorScheme.primary,
                            borderRadius: BorderRadius.circular(28),
                            border: Border.all(
                              color: isAmoled && isDark
                                  ? Colors.white.withAlpha(40)
                                  : Theme.of(
                                      context,
                                    ).colorScheme.primary.withAlpha(40),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.folder_open_rounded,
                                color: isAmoled && isDark
                                    ? Colors.white
                                    : Theme.of(context).colorScheme.onPrimary,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  LocaleProvider.tr('choose_other_folder'),
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: isAmoled && isDark
                                        ? Colors.white
                                        : Theme.of(
                                            context,
                                          ).colorScheme.onPrimary,
                                  ),
                                ),
                              ),
                              Icon(
                                Icons.arrow_forward_ios_rounded,
                                size: 16,
                                color: isAmoled && isDark
                                    ? Colors.white
                                    : Theme.of(context).colorScheme.onPrimary,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.only(right: 24, bottom: 8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: TranslatedText(
                            'cancel',
                            style: TextStyle(
                              color: primaryColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildFolderTile({
    required BuildContext context,
    required String folder,
    required bool isAmoled,
    required bool isDark,
  }) {
    final folderName = folder.split('/').last.isEmpty
        ? folder
        : folder.split('/').last;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: InkWell(
        onTap: () {
          Navigator.of(context).pop();
          _selectFolder(folder);
        },
        borderRadius: BorderRadius.circular(28),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            color: Colors.transparent,
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withAlpha(20),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.folder_rounded,
                  color: Theme.of(context).colorScheme.primary,
                  size: 24,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      folderName,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      formatFolderPath(folder),
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withAlpha(150),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickNewFolder() async {
    try {
      final String? path = await getDirectoryPath();
      if (path != null && path.isNotEmpty) {
        await _selectFolder(path);
      }
    } catch (e) {
      // Fallback error handling
      if (Platform.isAndroid) {
        final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
        if (!mounted) return;
        final isDark = Theme.of(context).brightness == Brightness.dark;

        const defaultPath = '/storage/emulated/0/Music';
        await _selectFolder(defaultPath);

        if (mounted) {
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white, width: 1)
                    : BorderSide.none,
              ),
              title: Text(LocaleProvider.tr('information')),
              content: Text(LocaleProvider.tr('default_path_set')),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(LocaleProvider.tr('ok')),
                ),
              ],
            ),
          );
        }
      }
    }
  }

  Future<void> _pickDownloadDirectory() async {
    if (Platform.isAndroid) {
      // Check Android version
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      final sdkInt = androidInfo.version.sdkInt;
      final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
      if (!mounted) return;
      final isDark = Theme.of(context).brightness == Brightness.dark;

      // If Android 9 (API 28) or lower, use default Music folder
      if (sdkInt <= 28) {
        const defaultPath = '/storage/emulated/0/Music';
        await _setDownloadDirectory(defaultPath);

        if (mounted) {
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white, width: 1)
                    : BorderSide.none,
              ),
              title: Text(LocaleProvider.tr('information')),
              content: Text(LocaleProvider.tr('android_9_or_lower')),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(LocaleProvider.tr('ok')),
                ),
              ],
            ),
          );
        }
        return;
      }
    }

    // Mostrar diálogo con carpetas más usadas
    await _showFolderSelectionDialog();
  }

  Future<void> _loadDownloadType() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _downloadTypeExplode =
          prefs.getBool('download_type_explode') ??
          true; // Changed default to true
    });
    downloadTypeNotifier.value = _downloadTypeExplode;
  }

  Future<void> _loadCoverQuality() async {
    final prefs = await SharedPreferences.getInstance();
    final quality = prefs.getBool('cover_quality_high') ?? true;
    setState(() {
      _coverQualityHigh = quality;
    });
    // Actualizar el notifier global
    coverQualityNotifier.value = quality;
  }

  Future<void> _setCoverQuality(bool highQuality) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('cover_quality_high', highQuality);
    setState(() {
      _coverQualityHigh = highQuality;
    });
    // Actualizar el notifier global
    coverQualityNotifier.value = highQuality;
  }

  Future<void> _loadAudioQuality() async {
    final prefs = await SharedPreferences.getInstance();
    final quality = prefs.getString('audio_quality') ?? 'high';
    setState(() {
      _audioQuality = quality;
    });
    // Actualizar el notifier global
    audioQualityNotifier.value = quality;
  }

  Future<void> _setAudioQuality(String quality) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('audio_quality', quality);
    setState(() {
      _audioQuality = quality;
    });
    // Actualizar el notifier global
    audioQualityNotifier.value = quality;
  }

  Future<void> _showAudioQualitySelection() async {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final primaryColor = Theme.of(context).colorScheme.primary;

            return AlertDialog(
              backgroundColor: isAmoled && isDark
                  ? Colors.black
                  : Theme.of(context).colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white24, width: 1)
                    : BorderSide.none,
              ),
              contentPadding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 400,
                  maxHeight: MediaQuery.of(context).size.height * 0.8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.high_quality_rounded,
                      size: 32,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    const SizedBox(height: 16),
                    TranslatedText(
                      'audio_quality',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: TranslatedText(
                        'audio_quality_desc',
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withAlpha(180),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _buildAudioQualityOption(
                      context: context,
                      title: LocaleProvider.tr('audio_quality_high'),
                      subtitle: LocaleProvider.tr('audio_quality_high_desc'),
                      value: 'high',
                      isSelected: _audioQuality == 'high',
                    ),
                    _buildAudioQualityOption(
                      context: context,
                      title: LocaleProvider.tr('audio_quality_medium'),
                      subtitle: LocaleProvider.tr('audio_quality_medium_desc'),
                      value: 'medium',
                      isSelected: _audioQuality == 'medium',
                    ),
                    _buildAudioQualityOption(
                      context: context,
                      title: LocaleProvider.tr('audio_quality_low'),
                      subtitle: LocaleProvider.tr('audio_quality_low_desc'),
                      value: 'low',
                      isSelected: _audioQuality == 'low',
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.only(right: 24, bottom: 8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: TranslatedText(
                            'cancel',
                            style: TextStyle(
                              color: primaryColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildAudioQualityOption({
    required BuildContext context,
    required String title,
    required String subtitle,
    required String value,
    required bool isSelected,
  }) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    final onPrimaryColor = Theme.of(context).colorScheme.onPrimary;
    final onSurfaceColor = Theme.of(context).colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: InkWell(
        onTap: () async {
          if (!isSelected) {
            await _setAudioQuality(value);
          }
          if (context.mounted) Navigator.of(context).pop();
        },
        borderRadius: BorderRadius.circular(28),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: isSelected ? primaryColor : Colors.transparent,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Row(
            children: [
              Icon(
                isSelected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                color: isSelected ? onPrimaryColor : onSurfaceColor,
                size: 24,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: isSelected
                            ? FontWeight.w600
                            : FontWeight.normal,
                        color: isSelected ? onPrimaryColor : onSurfaceColor,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: isSelected
                            ? onPrimaryColor.withAlpha(200)
                            : onSurfaceColor.withAlpha(150),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showCoverQualitySelection() async {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final primaryColor = Theme.of(context).colorScheme.primary;

            return AlertDialog(
              backgroundColor: isAmoled && isDark
                  ? Colors.black
                  : Theme.of(context).colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white24, width: 1)
                    : BorderSide.none,
              ),
              contentPadding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 400,
                  maxHeight: MediaQuery.of(context).size.height * 0.8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.image_rounded,
                      size: 32,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    const SizedBox(height: 16),
                    TranslatedText(
                      'cover_quality',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: TranslatedText(
                        'cover_quality_desc',
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withAlpha(180),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _buildCoverQualityOption(
                      context: context,
                      title: LocaleProvider.tr('high_quality'),
                      value: true,
                      isSelected: _coverQualityHigh,
                    ),
                    _buildCoverQualityOption(
                      context: context,
                      title: LocaleProvider.tr('low_quality'),
                      value: false,
                      isSelected: !_coverQualityHigh,
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.only(right: 24, bottom: 8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: TranslatedText(
                            'cancel',
                            style: TextStyle(
                              color: primaryColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildCoverQualityOption({
    required BuildContext context,
    required String title,
    required bool value,
    required bool isSelected,
  }) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    final onPrimaryColor = Theme.of(context).colorScheme.onPrimary;
    final onSurfaceColor = Theme.of(context).colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: InkWell(
        onTap: () async {
          if (!isSelected) {
            await _setCoverQuality(value);
          }
          if (context.mounted) Navigator.of(context).pop();
        },
        borderRadius: BorderRadius.circular(28),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            color: isSelected ? primaryColor : Colors.transparent,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Row(
            children: [
              Icon(
                isSelected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                color: isSelected ? onPrimaryColor : onSurfaceColor,
                size: 24,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: isSelected
                        ? FontWeight.w600
                        : FontWeight.normal,
                    color: isSelected ? onPrimaryColor : onSurfaceColor,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _refreshAvailableSpace() async {
    try {
      if (Platform.isAndroid) {
        const channel = MethodChannel('com.kirby.aura/storage');
        final stats = await channel.invokeMethod<Map<dynamic, dynamic>>(
          'getStorageStats',
          {'path': _downloadDirectory ?? '/storage/emulated/0'},
        );
        if (mounted) {
          setState(() {
            _availableBytesAtDownloadDir = (stats?['availableBytes'] as num?)
                ?.toInt();
            _totalBytesAtDownloadDir = (stats?['totalBytes'] as num?)?.toInt();
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _availableBytesAtDownloadDir = null;
            _totalBytesAtDownloadDir = null;
          });
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _availableBytesAtDownloadDir = null;
          _totalBytesAtDownloadDir = null;
        });
      }
    }
  }

  String _formatBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    double size = bytes.toDouble();
    int unitIndex = 0;
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex++;
    }
    return unitIndex <= 1
        ? '${size.toStringAsFixed(0)} ${units[unitIndex]}'
        : '${size.toStringAsFixed(1)} ${units[unitIndex]}';
  }

  Future<void> _setDownloadType(bool explode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('download_type_explode', explode);
    setState(() {
      _downloadTypeExplode = explode;
    });
    downloadTypeNotifier.value = explode;
  }

  // Función para mostrar selección de método de descarga con el mismo diseño
  Future<void> _showDownloadTypeSelection() async {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final primaryColor = Theme.of(context).colorScheme.primary;

            return AlertDialog(
              backgroundColor: isAmoled && isDark
                  ? Colors.black
                  : Theme.of(context).colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white24, width: 1)
                    : BorderSide.none,
              ),
              contentPadding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 400,
                  maxHeight: MediaQuery.of(context).size.height * 0.8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.download_for_offline_rounded,
                      size: 32,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    const SizedBox(height: 16),
                    TranslatedText(
                      'download_type',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: TranslatedText(
                        'download_type_desc',
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withAlpha(180),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _buildDownloadTypeOption(
                      context: context,
                      title: LocaleProvider.tr('explode'),
                      value: true,
                      isSelected: _downloadTypeExplode,
                    ),
                    _buildDownloadTypeOption(
                      context: context,
                      title: LocaleProvider.tr('direct'),
                      value: false,
                      isSelected: !_downloadTypeExplode,
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.only(right: 24, bottom: 8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: TranslatedText(
                            'cancel',
                            style: TextStyle(
                              color: primaryColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildDownloadTypeOption({
    required BuildContext context,
    required String title,
    required bool value,
    required bool isSelected,
  }) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    final onPrimaryColor = Theme.of(context).colorScheme.onPrimary;
    final onSurfaceColor = Theme.of(context).colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: InkWell(
        onTap: () async {
          if (!isSelected) {
            await _setDownloadType(value);
          }
          if (context.mounted) Navigator.of(context).pop();
        },
        borderRadius: BorderRadius.circular(28),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            color: isSelected ? primaryColor : Colors.transparent,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Row(
            children: [
              Icon(
                isSelected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                color: isSelected ? onPrimaryColor : onSurfaceColor,
                size: 24,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: isSelected
                        ? FontWeight.w600
                        : FontWeight.normal,
                    color: isSelected ? onPrimaryColor : onSurfaceColor,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showLanguageDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final primaryColor = Theme.of(context).colorScheme.primary;

            return AlertDialog(
              backgroundColor: isAmoled && isDark
                  ? Colors.black
                  : Theme.of(context).colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white24, width: 1)
                    : BorderSide.none,
              ),
              contentPadding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 400,
                  maxHeight: MediaQuery.of(context).size.height * 0.8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.language_rounded),
                    const SizedBox(height: 16),
                    TranslatedText(
                      'change_language',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _buildLanguageOption(
                      context: context,
                      title: LocaleProvider.tr('spanish'),
                      value: 'es',
                      isSelected: _currentLanguage == 'es',
                    ),
                    _buildLanguageOption(
                      context: context,
                      title: LocaleProvider.tr('english'),
                      value: 'en',
                      isSelected: _currentLanguage == 'en',
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.only(right: 24, bottom: 8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: TranslatedText(
                            'cancel',
                            style: TextStyle(
                              color: primaryColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildLanguageOption({
    required BuildContext context,
    required String title,
    required String value,
    required bool isSelected,
  }) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    final onPrimaryColor = Theme.of(context).colorScheme.onPrimary;
    final onSurfaceColor = Theme.of(context).colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: InkWell(
        onTap: () {
          if (!isSelected) {
            _setLanguage(value);
          }
          Navigator.of(context).pop();
        },
        borderRadius: BorderRadius.circular(28),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            color: isSelected ? primaryColor : Colors.transparent,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Row(
            children: [
              Icon(
                isSelected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                color: isSelected ? onPrimaryColor : onSurfaceColor,
                size: 24,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: isSelected
                        ? FontWeight.w600
                        : FontWeight.normal,
                    color: isSelected ? onPrimaryColor : onSurfaceColor,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showGestureSettingsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => const GestureSettingsDialog(),
    );
  }

  void _showTranslationLanguageDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final primaryColor = Theme.of(context).colorScheme.primary;

            return AlertDialog(
              backgroundColor: isAmoled && isDark
                  ? Colors.black
                  : Theme.of(context).colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white24, width: 1)
                    : BorderSide.none,
              ),
              contentPadding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 400,
                  maxHeight: MediaQuery.of(context).size.height * 0.8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.translate_rounded,
                      size: 32,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    const SizedBox(height: 16),
                    TranslatedText(
                      'translation_language',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: TranslatedText(
                        'translation_language_desc',
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withAlpha(180),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildTranslationLanguageOption(
                              context: context,
                              title: LocaleProvider.tr('auto_detect'),
                              icon: Icons.auto_awesome_rounded,
                              code: 'auto',
                            ),
                            _buildTranslationLanguageOption(
                              context: context,
                              title: LocaleProvider.tr('language_spanish'),
                              icon: Icons.translate_rounded,
                              code: 'es',
                            ),
                            _buildTranslationLanguageOption(
                              context: context,
                              title: LocaleProvider.tr('language_english'),
                              icon: Icons.translate_rounded,
                              code: 'en',
                            ),
                            _buildTranslationLanguageOption(
                              context: context,
                              title: LocaleProvider.tr('language_french'),
                              icon: Icons.translate_rounded,
                              code: 'fr',
                            ),
                            _buildTranslationLanguageOption(
                              context: context,
                              title: LocaleProvider.tr('language_german'),
                              icon: Icons.translate_rounded,
                              code: 'de',
                            ),
                            _buildTranslationLanguageOption(
                              context: context,
                              title: LocaleProvider.tr('language_italian'),
                              icon: Icons.translate_rounded,
                              code: 'it',
                            ),
                            _buildTranslationLanguageOption(
                              context: context,
                              title: LocaleProvider.tr('language_portuguese'),
                              icon: Icons.translate_rounded,
                              code: 'pt',
                            ),
                            _buildTranslationLanguageOption(
                              context: context,
                              title: LocaleProvider.tr('language_japanese'),
                              icon: Icons.translate_rounded,
                              code: 'ja',
                            ),
                            _buildTranslationLanguageOption(
                              context: context,
                              title: LocaleProvider.tr('language_korean'),
                              icon: Icons.translate_rounded,
                              code: 'ko',
                            ),
                            _buildTranslationLanguageOption(
                              context: context,
                              title: LocaleProvider.tr('language_chinese'),
                              icon: Icons.translate_rounded,
                              code: 'zh',
                            ),
                            _buildTranslationLanguageOption(
                              context: context,
                              title: LocaleProvider.tr('language_russian'),
                              icon: Icons.translate_rounded,
                              code: 'ru',
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.only(right: 24, bottom: 8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: TranslatedText(
                            'cancel',
                            style: TextStyle(
                              color: primaryColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildTranslationLanguageOption({
    required BuildContext context,
    required String title,
    required IconData icon,
    required String code,
  }) {
    final isSelected = translationLanguageNotifier.value == code;
    final primaryColor = Theme.of(context).colorScheme.primary;
    final onPrimaryColor = Theme.of(context).colorScheme.onPrimary;
    final onSurfaceColor = Theme.of(context).colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: InkWell(
        onTap: () async {
          if (!isSelected) {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('translation_language', code);
            translationLanguageNotifier.value = code;
          }
          if (context.mounted) Navigator.of(context).pop();
        },
        borderRadius: BorderRadius.circular(28),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            color: isSelected ? primaryColor : Colors.transparent,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                color: isSelected ? onPrimaryColor : onSurfaceColor,
                size: 24,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: isSelected
                        ? FontWeight.w600
                        : FontWeight.normal,
                    color: isSelected ? onPrimaryColor : onSurfaceColor,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isSelected)
                Icon(Icons.check_circle, color: onPrimaryColor, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  // Función para mostrar confirmación de eliminación de letras con el mismo diseño
  Future<void> _showDeleteLyricsConfirmation() async {
    showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final primaryColor = Theme.of(context).colorScheme.primary;

            return AlertDialog(
              backgroundColor: isAmoled && isDark
                  ? Colors.black
                  : Theme.of(context).colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white24, width: 1)
                    : BorderSide.none,
              ),
              contentPadding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 400,
                  maxHeight: MediaQuery.of(context).size.height * 0.8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.delete_sweep_rounded,
                      size: 32,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(height: 16),
                    TranslatedText(
                      'delete_lyrics',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: TranslatedText(
                        'delete_lyrics_confirm',
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withAlpha(180),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _buildDestructiveOption(
                      context: context,
                      title: LocaleProvider.tr('delete'),
                      icon: Icons.delete_forever_rounded,
                      onTap: () async {
                        Navigator.of(context).pop(true);
                        await SyncedLyricsService.clearLyrics();
                        if (context.mounted) {
                          _showLyricsDeletedDialog();
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.only(right: 24, bottom: 8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: TranslatedText(
                            'cancel',
                            style: TextStyle(
                              color: primaryColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildDestructiveOption({
    required BuildContext context,
    required String title,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    final errorContainer = Theme.of(context).colorScheme.error;
    final onErrorContainer = Theme.of(context).colorScheme.onError;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(28),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            color: errorContainer,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Row(
            children: [
              Icon(icon, color: onErrorContainer, size: 24),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: onErrorContainer,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Función para mostrar diálogo de letras eliminadas
  void _showLyricsDeletedDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final primaryColor = Theme.of(context).colorScheme.primary;

            return AlertDialog(
              backgroundColor: isAmoled && isDark
                  ? Colors.black
                  : Theme.of(context).colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white24, width: 1)
                    : BorderSide.none,
              ),
              contentPadding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 400,
                  maxHeight: MediaQuery.of(context).size.height * 0.8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.check_circle_rounded,
                      size: 32,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    const SizedBox(height: 16),
                    TranslatedText(
                      'lyrics_deleted',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: TranslatedText(
                        'lyrics_deleted_desc',
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withAlpha(180),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Padding(
                      padding: const EdgeInsets.only(right: 24, bottom: 8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: TranslatedText(
                            'ok',
                            style: TextStyle(
                              color: primaryColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _loadColorScheme() async {
    final savedColorScheme = await ThemePreferences.getColorScheme();
    setState(() {
      _currentColorScheme = savedColorScheme;
    });
  }

  void _showColorSelectionDialog(BuildContext context) {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
          side: isAmoled && isDark
              ? const BorderSide(color: Colors.white24, width: 1)
              : BorderSide.none,
        ),
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.color_lens_rounded,
              size: 32,
              color: Theme.of(context).colorScheme.onSurface,
            ),
            const SizedBox(height: 16),
            Text(
              LocaleProvider.tr('select_color'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: GridView.builder(
            shrinkWrap: true,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 1,
            ),
            itemCount: AppColorScheme.values.length,
            itemBuilder: (context, index) {
              final colorScheme = AppColorScheme.values[index];
              final isSelected = colorScheme == _currentColorScheme;

              // Para el color del sistema, mostrar un gradiente multicolor
              Widget circleWidget;

              if (colorScheme == AppColorScheme.system) {
                circleWidget = Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      colors: [
                        Colors.red,
                        Colors.orange,
                        Colors.yellow,
                        Colors.green,
                        Colors.blue,
                        Colors.indigo,
                        Colors.purple,
                      ],
                      stops: [0.0, 0.16, 0.33, 0.5, 0.66, 0.83, 1.0],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    border: Border.all(
                      color: isSelected ? Colors.white : Colors.transparent,
                      width: 3,
                    ),
                  ),
                  child: isSelected
                      ? const Icon(Icons.check, color: Colors.white, size: 24)
                      : const Icon(
                          Icons.auto_awesome,
                          color: Colors.white,
                          size: 20,
                        ),
                );
              } else {
                final displayColor = ThemePreferences.getColorFromScheme(
                  colorScheme,
                );
                circleWidget = Container(
                  decoration: BoxDecoration(
                    color: displayColor,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected ? Colors.white : Colors.transparent,
                      width: 3,
                    ),
                  ),
                  child: isSelected
                      ? const Icon(Icons.check, color: Colors.white, size: 24)
                      : null,
                );
              }

              return GestureDetector(
                onTap: () {
                  setState(() {
                    _currentColorScheme = colorScheme;
                  });
                  widget.setColorScheme?.call(colorScheme);
                  Navigator.of(context).pop();
                },
                child: circleWidget,
              );
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // final isSystem = colorSchemeNotifier.value == AppColorScheme.system;
    final cardColor = isAmoled
        ? Colors.white.withAlpha(20)
        : isDark
        ? Theme.of(context).colorScheme.secondary.withValues(alpha: 0.06)
        : Theme.of(context).colorScheme.secondary.withValues(alpha: 0.07);

    return Scaffold(
      extendBody: true,
      bottomNavigationBar: SizedBox(
        height: MediaQuery.of(context).padding.bottom,
        child: GestureDetector(
          onVerticalDragStart: (_) {},
          behavior: HitTestBehavior.translucent,
        ),
      ),
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: TranslatedText(
          'settings',
          style: TextStyle(fontWeight: FontWeight.w500),
        ),
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
        // Icono de información
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline, size: 26),
            onPressed: () => _showInfoDialog(context),
            tooltip: LocaleProvider.tr('information'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.of(context).padding.bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Preferencias
            Row(
              children: [
                const SizedBox(width: 14),
                TranslatedText(
                  'preferences',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Card(
              color: cardColor,
              margin: EdgeInsets.zero,
              elevation: 0,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(20),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(
                      Theme.of(context).brightness == Brightness.dark
                          ? Icons.dark_mode_rounded
                          : Icons.light_mode_rounded,
                      fill: 1,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    title: TranslatedText(
                      'select_theme',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    subtitle: TranslatedText(
                      _getCurrentThemeText(context),
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(16),
                        topRight: Radius.circular(16),
                        bottomLeft: Radius.circular(4),
                        bottomRight: Radius.circular(4),
                      ),
                    ),
                    onTap: () => _showThemeSelectionDialog(context),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Card(
              color: cardColor,
              margin: EdgeInsets.zero,
              elevation: 0,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(4),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(
                      Icons.palette,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    title: Text(
                      LocaleProvider.tr('select_color'),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    subtitle: Text(
                      ThemePreferences.getColorName(_currentColorScheme),
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(4)),
                    ),
                    onTap: () => _showColorSelectionDialog(context),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Card(
              color: cardColor,
              margin: EdgeInsets.zero,
              elevation: 0,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(4)),
              ),
              child: ListTile(
                onTap: _showArtworkBackgroundDialog,
                title: TranslatedText(
                  'use_artwork_as_background',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                subtitle: TranslatedText(
                  'use_artwork_as_background_desc',
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.9),
                  ),
                ),
                leading: Icon(
                  Icons.image_outlined,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(4)),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Card(
              color: cardColor,
              margin: EdgeInsets.zero,
              elevation: 0,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(4),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(
                      Icons.language,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    title: TranslatedText(
                      'change_language',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    subtitle: TranslatedText(
                      _currentLanguage == 'es' ? 'spanish' : 'english',
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(4)),
                    ),
                    onTap: () => _showLanguageDialog(context),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Card(
              color: cardColor,
              margin: EdgeInsets.zero,
              elevation: 0,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(4),
                  bottomLeft: Radius.circular(20),
                  bottomRight: Radius.circular(20),
                ),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(
                      Icons.touch_app,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    title: TranslatedText(
                      'gesture_settings',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    subtitle: TranslatedText(
                      'gesture_settings_desc',
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(4),
                        topRight: Radius.circular(4),
                        bottomLeft: Radius.circular(16),
                        bottomRight: Radius.circular(16),
                      ),
                    ),
                    onTap: () => _showGestureSettingsDialog(context),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Descargas
            Row(
              children: [
                const SizedBox(width: 14),
                TranslatedText(
                  'downloads',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Card(
              color: cardColor,
              margin: EdgeInsets.zero,
              elevation: 0,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(20),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(
                      Icons.sd_storage,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    title: Text(
                      _availableBytesAtDownloadDir != null &&
                              _totalBytesAtDownloadDir != null
                          ? '${_formatBytes(_availableBytesAtDownloadDir!)} ${LocaleProvider.tr('free_of')} ${_formatBytes(_totalBytesAtDownloadDir!)}'
                          : LocaleProvider.tr('calculating'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    subtitle:
                        (_availableBytesAtDownloadDir != null &&
                            _totalBytesAtDownloadDir != null)
                        ? Padding(
                            padding: const EdgeInsets.only(top: 8, right: 0),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: LinearProgressIndicator(
                                // ignore: deprecated_member_use
                                year2023: false,
                                value: (_totalBytesAtDownloadDir! > 0)
                                    ? (1 -
                                          (_availableBytesAtDownloadDir! /
                                              _totalBytesAtDownloadDir!))
                                    : null,
                                minHeight: 6,
                                backgroundColor: Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.3),
                              ),
                            ),
                          )
                        : null,
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(16),
                        topRight: Radius.circular(16),
                        bottomLeft: Radius.circular(4),
                        bottomRight: Radius.circular(4),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Card(
              color: cardColor,
              margin: EdgeInsets.zero,
              elevation: 0,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(4),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(
                      Icons.folder,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    title: TranslatedText(
                      'save_path',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    subtitle:
                        _downloadDirectory != null &&
                            _downloadDirectory!.isNotEmpty
                        ? Text(
                            _downloadDirectory!.startsWith(
                                  '/storage/emulated/0',
                                )
                                ? _downloadDirectory!.replaceFirst(
                                    '/storage/emulated/0',
                                    '',
                                  )
                                : _downloadDirectory!,
                            style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurface.withValues(alpha: 0.9),
                            ),
                            overflow: TextOverflow.ellipsis,
                          )
                        : TranslatedText(
                            'not_selected',
                            style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurface.withValues(alpha: 0.9),
                            ),
                          ),
                    trailing: Icon(
                      Icons.edit,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(4)),
                    ),
                    onTap: _pickDownloadDirectory,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Card(
              color: cardColor,
              margin: EdgeInsets.zero,
              elevation: 0,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(4),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(
                      Icons.download,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    title: TranslatedText(
                      'download_type',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    subtitle: TranslatedText(
                      'download_type_desc',
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                    trailing: IconButton(
                      icon: Icon(
                        Icons.arrow_drop_down,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      onPressed: () => _showDownloadTypeSelection(),
                    ),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(4)),
                    ),
                    onTap: () => _showDownloadTypeSelection(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Card(
              color: cardColor,
              margin: EdgeInsets.zero,
              elevation: 0,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(4),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(
                      Icons.audiotrack,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    title: TranslatedText(
                      'audio_quality',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    subtitle: TranslatedText(
                      'audio_quality_desc',
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                    trailing: IconButton(
                      icon: Icon(
                        Icons.arrow_drop_down,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      onPressed: () => _showAudioQualitySelection(),
                    ),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(4)),
                    ),
                    onTap: () => _showAudioQualitySelection(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Card(
              color: cardColor,
              margin: EdgeInsets.zero,
              elevation: 0,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(4),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(
                      Icons.add_photo_alternate,
                      weight: 600,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    title: TranslatedText(
                      'cover_quality',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    subtitle: TranslatedText(
                      'cover_quality_desc',
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                    trailing: IconButton(
                      icon: Icon(
                        Icons.arrow_drop_down,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      onPressed: () => _showCoverQualitySelection(),
                    ),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(4)),
                    ),
                    onTap: () => _showCoverQualitySelection(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Card(
              color: cardColor,
              margin: EdgeInsets.zero,
              elevation: 0,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(4),
                  bottomLeft: Radius.circular(20),
                  bottomRight: Radius.circular(20),
                ),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(
                      Icons.security,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    title: Text(
                      LocaleProvider.tr('grant_all_files_permission'),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    subtitle: Text(
                      LocaleProvider.tr('grant_all_files_permission_desc'),
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(4),
                        topRight: Radius.circular(4),
                        bottomLeft: Radius.circular(16),
                        bottomRight: Radius.circular(16),
                      ),
                    ),
                    onTap: () async {
                      final status = await Permission.manageExternalStorage
                          .request();
                      if (context.mounted) {
                        showDialog(
                          context: context,
                          builder: (context) {
                            final primaryColor = Theme.of(
                              context,
                            ).colorScheme.primary;
                            final errorColor = Theme.of(
                              context,
                            ).colorScheme.error;

                            return AlertDialog(
                              backgroundColor: isAmoled && isDark
                                  ? Colors.black
                                  : Theme.of(context).colorScheme.surface,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(28),
                                side: isAmoled && isDark
                                    ? const BorderSide(
                                        color: Colors.white24,
                                        width: 1,
                                      )
                                    : BorderSide.none,
                              ),
                              contentPadding: const EdgeInsets.fromLTRB(
                                0,
                                24,
                                0,
                                8,
                              ),
                              content: ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: 400,
                                  maxHeight:
                                      MediaQuery.of(context).size.height * 0.8,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      status.isGranted
                                          ? Icons.check_circle_rounded
                                          : Icons.error_rounded,
                                      size: 32,
                                      color: status.isGranted
                                          ? Theme.of(
                                              context,
                                            ).colorScheme.onSurface
                                          : errorColor,
                                    ),
                                    const SizedBox(height: 16),
                                    TranslatedText(
                                      status.isGranted
                                          ? 'permission_granted'
                                          : 'permission_denied',
                                      style: TextStyle(
                                        fontSize: 24,
                                        fontWeight: FontWeight.w500,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurface,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                    const SizedBox(height: 16),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 24,
                                      ),
                                      child: TranslatedText(
                                        status.isGranted
                                            ? 'permission_granted_desc'
                                            : 'permission_denied_desc',
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withAlpha(180),
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                    const SizedBox(height: 24),
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        right: 24,
                                        bottom: 8,
                                      ),
                                      child: Align(
                                        alignment: Alignment.centerRight,
                                        child: TextButton(
                                          onPressed: () =>
                                              Navigator.of(context).pop(),
                                          child: TranslatedText(
                                            'ok',
                                            style: TextStyle(
                                              color: primaryColor,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Música y reproducción
            Row(
              children: [
                const SizedBox(width: 14),
                TranslatedText(
                  'music_and_playback',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Card(
              color: cardColor,
              margin: EdgeInsets.zero,
              elevation: 0,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(20),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(
                      Icons.image,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    title: Text(
                      LocaleProvider.tr('artwork_quality'),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _artworkQuality == 1024
                              ? LocaleProvider.tr('100_percent_maximum')
                              : _artworkQuality == 410
                              ? LocaleProvider.tr('80_percent_recommended')
                              : _artworkQuality == 307
                              ? LocaleProvider.tr('60_percent_performance')
                              : _artworkQuality == 205
                              ? LocaleProvider.tr('40_percent_low')
                              : LocaleProvider.tr('20_percent_minimum'),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.9),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          LocaleProvider.tr(
                            'artwork_quality_description',
                          ), // Agrega esta key en tus traducciones
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.9),
                          ),
                        ),
                      ],
                    ),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(16),
                        topRight: Radius.circular(16),
                        bottomLeft: Radius.circular(4),
                        bottomRight: Radius.circular(4),
                      ),
                    ),
                    onTap: () => _showArtworkQualityDialog(context),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Card(
              color: cardColor,
              margin: EdgeInsets.zero,
              elevation: 0,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(4),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: Column(
                children: [
                  FutureBuilder<SharedPreferences>(
                    future: SharedPreferences.getInstance(),
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) return SizedBox.shrink();
                      final prefs = snapshot.data!;
                      final value =
                          prefs.getBool('index_songs_on_startup') ?? true;
                      return SwitchListTile(
                        value: value,
                        onChanged: (v) async {
                          await prefs.setBool('index_songs_on_startup', v);
                          setState(() {});
                        },
                        title: Text(
                          LocaleProvider.tr('index_songs_on_startup'),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        subtitle: Text(
                          LocaleProvider.tr('index_songs_on_startup_desc'),
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.9),
                          ),
                        ),
                        secondary: Icon(
                          Icons.library_music,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.all(Radius.circular(4)),
                        ),
                        thumbIcon: WidgetStateProperty.resolveWith<Icon?>((
                          Set<WidgetState> states,
                        ) {
                          final iconColor = isAmoled && isDark
                              ? Colors.white
                              : null;
                          if (states.contains(WidgetState.selected)) {
                            return Icon(
                              Icons.check,
                              size: 20,
                              color: iconColor,
                            );
                          } else {
                            return const Icon(Icons.close, size: 20);
                          }
                        }),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Card(
              color: cardColor,
              margin: EdgeInsets.zero,
              elevation: 0,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(4),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: Column(
                children: [
                  FutureBuilder<SharedPreferences>(
                    future: SharedPreferences.getInstance(),
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) return SizedBox.shrink();
                      final prefs = snapshot.data!;
                      final value =
                          prefs.getBool('show_lyrics_on_cover') ?? false;
                      return SwitchListTile(
                        value: value,
                        onChanged: (v) async {
                          await prefs.setBool('show_lyrics_on_cover', v);
                          setState(() {});
                        },
                        title: Text(
                          LocaleProvider.tr('show_lyrics_on_cover'),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        subtitle: Text(
                          LocaleProvider.tr('show_lyrics_on_cover_desc'),
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.9),
                          ),
                        ),
                        secondary: Icon(
                          Icons.font_download_outlined,
                          weight: 600,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.all(Radius.circular(4)),
                        ),
                        thumbIcon: WidgetStateProperty.resolveWith<Icon?>((
                          Set<WidgetState> states,
                        ) {
                          final iconColor = isAmoled && isDark
                              ? Colors.white
                              : null;
                          if (states.contains(WidgetState.selected)) {
                            return Icon(
                              Icons.check,
                              size: 20,
                              color: iconColor,
                            );
                          } else {
                            return const Icon(Icons.close, size: 20);
                          }
                        }),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Card(
              color: cardColor,
              margin: EdgeInsets.zero,
              elevation: 0,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(4),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: Column(
                children: [
                  ListTile(
                    title: Text(
                      LocaleProvider.tr('translation_language'),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    subtitle: ValueListenableBuilder<String>(
                      valueListenable: translationLanguageNotifier,
                      builder: (context, currentLanguage, child) {
                        String displayText;
                        switch (currentLanguage) {
                          case 'auto':
                            displayText = LocaleProvider.tr('auto_detect');
                            break;
                          case 'es':
                            displayText = LocaleProvider.tr('language_spanish');
                            break;
                          case 'en':
                            displayText = LocaleProvider.tr('language_english');
                            break;
                          case 'fr':
                            displayText = LocaleProvider.tr('language_french');
                            break;
                          case 'de':
                            displayText = LocaleProvider.tr('language_german');
                            break;
                          case 'it':
                            displayText = LocaleProvider.tr('language_italian');
                            break;
                          case 'pt':
                            displayText = LocaleProvider.tr(
                              'language_portuguese',
                            );
                            break;
                          case 'ja':
                            displayText = LocaleProvider.tr(
                              'language_japanese',
                            );
                            break;
                          case 'ko':
                            displayText = LocaleProvider.tr('language_korean');
                            break;
                          case 'zh':
                            displayText = LocaleProvider.tr('language_chinese');
                            break;
                          case 'ru':
                            displayText = LocaleProvider.tr('language_russian');
                            break;
                          default:
                            displayText = LocaleProvider.tr('auto_detect');
                        }
                        return Text(
                          displayText,
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.9),
                          ),
                        );
                      },
                    ),
                    leading: Icon(
                      Icons.translate,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(4)),
                    ),
                    onTap: () => _showTranslationLanguageDialog(context),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Card(
              color: cardColor,
              margin: EdgeInsets.zero,
              elevation: 0,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(4),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: Column(
                children: [
                  ValueListenableBuilder<bool>(
                    valueListenable: heroAnimationNotifier,
                    builder: (context, value, child) {
                      return SwitchListTile(
                        value: value,
                        onChanged: (v) async {
                          final prefs = await SharedPreferences.getInstance();
                          await prefs.setBool('use_hero_animation', v);
                          heroAnimationNotifier.value = v;
                          setState(() {});
                        },
                        title: Text(
                          LocaleProvider.tr('hero_animation'),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        subtitle: Text(
                          LocaleProvider.tr('hero_animation_desc'),
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.9),
                          ),
                        ),
                        secondary: Icon(
                          Icons.animation,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.all(Radius.circular(4)),
                        ),
                        thumbIcon: WidgetStateProperty.resolveWith<Icon?>((
                          Set<WidgetState> states,
                        ) {
                          final iconColor = isAmoled && isDark
                              ? Colors.white
                              : null;
                          if (states.contains(WidgetState.selected)) {
                            return Icon(
                              Icons.check,
                              size: 20,
                              color: iconColor,
                            );
                          } else {
                            return const Icon(Icons.close, size: 20);
                          }
                        }),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Card(
              color: cardColor,
              margin: EdgeInsets.zero,
              elevation: 0,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(4),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: Column(
                children: [
                  ValueListenableBuilder<bool>(
                    valueListenable: overlayNextButtonEnabled,
                    builder: (context, value, child) {
                      return SwitchListTile(
                        value: value,
                        onChanged: (v) async {
                          final prefs = await SharedPreferences.getInstance();
                          await prefs.setBool('overlay_next_button_enabled', v);
                          overlayNextButtonEnabled.value = v;
                          setState(() {});
                        },
                        title: Text(
                          LocaleProvider.tr('overlay_next_button'),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        subtitle: Text(
                          LocaleProvider.tr('overlay_next_button_desc'),
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.9),
                          ),
                        ),
                        secondary: Icon(
                          Icons.skip_next_rounded,
                          grade: 200,
                          fill: 1,
                          size: 28,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.all(Radius.circular(4)),
                        ),
                        thumbIcon: WidgetStateProperty.resolveWith<Icon?>((
                          Set<WidgetState> states,
                        ) {
                          final iconColor = isAmoled && isDark
                              ? Colors.white
                              : null;
                          if (states.contains(WidgetState.selected)) {
                            return Icon(
                              Icons.check,
                              size: 20,
                              color: iconColor,
                            );
                          } else {
                            return const Icon(Icons.close, size: 20);
                          }
                        }),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Card(
              color: cardColor,
              margin: EdgeInsets.zero,
              elevation: 0,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(4),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(
                      Icons.equalizer_rounded,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    title: Text(
                      LocaleProvider.tr('equalizer'),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    subtitle: Text(
                      LocaleProvider.tr('equalizer_desc'),
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                    trailing: Icon(
                      Icons.chevron_right,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(4)),
                    ),
                    onTap: () {
                      Navigator.of(context).push(
                        PageRouteBuilder(
                          pageBuilder:
                              (context, animation, secondaryAnimation) =>
                                  const EqualizerScreen(),
                          transitionsBuilder:
                              (context, animation, secondaryAnimation, child) {
                                const begin = Offset(1.0, 0.0);
                                const end = Offset.zero;
                                const curve = Curves.ease;
                                final tween = Tween(
                                  begin: begin,
                                  end: end,
                                ).chain(CurveTween(curve: curve));
                                return SlideTransition(
                                  position: animation.drive(tween),
                                  child: child,
                                );
                              },
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Card(
              color: cardColor,
              margin: EdgeInsets.zero,
              elevation: 0,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(4),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(
                      Icons.lyrics_outlined,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    title: Text(
                      LocaleProvider.tr('delete_lyrics'),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    subtitle: Text(
                      LocaleProvider.tr('delete_lyrics_desc'),
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(4)),
                    ),
                    onTap: () => _showDeleteLyricsConfirmation(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Card(
              color: cardColor,
              margin: EdgeInsets.zero,
              elevation: 0,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(4),
                  bottomLeft: Radius.circular(20),
                  bottomRight: Radius.circular(20),
                ),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(
                      Icons.battery_alert,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    title: Text(
                      LocaleProvider.tr('ignore_battery_optimization'),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _checkingBatteryOpt
                              ? LocaleProvider.tr('status_checking')
                              : _batteryOptDisabled
                              ? LocaleProvider.tr('status_enabled')
                              : LocaleProvider.tr('status_disabled'),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.9),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          LocaleProvider.tr('ignore_battery_optimization_desc'),
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.9),
                          ),
                        ),
                      ],
                    ),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(4),
                        topRight: Radius.circular(4),
                        bottomLeft: Radius.circular(16),
                        bottomRight: Radius.circular(16),
                      ),
                    ),
                    onTap: () =>
                        _solicitarIgnorarOptimizacionDeBateria(context),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Apartado de Respaldo
            Row(
              children: [
                const SizedBox(width: 14),
                TranslatedText(
                  'backup',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Card(
              color: cardColor,
              margin: EdgeInsets.zero,
              elevation: 0,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(20),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(
                      Icons.save_alt,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    title: Text(
                      LocaleProvider.tr('export_backup'),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    subtitle: Text(
                      LocaleProvider.tr('export_backup_desc'),
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(16),
                        topRight: Radius.circular(16),
                        bottomLeft: Radius.circular(4),
                        bottomRight: Radius.circular(4),
                      ),
                    ),
                    onTap: _exportBackup,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Card(
              color: cardColor,
              margin: EdgeInsets.zero,
              elevation: 0,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(4),
                  bottomLeft: Radius.circular(20),
                  bottomRight: Radius.circular(20),
                ),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(
                      Icons.upload_file,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    title: Text(
                      LocaleProvider.tr('import_backup'),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    subtitle: Text(
                      LocaleProvider.tr('import_backup_desc'),
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(4),
                        topRight: Radius.circular(4),
                        bottomLeft: Radius.circular(16),
                        bottomRight: Radius.circular(16),
                      ),
                    ),
                    onTap: _importBackup,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Ajustes de la app
            Row(
              children: [
                const SizedBox(width: 14),
                TranslatedText(
                  'app_settings',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Card(
              color: cardColor,
              margin: EdgeInsets.zero,
              elevation: 0,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(20),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(
                      Icons.restore,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    title: Text(
                      LocaleProvider.tr('reset_app'),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    subtitle: Text(
                      LocaleProvider.tr('reset_app_desc'),
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(16),
                        topRight: Radius.circular(16),
                        bottomLeft: Radius.circular(4),
                        bottomRight: Radius.circular(4),
                      ),
                    ),
                    onTap: _resetApp,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Card(
              color: cardColor,
              margin: EdgeInsets.zero,
              elevation: 0,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(4),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(
                      Icons.system_update_alt_rounded,
                      weight: 500,
                      grade: 200,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    title: Text(
                      LocaleProvider.tr('app_updates'),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    subtitle: Text(
                      LocaleProvider.tr('check_for_updates'),
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(4)),
                    ),
                    onTap: () {
                      Navigator.of(context).push(
                        PageRouteBuilder(
                          pageBuilder:
                              (context, animation, secondaryAnimation) =>
                                  const UpdateScreen(),
                          transitionsBuilder:
                              (context, animation, secondaryAnimation, child) {
                                const begin = Offset(1.0, 0.0);
                                const end = Offset.zero;
                                const curve = Curves.ease;
                                final tween = Tween(
                                  begin: begin,
                                  end: end,
                                ).chain(CurveTween(curve: curve));
                                return SlideTransition(
                                  position: animation.drive(tween),
                                  child: child,
                                );
                              },
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Card(
              color: cardColor,
              margin: EdgeInsets.zero,
              elevation: 0,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(4),
                  bottomLeft: Radius.circular(20),
                  bottomRight: Radius.circular(20),
                ),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(
                      Icons.info_outline,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    title: Text(
                      LocaleProvider.tr('about'),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    subtitle: Text(
                      LocaleProvider.tr('app_info'),
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(4),
                        topRight: Radius.circular(4),
                        bottomLeft: Radius.circular(16),
                        bottomRight: Radius.circular(16),
                      ),
                    ),
                    onTap: () {
                      Navigator.of(context).push(
                        PageRouteBuilder(
                          pageBuilder:
                              (context, animation, secondaryAnimation) =>
                                  const AboutScreen(),
                          transitionsBuilder:
                              (context, animation, secondaryAnimation, child) {
                                const begin = Offset(1.0, 0.0);
                                const end = Offset.zero;
                                const curve = Curves.ease;
                                final tween = Tween(
                                  begin: begin,
                                  end: end,
                                ).chain(CurveTween(curve: curve));
                                return SlideTransition(
                                  position: animation.drive(tween),
                                  child: child,
                                );
                              },
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _exportBackup() async {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    try {
      // Obtener datos de las bases de datos
      final favorites = await FavoritesDB().getFavorites();
      final recents = await RecentsDB().getRecents();
      final mostPlayed = await MostPlayedDB().getMostPlayed(limit: 10000);
      final playlistsRaw = await PlaylistsDB().getAllPlaylists();
      final playlists = <Map<String, dynamic>>[];
      for (final pl in playlistsRaw) {
        final songs = await PlaylistsDB().getSongsFromPlaylist(pl.id);
        playlists.add({
          'id': pl.id,
          'name': pl.name,
          'songs': songs.map((s) => s.data).toList(),
        });
      }
      // Serializar a JSON
      final backup = {
        'favorites': favorites.map((s) => s.data).toList(),
        'recents': recents.map((s) => s.data).toList(),
        'mostPlayed': mostPlayed.map((s) => s.data).toList(),
        'playlists': playlists,
      };
      final jsonStr = JsonEncoder.withIndent('  ').convert(backup);
      // Seleccionar carpeta y guardar
      final dir = await getDirectoryPath();
      if (dir == null) return;
      final file = File('$dir/music_backup.json');
      await file.writeAsString(jsonStr);
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: isAmoled && isDark
                ? const BorderSide(color: Colors.white, width: 1)
                : BorderSide.none,
          ),
          title: Text(LocaleProvider.tr('success')),
          content: Text(LocaleProvider.tr('backup_exported')),
        ),
      );
    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: isAmoled && isDark
                  ? const BorderSide(color: Colors.white, width: 1)
                  : BorderSide.none,
            ),
            title: Text(LocaleProvider.tr('error')),
            content: Text('${LocaleProvider.tr('error')}: $e'),
          ),
        );
      }
    }
  }

  Future<void> _importBackup() async {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    try {
      final typeGroup = XTypeGroup(label: 'json', extensions: ['json']);
      final filePath = await openFile(acceptedTypeGroups: [typeGroup]);
      if (filePath == null) return;
      final file = File(filePath.path);
      final jsonStr = await file.readAsString();
      final data = jsonDecode(jsonStr);
      // Confirmar reemplazo
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: isAmoled && isDark
                ? const BorderSide(color: Colors.white, width: 1)
                : BorderSide.none,
          ),
          title: Text(LocaleProvider.tr('import_backup')),
          content: Text(LocaleProvider.tr('import_confirm')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(LocaleProvider.tr('cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(LocaleProvider.tr('import')),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      // Limpiar bases de datos
      final boxFav = await FavoritesDB().box;
      await boxFav.clear();
      final boxRec = await RecentsDB().box;
      await boxRec.clear();
      final boxMost = await MostPlayedDB().box;
      await boxMost.clear();
      final boxPl = await PlaylistsDB().box;
      await boxPl.clear();
      // Restaurar favoritos
      if (data['favorites'] is List) {
        for (final path in data['favorites']) {
          if (!boxFav.values.contains(path)) {
            await boxFav.add(path);
          }
        }
      }
      // Restaurar recientes
      if (data['recents'] is List) {
        for (final path in data['recents']) {
          await boxRec.put(path, DateTime.now().millisecondsSinceEpoch);
        }
      }
      // Restaurar más escuchadas
      final mostPlayedBox = await MostPlayedDB().box;
      if (data['mostPlayed'] is List) {
        for (final path in data['mostPlayed']) {
          await mostPlayedBox.put(path, {'play_count': 1});
        }
      }
      // Restaurar playlists
      if (data['playlists'] is List) {
        for (final pl in data['playlists']) {
          final id =
              pl['id']?.toString() ??
              DateTime.now().millisecondsSinceEpoch.toString();
          final name = pl['name'] as String;
          final songPaths = (pl['songs'] as List)
              .map((e) => e.toString())
              .toList();
          final playlist = hive_model.PlaylistModel(
            id: id,
            name: name,
            songPaths: songPaths,
          );
          await boxPl.put(id, playlist);
        }
      }
      if (!mounted) return;

      // Activar notifiers para recargar datos sin reiniciar la app
      favoritesShouldReload.value = !favoritesShouldReload.value;
      playlistsShouldReload.value = !playlistsShouldReload.value;
      shortcutsShouldReload.value = !shortcutsShouldReload.value;
      mostPlayedShouldReload.value = !mostPlayedShouldReload.value;

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: isAmoled && isDark
                ? const BorderSide(color: Colors.white, width: 1)
                : BorderSide.none,
          ),
          title: Text(LocaleProvider.tr('success')),
          content: Text(LocaleProvider.tr('backup_imported')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(LocaleProvider.tr('ok')),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: isAmoled && isDark
                  ? const BorderSide(color: Colors.white, width: 1)
                  : BorderSide.none,
            ),
            title: Text(LocaleProvider.tr('error')),
            content: Text('${LocaleProvider.tr('error')}: $e'),
          ),
        );
      }
    }
  }

  // Función para restablecer la aplicación
  Future<void> _resetApp() async {
    try {
      // Mostrar diálogo de confirmación
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) {
          return ValueListenableBuilder<AppColorScheme>(
            valueListenable: colorSchemeNotifier,
            builder: (context, colorScheme, child) {
              final isAmoled = colorScheme == AppColorScheme.amoled;
              final isDark = Theme.of(context).brightness == Brightness.dark;
              final primaryColor = Theme.of(context).colorScheme.primary;

              return AlertDialog(
                backgroundColor: isAmoled && isDark
                    ? Colors.black
                    : Theme.of(context).colorScheme.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                  side: isAmoled && isDark
                      ? const BorderSide(color: Colors.white24, width: 1)
                      : BorderSide.none,
                ),
                contentPadding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
                content: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: 400,
                    maxHeight: MediaQuery.of(context).size.height * 0.8,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.warning_rounded,
                        size: 32,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(height: 16),
                      TranslatedText(
                        'reset_app_confirm',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w500,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: TranslatedText(
                          'reset_app_warning',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withAlpha(180),
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 24),
                      _buildDestructiveOption(
                        context: context,
                        title: LocaleProvider.tr('reset_app'),
                        icon: Icons.restore_rounded,
                        onTap: () => Navigator.of(context).pop(true),
                      ),
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.only(right: 24, bottom: 8),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: () => Navigator.of(context).pop(false),
                            child: TranslatedText(
                              'cancel',
                              style: TextStyle(
                                color: primaryColor,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );

      if (confirmed != true) return;

      // Borrar todas las bases de datos
      final boxFav = await FavoritesDB().box;
      await boxFav.clear();

      final boxRec = await RecentsDB().box;
      await boxRec.clear();

      final boxMost = await MostPlayedDB().box;
      await boxMost.clear();

      final boxPl = await PlaylistsDB().box;
      await boxPl.clear();

      final boxShortcuts = await ShortcutsDB().box;
      await boxShortcuts.clear();

      final boxSongs = await SongsIndexDB().box;
      await boxSongs.clear();

      final artistsDB = ArtistsDB();
      await artistsDB.clear();

      await ArtworkDB.clearCache();

      // Borrar letras de canciones
      await SyncedLyricsService.clearLyrics();

      // Borrar SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();

      if (!mounted) return;

      // Activar notifiers para recargar datos
      favoritesShouldReload.value = !favoritesShouldReload.value;
      playlistsShouldReload.value = !playlistsShouldReload.value;
      shortcutsShouldReload.value = !shortcutsShouldReload.value;
      mostPlayedShouldReload.value = !mostPlayedShouldReload.value;

      // Mostrar mensaje de éxito
      showDialog(
        context: context,
        builder: (BuildContext context) {
          return ValueListenableBuilder<AppColorScheme>(
            valueListenable: colorSchemeNotifier,
            builder: (context, colorScheme, child) {
              final isAmoled = colorScheme == AppColorScheme.amoled;
              final isDark = Theme.of(context).brightness == Brightness.dark;

              return AlertDialog(
                backgroundColor: isAmoled && isDark
                    ? Colors.black
                    : Theme.of(context).colorScheme.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                  side: isAmoled && isDark
                      ? const BorderSide(color: Colors.white24, width: 1)
                      : BorderSide.none,
                ),
                contentPadding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
                content: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: 400,
                    maxHeight: MediaQuery.of(context).size.height * 0.8,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.check_circle_rounded,
                        size: 32,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 16),
                      TranslatedText(
                        'success',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w500,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: TranslatedText(
                          'reset_app_success',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withAlpha(180),
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Padding(
                        padding: const EdgeInsets.only(right: 24, bottom: 8),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: TranslatedText(
                              'ok',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.primary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (BuildContext context) {
            return ValueListenableBuilder<AppColorScheme>(
              valueListenable: colorSchemeNotifier,
              builder: (context, colorScheme, child) {
                final isAmoled = colorScheme == AppColorScheme.amoled;
                final isDark = Theme.of(context).brightness == Brightness.dark;

                return AlertDialog(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: isAmoled && isDark
                        ? const BorderSide(color: Colors.white, width: 1)
                        : BorderSide.none,
                  ),
                  title: Center(
                    child: Text(
                      LocaleProvider.tr('error'),
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  content: SizedBox(
                    width: 400,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(height: 18),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Padding(
                            padding: EdgeInsets.symmetric(horizontal: 4),
                            child: Text(
                              '${LocaleProvider.tr('error')}: $e',
                              style: TextStyle(
                                fontSize: 14,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                              textAlign: TextAlign.left,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        SizedBox(height: 20),
                        // Tarjeta de aceptar
                        InkWell(
                          onTap: () => Navigator.of(context).pop(),
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            width: double.infinity,
                            padding: EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: isAmoled && isDark
                                  ? Colors.red.withValues(
                                      alpha: 0.2,
                                    ) // Color personalizado para amoled
                                  : Theme.of(
                                      context,
                                    ).colorScheme.errorContainer,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isAmoled && isDark
                                    ? Colors.red.withValues(
                                        alpha: 0.4,
                                      ) // Borde personalizado para amoled
                                    : Theme.of(context).colorScheme.error
                                          .withValues(alpha: 0.3),
                                width: 2,
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(12),
                                    color: isAmoled && isDark
                                        ? Colors.red.withValues(
                                            alpha: 0.2,
                                          ) // Fondo del ícono para amoled
                                        : Theme.of(context).colorScheme.error
                                              .withValues(alpha: 0.1),
                                  ),
                                  child: Icon(
                                    Icons.error,
                                    size: 30,
                                    color: isAmoled && isDark
                                        ? Colors
                                              .red // Ícono rojo para amoled
                                        : Theme.of(context).colorScheme.error,
                                  ),
                                ),
                                SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        LocaleProvider.tr('ok'),
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                          color: isAmoled && isDark
                                              ? Colors
                                                    .red // Texto rojo para amoled
                                              : Theme.of(
                                                  context,
                                                ).colorScheme.error,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      }
    }
  }
}
