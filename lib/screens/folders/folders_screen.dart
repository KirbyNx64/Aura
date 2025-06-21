import 'dart:async';
import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:path/path.dart' as p;
import 'package:music/main.dart';
import 'package:audio_service/audio_service.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'package:music/utils/db/favorites_db.dart';
import 'package:music/utils/notifiers.dart';

class FoldersScreen extends StatefulWidget {
  const FoldersScreen({super.key});

  @override
  State<FoldersScreen> createState() => _FoldersScreenState();
}

class _FoldersScreenState extends State<FoldersScreen>
    with WidgetsBindingObserver {
  final OnAudioQuery _audioQuery = OnAudioQuery();

  Map<String, List<SongModel>> songsByFolder = {};
  String? carpetaSeleccionada;

  Timer? _debounce;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  List<SongModel> _filteredSongs = [];

  double _lastBottomInset = 0.0;

  final int _pageSize = 50;
  int _currentMax = 50;
  late ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    cargarCanciones();
    foldersShouldReload.addListener(_onFoldersShouldReload);
    _scrollController = ScrollController()..addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _lastBottomInset = View.of(context).viewInsets.bottom;
  }

  void _onFoldersShouldReload() {
    cargarCanciones();
  }

  Future<void> cargarCanciones() async {
    final permiso = await _audioQuery.permissionsRequest();
    if (!permiso) return;

    final lista = await _audioQuery.querySongs();

    final agrupado = <String, List<SongModel>>{};
    for (var song in lista) {
      var carpeta = p.normalize(p.dirname(song.data)).trim();
      agrupado.putIfAbsent(carpeta, () => []).add(song);
    }

    setState(() {
      songsByFolder = agrupado;
      carpetaSeleccionada = null;
    });
  }

  void _handleLongPress(BuildContext context, SongModel song) async {
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
                  favoritesShouldReload.value = !favoritesShouldReload.value;

                  if (!context.mounted) return;

                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Eliminado de me gusta')),
                  );
                } else {
                  await _addToFavorites(song);
                  favoritesShouldReload.value = !favoritesShouldReload.value;
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  MediaItem songToMediaItem(SongModel song) {
    return MediaItem(
      id: song.id.toString(),
      album: song.album ?? 'Desconocido',
      title: song.title,
      artist: song.artist ?? 'Desconocido',
      artUri: song.uri != null ? Uri.parse(song.uri!) : null,
      extras: {'data': song.data},
    );
  }

  Future<void> _playSong(SongModel song) async {
    const int maxQueueSongs = 200;
    final playlist = songsByFolder[carpetaSeleccionada] ?? [];
    final index = playlist.indexWhere((s) => s.id == song.id);

    if (index != -1) {
      int before = (maxQueueSongs / 2).floor();
      int after = maxQueueSongs - before;
      int start = (index - before).clamp(0, playlist.length);
      int end = (index + after).clamp(0, playlist.length);
      List<SongModel> limitedQueue = playlist.sublist(start, end);
      int newIndex = index - start;

      await (audioHandler as MyAudioHandler).setQueueFromSongs(
        limitedQueue,
        initialIndex: newIndex,
      );
      await audioHandler.play();
    }
  }

  String quitarDiacriticos(String texto) {
    const conAcentos = 'áàäâãéèëêíìïîóòöôõúùüûÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛ';
    const sinAcentos = 'aaaaaeeeeiiiiooooouuuuaaaaaeeeeiiiiooooouuuu';

    for (int i = 0; i < conAcentos.length; i++) {
      texto = texto.replaceAll(conAcentos[i], sinAcentos[i]);
    }
    return texto.toLowerCase();
  }

  void _onSongSelected(SongModel song) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      if (!mounted) return;
      await _playSong(song);
    });
  }

  Future<void> _addToFavorites(SongModel song) async {
    await FavoritesDB().addFavorite(song);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Añadido a me gusta')));
    }
  }

  void _onSearchChanged(List<SongModel> canciones) {
    final query = quitarDiacriticos(_searchController.text.toLowerCase());

    setState(() {
      if (query.isEmpty) {
        _filteredSongs = List.from(canciones);
      } else {
        _filteredSongs = canciones.where((song) {
          final title = quitarDiacriticos(song.title);
          final artist = quitarDiacriticos(song.artist ?? '');
          return title.contains(query) || artist.contains(query);
        }).toList();
      }
      _currentMax = _pageSize;
    });
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent) {
      // Estás en el final de la lista, carga más elementos
      _loadMore();
    }
  }

  void _loadMore() {
    if (_currentMax < songsByFolder.length) {
      setState(() {
        _currentMax += _pageSize;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    foldersShouldReload.removeListener(_onFoldersShouldReload);
    _scrollController.dispose();
    super.dispose();
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
  Widget build(BuildContext context) {
    if (songsByFolder.isEmpty) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (carpetaSeleccionada == null) {
      return PopScope(
        canPop: true,
        child: Scaffold(
          resizeToAvoidBottomInset: true,
          appBar: AppBar(
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.folder_outlined, size: 28),
                const SizedBox(width: 8),
                const Text('Carpetas'),
              ],
            ),
          ),
          body: StreamBuilder<MediaItem?>(
            stream: audioHandler.mediaItem,
            builder: (context, currentSnapshot) {
              final current = currentSnapshot.data;
              final space = current != null ? 100.0 : 0.0;
              return Padding(
                padding: EdgeInsets.only(bottom: space),
                child: ListView.builder(
                  itemCount: songsByFolder.length,
                  itemBuilder: (context, i) {
                    final sortedEntries = songsByFolder.entries.toList()
                      ..sort(
                        (a, b) => p
                            .basename(a.key)
                            .toLowerCase()
                            .compareTo(p.basename(b.key).toLowerCase()),
                      );
                    final entry = sortedEntries[i];
                    final nombre = p.basename(entry.key);
                    final canciones = entry.value;

                    return ListTile(
                      leading: const Icon(Icons.folder, size: 36),
                      title: Text(nombre),
                      subtitle: Text('${canciones.length} canciones'),
                      onTap: () {
                        setState(() {
                          carpetaSeleccionada = entry.key;
                          _searchController.clear();
                          _filteredSongs = List.from(canciones);
                          _currentMax = _pageSize;
                        });
                      },
                    );
                  },
                ),
              );
            },
          ),
        ),
      );
    }

    final canciones = songsByFolder[carpetaSeleccionada] ?? [];

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          setState(() {
            carpetaSeleccionada = null;
            _searchController.clear();
            _filteredSongs.clear();
          });
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          FocusScope.of(context).unfocus();
        },
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () {
                setState(() {
                  carpetaSeleccionada = null;
                  _searchController.clear();
                  _filteredSongs.clear();
                });
              },
            ),
            title: Text(p.basename(carpetaSeleccionada!)),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(56),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  onChanged: (_) => _onSearchChanged(canciones),
                  onEditingComplete: () {
                    _searchFocusNode.unfocus();
                  },
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
          body: StreamBuilder<MediaItem?>(
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
                    child: _filteredSongs.isEmpty
                        ? const Center(
                            child: Text(
                              'No se encontraron canciones.',
                              style: TextStyle(fontSize: 16),
                            ),
                          )
                        : ListView.builder(
                            controller: _scrollController,
                            itemCount: _filteredSongs.length,
                            itemBuilder: (context, i) {
                              final song = _filteredSongs[i];
                              // Compara con el path, que es lo que normalmente usas como id en MediaItem
                              final isCurrent = current?.id == song.data;
                              final isPlaying = isCurrent && playing;

                              return ListTile(
                                onTap: () => _onSongSelected(song),
                                onLongPress: () {
                                  _handleLongPress(context, song);
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
                                      ? TextStyle(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                          fontWeight: FontWeight.bold,
                                        )
                                      : null,
                                ),
                                subtitle: Text(
                                  song.artist ?? 'Desconocido',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: IconButton(
                                  icon: Icon(
                                    isCurrent
                                        ? (isPlaying
                                              ? Icons.pause
                                              : Icons.play_arrow)
                                        : Icons.play_arrow,
                                    color: isCurrent
                                        ? Theme.of(context).colorScheme.primary
                                        : null,
                                  ),
                                  onPressed: () {
                                    if (isCurrent) {
                                      isPlaying
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
                              );
                            },
                          ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}
