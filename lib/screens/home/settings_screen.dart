import 'dart:io';
import 'package:flutter/material.dart';
import 'package:music/screens/home/ota_update_screen.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:music/utils/db/artwork_db.dart';
import 'package:music/utils/db/favorites_db.dart';
import 'package:music/utils/db/playlists_db.dart';
import 'package:music/utils/db/recent_db.dart';
import 'package:music/utils/db/mostplayer_db.dart';
import 'package:sqflite/sqflite.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_selector/file_selector.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/audio/synced_lyrics_service.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'dart:convert';
import 'package:flutter/services.dart';

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
  bool _audioProcessorFFmpeg = false; // true: FFmpeg, false: AudioTags
  AppColorScheme _currentColorScheme = AppColorScheme.deepPurple;

  @override
  void initState() {
    super.initState();
    _checkBatteryOptimization();
    _loadLanguage();
    _loadDownloadDirectory();
    _loadDownloadTypeAndProcessor();
    _loadColorScheme();
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

  void _showLanguageDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(LocaleProvider.tr('change_language')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioListTile<String>(
              value: 'es',
              groupValue: _currentLanguage,
              title: const Text('Español'),
              onChanged: (v) {
                if (v != null) {
                  _setLanguage(v);
                  Navigator.of(context).pop();
                }
              },
            ),
            RadioListTile<String>(
              value: 'en',
              groupValue: _currentLanguage,
              title: const Text('English'),
              onChanged: (v) {
                if (v != null) {
                  _setLanguage(v);
                  Navigator.of(context).pop();
                }
              },
            ),
          ],
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

  Future<void> _checkBatteryOptimization() async {
    if (!Platform.isAndroid) return;
    setState(() => _checkingBatteryOpt = true);
    final status = await Permission.ignoreBatteryOptimizations.status;
    setState(() {
      _batteryOptDisabled = status.isGranted;
      _checkingBatteryOpt = false;
    });
  }

  Future<void> _solicitarIgnorarOptimizacionDeBateria(BuildContext context) async {
    if (Platform.isAndroid) {
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
      builder: (context) => AlertDialog(
        title: Text(LocaleProvider.tr('select_theme')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.brightness_auto),
              title: Text(LocaleProvider.tr('system_default')),
              onTap: () {
                widget.setThemeMode?.call(AppThemeMode.system);
                Navigator.of(context).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.light_mode),
              title: Text(LocaleProvider.tr('light_mode')),
              onTap: () {
                widget.setThemeMode?.call(AppThemeMode.light);
                Navigator.of(context).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.dark_mode),
              title: Text(LocaleProvider.tr('dark_mode')),
              onTap: () {
                widget.setThemeMode?.call(AppThemeMode.dark);
                Navigator.of(context).pop();
              },
            ),
          ],
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
  }

  Future<void> _setDownloadDirectory(String? path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('download_directory', path ?? '');
    setState(() {
      _downloadDirectory = path;
    });
    downloadDirectoryNotifier.value = path;
  }

  Future<void> _pickDownloadDirectory() async {
    if (Platform.isAndroid) {
      // Check Android version
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      final sdkInt = androidInfo.version.sdkInt;
      
      // If Android 9 (API 28) or lower, use default Music folder
      if (sdkInt <= 28) {
        const defaultPath = '/storage/emulated/0/Music';
        await _setDownloadDirectory(defaultPath);
        
        if (mounted) {
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
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
    
    // For Android 10+ and other platforms, use file selector
    try {
      final String? path = await getDirectoryPath();
      if (path != null && path.isNotEmpty) {
        await _setDownloadDirectory(path);
      }
    } catch (e) {
      // Fallback error handling
      if (Platform.isAndroid) {
        const defaultPath = '/storage/emulated/0/Music';
        await _setDownloadDirectory(defaultPath);
        
        if (mounted) {
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
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
      } else {
        if (mounted) {
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(LocaleProvider.tr('error')),
              content: Text('${LocaleProvider.tr('error')}: $e'),
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

  Future<void> _loadDownloadTypeAndProcessor() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _downloadTypeExplode = prefs.getBool('download_type_explode') ?? false;
      _audioProcessorFFmpeg = prefs.getBool('audio_processor_ffmpeg') ?? false;
    });
    downloadTypeNotifier.value = _downloadTypeExplode;
    audioProcessorNotifier.value = _audioProcessorFFmpeg;
  }

  Future<void> _setDownloadType(bool explode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('download_type_explode', explode);
    setState(() {
      _downloadTypeExplode = explode;
    });
    downloadTypeNotifier.value = explode;
  }

  Future<void> _setAudioProcessor(bool ffmpeg) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('audio_processor_ffmpeg', ffmpeg);
    setState(() {
      _audioProcessorFFmpeg = ffmpeg;
    });
    audioProcessorNotifier.value = ffmpeg;
  }

  Future<void> _loadColorScheme() async {
    final savedColorScheme = await ThemePreferences.getColorScheme();
    setState(() {
      _currentColorScheme = savedColorScheme;
    });
  }

  void _showColorSelectionDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
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
            itemCount: AppColorScheme.values.where((e) => e.toString() != 'AppColorScheme.grey').length,
            itemBuilder: (context, index) {
              final filteredSchemes = AppColorScheme.values.where((e) => e.toString() != 'AppColorScheme.grey').toList();
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
                      ? const Icon(
                          Icons.check,
                          color: Colors.white,
                          size: 24,
                        )
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
    return Scaffold(
      appBar: AppBar(
        title: TranslatedText('settings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Preferencias
          TranslatedText(
            'preferences',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(
                    Theme.of(context).brightness == Brightness.dark 
                        ? Icons.dark_mode 
                        : Icons.light_mode,
                  ),
                  title: TranslatedText('select_theme'),
                  subtitle: TranslatedText(_getCurrentThemeText(context), style: const TextStyle(fontSize: 12)),
                  onTap: () => _showThemeSelectionDialog(context),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.palette),
                  title: Text(LocaleProvider.tr('select_color')),
                  subtitle: Text(ThemePreferences.getColorName(_currentColorScheme), style: const TextStyle(fontSize: 12)),
                  onTap: () => _showColorSelectionDialog(context),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.language),
                  title: TranslatedText('change_language'),
                  subtitle: TranslatedText(_currentLanguage == 'es' ? 'spanish' : 'english', style: const TextStyle(fontSize: 12)),
                  onTap: () => _showLanguageDialog(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Descargas
          TranslatedText(
            'downloads',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.folder),
                  title: TranslatedText('save_path'),
                  subtitle: _downloadDirectory != null && _downloadDirectory!.isNotEmpty
                      ? Text(
                          _downloadDirectory!.startsWith('/storage/emulated/0')
                              ? _downloadDirectory!.replaceFirst('/storage/emulated/0', '')
                              : _downloadDirectory!,
                          style: const TextStyle(fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                        )
                      : TranslatedText('not_selected', style: const TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.edit),
                  onTap: _pickDownloadDirectory,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.download),
                  title: TranslatedText('download_type'),
                  subtitle: TranslatedText('download_type_desc', style: const TextStyle(fontSize: 12)),
                  trailing: DropdownButton<bool>(
                    value: _downloadTypeExplode,
                    items: [
                      DropdownMenuItem(
                        value: true,
                        child: TranslatedText('explode'),
                      ),
                      DropdownMenuItem(
                        value: false,
                        child: TranslatedText('direct'),
                      ),
                    ],
                    onChanged: (v) {
                      if (v != null) _setDownloadType(v);
                    },
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.settings),
                  title: Text(LocaleProvider.tr('audio_processor')),
                  subtitle: Text(LocaleProvider.tr('audio_processor_desc'), style: const TextStyle(fontSize: 12)),
                  trailing: DropdownButton<bool>(
                    value: _audioProcessorFFmpeg,
                    items: [
                      DropdownMenuItem(
                        value: true,
                        child: Text(LocaleProvider.tr('ffmpeg')),
                      ),
                      DropdownMenuItem(
                        value: false,
                        child: Text(LocaleProvider.tr('audiotags')),
                      ),
                    ],
                    onChanged: (v) {
                      if (v != null) _setAudioProcessor(v);
                    },
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.security),
                  title: Text(LocaleProvider.tr('grant_all_files_permission')),
                  subtitle: Text(LocaleProvider.tr('grant_all_files_permission_desc'), style: const TextStyle(fontSize: 12)),
                  onTap: () async {
                    final status = await Permission.manageExternalStorage.request();
                    if (context.mounted) {
                      showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text(status.isGranted ? LocaleProvider.tr('permission_granted') : LocaleProvider.tr('permission_denied')),
                          content: Text(status.isGranted
                              ? LocaleProvider.tr('permission_granted_desc')
                              : LocaleProvider.tr('permission_denied_desc')),
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
            '${LocaleProvider.tr('music_and_playback')}:',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                FutureBuilder<SharedPreferences>(
                  future: SharedPreferences.getInstance(),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) return SizedBox.shrink();
                    final prefs = snapshot.data!;
                    final value = prefs.getBool('index_songs_on_startup') ?? true;
                    return SwitchListTile(
                      value: value,
                      onChanged: (v) async {
                        await prefs.setBool('index_songs_on_startup', v);
                        setState(() {});
                      },
                      title: Text(LocaleProvider.tr('index_songs_on_startup')),
                      subtitle: Text(LocaleProvider.tr('index_songs_on_startup_desc'), style: const TextStyle(fontSize: 12)),
                      secondary: const Icon(Icons.library_music),
                    );
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.lyrics),
                  title: Text(LocaleProvider.tr('delete_lyrics')),
                  subtitle: Text(LocaleProvider.tr('delete_lyrics_desc'), style: const TextStyle(fontSize: 12)),
                  onTap: () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text(LocaleProvider.tr('delete_lyrics')),
                        content: Text(LocaleProvider.tr('delete_lyrics_confirm')),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(false),
                            child: Text(LocaleProvider.tr('cancel')),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(true),
                            child: Text(LocaleProvider.tr('delete')),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true) {
                      await SyncedLyricsService.clearLyrics();
                      if (context.mounted) {
                        showDialog(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Text(LocaleProvider.tr('lyrics_deleted')),
                            content: Text(LocaleProvider.tr('lyrics_deleted_desc')),
                          ),
                        );
                      }
                    }
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.cleaning_services),
                  title: Text(LocaleProvider.tr('clear_artwork_cache')),
                  subtitle: Text(LocaleProvider.tr('clear_artwork_cache_desc'), style: const TextStyle(fontSize: 12)),
                  onTap: () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text(LocaleProvider.tr('clear_artwork_cache')),
                        content: Text(LocaleProvider.tr('clear_artwork_cache_confirm')),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(false),
                            child: Text(LocaleProvider.tr('cancel')),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(true),
                            child: Text(LocaleProvider.tr('delete')),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true) {
                      await ArtworkDB.clearCache();
                      if (context.mounted) {
                        showDialog(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Text(LocaleProvider.tr('artwork_cache_cleared')),
                            content: Text(LocaleProvider.tr('artwork_cache_cleared_desc')),
                          ),
                        );
                      }
                    }
                  },
                ),
                const Divider(height: 1),
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
                        style: const TextStyle(fontSize: 12),
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
            '${LocaleProvider.tr('backup')}:',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.save_alt),
                  title: Text(LocaleProvider.tr('export_backup')),
                  subtitle: Text(LocaleProvider.tr('export_backup_desc'), style: const TextStyle(fontSize: 12)),
                  onTap: _exportBackup,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.upload_file),
                  title: Text(LocaleProvider.tr('import_backup')),
                  subtitle: Text(LocaleProvider.tr('import_backup_desc'), style: const TextStyle(fontSize: 12)),
                  onTap: _importBackup,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Ajustes de la app
          Text(
            '${LocaleProvider.tr('app_settings')}:',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.system_update_alt),
                  title: Text(LocaleProvider.tr('app_updates')),
                  subtitle: Text(LocaleProvider.tr('check_for_updates'), style: const TextStyle(fontSize: 12)),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const UpdateScreen()),
                    );
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: Text(LocaleProvider.tr('about')),
                  subtitle: Text(LocaleProvider.tr('app_info'), style: const TextStyle(fontSize: 12)),
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        contentPadding: const EdgeInsets.fromLTRB(
                          24,
                          24,
                          24,
                          8,
                        ),
                        content: Column(
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
                              '${LocaleProvider.tr('version')}: v1.3.0',
                              style: const TextStyle(
                                fontSize: 15,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              LocaleProvider.tr('app_description'),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: Text(LocaleProvider.tr('cancel')),
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
    try {
      // Obtener datos de las bases de datos
      final favorites = await FavoritesDB().getFavorites();
      final recents = await RecentsDB().getRecents();
      final mostPlayed = await MostPlayedDB().getMostPlayed(limit: 10000);
      final playlistsRaw = await PlaylistsDB().getAllPlaylists();
      final playlists = <Map<String, dynamic>>[];
      for (final pl in playlistsRaw) {
        final songs = await PlaylistsDB().getSongsFromPlaylist(pl['id'] as int);
        playlists.add({
          'id': pl['id'],
          'name': pl['name'],
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
          title: Text(LocaleProvider.tr('success')),
          content: Text(LocaleProvider.tr('backup_exported')),
        ),
      );
    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(LocaleProvider.tr('error')),
            content: Text('${LocaleProvider.tr('error')}: $e'),
          ),
        );
      }
    }
  }

  Future<void> _importBackup() async {
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
      final dbFav = await FavoritesDB().database;
      await dbFav.delete('favorites');
      final dbRec = await RecentsDB().database;
      await dbRec.delete('recents');
      final dbMost = await MostPlayedDB().database;
      await dbMost.delete('most_played');
      final dbPl = await PlaylistsDB().database;
      await dbPl.delete('playlist_songs');
      await dbPl.delete('playlists');
      // Restaurar favoritos
      if (data['favorites'] is List) {
        for (final path in data['favorites']) {
          await dbFav.insert('favorites', {'path': path}, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }
      // Restaurar recientes
      if (data['recents'] is List) {
        for (final path in data['recents']) {
          await dbRec.insert('recents', {'path': path, 'timestamp': DateTime.now().millisecondsSinceEpoch}, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      // Restaurar más escuchadas
      if (data['mostPlayed'] is List) {
        for (final path in data['mostPlayed']) {
          await dbMost.insert('most_played', {'path': path, 'play_count': 1}, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      // Restaurar playlists
      if (data['playlists'] is List) {
        for (final pl in data['playlists']) {
          final playlistId = await dbPl.insert('playlists', {'name': pl['name']}, conflictAlgorithm: ConflictAlgorithm.ignore);
          if (pl['songs'] is List) {
            for (final songPath in pl['songs']) {
              await dbPl.insert('playlist_songs', {'playlist_id': playlistId, 'song_path': songPath}, conflictAlgorithm: ConflictAlgorithm.ignore);
            }
          }
        }
      }
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(LocaleProvider.tr('success')),
          content: Text(LocaleProvider.tr('backup_imported')),
          actions: [
            TextButton(
              onPressed: () {
                SystemNavigator.pop();
              },
              child: Text(LocaleProvider.tr('restart_app')),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(LocaleProvider.tr('error')),
            content: Text('${LocaleProvider.tr('error')}: $e'),
          ),
        );
      }
    }
  }
}
