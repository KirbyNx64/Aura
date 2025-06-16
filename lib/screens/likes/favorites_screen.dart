import 'package:flutter/material.dart';
import 'package:music/utils/db/favorites_db.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:music/main.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'package:audio_service/audio_service.dart';
import 'package:music/utils/notifiers.dart';

class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  List<SongModel> _favorites = [];
  late AnimationController _refreshController;
  bool _isReloading = false;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  List<SongModel> _filteredFavorites = [];
  double _lastBottomInset = 0.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _loadFavorites(initial: true);

    _searchFocusNode.addListener(() {
      setState(() {});
    });
    favoritesShouldReload.addListener(() {
      _loadFavorites();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    favoritesShouldReload.removeListener(() {
      _loadFavorites();
    });
    super.dispose();
  }

  Future<void> _loadFavorites({bool initial = false}) async {
    if (_isReloading) return;
    if (!initial) {
      if (!mounted) return;
      setState(() {
        _isReloading = true;
        _refreshController.repeat();
      });
    }
    final favs = await FavoritesDB().getFavorites();
    if (!initial) {
      // Espera un poco para que la animación sea visible
      await Future.delayed(const Duration(milliseconds: 600));
    }
    if (!mounted) return; // <-- Agrega esta línea
    setState(() {
      _favorites = favs;
      _isReloading = false;
      _refreshController.stop();
      _refreshController.reset();
    });
  }

  Future<void> _playSong(SongModel song) async {
    final index = _favorites.indexWhere((s) => s.data == song.data);
    if (index != -1) {
      await (audioHandler as MyAudioHandler).setQueueFromSongs(
        _favorites,
        initialIndex: index,
      );
      await audioHandler.play();
    }
  }

  Future<void> _removeFromFavorites(SongModel song) async {
    await FavoritesDB().removeFavorite(song.data);
    await _loadFavorites();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Eliminado de me gusta')));
    }
  }

  void _onSearchChanged() {
    final query = quitarDiacriticos(_searchController.text.trim());
    if (query.isEmpty) {
      setState(() {
        _filteredFavorites = [];
      });
      return;
    }
    setState(() {
      _filteredFavorites = _favorites.where((song) {
        final title = quitarDiacriticos(song.title);
        final artist = quitarDiacriticos(song.artist ?? '');
        return title.contains(query) || artist.contains(query);
      }).toList();
    });
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    final bottomInset = View.of(context).viewInsets.bottom;
    if (_lastBottomInset > 0.0 && bottomInset == 0.0) {
      if (mounted && _searchFocusNode.hasFocus) {
        _searchFocusNode.unfocus();
      }
    }
    _lastBottomInset = bottomInset;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _lastBottomInset = View.of(context).viewInsets.bottom;
  }

  String quitarDiacriticos(String texto) {
    const conAcentos = 'áàäâãéèëêíìïîóòöôõúùüûÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛ';
    const sinAcentos = 'aaaaaeeeeiiiiooooouuuuaaaaaeeeeiiiiooooouuuu';

    for (int i = 0; i < conAcentos.length; i++) {
      texto = texto.replaceAll(conAcentos[i], sinAcentos[i]);
    }
    return texto.toLowerCase();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.favorite_border, size: 28),
            const SizedBox(width: 8),
            const Text('Me gusta'),
          ],
        ),
        actions: [
          AnimatedBuilder(
            animation: _refreshController,
            builder: (context, child) {
              return Transform.rotate(
                angle: _refreshController.value * 6.3,
                child: IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Recargar',
                  onPressed: () {
                    if (!_isReloading) {
                      _loadFavorites();
                    }
                  },
                ),
              );
            },
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocusNode,
              onChanged: (_) => _onSearchChanged(),
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
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Builder(
                builder: (context) {
                  final List<SongModel> songsToShow =
                      _searchController.text.isNotEmpty
                      ? _filteredFavorites
                      : _favorites;
                  if (songsToShow.isEmpty) {
                    return const Center(child: Text('No hay canciones'));
                  }
                  return StreamBuilder<MediaItem?>(
                    stream: audioHandler.mediaItem,
                    builder: (context, currentSnapshot) {
                      final current = currentSnapshot.data;
                      return StreamBuilder<bool>(
                        stream: audioHandler.playbackState
                            .map((s) => s.playing)
                            .distinct(),
                        initialData: false,
                        builder: (context, playingSnapshot) {
                          final playing = playingSnapshot.data ?? false;
                          final space = current != null ? 100.0 : 0.0;
                          return Padding(
                            padding: EdgeInsets.only(bottom: space),
                            child: ListView.builder(
                              itemCount: songsToShow.length,
                              itemBuilder: (context, index) {
                                final song = songsToShow[index];
                                final isCurrent =
                                    current?.extras?['data'] == song.data;
                                return ListTile(
                                  onLongPress: () async {
                                    showModalBottomSheet(
                                      context: context,
                                      builder: (context) => SafeArea(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            ListTile(
                                              leading: const Icon(
                                                Icons.delete_outline,
                                              ),
                                              title: const Text(
                                                'Eliminar de me gusta',
                                              ),
                                              onTap: () async {
                                                Navigator.of(context).pop();
                                                await _removeFromFavorites(
                                                  song,
                                                );
                                                favoritesShouldReload.value =
                                                    !favoritesShouldReload
                                                        .value;
                                              },
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
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
                                    (song.artist == null ||
                                            song.artist!.trim().isEmpty)
                                        ? 'Desconocido'
                                        : song.artist!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: IconButton(
                                    icon: Icon(
                                      isCurrent && playing
                                          ? Icons.pause
                                          : Icons.play_arrow,
                                    ),
                                    onPressed: () {
                                      if (isCurrent) {
                                        playing
                                            ? audioHandler.pause()
                                            : audioHandler.play();
                                      } else {
                                        _playSong(song);
                                      }
                                    },
                                  ),
                                  selected: isCurrent,
                                  selectedTileColor: Theme.of(
                                    context,
                                  ).colorScheme.primaryContainer,
                                  onTap: () => _playSong(song),
                                );
                              },
                            ),
                          );
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
