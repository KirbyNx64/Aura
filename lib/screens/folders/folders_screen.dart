import 'dart:async';
import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:music/main.dart';
import 'package:audio_service/audio_service.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'package:music/utils/db/favorites_db.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:music/utils/db/playlists_db.dart';
import 'package:music/utils/db/songs_index_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  // Cambia la selección múltiple a rutas
  bool _isSelecting = false;
  final Set<String> _selectedSongPaths = {};

  // Cambia la estructura de canciones por carpeta a solo rutas
  Map<String, List<String>> songPathsByFolder = {};
  Map<String, String> folderDisplayNames = {};
  String? carpetaSeleccionada;
  List<SongModel> _filteredSongs = [];
  List<SongModel> _displaySongs = []; // Canciones que se muestran en la UI (filtradas por búsqueda)
  List<SongModel> _originalSongs = []; // Lista original para restaurar orden

  Timer? _debounce;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  double _lastBottomInset = 0.0;
  
  bool _isLoading = true;

  static const String _orderPrefsKey = 'folders_screen_order_filter';

  void _onFoldersShouldReload() {
    cargarCanciones(forceIndex: false);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadOrderFilter().then((_) => cargarCanciones());
    foldersShouldReload.addListener(_onFoldersShouldReload);
  }

  Future<void> _loadOrderFilter() async {
    final prefs = await SharedPreferences.getInstance();
    final int? savedIndex = prefs.getInt(_orderPrefsKey);
    if (savedIndex != null && savedIndex >= 0 && savedIndex < OrdenCarpetas.values.length) {
      setState(() {
        _orden = OrdenCarpetas.values[savedIndex];
      });
    }
  }

  Future<void> _saveOrderFilter() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_orderPrefsKey, _orden.index);
  }

  // Al cargar canciones:
  Future<void> cargarCanciones({bool forceIndex = false}) async {
    setState(() {
      _isLoading = true;
    });
    final prefs = await SharedPreferences.getInstance();
    final shouldIndex = forceIndex || (prefs.getBool('index_songs_on_startup') ?? true);
    if (shouldIndex) {
      await SongsIndexDB().indexAllSongs();
    }
    final folders = await SongsIndexDB().getFolders();
    final Map<String, List<String>> agrupado = {};
    final Map<String, String> displayNames = {};
    for (final folder in folders) {
      final paths = await SongsIndexDB().getSongsFromFolder(folder);
      if (paths.isNotEmpty) {
        agrupado[folder] = paths;
        // Obtener el nombre original de la carpeta sin normalizar
        final originalFolderName = _getOriginalFolderName(folder);
        displayNames[folder] = originalFolderName;
      }
    }
    setState(() {
      songPathsByFolder = agrupado;
      folderDisplayNames = displayNames;
      carpetaSeleccionada = null;
      _isLoading = false;
    });
    // Aplicar filtro si no es el normal
    if (_orden != OrdenCarpetas.normal && _originalSongs.isNotEmpty) {
      _ordenarCanciones();
    }
  }

  /// Obtiene el nombre original de la carpeta sin normalizar
  String _getOriginalFolderName(String normalizedFolderPath) {
    // Revertir la normalización para obtener el nombre original
    var originalPath = normalizedFolderPath;
    
    // Convertir de vuelta a la ruta original (sin minúsculas)
    final segments = originalPath.split(RegExp(r'[\\/]'));
    final folderName = segments.last;
    
    // Capitalizar la primera letra para que se vea mejor
    if (folderName.isNotEmpty) {
      return folderName[0].toUpperCase() + folderName.substring(1);
    }
    
    return folderName;
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
                  _selectedSongPaths.add(song.data);
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

  // Para reproducir:
  Future<void> _playSong(String path) async {
    final index = _filteredSongs.indexWhere((s) => s.data == path);
    if (index != -1) {
      await (audioHandler as MyAudioHandler).setQueueFromSongs(
        _filteredSongs,
        initialIndex: index,
      );
      await (audioHandler as MyAudioHandler).play();
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
        if (_selectedSongPaths.contains(song.data)) {
          _selectedSongPaths.remove(song.data);
          if (_selectedSongPaths.isEmpty) {
            _isSelecting = false;
          }
        } else {
          _selectedSongPaths.add(song.data);
        }
      });
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      if (!mounted) return;
      await _playSong(song.data);
    });
  }

  Future<void> _addToFavorites(SongModel song) async {
    await FavoritesDB().addFavorite(song);
  }

  void _ordenarCanciones() {
    setState(() {
      switch (_orden) {
        case OrdenCarpetas.normal:
          _filteredSongs = List.from(_originalSongs);
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
    _saveOrderFilter();
    // Actualizar también la lista de visualización
    _onSearchChanged();
  }

  void _aplicarOrdenamiento(List<SongModel> lista) {
    switch (_orden) {
      case OrdenCarpetas.normal:
        // Mantener el orden original de la carpeta
        break;
      case OrdenCarpetas.alfabetico:
        lista.sort((a, b) => a.title.compareTo(b.title));
        break;
      case OrdenCarpetas.invertido:
        lista.sort((a, b) => b.title.compareTo(a.title));
        break;
      case OrdenCarpetas.ultimoAgregado:
        // Invertir el orden de la lista
        lista.sort((a, b) {
          final indexA = _originalSongs.indexOf(a);
          final indexB = _originalSongs.indexOf(b);
          return indexB.compareTo(indexA);
        });
        break;
    }
  }

  void _onSearchChanged() {
    final query = quitarDiacriticos(_searchController.text.toLowerCase());

    // Primero aplicar ordenamiento a todas las canciones
    final allSongsOrdered = List<SongModel>.from(_originalSongs);
    _aplicarOrdenamiento(allSongsOrdered);
    
    // Guardar todas las canciones ordenadas en _filteredSongs (para reproducción)
    _filteredSongs = allSongsOrdered;

    // Filtrar solo las que se muestran en la UI
    List<SongModel> displayList;
    if (query.isEmpty) {
      displayList = List<SongModel>.from(allSongsOrdered);
    } else {
      displayList = allSongsOrdered.where((song) {
        final title = quitarDiacriticos(song.title);
        final artist = quitarDiacriticos(song.artist ?? '');
        return title.contains(query) || artist.contains(query);
      }).toList();
    }

    setState(() {
      _displaySongs = displayList;
    });
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
    if (songPathsByFolder.isEmpty) {
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
                onPressed: () => cargarCanciones(forceIndex: true),
              ),
            ],
          ),
          body: StreamBuilder<MediaItem?>(
            stream: audioHandler?.mediaItem,
            builder: (context, currentSnapshot) {
              final current = currentSnapshot.data;
              final space = current != null ? 100.0 : 0.0;
              return Padding(
                padding: EdgeInsets.only(bottom: space),
                child: ListView.builder(
                  itemCount: songPathsByFolder.length,
                  itemBuilder: (context, i) {
                    final sortedEntries = songPathsByFolder.entries.toList()
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
                      onTap: () async {
                        setState(() {
                          carpetaSeleccionada = entry.key;
                          _searchController.clear();
                          _isSelecting = false;
                          _selectedSongPaths.clear();
                        });
                        
                        // Cargar los objetos SongModel completos
                        final allSongs = await _audioQuery.querySongs();
                        final songsInFolder = allSongs.where((s) => entry.value.contains(s.data)).toList();
                        
                        setState(() {
                          _originalSongs = songsInFolder;
                        });
                        _ordenarCanciones();
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

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          setState(() {
            carpetaSeleccionada = null;
            _searchController.clear();
            _filteredSongs.clear();
            _displaySongs.clear();
            // Al salir, limpiar selección múltiple
            _isSelecting = false;
            _selectedSongPaths.clear();
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
            leading: _isSelecting
                ? null
                : IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () {
                      setState(() {
                        carpetaSeleccionada = null;
                        _searchController.clear();
                        _filteredSongs.clear();
                        _displaySongs.clear();
                        // Al salir, limpiar selección múltiple
                        _isSelecting = false;
                        _selectedSongPaths.clear();
                      });
                    },
                  ),
            title: _isSelecting
                ? Text('${_selectedSongPaths.length} ${LocaleProvider.tr('selected')}')
                : Text(folderDisplayNames[carpetaSeleccionada] ?? LocaleProvider.tr('folders')),
            actions: [
              if (_isSelecting) ...[
                IconButton(
                  icon: const Icon(Icons.favorite_outline),
                  tooltip: LocaleProvider.tr('add_to_favorites'),
                  onPressed: _selectedSongPaths.isEmpty ? null : () async {
                    // Acción masiva: añadir a favoritos
                    final selectedSongs = _displaySongs.where((s) => _selectedSongPaths.contains(s.data));
                    for (final song in selectedSongs) {
                      await _addToFavorites(song);
                    }
                    favoritesShouldReload.value = !favoritesShouldReload.value;
                    setState(() {
                      _isSelecting = false;
                      _selectedSongPaths.clear();
                    });
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.playlist_add),
                  tooltip: LocaleProvider.tr('add_to_playlist'),
                  onPressed: _selectedSongPaths.isEmpty ? null : () async {
                    await _handleAddToPlaylistMassive(context);
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.select_all),
                  tooltip: LocaleProvider.tr('select_all'),
                  onPressed: () {
                    setState(() {
                      if (_selectedSongPaths.length == _displaySongs.length) {
                        // Si todos están seleccionados, deseleccionar todos
                        _selectedSongPaths.clear();
                        if (_selectedSongPaths.isEmpty) {
                          _isSelecting = false;
                        }
                      } else {
                        // Seleccionar todos
                        _selectedSongPaths.addAll(_displaySongs.map((s) => s.data));
                      }
                    });
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: LocaleProvider.tr('cancel_selection'),
                  onPressed: () {
                    setState(() {
                      _isSelecting = false;
                      _selectedSongPaths.clear();
                    });
                  },
                ),
              ] else ...[
                IconButton(
                  icon: const Icon(Icons.shuffle, size: 28),
                  tooltip: LocaleProvider.tr('shuffle'),
                  onPressed: () {
                    if (_displaySongs.isNotEmpty) {
                      final random = (_displaySongs.toList()..shuffle()).first;
                      _playSong(random.data);
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
                    _saveOrderFilter();
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
                      onChanged: (_) => _onSearchChanged(),
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
            stream: audioHandler?.mediaItem,
            builder: (context, currentSnapshot) {
              // Detectar si el tema AMOLED está activo
              final isAmoledTheme = colorSchemeNotifier.value == AppColorScheme.amoled;
              final current = currentSnapshot.data;
              return StreamBuilder<bool>(
                stream: audioHandler?.playbackState
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
                            itemCount: _displaySongs.length,
                            itemBuilder: (context, i) {
                              final song = _displaySongs[i];
                              // Compara con el path, que es lo que normalmente usas como id en MediaItem
                              final path = song.data;
                              final isCurrent = (current?.id != null && path.isNotEmpty && current!.id == path);
                              final isPlaying = isCurrent && playing;
                              final isSelected = _selectedSongPaths.contains(path);

                              return ListTile(
                                onTap: () => _onSongSelected(song),
                                onLongPress: () {
                                  if (_isSelecting) {
                                    setState(() {
                                      if (_selectedSongPaths.contains(path)) {
                                  _selectedSongPaths.remove(path);
                                        if (_selectedSongPaths.isEmpty) {
                                          _isSelecting = false;
                                        }
                                      } else {
                                        _selectedSongPaths.add(path);
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
                                              _selectedSongPaths.add(path);
                                            } else {
                                              _selectedSongPaths.remove(path);
                                              if (_selectedSongPaths.isEmpty) {
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
                                                ? (audioHandler as MyAudioHandler).pause()
                                                : (audioHandler as MyAudioHandler).play();
                                          } else {
                                            _playSong(song.data);
                                          }
                                        },
                                      )
                                    : null,
                                selected: isCurrent,
                                selectedTileColor: isAmoledTheme
                                   ? Colors.white.withValues(alpha: 0.1) // Blanco muy transparente para AMOLED
                                  : Theme.of(context).colorScheme.primaryContainer,
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
    final TextEditingController playlistNameController = TextEditingController();
    final selectedPlaylistId = await showDialog<int>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) => SimpleDialog(
            title: TranslatedText('select_playlist'),
            children: [
              if (playlists.isNotEmpty)
                ...[
                  for (final playlist in playlists)
                    SimpleDialogOption(
                      onPressed: () {
                        Navigator.of(context).pop(playlist['id'] as int);
                      },
                      child: Text(playlist['name'] as String),
                    ),
                  const Divider(),
                ],
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: TextField(
                  controller: playlistNameController,
                  decoration: InputDecoration(
                    hintText: LocaleProvider.tr('new_playlist_name'),
                  ),
                  autofocus: playlists.isEmpty,
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
      final selectedSongs = _displaySongs.where((s) => _selectedSongPaths.contains(s.data));
      for (final song in selectedSongs) {
        await PlaylistsDB().addSongToPlaylist(selectedPlaylistId, song);
      }
      setState(() {
        _isSelecting = false;
        _selectedSongPaths.clear();
      });
    }
  }

  Future<void> _handleAddToPlaylistSingle(BuildContext context, SongModel song) async {
    final playlists = List<Map<String, dynamic>>.from(await PlaylistsDB().getAllPlaylists());
    if (!context.mounted) return;
    final TextEditingController playlistNameController = TextEditingController();
    final selectedPlaylistId = await showDialog<int>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) => SimpleDialog(
            title: TranslatedText('select_playlist'),
            children: [
              if (playlists.isNotEmpty)
                ...[
                  for (final playlist in playlists)
                    SimpleDialogOption(
                      onPressed: () {
                        Navigator.of(context).pop(playlist['id'] as int);
                      },
                      child: Text(playlist['name'] as String),
                    ),
                  const Divider(),
                ],
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: TextField(
                  controller: playlistNameController,
                  decoration: InputDecoration(
                    hintText: LocaleProvider.tr('new_playlist_name'),
                  ),
                  autofocus: playlists.isEmpty,
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
