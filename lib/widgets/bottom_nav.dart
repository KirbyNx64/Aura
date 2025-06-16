import 'package:audio_service/audio_service.dart';
import 'package:music/main.dart';
import 'package:flutter/material.dart';
import 'package:music/widgets/now_playing_overlay.dart';

class Material3BottomNav extends StatefulWidget {
  final List<WidgetBuilder> pageBuilders;
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
    // Construye la página inicial
    _pages[_selectedIndex] = widget.pageBuilders[_selectedIndex](context);
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
      // Construye la página solo si no existe
      _pages[index] ??= widget.pageBuilders[index](context);
    });
  }

  static const _navBarItems = [
    NavigationDestination(
      icon: Icon(Icons.queue_music_outlined),
      selectedIcon: Icon(Icons.queue_music),
      label: 'Listas',
    ),
    NavigationDestination(
      icon: Icon(Icons.favorite_border),
      selectedIcon: Icon(Icons.favorite),
      label: 'Me gusta',
    ),
    NavigationDestination(
      icon: Icon(Icons.folder_outlined),
      selectedIcon: Icon(Icons.folder),
      label: 'Carpetas',
    ),
    NavigationDestination(
      icon: Icon(Icons.download_outlined),
      selectedIcon: Icon(Icons.download),
      label: 'Descargar',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: StreamBuilder<MediaItem?>(
        stream: audioHandler.mediaItem,
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
                    height: 100, // Ajusta al alto real del overlay
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
      ),
      bottomNavigationBar: NavigationBar(
        animationDuration: const Duration(milliseconds: 400),
        selectedIndex: _selectedIndex,
        onDestinationSelected: _onItemTapped,
        destinations: _navBarItems,
      ),
    );
  }
}
