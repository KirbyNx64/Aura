import 'dart:async';
import 'dart:io';
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
import 'package:music/utils/db/recent_db.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:music/utils/db/shortcuts_db.dart';
import 'package:mini_music_visualizer/mini_music_visualizer.dart';
import 'package:music/screens/play/player_screen.dart';
import 'package:music/utils/db/playlist_model.dart' as hive_model;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

enum OrdenCarpetas {
  normal,
  alfabetico,
  invertido,
  ultimoAgregado,
  fechaEdicionAsc, // Más antiguas primero
  fechaEdicionDesc, // Más recientes primero
}

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
  List<SongModel> _displaySongs =
      []; // Canciones que se muestran en la UI (filtradas por búsqueda)
  List<SongModel> _originalSongs = []; // Lista original para restaurar orden

  Timer? _debounce;
  Timer? _playingDebounce;
  Timer? _mediaItemDebounce;
  Timer? _immediateMediaItemDebounce;
  final ValueNotifier<bool> _isPlayingNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<MediaItem?> _currentMediaItemNotifier =
      ValueNotifier<MediaItem?>(null);
  final ValueNotifier<MediaItem?> _immediateMediaItemNotifier =
      ValueNotifier<MediaItem?>(null);

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  double _lastBottomInset = 0.0;

  bool _isLoading = true;

  static const String _orderPrefsKey = 'folders_screen_order_filter';
  static const String _pinnedSongsKey = 'pinned_songs';
  static const String _ignoredSongsKey = 'ignored_songs';

  // Utilidades para gestionar canciones fijadas
  Future<List<String>> getPinnedSongs() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_pinnedSongsKey) ?? [];
  }

  Future<void> pinSong(String songPath) async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getStringList(_pinnedSongsKey) ?? [];
    if (!current.contains(songPath)) {
      current.insert(0, songPath); // Fijar al inicio
      if (current.length > 18) current.length = 18; // Limitar a 18
      await prefs.setStringList(_pinnedSongsKey, current);
    }
  }

  Future<void> unpinSong(String songPath) async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getStringList(_pinnedSongsKey) ?? [];
    current.remove(songPath);
    await prefs.setStringList(_pinnedSongsKey, current);
  }

  Future<bool> isSongPinned(String songPath) async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getStringList(_pinnedSongsKey) ?? [];
    return current.contains(songPath);
  }

  // Utilidades para gestionar canciones ignoradas
  Future<List<String>> getIgnoredSongs() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_ignoredSongsKey) ?? [];
  }

  Future<void> ignoreSong(String songPath) async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getStringList(_ignoredSongsKey) ?? [];
    if (!current.contains(songPath)) {
      current.add(songPath);
      await prefs.setStringList(_ignoredSongsKey, current);
    }
  }

  Future<void> unignoreSong(String songPath) async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getStringList(_ignoredSongsKey) ?? [];
    current.remove(songPath);
    await prefs.setStringList(_ignoredSongsKey, current);
  }

  Future<bool> isSongIgnored(String songPath) async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getStringList(_ignoredSongsKey) ?? [];
    return current.contains(songPath);
  }

  void _onFoldersShouldReload() async {
    // Siempre sincronizar el índice de carpetas en background
    await _sincronizarMapaCarpetas();

    // Si estamos dentro de una carpeta, actualizar solo esa carpeta sin salir
    if (carpetaSeleccionada != null) {
      await _actualizarCarpetaActual();
    } else {
      // Si estamos en la vista general, recargar para mostrar cambios
      cargarCanciones(forceIndex: false);
    }
  }

  /// Sincroniza el mapa de carpetas con archivos nuevos/eliminados en background
  Future<void> _sincronizarMapaCarpetas() async {
    try {
      // Sincronizar base de datos con archivos nuevos/eliminados
      await SongsIndexDB().syncDatabase();

      // Obtener todas las carpetas actualizadas
      final folders = await SongsIndexDB().getFolders();
      final Map<String, List<String>> nuevoMapa = {};
      final Map<String, String> nuevosDisplayNames = {};

      for (final folder in folders) {
        final paths = await SongsIndexDB().getSongsFromFolder(folder);
        if (paths.isNotEmpty) {
          nuevoMapa[folder] = paths;
          // Obtener el nombre original de la carpeta sin normalizar
          final originalFolderName = _getOriginalFolderName(folder);
          nuevosDisplayNames[folder] = originalFolderName;
        }
      }

      // Actualizar los mapas sin setState (background update)
      songPathsByFolder = nuevoMapa;
      folderDisplayNames = nuevosDisplayNames;
    } catch (e) {
      // Si hay error en la sincronización, no hacer nada crítico
      // El método que llame a este puede hacer fallback
    }
  }

  /// Actualiza solo la carpeta actual sin salir de ella manteniendo la posición
  Future<void> _actualizarCarpetaActual() async {
    if (carpetaSeleccionada == null) return;

    // Guardar el estado actual incluyendo posición de scroll
    final searchQuery = _searchController.text;
    final wasSelecting = _isSelecting;
    final selectedPaths = Set<String>.from(_selectedSongPaths);
    final scrollPosition = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;

    // Mostrar loading solo si no hay canciones (evita parpadeo)
    if (_displaySongs.isEmpty) {
      setState(() {
        _isLoading = true;
      });
    }

    try {
      // Usar las rutas ya actualizadas del mapa (sincronizado previamente)
      final updatedPaths = songPathsByFolder[carpetaSeleccionada!] ?? [];

      // Cargar los objetos SongModel completos para la carpeta actual
      final allSongs = await _audioQuery.querySongs();
      final songsInFolder = allSongs
          .where((s) => updatedPaths.contains(s.data))
          .toList();

      // Actualizar las listas de canciones sin setState para evitar rebuild
      _originalSongs = songsInFolder;

      // Aplicar ordenamiento actual
      await _aplicarOrdenamiento(_originalSongs);
      _filteredSongs = List<SongModel>.from(_originalSongs);

      // Restaurar el estado de búsqueda si había texto
      if (searchQuery.isNotEmpty) {
        _searchController.text = searchQuery;
        await _onSearchChanged();
      } else {
        _displaySongs = List<SongModel>.from(_filteredSongs);
      }

      // Restaurar selección múltiple si estaba activa
      if (wasSelecting) {
        _isSelecting = true;
        // Mantener solo las canciones seleccionadas que aún existen
        _selectedSongPaths.clear();
        _selectedSongPaths.addAll(
          selectedPaths.where(
            (path) => _displaySongs.any((song) => song.data == path),
          ),
        );
        // Si no queda ninguna canción seleccionada, salir del modo selección
        if (_selectedSongPaths.isEmpty) {
          _isSelecting = false;
        }
      }

      // Actualizar UI con setState mínimo
      if (mounted) {
        setState(() {
          _isLoading = false;
        });

        // Restaurar posición de scroll después del rebuild
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients && scrollPosition > 0.0) {
            _scrollController.animateTo(
              scrollPosition,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            );
          }
        });
      }

      // Precargar carátulas de las canciones
      unawaited(_preloadArtworksForSongs(songsInFolder));
    } catch (e) {
      // En caso de error, fallback al comportamiento original
      if (mounted) {
        cargarCanciones(forceIndex: false);
      }
      return;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadOrderFilter().then((_) => cargarCanciones());
    foldersShouldReload.addListener(_onFoldersShouldReload);

    // Escuchar cambios en el estado de reproducción con debounce
    audioHandler?.playbackState.listen((state) {
      _playingDebounce?.cancel();
      _playingDebounce = Timer(const Duration(milliseconds: 400), () {
        if (mounted) {
          _isPlayingNotifier.value = state.playing;
        }
      });
    });

    // Inicializar con el valor actual si ya hay algo reproduciéndose
    if (audioHandler?.mediaItem.valueOrNull != null) {
      // Cancelar cualquier debounce pendiente
      _immediateMediaItemDebounce?.cancel();
      _mediaItemDebounce?.cancel();
      _immediateMediaItemNotifier.value = audioHandler!.mediaItem.valueOrNull;
      _currentMediaItemNotifier.value = audioHandler!.mediaItem.valueOrNull;
    }

    // Inicializar el estado de reproducción actual
    if (audioHandler?.playbackState.valueOrNull != null) {
      _isPlayingNotifier.value =
          audioHandler!.playbackState.valueOrNull!.playing;
    }

    // Escuchar cambios en el MediaItem con debounce (para detección de canción actual)
    audioHandler?.mediaItem.listen((mediaItem) {
      _immediateMediaItemDebounce?.cancel();
      _immediateMediaItemDebounce = Timer(
        const Duration(milliseconds: 500),
        () {
          if (mounted) {
            _immediateMediaItemNotifier.value = mediaItem;
          }
        },
      );
    });

    // Escuchar cambios en el MediaItem con debounce (para espaciado y elementos no críticos)
    audioHandler?.mediaItem.listen((mediaItem) {
      _mediaItemDebounce?.cancel();
      _mediaItemDebounce = Timer(const Duration(milliseconds: 400), () {
        if (mounted) {
          _currentMediaItemNotifier.value = mediaItem;
        }
      });
    });
  }

  Future<void> _loadOrderFilter() async {
    final prefs = await SharedPreferences.getInstance();
    final int? savedIndex = prefs.getInt(_orderPrefsKey);
    if (savedIndex != null &&
        savedIndex >= 0 &&
        savedIndex < OrdenCarpetas.values.length) {
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
    final shouldIndex =
        forceIndex || (prefs.getBool('index_songs_on_startup') ?? true);
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
    final isPinned = await ShortcutsDB().isShortcut(song.data);
    final isIgnored = await isSongIgnored(song.data);

    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Encabezado con información de la canción
              Container(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    // Carátula de la canción
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 60,
                        height: 60,
                        child: _buildModalArtwork(song),
                      ),
                    ),
                    const SizedBox(width: 16),
                    // Título y artista
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            song.title,
                            maxLines: 1,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            song.artist ?? LocaleProvider.tr('unknown_artist'),
                            style: TextStyle(fontSize: 14),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Botón de YouTube para buscar la canción
                    ElevatedButton.icon(
                      onPressed: () async {
                        Navigator.of(context).pop();
                        await _searchSongOnYouTube(song);
                      },
                      label: Text(
                        'YouTube',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      icon: const Icon(Icons.search, size: 20),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.primaryContainer,
                        foregroundColor: Theme.of(
                          context,
                        ).colorScheme.onPrimaryContainer,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(Icons.queue_music),
                title: TranslatedText('add_to_queue'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await (audioHandler as MyAudioHandler).addSongsToQueueEnd([
                    song,
                  ]);
                },
              ),
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
              ListTile(
                leading: Icon(
                  isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                ),
                title: TranslatedText(
                  isPinned ? 'unpin_shortcut' : 'pin_shortcut',
                ),
                onTap: () async {
                  Navigator.of(context).pop();
                  if (isPinned) {
                    await ShortcutsDB().removeShortcut(song.data);
                  } else {
                    await ShortcutsDB().addShortcut(song.data);
                  }
                  if (mounted) setState(() {});
                  shortcutsShouldReload.value = !shortcutsShouldReload.value;
                },
              ),
              ListTile(
                leading: const Icon(Icons.share),
                title: TranslatedText('share_audio_file'),
                onTap: () async {
                  Navigator.of(context).pop();
                  final dataPath = song.data;
                  if (dataPath.isNotEmpty) {
                    await SharePlus.instance.share(
                      ShareParams(text: song.title, files: [XFile(dataPath)]),
                    );
                  }
                },
              ),
              ListTile(
                leading: Icon(
                  isIgnored ? Icons.visibility : Icons.visibility_off,
                ),
                title: TranslatedText(
                  isIgnored ? 'unignore_file' : 'ignore_file',
                ),
                onTap: () async {
                  Navigator.of(context).pop();
                  if (isIgnored) {
                    await unignoreSong(song.data);
                  } else {
                    await ignoreSong(song.data);
                  }
                  if (mounted) setState(() {});
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: TranslatedText('delete_from_device'),
                onTap: () async {
                  Navigator.of(context).pop();
                  final success = await _deleteSongFromDevice(song);
                  if (!success && context.mounted) {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: TranslatedText('error'),
                        content: TranslatedText('could_not_delete_song'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: TranslatedText('ok'),
                          ),
                        ],
                      ),
                    );
                  }
                },
              ),
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

  // Para reproducir y abrir PlayerScreen:
  Future<void> _playSongAndOpenPlayer(String path) async {
    final ignored = await getIgnoredSongs();
    final filtered = _filteredSongs
        .where((s) => !ignored.contains(s.data))
        .toList();
    final index = filtered.indexWhere((s) => s.data == path);
    if (index != -1) {
      final song = filtered[index];

      // Obtener la carátula para la pantalla del reproductor
      final songId = song.id;
      final songPath = song.data;
      final artUri = await getOrCacheArtwork(songId, songPath);

      // Crear el MediaItem para la pantalla del reproductor
      final mediaItem = MediaItem(
        id: song.data,
        title: song.title,
        artist: song.artist,
        duration: (song.duration != null && song.duration! > 0)
            ? Duration(milliseconds: song.duration!)
            : null,
        artUri: artUri,
        extras: {'songId': song.id, 'albumId': song.albumId, 'data': song.data},
      );

      // Navegar a la pantalla del reproductor primero
      if (!mounted) return;
      Navigator.of(context).push(
        PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) =>
              FullPlayerScreen(initialMediaItem: mediaItem),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return SlideTransition(
              position:
                  Tween<Offset>(
                    begin: const Offset(0, 1),
                    end: Offset.zero,
                  ).animate(
                    CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOutCubic,
                    ),
                  ),
              child: child,
            );
          },
          transitionDuration: const Duration(milliseconds: 350),
        ),
      );

      // Activar indicador de carga
      playLoadingNotifier.value = true;

      // Reproducir la canción después de un breve delay para que se abra la pantalla
      Future.delayed(const Duration(milliseconds: 400), () {
        if (mounted) {
          _playSong(path);
          Future.delayed(const Duration(milliseconds: 200), () {
            // Desactivar indicador de carga después de reproducir
            playLoadingNotifier.value = false;
          });
        }
      });
    }
  }

  // Para reproducir:
  Future<void> _playSong(String path) async {
    final ignored = await getIgnoredSongs();
    final filtered = _filteredSongs
        .where((s) => !ignored.contains(s.data))
        .toList();
    final index = filtered.indexWhere((s) => s.data == path);
    if (index != -1) {
      final handler = audioHandler as MyAudioHandler;
      // Guardar solo el nombre de la carpeta como origen
      final prefs = await SharedPreferences.getInstance();
      String origen;
      if (carpetaSeleccionada != null) {
        final parts = carpetaSeleccionada!.split(RegExp(r'[\\/]'));
        origen = parts.isNotEmpty ? parts.last : carpetaSeleccionada!;
      } else {
        origen = "Carpeta";
      }
      await prefs.setString('last_queue_source', origen);
      // Comprobar si la cola actual es igual a la nueva (por ids y orden)
      final currentQueue = handler.queue.value;
      final isSameQueue =
          currentQueue.length == filtered.length &&
          List.generate(
            filtered.length,
            (i) => currentQueue[i].id == filtered[i].data,
          ).every((x) => x);

      if (isSameQueue) {
        await handler.skipToQueueItem(index);
        await handler.play();
        return;
      }

      // Limpiar la cola y el MediaItem antes de mostrar la nueva canción
      handler.queue.add([]);
      handler.mediaItem.add(null);

      // Crear MediaItem temporal para mostrar el overlay inmediatamente
      final song = filtered[index];

      // Precargar la carátula antes de crear el MediaItem temporal
      Uri? cachedArtUri;
      try {
        cachedArtUri = await getOrCacheArtwork(song.id, song.data);
      } catch (e) {
        // Si falla, continuar sin carátula
      }

      final tempMediaItem = MediaItem(
        id: song.data,
        album: song.album ?? '',
        title: song.title,
        artist: song.artist ?? '',
        duration: (song.duration != null && song.duration! > 0)
            ? Duration(milliseconds: song.duration!)
            : null,
        artUri: cachedArtUri,
        extras: {
          'songId': song.id,
          'albumId': song.albumId,
          'data': song.data,
          'queueIndex': 0,
        },
      );
      handler.mediaItem.add(tempMediaItem);

      await handler.setQueueFromSongs(filtered, initialIndex: index);
      await handler.play();
    }
  }

  Future<bool> _deleteSongFromDevice(SongModel song) async {
    try {
      final file = File(song.data);
      if (await file.exists()) {
        // Si está reproduciéndose esta canción, pasar a la siguiente antes de borrar
        try {
          final handler = audioHandler as MyAudioHandler;
          final current = handler.mediaItem.valueOrNull;
          final isCurrent =
              current?.id == song.data || current?.extras?['data'] == song.data;
          if (isCurrent) {
            // Quitar de la cola priorizando saltar a la siguiente
            await handler.removeSongByPath(song.data);
          } else {
            // Quitarla de la cola si estuviera presente
            await handler.removeSongByPath(song.data);
          }
        } catch (_) {}

        await file.delete();

        // Limpiar caches relacionadas con la canción borrada
        try {
          removeArtworkFromCache(song.data);
        } catch (_) {}

        // Limpiar persistencias: favoritos, recientes, atajos y playlists
        try {
          await FavoritesDB().removeFavorite(song.data);
        } catch (_) {}
        try {
          await RecentsDB().removeRecent(song.data);
        } catch (_) {}
        try {
          if (await ShortcutsDB().isShortcut(song.data)) {
            await ShortcutsDB().removeShortcut(song.data);
          }
        } catch (_) {}
        try {
          final playlists = await PlaylistsDB().getAllPlaylists();
          for (final p in playlists) {
            if (p.songPaths.contains(song.data)) {
              await PlaylistsDB().removeSongFromPlaylist(p.id, song.data);
            }
          }
        } catch (_) {}

        // Sincronizar índice de canciones (por si quedó rastro)
        try {
          await SongsIndexDB().cleanNonExistentFiles();
        } catch (_) {}

        if (carpetaSeleccionada != null) {
          setState(() {
            _originalSongs.removeWhere((s) => s.data == song.data);
            _filteredSongs.removeWhere((s) => s.data == song.data);
            _displaySongs.removeWhere((s) => s.data == song.data);
            // También actualiza el mapa de paths
            songPathsByFolder[carpetaSeleccionada!]?.removeWhere(
              (path) => path == song.data,
            );
          });
        }

        // Notificar a otras pantallas que deben refrescar
        try {
          favoritesShouldReload.value = !favoritesShouldReload.value;
          playlistsShouldReload.value = !playlistsShouldReload.value;
          recentsShouldReload.value = !recentsShouldReload.value;
          shortcutsShouldReload.value = !shortcutsShouldReload.value;
        } catch (_) {}

        return true;
      }
      return false;
    } catch (e) {
      return false;
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

  String _formatArtistWithDuration(SongModel song) {
    final artist = (song.artist == null || song.artist!.trim().isEmpty)
        ? LocaleProvider.tr('unknown_artist')
        : song.artist!;

    if (song.duration != null && song.duration! > 0) {
      final duration = Duration(milliseconds: song.duration!);
      final hours = duration.inHours;
      final minutes = duration.inMinutes % 60;
      final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');

      String durationString;
      if (hours > 0) {
        durationString =
            '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:$seconds';
      } else {
        durationString = '$minutes:$seconds';
      }

      return '$artist • $durationString';
    }

    return artist;
  }

  Future<void> _preloadArtworksForSongs(List<SongModel> songs) async {
    try {
      for (final song in songs.take(20)) {
        // Usar el sistema de caché del MyAudioHandler en lugar de OnAudioQuery directamente
        unawaited(getOrCacheArtwork(song.id, song.data));
      }
    } catch (e) {
      // Ignorar errores de precarga
    }
  }

  void _onSongSelected(SongModel song) {
    try {
      (audioHandler as MyAudioHandler).isShuffleNotifier.value = false;
    } catch (_) {}
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

    // Precargar la carátula antes de mostrar el overlay
    unawaited(_preloadArtworkForSong(song));
    _playSongAndOpenPlayer(song.data);
  }

  Future<void> _preloadArtworkForSong(SongModel song) async {
    try {
      // Cargar la carátula inmediatamente
      await getOrCacheArtwork(song.id, song.data);
    } catch (e) {
      // Ignorar errores de precarga
    }
  }

  Future<void> _addToFavorites(SongModel song) async {
    await FavoritesDB().addFavorite(song);
  }

  // Añadir función auxiliar para ordenar por fecha de edición
  Future<void> _sortByFileDate(
    List<SongModel> lista, {
    required bool ascending,
  }) async {
    final dates = <String, DateTime>{};
    for (final song in lista) {
      try {
        dates[song.data] = await File(song.data).lastModified();
      } catch (_) {
        dates[song.data] = DateTime.fromMillisecondsSinceEpoch(0);
      }
    }
    lista.sort((a, b) {
      final dateA = dates[a.data]!;
      final dateB = dates[b.data]!;
      return ascending ? dateA.compareTo(dateB) : dateB.compareTo(dateA);
    });
  }

  // Modificar _aplicarOrdenamiento para soportar los nuevos tipos
  Future<void> _aplicarOrdenamiento(List<SongModel> lista) async {
    switch (_orden) {
      case OrdenCarpetas.normal:
        break;
      case OrdenCarpetas.alfabetico:
        lista.sort((a, b) => a.title.compareTo(b.title));
        break;
      case OrdenCarpetas.invertido:
        lista.sort((a, b) => b.title.compareTo(a.title));
        break;
      case OrdenCarpetas.ultimoAgregado:
        lista.sort((a, b) {
          final indexA = _originalSongs.indexOf(a);
          final indexB = _originalSongs.indexOf(b);
          return indexB.compareTo(indexA);
        });
        break;
      case OrdenCarpetas.fechaEdicionAsc:
        await _sortByFileDate(lista, ascending: true);
        break;
      case OrdenCarpetas.fechaEdicionDesc:
        await _sortByFileDate(lista, ascending: false);
        break;
    }
  }

  // Modificar _ordenarCanciones y _onSearchChanged para ser async y esperar el ordenamiento
  Future<void> _ordenarCanciones() async {
    await _aplicarOrdenamiento(_filteredSongs);
    _saveOrderFilter();
    await _onSearchChanged();
  }

  Future<void> _onSearchChanged() async {
    final query = quitarDiacriticos(_searchController.text.toLowerCase());
    final allSongsOrdered = List<SongModel>.from(_originalSongs);
    await _aplicarOrdenamiento(allSongsOrdered);
    _filteredSongs = allSongsOrdered;

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

  // Función para construir la carátula del modal
  Widget _buildModalArtwork(SongModel song) {
    return QueryArtworkWidget(
      id: song.id,
      type: ArtworkType.AUDIO,
      artworkBorder: BorderRadius.circular(8),
      artworkHeight: 60,
      artworkWidth: 60,
      keepOldArtwork: true,
      nullArtworkWidget: Container(
        width: 60,
        height: 60,
        decoration: BoxDecoration(
          color: Colors.grey[800],
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.music_note, color: Colors.grey[400], size: 30),
      ),
    );
  }

  // Función para buscar la canción en YouTube
  Future<void> _searchSongOnYouTube(SongModel song) async {
    try {
      final title = song.title;
      final artist = song.artist ?? '';

      // Crear la consulta de búsqueda
      String searchQuery = title;
      if (artist.isNotEmpty) {
        searchQuery = '$artist $title';
      }

      // Codificar la consulta para la URL
      final encodedQuery = Uri.encodeComponent(searchQuery);
      final youtubeSearchUrl =
          'https://www.youtube.com/results?search_query=$encodedQuery';

      // Intentar abrir YouTube en el navegador o en la app
      final url = Uri.parse(youtubeSearchUrl);

      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } else {
        // ignore: use_build_context_synchronously
      }
    } catch (e) {
      // ignore: avoid_print
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _playingDebounce?.cancel();
    _mediaItemDebounce?.cancel();
    _immediateMediaItemDebounce?.cancel();
    _isPlayingNotifier.dispose();
    _currentMediaItemNotifier.dispose();
    _immediateMediaItemNotifier.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _scrollController.dispose();
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
              Icon(
                Icons.folder_off,
                size: 48,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
              const SizedBox(height: 16),
              TranslatedText(
                'no_folders_with_songs',
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
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
          body: ValueListenableBuilder<MediaItem?>(
            valueListenable: _currentMediaItemNotifier,
            builder: (context, current, child) {
              final space = current != null ? 100.0 : 0.0;
              return Padding(
                padding: EdgeInsets.only(bottom: space),
                child: ListView.builder(
                  itemCount: songPathsByFolder.length,
                  itemBuilder: (context, i) {
                    final sortedEntries = songPathsByFolder.entries.toList()
                      ..sort(
                        (a, b) =>
                            folderDisplayNames[a.key]!.toLowerCase().compareTo(
                              folderDisplayNames[b.key]!.toLowerCase(),
                            ),
                      );
                    final entry = sortedEntries[i];
                    final nombre = folderDisplayNames[entry.key]!;
                    final canciones = entry.value;

                    return ListTile(
                      leading: const Icon(Icons.folder, size: 38),
                      title: Text(
                        nombre,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${canciones.length} ${LocaleProvider.tr('songs')}',
                      ),
                      onTap: () async {
                        await _loadSongsForFolder(entry);
                      },
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) async {
                          if (value == 'delete') {
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: TranslatedText('delete_folder'),
                                content: TranslatedText(
                                  'delete_folder_confirm',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(context).pop(false),
                                    child: TranslatedText('cancel'),
                                  ),
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(context).pop(true),
                                    child: TranslatedText('delete'),
                                  ),
                                ],
                              ),
                            );
                            if (confirmed == true) {
                              final success = await _deleteFolderAndSongs(
                                entry.key,
                              );
                              if (!success && context.mounted) {
                                showDialog(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: TranslatedText('error'),
                                    content: TranslatedText(
                                      'could_not_delete_folder',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.of(context).pop(),
                                        child: TranslatedText('ok'),
                                      ),
                                    ],
                                  ),
                                );
                              }
                            }
                          }
                        },
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            value: 'delete',
                            child: Row(
                              children: [
                                Icon(Icons.delete_outline),
                                SizedBox(width: 8),
                                TranslatedText('delete_folder'),
                              ],
                            ),
                          ),
                        ],
                      ),
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
                ? Text(
                    '${_selectedSongPaths.length} ${LocaleProvider.tr('selected')}',
                  )
                : Text(
                    folderDisplayNames[carpetaSeleccionada] ??
                        LocaleProvider.tr('folders'),
                  ),
            actions: [
              if (_isSelecting) ...[
                IconButton(
                  icon: const Icon(Icons.favorite_outline),
                  tooltip: LocaleProvider.tr('add_to_favorites'),
                  onPressed: _selectedSongPaths.isEmpty
                      ? null
                      : () async {
                          // Acción masiva: añadir a favoritos
                          final selectedSongs = _displaySongs.where(
                            (s) => _selectedSongPaths.contains(s.data),
                          );
                          for (final song in selectedSongs) {
                            await _addToFavorites(song);
                          }
                          favoritesShouldReload.value =
                              !favoritesShouldReload.value;
                          setState(() {
                            _isSelecting = false;
                            _selectedSongPaths.clear();
                          });
                        },
                ),
                IconButton(
                  icon: const Icon(Icons.playlist_add),
                  tooltip: LocaleProvider.tr('add_to_playlist'),
                  onPressed: _selectedSongPaths.isEmpty
                      ? null
                      : () async {
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
                        _selectedSongPaths.addAll(
                          _displaySongs.map((s) => s.data),
                        );
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
                      unawaited(_preloadArtworkForSong(random));
                      _playSongAndOpenPlayer(random.data);
                    }
                  },
                ),
                PopupMenuButton<OrdenCarpetas>(
                  icon: const Icon(Icons.sort, size: 28),
                  onSelected: (orden) async {
                    setState(() {
                      _orden = orden;
                    });
                    await _ordenarCanciones();
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
                    PopupMenuItem(
                      value: OrdenCarpetas.fechaEdicionDesc,
                      child: TranslatedText('edit_date_newest_first'),
                    ),
                    PopupMenuItem(
                      value: OrdenCarpetas.fechaEdicionAsc,
                      child: TranslatedText('edit_date_oldest_first'),
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
                        hintText: LocaleProvider.tr(
                          'search_by_title_or_artist',
                        ),
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _searchController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.close),
                                onPressed: () {
                                  _searchController.clear();
                                  _onSearchChanged();
                                  setState(() {});
                                },
                              )
                            : null,
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
          body: ValueListenableBuilder<MediaItem?>(
            valueListenable: _currentMediaItemNotifier,
            builder: (context, debouncedMediaItem, child) {
              // Detectar si el tema AMOLED está activo
              final isAmoledTheme =
                  colorSchemeNotifier.value == AppColorScheme.amoled;
              final space = debouncedMediaItem != null ? 100.0 : 0.0;

              return Padding(
                padding: EdgeInsets.only(bottom: space),
                child: _filteredSongs.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.folder_off,
                              size: 48,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurface.withValues(alpha: 0.6),
                            ),
                            const SizedBox(height: 16),
                            TranslatedText(
                              'no_songs_in_folder',
                              style: TextStyle(
                                fontSize: 14,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withValues(alpha: 0.6),
                              ),
                            ),
                          ],
                        ),
                      )
                    : ValueListenableBuilder<MediaItem?>(
                        valueListenable: _immediateMediaItemNotifier,
                        builder: (context, immediateMediaItem, child) {
                          return ListView.builder(
                            controller: _scrollController,
                            itemCount: _displaySongs.length,
                            itemBuilder: (context, i) {
                              final song = _displaySongs[i];
                              final path = song.data;
                              final isCurrent =
                                  (immediateMediaItem?.id != null &&
                                  path.isNotEmpty &&
                                  (immediateMediaItem!.id == path ||
                                      immediateMediaItem.extras?['data'] ==
                                          path));
                              final isSelected = _selectedSongPaths.contains(
                                path,
                              );
                              final isIgnoredFuture = isSongIgnored(path);
                              return FutureBuilder<bool>(
                                future: isIgnoredFuture,
                                builder: (context, snapshot) {
                                  final isIgnored = snapshot.data ?? false;

                                  // Solo usar ValueListenableBuilder para la canción actual
                                  if (isCurrent) {
                                    return ValueListenableBuilder<bool>(
                                      valueListenable: _isPlayingNotifier,
                                      builder: (context, playing, child) {
                                        return _buildOptimizedListTile(
                                          context,
                                          song,
                                          isCurrent,
                                          playing,
                                          isAmoledTheme,
                                          isIgnored,
                                          isSelected,
                                        );
                                      },
                                    );
                                  } else {
                                    // Para canciones que no están reproduciéndose, no usar StreamBuilder
                                    return _buildOptimizedListTile(
                                      context,
                                      song,
                                      isCurrent,
                                      false, // No playing
                                      isAmoledTheme,
                                      isIgnored,
                                      isSelected,
                                    );
                                  }
                                },
                              );
                            },
                          );
                        },
                      ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildOptimizedListTile(
    BuildContext context,
    SongModel song,
    bool isCurrent,
    bool playing,
    bool isAmoledTheme,
    bool isIgnored,
    bool isSelected,
  ) {
    final path = song.data;
    final opacity = isIgnored ? 0.4 : 1.0;

    return Opacity(
      opacity: opacity,
      child: ListTile(
        onTap: isIgnored ? null : () => _onSongSelected(song),
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
              child: Opacity(
                opacity: opacity,
                child: QueryArtworkWidget(
                  id: song.id,
                  type: ArtworkType.AUDIO,
                  artworkBorder: BorderRadius.circular(8),
                  artworkHeight: 50,
                  artworkWidth: 50,
                  keepOldArtwork: true,
                  nullArtworkWidget: Container(
                    color: Theme.of(context).colorScheme.surfaceContainer,
                    width: 50,
                    height: 50,
                    child: Icon(
                      Icons.music_note,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        title: Opacity(
          opacity: opacity,
          child: Row(
            children: [
              if (isCurrent)
                Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: MiniMusicVisualizer(
                    color: Theme.of(context).colorScheme.primary,
                    width: 4,
                    height: 15,
                    radius: 4,
                    animate: playing ? true : false,
                  ),
                ),
              Expanded(
                child: Text(
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
              ),
            ],
          ),
        ),
        subtitle: Opacity(
          opacity: opacity,
          child: Text(
            _formatArtistWithDuration(song),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        trailing: !_isSelecting
            ? IconButton(
                icon: Icon(
                  isCurrent
                      ? (playing ? Icons.pause : Icons.play_arrow)
                      : Icons.play_arrow,
                  color: isCurrent
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                onPressed: isIgnored
                    ? null
                    : () {
                        if (isCurrent) {
                          playing
                              ? (audioHandler as MyAudioHandler).pause()
                              : (audioHandler as MyAudioHandler).play();
                        } else {
                          _onSongSelected(song);
                        }
                      },
              )
            : null,
        selected: isCurrent,
        selectedTileColor: isAmoledTheme
            ? Colors.white.withValues(alpha: 0.1)
            : Theme.of(context).colorScheme.primaryContainer,
      ),
    );
  }

  Future<void> _handleAddToPlaylistMassive(BuildContext context) async {
    final playlists = await PlaylistsDB()
        .getAllPlaylists(); // List<PlaylistModel>
    if (!context.mounted) return;
    final TextEditingController playlistNameController =
        TextEditingController();
    final selectedPlaylistId = await showDialog<String>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) => SimpleDialog(
            title: TranslatedText('select_playlist'),
            children: [
              if (playlists.isNotEmpty) ...[
                for (final playlist in playlists)
                  SimpleDialogOption(
                    onPressed: () {
                      Navigator.of(context).pop(playlist.id);
                    },
                    child: Text(playlist.name),
                  ),
                const Divider(),
              ],
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
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
                  setStateDialog(() {
                    playlists.insert(
                      0,
                      hive_model.PlaylistModel(
                        id: id,
                        name: name,
                        songPaths: [],
                      ),
                    );
                  });
                  playlistNameController.clear();

                  // Notificar a la pantalla de inicio que debe actualizar las playlists
                  playlistsShouldReload.value = !playlistsShouldReload.value;

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
      final selectedSongs = _displaySongs.where(
        (s) => _selectedSongPaths.contains(s.data),
      );
      for (final song in selectedSongs) {
        await PlaylistsDB().addSongToPlaylist(selectedPlaylistId, song);
      }
      setState(() {
        _isSelecting = false;
        _selectedSongPaths.clear();
      });

      // Notificar a la pantalla de inicio que debe actualizar las playlists
      playlistsShouldReload.value = !playlistsShouldReload.value;
    }
  }

  Future<void> _handleAddToPlaylistSingle(
    BuildContext context,
    SongModel song,
  ) async {
    final playlists = await PlaylistsDB()
        .getAllPlaylists(); // List<PlaylistModel>
    if (!context.mounted) return;
    final TextEditingController playlistNameController =
        TextEditingController();
    final selectedPlaylistId = await showDialog<String>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) => SimpleDialog(
            title: TranslatedText('select_playlist'),
            children: [
              if (playlists.isNotEmpty) ...[
                for (final playlist in playlists)
                  SimpleDialogOption(
                    onPressed: () {
                      Navigator.of(context).pop(playlist.id);
                    },
                    child: Text(playlist.name),
                  ),
                const Divider(),
              ],
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
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
                  setStateDialog(() {
                    playlists.insert(
                      0,
                      hive_model.PlaylistModel(
                        id: id,
                        name: name,
                        songPaths: [],
                      ),
                    );
                  });
                  playlistNameController.clear();

                  // Notificar a la pantalla de inicio que debe actualizar las playlists
                  playlistsShouldReload.value = !playlistsShouldReload.value;

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

      // Notificar a la pantalla de inicio que debe actualizar las playlists
      playlistsShouldReload.value = !playlistsShouldReload.value;
    }
  }

  Future<bool> _deleteFolderAndSongs(String folderKey) async {
    try {
      final songPaths = songPathsByFolder[folderKey] ?? [];
      bool allDeleted = true;
      // Primero retirar todas las canciones de la cola (maneja salto si alguna es la actual)
      try {
        final handler = audioHandler as MyAudioHandler;
        await handler.removeSongsByPath(List<String>.from(songPaths));
      } catch (_) {}

      for (final path in songPaths) {
        final file = File(path);
        if (await file.exists()) {
          try {
            await file.delete();
          } catch (_) {
            allDeleted = false;
          }
        }
        // Limpiar por cada path
        try {
          removeArtworkFromCache(path);
        } catch (_) {}
        try {
          await FavoritesDB().removeFavorite(path);
        } catch (_) {}
        try {
          await RecentsDB().removeRecent(path);
        } catch (_) {}
        try {
          if (await ShortcutsDB().isShortcut(path)) {
            await ShortcutsDB().removeShortcut(path);
          }
        } catch (_) {}
      }
      // Limpiar de todas las playlists en una sola pasada
      try {
        final playlists = await PlaylistsDB().getAllPlaylists();
        for (final p in playlists) {
          final toRemove = p.songPaths
              .where((sp) => songPaths.contains(sp))
              .toList();
          for (final sp in toRemove) {
            await PlaylistsDB().removeSongFromPlaylist(p.id, sp);
          }
        }
      } catch (_) {}
      // Sincronizar índice
      try {
        await SongsIndexDB().cleanNonExistentFiles();
      } catch (_) {}
      setState(() {
        songPathsByFolder.remove(folderKey);
        folderDisplayNames.remove(folderKey);
      });

      // Notificar a otras pantallas
      try {
        favoritesShouldReload.value = !favoritesShouldReload.value;
        playlistsShouldReload.value = !playlistsShouldReload.value;
        recentsShouldReload.value = !recentsShouldReload.value;
        shortcutsShouldReload.value = !shortcutsShouldReload.value;
      } catch (_) {}
      return allDeleted;
    } catch (e) {
      return false;
    }
  }

  // Nueva función para cargar canciones de una carpeta con spinner
  Future<void> _loadSongsForFolder(MapEntry<String, List<String>> entry) async {
    setState(() {
      carpetaSeleccionada = entry.key;
      _searchController.clear();
      _isSelecting = false;
      _selectedSongPaths.clear();
      _originalSongs = [];
      _filteredSongs = [];
      _displaySongs = [];
      _isLoading = true;
    });

    // Sincronizar mapa de carpetas antes de cargar (por si hay canciones nuevas)
    await _sincronizarMapaCarpetas();

    // Usar las rutas actualizadas después de la sincronización
    final updatedPaths = songPathsByFolder[entry.key] ?? entry.value;

    // Actualizar los notifiers con los valores actuales del audioHandler
    if (audioHandler?.mediaItem.valueOrNull != null) {
      // Cancelar el debounce para evitar conflictos
      _immediateMediaItemDebounce?.cancel();
      _mediaItemDebounce?.cancel();
      _immediateMediaItemNotifier.value = audioHandler!.mediaItem.valueOrNull;
      _currentMediaItemNotifier.value = audioHandler!.mediaItem.valueOrNull;
    }
    if (audioHandler?.playbackState.valueOrNull != null) {
      _isPlayingNotifier.value =
          audioHandler!.playbackState.valueOrNull!.playing;
    }

    // Cargar los objetos SongModel completos con las rutas actualizadas
    final allSongs = await _audioQuery.querySongs();
    final songsInFolder = allSongs
        .where((s) => updatedPaths.contains(s.data))
        .toList();
    setState(() {
      _originalSongs = songsInFolder;
    });
    await _ordenarCanciones();
    // Precargar carátulas de las canciones en la carpeta
    unawaited(_preloadArtworksForSongs(songsInFolder));
    setState(() {
      _isLoading = false;
    });
  }

  // Soporte para pop interno desde el handler global
  bool canPopInternally() {
    return carpetaSeleccionada != null;
  }

  void handleInternalPop() {
    setState(() {
      carpetaSeleccionada = null;
    });
  }
}
