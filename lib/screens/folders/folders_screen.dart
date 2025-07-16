import 'dart:async';
import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:path/path.dart' as p;
import 'package:music/main.dart';
import 'package:audio_service/audio_service.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'package:music/utils/db/favorites_db.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:music/utils/db/playlists_db.dart';

enum OrdenCarpetas { normal, alfabetico, invertido, ultimoAgregado }

OrdenCarpetas _orden = OrdenCarpetas.normal;

class FoldersScreen extends StatefulWidget {
  const FoldersScreen({super.key});

  @override
  State<FoldersScreen> createState() => _FoldersScreenState();
}

class _FoldersScreenState extends State<FoldersScreen>
    with WidgetsBindingObserver {
  final OnAudioQuery _audioQuery = OnAudioQuery();

  Map<String, List<SongModel>> songsByFolder = {};
  Map<String, String> folderDisplayNames = {}; // Mapa para nombres de visualización
  String? carpetaSeleccionada;

  Timer? _debounce;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  List<SongModel> _filteredSongs = [];
  List<SongModel> _originalSongs = []; // Lista original para restaurar orden

  double _lastBottomInset = 0.0;
  
  bool _isLoading = true; // <-- Nuevo estado de carga

  // --- NUEVO: Estado para selección múltiple ---
  bool _isSelecting = false;
  final Set<int> _selectedSongIds = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    cargarCanciones();
    foldersShouldReload.addListener(_onFoldersShouldReload);
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
    setState(() {
      _isLoading = true;
    });
    final permiso = await _audioQuery.permissionsStatus();
    if (!permiso) {
      final solicitado = await _audioQuery.permissionsRequest();
      if (!solicitado) {
        setState(() {
          _isLoading = false;
        });
        return;
      }
    }

    final lista = await _audioQuery.querySongs();

    final agrupado = <String, List<SongModel>>{};
    final displayNames = <String, String>{};
    
    for (var song in lista) {
      // Obtener la ruta original para el nombre de visualización
      var originalPath = p.dirname(song.data);
      var originalDisplayName = p.basename(originalPath);
      
      // Normalizar la ruta para evitar duplicados
      var carpetaNormalizada = _normalizeFolderPath(song.data);
      
      // Agrupar canciones por ruta normalizada
      agrupado.putIfAbsent(carpetaNormalizada, () => []).add(song);
      
      // Guardar el nombre de visualización original (mantener la primera que encontremos)
      if (!displayNames.containsKey(carpetaNormalizada)) {
        displayNames[carpetaNormalizada] = originalDisplayName;
      }
    }

    setState(() {
      songsByFolder = agrupado;
      folderDisplayNames = displayNames;
      carpetaSeleccionada = null;
      _isLoading = false;
    });
  }

  /// Normaliza la ruta de la carpeta de manera más robusta para evitar duplicados
  String _normalizeFolderPath(String filePath) {
    // Primero normalizar la ruta completa
    var normalizedPath = p.normalize(filePath);
    
    // Obtener el directorio padre
    var dirPath = p.dirname(normalizedPath);
    
    // Normalizar el directorio padre también
    dirPath = p.normalize(dirPath);
    
    // En Windows, convertir todas las barras a barras invertidas para consistencia
    if (dirPath.contains('/')) {
      dirPath = dirPath.replaceAll('/', '\\');
    }
    
    // Remover cualquier espacio en blanco al final
    dirPath = dirPath.trim();
    
    // Si la ruta termina con una barra invertida, removerla (excepto para rutas de unidad como C:\)
    if (dirPath.endsWith('\\') && dirPath.length > 3) {
      dirPath = dirPath.substring(0, dirPath.length - 1);
    }
    
    // Normalizar mayúsculas/minúsculas para evitar duplicados
    // En Android, convertir todo a minúsculas para consistencia
    dirPath = dirPath.toLowerCase();
    
    return dirPath;
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
              title: TranslatedText(
                isFavorite ? 'remove_from_favorites' : 'add_to_favorites',
              ),
              onTap: () async {
                Navigator.of(context).pop();

                if (isFavorite) {
                  await FavoritesDB().removeFavorite(song.data);
                  favoritesShouldReload.value = !favoritesShouldReload.value;
                } else {
                  await _addToFavorites(song);
                  favoritesShouldReload.value = !favoritesShouldReload.value;
                }
              },
            ),
            // --- NUEVO: Añadir a playlist ---
            ListTile(
              leading: const Icon(Icons.playlist_add),
              title: TranslatedText('add_to_playlist'),
              onTap: () async {
                Navigator.of(context).pop();
                await _handleAddToPlaylistSingle(context, song);
              },
            ),
            // --- NUEVO: Opción de seleccionar ---
            ListTile(
              leading: const Icon(Icons.check_box_outlined),
              title: TranslatedText('select'),
              onTap: () {
                Navigator.of(context).pop();
                setState(() {
                  _isSelecting = true;
                  _selectedSongIds.add(song.id);
                });
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
      album: song.album ?? LocaleProvider.tr('unknown_artist'),
      title: song.title,
      artist: song.artist ?? LocaleProvider.tr('unknown_artist'),
      artUri: song.uri != null ? Uri.parse(song.uri!) : null,
      extras: {'data': song.data},
    );
  }

  Future<void> _playSong(SongModel song) async {
    final playlist = _filteredSongs; // Usa la lista filtrada/ordenada
    final index = playlist.indexWhere((s) => s.id == song.id);

    if (index != -1) {
      await (audioHandler as MyAudioHandler).setQueueFromSongs(
        playlist,
        initialIndex: index,
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
    if (_isSelecting) {
      setState(() {
        if (_selectedSongIds.contains(song.id)) {
          _selectedSongIds.remove(song.id);
          if (_selectedSongIds.isEmpty) {
            _isSelecting = false;
          }
        } else {
          _selectedSongIds.add(song.id);
        }
      });
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      if (!mounted) return;
      await _playSong(song);
    });
  }

  Future<void> _addToFavorites(SongModel song) async {
    await FavoritesDB().addFavorite(song);
  }

  void _ordenarCanciones() {
    setState(() {
      switch (_orden) {
        case OrdenCarpetas.normal:
          _filteredSongs = List.from(_originalSongs); // Restaura el orden original
          break;
        case OrdenCarpetas.alfabetico:
          _filteredSongs.sort((a, b) => a.title.compareTo(b.title));
          break;
        case OrdenCarpetas.invertido:
          _filteredSongs.sort((a, b) => b.title.compareTo(a.title));
          break;
        case OrdenCarpetas.ultimoAgregado:
          _filteredSongs = List.from(_originalSongs.reversed);
          break;
      }
    });
  }

  void _onSearchChanged(List<SongModel> canciones) {
    final query = quitarDiacriticos(_searchController.text.toLowerCase());

    List<SongModel> filteredList;
    if (query.isEmpty) {
      filteredList = List.from(canciones);
    } else {
      filteredList = canciones.where((song) {
        final title = quitarDiacriticos(song.title);
        final artist = quitarDiacriticos(song.artist ?? '');
        return title.contains(query) || artist.contains(query);
      }).toList();
    }

    setState(() {
      _filteredSongs = filteredList;
    });
    
    // Aplicar el ordenamiento actual después del filtrado
    _ordenarCanciones();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    foldersShouldReload.removeListener(_onFoldersShouldReload);
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
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (songsByFolder.isEmpty) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_off, 
              size: 48, 
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)),
              const SizedBox(height: 16),
              TranslatedText(
                'no_folders_with_songs',
                style: TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)),
              ),
            ],
          ),
        ),
      );
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
                TranslatedText('folders_title'),
              ],
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh, size: 28),
                tooltip: LocaleProvider.tr('reload'),
                onPressed: cargarCanciones,
              ),
            ],
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
                        (a, b) => folderDisplayNames[a.key]!
                            .toLowerCase()
                            .compareTo(folderDisplayNames[b.key]!.toLowerCase()),
                      );
                    final entry = sortedEntries[i];
                    final nombre = folderDisplayNames[entry.key]!;
                    final canciones = entry.value;

                    return ListTile(
                      leading: const Icon(Icons.folder, size: 38),
                      title: Text(nombre),
                      subtitle: Text('${canciones.length} ${LocaleProvider.tr('songs')}'),
                      onTap: () {
                        setState(() {
                          carpetaSeleccionada = entry.key;
                          _searchController.clear();
                          _originalSongs = List.from(canciones);
                          _filteredSongs = List.from(canciones);
                          _ordenarCanciones();
                          // Al entrar a la carpeta, limpiar selección múltiple
                          _isSelecting = false;
                          _selectedSongIds.clear();
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
            // Al salir, limpiar selección múltiple
            _isSelecting = false;
            _selectedSongIds.clear();
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
                  // Al salir, limpiar selección múltiple
                  _isSelecting = false;
                  _selectedSongIds.clear();
                });
              },
            ),
            title: Text(folderDisplayNames[carpetaSeleccionada] ?? LocaleProvider.tr('folders')),
            actions: [
              if (_isSelecting) ...[
                IconButton(
                  icon: const Icon(Icons.favorite_outline),
                  tooltip: LocaleProvider.tr('add_to_favorites'),
                  onPressed: _selectedSongIds.isEmpty ? null : () async {
                    // Acción masiva: añadir a favoritos
                    final selectedSongs = _filteredSongs.where((s) => _selectedSongIds.contains(s.id));
                    for (final song in selectedSongs) {
                      await _addToFavorites(song);
                    }
                    favoritesShouldReload.value = !favoritesShouldReload.value;
                    setState(() {
                      _isSelecting = false;
                      _selectedSongIds.clear();
                    });
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.playlist_add),
                  tooltip: LocaleProvider.tr('add_to_playlist'),
                  onPressed: _selectedSongIds.isEmpty ? null : () async {
                    await _handleAddToPlaylistMassive(context);
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: LocaleProvider.tr('cancel_selection'),
                  onPressed: () {
                    setState(() {
                      _isSelecting = false;
                      _selectedSongIds.clear();
                    });
                  },
                ),
              ] else ...[
                IconButton(
                  icon: const Icon(Icons.shuffle, size: 28),
                  tooltip: LocaleProvider.tr('shuffle'),
                  onPressed: () {
                    if (_filteredSongs.isNotEmpty) {
                      final random = (_filteredSongs.toList()..shuffle()).first;
                      _playSong(random);
                    }
                  },
                ),
                PopupMenuButton<OrdenCarpetas>(
                  icon: const Icon(Icons.sort, size: 28),
                  onSelected: (orden) {
                    setState(() {
                      _orden = orden;
                      _ordenarCanciones();
                    });
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: OrdenCarpetas.normal,
                      child: TranslatedText('default'),
                    ),
                    PopupMenuItem(
                      value: OrdenCarpetas.ultimoAgregado,
                      child: TranslatedText('invert_order'),
                    ),
                    PopupMenuItem(
                      value: OrdenCarpetas.alfabetico,
                      child: TranslatedText('alphabetical_az'),
                    ),
                    PopupMenuItem(
                      value: OrdenCarpetas.invertido,
                      child: TranslatedText('alphabetical_za'),
                    ),
                  ],
                ),
              ],
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(56),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: ValueListenableBuilder<String>(
                  valueListenable: languageNotifier,
                  builder: (context, lang, child) {
                    return TextField(
                      controller: _searchController,
                      focusNode: _searchFocusNode,
                      onChanged: (_) => _onSearchChanged(canciones),
                      onEditingComplete: () {
                        _searchFocusNode.unfocus();
                      },
                      decoration: InputDecoration(
                        hintText: LocaleProvider.tr('search_by_title_or_artist'),
                        prefixIcon: const Icon(Icons.search),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                        contentPadding: const EdgeInsets.symmetric(vertical: 0),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          body: StreamBuilder<MediaItem?>(
            stream: audioHandler.mediaItem,
            builder: (context, currentSnapshot) {
              // Detectar si el tema AMOLED está activo
              final isAmoledTheme = colorSchemeNotifier.value == AppColorScheme.amoled;
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
                        ? Center(
                            child: TranslatedText(
                              'no_songs_in_folder',
                              style: TextStyle(fontSize: 16),
                            ),
                          )
                        : ListView.builder(
                            itemCount: _filteredSongs.length,
                            itemBuilder: (context, i) {
                              final song = _filteredSongs[i];
                              // Compara con el path, que es lo que normalmente usas como id en MediaItem
                              final isCurrent = current?.id == song.data;
                              final isPlaying = isCurrent && playing;
                              final isSelected = _selectedSongIds.contains(song.id);

                              return ListTile(
                                onTap: () => _onSongSelected(song),
                                onLongPress: () {
                                  if (_isSelecting) {
                                    setState(() {
                                      if (_selectedSongIds.contains(song.id)) {
                                        _selectedSongIds.remove(song.id);
                                        if (_selectedSongIds.isEmpty) {
                                          _isSelecting = false;
                                        }
                                      } else {
                                        _selectedSongIds.add(song.id);
                                      }
                                    });
                                  } else {
                                    _handleLongPress(context, song);
                                  }
                                },
                                leading: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (_isSelecting)
                                      Checkbox(
                                        value: isSelected,
                                        onChanged: (checked) {
                                          setState(() {
                                            if (checked == true) {
                                              _selectedSongIds.add(song.id);
                                            } else {
                                              _selectedSongIds.remove(song.id);
                                              if (_selectedSongIds.isEmpty) {
                                                _isSelecting = false;
                                              }
                                            }
                                          });
                                        },
                                      ),
                                    ClipRRect(
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
                                          child: Icon(
                                            Icons.music_note,
                                            color: Theme.of(context).colorScheme.onSurface,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                title: Text(
                                  song.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: isCurrent
                                      ? TextStyle(
                                          color: isAmoledTheme
                                              ? Colors.white
                                              : Theme.of(context).colorScheme.primary,
                                          fontWeight: FontWeight.bold,
                                        )
                                      : null,
                                ),
                                subtitle: Text(
                                  song.artist ?? LocaleProvider.tr('unknown_artist'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: !_isSelecting
                                    ? IconButton(
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
                                      )
                                    : null,
                                selected: isCurrent,
                                selectedTileColor: isAmoledTheme
                                   ? Colors.white.withValues(alpha: 0.1) // Blanco muy transparente para AMOLED
                                   : Theme.of(context).colorScheme.primaryContainer,
                                tileColor: isSelected
                                    ? Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.4)
                                    : null,
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

  Future<void> _handleAddToPlaylistMassive(BuildContext context) async {
    final playlists = List<Map<String, dynamic>>.from(await PlaylistsDB().getAllPlaylists());
    if (!context.mounted) return;
    if (playlists.isEmpty) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: TranslatedText('add_to_playlist'),
          content: TranslatedText('no_playlists_found'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: TranslatedText('ok'),
            ),
          ],
        ),
      );
      return;
    }
    if (!context.mounted) return;
    final selectedPlaylistId = await showDialog<int>(
      context: context,
      builder: (context) {
        final TextEditingController playlistNameController = TextEditingController();
        return StatefulBuilder(
          builder: (context, setStateDialog) => SimpleDialog(
            title: TranslatedText('select_playlist'),
            children: [
              for (final playlist in playlists)
                SimpleDialogOption(
                  onPressed: () {
                    Navigator.of(context).pop(playlist['id'] as int);
                  },
                  child: Text(playlist['name'] as String),
                ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: TextField(
                  controller: playlistNameController,
                  decoration: InputDecoration(
                    hintText: LocaleProvider.tr('new_playlist_name'),
                  ),
                ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.add),
                label: TranslatedText('create_playlist'),
                onPressed: () async {
                  final name = playlistNameController.text.trim();
                  if (name.isEmpty) return;
                  final id = await PlaylistsDB().createPlaylist(name);
                  // Notificar a la app que se creó una nueva playlist
                  playlistsShouldReload.value = !playlistsShouldReload.value;
                  setStateDialog(() {
                    playlists.insert(0, {'id': id, 'name': name});
                  });
                  playlistNameController.clear();
                  if (context.mounted) {
                    Navigator.of(context).pop(id);
                  }
                },
              ),
            ],
          ),
        );
      },
    );
    if (selectedPlaylistId != null) {
      final selectedSongs = _filteredSongs.where((s) => _selectedSongIds.contains(s.id));
      for (final song in selectedSongs) {
        await PlaylistsDB().addSongToPlaylist(selectedPlaylistId, song);
      }
      // Confirmación eliminada: no mostrar SnackBar
      setState(() {
        _isSelecting = false;
        _selectedSongIds.clear();
      });
    }
  }

  Future<void> _handleAddToPlaylistSingle(BuildContext context, SongModel song) async {
    final playlists = List<Map<String, dynamic>>.from(await PlaylistsDB().getAllPlaylists());
    if (!context.mounted) return;
    if (playlists.isEmpty) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: TranslatedText('add_to_playlist'),
          content: TranslatedText('no_playlists_found'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: TranslatedText('ok'),
            ),
          ],
        ),
      );
      return;
    }
    if (!context.mounted) return;
    final selectedPlaylistId = await showDialog<int>(
      context: context,
      builder: (context) {
        final TextEditingController playlistNameController = TextEditingController();
        return StatefulBuilder(
          builder: (context, setStateDialog) => SimpleDialog(
            title: TranslatedText('select_playlist'),
            children: [
              for (final playlist in playlists)
                SimpleDialogOption(
                  onPressed: () {
                    Navigator.of(context).pop(playlist['id'] as int);
                  },
                  child: Text(playlist['name'] as String),
                ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: TextField(
                  controller: playlistNameController,
                  decoration: InputDecoration(
                    hintText: LocaleProvider.tr('new_playlist_name'),
                  ),
                ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.add),
                label: TranslatedText('create_playlist'),
                onPressed: () async {
                  final name = playlistNameController.text.trim();
                  if (name.isEmpty) return;
                  final id = await PlaylistsDB().createPlaylist(name);
                  playlistsShouldReload.value = !playlistsShouldReload.value;
                  setStateDialog(() {
                    playlists.insert(0, {'id': id, 'name': name});
                  });
                  playlistNameController.clear();
                  if (context.mounted) {
                    Navigator.of(context).pop(id);
                  }
                },
              ),
            ],
          ),
        );
      },
    );
    if (selectedPlaylistId != null) {
      await PlaylistsDB().addSongToPlaylist(selectedPlaylistId, song);
      // Confirmación eliminada: no mostrar SnackBar
    }
  }
}
