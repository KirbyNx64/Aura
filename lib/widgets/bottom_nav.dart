import 'package:audio_service/audio_service.dart';
import 'package:music/main.dart';
import 'package:flutter/material.dart';
import 'package:music/widgets/now_playing_overlay.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/notifiers.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:music/utils/theme_preferences.dart';

typedef PageBuilderWithTabChange =
    Widget Function(BuildContext context, void Function(int) onTabChange);

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
    final iconColor = isDark ? null : theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.75);
    
    return [
      NavigationDestination(
        icon: Icon(Symbols.home, weight: 600),
        selectedIcon: Icon(Symbols.home, fill: 1, weight: 600, color: iconColor),
        label: LocaleProvider.tr('home'),
      ),
      NavigationDestination(
        icon: Icon(Symbols.search, weight: 600),
        selectedIcon: Icon(Symbols.video_search, weight: 600, color: iconColor),
        label: LocaleProvider.tr('nav_search'),
      ),
      NavigationDestination(
        icon: Icon(Symbols.favorite_rounded, weight: 600),
        selectedIcon: Icon(Symbols.favorite_rounded, weight: 600, fill: 1, color: iconColor),
        label: LocaleProvider.tr('nav_favorites'),
      ),
      NavigationDestination(
        icon: Icon(Icons.folder_outlined),
        selectedIcon: Icon(Icons.folder, color: iconColor),
        label: LocaleProvider.tr('folders'),
      ),
      NavigationDestination(
        icon: Icon(Icons.download_outlined),
        selectedIcon: Icon(Icons.download, color: iconColor),
        label: LocaleProvider.tr('nav_downloads'),
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
                    ? Colors.white// Color más sutil para amoled
                    : null, // Usar el color por defecto para otros temas
              );
            },
          );
        },
      ),
    );
  }
}
