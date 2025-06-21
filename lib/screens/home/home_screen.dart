import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:music/utils/db/recent_db.dart';
import 'package:music/utils/db/mostplayer_db.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'package:music/main.dart';
import 'package:music/utils/db/favorites_db.dart';
import 'package:music/utils/notifiers.dart';
import 'package:flutter/services.dart';
import 'package:music/utils/db/playlists_db.dart';
import 'package:audio_service/audio_service.dart';
import 'package:music/screens/home/settings_screen.dart';

class HomeScreen extends StatefulWidget {
  final void Function(int)? onTabChange;
  const HomeScreen({super.key, this.onTabChange});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  List<SongModel> _recentSongs = [];
  bool _showingRecents = false;
  bool _showingPlaylistSongs = false;
  List<SongModel> _playlistSongs = [];
  Map<String, dynamic>? _selectedPlaylist;
  double _lastBottomInset = 0.0;

  // NUEVO: canciones más escuchadas
  List<SongModel> _mostPlayed = [];
  final PageController _pageController = PageController(viewportFraction: 0.95);
  final PageController _quickPickPageController = PageController(
    viewportFraction: 0.95,
  );
  List<Map<String, dynamic>> _playlists = [];

  final TextEditingController _searchRecentsController =
      TextEditingController();
  final FocusNode _searchRecentsFocus = FocusNode();
  List<SongModel> _filteredRecents = [];

  // Controladores y estados para búsqueda en playlist
  final TextEditingController _searchPlaylistController =
      TextEditingController();
  final FocusNode _searchPlaylistFocus = FocusNode();
  List<SongModel> _filteredPlaylistSongs = [];
  final List<List<SongModel>> _quickPickPages = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadMostPlayed().then((_) {
      _initQuickPickPages();
      setState(() {});
    });
    _loadPlaylists();
  }

  void _initQuickPickPages() {
    _quickPickPages.clear();
    final songs = List<SongModel>.from(_mostPlayed);
    songs.shuffle();
    // Divide la lista en páginas de 4, sin repetir
    for (int i = 0; i < 5; i++) {
      final start = i * 4;
      final end = (start + 4).clamp(0, songs.length);
      if (start < songs.length) {
        _quickPickPages.add(songs.sublist(start, end));
      }
    }
  }

  Future<void> _loadPlaylists() async {
    final playlists = await PlaylistsDB().getAllPlaylists();
    setState(() {
      _playlists = playlists;
    });
  }

  Future<void> _loadPlaylistSongs(Map<String, dynamic> playlist) async {
    final songs = await PlaylistsDB().getSongsFromPlaylist(playlist['id']);
    setState(() {
      _playlistSongs = songs;
      _selectedPlaylist = playlist;
      _showingPlaylistSongs = true;
      _showingRecents = false;
    });
  }

  Future<void> _loadMostPlayed() async {
    final songs = await MostPlayedDB().getMostPlayed(limit: 40);
    setState(() {
      _mostPlayed = songs;
      // Elimina el shuffle y asignación aquí
    });
  }

  Future<void> _loadRecents() async {
    try {
      final recents = await RecentsDB().getRecents();
      setState(() {
        _recentSongs = recents;
        _showingRecents = true;
      });
    } catch (e) {
      setState(() {
        _recentSongs = [];
        _showingRecents = true;
      });
    }
  }

  void _onSearchRecentsChanged() {
    final query = _quitarDiacriticos(_searchRecentsController.text.trim());
    if (query.isEmpty) {
      setState(() => _filteredRecents = []);
      return;
    }
    setState(() {
      _filteredRecents = _recentSongs.where((song) {
        final title = _quitarDiacriticos(song.title);
        final artist = _quitarDiacriticos(song.artist ?? '');
        return title.contains(query) || artist.contains(query);
      }).toList();
    });
  }

  void _onSearchPlaylistChanged() {
    final query = _quitarDiacriticos(_searchPlaylistController.text.trim());
    if (query.isEmpty) {
      setState(() => _filteredPlaylistSongs = []);
      return;
    }
    setState(() {
      _filteredPlaylistSongs = _playlistSongs.where((song) {
        final title = _quitarDiacriticos(song.title);
        final artist = _quitarDiacriticos(song.artist ?? '');
        return title.contains(query) || artist.contains(query);
      }).toList();
    });
  }

  String _quitarDiacriticos(String texto) {
    const conAcentos = 'áàäâãéèëêíìïîóòöôõúùüûÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛ';
    const sinAcentos = 'aaaaaeeeeiiiiooooouuuuaaaaaeeeeiiiiooooouuuu';
    for (int i = 0; i < conAcentos.length; i++) {
      texto = texto.replaceAll(conAcentos[i], sinAcentos[i]);
    }
    return texto.toLowerCase();
  }

  Future<bool> _onWillPop() async {
    if (_showingRecents || _showingPlaylistSongs) {
      setState(() {
        _showingRecents = false;
        _showingPlaylistSongs = false;
      });
      return false;
    }
    return true;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    _searchRecentsController.dispose();
    _searchRecentsFocus.dispose();
    _searchPlaylistController.dispose();
    _searchPlaylistFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    final bottomInset = View.of(context).viewInsets.bottom;
    if (_lastBottomInset > 0.0 && bottomInset == 0.0) {
      if (_showingRecents && _searchRecentsFocus.hasFocus) {
        _searchRecentsFocus.unfocus();
      }
      if (_showingPlaylistSongs && _searchPlaylistFocus.hasFocus) {
        _searchPlaylistFocus.unfocus();
      }
    }
    _lastBottomInset = bottomInset;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _lastBottomInset = View.of(context).viewInsets.bottom;
  }

  Future<void> _playSong(SongModel song, List<SongModel> queue) async {
    const int maxQueueSongs = 200;
    final index = queue.indexWhere((s) => s.data == song.data);

    if (index != -1) {
      int before = (maxQueueSongs / 2).floor();
      int after = maxQueueSongs - before;
      int start = (index - before).clamp(0, queue.length);
      int end = (index + after).clamp(0, queue.length);
      List<SongModel> limitedQueue = queue.sublist(start, end);
      int newIndex = index - start;

      await (audioHandler as MyAudioHandler).setQueueFromSongs(
        limitedQueue,
        initialIndex: newIndex,
      );
      await audioHandler.play();
    }
  }

  Future<void> _addToFavorites(SongModel song) async {
    await FavoritesDB().addFavorite(song);
    favoritesShouldReload.value = !favoritesShouldReload.value;
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Añadido a me gusta')));
    }
  }

  Future<void> _handleLongPress(BuildContext context, SongModel song) async {
    HapticFeedback.mediumImpact(); // <--- Vibración al mantener presionado
    final isFavorite = await FavoritesDB().isFavorite(song.data);

    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                isFavorite ? Icons.delete_outline : Icons.favorite_border,
              ),
              title: Text(
                isFavorite ? 'Eliminar de me gusta' : 'Añadir a me gusta',
              ),
              onTap: () async {
                Navigator.of(context).pop();

                if (isFavorite) {
                  await FavoritesDB().removeFavorite(song.data);
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Eliminado de me gusta')),
                  );
                } else {
                  await _addToFavorites(song);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Divide las canciones en páginas de 6
    List<List<SongModel>> pages = List.generate(3, (i) {
      final start = i * 6;
      final end = (start + 6).clamp(0, _mostPlayed.length);
      return _mostPlayed.length > start
          ? _mostPlayed.sublist(start, end)
          : <SongModel>[];
    });

    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        appBar: AppBar(
          leading: (_showingRecents || _showingPlaylistSongs)
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () {
                    setState(() {
                      _showingRecents = false;
                      _showingPlaylistSongs = false;
                    });
                  },
                )
              : null,
          title: Row(
            children: [
              if (!_showingRecents && !_showingPlaylistSongs)
                const Icon(Icons.home_outlined, size: 28),
              if (!_showingRecents && !_showingPlaylistSongs)
                const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _showingRecents
                      ? 'Recientes'
                      : _showingPlaylistSongs
                      ? ((_selectedPlaylist?['name'] ?? 'Playlist').length > 15
                            ? (_selectedPlaylist?['name'] ?? 'Playlist')
                                      .substring(0, 15) +
                                  '...'
                            : (_selectedPlaylist?['name'] ?? 'Playlist'))
                      : 'Inicio',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          actions: (!_showingRecents && !_showingPlaylistSongs)
              ? [
                  IconButton(
                    icon: const Icon(Icons.history, size: 28),
                    tooltip: 'Canciones recientes',
                    onPressed: _loadRecents,
                  ),
                  IconButton(
                    icon: const Icon(Icons.settings_outlined, size: 28),
                    tooltip: 'Ajustes',
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => const SettingsScreen(),
                        ),
                      );
                    },
                  ),
                ]
              : null,
          bottom: (_showingRecents || _showingPlaylistSongs)
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(56),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: TextField(
                      controller: _showingRecents
                          ? _searchRecentsController
                          : _searchPlaylistController,
                      focusNode: _showingRecents
                          ? _searchRecentsFocus
                          : _searchPlaylistFocus,
                      onChanged: (_) => _showingRecents
                          ? _onSearchRecentsChanged()
                          : _onSearchPlaylistChanged(),
                      decoration: InputDecoration(
                        hintText: 'Buscar por título o artista',
                        prefixIcon: const Icon(Icons.search),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                        contentPadding: const EdgeInsets.symmetric(vertical: 0),
                      ),
                    ),
                  ),
                )
              : null,
        ),
        body: StreamBuilder<MediaItem?>(
          stream: audioHandler.mediaItem,
          builder: (context, currentSnapshot) {
            final current = currentSnapshot.data;
            final space = current != null ? 100.0 : 0.0;

            return Padding(
              padding: EdgeInsets.only(bottom: space),
              child: _showingRecents
                  ? Builder(
                      builder: (context) {
                        final List<SongModel> songsToShow =
                            _searchRecentsController.text.isNotEmpty
                            ? _filteredRecents
                            : _recentSongs;
                        if (songsToShow.isEmpty) {
                          return const Center(
                            child: Text(
                              'No hay canciones recientes.',
                              style: TextStyle(fontSize: 16),
                            ),
                          );
                        }
                        return ListView.builder(
                          itemCount: songsToShow.length,
                          itemBuilder: (context, index) {
                            final song = songsToShow[index];
                            final isCurrent =
                                audioHandler.mediaItem.value?.extras?['data'] ==
                                song.data;
                            final isPlaying =
                                audioHandler.playbackState.value.playing;
                            return ListTile(
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: QueryArtworkWidget(
                                  id: song.id,
                                  type: ArtworkType.AUDIO,
                                  artworkBorder: BorderRadius.circular(8),
                                  artworkHeight: 50,
                                  artworkWidth: 50,
                                  keepOldArtwork: true,
                                  nullArtworkWidget: Container(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainer,
                                    width: 50,
                                    height: 50,
                                    child: const Icon(
                                      Icons.music_note,
                                      color: Colors.white70,
                                    ),
                                  ),
                                ),
                              ),
                              title: Text(
                                song.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: isCurrent
                                    ? const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      )
                                    : null,
                              ),
                              subtitle: Text(
                                (song.artist?.trim().isEmpty ?? true)
                                    ? 'Desconocido'
                                    : song.artist!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: IconButton(
                                icon: Icon(
                                  isCurrent && isPlaying
                                      ? Icons.pause
                                      : Icons.play_arrow,
                                ),
                                onPressed: () {
                                  if (isCurrent) {
                                    isPlaying
                                        ? audioHandler.pause()
                                        : audioHandler.play();
                                  } else {
                                    _playSong(song, songsToShow);
                                  }
                                },
                              ),
                              selected: isCurrent,
                              selectedTileColor: Theme.of(
                                context,
                              ).colorScheme.primaryContainer,
                              onTap: () async {
                                await _playSong(song, songsToShow);
                              },
                              onLongPress: () {
                                showModalBottomSheet(
                                  context: context,
                                  builder: (context) => SafeArea(
                                    child: FutureBuilder<bool>(
                                      future: FavoritesDB().isFavorite(
                                        song.data,
                                      ),
                                      builder: (context, snapshot) {
                                        final isFav = snapshot.data ?? false;
                                        return Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            ListTile(
                                              leading: Icon(
                                                isFav
                                                    ? Icons.delete_outline
                                                    : Icons.favorite_border,
                                              ),
                                              title: Text(
                                                isFav
                                                    ? 'Eliminar de me gusta'
                                                    : 'Añadir a me gusta',
                                              ),
                                              onTap: () async {
                                                Navigator.of(context).pop();
                                                if (isFav) {
                                                  await FavoritesDB()
                                                      .removeFavorite(
                                                        song.data,
                                                      );
                                                  favoritesShouldReload.value =
                                                      !favoritesShouldReload
                                                          .value;
                                                  if (context.mounted) {
                                                    ScaffoldMessenger.of(
                                                      context,
                                                    ).showSnackBar(
                                                      const SnackBar(
                                                        content: Text(
                                                          'Eliminado de me gusta',
                                                        ),
                                                      ),
                                                    );
                                                  }
                                                } else {
                                                  await _addToFavorites(song);
                                                }
                                              },
                                            ),
                                          ],
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
                    )
                  : _showingPlaylistSongs
                  ? Builder(
                      builder: (context) {
                        final List<SongModel> songsToShow =
                            _searchPlaylistController.text.isNotEmpty
                            ? _filteredPlaylistSongs
                            : _playlistSongs;
                        if (songsToShow.isEmpty) {
                          return const Center(
                            child: Text(
                              'No hay canciones en esta playlist.',
                              style: TextStyle(fontSize: 16),
                            ),
                          );
                        }
                        return ListView.builder(
                          itemCount: songsToShow.length,
                          itemBuilder: (context, index) {
                            final song = songsToShow[index];
                            final isCurrent =
                                audioHandler.mediaItem.value?.extras?['data'] ==
                                song.data;
                            final isPlaying =
                                audioHandler.playbackState.value.playing;

                            return ListTile(
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: QueryArtworkWidget(
                                  id: song.id,
                                  type: ArtworkType.AUDIO,
                                  artworkBorder: BorderRadius.circular(8),
                                  artworkHeight: 50,
                                  artworkWidth: 50,
                                  keepOldArtwork: true,
                                  nullArtworkWidget: Container(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainer,
                                    width: 50,
                                    height: 50,
                                    child: const Icon(
                                      Icons.music_note,
                                      color: Colors.white70,
                                    ),
                                  ),
                                ),
                              ),
                              title: Text(
                                song.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: isCurrent
                                    ? const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      )
                                    : null,
                              ),
                              subtitle: Text(
                                (song.artist?.trim().isEmpty ?? true)
                                    ? 'Desconocido'
                                    : song.artist!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: IconButton(
                                icon: Icon(
                                  isCurrent && isPlaying
                                      ? Icons.pause
                                      : Icons.play_arrow,
                                ),
                                onPressed: () {
                                  if (isCurrent) {
                                    isPlaying
                                        ? audioHandler.pause()
                                        : audioHandler.play();
                                  } else {
                                    _playSong(song, songsToShow);
                                  }
                                },
                              ),
                              selected: isCurrent,
                              selectedTileColor: Theme.of(
                                context,
                              ).colorScheme.primaryContainer,
                              onTap: () => _playSong(song, songsToShow),
                              onLongPress: () {
                                showModalBottomSheet(
                                  context: context,
                                  builder: (context) => SafeArea(
                                    child: FutureBuilder<bool>(
                                      future: FavoritesDB().isFavorite(
                                        song.data,
                                      ),
                                      builder: (context, snapshot) {
                                        final isFav = snapshot.data ?? false;
                                        return Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            ListTile(
                                              leading: Icon(
                                                isFav
                                                    ? Icons.delete_outline
                                                    : Icons.favorite_border,
                                              ),
                                              title: Text(
                                                isFav
                                                    ? 'Eliminar de me gusta'
                                                    : 'Añadir a me gusta',
                                              ),
                                              onTap: () async {
                                                Navigator.of(context).pop();
                                                if (isFav) {
                                                  await FavoritesDB()
                                                      .removeFavorite(
                                                        song.data,
                                                      );
                                                  favoritesShouldReload.value =
                                                      !favoritesShouldReload
                                                          .value;
                                                  if (context.mounted) {
                                                    ScaffoldMessenger.of(
                                                      context,
                                                    ).showSnackBar(
                                                      const SnackBar(
                                                        content: Text(
                                                          'Eliminado de me gusta',
                                                        ),
                                                      ),
                                                    );
                                                  }
                                                } else {
                                                  await _addToFavorites(song);
                                                }
                                              },
                                            ),
                                            if (_selectedPlaylist != null)
                                              ListTile(
                                                leading: const Icon(
                                                  Icons.playlist_remove,
                                                ),
                                                title: const Text(
                                                  'Eliminar de la playlist',
                                                ),
                                                onTap: () async {
                                                  Navigator.of(context).pop();
                                                  await PlaylistsDB()
                                                      .removeSongFromPlaylist(
                                                        _selectedPlaylist!['id'],
                                                        song.data,
                                                      );
                                                  await _loadPlaylistSongs(
                                                    _selectedPlaylist!,
                                                  );
                                                  if (!context.mounted) return;
                                                  ScaffoldMessenger.of(
                                                    context,
                                                  ).showSnackBar(
                                                    const SnackBar(
                                                      content: Text(
                                                        'Canción eliminada de la playlist',
                                                      ),
                                                    ),
                                                  );
                                                },
                                              ),
                                          ],
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
                    )
                  : SingleChildScrollView(
                      padding: EdgeInsets.zero,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 16),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 20),
                            child: Text(
                              'Acceso directos',
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 0),
                            child: SizedBox(
                              height: MediaQuery.of(context).size.height * 0.30,
                              child: PageView(
                                controller: _pageController,
                                onPageChanged: (_) {},
                                children: List.generate(3, (pageIndex) {
                                  final items = pages[pageIndex];
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                    child: GridView.builder(
                                      padding: const EdgeInsets.only(
                                        top: 8,
                                        bottom: 8,
                                      ),
                                      shrinkWrap: true,
                                      physics:
                                          const NeverScrollableScrollPhysics(),
                                      itemCount: 6,
                                      gridDelegate:
                                          const SliverGridDelegateWithFixedCrossAxisCount(
                                            crossAxisCount: 3,
                                            mainAxisSpacing: 12,
                                            crossAxisSpacing: 12,
                                            childAspectRatio: 1,
                                          ),
                                      itemBuilder: (context, index) {
                                        if (index < items.length) {
                                          final song = items[index];
                                          return AnimatedTapButton(
                                            onTap: () {
                                              _playSong(song, _mostPlayed);
                                            },
                                            onLongPress: () {
                                              _handleLongPress(context, song);
                                            },
                                            child: ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              child: QueryArtworkWidget(
                                                id: song.id,
                                                type: ArtworkType.AUDIO,
                                                artworkFit: BoxFit.cover,
                                                artworkBorder:
                                                    BorderRadius.circular(12),
                                                keepOldArtwork: true,
                                                nullArtworkWidget: Container(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .surfaceContainer,
                                                  child: const Icon(
                                                    Icons.music_note,
                                                    color: Colors.white70,
                                                    size: 36,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          );
                                        } else {
                                          return Container(
                                            decoration: BoxDecoration(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .surfaceContainerHighest,
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                            child: const Icon(
                                              Icons.music_note,
                                              color: Colors.white70,
                                              size: 36,
                                            ),
                                          );
                                        }
                                      },
                                    ),
                                  );
                                }),
                              ),
                            ),
                          ),
                          const SizedBox(height: 18),
                          Center(
                            child: SmoothPageIndicator(
                              controller: _pageController,
                              count: 3,
                              effect: WormEffect(
                                dotHeight: 8,
                                dotWidth: 8,
                                activeDotColor: Colors.white70,
                                dotColor: Colors.white24,
                              ),
                            ),
                          ),
                          const Divider(height: 32, thickness: 1),

                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 20),
                            child: Text(
                              'Selección rápida',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          (_quickPickPages.isEmpty)
                              ? const Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 20,
                                    vertical: 8,
                                  ),
                                  child: Text('No hay canciones para mostrar.'),
                                )
                              : Column(
                                  children: [
                                    SizedBox(
                                      height: 320,
                                      child: PageView.builder(
                                        controller: _quickPickPageController,
                                        itemCount: _quickPickPages.length,
                                        itemBuilder: (context, pageIndex) {
                                          final songs =
                                              _quickPickPages[pageIndex];
                                          // Reemplaza este fragmento dentro del PageView.builder de Selección rápida:
                                          return Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 0,
                                            ),
                                            child: ListView.builder(
                                              shrinkWrap: true,
                                              physics:
                                                  const NeverScrollableScrollPhysics(),
                                              itemCount: songs.length,
                                              itemBuilder: (context, index) {
                                                final song = songs[index];
                                                return Padding(
                                                  padding: EdgeInsets.only(
                                                    bottom:
                                                        index < songs.length - 1
                                                        ? 8.0
                                                        : 0,
                                                  ),
                                                  child: ListTile(
                                                    key: ValueKey(song.id),
                                                    leading: ClipRRect(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            8,
                                                          ),
                                                      child: QueryArtworkWidget(
                                                        id: song.id,
                                                        type: ArtworkType.AUDIO,
                                                        artworkHeight: 60,
                                                        artworkWidth: 60,
                                                        artworkBorder:
                                                            BorderRadius.zero,
                                                        artworkFit:
                                                            BoxFit.cover,
                                                        keepOldArtwork: true,
                                                        nullArtworkWidget: Container(
                                                          color: Theme.of(context)
                                                              .colorScheme
                                                              .surfaceContainer,
                                                          width: 44,
                                                          height: 44,
                                                          child: const Icon(
                                                            Icons.music_note,
                                                            color:
                                                                Colors.white70,
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                    title: Text(
                                                      song.title,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                    subtitle: Text(
                                                      (song.artist
                                                                  ?.trim()
                                                                  .isEmpty ??
                                                              true)
                                                          ? 'Desconocido'
                                                          : song.artist!,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                    onTap: () => _playSong(
                                                      song,
                                                      _mostPlayed,
                                                    ),
                                                    onLongPress: () =>
                                                        _handleLongPress(
                                                          context,
                                                          song,
                                                        ),
                                                  ),
                                                );
                                              },
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    SmoothPageIndicator(
                                      controller: _quickPickPageController,
                                      count: _quickPickPages.length,
                                      effect: WormEffect(
                                        dotHeight: 8,
                                        dotWidth: 8,
                                        activeDotColor: Colors.white70,
                                        dotColor: Colors.white24,
                                      ),
                                    ),
                                  ],
                                ),
                          const Divider(height: 32, thickness: 1),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 8,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'Playlists',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.add, size: 28),
                                  tooltip: 'Crear nueva playlist',
                                  padding: const EdgeInsets.only(left: 8),
                                  onPressed: () async {
                                    final controller = TextEditingController();
                                    final result = await showDialog<String>(
                                      context: context,
                                      builder: (context) => AlertDialog(
                                        title: const Text('Nueva playlist'),
                                        content: TextField(
                                          controller: controller,
                                          autofocus: true,
                                          decoration: const InputDecoration(
                                            labelText: 'Nombre de la playlist',
                                          ),
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.of(context).pop(),
                                            child: const Text('Cancelar'),
                                          ),
                                          TextButton(
                                            onPressed: () {
                                              Navigator.of(
                                                context,
                                              ).pop(controller.text.trim());
                                            },
                                            child: const Text('Crear'),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (result != null && result.isNotEmpty) {
                                      await PlaylistsDB().createPlaylist(
                                        result,
                                      );
                                      await _loadPlaylists();
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text('Playlist creada'),
                                          ),
                                        );
                                      }
                                    }
                                  },
                                ),
                              ],
                            ),
                          ),
                          // Aquí mostramos las playlists
                          if (_playlists.isEmpty)
                            const Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 10,
                              ),
                              child: Center(child: Text('No hay playlists.')),
                            )
                          else
                            ListView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              itemCount: _playlists.length,
                              itemBuilder: (context, index) {
                                final playlist = _playlists[index];
                                return ListTile(
                                  leading: const Icon(
                                    Icons.queue_music,
                                    size: 32,
                                    color: Colors.white70,
                                  ),
                                  title: Text(
                                    playlist['name'],
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () {
                                    _loadPlaylistSongs(playlist);
                                  },
                                  onLongPress: () async {
                                    showModalBottomSheet(
                                      context: context,
                                      builder: (context) => SafeArea(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            ListTile(
                                              leading: const Icon(Icons.edit),
                                              title: const Text(
                                                'Renombrar playlist',
                                              ),
                                              onTap: () async {
                                                Navigator.of(context).pop();
                                                final controller =
                                                    TextEditingController(
                                                      text: playlist['name'],
                                                    );
                                                final result = await showDialog<String>(
                                                  context: context,
                                                  builder: (context) => AlertDialog(
                                                    title: const Text(
                                                      'Renombrar playlist',
                                                    ),
                                                    content: TextField(
                                                      controller: controller,
                                                      autofocus: true,
                                                      decoration:
                                                          const InputDecoration(
                                                            labelText:
                                                                'Nuevo nombre',
                                                          ),
                                                    ),
                                                    actions: [
                                                      TextButton(
                                                        onPressed: () =>
                                                            Navigator.of(
                                                              context,
                                                            ).pop(),
                                                        child: const Text(
                                                          'Cancelar',
                                                        ),
                                                      ),
                                                      TextButton(
                                                        onPressed: () {
                                                          Navigator.of(
                                                            context,
                                                          ).pop(
                                                            controller.text
                                                                .trim(),
                                                          );
                                                        },
                                                        child: const Text(
                                                          'Guardar',
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                );
                                                if (result != null &&
                                                    result.isNotEmpty &&
                                                    result !=
                                                        playlist['name']) {
                                                  await PlaylistsDB()
                                                      .renamePlaylist(
                                                        playlist['id'],
                                                        result,
                                                      );
                                                  await _loadPlaylists();
                                                  if (context.mounted) {
                                                    ScaffoldMessenger.of(
                                                      context,
                                                    ).showSnackBar(
                                                      const SnackBar(
                                                        content: Text(
                                                          'Playlist renombrada',
                                                        ),
                                                      ),
                                                    );
                                                  }
                                                }
                                              },
                                            ),
                                            ListTile(
                                              leading: const Icon(
                                                Icons.delete_outline,
                                              ),
                                              title: const Text(
                                                'Eliminar playlist',
                                              ),
                                              onTap: () async {
                                                Navigator.of(context).pop();
                                                final confirm = await showDialog<bool>(
                                                  context: context,
                                                  builder: (context) => AlertDialog(
                                                    title: const Text(
                                                      'Eliminar playlist',
                                                    ),
                                                    content: const Text(
                                                      '¿Seguro que deseas eliminar esta playlist?',
                                                    ),
                                                    actions: [
                                                      TextButton(
                                                        onPressed: () =>
                                                            Navigator.of(
                                                              context,
                                                            ).pop(false),
                                                        child: const Text(
                                                          'Cancelar',
                                                        ),
                                                      ),
                                                      TextButton(
                                                        onPressed: () =>
                                                            Navigator.of(
                                                              context,
                                                            ).pop(true),
                                                        child: const Text(
                                                          'Eliminar',
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                );
                                                if (confirm == true) {
                                                  await PlaylistsDB()
                                                      .deletePlaylist(
                                                        playlist['id'],
                                                      );
                                                  await _loadPlaylists();
                                                  if (context.mounted) {
                                                    ScaffoldMessenger.of(
                                                      context,
                                                    ).showSnackBar(
                                                      const SnackBar(
                                                        content: Text(
                                                          'Playlist eliminada',
                                                        ),
                                                      ),
                                                    );
                                                  }
                                                }
                                              },
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                        ],
                      ),
                    ),
            );
          },
        ),
      ),
    );
  }
}

class AnimatedTapButton extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const AnimatedTapButton({
    super.key,
    required this.child,
    required this.onTap,
    this.onLongPress,
  });

  @override
  State<AnimatedTapButton> createState() => _AnimatedTapButtonState();
}

class _AnimatedTapButtonState extends State<AnimatedTapButton> {
  bool _pressed = false;

  void _handleTapUp(_) async {
    await Future.delayed(const Duration(milliseconds: 70));
    if (mounted) setState(() => _pressed = false);
  }

  void _handleTapCancel() async {
    await Future.delayed(const Duration(milliseconds: 70));
    if (mounted) setState(() => _pressed = false);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: _handleTapUp,
      onTapCancel: _handleTapCancel,
      child: AnimatedScale(
        scale: _pressed ? 0.93 : 1.0,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

class QuickPickSection extends StatefulWidget {
  final List<SongModel> mostPlayed;
  final void Function(SongModel) onTap;
  final void Function(BuildContext, SongModel) onLongPress;

  const QuickPickSection({
    super.key,
    required this.mostPlayed,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  State<QuickPickSection> createState() => _QuickPickSectionState();
}

class _QuickPickSectionState extends State<QuickPickSection> {
  late final List<SongModel> _quickPickSongs;

  @override
  void initState() {
    super.initState();
    final randomSongs = List<SongModel>.from(widget.mostPlayed);
    randomSongs.shuffle();
    _quickPickSongs = randomSongs.take(4).toList();
  }

  @override
  Widget build(BuildContext context) {
    if (_quickPickSongs.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Text('No hay canciones para mostrar.'),
      );
    }
    return ListView.separated(
      key: const PageStorageKey('quick_pick_list'),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _quickPickSongs.length,
      separatorBuilder: (_, __) => const SizedBox.shrink(),
      itemBuilder: (context, index) {
        final song = _quickPickSongs[index];
        return ListTile(
          key: ValueKey(song.id),
          minLeadingWidth: 56, // <-- Esto fuerza el espacio cuadrado
          contentPadding: EdgeInsets.zero,
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(
              8,
            ), // cuadrado con esquinas levemente redondeadas
            child: QueryArtworkWidget(
              id: song.id,
              type: ArtworkType.AUDIO,
              artworkBorder: BorderRadius.circular(8), // igual que arriba
              artworkHeight: 44,
              artworkWidth: 44,
              keepOldArtwork: true,
              nullArtworkWidget: Container(
                color: Theme.of(context).colorScheme.surfaceContainer,
                width: 44,
                height: 44,
                child: const Icon(Icons.music_note, color: Colors.white70),
              ),
            ),
          ),
          title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            (song.artist?.trim().isEmpty ?? true)
                ? 'Desconocido'
                : song.artist!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => widget.onTap(song),
          onLongPress: () => widget.onLongPress(context, song),
        );
      },
    );
  }
}
