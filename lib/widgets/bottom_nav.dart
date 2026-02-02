import 'package:audio_service/audio_service.dart';
import 'package:music/main.dart';
import 'package:flutter/material.dart';
import 'package:music/widgets/now_playing_overlay.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/theme_preferences.dart';

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
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
      _pages[index] ??= widget.pageBuilders[index](context, _onTabChange);
      widget.selectedTabIndex.value = index;
    });
  }

  // Nuevo: función para cambiar de pestaña desde hijos
  void _onTabChange(int index) {
    _onItemTapped(index);
  }

  @override
  void dispose() {
    super.dispose();
  }

  List<NavigationDestination> _getNavBarItems(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final iconColor = isDark
        ? null
        : theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.75);

    return [
      NavigationDestination(
        icon: AnimatedNavIcon(
          icon: Icon(Icons.home_filled, weight: 600),
          isSelected: _selectedIndex == 0,
        ),
        selectedIcon: AnimatedNavIcon(
          icon: Icon(Icons.home_filled, fill: 1, weight: 600, color: iconColor),
          isSelected: _selectedIndex == 0,
        ),
        label: LocaleProvider.tr('home'),
      ),
      NavigationDestination(
        icon: AnimatedNavIcon(
          icon: Icon(Icons.search, weight: 600),
          isSelected: _selectedIndex == 1,
        ),
        selectedIcon: AnimatedNavIcon(
          icon: Icon(Icons.saved_search, weight: 600, color: iconColor),
          isSelected: _selectedIndex == 1,
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
      body: ValueListenableBuilder<bool>(
        valueListenable: audioServiceReady,
        builder: (context, ready, _) {
          if (!ready || audioHandler == null) {
            // Muestra solo la pantalla principal sin overlay
            return SafeArea(
              top: false,
              child: IndexedStack(
                index: _selectedIndex,
                children: List.generate(
                  _pages.length,
                  (i) => _pages[i] ?? const SizedBox.shrink(),
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
                  return Stack(
                    children: [
                      SafeArea(
                        top: false,
                        child: IndexedStack(
                          index: _selectedIndex,
                          children: List.generate(
                            _pages.length,
                            (i) => _pages[i] ?? const SizedBox.shrink(),
                          ),
                        ),
                      ),
                      // Overlay optimizado - solo se construye cuando es necesario
                      if (overlayActive)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: MediaQuery.of(context).padding.bottom,
                          child: Container(
                            height: 100,
                            color: Theme.of(context).colorScheme.surface,
                          ),
                        ),
                      if (overlayActive)
                        Positioned(
                          bottom: MediaQuery.of(context).padding.bottom + 10,
                          left: 0,
                          right: 0,
                          child: const Center(
                            child: NowPlayingOverlay(showBar: true),
                          ),
                        ),
                    ],
                  );
                },
              );
            },
          );
        },
      ),
      bottomNavigationBar: ValueListenableBuilder<String>(
        valueListenable: languageNotifier,
        builder: (context, lang, child) {
          return ValueListenableBuilder<AppColorScheme>(
            valueListenable: colorSchemeNotifier,
            builder: (context, colorScheme, child) {
              final isAmoled = colorScheme == AppColorScheme.amoled;
              final isDark = Theme.of(context).brightness == Brightness.dark;

              return NavigationBar(
                backgroundColor: Theme.of(context).colorScheme.surface,
                animationDuration: const Duration(milliseconds: 400),
                selectedIndex: _selectedIndex,
                onDestinationSelected: _onItemTapped,
                destinations: _getNavBarItems(context),
                // Personalizar el color del indicador seleccionado para tema amoled
                indicatorColor: isAmoled && isDark
                    ? Colors
                          .white // Color más sutil para amoled
                    : null, // Usar el color por defecto para otros temas
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
    );
  }
}
