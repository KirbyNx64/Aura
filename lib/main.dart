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

late final AudioHandler audioHandler;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocaleProvider.loadLocale();
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
  audioHandler = await initAudioService();
  runApp(MyRootApp());
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
        audioHandler = await initAudioService();
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
