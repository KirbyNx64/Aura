import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:music/utils/db/recent_db.dart';
import 'package:music/utils/db/mostplayer_db.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'package:music/main.dart' show audioHandler, getAudioServiceSafely;
import 'package:music/utils/db/favorites_db.dart';
import 'package:music/utils/notifiers.dart';
import 'package:flutter/services.dart';
import 'package:music/utils/db/playlists_db.dart';
import 'package:music/utils/db/playlist_model.dart' as hive_model;
import 'package:audio_service/audio_service.dart';
import 'package:music/screens/home/ota_update_screen.dart';
import 'package:music/screens/home/settings_screen.dart';
import 'package:music/utils/ota_update_helper.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:music/utils/db/shortcuts_db.dart';
import 'package:music/utils/db/songs_index_db.dart';
import 'package:music/utils/db/artists_db.dart';
import 'package:music/utils/db/artist_images_cache_db.dart';
import 'package:music/utils/yt_search/service.dart';
import 'package:music/widgets/hero_cached.dart';
import 'package:mini_music_visualizer/mini_music_visualizer.dart';
import 'package:music/screens/play/player_screen.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:music/utils/song_info_dialog.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:music/screens/artist/artist_screen.dart';
import 'dart:async';

enum OrdenCancionesPlaylist { normal, alfabetico, invertido, ultimoAgregado }

class HomeScreen extends StatefulWidget {
  final void Function(int)? onTabChange;
  final void Function(AppThemeMode)? setThemeMode;
  final void Function(AppColorScheme)? setColorScheme;
  const HomeScreen({
    super.key,
    this.onTabChange,
    this.setThemeMode,
    this.setColorScheme,
  });

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  List<SongModel> _recentSongs = [];
  bool _showingRecents = false;
  bool _showingPlaylistSongs = false;
  List<SongModel> _playlistSongs = [];
  Map<String, dynamic>? _selectedPlaylist;
  double _lastBottomInset = 0.0;
  String? _updateVersion;
  String? _updateApkUrl;
  bool _updateChecked = false;
  
  // Estado de carga
  bool _isLoading = true;

  List<SongModel> _mostPlayed = [];
  final PageController _pageController = PageController(viewportFraction: 0.95);
  final PageController _quickPickPageController = PageController(
    viewportFraction: 0.90,
  );
  List<Map<String, dynamic>> _playlists = [];

  final TextEditingController _searchRecentsController =
      TextEditingController();
  final FocusNode _searchRecentsFocus = FocusNode();
  List<SongModel> _filteredRecents = [];
  OrdenCancionesPlaylist _ordenCancionesPlaylist =
      OrdenCancionesPlaylist.normal;
  static const String _orderPrefsKey = 'home_screen_playlist_order_filter';

  // Controladores y estados para búsqueda en playlist
  final TextEditingController _searchPlaylistController =
      TextEditingController();
  final FocusNode _searchPlaylistFocus = FocusNode();
  List<SongModel> _filteredPlaylistSongs = [];
  List<SongModel> _originalPlaylistSongs = [];
  final List<List<SongModel>> _quickPickPages = [];
  List<SongModel> allSongs = [];

  bool _isSelectingPlaylistSongs = false;
  final Set<int> _selectedPlaylistSongIds = {};

  List<SongModel> _shortcutSongs = [];
  List<SongModel> _randomSongs = []; // Canciones aleatorias para llenar espacios vacíos
  List<SongModel> _shuffledQuickPick = [];
  bool _randomSongsLoaded = false; // Bandera para evitar cargas duplicadas
  List<Map<String, dynamic>> _artists = []; // Lista de artistas populares

  // Cache para los widgets de accesos directos para evitar reconstrucciones
  final Map<String, Widget> _shortcutWidgetCache = {};

  // Cache para los widgets de selección rápida para evitar reconstrucciones
  final Map<String, Widget> _quickPickWidgetCache = {};

  // Cache para los widgets de artistas para evitar reconstrucciones
  final Map<String, Widget> _artistWidgetCache = {};
  final Map<String, Uint8List?> _artworkCache = {};

  Future<Uint8List?> _getCachedArtwork(int songId) async {
    final cacheKey = 'artwork_$songId';
    
    if (_artworkCache.containsKey(cacheKey)) {
      return _artworkCache[cacheKey];
    }
    
    try {
      final artwork = await OnAudioQuery().queryArtwork(
        songId,
        ArtworkType.AUDIO,
        format: ArtworkFormat.JPEG,
        size: 200,
      );
      
      _artworkCache[cacheKey] = artwork;
      return artwork;
    } catch (e) {
      _artworkCache[cacheKey] = null;
      return null;
    }
  }

  Future<void> _handleAddToPlaylistSingle(
    BuildContext context,
    SongModel song,
  ) async {
    final playlists = await PlaylistsDB().getAllPlaylists();
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

  Timer? _playingDebounce;
  Timer? _mediaItemDebounce;
  Timer? _immediateMediaItemDebounce;
  final ValueNotifier<bool> _isPlayingNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<String?> _currentSongPathNotifier =
      ValueNotifier<String?>(null);
  final ValueNotifier<MediaItem?> _currentMediaItemNotifier =
      ValueNotifier<MediaItem?>(null);
  final ValueNotifier<MediaItem?> _immediateMediaItemNotifier =
      ValueNotifier<MediaItem?>(null);

  /// Helper para obtener el AudioHandler de forma segura
  Future<MyAudioHandler?> _getAudioHandler() async {
    final handler = await getAudioServiceSafely();
    return handler as MyAudioHandler?;
  }

  // Devuelve la lista de accesos directos para mostrar en quick_access
          List<SongModel> get _accessDirectSongs {
          final shortcutPaths = _shortcutSongs.map((s) => s.data).toList();
          final randomPaths = _randomSongs.map((s) => s.data).toList();
          final allUsedPaths = {...shortcutPaths, ...randomPaths};
          
          // Mezclar las canciones recientes de forma aleatoria
          final shuffledRecents = List<SongModel>.from(_recentSongs)..shuffle();
          
          final List<SongModel> combined = [
            ..._shortcutSongs,
            ..._mostPlayed.where((s) => !allUsedPaths.contains(s.data)).take(18),
            ..._randomSongs,
            ...shuffledRecents.where((s) => !allUsedPaths.contains(s.data) &&
                                          !_mostPlayed.any((mp) => mp.data == s.data)),
          ];
          return combined.take(100).toList();
        }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeData();
    playlistsShouldReload.addListener(_onPlaylistsShouldReload);
    shortcutsShouldReload.addListener(_onShortcutsShouldReload);
    mostPlayedShouldReload.addListener(_onMostPlayedShouldReload);
    colorSchemeNotifier.addListener(_onThemeChanged);
    _buscarActualizacion();

    // Inicializar con el valor actual si ya hay algo reproduciéndose
    if (audioHandler?.mediaItem.valueOrNull != null) {
      // Cancelar cualquier debounce pendiente
      _immediateMediaItemDebounce?.cancel();
      _mediaItemDebounce?.cancel();
      _immediateMediaItemNotifier.value = audioHandler!.mediaItem.valueOrNull;
      _currentMediaItemNotifier.value = audioHandler!.mediaItem.valueOrNull;
      final path =
          audioHandler!.mediaItem.valueOrNull?.extras?['data'] as String?;
      _currentSongPathNotifier.value = path;
    }

    // Inicializar el estado de reproducción actual
    if (audioHandler?.playbackState.valueOrNull != null) {
      _isPlayingNotifier.value =
          audioHandler!.playbackState.valueOrNull!.playing;
    }

    // Escuchar cambios en el estado de reproducción con debounce
    audioHandler?.playbackState.listen((state) {
      _playingDebounce?.cancel();
      _playingDebounce = Timer(const Duration(milliseconds: 400), () {
        if (mounted) {
          _isPlayingNotifier.value = state.playing;
        }
      });
    });

    // Escuchar cambios en el MediaItem con debounce
    audioHandler?.mediaItem.listen((item) {
      _mediaItemDebounce?.cancel();
      _mediaItemDebounce = Timer(const Duration(milliseconds: 400), () {
        if (mounted) {
          _currentMediaItemNotifier.value = item;
          final path = item?.extras?['data'] as String?;
          _currentSongPathNotifier.value = path;
        }
      });
    });

    // Escuchar cambios inmediatos en el MediaItem (sin debounce)
    audioHandler?.mediaItem.listen((item) {
      _immediateMediaItemDebounce?.cancel();
      _immediateMediaItemDebounce = Timer(const Duration(milliseconds: 50), () {
        if (mounted) {
          _immediateMediaItemNotifier.value = item;
        }
      });
    });
  }

  /// Inicializa todos los datos necesarios para la pantalla de inicio
  Future<void> _initializeData() async {
    try {
      // Cargar filtros de orden
      await _loadOrderFilter();
      
      // Cargar todas las canciones
      await _loadAllSongs();
      
      // Cargar canciones más reproducidas
      await _loadMostPlayed();
      
      // Cargar accesos directos
      await _loadShortcuts();
      
      // Cargar artistas
      await _loadArtists();
      
      // Cargar canciones recientes
      await _loadRecentsData();
      
      // Llenar selección rápida con canciones aleatorias
      await _fillQuickPickWithRandomSongs();
      
      // Inicializar páginas de selección rápida
      _initQuickPickPages();
      
      // Cargar playlists
      await _loadPlaylists();
      
      // Finalizar carga
      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      // En caso de error, mostrar la pantalla de todas formas
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _onPlaylistsShouldReload() {
    _loadPlaylists();
  }

  void _onShortcutsShouldReload() {
    refreshShortcuts();
  }

  void _onMostPlayedShouldReload() {
    _loadMostPlayed();
  }

  void _onThemeChanged() {
    // Limpiar cachés de widgets cuando cambia el tema para forzar reconstrucción
    _artistWidgetCache.clear();
    _shortcutWidgetCache.clear();
    _quickPickWidgetCache.clear();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadOrderFilter() async {
    final prefs = await SharedPreferences.getInstance();
    final int? savedIndex = prefs.getInt(_orderPrefsKey);
    if (savedIndex != null &&
        savedIndex >= 0 &&
        savedIndex < OrdenCancionesPlaylist.values.length) {
      setState(() {
        _ordenCancionesPlaylist = OrdenCancionesPlaylist.values[savedIndex];
      });
    }
  }

  Future<void> _saveOrderFilter() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_orderPrefsKey, _ordenCancionesPlaylist.index);
  }

  void _ordenarCancionesPlaylist() {
    setState(() {
      switch (_ordenCancionesPlaylist) {
        case OrdenCancionesPlaylist.normal:
          _playlistSongs = List.from(_originalPlaylistSongs);
          break;
        case OrdenCancionesPlaylist.alfabetico:
          _playlistSongs.sort((a, b) => a.title.compareTo(b.title));
          break;
        case OrdenCancionesPlaylist.invertido:
          _playlistSongs.sort((a, b) => b.title.compareTo(a.title));
          break;
        case OrdenCancionesPlaylist.ultimoAgregado:
          _playlistSongs = List.from(_originalPlaylistSongs.reversed);
          break;
      }
    });
    _saveOrderFilter();
  }

  Future<void> _loadPinnedSongs() async {
    final prefs = await SharedPreferences.getInstance();
    final pinnedPaths = prefs.getStringList('pinned_songs') ?? [];
    List<SongModel> pinned = [];
    for (final path in pinnedPaths) {
      SongModel? song;
      try {
        song = allSongs.firstWhere((s) => s.data == path);
      } catch (_) {
        try {
          song = _mostPlayed.firstWhere((s) => s.data == path);
        } catch (_) {
          song = null;
        }
      }
      if (song != null) pinned.add(song);
    }
  }

  // Modificar _initQuickPickPages para usar _pinnedSongs y _mostPlayed
  void _initQuickPickPages() {
    _quickPickPages.clear();
    
    // print('🎵 Inicializando QuickPick - Accesos directos: ${_shortcutSongs.length}, Más escuchadas: ${_mostPlayed.length}, Aleatorias: ${_randomSongs.length}, AllSongs: ${allSongs.length}');
    
    // Inicializar la selección rápida mezclada
    _shuffleQuickPick();
    
    // Prioridad: 1) Accesos directos fijos, 2) Canciones más escuchadas, 3) Canciones aleatorias
    final shortcutPaths = _shortcutSongs.map((s) => s.data).toSet();
    final randomPaths = _randomSongs.map((s) => s.data).toSet();
    final allUsedPaths = {...shortcutPaths, ...randomPaths};
    
    final List<SongModel> combined = [];
    
    // 1. Agregar accesos directos fijos
    for (final song in _shortcutSongs) {
      if (!allUsedPaths.contains(song.data)) {
        combined.add(song);
        allUsedPaths.add(song.data);
      }
    }
    // print('🎵 Después de accesos directos: ${combined.length} canciones');
    
    // 2. Agregar canciones más escuchadas que no estén ya en uso
    for (final song in _mostPlayed) {
      if (!allUsedPaths.contains(song.data) && combined.length < 18) {
        combined.add(song);
        allUsedPaths.add(song.data);
      }
    }
    // print('🎵 Después de más escuchadas: ${combined.length} canciones');
    
    // 3. Si aún no tenemos 18 canciones, llenar con canciones aleatorias de _shuffledQuickPick
    if (combined.length < 18) {
      for (final song in _shuffledQuickPick) {
        if (!allUsedPaths.contains(song.data) && combined.length < 18) {
          combined.add(song);
          allUsedPaths.add(song.data);
        }
      }
    }
    // print('🎵 Después de shuffledQuickPick: ${combined.length} canciones');
    
    // 4. Si aún no tenemos 18 canciones, llenar con canciones aleatorias de allSongs
    if (combined.length < 18 && allSongs.isNotEmpty) {
      final availableSongs = allSongs
          .where((s) => !allUsedPaths.contains(s.data))
          .toList();
      availableSongs.shuffle();
      
      final neededSongs = 18 - combined.length;
      combined.addAll(availableSongs.take(neededSongs));
      // print('🎵 Después de allSongs fallback: ${combined.length} canciones');
    }
    
    // Asegurar que tenemos exactamente 18 canciones o las que estén disponibles
    final limited = combined.take(18).toList();
    
    // Dividir la lista en páginas de 6
    for (int i = 0; i < 3; i++) {
      final start = i * 6;
      final end = (start + 6).clamp(0, limited.length);
      if (start < limited.length) {
        _quickPickPages.add(limited.sublist(start, end));
      }
    }
  }

  // Cuando se fije o desfije una canción, recargar accesos directos
  Future<void> refreshPinnedSongs() async {
    await _loadPinnedSongs();
    await _fillQuickPickWithRandomSongs(forceReload: true);
    _initQuickPickPages();
    setState(() {});
  }

  Future<void> _loadShortcuts() async {
    final shortcutPaths = await ShortcutsDB().getShortcuts();
    List<SongModel> shortcutSongs = [];

    // Asegurar que haya canciones disponibles para hacer el mapeo
    List<SongModel> songsSource = allSongs;
    if (songsSource.isEmpty) {
      try {
        // Usar SongsIndexDB para obtener solo canciones no ignoradas
        songsSource = await SongsIndexDB().getIndexedSongs();
        // Persistir también en el estado para futuras búsquedas
        if (mounted) {
          setState(() {
            allSongs = songsSource;
          });
        }
      } catch (_) {}
    }

    // Cargar accesos directos reales
    for (final path in shortcutPaths) {
      try {
        final song = songsSource.firstWhere((s) => s.data == path);
        shortcutSongs.add(song);
      } catch (_) {}
    }

    if (mounted) {
      setState(() {
        // Invalida widgets cacheados para que reflejen el estado de fijado
        _shortcutWidgetCache.clear();
        _shortcutSongs = shortcutSongs;
      });
    }
    
    // Las canciones aleatorias se cargan solo una vez en initState
  }

  Future<void> _loadArtists({bool forceRefresh = false}) async {
    try {
      // print('🎵 Cargando artistas...');
      final artistsDB = ArtistsDB();
      
      // Intentar cargar artistas existentes primero
      List<Map<String, dynamic>> artists = await artistsDB.getTopArtists(limit: 20);
      // print('🎵 Artistas encontrados en DB: ${artists.length}');
      
      // Si no hay artistas y hay canciones disponibles, o si se fuerza el refresh, indexar
      if ((artists.isEmpty && allSongs.isNotEmpty) || forceRefresh) {
        // print('🎵 ${forceRefresh ? 'Forzando' : 'No hay artistas, '}indexando con ${allSongs.length} canciones...');
        await artistsDB.indexArtists(allSongs);
        artists = await artistsDB.getTopArtists(limit: 20);
        // print('🎵 Artistas después de indexar: ${artists.length}');
      }
      
      // Mostrar artistas inmediatamente en la UI
      if (mounted && artists.isNotEmpty) {
        // print('🎵 Mostrando ${artists.length} artistas en UI');
        setState(() {
          _artists = artists;
        });
        
        // Enriquecer artistas con imágenes de YouTube Music en segundo plano
        _enrichArtistsWithYTImages(artists);
      } else if (mounted) {
        // print('🎵 No hay artistas para mostrar');
        setState(() {
          _artists = [];
        });
      }
    } catch (e) {
      // print('🎵 Error cargando artistas: $e');
      // En caso de error, mantener la lista vacía
      if (mounted) {
        setState(() {
          _artists = [];
        });
      }
    }
  }

  // Función para enriquecer artistas con imágenes de YouTube Music usando cache persistente
  Future<void> _enrichArtistsWithYTImages(List<Map<String, dynamic>> artists) async {
    try {
      // print('🎵 Enriqueciendo ${artists.length} artistas con imágenes de YouTube Music...');
      
      // Primero, intentar cargar desde cache
      final artistNames = artists.map((a) => a['name'] as String).toList();
      final cachedImages = await ArtistImagesCacheDB.getCachedArtistImages(artistNames);
      
      // print('📦 Imágenes encontradas en cache: ${cachedImages.length}');
      
      // Crear mapa de cache para búsqueda rápida
      final cacheMap = <String, Map<String, dynamic>>{};
      for (final cached in cachedImages) {
        cacheMap[cached['name']] = cached;
      }
      
      // Aplicar imágenes desde cache
      bool hasUpdates = false;
      for (int i = 0; i < artists.length; i++) {
        final artist = artists[i];
        final artistName = artist['name'];
        
        if (cacheMap.containsKey(artistName)) {
          final cached = cacheMap[artistName]!;
          // print('📦 Usando imagen desde cache para: $artistName');
          
          artists[i] = {
            ...artist,
            'thumbUrl': cached['thumbUrl'],
            'browseId': cached['browseId'],
            'subscribers': cached['subscribers'],
          };
          hasUpdates = true;
        }
      }
      
      // Actualizar UI con imágenes del cache
      if (hasUpdates && mounted) {
        setState(() {
          _artists = List.from(artists);
        });
        _artistWidgetCache.clear();
        // print('🔄 UI actualizada con imágenes del cache');
      }
      
      // Si no hay actualizaciones del cache, actualizar la UI de todos modos para mostrar los artistas
      if (!hasUpdates && mounted) {
        setState(() {
          _artists = List.from(artists);
        });
        _artistWidgetCache.clear();
        // print('🔄 UI actualizada sin imágenes del cache');
      }
      
      // Buscar imágenes faltantes en YouTube Music
      final artistsToSearch = <int>[];
      for (int i = 0; i < artists.length; i++) {
        if (!cacheMap.containsKey(artists[i]['name'])) {
          artistsToSearch.add(i);
        }
      }
      
      // print('🔍 Artistas a buscar en YouTube Music: ${artistsToSearch.length}');
      
      for (final i in artistsToSearch) {
        final artist = artists[i];
        final artistName = artist['name'];
        
        // print('🔍 Buscando imagen para: $artistName');
        
        try {
          // Buscar el artista en YouTube Music con timeout
          final ytArtists = await searchArtists(artistName, limit: 1)
              .timeout(const Duration(seconds: 10));
          // print('🔍 Resultado de búsqueda para $artistName: ${ytArtists.length} artistas encontrados');
        
          if (ytArtists.isNotEmpty) {
            final ytArtist = ytArtists.first;
            // print('✅ Encontrado en YT: ${ytArtist['name']} - Thumb: ${ytArtist['thumbUrl'] != null ? 'Sí' : 'No'}');
            
            // Guardar en cache persistente
            await ArtistImagesCacheDB.cacheArtistImage(
              artistName: artistName,
              thumbUrl: ytArtist['thumbUrl'],
              browseId: ytArtist['browseId'],
              subscribers: ytArtist['subscribers'],
            );
            
            // Actualizar el artista con la información de YouTube Music
            artists[i] = {
              ...artist,
              'thumbUrl': ytArtist['thumbUrl'],
              'browseId': ytArtist['browseId'],
              'subscribers': ytArtist['subscribers'],
            };
            
            // Actualizar la UI inmediatamente cuando se encuentra una imagen
            if (mounted) {
              // print('🔄 Actualizando UI para ${artistName} con imagen: ${ytArtist['thumbUrl']}');
              setState(() {
                _artists = List.from(artists);
              });
              
              // Limpiar cache para forzar reconstrucción del widget
              _artistWidgetCache.clear();
              // print('🗑️ Cache de artistas limpiado');
            }
          } else {
            // print('❌ No se encontró en YouTube Music: $artistName');
            
            // Guardar en cache como "no encontrado" para evitar búsquedas repetidas
            await ArtistImagesCacheDB.cacheArtistImage(
              artistName: artistName,
              thumbUrl: null,
              browseId: null,
              subscribers: null,
            );
          }
        } on TimeoutException {
          // print('⏰ Timeout buscando $artistName en YouTube Music');
        } catch (e) {
          // print('❌ Error buscando $artistName en YouTube Music: $e');
        }
        
        // Pequeña pausa para evitar rate limiting
        await Future.delayed(const Duration(milliseconds: 100));
      }
      
      // Limpiar cache expirado
      final cleanedCount = await ArtistImagesCacheDB.cleanExpiredCache();
      if (cleanedCount > 0) {
        // print('🧹 Limpiados $cleanedCount elementos expirados del cache');
      }
      
      // print('🎵 Enriquecimiento completado');
    } catch (e) {
      // print('🎵 Error enriqueciendo artistas con imágenes de YT: $e');
      // Continuar sin las imágenes si hay error
    }
  }

  /// Fuerza la recarga de artistas (útil cuando se actualiza la biblioteca)
  /*Future<void> _reloadArtists() async {
    try {
      // print('🔄 Recargando artistas...');
      final artistsDB = ArtistsDB();
      
      // Forzar reindexación
      if (allSongs.isNotEmpty) {
        await artistsDB.forceReindex(allSongs);
      }
      
      final artists = await artistsDB.getTopArtists(limit: 20);
      // print('🔄 Artistas recargados: ${artists.length}');
      
      if (mounted) {
        // Limpiar cache de artistas para forzar reconstrucción
        _artistWidgetCache.clear();
        setState(() {
          _artists = artists;
        });
        
        // Enriquecer con imágenes en segundo plano
        if (artists.isNotEmpty) {
          _enrichArtistsWithYTImages(artists);
        }
      }
    } catch (e) {
      // print('❌ Error recargando artistas: $e');
      if (mounted) {
        setState(() {
          _artists = [];
        });
      }
    }
  }*/

  // Mostrar modal con canciones del artista
  Future<void> _showArtistSongsModal(BuildContext context, String artistName, List<SongModel> songs) async {
    // Obtener información del artista desde el cache
    final artistInfo = await ArtistImagesCacheDB.getCachedArtistImage(artistName);
    
    if (!context.mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.7,
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            
            // Header
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Container(
                    width: 60,
                    height: 60,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                    ),
                    child: ClipOval(
                      child: artistInfo?['thumbUrl'] != null
                          ? Image.network(
                              artistInfo!['thumbUrl'],
                              width: 60,
                              height: 60,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) {
                                return Container(
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                                  ),
                                  child: Icon(
                                    Icons.person,
                                    size: 30,
                                    color: Theme.of(context).colorScheme.primary,
                                  ),
                                );
                              },
                              loadingBuilder: (context, child, loadingProgress) {
                                if (loadingProgress == null) return child;
                                return Container(
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                                  ),
                                  child: Center(
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      value: loadingProgress.expectedTotalBytes != null
                                          ? loadingProgress.cumulativeBytesLoaded /
                                              loadingProgress.expectedTotalBytes!
                                          : null,
                                    ),
                                  ),
                                );
                              },
                            )
                          : QueryArtworkWidget(
                              id: songs.isNotEmpty ? songs.first.id : -1,
                              type: ArtworkType.AUDIO,
                              nullArtworkWidget: Container(
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                                ),
                                child: Icon(
                                  Icons.person,
                                  size: 30,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          artistName,
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${songs.length} ${LocaleProvider.tr('songs')}',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: () {
                      Navigator.of(context).pop(); // Cerrar el modal primero
                      Navigator.of(context).push(
                        PageRouteBuilder(
                          pageBuilder: (context, animation, secondaryAnimation) =>
                              ArtistScreen(artistName: artistName),
                          transitionsBuilder: (context, animation, secondaryAnimation, child) {
                            const begin = Offset(1.0, 0.0);
                            const end = Offset.zero;
                            const curve = Curves.ease;
                            var tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
                            return SlideTransition(
                              position: animation.drive(tween),
                              child: child,
                            );
                          },
                        ),
                      );
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).brightness == Brightness.dark
                          ? Theme.of(context).colorScheme.primaryContainer
                          : Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.person_outline,
                            size: 20,
                            color: Theme.of(context).brightness == Brightness.dark
                              ? Theme.of(context).colorScheme.onPrimaryContainer
                              : Theme.of(context).colorScheme.surfaceContainer,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            LocaleProvider.tr('go_to_artist'),
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                              color: Theme.of(context).brightness == Brightness.dark
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
            
            // Songs list
            Expanded(
              child: StreamBuilder<MediaItem?>(
                stream: audioHandler?.mediaItem,
                initialData: audioHandler?.mediaItem.valueOrNull,
                builder: (context, snapshot) {
                  final currentMediaItem = snapshot.data;
                  
                  return ListView.builder(
                    padding: EdgeInsets.only(
                      left: 0,
                      right: 0,
                      bottom: MediaQuery.of(context).padding.bottom,
                    ),
                    itemCount: songs.length,
                    itemBuilder: (context, index) {
                      final song = songs[index];
                      // Usar la misma lógica que _PlaylistListView para detectar la canción actual
                      final isCurrent = currentMediaItem != null && 
                          currentMediaItem.extras?['data'] == song.data;
                      final isAmoledTheme = colorSchemeNotifier.value == AppColorScheme.amoled;
                      
                      return Container(
                        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: isCurrent
                              ? (isAmoledTheme
                                  ? Colors.white.withValues(alpha: 0.15)
                                  : Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.8))
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: ListTile(
                          leading: FutureBuilder<Uint8List?>(
                            future: _getCachedArtwork(song.id),
                            builder: (context, snapshot) {
                              if (snapshot.hasData && snapshot.data != null) {
                                return Container(
                                  width: 50,
                                  height: 50,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(8),
                                    image: DecorationImage(
                                      image: MemoryImage(snapshot.data!),
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                );
                              } else {
                                return Container(
                                  width: 50,
                                  height: 50,
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.surfaceContainer,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Icon(
                                    Icons.music_note,
                                    size: 25, // 50 * 0.5
                                    color: Theme.of(context).colorScheme.onSurface,
                                  ),
                                );
                              }
                            },
                          ),
                          title: Text(
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                              color: isCurrent
                                  ? (isAmoledTheme
                                        ? Colors.white
                                        : Theme.of(context).colorScheme.primary)
                                  : null,
                            ),
                          ),
                          subtitle: Text(
                            song.artist ?? LocaleProvider.tr('unknown_artist'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isCurrent
                                  ? (isAmoledTheme
                                        ? Colors.white
                                        : Theme.of(context).colorScheme.primary)
                                  : null,
                            ),
                          ),
                          tileColor: Colors.transparent,
                          splashColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                          onTap: () async {
                            await _playSongAndOpenPlayer(
                              song,
                              songs,
                              queueSource: '${LocaleProvider.tr('artist')}: $artistName',
                            );
                            if (context.mounted) {
                              Navigator.of(context).pop();
                            }
                          },
                        ),
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

  // Widget para mostrar un artista en círculo
  Widget _buildArtistWidget(Map<String, dynamic> artist, BuildContext context) {
    final String artistKey = 'artist_${artist['name']}_${artist['song_count']}_${artist['thumbUrl'] ?? 'no_image'}_${colorSchemeNotifier.value.name}';
    
    // print('🎨 Construyendo widget para ${artist['name']} - ThumbUrl: ${artist['thumbUrl'] != null ? 'Sí' : 'No'}');
    
    Widget artistWidget;
    if (_artistWidgetCache.containsKey(artistKey)) {
      // print('📦 Usando widget desde cache para ${artist['name']}');
      artistWidget = _artistWidgetCache[artistKey]!;
    } else {
      // print('🆕 Creando nuevo widget para ${artist['name']}');
      artistWidget = AnimatedTapButton(
        onTap: () async {
          // Obtener canciones del artista
          final artistsDB = ArtistsDB();
          final artistSongs = await artistsDB.getArtistSongs(artist['name']);
          
          // Convertir rutas a SongModel
          final List<SongModel> songs = [];
          for (final path in artistSongs) {
            try {
              final song = allSongs.firstWhere((s) => s.data == path);
              songs.add(song);
            } catch (_) {}
          }
          
          if (songs.isNotEmpty && mounted) {
            await _playSongAndOpenPlayer(
              songs.first,
              songs,
              queueSource: '${LocaleProvider.tr('artist')}: ${artist['name']}',
            );
          }
        },
        onLongPress: () async {
          HapticFeedback.mediumImpact();
          if (!context.mounted) return;
          
          // Obtener canciones del artista
          final artistsDB = ArtistsDB();
          final artistSongs = await artistsDB.getArtistSongs(artist['name']);
          
          // Convertir rutas a SongModel
          final List<SongModel> songs = [];
          for (final path in artistSongs) {
            try {
              final song = allSongs.firstWhere((s) => s.data == path);
              songs.add(song);
            } catch (_) {}
          }
          
          if (songs.isNotEmpty && mounted) {
            if (!context.mounted) return;
            await _showArtistSongsModal(context, artist['name'], songs);
          }
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
              ),
              child: ClipOval(
                child: artist['thumbUrl'] != null
                    ? Image.network(
                        artist['thumbUrl'],
                        width: 80,
                        height: 80,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) {
                          return Container(
                            decoration: BoxDecoration(
                              color: colorSchemeNotifier.value == AppColorScheme.amoled
                                  ? Colors.white.withValues(alpha: 0.1)
                                  : Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.8),
                            ),
                            child: Center(
                              child: Icon(
                                Icons.person,
                                size: 40,
                              ),
                            ),
                          );
                        },
                        loadingBuilder: (context, child, loadingProgress) {
                          if (loadingProgress == null) return child;
                          return Container(
                            decoration: BoxDecoration(
                              color: colorSchemeNotifier.value == AppColorScheme.amoled
                                  ? Colors.white.withValues(alpha: 0.1)
                                  : Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.8),
                            ),
                            child: Center(
                              child: CircularProgressIndicator(
                                strokeWidth: 3,
                                value: loadingProgress.expectedTotalBytes != null
                                    ? loadingProgress.cumulativeBytesLoaded /
                                        loadingProgress.expectedTotalBytes!
                                    : null,
                              ),
                            ),
                          );
                        },
                      )
                    : Container(
                        decoration: BoxDecoration(
                          color: colorSchemeNotifier.value == AppColorScheme.amoled
                              ? Colors.white.withValues(alpha: 0.1)
                              : Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.8),
                        ),
                        child: Center(
                          child: Icon(
                            Icons.person,
                            size: 40,
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: 80,
              child: ValueListenableBuilder<AppColorScheme>(
                valueListenable: colorSchemeNotifier,
                builder: (context, colorScheme, child) {
                  return Text(
                    artist['name'],
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w500,
                      fontSize: 14,
                      color: colorScheme == AppColorScheme.amoled 
                          ? Colors.white 
                          : Theme.of(context).colorScheme.onSurface,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      );
      
      _artistWidgetCache[artistKey] = artistWidget;
    }
    
    return artistWidget;
  }

  Future<void> refreshShortcuts() async {
    await _loadShortcuts();
    await _fillQuickPickWithRandomSongs(forceReload: true);
    _initQuickPickPages();
    // Limpiar cache cuando se actualizan los shortcuts
    _shortcutWidgetCache.clear();
    _quickPickWidgetCache.clear();
    _artistWidgetCache.clear();
    setState(() {});
  }

  // Método optimizado para construir widgets de accesos directos: cachea solo la parte visual, handlers frescos
  Widget _buildShortcutWidget(SongModel song, BuildContext context) {
    final String shortcutKey = 'shortcut_${song.id}_${song.data}';
    final isSystem = colorSchemeNotifier.value == AppColorScheme.system;

    // Cachear solo el contenido visual pesado (carátula base, pin, título)
    Widget cachedVisual;
    if (_shortcutWidgetCache.containsKey(shortcutKey)) {
      cachedVisual = _shortcutWidgetCache[shortcutKey]!;
    } else {
      cachedVisual = RepaintBoundary(
        child: AspectRatio(
          aspectRatio: 1,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              children: [
                QueryArtworkWidget(
                  id: song.id,
                  type: ArtworkType.AUDIO,
                  artworkFit: BoxFit.cover,
                  artworkBorder: BorderRadius.circular(12),
                  keepOldArtwork: true,
                  artworkHeight: double.infinity,
                  artworkWidth: double.infinity,
                  artworkQuality: FilterQuality.high,
                  size: 400,
                  nullArtworkWidget: Container(
                    width: 400,
                    height: 400,
                    color: isSystem ? Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.5) : Theme.of(context).colorScheme.surfaceContainer,
                    child: Center(
                      child: Icon(
                        Icons.music_note,
                        color: Theme.of(context).colorScheme.onSurface,
                        size: 48,
                      ),
                    ),
                  ),
                ),
                if (_shortcutSongs.any((s) => s.data == song.data))
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.4),
                        shape: BoxShape.circle,
                      ),
                      padding: const EdgeInsets.all(4),
                      child: const Icon(
                        Icons.push_pin,
                        color: Colors.white,
                        size: 14,
                        shadows: [Shadow(blurRadius: 4, color: Colors.black)],
                      ),
                    ),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 6,
                      horizontal: 6,
                    ),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Colors.black.withAlpha(140),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    child: Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        shadows: [
                          Shadow(
                            blurRadius: 8,
                            color: Colors.black54,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      _shortcutWidgetCache[shortcutKey] = cachedVisual;
    }

    // Detectar si esta canción es la actual con debounce optimizado
    return ValueListenableBuilder<MediaItem?>(
      valueListenable: _immediateMediaItemNotifier,
      builder: (context, immediateMediaItem, child) {
        final path = song.data;
        final isCurrent =
            (immediateMediaItem?.id != null &&
            path.isNotEmpty &&
            (immediateMediaItem!.id == path ||
                immediateMediaItem.extras?['data'] == path));

        // Siempre usar ValueListenableBuilder para mantener estructura consistente
        return ValueListenableBuilder<bool>(
          valueListenable: _isPlayingNotifier,
          builder: (context, playing, child) {
            return _buildOptimizedShortcutTile(
              song: song,
              context: context,
              cachedVisual: cachedVisual,
              isCurrent: isCurrent,
              playing: isCurrent ? playing : false,
            );
          },
        );
      },
    );
  }

  Widget _buildOptimizedShortcutTile({
    required SongModel song,
    required BuildContext context,
    required Widget cachedVisual,
    required bool isCurrent,
    required bool playing,
  }) {
    // Usar AnimatedSwitcher para transición suave de la carátula
    Widget finalVisual = AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      transitionBuilder: (Widget child, Animation<double> animation) {
        return FadeTransition(opacity: animation, child: child);
      },
      child: Container(
        key: ValueKey(
          '${song.id}_$isCurrent',
        ), // Key única para trigger del AnimatedSwitcher
        child: Stack(
          children: [
            cachedVisual,
            // MiniMusicVisualizer en esquina superior izquierda si es la canción actual
            if (isCurrent)
              Positioned(
                top: 6,
                left: 6,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  padding: const EdgeInsets.all(4),
                  child: MiniMusicVisualizer(
                    color: Colors.white,
                    width: 3,
                    height: 12,
                    radius: 3,
                    animate: playing,
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    // Usar AnimatedContainer para transición suave del borde
    Widget childWidget = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        border: Border.all(
          color: isCurrent
              ? Theme.of(context).colorScheme.primary
              : Colors.transparent,
          width: 3,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: finalVisual,
    );

    final widget = AnimatedTapButton(
      onTap: () async {
        // Precargar la carátula antes de reproducir
        unawaited(_preloadArtworkForSong(song));
        if (!mounted) return;
        await _playSongAndOpenPlayer(
          song,
          _accessDirectSongs,
          queueSource: LocaleProvider.tr('quick_access_songs'),
        );
      },
      onLongPress: () async {
        HapticFeedback.mediumImpact();
        if (!context.mounted) return;
        final isPinned = _shortcutSongs.any((s) => s.data == song.data);
        final isFavorite = await FavoritesDB().isFavorite(song.data);
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
                                song.artist ??
                                    LocaleProvider.tr('unknown_artist'),
                                style: TextStyle(fontSize: 14),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Botón de búsqueda para abrir opciones
                        InkWell(
                          onTap: () async {
                            Navigator.of(context).pop();
                            await _showSearchOptions(song);
                          },
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: Theme.of(context).brightness == Brightness.dark
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
                                  color: Theme.of(context).brightness == Brightness.dark
                                    ? Theme.of(context).colorScheme.onPrimaryContainer
                                    : Theme.of(context).colorScheme.surfaceContainer,
                                ),
                                const SizedBox(width: 8),
                                TranslatedText(
                                  'search',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14,
                                    color: Theme.of(context).brightness == Brightness.dark
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
                      if (!context.mounted) return;
                      Navigator.of(context).pop();
                      await (audioHandler as MyAudioHandler).addSongsToQueueEnd(
                        [song],
                      );
                    },
                  ),
                  if (isPinned)
                    ListTile(
                      leading: const Icon(Icons.push_pin),
                      title: TranslatedText('unpin_shortcut'),
                      onTap: () async {
                        if (!context.mounted) return;
                        Navigator.of(context).pop();
                        await ShortcutsDB().removeShortcut(song.data);
                        shortcutsShouldReload.value =
                            !shortcutsShouldReload.value;
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
                      if (!context.mounted) return;
                      Navigator.of(context).pop();
                      if (isFavorite) {
                        await FavoritesDB().removeFavorite(song.data);
                        favoritesShouldReload.value =
                            !favoritesShouldReload.value;
                      } else {
                        await FavoritesDB().addFavorite(song);
                        favoritesShouldReload.value =
                            !favoritesShouldReload.value;
                      }
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.playlist_add),
                    title: TranslatedText('add_to_playlist'),
                    onTap: () async {
                      if (!context.mounted) return;
                      Navigator.of(context).pop();
                      await _handleAddToPlaylistSingle(context, song);
                    },
                  ),
                  if ((song.artist ?? '').trim().isNotEmpty)
                    ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: const TranslatedText('go_to_artist'),
                      onTap: () {
                        if (!context.mounted) return;
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
      child: childWidget,
    );

    return widget;
  }

  // Método optimizado para selección rápida: cachea solo el leading (carátula), handlers frescos
  Widget _buildQuickPickWidget(
    SongModel song,
    BuildContext context,
    List<SongModel> pageSongs,
  ) {
    final String quickPickKey = 'quickpick_leading_${song.id}_${song.data}';
    final isSystem = colorSchemeNotifier.value == AppColorScheme.system;
    Widget leading;
    if (_quickPickWidgetCache.containsKey(quickPickKey)) {
      leading = _quickPickWidgetCache[quickPickKey]!;
    } else {
      leading = ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: QueryArtworkWidget(
          id: song.id,
          type: ArtworkType.AUDIO,
          artworkHeight: 60,
          artworkWidth: 57,
          artworkBorder: BorderRadius.zero,
          artworkFit: BoxFit.cover,
          keepOldArtwork: true,
          nullArtworkWidget: Container(
            color: isSystem ? Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.5) : Theme.of(context).colorScheme.surfaceContainer,
            width: 60,
            height: 67,
            child: Icon(
              Icons.music_note,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      );
      _quickPickWidgetCache[quickPickKey] = leading;
    }

    // Detectar si esta canción es la actual con debounce optimizado
    return ValueListenableBuilder<MediaItem?>(
      valueListenable: _immediateMediaItemNotifier,
      builder: (context, immediateMediaItem, child) {
        final path = song.data;
        final isCurrent =
            (immediateMediaItem?.id != null &&
            path.isNotEmpty &&
            (immediateMediaItem!.id == path ||
                immediateMediaItem.extras?['data'] == path));

        final isAmoledTheme =
            colorSchemeNotifier.value == AppColorScheme.amoled;

        // Solo usar ValueListenableBuilder para el estado de reproducción si es la canción actual
        if (isCurrent) {
          return ValueListenableBuilder<bool>(
            valueListenable: _isPlayingNotifier,
            builder: (context, playing, child) {
              return _buildOptimizedQuickPickTile(
                song: song,
                context: context,
                leading: leading,
                isCurrent: isCurrent,
                playing: playing,
                isAmoledTheme: isAmoledTheme,
                pageSongs: pageSongs,
              );
            },
          );
        } else {
          // Para canciones que no están reproduciéndose, no usar listener de estado
          return _buildOptimizedQuickPickTile(
            song: song,
            context: context,
            leading: leading,
            isCurrent: isCurrent,
            playing: false,
            isAmoledTheme: isAmoledTheme,
            pageSongs: pageSongs,
          );
        }
      },
    );
  }

  Widget _buildOptimizedQuickPickTile({
    required SongModel song,
    required BuildContext context,
    required Widget leading,
    required bool isCurrent,
    required bool playing,
    required bool isAmoledTheme,
    required List<SongModel> pageSongs,
  }) {
    return RepaintBoundary(
      child: ListTile(
        key: ValueKey(song.id),
        contentPadding: const EdgeInsets.symmetric(horizontal: 0),
        splashColor: Colors.transparent,
        leading: leading,
        title: Row(
          children: [
            if (isCurrent)
              Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: MiniMusicVisualizer(
                  color: Theme.of(context).colorScheme.primary,
                  width: 4,
                  height: 15,
                  radius: 4,
                  animate: playing,
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
        subtitle: Text(
          _formatArtistWithDuration(song),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: isCurrent
              ? TextStyle(
                  color: isAmoledTheme
                      ? Colors.white
                      : Theme.of(context).colorScheme.primary,
                )
              : null,
        ),
        trailing: const Opacity(opacity: 0, child: Icon(Icons.more_vert)),
        onTap: () async {
          // Precargar la carátula antes de reproducir
          unawaited(_preloadArtworkForSong(song));
          if (!mounted) return;
          // Usar todas las canciones de selección rápida extendidas (más de 20) para reproducción
          final extendedQuickPick = _shuffledQuickPick.take(100).toList();
          await _playSongAndOpenPlayer(
            song,
            extendedQuickPick,
            queueSource: LocaleProvider.tr('quick_pick_songs'),
          );
        },
        onLongPress: () => _handleLongPress(context, song),
      ),
    );
  }

  Future<void> _buscarActualizacion() async {
    if (_updateChecked) return;
    _updateChecked = true;
    final updateInfo = await OtaUpdateHelper.checkForUpdate();
    if (mounted && updateInfo != null) {
      setState(() {
        _updateVersion = updateInfo.version;
        _updateApkUrl = updateInfo.apkUrl;
      });
    }
  }

  Future<void> _loadAllSongs() async {
    final songs = await SongsIndexDB().getIndexedSongs();
    setState(() {
      allSongs = songs;
    });
  }

  Future<void> _loadPlaylists() async {
    final playlists = await PlaylistsDB().getAllPlaylists();
    List<Map<String, dynamic>> playlistsWithSongs = [];
    for (final playlist in playlists) {
      // playlist es un PlaylistModel, accede directo a sus campos
      playlistsWithSongs.add({
        'id': playlist.id,
        'name': playlist.name,
        'songs': playlist.songPaths,
      });
    }
    setState(() {
      _playlists = playlistsWithSongs;
    });
  }

  Future<void> _loadPlaylistSongs(Map<String, dynamic> playlist) async {
    final songs = await PlaylistsDB().getSongsFromPlaylist(playlist['id']);
    // Limpiar cache de artistas para forzar reconstrucción con contexto correcto
    _artistWidgetCache.clear();
    setState(() {
      _originalPlaylistSongs = List.from(songs);
      _selectedPlaylist = playlist;
      _showingPlaylistSongs = true;
      _showingRecents = false;
    });
    _ordenarCancionesPlaylist();

    // Precargar carátulas de la playlist
    unawaited(_preloadArtworksForSongs(songs));
  }

  /// Función específica para refrescar las canciones de la playlist actual
  Future<void> _refreshPlaylistSongs() async {
    if (_selectedPlaylist != null) {
      final songs = await PlaylistsDB().getSongsFromPlaylist(_selectedPlaylist!['id']);
      setState(() {
        _originalPlaylistSongs = List.from(songs);
      });
      _ordenarCancionesPlaylist();

      // Precargar carátulas de la playlist
      unawaited(_preloadArtworksForSongs(songs));
    }
  }

  Future<void> _loadMostPlayed() async {
    final songs = await MostPlayedDB().getMostPlayed(limit: 40);
    setState(() {
      _mostPlayed = songs;
    });
    _shuffleQuickPick();

    // Limpiar cache de selección rápida cuando se cargan nuevas canciones
    _quickPickWidgetCache.clear();

    // Precargar carátulas de canciones más reproducidas
    unawaited(_preloadArtworksForSongs(songs));
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

  Future<void> _preloadArtworkForSong(SongModel song) async {
    try {
      await getOrCacheArtwork(song.id, song.data);
    } catch (e) {
      // Ignorar errores de precarga
    }
  }

  Future<void> _loadRecents() async {
    try {
      final recents = await RecentsDB().getRecents();
      setState(() {
        _recentSongs = recents;
        _showingRecents = true;
      });

      // Precargar carátulas de canciones recientes
      unawaited(_preloadArtworksForSongs(recents));
    } catch (e) {
      setState(() {
        _recentSongs = [];
        _showingRecents = true;
      });
    }
  }

  // Método para cargar solo los datos de recientes sin mostrar la UI
  Future<void> _loadRecentsData() async {
    try {
      final recents = await RecentsDB().getRecents();
      setState(() {
        _recentSongs = recents;
        // No cambiamos _showingRecents aquí
      });

      // Precargar carátulas de canciones recientes
      unawaited(_preloadArtworksForSongs(recents));
    } catch (e) {
      setState(() {
        _recentSongs = [];
        // No cambiamos _showingRecents aquí
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
    List<SongModel> filteredList = _playlistSongs.where((song) {
      final title = _quitarDiacriticos(song.title);
      final artist = _quitarDiacriticos(song.artist ?? '');
      return title.contains(query) || artist.contains(query);
    }).toList();

    setState(() {
      _filteredPlaylistSongs = filteredList;
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

  // Agrega la key global arriba en HomeScreenState
  final GlobalKey ytScreenKey = GlobalKey();


  bool canPopInternally() {
    // Retorna true si hay navegación interna (recientes o playlist songs abiertos)
    return _showingRecents || _showingPlaylistSongs;
  }

  void handleInternalPop() {
    // Manejar navegación interna de home screen
    if (_showingRecents || _showingPlaylistSongs) {
      // Limpiar cache de artistas para forzar reconstrucción con contexto correcto
      _artistWidgetCache.clear();
      setState(() {
        _showingRecents = false;
        _showingPlaylistSongs = false;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    playlistsShouldReload.removeListener(_onPlaylistsShouldReload);
    shortcutsShouldReload.removeListener(_onShortcutsShouldReload);
    mostPlayedShouldReload.removeListener(_onMostPlayedShouldReload);
    colorSchemeNotifier.removeListener(_onThemeChanged);
    _pageController.dispose();
    _searchRecentsController.dispose();
    _searchRecentsFocus.dispose();
    _searchPlaylistController.dispose();
    _searchPlaylistFocus.dispose();
    _playingDebounce?.cancel();
    _mediaItemDebounce?.cancel();
    _immediateMediaItemDebounce?.cancel();
    _isPlayingNotifier.dispose();
    _currentSongPathNotifier.dispose();
    _currentMediaItemNotifier.dispose();
    _immediateMediaItemNotifier.dispose();
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

  Future<void> _playSongAndOpenPlayer(
    SongModel song,
    List<SongModel> queue, {
    String? queueSource,
  }) async {
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
            position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
                .animate(
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
    // print('🟢 Activando loading...');
    playLoadingNotifier.value = true;
    // print('🟢 Loading activado: ${playLoadingNotifier.value}');

    // Reproducir la canción después de un breve delay para que se abra la pantalla
    Future.delayed(const Duration(milliseconds: 400), () async {
      try {
        if (mounted) {
          // Primero reproducir la canción
          await _playSong(song, queue, queueSource: queueSource);
          
          // Luego agregar las canciones aleatorias al reproductor (si es necesario)
          if (queueSource == LocaleProvider.tr('quick_access_songs') || 
              queueSource == LocaleProvider.tr('quick_pick_songs')) {
            // Esperar un poco para que la reproducción se estabilice
            await Future.delayed(const Duration(milliseconds: 200));
            await _addRandomSongsToPlayerQueue(queue);
          }
        }
      } catch (e) {
        // print('Error en reproducción: $e');
      }
    });
    
    // Desactivar loading después de un tiempo fijo (más confiable)
    Future.delayed(const Duration(milliseconds: 800), () {
      // print('🔴 Desactivando loading...');
      playLoadingNotifier.value = false;
      // print('🔴 Loading desactivado: ${playLoadingNotifier.value}');
    });
  }

  Future<void> _playSong(
    SongModel song,
    List<SongModel> queue, {
    String? queueSource,
  }) async {
    // Desactiva visualmente el shuffle
    try {
      final handler = await _getAudioHandler();
      if (handler != null) {
        handler.isShuffleNotifier.value = false;
      }
    } catch (_) {}
    const int maxQueueSongs = 200;
    final index = queue.indexWhere((s) => s.data == song.data);

    if (index != -1) {
      // Obtener AudioService de forma segura
      final handler = await _getAudioHandler();
      if (handler == null) {
        return;
      }

      // Comprobar si la cola actual es igual a la nueva (por ids y orden)
      final currentQueue = handler.queue.value;
      final isSameQueue =
          currentQueue.length == queue.length &&
          List.generate(
            queue.length,
            (i) => currentQueue[i].id == queue[i].data,
          ).every((x) => x);

      if (isSameQueue) {
        // Solo cambiar de canción
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

      int before = (maxQueueSongs / 2).floor();
      int after = maxQueueSongs - before;
      int start = (index - before).clamp(0, queue.length);
      int end = (index + after).clamp(0, queue.length);
      List<SongModel> limitedQueue = queue.sublist(start, end);
      int newIndex = index - start;

      // Guardar el origen en SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      String origen =
          queueSource ??
          (_showingPlaylistSongs && _selectedPlaylist != null
              ? "${_selectedPlaylist?['name'] ?? ''}"
              : _showingRecents
              ? LocaleProvider.tr('recent_songs_title')
              : "Home");
      await prefs.setString('last_queue_source', origen);
      await (handler).setQueueFromSongs(limitedQueue, initialIndex: newIndex);
      await (handler).play();
    }
  }

  Future<void> _addToFavorites(SongModel song) async {
    await FavoritesDB().addFavorite(song);
    favoritesShouldReload.value = !favoritesShouldReload.value;
  }

  Future<void> _handleLongPress(BuildContext context, SongModel song) async {
    HapticFeedback.mediumImpact();
    final isFavorite = await FavoritesDB().isFavorite(song.data);

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
                    // Botón de búsqueda para abrir opciones
                    InkWell(
                      onTap: () async {
                        Navigator.of(context).pop();
                        await _showSearchOptions(song);
                      },
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context).brightness == Brightness.dark
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
                              color: Theme.of(context).brightness == Brightness.dark
                                ? Theme.of(context).colorScheme.onPrimaryContainer
                                : Theme.of(context).colorScheme.surfaceContainer,
                            ),
                            const SizedBox(width: 8),
                            TranslatedText(
                              'search',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                                color: Theme.of(context).brightness == Brightness.dark
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
                  if (!context.mounted) return;
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
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.playlist_add),
                title: TranslatedText('add_to_playlist'),
                onTap: () async {
                  if (!context.mounted) return;
                  Navigator.of(context).pop();
                  await _handleAddToPlaylistSingle(context, song);
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
  }

  Future<void> _removeFromPlaylistMassive() async {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    final selectedSongs =
        (_searchPlaylistController.text.isNotEmpty
                ? _filteredPlaylistSongs
                : _playlistSongs)
            .where((s) => _selectedPlaylistSongIds.contains(s.id));
    final count = _selectedPlaylistSongIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: isAmoled && isDark
              ? const BorderSide(color: Colors.white, width: 1)
              : BorderSide.none,
        ),
        title: TranslatedText('remove_from_playlist'),
        content: Text(
          count == 1
              ? LocaleProvider.tr('confirm_remove_from_playlist')
              : "${LocaleProvider.tr('confirm_remove_from_playlist')} ($count)",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: TranslatedText('cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: TranslatedText('remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final song in selectedSongs) {
      await PlaylistsDB().removeSongFromPlaylist(
        _selectedPlaylist!['id'],
        song.data,
      );
    }
    await _loadPlaylistSongs(_selectedPlaylist!);
    setState(() {
      _isSelectingPlaylistSongs = false;
      _selectedPlaylistSongIds.clear();
    });
  }

  Future<void> _addToFavoritesMassive() async {
    final selectedSongs =
        (_searchPlaylistController.text.isNotEmpty
                ? _filteredPlaylistSongs
                : _playlistSongs)
            .where((s) => _selectedPlaylistSongIds.contains(s.id));
    for (final song in selectedSongs) {
      await FavoritesDB().addFavorite(song);
    }
    favoritesShouldReload.value = !favoritesShouldReload.value;
    setState(() {
      _isSelectingPlaylistSongs = false;
      _selectedPlaylistSongIds.clear();
    });
  }

  void _onPlaylistSongSelected(SongModel song) {
    if (_isSelectingPlaylistSongs) {
      setState(() {
        if (_selectedPlaylistSongIds.contains(song.id)) {
          _selectedPlaylistSongIds.remove(song.id);
          if (_selectedPlaylistSongIds.isEmpty) {
            _isSelectingPlaylistSongs = false;
          }
        } else {
          _selectedPlaylistSongIds.add(song.id);
        }
      });
      return;
    }
    // La reproducción debe hacerse por debounce desde el onTap del ListTile
  }

  Future<void> _showAddFromRecentsToCurrentPlaylistDialog() async {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isSystem = colorSchemeNotifier.value == AppColorScheme.system;
    
    final recents = await RecentsDB().getRecents();
    if (!mounted) return;
    final Set<int> selectedIds = {};
    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white, width: 1)
                    : BorderSide.none,
              ),
              title: TranslatedText('add_from_recents'),
              content: SizedBox(
                width: double.maxFinite,
                height: 400,
                child: recents.isEmpty
                    ? Center(child: TranslatedText('no_songs'))
                    : ListView.builder(
                        itemCount: recents.length,
                        itemBuilder: (context, index) {
                          final song = recents[index];
                          final isSelected = selectedIds.contains(song.id);
                          return ListTile(
                            onTap: () {
                              setStateDialog(() {
                                if (isSelected) {
                                  selectedIds.remove(song.id);
                                } else {
                                  selectedIds.add(song.id);
                                }
                              });
                            },
                            leading: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Checkbox(
                                  value: isSelected,
                                  onChanged: (checked) {
                                    setStateDialog(() {
                                      if (checked == true) {
                                        selectedIds.add(song.id);
                                      } else {
                                        selectedIds.remove(song.id);
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
                                    artworkHeight: 40,
                                    artworkWidth: 40,
                                    keepOldArtwork: true,
                                    nullArtworkWidget: Container(
                                      color: isSystem ? Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.5) : Theme.of(context).colorScheme.surfaceContainer,
                                      width: 40,
                                      height: 40,
                                      child: Icon(
                                        Icons.music_note,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurface,
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
                            ),
                            subtitle: Text(
                              _formatArtistWithDuration(song),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        },
                      ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: TranslatedText('cancel'),
                ),
                TextButton(
                  onPressed: selectedIds.isEmpty
                      ? null
                      : () async {
                          final toAdd = recents.where(
                            (s) => selectedIds.contains(s.id),
                          );
                          for (final song in toAdd) {
                            await PlaylistsDB().addSongToPlaylist(
                              _selectedPlaylist!['id'],
                              song,
                            );
                          }
                          if (context.mounted) {
                            Navigator.of(context).pop();
                            await _loadPlaylistSongs(_selectedPlaylist!);

                            // Notificar a otras pantallas que deben actualizar las playlists
                            playlistsShouldReload.value =
                                !playlistsShouldReload.value;
                          }
                        },
                  child: TranslatedText('add'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _shuffleQuickPick() {
    final shortcutPaths = _shortcutSongs.map((s) => s.data).toSet();
    final randomPaths = _randomSongs.map((s) => s.data).toSet();
    final allUsedPaths = {...shortcutPaths, ...randomPaths};
    
    // Crear una lista combinada con canciones más escuchadas y aleatorias
    final List<SongModel> combinedSongs = [];
    
    // Agregar canciones más escuchadas que no estén ya en uso
    for (final song in _mostPlayed) {
      if (!allUsedPaths.contains(song.data)) {
        combinedSongs.add(song);
        allUsedPaths.add(song.data);
      }
    }
    
    // Agregar canciones aleatorias que no estén ya en uso
    for (final song in _randomSongs) {
      if (!allUsedPaths.contains(song.data)) {
        combinedSongs.add(song);
        allUsedPaths.add(song.data);
      }
    }
    
    // Si no hay suficientes canciones, usar canciones de allSongs
    if (combinedSongs.length < 50 && allSongs.isNotEmpty) {
      final availableSongs = allSongs
          .where((s) => !allUsedPaths.contains(s.data))
          .toList();
      availableSongs.shuffle();
      
      final neededSongs = 50 - combinedSongs.length;
      combinedSongs.addAll(availableSongs.take(neededSongs));
    }
    
    // Mezclar todas las canciones
    combinedSongs.shuffle();
    _shuffledQuickPick = combinedSongs;
    
    // Limpiar cache de selección rápida cuando se actualiza la lista
    _quickPickWidgetCache.clear();
  }

  // Función para agregar 50 canciones aleatorias SOLO al reproductor (no visualmente)
  Future<void> _addRandomSongsToPlayerQueue(List<SongModel> currentQueue) async {
    try {
      final songsIndexDB = SongsIndexDB();
      
      // Obtener canciones aleatorias frescas de la base de datos
      final randomPaths = await songsIndexDB.getRandomSongs(limit: 50);
      
      // Convertir rutas a SongModel y filtrar duplicados
      final Set<String> usedPaths = currentQueue.map((s) => s.data).toSet();
      // También excluir canciones que ya están en accesos directos fijos
      final shortcutPaths = _shortcutSongs.map((s) => s.data).toSet();
      // Y excluir también las canciones más escuchadas
      final mostPlayedPaths = _mostPlayed.map((s) => s.data).toSet();
      usedPaths.addAll(shortcutPaths);
      usedPaths.addAll(mostPlayedPaths);
      
      final List<SongModel> randomSongsForPlayer = [];
      
      for (final path in randomPaths) {
        if (!usedPaths.contains(path) && randomSongsForPlayer.length < 50) {
          try {
            final song = allSongs.firstWhere((s) => s.data == path);
            randomSongsForPlayer.add(song);
            usedPaths.add(path);
          } catch (_) {
            // Si no se encuentra en allSongs, intentar obtenerla de la base de datos indexada
            try {
              final songs = await SongsIndexDB().getIndexedSongs();
              final foundSong = songs.firstWhere((s) => s.data == path);
              randomSongsForPlayer.add(foundSong);
              usedPaths.add(path);
            } catch (_) {}
          }
        }
      }
      
      // Agregar las canciones aleatorias al final de la cola actual del reproductor
      if (randomSongsForPlayer.isNotEmpty) {
        final audioHandler = await _getAudioHandler();
        if (audioHandler != null) {
          // Agregar las canciones aleatorias al final de la cola
          await audioHandler.addSongsToQueueEnd(randomSongsForPlayer);
          // print('✅ Agregadas ${randomSongsForPlayer.length} canciones aleatorias al reproductor');
        }
      } else {
        // print('⚠️ No se encontraron canciones aleatorias para agregar');
      }
      
    } catch (e) {
      // En caso de error, no hacer nada para no interrumpir la reproducción
      // print('❌ Error agregando canciones aleatorias al reproductor: $e');
    }
  }

  // Función para llenar la selección rápida con canciones aleatorias adicionales
  Future<void> _fillQuickPickWithRandomSongs({bool forceReload = false}) async {
    // Evitar cargas duplicadas a menos que se fuerce la recarga
    if (_randomSongsLoaded && !forceReload) return;
    
    // Si se fuerza la recarga, resetear la bandera
    if (forceReload) {
      _randomSongsLoaded = false;
    }
    
    try {
      final songsIndexDB = SongsIndexDB();
      
      // Obtener canciones aleatorias de la base de datos
      final randomPaths = await songsIndexDB.getRandomSongs(limit: 50);
      // print('🎵 Obtenidas ${randomPaths.length} canciones aleatorias de la DB');
      
      // Convertir rutas a SongModel y filtrar duplicados
      final Set<String> usedPaths = _shuffledQuickPick.map((s) => s.data).toSet();
      final List<SongModel> newRandomSongs = [];
      
      for (final path in randomPaths) {
        if (!usedPaths.contains(path) && newRandomSongs.length < 50) {
          try {
            final song = allSongs.firstWhere((s) => s.data == path);
            newRandomSongs.add(song);
            usedPaths.add(path);
          } catch (_) {
            // Si no se encuentra en allSongs, intentar obtenerla de la base de datos indexada
            try {
              final songs = await SongsIndexDB().getIndexedSongs();
              final foundSong = songs.firstWhere((s) => s.data == path);
              newRandomSongs.add(foundSong);
              usedPaths.add(path);
            } catch (_) {}
          }
        }
      }
      
      // print('🎵 Canciones aleatorias convertidas: ${newRandomSongs.length}');
      
      // Si no se obtuvieron suficientes canciones de la base de datos, usar allSongs como fallback
      if (newRandomSongs.length < 30 && allSongs.isNotEmpty) {
        final availableSongs = allSongs
            .where((s) => !usedPaths.contains(s.data))
            .toList();
        availableSongs.shuffle();
        
        final neededSongs = 50 - newRandomSongs.length;
        newRandomSongs.addAll(availableSongs.take(neededSongs));
        // print('🎵 Agregadas ${neededSongs} canciones de allSongs como fallback');
      }
      
      // Actualizar _randomSongs con las nuevas canciones aleatorias
      if (mounted) {
        setState(() {
          _randomSongs = newRandomSongs;
          _randomSongsLoaded = true; // Marcar como cargado
        });
        // print('🎵 Total de canciones aleatorias cargadas: ${_randomSongs.length}');
      }
      
      // Limpiar cache de selección rápida cuando se actualiza la lista
      _quickPickWidgetCache.clear();
      
    } catch (e) {
      // print('❌ Error cargando canciones aleatorias: $e');
      // En caso de error, usar canciones de allSongs como fallback
      if (allSongs.isNotEmpty) {
        final availableSongs = allSongs
            .where((s) => !_shuffledQuickPick.any((existing) => existing.data == s.data))
            .toList();
        availableSongs.shuffle();
        
        if (mounted) {
          setState(() {
            _randomSongs = availableSongs.take(50).toList();
            _randomSongsLoaded = true; // Marcar como cargado
          });
          // print('🎵 Usando fallback con ${_randomSongs.length} canciones de allSongs');
        }
      }
    }
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

  @override
  Widget build(BuildContext context) {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    // Mostrar pantalla de carga mientras se cargan las bases de datos
    if (_isLoading) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Icono de música con animación
              TweenAnimationBuilder<double>(
                duration: const Duration(seconds: 2),
                tween: Tween(begin: 0.0, end: 1.0),
                builder: (context, value, child) {
                  return Transform.scale(
                    scale: 0.8 + (0.2 * value),
                    child: Opacity(
                      opacity: value,
                      child: Container(
                        width: 120,
                        height: 120,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(60),
                        ),
                        child: Icon(
                          Icons.music_note,
                          size: 60,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                  );
                },
              ),
              
              const SizedBox(height: 32),
              
              // Indicador de progreso
              SizedBox(
                width: 200,
                child: LinearProgressIndicator(
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(8),
                  backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final quickPickSongsPerPage = 4;
    final limitedQuickPick = _shuffledQuickPick.take(20).toList();
    // Lista extendida para reproducción (más de 20 canciones)
    final extendedQuickPick = _shuffledQuickPick.take(50).toList();
    final quickPickPageCount = limitedQuickPick.isEmpty
        ? 0
        : (limitedQuickPick.length / quickPickSongsPerPage).ceil();

    return Scaffold(
        appBar: AppBar(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: (_showingRecents || _showingPlaylistSongs)
              ? (_isSelectingPlaylistSongs
                    ? null
                    : IconButton(
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
                        onPressed: () {
                          // Limpiar cache de artistas para forzar reconstrucción con contexto correcto
                          _artistWidgetCache.clear();
                          setState(() {
                            _showingRecents = false;
                            _showingPlaylistSongs = false;
                          });
                        },
                      ))
              : null,
          title: Row(
            children: [
              Expanded(
                child: _showingRecents
                    ? TranslatedText(
                        'recent',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )
                    : _showingPlaylistSongs
                    ? (_isSelectingPlaylistSongs
                          ? Text(
                              '${_selectedPlaylistSongIds.length} ${LocaleProvider.tr('selected')}',
                            )
                          : ((_selectedPlaylist?['name'] ?? '').isNotEmpty
                                ? Text(
                                    (_selectedPlaylist?['name'] ?? '').length >
                                            15
                                        ? (_selectedPlaylist?['name'] ?? '')
                                                  .substring(0, 15) +
                                              '...'
                                        : (_selectedPlaylist?['name'] ?? ''),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  )
                                : TranslatedText(
                                    'playlists',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  )))
                    : Row(
                        children: [
                          SvgPicture.asset(
                            'assets/icon/icon_foreground.svg',
                            width: 32,
                            height: 32,
                            colorFilter: ColorFilter.mode(
                              Theme.of(context).colorScheme.inverseSurface,
                              BlendMode.srcIn,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            "Aura",
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            "Music",
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          ),
          actions: (!_showingRecents && !_showingPlaylistSongs)
              ? [
                  IconButton(
                    icon: const Icon(Icons.history, size: 28),
                    tooltip: LocaleProvider.tr('recent_songs'),
                    onPressed: _loadRecents,
                  ),
                  IconButton(
                    icon: const Icon(Icons.settings_outlined, size: 28),
                    tooltip: LocaleProvider.tr('settings'),
                    onPressed: () {
                      Navigator.of(context).push(
                        PageRouteBuilder(
                          pageBuilder:
                              (context, animation, secondaryAnimation) =>
                                  SettingsScreen(
                                    setThemeMode: widget.setThemeMode,
                                    setColorScheme: widget.setColorScheme,
                                  ),
                          transitionsBuilder:
                              (context, animation, secondaryAnimation, child) {
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
                ]
              : _showingPlaylistSongs
              ? [
                  if (_isSelectingPlaylistSongs) ...[
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: LocaleProvider.tr('remove_from_playlist'),
                      onPressed: _selectedPlaylistSongIds.isEmpty
                          ? null
                          : _removeFromPlaylistMassive,
                    ),
                    IconButton(
                      icon: const Icon(Symbols.favorite_rounded, weight: 600),
                      tooltip: LocaleProvider.tr('add_to_favorites'),
                      onPressed: _selectedPlaylistSongIds.isEmpty
                          ? null
                          : _addToFavoritesMassive,
                    ),
                    IconButton(
                      icon: const Icon(Icons.select_all),
                      tooltip: LocaleProvider.tr('select_all'),
                      onPressed: () {
                        final songsToShow =
                            _searchPlaylistController.text.isNotEmpty
                            ? _filteredPlaylistSongs
                            : _playlistSongs;
                        setState(() {
                          if (_selectedPlaylistSongIds.length ==
                              songsToShow.length) {
                            // Si todos están seleccionados, deseleccionar todos
                            _selectedPlaylistSongIds.clear();
                            if (_selectedPlaylistSongIds.isEmpty) {
                              _isSelectingPlaylistSongs = false;
                            }
                          } else {
                            // Seleccionar todos
                            _selectedPlaylistSongIds.addAll(
                              songsToShow.map((s) => s.id),
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
                          _isSelectingPlaylistSongs = false;
                          _selectedPlaylistSongIds.clear();
                        });
                      },
                    ),
                  ] else ...[
                    IconButton(
                      icon: const Icon(Symbols.shuffle_rounded, size: 28, weight: 600),
                      tooltip: LocaleProvider.tr('shuffle'),
                      onPressed: () {
                        final List<SongModel> songsToShow =
                            _searchPlaylistController.text.isNotEmpty
                            ? _filteredPlaylistSongs
                            : _playlistSongs;
                        if (songsToShow.isNotEmpty) {
                          final random =
                              (songsToShow.toList()..shuffle()).first;
                          // Precargar la carátula antes de reproducir
                          unawaited(_preloadArtworkForSong(random));
                          _playSongAndOpenPlayer(
                            random,
                            songsToShow,
                            queueSource: _selectedPlaylist?['name'] ?? '',
                          );
                        }
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.add, size: 28),
                      tooltip: LocaleProvider.tr('add_from_recents'),
                      onPressed: _showAddFromRecentsToCurrentPlaylistDialog,
                    ),
                    PopupMenuButton<OrdenCancionesPlaylist>(
                      icon: const Icon(Icons.sort, size: 28),
                      tooltip: LocaleProvider.tr('filters'),
                      onSelected: (orden) {
                        setState(() {
                          _ordenCancionesPlaylist = orden;
                          _ordenarCancionesPlaylist();
                        });
                      },
                      itemBuilder: (context) => [
                        PopupMenuItem(
                          value: OrdenCancionesPlaylist.normal,
                          child: TranslatedText('last_added'),
                        ),
                        PopupMenuItem(
                          value: OrdenCancionesPlaylist.ultimoAgregado,
                          child: TranslatedText('invert_order'),
                        ),
                        PopupMenuItem(
                          value: OrdenCancionesPlaylist.alfabetico,
                          child: TranslatedText('alphabetical_az'),
                        ),
                        PopupMenuItem(
                          value: OrdenCancionesPlaylist.invertido,
                          child: TranslatedText('alphabetical_za'),
                        ),
                      ],
                    ),
                  ],
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
                        hintText: LocaleProvider.tr(
                          'search_by_title_or_artist',
                        ),
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon:
                            (_showingRecents
                                ? _searchRecentsController.text.isNotEmpty
                                : _searchPlaylistController.text.isNotEmpty)
                            ? IconButton(
                                icon: const Icon(Icons.close),
                                onPressed: () {
                                  if (_showingRecents) {
                                    _searchRecentsController.clear();
                                    _onSearchRecentsChanged();
                                    setState(() {});
                                  } else {
                                    _searchPlaylistController.clear();
                                    _onSearchPlaylistChanged();
                                    setState(() {});
                                  }
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
                )
              : null,
        ),
        body: ValueListenableBuilder<MediaItem?>(
          valueListenable: _currentMediaItemNotifier,
          builder: (context, debouncedMediaItem, child) {
            final space = debouncedMediaItem != null ? 100.0 : 0.0;

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
                          return Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.history,
                                  size: 48,
                                  color: Theme.of(context).colorScheme.onSurface
                                      .withValues(alpha: 0.6),
                                ),
                                const SizedBox(height: 16),
                                TranslatedText(
                                  'no_recent_songs',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.6),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }
                        return ValueListenableBuilder<MediaItem?>(
                          valueListenable: _immediateMediaItemNotifier,
                          builder: (context, immediateMediaItem, child) {
                            return ListView.builder(
                              itemCount: songsToShow.length,
                              itemBuilder: (context, index) {
                                final song = songsToShow[index];
                                final path = song.data;
                                final isCurrent =
                                    (immediateMediaItem?.id != null &&
                                    path.isNotEmpty &&
                                    (immediateMediaItem!.id == path ||
                                        immediateMediaItem.extras?['data'] ==
                                            path));
                                final isAmoledTheme =
                                    colorSchemeNotifier.value ==
                                    AppColorScheme.amoled;
                                final isSystem = colorSchemeNotifier.value == AppColorScheme.system;

                                // Solo usar ValueListenableBuilder para la canción actual
                                if (isCurrent) {
                                  return ValueListenableBuilder<bool>(
                                    valueListenable: _isPlayingNotifier,
                                    builder: (context, playing, child) {
                                      return ListTile(
                                        leading: ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          child: QueryArtworkWidget(
                                            id: song.id,
                                            type: ArtworkType.AUDIO,
                                            artworkBorder:
                                                BorderRadius.circular(8),
                                            artworkHeight: 50,
                                            artworkWidth: 50,
                                            keepOldArtwork: true,
                                            nullArtworkWidget: Container(
                                              color: isSystem ? Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.5) : Theme.of(context).colorScheme.surfaceContainer,
                                              width: 50,
                                              height: 50,
                                              child: Icon(
                                                Icons.music_note,
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.onSurface,
                                              ),
                                            ),
                                          ),
                                        ),
                                        title: Row(
                                          children: [
                                            if (isCurrent)
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  right: 8.0,
                                                ),
                                                child: MiniMusicVisualizer(
                                                  color: Theme.of(
                                                    context,
                                                  ).colorScheme.primary,
                                                  width: 4,
                                                  height: 15,
                                                  radius: 4,
                                                  animate: playing
                                                      ? true
                                                      : false,
                                                ),
                                              ),
                                            Expanded(
                                              child: Text(
                                                song.title,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .titleMedium
                                                    ?.copyWith(
                                                      fontWeight: isCurrent
                                                          ? FontWeight.bold
                                                          : FontWeight.normal,
                                                      color: isCurrent
                                                          ? (isAmoledTheme
                                                                ? Colors.white
                                                                : Theme.of(
                                                                        context,
                                                                      )
                                                                      .colorScheme
                                                                      .primary)
                                                          : Theme.of(context)
                                                                .colorScheme
                                                                .onSurface,
                                                    ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        subtitle: Text(
                                          _formatArtistWithDuration(song),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        trailing: IconButton(
                                          icon: Icon(
                                            isCurrent && playing
                                                ? Symbols.pause_rounded
                                                : Symbols.play_arrow_rounded,
                                          grade: 200,
                                          fill: 1,
                                          ),
                                          onPressed: () {
                                            if (isCurrent) {
                                              playing
                                                  ? (audioHandler
                                                            as MyAudioHandler)
                                                        .pause()
                                                  : (audioHandler
                                                            as MyAudioHandler)
                                                        .play();
                                            } else {
                                              // Precargar la carátula antes de reproducir
                                              unawaited(
                                                _preloadArtworkForSong(song),
                                              );
                                              _playSongAndOpenPlayer(
                                                song,
                                                songsToShow,
                                              );
                                            }
                                          },
                                        ),
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
                                        onTap: () async {
                                          // Precargar la carátula antes de reproducir
                                          unawaited(
                                            _preloadArtworkForSong(song),
                                          );
                                          if (!mounted) return;
                                          await _playSongAndOpenPlayer(
                                            song,
                                            songsToShow,
                                          );
                                        },
                                        onLongPress: () {
                                          showModalBottomSheet(
                                            context: context,
                                            isScrollControlled: true,
                                            builder: (context) => SafeArea(
                                              child: SingleChildScrollView(
                                                child: FutureBuilder<bool>(
                                                  future: FavoritesDB()
                                                      .isFavorite(song.data),
                                                  builder: (context, snapshot) {
                                                    final isFav =
                                                        snapshot.data ?? false;
                                                    return Column(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        // Encabezado con información de la canción
                                                        Container(
                                                          padding:
                                                              const EdgeInsets.all(
                                                                16,
                                                              ),
                                                          child: Row(
                                                            children: [
                                                              // Carátula de la canción
                                                              ClipRRect(
                                                                borderRadius:
                                                                    BorderRadius.circular(
                                                                      8,
                                                                    ),
                                                                child: SizedBox(
                                                                  width: 60,
                                                                  height: 60,
                                                                  child:
                                                                      _buildModalArtwork(
                                                                        song,
                                                                      ),
                                                                ),
                                                              ),
                                                              const SizedBox(
                                                                width: 16,
                                                              ),
                                                              // Título y artista
                                                              Expanded(
                                                                child: Column(
                                                                  crossAxisAlignment:
                                                                      CrossAxisAlignment
                                                                          .start,
                                                                  mainAxisSize:
                                                                      MainAxisSize
                                                                          .min,
                                                                  children: [
                                                                    Text(
                                                                      song.title,
                                                                      maxLines:
                                                                          1,
                                                                      style: const TextStyle(
                                                                        fontSize:
                                                                            16,
                                                                        fontWeight:
                                                                            FontWeight.bold,
                                                                      ),
                                                                      overflow:
                                                                          TextOverflow
                                                                              .ellipsis,
                                                                    ),
                                                                    const SizedBox(
                                                                      height: 4,
                                                                    ),
                                                                    Text(
                                                                      song.artist ??
                                                                          LocaleProvider.tr(
                                                                            'unknown_artist',
                                                                          ),
                                                                      style: TextStyle(
                                                                        fontSize:
                                                                            14,
                                                                      ),
                                                                      maxLines:
                                                                          1,
                                                                      overflow:
                                                                          TextOverflow
                                                                              .ellipsis,
                                                                    ),
                                                                  ],
                                                                ),
                                                              ),
                                                              const SizedBox(
                                                                width: 8,
                                                              ),
                                                              // Botón de búsqueda para abrir opciones
                                                              InkWell(
                                                                onTap: () async {
                                                                  Navigator.of(
                                                                    context,
                                                                  ).pop();
                                                                  await _showSearchOptions(
                                                                    song,
                                                                  );
                                                                },
                                                                borderRadius: BorderRadius.circular(12),
                                                                child: Container(
                                                                  padding: const EdgeInsets.symmetric(
                                                                    horizontal: 16,
                                                                    vertical: 8,
                                                                  ),
                                                                  decoration: BoxDecoration(
                                                                    color: Theme.of(context).brightness == Brightness.dark
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
                                                                        color: Theme.of(context).brightness == Brightness.dark
                                                                          ? Theme.of(context).colorScheme.onPrimaryContainer
                                                                          : Theme.of(context).colorScheme.surfaceContainer,
                                                                      ),
                                                                      const SizedBox(width: 8),
                                                                      TranslatedText(
                                                                        'search',
                                                                        style: TextStyle(
                                                                          fontWeight: FontWeight.w600,
                                                                          fontSize: 14,
                                                                          color: Theme.of(context).brightness == Brightness.dark
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
                                                          leading: const Icon(
                                                            Icons.queue_music,
                                                          ),
                                                          title: TranslatedText(
                                                            'add_to_queue',
                                                          ),
                                                          onTap: () async {
                                                            Navigator.of(
                                                              context,
                                                            ).pop();
                                                            await (audioHandler
                                                                    as MyAudioHandler)
                                                                .addSongsToQueueEnd(
                                                                  [song],
                                                                );
                                                          },
                                                        ),
                                                        ListTile(
                                                          leading: Icon(
                                                            isFav
                                                                ? Icons
                                                                      .delete_outline
                                                                : Icons
                                                                      .favorite_border,
                                                          ),
                                                          title: TranslatedText(
                                                            isFav
                                                                ? 'remove_from_favorites'
                                                                : 'add_to_favorites',
                                                          ),
                                                          onTap: () async {
                                                            Navigator.of(
                                                              context,
                                                            ).pop();
                                                            if (isFav) {
                                                              await FavoritesDB()
                                                                  .removeFavorite(
                                                                    song.data,
                                                                  );
                                                              favoritesShouldReload
                                                                      .value =
                                                                  !favoritesShouldReload
                                                                      .value;
                                                            } else {
                                                              await _addToFavorites(
                                                                song,
                                                              );
                                                            }
                                                          },
                                                        ),
                                                        ListTile(
                                                          leading: const Icon(
                                                            Icons
                                                                .delete_outline,
                                                          ),
                                                          title: TranslatedText(
                                                            'remove_from_recents',
                                                          ),
                                                          onTap: () async {
                                                            Navigator.of(
                                                              context,
                                                            ).pop();
                                                            await RecentsDB()
                                                                .removeRecent(
                                                                  song.data,
                                                                );
                                                            await _loadRecents();
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
                                                          leading: const Icon(Icons.info_outline),
                                                          title: TranslatedText('song_info'),
                                                          onTap: () async {
                                                            Navigator.of(context).pop();
                                                            await SongInfoDialog.showFromSong(context, song, colorSchemeNotifier);
                                                          },
                                                        ),
                                                      ],
                                                    );
                                                  },
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      );
                                    },
                                  );
                                } else {
                                  // Para canciones que no están reproduciéndose, no usar StreamBuilder
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
                                          color: isSystem ? Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.5) : Theme.of(context).colorScheme.surfaceContainer,
                                          width: 50,
                                          height: 50,
                                          child: Icon(
                                            Icons.music_note,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurface,
                                          ),
                                        ),
                                      ),
                                    ),
                                    title: Row(
                                      children: [
                                        if (isCurrent)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              right: 8.0,
                                            ),
                                            child: MiniMusicVisualizer(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.primary,
                                              width: 4,
                                              height: 15,
                                              radius: 4,
                                              animate: false, // No playing
                                            ),
                                          ),
                                        Expanded(
                                          child: Text(
                                            song.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium
                                                ?.copyWith(
                                                  fontWeight: isCurrent
                                                      ? FontWeight.bold
                                                      : FontWeight.normal,
                                                  color: isCurrent
                                                      ? (isAmoledTheme
                                                            ? Colors.white
                                                            : Theme.of(context)
                                                                  .colorScheme
                                                                  .primary)
                                                      : Theme.of(
                                                          context,
                                                        ).colorScheme.onSurface,
                                                ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    subtitle: Text(
                                      _formatArtistWithDuration(song),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    trailing: IconButton(
                                      icon: const Icon(Symbols.play_arrow_rounded, grade: 200, fill: 1),
                                      onPressed: () {
                                        // Precargar la carátula antes de reproducir
                                        unawaited(_preloadArtworkForSong(song));
                                        _playSongAndOpenPlayer(
                                          song,
                                          songsToShow,
                                        );
                                      },
                                    ),
                                    selected: isCurrent,
                                    selectedTileColor: isAmoledTheme
                                        ? Colors.white.withValues(alpha: 0.1)
                                        : Theme.of(
                                            context,
                                          ).colorScheme.primaryContainer,
                                    onTap: () async {
                                      // Precargar la carátula antes de reproducir
                                      unawaited(_preloadArtworkForSong(song));
                                      if (!mounted) return;
                                      await _playSongAndOpenPlayer(
                                        song,
                                        songsToShow,
                                      );
                                    },
                                    onLongPress: () {
                                      showModalBottomSheet(
                                        context: context,
                                        isScrollControlled: true,
                                        builder: (context) => SafeArea(
                                          child: SingleChildScrollView(
                                            child: FutureBuilder<bool>(
                                              future: FavoritesDB().isFavorite(
                                                song.data,
                                              ),
                                              builder: (context, snapshot) {
                                                final isFav =
                                                    snapshot.data ?? false;
                                                return Column(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    // Encabezado con información de la canción
                                                    Container(
                                                      padding:
                                                          const EdgeInsets.all(
                                                            16,
                                                          ),
                                                      child: Row(
                                                        children: [
                                                          // Carátula de la canción
                                                          ClipRRect(
                                                            borderRadius:
                                                                BorderRadius.circular(
                                                                  8,
                                                                ),
                                                            child: SizedBox(
                                                              width: 60,
                                                              height: 60,
                                                              child:
                                                                  _buildModalArtwork(
                                                                    song,
                                                                  ),
                                                            ),
                                                          ),
                                                          const SizedBox(
                                                            width: 16,
                                                          ),
                                                          // Título y artista
                                                          Expanded(
                                                            child: Column(
                                                              crossAxisAlignment:
                                                                  CrossAxisAlignment
                                                                      .start,
                                                              mainAxisSize:
                                                                  MainAxisSize
                                                                      .min,
                                                              children: [
                                                                Text(
                                                                  song.title,
                                                                  maxLines: 1,
                                                                  style: const TextStyle(
                                                                    fontSize:
                                                                        16,
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .bold,
                                                                  ),
                                                                  overflow:
                                                                      TextOverflow
                                                                          .ellipsis,
                                                                ),
                                                                const SizedBox(
                                                                  height: 4,
                                                                ),
                                                                Text(
                                                                  song.artist ??
                                                                      LocaleProvider.tr(
                                                                        'unknown_artist',
                                                                      ),
                                                                  style:
                                                                      TextStyle(
                                                                        fontSize:
                                                                            14,
                                                                      ),
                                                                  maxLines: 1,
                                                                  overflow:
                                                                      TextOverflow
                                                                          .ellipsis,
                                                                ),
                                                              ],
                                                            ),
                                                          ),
                                                          const SizedBox(
                                                            width: 8,
                                                          ),
                                                                                                                    // Botón de búsqueda para abrir opciones
                                                          InkWell(
                                                            onTap: () async {
                                                              Navigator.of(
                                                                context,
                                                              ).pop();
                                                              await _showSearchOptions(
                                                                song,
                                                              );
                                                            },
                                                            borderRadius: BorderRadius.circular(12),
                                                            child: Container(
                                                              padding: const EdgeInsets.symmetric(
                                                                horizontal: 16,
                                                                vertical: 8,
                                                              ),
                                                              decoration: BoxDecoration(
                                                                color: Theme.of(context).brightness == Brightness.dark
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
                                                                    color: Theme.of(context).brightness == Brightness.dark
                                                                      ? Theme.of(context).colorScheme.onPrimaryContainer
                                                                      : Theme.of(context).colorScheme.surfaceContainer,
                                                                  ),
                                                                  const SizedBox(width: 8),
                                                                  TranslatedText(
                                                                    'search',
                                                                    style: TextStyle(
                                                                      fontWeight: FontWeight.w600,
                                                                      fontSize: 14,
                                                                      color: Theme.of(context).brightness == Brightness.dark
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
                                                      leading: const Icon(
                                                        Icons.queue_music,
                                                      ),
                                                      title: TranslatedText(
                                                        'add_to_queue',
                                                      ),
                                                      onTap: () async {
                                                        Navigator.of(
                                                          context,
                                                        ).pop();
                                                        await (audioHandler
                                                                as MyAudioHandler)
                                                            .addSongsToQueueEnd(
                                                              [song],
                                                            );
                                                      },
                                                    ),
                                                    ListTile(
                                                      leading: Icon(
                                                        isFav
                                                            ? Icons
                                                                  .delete_outline
                                                            : Icons
                                                                  .favorite_border,
                                                      ),
                                                      title: TranslatedText(
                                                        isFav
                                                            ? 'remove_from_favorites'
                                                            : 'add_to_favorites',
                                                      ),
                                                      onTap: () async {
                                                        Navigator.of(
                                                          context,
                                                        ).pop();
                                                        if (isFav) {
                                                          await FavoritesDB()
                                                              .removeFavorite(
                                                                song.data,
                                                              );
                                                          favoritesShouldReload
                                                                  .value =
                                                              !favoritesShouldReload
                                                                  .value;
                                                        } else {
                                                          await _addToFavorites(
                                                            song,
                                                          );
                                                        }
                                                      },
                                                    ),
                                                    ListTile(
                                                      leading: const Icon(
                                                        Icons.delete_outline,
                                                      ),
                                                      title: TranslatedText(
                                                        'remove_from_recents',
                                                      ),
                                                      onTap: () async {
                                                        Navigator.of(
                                                          context,
                                                        ).pop();
                                                        await RecentsDB()
                                                            .removeRecent(
                                                              song.data,
                                                            );
                                                        await _loadRecents();
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
                                                      leading: const Icon(Icons.info_outline),
                                                      title: TranslatedText('song_info'),
                                                      onTap: () async {
                                                        Navigator.of(context).pop();
                                                        await SongInfoDialog.showFromSong(context, song, colorSchemeNotifier);
                                                      },
                                                    ),
                                                  ],
                                                );
                                              },
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  );
                                }
                              },
                            );
                          },
                        );
                      },
                    )
                  : _showingPlaylistSongs
                  ? RefreshIndicator(
                      onRefresh: _refreshPlaylistSongs,
                      child: Builder(
                      builder: (context) {
                        final List<SongModel> songsToShow =
                            _searchPlaylistController.text.isNotEmpty
                            ? _filteredPlaylistSongs
                            : _playlistSongs;
                        if (songsToShow.isEmpty) {
                          return Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.playlist_remove_outlined,
                                  size: 48,
                                  color: Theme.of(context).colorScheme.onSurface
                                      .withValues(alpha: 0.6),
                                ),
                                const SizedBox(height: 16),
                                TranslatedText(
                                  'no_songs_in_playlist',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.6),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }
                        return ValueListenableBuilder<MediaItem?>(
                          valueListenable: _immediateMediaItemNotifier,
                          builder: (context, immediateMediaItem, child) {
                            return ListView.builder(
                              itemCount: songsToShow.length,
                              itemBuilder: (context, index) {
                                final song = songsToShow[index];
                                final path = song.data;
                                final isCurrent =
                                    (immediateMediaItem?.id != null &&
                                    path.isNotEmpty &&
                                    (immediateMediaItem!.id == path ||
                                        immediateMediaItem.extras?['data'] ==
                                            path));
                                final isAmoledTheme =
                                    colorSchemeNotifier.value ==
                                    AppColorScheme.amoled;
                                final isSystem = colorSchemeNotifier.value == AppColorScheme.system;
                                // Solo usar ValueListenableBuilder para la canción actual
                                if (isCurrent) {
                                  return ValueListenableBuilder<bool>(
                                    valueListenable: _isPlayingNotifier,
                                    builder: (context, playing, child) {
                                      return ListTile(
                                        onTap: () async {
                                          if (_isSelectingPlaylistSongs) {
                                            _onPlaylistSongSelected(song);
                                          } else {
                                            if (!mounted) return;
                                            await _playSongAndOpenPlayer(
                                              song,
                                              songsToShow,
                                            );
                                          }
                                        },
                                        onLongPress: () async {
                                          if (_isSelectingPlaylistSongs) {
                                            setState(() {
                                              if (_selectedPlaylistSongIds
                                                  .contains(song.id)) {
                                                _selectedPlaylistSongIds.remove(
                                                  song.id,
                                                );
                                                if (_selectedPlaylistSongIds
                                                    .isEmpty) {
                                                  _isSelectingPlaylistSongs =
                                                      false;
                                                }
                                              } else {
                                                _selectedPlaylistSongIds.add(
                                                  song.id,
                                                );
                                              }
                                            });
                                          } else {
                                            final isPinned = await ShortcutsDB()
                                                .isShortcut(song.data);
                                            final isFav = await FavoritesDB()
                                                .isFavorite(song.data);
                                            if (!context.mounted) return;
                                            showModalBottomSheet(
                                              context: context,
                                              isScrollControlled: true,
                                              builder: (context) => SafeArea(
                                                child: SingleChildScrollView(
                                                  child: Column(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      // Encabezado con información de la canción
                                                      Container(
                                                        padding:
                                                            const EdgeInsets.all(
                                                              16,
                                                            ),
                                                        child: Row(
                                                          children: [
                                                            // Carátula de la canción
                                                            ClipRRect(
                                                              borderRadius:
                                                                  BorderRadius.circular(
                                                                    8,
                                                                  ),
                                                              child: SizedBox(
                                                                width: 60,
                                                                height: 60,
                                                                child:
                                                                    _buildModalArtwork(
                                                                      song,
                                                                    ),
                                                              ),
                                                            ),
                                                            const SizedBox(
                                                              width: 16,
                                                            ),
                                                            // Título y artista
                                                            Expanded(
                                                              child: Column(
                                                                crossAxisAlignment:
                                                                    CrossAxisAlignment
                                                                        .start,
                                                                mainAxisSize:
                                                                    MainAxisSize
                                                                        .min,
                                                                children: [
                                                                  Text(
                                                                    song.title,
                                                                    maxLines: 1,
                                                                    style: const TextStyle(
                                                                      fontSize:
                                                                          16,
                                                                      fontWeight:
                                                                          FontWeight
                                                                              .bold,
                                                                    ),
                                                                    overflow:
                                                                        TextOverflow
                                                                            .ellipsis,
                                                                  ),
                                                                  const SizedBox(
                                                                    height: 4,
                                                                  ),
                                                                  Text(
                                                                    song.artist ??
                                                                        LocaleProvider.tr(
                                                                          'unknown_artist',
                                                                        ),
                                                                    style: TextStyle(
                                                                      fontSize:
                                                                          14,
                                                                    ),
                                                                    maxLines: 1,
                                                                    overflow:
                                                                        TextOverflow
                                                                            .ellipsis,
                                                                  ),
                                                                ],
                                                              ),
                                                            ),
                                                            const SizedBox(
                                                              width: 8,
                                                            ),
                                                            // Botón de búsqueda para abrir opciones
                                                            InkWell(
                                                              onTap: () async {
                                                                Navigator.of(
                                                                  context,
                                                                ).pop();
                                                                await _showSearchOptions(
                                                                  song,
                                                                );
                                                              },
                                                              borderRadius: BorderRadius.circular(12),
                                                              child: Container(
                                                                padding: const EdgeInsets.symmetric(
                                                                  horizontal: 16,
                                                                  vertical: 8,
                                                                ),
                                                                decoration: BoxDecoration(
                                                                  color: Theme.of(context).brightness == Brightness.dark
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
                                                                      color: Theme.of(context).brightness == Brightness.dark
                                                                        ? Theme.of(context).colorScheme.onPrimaryContainer
                                                                        : Theme.of(context).colorScheme.surfaceContainer,
                                                                    ),
                                                                    const SizedBox(width: 8),
                                                                    TranslatedText(
                                                                      'search',
                                                                      style: TextStyle(
                                                                        fontWeight: FontWeight.w600,
                                                                        fontSize: 14,
                                                                        color: Theme.of(context).brightness == Brightness.dark
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
                                                        leading: const Icon(
                                                          Icons.queue_music,
                                                        ),
                                                        title: TranslatedText(
                                                          'add_to_queue',
                                                        ),
                                                        onTap: () async {
                                                          if (!context
                                                              .mounted) {
                                                            return;
                                                          }
                                                          Navigator.of(
                                                            context,
                                                          ).pop();
                                                          await (audioHandler
                                                                  as MyAudioHandler)
                                                              .addSongsToQueueEnd(
                                                                [song],
                                                              );
                                                        },
                                                      ),
                                                      ListTile(
                                                        leading: Icon(
                                                          isFav
                                                              ? Icons
                                                                    .delete_outline
                                                              : Icons
                                                                    .favorite_border,
                                                        ),
                                                        title: TranslatedText(
                                                          isFav
                                                              ? 'remove_from_favorites'
                                                              : 'add_to_favorites',
                                                        ),
                                                        onTap: () async {
                                                          if (!context
                                                              .mounted) {
                                                            return;
                                                          }
                                                          Navigator.of(
                                                            context,
                                                          ).pop();
                                                          if (isFav) {
                                                            await FavoritesDB()
                                                                .removeFavorite(
                                                                  song.data,
                                                                );
                                                            favoritesShouldReload
                                                                    .value =
                                                                !favoritesShouldReload
                                                                    .value;
                                                          } else {
                                                            await FavoritesDB()
                                                                .addFavorite(
                                                                  song,
                                                                );
                                                            favoritesShouldReload
                                                                    .value =
                                                                !favoritesShouldReload
                                                                    .value;
                                                          }
                                                        },
                                                      ),
                                                      ListTile(
                                                        leading: const Icon(
                                                          Icons.playlist_remove,
                                                        ),
                                                        title: TranslatedText(
                                                          'remove_from_playlist',
                                                        ),
                                                        onTap: () async {
                                                          if (!context
                                                              .mounted) {
                                                            return;
                                                          }
                                                          Navigator.of(
                                                            context,
                                                          ).pop();
                                                          await PlaylistsDB()
                                                              .removeSongFromPlaylist(
                                                                _selectedPlaylist!['id'],
                                                                song.data,
                                                              );
                                                          await _loadPlaylistSongs(
                                                            _selectedPlaylist!,
                                                          );
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
                                                        leading: Icon(
                                                          isPinned
                                                              ? Icons.push_pin
                                                              : Icons
                                                                    .push_pin_outlined,
                                                        ),
                                                        title: TranslatedText(
                                                          isPinned
                                                              ? 'unpin_shortcut'
                                                              : 'pin_shortcut',
                                                        ),
                                                        onTap: () async {
                                                          if (!context
                                                              .mounted) {
                                                            return;
                                                          }
                                                          Navigator.of(
                                                            context,
                                                          ).pop();
                                                          if (isPinned) {
                                                            await ShortcutsDB()
                                                                .removeShortcut(
                                                                  song.data,
                                                                );
                                                          } else {
                                                            await ShortcutsDB()
                                                                .addShortcut(
                                                                  song.data,
                                                                );
                                                          }
                                                          shortcutsShouldReload
                                                                  .value =
                                                              !shortcutsShouldReload
                                                                  .value;
                                                        },
                                                      ),
                                                      ListTile(
                                                        leading: const Icon(
                                                          Icons
                                                              .check_box_outlined,
                                                        ),
                                                        title: TranslatedText(
                                                          'select',
                                                        ),
                                                        onTap: () {
                                                          Navigator.of(
                                                            context,
                                                          ).pop();
                                                          setState(() {
                                                            _isSelectingPlaylistSongs =
                                                                true;
                                                            _selectedPlaylistSongIds
                                                                .add(song.id);
                                                          });
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
                                          }
                                        },
                                        leading: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (_isSelectingPlaylistSongs)
                                              Checkbox(
                                                value: _selectedPlaylistSongIds
                                                    .contains(song.id),
                                                onChanged: (checked) {
                                                  setState(() {
                                                    if (checked == true) {
                                                      _selectedPlaylistSongIds
                                                          .add(song.id);
                                                    } else {
                                                      _selectedPlaylistSongIds
                                                          .remove(song.id);
                                                      if (_selectedPlaylistSongIds
                                                          .isEmpty) {
                                                        _isSelectingPlaylistSongs =
                                                            false;
                                                      }
                                                    }
                                                  });
                                                },
                                              ),
                                            ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              child: QueryArtworkWidget(
                                                id: song.id,
                                                type: ArtworkType.AUDIO,
                                                artworkBorder:
                                                    BorderRadius.circular(8),
                                                artworkHeight: 50,
                                                artworkWidth: 50,
                                                keepOldArtwork: true,
                                                nullArtworkWidget: Container(
                                                  color: isSystem ? Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.5) : Theme.of(context).colorScheme.surfaceContainer,
                                                  width: 50,
                                                  height: 50,
                                                  child: Icon(
                                                    Icons.music_note,
                                                    color: Theme.of(
                                                      context,
                                                    ).colorScheme.onSurface,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        title: Row(
                                          children: [
                                            if (isCurrent)
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  right: 8.0,
                                                ),
                                                child: MiniMusicVisualizer(
                                                  color: Theme.of(
                                                    context,
                                                  ).colorScheme.primary,
                                                  width: 4,
                                                  height: 15,
                                                  radius: 4,
                                                  animate: playing
                                                      ? true
                                                      : false,
                                                ),
                                              ),
                                            Expanded(
                                              child: Text(
                                                song.title,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .titleMedium
                                                    ?.copyWith(
                                                      fontWeight: isCurrent
                                                          ? FontWeight.bold
                                                          : FontWeight.normal,
                                                      color: isCurrent
                                                          ? (isAmoledTheme
                                                                ? Colors.white
                                                                : Theme.of(
                                                                        context,
                                                                      )
                                                                      .colorScheme
                                                                      .primary)
                                                          : Theme.of(context)
                                                                .colorScheme
                                                                .onSurface,
                                                    ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        subtitle: Text(
                                          _formatArtistWithDuration(song),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        trailing: IconButton(
                                          icon: Icon(
                                            isCurrent && playing
                                                ? Symbols.pause_rounded
                                                : Symbols.play_arrow_rounded,
                                          grade: 200,
                                          fill: 1,
                                          ),
                                          onPressed: () {
                                            if (isCurrent) {
                                              playing
                                                  ? (audioHandler
                                                            as MyAudioHandler)
                                                        .pause()
                                                  : (audioHandler
                                                            as MyAudioHandler)
                                                        .play();
                                            } else {
                                              // Precargar la carátula antes de reproducir
                                              unawaited(
                                                _preloadArtworkForSong(song),
                                              );
                                              _playSongAndOpenPlayer(
                                                song,
                                                songsToShow,
                                              );
                                            }
                                          },
                                        ),
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
                                      );
                                    },
                                  );
                                } else {
                                  // Para canciones que no están reproduciéndose, no usar StreamBuilder
                                  final playing =
                                      audioHandler
                                          ?.playbackState
                                          .value
                                          .playing ??
                                      false;
                                  return ListTile(
                                    onTap: () async {
                                      if (_isSelectingPlaylistSongs) {
                                        _onPlaylistSongSelected(song);
                                      } else {
                                        if (!mounted) return;
                                        await _playSongAndOpenPlayer(
                                          song,
                                          songsToShow,
                                        );
                                      }
                                    },
                                    onLongPress: () async {
                                      if (_isSelectingPlaylistSongs) {
                                        setState(() {
                                          if (_selectedPlaylistSongIds.contains(
                                            song.id,
                                          )) {
                                            _selectedPlaylistSongIds.remove(
                                              song.id,
                                            );
                                            if (_selectedPlaylistSongIds
                                                .isEmpty) {
                                              _isSelectingPlaylistSongs = false;
                                            }
                                          } else {
                                            _selectedPlaylistSongIds.add(
                                              song.id,
                                            );
                                          }
                                        });
                                      } else {
                                        final isPinned = await ShortcutsDB()
                                            .isShortcut(song.data);
                                        final isFav = await FavoritesDB()
                                            .isFavorite(song.data);
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
                                                    padding:
                                                        const EdgeInsets.all(
                                                          16,
                                                        ),
                                                    child: Row(
                                                      children: [
                                                        // Carátula de la canción
                                                        ClipRRect(
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                8,
                                                              ),
                                                          child: SizedBox(
                                                            width: 60,
                                                            height: 60,
                                                            child:
                                                                _buildModalArtwork(
                                                                  song,
                                                                ),
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                          width: 16,
                                                        ),
                                                        // Título y artista
                                                        Expanded(
                                                          child: Column(
                                                            crossAxisAlignment:
                                                                CrossAxisAlignment
                                                                    .start,
                                                            mainAxisSize:
                                                                MainAxisSize
                                                                    .min,
                                                            children: [
                                                              Text(
                                                                song.title,
                                                                maxLines: 1,
                                                                style: const TextStyle(
                                                                  fontSize: 16,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .bold,
                                                                ),
                                                                overflow:
                                                                    TextOverflow
                                                                        .ellipsis,
                                                              ),
                                                              const SizedBox(
                                                                height: 4,
                                                              ),
                                                              Text(
                                                                song.artist ??
                                                                    LocaleProvider.tr(
                                                                      'unknown_artist',
                                                                    ),
                                                                style:
                                                                    TextStyle(
                                                                      fontSize:
                                                                          14,
                                                                    ),
                                                                maxLines: 1,
                                                                overflow:
                                                                    TextOverflow
                                                                        .ellipsis,
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                          width: 8,
                                                        ),
                                                        // Botón de búsqueda para abrir opciones
                                                        InkWell(
                                                          onTap: () async {
                                                            Navigator.of(
                                                              context,
                                                            ).pop();
                                                            await _showSearchOptions(
                                                              song,
                                                            );
                                                          },
                                                          borderRadius: BorderRadius.circular(12),
                                                          child: Container(
                                                            padding: const EdgeInsets.symmetric(
                                                              horizontal: 16,
                                                              vertical: 8,
                                                            ),
                                                            decoration: BoxDecoration(
                                                              color: Theme.of(context).brightness == Brightness.dark
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
                                                                  color: Theme.of(context).brightness == Brightness.dark
                                                                    ? Theme.of(context).colorScheme.onPrimaryContainer
                                                                    : Theme.of(context).colorScheme.surfaceContainer,
                                                                ),
                                                                const SizedBox(width: 8),
                                                                TranslatedText(
                                                                  'search',
                                                                  style: TextStyle(
                                                                    fontWeight: FontWeight.w600,
                                                                    fontSize: 14,
                                                                    color: Theme.of(context).brightness == Brightness.dark
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
                                                    leading: const Icon(
                                                      Icons.queue_music,
                                                    ),
                                                    title: TranslatedText(
                                                      'add_to_queue',
                                                    ),
                                                    onTap: () async {
                                                      if (!context.mounted) {
                                                        return;
                                                      }
                                                      Navigator.of(
                                                        context,
                                                      ).pop();
                                                      await (audioHandler
                                                              as MyAudioHandler)
                                                          .addSongsToQueueEnd([
                                                            song,
                                                          ]);
                                                    },
                                                  ),
                                                  ListTile(
                                                    leading: Icon(
                                                      isFav
                                                          ? Icons.delete_outline
                                                          : Symbols.favorite_rounded,
                                                      weight: isFav ? null : 600,
                                                    ),
                                                    title: TranslatedText(
                                                      isFav
                                                          ? 'remove_from_favorites'
                                                          : 'add_to_favorites',
                                                    ),
                                                    onTap: () async {
                                                      if (!context.mounted) {
                                                        return;
                                                      }
                                                      Navigator.of(
                                                        context,
                                                      ).pop();
                                                      if (isFav) {
                                                        await FavoritesDB()
                                                            .removeFavorite(
                                                              song.data,
                                                            );
                                                        favoritesShouldReload
                                                                .value =
                                                            !favoritesShouldReload
                                                                .value;
                                                      } else {
                                                        await FavoritesDB()
                                                            .addFavorite(song);
                                                        favoritesShouldReload
                                                                .value =
                                                            !favoritesShouldReload
                                                                .value;
                                                      }
                                                    },
                                                  ),
                                                  ListTile(
                                                    leading: const Icon(
                                                      Icons.playlist_remove,
                                                    ),
                                                    title: TranslatedText(
                                                      'remove_from_playlist',
                                                    ),
                                                    onTap: () async {
                                                      if (!context.mounted) {
                                                        return;
                                                      }
                                                      Navigator.of(
                                                        context,
                                                      ).pop();
                                                      await PlaylistsDB()
                                                          .removeSongFromPlaylist(
                                                            _selectedPlaylist!['id'],
                                                            song.data,
                                                          );
                                                      await _loadPlaylistSongs(
                                                        _selectedPlaylist!,
                                                      );
                                                    },
                                                  ),
                                                  ListTile(
                                                    leading: Icon(
                                                      isPinned
                                                          ? Icons.push_pin
                                                          : Icons
                                                                .push_pin_outlined,
                                                    ),
                                                    title: TranslatedText(
                                                      isPinned
                                                          ? 'unpin_shortcut'
                                                          : 'pin_shortcut',
                                                    ),
                                                    onTap: () async {
                                                      if (!context.mounted) {
                                                        return;
                                                      }
                                                      Navigator.of(
                                                        context,
                                                      ).pop();
                                                      if (isPinned) {
                                                        await ShortcutsDB()
                                                            .removeShortcut(
                                                              song.data,
                                                            );
                                                      } else {
                                                        await ShortcutsDB()
                                                            .addShortcut(
                                                              song.data,
                                                            );
                                                      }
                                                      shortcutsShouldReload
                                                              .value =
                                                          !shortcutsShouldReload
                                                              .value;
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
                                                    leading: const Icon(
                                                      Icons.check_box_outlined,
                                                    ),
                                                    title: TranslatedText(
                                                      'select',
                                                    ),
                                                    onTap: () {
                                                      Navigator.of(
                                                        context,
                                                      ).pop();
                                                      setState(() {
                                                        _isSelectingPlaylistSongs =
                                                            true;
                                                        _selectedPlaylistSongIds
                                                            .add(song.id);
                                                      });
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
                                      }
                                    },
                                    leading: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (_isSelectingPlaylistSongs)
                                          Checkbox(
                                            value: _selectedPlaylistSongIds
                                                .contains(song.id),
                                            onChanged: (checked) {
                                              setState(() {
                                                if (checked == true) {
                                                  _selectedPlaylistSongIds.add(
                                                    song.id,
                                                  );
                                                } else {
                                                  _selectedPlaylistSongIds
                                                      .remove(song.id);
                                                  if (_selectedPlaylistSongIds
                                                      .isEmpty) {
                                                    _isSelectingPlaylistSongs =
                                                        false;
                                                  }
                                                }
                                              });
                                            },
                                          ),
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          child: QueryArtworkWidget(
                                            id: song.id,
                                            type: ArtworkType.AUDIO,
                                            artworkBorder:
                                                BorderRadius.circular(8),
                                            artworkHeight: 50,
                                            artworkWidth: 50,
                                            keepOldArtwork: true,
                                            nullArtworkWidget: Container(
                                              color: isSystem ? Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.5) : Theme.of(context).colorScheme.surfaceContainer,
                                              width: 50,
                                              height: 50,
                                              child: Icon(
                                                Icons.music_note,
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.onSurface,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    title: Row(
                                      children: [
                                        if (isCurrent)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              right: 8.0,
                                            ),
                                            child: MiniMusicVisualizer(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.primary,
                                              width: 4,
                                              height: 15,
                                              radius: 4,
                                              animate: false, // No playing
                                            ),
                                          ),
                                        Expanded(
                                          child: Text(
                                            song.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium
                                                ?.copyWith(
                                                  fontWeight: isCurrent
                                                      ? FontWeight.bold
                                                      : FontWeight.normal,
                                                  color: isCurrent
                                                      ? (isAmoledTheme
                                                            ? Colors.white
                                                            : Theme.of(context)
                                                                  .colorScheme
                                                                  .primary)
                                                      : Theme.of(
                                                          context,
                                                        ).colorScheme.onSurface,
                                                ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    subtitle: Text(
                                      _formatArtistWithDuration(song),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    trailing: IconButton(
                                      icon: Icon(
                                        isCurrent && playing
                                            ? Symbols.pause_rounded
                                            : Symbols.play_arrow_rounded,
                                          grade: 200,
                                          fill: 1,
                                      ),
                                      onPressed: () {
                                        if (isCurrent) {
                                          playing
                                              ? (audioHandler as MyAudioHandler)
                                                    .pause()
                                              : (audioHandler as MyAudioHandler)
                                                    .play();
                                        } else {
                                          // Precargar la carátula antes de reproducir
                                          unawaited(
                                            _preloadArtworkForSong(song),
                                          );
                                          _playSongAndOpenPlayer(
                                            song,
                                            songsToShow,
                                          );
                                        }
                                      },
                                    ),
                                    selected: isCurrent,
                                    selectedTileColor: isCurrent
                                        ? (isAmoledTheme
                                            ? Colors.white.withValues(alpha: 0.15)
                                            : Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.8))
                                        : null,
                                    shape: isCurrent
                                        ? RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(16),
                                          )
                                        : null,
                                    );
                                  }
                                },
                              );
                            },
                          );
                        },
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: () async {
                        // print('🔄 Iniciando refresh completo...');
                        // Actualizar accesos directos y selección rápida
                        await _loadAllSongs();
                        await _loadMostPlayed();
                        await _loadShortcuts();
                        await _loadArtists(forceRefresh: true); // Forzar reindexación de artistas
                        await _fillQuickPickWithRandomSongs(forceReload: true);
                        _initQuickPickPages();
                        // Limpiar cache para forzar reconstrucción
                        _shortcutWidgetCache.clear();
                        _quickPickWidgetCache.clear();
                        // print('🔄 Refresh completado');
                        _artistWidgetCache.clear();
                        setState(() {});
                      },
                      child: SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: EdgeInsets.zero,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_updateVersion != null &&
                                _updateVersion!.isNotEmpty &&
                                _updateApkUrl != null) ...[
                              const SizedBox(height: 16),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 4,
                                ),
                                child: Material(
                                  color: colorSchemeNotifier.value == AppColorScheme.amoled
                                      ? Colors.white.withValues(alpha: 0.1)
                                      : Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.4),
                                  borderRadius: BorderRadius.circular(12),
                                  child: ListTile(
                                    leading: Icon(
                                      Icons.system_update,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurface,
                                    ),
                                    title: ValueListenableBuilder<String>(
                                      valueListenable: languageNotifier,
                                      builder: (context, lang, child) {
                                        return Text(
                                          '${LocaleProvider.tr('new_version_available')} $_updateVersion ${LocaleProvider.tr('available')}',
                                          style: TextStyle(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurface,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        );
                                      },
                                    ),
                                    trailing: TextButton(
                                      style: TextButton.styleFrom(
                                        foregroundColor: Theme.of(
                                          context,
                                        ).colorScheme.onPrimary,
                                        backgroundColor: Theme.of(
                                          context,
                                        ).colorScheme.primaryContainer,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                      ),
                                      child: Text(
                                        LocaleProvider.tr('update'),
                                        style: TextStyle(
                                          color:
                                              colorSchemeNotifier.value ==
                                                  AppColorScheme.amoled
                                              ? Theme.of(
                                                  context,
                                                ).colorScheme.onPrimary
                                              : Theme.of(
                                                  context,
                                                ).colorScheme.onSurface,
                                        ),
                                      ),
                                      onPressed: () {
                                        Navigator.of(context).push(
                                          PageRouteBuilder(
                                            pageBuilder:
                                                (context, animation, secondaryAnimation) =>
                                                    const UpdateScreen(),
                                            transitionsBuilder:
                                                (context, animation, secondaryAnimation, child) {
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
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 16),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                              ),
                              child: Row(
                                children: [
                                  TranslatedText(
                                    'quick_access',
                                    style: const TextStyle(
                                      fontSize: 26,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const Spacer(),
                                  IconButton(
                                    icon: Icon(
                                      Icons.play_circle_outline,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurface,
                                    ),
                                    tooltip: LocaleProvider.tr('play_all'),
                                    onPressed: () {
                                      _playSongAndOpenPlayer(
                                        _accessDirectSongs.first,
                                        _accessDirectSongs,
                                        queueSource: LocaleProvider.tr(
                                          'quick_access_songs',
                                        ),
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 0,
                              ),
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  // Calcular el ancho disponible para cada elemento
                                  final availableWidth =
                                      constraints.maxWidth -
                                      16; // Padding horizontal
                                  final itemWidth =
                                      (availableWidth - 24) /
                                      3; // 3 columnas con spacing
                                  final itemHeight =
                                      itemWidth; // Mantener aspecto cuadrado
                                  final gridHeight =
                                      (itemHeight * 2) +
                                      12 +
                                      16; // 2 filas + spacing + padding

                                  return SizedBox(
                                    height: gridHeight,
                                    child: PageView(
                                      controller: _pageController,
                                      onPageChanged: (_) {},
                                      children: List.generate(3, (pageIndex) {
                                        final items = _accessDirectSongs
                                            .skip(pageIndex * 6)
                                            .take(6)
                                            .toList();
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
                                                SliverGridDelegateWithFixedCrossAxisCount(
                                                  crossAxisCount: 3,
                                                  mainAxisSpacing: 12,
                                                  crossAxisSpacing: 10,
                                                  childAspectRatio:
                                                      itemWidth / itemHeight,
                                                ),
                                            itemBuilder: (context, index) {
                                              if (index < items.length) {
                                                final song = items[index];
                                                // Usar el método optimizado que cachea los widgets
                                                return _buildShortcutWidget(
                                                  song,
                                                  context,
                                                );
                                              } else {
                                                return Container(
                                                  decoration: BoxDecoration(
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .surfaceContainer,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          12,
                                                        ),
                                                  ),
                                                  child: Icon(
                                                    Icons.music_note,
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .onSurface
                                                        .withValues(alpha: 0.6),
                                                    size:
                                                        itemWidth *
                                                        0.3, // Tamaño del ícono adaptativo
                                                  ),
                                                );
                                              }
                                            },
                                          ),
                                        );
                                      }),
                                    ),
                                  );
                                },
                              ),
                            ),
                            const SizedBox(height: 10),
                            Center(
                              child: SmoothPageIndicator(
                                controller: _pageController,
                                count: 3,
                                effect: WormEffect(
                                  dotHeight: 8,
                                  dotWidth: 8,
                                  activeDotColor: Theme.of(
                                    context,
                                  ).colorScheme.primary,
                                  dotColor: Theme.of(context)
                                      .colorScheme
                                      .onSurface
                                      .withValues(alpha: 0.24),
                                ),
                              ),
                            ),
                            // Sección de Artistas
                              const SizedBox(height: 32),

                              // Solo mostrar la sección de artistas si hay artistas disponibles
                              if (_artists.isNotEmpty) ...[
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 20,
                                  ),
                                  child: Row(
                                    children: [
                                      const TranslatedText(
                                        'artists',
                                        style: TextStyle(
                                          fontSize: 20,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 16),
                                SizedBox(
                                  height: 120,
                                  child: ListView.builder(
                                    scrollDirection: Axis.horizontal,
                                    padding: const EdgeInsets.symmetric(horizontal: 16),
                                    itemCount: _artists.length,
                                    itemBuilder: (context, index) {
                                      final artist = _artists[index];
                                      return Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 10),
                                        child: _buildArtistWidget(artist, context),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            // Solo mostrar la sección de selección rápida si hay canciones disponibles
                            if (limitedQuickPick.isNotEmpty) ...[
                              const SizedBox(height: 32),

                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                ),
                                child: Row(
                                  children: [
                                    TranslatedText(
                                      'quick_pick',
                                      style: const TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const Spacer(),
                                    IconButton(
                                      icon: Icon(
                                        Icons.play_circle_outline,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurface,
                                      ),
                                      tooltip: LocaleProvider.tr('play_all'),
                                      onPressed: () {
                                        _playSongAndOpenPlayer(
                                          limitedQuickPick.first,
                                          extendedQuickPick,
                                          queueSource: LocaleProvider.tr(
                                            'quick_pick_songs',
                                          ),
                                        );
                                      },
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                              Column(
                                children: [
                                  SizedBox(
                                    height: 320,
                                    child: PageView.builder(
                                      controller: _quickPickPageController,
                                      itemCount: quickPickPageCount,
                                      itemBuilder: (context, pageIndex) {
                                        final songs = limitedQuickPick
                                            .skip(
                                              pageIndex * quickPickSongsPerPage,
                                            )
                                            .take(quickPickSongsPerPage)
                                            .toList();
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
                                                // Usar el método optimizado que cachea los widgets
                                                child: _buildQuickPickWidget(
                                                  song,
                                                  context,
                                                  songs,
                                                ),
                                              );
                                            },
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  // Solo mostrar el indicador si hay más de una página
                                  if (quickPickPageCount > 1)
                                    SmoothPageIndicator(
                                      controller: _quickPickPageController,
                                      count: quickPickPageCount,
                                      effect: WormEffect(
                                        dotHeight: 8,
                                        dotWidth: 8,
                                        activeDotColor: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                        dotColor: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.24),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                            const SizedBox(height: 32),

                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 8,
                              ),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  TranslatedText(
                                    'playlists',
                                    style: const TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),

                                  Row(
                                    children: [
                                      IconButton(
                                        icon: const Icon(
                                          Icons.refresh,
                                          size: 28,
                                        ),
                                        tooltip: LocaleProvider.tr('reload'),
                                        onPressed: _loadPlaylists,
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.add, size: 28),
                                        tooltip: LocaleProvider.tr(
                                          'create_new_playlist',
                                        ),
                                        padding: const EdgeInsets.only(left: 8),
                                        onPressed: () async {
                                          final controller =
                                              TextEditingController();
                                          final result = await showDialog<String>(
                                            context: context,
                                            builder: (context) => AlertDialog(
                                              shape: RoundedRectangleBorder(
                                                borderRadius: BorderRadius.circular(16),
                                                side: isAmoled && isDark
                                                    ? const BorderSide(color: Colors.white, width: 1)
                                                    : BorderSide.none,
                                              ),
                                              title: TranslatedText(
                                                'new_playlist',
                                              ),
                                              content: TextField(
                                                controller: controller,
                                                autofocus: true,
                                                decoration: InputDecoration(
                                                  labelText: LocaleProvider.tr(
                                                    'playlist_name',
                                                  ),
                                                ),
                                              ),
                                              actions: [
                                                TextButton(
                                                  onPressed: () => Navigator.of(
                                                    context,
                                                  ).pop(),
                                                  child: TranslatedText(
                                                    'cancel',
                                                  ),
                                                ),
                                                TextButton(
                                                  onPressed: () {
                                                    Navigator.of(context).pop(
                                                      controller.text.trim(),
                                                    );
                                                  },
                                                  child: TranslatedText(
                                                    'create',
                                                  ),
                                                ),
                                              ],
                                            ),
                                          );
                                          if (result != null &&
                                              result.isNotEmpty) {
                                            await PlaylistsDB().createPlaylist(
                                              result,
                                            );
                                            await _loadPlaylists();

                                            // Notificar a otras pantallas que deben actualizar las playlists
                                            playlistsShouldReload.value =
                                                !playlistsShouldReload.value;
                                          }
                                        },
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            // Aquí mostramos las playlists
                            if (_playlists.isEmpty)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 22,
                                ),
                                child: Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.playlist_remove,
                                        size: 48,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.6),
                                      ),
                                      const SizedBox(height: 16),
                                      TranslatedText(
                                        'no_playlists',
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: 0.6),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              )
                            else
                              ListView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: _playlists.length,
                                itemBuilder: (context, index) {
                                  final playlist = _playlists[index];
                                  return Column(
                                    children: [
                                      ListTile(
                                        leading: _buildPlaylistArtworkGrid(
                                          playlist,
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
                                                    leading: const Icon(
                                                      Icons.edit,
                                                    ),
                                                    title: TranslatedText(
                                                      'rename_playlist',
                                                    ),
                                                    onTap: () async {
                                                      Navigator.of(
                                                        context,
                                                      ).pop();
                                                      final controller =
                                                          TextEditingController(
                                                            text:
                                                                playlist['name'],
                                                          );
                                                      final result = await showDialog<String>(
                                                        context: context,
                                                        builder: (context) => AlertDialog(
                                                          shape: RoundedRectangleBorder(
                                                            borderRadius: BorderRadius.circular(16),
                                                            side: isAmoled && isDark
                                                                ? const BorderSide(color: Colors.white, width: 1)
                                                                : BorderSide.none,
                                                          ),
                                                          title: TranslatedText(
                                                            'rename_playlist',
                                                          ),
                                                          content: TextField(
                                                            controller:
                                                                controller,
                                                            autofocus: true,
                                                            decoration:
                                                                InputDecoration(
                                                                  labelText:
                                                                      LocaleProvider.tr(
                                                                        'new_name',
                                                                      ),
                                                                ),
                                                          ),
                                                          actions: [
                                                            TextButton(
                                                              onPressed: () =>
                                                                  Navigator.of(
                                                                    context,
                                                                  ).pop(),
                                                              child:
                                                                  TranslatedText(
                                                                    'cancel',
                                                                  ),
                                                            ),
                                                            TextButton(
                                                              onPressed: () {
                                                                Navigator.of(
                                                                  context,
                                                                ).pop(
                                                                  controller
                                                                      .text
                                                                      .trim(),
                                                                );
                                                              },
                                                              child:
                                                                  TranslatedText(
                                                                    'save',
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
                                                      }
                                                    },
                                                  ),
                                                  ListTile(
                                                    leading: const Icon(
                                                      Icons.delete_outline,
                                                    ),
                                                    title: TranslatedText(
                                                      'delete_playlist',
                                                    ),
                                                    onTap: () async {
                                                      Navigator.of(
                                                        context,
                                                      ).pop();
                                                      final confirm = await showDialog<bool>(
                                                        context: context,
                                                        builder: (context) => AlertDialog(
                                                          shape: RoundedRectangleBorder(
                                                            borderRadius: BorderRadius.circular(16),
                                                            side: isAmoled && isDark
                                                                ? const BorderSide(color: Colors.white, width: 1)
                                                                : BorderSide.none,
                                                          ),
                                                          title: TranslatedText(
                                                            'delete_playlist',
                                                          ),
                                                          content: TranslatedText(
                                                            'delete_playlist_confirm',
                                                          ),
                                                          actions: [
                                                            TextButton(
                                                              onPressed: () =>
                                                                  Navigator.of(
                                                                    context,
                                                                  ).pop(false),
                                                              child:
                                                                  TranslatedText(
                                                                    'cancel',
                                                                  ),
                                                            ),
                                                            TextButton(
                                                              onPressed: () =>
                                                                  Navigator.of(
                                                                    context,
                                                                  ).pop(true),
                                                              child:
                                                                  TranslatedText(
                                                                    'delete',
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
                                                      }
                                                    },
                                                  ),

                                                ],
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                      const SizedBox(height: 20),
                                    ],
                                  );
                                },
                              ),
                          ],
                        ),
                      ),
                    ),
            );
          },
        ),
      );
    
  }

  Widget _buildPlaylistArtworkGrid(Map<String, dynamic> playlist) {
    final rawList = playlist['songs'] as List?;
    // Filtra solo rutas válidas (no nulos ni vacíos)
    final filtered = (rawList ?? [])
        .where((e) => e != null && e.toString().isNotEmpty)
        .map((e) => e.toString())
        .toList();

    // Obtén las canciones reales que existen
    final List<SongModel> validSongs = [];
    for (final songPath in filtered) {
      final songIndex = allSongs.indexWhere((s) => s.data == songPath);
      if (songIndex != -1) {
        validSongs.add(allSongs[songIndex]);
      }
    }

    // Crear widget dependiendo del número de canciones
    return SizedBox(
      width: 57,
      height: 57,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: _buildArtworkLayout(validSongs),
      ),
    );
  }

  Widget _buildArtworkLayout(List<SongModel> songs) {
    switch (songs.length) {
      case 0:
        // Sin canciones: un solo ícono centrado
        return Container(
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: Center(
            child: Icon(
              Icons.music_note,
              color: Theme.of(context).colorScheme.onSurface,
              size: 24,
            ),
          ),
        );

      case 1:
        // Una canción: carátula completa
        return QueryArtworkWidget(
          id: songs[0].id,
          type: ArtworkType.AUDIO,
          artworkHeight: 57,
          artworkWidth: 57,
          artworkBorder: BorderRadius.zero,
          nullArtworkWidget: Container(
            color: Theme.of(context).colorScheme.surfaceContainer,
            child: Center(
              child: Icon(
                Icons.music_note,
                color: Theme.of(context).colorScheme.onSurface,
                size: 24,
              ),
            ),
          ),
        );

      case 2:
        // Dos canciones: lado a lado
        return Row(
          children: [
            Expanded(
              child: QueryArtworkWidget(
                id: songs[0].id,
                type: ArtworkType.AUDIO,
                artworkHeight: 57,
                artworkWidth: 28.5,
                artworkBorder: BorderRadius.zero,
                nullArtworkWidget: Container(
                  color: Theme.of(context).colorScheme.surfaceContainer,
                  child: Icon(
                    Icons.music_note,
                    color: Theme.of(context).colorScheme.onSurface,
                    size: 12,
                  ),
                ),
              ),
            ),
            Expanded(
              child: QueryArtworkWidget(
                id: songs[1].id,
                type: ArtworkType.AUDIO,
                artworkHeight: 57,
                artworkWidth: 28.5,
                artworkBorder: BorderRadius.zero,
                nullArtworkWidget: Container(
                  color: Theme.of(context).colorScheme.surfaceContainer,
                  child: Icon(
                    Icons.music_note,
                    color: Theme.of(context).colorScheme.onSurface,
                    size: 12,
                  ),
                ),
              ),
            ),
          ],
        );

      case 3:
        // Tres canciones: 2 arriba, 1 abajo centrada
        return Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: QueryArtworkWidget(
                      id: songs[0].id,
                      type: ArtworkType.AUDIO,
                      artworkHeight: 28.5,
                      artworkWidth: 28.5,
                      artworkBorder: BorderRadius.zero,
                      nullArtworkWidget: Container(
                        color: Theme.of(context).colorScheme.surfaceContainer,
                        child: Icon(
                          Icons.music_note,
                          color: Theme.of(context).colorScheme.onSurface,
                          size: 12,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: QueryArtworkWidget(
                      id: songs[1].id,
                      type: ArtworkType.AUDIO,
                      artworkHeight: 28.5,
                      artworkWidth: 28.5,
                      artworkBorder: BorderRadius.zero,
                      nullArtworkWidget: Container(
                        color: Theme.of(context).colorScheme.surfaceContainer,
                        child: Icon(
                          Icons.music_note,
                          color: Theme.of(context).colorScheme.onSurface,
                          size: 12,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: SizedBox(
                  width: 28.5,
                  height: 28.5,
                  child: QueryArtworkWidget(
                    id: songs[2].id,
                    type: ArtworkType.AUDIO,
                    artworkHeight: 28.5,
                    artworkWidth: 28.5,
                    artworkBorder: BorderRadius.zero,
                    nullArtworkWidget: Container(
                      color: Theme.of(context).colorScheme.surfaceContainer,
                      child: Icon(
                        Icons.music_note,
                        color: Theme.of(context).colorScheme.onSurface,
                        size: 12,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );

      default:
        // 4 o más canciones: grid 2x2 con las primeras 4
        return GridView.count(
          crossAxisCount: 2,
          physics: const NeverScrollableScrollPhysics(),
          children: List.generate(4, (index) {
            final song = songs[index];
            return QueryArtworkWidget(
              id: song.id,
              type: ArtworkType.AUDIO,
              artworkHeight: 28.5,
              artworkWidth: 28.5,
              artworkBorder: BorderRadius.zero,
              nullArtworkWidget: Container(
                color: Theme.of(context).colorScheme.surfaceContainer,
                child: Icon(
                  Icons.music_note,
                  color: Theme.of(context).colorScheme.onSurface,
                  size: 12,
                ),
              ),
            );
          }),
        );
    }
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
