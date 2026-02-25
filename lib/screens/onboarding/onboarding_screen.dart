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
import 'package:flutter_m3shapes/flutter_m3shapes.dart';
import 'package:package_info_plus/package_info_plus.dart';

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
  bool _isRequestingPermission = false;

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
    if (_isRequestingPermission) return;
    _isRequestingPermission = true;
    try {
      if (Platform.isAndroid && _androidSdkInt >= 33) {
        await Permission.audio.request();
      } else {
        await Permission.storage.request();
      }
      await _checkPermissions();
    } finally {
      _isRequestingPermission = false;
    }
  }

  Future<void> _requestAllFilesPermission() async {
    if (_isRequestingPermission) return;
    _isRequestingPermission = true;
    try {
      if (Platform.isAndroid && _androidSdkInt >= 30) {
        await Permission.manageExternalStorage.request();
      }
      await _checkPermissions();
    } finally {
      _isRequestingPermission = false;
    }
  }

  Future<void> _requestNotificationPermission() async {
    if (_isRequestingPermission) return;
    _isRequestingPermission = true;
    try {
      await Permission.notification.request();
      await _checkPermissions();
    } finally {
      _isRequestingPermission = false;
    }
  }

  Future<void> _requestIgnoreBatteryOptimization() async {
    if (_isRequestingPermission) return;
    _isRequestingPermission = true;
    try {
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
    } finally {
      _isRequestingPermission = false;
      _checkPermissions();
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

  void _previousPage() {
    _pageController.previousPage(
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

    return PopScope(
      canPop: _currentPage == 0,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_currentPage > 0) {
          _previousPage();
        }
      },
      child: Scaffold(
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
                      onBack: _previousPage,
                      currentStep: 2,
                      totalSteps: 5,
                    ),

                    // Paso 3: Notificaciones
                    _NotificationsPage(
                      notificationsGranted: _notificationPermissionGranted,
                      onRequestNotifications: _requestNotificationPermission,
                      onNext: _nextPage,
                      onBack: _previousPage,
                      currentStep: 3,
                      totalSteps: 5,
                    ),

                    // Paso 4: Optimización de Batería
                    _BatteryOptimizationPage(
                      isIgnored: _batteryOptimizationIgnored,
                      onRequestIgnore: _requestIgnoreBatteryOptimization,
                      onNext: _nextPage,
                      onBack: _previousPage,
                      currentStep: 4,
                      totalSteps: 5,
                    ),

                    // Paso 5: Todo listo
                    _AllSetPage(
                      onFinish: _finishOnboarding,
                      onBack: _previousPage,
                      currentStep: 5,
                      totalSteps: 5,
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
                    5, // Total de páginas ahora es 5
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
    final textTheme = Theme.of(context).textTheme;
    final isAmoled =
        Theme.of(context).brightness == Brightness.dark &&
        Theme.of(context).colorScheme.surface == Colors.black;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Stack(
      children: [
        Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final isShort = MediaQuery.of(context).size.height < 700;
                  return SingleChildScrollView(
                    physics: isShort
                        ? const ClampingScrollPhysics()
                        : const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 28.0),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: IntrinsicHeight(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              height: MediaQuery.of(context).size.height < 700
                                  ? 24
                                  : 48,
                            ),
                            // Titulo Estilizado
                            TranslatedText(
                              'welcome',
                              style: textTheme.displaySmall?.copyWith(
                                fontWeight: FontWeight.w900,
                                color: colorScheme.onSurface,
                                height: 1.1,
                                letterSpacing: -1,
                              ),
                            ),
                            TranslatedText(
                              'to',
                              style: textTheme.displaySmall?.copyWith(
                                fontWeight: FontWeight.w900,
                                color: colorScheme.onSurface,
                                height: 1.1,
                                letterSpacing: -1,
                              ),
                            ),
                            Text(
                              'Aura',
                              style: textTheme.displayMedium?.copyWith(
                                fontWeight: FontWeight.w900,
                                color: colorScheme.primary,
                                height: 1.1,
                                letterSpacing: -1,
                              ),
                            ),
                            const SizedBox(height: 16),
                            // Badge de Beta
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: isAmoled
                                    ? Colors.white.withAlpha(20)
                                    : isDark
                                    ? colorScheme.secondary.withValues(
                                        alpha: 0.06,
                                      )
                                    : colorScheme.secondary.withValues(
                                        alpha: 0.07,
                                      ),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: FutureBuilder<PackageInfo>(
                                future: PackageInfo.fromPlatform(),
                                builder: (context, snapshot) {
                                  final version =
                                      snapshot.data?.version ?? '1.8.1';
                                  return Text(
                                    'v$version',
                                    style: textTheme.labelLarge?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      color: colorScheme.onSurface.withValues(
                                        alpha: 0.6,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),

                            const Spacer(flex: 1),

                            // Icono Central Adaptativo
                            Center(
                              child: Builder(
                                builder: (context) {
                                  final screenHeight = MediaQuery.of(
                                    context,
                                  ).size.height;
                                  final isShortScreen = screenHeight < 700;
                                  final size = isShortScreen ? 160.0 : 220.0;
                                  final iconSize = isShortScreen
                                      ? 110.0
                                      : 160.0;

                                  return M3Container.c7SidedCookie(
                                    color: isAmoled
                                        ? Colors.white.withAlpha(20)
                                        : isDark
                                        ? colorScheme.secondary.withValues(
                                            alpha: 0.06,
                                          )
                                        : colorScheme.secondary.withValues(
                                            alpha: 0.07,
                                          ),
                                    width: size,
                                    height: size,
                                    child: Center(
                                      child: SvgPicture.asset(
                                        'assets/icon/icon_foreground.svg',
                                        height: iconSize,
                                        colorFilter: ColorFilter.mode(
                                          colorScheme.primary,
                                          BlendMode.srcIn,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),

                            const Spacer(flex: 1),

                            // Subtexto
                            Center(
                              child: TranslatedText(
                                "onboarding_setup_desc",
                                textAlign: TextAlign.center,
                                style: textTheme.bodyLarge?.copyWith(
                                  color: colorScheme.onSurface.withValues(
                                    alpha: 0.6,
                                  ),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),

                            const Spacer(flex: 1),
                            // Selector de Idioma (Sutil)
                            Center(
                              child: ValueListenableBuilder<String>(
                                valueListenable: languageNotifier,
                                builder: (context, currentLang, _) {
                                  return Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _LanguageButton(
                                        label: 'ES',
                                        isSelected: currentLang == 'es',
                                        onTap: () {
                                          LocaleProvider.setLanguage('es');
                                          _saveLanguage('es');
                                        },
                                      ),
                                      const SizedBox(width: 8),
                                      _LanguageButton(
                                        label: 'EN',
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
                            ),

                            const Spacer(flex: 1),
                            const SizedBox(height: 16),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),

            // Card del Botón "Let's Go!" (Footer)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isAmoled
                    ? Colors.white.withAlpha(20)
                    : isDark
                    ? colorScheme.secondary.withValues(alpha: 0.06)
                    : colorScheme.secondary.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(32),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    const SizedBox(width: 4),
                    TranslatedText(
                      "lets_go",
                      style: textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w900,
                        color: colorScheme.onSurface,
                        letterSpacing: -0.5,
                        fontSize: MediaQuery.of(context).size.height < 700
                            ? 20
                            : null,
                      ),
                    ),
                    const Spacer(),
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: onNext,
                        borderRadius: BorderRadius.circular(22),
                        child: Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color: colorScheme.primary,
                            borderRadius: BorderRadius.circular(22),
                          ),
                          child: Icon(
                            Icons.arrow_forward_rounded,
                            color: colorScheme.onPrimary,
                            size: 32,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
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
                color: colorScheme.secondary.withValues(alpha: 0.06),
              ),
              child: const Icon(Icons.info_outline_rounded, size: 26),
            ),
            tooltip: LocaleProvider.tr('about'),
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
    final isAmoled =
        Theme.of(context).brightness == Brightness.dark &&
        Theme.of(context).colorScheme.surface == Colors.black;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected
              ? colorScheme.primaryContainer
              : isAmoled
              ? Colors.white.withAlpha(20)
              : isDark
              ? Theme.of(context).colorScheme.secondary.withValues(alpha: 0.06)
              : Theme.of(context).colorScheme.secondary.withValues(alpha: 0.07),
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
  final VoidCallback onBack;
  final int currentStep;
  final int totalSteps;

  const _PermissionsPage({
    required this.androidSdkInt,
    required this.mediaGranted,
    required this.allFilesGranted,
    required this.onRequestMedia,
    required this.onRequestAllFiles,
    required this.canAdvance,
    required this.onNext,
    required this.onBack,
    required this.currentStep,
    required this.totalSteps,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isAmoled =
        Theme.of(context).brightness == Brightness.dark &&
        Theme.of(context).colorScheme.surface == Colors.black;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final showAllFilesOption = Platform.isAndroid && androidSdkInt >= 30;

    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isShort = MediaQuery.of(context).size.height < 700;
              return SingleChildScrollView(
                physics: isShort
                    ? const ClampingScrollPhysics()
                    : const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 28.0),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: IntrinsicHeight(
                    child: Column(
                      children: [
                        SizedBox(
                          height: MediaQuery.of(context).size.height < 700
                              ? 24
                              : 48,
                        ),
                        // Título y Descripción
                        TranslatedText(
                          'media_permission',
                          style: textTheme.displaySmall?.copyWith(
                            fontWeight: FontWeight.w900,
                            color: colorScheme.onSurface,
                            letterSpacing: -1,
                            fontSize: MediaQuery.of(context).size.height < 700
                                ? 28
                                : null,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        TranslatedText(
                          'permissions_desc',
                          style: textTheme.bodyLarge?.copyWith(
                            color: colorScheme.onSurface.withValues(alpha: 0.6),
                            height: 1.4,
                          ),
                          textAlign: TextAlign.center,
                        ),

                        const Spacer(),

                        // Composición Visual Adaptativa
                        Builder(
                          builder: (context) {
                            final isShort =
                                MediaQuery.of(context).size.height < 700;
                            return SizedBox(
                              height: isShort ? 200 : 320,
                              width: double.infinity,
                              child: Center(
                                child: M3Container.oval(
                                  color: isAmoled
                                      ? Colors.white.withAlpha(20)
                                      : isDark
                                      ? colorScheme.secondary.withValues(
                                          alpha: 0.06,
                                        )
                                      : colorScheme.secondary.withValues(
                                          alpha: 0.07,
                                        ),
                                  width: isShort ? 160 : 220,
                                  height: isShort ? 160 : 220,
                                  child: Center(
                                    child: Transform.rotate(
                                      angle: 0.5,
                                      child: Icon(
                                        Icons.lock_open_rounded,
                                        size: isShort ? 70 : 100,
                                        color: colorScheme.primary,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),

                        const Spacer(),

                        // Botón de Acción Principal (Dinámico)
                        if (!mediaGranted)
                          _ActionCardButton(
                            labelKey: 'grant_media_permission',
                            onTap: onRequestMedia,
                          )
                        else if (showAllFilesOption && !allFilesGranted)
                          _ActionCardButton(
                            labelKey: 'grant_all_files_permission',
                            onTap: onRequestAllFiles,
                          )
                        else
                          _ActionCardButton(
                            labelKey: 'permission_granted',
                            onTap: onNext,
                            isCompleted: true,
                          ),

                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),

        // Footer con Progreso
        _OnboardingFooter(
          currentStep: currentStep,
          totalSteps: totalSteps,
          onNext: onNext,
          onBack: onBack,
          isEnabled: canAdvance,
        ),
      ],
    );
  }
}

class _ActionCardButton extends StatelessWidget {
  final String labelKey;
  final VoidCallback onTap;
  final bool isCompleted;

  const _ActionCardButton({
    required this.labelKey,
    required this.onTap,
    this.isCompleted = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: isCompleted
            ? colorScheme.primary.withValues(alpha: 0.1)
            : colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(24),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isCompleted)
                  Icon(
                    Icons.check_circle_rounded,
                    color: colorScheme.primary,
                    size: 24,
                  ),
                if (isCompleted) const SizedBox(width: 8),
                TranslatedText(
                  labelKey,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: isCompleted
                        ? colorScheme.primary
                        : colorScheme.onPrimaryContainer,
                    letterSpacing: -0.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OnboardingFooter extends StatelessWidget {
  final int currentStep;
  final int totalSteps;
  final VoidCallback onNext;
  final VoidCallback? onBack;
  final bool isEnabled;

  const _OnboardingFooter({
    required this.currentStep,
    required this.totalSteps,
    required this.onNext,
    this.onBack,
    required this.isEnabled,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isAmoled = isDark && colorScheme.surface == Colors.black;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isAmoled
            ? Colors.white.withAlpha(20)
            : isDark
            ? colorScheme.secondary.withValues(alpha: 0.06)
            : colorScheme.secondary.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(32),
      ),
      child: Row(
        children: [
          const SizedBox(width: 20),
          ValueListenableBuilder<String>(
            valueListenable: languageNotifier,
            builder: (context, lang, child) {
              return Text(
                LocaleProvider.tr('step_of')
                    .replaceFirst('{current}', currentStep.toString())
                    .replaceFirst('{total}', totalSteps.toString()),
                style: textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              );
            },
          ),
          const Spacer(),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: isEnabled ? onNext : null,
              borderRadius: BorderRadius.circular(22),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: isEnabled
                      ? colorScheme.primary
                      : colorScheme.outline.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Icon(
                  Icons.arrow_forward_rounded,
                  color: isEnabled
                      ? colorScheme.onPrimary
                      : colorScheme.onSurface.withValues(alpha: 0.3),
                  size: 32,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NotificationsPage extends StatelessWidget {
  final bool notificationsGranted;
  final VoidCallback onRequestNotifications;
  final VoidCallback onNext;
  final VoidCallback onBack;
  final int currentStep;
  final int totalSteps;

  const _NotificationsPage({
    required this.notificationsGranted,
    required this.onRequestNotifications,
    required this.onNext,
    required this.onBack,
    required this.currentStep,
    required this.totalSteps,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isAmoled =
        Theme.of(context).brightness == Brightness.dark &&
        Theme.of(context).colorScheme.surface == Colors.black;

    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isShort = MediaQuery.of(context).size.height < 700;
              return SingleChildScrollView(
                physics: isShort
                    ? const ClampingScrollPhysics()
                    : const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 28.0),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: IntrinsicHeight(
                    child: Column(
                      children: [
                        SizedBox(
                          height: MediaQuery.of(context).size.height < 700
                              ? 24
                              : 48,
                        ),
                        TranslatedText(
                          'notifications_title',
                          style: textTheme.displaySmall?.copyWith(
                            fontWeight: FontWeight.w900,
                            color: colorScheme.onSurface,
                            letterSpacing: -1,
                            fontSize: MediaQuery.of(context).size.height < 700
                                ? 28
                                : null,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        TranslatedText(
                          'notifications_desc',
                          style: textTheme.bodyLarge?.copyWith(
                            color: colorScheme.onSurface.withValues(alpha: 0.6),
                            height: 1.4,
                          ),
                          textAlign: TextAlign.center,
                        ),

                        const Spacer(),

                        // Composición Visual Adaptativa
                        Builder(
                          builder: (context) {
                            final isShort =
                                MediaQuery.of(context).size.height < 700;
                            return SizedBox(
                              height: isShort ? 200 : 320,
                              width: double.infinity,
                              child: Center(
                                child: M3Container.triangle(
                                  color: isAmoled
                                      ? Colors.white.withAlpha(20)
                                      : isDark
                                      ? colorScheme.secondary.withValues(
                                          alpha: 0.06,
                                        )
                                      : colorScheme.secondary.withValues(
                                          alpha: 0.07,
                                        ),
                                  width: isShort ? 160 : 220,
                                  height: isShort ? 150 : 200,
                                  child: Center(
                                    child: Column(
                                      children: [
                                        SizedBox(height: isShort ? 40 : 70),
                                        Icon(
                                          Icons.notifications_active_rounded,
                                          size: isShort ? 70 : 100,
                                          color: colorScheme.primary,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),

                        const Spacer(),

                        if (!notificationsGranted)
                          _ActionCardButton(
                            labelKey: 'grant_notifications',
                            onTap: onRequestNotifications,
                          )
                        else
                          _ActionCardButton(
                            labelKey: 'notifications_active',
                            onTap: onNext,
                            isCompleted: true,
                          ),

                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        _OnboardingFooter(
          currentStep: currentStep,
          totalSteps: totalSteps,
          onNext: onNext,
          onBack: onBack,
          isEnabled: true, // Notificaciones opcionales
        ),
      ],
    );
  }
}

class _BatteryOptimizationPage extends StatelessWidget {
  final bool isIgnored;
  final VoidCallback onRequestIgnore;
  final VoidCallback onNext;
  final VoidCallback onBack;
  final int currentStep;
  final int totalSteps;

  const _BatteryOptimizationPage({
    required this.isIgnored,
    required this.onRequestIgnore,
    required this.onNext,
    required this.onBack,
    required this.currentStep,
    required this.totalSteps,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isAmoled =
        Theme.of(context).brightness == Brightness.dark &&
        Theme.of(context).colorScheme.surface == Colors.black;

    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isShort = MediaQuery.of(context).size.height < 700;
              return SingleChildScrollView(
                physics: isShort
                    ? const ClampingScrollPhysics()
                    : const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 28.0),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: IntrinsicHeight(
                    child: Column(
                      children: [
                        SizedBox(
                          height: MediaQuery.of(context).size.height < 700
                              ? 16
                              : 38,
                        ),
                        TranslatedText(
                          'battery_optimization_onboarding_title',
                          style: textTheme.displaySmall?.copyWith(
                            fontWeight: FontWeight.w900,
                            color: colorScheme.onSurface,
                            letterSpacing: -1,
                            fontSize: MediaQuery.of(context).size.height < 700
                                ? 28
                                : null,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        TranslatedText(
                          'battery_optimization_onboarding_desc',
                          style: textTheme.bodyLarge?.copyWith(
                            color: colorScheme.onSurface.withValues(alpha: 0.6),
                            height: 1.4,
                          ),
                          textAlign: TextAlign.center,
                        ),

                        const Spacer(),

                        // Composición Visual Adaptativa
                        Builder(
                          builder: (context) {
                            final isShort =
                                MediaQuery.of(context).size.height < 700;
                            return SizedBox(
                              height: isShort ? 180 : 280,
                              width: double.infinity,
                              child: Center(
                                child: M3Container.arch(
                                  color: isAmoled
                                      ? Colors.white.withAlpha(20)
                                      : isDark
                                      ? colorScheme.secondary.withValues(
                                          alpha: 0.06,
                                        )
                                      : colorScheme.secondary.withValues(
                                          alpha: 0.07,
                                        ),
                                  width: isShort ? 150 : 200,
                                  height: isShort ? 150 : 200,
                                  child: Center(
                                    child: Icon(
                                      Icons.battery_saver_rounded,
                                      size: isShort ? 70 : 100,
                                      color: colorScheme.primary,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),

                        const Spacer(),

                        if (!isIgnored)
                          _ActionCardButton(
                            labelKey: 'ignore_optimization',
                            onTap: onRequestIgnore,
                          )
                        else
                          _ActionCardButton(
                            labelKey: 'optimization_ignored',
                            onTap: onNext,
                            isCompleted: true,
                          ),

                        const Spacer(),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        _OnboardingFooter(
          currentStep: currentStep,
          totalSteps: totalSteps,
          onNext: onNext,
          onBack: onBack,
          isEnabled: true,
        ),
      ],
    );
  }
}

class _AllSetPage extends StatelessWidget {
  final VoidCallback onFinish;
  final VoidCallback onBack;
  final int currentStep;
  final int totalSteps;

  const _AllSetPage({
    required this.onFinish,
    required this.onBack,
    required this.currentStep,
    required this.totalSteps,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isAmoled = isDark && colorScheme.surface == Colors.black;

    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isShort = MediaQuery.of(context).size.height < 700;
              return SingleChildScrollView(
                physics: isShort
                    ? const ClampingScrollPhysics()
                    : const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 28.0),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: IntrinsicHeight(
                    child: Column(
                      children: [
                        SizedBox(
                          height: MediaQuery.of(context).size.height < 700
                              ? 24
                              : 48,
                        ),
                        TranslatedText(
                          'all_set_title',
                          style: textTheme.displaySmall?.copyWith(
                            fontWeight: FontWeight.w900,
                            color: colorScheme.onSurface,
                            letterSpacing: -1,
                            fontSize: MediaQuery.of(context).size.height < 700
                                ? 28
                                : null,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        TranslatedText(
                          'all_set_desc',
                          style: textTheme.bodyLarge?.copyWith(
                            color: colorScheme.onSurface.withValues(alpha: 0.6),
                            height: 1.4,
                          ),
                          textAlign: TextAlign.center,
                        ),

                        const Spacer(),

                        // Composición Visual Adaptativa
                        Builder(
                          builder: (context) {
                            final isShort =
                                MediaQuery.of(context).size.height < 700;
                            return SizedBox(
                              height: isShort ? 200 : 320,
                              width: double.infinity,
                              child: Center(
                                child: M3Container.pentagon(
                                  color: isAmoled
                                      ? Colors.white.withAlpha(20)
                                      : isDark
                                      ? colorScheme.secondary.withValues(
                                          alpha: 0.06,
                                        )
                                      : colorScheme.secondary.withValues(
                                          alpha: 0.07,
                                        ),
                                  width: isShort ? 160 : 220,
                                  height: isShort ? 160 : 220,
                                  child: Center(
                                    child: Icon(
                                      Icons.done_all_rounded,
                                      size: isShort ? 80 : 110,
                                      color: colorScheme.primary,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),

                        const Spacer(),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        _OnboardingFooter(
          currentStep: currentStep,
          totalSteps: totalSteps,
          onNext: onFinish,
          onBack: onBack,
          isEnabled: true,
        ),
      ],
    );
  }
}
