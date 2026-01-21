import 'package:flutter/material.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/gesture_preferences.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/theme_preferences.dart';

class GestureSettingsDialog extends StatefulWidget {
  const GestureSettingsDialog({super.key});

  @override
  State<GestureSettingsDialog> createState() => _GestureSettingsDialogState();
}

class _GestureSettingsDialogState extends State<GestureSettingsDialog> {
  Map<String, bool> _gesturePreferences = {
    'closePlayer': true,
    'openPlaylist': true,
    'changeSong': true,
    'openPlayer': true,
  };
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final preferences = await GesturePreferences.getAllGesturePreferences();
    setState(() {
      // Invertir la lógica: true = activo, false = desactivado
      _gesturePreferences = {
        'closePlayer': !preferences['closePlayer']!,
        'openPlaylist': !preferences['openPlaylist']!,
        'changeSong': !preferences['changeSong']!,
        'openPlayer': !preferences['openPlayer']!,
      };
      _isLoading = false;
    });
  }

  Future<void> _savePreferences() async {
    // Invertir la lógica al guardar: true = activo, false = desactivado
    final preferencesToSave = {
      'closePlayer': !_gesturePreferences['closePlayer']!,
      'openPlaylist': !_gesturePreferences['openPlaylist']!,
      'changeSong': !_gesturePreferences['changeSong']!,
      'openPlayer': !_gesturePreferences['openPlayer']!,
    };
    await GesturePreferences.setAllGesturePreferences(preferencesToSave);
    // Notificar que las preferencias han cambiado
    gesturePreferencesChanged.value = !gesturePreferencesChanged.value;
  }

  @override
  Widget build(BuildContext context) {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
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
          LocaleProvider.tr('gesture_settings_title'),
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      content: _isLoading
          ? const SizedBox(
              height: 200,
              child: Center(child: CircularProgressIndicator()),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  LocaleProvider.tr('gesture_settings_desc_dialog'),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  title: Text(LocaleProvider.tr('gesture_open_player')),
                  value: _gesturePreferences['openPlayer']!,
                  onChanged: (value) {
                    setState(() {
                      _gesturePreferences['openPlayer'] = value;
                    });
                  },
                ),
                SwitchListTile(
                  title: Text(LocaleProvider.tr('gesture_close_player')),
                  value: _gesturePreferences['closePlayer']!,
                  onChanged: (value) {
                    setState(() {
                      _gesturePreferences['closePlayer'] = value;
                    });
                  },
                ),
                SwitchListTile(
                  title: Text(LocaleProvider.tr('gesture_open_playlist')),
                  value: _gesturePreferences['openPlaylist']!,
                  onChanged: (value) {
                    setState(() {
                      _gesturePreferences['openPlaylist'] = value;
                    });
                  },
                ),
                SwitchListTile(
                  title: Text(LocaleProvider.tr('gesture_change_song')),
                  value: _gesturePreferences['changeSong']!,
                  onChanged: (value) {
                    setState(() {
                      _gesturePreferences['changeSong'] = value;
                    });
                  },
                ),
              ],
            ),
      actions: _isLoading
          ? []
          : [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(LocaleProvider.tr('cancel')),
              ),
              TextButton(
                onPressed: () async {
                  await _savePreferences();
                  if (mounted) {
                    if (!context.mounted) return;
                    Navigator.of(context).pop();
                  }
                },
                child: Text(LocaleProvider.tr('ok')),
              ),
            ],
    );
  }
}
