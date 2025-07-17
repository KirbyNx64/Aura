import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'package:music/utils/permission/permission_handler.dart';
import 'package:music/utils/theme_preferences.dart';
import 'widgets/bottom_nav.dart';
import 'screens/home/home_screen.dart';
import 'screens/likes/favorites_screen.dart';
import 'screens/folders/folders_screen.dart';
import 'screens/download/download_screen.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';
import 'package:music/utils/yt_search/yt_screen.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/notifiers.dart';

// Cambiar de late final a nullable para mejor manejo de errores
AudioHandler? audioHandler;
bool _audioHandlerInitialized = false;
bool _audioHandlerInitializing = false;

/// Notifier para indicar cuando el AudioService está listo
final ValueNotifier<bool> audioServiceReady = ValueNotifier<bool>(false);

/// Verifica si el AudioService está inicializando
bool get isAudioServiceInitializing => _audioHandlerInitializing;

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
  // print('🔄 AudioService no inicializado, inicializando...');
  return await initializeAudioServiceSafely();
}

/// Inicializa el AudioService de forma segura cuando se necesita
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
    // print('🎵 Inicializando AudioService de forma segura...');
    
    // Limpieza preventiva
    try {
      await cleanupAudioHandler();
      await Future.delayed(const Duration(milliseconds: 200));
    } catch (_) {}
    
    audioHandler = await initAudioService().timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        // print('⏰ Timeout en inicialización segura');
        throw Exception('Timeout al inicializar el audio service');
      },
    );
    
    _audioHandlerInitialized = true;
    audioServiceReady.value = true; // Notificar que está listo
    // print('✅ AudioService inicializado de forma segura');
    return audioHandler;
  } catch (e) {
    // print('❌ Error al inicializar AudioService de forma segura: $e');
    _audioHandlerInitialized = false;
    audioHandler = null;
    audioServiceReady.value = false; // Resetear el estado
    return null;
  } finally {
    _audioHandlerInitializing = false;
  }
}

class LifecycleHandler extends WidgetsBindingObserver {
  LifecycleHandler() {
    // print('🔧 LifecycleHandler constructor ejecutado');
  }
  
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.detached) {
      try {
        await audioHandler?.customAction("saveSession");
      } catch (_) {}
    }
  }
}

void main() async {
  // print('🚀 main() iniciado');
  WidgetsFlutterBinding.ensureInitialized();
  // print('✅ WidgetsFlutterBinding inicializado');
  // WidgetsBinding.instance.addObserver(LifecycleHandler()); // Comentado temporalmente
  // print('✅ LifecycleHandler agregado');
  // print('🔍 Iniciando aplicación...');
  await LocaleProvider.loadLocale(); // Comentado temporalmente
  // print('🌍 Locale cargado (comentado)');
  final permisosOk = await pedirPermisosMedia();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
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

  // Ir directo a MainApp y inicializar AudioService en segundo plano
  runApp(MyRootApp());
  
  // Inicializar AudioService en segundo plano después de que la UI esté lista
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    // print('🔄 Inicializando AudioService en segundo plano...');
    try {
      await initializeAudioServiceSafely();
    } catch (e) {
      // print('⚠️ Error al inicializar AudioService en segundo plano: $e');
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
        // Usa pushAndRemoveUntil para limpiar el stack y evitar problemas de contexto
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => MainApp(currentLanguage: languageNotifier.value)),
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

class _MainAppState extends State<MainApp> {
  AppThemeMode _themeMode = AppThemeMode.system;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadThemePreferences();
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
    }
  }

  void _setThemeMode(AppThemeMode themeMode) async {
    setState(() {
      _themeMode = themeMode;
    });
    // Guardar la preferencia
    await ThemePreferences.setThemeMode(themeMode);
  }

  void _setColorScheme(AppColorScheme colorScheme) async {
    // Actualizar el notifier para que el tema se actualice inmediatamente
    colorSchemeNotifier.value = colorScheme;
    // Guardar la preferencia
    await ThemePreferences.setColorScheme(colorScheme);
  }

  ThemeData _buildTheme(Brightness brightness) {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    if (isAmoled && brightness == Brightness.dark) {
      return ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        canvasColor: Colors.black,
        cardColor: Colors.black,
        // dialogBackgroundColor: Colors.black, // deprecated
        appBarTheme: const AppBarTheme(backgroundColor: Colors.black, foregroundColor: Colors.white),
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
    return ThemeData(
      useMaterial3: true,
      colorSchemeSeed: ThemePreferences.getColorFromScheme(colorSchemeNotifier.value),
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
        home: const Scaffold(
          body: Center(
            child: CircularProgressIndicator(),
          ),
        ),
      );
    }

    // Determinar el brightness basado en el tema seleccionado
    Brightness? brightness;
    switch (_themeMode) {
      case AppThemeMode.light:
        brightness = Brightness.light;
        break;
      case AppThemeMode.dark:
        brightness = Brightness.dark;
        break;
      case AppThemeMode.system:
        brightness = null; // Usar el del sistema
        break;
    }

    return ValueListenableBuilder<AppColorScheme>(
      valueListenable: colorSchemeNotifier,
      builder: (context, colorScheme, child) {
        // Actualizar la barra de navegación cuando cambie el color
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final isDark = brightness == Brightness.dark || 
                        (brightness == null && MediaQuery.of(context).platformBrightness == Brightness.dark);
          
          // Crear un tema temporal para obtener los colores del sistema
          final tempTheme = _buildTheme(isDark ? Brightness.dark : Brightness.light);
          
          SystemChrome.setSystemUIOverlayStyle(
            SystemUiOverlayStyle(
              systemNavigationBarColor: tempTheme.colorScheme.surface,
              systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
              statusBarColor: Colors.transparent,
              statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
            ),
          );
        });
        
        return MaterialApp(
          title: 'Mi App de Música',
          debugShowCheckedModeBanner: false,
          themeMode: _themeMode == AppThemeMode.system ? ThemeMode.system : 
                     _themeMode == AppThemeMode.dark ? ThemeMode.dark : ThemeMode.light,
          theme: _buildTheme(Brightness.light),
          darkTheme: _buildTheme(Brightness.dark),
          home: Material3BottomNav(
            pageBuilders: [
              (context, onTabChange) => HomeScreen(onTabChange: onTabChange, setThemeMode: _setThemeMode, setColorScheme: _setColorScheme),
              (context, onTabChange) => YtSearchTestScreen(),
              (context, onTabChange) => FavoritesScreen(),
              (context, onTabChange) => FoldersScreen(),
              (context, onTabChange) => DownloadScreen(),
            ],
          ),
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
        // print('DEBUG: MyRootApp rebuilding with language: $lang');
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
