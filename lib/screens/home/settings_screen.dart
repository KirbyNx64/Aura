import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:music/screens/home/ota_update_screen.dart';
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
import 'package:url_launcher/url_launcher.dart';
import 'package:icons_plus/icons_plus.dart' as icons_plus;
import 'package:material_symbols_icons/symbols.dart';
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
  AppColorScheme _currentColorScheme = AppColorScheme.deepPurple;
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
  }

  Future<void> _initHeroAnimationSetting() async {
    final prefs = await SharedPreferences.getInstance();
    final useHero = prefs.getBool('use_hero_animation') ?? false;
    heroAnimationNotifier.value = useHero;
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
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: isAmoled && isDark
              ? const BorderSide(color: Colors.white, width: 1)
              : BorderSide.none,
        ),
        title: Text(LocaleProvider.tr('info')),
        content: Text(LocaleProvider.tr('settings_info')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(LocaleProvider.tr('ok')),
          ),
        ],
      ),
    );
  }

  void _showArtworkQualityDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
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
                  LocaleProvider.tr('artwork_quality'),
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              content: SizedBox(
                width: 400,
                height: 500, // Altura fija para permitir scroll
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                    SizedBox(height: 18),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          LocaleProvider.tr('artwork_quality_description'),
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
                    // Tarjeta de 100% Máximo
                    InkWell(
                      onTap: () {
                        _setArtworkQuality(1024);
                        Navigator.of(context).pop();
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: _artworkQuality == 1024
                              ? (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.2) // Color personalizado para amoled seleccionado
                                  : Theme.of(context).colorScheme.primaryContainer)
                              : (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.1) // Color personalizado para amoled no seleccionado
                                  : Theme.of(context).colorScheme.secondaryContainer),
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(16),
                            topRight: Radius.circular(16),
                            bottomLeft: Radius.circular(4),
                            bottomRight: Radius.circular(4),
                          ),
                          border: Border.all(
                            color: _artworkQuality == 1024
                                ? (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.4) // Borde personalizado para amoled seleccionado
                                    : Theme.of(context).colorScheme.primary.withValues(alpha: 0.3))
                                : (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.2) // Borde personalizado para amoled no seleccionado
                                    : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1)),
                            width: _artworkQuality == 1024 ? 2 : 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: _artworkQuality == 1024
                                    ? (isAmoled && isDark
                                        ? Colors.white.withValues(alpha: 0.2) // Fondo del ícono para amoled seleccionado
                                        : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1))
                                    : Colors.transparent,
                              ),
                              child: Icon(
                                Icons.high_quality,
                                size: 30,
                                color: _artworkQuality == 1024
                                    ? (isAmoled && isDark
                                        ? Colors.white // Ícono blanco para amoled seleccionado
                                        : Theme.of(context).colorScheme.primary)
                                    : (isAmoled && isDark
                                        ? Colors.white // Ícono blanco para amoled no seleccionado
                                        : Theme.of(context).colorScheme.onSurface),
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    LocaleProvider.tr('100_percent_maximum'),
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: _artworkQuality == 1024
                                          ? (isAmoled && isDark
                                              ? Colors.white // Texto blanco para amoled seleccionado
                                              : Theme.of(context).colorScheme.primary)
                                          : (isAmoled && isDark
                                              ? Colors.white // Texto blanco para amoled no seleccionado
                                              : Theme.of(context).colorScheme.onSurface),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (_artworkQuality == 1024)
                              Icon(
                                Icons.check_circle,
                                color: isAmoled && isDark
                                    ? Colors.white // Check blanco para amoled
                                    : Theme.of(context).colorScheme.primary,
                                size: 24,
                              ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: 4),
                    // Tarjeta de 80% Recomendado
                    InkWell(
                      onTap: () {
                        _setArtworkQuality(410);
                        Navigator.of(context).pop();
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: _artworkQuality == 410
                              ? (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.2) // Color personalizado para amoled seleccionado
                                  : Theme.of(context).colorScheme.primaryContainer)
                              : (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.1) // Color personalizado para amoled no seleccionado
                                  : Theme.of(context).colorScheme.secondaryContainer),
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(4),
                            topRight: Radius.circular(4),
                            bottomLeft: Radius.circular(4),
                            bottomRight: Radius.circular(4),
                          ),
                          border: Border.all(
                            color: _artworkQuality == 410
                                ? (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.4) // Borde personalizado para amoled seleccionado
                                    : Theme.of(context).colorScheme.primary.withValues(alpha: 0.3))
                                : (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.2) // Borde personalizado para amoled no seleccionado
                                    : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1)),
                            width: _artworkQuality == 410 ? 2 : 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: _artworkQuality == 410
                                    ? (isAmoled && isDark
                                        ? Colors.white.withValues(alpha: 0.2) // Fondo del ícono para amoled seleccionado
                                        : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1))
                                    : Colors.transparent,
                              ),
                              child: Icon(
                                Icons.recommend,
                                size: 30,
                                color: _artworkQuality == 410
                                    ? (isAmoled && isDark
                                        ? Colors.white // Ícono blanco para amoled seleccionado
                                        : Theme.of(context).colorScheme.primary)
                                    : (isAmoled && isDark
                                        ? Colors.white // Ícono blanco para amoled no seleccionado
                                        : Theme.of(context).colorScheme.onSurface),
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    LocaleProvider.tr('80_percent_recommended'),
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: _artworkQuality == 410
                                          ? (isAmoled && isDark
                                              ? Colors.white // Texto blanco para amoled seleccionado
                                              : Theme.of(context).colorScheme.primary)
                                          : (isAmoled && isDark
                                              ? Colors.white // Texto blanco para amoled no seleccionado
                                              : Theme.of(context).colorScheme.onSurface),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (_artworkQuality == 410)
                              Icon(
                                Icons.check_circle,
                                color: isAmoled && isDark
                                    ? Colors.white // Check blanco para amoled
                                    : Theme.of(context).colorScheme.primary,
                                size: 24,
                              ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: 4),
                    // Tarjeta de 60% Rendimiento
                    InkWell(
                      onTap: () {
                        _setArtworkQuality(307);
                        Navigator.of(context).pop();
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: _artworkQuality == 307
                              ? (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.2) // Color personalizado para amoled seleccionado
                                  : Theme.of(context).colorScheme.primaryContainer)
                              : (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.1) // Color personalizado para amoled no seleccionado
                                  : Theme.of(context).colorScheme.secondaryContainer),
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(4),
                            topRight: Radius.circular(4),
                            bottomLeft: Radius.circular(4),
                            bottomRight: Radius.circular(4),
                          ),
                          border: Border.all(
                            color: _artworkQuality == 307
                                ? (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.4) // Borde personalizado para amoled seleccionado
                                    : Theme.of(context).colorScheme.primary.withValues(alpha: 0.3))
                                : (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.2) // Borde personalizado para amoled no seleccionado
                                    : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1)),
                            width: _artworkQuality == 307 ? 2 : 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: _artworkQuality == 307
                                    ? (isAmoled && isDark
                                        ? Colors.white.withValues(alpha: 0.2) // Fondo del ícono para amoled seleccionado
                                        : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1))
                                    : Colors.transparent,
                              ),
                              child: Icon(
                                Icons.speed,
                                size: 30,
                                color: _artworkQuality == 307
                                    ? (isAmoled && isDark
                                        ? Colors.white // Ícono blanco para amoled seleccionado
                                        : Theme.of(context).colorScheme.primary)
                                    : (isAmoled && isDark
                                        ? Colors.white // Ícono blanco para amoled no seleccionado
                                        : Theme.of(context).colorScheme.onSurface),
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    LocaleProvider.tr('60_percent_performance'),
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: _artworkQuality == 307
                                          ? (isAmoled && isDark
                                              ? Colors.white // Texto blanco para amoled seleccionado
                                              : Theme.of(context).colorScheme.primary)
                                          : (isAmoled && isDark
                                              ? Colors.white // Texto blanco para amoled no seleccionado
                                              : Theme.of(context).colorScheme.onSurface),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (_artworkQuality == 307)
                              Icon(
                                Icons.check_circle,
                                color: isAmoled && isDark
                                    ? Colors.white // Check blanco para amoled
                                    : Theme.of(context).colorScheme.primary,
                                size: 24,
                              ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: 4),
                    // Tarjeta de 40% Bajo
                    InkWell(
                      onTap: () {
                        _setArtworkQuality(205);
                        Navigator.of(context).pop();
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: _artworkQuality == 205
                              ? (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.2) // Color personalizado para amoled seleccionado
                                  : Theme.of(context).colorScheme.primaryContainer)
                              : (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.1) // Color personalizado para amoled no seleccionado
                                  : Theme.of(context).colorScheme.secondaryContainer),
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(4),
                            topRight: Radius.circular(4),
                            bottomLeft: Radius.circular(4),
                            bottomRight: Radius.circular(4),
                          ),
                          border: Border.all(
                            color: _artworkQuality == 205
                                ? (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.4) // Borde personalizado para amoled seleccionado
                                    : Theme.of(context).colorScheme.primary.withValues(alpha: 0.3))
                                : (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.2) // Borde personalizado para amoled no seleccionado
                                    : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1)),
                            width: _artworkQuality == 205 ? 2 : 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: _artworkQuality == 205
                                    ? (isAmoled && isDark
                                        ? Colors.white.withValues(alpha: 0.2) // Fondo del ícono para amoled seleccionado
                                        : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1))
                                    : Colors.transparent,
                              ),
                              child: Icon(
                                Icons.low_priority,
                                size: 30,
                                color: _artworkQuality == 205
                                    ? (isAmoled && isDark
                                        ? Colors.white // Ícono blanco para amoled seleccionado
                                        : Theme.of(context).colorScheme.primary)
                                    : (isAmoled && isDark
                                        ? Colors.white // Ícono blanco para amoled no seleccionado
                                        : Theme.of(context).colorScheme.onSurface),
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    LocaleProvider.tr('40_percent_low'),
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: _artworkQuality == 205
                                          ? (isAmoled && isDark
                                              ? Colors.white // Texto blanco para amoled seleccionado
                                              : Theme.of(context).colorScheme.primary)
                                          : (isAmoled && isDark
                                              ? Colors.white // Texto blanco para amoled no seleccionado
                                              : Theme.of(context).colorScheme.onSurface),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (_artworkQuality == 205)
                              Icon(
                                Icons.check_circle,
                                color: isAmoled && isDark
                                    ? Colors.white // Check blanco para amoled
                                    : Theme.of(context).colorScheme.primary,
                                size: 24,
                              ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: 4),
                    // Tarjeta de 20% Mínimo
                    InkWell(
                      onTap: () {
                        _setArtworkQuality(102);
                        Navigator.of(context).pop();
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: _artworkQuality == 102
                              ? (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.2) // Color personalizado para amoled seleccionado
                                  : Theme.of(context).colorScheme.primaryContainer)
                              : (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.1) // Color personalizado para amoled no seleccionado
                                  : Theme.of(context).colorScheme.secondaryContainer),
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(4),
                            topRight: Radius.circular(4),
                            bottomLeft: Radius.circular(16),
                            bottomRight: Radius.circular(16),
                          ),
                          border: Border.all(
                            color: _artworkQuality == 102
                                ? (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.4) // Borde personalizado para amoled seleccionado
                                    : Theme.of(context).colorScheme.primary.withValues(alpha: 0.3))
                                : (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.2) // Borde personalizado para amoled no seleccionado
                                    : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1)),
                            width: _artworkQuality == 102 ? 2 : 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: _artworkQuality == 102
                                    ? (isAmoled && isDark
                                        ? Colors.white.withValues(alpha: 0.2) // Fondo del ícono para amoled seleccionado
                                        : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1))
                                    : Colors.transparent,
                              ),
                              child: Icon(
                                Icons.compress,
                                size: 30,
                                color: _artworkQuality == 102
                                    ? (isAmoled && isDark
                                        ? Colors.white // Ícono blanco para amoled seleccionado
                                        : Theme.of(context).colorScheme.primary)
                                    : (isAmoled && isDark
                                        ? Colors.white // Ícono blanco para amoled no seleccionado
                                        : Theme.of(context).colorScheme.onSurface),
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    LocaleProvider.tr('20_percent_minimum'),
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: _artworkQuality == 102
                                          ? (isAmoled && isDark
                                              ? Colors.white // Texto blanco para amoled seleccionado
                                              : Theme.of(context).colorScheme.primary)
                                          : (isAmoled && isDark
                                              ? Colors.white // Texto blanco para amoled no seleccionado
                                              : Theme.of(context).colorScheme.onSurface),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (_artworkQuality == 102)
                              Icon(
                                Icons.check_circle,
                                color: isAmoled && isDark
                                    ? Colors.white // Check blanco para amoled
                                    : Theme.of(context).colorScheme.primary,
                                size: 24,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              )
            );
          },
        );
      },
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
            builder: (context) => AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white, width: 1)
                    : BorderSide.none,
              ),
              title: Text(LocaleProvider.tr('information')),
              content: Text(LocaleProvider.tr('battery_optimization_info')),
            ),
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
            
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white, width: 1)
                    : BorderSide.none,
              ),
              title: Center(
                child: TranslatedText(
                  'select_theme',
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
                        child: TranslatedText(
                          'select_theme_desc',
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
                    // Tarjeta de Sistema predeterminado
                    InkWell(
                      onTap: () {
                        widget.setThemeMode?.call(AppThemeMode.system);
                        Navigator.of(context).pop();
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: _getCurrentThemeText(context) == LocaleProvider.tr('system_default')
                              ? (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.2) // Color personalizado para amoled seleccionado
                                  : Theme.of(context).colorScheme.primaryContainer)
                              : (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.1) // Color personalizado para amoled no seleccionado
                                  : Theme.of(context).colorScheme.secondaryContainer),
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(16),
                            topRight: Radius.circular(16),
                            bottomLeft: Radius.circular(4),
                            bottomRight: Radius.circular(4),
                          ),
                          border: Border.all(
                            color: _getCurrentThemeText(context) == LocaleProvider.tr('system_default')
                                ? (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.4) // Borde personalizado para amoled seleccionado
                                    : Theme.of(context).colorScheme.primary.withValues(alpha: 0.3))
                                : (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.2) // Borde personalizado para amoled no seleccionado
                                    : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1)),
                            width: _getCurrentThemeText(context) == LocaleProvider.tr('system_default') ? 2 : 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: _getCurrentThemeText(context) == LocaleProvider.tr('system_default')
                                    ? (isAmoled && isDark
                                        ? Colors.white.withValues(alpha: 0.2) // Fondo del ícono para amoled seleccionado
                                        : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1))
                                    : Colors.transparent,
                              ),
                              child: Icon(
                                Icons.brightness_auto,
                                size: 30,
                                color: _getCurrentThemeText(context) == LocaleProvider.tr('system_default')
                                    ? (isAmoled && isDark
                                        ? Colors.white // Ícono blanco para amoled seleccionado
                                        : Theme.of(context).colorScheme.primary)
                                    : (isAmoled && isDark
                                        ? Colors.white // Ícono blanco para amoled no seleccionado
                                        : Theme.of(context).colorScheme.onSurface),
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    LocaleProvider.tr('system_default'),
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: _getCurrentThemeText(context) == LocaleProvider.tr('system_default')
                                          ? (isAmoled && isDark
                                              ? Colors.white // Texto blanco para amoled seleccionado
                                              : Theme.of(context).colorScheme.primary)
                                          : (isAmoled && isDark
                                              ? Colors.white // Texto blanco para amoled no seleccionado
                                              : Theme.of(context).colorScheme.onSurface),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (_getCurrentThemeText(context) == LocaleProvider.tr('system_default'))
                              Icon(
                                Icons.check_circle,
                                color: isAmoled && isDark
                                    ? Colors.white // Check blanco para amoled
                                    : Theme.of(context).colorScheme.primary,
                                size: 24,
                              ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: 4),
                    // Tarjeta de Modo claro
                    InkWell(
                      onTap: () {
                        widget.setThemeMode?.call(AppThemeMode.light);
                        Navigator.of(context).pop();
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: _getCurrentThemeText(context) == LocaleProvider.tr('light_mode')
                              ? (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.2) // Color personalizado para amoled seleccionado
                                  : Theme.of(context).colorScheme.primaryContainer)
                              : (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.1) // Color personalizado para amoled no seleccionado
                                  : Theme.of(context).colorScheme.secondaryContainer),
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(4),
                            topRight: Radius.circular(4),
                            bottomLeft: Radius.circular(4),
                            bottomRight: Radius.circular(4),
                          ),
                          border: Border.all(
                            color: _getCurrentThemeText(context) == LocaleProvider.tr('light_mode')
                                ? (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.4) // Borde personalizado para amoled seleccionado
                                    : Theme.of(context).colorScheme.primary.withValues(alpha: 0.3))
                                : (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.2) // Borde personalizado para amoled no seleccionado
                                    : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1)),
                            width: _getCurrentThemeText(context) == LocaleProvider.tr('light_mode') ? 2 : 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: _getCurrentThemeText(context) == LocaleProvider.tr('light_mode')
                                    ? (isAmoled && isDark
                                        ? Colors.white.withValues(alpha: 0.2) // Fondo del ícono para amoled seleccionado
                                        : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1))
                                    : Colors.transparent,
                              ),
                              child: Icon(
                                Icons.light_mode,
                                size: 30,
                                color: _getCurrentThemeText(context) == LocaleProvider.tr('light_mode')
                                    ? (isAmoled && isDark
                                        ? Colors.white // Ícono blanco para amoled seleccionado
                                        : Theme.of(context).colorScheme.primary)
                                    : (isAmoled && isDark
                                        ? Colors.white // Ícono blanco para amoled no seleccionado
                                        : Theme.of(context).colorScheme.onSurface),
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    LocaleProvider.tr('light_mode'),
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: _getCurrentThemeText(context) == LocaleProvider.tr('light_mode')
                                          ? (isAmoled && isDark
                                              ? Colors.white // Texto blanco para amoled seleccionado
                                              : Theme.of(context).colorScheme.primary)
                                          : (isAmoled && isDark
                                              ? Colors.white // Texto blanco para amoled no seleccionado
                                              : Theme.of(context).colorScheme.onSurface),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (_getCurrentThemeText(context) == LocaleProvider.tr('light_mode'))
                              Icon(
                                Icons.check_circle,
                                color: isAmoled && isDark
                                    ? Colors.white // Check blanco para amoled
                                    : Theme.of(context).colorScheme.primary,
                                size: 24,
                              ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: 4),
                    // Tarjeta de Modo oscuro
                    InkWell(
                      onTap: () {
                        widget.setThemeMode?.call(AppThemeMode.dark);
                        Navigator.of(context).pop();
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: _getCurrentThemeText(context) == LocaleProvider.tr('dark_mode')
                              ? (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.2) // Color personalizado para amoled seleccionado
                                  : Theme.of(context).colorScheme.primaryContainer)
                              : (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.1) // Color personalizado para amoled no seleccionado
                                  : Theme.of(context).colorScheme.secondaryContainer),
                          borderRadius: BorderRadius.only(
                            bottomLeft: Radius.circular(16),
                            bottomRight: Radius.circular(16),
                            topLeft: Radius.circular(4),
                            topRight: Radius.circular(4),
                          ),
                          border: Border.all(
                            color: _getCurrentThemeText(context) == LocaleProvider.tr('dark_mode')
                                ? (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.4) // Borde personalizado para amoled seleccionado
                                    : Theme.of(context).colorScheme.primary.withValues(alpha: 0.3))
                                : (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.2) // Borde personalizado para amoled no seleccionado
                                    : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1)),
                            width: _getCurrentThemeText(context) == LocaleProvider.tr('dark_mode') ? 2 : 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: _getCurrentThemeText(context) == LocaleProvider.tr('dark_mode')
                                    ? (isAmoled && isDark
                                        ? Colors.white.withValues(alpha: 0.2) // Fondo del ícono para amoled seleccionado
                                        : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1))
                                    : Colors.transparent,
                              ),
                              child: Icon(
                                Icons.dark_mode,
                                size: 30,
                                color: _getCurrentThemeText(context) == LocaleProvider.tr('dark_mode')
                                    ? (isAmoled && isDark
                                        ? Colors.white // Ícono blanco para amoled seleccionado
                                        : Theme.of(context).colorScheme.primary)
                                    : (isAmoled && isDark
                                        ? Colors.white // Ícono blanco para amoled no seleccionado
                                        : Theme.of(context).colorScheme.onSurface),
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    LocaleProvider.tr('dark_mode'),
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: _getCurrentThemeText(context) == LocaleProvider.tr('dark_mode')
                                          ? (isAmoled && isDark
                                              ? Colors.white // Texto blanco para amoled seleccionado
                                              : Theme.of(context).colorScheme.primary)
                                          : (isAmoled && isDark
                                              ? Colors.white // Texto blanco para amoled no seleccionado
                                              : Theme.of(context).colorScheme.onSurface),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (_getCurrentThemeText(context) == LocaleProvider.tr('dark_mode'))
                              Icon(
                                Icons.check_circle,
                                color: isAmoled && isDark
                                    ? Colors.white // Check blanco para amoled
                                    : Theme.of(context).colorScheme.primary,
                                size: 24,
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
    setState(() {
      _downloadDirectory = prefs.getString('download_directory');
    });
    downloadDirectoryNotifier.value = _downloadDirectory;
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
            
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white, width: 1)
                    : BorderSide.none,
              ),
              title: TranslatedText('select_common_folder'),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (commonFolders.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Text(
                          LocaleProvider.tr('no_common_folders'),
                          style: Theme.of(context).textTheme.bodyMedium,
                          textAlign: TextAlign.center,
                        ),
                      )
                    else
                      ...commonFolders.map((folder) => ListTile(
                        leading: const Icon(Icons.folder),
                        title: Text(
                          folder.split('/').last.isEmpty ? folder : folder.split('/').last,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          formatFolderPath(folder),
                          style: Theme.of(context).textTheme.bodySmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () {
                          Navigator.of(context).pop();
                          _selectFolder(folder);
                        },
                      )),
                    if (commonFolders.isNotEmpty) SizedBox(height: 16),
                    // Botón para elegir otra carpeta con diseño especial
                    InkWell(
                      onTap: () async {
                        Navigator.of(context).pop();
                        await _pickNewFolder();
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: (isAmoled && isDark
                              ? Colors.white.withValues(alpha: 0.2)
                              : Theme.of(context).colorScheme.primaryContainer),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: (isAmoled && isDark
                                ? Colors.white.withValues(alpha: 0.4)
                                : Theme.of(context).colorScheme.primary.withValues(alpha: 0.3)),
                            width: 2,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.2)
                                    : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1)),
                              ),
                              child: Icon(
                                Icons.folder_open,
                                size: 30,
                                color: (isAmoled && isDark
                                    ? Colors.white
                                    : Theme.of(context).colorScheme.primary),
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                LocaleProvider.tr('choose_other_folder'),
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: (isAmoled && isDark
                                      ? Colors.white
                                      : Theme.of(context).colorScheme.primary),
                                ),
                              ),
                            ),
                            Icon(
                              Icons.arrow_forward_ios,
                              size: 20,
                              color: (isAmoled && isDark
                                  ? Colors.white
                                  : Theme.of(context).colorScheme.primary),
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
            
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white, width: 1)
                    : BorderSide.none,
              ),
              title: Center(
                child: TranslatedText(
                  'audio_quality',
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
                        child: TranslatedText(
                          'audio_quality_desc',
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
                    // Tarjeta de calidad alta
                    InkWell(
                      onTap: () async {
                        Navigator.of(context).pop();
                        await _setAudioQuality('high');
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: _audioQuality == 'high' 
                              ? (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.2)
                                  : Theme.of(context).colorScheme.primaryContainer)
                              : (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.1)
                                  : Theme.of(context).colorScheme.secondaryContainer),
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(16),
                            topRight: Radius.circular(16),
                            bottomLeft: Radius.circular(4),
                            bottomRight: Radius.circular(4),
                          ),
                          border: Border.all(
                            color: _audioQuality == 'high'
                                ? (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.4)
                                    : Theme.of(context).colorScheme.primary.withValues(alpha: 0.3))
                                : (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.2)
                                    : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1)),
                            width: _audioQuality == 'high' ? 2 : 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: _audioQuality == 'high'
                                    ? (isAmoled && isDark
                                        ? Colors.white.withValues(alpha: 0.2)
                                        : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1))
                                    : Colors.transparent,
                              ),
                              child: Icon(
                                Icons.high_quality,
                                size: 30,
                                color: _audioQuality == 'high'
                                    ? (isAmoled && isDark
                                        ? Colors.white
                                        : Theme.of(context).colorScheme.primary)
                                    : (isAmoled && isDark
                                        ? Colors.white
                                        : Theme.of(context).colorScheme.onSurface),
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    LocaleProvider.tr('audio_quality_high'),
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: _audioQuality == 'high'
                                          ? (isAmoled && isDark
                                              ? Colors.white
                                              : Theme.of(context).colorScheme.primary)
                                          : (isAmoled && isDark
                                              ? Colors.white
                                              : Theme.of(context).colorScheme.onSurface),
                                    ),
                                  ),
                                  SizedBox(height: 4),
                                  Text(
                                    LocaleProvider.tr('audio_quality_high_desc'),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: _audioQuality == 'high'
                                          ? (isAmoled && isDark
                                              ? Colors.white.withValues(alpha: 0.8)
                                              : Theme.of(context).colorScheme.primary.withValues(alpha: 0.8))
                                          : (isAmoled && isDark
                                              ? Colors.white.withValues(alpha: 0.7)
                                              : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (_audioQuality == 'high')
                              Icon(
                                Icons.check_circle,
                                color: isAmoled && isDark
                                    ? Colors.white
                                    : Theme.of(context).colorScheme.primary,
                                size: 24,
                              ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: 4),
                    // Tarjeta de calidad media
                    InkWell(
                      onTap: () async {
                        Navigator.of(context).pop();
                        await _setAudioQuality('medium');
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: _audioQuality == 'medium' 
                              ? (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.2)
                                  : Theme.of(context).colorScheme.primaryContainer)
                              : (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.1)
                                  : Theme.of(context).colorScheme.secondaryContainer),
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(4),
                            topRight: Radius.circular(4),
                            bottomLeft: Radius.circular(4),
                            bottomRight: Radius.circular(4),
                          ),
                          border: Border.all(
                            color: _audioQuality == 'medium'
                                ? (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.4)
                                    : Theme.of(context).colorScheme.primary.withValues(alpha: 0.3))
                                : (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.2)
                                    : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1)),
                            width: _audioQuality == 'medium' ? 2 : 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: _audioQuality == 'medium'
                                    ? (isAmoled && isDark
                                        ? Colors.white.withValues(alpha: 0.2)
                                        : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1))
                                    : Colors.transparent,
                              ),
                              child: Icon(
                                Icons.equalizer,
                                size: 30,
                                color: _audioQuality == 'medium'
                                    ? (isAmoled && isDark
                                        ? Colors.white
                                        : Theme.of(context).colorScheme.primary)
                                    : (isAmoled && isDark
                                        ? Colors.white
                                        : Theme.of(context).colorScheme.onSurface),
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    LocaleProvider.tr('audio_quality_medium'),
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: _audioQuality == 'medium'
                                          ? (isAmoled && isDark
                                              ? Colors.white
                                              : Theme.of(context).colorScheme.primary)
                                          : (isAmoled && isDark
                                              ? Colors.white
                                              : Theme.of(context).colorScheme.onSurface),
                                    ),
                                  ),
                                  SizedBox(height: 4),
                                  Text(
                                    LocaleProvider.tr('audio_quality_medium_desc'),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: _audioQuality == 'medium'
                                          ? (isAmoled && isDark
                                              ? Colors.white.withValues(alpha: 0.8)
                                              : Theme.of(context).colorScheme.primary.withValues(alpha: 0.8))
                                          : (isAmoled && isDark
                                              ? Colors.white.withValues(alpha: 0.7)
                                              : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (_audioQuality == 'medium')
                              Icon(
                                Icons.check_circle,
                                color: isAmoled && isDark
                                    ? Colors.white
                                    : Theme.of(context).colorScheme.primary,
                                size: 24,
                              ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: 4),
                    // Tarjeta de calidad baja
                    InkWell(
                      onTap: () async {
                        Navigator.of(context).pop();
                        await _setAudioQuality('low');
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: _audioQuality == 'low' 
                              ? (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.2)
                                  : Theme.of(context).colorScheme.primaryContainer)
                              : (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.1)
                                  : Theme.of(context).colorScheme.secondaryContainer),
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(4),
                            topRight: Radius.circular(4),
                            bottomLeft: Radius.circular(16),
                            bottomRight: Radius.circular(16),
                          ),
                          border: Border.all(
                            color: _audioQuality == 'low'
                                ? (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.4)
                                    : Theme.of(context).colorScheme.primary.withValues(alpha: 0.3))
                                : (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.2)
                                    : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1)),
                            width: _audioQuality == 'low' ? 2 : 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: _audioQuality == 'low'
                                    ? (isAmoled && isDark
                                        ? Colors.white.withValues(alpha: 0.2)
                                        : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1))
                                    : Colors.transparent,
                              ),
                              child: Icon(
                                Icons.low_priority,
                                size: 30,
                                color: _audioQuality == 'low'
                                    ? (isAmoled && isDark
                                        ? Colors.white
                                        : Theme.of(context).colorScheme.primary)
                                    : (isAmoled && isDark
                                        ? Colors.white
                                        : Theme.of(context).colorScheme.onSurface),
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    LocaleProvider.tr('audio_quality_low'),
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: _audioQuality == 'low'
                                          ? (isAmoled && isDark
                                              ? Colors.white
                                              : Theme.of(context).colorScheme.primary)
                                          : (isAmoled && isDark
                                              ? Colors.white
                                              : Theme.of(context).colorScheme.onSurface),
                                    ),
                                  ),
                                  SizedBox(height: 4),
                                  Text(
                                    LocaleProvider.tr('audio_quality_low_desc'),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: _audioQuality == 'low'
                                          ? (isAmoled && isDark
                                              ? Colors.white.withValues(alpha: 0.8)
                                              : Theme.of(context).colorScheme.primary.withValues(alpha: 0.8))
                                          : (isAmoled && isDark
                                              ? Colors.white.withValues(alpha: 0.7)
                                              : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (_audioQuality == 'low')
                              Icon(
                                Icons.check_circle,
                                color: isAmoled && isDark
                                    ? Colors.white
                                    : Theme.of(context).colorScheme.primary,
                                size: 24,
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

  Future<void> _showCoverQualitySelection() async {
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
                child: TranslatedText(
                  'cover_quality',
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
                        child: TranslatedText(
                          'cover_quality_desc',
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
                    // Tarjeta de calidad alta
                    InkWell(
                      onTap: () async {
                        Navigator.of(context).pop();
                        await _setCoverQuality(true);
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: _coverQualityHigh 
                              ? (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.2)
                                  : Theme.of(context).colorScheme.primaryContainer)
                              : (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.1)
                                  : Theme.of(context).colorScheme.secondaryContainer),
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(16),
                            topRight: Radius.circular(16),
                            bottomLeft: Radius.circular(4),
                            bottomRight: Radius.circular(4),
                          ),
                          border: Border.all(
                            color: _coverQualityHigh
                                ? (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.4)
                                    : Theme.of(context).colorScheme.primary.withValues(alpha: 0.3))
                                : (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.2)
                                    : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1)),
                            width: _coverQualityHigh ? 2 : 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: _coverQualityHigh
                                    ? (isAmoled && isDark
                                        ? Colors.white.withValues(alpha: 0.2)
                                        : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1))
                                    : Colors.transparent,
                              ),
                              child: Icon(
                                Icons.high_quality,
                                size: 30,
                                color: _coverQualityHigh
                                    ? (isAmoled && isDark
                                        ? Colors.white
                                        : Theme.of(context).colorScheme.primary)
                                    : (isAmoled && isDark
                                        ? Colors.white
                                        : Theme.of(context).colorScheme.onSurface),
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    LocaleProvider.tr('high_quality'),
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: _coverQualityHigh
                                          ? (isAmoled && isDark
                                              ? Colors.white
                                              : Theme.of(context).colorScheme.primary)
                                          : (isAmoled && isDark
                                              ? Colors.white
                                              : Theme.of(context).colorScheme.onSurface),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (_coverQualityHigh)
                              Icon(
                                Icons.check_circle,
                                color: isAmoled && isDark
                                    ? Colors.white
                                    : Theme.of(context).colorScheme.primary,
                                size: 24,
                              ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: 4),
                    // Tarjeta de calidad baja
                    InkWell(
                      onTap: () async {
                        Navigator.of(context).pop();
                        await _setCoverQuality(false);
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: !_coverQualityHigh 
                              ? (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.2)
                                  : Theme.of(context).colorScheme.primaryContainer)
                              : (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.1)
                                  : Theme.of(context).colorScheme.secondaryContainer),
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(4),
                            topRight: Radius.circular(4),
                            bottomLeft: Radius.circular(16),
                            bottomRight: Radius.circular(16),
                          ),
                          border: Border.all(
                            color: !_coverQualityHigh
                                ? (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.4)
                                    : Theme.of(context).colorScheme.primary.withValues(alpha: 0.3))
                                : (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.2)
                                    : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1)),
                            width: !_coverQualityHigh ? 2 : 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: !_coverQualityHigh
                                    ? (isAmoled && isDark
                                        ? Colors.white.withValues(alpha: 0.2)
                                        : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1))
                                    : Colors.transparent,
                              ),
                              child: Icon(
                                Icons.low_priority,
                                size: 30,
                                color: !_coverQualityHigh
                                    ? (isAmoled && isDark
                                        ? Colors.white
                                        : Theme.of(context).colorScheme.primary)
                                    : (isAmoled && isDark
                                        ? Colors.white
                                        : Theme.of(context).colorScheme.onSurface),
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    LocaleProvider.tr('low_quality'),
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: !_coverQualityHigh
                                          ? (isAmoled && isDark
                                              ? Colors.white
                                              : Theme.of(context).colorScheme.primary)
                                          : (isAmoled && isDark
                                              ? Colors.white
                                              : Theme.of(context).colorScheme.onSurface),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (!_coverQualityHigh)
                              Icon(
                                Icons.check_circle,
                                color: isAmoled && isDark
                                    ? Colors.white
                                    : Theme.of(context).colorScheme.primary,
                                size: 24,
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
            
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white, width: 1)
                    : BorderSide.none,
              ),
              title: Center(
                child: TranslatedText(
                  'download_type',
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
                        child: TranslatedText(
                          'download_type_desc',
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
                    // Tarjeta de método Explode
                    InkWell(
                      onTap: () async {
                        Navigator.of(context).pop();
                        await _setDownloadType(true);
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: _downloadTypeExplode 
                              ? (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.2) // Color personalizado para amoled seleccionado
                                  : Theme.of(context).colorScheme.primaryContainer)
                              : (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.1) // Color personalizado para amoled no seleccionado
                                  : Theme.of(context).colorScheme.secondaryContainer),
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(16),
                            topRight: Radius.circular(16),
                            bottomLeft: Radius.circular(4),
                            bottomRight: Radius.circular(4),
                          ),
                          border: Border.all(
                            color: _downloadTypeExplode
                                ? (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.4) // Borde personalizado para amoled seleccionado
                                    : Theme.of(context).colorScheme.primary.withValues(alpha: 0.3))
                                : (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.2) // Borde personalizado para amoled no seleccionado
                                    : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1)),
                            width: _downloadTypeExplode ? 2 : 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: _downloadTypeExplode
                                    ? (isAmoled && isDark
                                        ? Colors.white.withValues(alpha: 0.2) // Fondo del ícono para amoled seleccionado
                                        : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1))
                                    : Colors.transparent,
                              ),
                              child: Icon(
                                Icons.explore,
                                size: 30,
                                color: _downloadTypeExplode
                                    ? (isAmoled && isDark
                                        ? Colors.white // Ícono blanco para amoled seleccionado
                                        : Theme.of(context).colorScheme.primary)
                                    : (isAmoled && isDark
                                        ? Colors.white // Ícono blanco para amoled no seleccionado
                                        : Theme.of(context).colorScheme.onSurface),
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    LocaleProvider.tr('explode'),
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: _downloadTypeExplode
                                          ? (isAmoled && isDark
                                              ? Colors.white // Texto blanco para amoled seleccionado
                                              : Theme.of(context).colorScheme.primary)
                                          : (isAmoled && isDark
                                              ? Colors.white // Texto blanco para amoled no seleccionado
                                              : Theme.of(context).colorScheme.onSurface),
                                    ),
                                  ),
                                  
                                ],
                              ),
                            ),
                            if (_downloadTypeExplode)
                              Icon(
                                Icons.check_circle,
                                color: isAmoled && isDark
                                    ? Colors.white // Check blanco para amoled
                                    : Theme.of(context).colorScheme.primary,
                                size: 24,
                              ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: 4),
                    // Tarjeta de método Directo
                    InkWell(
                      onTap: () async {
                        Navigator.of(context).pop();
                        await _setDownloadType(false);
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: !_downloadTypeExplode 
                              ? (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.2) // Color personalizado para amoled seleccionado
                                  : Theme.of(context).colorScheme.primaryContainer)
                              : (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.1) // Color personalizado para amoled no seleccionado
                                  : Theme.of(context).colorScheme.secondaryContainer),
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(4),
                            topRight: Radius.circular(4),
                            bottomLeft: Radius.circular(16),
                            bottomRight: Radius.circular(16),
                          ),
                          border: Border.all(
                            color: !_downloadTypeExplode
                                ? (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.4) // Borde personalizado para amoled seleccionado
                                    : Theme.of(context).colorScheme.primary.withValues(alpha: 0.3))
                                : (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.2) // Borde personalizado para amoled no seleccionado
                                    : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1)),
                            width: !_downloadTypeExplode ? 2 : 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: !_downloadTypeExplode
                                    ? (isAmoled && isDark
                                        ? Colors.white.withValues(alpha: 0.2) // Fondo del ícono para amoled seleccionado
                                        : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1))
                                    : Colors.transparent,
                              ),
                              child: Icon(
                                Icons.download_done,
                                size: 30,
                                color: !_downloadTypeExplode
                                    ? (isAmoled && isDark
                                        ? Colors.white // Ícono blanco para amoled seleccionado
                                        : Theme.of(context).colorScheme.primary)
                                    : (isAmoled && isDark
                                        ? Colors.white // Ícono blanco para amoled no seleccionado
                                        : Theme.of(context).colorScheme.onSurface),
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    LocaleProvider.tr('direct'),
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: !_downloadTypeExplode
                                          ? (isAmoled && isDark
                                              ? Colors.white // Texto blanco para amoled seleccionado
                                              : Theme.of(context).colorScheme.primary)
                                          : (isAmoled && isDark
                                              ? Colors.white // Texto blanco para amoled no seleccionado
                                              : Theme.of(context).colorScheme.onSurface),
                                    ),
                                  ),
                                  
                                ],
                              ),
                            ),
                            if (!_downloadTypeExplode)
                              Icon(
                                Icons.check_circle,
                                color: isAmoled && isDark
                                    ? Colors.white // Check blanco para amoled
                                    : Theme.of(context).colorScheme.primary,
                                size: 24,
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

  void _showLanguageDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
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
                child: TranslatedText(
                  'change_language',
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
                        child: TranslatedText(
                          'select_language_desc',
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
                    // Tarjeta de Español
                    InkWell(
                      onTap: () {
                        _setLanguage('es');
                        Navigator.of(context).pop();
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: _currentLanguage == 'es'
                              ? (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.2) // Color personalizado para amoled seleccionado
                                  : Theme.of(context).colorScheme.primaryContainer)
                              : (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.1) // Color personalizado para amoled no seleccionado
                                  : Theme.of(context).colorScheme.secondaryContainer),
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(16),
                            topRight: Radius.circular(16),
                            bottomLeft: Radius.circular(4),
                            bottomRight: Radius.circular(4),
                          ),
                          border: Border.all(
                            color: _currentLanguage == 'es'
                                ? (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.4) // Borde personalizado para amoled seleccionado
                                    : Theme.of(context).colorScheme.primary.withValues(alpha: 0.3))
                                : (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.2) // Borde personalizado para amoled no seleccionado
                                    : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1)),
                            width: _currentLanguage == 'es' ? 2 : 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: _currentLanguage == 'es'
                                    ? (isAmoled && isDark
                                        ? Colors.white.withValues(alpha: 0.2) // Fondo del ícono para amoled seleccionado
                                        : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1))
                                    : Colors.transparent,
                              ),
                              child: Icon(
                                Icons.language,
                                size: 30,
                                color: _currentLanguage == 'es'
                                    ? (isAmoled && isDark
                                        ? Colors.white // Ícono blanco para amoled seleccionado
                                        : Theme.of(context).colorScheme.primary)
                                    : (isAmoled && isDark
                                        ? Colors.white // Ícono blanco para amoled no seleccionado
                                        : Theme.of(context).colorScheme.onSurface),
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Español',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: _currentLanguage == 'es'
                                          ? (isAmoled && isDark
                                              ? Colors.white // Texto blanco para amoled seleccionado
                                              : Theme.of(context).colorScheme.primary)
                                          : (isAmoled && isDark
                                              ? Colors.white // Texto blanco para amoled no seleccionado
                                              : Theme.of(context).colorScheme.onSurface),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (_currentLanguage == 'es')
                              Icon(
                                Icons.check_circle,
                                color: isAmoled && isDark
                                    ? Colors.white // Check blanco para amoled
                                    : Theme.of(context).colorScheme.primary,
                                size: 24,
                              ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: 4),
                    // Tarjeta de English
                    InkWell(
                      onTap: () {
                        _setLanguage('en');
                        Navigator.of(context).pop();
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: _currentLanguage == 'en'
                              ? (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.2) // Color personalizado para amoled seleccionado
                                  : Theme.of(context).colorScheme.primaryContainer)
                              : (isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.1) // Color personalizado para amoled no seleccionado
                                  : Theme.of(context).colorScheme.secondaryContainer),
                          borderRadius: BorderRadius.only(
                            bottomLeft: Radius.circular(16),
                            bottomRight: Radius.circular(16),
                            topLeft: Radius.circular(4),
                            topRight: Radius.circular(4),
                          ),
                          border: Border.all(
                            color: _currentLanguage == 'en'
                                ? (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.4) // Borde personalizado para amoled seleccionado
                                    : Theme.of(context).colorScheme.primary.withValues(alpha: 0.3))
                                : (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.2) // Borde personalizado para amoled no seleccionado
                                    : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1)),
                            width: _currentLanguage == 'en' ? 2 : 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: _currentLanguage == 'en'
                                    ? (isAmoled && isDark
                                        ? Colors.white.withValues(alpha: 0.2) // Fondo del ícono para amoled seleccionado
                                        : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1))
                                    : Colors.transparent,
                              ),
                              child: Icon(
                                Icons.language,
                                size: 30,
                                color: _currentLanguage == 'en'
                                    ? (isAmoled && isDark
                                        ? Colors.white // Ícono blanco para amoled seleccionado
                                        : Theme.of(context).colorScheme.primary)
                                    : (isAmoled && isDark
                                        ? Colors.white // Ícono blanco para amoled no seleccionado
                                        : Theme.of(context).colorScheme.onSurface),
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'English',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: _currentLanguage == 'en'
                                          ? (isAmoled && isDark
                                              ? Colors.white // Texto blanco para amoled seleccionado
                                              : Theme.of(context).colorScheme.primary)
                                          : (isAmoled && isDark
                                              ? Colors.white // Texto blanco para amoled no seleccionado
                                              : Theme.of(context).colorScheme.onSurface),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (_currentLanguage == 'en')
                              Icon(
                                Icons.check_circle,
                                color: isAmoled && isDark
                                    ? Colors.white // Check blanco para amoled
                                    : Theme.of(context).colorScheme.primary,
                                size: 24,
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

  void _showGestureSettingsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => const GestureSettingsDialog(),
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
            
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white, width: 1)
                    : BorderSide.none,
              ),
              title: Center(
                child: TranslatedText(
                  'delete_lyrics',
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
                        child: TranslatedText(
                          'delete_lyrics_confirm',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                          textAlign: TextAlign.left,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    SizedBox(height: 20),
                    // Tarjeta de confirmar eliminación
                    InkWell(
                      onTap: () async {
                        Navigator.of(context).pop(true);
                        await SyncedLyricsService.clearLyrics();
                        if (context.mounted) {
                          _showLyricsDeletedDialog();
                        }
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: isAmoled && isDark
                              ? Colors.red.withValues(alpha: 0.2) // Color personalizado para amoled
                              : Theme.of(context).colorScheme.errorContainer,
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(16),
                            topRight: Radius.circular(16),
                            bottomLeft: Radius.circular(4),
                            bottomRight: Radius.circular(4),
                          ),
                          border: isAmoled && isDark
                              ? Border.all(
                                  color: Colors.red.withValues(alpha: 0.4), // Borde personalizado para amoled
                                  width: 1,
                                )
                              : null,
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              child: Icon(
                                Icons.delete_forever,
                                size: 30,
                                color: isAmoled && isDark
                                    ? Colors.red // Ícono rojo para amoled
                                    : Theme.of(context).colorScheme.error,
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    LocaleProvider.tr('delete'),
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: isAmoled && isDark
                                          ? Colors.red // Texto rojo para amoled
                                          : Theme.of(context).colorScheme.error,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: 4),
                    // Tarjeta de cancelar
                    InkWell(
                      onTap: () => Navigator.of(context).pop(false),
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: isAmoled && isDark
                              ? Colors.white.withValues(alpha: 0.1) // Color personalizado para amoled
                              : Theme.of(context).colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.only(
                            bottomLeft: Radius.circular(16),
                            bottomRight: Radius.circular(16),
                            topLeft: Radius.circular(4),
                            topRight: Radius.circular(4),
                          ),
                          border: Border.all(
                            color: isAmoled && isDark
                                ? Colors.white.withValues(alpha: 0.2) // Borde personalizado para amoled
                                : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: Colors.transparent,
                              ),
                              child: Icon(
                                Icons.cancel,
                                size: 30,
                                color: isAmoled && isDark
                                    ? Colors.white // Ícono blanco para amoled
                                    : Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    LocaleProvider.tr('cancel'),
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: isAmoled && isDark
                                          ? Colors.white // Texto blanco para amoled
                                          : Theme.of(context).colorScheme.onSurface,
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
            
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white, width: 1)
                    : BorderSide.none,
              ),
              title: Center(
                child: TranslatedText(
                  'lyrics_deleted',
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
                        child: TranslatedText(
                          'lyrics_deleted_desc',
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
                              ? Colors.white.withValues(alpha: 0.2) // Color personalizado para amoled
                              : Theme.of(context).colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isAmoled && isDark
                                ? Colors.white.withValues(alpha: 0.4) // Borde personalizado para amoled
                                : Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
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
                                    ? Colors.white.withValues(alpha: 0.2) // Fondo del ícono para amoled
                                    : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                              ),
                              child: Icon(
                                Icons.check_circle,
                                size: 30,
                                color: isAmoled && isDark
                                    ? Colors.white // Ícono blanco para amoled
                                    : Theme.of(context).colorScheme.primary,
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    LocaleProvider.tr('ok'),
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: isAmoled && isDark
                                          ? Colors.white // Texto blanco para amoled
                                          : Theme.of(context).colorScheme.primary,
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
          borderRadius: BorderRadius.circular(16),
          side: isAmoled && isDark
              ? const BorderSide(color: Colors.white, width: 1)
              : BorderSide.none,
        ),
        title: Text(LocaleProvider.tr('select_color')),
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
            itemCount: AppColorScheme.values
                .where((e) => e.toString() != 'AppColorScheme.grey')
                .length,
            itemBuilder: (context, index) {
              final filteredSchemes = AppColorScheme.values
                  .where((e) => e.toString() != 'AppColorScheme.grey')
                  .toList();
              final colorScheme = filteredSchemes[index];
              final color = ThemePreferences.getColorFromScheme(colorScheme);
              final isSelected = colorScheme == _currentColorScheme;

              return GestureDetector(
                onTap: () {
                  setState(() {
                    _currentColorScheme = colorScheme;
                  });
                  widget.setColorScheme?.call(colorScheme);
                  Navigator.of(context).pop();
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected ? Colors.white : Colors.transparent,
                      width: 3,
                    ),
                  ),
                  child: isSelected
                      ? const Icon(Icons.check, color: Colors.white, size: 24)
                      : null,
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(LocaleProvider.tr('cancel')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: TranslatedText('settings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
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
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Preferencias
          TranslatedText(
            'preferences',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary),
          ),
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(4),
                bottomRight: Radius.circular(4),
              ),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: Icon(
                    Theme.of(context).brightness == Brightness.dark
                        ? Icons.dark_mode
                        : Icons.light_mode,
                  ),
                  title: TranslatedText('select_theme'),
                  subtitle: TranslatedText(
                    _getCurrentThemeText(context),
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
                  ),
                  onTap: () => _showThemeSelectionDialog(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Card(
            margin: EdgeInsets.zero,
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
                  leading: const Icon(Icons.palette),
                  title: Text(LocaleProvider.tr('select_color')),
                  subtitle: Text(
                    ThemePreferences.getColorName(_currentColorScheme),
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
                  ),
                  onTap: () => _showColorSelectionDialog(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Card(
            margin: EdgeInsets.zero,
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
                  leading: const Icon(Icons.language),
                  title: TranslatedText('change_language'),
                  subtitle: TranslatedText(
                    _currentLanguage == 'es' ? 'spanish' : 'english',
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
                  ),
                  onTap: () => _showLanguageDialog(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Card(
            margin: EdgeInsets.zero,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(4),
                topRight: Radius.circular(4),
                bottomLeft: Radius.circular(16),
                bottomRight: Radius.circular(16),
              ),
            ),
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.touch_app),
                title: TranslatedText('gesture_settings'),
                subtitle: TranslatedText('gesture_settings_desc', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7))),
                onTap: () => _showGestureSettingsDialog(context),
              ),
            ],
          ),
        ),
          const SizedBox(height: 24),

          // Descargas
          TranslatedText(
            'downloads',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary),
          ),
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(4),
                bottomRight: Radius.circular(4),
              ),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.sd_storage),
                  title: Text(
                    _availableBytesAtDownloadDir != null &&
                            _totalBytesAtDownloadDir != null
                        ? '${_formatBytes(_availableBytesAtDownloadDir!)} ${LocaleProvider.tr('free_of')} ${_formatBytes(_totalBytesAtDownloadDir!)}'
                        : LocaleProvider.tr('calculating'),
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
                              backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                            ),
                          ),
                        )
                      : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Card(
            margin: EdgeInsets.zero,
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
                  leading: const Icon(Icons.folder),
                  title: TranslatedText('save_path'),
                  subtitle:
                      _downloadDirectory != null &&
                          _downloadDirectory!.isNotEmpty
                      ? Text(
                          _downloadDirectory!.startsWith('/storage/emulated/0')
                              ? _downloadDirectory!.replaceFirst(
                                  '/storage/emulated/0',
                                  '',
                                )
                              : _downloadDirectory!,
                          style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
                          overflow: TextOverflow.ellipsis,
                        )
                      : TranslatedText(
                          'not_selected',
                          style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
                        ),
                  trailing: const Icon(Icons.edit),
                  onTap: _pickDownloadDirectory,
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Card(
            margin: EdgeInsets.zero,
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
                  leading: const Icon(Icons.download),
                  title: TranslatedText('download_type'),
                  subtitle: TranslatedText(
                    'download_type_desc',
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.arrow_drop_down),
                    onPressed: () => _showDownloadTypeSelection(),
                  ),
                  onTap: () => _showDownloadTypeSelection(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Card(
            margin: EdgeInsets.zero,
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
                  leading: const Icon(Icons.audiotrack),
                  title: TranslatedText('audio_quality'),
                  subtitle: TranslatedText(
                    'audio_quality_desc',
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.arrow_drop_down),
                    onPressed: () => _showAudioQualitySelection(),
                  ),
                  onTap: () => _showAudioQualitySelection(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Card(
            margin: EdgeInsets.zero,
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
                  leading: const Icon(Symbols.add_photo_alternate, weight: 600),
                  title: TranslatedText('cover_quality'),
                  subtitle: TranslatedText(
                    'cover_quality_desc',
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.arrow_drop_down),
                    onPressed: () => _showCoverQualitySelection(),
                  ),
                  onTap: () => _showCoverQualitySelection(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Card(
            margin: EdgeInsets.zero,
            shape: const RoundedRectangleBorder(  
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(4),
                topRight: Radius.circular(4),
                bottomLeft: Radius.circular(16),
                bottomRight: Radius.circular(16),
              ),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.security),
                  title: Text(LocaleProvider.tr('grant_all_files_permission')),
                  subtitle: Text(
                    LocaleProvider.tr('grant_all_files_permission_desc'),
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
                  ),
                  onTap: () async {
                    final status = await Permission.manageExternalStorage
                        .request();
                    if (context.mounted) {
                      showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                            side: isAmoled && isDark
                                ? const BorderSide(color: Colors.white, width: 1)
                                : BorderSide.none,
                          ),
                          title: Text(
                            status.isGranted
                                ? LocaleProvider.tr('permission_granted')
                                : LocaleProvider.tr('permission_denied'),
                          ),
                          content: Text(
                            status.isGranted
                                ? LocaleProvider.tr('permission_granted_desc')
                                : LocaleProvider.tr('permission_denied_desc'),
                          ),
                        ),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Música y reproducción
          Text(
            LocaleProvider.tr('music_and_playback'),
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary),
          ),
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(4),
                bottomRight: Radius.circular(4),
              ),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.image),
                  title: Text(LocaleProvider.tr('artwork_quality')),
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
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        LocaleProvider.tr(
                          'artwork_quality_description',
                        ), // Agrega esta key en tus traducciones
                        style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
                      ),
                    ],
                  ),
                  onTap: () => _showArtworkQualityDialog(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Card(
            margin: EdgeInsets.zero,
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
                      title: Text(LocaleProvider.tr('index_songs_on_startup')),
                      subtitle: Text(
                        LocaleProvider.tr('index_songs_on_startup_desc'),
                        style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
                      ),
                      secondary: const Icon(Icons.library_music),
                      thumbIcon: WidgetStateProperty.resolveWith<Icon?>((Set<WidgetState> states) {
                        if (states.contains(WidgetState.selected)) {
                          return const Icon(Icons.check, size: 20);
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
            margin: EdgeInsets.zero,
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
                    final value = prefs.getBool('show_lyrics_on_cover') ?? false;
                    return SwitchListTile(
                      value: value,
                      onChanged: (v) async {
                        await prefs.setBool('show_lyrics_on_cover', v);
                        setState(() {});
                      },
                      title: Text(LocaleProvider.tr('show_lyrics_on_cover')),
                      subtitle: Text(
                        LocaleProvider.tr('show_lyrics_on_cover_desc'),
                        style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
                      ),
                      secondary: const Icon(Symbols.slab_serif, weight: 600),
                      thumbIcon: WidgetStateProperty.resolveWith<Icon?>((Set<WidgetState> states) {
                        if (states.contains(WidgetState.selected)) {
                          return const Icon(Icons.check, size: 20);
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
            margin: EdgeInsets.zero,
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
                  leading: const Icon(Icons.lyrics_outlined),
                  title: Text(LocaleProvider.tr('delete_lyrics')),
                  subtitle: Text(
                    LocaleProvider.tr('delete_lyrics_desc'),
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
                  ),
                  onTap: () => _showDeleteLyricsConfirmation(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Card(
            margin: EdgeInsets.zero,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(4),
                topRight: Radius.circular(4),
                bottomLeft: Radius.circular(16),
                bottomRight: Radius.circular(16),
              ),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.battery_alert),
                  title: Text(LocaleProvider.tr('ignore_battery_optimization')),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _checkingBatteryOpt
                            ? LocaleProvider.tr('status_checking')
                            : _batteryOptDisabled
                            ? LocaleProvider.tr('status_enabled')
                            : LocaleProvider.tr('status_disabled'),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        LocaleProvider.tr('ignore_battery_optimization_desc'),
                        style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
                      ),
                    ],
                  ),
                  onTap: () => _solicitarIgnorarOptimizacionDeBateria(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Apartado de Respaldo
          Text(
            LocaleProvider.tr('backup'),
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary),
          ),
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(4),
                bottomRight: Radius.circular(4),
              ),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.save_alt),
                  title: Text(LocaleProvider.tr('export_backup')),
                  subtitle: Text(
                    LocaleProvider.tr('export_backup_desc'),
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
                  ),
                  onTap: _exportBackup,
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Card(
            margin: EdgeInsets.zero,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(4),
                topRight: Radius.circular(4),
                bottomLeft: Radius.circular(16),
                bottomRight: Radius.circular(16),
              ),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.upload_file),
                  title: Text(LocaleProvider.tr('import_backup')),
                  subtitle: Text(
                    LocaleProvider.tr('import_backup_desc'),
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
                  ),
                  onTap: _importBackup,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Ajustes de la app
          Text(
            LocaleProvider.tr('app_settings'),
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary),
          ),
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(4),
                bottomRight: Radius.circular(4),
              ),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.restore),
                  title: Text(LocaleProvider.tr('reset_app')),
                  subtitle: Text(
                    LocaleProvider.tr('reset_app_desc'),
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
                  ),
                  onTap: _resetApp,
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Card(
            margin: EdgeInsets.zero,
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
                  leading: const Icon(Icons.system_update_alt),
                  title: Text(LocaleProvider.tr('app_updates')),
                  subtitle: Text(
                    LocaleProvider.tr('check_for_updates'),
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
                  ),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const UpdateScreen()),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Card(
            margin: EdgeInsets.zero,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(4),
                topRight: Radius.circular(4),
                bottomLeft: Radius.circular(16),
                bottomRight: Radius.circular(16),
              ),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: Text(LocaleProvider.tr('about')),
                  subtitle: Text(
                    LocaleProvider.tr('app_info'),
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
                  ),
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: isAmoled && isDark
                              ? const BorderSide(color: Colors.white, width: 1)
                              : BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.fromLTRB(
                          24,
                          24,
                          24,
                          8,
                        ),
                        content: Stack(
                          children: [
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: Image.asset(
                                'assets/icon.png',
                                width: 64,
                                height: 64,
                              ),
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              'Aura Music',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${LocaleProvider.tr('version')}: v1.5.2',
                              style: const TextStyle(fontSize: 15),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.surfaceContainer,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
                                  width: 1,
                                ),
                              ),
                              child: Text(
                                LocaleProvider.tr('app_description'),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.5,
                                  color: Theme.of(context).colorScheme.onSurface,
                                ),
                              ),
                            ),
                              ],
                            ),
                            // Ícono de GitHub en la esquina superior derecha
                            Positioned(
                              top: 0,
                              right: 0,
                              child: IconButton(
                                onPressed: () async {
                                  final Uri url = Uri.parse('https://github.com/KirbyNx64/Aura');
                                  if (await canLaunchUrl(url)) {
                                    await launchUrl(url, mode: LaunchMode.externalApplication);
                                  }
                                },
                                icon: Icon(
                                  icons_plus.Bootstrap.github,
                                  size: 44,
                                ),
                                tooltip: LocaleProvider.tr('view_on_github'),
                              ),
                            ),
                          ],
                        ),
                        actions: [
                          SizedBox(height: 8),
                          // Tarjeta de cancelar
                          InkWell(
                            onTap: () => Navigator.of(context).pop(),
                            borderRadius: BorderRadius.circular(16),
                            child: Container(
                              width: double.infinity,
                              padding: EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: (colorSchemeNotifier.value == AppColorScheme.amoled && Theme.of(context).brightness == Brightness.dark)
                                    ? Colors.white.withValues(alpha: 0.2)
                                    : Theme.of(context).colorScheme.primaryContainer,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: (colorSchemeNotifier.value == AppColorScheme.amoled && Theme.of(context).brightness == Brightness.dark)
                                      ? Colors.white.withValues(alpha: 0.4)
                                      : Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                                  width: 2,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    padding: EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(12),
                                      color: (colorSchemeNotifier.value == AppColorScheme.amoled && Theme.of(context).brightness == Brightness.dark)
                                          ? Colors.white.withValues(alpha: 0.2)
                                          : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                                    ),
                                    child: Icon(
                                      Icons.check_circle,
                                      size: 30,
                                      color: (colorSchemeNotifier.value == AppColorScheme.amoled && Theme.of(context).brightness == Brightness.dark)
                                          ? Colors.white
                                          : Theme.of(context).colorScheme.primary,
                                    ),
                                  ),
                                  SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          LocaleProvider.tr('ok'),
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w600,
                                            color: (colorSchemeNotifier.value == AppColorScheme.amoled && Theme.of(context).brightness == Brightness.dark)
                                                ? Colors.white
                                                : Theme.of(context).colorScheme.primary,
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
                    );
                  },
                ),
              ],
            ),
          ),
        ],
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
              
              return AlertDialog(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: isAmoled && isDark
                      ? const BorderSide(color: Colors.white, width: 1)
                      : BorderSide.none,
                ),
                title: Center(
                  child: Text(
                    LocaleProvider.tr('reset_app_confirm'),
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
                            LocaleProvider.tr('reset_app_warning'),
                            style: TextStyle(
                              fontSize: 14,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                            textAlign: TextAlign.left,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      SizedBox(height: 20),
                      // Tarjeta de confirmar restablecimiento
                      InkWell(
                        onTap: () => Navigator.of(context).pop(true),
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          width: double.infinity,
                          padding: EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: isAmoled && isDark
                                ? Colors.red.withValues(alpha: 0.2) // Color personalizado para amoled
                                : Theme.of(context).colorScheme.errorContainer,
                            borderRadius: BorderRadius.only(
                              topLeft: Radius.circular(16),
                              topRight: Radius.circular(16),
                              bottomLeft: Radius.circular(4),
                              bottomRight: Radius.circular(4),
                            ),
                            border: isAmoled && isDark
                                ? Border.all(
                                    color: Colors.red.withValues(alpha: 0.4), // Borde personalizado para amoled
                                    width: 1,
                                  )
                                : null,
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: EdgeInsets.all(8),
                                child: Icon(
                                  Icons.restore,
                                  size: 30,
                                  color: isAmoled && isDark
                                      ? Colors.red // Ícono rojo para amoled
                                      : Theme.of(context).colorScheme.error,
                                ),
                              ),
                              SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      LocaleProvider.tr('reset_app'),
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        color: isAmoled && isDark
                                            ? Colors.red // Texto rojo para amoled
                                            : Theme.of(context).colorScheme.error,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      SizedBox(height: 4),
                      // Tarjeta de cancelar
                      InkWell(
                        onTap: () => Navigator.of(context).pop(false),
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          width: double.infinity,
                          padding: EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: isAmoled && isDark
                                ? Colors.white.withValues(alpha: 0.1) // Color personalizado para amoled
                                : Theme.of(context).colorScheme.secondaryContainer,
                            borderRadius: BorderRadius.only(
                              bottomLeft: Radius.circular(16),
                              bottomRight: Radius.circular(16),
                              topLeft: Radius.circular(4),
                              topRight: Radius.circular(4),
                            ),
                            border: Border.all(
                              color: isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.2) // Borde personalizado para amoled
                                  : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  color: Colors.transparent,
                                ),
                                child: Icon(
                                  Icons.cancel,
                                  size: 30,
                                  color: isAmoled && isDark
                                      ? Colors.white // Ícono blanco para amoled
                                      : Theme.of(context).colorScheme.onSurface,
                                ),
                              ),
                              SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      LocaleProvider.tr('cancel'),
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        color: isAmoled && isDark
                                            ? Colors.white // Texto blanco para amoled
                                            : Theme.of(context).colorScheme.onSurface,
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
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: isAmoled && isDark
                      ? const BorderSide(color: Colors.white, width: 1)
                      : BorderSide.none,
                ),
                title: Center(
                  child: Text(
                    LocaleProvider.tr('success'),
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
                            LocaleProvider.tr('reset_app_success'),
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
                                ? Colors.white.withValues(alpha: 0.2) // Color personalizado para amoled
                                : Theme.of(context).colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.4) // Borde personalizado para amoled
                                  : Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
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
                                      ? Colors.white.withValues(alpha: 0.2) // Fondo del ícono para amoled
                                      : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                                ),
                                child: Icon(
                                  Icons.check_circle,
                                  size: 30,
                                  color: isAmoled && isDark
                                      ? Colors.white // Ícono blanco para amoled
                                      : Theme.of(context).colorScheme.primary,
                                ),
                              ),
                              SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      LocaleProvider.tr('ok'),
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        color: isAmoled && isDark
                                            ? Colors.white // Texto blanco para amoled
                                            : Theme.of(context).colorScheme.primary,
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
                                  ? Colors.red.withValues(alpha: 0.2) // Color personalizado para amoled
                                  : Theme.of(context).colorScheme.errorContainer,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isAmoled && isDark
                                    ? Colors.red.withValues(alpha: 0.4) // Borde personalizado para amoled
                                    : Theme.of(context).colorScheme.error.withValues(alpha: 0.3),
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
                                        ? Colors.red.withValues(alpha: 0.2) // Fondo del ícono para amoled
                                        : Theme.of(context).colorScheme.error.withValues(alpha: 0.1),
                                  ),
                                  child: Icon(
                                    Icons.error,
                                    size: 30,
                                    color: isAmoled && isDark
                                        ? Colors.red // Ícono rojo para amoled
                                        : Theme.of(context).colorScheme.error,
                                  ),
                                ),
                                SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        LocaleProvider.tr('ok'),
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                          color: isAmoled && isDark
                                              ? Colors.red // Texto rojo para amoled
                                              : Theme.of(context).colorScheme.error,
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
