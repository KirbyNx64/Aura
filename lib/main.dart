import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:music/utils/permission/permission_handler.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:music/widgets/bottom_nav.dart';
import 'package:music/screens/home/home_screen.dart';
import 'package:music/screens/likes/favorites_screen.dart';
import 'package:music/screens/folders/folders_screen.dart';
import 'package:music/screens/download/download_screen.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';
import 'package:music/utils/yt_search/yt_screen.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:music/utils/db/playlist_model.dart';
import 'package:music/utils/audio/synced_lyrics_service.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'package:music/utils/db/songs_index_db.dart';
import 'package:music/utils/db/artists_db.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:flutter_sharing_intent/model/sharing_file.dart';
import 'package:music/utils/sharing_handler.dart';
import 'package:music/utils/yt_preview_modal.dart';
import 'dart:async';

// Cambiar de late final a nullable para mejor manejo de errores
AudioHandler? audioHandler;
bool _audioHandlerInitialized = false;
bool _audioHandlerInitializing = false;

/// Notifier para indicar cuando el AudioService está listo
final ValueNotifier<bool> audioServiceReady = ValueNotifier<bool>(false);
final ValueNotifier<bool> overlayVisibleNotifier = ValueNotifier<bool>(
  false,
); // Notificador global para el overlay

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
    await songsIndexDB.indexAllSongs();

    // print('🎵 Indexando artistas...');
    
    // Indexar artistas
    final artistsDB = ArtistsDB();
    await artistsDB.indexArtists(allSongs);
    
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

    audioHandler = await initAudioService();

    _audioHandlerInitialized = true;
    audioServiceReady.value = true; // Notificar que está listo
    return audioHandler;
  } catch (e) {
    _audioHandlerInitialized = false;
    audioHandler = null;
    audioServiceReady.value = false; // Resetear el estado
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
      } catch (_) {}
    }
  }
}

// Declara el ValueNotifier global en main.dart
final selectedTabIndex = ValueNotifier<int>(0);

// Declara el key global arriba en main.dart
final GlobalKey<HomeScreenState> homeScreenKey = GlobalKey<HomeScreenState>();

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
  final ValueNotifier<int> selectedTabIndex = ValueNotifier<int>(0);
  final GlobalKey ytScreenKey = GlobalKey();
  final GlobalKey foldersScreenKey = GlobalKey();
  
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
    SharingHandler.getInitialSharingMedia().then((List<SharedFile> sharedFiles) {
      if (sharedFiles.isNotEmpty) {
        _handleSharedLinks(sharedFiles);
      }
    });
  }

  /// Maneja los enlaces compartidos de YouTube
  Future<void> _handleSharedLinks(List<SharedFile> sharedFiles) async {
    try {
      final youtubeResults = await SharingHandler.processSharedLinks(sharedFiles);
      
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
          LocaleProvider.tr('youtube_processing_error').replaceAll('@error', e.toString()),
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
              LocaleProvider.tr('youtube_modal_error').replaceAll('@error', e.toString()),
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
    return PopScope(
      canPop: false, // Siempre bloquear pop inicialmente
      onPopInvokedWithResult: (didPop, result) {
        final tab = selectedTabIndex.value;
        
        // Verificar navegación interna primero
        if (tab == 1) {
          // YT
          final state = ytScreenKey.currentState as dynamic;
          if (state?.canPopInternally() == true) {
            state.handleInternalPop();
            return;
          }
        } else if (tab == 3) {
          // Folders
          final state = foldersScreenKey.currentState as dynamic;
          if (state?.canPopInternally() == true) {
            state.handleInternalPop();
            return;
          }
        } else if (tab == 0) {
          // Home screen - verificar si tiene navegación interna
          final state = homeScreenKey.currentState as dynamic;
          if (state?.canPopInternally() == true) {
            state.handleInternalPop();
            return;
          }
        }
        
        // Bloquear completamente el cierre de la aplicación
        // Solo permitir navegación interna, nunca salir de la app
      },
      child: Material3BottomNav(
        pageBuilders: [
          (context, onTabChange) => HomeScreen(
            key: homeScreenKey,
            onTabChange: onTabChange,
            setThemeMode: widget.setThemeMode,
            setColorScheme: widget.setColorScheme,
          ),
          (context, onTabChange) => YtSearchTestScreen(key: ytScreenKey),
          (context, onTabChange) => FavoritesScreen(),
          (context, onTabChange) => FoldersScreen(key: foldersScreenKey),
          (context, onTabChange) => DownloadScreen(),
        ],
        selectedTabIndex: selectedTabIndex,
      ),
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  Hive.registerAdapter(PlaylistModelAdapter());
  await SyncedLyricsService.initialize();

  // Inicialización del servicio de notificaciones
  await NotificationService.initialize();

  await LocaleProvider.loadLocale();
  final permisosOk = await pedirPermisosMedia();
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

  if (!permisosOk) {
    runApp(
      MaterialApp(
        home: PermisosScreen(),
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: Colors.deepPurple,
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

  // Realizar indexación solo si es la primera vez que se abre la app
  performIndexingIfNeeded();

  // Precargar el SVG en memoria antes de mostrar la app
  try {
    // Cargar el SVG como string para precargarlo en memoria
    await rootBundle.loadString('assets/icon/icon_foreground.svg');
  } catch (e) {
    // Si falla la precarga, continuar de todas formas
  }

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
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (_) => MainApp(currentLanguage: languageNotifier.value),
          ),
          (route) => false,
        );
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
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
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
  AppThemeMode _themeMode = AppThemeMode.system;
  bool _isLoading = true;
  
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

    // Reconfigurar la barra de navegación cuando la app regrese
    if (state == AppLifecycleState.resumed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Usar los colores dinámicos guardados
        _updateSystemNavigationBar(_currentLightDynamic, _currentDarkDynamic);
      });
    }
  }

  // Método para actualizar la barra de navegación del sistema
  void _updateSystemNavigationBar([ColorScheme? lightDynamic, ColorScheme? darkDynamic]) {
    if (!mounted) return;

    try {
      final isDark =
          _themeMode == AppThemeMode.dark ||
          (_themeMode == AppThemeMode.system &&
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
          surfaceColor = isDark ? const Color(0xFF121212) : const Color(0xFFF5F5F5);
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
    final savedThemeMode = await ThemePreferences.getThemeMode();
    final savedColorScheme = await ThemePreferences.getColorScheme();
    if (mounted) {
      setState(() {
        _themeMode = savedThemeMode;
        _isLoading = false;
      });
      // Inicializar el notifier con el color guardado
      colorSchemeNotifier.value = savedColorScheme;
      
      // Inicializar la configuración de animación hero
      final prefs = await SharedPreferences.getInstance();
      final useHero = prefs.getBool('use_hero_animation') ?? true;
      heroAnimationNotifier.value = useHero;
      
      // Inicializar la configuración del botón next en overlay
      final nextButtonEnabled = prefs.getBool('overlay_next_button_enabled') ?? false;
      overlayNextButtonEnabled.value = nextButtonEnabled;
      // Configurar la barra de navegación del sistema después de cargar las preferencias
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _updateSystemNavigationBar();
      });
    }
  }

  void _setThemeMode(AppThemeMode themeMode) async {
    setState(() {
      _themeMode = themeMode;
    });
    // Guardar la preferencia
    await ThemePreferences.setThemeMode(themeMode);
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
    // Actualizar la barra de navegación del sistema con los colores dinámicos actuales
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateSystemNavigationBar(_currentLightDynamic, _currentDarkDynamic);
    });
  }

  ThemeData _buildTheme(Brightness brightness, [ColorScheme? dynamicColorScheme]) {
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
    if (colorSchemeNotifier.value == AppColorScheme.system && dynamicColorScheme != null) {
      return ThemeData(
        useMaterial3: true,
        colorScheme: dynamicColorScheme,
        brightness: brightness,
      );
    }
    
    // Usar color personalizado
    return ThemeData(
      useMaterial3: true,
      colorSchemeSeed: ThemePreferences.getColorFromScheme(
        colorSchemeNotifier.value,
      ),
      brightness: brightness,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Mostrar pantalla de carga mientras se cargan las preferencias
    if (_isLoading) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _buildTheme(Brightness.dark),
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

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

            return MaterialApp(
              title: 'Mi App de Música',
              debugShowCheckedModeBanner: false,
              themeMode: _themeMode == AppThemeMode.system
                  ? ThemeMode.system
                  : _themeMode == AppThemeMode.dark
                  ? ThemeMode.dark
                  : ThemeMode.light,
              theme: _buildTheme(Brightness.light, lightDynamic),
              darkTheme: _buildTheme(Brightness.dark, darkDynamic),
              home: MainNavRoot(
                setThemeMode: _setThemeMode,
                setColorScheme: _setColorScheme,
              ),
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
