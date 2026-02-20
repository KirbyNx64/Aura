import 'package:audio_service/audio_service.dart';
import 'package:music/main.dart';
import 'package:flutter/material.dart';
import 'package:music/widgets/now_playing_overlay.dart';
import 'package:music/screens/play/player_screen.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:material_symbols_icons/symbols.dart';
// import 'package:flutter/services.dart';
import 'dart:async';
import 'package:music/widgets/sliding_up_panel/sliding_up_panel_overlay.dart'
    as overlay_panel;

typedef PageBuilderWithTabChange =
    Widget Function(BuildContext context, void Function(int) onTabChange);

// Widget para animar los iconos con efecto de rebote
class AnimatedNavIcon extends StatefulWidget {
  final Widget icon;
  final bool isSelected;

  const AnimatedNavIcon({
    super.key,
    required this.icon,
    required this.isSelected,
  });

  @override
  State<AnimatedNavIcon> createState() => _AnimatedNavIconState();
}

class _AnimatedNavIconState extends State<AnimatedNavIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );

    _scaleAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.0,
          end: 1.15,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 50,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.15,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeInOut)),
        weight: 50,
      ),
    ]).animate(_controller);
  }

  @override
  void didUpdateWidget(AnimatedNavIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isSelected && !oldWidget.isSelected) {
      _controller.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(scale: _scaleAnimation, child: widget.icon);
  }
}

class Material3BottomNav extends StatefulWidget {
  final List<PageBuilderWithTabChange> pageBuilders;
  final int initialIndex;
  final ValueNotifier<int> selectedTabIndex;

  const Material3BottomNav({
    super.key,
    required this.pageBuilders,
    required this.selectedTabIndex,
    this.initialIndex = 0,
  });

  @override
  State<Material3BottomNav> createState() => _Material3BottomNavState();
}

class _Material3BottomNavState extends State<Material3BottomNav> {
  late int _selectedIndex;
  late final List<Widget?> _pages;
  final overlay_panel.PanelController _overlayPanelController =
      overlay_panel.PanelController();
  bool _playlistOpen = false;
  final ValueNotifier<double> _panelPositionNotifier = ValueNotifier(0.0);
  final ValueNotifier<bool> _hideBackgroundNotifier = ValueNotifier(false);
  final ValueNotifier<bool> _hidePlayerPanelNotifier = ValueNotifier(true);
  Timer? _hidePlayerTimer;
  Timer? _hideBackgroundTimer;
  Widget? _playerScreenWidget;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialIndex;
    _pages = List<Widget?>.filled(widget.pageBuilders.length, null);
    _pages[_selectedIndex] = widget.pageBuilders[_selectedIndex](
      context,
      _onTabChange,
    );
    widget.selectedTabIndex.value = _selectedIndex;

    // Escuchar solicitudes para abrir el panel del reproductor
    openPlayerPanelNotifier.addListener(_onOpenPlayerPanelRequested);
  }

  void _onOpenPlayerPanelRequested() {
    if (openPlayerPanelNotifier.value && _overlayPanelController.isAttached) {
      _overlayPanelController.open();
      openPlayerPanelNotifier.value = false; // Reset
    }
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
      _pages[index] ??= widget.pageBuilders[index](context, _onTabChange);
      widget.selectedTabIndex.value = index;
    });
    bottomNavVisibleNotifier.value = true;
  }

  // Nuevo: función para cambiar de pestaña desde hijos
  void _onTabChange(int index) {
    _onItemTapped(index);
  }

  // Función para manejar el botón atrás de forma centralizada
  bool _handleBackNavigation() {
    final tab = widget.selectedTabIndex.value;
    bool handledInternally = false;

    if (tab == 1) {
      // YT
      final state = ytScreenKey.currentState as dynamic;
      if (state?.canPopInternally() == true) {
        state.handleInternalPop();
        handledInternally = true;
      }
    } else if (tab == 3) {
      // Folders
      final state = foldersScreenKey.currentState as dynamic;
      if (state?.canPopInternally() == true) {
        state.handleInternalPop();
        handledInternally = true;
      }
    } else if (tab == 0) {
      // Home screen
      final state = homeScreenKey.currentState as dynamic;
      if (state?.canPopInternally() == true) {
        state.handleInternalPop();
        handledInternally = true;
      }
    }

    if (handledInternally) return true;

    // Si no se manejó internamente y no estamos en la pestaña Home, ir a Home
    if (tab != 0) {
      _onItemTapped(0);
      return true;
    }

    return false;
  }

  @override
  void dispose() {
    openPlayerPanelNotifier.removeListener(_onOpenPlayerPanelRequested);
    _hidePlayerTimer?.cancel();
    _hideBackgroundTimer?.cancel();
    super.dispose();
  }

  List<NavigationDestination> _getNavBarItems(
    BuildContext context,
    AppColorScheme colorScheme,
  ) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final iconColor = isDark
        ? null
        : theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.75);

    return [
      NavigationDestination(
        icon: AnimatedNavIcon(
          icon: Icon(Symbols.home, weight: 600),
          isSelected: _selectedIndex == 0,
        ),
        selectedIcon: AnimatedNavIcon(
          icon: Icon(Symbols.home, fill: 1, weight: 600, color: iconColor),
          isSelected: _selectedIndex == 0,
        ),
        label: LocaleProvider.tr('home'),
      ),
      NavigationDestination(
        icon: ValueListenableBuilder<bool>(
          valueListenable: hasNewDownloadsNotifier,
          builder: (context, hasNew, child) {
            return Badge(
              isLabelVisible: hasNew,
              backgroundColor:
                  (colorScheme == AppColorScheme.amoled &&
                      _selectedIndex == 1 &&
                      isDark)
                  ? Colors.black
                  : theme.colorScheme.primary,
              smallSize: 10,
              child: child!,
            );
          },
          child: AnimatedNavIcon(
            icon: Icon(Symbols.search, weight: 600),
            isSelected: _selectedIndex == 1,
          ),
        ),
        selectedIcon: ValueListenableBuilder<bool>(
          valueListenable: hasNewDownloadsNotifier,
          builder: (context, hasNew, child) {
            return Badge(
              isLabelVisible: hasNew,
              backgroundColor:
                  (colorScheme == AppColorScheme.amoled &&
                      _selectedIndex == 1 &&
                      isDark)
                  ? Colors.black
                  : theme.colorScheme.primary,
              smallSize: 10,
              child: child!,
            );
          },
          child: AnimatedNavIcon(
            icon: Icon(Symbols.video_search, weight: 600, color: iconColor),
            isSelected: _selectedIndex == 1,
          ),
        ),
        label: LocaleProvider.tr('nav_search'),
      ),
      NavigationDestination(
        icon: AnimatedNavIcon(
          icon: Icon(Icons.favorite_outline_rounded, weight: 600),
          isSelected: _selectedIndex == 2,
        ),
        selectedIcon: AnimatedNavIcon(
          icon: Icon(
            Icons.favorite_rounded,
            weight: 600,
            fill: 1,
            color: iconColor,
          ),
          isSelected: _selectedIndex == 2,
        ),
        label: LocaleProvider.tr('nav_favorites'),
      ),
      NavigationDestination(
        icon: AnimatedNavIcon(
          icon: Icon(Icons.library_music_outlined),
          isSelected: _selectedIndex == 3,
        ),
        selectedIcon: AnimatedNavIcon(
          icon: Icon(Icons.library_music, color: iconColor),
          isSelected: _selectedIndex == 3,
        ),
        label: LocaleProvider.tr('nav_library'),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      resizeToAvoidBottomInset: false,
      body: ValueListenableBuilder<bool>(
        valueListenable: audioServiceReady,
        builder: (context, ready, _) {
          if (!ready || audioHandler == null) {
            // Muestra solo la pantalla principal sin overlay
            return SafeArea(
              top: false,
              child: PopScope(
                canPop: false,
                onPopInvokedWithResult: (didPop, result) {
                  if (didPop) return;
                  _handleBackNavigation();
                },
                child: IndexedStack(
                  index: _selectedIndex,
                  children: List.generate(
                    _pages.length,
                    (i) => _pages[i] ?? const SizedBox.shrink(),
                  ),
                ),
              ),
            );
          }
          return StreamBuilder<MediaItem?>(
            stream: audioHandler?.mediaItem,
            builder: (context, snapshot) {
              // El overlay permanece visible una vez que aparece
              if (snapshot.data != null && !overlayVisibleNotifier.value) {
                overlayVisibleNotifier.value = true;
              }
              return ValueListenableBuilder<bool>(
                valueListenable: overlayVisibleNotifier,
                builder: (context, overlayActive, child) {
                  final pageContent = SafeArea(
                    top: false,
                    bottom: false,
                    child: IndexedStack(
                      index: _selectedIndex,
                      children: List.generate(
                        _pages.length,
                        (i) => _pages[i] ?? const SizedBox.shrink(),
                      ),
                    ),
                  );

                  if (!overlayActive) {
                    return PopScope(
                      canPop: false,
                      onPopInvokedWithResult: (didPop, result) {
                        if (didPop) return;
                        _handleBackNavigation();
                      },
                      child: pageContent,
                    );
                  }

                  final bottomPadding = MediaQuery.of(context).padding.bottom;
                  final screenHeight = MediaQuery.of(context).size.height;

                  // Check if we need to open the panel after it renders (e.g. first launch)
                  if (openPlayerPanelNotifier.value) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (openPlayerPanelNotifier.value &&
                          _overlayPanelController.isAttached) {
                        _overlayPanelController.open();
                        openPlayerPanelNotifier.value = false;
                      }
                    });
                  }

                  return ValueListenableBuilder<bool>(
                    valueListenable: playLoadingNotifier,
                    builder: (context, isLoading, _) {
                      return PopScope(
                        canPop: false,
                        onPopInvokedWithResult: (didPop, result) {
                          if (didPop) return;

                          // Prioridad: cerrar panel si está abierto
                          if (_overlayPanelController.isAttached &&
                              _overlayPanelController.isPanelOpen) {
                            // Si el playlist interno está abierto, dejamos que FullPlayerScreen maneje el cierre
                            if (_playlistOpen) return;

                            // if (isLoading) return; // Bloquear si carga
                            _overlayPanelController.close();
                            return;
                          }

                          // Si no hay panel abierto, manejar navegación interna de tabs
                          _handleBackNavigation();
                        },
                        child: overlay_panel.SlidingUpPanel(
                          controller: _overlayPanelController,
                          minHeight: 82 + bottomPadding,
                          maxHeight: screenHeight,
                          renderPanelSheet: false,
                          boxShadow: const [],
                          color: Colors.transparent,
                          isDraggable:
                              !_playlistOpen, // Bloquear deslizado solo si el playlist está abierto
                          panelSnapping: true,
                          backdropEnabled: false,
                          defaultPanelState: overlay_panel.PanelState.closed,
                          onPanelSlide: (position) {
                            // Actualizar posición para animar AppBar (sin setState para evitar lag)
                            _panelPositionNotifier.value = position;
                            // Ocultar la barra de navegación cuando el panel se abre
                            if (position > 0.1) {
                              if (bottomNavVisibleNotifier.value) {
                                bottomNavVisibleNotifier.value = false;
                              }
                            } else {
                              if (!bottomNavVisibleNotifier.value) {
                                bottomNavVisibleNotifier.value = true;
                              }
                            }

                            // Optimización: Ocultar el contenido de fondo (Home, Search, etc.)
                            // cuando el panel está casi totalmente abierto para evitar pintado innecesario.
                            // Usamos 0.98 como umbral de seguridad.
                            final shouldHide = position >= 0.98;
                            if (_hideBackgroundNotifier.value != shouldHide) {
                              _hideBackgroundNotifier.value = shouldHide;
                            }

                            final shouldHidePlayer = position <= 0.005;
                            if (shouldHidePlayer) {
                              if (_hidePlayerTimer == null &&
                                  !_hidePlayerPanelNotifier.value) {
                                _hidePlayerTimer = Timer(
                                  const Duration(seconds: 1),
                                  () {
                                    if (mounted) {
                                      _hidePlayerPanelNotifier.value = true;
                                    }
                                    _hidePlayerTimer = null;
                                  },
                                );
                              }
                            } else {
                              _hidePlayerTimer?.cancel();
                              _hidePlayerTimer = null;
                              if (_hidePlayerPanelNotifier.value) {
                                _hidePlayerPanelNotifier.value = false;
                              }
                            }
                          },
                          onPanelClosed: () {
                            bottomNavVisibleNotifier.value = true;
                            // Asegurar que se muestre al cerrar
                            if (_hideBackgroundNotifier.value) {
                              _hideBackgroundNotifier.value = false;
                            }

                            // Iniciar el delay de 1 seg para ocultar el reproductor
                            if (_hidePlayerTimer == null &&
                                !_hidePlayerPanelNotifier.value) {
                              _hidePlayerTimer = Timer(
                                const Duration(seconds: 1),
                                () {
                                  if (mounted) {
                                    _hidePlayerPanelNotifier.value = true;
                                  }
                                  _hidePlayerTimer = null;
                                },
                              );
                            }
                            // Asegurar que _playlistOpen se resetee al cerrar el panel
                            if (_playlistOpen) {
                              setState(() {
                                _playlistOpen = false;
                              });
                            }
                          },
                          onPanelOpened: () {
                            bottomNavVisibleNotifier.value = false;
                            // Mostrar reproductor inmediatamente al abrir
                            _hidePlayerTimer?.cancel();
                            _hidePlayerTimer = null;
                            if (_hidePlayerPanelNotifier.value) {
                              _hidePlayerPanelNotifier.value = false;
                            }

                            if (!_hideBackgroundNotifier.value) {
                              _hideBackgroundNotifier.value = true;
                            }
                          },
                          body: RepaintBoundary(
                            // Aislar el contenido de tabs (FoldersScreen, etc.) del scroll
                            // del panel del reproductor. Reduce lag cuando hay listas de canciones.
                            child: ValueListenableBuilder<bool>(
                              valueListenable: _hideBackgroundNotifier,
                              builder: (context, hide, child) {
                                return Visibility(
                                  visible: !hide,
                                  maintainState: true,
                                  maintainAnimation: false,
                                  maintainSize: false,
                                  child: child!,
                                );
                              },
                              child: pageContent,
                            ),
                          ),
                          collapsed: ValueListenableBuilder<double>(
                            valueListenable: _panelPositionNotifier,
                            builder: (context, position, child) {
                              return Opacity(
                                opacity: (1.0 - (position / 0.3)).clamp(
                                  0.0,
                                  1.0,
                                ),
                                child: child,
                              );
                            },
                            child: RepaintBoundary(
                              child: Padding(
                                padding: EdgeInsets.only(bottom: bottomPadding),
                                child: NowPlayingOverlay(
                                  showBar: true,
                                  onTap: () {
                                    if (_overlayPanelController.isAttached) {
                                      _overlayPanelController.open();
                                    }
                                  },
                                ),
                              ),
                            ),
                          ),
                          panel: Builder(
                            builder: (context) {
                              // Usar viewPadding (padding del sistema) en vez del
                              // padding modificado por el Scaffold que incluye la
                              // altura del bottom nav (ahora fija con SizedBox).
                              final data = MediaQuery.of(context);
                              
                              // Crear el widget del reproductor una vez y mantenerlo en memoria
                              _playerScreenWidget ??= FullPlayerScreen(
                                initialMediaItem: snapshot.data,
                                panelPositionNotifier: _panelPositionNotifier,
                                onClose: () {
                                  if (_overlayPanelController.isAttached) {
                                    _overlayPanelController.close();
                                  }
                                },
                                onPlaylistStateChanged: (isOpen) {
                                  if (_playlistOpen != isOpen) {
                                    setState(() {
                                      _playlistOpen = isOpen;
                                    });
                                  }
                                },
                              );
                              
                              return MediaQuery(
                                data: data.copyWith(
                                  padding: data.padding.copyWith(
                                    bottom: data.viewPadding.bottom,
                                  ),
                                ),
                                child: RepaintBoundary(
                                  child: ClipRRect(
                                    borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(20),
                                    ),
                                    child: ValueListenableBuilder<bool>(
                                      valueListenable: _hidePlayerPanelNotifier,
                                      builder: (context, hide, child) {
                                        return Visibility(
                                          visible: !hide,
                                          maintainState: true,
                                          maintainAnimation: false,
                                          maintainSize: false,
                                          child: child!,
                                        );
                                      },
                                      child: _playerScreenWidget ?? const SizedBox.shrink(),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      );
                    },
                  );
                },
              );
            },
          );
        },
      ),
      bottomNavigationBar: ValueListenableBuilder<bool>(
        valueListenable: bottomNavVisibleNotifier,
        builder: (context, isVisible, navChild) {
          final bottomPadding = MediaQuery.paddingOf(context).bottom;
          final navHeight = 74 + bottomPadding;
          return SizedBox(
            height: navHeight,
            child: AnimatedSlide(
              offset: isVisible ? Offset.zero : const Offset(0, 1),
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              child: IgnorePointer(
                ignoring: !isVisible,
                child: Stack(
                  children: [
                    // Gesto para bloquear toques en la barra de Android
                    GestureDetector(
                      onVerticalDragStart: (_) {},
                      behavior: HitTestBehavior.translucent,
                      child: SizedBox(
                        height: navHeight,
                        width: double.infinity,
                      ),
                    ),
                    navChild!,
                  ],
                ),
              ),
            ),
          );
        },
        child: ValueListenableBuilder<String>(
          valueListenable: languageNotifier,
          builder: (context, lang, child) {
            return ValueListenableBuilder<AppColorScheme>(
              valueListenable: colorSchemeNotifier,
              builder: (context, colorScheme, child) {
                final isAmoled = colorScheme == AppColorScheme.amoled;
                final isDark = Theme.of(context).brightness == Brightness.dark;

                return NavigationBar(
                  height: 74,
                  backgroundColor: Theme.of(context).colorScheme.surface,
                  animationDuration: const Duration(milliseconds: 400),
                  selectedIndex: _selectedIndex,
                  onDestinationSelected: _onItemTapped,
                  destinations: _getNavBarItems(context, colorScheme),
                  indicatorColor: isAmoled && isDark ? Colors.white : null,
                  labelTextStyle: WidgetStateProperty.resolveWith<TextStyle?>((
                    Set<WidgetState> states,
                  ) {
                    final isSelected = states.contains(WidgetState.selected);
                    return Theme.of(context).textTheme.labelSmall?.copyWith(
                      overflow: TextOverflow.ellipsis,
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
                      fontSize: 12,
                      color: isSelected
                          ? (isAmoled && isDark
                                ? Colors.white
                                : Theme.of(
                                    context,
                                  ).colorScheme.onPrimaryContainer)
                          : null,
                    );
                  }),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
