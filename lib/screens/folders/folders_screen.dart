import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:on_audio_query/on_audio_query.dart';
import 'package:music/main.dart';
import 'package:audio_service/audio_service.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'package:music/utils/db/favorites_db.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/screens/edit/edit_metadata_screen.dart';
// import 'package:music/screens/convert/audio_conversion_screen.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:music/utils/db/playlists_db.dart';
import 'package:music/utils/db/songs_index_db.dart';
import 'package:music/utils/db/recent_db.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:music/utils/db/shortcuts_db.dart';
import 'package:music/utils/db/mostplayer_db.dart';
import 'package:music/screens/artist/artist_screen.dart';
import 'package:mini_music_visualizer/mini_music_visualizer.dart';
import 'package:music/screens/play/player_screen.dart';
import 'package:music/widgets/hero_cached.dart';
import 'package:music/utils/db/playlist_model.dart' as hive_model;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:media_scanner/media_scanner.dart';
import 'package:music/widgets/song_info_dialog.dart';
import 'package:device_info_plus/device_info_plus.dart';

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
  
  // Cache de carpetas ignoradas para evitar parpadeos
  Set<String> _ignoredFoldersCache = {};
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

  // Variables para búsqueda de carpetas
  final TextEditingController _folderSearchController = TextEditingController();
  final FocusNode _folderSearchFocusNode = FocusNode();
  List<MapEntry<String, List<String>>> _filteredFolders = [];

  double _lastBottomInset = 0.0;

  bool _isLoading = true;
  
  // Variable para verificar si estamos en Android 10+
  bool _isAndroid10OrHigher = false;

  static const String _orderPrefsKey = 'folders_screen_order_filter';
  static const String _pinnedSongsKey = 'pinned_songs';
  static const String _ignoredSongsKey = 'ignored_songs';
  static const String _ignoredFoldersKey = 'ignored_folders';

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

  // Utilidades para gestionar carpetas ignoradas
  Future<List<String>> getIgnoredFolders() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_ignoredFoldersKey) ?? [];
  }

  Future<bool> isFolderIgnored(String folderPath) async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getStringList(_ignoredFoldersKey) ?? [];
    return current.contains(folderPath);
  }

  Future<void> ignoreFolder(String folderPath) async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getStringList(_ignoredFoldersKey) ?? [];
    if (!current.contains(folderPath)) {
      current.add(folderPath);
      await prefs.setStringList(_ignoredFoldersKey, current);
    }
  }

  Future<void> unignoreFolder(String folderPath) async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getStringList(_ignoredFoldersKey) ?? [];
    current.remove(folderPath);
    await prefs.setStringList(_ignoredFoldersKey, current);
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

  /// Función específica para refrescar el contenido de la carpeta actual
  Future<void> _refreshCurrentFolder() async {
    if (carpetaSeleccionada != null) {
      // Sincronizar el índice de carpetas
      await _sincronizarMapaCarpetas();
      
      // Actualizar solo la carpeta actual
      await _actualizarCarpetaActual();
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
          final originalFolderName = await _getOriginalFolderName(folder);
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
    _checkAndroidVersion();
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

  // Verificar versión de Android
  Future<void> _checkAndroidVersion() async {
    if (Platform.isAndroid) {
      try {
        final deviceInfo = DeviceInfoPlugin();
        final androidInfo = await deviceInfo.androidInfo;
        // Android 10 = API level 29
        if (mounted) {
          setState(() {
            _isAndroid10OrHigher = (androidInfo.version.sdkInt >= 29);
          });
        }
      } catch (e) {
        // En caso de error, asumir que no es Android 10+
        if (mounted) {
          setState(() {
            _isAndroid10OrHigher = false;
          });
        }
      }
    }
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
    if (!mounted) return;
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
    // Incluir también carpetas ignoradas para poder restaurarlas
    final ignored = await getIgnoredFolders();
    
    // Cargar cache de carpetas ignoradas para evitar parpadeos
    _ignoredFoldersCache = Set<String>.from(ignored);
    
    final allFolderKeys = {
      ...folders,
      ...ignored,
    };
    final Map<String, List<String>> agrupado = {};
    final Map<String, String> displayNames = {};
    for (final folder in allFolderKeys) {
      final paths = await SongsIndexDB().getSongsFromFolder(folder);
      if (paths.isNotEmpty) {
        agrupado[folder] = paths;
        // Obtener el nombre original de la carpeta sin normalizar
        final originalFolderName = await _getOriginalFolderName(folder);
        displayNames[folder] = originalFolderName;
      } else {
        // Si la carpeta está ignorada pero no tiene canciones en el índice,
        // igual la mostramos con 0 canciones para poder restaurarla.
        if (ignored.contains(folder)) {
          agrupado[folder] = [];
          final originalFolderName = await _getOriginalFolderName(folder);
          displayNames[folder] = originalFolderName.isNotEmpty
              ? originalFolderName
              : folder.split(RegExp(r'[\\/]')).last;
        }
      }
    }
    if (!mounted) return;
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
  Future<String> _getOriginalFolderName(String normalizedFolderPath) async {
    // Buscar en las canciones de esta carpeta para obtener el nombre real
    final paths = songPathsByFolder[normalizedFolderPath] ?? [];
    if (paths.isNotEmpty) {
      // Usar la primera canción para obtener el directorio real
      try {
        final firstSongPath = paths.first;
        final directory = Directory(p.dirname(firstSongPath));
        return directory.path.split(RegExp(r'[\\/]')).last;
      } catch (e) {
        // Fallback: usar el último segmento de la ruta normalizada
        final segments = normalizedFolderPath.split(RegExp(r'[\\/]'));
        return segments.last;
      }
    }
    
    // Si no hay canciones en songPathsByFolder, intentar obtenerlas directamente
    try {
      final paths = await SongsIndexDB().getSongsFromFolder(normalizedFolderPath);
      if (paths.isNotEmpty) {
        final firstSongPath = paths.first;
        final directory = Directory(p.dirname(firstSongPath));
        return directory.path.split(RegExp(r'[\\/]')).last;
      }
    } catch (e) {
      // Fallback: usar el último segmento de la ruta normalizada
    }
    
    // Fallback: usar el último segmento de la ruta normalizada
    final segments = normalizedFolderPath.split(RegExp(r'[\\/]'));
    return segments.last;
  }

  void _handleLongPress(BuildContext context, SongModel song) async {
    final isFavorite = await FavoritesDB().isFavorite(song.data);
    final isPinned = await ShortcutsDB().isShortcut(song.data);
    final isIgnored = await isSongIgnored(song.data);

    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) {
        final maxHeight = MediaQuery.of(context).size.height - MediaQuery.of(context).padding.top;
        return Container(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: SafeArea(
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
                                            // Botón para buscar la canción en YouTube o YouTube Music
                        GestureDetector(
                          onTap: () async {
                            Navigator.of(context).pop();
                            await _showSearchOptions(song);
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).brightness == Brightness.dark
                              ? Theme.of(context).colorScheme.primaryContainer
                              : Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.7),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.search,
                                  size: 20,
                                  color: Theme.of(
                                    context,
                                  ).brightness == Brightness.dark
                                  ? Theme.of(context).colorScheme.onPrimaryContainer
                                  : Theme.of(context).colorScheme.surfaceContainer,
                                ),
                                const SizedBox(width: 8),
                                TranslatedText(
                                  'search',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14,
                                    color: Theme.of(
                                      context,
                                    ).brightness == Brightness.dark
                                    ? Theme.of(context).colorScheme.onPrimaryContainer
                                    : Theme.of(context).colorScheme.surfaceContainer,
                                  ),
                                ),
                              ],
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
                      isFavorite ? Icons.delete_outline : Symbols.favorite_rounded,
                      weight: isFavorite ? null : 600,
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
                  
                  // Botón "Más" para mostrar opciones adicionales
                  ListTile(
                    leading: const Icon(Icons.more_horiz),
                    title: TranslatedText('more'),
                    onTap: () {
                      Navigator.of(context).pop();
                      _showMoreOptionsModal(context, song, isPinned, isIgnored);
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showMoreOptionsModal(BuildContext context, SongModel song, bool isPinned, bool isIgnored) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) {
        final maxHeight = MediaQuery.of(context).size.height - MediaQuery.of(context).padding.top;
        return Container(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: SafeArea(
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
                        // Botón para cerrar
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                  
                  // Opciones adicionales
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
                  if ((song.artist ?? '').trim().isNotEmpty)
                    ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: const TranslatedText('go_to_artist'),
                      onTap: () {
                        Navigator.of(context).pop();
                        final name = (song.artist ?? '').trim();
                        if (name.isEmpty) return;
                        Navigator.of(context).push(
                          PageRouteBuilder(
                            pageBuilder: (context, animation, secondaryAnimation) =>
                                ArtistScreen(artistName: name),
                            transitionsBuilder: (context, animation, secondaryAnimation, child) {
                              const begin = Offset(1.0, 0.0);
                              const end = Offset.zero;
                              const curve = Curves.ease;
                              final tween = Tween(
                                begin: begin,
                                end: end,
                              ).chain(CurveTween(curve: curve));
                              return SlideTransition(
                                position: animation.drive(tween),
                                child: child,
                              );
                            },
                          ),
                        );
                      },
                    ),
                  ListTile(
                    leading: const Icon(Icons.edit),
                    title: TranslatedText('edit_metadata'),
                    onTap: () async {
                      Navigator.of(context).pop();
                      await _navigateToEditScreen(songToMediaItem(song));
                    },
                  ),
                  if (_isAndroid10OrHigher)
                    ListTile(
                      leading: const Icon(Icons.drive_file_move),
                      title: TranslatedText('move_to_folder'),
                      onTap: () async {
                        Navigator.of(context).pop();
                        await _showFolderSelector(song, isMove: true);
                      },
                    ),
                  if (_isAndroid10OrHigher)
                    ListTile(
                      leading: const Icon(Icons.copy),
                      title: TranslatedText('copy_to_folder'),
                      onTap: () async {
                        Navigator.of(context).pop();
                        await _showFolderSelector(song, isMove: false);
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
                      await _showDeleteConfirmation(song);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: TranslatedText('song_info'),
                    onTap: () async {
                      Navigator.of(context).pop();
                      await SongInfoDialog.showFromSong(context, song, colorSchemeNotifier);
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  MediaItem songToMediaItem(SongModel song) {
    return MediaItem(
      id: song.data, // Usar la ruta del archivo como ID para AudioTags
      album: song.album ?? LocaleProvider.tr('unknown_artist'),
      title: song.title,
      artist: song.artist ?? LocaleProvider.tr('unknown_artist'),
      artUri: song.uri != null ? Uri.parse(song.uri!) : null,
      extras: {'data': song.data, 'db_id': song.id.toString()},
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
      
      // Limpiar el fallback de las carátulas para evitar parpadeo
      ArtworkHeroCached.clearFallback();

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

        // Notificar al MediaStore de Android que el archivo fue eliminado
        try {
          await MediaScanner.loadMedia(path: song.data);
        } catch (_) {}

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

  // Función para filtrar carpetas
  void _onFolderSearchChanged() async {
    final query = quitarDiacriticos(_folderSearchController.text.toLowerCase());
    if (query.isEmpty) {
      if (!mounted) return;
      setState(() {
        _filteredFolders = [];
      });
      return;
    }

    // Buscar en nombres de carpetas
    final folderMatches = songPathsByFolder.entries.where((entry) {
      final folderName = quitarDiacriticos(folderDisplayNames[entry.key] ?? '').toLowerCase();
      return folderName.contains(query);
    }).toList();

    // Buscar en canciones y obtener las carpetas que las contienen
    final songMatches = <String>{}; // Set para evitar duplicados
    try {
      final allSongs = await _audioQuery.querySongs();
      for (final song in allSongs) {
        final title = quitarDiacriticos(song.title).toLowerCase();
        final artist = quitarDiacriticos(song.artist ?? '').toLowerCase();
        
        if (title.contains(query) || artist.contains(query)) {
          // Encontrar la carpeta que contiene esta canción
          final folderPath = _getFolderPath(song.data);
          if (songPathsByFolder.containsKey(folderPath)) {
            songMatches.add(folderPath);
          }
        }
      }
    } catch (e) {
      // Si hay error al buscar canciones, continuar solo con búsqueda de carpetas
    }

    // Combinar resultados de búsqueda de carpetas y canciones
    final allMatches = <String, List<String>>{};
    
    // Agregar coincidencias de carpetas
    for (final entry in folderMatches) {
      allMatches[entry.key] = entry.value;
    }
    
    // Agregar coincidencias de canciones (sin duplicar)
    for (final folderPath in songMatches) {
      if (!allMatches.containsKey(folderPath)) {
        allMatches[folderPath] = songPathsByFolder[folderPath] ?? [];
      }
    }

    if (!mounted) return;
    setState(() {
      _filteredFolders = allMatches.entries.toList();
    });
  }

  // Función para construir la carátula del modal
  Widget _buildModalArtwork(SongModel song) {
    final isSystem = colorSchemeNotifier.value == AppColorScheme.system;
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
          color: isSystem ? Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.5) : Theme.of(context).colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.music_note, size: 30),
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

  // Función para buscar la canción en YouTube Music
  Future<void> _searchSongOnYouTubeMusic(SongModel song) async {
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
      
      // URL correcta para búsqueda en YouTube Music
      final ytMusicSearchUrl = 'https://music.youtube.com/search?q=$encodedQuery';

      // Intentar abrir YouTube Music en el navegador o en la app
      final url = Uri.parse(ytMusicSearchUrl);

      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } else {
        // ignore: use_build_context_synchronously
      }
    } catch (e) {
      // ignore: avoid_print
    }
  }

  // Función para mostrar opciones de búsqueda
  Future<void> _showSearchOptions(SongModel song) async {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white, width: 1)
                    : BorderSide.none,
              ),
              title: Center(
                child: TranslatedText(
                  'search_song',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(height: 18),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Row(
                        children: [
                          SizedBox(width: 4),
                          TranslatedText(
                            'search_options',
                            style: TextStyle(
                              fontSize: 14,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: 20),
                    // Tarjeta de YouTube
                    InkWell(
                      onTap: () {
                        Navigator.of(context).pop();
                        _searchSongOnYouTube(song);
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: isAmoled && isDark
                              ? Colors.white.withValues(alpha: 0.1) // Color personalizado para amoled
                              : Theme.of(context).colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(16),
                            topRight: Radius.circular(16),
                            bottomLeft: Radius.circular(4),
                            bottomRight: Radius.circular(4),
                          ),
                          border: Border.all(
                            color: isAmoled && isDark
                                ? Colors.white.withValues(alpha: 0.2) // Borde personalizado para amoled
                                : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Image.asset(
                                'assets/icon/Youtube_logo.png',
                                width: 30,
                                height: 30,
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'YouTube',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: isAmoled && isDark
                                      ? Colors.white // Texto blanco para amoled
                                      : Theme.of(context).colorScheme.onSurface,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: 4),
                    // Tarjeta de YouTube Music
                    InkWell(
                      onTap: () {
                        Navigator.of(context).pop();
                        _searchSongOnYouTubeMusic(song);
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: isAmoled && isDark
                              ? Colors.white.withValues(alpha: 0.1) // Color personalizado para amoled
                              : Theme.of(context).colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(4),
                            topRight: Radius.circular(4),
                            bottomLeft: Radius.circular(16),
                            bottomRight: Radius.circular(16),
                          ),
                          border: Border.all(
                            color: isAmoled && isDark
                                ? Colors.white.withValues(alpha: 0.2) // Borde personalizado para amoled
                                : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Image.asset(
                                'assets/icon/Youtube_Music_icon.png',
                                width: 30,
                                height: 30,
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'YT Music',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: isAmoled && isDark
                                      ? Colors.white // Texto blanco para amoled
                                      : Theme.of(context).colorScheme.onSurface,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // Función para mostrar confirmación de borrado con el mismo diseño
  Future<void> _showDeleteConfirmation(SongModel song) async {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white, width: 1)
                    : BorderSide.none,
              ),
              title: Center(
                child: TranslatedText(
                  'delete_song',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(height: 18),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child: TranslatedText(
                          'delete_song_confirm',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                          textAlign: TextAlign.left,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    SizedBox(height: 20),
                    // Tarjeta de confirmar borrado
                    InkWell(
                      onTap: () async {
                        Navigator.of(context).pop();
                        final success = await _deleteSongFromDevice(song);
                        if (!success && context.mounted) {
                          showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                                side: isAmoled && isDark
                                    ? const BorderSide(color: Colors.white, width: 1)
                                    : BorderSide.none,
                              ),
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
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: isAmoled && isDark
                              ? Colors.red.withValues(alpha: 0.2) // Color personalizado para amoled
                              : Theme.of(context).colorScheme.errorContainer,
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(16),
                            topRight: Radius.circular(16),
                            bottomLeft: Radius.circular(4),
                            bottomRight: Radius.circular(4),
                          ),
                          border: Border.all(
                            color: isAmoled && isDark
                                ? Colors.red.withValues(alpha: 0.4) // Borde personalizado para amoled
                                : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                Icons.delete_forever,
                                size: 30,
                                color: isAmoled && isDark
                                    ? Colors.red // Ícono rojo para amoled
                                    : Theme.of(context).colorScheme.onErrorContainer,
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                LocaleProvider.tr('delete'),
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: isAmoled && isDark
                                      ? Colors.red // Texto rojo para amoled
                                      : Theme.of(context).colorScheme.onErrorContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: 4),
                    // Tarjeta de cancelar
                    InkWell(
                      onTap: () {
                        Navigator.of(context).pop();
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: isAmoled && isDark
                              ? Colors.white.withValues(alpha: 0.1) // Color personalizado para amoled
                              : Theme.of(context).colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.only(
                            bottomLeft: Radius.circular(16),
                            bottomRight: Radius.circular(16),
                            topLeft: Radius.circular(4),
                            topRight: Radius.circular(4),
                          ),
                          border: Border.all(
                            color: isAmoled && isDark
                                ? Colors.white.withValues(alpha: 0.2) // Borde personalizado para amoled
                                : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                Icons.cancel_outlined,
                                size: 30,
                                color: isAmoled && isDark
                                    ? Colors.white // Ícono blanco para amoled
                                    : Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                LocaleProvider.tr('cancel'),
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: isAmoled && isDark
                                      ? Colors.white // Texto blanco para amoled
                                      : Theme.of(context).colorScheme.onSurface,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }


  // Función para mostrar diálogo de renombrado de carpeta
  Future<void> _showRenameFolderDialog(String folderKey, String currentName) async {
    final TextEditingController nameController = TextEditingController(text: currentName);

    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white, width: 1)
                    : BorderSide.none,
              ),
              title: Center(
                child: TranslatedText(
                  'rename_folder',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(height: 18),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Row(
                        children: [
                          SizedBox(width: 4),
                          TranslatedText(
                            'folder_name',
                            style: TextStyle(
                              fontSize: 14,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: 20),
                    TextField(
                      controller: nameController,
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: LocaleProvider.tr('enter_folder_name'),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: TranslatedText('cancel'),
                ),
                TextButton(
                  onPressed: () async {
                    final newName = nameController.text.trim();
                    if (newName.isNotEmpty && newName != currentName) {
                      // Cerrar el diálogo primero
                      if (context.mounted) {
                        Navigator.of(context).pop();
                      }
                      // Luego ejecutar el renombrado
                      await _renameFolder(folderKey, newName);
                    } else if (newName.isEmpty) {
                      // Mostrar mensaje de error si el nombre está vacío
                      _showMessage(
                        LocaleProvider.tr('error'),
                        description: LocaleProvider.tr('folder_name_required'),
                        isError: true,
                      );
                    }
                  },
                  child: TranslatedText('rename'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // Función para renombrar la carpeta
  Future<void> _renameFolder(String folderKey, String newName) async {
    try {
      // Obtener la ruta original de la carpeta
      final originalPath = folderKey;
      
      // Intentar encontrar la ruta real de la carpeta
      String realPath = originalPath;
      final directory = Directory(originalPath);
      
      // Si la ruta normalizada no existe, intentar encontrar la ruta real
      if (!await directory.exists()) {
        // Buscar en las canciones de la carpeta para obtener la ruta real
        final songsInFolder = songPathsByFolder[folderKey] ?? [];
        if (songsInFolder.isNotEmpty) {
          // Obtener la ruta real del directorio padre de la primera canción
          final firstSongPath = songsInFolder.first;
          final realDirPath = p.dirname(firstSongPath);
          realPath = realDirPath;
        } else {
          throw Exception('Carpeta no encontrada - no hay canciones en la carpeta');
        }
      }
      
      final realDirectory = Directory(realPath);
      
      // Verificar que la carpeta real existe
      if (!await realDirectory.exists()) {
        throw Exception('Carpeta no encontrada');
      }
      
      // Crear la nueva ruta con el nuevo nombre
      final parentDir = realDirectory.parent;
      final newPath = p.join(parentDir.path, newName);
      final newDirectory = Directory(newPath);
      
      // Verificar que no existe una carpeta con el nuevo nombre
      if (await newDirectory.exists()) {
        throw Exception('Ya existe una carpeta con ese nombre');
      }
      
      // Renombrar la carpeta física
      await realDirectory.rename(newPath);
      
      // Obtener todas las canciones de la carpeta original
      final songsInFolder = songPathsByFolder[folderKey] ?? [];
      
      // Actualizar todas las rutas de las canciones en la base de datos de una vez
      await SongsIndexDB().updateFolderPaths(realPath, newPath);
      
      // Actualizar los mapas locales
      setState(() {
        // Crear nueva entrada con la nueva ruta
        songPathsByFolder[newPath] = songsInFolder.map((songPath) {
          final songFileName = p.basename(songPath);
          return p.join(newPath, songFileName);
        }).toList();
        
        // Actualizar el nombre de visualización
        folderDisplayNames[newPath] = newName;
        
        // Eliminar la entrada antigua
        songPathsByFolder.remove(folderKey);
        folderDisplayNames.remove(folderKey);
      });
      
      // Mostrar mensaje de éxito
      if (mounted) {
        _showMessage(
          LocaleProvider.tr('success'),
          description: '${LocaleProvider.tr('folder_renamed_to')} "$newName"',
          isError: false,
        );
      } else {
        // print('DEBUG: Widget no está montado, no se puede mostrar mensaje');
      }
    } catch (e) {
      // print('DEBUG: Error al renombrar carpeta: $e');
      // Mostrar mensaje de error específico
      String errorMessage;
      if (e.toString().contains('Ya existe una carpeta con ese nombre')) {
        errorMessage = LocaleProvider.tr('folder_name_already_exists');
      } else if (e.toString().contains('Carpeta no encontrada')) {
        errorMessage = LocaleProvider.tr('folder_not_found');
      } else if (e.toString().contains('Permission denied') || e.toString().contains('Acceso denegado')) {
        errorMessage = LocaleProvider.tr('permission_denied_rename');
      } else {
        errorMessage = LocaleProvider.tr('error_renaming_folder');
      }
      
      if (mounted) {
        // print('DEBUG: Mostrando mensaje de error para renombrar carpeta');
        _showMessage(
          LocaleProvider.tr('error'),
          description: errorMessage,
          isError: true,
        );
      } else {
        // print('DEBUG: Widget no está montado, no se puede mostrar mensaje de error');
      }
    }
  }

  // Función para mostrar confirmación de borrado de carpeta con el mismo diseño
  Future<void> _showDeleteFolderConfirmation(String folderKey, String folderName) async {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white, width: 1)
                    : BorderSide.none,
              ),
              title: Center(
                child: TranslatedText(
                  'delete_folder',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(height: 18),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child: TranslatedText(
                          'delete_folder_confirm',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                          textAlign: TextAlign.left,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    SizedBox(height: 20),
                    // Tarjeta de confirmar borrado
                    InkWell(
                      onTap: () async {
                        Navigator.of(context).pop();
                        final success = await _deleteFolderAndSongs(folderKey);
                        if (!success && context.mounted) {
                          showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                                side: isAmoled && isDark
                                    ? const BorderSide(color: Colors.white, width: 1)
                                    : BorderSide.none,
                              ),
                              title: TranslatedText('error'),
                              content: TranslatedText('could_not_delete_folder'),
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
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: isAmoled && isDark
                              ? Colors.red.withValues(alpha: 0.2) // Color personalizado para amoled
                              : Theme.of(context).colorScheme.errorContainer,
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(16),
                            topRight: Radius.circular(16),
                            bottomLeft: Radius.circular(4),
                            bottomRight: Radius.circular(4),
                          ),
                          border: Border.all(
                            color: isAmoled && isDark
                                ? Colors.red.withValues(alpha: 0.4) // Borde personalizado para amoled
                                : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                Icons.folder_delete,
                                size: 30,
                                color: isAmoled && isDark
                                    ? Colors.red // Ícono rojo para amoled
                                    : Theme.of(context).colorScheme.onErrorContainer,
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                LocaleProvider.tr('delete'),
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: isAmoled && isDark
                                      ? Colors.red // Texto rojo para amoled
                                      : Theme.of(context).colorScheme.onErrorContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: 4),
                    // Tarjeta de cancelar
                    InkWell(
                      onTap: () {
                        Navigator.of(context).pop();
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: isAmoled && isDark
                              ? Colors.white.withValues(alpha: 0.1) // Color personalizado para amoled
                              : Theme.of(context).colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.only(
                            bottomLeft: Radius.circular(16),
                            bottomRight: Radius.circular(16),
                            topLeft: Radius.circular(4),
                            topRight: Radius.circular(4),
                          ),
                          border: Border.all(
                            color: isAmoled && isDark
                                ? Colors.white.withValues(alpha: 0.2) // Borde personalizado para amoled
                                : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                Icons.cancel_outlined,
                                size: 30,
                                color: isAmoled && isDark
                                    ? Colors.white // Ícono blanco para amoled
                                    : Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                LocaleProvider.tr('cancel'),
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: isAmoled && isDark
                                      ? Colors.white // Texto blanco para amoled
                                      : Theme.of(context).colorScheme.onSurface,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _removeSongsFromAllDatabases(String folderPath) async {
    // Obtener todas las canciones de la carpeta antes de eliminarlas
    final songsInFolder = songPathsByFolder[folderPath] ?? [];
    
    // Eliminar de RecentsDB
    for (final songPath in songsInFolder) {
      try {
        await RecentsDB().removeRecent(songPath);
      } catch (e) {
        // Ignorar errores si la canción no está en recientes
      }
    }
    
    // Eliminar de MostPlayedDB
    for (final songPath in songsInFolder) {
      try {
        await MostPlayedDB().removeMostPlayed(songPath);
      } catch (e) {
        // Ignorar errores si la canción no está en más reproducidas
      }
    }
    
    // Eliminar de ShortcutsDB
    try {
      final shortcuts = await ShortcutsDB().getShortcuts();
      final shortcutsToRemove = shortcuts.where((path) => songsInFolder.contains(path)).toList();
      for (final path in shortcutsToRemove) {
        await ShortcutsDB().removeShortcut(path);
      }
    } catch (e) {
      // Ignorar errores
    }
    
    // Eliminar de FavoritesDB
    for (final songPath in songsInFolder) {
      try {
        await FavoritesDB().removeFavorite(songPath);
      } catch (e) {
        // Ignorar errores si la canción no está en favoritos
      }
    }
  }

  Future<void> _ignoreFolderFlow(String folderKey) async {
    final folderName = folderDisplayNames[folderKey] ?? '';
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white, width: 1)
                    : BorderSide.none,
              ),
              title: Center(
                child: TranslatedText(
                  'ignore_folder',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(height: 18),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          LocaleProvider.tr('ignore_folder_confirm').replaceAll('{folder}', folderName),
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                          textAlign: TextAlign.left,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    SizedBox(height: 20),
                    // Tarjeta de confirmar ignorar
                    InkWell(
                      onTap: () {
                        Navigator.of(context).pop(true);
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: isAmoled && isDark
                              ? Colors.orange.withValues(alpha: 0.2) // Color personalizado para amoled
                              : Theme.of(context).colorScheme.primaryContainer,
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(16),
                            topRight: Radius.circular(16),
                            bottomLeft: Radius.circular(4),
                            bottomRight: Radius.circular(4),
                          ),
                          border: Border.all(
                            color: isAmoled && isDark
                                ? Colors.orange.withValues(alpha: 0.4) // Borde personalizado para amoled
                                : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                Icons.visibility_off,
                                size: 30,
                                color: isAmoled && isDark
                                    ? Colors.orange // Ícono naranja para amoled
                                    : Theme.of(context).colorScheme.onPrimaryContainer,
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                LocaleProvider.tr('ignore_folder'),
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: isAmoled && isDark
                                      ? Colors.orange // Texto naranja para amoled
                                      : Theme.of(context).colorScheme.onPrimaryContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: 4),
                    // Tarjeta de cancelar
                    InkWell(
                      onTap: () {
                        Navigator.of(context).pop(false);
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: isAmoled && isDark
                              ? Colors.white.withValues(alpha: 0.1) // Color personalizado para amoled
                              : Theme.of(context).colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.only(
                            bottomLeft: Radius.circular(16),
                            bottomRight: Radius.circular(16),
                            topLeft: Radius.circular(4),
                            topRight: Radius.circular(4),
                          ),
                          border: Border.all(
                            color: isAmoled && isDark
                                ? Colors.white.withValues(alpha: 0.2) // Borde personalizado para amoled
                                : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                Icons.cancel_outlined,
                                size: 30,
                                color: isAmoled && isDark
                                    ? Colors.white // Ícono blanco para amoled
                                    : Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                LocaleProvider.tr('cancel'),
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: isAmoled && isDark
                                      ? Colors.white // Texto blanco para amoled
                                      : Theme.of(context).colorScheme.onSurface,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (confirmed != true) return;

    await ignoreFolder(folderKey);
    
    // Eliminar canciones de todas las bases de datos
    await SongsIndexDB().deleteFolderEntries(folderKey);
    await _removeSongsFromAllDatabases(folderKey);

    if (!mounted) return;
    setState(() {
      // Mantener la carpeta visible con 0 canciones para poder restaurarla
      songPathsByFolder[folderKey] = [];
      // Actualizar cache de carpetas ignoradas
      _ignoredFoldersCache.add(folderKey);
    });

    if (!mounted) return;
    _showMessage(LocaleProvider.tr('success'), description: LocaleProvider.tr('folder_ignored_success'));
  }

  Future<void> _unignoreFolderFlow(String folderKey) async {
    await unignoreFolder(folderKey);
    await SongsIndexDB().syncDatabase();
    if (!mounted) return;
    await cargarCanciones(forceIndex: true);
    if (!mounted) return;
    _showMessage(LocaleProvider.tr('success'), description: LocaleProvider.tr('folder_unignored_success'));
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
    _folderSearchController.dispose();
    _folderSearchFocusNode.dispose();
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
      if (mounted && _folderSearchFocusNode.hasFocus) {
        _folderSearchFocusNode.unfocus();
      }
    }
    _lastBottomInset = bottomInset;
  }

  @override
  Widget build(BuildContext context) {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (songPathsByFolder.isEmpty) {
      return Scaffold(
        body: RefreshIndicator(
          onRefresh: () async {
            // Recargar las carpetas al hacer scroll hacia abajo
            await cargarCanciones(forceIndex: true);
          },
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: MediaQuery.of(context).size.height - 
                    MediaQuery.of(context).padding.top - 
                    kToolbarHeight - 
                    MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32.0),
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
              ),
            ),
          ),
        ),
      );
    }

    if (carpetaSeleccionada == null) {
      return Scaffold(
          resizeToAvoidBottomInset: true,
          appBar: AppBar(
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
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
                icon: const Icon(Icons.info_outline, size: 28),
                tooltip: LocaleProvider.tr('information'),
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: isAmoled && isDark
                            ? const BorderSide(color: Colors.white, width: 1)
                            : BorderSide.none,
                      ),
                      title: TranslatedText('info'),
                      content: TranslatedText('folders_and_songs_info'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: TranslatedText('ok'),
                        ),
                      ],
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
                  controller: _folderSearchController,
                  focusNode: _folderSearchFocusNode,
                  onChanged: (_) => _onFolderSearchChanged(),
                  onEditingComplete: () {
                    _folderSearchFocusNode.unfocus();
                  },
                  decoration: InputDecoration(
                    hintText: LocaleProvider.tr('search_folders_and_songs'),
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _folderSearchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              _folderSearchController.clear();
                              _onFolderSearchChanged();
                              setState(() {});
                            },
                          )
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 0),
                  ),
                ),
              ),
            ),
          ),
          body: RefreshIndicator(
            onRefresh: () async {
              // Recargar las carpetas al hacer scroll hacia abajo
              await cargarCanciones(forceIndex: true);
            },
            child: ValueListenableBuilder<MediaItem?>(
              valueListenable: _currentMediaItemNotifier,
              builder: (context, current, child) {
                final space = current != null ? 100.0 : 0.0;
                return Padding(
                  padding: EdgeInsets.only(bottom: space),
                  child: ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount: _folderSearchController.text.isNotEmpty
                              ? _filteredFolders.length
                              : songPathsByFolder.length,
                          itemBuilder: (context, i) {
                            final sortedEntries = _folderSearchController.text.isNotEmpty
                                ? _filteredFolders
                                : songPathsByFolder.entries.toList()
                                  ..sort(
                                    (a, b) =>
                                        folderDisplayNames[a.key]!.toLowerCase().compareTo(
                                          folderDisplayNames[b.key]!.toLowerCase(),
                                        ),
                                  );
                            final entry = sortedEntries[i];
                    final nombre = folderDisplayNames[entry.key]!;
                    final canciones = entry.value;

                    // Usar cache para evitar parpadeos
                    final ignored = _ignoredFoldersCache.contains(entry.key);
                    final opacity = ignored ? 0.4 : 1.0;
                    return Opacity(
                      opacity: opacity,
                      child: ListTile(
                        leading: const Icon(Icons.folder, size: 38),
                        title: Text(
                          nombre,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: ignored && canciones.isEmpty 
                            ? null 
                            : Text(
                                '${canciones.length} ${LocaleProvider.tr('songs')}',
                              ),
                        onTap: ignored ? null : () async {
                          await _loadSongsForFolder(entry);
                        },
                        trailing: PopupMenuButton<String>(
                          onSelected: (value) async {
                            if (value == 'rename') {
                              await _showRenameFolderDialog(entry.key, folderDisplayNames[entry.key] ?? '');
                            } else if (value == 'delete') {
                              await _showDeleteFolderConfirmation(entry.key, folderDisplayNames[entry.key] ?? '');
                            } else if (value == 'toggle_ignore') {
                              if (ignored) {
                                await _unignoreFolderFlow(entry.key);
                              } else {
                                await _ignoreFolderFlow(entry.key);
                              }
                            }
                          },
                          itemBuilder: (context) => [
                            PopupMenuItem(
                              value: 'rename',
                              child: Row(
                                children: [
                                  Icon(Icons.edit_outlined),
                                  SizedBox(width: 8),
                                  TranslatedText('rename_folder'),
                                ],
                              ),
                            ),
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
                            PopupMenuItem(
                              value: 'toggle_ignore',
                              child: Row(
                                children: [
                                  Icon(ignored ? Icons.visibility : Icons.visibility_off),
                                  SizedBox(width: 8),
                                  TranslatedText(ignored ? 'unignore_folder' : 'ignore_folder'),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  
              },
            ),
          );
              }
            ),
          ),
        );
    }

    return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          FocusScope.of(context).unfocus();
        },
        child: Scaffold(
          appBar: AppBar(
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
        scrolledUnderElevation: 0,
            leading: _isSelecting
                ? IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: LocaleProvider.tr('cancel_selection'),
                    onPressed: () {
                      setState(() {
                        _isSelecting = false;
                        _selectedSongPaths.clear();
                      });
                    },
                  )
                : IconButton(
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                      maxWidth: 40,
                      maxHeight: 40,
                    ),
                    padding: EdgeInsets.zero,
                    icon: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
                      ),
                      child: const Icon(
                        Icons.arrow_back,
                        size: 24,
                      ),
                    ),
                    onPressed: () async {
                      setState(() {
                        carpetaSeleccionada = null;
                        _searchController.clear();
                        _filteredSongs.clear();
                        _displaySongs.clear();
                        // Al salir, limpiar selección múltiple
                        _isSelecting = false;
                        _selectedSongPaths.clear();
                      });
                      // Recargar la lista de carpetas para mostrar el estado actual
                      await cargarCanciones(forceIndex: false);
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
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  tooltip: LocaleProvider.tr('options'),
                  onSelected: (String value) async {
                    switch (value) {
                      case 'add_to_favorites':
                        if (_selectedSongPaths.isNotEmpty) {
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
                        }
                        break;
                      case 'add_to_playlist':
                        if (_selectedSongPaths.isNotEmpty) {
                          await _handleAddToPlaylistMassive(context);
                        }
                        break;
                      case 'copy_to_folder':
                        if (_selectedSongPaths.isNotEmpty) {
                          await _handleCopyToFolder(context);
                        }
                        break;
                      case 'move_to_folder':
                        if (_selectedSongPaths.isNotEmpty) {
                          await _handleMoveToFolder(context);
                        }
                        break;
                      case 'delete_songs':
                        if (_selectedSongPaths.isNotEmpty) {
                          await _handleDeleteSongs(context);
                        }
                        break;
                    }
                  },
                  itemBuilder: (BuildContext context) => [
                    PopupMenuItem<String>(
                      value: 'add_to_favorites',
                      enabled: _selectedSongPaths.isNotEmpty,
                      child: Row(
                        children: [
                          const Icon(Symbols.favorite_rounded, weight: 600),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(LocaleProvider.tr('add_to_favorites')),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuItem<String>(
                      value: 'add_to_playlist',
                      enabled: _selectedSongPaths.isNotEmpty,
                      child: Row(
                        children: [
                          const Icon(Icons.playlist_add),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(LocaleProvider.tr('add_to_playlist')),
                          ),
                        ],
                      ),
                    ),
                    if (_isAndroid10OrHigher)
                      PopupMenuItem<String>(
                        value: 'copy_to_folder',
                        enabled: _selectedSongPaths.isNotEmpty,
                        child: Row(
                          children: [
                            const Icon(Icons.copy),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(LocaleProvider.tr('copy_to_folder')),
                            ),
                          ],
                        ),
                      ),
                    if (_isAndroid10OrHigher)
                      PopupMenuItem<String>(
                        value: 'move_to_folder',
                        enabled: _selectedSongPaths.isNotEmpty,
                        child: Row(
                          children: [
                            const Icon(Icons.drive_file_move),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(LocaleProvider.tr('move_to_folder')),
                            ),
                          ],
                        ),
                      ),
                    PopupMenuItem<String>(
                      value: 'delete_songs',
                      enabled: _selectedSongPaths.isNotEmpty,
                      child: Row(
                        children: [
                          const Icon(Icons.delete),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(LocaleProvider.tr('delete_songs')),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ] else ...[
                IconButton(
                  icon: const Icon(Symbols.shuffle_rounded, size: 28, weight: 600),
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
                  tooltip: LocaleProvider.tr('filters'),
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
          body: RefreshIndicator(
            onRefresh: _refreshCurrentFolder,
            child: ValueListenableBuilder<MediaItem?>(
              valueListenable: _currentMediaItemNotifier,
              builder: (context, debouncedMediaItem, child) {
                // Detectar si el tema AMOLED está activo
                final isAmoledTheme =
                    colorSchemeNotifier.value == AppColorScheme.amoled;
                final space = debouncedMediaItem != null ? 100.0 : 0.0;

                return Padding(
                  padding: EdgeInsets.only(bottom: space),
                  child: _filteredSongs.isEmpty
                      ? SingleChildScrollView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          child: SizedBox(
                            height: MediaQuery.of(context).size.height - 200,
                            child: Center(
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
                            ),
                          ),
                        )
                      : ValueListenableBuilder<MediaItem?>(
                          valueListenable: _immediateMediaItemNotifier,
                          builder: (context, immediateMediaItem, child) {
                            return ListView.builder(
                              controller: _scrollController,
                              physics: const AlwaysScrollableScrollPhysics(),
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
    final isSystem = colorSchemeNotifier.value == AppColorScheme.system;

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
                    color: isSystem ? Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.5) : Theme.of(context).colorScheme.surfaceContainer,
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
                          fontSize: 16,
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
                      ? (playing ? Symbols.pause_rounded : Symbols.play_arrow_rounded)
                      : Symbols.play_arrow_rounded,
                  fill: 1,
                  grade: 200,
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
        selectedTileColor: isCurrent
            ? (isAmoledTheme
                ? Colors.transparent
                : Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.8))
            : null,
        shape: isCurrent
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              )
            : null,
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

  Future<void> _handleCopyToFolder(BuildContext context) async {
    if (!context.mounted) return;
    
    final selectedSongs = _displaySongs.where(
      (s) => _selectedSongPaths.contains(s.data),
    ).toList();
    
    if (selectedSongs.isEmpty) return;
    
    // Usar la función existente para mostrar el selector de carpetas
    // pero adaptada para múltiples canciones
    await _showFolderSelectorMultiple(selectedSongs, isMove: false);
  }

  Future<void> _handleMoveToFolder(BuildContext context) async {
    if (!context.mounted) return;
    
    final selectedSongs = _displaySongs.where(
      (s) => _selectedSongPaths.contains(s.data),
    ).toList();
    
    if (selectedSongs.isEmpty) return;
    
    // Usar la función existente para mostrar el selector de carpetas
    // pero adaptada para múltiples canciones
    await _showFolderSelectorMultiple(selectedSongs, isMove: true);
  }

  Future<void> _handleDeleteSongs(BuildContext context) async {
    if (!context.mounted) return;
    
    final selectedSongs = _displaySongs.where(
      (s) => _selectedSongPaths.contains(s.data),
    ).toList();
    
    if (selectedSongs.isEmpty) return;
    
    // Mostrar diálogo de confirmación con el mismo diseño que el individual
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
        final isDark = Theme.of(context).brightness == Brightness.dark;
        
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: isAmoled && isDark
                ? const BorderSide(color: Colors.white, width: 1)
                : BorderSide.none,
          ),
          title: Center(
            child: Text(
              LocaleProvider.tr('delete_songs'),
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 18),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      LocaleProvider.tr('delete_songs_confirm')
                          .replaceAll('{count}', selectedSongs.length.toString()),
                      style: TextStyle(
                        fontSize: 14,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      textAlign: TextAlign.left,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                // Tarjeta de confirmar borrado
                InkWell(
                  onTap: () {
                    Navigator.of(context).pop(true);
                  },
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: isAmoled && isDark
                          ? Colors.red.withValues(alpha: 0.2)
                          : Theme.of(context).colorScheme.errorContainer,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(16),
                        topRight: Radius.circular(16),
                        bottomLeft: Radius.circular(4),
                        bottomRight: Radius.circular(4),
                      ),
                      border: Border.all(
                        color: isAmoled && isDark
                            ? Colors.red.withValues(alpha: 0.4)
                            : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Icons.delete_forever,
                            size: 30,
                            color: isAmoled && isDark
                                ? Colors.red
                                : Theme.of(context).colorScheme.onErrorContainer,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            LocaleProvider.tr('delete'),
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: isAmoled && isDark
                                  ? Colors.red
                                  : Theme.of(context).colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                // Tarjeta de cancelar
                InkWell(
                  onTap: () {
                    Navigator.of(context).pop(false);
                  },
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: isAmoled && isDark
                          ? Colors.white.withValues(alpha: 0.1)
                          : Theme.of(context).colorScheme.secondaryContainer,
                      borderRadius: const BorderRadius.only(
                        bottomLeft: Radius.circular(16),
                        bottomRight: Radius.circular(16),
                        topLeft: Radius.circular(4),
                        topRight: Radius.circular(4),
                      ),
                      border: Border.all(
                        color: isAmoled && isDark
                            ? Colors.white.withValues(alpha: 0.2)
                            : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Icons.cancel_outlined,
                            size: 30,
                            color: isAmoled && isDark
                                ? Colors.white
                                : Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            LocaleProvider.tr('cancel'),
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: isAmoled && isDark
                                  ? Colors.white
                                  : Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    
    if (confirmed == true) {
      await _deleteMultipleSongs(selectedSongs);
    }
  }

  // Función para borrar múltiples canciones (optimizada)
  Future<void> _deleteMultipleSongs(List<SongModel> songs) async {
    int successCount = 0;
    int errorCount = 0;
    final List<String> songPaths = songs.map((s) => s.data).toList();
    
    try {
      // Primero retirar todas las canciones de la cola de una vez
      try {
        final handler = audioHandler as MyAudioHandler;
        await handler.removeSongsByPath(List<String>.from(songPaths));
      } catch (_) {}

      // Borrar archivos físicos
      for (final song in songs) {
        try {
          final file = File(song.data);
          if (await file.exists()) {
            await file.delete();
            
            // Notificar al MediaStore de Android que el archivo fue eliminado
            try {
              await MediaScanner.loadMedia(path: song.data);
            } catch (_) {}
            
            successCount++;
            
            // Limpiar caché de artwork
            try {
              removeArtworkFromCache(song.data);
            } catch (_) {}
          } else {
            errorCount++;
          }
        } catch (e) {
          errorCount++;
        }
      }

      // Limpiar de todas las bases de datos
      try {
        for (final path in songPaths) {
          await FavoritesDB().removeFavorite(path);
        }
      } catch (_) {}
      try {
        for (final path in songPaths) {
          await RecentsDB().removeRecent(path);
        }
      } catch (_) {}
      try {
        for (final path in songPaths) {
          if (await ShortcutsDB().isShortcut(path)) {
            await ShortcutsDB().removeShortcut(path);
          }
        }
      } catch (_) {}
      try {
        final playlists = await PlaylistsDB().getAllPlaylists();
        for (final p in playlists) {
          final toRemove = p.songPaths.where((sp) => songPaths.contains(sp)).toList();
          for (final sp in toRemove) {
            await PlaylistsDB().removeSongFromPlaylist(p.id, sp);
          }
        }
      } catch (_) {}

      // Sincronizar índice una sola vez
      try {
        await SongsIndexDB().cleanNonExistentFiles();
      } catch (_) {}

      // Actualizar el estado local
      if (carpetaSeleccionada != null) {
        setState(() {
          _originalSongs.removeWhere((s) => songPaths.contains(s.data));
          _filteredSongs.removeWhere((s) => songPaths.contains(s.data));
          _displaySongs.removeWhere((s) => songPaths.contains(s.data));
          songPathsByFolder[carpetaSeleccionada!]?.removeWhere(
            (path) => songPaths.contains(path),
          );
        });
      }

      // Notificar a otras pantallas
      try {
        favoritesShouldReload.value = !favoritesShouldReload.value;
        shortcutsShouldReload.value = !shortcutsShouldReload.value;
        playlistsShouldReload.value = !playlistsShouldReload.value;
      } catch (_) {}

    } catch (e) {
      // No hacer nada
    }
    
    if (mounted) {
      _showMessage(
        LocaleProvider.tr('songs_deleted'),
        isError: false,
        description: LocaleProvider.tr('delete_completed')
            .replaceAll('{success}', successCount.toString())
            .replaceAll('{error}', errorCount.toString()),
      );
      
      setState(() {
        _isSelecting = false;
        _selectedSongPaths.clear();
      });
    }
  }

  // Función para mostrar el selector de carpetas para múltiples canciones
  // Reutiliza la lógica de _showFolderSelector pero adaptada para múltiples canciones
  Future<void> _showFolderSelectorMultiple(List<SongModel> songs, {required bool isMove}) async {
    // Verificar permisos para la primera canción (asumimos que todas están en la misma ubicación)
    if (songs.isNotEmpty) {
      await _checkFilePermissions(songs.first.data);
    }
    
    final folders = await SongsIndexDB().getFolders();
    
    // Crear mapa de carpetas con sus rutas completas originales
    final Map<String, String> folderMap = {};
    for (final folder in folders) {
      // Obtener la ruta original completa desde las canciones
      final songsInFolder = await SongsIndexDB().getSongsFromFolder(folder);
      String originalPath = folder;
      
      if (songsInFolder.isNotEmpty) {
        // Usar la ruta del primer archivo para obtener la carpeta original
        final firstSongPath = songsInFolder.first;
        final originalFolder = p.dirname(firstSongPath);
        originalPath = originalFolder;
      }
      
      folderMap[folder] = originalPath;
    }
    
    // Para simplificar, mostrar todas las carpetas disponibles
    // El usuario puede elegir cualquier carpeta, incluso la actual
    final availableFolders = folders;

    if (availableFolders.isEmpty) {
      _showMessage(
        isMove 
          ? 'No hay otras carpetas disponibles para mover las canciones.' 
          : 'No hay carpetas disponibles para copiar las canciones.',
        isError: true,
      );
      return;
    }

    // Ordenar las carpetas alfabéticamente igual que en la pantalla principal
    availableFolders.sort((a, b) {
      // Usar folderDisplayNames si está disponible, sino usar el nombre de la carpeta de la ruta
      final nameA = folderDisplayNames.containsKey(a) 
          ? folderDisplayNames[a]!.toLowerCase()
          : p.basename(folderMap[a] ?? '').toLowerCase();
      final nameB = folderDisplayNames.containsKey(b) 
          ? folderDisplayNames[b]!.toLowerCase()
          : p.basename(folderMap[b] ?? '').toLowerCase();
      return nameA.compareTo(nameB);
    });

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Encabezado
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      isMove ? Icons.drive_file_move : Icons.copy,
                      color: Theme.of(context).colorScheme.inverseSurface.withValues(alpha: 0.95),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        isMove ? LocaleProvider.tr('move_to_folder') : LocaleProvider.tr('copy_to_folder'),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              // Lista de carpetas
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: availableFolders.length,
                  itemBuilder: (context, index) {
                    final folder = availableFolders[index];
                    final originalPath = folderMap[folder] ?? folder;
                    final displayName = folderDisplayNames[folder] ?? p.basename(originalPath);
                    
                    return ListTile(
                      leading: Icon(
                        Icons.folder,
                      ),
                      title: Text(
                        displayName,
                        maxLines: 1,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      onTap: () async {
                        Navigator.of(context).pop();
                        await _processMultipleSongs(songs, originalPath, isMove: isMove);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Función para procesar múltiples canciones (copiar o mover)
  Future<void> _processMultipleSongs(List<SongModel> songs, String destinationFolder, {required bool isMove}) async {
    int successCount = 0;
    int errorCount = 0;
    
    // ValueNotifier para actualizar el progreso en tiempo real
    final progressNotifier = ValueNotifier<String>('0 / ${songs.length}');
    
    // Mostrar diálogo de progreso
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return PopScope(
          canPop: false,
          child: ValueListenableBuilder<String>(
            valueListenable: progressNotifier,
            builder: (context, progress, child) {
              return AlertDialog(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 24),
                    Text(
                      isMove 
                        ? LocaleProvider.tr('moving_songs')
                        : LocaleProvider.tr('copying_songs'),
                      style: const TextStyle(fontSize: 16),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      progress,
                      style: const TextStyle(fontSize: 14),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
    
    for (final song in songs) {
      try {
        if (isMove) {
          await _moveSongToFolderInternal(song, destinationFolder);
        } else {
          await _copySongToFolderInternal(song, destinationFolder);
        }
        successCount++;
      } catch (e) {
        errorCount++;
      }
      
      // Actualizar el progreso
      progressNotifier.value = '${successCount + errorCount} / ${songs.length}';
    }
    
    // Limpiar el notifier
    progressNotifier.dispose();
    
    // Cerrar diálogo de progreso
    if (mounted) Navigator.of(context).pop();
    
    if (mounted) {
      _showMessage(
        isMove 
          ? LocaleProvider.tr('song_moved')
          : LocaleProvider.tr('song_copied'),
        isError: false,
        description: isMove 
          ? LocaleProvider.tr('move_completed')
              .replaceAll('{success}', successCount.toString())
              .replaceAll('{error}', errorCount.toString())
          : LocaleProvider.tr('copy_completed')
              .replaceAll('{success}', successCount.toString())
              .replaceAll('{error}', errorCount.toString()),
      );
      
      setState(() {
        _isSelecting = false;
        _selectedSongPaths.clear();
      });
      
      // No recargar la pantalla, las funciones internas ya actualizaron el estado local
    }
  }

  // Versión interna de _copySongToFolder sin diálogos de confirmación
  Future<void> _copySongToFolderInternal(SongModel song, String destinationFolder) async {
    try {
      final sourceFile = File(song.data);
      if (!await sourceFile.exists()) {
        throw Exception('El archivo no existe.');
      }

      final fileName = p.basename(song.data);
      final destinationPath = p.join(destinationFolder, fileName);
      var destinationFile = File(destinationPath);

      // Verificar si el archivo ya existe en el destino
      if (await destinationFile.exists()) {
        // Generar un nombre único
        final nameWithoutExt = p.basenameWithoutExtension(song.data);
        final extension = p.extension(song.data);
        int counter = 1;
        String newFileName;
        String finalDestinationPath;
        do {
          newFileName = '${nameWithoutExt}_$counter$extension';
          finalDestinationPath = p.join(destinationFolder, newFileName);
          destinationFile = File(finalDestinationPath);
          counter++;
        } while (await destinationFile.exists());
        
        await sourceFile.copy(finalDestinationPath);
      } else {
        await sourceFile.copy(destinationPath);
      }

      // Actualizar el archivo nuevo en el sistema de medios de Android
      await MediaScanner.loadMedia(path: destinationPath);
      
      // Actualizar la base de datos para indexar los cambios
      await SongsIndexDB().forceReindex();

      // Actualizar el estado local sin recargar toda la pantalla
      if (carpetaSeleccionada != null) {
        setState(() {
          // No removemos la canción de la carpeta actual porque es una copia
          // Solo actualizamos el mapa de paths de la carpeta destino
          final destinationFolderKey = destinationFolder;
          if (songPathsByFolder.containsKey(destinationFolderKey)) {
            songPathsByFolder[destinationFolderKey]!.add(song.data);
          }
        });
      }

      // Notificar a otras pantallas que deben refrescar
      try {
        favoritesShouldReload.value = !favoritesShouldReload.value;
        shortcutsShouldReload.value = !shortcutsShouldReload.value;
        playlistsShouldReload.value = !playlistsShouldReload.value;
      } catch (_) {}
    } catch (e) {
      throw Exception('Error copiando canción: $e');
    }
  }

  // Versión interna de _moveSongToFolder sin diálogos de confirmación
  Future<void> _moveSongToFolderInternal(SongModel song, String destinationFolder) async {
    try {
      final sourceFile = File(song.data);
      if (!await sourceFile.exists()) {
        throw Exception('El archivo no existe.');
      }

      final fileName = p.basename(song.data);
      final destinationPath = p.join(destinationFolder, fileName);
      var destinationFile = File(destinationPath);

      // Verificar si el archivo ya existe en el destino
      if (await destinationFile.exists()) {
        // Generar un nombre único
        final nameWithoutExt = p.basenameWithoutExtension(song.data);
        final extension = p.extension(song.data);
        int counter = 1;
        String newFileName;
        String finalDestinationPath;
        do {
          newFileName = '${nameWithoutExt}_$counter$extension';
          finalDestinationPath = p.join(destinationFolder, newFileName);
          destinationFile = File(finalDestinationPath);
          counter++;
        } while (await destinationFile.exists());
        
        await sourceFile.rename(finalDestinationPath);
      } else {
        await sourceFile.rename(destinationPath);
      }

      // Notificar al MediaStore sobre el archivo original eliminado
      try {
        await MediaScanner.loadMedia(path: song.data);
      } catch (_) {}
      
      // Actualizar el archivo nuevo en el sistema de medios de Android
      await MediaScanner.loadMedia(path: destinationPath);
      
      // Actualizar la base de datos para indexar los cambios
      await SongsIndexDB().forceReindex();

      // Actualizar el estado local sin recargar toda la pantalla
      if (carpetaSeleccionada != null) {
        setState(() {
          // Remover la canción de la carpeta actual
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
        shortcutsShouldReload.value = !shortcutsShouldReload.value;
        playlistsShouldReload.value = !playlistsShouldReload.value;
      } catch (_) {}
    } catch (e) {
      throw Exception('Error moviendo canción: $e');
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
    if (!mounted) return;
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
    if (!mounted) return;
    setState(() {
      _originalSongs = songsInFolder;
    });
    await _ordenarCanciones();
    // Precargar carátulas de las canciones en la carpeta
    unawaited(_preloadArtworksForSongs(songsInFolder));
    if (!mounted) return;
    setState(() {
      _isLoading = false;
    });
  }

  // Soporte para pop interno desde el handler global
  bool canPopInternally() {
    return carpetaSeleccionada != null;
  }

  void handleInternalPop() {
    if (!mounted) return;
    setState(() {
      carpetaSeleccionada = null;
    });
    // Recargar la lista de carpetas para mostrar el estado actual
    cargarCanciones(forceIndex: false);
  }

  // Función para mostrar el selector de carpetas
  Future<void> _showFolderSelector(SongModel song, {required bool isMove}) async {
    // Verificar permisos antes de continuar
    await _checkFilePermissions(song.data);
    
    final folders = await SongsIndexDB().getFolders();
    final currentFolder = _getFolderPath(song.data);
    
    // Crear mapa de carpetas con sus rutas completas originales
    final Map<String, String> folderMap = {};
    for (final folder in folders) {
      // Obtener la ruta original completa desde las canciones
      final songsInFolder = await SongsIndexDB().getSongsFromFolder(folder);
      String originalPath = folder;
      
      if (songsInFolder.isNotEmpty) {
        // Usar la ruta del primer archivo para obtener la carpeta original
        final firstSongPath = songsInFolder.first;
        final originalFolder = p.dirname(firstSongPath);
        originalPath = originalFolder;
      }
      
      folderMap[folder] = originalPath;
    }
    
    // Filtrar la carpeta actual si es mover
    final availableFolders = isMove 
        ? folders.where((folder) => folder != currentFolder).toList()
        : folders;

    if (availableFolders.isEmpty) {
      _showMessage(
        isMove ? 'No hay otras carpetas disponibles para mover la canción.' : 'No hay carpetas disponibles para copiar la canción.',
        isError: true,
      );
      return;
    }

    // Ordenar las carpetas alfabéticamente igual que en la pantalla principal
    availableFolders.sort((a, b) {
      // Usar folderDisplayNames si está disponible, sino usar el nombre de la carpeta de la ruta
      final nameA = folderDisplayNames.containsKey(a) 
          ? folderDisplayNames[a]!.toLowerCase()
          : p.basename(folderMap[a] ?? '').toLowerCase();
      final nameB = folderDisplayNames.containsKey(b) 
          ? folderDisplayNames[b]!.toLowerCase()
          : p.basename(folderMap[b] ?? '').toLowerCase();
      return nameA.compareTo(nameB);
    });

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Encabezado
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      isMove ? Icons.drive_file_move : Icons.copy,
                      color: Theme.of(context).colorScheme.inverseSurface.withValues(alpha: 0.95),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        isMove ? LocaleProvider.tr('move_song') : LocaleProvider.tr('copy_song'),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              // Lista de carpetas
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: availableFolders.length,
                  itemBuilder: (context, index) {
                    final folder = availableFolders[index];
                    final originalPath = folderMap[folder]!;
                    final displayName = p.basename(originalPath);
                    
                    return ListTile(
                      leading: const Icon(Icons.folder),
                      title: Text(
                        displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () async {
                        Navigator.of(context).pop();
                        if (isMove) {
                          await _moveSongToFolder(song, originalPath);
                        } else {
                          await _copySongToFolder(song, originalPath);
                        }
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Función para mover una canción a otra carpeta
  Future<void> _moveSongToFolder(SongModel song, String destinationFolder) async {
    // Mostrar diálogo de carga
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return PopScope(
          canPop: false,
          child: AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 24),
                Text(
                  LocaleProvider.tr('moving_song'),
                  style: const TextStyle(fontSize: 16),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        );
      },
    );

    try {
      final sourceFile = File(song.data);
      if (!await sourceFile.exists()) {
        if (mounted) Navigator.of(context).pop(); // Cerrar diálogo
        _showMessage('El archivo no existe.', isError: true);
        return;
      }

      final fileName = p.basename(song.data);
      final destinationPath = p.join(destinationFolder, fileName);
      final destinationFile = File(destinationPath);

      // Verificar si ya existe un archivo con el mismo nombre
      if (await destinationFile.exists()) {
        if (mounted) Navigator.of(context).pop(); // Cerrar diálogo
        _showMessage(LocaleProvider.tr('error_moving_song'), description: LocaleProvider.tr('file_already_exists'), isError: true);
        return;
      }

      // Verificar que la carpeta de destino existe y es accesible
      final destinationDir = Directory(destinationFolder);
      
      if (!await destinationDir.exists()) {
        if (mounted) Navigator.of(context).pop(); // Cerrar diálogo
        _showMessage('La carpeta de destino no existe o no es accesible.\n\nRuta: $destinationFolder', isError: true);
        return;
      }

      // Intentar mover el archivo usando copy + delete como fallback
      bool moveSuccessful = false;
      try {
        // Primero intentar rename (más eficiente)
        await sourceFile.rename(destinationPath);
        moveSuccessful = true;
      } catch (e) {
        // Si rename falla, intentar copy + delete
        try {
          await sourceFile.copy(destinationPath);
          await sourceFile.delete();
          moveSuccessful = true;
        } catch (copyError) {
          // Si copy falla, eliminar el archivo copiado si existe
          try {
            final tempFile = File(destinationPath);
            if (await tempFile.exists()) {
              await tempFile.delete();
            }
          } catch (_) {
            // Ignorar errores al eliminar archivo temporal
          }
          rethrow;
        }
      }

      if (!moveSuccessful) {
        throw Exception('No se pudo mover el archivo');
      }

      // Notificar al MediaStore sobre el archivo original eliminado
      try {
        await MediaScanner.loadMedia(path: song.data);
      } catch (_) {}
      
      // Actualizar el archivo nuevo en el sistema de medios de Android
      await MediaScanner.loadMedia(path: destinationPath);
      
      // Actualizar la base de datos para indexar los cambios
      await SongsIndexDB().forceReindex();
      
      // Actualizar el estado local sin recargar toda la pantalla
      if (carpetaSeleccionada != null) {
        setState(() {
          // Remover la canción de la carpeta actual
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
        shortcutsShouldReload.value = !shortcutsShouldReload.value;
      } catch (_) {}

      // Cerrar diálogo de carga
      if (mounted) Navigator.of(context).pop();

      _showMessage(
        LocaleProvider.tr('song_moved'),
        description: LocaleProvider.tr('song_moved_desc'),
      );

    } catch (e) {
      // Cerrar diálogo de carga en caso de error
      if (mounted) Navigator.of(context).pop();
      
      _showMessage(
        LocaleProvider.tr('error_moving_song'),
        description: '${LocaleProvider.tr('error_moving_song_desc')}\n\nError: ${e.toString()}',
        isError: true,
      );
    }
  }

  // Función para copiar una canción a otra carpeta
  Future<void> _copySongToFolder(SongModel song, String destinationFolder) async {
    // Mostrar diálogo de carga
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return PopScope(
          canPop: false,
          child: AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 24),
                Text(
                  LocaleProvider.tr('copying_song'),
                  style: const TextStyle(fontSize: 16),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        );
      },
    );

    try {
      final sourceFile = File(song.data);
      if (!await sourceFile.exists()) {
        if (mounted) Navigator.of(context).pop(); // Cerrar diálogo
        _showMessage('El archivo no existe.', isError: true);
        return;
      }

      final fileName = p.basename(song.data);
      final destinationPath = p.join(destinationFolder, fileName);
      final destinationFile = File(destinationPath);

      // Verificar si ya existe un archivo con el mismo nombre
      if (await destinationFile.exists()) {
        if (mounted) Navigator.of(context).pop(); // Cerrar diálogo
        _showMessage(LocaleProvider.tr('error_copying_song'), description: LocaleProvider.tr('file_already_exists'), isError: true);
        return;
      }

      // Verificar que la carpeta de destino existe y es accesible
      final destinationDir = Directory(destinationFolder);
      
      if (!await destinationDir.exists()) {
        if (mounted) Navigator.of(context).pop(); // Cerrar diálogo
        _showMessage('La carpeta de destino no existe o no es accesible.\n\nRuta: $destinationFolder', isError: true);
        return;
      }

      // Copiar el archivo
      await sourceFile.copy(destinationPath);

      // Verificar que la copia fue exitosa
      if (!await destinationFile.exists()) {
        throw Exception('La copia no se completó correctamente');
      }

      // Actualizar el archivo nuevo en el sistema de medios de Android
      await MediaScanner.loadMedia(path: destinationPath);
      
      // Actualizar la base de datos para indexar los cambios
      await SongsIndexDB().forceReindex();
      
      // Notificar a otras pantallas que deben refrescar
      try {
        favoritesShouldReload.value = !favoritesShouldReload.value;
        shortcutsShouldReload.value = !shortcutsShouldReload.value;
      } catch (_) {}

      // Cerrar diálogo de carga
      if (mounted) Navigator.of(context).pop();

      _showMessage(
        LocaleProvider.tr('song_copied'),
        description: LocaleProvider.tr('song_copied_desc'),
      );

    } catch (e) {
      // Cerrar diálogo de carga en caso de error
      if (mounted) Navigator.of(context).pop();
      
      _showMessage(
        LocaleProvider.tr('error_copying_song'),
        description: '${LocaleProvider.tr('error_copying_song_desc')}\n\nError: ${e.toString()}',
        isError: true,
      );
    }
  }

  // Función auxiliar para obtener la ruta de carpeta de un archivo
  String _getFolderPath(String filePath) {
    var normalizedPath = p.normalize(filePath);
    var dirPath = p.dirname(normalizedPath);
    dirPath = p.normalize(dirPath);
    if (dirPath.contains('/')) dirPath = dirPath.replaceAll('/', '\\');
    dirPath = dirPath.trim();
    if (dirPath.endsWith('\\') && dirPath.length > 3) {
      dirPath = dirPath.substring(0, dirPath.length - 1);
    }
    dirPath = dirPath.toLowerCase();
    return dirPath;
  }

  // Función para verificar permisos de archivos
  Future<void> _checkFilePermissions(String filePath) async {
    try {
      final file = File(filePath);
      final parentDir = Directory(p.dirname(filePath));
      
      // Verificar si podemos leer el archivo
      if (!await file.exists()) {
        return;
      }
      
      // Verificar si podemos leer el directorio padre
      if (!await parentDir.exists()) {
        return;
      }
      
      // Intentar listar el directorio para verificar permisos
      await parentDir.list().first;
    } catch (e) {
      _showMessage(
        'Advertencia de permisos',
        description: 'Puede haber problemas con los permisos de archivos. Error: ${e.toString()}',
        isError: true,
      );
    }
  }

  // Función para mostrar mensajes de confirmación o error
  void _showMessage(String title, {String? description, bool isError = false}) {
    if (!mounted) return;
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white, width: 1)
                    : BorderSide.none,
              ),
              title: Center(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (description != null) ...[
                      SizedBox(height: 18),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: EdgeInsets.symmetric(horizontal: 4),
                          child: Text(
                            description,
                            style: TextStyle(
                              fontSize: 14,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                            textAlign: TextAlign.left,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      SizedBox(height: 20),
                    ],
                    // Tarjeta de aceptar
                    InkWell(
                      onTap: () => Navigator.of(context).pop(),
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: isAmoled && isDark
                              ? Colors.white.withValues(alpha: 0.2)
                              : Theme.of(context).colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isAmoled && isDark
                                ? Colors.white.withValues(alpha: 0.4)
                                : Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                            width: 2,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: isError
                                    ? null
                                    : (isAmoled && isDark
                                        ? Colors.white.withValues(alpha: 0.2)
                                        : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1)),
                              ),
                              child: Icon(
                                isError ? Icons.error : Icons.check_circle,
                                size: 30,
                                color: isAmoled && isDark
                                    ? Colors.white
                                    : Theme.of(context).colorScheme.primary,
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                LocaleProvider.tr('ok'),
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: isAmoled && isDark
                                      ? Colors.white
                                      : Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _navigateToEditScreen(MediaItem song) async {
    await Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            EditMetadataScreen(song: song),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(1.0, 0.0);
          const end = Offset.zero;
          const curve = Curves.ease;
          final tween = Tween(
            begin: begin,
            end: end,
          ).chain(CurveTween(curve: curve));
          return SlideTransition(
            position: animation.drive(tween),
            child: child,
          );
        },
      ),
    );
  }

  /*Future<void> _navigateToConversionScreen(MediaItem song) async {
    await Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            AudioConversionScreen(song: song),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(1.0, 0.0);
          const end = Offset.zero;
          const curve = Curves.ease;
          final tween = Tween(
            begin: begin,
            end: end,
          ).chain(CurveTween(curve: curve));
          return SlideTransition(
            position: animation.drive(tween),
            child: child,
          );
        },
      ),
    );
  }
  */
}

