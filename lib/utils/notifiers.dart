import 'package:flutter/material.dart';
import 'package:music/utils/theme_preferences.dart';

final foldersShouldReload = ValueNotifier<bool>(false);

final favoritesShouldReload = ValueNotifier<bool>(false);

final playlistsShouldReload = ValueNotifier<bool>(false);

final recentsShouldReload = ValueNotifier<bool>(false);

final mostPlayedShouldReload = ValueNotifier<bool>(false);

final downloadDirectoryNotifier = ValueNotifier<String?>(null);
final downloadTypeNotifier = ValueNotifier<bool>(
  false,
); // true: Explode, false: Directo
final audioProcessorNotifier = ValueNotifier<bool>(
  false,
); // true: FFmpeg, false: AudioTags

final colorSchemeNotifier = ValueNotifier<AppColorScheme>(
  AppColorScheme.deepPurple,
);

final ValueNotifier<bool> shortcutsShouldReload = ValueNotifier(false);

final ValueNotifier<String> audioQualityNotifier = ValueNotifier<String>(
  'high',
); // 'high', 'medium', 'low'

final ValueNotifier<bool> coverQualityNotifier = ValueNotifier<bool>(
  true,
); // true: alta, false: baja

final ValueNotifier<bool> heroAnimationNotifier = ValueNotifier(true);

final ValueNotifier<bool> playLoadingNotifier = ValueNotifier(false);

final ValueNotifier<bool> overlayNextButtonEnabled = ValueNotifier(false);

// Notifier para controlar si el overlay puede abrir la pantalla del reproductor
final ValueNotifier<bool> overlayPlayerNavigationEnabled = ValueNotifier(true);

// Notifier para actualizar las preferencias de gestos
final ValueNotifier<bool> gesturePreferencesChanged = ValueNotifier(false);

// Notifier para notificar cuando se actualiza una letra
final ValueNotifier<String?> lyricsUpdatedNotifier = ValueNotifier<String?>(null);

// Notifier para el idioma de traducción
final ValueNotifier<String> translationLanguageNotifier = ValueNotifier<String>('auto');

// Notifier para el badge de descargas nuevas
final ValueNotifier<bool> hasNewDownloadsNotifier = ValueNotifier<bool>(false);