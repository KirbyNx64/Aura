import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:music/utils/permission/permission_handler.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:music/widgets/bottom_nav.dart';
import 'package:music/screens/home/home_screen.dart';
import 'package:music/screens/likes/favorites_screen.dart';
import 'package:music/screens/folders/folders_screen.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';
import 'package:music/utils/yt_search/yt_screen.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:music/utils/db/playlist_model.dart';
import 'package:music/utils/db/download_history_model.dart';
import 'package:music/utils/db/artist_songs_cache_db.dart';
import 'package:music/utils/audio/synced_lyrics_service.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'package:music/utils/yt_search/stream_provider.dart';
import 'package:music/utils/db/songs_index_db.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:flutter_sharing_intent/model/sharing_file.dart';
import 'package:music/utils/sharing_handler.dart';
import 'package:music/utils/yt_preview_modal.dart';
import 'package:music/services/download_history_service.dart';
import 'package:material_loading_indicator/loading_indicator.dart';
import 'package:music/screens/onboarding/onboarding_screen.dart';
import 'package:music/utils/theme_controller.dart';
import 'package:music/utils/download_manager.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';
import 'dart:async';
import 'package:terminate_restart/terminate_restart.dart';

// Cambiar de late final a nullable para mejor manejo de errores
AudioHandler? audioHandler;
bool _audioHandlerInitialized = false;
bool _audioHandlerInitializing = false;

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// Notifier para indicar cuando el AudioService está listo
final ValueNotifier<bool> audioServiceReady = ValueNotifier<bool>(false);
final ValueNotifier<bool> overlayVisibleNotifier = ValueNotifier<bool>(
  false,
); // Notificador global para el overlay

/// Extension para facilitar el acceso seguro a MyAudioHandler
extension AudioHandlerSafeCast on AudioHandler? {
  MyAudioHandler? get myHandler {
    final handler = this;
    if (handler is MyAudioHandler) return handler;
    return null;
  }
}

/// Verifica si el AudioService está inicializando
bool get isAudioServiceInitializing => _audioHandlerInitializing;

/// Función para realizar la indexación de canciones y artistas (solo la primera vez)
Future<void> performIndexingIfNeeded() async {
  try {
    // Verificar si realmente necesita indexación
    final songsIndexDB = SongsIndexDB();
    final needsIndex = await songsIndexDB.needsIndexing();

    if (!needsIndex) {
      // print('🎵 La app ya está indexada, no se necesita indexación');
      return;
    }

    // print('🎵 Primera vez abriendo la app - Iniciando indexación...');

    // Obtener el total de canciones
    final OnAudioQuery audioQuery = OnAudioQuery();
    final allSongs = await audioQuery.querySongs();
    // print('🎵 Procesando ${allSongs.length} canciones...');

    // Realizar la indexación de canciones
    await songsIndexDB.indexAllSongs(allSongs);

    // print('🎵 Indexación completada exitosamente - La app está lista');
  } catch (e) {
    // print('❌ Error durante la indexación: $e');
    // Continuar de todas formas para no bloquear la app
  }
}

/// Obtiene el AudioService de forma segura, esperando si es necesario
Future<AudioHandler?> getAudioServiceSafely() async {
  // Si ya está listo, retornarlo inmediatamente
  if (audioHandler != null && _audioHandlerInitialized) {
    return audioHandler;
  }

  // Si está inicializando, esperar
  if (_audioHandlerInitializing) {
    // ('⏳ Esperando a que AudioService termine de inicializar...');
    while (_audioHandlerInitializing) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    return audioHandler;
  }

  // Si no está inicializado, intentar inicializarlo
  return await initializeAudioServiceSafely();
}

/// Inicializa el AudioService de forma normal
Future<AudioHandler?> initializeAudioServiceSafely() async {
  if (_audioHandlerInitialized && audioHandler != null) {
    return audioHandler;
  }

  if (_audioHandlerInitializing) {
    // Esperar si ya se está inicializando
    while (_audioHandlerInitializing) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    return audioHandler;
  }

  try {
    _audioHandlerInitializing = true;

    // Usar la nueva función segura que maneja mejor los conflictos
    audioHandler = await getAudioHandlerSafely();

    _audioHandlerInitialized = true;
    audioServiceReady.value = true; // Notificar que está listo
    return audioHandler;
  } catch (e) {
    _audioHandlerInitialized = false;
    audioHandler = null;
    audioServiceReady.value = false; // Resetear el estado

    // Intentar reinicializar como último recurso
    try {
      await reinitializeAudioHandler();
      audioHandler = await getAudioHandlerSafely();
      _audioHandlerInitialized = true;
      audioServiceReady.value = true;
      return audioHandler;
    } catch (e2) {
      // Error silencioso - la app puede funcionar sin audio service
    }

    return null;
  } finally {
    _audioHandlerInitializing = false;
  }
}

class LifecycleHandler extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.detached) {
      try {
        await audioHandler?.customAction("saveSession");
        // Cerrar YoutubeExplode cuando la app se cierra
        DownloadManager().closeYoutubeExplode();
      } catch (_) {}
    }
  }
}

// Declara el ValueNotifier global en main.dart
final selectedTabIndex = ValueNotifier<int>(0);

final GlobalKey<HomeScreenState> homeScreenKey = GlobalKey<HomeScreenState>();
final GlobalKey ytScreenKey = GlobalKey();
final GlobalKey favoritesScreenKey = GlobalKey();
final GlobalKey foldersScreenKey = GlobalKey();

class MainNavRoot extends StatefulWidget {
  final void Function(AppThemeMode) setThemeMode;
  final void Function(AppColorScheme) setColorScheme;
  const MainNavRoot({
    super.key,
    required this.setThemeMode,
    required this.setColorScheme,
  });
  @override
  State<MainNavRoot> createState() => _MainNavRootState();
}

class _MainNavRootState extends State<MainNavRoot> {
  StreamSubscription? _sharingSubscription;

  @override
  void initState() {
    super.initState();
    _initializeSharingHandler();
  }

  @override
  void dispose() {
    _sharingSubscription?.cancel();
    super.dispose();
  }

  /// Inicializa el manejador de enlaces compartidos
  void _initializeSharingHandler() {
    // Escuchar enlaces compartidos entrantes
    _sharingSubscription = SharingHandler.sharingIntentStream.listen(
      (List<SharedFile> sharedFiles) async {
        await _handleSharedLinks(sharedFiles);
      },
      onError: (error) {
        // print('Error en sharing intent: $error');
      },
    );

    // Procesar enlaces compartidos iniciales (cuando la app se abre desde un enlace)
    SharingHandler.getInitialSharingMedia().then((
      List<SharedFile> sharedFiles,
    ) {
      if (sharedFiles.isNotEmpty) {
        _handleSharedLinks(sharedFiles);
      }
    });
  }

  /// Maneja los enlaces compartidos de YouTube
  Future<void> _handleSharedLinks(List<SharedFile> sharedFiles) async {
    try {
      final youtubeResults = await SharingHandler.processSharedLinks(
        sharedFiles,
      );

      if (youtubeResults.isNotEmpty) {
        // Cambiar a la pestaña de YouTube (índice 1)
        selectedTabIndex.value = 1;

        // Abrir el YtPreviewPlayer con los resultados
        if (mounted) {
          _openYtPreviewPlayer(youtubeResults);
        }
      } else {
        // No se encontraron resultados válidos
        if (mounted) {
          _showErrorDialog(
            LocaleProvider.tr('error'),
            LocaleProvider.tr('youtube_link_invalid'),
          );
        }
      }
    } catch (e) {
      // Mostrar diálogo de error si algo falla
      if (mounted) {
        _showErrorDialog(
          LocaleProvider.tr('error'),
          LocaleProvider.tr(
            'youtube_processing_error',
          ).replaceAll('@error', e.toString()),
        );
      }
    }
  }

  /// Abre el YtPreviewPlayer con los resultados de YouTube
  void _openYtPreviewPlayer(List<dynamic> results) {
    // Abrir el modal directamente desde aquí
    _showYtPreviewPlayerModal(results);
  }

  /// Muestra el modal del YtPreviewPlayer
  void _showYtPreviewPlayerModal(List<dynamic> results) {
    if (results.isEmpty) {
      _showErrorDialog(
        LocaleProvider.tr('error'),
        LocaleProvider.tr('youtube_no_results'),
      );
      return;
    }

    // Navegar a la pestaña de YouTube primero
    selectedTabIndex.value = 1;

    // Obtener el contexto de la aplicación
    final context = homeScreenKey.currentContext ?? ytScreenKey.currentContext;
    if (context != null) {
      // Esperar un momento y luego abrir el modal
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) {
          if (!context.mounted) return;
          try {
            YtPreviewModal.show(context, results);
          } catch (e) {
            _showErrorDialog(
              LocaleProvider.tr('error'),
              LocaleProvider.tr(
                'youtube_modal_error',
              ).replaceAll('@error', e.toString()),
            );
          }
        }
      });
    } else {
      _showErrorDialog(
        LocaleProvider.tr('error'),
        LocaleProvider.tr('youtube_context_error'),
      );
    }
  }

  /// Muestra un diálogo de error
  void _showErrorDialog(String title, String message) {
    final context = homeScreenKey.currentContext ?? ytScreenKey.currentContext;
    if (context != null && context.mounted) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
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

  @override
  Widget build(BuildContext context) {
    return Material3BottomNav(
      pageBuilders: [
        (context, onTabChange) => HomeScreen(
          key: homeScreenKey,
          onTabChange: onTabChange,
          setThemeMode: widget.setThemeMode,
          setColorScheme: widget.setColorScheme,
        ),
        (context, onTabChange) => YtSearchTestScreen(key: ytScreenKey),
        (context, onTabChange) => FavoritesScreen(key: favoritesScreenKey),
        (context, onTabChange) => FoldersScreen(key: foldersScreenKey),
      ],
      selectedTabIndex: selectedTabIndex,
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Backend de video más robusto (media_kit) manteniendo API de video_player.
  VideoPlayerMediaKit.ensureInitialized(android: true);
  TerminateRestart.instance.initialize();
  await Hive.initFlutter();
  Hive.registerAdapter(PlaylistModelAdapter());
  Hive.registerAdapter(DownloadHistoryModelAdapter());
  await SyncedLyricsService.initialize();

  // Inicialización del servicio de notificaciones
  await NotificationService.initialize();

  try {
    await ArtistSongsCacheDB().clearAllCache();
  } catch (_) {}

  await LocaleProvider.loadLocale();

  // Verificar si es la primera vez que se ejecuta la app
  final prefs = await SharedPreferences.getInstance();
  final isFirstRun = prefs.getBool('first_run') ?? true;

  // Cargar preferencias de tema inmediatamente para evitar parpadeos
  final themeIndex = prefs.getInt('theme_mode');
  if (themeIndex != null &&
      themeIndex >= 0 &&
      themeIndex < AppThemeMode.values.length) {
    themeModeNotifier.value = AppThemeMode.values[themeIndex];
  } else {
    // Intentar migración de formato antiguo si fuera necesario
    final oldIsDarkMode = prefs.getBool('theme_mode');
    if (oldIsDarkMode != null) {
      themeModeNotifier.value = oldIsDarkMode
          ? AppThemeMode.dark
          : AppThemeMode.light;
    }
  }

  final colorIndex = prefs.getInt('color_scheme');
  if (colorIndex != null &&
      colorIndex >= 0 &&
      colorIndex < AppColorScheme.values.length) {
    colorSchemeNotifier.value = AppColorScheme.values[colorIndex];
  }

  // Cargar preferencias de fondo AMOLED/Dinámico
  useArtworkAsBackgroundPlayerNotifier.value =
      prefs.getBool('use_artwork_background_player') ?? true;
  useArtworkAsBackgroundOverlayNotifier.value =
      prefs.getBool('use_artwork_background_overlay') ?? false;
  useDynamicColorBackgroundNotifier.value =
      prefs.getBool('use_dynamic_color_background') ?? false;
  useDynamicColorInDialogsNotifier.value =
      prefs.getBool('use_dynamic_color_in_dialogs') ?? false;

  // Cargar directorio de descargas
  final downloadDir =
      prefs.getString('download_directory') ?? '/storage/emulated/0/Music';
  downloadDirectoryNotifier.value = downloadDir;

  // Cargar calidad de carátula streaming al arrancar para que el player use
  // la calidad correcta desde el primer render.
  final storedCoverQuality = prefs.getString('cover_quality');
  final legacyCoverHigh = prefs.getBool('cover_quality_high');
  final resolvedCoverQuality =
      (storedCoverQuality == 'high' ||
          storedCoverQuality == 'medium' ||
          storedCoverQuality == 'medium_low' ||
          storedCoverQuality == 'low')
      ? storedCoverQuality!
      : (legacyCoverHigh == true ? 'high' : 'medium_low');
  coverQualityNotifier.value = resolvedCoverQuality;

  final storedStreamingAudioQuality = prefs.getString('stream_audio_quality');
  final resolvedStreamingAudioQuality =
      (storedStreamingAudioQuality == 'high' ||
          storedStreamingAudioQuality == 'low')
      ? storedStreamingAudioQuality!
      : 'low';
  streamingAudioQualityNotifier.value = resolvedStreamingAudioQuality;

  bool permisosOk = false;

  if (!isFirstRun) {
    permisosOk = await pedirPermisosMedia();
  } else {
    // Si es primera vez, asumimos que no hay permisos pero dejamos pasar al Onboarding,
    // que se encargará de pedirlos.
    permisosOk = true;
  }

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Configuración inicial de la barra de navegación del sistema
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarDividerColor: Colors.transparent,
    ),
  );

  // Para Android 15+, asegurar que el contenido no se superponga con la barra de navegación
  // sin cambiar los colores
  SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.manual,
    overlays: [SystemUiOverlay.top, SystemUiOverlay.bottom],
  );

  if (!permisosOk && !isFirstRun) {
    runApp(
      MaterialApp(
        scaffoldMessengerKey: rootScaffoldMessengerKey,
        home: PermisosScreen(),
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale('es', ''), Locale('en', '')],
        locale: Locale(languageNotifier.value, ''),
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: ThemePreferences.getColorFromScheme(
            colorSchemeNotifier.value,
          ),
          brightness: Brightness.dark,
        ),
      ),
    );
    return;
  }

  // Inicializar AudioService ANTES de verificar indexación para que esté disponible siempre
  try {
    await initializeAudioServiceSafely();
  } catch (e) {
    // La app seguirá, pero el audio podría no estar disponible hasta que se intente de nuevo
  }

  Future.microtask(() async {
    try {
      await StreamService.cleanExpiredStreams();
    } catch (_) {}
  });

  // Realizar indexación solo si es la primera vez que se abre la app (pero no en onboarding)
  if (!isFirstRun) {
    performIndexingIfNeeded();
  }

  // Precargar el SVG en memoria antes de mostrar la app
  try {
    // Cargar el SVG como string para precargarlo en memoria
    await rootBundle.loadString('assets/icon/icon_foreground.svg');
  } catch (e) {
    // Si falla la precarga, continuar de todas formas
  }

  // Pre-inicializar base de datos de historial de descargas en segundo plano
  Future.microtask(() async {
    try {
      await DownloadHistoryService().preInitialize();
      // Verificar si hay descargas no vistas
      hasNewDownloadsNotifier.value = await DownloadHistoryService()
          .hasUnviewedDownloads();
    } catch (e) {
      // Error silencioso - se inicializará cuando se necesite
    }
  });

  // Ir directo a MainApp y dejar la inicialización en segundo plano como respaldo
  runApp(MyRootApp());

  // (Opcional) Inicializar AudioService en segundo plano después de que la UI esté lista
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    if (!_audioHandlerInitialized) {
      try {
        await initializeAudioServiceSafely();
      } catch (e) {
        // Error silencioso
      }
    }
  });
}

class PermisosScreen extends StatefulWidget {
  const PermisosScreen({super.key});

  @override
  State<PermisosScreen> createState() => _PermisosScreenState();
}

class _PermisosScreenState extends State<PermisosScreen>
    with WidgetsBindingObserver {
  final bool _cargando = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.resumed) {
      final ok = await pedirPermisosMedia();
      if (ok) {
        if (!mounted) return;

        // Solo inicializar audioHandler si no se ha inicializado antes
        if (!_audioHandlerInitialized) {
          audioHandler = await initAudioService();
          _audioHandlerInitialized = true;
        }

        if (!mounted) return;

        // Realizar indexación solo si es la primera vez que se abre la app
        performIndexingIfNeeded();

        // Ir directo a la app
        if (!mounted) return;
        Navigator.of(
          context,
        ).pushReplacement(MaterialPageRoute(builder: (_) => MyRootApp()));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.lock,
                size: 80,
                color: Colors.white.withAlpha((0.85 * 255).toInt()),
              ),
              const SizedBox(height: 34),
              const Text(
                'Se requieren permisos de almacenamiento y multimedia para usar la app.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18),
              ),
              const SizedBox(height: 42),
              ElevatedButton.icon(
                icon: const Icon(Icons.security),
                label: _cargando
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: LoadingIndicator(
                          activeIndicatorColor: Colors.white,
                        ),
                      )
                    : const Text('Otorgar permisos'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.deepPurple,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(180, 48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  elevation: 0,
                ),
                onPressed: _cargando
                    ? null
                    : () async {
                        await openAppSettings();
                      },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MainApp extends StatefulWidget {
  final String currentLanguage;

  const MainApp({super.key, required this.currentLanguage});

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> with WidgetsBindingObserver {
  bool _isLoading = true;
  bool _showOnboarding = false;
  int? _lastShownStreamErrorId;
  bool _isShowingStreamErrorDialog = false;
  final GlobalKey<NavigatorState> _appNavigatorKey =
      GlobalKey<NavigatorState>();

  // Variables para mantener los colores dinámicos actuales
  ColorScheme? _currentLightDynamic;
  ColorScheme? _currentDarkDynamic;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadThemePreferences();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    // Reconfigurar cuando la app regrese del segundo plano
    if (state == AppLifecycleState.resumed) {
      // Restaurar configuración de audio (volumen, equalizer, etc.)
      // Esto es crucial para evitar que el volumen se quede bajo después de
      // que la app ha estado en segundo plano por mucho tiempo
      if (audioHandler != null) {
        audioHandler.myHandler?.restoreAudioConfiguration();
      }

      // Reconfigurar la barra de navegación
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Usar los colores dinámicos guardados
        _updateSystemNavigationBar(_currentLightDynamic, _currentDarkDynamic);

        // Re-aplicar wakelock si está habilitado
        if (wakelockEnabledNotifier.value) {
          WakelockPlus.toggle(enable: true);
        }
      });
    }
  }

  // Método para actualizar la barra de navegación del sistema
  void _updateSystemNavigationBar([
    ColorScheme? lightDynamic,
    ColorScheme? darkDynamic,
  ]) {
    if (!mounted) return;

    try {
      final isDark =
          themeModeNotifier.value == AppThemeMode.dark ||
          (themeModeNotifier.value == AppThemeMode.system &&
              MediaQuery.of(context).platformBrightness == Brightness.dark);

      // Obtener el color correcto basado en el esquema de color actual
      Color surfaceColor;

      if (colorSchemeNotifier.value == AppColorScheme.amoled && isDark) {
        // Para tema AMOLED, usar negro
        surfaceColor = Colors.black;
      } else if (colorSchemeNotifier.value == AppColorScheme.system) {
        // Para tema sistema, usar los colores dinámicos si están disponibles
        if (isDark && darkDynamic != null) {
          surfaceColor = darkDynamic.surface;
        } else if (!isDark && lightDynamic != null) {
          surfaceColor = lightDynamic.surface;
        } else {
          // Fallback si no hay colores dinámicos
          surfaceColor = isDark
              ? const Color(0xFF121212)
              : const Color(0xFFF5F5F5);
        }
      } else {
        // Para otros temas, crear un tema temporal con el esquema correcto
        final tempTheme = _buildTheme(
          isDark ? Brightness.dark : Brightness.light,
        );
        surfaceColor = tempTheme.colorScheme.surface;
      }

      // Configurar la barra de navegación del sistema
      SystemChrome.setSystemUIOverlayStyle(
        SystemUiOverlayStyle(
          systemNavigationBarColor: surfaceColor,
          systemNavigationBarIconBrightness: isDark
              ? Brightness.light
              : Brightness.dark,
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
          systemNavigationBarDividerColor: Colors.transparent,
        ),
      );

      // Configuración adicional para Android con retraso para asegurar que se aplique
      if (Theme.of(context).platform == TargetPlatform.android) {
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted) {
            SystemChrome.setSystemUIOverlayStyle(
              SystemUiOverlayStyle(
                systemNavigationBarColor: surfaceColor,
                systemNavigationBarIconBrightness: isDark
                    ? Brightness.light
                    : Brightness.dark,
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: isDark
                    ? Brightness.light
                    : Brightness.dark,
                systemNavigationBarDividerColor: Colors.transparent,
              ),
            );
          }
        });
      }
    } catch (e) {
      // En caso de error, usar configuración por defecto
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness: Brightness.light,
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
        ),
      );
    }
  }

  Future<void> _loadThemePreferences() async {
    await ThemePreferences.getThemeMode();
    final savedColorScheme = await ThemePreferences.getColorScheme();
    if (mounted) {
      // Inicializar el notifier con el color guardado
      colorSchemeNotifier.value = savedColorScheme;

      final prefs = await SharedPreferences.getInstance();

      // Verificar si es la primera vez (onboarding) y otras preferencias
      final isFirstRun = prefs.getBool('first_run') ?? true;

      final nextButtonEnabled =
          prefs.getBool('overlay_next_button_enabled') ?? true;
      final useArtworkOverlay =
          prefs.getBool('use_artwork_background_overlay') ?? false;
      final useArtworkPlayer =
          prefs.getBool('use_artwork_background_player') ?? true;

      // Actualizar estado una sola vez
      setState(() {
        _showOnboarding = isFirstRun;

        overlayNextButtonEnabled.value = nextButtonEnabled;
        wakelockEnabledNotifier.value =
            prefs.getBool('wakelock_enabled') ?? false;
        if (wakelockEnabledNotifier.value) {
          WakelockPlus.toggle(enable: true);
        }
        useArtworkAsBackgroundOverlayNotifier.value = useArtworkOverlay;
        useArtworkAsBackgroundPlayerNotifier.value = useArtworkPlayer;
        useDynamicColorBackgroundNotifier.value =
            prefs.getBool('use_dynamic_color_background') ?? false;
        useDynamicColorInDialogsNotifier.value =
            prefs.getBool('use_dynamic_color_in_dialogs') ?? false;

        final lyricsProviderIndex =
            prefs.getInt('lyrics_service_provider') ??
            LyricsServiceProvider.simpmusic.index;
        if (lyricsProviderIndex >= 0 &&
            lyricsProviderIndex < LyricsServiceProvider.values.length) {
          lyricsServiceProviderNotifier.value =
              LyricsServiceProvider.values[lyricsProviderIndex];
        }

        _isLoading = false;
      });

      // Configurar la barra de navegación del sistema después de cargar las preferencias
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _updateSystemNavigationBar();
      });

      // Iniciar el listener del ThemeController cuando el audioHandler esté listo
      _initThemeControllerListener();
    }
  }

  /// Inicia el listener del ThemeController para escuchar cambios de canción
  void _initThemeControllerListener() {
    if (audioHandler != null) {
      ThemeController.instance.startListening(audioHandler!.mediaItem);
    } else {
      // Esperar a que el audioHandler esté listo
      void listener() {
        if (audioServiceReady.value && audioHandler != null) {
          ThemeController.instance.startListening(audioHandler!.mediaItem);
          audioServiceReady.removeListener(listener);
        }
      }

      audioServiceReady.addListener(listener);
    }
  }

  void _setThemeMode(AppThemeMode themeMode) async {
    themeModeNotifier.value = themeMode;
    // Guardar la preferencia
    await ThemePreferences.setThemeMode(themeMode);

    // Si se activa modo claro o sistema y el color es AMOLED, cambiar a sistema
    // ya que AMOLED solo tiene sentido en modo oscuro.
    if (themeMode != AppThemeMode.dark &&
        colorSchemeNotifier.value == AppColorScheme.amoled) {
      _setColorScheme(AppColorScheme.system);
    }

    // Actualizar la barra de navegación del sistema con los colores dinámicos actuales
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateSystemNavigationBar(_currentLightDynamic, _currentDarkDynamic);
    });
  }

  void _setColorScheme(AppColorScheme colorScheme) async {
    // Actualizar el notifier para que el tema se actualice inmediatamente
    colorSchemeNotifier.value = colorScheme;
    // Guardar la preferencia
    await ThemePreferences.setColorScheme(colorScheme);

    // Si se activa AMOLED, activar también el modo oscuro
    if (colorScheme == AppColorScheme.amoled) {
      _setThemeMode(AppThemeMode.dark);
    }

    // Actualizar la barra de navegación del sistema con los colores dinámicos actuales
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateSystemNavigationBar(_currentLightDynamic, _currentDarkDynamic);
    });
  }

  ThemeData _buildTheme(
    Brightness brightness, [
    ColorScheme? dynamicColorScheme,
    Color? artworkColor,
  ]) {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    if (isAmoled && brightness == Brightness.dark) {
      return ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        canvasColor: Colors.black,
        cardColor: Colors.black,
        // dialogBackgroundColor: Colors.black, // deprecated
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
        dialogTheme: const DialogThemeData(backgroundColor: Colors.black),
        colorScheme: const ColorScheme.dark(
          primary: Colors.white,
          onPrimary: Colors.black,
          secondary: Colors.white70,
          onSecondary: Colors.black,
          surface: Colors.black,
          onSurface: Colors.white,
          error: Colors.red,
          onError: Colors.white,
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: Colors.white),
          bodyMedium: TextStyle(color: Colors.white),
          bodySmall: TextStyle(color: Colors.white70),
          titleLarge: TextStyle(color: Colors.white),
          titleMedium: TextStyle(color: Colors.white),
          titleSmall: TextStyle(color: Colors.white70),
        ),
      );
    }

    // Si se seleccionó "Sistema" y hay colores dinámicos disponibles, usarlos
    if (colorSchemeNotifier.value == AppColorScheme.system &&
        dynamicColorScheme != null) {
      return ThemeData(
        useMaterial3: true,
        colorScheme: dynamicColorScheme,
        brightness: brightness,
      );
    }

    // Si el esquema es dinámico y hay color de carátula, usarlo
    final isDynamic = colorSchemeNotifier.value == AppColorScheme.dynamic;
    final seedColor = (isDynamic && artworkColor != null)
        ? artworkColor
        : ThemePreferences.getColorFromScheme(colorSchemeNotifier.value);

    return ThemeData(
      useMaterial3: true,
      colorSchemeSeed: seedColor,
      brightness: brightness,
    );
  }

  String _streamErrorMessageForCode(String code) {
    switch (code) {
      case 'restricted':
        return LocaleProvider.tr('error_loading_audio_restricted');
      case 'network':
        return LocaleProvider.tr('error_loading_audio_network');
      default:
        return LocaleProvider.tr('error_loading_audio');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Mostrar pantalla de carga mientras se cargan las preferencias
    if (_isLoading) {
      return MaterialApp(
        scaffoldMessengerKey: rootScaffoldMessengerKey,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale('es', ''), Locale('en', '')],
        locale: Locale(languageNotifier.value, ''),
        theme: _buildTheme(Brightness.dark),
        home: Scaffold(body: Center(child: LoadingIndicator())),
      );
    }

    return ValueListenableBuilder<AppThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, themeMode, child) {
        return DynamicColorBuilder(
          builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
            // Guardar los colores dinámicos actuales
            _currentLightDynamic = lightDynamic;
            _currentDarkDynamic = darkDynamic;

            return ValueListenableBuilder<AppColorScheme>(
              valueListenable: colorSchemeNotifier,
              builder: (context, colorScheme, child) {
                // Actualizar la barra de navegación cuando cambie el color
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _updateSystemNavigationBar(lightDynamic, darkDynamic);
                });

                // Escuchar cambios del color dominante extraído de la carátula
                return ValueListenableBuilder<Color?>(
                  valueListenable: ThemeController.instance.dominantColor,
                  builder: (context, artworkColor, _) {
                    return MaterialApp(
                      title: 'Aura',
                      themeAnimationDuration: Duration.zero,
                      navigatorKey: _appNavigatorKey,
                      scaffoldMessengerKey: rootScaffoldMessengerKey,
                      builder: (context, child) {
                        return ValueListenableBuilder<
                          StreamPlaybackErrorEvent?
                        >(
                          valueListenable: streamPlaybackErrorNotifier,
                          builder: (context, streamError, _) {
                            if (streamError != null &&
                                streamError.id != _lastShownStreamErrorId) {
                              _lastShownStreamErrorId = streamError.id;
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (!mounted) return;
                                if (_isShowingStreamErrorDialog) return;

                                final dialogContext =
                                    _appNavigatorKey.currentContext ?? context;
                                final isAmoled =
                                    colorSchemeNotifier.value ==
                                    AppColorScheme.amoled;
                                final isDark =
                                    Theme.of(dialogContext).brightness ==
                                    Brightness.dark;
                                final primaryColor = Theme.of(
                                  dialogContext,
                                ).colorScheme.primary;

                                _isShowingStreamErrorDialog = true;
                                try {
                                  showDialog<void>(
                                    context: dialogContext,
                                    useRootNavigator: true,
                                    builder: (dialogBuilderContext) {
                                      return AlertDialog(
                                        backgroundColor: isAmoled && isDark
                                            ? Colors.black
                                            : Theme.of(
                                                dialogBuilderContext,
                                              ).colorScheme.surface,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            28,
                                          ),
                                          side: isAmoled && isDark
                                              ? const BorderSide(
                                                  color: Colors.white24,
                                                  width: 1,
                                                )
                                              : BorderSide.none,
                                        ),
                                        surfaceTintColor: Colors.transparent,
                                        contentPadding:
                                            const EdgeInsets.fromLTRB(
                                              0,
                                              24,
                                              0,
                                              8,
                                            ),
                                        content: ConstrainedBox(
                                          constraints: BoxConstraints(
                                            maxWidth: 400,
                                            maxHeight:
                                                MediaQuery.of(
                                                  dialogBuilderContext,
                                                ).size.height *
                                                0.8,
                                          ),
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.error_outline_rounded,
                                                size: 32,
                                                color: Theme.of(
                                                  dialogBuilderContext,
                                                ).colorScheme.onSurface,
                                              ),
                                              const SizedBox(height: 16),
                                              Text(
                                                LocaleProvider.tr('error'),
                                                style: TextStyle(
                                                  fontSize: 20,
                                                  fontWeight: FontWeight.bold,
                                                  color: Theme.of(
                                                    dialogBuilderContext,
                                                  ).colorScheme.onSurface,
                                                ),
                                              ),
                                              const SizedBox(height: 16),
                                              Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 24,
                                                    ),
                                                child: Text(
                                                  _streamErrorMessageForCode(
                                                    streamError.code,
                                                  ),
                                                  style: TextStyle(
                                                    fontSize: 14,
                                                    color:
                                                        Theme.of(
                                                              dialogBuilderContext,
                                                            )
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
                                                  alignment:
                                                      Alignment.centerRight,
                                                  child: Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      if (streamError.videoId !=
                                                              null &&
                                                          streamError
                                                              .videoId!
                                                              .isNotEmpty)
                                                        TextButton(
                                                          onPressed: () async {
                                                            Navigator.of(
                                                              dialogBuilderContext,
                                                            ).pop();
                                                            final videoId =
                                                                streamError
                                                                    .videoId!
                                                                    .trim();
                                                            if (videoId
                                                                .isEmpty) {
                                                              return;
                                                            }
                                                            try {
                                                              await StreamService.invalidateCachedStream(
                                                                videoId,
                                                              );
                                                              final refreshedUrl =
                                                                  await StreamService.getBestAudioUrl(
                                                                    videoId,
                                                                    forceRefresh:
                                                                        true,
                                                                    reportError:
                                                                        true,
                                                                    fastFail:
                                                                        true,
                                                                  );
                                                              if (refreshedUrl ==
                                                                      null ||
                                                                  refreshedUrl
                                                                      .isEmpty) {
                                                                return;
                                                              }
                                                              await audioHandler
                                                                  ?.customAction(
                                                                    'retryCurrentStream',
                                                                    {
                                                                      'videoId':
                                                                          videoId,
                                                                      'streamUrl':
                                                                          refreshedUrl,
                                                                    },
                                                                  );
                                                            } catch (_) {}
                                                          },
                                                          child: Text(
                                                            LocaleProvider.tr(
                                                              'retry',
                                                            ),
                                                            style: TextStyle(
                                                              color:
                                                                  primaryColor,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .bold,
                                                            ),
                                                          ),
                                                        ),
                                                      TextButton(
                                                        onPressed: () =>
                                                            Navigator.of(
                                                              dialogBuilderContext,
                                                            ).pop(),
                                                        child: Text(
                                                          LocaleProvider.tr(
                                                            'ok',
                                                          ),
                                                          style: TextStyle(
                                                            color: primaryColor,
                                                            fontWeight:
                                                                FontWeight.bold,
                                                          ),
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
                                  ).whenComplete(() {
                                    if (mounted) {
                                      _isShowingStreamErrorDialog = false;
                                    }
                                  });
                                } catch (_) {
                                  _isShowingStreamErrorDialog = false;
                                }
                              });
                            }
                            return child ?? const SizedBox.shrink();
                          },
                        );
                      },
                      localizationsDelegates: const [
                        GlobalMaterialLocalizations.delegate,
                        GlobalWidgetsLocalizations.delegate,
                        GlobalCupertinoLocalizations.delegate,
                      ],
                      supportedLocales: const [
                        Locale('es', ''),
                        Locale('en', ''),
                      ],
                      locale: Locale(languageNotifier.value, ''),
                      themeMode: themeMode == AppThemeMode.system
                          ? ThemeMode.system
                          : themeMode == AppThemeMode.dark
                          ? ThemeMode.dark
                          : ThemeMode.light,
                      theme: _buildTheme(
                        Brightness.light,
                        lightDynamic,
                        artworkColor,
                      ),
                      darkTheme: _buildTheme(
                        Brightness.dark,
                        darkDynamic,
                        artworkColor,
                      ),
                      home: _showOnboarding
                          ? OnboardingScreen(
                              onFinish: () {
                                setState(() {
                                  _showOnboarding = false;
                                });
                                // Después de terminar el onboarding y tener permisos, indexar la música
                                performIndexingIfNeeded();
                              },
                            )
                          : MainNavRoot(
                              setThemeMode: _setThemeMode,
                              setColorScheme: _setColorScheme,
                            ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

class MyRootApp extends StatelessWidget {
  const MyRootApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: languageNotifier,
      builder: (context, lang, _) {
        return MainApp(currentLanguage: lang);
      },
    );
  }
}

class ErrorInitScreen extends StatelessWidget {
  final VoidCallback onRetry;
  const ErrorInitScreen({super.key, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 80, color: Colors.redAccent),
              const SizedBox(height: 34),
              const Text(
                'No se pudo inicializar el audio.\nCierra la app completamente y vuelve a intentarlo.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18),
              ),
              const SizedBox(height: 42),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Intentar de nuevo'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.deepPurple,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(180, 48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  elevation: 0,
                ),
                onPressed: onRetry,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
