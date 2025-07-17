import 'package:audio_service/audio_service.dart';
import 'package:music/main.dart';
import 'package:flutter/material.dart';
import 'package:music/widgets/now_playing_overlay.dart';
import 'package:music/l10n/locale_provider.dart';

typedef PageBuilderWithTabChange =
    Widget Function(BuildContext context, void Function(int) onTabChange);

class Material3BottomNav extends StatefulWidget {
  final List<PageBuilderWithTabChange> pageBuilders;
  final int initialIndex;

  const Material3BottomNav({
    super.key,
    required this.pageBuilders,
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
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
      _pages[index] ??= widget.pageBuilders[index](context, _onTabChange);
    });
  }

  // Nuevo: función para cambiar de pestaña desde hijos
  void _onTabChange(int index) {
    _onItemTapped(index);
  }

  List<NavigationDestination> get _navBarItems => [
    NavigationDestination(
      icon: Icon(Icons.home_outlined),
      selectedIcon: Icon(Icons.home),
      label: LocaleProvider.tr('home'),
    ),
    NavigationDestination(
      icon: Icon(Icons.search),
      selectedIcon: Icon(Icons.search),
      label: LocaleProvider.tr('nav_search'),
    ),
    NavigationDestination(
      icon: Icon(Icons.favorite_border),
      selectedIcon: Icon(Icons.favorite),
      label: LocaleProvider.tr('nav_favorites'),
    ),
    NavigationDestination(
      icon: Icon(Icons.folder_outlined),
      selectedIcon: Icon(Icons.folder),
      label: LocaleProvider.tr('folders'),
    ),
    NavigationDestination(
      icon: Icon(Icons.download_outlined),
      selectedIcon: Icon(Icons.download),
      label: LocaleProvider.tr('nav_downloads'),
    ),
  ];

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
              final overlayActive = snapshot.data != null;
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
                      child: Center(
                        child: SizedBox(
                          width: MediaQuery.of(context).size.width,
                          child: const NowPlayingOverlay(showBar: true),
                        ),
                      ),
                    ),
                ],
              );
            },
          );
        },
      ),
      bottomNavigationBar: ValueListenableBuilder<String>(
        valueListenable: languageNotifier,
        builder: (context, lang, child) {
          return NavigationBar(
            backgroundColor: Theme.of(context).colorScheme.surface,
            animationDuration: const Duration(milliseconds: 400),
            selectedIndex: _selectedIndex,
            onDestinationSelected: _onItemTapped,
            destinations: _navBarItems,
          );
        },
      ),
    );
  }
}
