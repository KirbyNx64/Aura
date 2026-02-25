import 'package:flutter/material.dart';
import 'package:music/utils/theme_preferences.dart';

final foldersShouldReload = ValueNotifier<bool>(false);

final favoritesShouldReload = ValueNotifier<bool>(false);

final dislikesShouldReload = ValueNotifier<bool>(false);

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
  AppColorScheme.amoled,
);

final themeModeNotifier = ValueNotifier<AppThemeMode>(AppThemeMode.dark);

final ValueNotifier<bool> shortcutsShouldReload = ValueNotifier(false);

final ValueNotifier<String> audioQualityNotifier = ValueNotifier<String>(
  'high',
); // 'high', 'medium', 'low'

final ValueNotifier<String> coverQualityNotifier = ValueNotifier<String>(
  'high',
); // 'high', 'medium', 'low'

final ValueNotifier<bool> playLoadingNotifier = ValueNotifier(false);

final ValueNotifier<bool> overlayNextButtonEnabled = ValueNotifier(false);

// Notifier para controlar si el overlay puede abrir la pantalla del reproductor
final ValueNotifier<bool> overlayPlayerNavigationEnabled = ValueNotifier(true);

// Notifier para actualizar las preferencias de gestos
final ValueNotifier<bool> gesturePreferencesChanged = ValueNotifier(false);

// Notifier para notificar cuando se actualiza una letra
final ValueNotifier<String?> lyricsUpdatedNotifier = ValueNotifier<String?>(
  null,
);

// Notifier para el idioma de traducción
final ValueNotifier<String> translationLanguageNotifier = ValueNotifier<String>(
  'auto',
);

// Notifier para el badge de descargas nuevas
final ValueNotifier<bool> hasNewDownloadsNotifier = ValueNotifier<bool>(false);

// Notifier para usar la carátula como fondo en el reproductor
final ValueNotifier<bool> useArtworkAsBackgroundPlayerNotifier =
    ValueNotifier<bool>(true);

// Notifier para usar la carátula como fondo en el overlay
final ValueNotifier<bool> useArtworkAsBackgroundOverlayNotifier =
    ValueNotifier<bool>(true);

// Notifier para usar color dinámico como fondo
final ValueNotifier<bool> useDynamicColorBackgroundNotifier =
    ValueNotifier<bool>(false);

// Notifier para usar color dinámico en los diálogos/bottom sheets (SleepTimer, AddToPlaylist, etc)
final ValueNotifier<bool> useDynamicColorInDialogsNotifier =
    ValueNotifier<bool>(false);

// Notifier para enfocar la búsqueda YT al cambiar de tab desde la barra de home
final ValueNotifier<bool> focusYtSearchNotifier = ValueNotifier<bool>(false);

// Notifier para ocultar la barra de navegación en búsquedas
final ValueNotifier<bool> bottomNavVisibleNotifier = ValueNotifier<bool>(true);

// Notifier para notificar cuando se actualiza una carpeta específica (ej. nueva descarga)
final ValueNotifier<String?> folderUpdatedNotifier = ValueNotifier<String?>(
  null,
);

// Notifier para solicitar la apertura del panel del reproductor
final ValueNotifier<bool> openPlayerPanelNotifier = ValueNotifier<bool>(false);

// Notifier para controlar si la pantalla debe permanecer encendida
final ValueNotifier<bool> wakelockEnabledNotifier = ValueNotifier<bool>(false);

enum LyricsServiceProvider { lrclib, simpmusic }

final lyricsServiceProviderNotifier = ValueNotifier<LyricsServiceProvider>(
  LyricsServiceProvider.simpmusic,
);
