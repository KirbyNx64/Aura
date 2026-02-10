import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:music/screens/home/about_screen.dart';
import 'dart:io';
import 'package:music/l10n/locale_provider.dart';
import 'package:material_loading_indicator/loading_indicator.dart';
import 'package:flutter_svg/flutter_svg.dart';

class OnboardingScreen extends StatefulWidget {
  final VoidCallback onFinish;

  const OnboardingScreen({super.key, required this.onFinish});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with WidgetsBindingObserver {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  // Estado de permisos
  bool _mediaPermissionGranted = false;
  bool _allFilesPermissionGranted = false;
  bool _notificationPermissionGranted = false;
  bool _batteryOptimizationIgnored = false;

  // Info del dispositivo
  int _androidSdkInt = 0;
  bool _isLoadingInfo = true;

  @override
  void initState() {
    super.initState();
    _initDeviceInfo();
    _checkPermissions();
    // Observar ciclo de vida por si el usuario vuelve de ajustes
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkPermissions();
    }
  }

  Future<void> _initDeviceInfo() async {
    if (Platform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      setState(() {
        _androidSdkInt = androidInfo.version.sdkInt;
        _isLoadingInfo = false;
      });
    } else {
      setState(() => _isLoadingInfo = false);
    }
  }

  Future<void> _checkPermissions() async {
    // Media / Audio
    bool mediaGranted = false;
    if (Platform.isAndroid && _androidSdkInt >= 33) {
      mediaGranted = await Permission.audio.isGranted;
    } else {
      mediaGranted = await Permission.storage.isGranted;
    }

    // All Files (Android 11+)
    bool allFilesGranted = false;
    if (Platform.isAndroid && _androidSdkInt >= 30) {
      allFilesGranted = await Permission.manageExternalStorage.isGranted;
    } else {
      // En versiones anteriores no se pide este permiso específico aparte del storage
      allFilesGranted = true;
    }

    // Notificaciones
    bool notificationsGranted = await Permission.notification.isGranted;

    // Optimización de Batería (Ignored = true es bueno)
    bool batteryIgnored = await Permission.ignoreBatteryOptimizations.isGranted;

    if (mounted) {
      setState(() {
        _mediaPermissionGranted = mediaGranted;
        _allFilesPermissionGranted = allFilesGranted;
        _notificationPermissionGranted = notificationsGranted;
        _batteryOptimizationIgnored = batteryIgnored;
      });
    }
  }

  Future<void> _requestMediaPermission() async {
    if (Platform.isAndroid && _androidSdkInt >= 33) {
      await Permission.audio.request();
    } else {
      await Permission.storage.request();
    }
    await _checkPermissions();
  }

  Future<void> _requestAllFilesPermission() async {
    if (Platform.isAndroid && _androidSdkInt >= 30) {
      await Permission.manageExternalStorage.request();
    }
    await _checkPermissions();
  }

  Future<void> _requestNotificationPermission() async {
    await Permission.notification.request();
    await _checkPermissions();
  }

  Future<void> _requestIgnoreBatteryOptimization() async {
    if (Platform.isAndroid) {
      final status = await Permission.ignoreBatteryOptimizations.status;
      if (!status.isGranted) {
        final intent = AndroidIntent(
          action: 'android.settings.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
          data:
              'package:com.kirby.aura', // Asegúrate de que este es el package name correcto o usa package_info_plus
          flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
        );
        try {
          await intent.launch();
        } catch (e) {
          // Fallback si falla el intent específico
          await Permission.ignoreBatteryOptimizations.request();
        }
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _finishOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('first_run', false);
    widget.onFinish();
  }

  void _nextPage() {
    _pageController.nextPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingInfo) {
      return Scaffold(body: Center(child: LoadingIndicator()));
    }

    // Determinar si los permisos necesarios están concedidos para habilitar "Siguiente"
    final bool canAdvanceFromPermissions =
        _mediaPermissionGranted && _allFilesPermissionGranted;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (index) {
                  setState(() {
                    _currentPage = index;
                  });
                },
                children: [
                  // Paso 1: Bienvenida
                  _WelcomePage(onNext: _nextPage),

                  // Paso 2: Permisos de Archivos
                  _PermissionsPage(
                    androidSdkInt: _androidSdkInt,
                    mediaGranted: _mediaPermissionGranted,
                    allFilesGranted: _allFilesPermissionGranted,
                    onRequestMedia: _requestMediaPermission,
                    onRequestAllFiles: _requestAllFilesPermission,
                    canAdvance: canAdvanceFromPermissions,
                    onNext: _nextPage,
                  ),

                  // Paso 3: Notificaciones
                  _NotificationsPage(
                    notificationsGranted: _notificationPermissionGranted,
                    onRequestNotifications: _requestNotificationPermission,
                    onNext: _nextPage,
                  ),

                  // Paso 4: Optimización de Batería (Final)
                  _BatteryOptimizationPage(
                    isIgnored: _batteryOptimizationIgnored,
                    onRequestIgnore: _requestIgnoreBatteryOptimization,
                    onFinish: _finishOnboarding,
                  ),
                ],
              ),
            ),
            // Indicadores de página
            Padding(
              padding: const EdgeInsets.all(24.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  4, // Total de páginas ahora es 4
                  (index) => AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    height: 8,
                    width: _currentPage == index ? 24 : 8,
                    decoration: BoxDecoration(
                      color: _currentPage == index
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(
                              context,
                            ).colorScheme.outline.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WelcomePage extends StatelessWidget {
  final VoidCallback onNext; // Callback para el botón

  const _WelcomePage({required this.onNext}); // Constructor requiere onNext

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Stack(
      children: [
        Positioned(
          top: 16,
          right: 16,
          child: IconButton(
            constraints: const BoxConstraints(
              minWidth: 40,
              minHeight: 40,
              maxWidth: 40,
              maxHeight: 40,
            ),
            padding: EdgeInsets.zero,
            onPressed: () {
              Navigator.of(context).push(
                PageRouteBuilder(
                  pageBuilder: (context, animation, secondaryAnimation) =>
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
            icon: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Theme.of(
                  context,
                ).colorScheme.secondary.withValues(alpha: 0.06),
              ),
              child: const Icon(Icons.info_outline_rounded, size: 26),
            ),
            tooltip: LocaleProvider.tr('about'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(26.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(),
              // Icono principal
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.primary,
                  shape: BoxShape.circle,
                ),
                child: SvgPicture.asset(
                  'assets/icon/icon_foreground.svg',
                  height: 120,
                  colorFilter: ColorFilter.mode(
                    colorScheme.onPrimary,
                    BlendMode.srcIn,
                  ),
                ),
              ),
              const SizedBox(height: 36),

              // Texto Bienvenida traducible
              Text(
                'Aura Music',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSurface,
                ),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 120),

              // Selector de Idioma
              Text(
                LocaleProvider.tr('choose_language'),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface.withValues(alpha: 0.8),
                ),
              ),
              const SizedBox(height: 16),
              ValueListenableBuilder<String>(
                valueListenable: languageNotifier,
                builder: (context, currentLang, _) {
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _LanguageButton(
                        label: 'Español',
                        isSelected: currentLang == 'es',
                        onTap: () {
                          LocaleProvider.setLanguage('es');
                          _saveLanguage('es');
                        },
                      ),
                      const SizedBox(width: 16),
                      _LanguageButton(
                        label: 'English',
                        isSelected: currentLang == 'en',
                        onTap: () {
                          LocaleProvider.setLanguage('en');
                          _saveLanguage('en');
                        },
                      ),
                    ],
                  );
                },
              ),

              const Spacer(),

              // Botón Siguiente
              FilledButton(
                onPressed: onNext,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(double.infinity, 56),
                  foregroundColor: colorScheme.onPrimary,
                  backgroundColor: colorScheme.primary,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const TranslatedText('next'),
                    const SizedBox(width: 8),
                    const Icon(Icons.arrow_forward_rounded),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _saveLanguage(String lang) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_language', lang);
  }
}

class _LanguageButton extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _LanguageButton({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? colorScheme.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected
                ? colorScheme.onPrimaryContainer
                : colorScheme.onSurface,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

class _PermissionsPage extends StatelessWidget {
  final int androidSdkInt;
  final bool mediaGranted;
  final bool allFilesGranted;
  final VoidCallback onRequestMedia;
  final VoidCallback onRequestAllFiles;
  final bool canAdvance;
  final VoidCallback onNext;

  const _PermissionsPage({
    required this.androidSdkInt,
    required this.mediaGranted,
    required this.allFilesGranted,
    required this.onRequestMedia,
    required this.onRequestAllFiles,
    required this.canAdvance,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final showAllFilesOption = Platform.isAndroid && androidSdkInt >= 30;

    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(),
          Icon(Icons.lock_open_rounded, size: 80, color: colorScheme.primary),
          const SizedBox(height: 48),
          TranslatedText(
            'permissions_title',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: colorScheme.onSurface,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          TranslatedText(
            'permissions_desc',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurface.withValues(alpha: 0.7),
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),

          const SizedBox(height: 32),

          // Lista de permisos
          _PermissionItem(
            title: 'music_audio_permission',
            isGranted: mediaGranted,
            onTap: onRequestMedia,
            icon: Icons.music_note_rounded,
          ),

          if (showAllFilesOption) ...[
            const SizedBox(height: 16),
            _PermissionItem(
              title: 'all_files_permission',
              isGranted: allFilesGranted,
              onTap: onRequestAllFiles,
              icon: Icons.folder_special_rounded,
            ),
          ],

          const Spacer(),

          // Botón Siguiente
          FilledButton(
            onPressed: canAdvance ? onNext : null,
            style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 56),
              // Si no puede avanzar, el estilo disabled por defecto de Flutter se encarga del color gris
              backgroundColor: canAdvance ? colorScheme.primary : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const TranslatedText('next'),
                const SizedBox(width: 8),
                const Icon(Icons.arrow_forward_rounded),
              ],
            ),
          ),

          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _PermissionItem extends StatelessWidget {
  final String title;
  final bool isGranted;
  final VoidCallback onTap;
  final IconData icon;

  const _PermissionItem({
    required this.title,
    required this.isGranted,
    required this.onTap,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: ListTile(
        onTap: isGranted ? null : onTap,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: isGranted
                ? Colors.transparent
                : colorScheme.outline.withValues(alpha: 0.3),
          ),
        ),
        tileColor: isGranted
            ? colorScheme.primaryContainer.withValues(alpha: 0.3)
            : null,
        leading: Icon(
          icon,
          color: isGranted ? colorScheme.primary : colorScheme.onSurface,
        ),
        title: TranslatedText(
          title,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: isGranted ? colorScheme.primary : colorScheme.onSurface,
          ),
        ),
        trailing: isGranted
            ? Icon(Icons.check_circle_rounded, color: colorScheme.primary)
            : const Icon(Icons.chevron_right_rounded),
      ),
    );
  }
}

class _NotificationsPage extends StatelessWidget {
  final bool notificationsGranted;
  final VoidCallback onRequestNotifications;
  final VoidCallback onNext;

  const _NotificationsPage({
    required this.notificationsGranted,
    required this.onRequestNotifications,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(),
          Icon(
            Icons.notifications_active_rounded,
            size: 80,
            color: colorScheme.primary,
          ),
          const SizedBox(height: 48),
          TranslatedText(
            'notifications_title',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: colorScheme.onSurface,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          TranslatedText(
            'notifications_desc',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurface.withValues(alpha: 0.7),
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),

          const SizedBox(height: 32),

          if (!notificationsGranted)
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: onRequestNotifications,
                icon: const Icon(Icons.notifications_active_rounded),
                label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16.0),
                  child: TranslatedText(
                    'grant_notifications',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            )
          else
            Icon(
              Icons.check_circle_rounded,
              color: colorScheme.primary,
              size: 64,
            ),

          const Spacer(),

          // Botón Siguiente
          FilledButton(
            onPressed: onNext,
            style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 56),
              // Habilitado siempre, ya que las notificaciones son opcionales
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const TranslatedText('next'),
                const SizedBox(width: 8),
                const Icon(Icons.arrow_forward_rounded),
              ],
            ),
          ),

          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _BatteryOptimizationPage extends StatelessWidget {
  final bool isIgnored;
  final VoidCallback onRequestIgnore;
  final VoidCallback onFinish;

  const _BatteryOptimizationPage({
    required this.isIgnored,
    required this.onRequestIgnore,
    required this.onFinish,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(),
          Icon(
            Icons.battery_saver_rounded,
            size: 80,
            color: colorScheme.primary,
          ),
          const SizedBox(height: 48),
          TranslatedText(
            'battery_optimization_onboarding_title',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: colorScheme.onSurface,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          TranslatedText(
            'battery_optimization_onboarding_desc',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurface.withValues(alpha: 0.7),
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),

          const SizedBox(height: 32),

          if (!isIgnored)
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: onRequestIgnore,
                icon: const Icon(Icons.battery_alert_rounded),
                label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16.0),
                  child: TranslatedText(
                    'ignore_optimization',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            )
          else
            Icon(
              Icons.check_circle_rounded,
              color: colorScheme.primary,
              size: 64,
            ),

          const Spacer(),

          // Botón Finalizar
          FilledButton.icon(
            onPressed: onFinish,
            icon: const Icon(Icons.check_rounded),
            label: const TranslatedText('finish'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 56),
            ),
          ),

          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
