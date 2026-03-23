import 'dart:async';
import 'package:music/widgets/refresh_m3e.dart';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:on_audio_query/on_audio_query.dart';
import 'package:music/main.dart' show AudioHandlerSafeCast, audioHandler;
import 'package:audio_service/audio_service.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'package:music/utils/encoding_utils.dart';
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
// import 'package:music/widgets/hero_cached.dart';
import 'package:music/widgets/artwork_list_tile.dart';
import 'package:music/utils/db/playlist_model.dart' as hive_model;
import 'package:music/utils/simple_yt_download.dart';
import 'package:music/utils/yt_search/service.dart' as yt_service;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:music/widgets/song_info_dialog.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:material_loading_indicator/loading_indicator.dart';

enum OrdenCarpetas {
  normal,
  alfabetico,
  invertido,
  ultimoAgregado,
  fechaEdicionAsc, // Más antiguas primero
  fechaEdicionDesc, // Más recientes primero
}

enum PlaylistSource { local, streaming, ytMusicCookies }

enum FoldersRootView { folders, allSongs, playlists }

OrdenCarpetas _orden = OrdenCarpetas.normal;
OrdenCarpetas _ordenPlaylist = OrdenCarpetas.normal;

class _StreamingPlaylistItem {
  final String rawPath;
  final String title;
  final String artist;
  final String? videoId;
  final String? artUri;
  final String? durationText;
  final int? durationMs;

  const _StreamingPlaylistItem({
    required this.rawPath,
    required this.title,
    required this.artist,
    this.videoId,
    this.artUri,
    this.durationText,
    this.durationMs,
  });
}

class _YtLibraryPlaylistItem {
  final String playlistId;
  final String title;
  final String? author;
  final String? thumbUrl;
  final String? countText;
  final int? trackCount;

  const _YtLibraryPlaylistItem({
    required this.playlistId,
    required this.title,
    this.author,
    this.thumbUrl,
    this.countText,
    this.trackCount,
  });
}

class _PlaylistListEntry {
  final hive_model.PlaylistModel? local;
  final _YtLibraryPlaylistItem? ytLibrary;

  const _PlaylistListEntry.local(this.local) : ytLibrary = null;
  const _PlaylistListEntry.ytLibrary(this.ytLibrary) : local = null;

  bool get isYtLibrary => ytLibrary != null;
}

class _StreamingArtwork extends StatefulWidget {
  final List<String> sources;
  final Color backgroundColor;
  final Color iconColor;

  const _StreamingArtwork({
    required this.sources,
    required this.backgroundColor,
    required this.iconColor,
  });

  @override
  State<_StreamingArtwork> createState() => _StreamingArtworkState();
}

class _StreamingArtworkState extends State<_StreamingArtwork> {
  int _sourceIndex = 0;

  void _tryNextSource() {
    if (_sourceIndex >= widget.sources.length - 1) return;
    if (!mounted) return;
    setState(() {
      _sourceIndex++;
    });
  }

  Widget _buildFallback() {
    return Container(
      color: Colors.transparent,
      child: Icon(Icons.music_note_rounded, color: Colors.transparent),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.sources.isEmpty || _sourceIndex >= widget.sources.length) {
      return _buildFallback();
    }

    final currentSource = widget.sources[_sourceIndex];
    final lower = currentSource.toLowerCase();

    if (lower.startsWith('file://') || currentSource.startsWith('/')) {
      final filePath = lower.startsWith('file://')
          ? (Uri.tryParse(currentSource)?.toFilePath() ?? '')
          : currentSource;
      if (filePath.isEmpty) {
        _tryNextSource();
        return _buildFallback();
      }

      return Image.file(
        File(filePath),
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          _tryNextSource();
          return _buildFallback();
        },
      );
    }

    return CachedNetworkImage(
      imageUrl: currentSource,
      fit: BoxFit.cover,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      placeholder: (context, url) => _buildFallback(),
      errorWidget: (context, url, error) {
        _tryNextSource();
        return _buildFallback();
      },
    );
  }
}

class FoldersScreen extends StatefulWidget {
  const FoldersScreen({super.key});

  @override
  State<FoldersScreen> createState() => _FoldersScreenState();
}

class _FoldersScreenState extends State<FoldersScreen>
    with WidgetsBindingObserver {
  static const bool _ytUiDebugLogs = true;

  void _ytUiLog(String message) {
    if (!_ytUiDebugLogs) return;
    debugPrint('[FOLDERS/YT] $message');
  }

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
  List<_StreamingPlaylistItem> _originalPlaylistStreamingItems = [];
  List<_StreamingPlaylistItem> _playlistStreamingItems = [];
  List<_StreamingPlaylistItem> _filteredPlaylistStreamingItems = [];

  // Variable para controlar si se muestran todas las canciones vs carpetas
  bool _showAllSongs = false;

  // Variables para la vista de playlists
  bool _showPlaylists = false;
  PlaylistSource _playlistSource = PlaylistSource.streaming;
  List<hive_model.PlaylistModel> _playlists = [];
  List<hive_model.PlaylistModel> _filteredPlaylists = [];
  List<_YtLibraryPlaylistItem> _ytLibraryPlaylists = [];
  List<_YtLibraryPlaylistItem> _filteredYtLibraryPlaylists = [];
  final Map<String, List<_StreamingPlaylistItem>> _ytPlaylistItemsCache = {};
  final Map<String, String?> _ytPlaylistContinuationTokenCache = {};
  int _ytPlaylistSongsLoadGeneration = 0;
  String? _ytActivePlaylistContinuationToken;
  bool _ytActivePlaylistHasMore = false;
  bool _isLoadingMoreYtPlaylistSongs = false;
  List<SongModel> _allSongsForGrid = [];
  Map<String, List<String>> _playlistArtworkSourcesCache = {};
  hive_model.PlaylistModel? _selectedPlaylist;
  _YtLibraryPlaylistItem? _selectedYtLibraryPlaylist;
  bool _hasYtAuthCookieSession = false;
  String? _ytAccountDisplayName;
  bool _isLoadingYtLibraryPlaylists = false;
  final TextEditingController _playlistSearchController =
      TextEditingController();

  Timer? _debounce;
  Timer? _playingDebounce;
  Timer? _mediaItemDebounce;
  final ValueNotifier<bool> _isPlayingNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<MediaItem?> _currentMediaItemNotifier =
      ValueNotifier<MediaItem?>(null);

  static String? _pathFromMediaItem(MediaItem? item) =>
      item?.extras?['data'] ?? item?.id;

  bool get _hasSelectedPlaylist =>
      _selectedPlaylist != null || _selectedYtLibraryPlaylist != null;
  bool get _isStreamingPlaylistDetail =>
      _hasSelectedPlaylist && _playlistSource != PlaylistSource.local;

  bool get _isSpanishAppLanguage =>
      languageNotifier.value.toLowerCase().startsWith('es');

  String _displayYtLibraryPlaylistTitle(String title) {
    final trimmed = title.trim();
    if (_isSpanishAppLanguage && trimmed.toLowerCase() == 'liked music') {
      return 'Música que te gustó';
    }
    return title;
  }

  bool _isLikedMusicYtPlaylist(_YtLibraryPlaylistItem item) {
    final playlistId = item.playlistId.trim().toUpperCase();
    if (playlistId == 'LM') return true;

    final rawTitle = item.title.trim().toLowerCase();
    if (rawTitle == 'liked music' ||
        rawTitle == 'música que te gustó' ||
        rawTitle == 'musica que te gusto') {
      return true;
    }

    final displayTitle = _displayYtLibraryPlaylistTitle(
      item.title,
    ).trim().toLowerCase();
    return displayTitle == 'música que te gustó' ||
        displayTitle == 'musica que te gusto';
  }

  String _currentSelectedPlaylistName() =>
      (_selectedYtLibraryPlaylist != null
          ? _displayYtLibraryPlaylistTitle(_selectedYtLibraryPlaylist!.title)
          : null) ??
      _selectedPlaylist?.name ??
      LocaleProvider.tr('playlists');

  String _playlistSourceLabel(PlaylistSource source) {
    switch (source) {
      case PlaylistSource.local:
        return 'local';
      case PlaylistSource.streaming:
        return 'streaming';
      case PlaylistSource.ytMusicCookies:
        return 'ytMusicCookies';
    }
  }

  String get _ytCookiesSourceLabel {
    final name = _ytAccountDisplayName?.trim();
    if (name != null && name.isNotEmpty) {
      return 'YouTube Music ($name)';
    }
    return 'YouTube Music (cookies)';
  }

  Future<void> _refreshYtAccountDisplayName({bool force = false}) async {
    if (!force) {
      final cached = _ytAccountDisplayName?.trim();
      if (cached != null && cached.isNotEmpty) return;
    }

    final hasAuth = await yt_service.hasYtMusicAuthCookieHeader();
    if (!mounted) return;
    if (!hasAuth) {
      if (_ytAccountDisplayName != null) {
        setState(() {
          _ytAccountDisplayName = null;
        });
      }
      return;
    }

    final accountName = await yt_service.getYtMusicAccountDisplayName();
    if (!mounted) return;
    final normalized = accountName?.trim();
    if (_ytAccountDisplayName != normalized) {
      setState(() {
        _ytAccountDisplayName = normalized;
      });
    }
  }

  void _invalidateYtPlaylistSongLoads(String reason) {
    _ytPlaylistSongsLoadGeneration++;
    _ytUiLog(
      '_invalidateYtPlaylistSongLoads generation=$_ytPlaylistSongsLoadGeneration reason=$reason',
    );
  }

  bool _isYtPlaylistSongLoadActive({
    required int generation,
    required String playlistId,
  }) {
    final isActive =
        mounted &&
        generation == _ytPlaylistSongsLoadGeneration &&
        _playlistSource == PlaylistSource.ytMusicCookies &&
        _selectedYtLibraryPlaylist?.playlistId == playlistId;
    if (!isActive) {
      _ytUiLog(
        '_loadSongsFromYtLibraryPlaylist discard stale result: req=$playlistId, '
        'generation=$generation, currentGeneration=$_ytPlaylistSongsLoadGeneration, '
        'selected=${_selectedYtLibraryPlaylist?.playlistId}, '
        'source=${_playlistSourceLabel(_playlistSource)}',
      );
    }
    return isActive;
  }

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final ScrollController _foldersScrollController = ScrollController();
  final ScrollController _playlistsScrollController = ScrollController();

  // Variables para búsqueda de carpetas
  final TextEditingController _folderSearchController = TextEditingController();
  final FocusNode _folderSearchFocusNode = FocusNode();
  List<MapEntry<String, List<String>>> _filteredFolders = [];

  double _lastBottomInset = 0.0;

  bool _isLoading = true;

  // Variable para verificar si estamos en Android 10+
  bool _isAndroid10OrHigher = false;

  static const String _orderPrefsKey = 'folders_screen_order_filter';
  static const String _orderPlaylistPrefsKey = 'playlists_screen_order_filter';
  static const String _lastRootViewPrefsKey = 'folders_screen_last_root_view';
  static const String _lastPlaylistSourcePrefsKey =
      'folders_screen_last_playlist_source';
  static const String _pinnedSongsKey = 'pinned_songs';
  static const String _ignoredSongsKey = 'ignored_songs';
  static const String _ignoredFoldersKey = 'ignored_folders';
  FoldersRootView _initialRootView = FoldersRootView.playlists;

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

  void _onFolderUpdated() async {
    final rawFolderPath = folderUpdatedNotifier.value;
    if (rawFolderPath == null || !mounted) return;

    // Normalizar path siguiendo la lógica de SongsIndexDB
    var dirPath = p.normalize(rawFolderPath);
    if (dirPath.contains('/')) dirPath = dirPath.replaceAll('/', '\\');
    dirPath = dirPath.trim();
    if (dirPath.endsWith('\\') && dirPath.length > 3) {
      dirPath = dirPath.substring(0, dirPath.length - 1);
    }
    dirPath = dirPath.toLowerCase();

    // Obtener canciones actualizadas directamente con la key normalizada
    final songs = await SongsIndexDB().getSongsFromFolder(dirPath);

    if (mounted) {
      setState(() {
        if (songs.isNotEmpty) {
          final isNew = !songPathsByFolder.containsKey(dirPath);
          songPathsByFolder[dirPath] = songs;

          if (isNew) {
            folderDisplayNames[dirPath] = rawFolderPath
                .split(RegExp(r'[\\/]'))
                .last;
          }
        }
      });

      if (carpetaSeleccionada == dirPath) {
        await _actualizarCarpetaActual();
      }
    }
  }

  void _onCoverQualityChanged() {
    if (!mounted) return;

    // Forzar recomputo de fuentes de carátula de playlists streaming.
    _playlistArtworkSourcesCache.clear();
    setState(() {});
  }

  /// Función específica para refrescar el contenido de la carpeta actual o todas las canciones
  Future<void> _refreshCurrentFolder() async {
    if (_showAllSongs) {
      // Recargar todas las canciones
      await _loadAllSongs();
    } else if (_selectedYtLibraryPlaylist != null) {
      await _loadSongsFromYtLibraryPlaylist(
        _selectedYtLibraryPlaylist!,
        forceRefresh: true,
      );
    } else if (_selectedPlaylist != null) {
      // Recargar la playlist seleccionada
      await _loadSongsFromPlaylist(_selectedPlaylist!);
    } else if (carpetaSeleccionada != null) {
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
    unawaited(_initializeScreenState());
    foldersShouldReload.addListener(_onFoldersShouldReload);
    folderUpdatedNotifier.addListener(_onFolderUpdated);
    coverQualityNotifier.addListener(_onCoverQualityChanged);

    // Escuchar cambios en el estado de reproducción con debounce
    // Solo actualizar si el valor realmente cambió para evitar rebuilds redundantes
    audioHandler?.playbackState.listen((state) {
      _playingDebounce?.cancel();
      _playingDebounce = Timer(const Duration(milliseconds: 100), () {
        if (mounted && _isPlayingNotifier.value != state.playing) {
          _isPlayingNotifier.value = state.playing;
        }
      });
    });

    // Inicializar con el valor actual si ya hay algo reproduciéndose
    if (audioHandler?.mediaItem.valueOrNull != null) {
      _mediaItemDebounce?.cancel();
      _currentMediaItemNotifier.value = audioHandler!.mediaItem.valueOrNull;
    }

    // Inicializar el estado de reproducción actual
    if (audioHandler?.playbackState.valueOrNull != null) {
      _isPlayingNotifier.value =
          audioHandler!.playbackState.valueOrNull!.playing;
    }

    // Un solo listener para MediaItem: evita rebuilds duplicados (antes 50ms + 200ms)
    // Solo actualizar si la ruta de la canción realmente cambió
    audioHandler?.mediaItem.listen((mediaItem) {
      final newPath = _pathFromMediaItem(mediaItem);
      _mediaItemDebounce?.cancel();
      _mediaItemDebounce = Timer(const Duration(milliseconds: 80), () {
        if (mounted &&
            _pathFromMediaItem(_currentMediaItemNotifier.value) != newPath) {
          _currentMediaItemNotifier.value = mediaItem;
        }
      });
    });
  }

  Future<void> _initializeScreenState() async {
    await _loadOrderFilter();
    await _loadLastViewPrefs();
    switch (_initialRootView) {
      case FoldersRootView.folders:
        await cargarCanciones();
        break;
      case FoldersRootView.allSongs:
        await _loadAllSongs();
        break;
      case FoldersRootView.playlists:
        await _loadPlaylists();
        break;
    }
  }

  FoldersRootView _currentRootView() {
    if (_showPlaylists) return FoldersRootView.playlists;
    if (_showAllSongs) return FoldersRootView.allSongs;
    return FoldersRootView.folders;
  }

  Future<void> _saveLastViewPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastRootViewPrefsKey, _currentRootView().index);
    await prefs.setInt(_lastPlaylistSourcePrefsKey, _playlistSource.index);
  }

  Future<void> _loadLastViewPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final savedRootView = prefs.getInt(_lastRootViewPrefsKey);
    if (savedRootView != null &&
        savedRootView >= 0 &&
        savedRootView < FoldersRootView.values.length) {
      _initialRootView = FoldersRootView.values[savedRootView];
    }

    final savedPlaylistSource = prefs.getInt(_lastPlaylistSourcePrefsKey);
    if (savedPlaylistSource != null &&
        savedPlaylistSource >= 0 &&
        savedPlaylistSource < PlaylistSource.values.length) {
      if (mounted) {
        setState(() {
          _playlistSource = PlaylistSource.values[savedPlaylistSource];
        });
      } else {
        _playlistSource = PlaylistSource.values[savedPlaylistSource];
      }
    }
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

    final int? savedPlaylistIndex = prefs.getInt(_orderPlaylistPrefsKey);
    if (savedPlaylistIndex != null &&
        savedPlaylistIndex >= 0 &&
        savedPlaylistIndex < OrdenCarpetas.values.length) {
      setState(() {
        _ordenPlaylist = OrdenCarpetas.values[savedPlaylistIndex];
      });
    }
  }

  void _setPlaylistSource(PlaylistSource source) {
    if (_playlistSource == source) return;
    _ytUiLog(
      'set source: ${_playlistSourceLabel(_playlistSource)} -> ${_playlistSourceLabel(source)}',
    );
    _invalidateYtPlaylistSongLoads(
      'source-change:${_playlistSourceLabel(_playlistSource)}->${_playlistSourceLabel(source)}',
    );
    setState(() {
      _playlistSource = source;
      _applyPlaylistFilters();
    });
    if (_playlistSource == PlaylistSource.ytMusicCookies) {
      unawaited(_loadYtLibraryPlaylists());
      unawaited(_refreshYtAccountDisplayName());
    }
    unawaited(_saveLastViewPrefs());
  }

  bool _isStreamingPath(String path) {
    final normalized = path.trim().toLowerCase();
    if (normalized.isEmpty) return false;
    if (normalized.startsWith('/')) return false;
    if (normalized.startsWith('file://')) return false;
    if (normalized.startsWith('content://')) return false;
    return true;
  }

  String? _extractVideoIdFromPath(String rawPath) {
    final path = rawPath.trim();
    if (path.isEmpty) return null;

    if (path.startsWith('yt:')) {
      final id = path.substring(3).trim();
      return id.isEmpty ? null : id;
    }

    final uri = Uri.tryParse(path);
    if (uri != null) {
      final queryVideoId = uri.queryParameters['v']?.trim();
      if (queryVideoId != null && queryVideoId.isNotEmpty) {
        return queryVideoId;
      }
      if (uri.host.contains('youtu.be') && uri.pathSegments.isNotEmpty) {
        final shortId = uri.pathSegments.first.trim();
        if (shortId.isNotEmpty) {
          return shortId;
        }
      }
    }

    final idLike = RegExp(r'^[a-zA-Z0-9_-]{11}$');
    if (idLike.hasMatch(path)) return path;
    return null;
  }

  String _currentStreamingCoverQuality() {
    final quality = coverQualityNotifier.value;
    if (quality == 'high' ||
        quality == 'medium' ||
        quality == 'medium_low' ||
        quality == 'low') {
      return quality;
    }
    return 'medium';
  }

  String _ytThumbFileForQuality(String quality) {
    switch (quality) {
      case 'medium':
        return 'sddefault.jpg';
      case 'medium_low':
        return 'hqdefault.jpg';
      case 'low':
        return 'hqdefault.jpg';
      default:
        return 'maxresdefault.jpg';
    }
  }

  String _googleThumbSizeForQuality(String quality) {
    switch (quality) {
      case 'medium':
        return 's600';
      case 'medium_low':
        return 's450';
      case 'low':
        return 's300';
      default:
        return 's1200';
    }
  }

  String? _applyStreamingArtworkQuality(String? rawUrl, {String? videoId}) {
    final normalized = rawUrl?.trim();
    if (normalized == null || normalized.isEmpty || normalized == 'null') {
      return null;
    }

    final quality = _currentStreamingCoverQuality();
    final lower = normalized.toLowerCase();

    if (lower.contains('googleusercontent.com')) {
      final size = _googleThumbSizeForQuality(quality);
      final replaced = normalized.replaceFirst(RegExp(r'=s\d+\b'), '=$size');
      if (replaced != normalized) return replaced;

      final eqIndex = normalized.lastIndexOf('=');
      if (eqIndex != -1 && eqIndex < normalized.length - 1) {
        final suffix = normalized.substring(eqIndex + 1);
        if (!suffix.contains('/')) {
          return '${normalized.substring(0, eqIndex + 1)}$size';
        }
      }
      return '$normalized=$size';
    }

    final uri = Uri.tryParse(normalized);
    if (uri == null) return normalized;

    final host = uri.host.toLowerCase();
    if (!host.contains('ytimg.com') && !host.contains('img.youtube.com')) {
      return normalized;
    }

    final qualityFile = _ytThumbFileForQuality(quality);
    final qualityWebp = qualityFile.replaceAll('.jpg', '.webp');
    final segments = List<String>.from(uri.pathSegments);

    if (segments.isNotEmpty) {
      final last = segments.last.toLowerCase();
      final isKnownThumb =
          last.contains('maxresdefault') ||
          last.contains('sddefault') ||
          last.contains('hqdefault') ||
          last.contains('mqdefault');
      if (isKnownThumb) {
        final useWebp = last.endsWith('.webp');
        segments[segments.length - 1] = useWebp ? qualityWebp : qualityFile;
        return uri.replace(pathSegments: segments).toString();
      }
    }

    final id = videoId?.trim();
    if (id != null && id.isNotEmpty) {
      return 'https://i.ytimg.com/vi/$id/$qualityFile';
    }

    return normalized;
  }

  List<String> _streamingFallbackArtworkUrls(String videoId) {
    final qualityFile = _ytThumbFileForQuality(_currentStreamingCoverQuality());
    final urls = <String>[
      'https://i.ytimg.com/vi/$videoId/$qualityFile',
      'https://img.youtube.com/vi/$videoId/sddefault.jpg',
      'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
      'https://img.youtube.com/vi/$videoId/maxresdefault.jpg',
    ];
    return urls.toSet().toList();
  }

  List<String> _streamingArtworkSources(_StreamingPlaylistItem item) {
    final sources = <String>[];
    final id = item.videoId?.trim();
    final rawArt = _applyStreamingArtworkQuality(item.artUri, videoId: id);
    if (rawArt != null && rawArt.isNotEmpty) {
      sources.add(rawArt);
    }
    if (id != null && id.isNotEmpty) {
      sources.addAll(_streamingFallbackArtworkUrls(id));
    }
    return sources.toSet().toList();
  }

  bool _playlistMatchesCurrentSource(hive_model.PlaylistModel playlist) {
    switch (_playlistSource) {
      case PlaylistSource.local:
        return _playlistMatchesTargetSource(playlist, forStreaming: false);
      case PlaylistSource.streaming:
        return _playlistMatchesTargetSource(playlist, forStreaming: true);
      case PlaylistSource.ytMusicCookies:
        return false;
    }
  }

  bool _playlistMatchesTargetSource(
    hive_model.PlaylistModel playlist, {
    required bool forStreaming,
  }) {
    if (playlist.songPaths.isEmpty) return true;
    if (forStreaming) return playlist.songPaths.any(_isStreamingPath);
    return playlist.songPaths.any((path) => !_isStreamingPath(path));
  }

  void _applyPlaylistFilters() {
    final query = _playlistSearchController.text.trim().toLowerCase();
    final sourceFiltered = _playlists
        .where(_playlistMatchesCurrentSource)
        .toList();
    final includeYtLibrary = _playlistSource == PlaylistSource.ytMusicCookies;

    List<_YtLibraryPlaylistItem> ytFiltered;
    if (includeYtLibrary) {
      ytFiltered = _ytLibraryPlaylists.toList();
    } else {
      ytFiltered = [];
    }

    if (query.isEmpty) {
      _filteredPlaylists = sourceFiltered;
      _filteredYtLibraryPlaylists = ytFiltered;
      return;
    }
    _filteredPlaylists = sourceFiltered
        .where((p) => p.name.toLowerCase().contains(query))
        .toList();
    _filteredYtLibraryPlaylists = ytFiltered.where((playlist) {
      final title = playlist.title.toLowerCase();
      final titleDisplay = _displayYtLibraryPlaylistTitle(
        playlist.title,
      ).toLowerCase();
      final author = (playlist.author ?? '').toLowerCase();
      final count = (playlist.countText ?? '').toLowerCase();
      return title.contains(query) ||
          titleDisplay.contains(query) ||
          author.contains(query) ||
          count.contains(query);
    }).toList();
  }

  List<_PlaylistListEntry> _buildPlaylistListEntries() {
    final entries = <_PlaylistListEntry>[];
    if (_playlistSource == PlaylistSource.ytMusicCookies) {
      entries.addAll(
        _filteredYtLibraryPlaylists.map(_PlaylistListEntry.ytLibrary),
      );
      return entries;
    }
    entries.addAll(_filteredPlaylists.map(_PlaylistListEntry.local));
    return entries;
  }

  String _formatYtLibraryPlaylistSubtitle(_YtLibraryPlaylistItem item) {
    if (_isLikedMusicYtPlaylist(item)) {
      return LocaleProvider.tr('yt_auto_generated_playlist');
    }

    final countText = item.countText?.trim();
    if (countText != null && countText.isNotEmpty) {
      return _localizeYtTrackCountText(countText);
    }
    final count = item.trackCount;
    if (count != null && count > 0) {
      return '$count ${LocaleProvider.tr('songs')}';
    }
    final author = item.author?.trim();
    if (author != null && author.isNotEmpty) return author;
    return LocaleProvider.tr('playlists');
  }

  String _localizeYtTrackCountText(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return trimmed;

    final singularSong = LocaleProvider.tr('mode_song').toLowerCase();
    final pluralSongs = LocaleProvider.tr('songs').toLowerCase();

    return trimmed.replaceAllMapped(
      RegExp(r'\btracks?\b', caseSensitive: false),
      (match) {
        final token = match.group(0)?.toLowerCase() ?? '';
        return token == 'track' ? singularSong : pluralSongs;
      },
    );
  }

  Widget _buildYtLibraryPlaylistArtwork(_YtLibraryPlaylistItem playlist) {
    final art = _applyStreamingArtworkQuality(playlist.thumbUrl);
    if (art == null || art.isEmpty) {
      return Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: Theme.of(context).colorScheme.surfaceContainer,
        ),
        child: Icon(
          Icons.queue_music_rounded,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 48,
        height: 48,
        child: CachedNetworkImage(
          imageUrl: art,
          fit: BoxFit.cover,
          fadeInDuration: Duration.zero,
          fadeOutDuration: Duration.zero,
          errorWidget: (context, url, error) => Container(
            color: Theme.of(context).colorScheme.surfaceContainer,
            child: Icon(
              Icons.queue_music_rounded,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _loadYtLibraryPlaylists({bool forceRefresh = false}) async {
    _ytUiLog(
      '_loadYtLibraryPlaylists start: forceRefresh=$forceRefresh, currentSource=${_playlistSourceLabel(_playlistSource)}',
    );
    final hasAuth = await yt_service.hasYtMusicAuthCookieHeader();
    _ytUiLog('_loadYtLibraryPlaylists hasAuth=$hasAuth');
    if (!mounted) return;

    if (!hasAuth) {
      _ytUiLog('_loadYtLibraryPlaylists aborted: no auth cookie');
      setState(() {
        _hasYtAuthCookieSession = false;
        _isLoadingYtLibraryPlaylists = false;
        _ytLibraryPlaylists = [];
        _filteredYtLibraryPlaylists = [];
      });
      return;
    }

    if (_isLoadingYtLibraryPlaylists) return;
    if (!forceRefresh && _ytLibraryPlaylists.isNotEmpty) {
      _ytUiLog(
        '_loadYtLibraryPlaylists using cache: cached=${_ytLibraryPlaylists.length}',
      );
      setState(() {
        _hasYtAuthCookieSession = true;
        _applyPlaylistFilters();
      });
      return;
    }

    setState(() {
      _hasYtAuthCookieSession = true;
      _isLoadingYtLibraryPlaylists = true;
    });

    try {
      final rawPlaylists = await yt_service.getLibraryPlaylists(limit: 120);
      _ytUiLog('service.getLibraryPlaylists returned=${rawPlaylists.length}');
      final parsed = rawPlaylists
          .map(
            (playlist) => _YtLibraryPlaylistItem(
              playlistId: playlist.playlistId,
              title: playlist.title,
              author: playlist.author,
              thumbUrl: playlist.thumbUrl,
              countText: playlist.countText,
              trackCount: playlist.trackCount,
            ),
          )
          .toList();

      if (!mounted) return;
      setState(() {
        _ytLibraryPlaylists = parsed;
        _isLoadingYtLibraryPlaylists = false;
        _applyPlaylistFilters();
      });
      _ytUiLog(
        '_loadYtLibraryPlaylists done: parsed=${parsed.length}, filtered=${_filteredYtLibraryPlaylists.length}',
      );
    } catch (e) {
      _ytUiLog('_loadYtLibraryPlaylists exception while loading playlists: $e');
      if (!mounted) return;
      setState(() {
        _isLoadingYtLibraryPlaylists = false;
        _applyPlaylistFilters();
      });
    }
  }

  Future<void> _saveOrderFilter() async {
    final prefs = await SharedPreferences.getInstance();
    if (_hasSelectedPlaylist) {
      await prefs.setInt(_orderPlaylistPrefsKey, _ordenPlaylist.index);
    } else {
      await prefs.setInt(_orderPrefsKey, _orden.index);
    }
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

    final allFolderKeys = {...folders, ...ignored};
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
      final paths = await SongsIndexDB().getSongsFromFolder(
        normalizedFolderPath,
      );
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
    final isIgnored = await isSongIgnored(song.data);

    if (!context.mounted) return;
    final isAmoled =
        Theme.of(context).brightness == Brightness.dark &&
        Theme.of(context).colorScheme.surface == Colors.black;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) {
        final maxHeight =
            MediaQuery.of(context).size.height -
            MediaQuery.of(context).padding.top;
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
                                song.displayTitle,
                                maxLines: 1,
                                style: Theme.of(context).textTheme.titleMedium,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                song.displayArtist,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: isAmoled
                                      ? Colors.white.withValues(alpha: 0.85)
                                      : null,
                                ),
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
                              color:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context)
                                        .colorScheme
                                        .onPrimaryContainer
                                        .withValues(alpha: 0.7),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.search,
                                  size: 20,
                                  color:
                                      Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? Theme.of(context).colorScheme.onPrimary
                                      : Theme.of(
                                          context,
                                        ).colorScheme.surfaceContainer,
                                ),
                                const SizedBox(width: 8),
                                TranslatedText(
                                  'search',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14,
                                    color:
                                        Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? Theme.of(
                                            context,
                                          ).colorScheme.onPrimary
                                        : Theme.of(
                                            context,
                                          ).colorScheme.surfaceContainer,
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
                      await audioHandler.myHandler?.addSongsToQueueEnd([song]);
                    },
                  ),
                  ListTile(
                    leading: Icon(
                      isFavorite
                          ? Icons.delete_outline
                          : Icons.favorite_outline_rounded,
                      weight: isFavorite ? null : 600,
                    ),
                    title: TranslatedText(
                      isFavorite ? 'remove_from_favorites' : 'add_to_favorites',
                    ),
                    onTap: () async {
                      Navigator.of(context).pop();

                      if (isFavorite) {
                        await FavoritesDB().removeFavorite(song.data);
                        favoritesShouldReload.value =
                            !favoritesShouldReload.value;
                      } else {
                        await _addToFavorites(song);
                        favoritesShouldReload.value =
                            !favoritesShouldReload.value;
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
                          ShareParams(
                            text: song.displayTitle,
                            files: [XFile(dataPath)],
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

                  // Botón "Más" para mostrar opciones adicionales
                  ListTile(
                    leading: const Icon(Icons.more_horiz),
                    title: TranslatedText('more'),
                    onTap: () {
                      Navigator.of(context).pop();
                      _showMoreOptionsModal(context, song, isIgnored);
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

  void _showMoreOptionsModal(
    BuildContext context,
    SongModel song,
    bool isIgnored,
  ) {
    final isAmoled =
        Theme.of(context).brightness == Brightness.dark &&
        Theme.of(context).colorScheme.surface == Colors.black;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) {
        final maxHeight =
            MediaQuery.of(context).size.height -
            MediaQuery.of(context).padding.top;
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
                                song.displayTitle,
                                maxLines: 1,
                                style: Theme.of(context).textTheme.titleMedium,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                song.displayArtist,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: isAmoled
                                      ? Colors.white.withValues(alpha: 0.85)
                                      : null,
                                ),
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
                  if (song.displayArtist.trim().isNotEmpty)
                    ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: const TranslatedText('go_to_artist'),
                      onTap: () {
                        Navigator.of(context).pop();
                        final name = song.displayArtist.trim();
                        if (name.isEmpty) return;
                        Navigator.of(context).push(
                          PageRouteBuilder(
                            pageBuilder:
                                (context, animation, secondaryAnimation) =>
                                    ArtistScreen(artistName: name),
                            transitionsBuilder:
                                (
                                  context,
                                  animation,
                                  secondaryAnimation,
                                  child,
                                ) {
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
                      await SongInfoDialog.showFromSong(
                        context,
                        song,
                        colorSchemeNotifier,
                      );
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
      album: song.displayAlbum,
      title: song.displayTitle,
      artist: song.displayArtist,
      artUri: song.uri != null ? Uri.parse(song.uri!) : null,
      extras: {'data': song.data, 'db_id': song.id.toString()},
    );
  }

  // Para reproducir y abrir PlayerScreen:
  Future<void> _playSongAndOpenPlayer(String path) async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (playLoadingNotifier.value) return;
    // Desactiva visualmente el shuffle de inmediato
    try {
      if (audioHandler is MyAudioHandler) {
        audioHandler.myHandler?.isShuffleNotifier.value = false;
      }
    } catch (_) {}

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
      final previousMediaItem = audioHandler.myHandler?.mediaItem.value;
      final wasStreamingBeforeSelection =
          previousMediaItem?.extras?['isStreaming'] == true;

      // Crear MediaItem temporal y actualizar inmediatamente para evitar visualizar la canción anterior
      // ArtworkHeroCached.clearFallback();

      // Iniciar carga de carátula
      final artUriFuture = getOrCacheArtwork(songId, songPath);

      Uri? cachedArtUri;
      try {
        // Intentar obtener si es rápido (cache)
        cachedArtUri = await artUriFuture.timeout(
          const Duration(milliseconds: 25),
        );
      } catch (_) {
        // Si no es rápido, actualizar cuando esté listo para evitar el flash del placeholder
        artUriFuture.then((uri) {
          if (uri != null && mounted) {
            final handler = audioHandler.myHandler;
            final current = handler?.mediaItem.value;
            // Verificar que seguimos en la misma canción
            if (current != null && current.extras?['songId'] == songId) {
              final updatedItem = current.copyWith(artUri: uri);
              handler?.mediaItem.add(updatedItem);
            }
          }
        });
      }

      if (audioHandler != null && !wasStreamingBeforeSelection) {
        final tempMediaItem = MediaItem(
          id: song.data,
          title: song.displayTitle,
          artist: song.displayArtist,
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
        audioHandler.myHandler?.mediaItem.add(tempMediaItem);
      }

      // Abrir el panel del reproductor con la nueva animación
      if (!mounted) return;
      openPlayerPanelNotifier.value = true;

      // Activar indicador de carga
      final loaderStartedAt = DateTime.now();
      const minLoaderVisible = Duration(milliseconds: 320);
      playLoadingNotifier.value = true;
      final loaderHardGuard = Timer(const Duration(seconds: 6), () {
        // Loader local se gestiona globalmente desde audio handler.
      });

      try {
        await Future<void>.delayed(const Duration(milliseconds: 16));
        if (!mounted) return;
        await _playSong(
          path,
        ).timeout(const Duration(seconds: 4), onTimeout: () {});
      } finally {
        loaderHardGuard.cancel();
        final elapsed = DateTime.now().difference(loaderStartedAt);
        if (elapsed < minLoaderVisible) {
          await Future<void>.delayed(minLoaderVisible - elapsed);
        }
        // Desactivar indicador de carga lo gestiona audio handler para local.
      }
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
      final handler = audioHandler.myHandler;
      // Guardar solo el nombre de la carpeta como origen
      final prefs = await SharedPreferences.getInstance();
      String origen;
      if (carpetaSeleccionada != null) {
        if (carpetaSeleccionada == '__ALL_SONGS__') {
          // Usar la traducción para "Todas las canciones"
          origen = LocaleProvider.tr('all_songs');
        } else if (carpetaSeleccionada!.startsWith('__PLAYLIST__') ||
            carpetaSeleccionada!.startsWith('__YT_PLAYLIST__')) {
          // Usar el nombre de la playlist
          origen = _currentSelectedPlaylistName();
        } else {
          final parts = carpetaSeleccionada!.split(RegExp(r'[\\/]'));
          origen = parts.isNotEmpty ? parts.last : carpetaSeleccionada!;
        }
      } else {
        origen = "Carpeta";
      }
      await prefs.setString('last_queue_source', origen);

      // Limpiar la cola y el MediaItem antes de mostrar la nueva canción (Comportamiento Favorites)
      handler?.queue.add([]);

      // Limpiar el fallback de las carátulas para evitar parpadeo
      // ArtworkHeroCached.clearFallback();

      await handler?.setQueueFromSongs(filtered, initialIndex: index);
      await handler?.play();
    }
  }

  Future<bool> _deleteSongFromDevice(SongModel song) async {
    try {
      final file = File(song.data);
      if (await file.exists()) {
        // Si está reproduciéndose esta canción, pasar a la siguiente antes de borrar
        try {
          final handler = audioHandler.myHandler;
          final current = handler?.mediaItem.valueOrNull;
          final isCurrent =
              current?.id == song.data || current?.extras?['data'] == song.data;
          if (isCurrent) {
            // Quitar de la cola priorizando saltar a la siguiente
            await handler?.removeSongByPath(song.data);
          } else {
            // Quitarla de la cola si estuviera presente
            await handler?.removeSongByPath(song.data);
          }
        } catch (_) {}

        await file.delete();

        // Notificar al MediaStore de Android que el archivo fue eliminado
        try {
          await OnAudioQuery().scanMedia(song.data);
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
    final artist = (song.displayArtist.trim().isEmpty)
        ? LocaleProvider.tr('unknown_artist')
        : song.displayArtist;

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

  int? _parseDurationMs(dynamic raw) {
    if (raw is int && raw > 0) return raw;
    if (raw is num && raw > 0) return raw.toInt();
    if (raw is String) {
      final parsed = int.tryParse(raw.trim());
      if (parsed != null && parsed > 0) return parsed;
    }
    return null;
  }

  String _formatDurationMs(int durationMs) {
    final duration = Duration(milliseconds: durationMs);
    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:$seconds';
    }
    return '$minutes:$seconds';
  }

  String _formatStreamingArtistWithDuration(_StreamingPlaylistItem item) {
    final artist = item.artist.trim().isEmpty
        ? LocaleProvider.tr('artist_unknown')
        : item.artist;

    final durationText = item.durationText?.trim();
    if (durationText != null && durationText.isNotEmpty) {
      return '$artist • $durationText';
    }

    final durationMs = item.durationMs;
    if (durationMs != null && durationMs > 0) {
      return '$artist • ${_formatDurationMs(durationMs)}';
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
      audioHandler.myHandler?.isShuffleNotifier.value = false;
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
    final ordenActual = _hasSelectedPlaylist ? _ordenPlaylist : _orden;
    switch (ordenActual) {
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

  void _aplicarOrdenamientoStreaming(List<_StreamingPlaylistItem> lista) {
    final ordenActual = _hasSelectedPlaylist ? _ordenPlaylist : _orden;
    switch (ordenActual) {
      case OrdenCarpetas.normal:
        lista
          ..clear()
          ..addAll(_originalPlaylistStreamingItems);
        break;
      case OrdenCarpetas.alfabetico:
        lista.sort((a, b) => a.title.compareTo(b.title));
        break;
      case OrdenCarpetas.invertido:
        lista.sort((a, b) => b.title.compareTo(a.title));
        break;
      case OrdenCarpetas.ultimoAgregado:
        lista
          ..clear()
          ..addAll(_originalPlaylistStreamingItems.reversed);
        break;
      case OrdenCarpetas.fechaEdicionAsc:
      case OrdenCarpetas.fechaEdicionDesc:
        // No aplica para streaming: mantener orden actual/base.
        break;
    }
  }

  // Modificar _ordenarCanciones y _onSearchChanged para ser async y esperar el ordenamiento
  Future<void> _ordenarCanciones() async {
    if (_isStreamingPlaylistDetail) {
      _aplicarOrdenamientoStreaming(_playlistStreamingItems);
      _saveOrderFilter();
      await _onSearchChanged();
      return;
    }

    await _aplicarOrdenamiento(_filteredSongs);
    _saveOrderFilter();
    await _onSearchChanged();
  }

  Future<void> _onSearchChanged() async {
    final query = quitarDiacriticos(_searchController.text.toLowerCase());

    if (_isStreamingPlaylistDetail) {
      if (query.isEmpty) {
        setState(() {
          _filteredPlaylistStreamingItems = [];
        });
        return;
      }
      setState(() {
        _filteredPlaylistStreamingItems = _playlistStreamingItems.where((item) {
          final title = quitarDiacriticos(item.title);
          final artist = quitarDiacriticos(item.artist);
          final rawPath = quitarDiacriticos(item.rawPath);
          final videoId = quitarDiacriticos(item.videoId ?? '');
          return title.contains(query) ||
              artist.contains(query) ||
              rawPath.contains(query) ||
              videoId.contains(query);
        }).toList();
      });
      return;
    }

    final allSongsOrdered = List<SongModel>.from(_originalSongs);
    await _aplicarOrdenamiento(allSongsOrdered);
    _filteredSongs = allSongsOrdered;

    List<SongModel> displayList;
    if (query.isEmpty) {
      displayList = List<SongModel>.from(allSongsOrdered);
    } else {
      displayList = allSongsOrdered.where((song) {
        final title = quitarDiacriticos(song.displayTitle);
        final artist = quitarDiacriticos(song.displayArtist);
        return title.contains(query) || artist.contains(query);
      }).toList();
    }

    setState(() {
      _displaySongs = displayList;
    });
  }

  Future<void> _playStreamingPlaylistItem(_StreamingPlaylistItem item) async {
    if (playLoadingNotifier.value) return;
    final targetVideoId = item.videoId?.trim();
    if (targetVideoId == null || targetVideoId.isEmpty) return;

    final loaderStartedAt = DateTime.now();
    const minLoaderVisible = Duration(milliseconds: 650);
    playLoadingNotifier.value = true;
    openPlayerPanelNotifier.value = true;
    var loadingReleased = false;
    StreamSubscription<PlaybackState>? playbackWatchSub;
    Timer? loadingGuard;
    void releaseLoading() {
      if (loadingReleased) return;
      loadingReleased = true;
      loadingGuard?.cancel();
      loadingGuard = null;
      playbackWatchSub?.cancel();
      playbackWatchSub = null;

      final elapsed = DateTime.now().difference(loaderStartedAt);
      if (elapsed >= minLoaderVisible) {
        playLoadingNotifier.value = false;
      } else {
        final remaining = minLoaderVisible - elapsed;
        Timer(remaining, () {
          playLoadingNotifier.value = false;
        });
      }
    }

    loadingGuard = Timer(const Duration(seconds: 8), releaseLoading);
    try {
      final handler = audioHandler;
      if (handler == null) return;
      playbackWatchSub = handler.playbackState.listen((playbackState) {
        if (loadingReleased) return;
        final currentMedia = handler.mediaItem.value;
        final currentVideoId = currentMedia?.extras?['videoId']
            ?.toString()
            .trim();
        if (playbackState.playing &&
            currentVideoId == targetVideoId &&
            playbackState.updatePosition > Duration.zero) {
          releaseLoading();
        }
      });
      // En playlists streaming, siempre enviar la lista completa al reproductor
      // y solo usar el item tocado para resolver el índice inicial.
      final queueItems = _playlistStreamingItems
          .where((entry) => (entry.videoId?.trim().isNotEmpty ?? false))
          .map((entry) {
            final entryVideoId = entry.videoId!.trim();
            final entryArtUri =
                _applyStreamingArtworkQuality(
                  entry.artUri,
                  videoId: entryVideoId,
                ) ??
                _streamingFallbackArtworkUrls(entryVideoId).first;
            return <String, dynamic>{
              'videoId': entryVideoId,
              'title': entry.title.trim().isNotEmpty
                  ? entry.title.trim()
                  : LocaleProvider.tr('title_unknown'),
              'artist': entry.artist.trim().isNotEmpty
                  ? entry.artist.trim()
                  : LocaleProvider.tr('artist_unknown'),
              'artUri': entryArtUri,
              if (entry.durationMs != null && entry.durationMs! > 0)
                'durationMs': entry.durationMs,
              if (entry.durationText != null &&
                  entry.durationText!.trim().isNotEmpty)
                'durationText': entry.durationText!.trim(),
            };
          })
          .toList();
      if (queueItems.isEmpty) return;
      int initialQueueIndex = queueItems.indexWhere(
        (entry) => entry['videoId'] == targetVideoId,
      );
      if (initialQueueIndex < 0) initialQueueIndex = 0;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'last_queue_source',
        _currentSelectedPlaylistName(),
      );

      await handler
          .customAction('playYtStreamQueue', {
            'items': queueItems,
            'initialIndex': initialQueueIndex,
            'autoPlay': true,
          })
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      releaseLoading();
    } finally {
      if (loadingReleased) {
        loadingGuard?.cancel();
        loadingGuard = null;
        await playbackWatchSub?.cancel();
        playbackWatchSub = null;
      }
    }
  }

  Future<void> _startStreamingRadioFromItem(_StreamingPlaylistItem item) async {
    final videoId = item.videoId?.trim();
    if (videoId == null || videoId.isEmpty) return;
    if (playLoadingNotifier.value) return;

    playLoadingNotifier.value = true;
    openPlayerPanelNotifier.value = true;
    try {
      final handler = audioHandler;
      if (handler == null) {
        playLoadingNotifier.value = false;
        return;
      }
      final artUri =
          _applyStreamingArtworkQuality(item.artUri, videoId: videoId) ??
          _streamingFallbackArtworkUrls(videoId).first;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'last_queue_source',
        _currentSelectedPlaylistName(),
      );

      await handler
          .customAction('playYtStreamQueue', {
            'items': [
              {
                'videoId': videoId,
                'title': item.title.trim().isNotEmpty
                    ? item.title.trim()
                    : LocaleProvider.tr('title_unknown'),
                'artist': item.artist.trim().isNotEmpty
                    ? item.artist.trim()
                    : LocaleProvider.tr('artist_unknown'),
                'artUri': artUri,
                if (item.durationMs != null && item.durationMs! > 0)
                  'durationMs': item.durationMs,
                if (item.durationText != null &&
                    item.durationText!.trim().isNotEmpty)
                  'durationText': item.durationText!.trim(),
              },
            ],
            'initialIndex': 0,
            'autoPlay': true,
            'autoStartRadio': true,
          })
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      playLoadingNotifier.value = false;
    }
  }

  String _streamingDisplayUrl(_StreamingPlaylistItem item) {
    final id = item.videoId?.trim();
    if (id != null && id.isNotEmpty) {
      return 'https://www.youtube.com/watch?v=$id';
    }
    return item.rawPath;
  }

  Future<void> _downloadStreamingPlaylistItem(
    _StreamingPlaylistItem item,
  ) async {
    final videoId = item.videoId?.trim();
    if (videoId == null || videoId.isEmpty) return;
    await SimpleYtDownload.downloadVideoWithArtist(
      context,
      videoId,
      item.title,
      item.artist,
      thumbUrl: _applyStreamingArtworkQuality(item.artUri, videoId: videoId),
    );
  }

  Future<void> _searchStreamingOnYouTube(_StreamingPlaylistItem item) async {
    try {
      String searchQuery = item.title.trim();
      final artist = item.artist.trim();
      if (artist.isNotEmpty &&
          artist != LocaleProvider.tr('artist_unknown').trim()) {
        searchQuery = '$artist ${item.title.trim()}';
      }
      final encodedQuery = Uri.encodeComponent(searchQuery);
      final url = Uri.parse(
        'https://www.youtube.com/results?search_query=$encodedQuery',
      );
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
  }

  Future<void> _searchStreamingOnYouTubeMusic(
    _StreamingPlaylistItem item,
  ) async {
    try {
      String searchQuery = item.title.trim();
      final artist = item.artist.trim();
      if (artist.isNotEmpty &&
          artist != LocaleProvider.tr('artist_unknown').trim()) {
        searchQuery = '$artist ${item.title.trim()}';
      }
      final encodedQuery = Uri.encodeComponent(searchQuery);
      final url = Uri.parse('https://music.youtube.com/search?q=$encodedQuery');
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
  }

  Future<void> _showStreamingSearchOptions(_StreamingPlaylistItem item) async {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final primaryColor = Theme.of(context).colorScheme.primary;

            return AlertDialog(
              backgroundColor: isAmoled && isDark
                  ? Colors.black
                  : Theme.of(context).colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white24, width: 1)
                    : BorderSide.none,
              ),
              contentPadding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 400,
                  maxHeight: MediaQuery.of(context).size.height * 0.8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.search_rounded, size: 32),
                    const SizedBox(height: 16),
                    TranslatedText(
                      'search_song',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildActionOption(
                      context: context,
                      title: 'YouTube',
                      leading: Image.asset(
                        'assets/icon/Youtube_logo.png',
                        width: 24,
                        height: 24,
                      ),
                      onTap: () {
                        Navigator.of(context).pop();
                        _searchStreamingOnYouTube(item);
                      },
                    ),
                    const SizedBox(height: 8),
                    _buildActionOption(
                      context: context,
                      title: 'YT Music',
                      leading: Image.asset(
                        'assets/icon/Youtube_Music_icon.png',
                        width: 24,
                        height: 24,
                      ),
                      onTap: () {
                        Navigator.of(context).pop();
                        _searchStreamingOnYouTubeMusic(item);
                      },
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.only(right: 24, bottom: 8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: TranslatedText(
                            'cancel',
                            style: TextStyle(
                              color: primaryColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
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

  Future<void> _handleStreamingPlaylistLongPress(
    BuildContext context,
    _StreamingPlaylistItem item,
  ) async {
    final isFavorite = await FavoritesDB().isFavorite(item.rawPath);
    final isPinned = await ShortcutsDB().isShortcut(item.rawPath);
    if (!context.mounted) return;
    final isAmoled =
        Theme.of(context).brightness == Brightness.dark &&
        Theme.of(context).colorScheme.surface == Colors.black;
    final videoUrl = _streamingDisplayUrl(item);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) {
        final maxHeight =
            MediaQuery.of(context).size.height -
            MediaQuery.of(context).padding.top;
        return Container(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            width: 60,
                            height: 60,
                            child: _StreamingArtwork(
                              sources: _streamingArtworkSources(item),
                              backgroundColor: Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHigh,
                              iconColor: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                item.title,
                                maxLines: 1,
                                style: Theme.of(context).textTheme.titleMedium,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                item.artist,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: isAmoled
                                      ? Colors.white.withValues(alpha: 0.85)
                                      : null,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () async {
                            Navigator.of(context).pop();
                            await _showStreamingSearchOptions(item);
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context)
                                        .colorScheme
                                        .onPrimaryContainer
                                        .withValues(alpha: 0.7),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.search,
                                  size: 20,
                                  color:
                                      Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? Theme.of(context).colorScheme.onPrimary
                                      : Theme.of(
                                          context,
                                        ).colorScheme.surfaceContainer,
                                ),
                                const SizedBox(width: 8),
                                TranslatedText(
                                  'search',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14,
                                    color:
                                        Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? Theme.of(
                                            context,
                                          ).colorScheme.onPrimary
                                        : Theme.of(
                                            context,
                                          ).colorScheme.surfaceContainer,
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
                    leading: const Icon(Icons.sensors),
                    title: TranslatedText('start_radio'),
                    onTap: () async {
                      Navigator.of(context).pop();
                      await _startStreamingRadioFromItem(item);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.queue_music),
                    title: TranslatedText('add_to_queue'),
                    onTap: () async {
                      Navigator.of(context).pop();
                      final videoId = item.videoId?.trim();
                      if (videoId == null || videoId.isEmpty) return;
                      final artUri =
                          _applyStreamingArtworkQuality(
                            item.artUri,
                            videoId: videoId,
                          ) ??
                          _streamingFallbackArtworkUrls(videoId).first;
                      await audioHandler.myHandler
                          ?.customAction('addYtStreamToQueue', {
                            'videoId': videoId,
                            'title': item.title,
                            'artist': item.artist,
                            'artUri': artUri,
                          });
                    },
                  ),
                  ListTile(
                    leading: Icon(
                      isFavorite
                          ? Icons.delete_outline
                          : Icons.favorite_outline_rounded,
                      weight: isFavorite ? null : 600,
                    ),
                    title: TranslatedText(
                      isFavorite ? 'remove_from_favorites' : 'add_to_favorites',
                    ),
                    onTap: () async {
                      Navigator.of(context).pop();
                      if (isFavorite) {
                        await FavoritesDB().removeFavorite(item.rawPath);
                      } else {
                        await FavoritesDB().addFavoritePath(
                          item.rawPath,
                          title: item.title,
                          artist: item.artist,
                          videoId: item.videoId,
                          artUri: item.artUri,
                          durationText: item.durationText,
                          durationMs: item.durationMs,
                        );
                      }
                      favoritesShouldReload.value =
                          !favoritesShouldReload.value;
                    },
                  ),
                  if (_selectedPlaylist != null)
                    ListTile(
                      leading: const Icon(Icons.delete_outline),
                      title: TranslatedText('remove_from_playlist'),
                      onTap: () async {
                        Navigator.of(context).pop();
                        await PlaylistsDB().removeSongFromPlaylist(
                          _selectedPlaylist!.id,
                          item.rawPath,
                        );
                        playlistsShouldReload.value =
                            !playlistsShouldReload.value;
                        await _loadSongsFromPlaylist(_selectedPlaylist!);
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
                        await ShortcutsDB().removeShortcut(item.rawPath);
                      } else {
                        await ShortcutsDB().addShortcut(
                          item.rawPath,
                          title: item.title,
                          artist: item.artist,
                          videoId: item.videoId,
                          artUri: item.artUri,
                          durationText: item.durationText,
                          durationMs: item.durationMs,
                        );
                      }
                      shortcutsShouldReload.value =
                          !shortcutsShouldReload.value;
                    },
                  ),
                  if (item.artist.trim().isNotEmpty &&
                      item.artist.trim() != LocaleProvider.tr('artist_unknown'))
                    ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: const TranslatedText('go_to_artist'),
                      onTap: () {
                        Navigator.of(context).pop();
                        final name = item.artist.trim();
                        if (name.isEmpty) return;
                        Navigator.of(context).push(
                          PageRouteBuilder(
                            pageBuilder:
                                (context, animation, secondaryAnimation) =>
                                    ArtistScreen(artistName: name),
                            transitionsBuilder:
                                (
                                  context,
                                  animation,
                                  secondaryAnimation,
                                  child,
                                ) {
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
                    leading: const Icon(Icons.download_rounded),
                    title: TranslatedText('download'),
                    onTap: () async {
                      Navigator.of(context).pop();
                      await _downloadStreamingPlaylistItem(item);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.share_rounded),
                    title: TranslatedText('share_link'),
                    onTap: () async {
                      Navigator.of(context).pop();
                      await SharePlus.instance.share(
                        ShareParams(text: videoUrl),
                      );
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.check_box_outlined),
                    title: TranslatedText('select'),
                    onTap: () {
                      Navigator.of(context).pop();
                      setState(() {
                        _isSelecting = true;
                        _selectedSongPaths.add(item.rawPath);
                      });
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: TranslatedText('song_info'),
                    onTap: () async {
                      Navigator.of(context).pop();
                      final mediaItem = MediaItem(
                        id: item.rawPath,
                        title: item.title,
                        artist: item.artist,
                        artUri: Uri.tryParse(item.artUri ?? ''),
                        extras: {
                          'data': item.rawPath,
                          'videoId': item.videoId,
                          'isStreaming': true,
                          if (item.artUri != null &&
                              item.artUri!.trim().isNotEmpty)
                            'displayArtUri': item.artUri!.trim(),
                        },
                      );
                      await SongInfoDialog.show(
                        context,
                        mediaItem,
                        colorSchemeNotifier,
                      );
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
      final folderName = quitarDiacriticos(
        folderDisplayNames[entry.key] ?? '',
      ).toLowerCase();
      return folderName.contains(query);
    }).toList();

    // Buscar en canciones y obtener las carpetas que las contienen
    final songMatches = <String>{}; // Set para evitar duplicados
    try {
      final allSongs = await _audioQuery.querySongs();
      for (final song in allSongs) {
        final title = quitarDiacriticos(song.displayTitle).toLowerCase();
        final artist = quitarDiacriticos(song.displayArtist).toLowerCase();

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
    return ArtworkListTile(
      songId: song.id,
      songPath: song.data,
      size: 60,
      borderRadius: BorderRadius.circular(8),
    );
  }

  // Función para buscar la canción en YouTube
  Future<void> _searchSongOnYouTube(SongModel song) async {
    try {
      final title = song.displayTitle;
      final artist = song.displayArtist;

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
      final title = song.displayTitle;
      final artist = song.displayArtist;

      // Crear la consulta de búsqueda
      String searchQuery = title;
      if (artist.isNotEmpty) {
        searchQuery = '$artist $title';
      }

      // Codificar la consulta para la URL
      final encodedQuery = Uri.encodeComponent(searchQuery);

      // URL correcta para búsqueda en YouTube Music
      final ytMusicSearchUrl =
          'https://music.youtube.com/search?q=$encodedQuery';

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
            final primaryColor = Theme.of(context).colorScheme.primary;

            return AlertDialog(
              backgroundColor: isAmoled && isDark
                  ? Colors.black
                  : Theme.of(context).colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white24, width: 1)
                    : BorderSide.none,
              ),
              contentPadding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 400,
                  maxHeight: MediaQuery.of(context).size.height * 0.8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.search_rounded, size: 32),
                    const SizedBox(height: 16),
                    TranslatedText(
                      'search_song',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: TranslatedText(
                        'search_options',
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withAlpha(180),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _buildActionOption(
                      context: context,
                      title: 'YouTube',
                      leading: Image.asset(
                        'assets/icon/Youtube_logo.png',
                        width: 24,
                        height: 24,
                      ),
                      onTap: () {
                        Navigator.of(context).pop();
                        _searchSongOnYouTube(song);
                      },
                    ),
                    const SizedBox(height: 8),
                    _buildActionOption(
                      context: context,
                      title: 'YT Music',
                      leading: Image.asset(
                        'assets/icon/Youtube_Music_icon.png',
                        width: 24,
                        height: 24,
                      ),
                      onTap: () {
                        Navigator.of(context).pop();
                        _searchSongOnYouTubeMusic(song);
                      },
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.only(right: 24, bottom: 8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: TranslatedText(
                            'cancel',
                            style: TextStyle(
                              color: primaryColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
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

  Future<void> _showDeleteConfirmation(SongModel song) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;

            return AlertDialog(
              backgroundColor: isAmoled && isDark
                  ? Colors.black
                  : Theme.of(context).colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white24, width: 1)
                    : BorderSide.none,
              ),
              contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
              icon: Icon(
                Icons.delete_sweep_rounded,
                size: 32,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                LocaleProvider.tr('delete_song'),
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
              content: Text(
                LocaleProvider.tr('delete_song_confirm'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              actionsPadding: const EdgeInsets.all(16),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(
                    LocaleProvider.tr('cancel'),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: Text(
                    LocaleProvider.tr('delete'),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirmed == true && mounted) {
      final success = await _deleteSongFromDevice(song);
      if (!success && mounted) {
        _showMessage(
          LocaleProvider.tr('error'),
          description: LocaleProvider.tr('could_not_delete_song'),
          isError: true,
        );
      }
    }
  }

  // Función para mostrar diálogo de renombrado de carpeta
  Future<void> _showRenameFolderDialog(
    String folderKey,
    String currentName,
  ) async {
    final TextEditingController nameController = TextEditingController(
      text: currentName,
    );

    final String? newName = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;

            return AlertDialog(
              backgroundColor: isAmoled && isDark
                  ? Colors.black
                  : Theme.of(context).colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white24, width: 1)
                    : BorderSide.none,
              ),
              contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
              icon: Icon(
                Icons.drive_file_rename_outline_rounded,
                size: 32,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              title: Text(
                LocaleProvider.tr('rename_folder'),
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 16),
                  TextField(
                    controller: nameController,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: LocaleProvider.tr('folder_name'),
                      hintText: LocaleProvider.tr('enter_folder_name'),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      filled: true,
                      fillColor: isAmoled && isDark
                          ? Colors.white.withAlpha(10)
                          : Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest
                                .withAlpha(100),
                    ),
                    onSubmitted: (value) =>
                        Navigator.of(context).pop(value.trim()),
                  ),
                ],
              ),
              actionsPadding: const EdgeInsets.all(16),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(
                    LocaleProvider.tr('cancel'),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      Navigator.of(context).pop(nameController.text.trim()),
                  child: Text(
                    LocaleProvider.tr('rename'),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    if (newName != null && newName.isNotEmpty && newName != currentName) {
      await _renameFolder(folderKey, newName);
    } else if (newName != null && newName.isEmpty) {
      _showMessage(
        LocaleProvider.tr('error'),
        description: LocaleProvider.tr('folder_name_required'),
        isError: true,
      );
    }
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
          throw Exception(
            'Carpeta no encontrada - no hay canciones en la carpeta',
          );
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
      } else if (e.toString().contains('Permission denied') ||
          e.toString().contains('Acceso denegado')) {
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
  // Función para mostrar confirmación de borrado de carpeta con el mismo diseño
  Future<void> _showDeleteFolderConfirmation(
    String folderKey,
    String folderName,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;

            return AlertDialog(
              backgroundColor: isAmoled && isDark
                  ? Colors.black
                  : Theme.of(context).colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white24, width: 1)
                    : BorderSide.none,
              ),
              contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
              icon: Icon(
                Icons.folder_delete_rounded,
                size: 32,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                LocaleProvider.tr('delete_folder'),
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
              content: Text(
                LocaleProvider.tr('delete_folder_confirm'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              actionsPadding: const EdgeInsets.all(16),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(
                    LocaleProvider.tr('cancel'),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: Text(
                    LocaleProvider.tr('delete'),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirmed == true && mounted) {
      final success = await _deleteFolderAndSongs(folderKey);
      if (!success && mounted) {
        _showMessage(
          LocaleProvider.tr('error'),
          description: LocaleProvider.tr('could_not_delete_folder'),
          isError: true,
        );
      }
    }
  }

  Widget _buildDestructiveOption({
    required BuildContext context,
    required String title,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    final errorContainer = Theme.of(context).colorScheme.error;
    final onErrorContainer = Theme.of(context).colorScheme.onError;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(28),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            color: errorContainer,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Row(
            children: [
              Icon(icon, color: onErrorContainer, size: 24),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: onErrorContainer,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionOption({
    required BuildContext context,
    required String title,
    required VoidCallback onTap,
    IconData? icon,
    Widget? leading,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(28),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Row(
            children: [
              if (leading != null)
                SizedBox(width: 24, height: 24, child: Center(child: leading))
              else if (icon != null)
                Icon(
                  icon,
                  color: Theme.of(context).colorScheme.onPrimary,
                  size: 24,
                ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
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
      final shortcutsToRemove = shortcuts
          .where((path) => songsInFolder.contains(path))
          .toList();
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
            final primaryColor = Theme.of(context).colorScheme.primary;

            return AlertDialog(
              backgroundColor: isAmoled && isDark
                  ? Colors.black
                  : Theme.of(context).colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white24, width: 1)
                    : BorderSide.none,
              ),
              contentPadding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 400,
                  maxHeight: MediaQuery.of(context).size.height * 0.8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.visibility_off_rounded, size: 32),
                    const SizedBox(height: 16),
                    TranslatedText(
                      'ignore_folder',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        LocaleProvider.tr(
                          'ignore_folder_confirm',
                        ).replaceAll('{folder}', folderName),
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withAlpha(180),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _buildActionOption(
                      context: context,
                      title: LocaleProvider.tr('ignore_folder'),
                      icon: Icons.visibility_off_rounded,
                      onTap: () => Navigator.of(context).pop(true),
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.only(right: 24, bottom: 8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: TranslatedText(
                            'cancel',
                            style: TextStyle(
                              color: primaryColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
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
    _showMessage(
      LocaleProvider.tr('success'),
      description: LocaleProvider.tr('folder_ignored_success'),
    );
  }

  Future<void> _unignoreFolderFlow(String folderKey) async {
    await unignoreFolder(folderKey);
    await SongsIndexDB().syncDatabase();
    if (!mounted) return;
    await cargarCanciones(forceIndex: true);
    if (!mounted) return;
    _showMessage(
      LocaleProvider.tr('success'),
      description: LocaleProvider.tr('folder_unignored_success'),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _playingDebounce?.cancel();
    _mediaItemDebounce?.cancel();
    _isPlayingNotifier.dispose();
    _currentMediaItemNotifier.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _folderSearchController.dispose();
    _folderSearchFocusNode.dispose();
    _scrollController.dispose();
    _foldersScrollController.dispose();
    _playlistsScrollController.dispose();
    foldersShouldReload.removeListener(_onFoldersShouldReload);
    folderUpdatedNotifier.removeListener(_onFolderUpdated);
    coverQualityNotifier.removeListener(_onCoverQualityChanged);
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

  Future<void> _showSortOptionsDialog() async {
    showDialog(
      context: context,
      builder: (context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final isStreamingPlaylistSortContext = _isStreamingPlaylistDetail;

            return AlertDialog(
              backgroundColor: isAmoled && isDark
                  ? Colors.black
                  : Theme.of(context).colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white24, width: 1)
                    : BorderSide.none,
              ),
              contentPadding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.sort_rounded, size: 32),
                  const SizedBox(height: 16),
                  TranslatedText(
                    'filters',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w500,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (isStreamingPlaylistSortContext)
                    _buildSortOption(
                      OrdenCarpetas.ultimoAgregado,
                      'last_added',
                      Icons.history_rounded,
                    )
                  else
                    _buildSortOption(
                      OrdenCarpetas.normal,
                      'default',
                      Icons.history_rounded,
                    ),
                  if (isStreamingPlaylistSortContext)
                    _buildSortOption(
                      OrdenCarpetas.normal,
                      'invert_order',
                      Icons.swap_vert_rounded,
                    )
                  else
                    _buildSortOption(
                      OrdenCarpetas.ultimoAgregado,
                      'invert_order',
                      Icons.swap_vert_rounded,
                    ),
                  _buildSortOption(
                    OrdenCarpetas.alfabetico,
                    'alphabetical_az',
                    Icons.sort_by_alpha_rounded,
                  ),
                  _buildSortOption(
                    OrdenCarpetas.invertido,
                    'alphabetical_za',
                    Icons.sort_by_alpha_rounded,
                  ),
                  if (!isStreamingPlaylistSortContext)
                    _buildSortOption(
                      OrdenCarpetas.fechaEdicionDesc,
                      'edit_date_newest_first',
                      Icons.calendar_month_rounded,
                    ),
                  if (!isStreamingPlaylistSortContext)
                    _buildSortOption(
                      OrdenCarpetas.fechaEdicionAsc,
                      'edit_date_oldest_first',
                      Icons.calendar_today_rounded,
                    ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSortOption(OrdenCarpetas value, String labelKey, IconData icon) {
    final ordenActual = _hasSelectedPlaylist ? _ordenPlaylist : _orden;
    final isSelected = ordenActual == value;
    final colorScheme = Theme.of(context).colorScheme;
    final primaryColor = colorScheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final useSubtleStyling = isAmoled && isDark;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: InkWell(
        onTap: () async {
          setState(() {
            if (_hasSelectedPlaylist) {
              _ordenPlaylist = value;
            } else {
              _orden = value;
            }
          });
          await _ordenarCanciones();
          _saveOrderFilter();
          if (mounted) {
            Navigator.pop(context);
          }
        },
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: isSelected
                ? (useSubtleStyling ? primaryColor.withAlpha(30) : primaryColor)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            border: isSelected && useSubtleStyling
                ? Border.all(color: primaryColor.withAlpha(100), width: 1)
                : null,
          ),
          child: Row(
            children: [
              Icon(
                icon,
                color: isSelected
                    ? (useSubtleStyling ? primaryColor : colorScheme.onPrimary)
                    : colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: TranslatedText(
                  labelKey,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: isSelected
                        ? FontWeight.bold
                        : FontWeight.normal,
                    color: isSelected
                        ? (useSubtleStyling
                              ? primaryColor
                              : colorScheme.onPrimary)
                        : colorScheme.onSurface,
                  ),
                ),
              ),
              if (isSelected)
                Icon(
                  Icons.check_circle_rounded,
                  color: useSubtleStyling
                      ? primaryColor
                      : colorScheme.onPrimary,
                  size: 20,
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final selectingStreamingPlaylist = _isStreamingPlaylistDetail;

    if (_isLoading) {
      return Scaffold(body: Center(child: LoadingIndicator()));
    }
    if (songPathsByFolder.isEmpty &&
        !_showAllSongs &&
        !_showPlaylists &&
        !_hasSelectedPlaylist) {
      return Scaffold(
        body: ExpressiveRefreshIndicator(
          onRefresh: () async {
            // Recargar las carpetas al hacer scroll hacia abajo
            await cargarCanciones(forceIndex: true);
          },
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight:
                    MediaQuery.of(context).size.height -
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
                      Container(
                        width: 80,
                        height: 80,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isDark
                              ? Theme.of(
                                  context,
                                ).colorScheme.secondary.withValues(alpha: 0.04)
                              : Theme.of(
                                  context,
                                ).colorScheme.secondary.withValues(alpha: 0.05),
                        ),
                        child: Icon(
                          Icons.folder_off_rounded,
                          size: 50,
                          color:
                              Theme.of(context).brightness == Brightness.light
                              ? Theme.of(
                                  context,
                                ).colorScheme.onSurface.withValues(alpha: 0.7)
                              : Theme.of(
                                  context,
                                ).colorScheme.onSurface.withValues(alpha: 0.7),
                        ),
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

    // Vista de lista de playlists
    if (_showPlaylists && !_hasSelectedPlaylist) {
      final colorScheme = colorSchemeNotifier.value;
      final isAmoled = colorScheme == AppColorScheme.amoled;
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final playlistEntries = _buildPlaylistListEntries();
      final isYtCookiesWithSession =
          _playlistSource == PlaylistSource.ytMusicCookies &&
          _hasYtAuthCookieSession;
      final barColor = isAmoled
          ? Colors.white.withAlpha(20)
          : isDark
          ? Theme.of(context).colorScheme.secondary.withValues(alpha: 0.06)
          : Theme.of(context).colorScheme.secondary.withValues(alpha: 0.07);

      return Scaffold(
        resizeToAvoidBottomInset: true,
        appBar: AppBar(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          title: GestureDetector(
            onTap: () => _showViewSelectorModal(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TranslatedText(
                  'playlists',
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isDark
                        ? Theme.of(
                            context,
                          ).colorScheme.secondary.withValues(alpha: 0.06)
                        : Theme.of(
                            context,
                          ).colorScheme.secondary.withValues(alpha: 0.06),
                  ),
                  child: Icon(
                    Icons.keyboard_arrow_down,
                    color: Theme.of(context).colorScheme.onSurface,
                    size: 18,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            PopupMenuButton<String>(
              color: isAmoled
                  ? Colors.grey.shade900
                  : Theme.of(context).colorScheme.surfaceContainerHigh,
              icon: const Icon(Icons.more_vert),
              tooltip: LocaleProvider.tr('want_more_options'),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              onSelected: (value) {
                switch (value) {
                  case 'source_local':
                    _setPlaylistSource(PlaylistSource.local);
                    break;
                  case 'source_streaming':
                    _setPlaylistSource(PlaylistSource.streaming);
                    break;
                  case 'source_yt_cookies':
                    _setPlaylistSource(PlaylistSource.ytMusicCookies);
                    break;
                  case 'create_playlist':
                    _createNewPlaylist();
                    break;
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem<String>(
                  value: 'source_local',
                  child: Row(
                    children: [
                      Icon(Icons.music_note_rounded, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(LocaleProvider.tr('show_local_songs')),
                      ),
                      if (_playlistSource == PlaylistSource.local)
                        Icon(
                          Icons.check,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'source_streaming',
                  child: Row(
                    children: [
                      Icon(Icons.cloud_outlined, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(LocaleProvider.tr('show_streaming_songs')),
                      ),
                      if (_playlistSource == PlaylistSource.streaming)
                        Icon(
                          Icons.check,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'source_yt_cookies',
                  child: Row(
                    children: [
                      Icon(
                        isYtCookiesWithSession
                            ? Icons.cloud_done_outlined
                            : Icons.cloud_off_outlined,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(_ytCookiesSourceLabel)),
                      if (_playlistSource == PlaylistSource.ytMusicCookies)
                        Icon(
                          Icons.check,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'create_playlist',
                  child: Row(
                    children: [
                      const Icon(Icons.add, size: 20),
                      const SizedBox(width: 12),
                      Text(LocaleProvider.tr('create_playlist')),
                    ],
                  ),
                ),
              ],
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(56),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _playlistSearchController,
                cursorColor: Theme.of(context).colorScheme.primary,
                decoration: InputDecoration(
                  hintText: LocaleProvider.tr('search_playlists'),
                  hintStyle: TextStyle(
                    color: isAmoled
                        ? Colors.white.withAlpha(160)
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 15,
                  ),
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _playlistSearchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            _playlistSearchController.clear();
                            setState(() {
                              _applyPlaylistFilters();
                            });
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: barColor,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(28),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(28),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(28),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                ),
                onChanged: (value) {
                  setState(() {
                    _applyPlaylistFilters();
                  });
                },
              ),
            ),
          ),
        ),
        body: _isLoading
            ? Center(child: LoadingIndicator())
            : (playlistEntries.isEmpty && _isLoadingYtLibraryPlaylists)
            ? Center(child: LoadingIndicator())
            : playlistEntries.isEmpty
            ? ExpressiveRefreshIndicator(
                onRefresh: () async {
                  await _loadPlaylists();
                },
                color: Theme.of(context).colorScheme.primary,
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: SizedBox(
                    height: MediaQuery.of(context).size.height - 200,
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 80,
                            height: 80,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isDark
                                  ? Theme.of(context).colorScheme.secondary
                                        .withValues(alpha: 0.04)
                                  : Theme.of(context).colorScheme.secondary
                                        .withValues(alpha: 0.05),
                            ),
                            child: Icon(
                              Icons.queue_music_outlined,
                              size: 50,
                              color:
                                  Theme.of(context).brightness ==
                                      Brightness.light
                                  ? Theme.of(context).colorScheme.onSurface
                                        .withValues(alpha: 0.7)
                                  : Theme.of(context).colorScheme.onSurface
                                        .withValues(alpha: 0.7),
                            ),
                          ),
                          const SizedBox(height: 16),
                          TranslatedText(
                            _playlistSearchController.text.isNotEmpty
                                ? 'no_results'
                                : 'no_playlists',
                            style: TextStyle(
                              fontSize: 16,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurface.withValues(alpha: 0.5),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              )
            : ExpressiveRefreshIndicator(
                onRefresh: () async {
                  await _loadPlaylists();
                },
                color: Theme.of(context).colorScheme.primary,
                child: ValueListenableBuilder<MediaItem?>(
                  valueListenable: _currentMediaItemNotifier,
                  builder: (context, debouncedMediaItem, child) {
                    final bottomPadding = MediaQuery.of(context).padding.bottom;
                    final space =
                        (debouncedMediaItem != null ? 100.0 : 0.0) +
                        bottomPadding;

                    return RawScrollbar(
                      controller: _playlistsScrollController,
                      thumbColor: Theme.of(context).colorScheme.primary,
                      thickness: 6.0,
                      radius: const Radius.circular(8),
                      interactive: true,
                      padding: EdgeInsets.only(bottom: space),
                      child: ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        controller: _playlistsScrollController,
                        padding: EdgeInsets.only(
                          left: 16.0,
                          right: 16.0,
                          top: 8.0,
                          bottom: space,
                        ),
                        itemCount: playlistEntries.length,
                        itemBuilder: (context, index) {
                          final entry = playlistEntries[index];
                          final playlist = entry.local;
                          final ytPlaylist = entry.ytLibrary;

                          // Determinar el borderRadius según la posición
                          final bool isFirst = index == 0;
                          final bool isLast =
                              index == playlistEntries.length - 1;
                          final bool isOnly = playlistEntries.length == 1;

                          BorderRadius borderRadius;
                          if (isOnly) {
                            borderRadius = BorderRadius.circular(20);
                          } else if (isFirst) {
                            borderRadius = const BorderRadius.only(
                              topLeft: Radius.circular(20),
                              topRight: Radius.circular(20),
                              bottomLeft: Radius.circular(4),
                              bottomRight: Radius.circular(4),
                            );
                          } else if (isLast) {
                            borderRadius = const BorderRadius.only(
                              topLeft: Radius.circular(4),
                              topRight: Radius.circular(4),
                              bottomLeft: Radius.circular(20),
                              bottomRight: Radius.circular(20),
                            );
                          } else {
                            borderRadius = BorderRadius.circular(4);
                          }

                          return Padding(
                            padding: EdgeInsets.only(bottom: isLast ? 0 : 4),
                            child: Card(
                              color: barColor,
                              margin: EdgeInsets.zero,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: borderRadius,
                              ),
                              child: ClipRRect(
                                borderRadius: borderRadius,
                                child: ListTile(
                                  shape: RoundedRectangleBorder(
                                    borderRadius: borderRadius,
                                  ),
                                  leading: entry.isYtLibrary
                                      ? _buildYtLibraryPlaylistArtwork(
                                          ytPlaylist!,
                                        )
                                      : _buildPlaylistArtworkGrid(playlist!),
                                  title: Text(
                                    entry.isYtLibrary
                                        ? _displayYtLibraryPlaylistTitle(
                                            ytPlaylist!.title,
                                          )
                                        : playlist!.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                  subtitle: Text(
                                    entry.isYtLibrary
                                        ? _formatYtLibraryPlaylistSubtitle(
                                            ytPlaylist!,
                                          )
                                        : '${playlist!.songPaths.length} ${LocaleProvider.tr('songs')}',
                                    style: isAmoled
                                        ? TextStyle(
                                            color: Colors.white.withValues(
                                              alpha: 0.8,
                                            ),
                                          )
                                        : null,
                                  ),
                                  onTap: () async {
                                    if (entry.isYtLibrary) {
                                      await _loadSongsFromYtLibraryPlaylist(
                                        ytPlaylist!,
                                      );
                                    } else {
                                      await _loadSongsFromPlaylist(playlist!);
                                    }
                                  },
                                  onLongPress: entry.isYtLibrary
                                      ? null
                                      : () => _showPlaylistOptions(playlist!),
                                ),
                              ),
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

    if (carpetaSeleccionada == null) {
      return Scaffold(
        resizeToAvoidBottomInset: true,
        appBar: AppBar(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          title: GestureDetector(
            onTap: () => _showViewSelectorModal(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TranslatedText(
                  'folders_title',
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isDark
                        ? Theme.of(
                            context,
                          ).colorScheme.secondary.withValues(alpha: 0.06)
                        : Theme.of(
                            context,
                          ).colorScheme.secondary.withValues(alpha: 0.06),
                  ),
                  child: Icon(
                    Icons.keyboard_arrow_down,
                    color: Theme.of(context).colorScheme.onSurface,
                    size: 18,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.info_outline, size: 28),
              tooltip: LocaleProvider.tr('information'),
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (context) {
                    return ValueListenableBuilder<AppColorScheme>(
                      valueListenable: colorSchemeNotifier,
                      builder: (context, colorScheme, child) {
                        final isAmoled = colorScheme == AppColorScheme.amoled;
                        final isDark =
                            Theme.of(context).brightness == Brightness.dark;
                        final primaryColor = Theme.of(
                          context,
                        ).colorScheme.primary;

                        return AlertDialog(
                          backgroundColor: isAmoled && isDark
                              ? Colors.black
                              : Theme.of(context).colorScheme.surface,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(28),
                            side: isAmoled && isDark
                                ? const BorderSide(
                                    color: Colors.white24,
                                    width: 1,
                                  )
                                : BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.fromLTRB(
                            0,
                            24,
                            0,
                            8,
                          ),
                          content: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: 400,
                              maxHeight:
                                  MediaQuery.of(context).size.height * 0.8,
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.info_rounded,
                                  size: 32,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface,
                                ),
                                const SizedBox(height: 16),
                                TranslatedText(
                                  'info',
                                  style: TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.w500,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 24,
                                  ),
                                  child: TranslatedText(
                                    'folders_and_songs_info',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurface.withAlpha(180),
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                                const SizedBox(height: 24),
                                Padding(
                                  padding: const EdgeInsets.only(
                                    right: 24,
                                    bottom: 8,
                                  ),
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: TextButton(
                                      onPressed: () =>
                                          Navigator.of(context).pop(),
                                      child: TranslatedText(
                                        'ok',
                                        style: TextStyle(
                                          color: primaryColor,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
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
              },
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(56),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Builder(
                builder: (context) {
                  final colorScheme = colorSchemeNotifier.value;
                  final isAmoled = colorScheme == AppColorScheme.amoled;
                  final isDark =
                      Theme.of(context).brightness == Brightness.dark;
                  final barColor = isAmoled
                      ? Colors.white.withAlpha(20)
                      : isDark
                      ? Theme.of(
                          context,
                        ).colorScheme.secondary.withValues(alpha: 0.06)
                      : Theme.of(
                          context,
                        ).colorScheme.secondary.withValues(alpha: 0.07);

                  return TextField(
                    controller: _folderSearchController,
                    focusNode: _folderSearchFocusNode,
                    onChanged: (_) => _onFolderSearchChanged(),
                    onEditingComplete: () {
                      _folderSearchFocusNode.unfocus();
                    },
                    cursorColor: Theme.of(context).colorScheme.primary,
                    decoration: InputDecoration(
                      hintText: LocaleProvider.tr('search_folders_and_songs'),
                      hintStyle: TextStyle(
                        color: isAmoled
                            ? Colors.white.withAlpha(160)
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 15,
                      ),
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
                      filled: true,
                      fillColor: barColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(28),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(28),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(28),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        body: ExpressiveRefreshIndicator(
          onRefresh: () async {
            // Recargar las carpetas al hacer scroll hacia abajo
            await cargarCanciones(forceIndex: true);
          },
          color: Theme.of(context).colorScheme.primary,
          child: ValueListenableBuilder<MediaItem?>(
            valueListenable: _currentMediaItemNotifier,
            builder: (context, current, child) {
              final bottomPadding = MediaQuery.of(context).padding.bottom;
              final space = (current != null ? 100.0 : 0.0) + bottomPadding;
              return Builder(
                builder: (context) {
                  final colorScheme = colorSchemeNotifier.value;
                  final isAmoled = colorScheme == AppColorScheme.amoled;
                  final isDark =
                      Theme.of(context).brightness == Brightness.dark;
                  final cardColor = isAmoled
                      ? Colors.white.withAlpha(20)
                      : isDark
                      ? Theme.of(
                          context,
                        ).colorScheme.secondary.withValues(alpha: 0.06)
                      : Theme.of(
                          context,
                        ).colorScheme.secondary.withValues(alpha: 0.07);

                  final sortedEntries =
                      _folderSearchController.text.isNotEmpty
                            ? _filteredFolders
                            : songPathsByFolder.entries.toList()
                        ..sort(
                          (a, b) => folderDisplayNames[a.key]!
                              .toLowerCase()
                              .compareTo(
                                folderDisplayNames[b.key]!.toLowerCase(),
                              ),
                        );

                  if (sortedEntries.isEmpty) {
                    return SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      child: SizedBox(
                        height: MediaQuery.of(context).size.height - 200,
                        child: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                width: 80,
                                height: 80,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: isDark
                                      ? Theme.of(context).colorScheme.secondary
                                            .withValues(alpha: 0.04)
                                      : Theme.of(context).colorScheme.secondary
                                            .withValues(alpha: 0.05),
                                ),
                                child: Icon(
                                  Icons.folder_off_rounded,
                                  size: 50,
                                  color:
                                      Theme.of(context).brightness ==
                                          Brightness.light
                                      ? Theme.of(context).colorScheme.onSurface
                                            .withValues(alpha: 0.7)
                                      : Theme.of(context).colorScheme.onSurface
                                            .withValues(alpha: 0.7),
                                ),
                              ),
                              const SizedBox(height: 16),
                              TranslatedText(
                                _folderSearchController.text.isNotEmpty
                                    ? 'no_results'
                                    : 'no_folders_with_songs',
                                style: TextStyle(
                                  fontSize: 16,
                                  color: Theme.of(context).colorScheme.onSurface
                                      .withValues(alpha: 0.6),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }

                  return RawScrollbar(
                    controller: _foldersScrollController,
                    thumbColor: Theme.of(context).colorScheme.primary,
                    thickness: 6.0,
                    radius: const Radius.circular(8),
                    interactive: true,
                    padding: EdgeInsets.only(bottom: space),
                    child: ListView.builder(
                      controller: _foldersScrollController,
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.only(
                        left: 16.0,
                        right: 16.0,
                        top: 8.0,
                        bottom: space,
                      ),
                      itemCount: sortedEntries.length,
                      itemBuilder: (context, i) {
                        final entry = sortedEntries[i];
                        final nombre = folderDisplayNames[entry.key]!;
                        final canciones = entry.value;

                        // Usar cache para evitar parpadeos
                        final ignored = _ignoredFoldersCache.contains(
                          entry.key,
                        );
                        final opacity = ignored ? 0.4 : 1.0;

                        // Determinar el borderRadius según la posición
                        final bool isFirst = i == 0;
                        final bool isLast = i == sortedEntries.length - 1;
                        final bool isOnly = sortedEntries.length == 1;

                        BorderRadius borderRadius;
                        if (isOnly) {
                          borderRadius = BorderRadius.circular(20);
                        } else if (isFirst) {
                          borderRadius = const BorderRadius.only(
                            topLeft: Radius.circular(20),
                            topRight: Radius.circular(20),
                            bottomLeft: Radius.circular(4),
                            bottomRight: Radius.circular(4),
                          );
                        } else if (isLast) {
                          borderRadius = const BorderRadius.only(
                            topLeft: Radius.circular(4),
                            topRight: Radius.circular(4),
                            bottomLeft: Radius.circular(20),
                            bottomRight: Radius.circular(20),
                          );
                        } else {
                          borderRadius = BorderRadius.circular(4);
                        }

                        return Padding(
                          padding: EdgeInsets.only(bottom: isLast ? 0 : 4),
                          child: Card(
                            color: cardColor,
                            margin: EdgeInsets.zero,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: borderRadius,
                            ),
                            child: ClipRRect(
                              borderRadius: borderRadius,
                              child: Opacity(
                                opacity: opacity,
                                child: ListTile(
                                  shape: RoundedRectangleBorder(
                                    borderRadius: borderRadius,
                                  ),
                                  leading: const Icon(Icons.folder, size: 38),
                                  title: Text(
                                    nombre,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                  subtitle: Text(
                                    '${canciones.length} ${LocaleProvider.tr('songs')}',
                                    style: isAmoled
                                        ? TextStyle(
                                            color: Colors.white.withValues(
                                              alpha: 0.8,
                                            ),
                                          )
                                        : null,
                                  ),
                                  onTap: ignored
                                      ? null
                                      : () async {
                                          await _loadSongsForFolder(entry);
                                        },
                                  trailing: Container(
                                    width: 26,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary.withAlpha(20),
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: IconButton(
                                      icon: const Icon(
                                        Icons.more_vert,
                                        size: 22,
                                      ),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      onPressed: () => _showFolderOptionsModal(
                                        context,
                                        entry.key,
                                        nombre,
                                        ignored,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  );
                },
              );
            },
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
              : _showAllSongs
              ? null // No back button when showing all songs
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
                      color: isDark
                          ? Theme.of(
                              context,
                            ).colorScheme.secondary.withValues(alpha: 0.06)
                          : Theme.of(
                              context,
                            ).colorScheme.secondary.withValues(alpha: 0.06),
                    ),
                    child: const Icon(Icons.arrow_back, size: 24),
                  ),
                  onPressed: () async {
                    // Si hay una playlist seleccionada, volver a la lista de playlists
                    if (_hasSelectedPlaylist) {
                      _invalidateYtPlaylistSongLoads(
                        'appbar-back-from-playlist-detail',
                      );
                      setState(() {
                        _selectedPlaylist = null;
                        _selectedYtLibraryPlaylist = null;
                        carpetaSeleccionada = null;
                        _searchController.clear();
                        _filteredSongs.clear();
                        _displaySongs.clear();
                        _isSelecting = false;
                        _selectedSongPaths.clear();
                      });
                      await _loadPlaylists();
                      return;
                    }

                    _invalidateYtPlaylistSongLoads('appbar-back-to-folders');
                    setState(() {
                      carpetaSeleccionada = null;
                      _showAllSongs = false;
                      _selectedYtLibraryPlaylist = null;
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
              : _showAllSongs
              ? GestureDetector(
                  onTap: () => _showViewSelectorModal(),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        LocaleProvider.tr('all_songs'),
                        style: TextStyle(fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isDark
                              ? Theme.of(
                                  context,
                                ).colorScheme.secondary.withValues(alpha: 0.06)
                              : Theme.of(
                                  context,
                                ).colorScheme.secondary.withValues(alpha: 0.06),
                        ),
                        child: Icon(
                          Icons.keyboard_arrow_down,
                          color: Theme.of(context).colorScheme.onSurface,
                          size: 18,
                        ),
                      ),
                    ],
                  ),
                )
              : _hasSelectedPlaylist
              ? Text(
                  _currentSelectedPlaylistName(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.9),
                  ),
                )
              : Text(
                  folderDisplayNames[carpetaSeleccionada] ??
                      LocaleProvider.tr('folders'),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.9),
                  ),
                ),
          actions: [
            if (_isSelecting) ...[
              IconButton(
                icon: const Icon(Icons.select_all),
                tooltip: LocaleProvider.tr('select_all'),
                onPressed: () {
                  final visibleStreamingItems =
                      _searchController.text.isNotEmpty
                      ? _filteredPlaylistStreamingItems
                      : _playlistStreamingItems;
                  setState(() {
                    if (selectingStreamingPlaylist) {
                      if (_selectedSongPaths.length ==
                          visibleStreamingItems.length) {
                        _selectedSongPaths.clear();
                        if (_selectedSongPaths.isEmpty) {
                          _isSelecting = false;
                        }
                      } else {
                        _selectedSongPaths.addAll(
                          visibleStreamingItems.map((s) => s.rawPath),
                        );
                      }
                    } else if (_selectedSongPaths.length ==
                        _displaySongs.length) {
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
                surfaceTintColor: isAmoled
                    ? Colors.grey.shade900
                    : Theme.of(context).colorScheme.surfaceContainerHigh,
                icon: const Icon(Icons.more_vert),
                tooltip: LocaleProvider.tr('options'),
                elevation: 3,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                color:
                    (colorSchemeNotifier.value == AppColorScheme.amoled &&
                        Theme.of(context).brightness == Brightness.dark)
                    ? const Color(0xFF1E1E1E)
                    : null,
                onSelected: (String value) async {
                  switch (value) {
                    case 'add_to_favorites':
                      if (_selectedSongPaths.isNotEmpty) {
                        if (selectingStreamingPlaylist) {
                          final visibleStreamingItems =
                              _searchController.text.isNotEmpty
                              ? _filteredPlaylistStreamingItems
                              : _playlistStreamingItems;
                          final selectedStreamingItems = visibleStreamingItems
                              .where(
                                (item) =>
                                    _selectedSongPaths.contains(item.rawPath),
                              );
                          for (final item in selectedStreamingItems) {
                            await FavoritesDB().addFavoritePath(
                              item.rawPath,
                              title: item.title,
                              artist: item.artist,
                              videoId: item.videoId,
                              artUri: item.artUri,
                              durationText: item.durationText,
                              durationMs: item.durationMs,
                            );
                          }
                        } else {
                          final selectedSongs = _displaySongs.where(
                            (s) => _selectedSongPaths.contains(s.data),
                          );
                          for (final song in selectedSongs) {
                            await _addToFavorites(song);
                          }
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
                    case 'download':
                      if (_selectedSongPaths.isNotEmpty &&
                          selectingStreamingPlaylist) {
                        await _handleDownloadSelectedStreamingPlaylistItems();
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
                        if (selectingStreamingPlaylist) {
                          if (_selectedPlaylist != null) {
                            await _handleRemoveStreamingFromPlaylistMassive(
                              context,
                            );
                          }
                        } else {
                          await _handleDeleteSongs(context);
                        }
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
                        const Icon(Icons.favorite_border_rounded),
                        const SizedBox(width: 12),
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
                        const Icon(Icons.playlist_add_rounded),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(LocaleProvider.tr('add_to_playlist')),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'download',
                    enabled:
                        _selectedSongPaths.isNotEmpty &&
                        selectingStreamingPlaylist,
                    child: Row(
                      children: [
                        const Icon(Icons.download_rounded),
                        const SizedBox(width: 12),
                        Expanded(child: Text(LocaleProvider.tr('download'))),
                      ],
                    ),
                  ),
                  if (_isAndroid10OrHigher && !selectingStreamingPlaylist)
                    PopupMenuItem<String>(
                      value: 'copy_to_folder',
                      enabled: _selectedSongPaths.isNotEmpty,
                      child: Row(
                        children: [
                          const Icon(Icons.copy_rounded),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(LocaleProvider.tr('copy_to_folder')),
                          ),
                        ],
                      ),
                    ),
                  if (_isAndroid10OrHigher && !selectingStreamingPlaylist)
                    PopupMenuItem<String>(
                      value: 'move_to_folder',
                      enabled: _selectedSongPaths.isNotEmpty,
                      child: Row(
                        children: [
                          const Icon(Icons.drive_file_move_rounded),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(LocaleProvider.tr('move_to_folder')),
                          ),
                        ],
                      ),
                    ),
                  PopupMenuItem<String>(
                    value: 'delete_songs',
                    enabled:
                        _selectedSongPaths.isNotEmpty &&
                        (!selectingStreamingPlaylist ||
                            _selectedPlaylist != null),
                    child: Row(
                      children: [
                        const Icon(Icons.delete_outline_rounded),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(LocaleProvider.tr('delete_songs')),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ] else ...[
              if (_selectedPlaylist != null &&
                  _playlistSource == PlaylistSource.local)
                IconButton(
                  icon: const Icon(Icons.add, size: 28),
                  tooltip: LocaleProvider.tr('add_songs'),
                  onPressed: () => _showAddSongsToPlaylistDialog(),
                ),
              IconButton(
                icon: const Icon(Icons.shuffle_rounded, size: 28, weight: 600),
                tooltip: LocaleProvider.tr('shuffle'),
                onPressed: () {
                  final showingStreamingPlaylist = _isStreamingPlaylistDetail;
                  if (showingStreamingPlaylist) {
                    final visibleStreaming = _searchController.text.isNotEmpty
                        ? _filteredPlaylistStreamingItems
                        : _playlistStreamingItems;
                    if (visibleStreaming.isNotEmpty) {
                      final random =
                          (visibleStreaming.toList()..shuffle()).first;
                      _playStreamingPlaylistItem(random);
                    }
                    return;
                  }

                  if (_displaySongs.isNotEmpty) {
                    final random = (_displaySongs.toList()..shuffle()).first;
                    unawaited(_preloadArtworkForSong(random));
                    _playSongAndOpenPlayer(random.data);
                  }
                },
              ),
              IconButton(
                icon: const Icon(Icons.sort, size: 28),
                tooltip: LocaleProvider.tr('filters'),
                onPressed: _showSortOptionsDialog,
              ),
            ],
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(56),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: ValueListenableBuilder<String>(
                valueListenable: languageNotifier,
                builder: (context, lang, child) {
                  final colorScheme = colorSchemeNotifier.value;
                  final isAmoled = colorScheme == AppColorScheme.amoled;
                  final isDark =
                      Theme.of(context).brightness == Brightness.dark;
                  final barColor = isAmoled
                      ? Colors.white.withAlpha(20)
                      : isDark
                      ? Theme.of(
                          context,
                        ).colorScheme.secondary.withValues(alpha: 0.06)
                      : Theme.of(
                          context,
                        ).colorScheme.secondary.withValues(alpha: 0.07);

                  return TextField(
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    onChanged: (_) => _onSearchChanged(),
                    onEditingComplete: () {
                      _searchFocusNode.unfocus();
                    },
                    cursorColor: Theme.of(context).colorScheme.primary,
                    decoration: InputDecoration(
                      hintText: LocaleProvider.tr('search_by_title_or_artist'),
                      hintStyle: TextStyle(
                        color: isAmoled
                            ? Colors.white.withAlpha(160)
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 15,
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
                      filled: true,
                      fillColor: barColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(28),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(28),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(28),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        body: ExpressiveRefreshIndicator(
          onRefresh: _refreshCurrentFolder,
          color: Theme.of(context).colorScheme.primary,
          child: ValueListenableBuilder<MediaItem?>(
            valueListenable: _currentMediaItemNotifier,
            builder: (context, currentMediaItem, child) {
              final colorScheme = colorSchemeNotifier.value;
              final isAmoled = colorScheme == AppColorScheme.amoled;
              final isDark = Theme.of(context).brightness == Brightness.dark;

              final bottomPadding = MediaQuery.of(context).padding.bottom;
              final space =
                  (currentMediaItem != null ? 100.0 : 0.0) + bottomPadding;
              final showingStreamingPlaylist = _isStreamingPlaylistDetail;
              final streamingToShow =
                  showingStreamingPlaylist && _searchController.text.isNotEmpty
                  ? _filteredPlaylistStreamingItems
                  : _playlistStreamingItems;
              final showYtStreamingPagination =
                  showingStreamingPlaylist &&
                  _playlistSource == PlaylistSource.ytMusicCookies &&
                  _selectedYtLibraryPlaylist != null &&
                  _searchController.text.isEmpty;
              final showYtStreamingFooter =
                  showYtStreamingPagination &&
                  (_ytActivePlaylistHasMore || _isLoadingMoreYtPlaylistSongs);

              if ((showingStreamingPlaylist && streamingToShow.isEmpty) ||
                  (!showingStreamingPlaylist && _filteredSongs.isEmpty)) {
                return SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: SizedBox(
                    height: MediaQuery.of(context).size.height - 200,
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 80,
                            height: 80,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isDark
                                  ? Theme.of(context).colorScheme.secondary
                                        .withValues(alpha: 0.04)
                                  : Theme.of(context).colorScheme.secondary
                                        .withValues(alpha: 0.05),
                            ),
                            child: Icon(
                              _showAllSongs
                                  ? Icons.music_note_rounded
                                  : _hasSelectedPlaylist
                                  ? Icons.queue_music_rounded
                                  : Icons.folder_off_rounded,
                              size: 50,
                              color:
                                  Theme.of(context).brightness ==
                                      Brightness.light
                                  ? Theme.of(context).colorScheme.onSurface
                                        .withValues(alpha: 0.7)
                                  : Theme.of(context).colorScheme.onSurface
                                        .withValues(alpha: 0.7),
                            ),
                          ),
                          const SizedBox(height: 16),
                          TranslatedText(
                            _showAllSongs
                                ? 'no_songs'
                                : _hasSelectedPlaylist
                                ? (showingStreamingPlaylist
                                      ? 'no_streaming_songs'
                                      : 'no_songs_in_playlist')
                                : 'no_songs_in_folder',
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
                );
              }

              final cardColor = isAmoled
                  ? Colors.white.withAlpha(20)
                  : isDark
                  ? Theme.of(
                      context,
                    ).colorScheme.secondary.withValues(alpha: 0.06)
                  : Theme.of(
                      context,
                    ).colorScheme.secondary.withValues(alpha: 0.07);

              return RawScrollbar(
                controller: _scrollController,
                thumbColor: Theme.of(context).colorScheme.primary,
                thickness: 6.0,
                radius: const Radius.circular(8),
                interactive: true,
                padding: EdgeInsets.only(bottom: space),
                child: ListView.builder(
                  controller: _scrollController,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.only(
                    left: 16.0,
                    right: 16.0,
                    top: 8.0,
                    bottom: space,
                  ),
                  itemCount: showingStreamingPlaylist
                      ? streamingToShow.length + (showYtStreamingFooter ? 1 : 0)
                      : _displaySongs.length,
                  itemBuilder: (context, i) {
                    if (showingStreamingPlaylist) {
                      if (i >= streamingToShow.length) {
                        if (showYtStreamingPagination &&
                            _ytActivePlaylistHasMore &&
                            !_isLoadingMoreYtPlaylistSongs) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (!mounted) return;
                            unawaited(_loadMoreYtPlaylistSongsIfNeeded());
                          });
                        }
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Center(
                            child: _isLoadingMoreYtPlaylistSongs
                                ? Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: LoadingIndicator(),
                                      ),
                                      const SizedBox(width: 12),
                                      TranslatedText(
                                        'loading_more',
                                        style: TextStyle(fontSize: 14),
                                      ),
                                    ],
                                  )
                                : const SizedBox.shrink(),
                          ),
                        );
                      }

                      final item = streamingToShow[i];
                      if (showYtStreamingPagination &&
                          _ytActivePlaylistHasMore &&
                          !_isLoadingMoreYtPlaylistSongs &&
                          i >= streamingToShow.length - 5) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (!mounted) return;
                          unawaited(_loadMoreYtPlaylistSongsIfNeeded());
                        });
                      }
                      final sources = _streamingArtworkSources(item);
                      final isSelected = _selectedSongPaths.contains(
                        item.rawPath,
                      );
                      final currentVideoId = currentMediaItem
                          ?.extras?['videoId']
                          ?.toString()
                          .trim();
                      final isCurrent =
                          currentVideoId != null &&
                          item.videoId?.trim() == currentVideoId;
                      final bool isFirst = i == 0;
                      final bool isLast = i == streamingToShow.length - 1;
                      final bool isOnly = streamingToShow.length == 1;

                      BorderRadius borderRadius;
                      if (isOnly) {
                        borderRadius = BorderRadius.circular(20);
                      } else if (isFirst) {
                        borderRadius = const BorderRadius.only(
                          topLeft: Radius.circular(20),
                          topRight: Radius.circular(20),
                          bottomLeft: Radius.circular(4),
                          bottomRight: Radius.circular(4),
                        );
                      } else if (isLast) {
                        borderRadius = const BorderRadius.only(
                          topLeft: Radius.circular(4),
                          topRight: Radius.circular(4),
                          bottomLeft: Radius.circular(20),
                          bottomRight: Radius.circular(20),
                        );
                      } else {
                        borderRadius = BorderRadius.circular(4);
                      }

                      Widget buildStreamingTile(bool playing) {
                        return ListTile(
                          shape: RoundedRectangleBorder(
                            borderRadius: borderRadius,
                          ),
                          onTap: () {
                            if (_isSelecting) {
                              setState(() {
                                if (isSelected) {
                                  _selectedSongPaths.remove(item.rawPath);
                                  if (_selectedSongPaths.isEmpty) {
                                    _isSelecting = false;
                                  }
                                } else {
                                  _selectedSongPaths.add(item.rawPath);
                                }
                              });
                            } else {
                              _playStreamingPlaylistItem(item);
                            }
                          },
                          onLongPress: () {
                            if (_isSelecting) {
                              setState(() {
                                if (isSelected) {
                                  _selectedSongPaths.remove(item.rawPath);
                                  if (_selectedSongPaths.isEmpty) {
                                    _isSelecting = false;
                                  }
                                } else {
                                  _selectedSongPaths.add(item.rawPath);
                                }
                              });
                            } else {
                              _handleStreamingPlaylistLongPress(context, item);
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
                                        _selectedSongPaths.add(item.rawPath);
                                      } else {
                                        _selectedSongPaths.remove(item.rawPath);
                                        if (_selectedSongPaths.isEmpty) {
                                          _isSelecting = false;
                                        }
                                      }
                                    });
                                  },
                                ),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: SizedBox(
                                  width: 50,
                                  height: 50,
                                  child: _StreamingArtwork(
                                    sources: sources,
                                    backgroundColor: Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainerHigh,
                                    iconColor: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          title: Row(
                            children: [
                              if (isCurrent)
                                Padding(
                                  padding: const EdgeInsets.only(right: 8.0),
                                  child: MiniMusicVisualizer(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    width: 4,
                                    height: 15,
                                    radius: 4,
                                    animate: playing,
                                  ),
                                ),
                              Expanded(
                                child: Text(
                                  item.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: isCurrent
                                      ? Theme.of(
                                          context,
                                        ).textTheme.titleMedium?.copyWith(
                                          color: isAmoled
                                              ? Colors.white
                                              : Theme.of(
                                                  context,
                                                ).colorScheme.primary,
                                          fontWeight: FontWeight.bold,
                                        )
                                      : Theme.of(context).textTheme.titleMedium,
                                ),
                              ),
                            ],
                          ),
                          subtitle: Text(
                            _formatStreamingArtistWithDuration(item),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: isAmoled
                                ? TextStyle(
                                    color: Colors.white.withValues(alpha: 0.8),
                                  )
                                : null,
                          ),
                          trailing: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.primary.withAlpha(20),
                              shape: BoxShape.circle,
                            ),
                            child: IconButton(
                              icon: Icon(
                                isCurrent && playing
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                grade: 200,
                                fill: 1,
                                color: isCurrent
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                              onPressed: () {
                                if (isCurrent) {
                                  playing
                                      ? audioHandler.myHandler?.pause()
                                      : audioHandler.myHandler?.play();
                                } else {
                                  _playStreamingPlaylistItem(item);
                                }
                              },
                            ),
                          ),
                          selected: isCurrent,
                          selectedTileColor: Colors.transparent,
                        );
                      }

                      return Padding(
                        padding: EdgeInsets.only(bottom: isLast ? 0 : 4),
                        child: Card(
                          color: isCurrent
                              ? isAmoled
                                    ? cardColor
                                    : Theme.of(context).colorScheme.primary
                                          .withAlpha(isDark ? 40 : 25)
                              : cardColor,
                          margin: EdgeInsets.zero,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: borderRadius,
                          ),
                          child: ClipRRect(
                            borderRadius: borderRadius,
                            child: isCurrent
                                ? ValueListenableBuilder<bool>(
                                    valueListenable: _isPlayingNotifier,
                                    builder: (context, playing, child) {
                                      return buildStreamingTile(playing);
                                    },
                                  )
                                : buildStreamingTile(false),
                          ),
                        ),
                      );
                    }

                    final song = _displaySongs[i];
                    final path = song.data;
                    final isCurrent =
                        (currentMediaItem?.id != null &&
                        path.isNotEmpty &&
                        (currentMediaItem!.id == path ||
                            currentMediaItem.extras?['data'] == path));
                    final isSelected = _selectedSongPaths.contains(path);
                    final isIgnoredFuture = isSongIgnored(path);

                    // Determinar el borderRadius según la posición
                    final bool isFirst = i == 0;
                    final bool isLast = i == _displaySongs.length - 1;
                    final bool isOnly = _displaySongs.length == 1;

                    BorderRadius borderRadius;
                    if (isOnly) {
                      borderRadius = BorderRadius.circular(20);
                    } else if (isFirst) {
                      borderRadius = const BorderRadius.only(
                        topLeft: Radius.circular(20),
                        topRight: Radius.circular(20),
                        bottomLeft: Radius.circular(4),
                        bottomRight: Radius.circular(4),
                      );
                    } else if (isLast) {
                      borderRadius = const BorderRadius.only(
                        topLeft: Radius.circular(4),
                        topRight: Radius.circular(4),
                        bottomLeft: Radius.circular(20),
                        bottomRight: Radius.circular(20),
                      );
                    } else {
                      borderRadius = BorderRadius.circular(4);
                    }

                    return FutureBuilder<bool>(
                      future: isIgnoredFuture,
                      builder: (context, snapshot) {
                        final isIgnored = snapshot.data ?? false;

                        Widget listTileWidget;
                        // Solo usar ValueListenableBuilder para la canción actual
                        if (isCurrent) {
                          listTileWidget = ValueListenableBuilder<bool>(
                            valueListenable: _isPlayingNotifier,
                            builder: (context, playing, child) {
                              return _buildOptimizedListTile(
                                context,
                                song,
                                isCurrent,
                                playing,
                                isAmoled,
                                isIgnored,
                                isSelected,
                                borderRadius: borderRadius,
                              );
                            },
                          );
                        } else {
                          // Para canciones que no están reproduciéndose, no usar StreamBuilder
                          listTileWidget = _buildOptimizedListTile(
                            context,
                            song,
                            isCurrent,
                            false, // No playing
                            isAmoled,
                            isIgnored,
                            isSelected,
                            borderRadius: borderRadius,
                          );
                        }

                        return RepaintBoundary(
                          child: Padding(
                            padding: EdgeInsets.only(bottom: isLast ? 0 : 4),
                            child: Card(
                              color: isCurrent
                                  ? isAmoled
                                        ? cardColor
                                        : Theme.of(context).colorScheme.primary
                                              .withAlpha(isDark ? 40 : 25)
                                  : cardColor,
                              margin: EdgeInsets.zero,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: borderRadius,
                              ),
                              child: ClipRRect(
                                borderRadius: borderRadius,
                                child: listTileWidget,
                              ),
                            ),
                          ),
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
    bool isSelected, {
    BorderRadius? borderRadius,
  }) {
    final path = song.data;
    final opacity = isIgnored ? 0.4 : 1.0;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isAmoled =
        isDark && Theme.of(context).colorScheme.surface == Colors.black;

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
                child: ArtworkListTile(
                  key: ValueKey('folder_art_${song.data}'),
                  songId: song.id,
                  songPath: song.data,
                  size: 50,
                  borderRadius: BorderRadius.circular(8),
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
                  song.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: isCurrent
                      ? Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: isAmoledTheme
                              ? Colors.white
                              : Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        )
                      : Theme.of(context).textTheme.titleMedium,
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
            style: isAmoled
                ? TextStyle(color: Colors.white.withValues(alpha: 0.8))
                : null,
          ),
        ),
        trailing: !_isSelecting
            ? Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withAlpha(20),
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  icon: Icon(
                    isCurrent
                        ? (playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded)
                        : Icons.play_arrow_rounded,
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
                                ? audioHandler.myHandler?.pause()
                                : audioHandler.myHandler?.play();
                          } else {
                            _onSongSelected(song);
                          }
                        },
                ),
              )
            : null,
        selected: isCurrent,
        selectedTileColor: Colors.transparent,
        shape: borderRadius != null
            ? RoundedRectangleBorder(borderRadius: borderRadius)
            : null,
      ),
    );
  }

  Future<void> _handleAddToPlaylistMassive(BuildContext context) async {
    final allPlaylists = await PlaylistsDB().getAllPlaylists();
    final selectingStreamingPlaylist = _isStreamingPlaylistDetail;
    final playlists = allPlaylists
        .where(
          (p) => _playlistMatchesTargetSource(
            p,
            forStreaming: selectingStreamingPlaylist,
          ),
        )
        .toList();
    final visibleStreamingItems = _searchController.text.isNotEmpty
        ? _filteredPlaylistStreamingItems
        : _playlistStreamingItems;

    Future<void> addSelectedToPlaylist(String playlistId) async {
      if (selectingStreamingPlaylist) {
        final selectedStreamingItems = visibleStreamingItems.where(
          (item) => _selectedSongPaths.contains(item.rawPath),
        );
        for (final item in selectedStreamingItems) {
          await PlaylistsDB().addSongPathToPlaylist(
            playlistId,
            item.rawPath,
            title: item.title,
            artist: item.artist,
            videoId: item.videoId,
            artUri: item.artUri,
            durationText: item.durationText,
            durationMs: item.durationMs,
          );
        }
      } else {
        final selectedSongs = _displaySongs.where(
          (s) => _selectedSongPaths.contains(s.data),
        );
        for (final song in selectedSongs) {
          await PlaylistsDB().addSongToPlaylist(playlistId, song);
        }
      }
    }

    if (_allSongsForGrid.isEmpty) {
      final allIndexedSongs = await SongsIndexDB().getIndexedSongs();
      if (mounted) {
        setState(() {
          _allSongsForGrid = allIndexedSongs;
        });
      }
    }

    final TextEditingController controller = TextEditingController();

    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final colorScheme = colorSchemeNotifier.value;
        final isAmoled = colorScheme == AppColorScheme.amoled;
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final barColor = isAmoled
            ? Colors.white.withAlpha(20)
            : isDark
            ? Theme.of(context).colorScheme.secondary.withValues(alpha: 0.06)
            : Theme.of(context).colorScheme.secondary.withValues(alpha: 0.07);

        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom + 16,
                left: 16,
                right: 16,
                top: 12,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant.withAlpha(100),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    LocaleProvider.tr('save_to_playlist'),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (playlists.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Column(
                        children: [
                          Icon(
                            Icons.playlist_add_rounded,
                            size: 48,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            LocaleProvider.tr('no_playlists_yet'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (playlists.isNotEmpty)
                    Flexible(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.of(context).size.height * 0.4,
                        ),
                        child: ListView.builder(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          itemCount: playlists.length,
                          itemBuilder: (context, i) {
                            final pl = playlists[i];
                            final bool isFirst = i == 0;
                            final bool isLast = i == playlists.length - 1;
                            final bool isOnly = playlists.length == 1;

                            BorderRadius borderRadius;
                            if (isOnly) {
                              borderRadius = BorderRadius.circular(20);
                            } else if (isFirst) {
                              borderRadius = const BorderRadius.only(
                                topLeft: Radius.circular(20),
                                topRight: Radius.circular(20),
                                bottomLeft: Radius.circular(4),
                                bottomRight: Radius.circular(4),
                              );
                            } else if (isLast) {
                              borderRadius = const BorderRadius.only(
                                topLeft: Radius.circular(4),
                                topRight: Radius.circular(4),
                                bottomLeft: Radius.circular(20),
                                bottomRight: Radius.circular(20),
                              );
                            } else {
                              borderRadius = BorderRadius.circular(4);
                            }

                            return Padding(
                              padding: EdgeInsets.only(bottom: isLast ? 0 : 4),
                              child: Card(
                                color: barColor,
                                margin: EdgeInsets.zero,
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: borderRadius,
                                ),
                                child: ListTile(
                                  shape: RoundedRectangleBorder(
                                    borderRadius: borderRadius,
                                  ),
                                  leading: _buildPlaylistArtworkGrid(pl),
                                  title: Text(
                                    pl.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                  onTap: () async {
                                    await addSelectedToPlaylist(pl.id);
                                    setState(() {
                                      _isSelecting = false;
                                      _selectedSongPaths.clear();
                                    });
                                    playlistsShouldReload.value =
                                        !playlistsShouldReload.value;
                                    if (context.mounted) {
                                      Navigator.of(context).pop();
                                    }
                                  },
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: controller,
                    autofocus: false,
                    decoration: InputDecoration(
                      hintText: LocaleProvider.tr('new_playlist'),
                      prefixIcon: const Icon(Icons.playlist_add),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.check_rounded),
                        onPressed: () async {
                          final name = controller.text.trim();
                          if (name.isNotEmpty) {
                            final id = await PlaylistsDB().createPlaylist(name);
                            await addSelectedToPlaylist(id);
                            setState(() {
                              _isSelecting = false;
                              _selectedSongPaths.clear();
                            });
                            playlistsShouldReload.value =
                                !playlistsShouldReload.value;
                            if (context.mounted) Navigator.of(context).pop();
                          }
                        },
                      ),
                      filled: true,
                      fillColor: barColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 16,
                      ),
                    ),
                    onSubmitted: (value) async {
                      final name = value.trim();
                      if (name.isNotEmpty) {
                        final id = await PlaylistsDB().createPlaylist(name);
                        await addSelectedToPlaylist(id);
                        setState(() {
                          _isSelecting = false;
                          _selectedSongPaths.clear();
                        });
                        playlistsShouldReload.value =
                            !playlistsShouldReload.value;
                        if (context.mounted) Navigator.of(context).pop();
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _handleCopyToFolder(BuildContext context) async {
    if (!context.mounted) return;

    final selectedSongs = _displaySongs
        .where((s) => _selectedSongPaths.contains(s.data))
        .toList();

    if (selectedSongs.isEmpty) return;

    // Usar la función existente para mostrar el selector de carpetas
    // pero adaptada para múltiples canciones
    await _showFolderSelectorMultiple(selectedSongs, isMove: false);
  }

  Future<void> _handleMoveToFolder(BuildContext context) async {
    if (!context.mounted) return;

    final selectedSongs = _displaySongs
        .where((s) => _selectedSongPaths.contains(s.data))
        .toList();

    if (selectedSongs.isEmpty) return;

    // Usar la función existente para mostrar el selector de carpetas
    // pero adaptada para múltiples canciones
    await _showFolderSelectorMultiple(selectedSongs, isMove: true);
  }

  Future<void> _handleRemoveStreamingFromPlaylistMassive(
    BuildContext context,
  ) async {
    if (!context.mounted || _selectedPlaylist == null) return;

    final visibleStreamingItems = _searchController.text.isNotEmpty
        ? _filteredPlaylistStreamingItems
        : _playlistStreamingItems;
    final selectedStreamingItems = visibleStreamingItems
        .where((item) => _selectedSongPaths.contains(item.rawPath))
        .toList();
    if (selectedStreamingItems.isEmpty) return;

    for (final item in selectedStreamingItems) {
      await PlaylistsDB().removeSongFromPlaylist(
        _selectedPlaylist!.id,
        item.rawPath,
      );
    }

    if (!mounted) return;
    setState(() {
      _isSelecting = false;
      _selectedSongPaths.clear();
    });
    playlistsShouldReload.value = !playlistsShouldReload.value;
    await _loadSongsFromPlaylist(_selectedPlaylist!);
  }

  Future<void> _handleDownloadSelectedStreamingPlaylistItems() async {
    final visibleStreamingItems = _searchController.text.isNotEmpty
        ? _filteredPlaylistStreamingItems
        : _playlistStreamingItems;
    final selectedStreamingItems = visibleStreamingItems
        .where((item) => _selectedSongPaths.contains(item.rawPath))
        .toList();
    if (selectedStreamingItems.isEmpty) return;

    for (final item in selectedStreamingItems) {
      await _downloadStreamingPlaylistItem(item);
    }

    if (!mounted) return;
    setState(() {
      _isSelecting = false;
      _selectedSongPaths.clear();
    });
  }

  Future<void> _handleDeleteSongs(BuildContext context) async {
    if (!context.mounted) return;

    final selectedSongs = _displaySongs
        .where((s) => _selectedSongPaths.contains(s.data))
        .toList();

    if (selectedSongs.isEmpty) return;

    // Mostrar diálogo de confirmación con el mismo diseño que el individual
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;

            return AlertDialog(
              backgroundColor: isAmoled && isDark
                  ? Colors.black
                  : Theme.of(context).colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white24, width: 1)
                    : BorderSide.none,
              ),
              contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
              icon: Icon(
                Icons.delete_sweep_rounded,
                size: 32,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                LocaleProvider.tr('delete_songs'),
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
              content: Text(
                LocaleProvider.tr(
                  'delete_songs_confirm',
                ).replaceAll('{count}', selectedSongs.length.toString()),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              actionsPadding: const EdgeInsets.all(16),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(
                    LocaleProvider.tr('cancel'),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: Text(
                    LocaleProvider.tr('delete'),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            );
          },
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
        final handler = audioHandler.myHandler;
        await handler?.removeSongsByPath(List<String>.from(songPaths));
      } catch (_) {}

      // Borrar archivos físicos
      for (final song in songs) {
        try {
          final file = File(song.data);
          if (await file.exists()) {
            await file.delete();

            // Notificar al MediaStore de Android que el archivo fue eliminado
            try {
              await OnAudioQuery().scanMedia(song.data);
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
          final toRemove = p.songPaths
              .where((sp) => songPaths.contains(sp))
              .toList();
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
  Future<void> _showFolderSelectorMultiple(
    List<SongModel> songs, {
    required bool isMove,
  }) async {
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
                      color: Theme.of(
                        context,
                      ).dividerColor.withValues(alpha: 0.1),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      isMove ? Icons.drive_file_move : Icons.copy,
                      color: Theme.of(
                        context,
                      ).colorScheme.inverseSurface.withValues(alpha: 0.95),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        isMove
                            ? LocaleProvider.tr('move_to_folder')
                            : LocaleProvider.tr('copy_to_folder'),
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
                    final displayName =
                        folderDisplayNames[folder] ?? p.basename(originalPath);

                    return ListTile(
                      leading: Icon(Icons.folder),
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
                        await _processMultipleSongs(
                          songs,
                          originalPath,
                          isMove: isMove,
                        );
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
  Future<void> _processMultipleSongs(
    List<SongModel> songs,
    String destinationFolder, {
    required bool isMove,
  }) async {
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
              final isAmoled =
                  colorSchemeNotifier.value == AppColorScheme.amoled;
              final isDark = Theme.of(context).brightness == Brightness.dark;
              return AlertDialog(
                backgroundColor: isAmoled && isDark
                    ? Colors.black
                    : Theme.of(context).colorScheme.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                  side: isAmoled && isDark
                      ? const BorderSide(color: Colors.white24, width: 1)
                      : BorderSide.none,
                ),
                contentPadding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(width: 40, height: 40, child: LoadingIndicator()),
                    const SizedBox(height: 24),
                    Text(
                      isMove
                          ? LocaleProvider.tr('moving_songs')
                          : LocaleProvider.tr('copying_songs'),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      progress,
                      style: TextStyle(
                        fontSize: 14,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
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
  Future<void> _copySongToFolderInternal(
    SongModel song,
    String destinationFolder,
  ) async {
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
      await OnAudioQuery().scanMedia(destinationPath);

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
  Future<void> _moveSongToFolderInternal(
    SongModel song,
    String destinationFolder,
  ) async {
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
        await OnAudioQuery().scanMedia(song.data);
      } catch (_) {}

      // Actualizar el archivo nuevo en el sistema de medios de Android
      await OnAudioQuery().scanMedia(destinationPath);

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
    final allPlaylists = await PlaylistsDB().getAllPlaylists();
    final playlists = allPlaylists
        .where((p) => _playlistMatchesTargetSource(p, forStreaming: false))
        .toList();

    if (_allSongsForGrid.isEmpty) {
      final allIndexedSongs = await SongsIndexDB().getIndexedSongs();
      if (mounted) {
        setState(() {
          _allSongsForGrid = allIndexedSongs;
        });
      }
    }

    final TextEditingController controller = TextEditingController();

    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final colorScheme = colorSchemeNotifier.value;
        final isAmoled = colorScheme == AppColorScheme.amoled;
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final barColor = isAmoled
            ? Colors.white.withAlpha(20)
            : isDark
            ? Theme.of(context).colorScheme.secondary.withValues(alpha: 0.06)
            : Theme.of(context).colorScheme.secondary.withValues(alpha: 0.07);

        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom + 16,
                left: 16,
                right: 16,
                top: 12,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant.withAlpha(100),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    LocaleProvider.tr('save_to_playlist'),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (playlists.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Column(
                        children: [
                          Icon(
                            Icons.playlist_add_rounded,
                            size: 48,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            LocaleProvider.tr('no_playlists_yet'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (playlists.isNotEmpty)
                    Flexible(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.of(context).size.height * 0.4,
                        ),
                        child: ListView.builder(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          itemCount: playlists.length,
                          itemBuilder: (context, i) {
                            final pl = playlists[i];
                            final bool isFirst = i == 0;
                            final bool isLast = i == playlists.length - 1;
                            final bool isOnly = playlists.length == 1;

                            BorderRadius borderRadius;
                            if (isOnly) {
                              borderRadius = BorderRadius.circular(20);
                            } else if (isFirst) {
                              borderRadius = const BorderRadius.only(
                                topLeft: Radius.circular(20),
                                topRight: Radius.circular(20),
                                bottomLeft: Radius.circular(4),
                                bottomRight: Radius.circular(4),
                              );
                            } else if (isLast) {
                              borderRadius = const BorderRadius.only(
                                topLeft: Radius.circular(4),
                                topRight: Radius.circular(4),
                                bottomLeft: Radius.circular(20),
                                bottomRight: Radius.circular(20),
                              );
                            } else {
                              borderRadius = BorderRadius.circular(4);
                            }

                            return Padding(
                              padding: EdgeInsets.only(bottom: isLast ? 0 : 4),
                              child: Card(
                                color: barColor,
                                margin: EdgeInsets.zero,
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: borderRadius,
                                ),
                                child: ListTile(
                                  shape: RoundedRectangleBorder(
                                    borderRadius: borderRadius,
                                  ),
                                  leading: _buildPlaylistArtworkGrid(pl),
                                  title: Text(
                                    pl.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                  onTap: () async {
                                    await PlaylistsDB().addSongToPlaylist(
                                      pl.id,
                                      song,
                                    );
                                    playlistsShouldReload.value =
                                        !playlistsShouldReload.value;
                                    if (context.mounted) {
                                      Navigator.of(context).pop();
                                    }
                                  },
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: controller,
                    autofocus: false,
                    decoration: InputDecoration(
                      hintText: LocaleProvider.tr('new_playlist'),
                      prefixIcon: const Icon(Icons.playlist_add),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.check_rounded),
                        onPressed: () async {
                          final name = controller.text.trim();
                          if (name.isNotEmpty) {
                            final id = await PlaylistsDB().createPlaylist(name);
                            await PlaylistsDB().addSongToPlaylist(id, song);
                            playlistsShouldReload.value =
                                !playlistsShouldReload.value;
                            if (context.mounted) Navigator.of(context).pop();
                          }
                        },
                      ),
                      filled: true,
                      fillColor: barColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 16,
                      ),
                    ),
                    onSubmitted: (value) async {
                      final name = value.trim();
                      if (name.isNotEmpty) {
                        final id = await PlaylistsDB().createPlaylist(name);
                        await PlaylistsDB().addSongToPlaylist(id, song);
                        playlistsShouldReload.value =
                            !playlistsShouldReload.value;
                        if (context.mounted) Navigator.of(context).pop();
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<bool> _deleteFolderAndSongs(String folderKey) async {
    try {
      final songPaths = songPathsByFolder[folderKey] ?? [];
      bool allDeleted = true;
      // Primero retirar todas las canciones de la cola (maneja salto si alguna es la actual)
      try {
        final handler = audioHandler.myHandler;
        await handler?.removeSongsByPath(List<String>.from(songPaths));
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
    _invalidateYtPlaylistSongLoads('open-folder:${entry.key}');
    setState(() {
      carpetaSeleccionada = entry.key;
      _selectedPlaylist = null;
      _selectedYtLibraryPlaylist = null;
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
      _mediaItemDebounce?.cancel();
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

  /// Cargar todas las canciones de todas las carpetas
  Future<void> _loadAllSongs() async {
    if (!mounted) return;
    _invalidateYtPlaylistSongLoads('open-all-songs');
    setState(() {
      carpetaSeleccionada =
          '__ALL_SONGS__'; // Marcador especial para indicar que estamos mostrando todas las canciones
      _showAllSongs = true;
      _showPlaylists = false;
      _selectedPlaylist = null;
      _selectedYtLibraryPlaylist = null;
      _searchController.clear();
      _isSelecting = false;
      _selectedSongPaths.clear();
      _originalSongs = [];
      _filteredSongs = [];
      _displaySongs = [];
      _isLoading = true;
    });

    // Sincronizar mapa de carpetas antes de cargar
    await _sincronizarMapaCarpetas();

    // Actualizar los notifiers con los valores actuales del audioHandler
    if (audioHandler?.mediaItem.valueOrNull != null) {
      _mediaItemDebounce?.cancel();
      _currentMediaItemNotifier.value = audioHandler!.mediaItem.valueOrNull;
    }
    if (audioHandler?.playbackState.valueOrNull != null) {
      _isPlayingNotifier.value =
          audioHandler!.playbackState.valueOrNull!.playing;
    }

    // Obtener todas las rutas de canciones de todas las carpetas (no ignoradas)
    final allPaths = <String>[];
    for (final entry in songPathsByFolder.entries) {
      if (!_ignoredFoldersCache.contains(entry.key)) {
        allPaths.addAll(entry.value);
      }
    }

    // Cargar los objetos SongModel completos
    final allSongs = await _audioQuery.querySongs();
    final songsToShow = allSongs
        .where((s) => allPaths.contains(s.data))
        .toList();
    if (!mounted) return;
    setState(() {
      _originalSongs = songsToShow;
    });
    await _ordenarCanciones();
    // Precargar carátulas
    unawaited(_preloadArtworksForSongs(songsToShow));
    if (!mounted) return;
    setState(() {
      _isLoading = false;
    });
    unawaited(_saveLastViewPrefs());
  }

  /// Generar cuadrícula de carátulas para una playlist (como en Home)
  Widget _buildPlaylistArtworkGrid(hive_model.PlaylistModel playlist) {
    final filtered = playlist.songPaths
        .where((path) => path.trim().isNotEmpty)
        .toList();
    final latestPaths = filtered.reversed.take(4).toList();

    final List<Widget> artworks = latestPaths.map((path) {
      final normalizedPath = path.trim();
      if (_isStreamingPath(normalizedPath)) {
        final sources = _streamingPlaylistArtworkSources(
          playlist.id,
          normalizedPath,
        );
        return _StreamingArtwork(
          sources: sources,
          backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
          iconColor: Theme.of(context).colorScheme.onSurfaceVariant,
        );
      }

      final songIndex = _allSongsForGrid.indexWhere(
        (song) => song.data == normalizedPath,
      );
      if (songIndex == -1) {
        return Container(
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: Center(
            child: Icon(
              Icons.music_note,
              color: Theme.of(context).colorScheme.onSurface,
              size: 20,
            ),
          ),
        );
      }
      final song = _allSongsForGrid[songIndex];
      return ArtworkListTile(
        songId: song.id,
        songPath: song.data,
        borderRadius: BorderRadius.zero,
      );
    }).toList();

    return SizedBox(
      width: 48,
      height: 48,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: _buildArtworkLayout(artworks),
      ),
    );
  }

  List<String> _streamingPlaylistArtworkSources(
    String playlistId,
    String path,
  ) {
    final cacheKey = '$playlistId::$path';
    final cached = _playlistArtworkSourcesCache[cacheKey];
    if (cached != null && cached.isNotEmpty) return cached;

    final videoId = _extractVideoIdFromPath(path);
    if (videoId == null || videoId.isEmpty) return const [];
    return _streamingFallbackArtworkUrls(videoId);
  }

  Future<Map<String, List<String>>> _buildPlaylistArtworkSourcesCache(
    List<hive_model.PlaylistModel> playlists,
  ) async {
    final cache = <String, List<String>>{};
    for (final playlist in playlists) {
      final paths = playlist.songPaths
          .where((p) => p.trim().isNotEmpty)
          .toList()
          .reversed
          .take(4);
      for (final rawPath in paths) {
        final path = rawPath.trim();
        if (!_isStreamingPath(path)) continue;
        final meta = await PlaylistsDB().getPlaylistSongMeta(playlist.id, path);
        final metaArtUri = meta?['artUri']?.toString().trim();
        final metaVideoId = meta?['videoId']?.toString().trim();
        final videoId = (metaVideoId != null && metaVideoId.isNotEmpty)
            ? metaVideoId
            : _extractVideoIdFromPath(path);

        final sources = <String>[];
        final resolvedMetaArtUri = _applyStreamingArtworkQuality(
          metaArtUri,
          videoId: videoId,
        );
        if (resolvedMetaArtUri != null && resolvedMetaArtUri.isNotEmpty) {
          sources.add(resolvedMetaArtUri);
        }
        if (videoId != null && videoId.isNotEmpty) {
          sources.addAll(_streamingFallbackArtworkUrls(videoId));
        }
        if (sources.isNotEmpty) {
          cache['${playlist.id}::$path'] = sources.toSet().toList();
        }
      }
    }
    return cache;
  }

  Widget _buildArtworkLayout(List<Widget> artworks) {
    switch (artworks.length) {
      case 0:
        return Container(
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: Center(
            child: Icon(
              Icons.music_note,
              color: Theme.of(context).colorScheme.onSurface,
              size: 20,
            ),
          ),
        );

      case 1:
        return artworks[0];

      case 2:
      case 3:
        // Caso 2 y 3: mostramos 2 (lado a lado)
        return Row(
          children: [
            Expanded(child: artworks[0]),
            Expanded(child: artworks[1]),
          ],
        );

      default:
        // 4 o más canciones: Cuadrícula 2x2
        return Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  Expanded(child: artworks[0]),
                  Expanded(child: artworks[1]),
                ],
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  Expanded(child: artworks[2]),
                  Expanded(child: artworks[3]),
                ],
              ),
            ),
          ],
        );
    }
  }

  /// Cargar la lista de playlists desde la base de datos
  Future<void> _loadPlaylists() async {
    _ytUiLog(
      '_loadPlaylists start: source=${_playlistSourceLabel(_playlistSource)}',
    );
    if (!mounted) return;
    _invalidateYtPlaylistSongLoads('open-playlists-root');
    setState(() {
      _showPlaylists = true;
      _showAllSongs = false;
      carpetaSeleccionada = null;
      _selectedPlaylist = null;
      _selectedYtLibraryPlaylist = null;
      _searchController.clear();
      _playlistSearchController.clear();
      _isSelecting = false;
      _selectedSongPaths.clear();
      _filteredSongs.clear();
      _displaySongs.clear();
      _isLoading = true;
    });

    final playlists = await PlaylistsDB().getAllPlaylists();
    final allIndexedSongs = await SongsIndexDB().getIndexedSongs();
    final streamingArtworkCache = await _buildPlaylistArtworkSourcesCache(
      playlists,
    );
    final hasYtAuth = await yt_service.hasYtMusicAuthCookieHeader();
    _ytUiLog(
      '_loadPlaylists local=${playlists.length}, hasYtAuth=$hasYtAuth, source=${_playlistSourceLabel(_playlistSource)}',
    );

    if (!mounted) return;
    setState(() {
      _playlists = playlists;
      _allSongsForGrid = allIndexedSongs;
      _playlistArtworkSourcesCache = streamingArtworkCache;
      _hasYtAuthCookieSession = hasYtAuth;
      if (!hasYtAuth) {
        _ytAccountDisplayName = null;
      }
      if (!hasYtAuth) {
        _ytLibraryPlaylists = [];
        _filteredYtLibraryPlaylists = [];
      }
      _isLoading = false;
      _applyPlaylistFilters();
    });

    if (_playlistSource == PlaylistSource.ytMusicCookies && hasYtAuth) {
      unawaited(_loadYtLibraryPlaylists(forceRefresh: true));
      unawaited(_refreshYtAccountDisplayName(force: true));
    } else if (_playlistSource == PlaylistSource.ytMusicCookies && !hasYtAuth) {
      _ytUiLog(
        '_loadPlaylists source=ytMusicCookies but no auth cookie; remote list will stay empty',
      );
    }
    if (hasYtAuth) {
      unawaited(_refreshYtAccountDisplayName());
    }

    unawaited(_saveLastViewPrefs());
  }

  /// Crear una nueva lista de reproducción
  Future<void> _createNewPlaylist() async {
    final TextEditingController nameController = TextEditingController();
    final String? playlistId = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: TranslatedText('create_playlist'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: InputDecoration(
            hintText: LocaleProvider.tr('new_playlist_name'),
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: TranslatedText('cancel'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(nameController.text.trim()),
            child: TranslatedText('create'),
          ),
        ],
      ),
    );

    if (playlistId != null && playlistId.isNotEmpty) {
      final String id = await PlaylistsDB().createPlaylist(playlistId);
      if (id.isNotEmpty) {
        // Notificar a otras pantallas
        playlistsShouldReload.value = !playlistsShouldReload.value;
        // Recargar la lista local
        await _loadPlaylists();
      }
    }
  }

  /// Mostrar diálogo para agregar canciones a la playlist actual
  Future<void> _showAddSongsToPlaylistDialog() async {
    if (_selectedPlaylist == null) return;

    final allSongs = await SongsIndexDB().getIndexedSongs();
    final currentSongPaths = _selectedPlaylist!.songPaths.toSet();

    // Filtrar canciones que ya están en la playlist
    final availableSongs = allSongs
        .where((s) => !currentSongPaths.contains(s.data))
        .toList();

    if (!mounted) return;

    final Set<String> selectedPaths = {};
    String query = "";

    final selected = await showDialog<List<String>>(
      context: context,
      builder: (context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final primaryColor = Theme.of(context).colorScheme.primary;

            return StatefulBuilder(
              builder: (context, setStateDialog) {
                // Optimizar filtrado para evitar procesar toda la lista en cada frame si es posible
                final filtered = query.isEmpty
                    ? availableSongs
                    : availableSongs.where((s) {
                        final title = s.title.toLowerCase();
                        final artist = (s.artist ?? "").toLowerCase();
                        final q = query.toLowerCase();
                        return title.contains(q) || artist.contains(q);
                      }).toList();

                return AlertDialog(
                  backgroundColor: isAmoled && isDark
                      ? Colors.black
                      : Theme.of(context).colorScheme.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28),
                    side: isAmoled && isDark
                        ? const BorderSide(color: Colors.white24, width: 1)
                        : BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
                  content: SizedBox(
                    width: 500, // Forzar ancho
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(context).size.height * 0.7,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.playlist_add, size: 32),
                          const SizedBox(height: 16),
                          TranslatedText(
                            'add_songs',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w500,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: TextField(
                              decoration: InputDecoration(
                                hintText: LocaleProvider.tr('search_songs'),
                                prefixIcon: const Icon(Icons.search),
                                filled: true,
                                fillColor: isDark
                                    ? Colors.white.withAlpha(20)
                                    : Colors.black.withAlpha(10),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(20),
                                  borderSide: BorderSide.none,
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                              ),
                              onChanged: (v) {
                                setStateDialog(() {
                                  query = v;
                                });
                              },
                            ),
                          ),
                          const SizedBox(height: 16),
                          Flexible(
                            child: Container(
                              margin: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(20),
                                color: isDark
                                    ? Colors.white.withAlpha(10)
                                    : Colors.black.withAlpha(5),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(20),
                                child: filtered.isEmpty
                                    ? Center(
                                        child: Padding(
                                          padding: const EdgeInsets.all(24.0),
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.music_off_rounded,
                                                size: 48,
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onSurface
                                                    .withAlpha(100),
                                              ),
                                              const SizedBox(height: 12),
                                              TranslatedText(
                                                'no_songs',
                                                style: TextStyle(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSurface
                                                      .withAlpha(150),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      )
                                    : ListView.builder(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 8,
                                        ),
                                        itemCount: filtered.length,
                                        itemBuilder: (context, index) {
                                          final song = filtered[index];
                                          final isSelected = selectedPaths
                                              .contains(song.data);
                                          return ListTile(
                                            onTap: () {
                                              setStateDialog(() {
                                                if (isSelected) {
                                                  selectedPaths.remove(
                                                    song.data,
                                                  );
                                                } else {
                                                  selectedPaths.add(song.data);
                                                }
                                              });
                                            },
                                            leading: ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              child: ArtworkListTile(
                                                songId: song.id,
                                                songPath: song.data,
                                                size: 40,
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                              ),
                                            ),
                                            title: Text(
                                              song.displayTitle,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                            subtitle: Text(
                                              song.displayArtist,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onSurface
                                                    .withAlpha(150),
                                              ),
                                            ),
                                            trailing: Checkbox(
                                              value: isSelected,
                                              activeColor: primaryColor,
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                              onChanged: (v) {
                                                setStateDialog(() {
                                                  if (v == true) {
                                                    selectedPaths.add(
                                                      song.data,
                                                    );
                                                  } else {
                                                    selectedPaths.remove(
                                                      song.data,
                                                    );
                                                  }
                                                });
                                              },
                                            ),
                                          );
                                        },
                                      ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Padding(
                            padding: const EdgeInsets.only(
                              right: 24,
                              bottom: 8,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: TranslatedText(
                                    'cancel',
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                TextButton(
                                  onPressed: selectedPaths.isEmpty
                                      ? null
                                      : () => Navigator.pop(
                                          context,
                                          selectedPaths.toList(),
                                        ),
                                  style: TextButton.styleFrom(
                                    foregroundColor: primaryColor,
                                  ),
                                  child: TranslatedText(
                                    'add',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );

    if (selected != null && selected.isNotEmpty) {
      for (final path in selected) {
        try {
          final song = allSongs.firstWhere((s) => s.data == path);
          await PlaylistsDB().addSongToPlaylist(_selectedPlaylist!.id, song);
        } catch (_) {}
      }
      playlistsShouldReload.value = !playlistsShouldReload.value;
      await _loadSongsFromPlaylist(_selectedPlaylist!);
    }
  }

  /// Mostrar opciones de la playlist al mantener presionado
  void _showPlaylistOptions(hive_model.PlaylistModel playlist) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                playlist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: TranslatedText('rename_playlist'),
              onTap: () {
                Navigator.pop(context);
                _showRenamePlaylistDialog(playlist);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: TranslatedText('delete_playlist'),
              onTap: () {
                Navigator.pop(context);
                _showDeletePlaylistConfirmation(playlist);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Diálogo para renombrar la playlist
  Future<void> _showRenamePlaylistDialog(
    hive_model.PlaylistModel playlist,
  ) async {
    final TextEditingController nameController = TextEditingController(
      text: playlist.name,
    );
    final String? newName = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final primaryColor = Theme.of(context).colorScheme.primary;

            return AlertDialog(
              backgroundColor: isAmoled && isDark
                  ? Colors.black
                  : Theme.of(context).colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white24, width: 1)
                    : BorderSide.none,
              ),
              contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 400,
                  maxHeight: MediaQuery.of(context).size.height * 0.8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.edit_note_rounded, size: 32),
                    const SizedBox(height: 16),
                    TranslatedText(
                      'rename_playlist',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: nameController,
                      autofocus: true,
                      decoration: InputDecoration(
                        labelText: LocaleProvider.tr('playlist_name'),
                        hintText: LocaleProvider.tr('enter_playlist_name'),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        filled: true,
                        fillColor: isAmoled && isDark
                            ? Colors.white.withAlpha(10)
                            : Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest
                                  .withAlpha(100),
                      ),
                      onSubmitted: (value) =>
                          Navigator.of(context).pop(value.trim()),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: TranslatedText(
                    'cancel',
                    style: TextStyle(
                      color: primaryColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      Navigator.of(context).pop(nameController.text.trim()),
                  child: TranslatedText(
                    'rename',
                    style: TextStyle(
                      color: primaryColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    if (newName != null && newName.isNotEmpty && newName != playlist.name) {
      await PlaylistsDB().renamePlaylist(playlist.id, newName);
      playlistsShouldReload.value = !playlistsShouldReload.value;
      await _loadPlaylists();
    }
  }

  /// Confirmación para eliminar la playlist
  Future<void> _showDeletePlaylistConfirmation(
    hive_model.PlaylistModel playlist,
  ) async {
    final bool confirmed =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext context) {
            return ValueListenableBuilder<AppColorScheme>(
              valueListenable: colorSchemeNotifier,
              builder: (context, colorScheme, child) {
                final isAmoled = colorScheme == AppColorScheme.amoled;
                final isDark = Theme.of(context).brightness == Brightness.dark;
                final primaryColor = Theme.of(context).colorScheme.primary;

                return AlertDialog(
                  backgroundColor: isAmoled && isDark
                      ? Colors.black
                      : Theme.of(context).colorScheme.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28),
                    side: isAmoled && isDark
                        ? const BorderSide(color: Colors.white24, width: 1)
                        : BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
                  content: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: 400,
                      maxHeight: MediaQuery.of(context).size.height * 0.8,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.delete_sweep_rounded,
                          size: 32,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        const SizedBox(height: 16),
                        TranslatedText(
                          'delete_playlist',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w500,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Text(
                            '${LocaleProvider.tr('delete_playlist_confirm')} "${playlist.name}"?',
                            style: TextStyle(
                              fontSize: 14,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurface.withAlpha(180),
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(height: 24),
                        _buildDestructiveOption(
                          context: context,
                          title: LocaleProvider.tr('delete'),
                          icon: Icons.delete_forever_rounded,
                          onTap: () => Navigator.of(context).pop(true),
                        ),
                        const SizedBox(height: 16),
                        Padding(
                          padding: const EdgeInsets.only(right: 24, bottom: 8),
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: () => Navigator.of(context).pop(false),
                              child: TranslatedText(
                                'cancel',
                                style: TextStyle(
                                  color: primaryColor,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
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
        ) ??
        false;

    if (confirmed) {
      await PlaylistsDB().deletePlaylist(playlist.id);
      playlistsShouldReload.value = !playlistsShouldReload.value;
      await _loadPlaylists();
    }
  }

  Future<void> _loadSongsFromYtLibraryPlaylist(
    _YtLibraryPlaylistItem playlist, {
    bool forceRefresh = false,
  }) async {
    final requestedPlaylistId = playlist.playlistId;
    _invalidateYtPlaylistSongLoads('open-yt-playlist:$requestedPlaylistId');
    final loadGeneration = _ytPlaylistSongsLoadGeneration;
    _ytUiLog(
      '_loadSongsFromYtLibraryPlaylist start: id=$requestedPlaylistId, title=${playlist.title}, forceRefresh=$forceRefresh, generation=$loadGeneration',
    );
    if (!mounted) return;

    setState(() {
      _selectedYtLibraryPlaylist = playlist;
      _selectedPlaylist = null;
      carpetaSeleccionada = '__YT_PLAYLIST__${playlist.playlistId}';
      _searchController.clear();
      _isSelecting = false;
      _selectedSongPaths.clear();
      _originalSongs = [];
      _filteredSongs = [];
      _displaySongs = [];
      _playlistStreamingItems = [];
      _filteredPlaylistStreamingItems = [];
      _ytActivePlaylistContinuationToken = null;
      _ytActivePlaylistHasMore = false;
      _isLoadingMoreYtPlaylistSongs = false;
      _isLoading = true;
    });

    if (audioHandler?.mediaItem.valueOrNull != null) {
      _mediaItemDebounce?.cancel();
      _currentMediaItemNotifier.value = audioHandler!.mediaItem.valueOrNull;
    }
    if (audioHandler?.playbackState.valueOrNull != null) {
      _isPlayingNotifier.value =
          audioHandler!.playbackState.valueOrNull!.playing;
    }

    List<_StreamingPlaylistItem> streamingItems;
    final cached = _ytPlaylistItemsCache[requestedPlaylistId];
    if (!forceRefresh && cached != null && cached.isNotEmpty) {
      _ytUiLog(
        '_loadSongsFromYtLibraryPlaylist using cache: tracks=${cached.length}',
      );
      streamingItems = List<_StreamingPlaylistItem>.from(cached);
      final cachedContinuation =
          _ytPlaylistContinuationTokenCache[requestedPlaylistId]?.trim();
      _ytActivePlaylistContinuationToken =
          (cachedContinuation != null && cachedContinuation.isNotEmpty)
          ? cachedContinuation
          : null;
      _ytActivePlaylistHasMore = _ytActivePlaylistContinuationToken != null;
    } else {
      final firstPage = await yt_service.getPlaylistSongsPage(
        requestedPlaylistId,
        limit: 100,
      );
      if (!_isYtPlaylistSongLoadActive(
        generation: loadGeneration,
        playlistId: requestedPlaylistId,
      )) {
        return;
      }
      final tracks =
          (firstPage['results'] as List?)
              ?.whereType<yt_service.YtMusicResult>()
              .toList() ??
          <yt_service.YtMusicResult>[];
      final nextToken = firstPage['continuationToken']?.toString().trim();
      _ytActivePlaylistContinuationToken =
          (nextToken != null && nextToken.isNotEmpty) ? nextToken : null;
      _ytActivePlaylistHasMore = _ytActivePlaylistContinuationToken != null;
      _ytPlaylistContinuationTokenCache[requestedPlaylistId] =
          _ytActivePlaylistContinuationToken;
      _ytUiLog(
        '_loadSongsFromYtLibraryPlaylist first page tracks=${tracks.length}, hasMore=$_ytActivePlaylistHasMore',
      );
      streamingItems = _mapYtTracksToStreamingItems(tracks);

      _ytPlaylistItemsCache[requestedPlaylistId] = List.from(streamingItems);
    }

    if (!_isYtPlaylistSongLoadActive(
      generation: loadGeneration,
      playlistId: requestedPlaylistId,
    )) {
      return;
    }

    _originalSongs = [];
    _filteredSongs = [];
    _displaySongs = [];
    _originalPlaylistStreamingItems = List.from(streamingItems);
    _playlistStreamingItems = List.from(streamingItems);
    _filteredPlaylistStreamingItems = [];

    await _ordenarCanciones();
    if (!_isYtPlaylistSongLoadActive(
      generation: loadGeneration,
      playlistId: requestedPlaylistId,
    )) {
      return;
    }
    _ytUiLog(
      '_loadSongsFromYtLibraryPlaylist done: visible=${_playlistStreamingItems.length}, hasMore=$_ytActivePlaylistHasMore',
    );
    if (!mounted) return;
    setState(() {
      _isLoading = false;
    });
    unawaited(_saveLastViewPrefs());
  }

  List<_StreamingPlaylistItem> _mapYtTracksToStreamingItems(
    List<yt_service.YtMusicResult> tracks,
  ) {
    return tracks
        .where((track) => (track.videoId?.trim().isNotEmpty ?? false))
        .map((track) {
          final videoId = track.videoId!.trim();
          final durationText = (track.durationText?.trim().isNotEmpty ?? false)
              ? track.durationText!.trim()
              : (track.durationMs != null && track.durationMs! > 0)
              ? _formatDurationMs(track.durationMs!)
              : null;
          return _StreamingPlaylistItem(
            rawPath: 'yt:$videoId',
            title: (track.title?.trim().isNotEmpty ?? false)
                ? track.title!.trim()
                : 'YouTube Music ($videoId)',
            artist: (track.artist?.trim().isNotEmpty ?? false)
                ? track.artist!.trim()
                : LocaleProvider.tr('artist_unknown'),
            videoId: videoId,
            artUri: _applyStreamingArtworkQuality(
              track.thumbUrl,
              videoId: videoId,
            ),
            durationText: durationText,
            durationMs: track.durationMs,
          );
        })
        .toList();
  }

  Future<void> _loadMoreYtPlaylistSongsIfNeeded() async {
    if (!mounted) return;
    if (_playlistSource != PlaylistSource.ytMusicCookies) return;
    if (_selectedYtLibraryPlaylist == null) return;
    if (_searchController.text.isNotEmpty) return;
    if (!_ytActivePlaylistHasMore) return;
    if (_isLoadingMoreYtPlaylistSongs) return;

    final playlistId = _selectedYtLibraryPlaylist!.playlistId;
    final token = _ytActivePlaylistContinuationToken?.trim();
    if (token == null || token.isEmpty) {
      _ytActivePlaylistHasMore = false;
      return;
    }

    final loadGeneration = _ytPlaylistSongsLoadGeneration;
    setState(() {
      _isLoadingMoreYtPlaylistSongs = true;
    });

    try {
      final page = await yt_service.getPlaylistSongsPage(
        playlistId,
        continuationToken: token,
        limit: 100,
      );
      if (!_isYtPlaylistSongLoadActive(
        generation: loadGeneration,
        playlistId: playlistId,
      )) {
        return;
      }

      final tracks =
          (page['results'] as List?)
              ?.whereType<yt_service.YtMusicResult>()
              .toList() ??
          <yt_service.YtMusicResult>[];
      final mapped = _mapYtTracksToStreamingItems(tracks);
      final nextToken = page['continuationToken']?.toString().trim();
      final existingRawPaths = _originalPlaylistStreamingItems
          .map((e) => e.rawPath)
          .toSet();
      final deduped = mapped
          .where((item) => !existingRawPaths.contains(item.rawPath))
          .toList();

      _originalPlaylistStreamingItems.addAll(deduped);
      _ytPlaylistItemsCache[playlistId] = List.from(
        _originalPlaylistStreamingItems,
      );
      _ytActivePlaylistContinuationToken =
          (nextToken != null && nextToken.isNotEmpty) ? nextToken : null;
      _ytActivePlaylistHasMore = _ytActivePlaylistContinuationToken != null;
      _ytPlaylistContinuationTokenCache[playlistId] =
          _ytActivePlaylistContinuationToken;

      await _ordenarCanciones();
      if (!mounted) return;
      setState(() {
        _isLoadingMoreYtPlaylistSongs = false;
      });
      _ytUiLog(
        '_loadMoreYtPlaylistSongsIfNeeded done: added=${deduped.length}, total=${_originalPlaylistStreamingItems.length}, hasMore=$_ytActivePlaylistHasMore',
      );
    } catch (e) {
      _ytUiLog('_loadMoreYtPlaylistSongsIfNeeded error: $e');
      if (!mounted) return;
      setState(() {
        _isLoadingMoreYtPlaylistSongs = false;
      });
    }
  }

  /// Cargar las canciones de una playlist seleccionada
  Future<void> _loadSongsFromPlaylist(hive_model.PlaylistModel playlist) async {
    if (!mounted) return;
    _invalidateYtPlaylistSongLoads('open-local-playlist:${playlist.id}');
    setState(() {
      _selectedPlaylist = playlist;
      _selectedYtLibraryPlaylist = null;
      carpetaSeleccionada = '__PLAYLIST__${playlist.id}';
      _searchController.clear();
      _isSelecting = false;
      _selectedSongPaths.clear();
      _originalSongs = [];
      _filteredSongs = [];
      _displaySongs = [];
      _playlistStreamingItems = [];
      _filteredPlaylistStreamingItems = [];
      _isLoading = true;
    });

    // Actualizar los notifiers con los valores actuales del audioHandler
    if (audioHandler?.mediaItem.valueOrNull != null) {
      _mediaItemDebounce?.cancel();
      _currentMediaItemNotifier.value = audioHandler!.mediaItem.valueOrNull;
    }
    if (audioHandler?.playbackState.valueOrNull != null) {
      _isPlayingNotifier.value =
          audioHandler!.playbackState.valueOrNull!.playing;
    }

    // Obtener las canciones de la playlist
    final songs = await PlaylistsDB().getSongsFromPlaylist(playlist.id);
    final streamingItems = <_StreamingPlaylistItem>[];
    for (final path in playlist.songPaths) {
      if (!_isStreamingPath(path)) continue;
      final meta = await PlaylistsDB().getPlaylistSongMeta(playlist.id, path);
      final metaVideoId = meta?['videoId']?.toString().trim();
      final videoId = (metaVideoId != null && metaVideoId.isNotEmpty)
          ? metaVideoId
          : _extractVideoIdFromPath(path);
      final metaTitle = meta?['title']?.toString().trim();
      final metaArtist = meta?['artist']?.toString().trim();
      final metaArtUri = meta?['artUri']?.toString().trim();
      final resolvedMetaArtUri = _applyStreamingArtworkQuality(
        metaArtUri,
        videoId: videoId,
      );
      final metaDurationText = meta?['durationText']?.toString().trim();
      final metaDurationMs = _parseDurationMs(meta?['durationMs']);
      final durationText =
          (metaDurationText != null && metaDurationText.isNotEmpty)
          ? metaDurationText
          : (metaDurationMs != null && metaDurationMs > 0)
          ? _formatDurationMs(metaDurationMs)
          : null;

      streamingItems.add(
        _StreamingPlaylistItem(
          rawPath: path,
          title: (metaTitle != null && metaTitle.isNotEmpty)
              ? metaTitle
              : (videoId != null && videoId.isNotEmpty)
              ? 'YouTube Music ($videoId)'
              : path,
          artist: (metaArtist != null && metaArtist.isNotEmpty)
              ? metaArtist
              : LocaleProvider.tr('artist_unknown'),
          videoId: videoId,
          artUri: resolvedMetaArtUri,
          durationText: durationText,
          durationMs: metaDurationMs,
        ),
      );
    }

    if (!mounted) return;

    // Ordenar según las preferencias guardadas
    List<SongModel> songsToShow = songs;
    _originalSongs = List.from(songs);
    _filteredSongs = songsToShow;
    _displaySongs = songsToShow;
    _originalPlaylistStreamingItems = List.from(streamingItems);
    _playlistStreamingItems = streamingItems;
    _filteredPlaylistStreamingItems = [];

    // Reaplicar el orden activo (local o streaming) y sincronizar listas visibles.
    await _ordenarCanciones();

    // Precargar artworks
    unawaited(_preloadArtworksForSongs(songsToShow));
    if (!mounted) return;
    setState(() {
      _isLoading = false;
    });
    unawaited(_saveLastViewPrefs());
  }

  /// Mostrar el modal de selección de vista (Carpetas o Todas)
  void _showViewSelectorModal() {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showModalBottomSheet(
      context: context,
      backgroundColor: isAmoled && isDark
          ? Colors.black
          : Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Indicador de arrastre
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: isAmoled && isDark
                        ? Colors.white.withValues(alpha: 0.3)
                        : Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // Opción: Carpetas
                ListTile(
                  leading: Icon(
                    Icons.folder_outlined,
                    color: !_showAllSongs && !_showPlaylists
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                  title: TranslatedText(
                    'folders_title',
                    style: TextStyle(
                      fontWeight: !_showAllSongs && !_showPlaylists
                          ? FontWeight.w600
                          : FontWeight.normal,
                      color: !_showAllSongs && !_showPlaylists
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                  ),
                  trailing: !_showAllSongs && !_showPlaylists
                      ? Icon(
                          Icons.check,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                  onTap: () async {
                    Navigator.pop(context);
                    if (_showAllSongs || _showPlaylists) {
                      _invalidateYtPlaylistSongLoads(
                        'view-selector-open-folders',
                      );
                      setState(() {
                        _showAllSongs = false;
                        _showPlaylists = false;
                        _selectedPlaylist = null;
                        _selectedYtLibraryPlaylist = null;
                        carpetaSeleccionada = null;
                        _searchController.clear();
                        _filteredSongs.clear();
                        _displaySongs.clear();
                        _isSelecting = false;
                        _selectedSongPaths.clear();
                      });
                      await _saveLastViewPrefs();
                      // Recargar las carpetas para mostrar las ignoradas también
                      await cargarCanciones(forceIndex: false);
                    }
                  },
                ),
                // Opción: Todas
                ListTile(
                  leading: Icon(
                    Icons.library_music_outlined,
                    color: _showAllSongs
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                  title: TranslatedText(
                    'all_songs',
                    style: TextStyle(
                      fontWeight: _showAllSongs
                          ? FontWeight.w600
                          : FontWeight.normal,
                      color: _showAllSongs
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                  ),
                  trailing: _showAllSongs
                      ? Icon(
                          Icons.check,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                  onTap: () async {
                    Navigator.pop(context);
                    if (!_showAllSongs) {
                      await _loadAllSongs();
                    }
                  },
                ),
                // Opción: Listas de reproducción
                ListTile(
                  leading: Icon(
                    Icons.queue_music_outlined,
                    color: _showPlaylists
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                  title: TranslatedText(
                    'playlists',
                    style: TextStyle(
                      fontWeight: _showPlaylists
                          ? FontWeight.w600
                          : FontWeight.normal,
                      color: _showPlaylists
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                  ),
                  trailing: _showPlaylists
                      ? Icon(
                          Icons.check,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                  onTap: () async {
                    Navigator.pop(context);
                    if (!_showPlaylists) {
                      await _loadPlaylists();
                    }
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // Soporte para pop interno desde el handler global
  bool canPopInternally() {
    // Si estamos mostrando todas las canciones, no hay pop interno
    // (el botón back del sistema debe salir de la pantalla, no volver a carpetas)
    if (_showAllSongs) return false;
    // Si estamos en la lista de playlists (sin playlist seleccionada), no hay pop interno
    if (_showPlaylists && !_hasSelectedPlaylist) return false;
    // Si hay una playlist seleccionada, hay pop interno (volver a lista de playlists)
    if (_hasSelectedPlaylist) return true;
    return carpetaSeleccionada != null;
  }

  void handleInternalPop() {
    if (!mounted) return;

    // Si hay una playlist seleccionada, volver a la lista de playlists
    if (_hasSelectedPlaylist) {
      _invalidateYtPlaylistSongLoads('internal-pop-from-playlist-detail');
      setState(() {
        _selectedPlaylist = null;
        _selectedYtLibraryPlaylist = null;
        carpetaSeleccionada = null;
        _searchController.clear();
        _filteredSongs.clear();
        _displaySongs.clear();
        _isSelecting = false;
        _selectedSongPaths.clear();
      });
      _loadPlaylists();
      return;
    }

    _invalidateYtPlaylistSongLoads('internal-pop-to-folders');
    setState(() {
      carpetaSeleccionada = null;
      _showAllSongs = false;
      _showPlaylists = false;
      _selectedPlaylist = null;
      _selectedYtLibraryPlaylist = null;
    });
    unawaited(_saveLastViewPrefs());
    // Recargar la lista de carpetas para mostrar el estado actual
    cargarCanciones(forceIndex: false);
  }

  // Función para mostrar el selector de carpetas
  Future<void> _showFolderSelector(
    SongModel song, {
    required bool isMove,
  }) async {
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
        isMove
            ? 'No hay otras carpetas disponibles para mover la canción.'
            : 'No hay carpetas disponibles para copiar la canción.',
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
                      color: Theme.of(
                        context,
                      ).dividerColor.withValues(alpha: 0.1),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      isMove ? Icons.drive_file_move : Icons.copy,
                      color: Theme.of(
                        context,
                      ).colorScheme.inverseSurface.withValues(alpha: 0.95),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        isMove
                            ? LocaleProvider.tr('move_song')
                            : LocaleProvider.tr('copy_song'),
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
  Future<void> _moveSongToFolder(
    SongModel song,
    String destinationFolder,
  ) async {
    // Mostrar diálogo de carga
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return PopScope(
          canPop: false,
          child: AlertDialog(
            backgroundColor: isAmoled && isDark
                ? Colors.black
                : Theme.of(context).colorScheme.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
              side: isAmoled && isDark
                  ? const BorderSide(color: Colors.white24, width: 1)
                  : BorderSide.none,
            ),
            contentPadding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(width: 40, height: 40, child: LoadingIndicator()),
                const SizedBox(height: 24),
                Text(
                  LocaleProvider.tr('moving_song'),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                  ),
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
        _showMessage(
          LocaleProvider.tr('error_moving_song'),
          description: LocaleProvider.tr('file_already_exists'),
          isError: true,
        );
        return;
      }

      // Verificar que la carpeta de destino existe y es accesible
      final destinationDir = Directory(destinationFolder);

      if (!await destinationDir.exists()) {
        if (mounted) Navigator.of(context).pop(); // Cerrar diálogo
        _showMessage(
          'La carpeta de destino no existe o no es accesible.\n\nRuta: $destinationFolder',
          isError: true,
        );
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
        await OnAudioQuery().scanMedia(song.data);
      } catch (_) {}

      // Actualizar el archivo nuevo en el sistema de medios de Android
      await OnAudioQuery().scanMedia(destinationPath);

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
        description:
            '${LocaleProvider.tr('error_moving_song_desc')}\n\nError: ${e.toString()}',
        isError: true,
      );
    }
  }

  // Función para copiar una canción a otra carpeta
  Future<void> _copySongToFolder(
    SongModel song,
    String destinationFolder,
  ) async {
    // Mostrar diálogo de carga
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return PopScope(
          canPop: false,
          child: AlertDialog(
            backgroundColor: isAmoled && isDark
                ? Colors.black
                : Theme.of(context).colorScheme.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
              side: isAmoled && isDark
                  ? const BorderSide(color: Colors.white24, width: 1)
                  : BorderSide.none,
            ),
            contentPadding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(width: 40, height: 40, child: LoadingIndicator()),
                const SizedBox(height: 24),
                Text(
                  LocaleProvider.tr('copying_song'),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                  ),
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
        _showMessage(
          LocaleProvider.tr('error_copying_song'),
          description: LocaleProvider.tr('file_already_exists'),
          isError: true,
        );
        return;
      }

      // Verificar que la carpeta de destino existe y es accesible
      final destinationDir = Directory(destinationFolder);

      if (!await destinationDir.exists()) {
        if (mounted) Navigator.of(context).pop(); // Cerrar diálogo
        _showMessage(
          'La carpeta de destino no existe o no es accesible.\n\nRuta: $destinationFolder',
          isError: true,
        );
        return;
      }

      // Copiar el archivo
      await sourceFile.copy(destinationPath);

      // Verificar que la copia fue exitosa
      if (!await destinationFile.exists()) {
        throw Exception('La copia no se completó correctamente');
      }

      // Actualizar el archivo nuevo en el sistema de medios de Android
      await OnAudioQuery().scanMedia(destinationPath);

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
        description:
            '${LocaleProvider.tr('error_copying_song_desc')}\n\nError: ${e.toString()}',
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
        description:
            'Puede haber problemas con los permisos de archivos. Error: ${e.toString()}',
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
              backgroundColor: isAmoled && isDark
                  ? Colors.black
                  : Theme.of(context).colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white24, width: 1)
                    : BorderSide.none,
              ),
              contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
              icon: Icon(
                isError
                    ? Icons.error_outline_rounded
                    : Icons.check_circle_outline_rounded,
                size: 32,
                color: isError
                    ? Theme.of(context).colorScheme.error
                    : Theme.of(context).colorScheme.onSurface,
              ),
              title: Text(
                title,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
              content: description != null
                  ? Text(
                      description,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    )
                  : null,
              actionsPadding: const EdgeInsets.all(16),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(
                    LocaleProvider.tr('ok'),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ],
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

  void _showFolderOptionsModal(
    BuildContext context,
    String folderKey,
    String folderName,
    bool isIgnored,
  ) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurfaceVariant.withAlpha(100),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 24),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: TranslatedText(
                  'rename_folder',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                onTap: () async {
                  Navigator.of(context).pop();
                  await _showRenameFolderDialog(folderKey, folderName);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: TranslatedText(
                  'delete_folder',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                onTap: () async {
                  Navigator.of(context).pop();
                  await _showDeleteFolderConfirmation(folderKey, folderName);
                },
              ),
              ListTile(
                leading: Icon(
                  isIgnored
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                title: TranslatedText(
                  isIgnored ? 'unignore_folder' : 'ignore_folder',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                onTap: () async {
                  Navigator.of(context).pop();
                  if (isIgnored) {
                    await _unignoreFolderFlow(folderKey);
                  } else {
                    await _ignoreFolderFlow(folderKey);
                  }
                },
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }
}
