import 'dart:ui';

import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:music/main.dart';
import 'package:music/utils/yt_search/service.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/simple_yt_download.dart';
import 'package:music/utils/yt_search/search_history.dart';
import 'package:music/utils/yt_search/suggestions_widget.dart';
import 'package:file_selector/file_selector.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:music/utils/yt_search/stream_provider.dart';
import 'package:image/image.dart' as img;
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:dio/dio.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:music/utils/notification_service.dart';
import 'package:music/widgets/image_viewer.dart';
import 'package:music/screens/artist/artist_screen.dart';
import 'package:music/screens/download/download_history_screen.dart';
import 'package:music/utils/db/favorites_db.dart';
import 'package:music/utils/db/playlists_db.dart';
import 'package:music/utils/db/playlist_model.dart' as hive_model;
import 'package:music/utils/db/songs_index_db.dart';
import 'package:music/utils/song_info_dialog.dart';
import 'package:music/widgets/artwork_list_tile.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:buttons_tabbar/buttons_tabbar.dart';
import 'package:material_loading_indicator/loading_indicator.dart';
import 'package:open_settings_plus/open_settings_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:io';

// Top-level function para usar con compute
Uint8List? decodeAndCropImage(Uint8List bytes) {
  final original = img.decodeImage(bytes);
  if (original != null) {
    final minSide = original.width < original.height
        ? original.width
        : original.height;
    final offsetX = (original.width - minSide) ~/ 2;
    final offsetY = (original.height - minSide) ~/ 2;
    final square = img.copyCrop(
      original,
      x: offsetX,
      y: offsetY,
      width: minSide,
      height: minSide,
    );
    return Uint8List.fromList(img.encodeJpg(square));
  }
  return null;
}

// Top-level function para recortar imágenes hqdefault (elimina franjas negras)
Uint8List? decodeAndCropImageHQ(Uint8List bytes) {
  final original = img.decodeImage(bytes);
  if (original != null) {
    // Para hqdefault (480x360), el contenido real está en el centro
    // Las franjas negras están arriba y abajo
    final width = original.width;
    final height = original.height;

    // Calcular el área de contenido real (aproximadamente 75% del centro - menos agresivo)
    final contentHeight = (height * 0.75).round();
    final offsetY = (height - contentHeight) ~/ 2;

    // Crear un cuadrado del área de contenido
    final minSide = width < contentHeight ? width : contentHeight;
    final offsetX = (width - minSide) ~/ 2;

    final square = img.copyCrop(
      original,
      x: offsetX,
      y: offsetY,
      width: minSide,
      height: minSide,
    );
    return Uint8List.fromList(img.encodeJpg(square));
  }
  return null;
}

String _formatDurationFromMilliseconds(int durationMs) {
  final duration = Duration(milliseconds: durationMs);
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:$seconds';
  }
  return '$minutes:$seconds';
}

int? _parseDurationTextToMilliseconds(String? text) {
  final value = text?.trim();
  if (value == null || value.isEmpty) return null;

  final parts = value.split(':');
  if (parts.isEmpty || parts.length > 3) return null;

  int totalSeconds = 0;
  for (final part in parts) {
    final parsed = int.tryParse(part.trim());
    if (parsed == null) return null;
    totalSeconds = totalSeconds * 60 + parsed;
  }

  if (totalSeconds <= 0) return null;
  return totalSeconds * 1000;
}

String _artistWithDurationText({
  String? artist,
  String? fallbackArtist,
  String? durationText,
  int? durationMs,
}) {
  final artistText = artist?.trim();
  final fallbackText = fallbackArtist?.trim();
  final baseArtist = (artistText != null && artistText.isNotEmpty)
      ? artistText
      : (fallbackText != null && fallbackText.isNotEmpty)
      ? fallbackText
      : LocaleProvider.tr('artist_unknown');

  final normalizedDurationText = durationText?.trim();
  if (normalizedDurationText != null && normalizedDurationText.isNotEmpty) {
    return '$baseArtist • $normalizedDurationText';
  }

  if (durationMs != null && durationMs > 0) {
    return '$baseArtist • ${_formatDurationFromMilliseconds(durationMs)}';
  }

  return baseArtist;
}

class TabItem {
  final String label;
  final String?
  id; // 'songs', 'videos', 'playlists', 'albums' or null for results
  TabItem(this.label, this.id);
}

class _YtStreamingArtwork extends StatefulWidget {
  final List<String> sources;
  final Color backgroundColor;
  final Color iconColor;

  const _YtStreamingArtwork({
    required this.sources,
    required this.backgroundColor,
    required this.iconColor,
  });

  @override
  State<_YtStreamingArtwork> createState() => _YtStreamingArtworkState();
}

class _YtStreamingArtworkState extends State<_YtStreamingArtwork> {
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

class YtSearchTestScreen extends StatefulWidget {
  final String? initialQuery;
  const YtSearchTestScreen({super.key, this.initialQuery});

  @override
  State<YtSearchTestScreen> createState() => _YtSearchTestScreenState();
}

// Caché global para imágenes procesadas
final Map<String, Uint8List> _imageCache = {};

class _YtSearchTestScreenState extends State<YtSearchTestScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  late TabController _tabController;
  List<TabItem> _tabs = [];
  List<YtMusicResult> _songResults = [];
  List<YtMusicResult> _videoResults = [];
  List<dynamic> _albumResults = [];
  List<Map<String, String>> _playlistResults = [];
  List<Map<String, dynamic>> _artistResults = [];
  String? _expandedCategory; // 'songs', 'videos', 'album', 'playlists', o null
  bool _loading = false;
  String? _error;
  double _lastViewInset = 0;
  bool _hasSearched = false;
  bool _showSuggestions = false;
  bool _noInternet = false; // Nuevo estado para internet
  bool _loadingMoreSongs = false;
  bool _loadingMoreVideos = false;
  bool _loadingMorePlaylists = false;
  List<YtMusicResult> _albumSongs = [];
  Map<String, dynamic>? _currentAlbum;
  bool _loadingAlbumSongs = false;
  List<YtMusicResult> _playlistSongs = [];
  Map<String, dynamic>? _currentPlaylist;
  bool _loadingPlaylistSongs = false;

  // Variables para manejar enlaces de YouTube
  bool _isUrlSearch = false;
  Video? _urlVideoResult;
  bool _loadingUrlVideo = false;
  String? _urlVideoError;

  // Variables para manejar playlists de YouTube
  bool _isUrlPlaylistSearch = false;
  List<YtMusicResult> _urlPlaylistVideos = [];
  String? _urlPlaylistTitle;
  String? _urlPlaylistThumb;
  bool _loadingUrlPlaylist = false;
  String? _urlPlaylistError;

  // ValueNotifiers para el progreso de descarga
  final ValueNotifier<double> downloadProgressNotifier = ValueNotifier(0.0);
  final ValueNotifier<bool> isDownloadingNotifier = ValueNotifier(false);
  final ValueNotifier<bool> isProcessingNotifier = ValueNotifier(false);
  final ValueNotifier<int> queueLengthNotifier = ValueNotifier(0);

  // Estado para selección múltiple
  final Set<String> _selectedIndexes = {};
  bool _isSelectionMode = false;
  int _searchSessionId = 0;
  final Map<String, String> _resolvedLh3ThumbByVideoId = {};

  // ScrollControllers para paginación incremental
  final ScrollController _songScrollController = ScrollController();
  final ScrollController _videoScrollController = ScrollController();
  final ScrollController _playlistScrollController = ScrollController();
  final ScrollController _tabScrollController = ScrollController();
  int _songPage = 1;
  int _videoPage = 1;
  int _playlistPage = 1;
  bool _hasMoreSongs = true;
  bool _hasMoreVideos = true;
  bool _hasMorePlaylists = true;

  Future<List<YtMusicResult>> _searchVideosOnly(String query) async {
    return searchVideosWithPagination(query, maxPages: 1);
  }

  Future<void> _search() async {
    if (_controller.text.trim().isEmpty) {
      return;
    }

    // Verificar si es un enlace de playlist de YouTube
    if (_isYouTubePlaylistUrl(_controller.text)) {
      _focusNode.unfocus();
      await _processUrlPlaylist(_controller.text);
      return;
    }

    // Verificar si es un enlace de video de YouTube
    if (_isYouTubeUrl(_controller.text)) {
      _focusNode.unfocus();
      await _processUrlVideo(_controller.text);
      return;
    }

    // Salir de la vista expandida al hacer una nueva búsqueda
    if (_expandedCategory != null) {
      setState(() {
        _expandedCategory = null;
        _tabController.index = 0;
      });
    }
    setState(() {
      _selectedIndexes.clear();
      _isSelectionMode = false;
      _noInternet = false;
      _songResults = [];
      _videoResults = [];
      _albumResults = [];
      _playlistResults = [];
      _artistResults = [];
      _albumSongs = [];
      _currentAlbum = null;
      _playlistSongs = [];
      _currentPlaylist = null;
      _songPage = 1;
      _videoPage = 1;
      _playlistPage = 1;
      _hasMoreSongs = true;
      _hasMoreVideos = true;
      _hasMorePlaylists = true;
      _loadingMoreSongs = true;
      _loadingMoreVideos = true;
      _loadingMorePlaylists = true;
      _searchSessionId++;
    });
    final List<ConnectivityResult> connectivityResult = await Connectivity()
        .checkConnectivity();
    if (connectivityResult.contains(ConnectivityResult.none)) {
      if (mounted) {
        setState(() {
          _noInternet = true;
          _loading = false;
          _songResults = [];
          _videoResults = [];
          _albumResults = [];
          _playlistResults = [];
          _artistResults = [];
          _albumSongs = [];
          _currentAlbum = null;
          _playlistSongs = [];
          _currentPlaylist = null;
          _hasSearched = false;
        });
      }
      return;
    }
    _focusNode.unfocus();
    await SearchHistory.addToHistory(_controller.text.trim());
    setState(() {
      _loading = true;
      _songResults = [];
      _videoResults = [];
      _albumResults = [];
      _playlistResults = [];
      _artistResults = [];
      _albumSongs = [];
      _currentAlbum = null;
      _playlistSongs = [];
      _currentPlaylist = null;
      _error = null;
      _hasSearched = true;
      _loadingMoreSongs = false;
      _loadingMoreVideos = false;
      _loadingMorePlaylists = false;
      _showSuggestions = false;
    });
    try {
      // 1. Obtener los primeros 20 resultados rápidamente
      final songFuture = searchSongsOnly(_controller.text);
      final videoFuture = _searchVideosOnly(_controller.text);
      final albumFuture = searchAlbumsOnly(_controller.text);
      final playlistFuture = searchPlaylistsOnly(_controller.text);
      final artistFuture = searchArtists(_controller.text, limit: 10);
      final results = await Future.wait([
        songFuture,
        videoFuture,
        albumFuture,
        playlistFuture,
        artistFuture,
      ]);
      if (!mounted) return;
      setState(() {
        _songResults = (results[0] as List).cast<YtMusicResult>();
        _videoResults = (results[1] as List).cast<YtMusicResult>();
        _albumResults = (results[2] as List); // No cast<YtMusicResult> aquí
        _playlistResults = (results[3] as List).cast<Map<String, String>>();
        _artistResults = (results[4] as List).cast<Map<String, dynamic>>();
        // print('Álbumes encontrados:  [32m${_albumResults.length} [0m');
        _loading = false;
        _updateTabs();
      });
      // 2. En segundo plano, cargar más resultados (hasta 100)
      // Para canciones
      searchSongsWithPagination(_controller.text, maxPages: 5).then((
        moreSongs,
      ) {
        if (!mounted) return;
        setState(() {
          final existingIds = _songResults.map((e) => e.videoId).toSet();
          final newOnes = moreSongs
              .where((e) => !existingIds.contains(e.videoId))
              .toList();
          _songResults.addAll(newOnes);
          _loadingMoreSongs = false;
        });
      });
      // Para videos: si tienes paginación, implementa aquí la llamada extendida
      searchVideosWithPagination(_controller.text, maxPages: 5).then((
        moreVideos,
      ) {
        if (!mounted) return;
        setState(() {
          _mergeVideoResultsInPlace(moreVideos);
          _loadingMoreVideos = false;
        });
      });
      // Para listas de reproducción
      searchPlaylistsWithPagination(_controller.text, maxPages: 5).then((
        morePlaylists,
      ) {
        if (!mounted) return;
        setState(() {
          final existingIds = _playlistResults
              .map((e) => e['browseId'])
              .toSet();
          final newOnes = morePlaylists
              .where((e) => !existingIds.contains(e['browseId']))
              .toList();
          _playlistResults.addAll(newOnes);
          _loadingMorePlaylists = false;
        });
      });
      // Para álbumes: (puedes agregar paginación extendida aquí si lo deseas)
    } catch (e) {
      if (e is DioException) {
        if (mounted) {
          setState(() {
            _noInternet = true;
            _loading = false;
            _songResults = [];
            _videoResults = [];
            _albumResults = [];
            _artistResults = [];
            _hasSearched = false;
            _error = null;
          });
        }
      } else {
        setState(() {
          _error = 'Error: $e';
          _loading = false;
        });
      }
      setState(() {
        _loadingMoreSongs = false;
        _loadingMoreVideos = false;
        _albumResults = [];
      });
    }
  }

  void _animateToCategory(String categoryId) {
    final index = _tabs.indexWhere((t) => t.id == categoryId);
    if (index != -1) {
      _tabController.animateTo(index);
    }
  }

  void _handleTabSelection() {
    if (mounted) {
      setState(() {
        if (_tabController.index >= 0 && _tabController.index < _tabs.length) {
          _expandedCategory = _tabs[_tabController.index].id;
        } else {
          _expandedCategory = null;
        }
      });
    }
  }

  void _updateTabs() {
    final List<TabItem> newTabs = [TabItem(LocaleProvider.tr('results'), null)];

    if (_songResults.isNotEmpty) {
      newTabs.add(TabItem(LocaleProvider.tr('songs_search'), 'songs'));
    }
    if (_videoResults.isNotEmpty) {
      newTabs.add(TabItem(LocaleProvider.tr('videos'), 'videos'));
    }
    if (_playlistResults.isNotEmpty) {
      newTabs.add(TabItem(LocaleProvider.tr('playlists'), 'playlists'));
    }
    if (_albumResults.isNotEmpty) {
      newTabs.add(TabItem(LocaleProvider.tr('albums'), 'albums'));
    }

    // Check if tabs have changed
    bool changed = false;
    if (newTabs.length != _tabs.length) {
      changed = true;
    } else {
      for (int i = 0; i < newTabs.length; i++) {
        if (newTabs[i].id != _tabs[i].id) {
          changed = true;
          break;
        }
      }
    }

    if (changed) {
      final oldController = _tabController;
      oldController.removeListener(_handleTabSelection);

      // Defer unnecessary rebuilds during controller switch
      // We create the new controller immediately so the build method uses it
      _tabs = newTabs;
      _tabController = TabController(length: _tabs.length, vsync: this);
      _tabController.addListener(_handleTabSelection);
      // Reset to first tab
      _tabController.index = 0;
      _expandedCategory = null;

      // Dispose the old controller only after the frame is done to avoid
      // "Null check operator used on a null value" errors in ButtonsTabBar
      // which might try to remove listeners from the disposed controller.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        oldController.dispose();
      });
    }
  }

  void _handleFocusChange() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    _tabs = [
      TabItem(LocaleProvider.tr('results'), null),
      TabItem(LocaleProvider.tr('songs_search'), 'songs'),
      TabItem(LocaleProvider.tr('videos'), 'videos'),
      TabItem(LocaleProvider.tr('playlists'), 'playlists'),
      TabItem(LocaleProvider.tr('albums'), 'albums'),
    ];
    _tabController = TabController(length: _tabs.length, vsync: this);
    _tabController.addListener(_handleTabSelection);
    WidgetsBinding.instance.addObserver(this);

    // Mostrar sugerencias por defecto
    _showSuggestions = true;

    _focusNode.addListener(_handleFocusChange);
    focusYtSearchNotifier.addListener(_handleFocusYtSearchRequest);

    // Si llegamos a esta pantalla con el notifier ya en true (ej. desde barra de home)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && focusYtSearchNotifier.value) {
        focusYtSearchNotifier.value = false;
        Future.delayed(const Duration(milliseconds: 200), () {
          if (mounted) _focusNode.requestFocus();
        });
      }
    });

    _songScrollController.addListener(() {
      if (_expandedCategory == 'songs' &&
          !_loadingMoreSongs &&
          _songScrollController.position.pixels >=
              _songScrollController.position.maxScrollExtent - 10) {
        _loadMoreSongs();
      }
    });
    _videoScrollController.addListener(() {
      if (_expandedCategory == 'videos' &&
          !_loadingMoreVideos &&
          _videoScrollController.position.pixels >=
              _videoScrollController.position.maxScrollExtent - 10) {
        _loadMoreVideos();
      }
    });
    _playlistScrollController.addListener(() {
      if (_expandedCategory == 'playlists' &&
          !_loadingMorePlaylists &&
          _playlistScrollController.position.pixels >=
              _playlistScrollController.position.maxScrollExtent - 10) {
        _loadMorePlaylists();
      }
    });

    // Verificar si hay historial

    // Configurar la cola de descargas
    _setupDownloadQueue();

    if (widget.initialQuery != null && widget.initialQuery!.isNotEmpty) {
      _controller.text = widget.initialQuery!;
      _search();
    }
  }

  void _handleFocusYtSearchRequest() {
    if (!focusYtSearchNotifier.value) return;
    focusYtSearchNotifier.value = false;
    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    focusYtSearchNotifier.removeListener(_handleFocusYtSearchRequest);
    WidgetsBinding.instance.removeObserver(this);
    _tabController.removeListener(_handleTabSelection);
    _tabController.dispose();
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    downloadProgressNotifier.dispose();
    isDownloadingNotifier.dispose();
    isProcessingNotifier.dispose();
    queueLengthNotifier.dispose();
    _songScrollController.dispose();
    _videoScrollController.dispose();
    _playlistScrollController.dispose();
    _tabScrollController.dispose();
    _imageCache.clear();
    super.dispose();
  }

  // Helper para traducir/formatear el texto de audiencia/subs
  String? _formatArtistSubtitle(String? text) {
    if (text == null) return null;

    String cleanNumber(String input, String term) {
      return input
          .replaceAll(RegExp(term, caseSensitive: false), '')
          .replaceAll(RegExp(r'\s+de\s+', caseSensitive: false), '')
          .trim();
    }

    if (text.toLowerCase().contains('monthly audience')) {
      return '${LocaleProvider.tr('monthly_audience_label')} ${cleanNumber(text, 'monthly audience')}';
    }
    if (text.toLowerCase().contains('oyentes mensuales')) {
      return '${LocaleProvider.tr('monthly_audience_label')} ${cleanNumber(text, 'oyentes mensuales')}';
    }

    if (text.toLowerCase().contains('subscribers')) {
      return '${cleanNumber(text, 'subscribers')} ${LocaleProvider.tr('subscribers_label')}';
    }
    if (text.toLowerCase().contains('suscriptores')) {
      return '${cleanNumber(text, 'suscriptores')} ${LocaleProvider.tr('subscribers_label')}';
    }

    return text;
  }

  // Función helper para manejar imágenes de red de forma segura
  Widget _buildSafeNetworkImage(
    String? imageUrl, {
    double? width,
    double? height,
    BoxFit? fit,
    Widget? fallback,
  }) {
    if (imageUrl == null || imageUrl.isEmpty) {
      return fallback ?? const Icon(Icons.music_note, size: 32);
    }

    // Si ya existe la versión recortada en caché, mostrarla directamente
    if (_imageCache.containsKey(imageUrl)) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(
          _imageCache[imageUrl]!,
          width: width,
          height: height,
          fit: fit ?? BoxFit.cover,
        ),
      );
    }

    return CachedNetworkImage(
      imageUrl: imageUrl,
      httpHeaders: headers,
      width: width,
      height: height,
      fit: fit ?? BoxFit.cover,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      errorWidget: (context, url, error) {
        return fallback ?? const Icon(Icons.music_note, size: 32);
      },
      placeholder: (context, url) {
        return Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: CircularProgressIndicator(color: Colors.transparent),
          ),
        );
      },
    );
  }

  List<String> _playlistArtworkSources(YtMusicResult item) {
    final sources = <String>[];
    final rawArt = item.thumbUrl?.trim();
    if (rawArt != null && rawArt.isNotEmpty && rawArt != 'null') {
      sources.add(rawArt);
    }
    final id = item.videoId?.trim();
    if (id != null && id.isNotEmpty) {
      sources.addAll([
        'https://i.ytimg.com/vi/$id/hqdefault.jpg',
        'https://img.youtube.com/vi/$id/sddefault.jpg',
        'https://img.youtube.com/vi/$id/maxresdefault.jpg',
      ]);
    }
    return sources.toSet().toList();
  }

  bool _isStreamingPlaylistPath(String path) {
    final normalized = path.trim().toLowerCase();
    if (normalized.isEmpty) return false;
    if (normalized.startsWith('/')) return false;
    if (normalized.startsWith('file://')) return false;
    if (normalized.startsWith('content://')) return false;
    return true;
  }

  bool _playlistMatchesStreamingSource(hive_model.PlaylistModel playlist) {
    if (playlist.songPaths.isEmpty) return true;
    return playlist.songPaths.any(_isStreamingPlaylistPath);
  }

  String? _extractVideoIdFromPlaylistPath(String rawPath) {
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

  List<String> _streamingPlaylistArtworkSources(
    String playlistId,
    String path,
    Map<String, List<String>> streamingArtworkCache,
  ) {
    final cacheKey = '$playlistId::$path';
    final cached = streamingArtworkCache[cacheKey];
    if (cached != null && cached.isNotEmpty) return cached;

    final videoId = _extractVideoIdFromPlaylistPath(path);
    if (videoId == null || videoId.isEmpty) return const [];
    return [
      'https://img.youtube.com/vi/$videoId/maxresdefault.jpg',
      'https://img.youtube.com/vi/$videoId/sddefault.jpg',
      'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
    ];
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
        if (!_isStreamingPlaylistPath(path)) continue;
        final meta = await PlaylistsDB().getPlaylistSongMeta(playlist.id, path);
        final metaArtUri = meta?['artUri']?.toString().trim();
        final metaVideoId = meta?['videoId']?.toString().trim();
        final videoId = (metaVideoId != null && metaVideoId.isNotEmpty)
            ? metaVideoId
            : _extractVideoIdFromPlaylistPath(path);

        final sources = <String>[];
        if (metaArtUri != null &&
            metaArtUri.isNotEmpty &&
            metaArtUri != 'null') {
          sources.add(metaArtUri);
        }
        if (videoId != null && videoId.isNotEmpty) {
          sources.addAll([
            'https://img.youtube.com/vi/$videoId/maxresdefault.jpg',
            'https://img.youtube.com/vi/$videoId/sddefault.jpg',
            'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
          ]);
        }
        if (sources.isNotEmpty) {
          cache['${playlist.id}::$path'] = sources.toSet().toList();
        }
      }
    }
    return cache;
  }

  Widget _buildModalPlaylistArtworkGrid(
    hive_model.PlaylistModel playlist,
    List<SongModel> allSongs, {
    Map<String, List<String>> streamingArtworkCache =
        const <String, List<String>>{},
  }) {
    final filtered = playlist.songPaths
        .where((path) => path.trim().isNotEmpty)
        .toList();
    final latestPaths = filtered.reversed.take(4).toList();

    final List<Widget> artworks = latestPaths.map((path) {
      final normalizedPath = path.trim();
      if (_isStreamingPlaylistPath(normalizedPath)) {
        return _YtStreamingArtwork(
          sources: _streamingPlaylistArtworkSources(
            playlist.id,
            normalizedPath,
            streamingArtworkCache,
          ),
          backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
          iconColor: Theme.of(context).colorScheme.onSurfaceVariant,
        );
      }

      final songIndex = allSongs.indexWhere(
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
      final song = allSongs[songIndex];
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
        child: _buildPlaylistArtworkLayout(artworks),
      ),
    );
  }

  Widget _buildPlaylistArtworkLayout(List<Widget> artworks) {
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
        return Row(
          children: [
            Expanded(child: artworks[0]),
            Expanded(child: artworks[1]),
          ],
        );
      default:
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

  @override
  void didChangeMetrics() {
    final viewInsets =
        PlatformDispatcher.instance.views.first.viewInsets.bottom;
    if (_lastViewInset > 0 && viewInsets == 0) {
      // El teclado se ocultó
      _focusNode.unfocus();
    }
    _lastViewInset = viewInsets;
  }

  void _clearResults() {
    setState(() {
      _songResults = [];
      _videoResults = [];
      _artistResults = [];
      _error = null;
      _hasSearched = false;
      _loading = false;
      _loadingMoreSongs = false;
      _loadingMoreVideos = false;
      _showSuggestions = true;
      _isUrlSearch = false;
      _urlVideoResult = null;
      _loadingUrlVideo = false;
      _urlVideoError = null;
      _isUrlPlaylistSearch = false;
      _urlPlaylistVideos = [];
      _urlPlaylistTitle = null;
      _loadingUrlPlaylist = false;
      _urlPlaylistError = null;
      _tabController.index = 0;
      _controller.clear();
      _albumSongs = [];
      _currentAlbum = null;
      _playlistSongs = [];
      _currentPlaylist = null;
      _selectedIndexes.clear();
      _isSelectionMode = false;
      _searchSessionId++;
    });
    if (_tabScrollController.hasClients) {
      _tabScrollController.jumpTo(0);
    }
    _focusNode.unfocus();
  }

  // Función para detectar si el texto es un enlace de YouTube
  bool _isYouTubeUrl(String text) {
    final trimmedText = text.trim();
    return trimmedText.contains('youtube.com/watch') ||
        trimmedText.contains('youtu.be/') ||
        trimmedText.contains('youtube.com/embed/') ||
        trimmedText.contains('youtube.com/v/') ||
        trimmedText.contains('m.youtube.com/watch');
  }

  // Función para detectar si el texto es un enlace de playlist de YouTube Music
  bool _isYouTubePlaylistUrl(String text) {
    final trimmedText = text.trim();
    return trimmedText.contains('music.youtube.com/playlist') ||
        trimmedText.contains('youtube.com/playlist') ||
        trimmedText.contains('playlist?list=') ||
        (trimmedText.contains('youtube.com/watch') &&
            trimmedText.contains('list='));
  }

  // Función para extraer el ID de playlist de la URL
  String? _extractPlaylistId(String url) {
    try {
      final uri = Uri.parse(url);

      // Caso 1: URL directa de playlist
      if (uri.pathSegments.isNotEmpty &&
          uri.pathSegments[0] == "playlist" &&
          uri.queryParameters.containsKey("list")) {
        return uri.queryParameters['list'];
      }

      // Caso 2: URL de video con parámetro list (playlist)
      if (uri.queryParameters.containsKey("list")) {
        return uri.queryParameters['list'];
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  // Función mejorada para validar IDs de playlist (basada en Harmony Music)
  String _validatePlaylistId(String playlistId) {
    // Para playlists de canales (OLAK, OLAD, etc.), mantener el ID tal como está
    if (playlistId.startsWith('OLAK') ||
        playlistId.startsWith('OLAD') ||
        playlistId.startsWith('OLAT') ||
        playlistId.startsWith('OL')) {
      return playlistId;
    }
    // Para playlists regulares, remover prefijo VL si existe
    return playlistId.startsWith('VL') ? playlistId.substring(2) : playlistId;
  }

  // Función para extraer información del video desde el enlace
  Future<void> _processUrlVideo(String url) async {
    setState(() {
      _loadingUrlVideo = true;
      _urlVideoError = null;
      _isUrlSearch = true;
    });

    try {
      final yt = YoutubeExplode();
      final video = await yt.videos.get(url);
      yt.close();

      setState(() {
        _urlVideoResult = video;
        _loadingUrlVideo = false;
      });
    } catch (e) {
      setState(() {
        _urlVideoError = 'Error al procesar el enlace: ${e.toString()}';
        _loadingUrlVideo = false;
      });
    }
  }

  // Función para extraer información de la playlist desde el enlace usando el servicio existente
  Future<void> _processUrlPlaylist(String url) async {
    setState(() {
      _loadingUrlPlaylist = true;
      _urlPlaylistError = null;
      _isUrlPlaylistSearch = true;
    });

    try {
      // Extraer ID de playlist de la URL
      final playlistId = _extractPlaylistId(url);
      if (playlistId == null) {
        throw Exception('No se pudo extraer el ID de la playlist de la URL');
      }

      // Validar y normalizar el ID
      final validatedId = _validatePlaylistId(playlistId);

      // Obtener información de la playlist
      final playlistInfo = await getPlaylistInfo(validatedId);
      if (playlistInfo == null) {
        throw Exception('No se pudo obtener información de la playlist');
      }

      // Obtener todas las canciones de la playlist usando el servicio existente (sin límite)
      final allSongs = await getPlaylistSongs(
        validatedId,
      ); // Sin límite para obtener todas

      setState(() {
        _urlPlaylistTitle = playlistInfo['title'];
        _urlPlaylistThumb = playlistInfo['thumbUrl'];
        _urlPlaylistVideos = allSongs;
        _loadingUrlPlaylist = false;
      });
    } catch (e) {
      setState(() {
        _urlPlaylistError = 'Error al procesar la playlist: ${e.toString()}';
        _loadingUrlPlaylist = false;
      });
    }
  }

  // Función para construir la UI del resultado del video
  Widget _buildUrlVideoResult() {
    final isSystem = colorSchemeNotifier.value == AppColorScheme.system;
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_urlVideoResult == null) return const SizedBox.shrink();

    final video = _urlVideoResult!;
    final videoId = video.id.toString().trim();
    final artist = video.author.replaceFirst(RegExp(r' - Topic$'), '').trim();
    final fallbackThumbUrl =
        'https://img.youtube.com/vi/$videoId/maxresdefault.jpg';
    final thumbUrl = video.thumbnails.highResUrl.trim().isNotEmpty
        ? video.thumbnails.highResUrl
        : fallbackThumbUrl;
    final durationMs = video.duration?.inMilliseconds;
    final durationText = (durationMs != null && durationMs > 0)
        ? _formatDurationFromMilliseconds(durationMs)
        : null;

    final topBorderRadius = const BorderRadius.only(
      topLeft: Radius.circular(20),
      topRight: Radius.circular(20),
      bottomLeft: Radius.circular(4),
      bottomRight: Radius.circular(4),
    );

    final bottomBorderRadius = const BorderRadius.only(
      topLeft: Radius.circular(4),
      topRight: Radius.circular(4),
      bottomLeft: Radius.circular(20),
      bottomRight: Radius.circular(20),
    );

    return SingleChildScrollView(
      child: Column(
        children: [
          // Card 1: Información (Thumbnail, Título, Artista)
          Card(
            color: isDark && !isAmoled
                ? Theme.of(context).colorScheme.secondary.withValues(alpha: 0.2)
                : isAmoled
                ? Colors.white.withAlpha(40)
                : Theme.of(context).colorScheme.secondaryContainer,
            margin: EdgeInsets.zero,
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: topBorderRadius),
            child: InkWell(
              borderRadius: topBorderRadius,
              onTap: null,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: _buildSafeNetworkImage(
                        fallbackThumbUrl,
                        width: 80,
                        height: 80,
                        fit: BoxFit.cover,
                        fallback: Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            color: isSystem
                                ? Theme.of(
                                    context,
                                  ).colorScheme.secondaryContainer
                                : Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(Icons.music_video, size: 30),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _urlVideoResult!.title,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _urlVideoResult!.author.replaceFirst(
                              RegExp(r' - Topic$'),
                              '',
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          // Card 2: Acciones (Guardar / Descargar)
          Card(
            color: Theme.of(context).colorScheme.primary,
            margin: EdgeInsets.zero,
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: bottomBorderRadius),
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(4),
                      bottomLeft: Radius.circular(20),
                    ),
                    onTap: () async {
                      await showModalBottomSheet(
                        context: context,
                        backgroundColor: Colors.transparent,
                        builder: (modalContext) {
                          final isAmoled =
                              colorSchemeNotifier.value ==
                              AppColorScheme.amoled;
                          final isDark =
                              Theme.of(context).brightness == Brightness.dark;
                          final menuColor = isAmoled && isDark
                              ? Colors.black
                              : Theme.of(context).colorScheme.surface;

                          return SafeArea(
                            child: Container(
                              decoration: BoxDecoration(
                                color: menuColor,
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(28),
                                ),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const SizedBox(height: 12),
                                  Container(
                                    width: 40,
                                    height: 4,
                                    decoration: BoxDecoration(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant
                                          .withAlpha(100),
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  ListTile(
                                    leading: const Icon(
                                      Icons.favorite_outline_rounded,
                                    ),
                                    title: Text(
                                      LocaleProvider.tr('add_to_favorites'),
                                    ),
                                    onTap: () async {
                                      Navigator.of(modalContext).pop();
                                      final resolvedLh3Thumb =
                                          await _resolveLh3ThumbForVideoId(
                                            videoId,
                                            queryHint: video.title,
                                          );
                                      final preferredSaveThumb =
                                          (resolvedLh3Thumb != null &&
                                              resolvedLh3Thumb
                                                  .trim()
                                                  .isNotEmpty)
                                          ? resolvedLh3Thumb
                                          : thumbUrl;
                                      final savedThumbUrl =
                                          await _resolvedSavedThumbWithQuality(
                                            preferredSaveThumb,
                                            videoId: videoId,
                                          );
                                      final videoAsResult = YtMusicResult(
                                        title: video.title,
                                        artist: artist,
                                        thumbUrl: savedThumbUrl,
                                        videoId: videoId,
                                        durationMs: durationMs,
                                        durationText: durationText,
                                      );
                                      await _addSongToFavorites(videoAsResult);
                                      _showMessage(
                                        LocaleProvider.tr('success'),
                                        LocaleProvider.tr('added_to_favorites'),
                                      );
                                    },
                                  ),
                                  ListTile(
                                    leading: const Icon(
                                      Icons.playlist_add_rounded,
                                    ),
                                    title: Text(
                                      LocaleProvider.tr('add_to_playlist'),
                                    ),
                                    onTap: () async {
                                      Navigator.of(modalContext).pop();
                                      final resolvedLh3Thumb =
                                          await _resolveLh3ThumbForVideoId(
                                            videoId,
                                            queryHint: video.title,
                                          );
                                      final preferredSaveThumb =
                                          (resolvedLh3Thumb != null &&
                                              resolvedLh3Thumb
                                                  .trim()
                                                  .isNotEmpty)
                                          ? resolvedLh3Thumb
                                          : thumbUrl;
                                      final savedThumbUrl =
                                          await _resolvedSavedThumbWithQuality(
                                            preferredSaveThumb,
                                            videoId: videoId,
                                          );
                                      final videoAsResult = YtMusicResult(
                                        title: video.title,
                                        artist: artist,
                                        thumbUrl: savedThumbUrl,
                                        videoId: videoId,
                                        durationMs: durationMs,
                                        durationText: durationText,
                                      );
                                      await _showAddSongToPlaylistDialog(
                                        videoAsResult,
                                      );
                                    },
                                  ),
                                  const SizedBox(height: 8),
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.bookmark_add_outlined,
                            color: Theme.of(context).colorScheme.onPrimary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            LocaleProvider.tr('save'),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onPrimary,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Container(
                  width: 1,
                  height: 30,
                  color: Theme.of(context).colorScheme.onPrimary.withAlpha(80),
                ),
                Expanded(
                  child: InkWell(
                    borderRadius: const BorderRadius.only(
                      topRight: Radius.circular(4),
                      bottomRight: Radius.circular(20),
                    ),
                    onTap: () async {
                      final downloadQueue = DownloadQueue();
                      await downloadQueue.addToQueue(
                        context: context,
                        videoId: videoId,
                        title: video.title,
                        artist: artist,
                        thumbUrl: thumbUrl,
                      );
                      _showMessage(
                        LocaleProvider.tr('success'),
                        LocaleProvider.tr('download_started'),
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.download,
                            color: Theme.of(context).colorScheme.onPrimary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            LocaleProvider.tr('download'),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onPrimary,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Función para construir la UI del resultado de la playlist
  Widget _buildUrlPlaylistResult() {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    // Determine theme brightness
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_urlPlaylistVideos.isEmpty) return const SizedBox.shrink();

    return ValueListenableBuilder<bool>(
      valueListenable: overlayVisibleNotifier,
      builder: (context, overlayVisible, _) {
        final bottomPadding = MediaQuery.of(context).padding.bottom;
        final bottomSpace = (overlayVisible ? 100.0 : 0.0) + bottomPadding;
        final cardColor = isAmoled && isDark
            ? Colors.white.withAlpha(20)
            : isDark
            ? Theme.of(context).colorScheme.secondary.withValues(alpha: 0.06)
            : Theme.of(context).colorScheme.secondary.withValues(alpha: 0.07);

        return RawScrollbar(
          thumbColor: Theme.of(context).colorScheme.primary,
          thickness: 6,
          radius: const Radius.circular(8),
          interactive: true,
          padding: EdgeInsets.only(bottom: bottomSpace),
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 12,
              bottom: bottomSpace,
            ),
            itemCount: _urlPlaylistVideos.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      if (_urlPlaylistThumb != null)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: _buildSafeNetworkImage(
                            _urlPlaylistThumb,
                            width: 45,
                            height: 45,
                            fit: BoxFit.cover,
                          ),
                        )
                      else
                        Icon(
                          Icons.playlist_play,
                          size: 50,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _urlPlaylistTitle ?? 'Playlist',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 18,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '${_urlPlaylistVideos.length} ${LocaleProvider.tr('songs')}',
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary,
                          shape: BoxShape.circle,
                        ),
                        child: PopupMenuButton<String>(
                          tooltip: LocaleProvider.tr('want_more_options'),
                          padding: EdgeInsets.zero,
                          icon: Icon(
                            Icons.more_vert,
                            color: Theme.of(context).colorScheme.onPrimary,
                          ),
                          color: isAmoled
                              ? Colors.grey.shade900
                              : Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHigh,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          onSelected: (value) async {
                            if (value == 'favorites') {
                              await _addSongsToFavorites(_urlPlaylistVideos);
                            } else if (value == 'playlist') {
                              await _showAddMultipleSongsToPlaylistDialog(
                                _urlPlaylistVideos,
                              );
                            } else if (value == 'download') {
                              await _downloadSongs(_urlPlaylistVideos);
                            }
                          },
                          itemBuilder: (context) => [
                            PopupMenuItem<String>(
                              value: 'favorites',
                              child: Row(
                                children: [
                                  const Icon(Icons.favorite_outline_rounded),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      LocaleProvider.tr('add_to_favorites'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            PopupMenuItem<String>(
                              value: 'playlist',
                              child: Row(
                                children: [
                                  const Icon(Icons.playlist_add_rounded),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      LocaleProvider.tr('add_to_playlist'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            PopupMenuItem<String>(
                              value: 'download',
                              child: Row(
                                children: [
                                  const Icon(Icons.download_rounded),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(LocaleProvider.tr('download')),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }

              final songIndex = index - 1;
              final item = _urlPlaylistVideos[songIndex];
              final bool isFirst = songIndex == 0;
              final bool isLast = songIndex == _urlPlaylistVideos.length - 1;
              final bool isOnly = _urlPlaylistVideos.length == 1;

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
                  shape: RoundedRectangleBorder(borderRadius: borderRadius),
                  child: InkWell(
                    borderRadius: borderRadius,
                    onTap: null,
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 50,
                          height: 50,
                          child: _YtStreamingArtwork(
                            sources: _playlistArtworkSources(item),
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHigh,
                            iconColor: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      title: Text(
                        item.title ?? 'Sin título',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                      subtitle: Text(
                        _artistWithDurationText(
                          artist: item.artist?.replaceFirst(
                            RegExp(r' - Topic$'),
                            '',
                          ),
                          fallbackArtist: 'Unknown Artist',
                          durationText: item.durationText,
                          durationMs: item.durationMs,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
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
                        child: PopupMenuButton<String>(
                          tooltip: LocaleProvider.tr('want_more_options'),
                          padding: EdgeInsets.zero,
                          icon: const Icon(Icons.more_vert, size: 20),
                          color: isAmoled
                              ? Colors.grey.shade900
                              : Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHigh,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          onSelected: (value) async {
                            if (value == 'favorites') {
                              await _addSongToFavorites(item);
                            } else if (value == 'playlist') {
                              await _showAddSongToPlaylistDialog(item);
                            } else if (value == 'download') {
                              await _downloadSingleSong(item);
                            }
                          },
                          itemBuilder: (context) => [
                            PopupMenuItem<String>(
                              value: 'favorites',
                              child: Row(
                                children: [
                                  const Icon(Icons.favorite_outline_rounded),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      LocaleProvider.tr('add_to_favorites'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            PopupMenuItem<String>(
                              value: 'playlist',
                              child: Row(
                                children: [
                                  const Icon(Icons.playlist_add_rounded),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      LocaleProvider.tr('add_to_playlist'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            PopupMenuItem<String>(
                              value: 'download',
                              child: Row(
                                children: [
                                  const Icon(Icons.download_rounded),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(LocaleProvider.tr('download')),
                                  ),
                                ],
                              ),
                            ),
                          ],
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
  }

  // Métodos para manejar el progreso de descarga
  void _onDownloadProgress(double progress, int notificationId) {
    downloadProgressNotifier.value = progress;
    // showDownloadProgressNotification(progress * 100); // 0% a 100% durante la descarga
    DownloadNotificationThrottler().show(
      progress * 100,
      notificationId: notificationId,
    );
    // Ya no cancelamos la notificación aquí, solo cuando ambos procesos terminen
  }

  void _onDownloadStart(String title, String artist, int notificationId) {
    // Actualizar la longitud de la cola
    final downloadQueue = DownloadQueue();
    queueLengthNotifier.value = downloadQueue.queueLength;

    // Establecer el título de la canción en la notificación
    DownloadNotificationThrottler().setTitle(title);

    // Mostrar el estado de descarga
    isDownloadingNotifier.value = true;
    isProcessingNotifier.value = false;
  }

  void _onDownloadStateChange(bool isDownloading, bool isProcessing) {
    isDownloadingNotifier.value = isDownloading;
    isProcessingNotifier.value = isProcessing;

    final downloadQueue = DownloadQueue();

    if (!isDownloading && !isProcessing) {
      downloadProgressNotifier.value = 0.0;

      // Actualizar la longitud de la cola
      queueLengthNotifier.value = downloadQueue.queueLength;
      // Ya no cancelamos la notificación aquí, las notificaciones se mantienen individualmente
    }
  }

  void _onDownloadSuccess(String title, String message, int notificationId) {
    final downloadQueue = DownloadQueue();

    // Mostrar notificación de descarga completada
    showDownloadCompletedNotification(title, notificationId);

    // Solo limpiar el estado si no hay más descargas en la cola
    if (downloadQueue.queueLength == 0) {
      isDownloadingNotifier.value = false;
      isProcessingNotifier.value = false;
      downloadProgressNotifier.value = 0.0;
      // Ya no cancelamos la notificación aquí, las notificaciones se mantienen individualmente
    }

    // Actualizar la longitud de la cola
    queueLengthNotifier.value = downloadQueue.queueLength;
  }

  void _onDownloadError(String title, String message) {
    final downloadQueue = DownloadQueue();

    // Solo limpiar el estado si no hay más descargas en la cola
    if (downloadQueue.queueLength == 0) {
      isDownloadingNotifier.value = false;
      isProcessingNotifier.value = false;
      downloadProgressNotifier.value = 0.0;
      // Ya no cancelamos la notificación aquí, las notificaciones se mantienen individualmente
    }

    // Mostrar notificación de fallo para la tarea actual si corresponde
    final task = downloadQueue.currentTask;
    if (task != null) {
      showDownloadFailedNotification(task.title, task.notificationId);
    }

    // Actualizar la longitud de la cola
    queueLengthNotifier.value = downloadQueue.queueLength;
  }

  // Método para manejar cuando se agrega una descarga a la cola
  void _onDownloadAddedToQueue(String title, String artist) {
    final downloadQueue = DownloadQueue();
    queueLengthNotifier.value = downloadQueue.queueLength;

    // Establecer el título de la canción en la notificación
    DownloadNotificationThrottler().setTitle(title);

    // Si hay más de una descarga en la cola, mostrar el estado de descarga
    if (downloadQueue.queueLength > 1) {
      isDownloadingNotifier.value = true;
      isProcessingNotifier.value = false;
    }
  }

  void _onSuggestionSelected(String suggestion) {
    _controller.text = suggestion;
    _search();
  }

  void _onClearHistory() {
    setState(() {
      // El widget de sugerencias se actualizará automáticamente
    });
  }

  Future<void> _checkHistory() async {}

  // Configurar la cola de descargas
  void _setupDownloadQueue() {
    final downloadQueue = DownloadQueue();
    downloadQueue.setCallbacks(
      onProgress: _onDownloadProgress,
      onStateChange: _onDownloadStateChange,
      onSuccess: _onDownloadSuccess,
      onError: _onDownloadError,
      onDownloadStart: _onDownloadStart,
      onDownloadAddedToQueue: _onDownloadAddedToQueue,
    );

    // Actualizar el estado inicial
    queueLengthNotifier.value = downloadQueue.queueLength;
  }

  // Métodos para manejar carpetas más usadas
  Future<void> _incrementFolderUsage(String path) async {
    final prefs = await SharedPreferences.getInstance();
    Map<String, int> folderUsage = {};

    // Obtener el mapa actual de uso de carpetas
    final usageList = prefs.getStringList('folder_usage') ?? [];

    if (usageList.isNotEmpty) {
      // Convertir la lista de vuelta a un mapa
      for (int i = 0; i < usageList.length - 1; i += 2) {
        final path = usageList[i];
        final usage = int.tryParse(usageList[i + 1]) ?? 0;
        folderUsage[path] = usage;
      }
    }

    // Incrementar el contador para esta carpeta
    folderUsage[path] = (folderUsage[path] ?? 0) + 1;

    // Guardar como lista de pares key-value
    final List<String> newUsageList = [];
    folderUsage.forEach((key, value) {
      newUsageList.add(key);
      newUsageList.add(value.toString());
    });

    await prefs.setStringList('folder_usage', newUsageList);
  }

  Future<List<String>> _getMostUsedFolders() async {
    final prefs = await SharedPreferences.getInstance();
    final usageList = prefs.getStringList('folder_usage') ?? [];

    if (usageList.isEmpty) return [];

    // Convertir la lista de vuelta a un mapa
    Map<String, int> folderUsage = {};
    for (int i = 0; i < usageList.length - 1; i += 2) {
      final path = usageList[i];
      final usage = int.tryParse(usageList[i + 1]) ?? 0;
      folderUsage[path] = usage;
    }

    // Ordenar por uso (mayor a menor) y tomar las 5 más usadas
    final sortedFolders = folderUsage.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return sortedFolders.take(5).map((e) => e.key).toList();
  }

  Future<void> _selectFolder(String path) async {
    downloadDirectoryNotifier.value = path;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('download_directory', path);
    await _incrementFolderUsage(path);
  }

  Future<void> _pickDirectory() async {
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    final sdkInt = androidInfo.version.sdkInt;
    if (!mounted) return;

    // Android 9 or lower: use default Music folder
    if (sdkInt <= 28) {
      final path = '/storage/emulated/0/Music';
      downloadDirectoryNotifier.value = path;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('download_directory', path);
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (context) => ValueListenableBuilder<AppColorScheme>(
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
                    Icon(Icons.info_rounded, size: 32, color: primaryColor),
                    const SizedBox(height: 16),
                    TranslatedText(
                      'info',
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
                        LocaleProvider.tr('android_9_or_lower'),
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withAlpha(160),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Padding(
                      padding: const EdgeInsets.only(right: 24, bottom: 8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
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
        ),
      );
      return;
    }

    // Mostrar diálogo con carpetas más usadas
    await _showFolderSelectionDialog();
  }

  Future<void> _showFolderSelectionDialog() async {
    final commonFolders = await _getMostUsedFolders();

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) {
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
                      Icons.folder_special_rounded,
                      size: 32,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    const SizedBox(height: 16),
                    TranslatedText(
                      'select_common_folder',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (commonFolders.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 16,
                        ),
                        child: Text(
                          LocaleProvider.tr('no_common_folders'),
                          style: Theme.of(context).textTheme.bodyMedium,
                          textAlign: TextAlign.center,
                        ),
                      )
                    else
                      Flexible(
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: commonFolders
                                .map(
                                  (folder) => _buildFolderTile(
                                    context: context,
                                    folder: folder,
                                    isAmoled: isAmoled,
                                    isDark: isDark,
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: InkWell(
                        onTap: () async {
                          Navigator.of(context).pop();
                          await _pickNewFolder();
                        },
                        borderRadius: BorderRadius.circular(28),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 16,
                          ),
                          decoration: BoxDecoration(
                            color: isAmoled && isDark
                                ? Colors.white.withAlpha(20)
                                : Theme.of(context).colorScheme.primary,
                            borderRadius: BorderRadius.circular(28),
                            border: Border.all(
                              color: isAmoled && isDark
                                  ? Colors.white.withAlpha(40)
                                  : Theme.of(
                                      context,
                                    ).colorScheme.primary.withAlpha(40),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.folder_open_rounded,
                                color: isAmoled && isDark
                                    ? Colors.white
                                    : Theme.of(context).colorScheme.onPrimary,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  LocaleProvider.tr('choose_other_folder'),
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: isAmoled && isDark
                                        ? Colors.white
                                        : Theme.of(
                                            context,
                                          ).colorScheme.onPrimary,
                                  ),
                                ),
                              ),
                              Icon(
                                Icons.arrow_forward_ios_rounded,
                                size: 16,
                                color: isAmoled && isDark
                                    ? Colors.white
                                    : Theme.of(context).colorScheme.onPrimary,
                              ),
                            ],
                          ),
                        ),
                      ),
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

  Widget _buildFolderTile({
    required BuildContext context,
    required String folder,
    required bool isAmoled,
    required bool isDark,
  }) {
    final folderName = folder.split('/').last.isEmpty
        ? folder
        : folder.split('/').last;

    final isSelected = folder == downloadDirectoryNotifier.value;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: InkWell(
        onTap: () {
          Navigator.of(context).pop();
          _selectFolder(folder);
        },
        borderRadius: BorderRadius.circular(28),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            color: isSelected
                ? Theme.of(
                    context,
                  ).colorScheme.primary.withAlpha(isDark ? 40 : 25)
                : Colors.transparent,
            border: isSelected
                ? Border.all(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withAlpha(isDark ? 60 : 40),
                    width: 1,
                  )
                : null,
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withAlpha(20),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isSelected
                      ? Icons.check_circle_rounded
                      : Icons.folder_rounded,
                  color: Theme.of(context).colorScheme.primary,
                  size: 24,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      folderName,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.w500,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      formatFolderPath(folder),
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withAlpha(150),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (isSelected)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(
                    Icons.check_rounded,
                    color: Theme.of(context).colorScheme.primary,
                    size: 20,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickNewFolder() async {
    final String? path = await getDirectoryPath();
    if (path != null && path.isNotEmpty) {
      await _selectFolder(path);
    }
  }

  void _toggleSelection(int index, {required bool isVideo}) {
    final item = isVideo ? _videoResults[index] : _songResults[index];
    final videoId = item.videoId;
    if (videoId == null) return;
    final key = isVideo ? 'video-$videoId' : 'song-$videoId';
    setState(() {
      if (_selectedIndexes.contains(key)) {
        _selectedIndexes.remove(key);
        if (_selectedIndexes.isEmpty) _isSelectionMode = false;
      } else {
        _selectedIndexes.add(key);
        _isSelectionMode = true;
      }
    });
  }

  void _clearSelection() {
    setState(() {
      _selectedIndexes.clear();
      _isSelectionMode = false;
    });
  }

  void _selectByKey(String key) {
    setState(() {
      _selectedIndexes.add(key);
      _isSelectionMode = true;
    });
  }

  Future<void> _downloadSingleSong(YtMusicResult item) async {
    final videoId = item.videoId?.trim();
    if (videoId == null || videoId.isEmpty) return;
    final downloadQueue = DownloadQueue();
    await downloadQueue.addToQueue(
      context: context,
      videoId: videoId,
      title: item.title ?? 'Sin título',
      artist:
          item.artist?.replaceFirst(RegExp(r' - Topic$'), '') ??
          LocaleProvider.tr('artist_unknown'),
      thumbUrl: item.thumbUrl,
    );
    _showMessage(
      LocaleProvider.tr('success'),
      LocaleProvider.tr('songs_added_to_queue').replaceAll('@count', '1'),
    );
  }

  Future<void> _downloadSongs(List<YtMusicResult> items) async {
    final validItems = items
        .where((item) => item.videoId?.trim().isNotEmpty == true)
        .toList();
    if (validItems.isEmpty) return;

    final downloadQueue = DownloadQueue();
    for (final item in validItems) {
      final videoId = item.videoId!.trim();
      await downloadQueue.addToQueue(
        context: context,
        videoId: videoId,
        title: item.title ?? 'Sin título',
        artist:
            item.artist?.replaceFirst(RegExp(r' - Topic$'), '') ??
            LocaleProvider.tr('artist_unknown'),
        thumbUrl: item.thumbUrl,
      );
    }

    _showMessage(
      LocaleProvider.tr('success'),
      LocaleProvider.tr(
        'songs_added_to_queue',
      ).replaceAll('@count', validItems.length.toString()),
    );
  }

  Future<void> _addSongToQueue(YtMusicResult item) async {
    final videoId = item.videoId?.trim();
    if (videoId == null || videoId.isEmpty) return;

    if (!audioServiceReady.value || audioHandler == null) {
      await initializeAudioServiceSafely();
    }

    final title = item.title?.trim().isNotEmpty == true
        ? item.title!.trim()
        : LocaleProvider.tr('title_unknown');
    final artist = item.artist?.trim().isNotEmpty == true
        ? item.artist!.trim()
        : LocaleProvider.tr('artist_unknown');
    final artUri = item.thumbUrl?.trim().isNotEmpty == true
        ? item.thumbUrl!.trim()
        : 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';

    await audioHandler?.customAction('addYtStreamToQueue', {
      'videoId': videoId,
      'title': title,
      'artist': artist,
      'artUri': artUri,
      if (item.durationMs != null && item.durationMs! > 0)
        'durationMs': item.durationMs,
      if (item.durationText != null && item.durationText!.trim().isNotEmpty)
        'durationText': item.durationText!.trim(),
    });
  }

  Future<void> _addSongToFavorites(
    YtMusicResult item, {
    bool notifyReload = true,
  }) async {
    final videoId = item.videoId?.trim();
    if (videoId == null || videoId.isEmpty) return;
    final title = item.title?.trim().isNotEmpty == true
        ? item.title!.trim()
        : LocaleProvider.tr('title_unknown');
    final artist = item.artist?.trim().isNotEmpty == true
        ? item.artist!.trim()
        : LocaleProvider.tr('artist_unknown');
    final artUri = item.thumbUrl?.trim().isNotEmpty == true
        ? item.thumbUrl!.trim()
        : 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';
    await FavoritesDB().addFavoritePath(
      'yt:$videoId',
      title: title,
      artist: artist,
      videoId: videoId,
      artUri: artUri,
      durationText: item.durationText,
      durationMs: item.durationMs,
    );
    if (notifyReload) {
      favoritesShouldReload.value = !favoritesShouldReload.value;
    }
  }

  Future<void> _addSongsToFavorites(List<YtMusicResult> items) async {
    final itemsInDisplayOrder = <YtMusicResult>[];
    final seenVideoIds = <String>{};

    for (final item in items) {
      final videoId = item.videoId?.trim();
      if (videoId == null || videoId.isEmpty) continue;
      if (!seenVideoIds.add(videoId)) continue;
      itemsInDisplayOrder.add(item);
    }

    if (itemsInDisplayOrder.isEmpty) return;

    // Favorites se muestran en orden inverso de insercion.
    // Insertamos al reves para preservar el orden visual de arriba hacia abajo.
    for (final item in itemsInDisplayOrder.reversed) {
      await _addSongToFavorites(item, notifyReload: false);
    }

    if (seenVideoIds.isNotEmpty) {
      favoritesShouldReload.value = !favoritesShouldReload.value;
    }
  }

  Future<void> _searchSongOnYouTube(YtMusicResult item) async {
    final title = item.title?.trim() ?? '';
    if (title.isEmpty) return;
    final artist = item.artist?.replaceFirst(RegExp(r' - Topic$'), '').trim();
    var searchQuery = title;
    if (artist != null && artist.isNotEmpty) {
      searchQuery = '$artist $title';
    }
    final encodedQuery = Uri.encodeComponent(searchQuery);
    final url = Uri.parse(
      'https://www.youtube.com/results?search_query=$encodedQuery',
    );
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  Future<void> _searchSongOnYouTubeMusic(YtMusicResult item) async {
    final title = item.title?.trim() ?? '';
    if (title.isEmpty) return;
    final artist = item.artist?.replaceFirst(RegExp(r' - Topic$'), '').trim();
    var searchQuery = title;
    if (artist != null && artist.isNotEmpty) {
      searchQuery = '$artist $title';
    }
    final encodedQuery = Uri.encodeComponent(searchQuery);
    final url = Uri.parse('https://music.youtube.com/search?q=$encodedQuery');
    await launchUrl(url, mode: LaunchMode.externalApplication);
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

  Future<void> _showSongSearchOptions(YtMusicResult item) async {
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
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
                        Navigator.of(dialogContext).pop();
                        _searchSongOnYouTube(item);
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
                        Navigator.of(dialogContext).pop();
                        _searchSongOnYouTubeMusic(item);
                      },
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.only(right: 24, bottom: 8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.of(dialogContext).pop(),
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

  Future<void> _showSongInfo(YtMusicResult item) async {
    final videoId = item.videoId?.trim();
    if (videoId == null || videoId.isEmpty) return;
    final durationText = item.durationText?.trim();
    final durationMs = item.durationMs;
    final mediaItem = MediaItem(
      id: 'yt:$videoId',
      title: item.title?.trim().isNotEmpty == true
          ? item.title!.trim()
          : LocaleProvider.tr('title_unknown'),
      artist: item.artist?.trim().isNotEmpty == true
          ? item.artist!.trim()
          : LocaleProvider.tr('artist_unknown'),
      duration: (durationMs != null && durationMs > 0)
          ? Duration(milliseconds: durationMs)
          : null,
      artUri: Uri.tryParse(
        item.thumbUrl?.trim().isNotEmpty == true
            ? item.thumbUrl!.trim()
            : 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
      ),
      extras: {
        'data': 'yt:$videoId',
        'videoId': videoId,
        'isStreaming': true,
        if (durationMs != null && durationMs > 0) 'durationMs': durationMs,
        if (durationText != null && durationText.isNotEmpty)
          'durationText': durationText,
        if (item.thumbUrl?.trim().isNotEmpty == true)
          'displayArtUri': item.thumbUrl!.trim(),
      },
    );
    await SongInfoDialog.show(context, mediaItem, colorSchemeNotifier);
  }

  Future<void> _showAddSongToPlaylistDialog(YtMusicResult item) async {
    final videoId = item.videoId?.trim();
    if (videoId == null || videoId.isEmpty) return;
    final allPlaylists = (await PlaylistsDB().getAllPlaylists())
        .where(_playlistMatchesStreamingSource)
        .toList();
    final allSongs = await SongsIndexDB().getIndexedSongs();
    final playlistArtworkSourcesCache = await _buildPlaylistArtworkSourcesCache(
      allPlaylists,
    );
    final textController = TextEditingController();
    if (!mounted) return;

    final title = item.title?.trim().isNotEmpty == true
        ? item.title!.trim()
        : LocaleProvider.tr('title_unknown');
    final artist = item.artist?.trim().isNotEmpty == true
        ? item.artist!.trim()
        : LocaleProvider.tr('artist_unknown');
    final artUri = item.thumbUrl?.trim().isNotEmpty == true
        ? item.thumbUrl!.trim()
        : 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';
    final path = 'yt:$videoId';

    Future<void> addToPlaylist(String playlistId) async {
      await PlaylistsDB().addSongPathToPlaylist(
        playlistId,
        path,
        title: title,
        artist: artist,
        videoId: videoId,
        artUri: artUri,
        durationText: item.durationText,
        durationMs: item.durationMs,
      );
      playlistsShouldReload.value = !playlistsShouldReload.value;
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final barColor = isDark
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
                  if (allPlaylists.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(LocaleProvider.tr('no_playlists_yet')),
                    ),
                  if (allPlaylists.isNotEmpty)
                    Flexible(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.of(context).size.height * 0.4,
                        ),
                        child: ListView.builder(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          itemCount: allPlaylists.length,
                          itemBuilder: (context, i) {
                            final pl = allPlaylists[i];
                            return Padding(
                              padding: EdgeInsets.only(
                                bottom: i == allPlaylists.length - 1 ? 0 : 4,
                              ),
                              child: Card(
                                color: barColor,
                                margin: EdgeInsets.zero,
                                elevation: 0,
                                child: ListTile(
                                  leading: _buildModalPlaylistArtworkGrid(
                                    pl,
                                    allSongs,
                                    streamingArtworkCache:
                                        playlistArtworkSourcesCache,
                                  ),
                                  title: Text(
                                    pl.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                  onTap: () async {
                                    await addToPlaylist(pl.id);
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
                    controller: textController,
                    decoration: InputDecoration(
                      hintText: LocaleProvider.tr('new_playlist'),
                      prefixIcon: const Icon(Icons.playlist_add),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.check_rounded),
                        onPressed: () async {
                          final name = textController.text.trim();
                          if (name.isEmpty) return;
                          final playlistId = await PlaylistsDB().createPlaylist(
                            name,
                          );
                          await addToPlaylist(playlistId);
                          if (context.mounted) Navigator.of(context).pop();
                        },
                      ),
                      filled: true,
                      fillColor: barColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: (value) async {
                      final name = value.trim();
                      if (name.isEmpty) return;
                      final playlistId = await PlaylistsDB().createPlaylist(
                        name,
                      );
                      await addToPlaylist(playlistId);
                      if (context.mounted) Navigator.of(context).pop();
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

  Future<void> _showAddMultipleSongsToPlaylistDialog(
    List<YtMusicResult> items,
  ) async {
    final validItems = items
        .where((item) => item.videoId?.trim().isNotEmpty == true)
        .toList();
    if (validItems.isEmpty) return;

    final allPlaylists = (await PlaylistsDB().getAllPlaylists())
        .where(_playlistMatchesStreamingSource)
        .toList();
    final allSongs = await SongsIndexDB().getIndexedSongs();
    final playlistArtworkSourcesCache = await _buildPlaylistArtworkSourcesCache(
      allPlaylists,
    );
    if (!mounted) return;
    final textController = TextEditingController();

    Future<void> addItemsToPlaylist(String playlistId) async {
      final itemsInDisplayOrder = <YtMusicResult>[];
      final seenVideoIds = <String>{};
      for (final item in validItems) {
        final videoId = item.videoId?.trim();
        if (videoId == null || videoId.isEmpty) continue;
        if (!seenVideoIds.add(videoId)) continue;
        itemsInDisplayOrder.add(item);
      }

      for (final item in itemsInDisplayOrder) {
        final videoId = item.videoId?.trim();
        if (videoId == null || videoId.isEmpty) continue;
        await PlaylistsDB().addSongPathToPlaylist(
          playlistId,
          'yt:$videoId',
          title: item.title?.trim().isNotEmpty == true
              ? item.title!.trim()
              : LocaleProvider.tr('title_unknown'),
          artist: item.artist?.trim().isNotEmpty == true
              ? item.artist!.trim()
              : LocaleProvider.tr('artist_unknown'),
          videoId: videoId,
          artUri: item.thumbUrl?.trim().isNotEmpty == true
              ? item.thumbUrl!.trim()
              : 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
          durationText: item.durationText,
          durationMs: item.durationMs,
        );
      }
      playlistsShouldReload.value = !playlistsShouldReload.value;
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final barColor = isDark
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
                  Text(
                    LocaleProvider.tr('save_to_playlist'),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (allPlaylists.isNotEmpty)
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: allPlaylists.length,
                        itemBuilder: (context, i) {
                          final pl = allPlaylists[i];
                          return Card(
                            color: barColor,
                            margin: EdgeInsets.only(
                              bottom: i == allPlaylists.length - 1 ? 0 : 4,
                            ),
                            elevation: 0,
                            child: ListTile(
                              leading: _buildModalPlaylistArtworkGrid(
                                pl,
                                allSongs,
                                streamingArtworkCache:
                                    playlistArtworkSourcesCache,
                              ),
                              title: Text(pl.name),
                              onTap: () async {
                                await addItemsToPlaylist(pl.id);
                                if (context.mounted) {
                                  Navigator.of(context).pop();
                                }
                              },
                            ),
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: textController,
                    decoration: InputDecoration(
                      hintText: LocaleProvider.tr('new_playlist'),
                      prefixIcon: const Icon(Icons.playlist_add),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.check_rounded),
                        onPressed: () async {
                          final name = textController.text.trim();
                          if (name.isEmpty) return;
                          final playlistId = await PlaylistsDB().createPlaylist(
                            name,
                          );
                          await addItemsToPlaylist(playlistId);
                          if (context.mounted) Navigator.of(context).pop();
                        },
                      ),
                      filled: true,
                      fillColor: barColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showSongActionsModal(
    YtMusicResult item, {
    required String selectionKey,
    String? fallbackThumbUrl,
    String? fallbackArtist,
  }) async {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final title = item.title?.trim().isNotEmpty == true
        ? item.title!.trim()
        : LocaleProvider.tr('title_unknown');
    final artist = item.artist?.trim().isNotEmpty == true
        ? item.artist!.trim()
        : (fallbackArtist?.trim().isNotEmpty == true
              ? fallbackArtist!.trim()
              : LocaleProvider.tr('artist_unknown'));
    final thumb = item.thumbUrl?.trim().isNotEmpty == true
        ? item.thumbUrl!.trim()
        : (fallbackThumbUrl?.trim().isNotEmpty == true
              ? fallbackThumbUrl!.trim()
              : null);
    final videoId = item.videoId?.trim();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (modalContext) {
        return SafeArea(
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
                        child: thumb != null
                            ? _buildSafeNetworkImage(
                                thumb,
                                width: 60,
                                height: 60,
                                fit: BoxFit.cover,
                                fallback: Container(
                                  width: 60,
                                  height: 60,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainer,
                                  child: const Icon(Icons.music_note_rounded),
                                ),
                              )
                            : Container(
                                width: 60,
                                height: 60,
                                color: Theme.of(
                                  context,
                                ).colorScheme.surfaceContainer,
                                child: const Icon(Icons.music_note_rounded),
                              ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                color: isAmoled
                                    ? Colors.white.withValues(alpha: 0.85)
                                    : null,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: () async {
                          Navigator.of(modalContext).pop();
                          await _showSongSearchOptions(item);
                        },
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color:
                                Theme.of(context).brightness == Brightness.dark
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
                                      ? Theme.of(context).colorScheme.onPrimary
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
                  title: const TranslatedText('add_to_queue'),
                  onTap: () async {
                    Navigator.of(modalContext).pop();
                    await _addSongToQueue(item);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.favorite_outline_rounded),
                  title: TranslatedText('add_to_favorites'),
                  onTap: () async {
                    Navigator.of(modalContext).pop();
                    await _addSongToFavorites(item);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.playlist_add_rounded),
                  title: TranslatedText('add_to_playlist'),
                  onTap: () async {
                    Navigator.of(modalContext).pop();
                    await _showAddSongToPlaylistDialog(item);
                  },
                ),
                if (artist.trim().isNotEmpty &&
                    artist.trim() != LocaleProvider.tr('artist_unknown'))
                  ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: const TranslatedText('go_to_artist'),
                    onTap: () {
                      Navigator.of(modalContext).pop();
                      final name = artist.trim();
                      if (name.isEmpty) return;
                      Navigator.of(context).push(
                        PageRouteBuilder(
                          pageBuilder:
                              (context, animation, secondaryAnimation) =>
                                  ArtistScreen(artistName: name),
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
                ListTile(
                  leading: const Icon(Icons.download_rounded),
                  title: TranslatedText('download'),
                  onTap: () async {
                    Navigator.of(modalContext).pop();
                    await _downloadSingleSong(item);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.share_rounded),
                  title: TranslatedText('share_link'),
                  onTap: () async {
                    Navigator.of(modalContext).pop();
                    if (videoId != null && videoId.isNotEmpty) {
                      await SharePlus.instance.share(
                        ShareParams(
                          text: 'https://music.youtube.com/watch?v=$videoId',
                        ),
                      );
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.check_box_outlined),
                  title: TranslatedText('select'),
                  onTap: () {
                    Navigator.of(modalContext).pop();
                    _selectByKey(selectionKey);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: TranslatedText('song_info'),
                  onTap: () async {
                    Navigator.of(modalContext).pop();
                    await _showSongInfo(item);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlayTrailingButton(
    YtMusicResult item, {
    String? fallbackThumbUrl,
    String? fallbackArtist,
    List<YtMusicResult>? queueItems,
    int? initialIndex,
    bool playAsQueue = false,
    String? queueSource,
  }) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withAlpha(20),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: const Icon(Icons.play_arrow_rounded, grade: 200, fill: 1),
        tooltip: LocaleProvider.tr('play'),
        onPressed: () async {
          await _playInMainPlayer(
            item,
            fallbackThumbUrl: fallbackThumbUrl,
            fallbackArtist: fallbackArtist,
            queueItems: queueItems,
            initialIndex: initialIndex,
            playAsQueue: playAsQueue,
            queueSource: queueSource,
          );
        },
      ),
    );
  }

  List<YtMusicResult> _getSelectedItems() {
    return _selectedIndexes
        .map<YtMusicResult>((key) {
          if (key.startsWith('video-')) {
            final videoId = key.substring(6);
            return _videoResults.firstWhere(
              (item) => item.videoId == videoId,
              orElse: () => YtMusicResult(),
            );
          } else if (key.startsWith('song-')) {
            final videoId = key.substring(5);
            return _songResults.firstWhere(
              (item) => item.videoId == videoId,
              orElse: () => YtMusicResult(),
            );
          } else if (key.startsWith('album-')) {
            final videoId = key.substring(6);
            return _albumSongs.firstWhere(
              (item) => item.videoId == videoId,
              orElse: () => YtMusicResult(),
            );
          } else if (key.startsWith('playlist-')) {
            final videoId = key.substring(9);
            return _playlistSongs.firstWhere(
              (item) => item.videoId == videoId,
              orElse: () => YtMusicResult(),
            );
          }
          return YtMusicResult();
        })
        .where((item) => item.videoId?.trim().isNotEmpty == true)
        .toList();
  }

  Future<void> _addSelectedToFavorites() async {
    final items = _getSelectedItems();
    if (items.isEmpty) return;
    for (final item in items) {
      await _addSongToFavorites(item);
    }
    _clearSelection();
  }

  Future<void> _addSelectedToPlaylist() async {
    final items = _getSelectedItems();
    if (items.isEmpty) return;
    final allPlaylists = (await PlaylistsDB().getAllPlaylists())
        .where(_playlistMatchesStreamingSource)
        .toList();
    final allSongs = await SongsIndexDB().getIndexedSongs();
    final playlistArtworkSourcesCache = await _buildPlaylistArtworkSourcesCache(
      allPlaylists,
    );
    if (!mounted) return;
    final textController = TextEditingController();

    Future<void> addItemsToPlaylist(String playlistId) async {
      final itemsInDisplayOrder = <YtMusicResult>[];
      final seenVideoIds = <String>{};
      for (final item in items) {
        final videoId = item.videoId?.trim();
        if (videoId == null || videoId.isEmpty) continue;
        if (!seenVideoIds.add(videoId)) continue;
        itemsInDisplayOrder.add(item);
      }

      for (final item in itemsInDisplayOrder) {
        final videoId = item.videoId?.trim();
        if (videoId == null || videoId.isEmpty) continue;
        await PlaylistsDB().addSongPathToPlaylist(
          playlistId,
          'yt:$videoId',
          title: item.title?.trim().isNotEmpty == true
              ? item.title!.trim()
              : LocaleProvider.tr('title_unknown'),
          artist: item.artist?.trim().isNotEmpty == true
              ? item.artist!.trim()
              : LocaleProvider.tr('artist_unknown'),
          videoId: videoId,
          artUri: item.thumbUrl?.trim().isNotEmpty == true
              ? item.thumbUrl!.trim()
              : 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
          durationText: item.durationText,
          durationMs: item.durationMs,
        );
      }
      playlistsShouldReload.value = !playlistsShouldReload.value;
      _clearSelection();
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final barColor = isDark
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
                  Text(
                    LocaleProvider.tr('save_to_playlist'),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (allPlaylists.isNotEmpty)
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: allPlaylists.length,
                        itemBuilder: (context, i) {
                          final pl = allPlaylists[i];
                          return Card(
                            color: barColor,
                            margin: EdgeInsets.only(
                              bottom: i == allPlaylists.length - 1 ? 0 : 4,
                            ),
                            elevation: 0,
                            child: ListTile(
                              leading: _buildModalPlaylistArtworkGrid(
                                pl,
                                allSongs,
                                streamingArtworkCache:
                                    playlistArtworkSourcesCache,
                              ),
                              title: Text(pl.name),
                              onTap: () async {
                                await addItemsToPlaylist(pl.id);
                                if (context.mounted) {
                                  Navigator.of(context).pop();
                                }
                              },
                            ),
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: textController,
                    decoration: InputDecoration(
                      hintText: LocaleProvider.tr('new_playlist'),
                      prefixIcon: const Icon(Icons.playlist_add),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.check_rounded),
                        onPressed: () async {
                          final name = textController.text.trim();
                          if (name.isEmpty) return;
                          final playlistId = await PlaylistsDB().createPlaylist(
                            name,
                          );
                          await addItemsToPlaylist(playlistId);
                          if (context.mounted) Navigator.of(context).pop();
                        },
                      ),
                      filled: true,
                      fillColor: barColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _downloadSelected() async {
    final items = _getSelectedItems();

    for (final item in items) {
      if (item.videoId != null) {
        await SimpleYtDownload.downloadVideoWithArtist(
          context,
          item.videoId!,
          item.title ?? '',
          item.artist ?? '',
        );
      }
    }
    _clearSelection();

    // Mostrar mensaje de confirmación
    _showMessage(
      LocaleProvider.tr('success'),
      LocaleProvider.tr(
        'download_started_for_elements',
      ).replaceAll('@count', items.length.toString()),
    );
  }

  bool _hasNonEmptyText(String? value) =>
      value != null && value.trim().isNotEmpty;

  YtMusicResult _mergeVideoResultEntry(
    YtMusicResult current,
    YtMusicResult incoming,
  ) {
    final currentDurationText = current.durationText?.trim();
    final incomingDurationText = incoming.durationText?.trim();

    return YtMusicResult(
      title: _hasNonEmptyText(current.title) ? current.title : incoming.title,
      artist: _hasNonEmptyText(current.artist)
          ? current.artist
          : incoming.artist,
      thumbUrl: _hasNonEmptyText(current.thumbUrl)
          ? current.thumbUrl
          : incoming.thumbUrl,
      videoId: _hasNonEmptyText(current.videoId)
          ? current.videoId
          : incoming.videoId,
      durationText:
          (currentDurationText != null && currentDurationText.isNotEmpty)
          ? currentDurationText
          : incomingDurationText,
      durationMs: (current.durationMs != null && current.durationMs! > 0)
          ? current.durationMs
          : incoming.durationMs,
    );
  }

  int _mergeVideoResultsInPlace(List<YtMusicResult> incoming) {
    int addedCount = 0;
    for (final candidate in incoming) {
      final candidateId = candidate.videoId?.trim();
      if (candidateId == null || candidateId.isEmpty) {
        _videoResults.add(candidate);
        addedCount++;
        continue;
      }

      final existingIndex = _videoResults.indexWhere(
        (entry) => entry.videoId?.trim() == candidateId,
      );
      if (existingIndex == -1) {
        _videoResults.add(candidate);
        addedCount++;
        continue;
      }

      final existing = _videoResults[existingIndex];
      final merged = _mergeVideoResultEntry(existing, candidate);
      final hasChanged =
          merged.title != existing.title ||
          merged.artist != existing.artist ||
          merged.thumbUrl != existing.thumbUrl ||
          merged.videoId != existing.videoId ||
          merged.durationText != existing.durationText ||
          merged.durationMs != existing.durationMs;
      if (hasChanged) {
        _videoResults[existingIndex] = merged;
      }
    }
    return addedCount;
  }

  Future<void> _loadMoreSongs() async {
    if (_loadingMoreSongs || !_hasMoreSongs) return;
    setState(() {
      _loadingMoreSongs = true;
    });
    final nextPage = _songPage + 1;
    final moreSongs = await searchSongsWithPagination(
      _controller.text,
      maxPages: nextPage,
    );
    if (!mounted) return;
    setState(() {
      final existingIds = _songResults.map((e) => e.videoId).toSet();
      final newOnes = moreSongs
          .where((e) => !existingIds.contains(e.videoId))
          .toList();
      _songResults.addAll(newOnes);
      _songPage = nextPage;
      _loadingMoreSongs = false;
      _hasMoreSongs = newOnes.isNotEmpty;
    });
  }

  Future<void> _loadMoreVideos() async {
    if (_loadingMoreVideos || !_hasMoreVideos) return;
    setState(() {
      _loadingMoreVideos = true;
    });
    final nextPage = _videoPage + 1;
    final moreVideos = await searchVideosWithPagination(
      _controller.text,
      maxPages: nextPage,
    );
    if (!mounted) return;
    setState(() {
      final addedCount = _mergeVideoResultsInPlace(moreVideos);
      _videoPage = nextPage;
      _loadingMoreVideos = false;
      _hasMoreVideos = addedCount > 0;
    });
  }

  Future<void> _loadMorePlaylists() async {
    if (_loadingMorePlaylists || !_hasMorePlaylists) return;
    setState(() {
      _loadingMorePlaylists = true;
    });
    final nextPage = _playlistPage + 1;
    final morePlaylists = await searchPlaylistsWithPagination(
      _controller.text,
      maxPages: nextPage,
    );
    if (!mounted) return;
    setState(() {
      final existingIds = _playlistResults.map((e) => e['browseId']).toSet();
      final newOnes = morePlaylists
          .where((e) => !existingIds.contains(e['browseId']))
          .toList();
      _playlistResults.addAll(newOnes);
      _playlistPage = nextPage;
      _loadingMorePlaylists = false;
      _hasMorePlaylists = newOnes.isNotEmpty;
    });
  }

  // Métodos para pop interno desde el home
  bool canPopInternally() {
    return _expandedCategory != null ||
        _hasSearched ||
        _isUrlSearch ||
        _isUrlPlaylistSearch;
  }

  void handleInternalPop() {
    if (_expandedCategory == 'album' || _expandedCategory == 'playlist') {
      setState(() {
        _expandedCategory = null;
        _albumSongs = [];
        _currentAlbum = null;
        _playlistSongs = [];
        _currentPlaylist = null;
      });
      // Restaurar el estado de la pestaña actual (ej. si estaba en la pestaña 'Álbumes')
      _handleTabSelection();
    } else if (_expandedCategory != null) {
      // Si estamos en una pestaña de categoría ('songs', 'videos', etc.)
      if (_tabController.index != 0) {
        _tabController.animateTo(0);
        if (_tabScrollController.hasClients) {
          _tabScrollController.animateTo(
            0,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        }
      } else {
        _clearResults();
      }
    } else {
      _clearResults();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isSystem = colorSchemeNotifier.value == AppColorScheme.system;
    final isAmoledTheme =
        Theme.of(context).brightness == Brightness.dark &&
        Theme.of(context).colorScheme.surface == Colors.black;
    final menuColor = isAmoledTheme
        ? Colors.grey.shade900
        : Theme.of(context).colorScheme.surfaceContainerHigh;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: _isSelectionMode
            ? Text(
                '${_selectedIndexes.length} ${LocaleProvider.tr('selected')}',
              )
            : TranslatedText(
                'search',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
        leading: _isSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: _clearSelection,
              )
            : (canPopInternally()
                  ? IconButton(
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
                                ).colorScheme.secondary.withAlpha(15)
                              : Theme.of(
                                  context,
                                ).colorScheme.secondary.withAlpha(18),
                        ),
                        child: const Icon(Icons.arrow_back, size: 24),
                      ),
                      onPressed: handleInternalPop,
                    )
                  : null),
        actions: _isSelectionMode
            ? [
                if (_selectedIndexes.isNotEmpty)
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert),
                    tooltip: LocaleProvider.tr('want_more_options'),
                    color: menuColor,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    onSelected: (value) async {
                      if (value == 'favorites') {
                        await _addSelectedToFavorites();
                      } else if (value == 'playlist') {
                        await _addSelectedToPlaylist();
                      } else if (value == 'download') {
                        await _downloadSelected();
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem<String>(
                        value: 'favorites',
                        child: Row(
                          children: [
                            const Icon(Icons.favorite_outline_rounded),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                LocaleProvider.tr('add_to_favorites'),
                              ),
                            ),
                          ],
                        ),
                      ),
                      PopupMenuItem<String>(
                        value: 'playlist',
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
                        child: Row(
                          children: [
                            const Icon(Icons.download_rounded),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(LocaleProvider.tr('download')),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
              ]
            : [
                ValueListenableBuilder<bool>(
                  valueListenable: hasNewDownloadsNotifier,
                  builder: (context, hasNewDownloads, child) {
                    return Stack(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.history, size: 28),
                          tooltip: LocaleProvider.tr('download_history'),
                          onPressed: () {
                            Navigator.of(context).push(
                              PageRouteBuilder(
                                pageBuilder:
                                    (context, animation, secondaryAnimation) =>
                                        const DownloadHistoryScreen(),
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
                        if (hasNewDownloads)
                          Positioned(
                            right: 8,
                            top: 8,
                            child: Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primary,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Theme.of(
                                    context,
                                  ).scaffoldBackgroundColor,
                                  width: 1.5,
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
                ValueListenableBuilder<String?>(
                  valueListenable: downloadDirectoryNotifier,
                  builder: (context, dir, child) {
                    return IconButton(
                      icon: const Icon(Icons.folder_open, size: 28),
                      tooltip: dir == null || dir.isEmpty
                          ? LocaleProvider.tr('choose_folder')
                          : LocaleProvider.tr('folder_ready'),
                      onPressed: _pickDirectory,
                    );
                  },
                ),
                ValueListenableBuilder<String>(
                  valueListenable: languageNotifier,
                  builder: (context, lang, child) {
                    return IconButton(
                      icon: const Icon(Icons.info_outline, size: 28),
                      tooltip: LocaleProvider.tr('info'),
                      onPressed: () {
                        showDialog(
                          context: context,
                          builder: (context) =>
                              ValueListenableBuilder<AppColorScheme>(
                                valueListenable: colorSchemeNotifier,
                                builder: (context, colorScheme, child) {
                                  final isAmoled =
                                      colorScheme == AppColorScheme.amoled;
                                  final isDark =
                                      Theme.of(context).brightness ==
                                      Brightness.dark;
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
                                            MediaQuery.of(context).size.height *
                                            0.8,
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
                                              'search_music_in_ytm',
                                              style: TextStyle(
                                                fontSize: 14,
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onSurface
                                                    .withAlpha(160),
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
                              ),
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
            child: ValueListenableBuilder<String>(
              valueListenable: languageNotifier,
              builder: (context, lang, child) {
                final colorScheme = colorSchemeNotifier.value;
                final isDark = Theme.of(context).brightness == Brightness.dark;
                final isAmoled = colorScheme == AppColorScheme.amoled;
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
                  controller: _controller,
                  focusNode: _focusNode,
                  onChanged: (value) {
                    setState(() {
                      _showSuggestions = true;
                      _noInternet = false;
                      if (value.isNotEmpty) {
                        _hasSearched = false;
                        _songResults = [];
                        _videoResults = [];
                        _albumResults = [];
                        _artistResults = [];
                      }
                    });
                    if (value.isEmpty) {
                      _checkHistory().then((_) {
                        setState(() {});
                      });
                    }
                  },
                  onSubmitted: (_) => _search(),
                  onTap: () {
                    setState(() {
                      _showSuggestions = true;
                      if (_controller.text.isNotEmpty) {
                        _hasSearched = false;
                      }
                    });
                  },
                  cursorColor: Theme.of(context).colorScheme.primary,
                  decoration: InputDecoration(
                    hintText: LocaleProvider.tr('search_in_youtube_music'),
                    hintStyle: TextStyle(
                      color: isAmoled
                          ? Colors.white.withAlpha(160)
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 15,
                    ),
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _controller.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              _controller.clear();
                              _clearResults();
                              setState(() {
                                _showSuggestions = true;
                                _hasSearched = false;
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
                );
              },
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          // Contenido principal
          Expanded(
            child: Padding(
              padding: EdgeInsets.zero,
              child: StreamBuilder<MediaItem?>(
                stream: audioHandler?.mediaItem,
                builder: (context, snapshot) {
                  // print('DEBUG: StreamBuilder rebuild, mediaItem: ${snapshot.data != null}');
                  final mediaItem = snapshot.data;
                  // Calcular espacio inferior considerando overlay de reproducción
                  // (ya no sumamos espacio para la barra de progreso)
                  final bottomPadding = MediaQuery.of(context).padding.bottom;
                  double bottomSpace =
                      (mediaItem != null ? 100.0 : 0.0) + bottomPadding;
                  return Column(
                    children: [
                      if (!_loading &&
                          (_songResults.isNotEmpty ||
                              _videoResults.isNotEmpty ||
                              _albumResults.isNotEmpty ||
                              _playlistResults.isNotEmpty) &&
                          _hasSearched)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: SingleChildScrollView(
                            controller: _tabScrollController,
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: ButtonsTabBar(
                              key: ValueKey(_tabController),
                              controller: _tabController,
                              backgroundColor: Theme.of(
                                context,
                              ).colorScheme.primary,
                              unselectedBackgroundColor: isAmoled
                                  ? Colors.white.withAlpha(30)
                                  : Theme.of(context).colorScheme.secondary
                                        .withValues(alpha: 0.2),
                              labelStyle: TextStyle(
                                color: Theme.of(context).colorScheme.onPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              unselectedLabelStyle: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                              borderWidth: 1,
                              borderColor: Colors.transparent,
                              unselectedBorderColor: Colors.transparent,
                              radius: 8,
                              tabs: _tabs
                                  .map((t) => Tab(text: t.label))
                                  .toList(),
                              onTap: (index) {
                                // Logic is handled by listener
                              },
                            ),
                          ),
                        ),
                      // SOLO UNO de estos bloques se muestra a la vez
                      if (_error != null)
                        Text(_error!, style: const TextStyle(color: Colors.red))
                      else if (_isUrlSearch && _loadingUrlVideo)
                        Expanded(child: Center(child: LoadingIndicator()))
                      else if (_isUrlSearch && _urlVideoError != null)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.error_outline,
                                    size: 48,
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    _urlVideoError!,
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.error,
                                      fontSize: 14,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        )
                      else if (_isUrlSearch && _urlVideoResult != null)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: _buildUrlVideoResult(),
                          ),
                        )
                      else if (_isUrlPlaylistSearch && _loadingUrlPlaylist)
                        Expanded(child: Center(child: LoadingIndicator()))
                      else if (_isUrlPlaylistSearch &&
                          _urlPlaylistError != null)
                        Expanded(
                          child: Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.error_outline,
                                  size: 48,
                                  color: Theme.of(context).colorScheme.error,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  _urlPlaylistError!,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                    fontSize: 14,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                        )
                      else if (_isUrlPlaylistSearch &&
                          _urlPlaylistVideos.isNotEmpty)
                        Expanded(child: _buildUrlPlaylistResult())
                      else if (_loading)
                        Expanded(child: Center(child: LoadingIndicator()))
                      else if (_noInternet)
                        Expanded(
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
                                        ? Theme.of(context)
                                              .colorScheme
                                              .secondary
                                              .withValues(alpha: 0.04)
                                        : Theme.of(context)
                                              .colorScheme
                                              .secondary
                                              .withValues(alpha: 0.05),
                                  ),
                                  child: Icon(
                                    Icons.wifi_off_rounded,
                                    grade: 300,
                                    size: 50,
                                    color:
                                        Theme.of(context).brightness ==
                                            Brightness.light
                                        ? Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: 0.7)
                                        : Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: 0.7),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  LocaleProvider.tr('no_internet_connection'),
                                  style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.6),
                                    fontSize: 14,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 26),
                                ElevatedButton.icon(
                                  onPressed: () {
                                    switch (OpenSettingsPlus.shared) {
                                      case OpenSettingsPlusAndroid settings:
                                        settings.wifi();
                                        break;
                                      case OpenSettingsPlusIOS settings:
                                        settings.wifi();
                                        break;
                                      default:
                                        break;
                                    }
                                  },
                                  icon: Container(
                                    width: 24,
                                    height: 24,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Colors.white.withValues(
                                        alpha: 0.2,
                                      ),
                                    ),
                                    child: Icon(
                                      Icons.settings,
                                      size: 16,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onPrimary,
                                    ),
                                  ),
                                  label: Text(
                                    LocaleProvider.tr('open_settings'),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    foregroundColor: Theme.of(
                                      context,
                                    ).colorScheme.onPrimary,
                                    shadowColor: Colors.transparent,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 24,
                                      vertical: 12,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(24),
                                    ),
                                    elevation: 4,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      else if (_showSuggestions &&
                          !_loading &&
                          _controller.text.isEmpty)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: FutureBuilder<List<String>>(
                              future: SearchHistory.getHistory(),
                              builder: (context, snapshot) {
                                final hasHistory =
                                    snapshot.hasData &&
                                    snapshot.data!.isNotEmpty;
                                if (!hasHistory) {
                                  if (_focusNode.hasFocus) {
                                    return const SizedBox.shrink();
                                  }
                                  return Center(
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Container(
                                          width: 80,
                                          height: 80,
                                          alignment: Alignment.center,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: isDark
                                                ? Theme.of(context)
                                                      .colorScheme
                                                      .secondary
                                                      .withValues(alpha: 0.04)
                                                : Theme.of(context)
                                                      .colorScheme
                                                      .secondary
                                                      .withValues(alpha: 0.05),
                                          ),
                                          child: Icon(
                                            Icons.history_rounded,
                                            grade: 300,
                                            size: 50,
                                            color:
                                                Theme.of(context).brightness ==
                                                    Brightness.light
                                                ? Theme.of(context)
                                                      .colorScheme
                                                      .onSurface
                                                      .withValues(alpha: 0.7)
                                                : Theme.of(context)
                                                      .colorScheme
                                                      .onSurface
                                                      .withValues(alpha: 0.7),
                                          ),
                                        ),
                                        const SizedBox(height: 16),
                                        Text(
                                          LocaleProvider.tr(
                                            'no_recent_searches',
                                          ),
                                          style: TextStyle(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurface
                                                .withValues(alpha: 0.6),
                                            fontSize: 14,
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                } else {
                                  return SearchSuggestionsWidget(
                                    query: _controller.text,
                                    onSuggestionSelected: _onSuggestionSelected,
                                    onClearHistory: _onClearHistory,
                                  );
                                }
                              },
                            ),
                          ),
                        )
                      else if (_showSuggestions &&
                          !_loading &&
                          _controller.text.isNotEmpty &&
                          !_hasSearched)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: SearchSuggestionsWidget(
                              query: _controller.text,
                              onSuggestionSelected: _onSuggestionSelected,
                              onClearHistory: _onClearHistory,
                            ),
                          ),
                        )
                      else if (!_loading &&
                          (_songResults.isNotEmpty ||
                              _videoResults.isNotEmpty) &&
                          _hasSearched)
                        Expanded(
                          child: Builder(
                            builder: (context) {
                              if (_expandedCategory == 'songs') {
                                // Mostrar solo todas las canciones con botón de volver
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: ListView.builder(
                                        key: PageStorageKey(
                                          'yt_songs_list_$_searchSessionId',
                                        ),
                                        controller: _songScrollController,
                                        padding: EdgeInsets.only(
                                          bottom: bottomSpace,
                                        ),
                                        itemCount:
                                            _songResults.length +
                                            (_loadingMoreSongs ? 1 : 0),
                                        itemBuilder: (context, idx) {
                                          if (_loadingMoreSongs &&
                                              idx == _songResults.length) {
                                            return Container(
                                              padding: const EdgeInsets.all(16),
                                              child: Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  SizedBox(
                                                    width: 20,
                                                    height: 20,
                                                    child: LoadingIndicator(),
                                                  ),
                                                  const SizedBox(width: 12),
                                                  TranslatedText(
                                                    'loading_more',
                                                    style: TextStyle(
                                                      fontSize: 14,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            );
                                          }
                                          final item = _songResults[idx];
                                          final videoId = item.videoId;
                                          final isSelected =
                                              videoId != null &&
                                              _selectedIndexes.contains(
                                                'song-$videoId',
                                              );

                                          final isDark =
                                              Theme.of(context).brightness ==
                                              Brightness.dark;
                                          final cardColor = isAmoled && isDark
                                              ? Colors.white.withAlpha(20)
                                              : isDark
                                              ? Theme.of(context)
                                                    .colorScheme
                                                    .secondary
                                                    .withValues(alpha: 0.06)
                                              : Theme.of(context)
                                                    .colorScheme
                                                    .secondary
                                                    .withValues(alpha: 0.07);

                                          final bool isFirst = idx == 0;
                                          final bool isLast =
                                              idx == _songResults.length - 1;
                                          final bool isOnly =
                                              _songResults.length == 1;

                                          BorderRadius borderRadius;
                                          if (isOnly) {
                                            borderRadius =
                                                BorderRadius.circular(20);
                                          } else if (isFirst) {
                                            borderRadius =
                                                const BorderRadius.only(
                                                  topLeft: Radius.circular(20),
                                                  topRight: Radius.circular(20),
                                                  bottomLeft: Radius.circular(
                                                    4,
                                                  ),
                                                  bottomRight: Radius.circular(
                                                    4,
                                                  ),
                                                );
                                          } else if (isLast) {
                                            borderRadius =
                                                const BorderRadius.only(
                                                  topLeft: Radius.circular(4),
                                                  topRight: Radius.circular(4),
                                                  bottomLeft: Radius.circular(
                                                    20,
                                                  ),
                                                  bottomRight: Radius.circular(
                                                    20,
                                                  ),
                                                );
                                          } else {
                                            borderRadius =
                                                BorderRadius.circular(4);
                                          }

                                          return Padding(
                                            padding: EdgeInsets.only(
                                              bottom: isLast ? 0 : 4,
                                              left: 16,
                                              right: 16,
                                            ),
                                            child: Card(
                                              color: cardColor,
                                              margin: EdgeInsets.zero,
                                              elevation: 0,
                                              shape: RoundedRectangleBorder(
                                                borderRadius: borderRadius,
                                              ),
                                              child: InkWell(
                                                borderRadius: borderRadius,
                                                onLongPress: () {
                                                  HapticFeedback.selectionClick();
                                                  final item =
                                                      _songResults[idx];
                                                  final videoId = item.videoId;
                                                  if (videoId == null) return;
                                                  if (_isSelectionMode) {
                                                    _toggleSelection(
                                                      idx,
                                                      isVideo: false,
                                                    );
                                                    return;
                                                  }
                                                  _showSongActionsModal(
                                                    item,
                                                    selectionKey:
                                                        'song-$videoId',
                                                  );
                                                },
                                                onTap: () async {
                                                  if (_isSelectionMode) {
                                                    _toggleSelection(
                                                      idx,
                                                      isVideo: false,
                                                    );
                                                  } else {
                                                    await _playInMainPlayer(
                                                      _songResults[idx],
                                                    );
                                                  }
                                                },
                                                child: ListTile(
                                                  contentPadding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 16,
                                                        vertical: 4,
                                                      ),
                                                  leading: Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      if (_isSelectionMode)
                                                        Checkbox(
                                                          value: isSelected,
                                                          onChanged: (checked) {
                                                            setState(() {
                                                              if (videoId ==
                                                                  null) {
                                                                return;
                                                              }
                                                              final key =
                                                                  'song-$videoId';
                                                              if (checked ==
                                                                  true) {
                                                                _selectedIndexes
                                                                    .add(key);
                                                              } else {
                                                                _selectedIndexes
                                                                    .remove(
                                                                      key,
                                                                    );
                                                                if (_selectedIndexes
                                                                    .isEmpty) {
                                                                  _isSelectionMode =
                                                                      false;
                                                                }
                                                              }
                                                            });
                                                          },
                                                        ),
                                                      ClipRRect(
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                        child:
                                                            item.thumbUrl !=
                                                                null
                                                            ? _buildSafeNetworkImage(
                                                                item.thumbUrl!,
                                                                width: 50,
                                                                height: 50,
                                                                fit: BoxFit
                                                                    .cover,
                                                                fallback: Container(
                                                                  width: 50,
                                                                  height: 50,
                                                                  decoration: BoxDecoration(
                                                                    color:
                                                                        isSystem
                                                                        ? Theme.of(
                                                                            context,
                                                                          ).colorScheme.secondaryContainer
                                                                        : Theme.of(
                                                                            context,
                                                                          ).colorScheme.surfaceContainer,
                                                                    borderRadius:
                                                                        BorderRadius.circular(
                                                                          8,
                                                                        ),
                                                                  ),
                                                                  child: const Icon(
                                                                    Icons
                                                                        .music_note,
                                                                    size: 24,
                                                                    color: Colors
                                                                        .grey,
                                                                  ),
                                                                ),
                                                              )
                                                            : Container(
                                                                width: 50,
                                                                height: 50,
                                                                decoration: BoxDecoration(
                                                                  color: Colors
                                                                      .grey[300],
                                                                  borderRadius:
                                                                      BorderRadius.circular(
                                                                        8,
                                                                      ),
                                                                ),
                                                                child: const Icon(
                                                                  Icons
                                                                      .music_note,
                                                                  size: 24,
                                                                ),
                                                              ),
                                                      ),
                                                    ],
                                                  ),
                                                  title: Text(
                                                    item.title ??
                                                        LocaleProvider.tr(
                                                          'title_unknown',
                                                        ),
                                                    style: Theme.of(
                                                      context,
                                                    ).textTheme.titleMedium,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                  subtitle: Text(
                                                    _artistWithDurationText(
                                                      artist: item.artist,
                                                      fallbackArtist:
                                                          LocaleProvider.tr(
                                                            'artist_unknown',
                                                          ),
                                                      durationText:
                                                          item.durationText,
                                                      durationMs:
                                                          item.durationMs,
                                                    ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      color: isAmoled
                                                          ? Colors.white
                                                                .withValues(
                                                                  alpha: 0.8,
                                                                )
                                                          : null,
                                                    ),
                                                  ),
                                                  trailing:
                                                      _buildPlayTrailingButton(
                                                        item,
                                                      ),
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                );
                              } else if (_expandedCategory == 'videos') {
                                // Mostrar solo todos los videos con botón de volver
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: ListView.builder(
                                        key: PageStorageKey(
                                          'yt_videos_list_$_searchSessionId',
                                        ),
                                        controller: _videoScrollController,
                                        padding: EdgeInsets.only(
                                          bottom: bottomSpace,
                                        ),
                                        itemCount:
                                            _videoResults.length +
                                            (_loadingMoreVideos ? 1 : 0),
                                        itemBuilder: (context, idx) {
                                          if (_loadingMoreVideos &&
                                              idx == _videoResults.length) {
                                            return Container(
                                              padding: const EdgeInsets.all(16),
                                              child: Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  SizedBox(
                                                    width: 20,
                                                    height: 20,
                                                    child: LoadingIndicator(),
                                                  ),
                                                  const SizedBox(width: 12),
                                                  TranslatedText(
                                                    'loading_more',
                                                    style: TextStyle(
                                                      fontSize: 14,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            );
                                          }
                                          final item = _videoResults[idx];
                                          final videoId = item.videoId;
                                          final isSelected =
                                              videoId != null &&
                                              _selectedIndexes.contains(
                                                'video-$videoId',
                                              );

                                          final isDark =
                                              Theme.of(context).brightness ==
                                              Brightness.dark;
                                          final cardColor = isAmoled && isDark
                                              ? Colors.white.withAlpha(20)
                                              : isDark
                                              ? Theme.of(context)
                                                    .colorScheme
                                                    .secondary
                                                    .withValues(alpha: 0.06)
                                              : Theme.of(context)
                                                    .colorScheme
                                                    .secondary
                                                    .withValues(alpha: 0.07);

                                          final bool isFirst = idx == 0;
                                          final bool isLast =
                                              idx == _videoResults.length - 1;
                                          final bool isOnly =
                                              _videoResults.length == 1;

                                          BorderRadius borderRadius;
                                          if (isOnly) {
                                            borderRadius =
                                                BorderRadius.circular(20);
                                          } else if (isFirst) {
                                            borderRadius =
                                                const BorderRadius.only(
                                                  topLeft: Radius.circular(20),
                                                  topRight: Radius.circular(20),
                                                  bottomLeft: Radius.circular(
                                                    4,
                                                  ),
                                                  bottomRight: Radius.circular(
                                                    4,
                                                  ),
                                                );
                                          } else if (isLast) {
                                            borderRadius =
                                                const BorderRadius.only(
                                                  topLeft: Radius.circular(4),
                                                  topRight: Radius.circular(4),
                                                  bottomLeft: Radius.circular(
                                                    20,
                                                  ),
                                                  bottomRight: Radius.circular(
                                                    20,
                                                  ),
                                                );
                                          } else {
                                            borderRadius =
                                                BorderRadius.circular(4);
                                          }

                                          return Padding(
                                            padding: EdgeInsets.only(
                                              bottom: isLast ? 0 : 4,
                                              left: 16,
                                              right: 16,
                                            ),
                                            child: Card(
                                              color: cardColor,
                                              margin: EdgeInsets.zero,
                                              elevation: 0,
                                              shape: RoundedRectangleBorder(
                                                borderRadius: borderRadius,
                                              ),
                                              child: InkWell(
                                                borderRadius: borderRadius,
                                                onLongPress: () {
                                                  HapticFeedback.selectionClick();
                                                  final item =
                                                      _videoResults[idx];
                                                  final videoId = item.videoId;
                                                  if (videoId == null) return;
                                                  if (_isSelectionMode) {
                                                    _toggleSelection(
                                                      idx,
                                                      isVideo: true,
                                                    );
                                                    return;
                                                  }
                                                  _showSongActionsModal(
                                                    item,
                                                    selectionKey:
                                                        'video-$videoId',
                                                  );
                                                },
                                                onTap: () async {
                                                  if (_isSelectionMode) {
                                                    _toggleSelection(
                                                      idx,
                                                      isVideo: true,
                                                    );
                                                  } else {
                                                    await _playInMainPlayer(
                                                      _videoResults[idx],
                                                    );
                                                  }
                                                },
                                                child: ListTile(
                                                  contentPadding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 16,
                                                        vertical: 4,
                                                      ),
                                                  leading: Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      if (_isSelectionMode)
                                                        Checkbox(
                                                          value: isSelected,
                                                          onChanged: (checked) {
                                                            setState(() {
                                                              if (videoId ==
                                                                  null) {
                                                                return;
                                                              }
                                                              final key =
                                                                  'video-$videoId';
                                                              if (checked ==
                                                                  true) {
                                                                _selectedIndexes
                                                                    .add(key);
                                                              } else {
                                                                _selectedIndexes
                                                                    .remove(
                                                                      key,
                                                                    );
                                                                if (_selectedIndexes
                                                                    .isEmpty) {
                                                                  _isSelectionMode =
                                                                      false;
                                                                }
                                                              }
                                                            });
                                                          },
                                                        ),
                                                      ClipRRect(
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                        child:
                                                            item.thumbUrl !=
                                                                null
                                                            ? _buildSafeNetworkImage(
                                                                item.thumbUrl!,
                                                                width: 50,
                                                                height: 50,
                                                                fit: BoxFit
                                                                    .cover,
                                                                fallback: Container(
                                                                  width: 50,
                                                                  height: 50,
                                                                  decoration: BoxDecoration(
                                                                    color:
                                                                        isSystem
                                                                        ? Theme.of(
                                                                            context,
                                                                          ).colorScheme.secondaryContainer
                                                                        : Theme.of(
                                                                            context,
                                                                          ).colorScheme.surfaceContainer,
                                                                    borderRadius:
                                                                        BorderRadius.circular(
                                                                          8,
                                                                        ),
                                                                  ),
                                                                  child: const Icon(
                                                                    Icons
                                                                        .music_note,
                                                                    size: 24,
                                                                  ),
                                                                ),
                                                              )
                                                            : Container(
                                                                width: 50,
                                                                height: 50,
                                                                decoration: BoxDecoration(
                                                                  color: Colors
                                                                      .grey[300],
                                                                  borderRadius:
                                                                      BorderRadius.circular(
                                                                        8,
                                                                      ),
                                                                ),
                                                                child: const Icon(
                                                                  Icons
                                                                      .music_video,
                                                                  size: 24,
                                                                  color: Colors
                                                                      .grey,
                                                                ),
                                                              ),
                                                      ),
                                                    ],
                                                  ),
                                                  title: Text(
                                                    item.title ??
                                                        LocaleProvider.tr(
                                                          'title_unknown',
                                                        ),
                                                    style: Theme.of(
                                                      context,
                                                    ).textTheme.titleMedium,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                  subtitle: Text(
                                                    _artistWithDurationText(
                                                      artist: item.artist,
                                                      fallbackArtist:
                                                          LocaleProvider.tr(
                                                            'artist_unknown',
                                                          ),
                                                      durationText:
                                                          item.durationText,
                                                      durationMs:
                                                          item.durationMs,
                                                    ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      color: isAmoled
                                                          ? Colors.white
                                                                .withValues(
                                                                  alpha: 0.8,
                                                                )
                                                          : null,
                                                    ),
                                                  ),
                                                  trailing:
                                                      _buildPlayTrailingButton(
                                                        item,
                                                      ),
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                );
                              } else if (_expandedCategory == 'albums') {
                                // Mostrar solo álbumes con botón de volver
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: ListView.builder(
                                        key: PageStorageKey(
                                          'yt_albums_list_$_searchSessionId',
                                        ),
                                        padding: EdgeInsets.only(
                                          bottom: bottomSpace,
                                        ),
                                        itemCount: _albumResults.length,
                                        itemBuilder: (context, index) {
                                          final item = _albumResults[index];
                                          YtMusicResult album;
                                          if (item is YtMusicResult) {
                                            album = item;
                                          } else if (item is Map) {
                                            final map =
                                                item as Map<String, dynamic>;
                                            album = YtMusicResult(
                                              title: map['title'] as String?,
                                              artist: map['artist'] as String?,
                                              thumbUrl:
                                                  map['thumbUrl'] as String?,
                                              videoId:
                                                  map['browseId'] as String?,
                                            );
                                          } else {
                                            album = YtMusicResult();
                                          }

                                          // Lógica de diseño de tarjetas
                                          final isDark =
                                              Theme.of(context).brightness ==
                                              Brightness.dark;
                                          final cardColor = isAmoled && isDark
                                              ? Colors.white.withAlpha(20)
                                              : isDark
                                              ? Theme.of(context)
                                                    .colorScheme
                                                    .secondary
                                                    .withValues(alpha: 0.06)
                                              : Theme.of(context)
                                                    .colorScheme
                                                    .secondary
                                                    .withValues(alpha: 0.07);

                                          final bool isFirst = index == 0;
                                          final bool isLast =
                                              index == _albumResults.length - 1;
                                          final bool isOnly =
                                              _albumResults.length == 1;

                                          BorderRadius borderRadius;
                                          if (isOnly) {
                                            borderRadius =
                                                BorderRadius.circular(20);
                                          } else if (isFirst) {
                                            borderRadius =
                                                const BorderRadius.only(
                                                  topLeft: Radius.circular(20),
                                                  topRight: Radius.circular(20),
                                                  bottomLeft: Radius.circular(
                                                    4,
                                                  ),
                                                  bottomRight: Radius.circular(
                                                    4,
                                                  ),
                                                );
                                          } else if (isLast) {
                                            borderRadius =
                                                const BorderRadius.only(
                                                  topLeft: Radius.circular(4),
                                                  topRight: Radius.circular(4),
                                                  bottomLeft: Radius.circular(
                                                    20,
                                                  ),
                                                  bottomRight: Radius.circular(
                                                    20,
                                                  ),
                                                );
                                          } else {
                                            borderRadius =
                                                BorderRadius.circular(4);
                                          }

                                          return Padding(
                                            padding: EdgeInsets.only(
                                              bottom: isLast ? 0 : 4,
                                              left: 16,
                                              right: 16,
                                            ),
                                            child: Card(
                                              color: cardColor,
                                              margin: EdgeInsets.zero,
                                              elevation: 0,
                                              shape: RoundedRectangleBorder(
                                                borderRadius: borderRadius,
                                              ),
                                              child: InkWell(
                                                borderRadius: borderRadius,
                                                onTap: () async {
                                                  if (album.videoId == null) {
                                                    return;
                                                  }
                                                  setState(() {
                                                    _expandedCategory = 'album';
                                                    _loadingAlbumSongs = true;
                                                    _albumSongs = [];
                                                    _currentAlbum = {
                                                      'id': album.videoId,
                                                      'title': album.title,
                                                      'artist': album.artist,
                                                      'thumbUrl':
                                                          album.thumbUrl,
                                                    };
                                                  });
                                                  final songs =
                                                      await getAlbumSongs(
                                                        album.videoId!,
                                                      );
                                                  if (!mounted) return;
                                                  setState(() {
                                                    _albumSongs = songs;
                                                    _loadingAlbumSongs = false;
                                                  });
                                                },
                                                child: ListTile(
                                                  contentPadding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 16,
                                                        vertical: 4,
                                                      ),
                                                  leading: ClipRRect(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          8,
                                                        ),
                                                    child:
                                                        album.thumbUrl != null
                                                        ? CachedNetworkImage(
                                                            imageUrl:
                                                                album.thumbUrl!,
                                                            width: 56,
                                                            height: 56,
                                                            fit: BoxFit.cover,
                                                            fadeInDuration:
                                                                Duration.zero,
                                                            fadeOutDuration:
                                                                Duration.zero,
                                                            errorWidget:
                                                                (
                                                                  context,
                                                                  url,
                                                                  error,
                                                                ) => Container(
                                                                  width: 56,
                                                                  height: 56,
                                                                  decoration: BoxDecoration(
                                                                    color: Colors
                                                                        .grey[300],
                                                                    borderRadius:
                                                                        BorderRadius.circular(
                                                                          12,
                                                                        ),
                                                                  ),
                                                                  child: const Icon(
                                                                    Icons.album,
                                                                    size: 32,
                                                                    color: Colors
                                                                        .grey,
                                                                  ),
                                                                ),
                                                          )
                                                        : Container(
                                                            width: 56,
                                                            height: 56,
                                                            decoration:
                                                                BoxDecoration(
                                                                  color: Colors
                                                                      .grey[300],
                                                                  borderRadius:
                                                                      BorderRadius.circular(
                                                                        12,
                                                                      ),
                                                                ),
                                                            child: const Icon(
                                                              Icons.album,
                                                              size: 32,
                                                              color:
                                                                  Colors.grey,
                                                            ),
                                                          ),
                                                  ),
                                                  title: Text(
                                                    album.title ??
                                                        'Álbum desconocido',
                                                    style: Theme.of(
                                                      context,
                                                    ).textTheme.titleMedium,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                  subtitle: Text(
                                                    album.artist ??
                                                        'Artista desconocido',
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      color: isAmoled
                                                          ? Colors.white
                                                                .withValues(
                                                                  alpha: 0.8,
                                                                )
                                                          : null,
                                                    ),
                                                  ),
                                                  trailing: IconButton(
                                                    style: IconButton.styleFrom(
                                                      backgroundColor:
                                                          Theme.of(context)
                                                              .colorScheme
                                                              .primary
                                                              .withAlpha(20),
                                                    ),
                                                    icon: const Icon(
                                                      Icons.link_rounded,
                                                      size: 20,
                                                    ),
                                                    tooltip: 'Copiar enlace',
                                                    onPressed: () {
                                                      if (album.videoId !=
                                                          null) {
                                                        Clipboard.setData(
                                                          ClipboardData(
                                                            text:
                                                                'https://music.youtube.com/browse/${album.videoId}',
                                                          ),
                                                        );
                                                      }
                                                    },
                                                  ),
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                );
                              } else if (_expandedCategory == 'album') {
                                return Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          if (_currentAlbum != null) ...[
                                            if (_currentAlbum!['thumbUrl']
                                                    is String &&
                                                (_currentAlbum!['thumbUrl']
                                                        as String)
                                                    .isNotEmpty)
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  right: 12,
                                                ),
                                                child: ClipRRect(
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                  child: _buildSafeNetworkImage(
                                                    _currentAlbum!['thumbUrl']
                                                        as String,
                                                    width: 40,
                                                    height: 40,
                                                    fit: BoxFit.cover,
                                                    fallback: Container(
                                                      width: 40,
                                                      height: 40,
                                                      decoration: BoxDecoration(
                                                        color: isSystem
                                                            ? Theme.of(context)
                                                                  .colorScheme
                                                                  .secondaryContainer
                                                            : Theme.of(context)
                                                                  .colorScheme
                                                                  .surfaceContainer,
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                      ),
                                                      child: const Icon(
                                                        Icons.music_note,
                                                        size: 20,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            Expanded(
                                              child: Text(
                                                _currentAlbum!['title'] ?? '',
                                                style: Theme.of(
                                                  context,
                                                ).textTheme.titleMedium,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Container(
                                              width: 40,
                                              height: 40,
                                              decoration: BoxDecoration(
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.primary,
                                                shape: BoxShape.circle,
                                              ),
                                              child: PopupMenuButton<String>(
                                                color: isAmoled
                                                    ? Colors.grey.shade900
                                                    : Theme.of(context)
                                                          .colorScheme
                                                          .surfaceContainerHigh,
                                                tooltip: LocaleProvider.tr(
                                                  'want_more_options',
                                                ),
                                                padding: EdgeInsets.zero,
                                                icon: Icon(
                                                  Icons.more_vert,
                                                  size: 22,
                                                  color: isAmoled && isDark
                                                      ? Colors.black
                                                      : Theme.of(
                                                          context,
                                                        ).colorScheme.onPrimary,
                                                ),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(16),
                                                ),
                                                onSelected: (value) async {
                                                  if (_albumSongs.isEmpty) {
                                                    return;
                                                  }
                                                  if (value == 'favorites') {
                                                    await _addSongsToFavorites(
                                                      _albumSongs,
                                                    );
                                                  } else if (value ==
                                                      'playlist') {
                                                    await _showAddMultipleSongsToPlaylistDialog(
                                                      _albumSongs,
                                                    );
                                                  } else if (value ==
                                                      'download') {
                                                    await _downloadSongs(
                                                      _albumSongs,
                                                    );
                                                  }
                                                },
                                                itemBuilder: (context) => [
                                                  PopupMenuItem<String>(
                                                    value: 'favorites',
                                                    child: Row(
                                                      children: [
                                                        const Icon(
                                                          Icons
                                                              .favorite_outline_rounded,
                                                        ),
                                                        const SizedBox(
                                                          width: 12,
                                                        ),
                                                        Expanded(
                                                          child: Text(
                                                            LocaleProvider.tr(
                                                              'add_to_favorites',
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                  PopupMenuItem<String>(
                                                    value: 'playlist',
                                                    child: Row(
                                                      children: [
                                                        const Icon(
                                                          Icons
                                                              .playlist_add_rounded,
                                                        ),
                                                        const SizedBox(
                                                          width: 12,
                                                        ),
                                                        Expanded(
                                                          child: Text(
                                                            LocaleProvider.tr(
                                                              'add_to_playlist',
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                  PopupMenuItem<String>(
                                                    value: 'download',
                                                    child: Row(
                                                      children: [
                                                        const Icon(
                                                          Icons
                                                              .download_rounded,
                                                        ),
                                                        const SizedBox(
                                                          width: 12,
                                                        ),
                                                        Expanded(
                                                          child: Text(
                                                            LocaleProvider.tr(
                                                              'download',
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      if (_loadingAlbumSongs)
                                        Expanded(
                                          child: Center(
                                            child: LoadingIndicator(),
                                          ),
                                        )
                                      else if (_albumSongs.isEmpty)
                                        Expanded(
                                          child: Center(
                                            child: TranslatedText(
                                              'no_results',
                                              textAlign: TextAlign.center,
                                            ),
                                          ),
                                        )
                                      else
                                        Expanded(
                                          child: ListView.builder(
                                            key: PageStorageKey(
                                              "yt_album_details_list_${_currentAlbum?['id'] ?? 'unknown'}",
                                            ),
                                            padding: EdgeInsets.only(
                                              bottom: bottomSpace,
                                            ),
                                            itemCount: _albumSongs.length,
                                            itemBuilder: (context, idx) {
                                              final item = _albumSongs[idx];
                                              final videoId = item.videoId;
                                              final isSelected =
                                                  videoId != null &&
                                                  _selectedIndexes.contains(
                                                    'album-$videoId',
                                                  );

                                              final isDark =
                                                  Theme.of(
                                                    context,
                                                  ).brightness ==
                                                  Brightness.dark;
                                              final cardColor =
                                                  isAmoled && isDark
                                                  ? Colors.white.withAlpha(20)
                                                  : isDark
                                                  ? Theme.of(context)
                                                        .colorScheme
                                                        .secondary
                                                        .withValues(alpha: 0.06)
                                                  : Theme.of(context)
                                                        .colorScheme
                                                        .secondary
                                                        .withValues(
                                                          alpha: 0.07,
                                                        );

                                              final bool isFirst = idx == 0;
                                              final bool isLast =
                                                  idx == _albumSongs.length - 1;
                                              final bool isOnly =
                                                  _albumSongs.length == 1;

                                              BorderRadius borderRadius;
                                              if (isOnly) {
                                                borderRadius =
                                                    BorderRadius.circular(20);
                                              } else if (isFirst) {
                                                borderRadius =
                                                    const BorderRadius.only(
                                                      topLeft: Radius.circular(
                                                        20,
                                                      ),
                                                      topRight: Radius.circular(
                                                        20,
                                                      ),
                                                      bottomLeft:
                                                          Radius.circular(4),
                                                      bottomRight:
                                                          Radius.circular(4),
                                                    );
                                              } else if (isLast) {
                                                borderRadius =
                                                    const BorderRadius.only(
                                                      topLeft: Radius.circular(
                                                        4,
                                                      ),
                                                      topRight: Radius.circular(
                                                        4,
                                                      ),
                                                      bottomLeft:
                                                          Radius.circular(20),
                                                      bottomRight:
                                                          Radius.circular(20),
                                                    );
                                              } else {
                                                borderRadius =
                                                    BorderRadius.circular(4);
                                              }

                                              return Padding(
                                                padding: EdgeInsets.only(
                                                  bottom: isLast ? 0 : 4,
                                                ),
                                                child: Card(
                                                  color: cardColor,
                                                  margin: EdgeInsets.zero,
                                                  elevation: 0,
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius: borderRadius,
                                                  ),
                                                  child: InkWell(
                                                    borderRadius: borderRadius,
                                                    onLongPress: () {
                                                      HapticFeedback.selectionClick();
                                                      if (videoId == null) {
                                                        return;
                                                      }
                                                      if (!_isSelectionMode) {
                                                        _showSongActionsModal(
                                                          _albumSongs[idx],
                                                          selectionKey:
                                                              'album-$videoId',
                                                          fallbackThumbUrl:
                                                              _currentAlbum?['thumbUrl']
                                                                  as String?,
                                                          fallbackArtist:
                                                              _currentAlbum?['artist']
                                                                  as String?,
                                                        );
                                                        return;
                                                      }
                                                      setState(() {
                                                        final key =
                                                            'album-$videoId';
                                                        if (_selectedIndexes
                                                            .contains(key)) {
                                                          _selectedIndexes
                                                              .remove(key);
                                                          if (_selectedIndexes
                                                              .isEmpty) {
                                                            _isSelectionMode =
                                                                false;
                                                          }
                                                        } else {
                                                          _selectedIndexes.add(
                                                            key,
                                                          );
                                                          _isSelectionMode =
                                                              true;
                                                        }
                                                      });
                                                    },
                                                    onTap: () async {
                                                      if (_isSelectionMode) {
                                                        if (videoId == null) {
                                                          return;
                                                        }
                                                        setState(() {
                                                          final key =
                                                              'album-$videoId';
                                                          if (_selectedIndexes
                                                              .contains(key)) {
                                                            _selectedIndexes
                                                                .remove(key);
                                                            if (_selectedIndexes
                                                                .isEmpty) {
                                                              _isSelectionMode =
                                                                  false;
                                                            }
                                                          } else {
                                                            _selectedIndexes
                                                                .add(key);
                                                            _isSelectionMode =
                                                                true;
                                                          }
                                                        });
                                                      } else {
                                                        await _playInMainPlayer(
                                                          _albumSongs[idx],
                                                          fallbackThumbUrl:
                                                              _currentAlbum?['thumbUrl'],
                                                          fallbackArtist:
                                                              _currentAlbum?['artist'] ??
                                                              LocaleProvider.tr(
                                                                'artist_unknown',
                                                              ),
                                                          queueItems:
                                                              _albumSongs,
                                                          initialIndex: idx,
                                                          playAsQueue: true,
                                                          queueSource:
                                                              _currentAlbum?['title']
                                                                  ?.toString() ??
                                                              'YouTube Music',
                                                        );
                                                      }
                                                    },
                                                    child: ListTile(
                                                      contentPadding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 16,
                                                            vertical: 4,
                                                          ),
                                                      leading: Row(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          if (_isSelectionMode)
                                                            Checkbox(
                                                              value: isSelected,
                                                              onChanged: (checked) {
                                                                setState(() {
                                                                  if (videoId ==
                                                                      null) {
                                                                    return;
                                                                  }
                                                                  final key =
                                                                      'album-$videoId';
                                                                  if (checked ==
                                                                      true) {
                                                                    _selectedIndexes
                                                                        .add(
                                                                          key,
                                                                        );
                                                                  } else {
                                                                    _selectedIndexes
                                                                        .remove(
                                                                          key,
                                                                        );
                                                                    if (_selectedIndexes
                                                                        .isEmpty) {
                                                                      _isSelectionMode =
                                                                          false;
                                                                    }
                                                                  }
                                                                });
                                                              },
                                                            ),
                                                          SizedBox(
                                                            width: 50,
                                                            height: 50,
                                                            child: Center(
                                                              child: Text(
                                                                '${idx + 1}',
                                                                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w600,
                                                                  color:
                                                                      isAmoled
                                                                      ? Colors.white.withValues(
                                                                          alpha:
                                                                              0.85,
                                                                        )
                                                                      : Theme.of(
                                                                          context,
                                                                        ).colorScheme.onSurface.withValues(
                                                                          alpha:
                                                                              0.8,
                                                                        ),
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                      title: Text(
                                                        item.title ??
                                                            LocaleProvider.tr(
                                                              'title_unknown',
                                                            ),
                                                        style: Theme.of(
                                                          context,
                                                        ).textTheme.titleMedium,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                      ),
                                                      subtitle: Text(
                                                        _artistWithDurationText(
                                                          artist: item.artist,
                                                          fallbackArtist:
                                                              _currentAlbum?['artist']
                                                                  ?.toString(),
                                                          durationText:
                                                              item.durationText,
                                                          durationMs:
                                                              item.durationMs,
                                                        ),
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                          color: isAmoled
                                                              ? Colors.white
                                                                    .withValues(
                                                                      alpha:
                                                                          0.8,
                                                                    )
                                                              : null,
                                                        ),
                                                      ),
                                                      trailing:
                                                          _buildPlayTrailingButton(
                                                            item,
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                    ],
                                  ),
                                );
                              } else if (_expandedCategory == 'playlist') {
                                // Mostrar canciones de una playlist específica
                                return Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          if (_currentPlaylist != null) ...[
                                            if (_currentPlaylist!['thumbUrl'] !=
                                                null)
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  right: 12,
                                                ),
                                                child: ClipRRect(
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                  child: _buildSafeNetworkImage(
                                                    _currentPlaylist!['thumbUrl'],
                                                    width: 40,
                                                    height: 40,
                                                    fit: BoxFit.cover,
                                                    fallback: Container(
                                                      width: 40,
                                                      height: 40,
                                                      decoration: BoxDecoration(
                                                        color: isSystem
                                                            ? Theme.of(context)
                                                                  .colorScheme
                                                                  .secondaryContainer
                                                            : Theme.of(context)
                                                                  .colorScheme
                                                                  .surfaceContainer,
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                      ),
                                                      child: const Icon(
                                                        Icons.music_note,
                                                        size: 20,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    _currentPlaylist!['title'] ??
                                                        '',
                                                    style: Theme.of(
                                                      context,
                                                    ).textTheme.titleMedium,
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Container(
                                              width: 40,
                                              height: 40,
                                              decoration: BoxDecoration(
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.primary,
                                                shape: BoxShape.circle,
                                              ),
                                              child: PopupMenuButton<String>(
                                                tooltip: LocaleProvider.tr(
                                                  'want_more_options',
                                                ),
                                                padding: EdgeInsets.zero,
                                                icon: Icon(
                                                  Icons.more_vert,
                                                  size: 22,
                                                  color: isAmoled && isDark
                                                      ? Colors.black
                                                      : Theme.of(
                                                          context,
                                                        ).colorScheme.onPrimary,
                                                ),
                                                color: isAmoled
                                                    ? Colors.grey.shade900
                                                    : Theme.of(context)
                                                          .colorScheme
                                                          .surfaceContainerHigh,
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(16),
                                                ),
                                                onSelected: (value) async {
                                                  if (_playlistSongs.isEmpty) {
                                                    return;
                                                  }
                                                  if (value == 'favorites') {
                                                    await _addSongsToFavorites(
                                                      _playlistSongs,
                                                    );
                                                  } else if (value ==
                                                      'playlist') {
                                                    await _showAddMultipleSongsToPlaylistDialog(
                                                      _playlistSongs,
                                                    );
                                                  } else if (value ==
                                                      'download') {
                                                    await _downloadSongs(
                                                      _playlistSongs,
                                                    );
                                                  }
                                                },
                                                itemBuilder: (context) => [
                                                  PopupMenuItem<String>(
                                                    value: 'favorites',
                                                    child: Row(
                                                      children: [
                                                        const Icon(
                                                          Icons
                                                              .favorite_outline_rounded,
                                                        ),
                                                        const SizedBox(
                                                          width: 12,
                                                        ),
                                                        Expanded(
                                                          child: Text(
                                                            LocaleProvider.tr(
                                                              'add_to_favorites',
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                  PopupMenuItem<String>(
                                                    value: 'playlist',
                                                    child: Row(
                                                      children: [
                                                        const Icon(
                                                          Icons
                                                              .playlist_add_rounded,
                                                        ),
                                                        const SizedBox(
                                                          width: 12,
                                                        ),
                                                        Expanded(
                                                          child: Text(
                                                            LocaleProvider.tr(
                                                              'add_to_playlist',
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                  PopupMenuItem<String>(
                                                    value: 'download',
                                                    child: Row(
                                                      children: [
                                                        const Icon(
                                                          Icons
                                                              .download_rounded,
                                                        ),
                                                        const SizedBox(
                                                          width: 12,
                                                        ),
                                                        Expanded(
                                                          child: Text(
                                                            LocaleProvider.tr(
                                                              'download',
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      if (_loadingPlaylistSongs)
                                        Expanded(
                                          child: Center(
                                            child: LoadingIndicator(),
                                          ),
                                        )
                                      else if (_playlistSongs.isEmpty)
                                        Expanded(
                                          child: Center(
                                            child: TranslatedText(
                                              'no_results',
                                              textAlign: TextAlign.center,
                                            ),
                                          ),
                                        )
                                      else
                                        Expanded(
                                          child: ListView.builder(
                                            key: PageStorageKey(
                                              "yt_playlist_details_list_${_currentPlaylist?['id'] ?? 'unknown'}",
                                            ),
                                            padding: EdgeInsets.only(
                                              bottom: bottomSpace,
                                            ),
                                            itemCount: _playlistSongs.length,
                                            itemBuilder: (context, idx) {
                                              final item = _playlistSongs[idx];
                                              final videoId = item.videoId;
                                              final isSelected =
                                                  videoId != null &&
                                                  _selectedIndexes.contains(
                                                    'playlist-$videoId',
                                                  );

                                              final isDark =
                                                  Theme.of(
                                                    context,
                                                  ).brightness ==
                                                  Brightness.dark;
                                              final cardColor =
                                                  isAmoled && isDark
                                                  ? Colors.white.withAlpha(20)
                                                  : isDark
                                                  ? Theme.of(context)
                                                        .colorScheme
                                                        .secondary
                                                        .withValues(alpha: 0.06)
                                                  : Theme.of(context)
                                                        .colorScheme
                                                        .secondary
                                                        .withValues(
                                                          alpha: 0.07,
                                                        );

                                              final bool isFirst = idx == 0;
                                              final bool isLast =
                                                  idx ==
                                                  _playlistSongs.length - 1;
                                              final bool isOnly =
                                                  _playlistSongs.length == 1;

                                              BorderRadius borderRadius;
                                              if (isOnly) {
                                                borderRadius =
                                                    BorderRadius.circular(20);
                                              } else if (isFirst) {
                                                borderRadius =
                                                    const BorderRadius.only(
                                                      topLeft: Radius.circular(
                                                        20,
                                                      ),
                                                      topRight: Radius.circular(
                                                        20,
                                                      ),
                                                      bottomLeft:
                                                          Radius.circular(4),
                                                      bottomRight:
                                                          Radius.circular(4),
                                                    );
                                              } else if (isLast) {
                                                borderRadius =
                                                    const BorderRadius.only(
                                                      topLeft: Radius.circular(
                                                        4,
                                                      ),
                                                      topRight: Radius.circular(
                                                        4,
                                                      ),
                                                      bottomLeft:
                                                          Radius.circular(20),
                                                      bottomRight:
                                                          Radius.circular(20),
                                                    );
                                              } else {
                                                borderRadius =
                                                    BorderRadius.circular(4);
                                              }

                                              return Padding(
                                                padding: EdgeInsets.only(
                                                  bottom: isLast ? 0 : 4,
                                                ),
                                                child: Card(
                                                  color: cardColor,
                                                  margin: EdgeInsets.zero,
                                                  elevation: 0,
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius: borderRadius,
                                                  ),
                                                  child: InkWell(
                                                    borderRadius: borderRadius,
                                                    onLongPress: () {
                                                      HapticFeedback.selectionClick();
                                                      if (videoId == null) {
                                                        return;
                                                      }
                                                      if (!_isSelectionMode) {
                                                        _showSongActionsModal(
                                                          _playlistSongs[idx],
                                                          selectionKey:
                                                              'playlist-$videoId',
                                                          fallbackThumbUrl:
                                                              _currentPlaylist?['thumbUrl']
                                                                  as String?,
                                                          fallbackArtist:
                                                              _currentPlaylist?['artist']
                                                                  as String?,
                                                        );
                                                        return;
                                                      }
                                                      setState(() {
                                                        final key =
                                                            'playlist-$videoId';
                                                        if (_selectedIndexes
                                                            .contains(key)) {
                                                          _selectedIndexes
                                                              .remove(key);
                                                          if (_selectedIndexes
                                                              .isEmpty) {
                                                            _isSelectionMode =
                                                                false;
                                                          }
                                                        } else {
                                                          _selectedIndexes.add(
                                                            key,
                                                          );
                                                          _isSelectionMode =
                                                              true;
                                                        }
                                                      });
                                                    },
                                                    onTap: () async {
                                                      if (_isSelectionMode) {
                                                        if (videoId == null) {
                                                          return;
                                                        }
                                                        setState(() {
                                                          final key =
                                                              'playlist-$videoId';
                                                          if (_selectedIndexes
                                                              .contains(key)) {
                                                            _selectedIndexes
                                                                .remove(key);
                                                            if (_selectedIndexes
                                                                .isEmpty) {
                                                              _isSelectionMode =
                                                                  false;
                                                            }
                                                          } else {
                                                            _selectedIndexes
                                                                .add(key);
                                                            _isSelectionMode =
                                                                true;
                                                          }
                                                        });
                                                      } else {
                                                        await _playInMainPlayer(
                                                          _playlistSongs[idx],
                                                          fallbackThumbUrl:
                                                              _currentPlaylist?['thumbUrl'],
                                                          fallbackArtist:
                                                              LocaleProvider.tr(
                                                                'artist_unknown',
                                                              ),
                                                          queueItems:
                                                              _playlistSongs,
                                                          initialIndex: idx,
                                                          playAsQueue: true,
                                                          queueSource:
                                                              _currentPlaylist?['title']
                                                                  ?.toString() ??
                                                              'YouTube Music',
                                                        );
                                                      }
                                                    },
                                                    child: ListTile(
                                                      contentPadding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 16,
                                                            vertical: 4,
                                                          ),
                                                      leading: Row(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          if (_isSelectionMode)
                                                            Checkbox(
                                                              value: isSelected,
                                                              onChanged: (checked) {
                                                                setState(() {
                                                                  if (videoId ==
                                                                      null) {
                                                                    return;
                                                                  }
                                                                  final key =
                                                                      'playlist-$videoId';
                                                                  if (checked ==
                                                                      true) {
                                                                    _selectedIndexes
                                                                        .add(
                                                                          key,
                                                                        );
                                                                  } else {
                                                                    _selectedIndexes
                                                                        .remove(
                                                                          key,
                                                                        );
                                                                    if (_selectedIndexes
                                                                        .isEmpty) {
                                                                      _isSelectionMode =
                                                                          false;
                                                                    }
                                                                  }
                                                                });
                                                              },
                                                            ),
                                                          ClipRRect(
                                                            borderRadius:
                                                                BorderRadius.circular(
                                                                  8,
                                                                ),
                                                            child:
                                                                item.thumbUrl !=
                                                                    null
                                                                ? _buildSafeNetworkImage(
                                                                    item.thumbUrl!,
                                                                    width: 50,
                                                                    height: 50,
                                                                    fit: BoxFit
                                                                        .cover,
                                                                  )
                                                                : (_currentPlaylist !=
                                                                          null &&
                                                                      _currentPlaylist!['thumbUrl'] !=
                                                                          null &&
                                                                      (_currentPlaylist!['thumbUrl']
                                                                              as String)
                                                                          .isNotEmpty)
                                                                ? _buildSafeNetworkImage(
                                                                    _currentPlaylist!['thumbUrl'],
                                                                    width: 50,
                                                                    height: 50,
                                                                    fit: BoxFit
                                                                        .cover,
                                                                    fallback: Container(
                                                                      width: 50,
                                                                      height:
                                                                          50,
                                                                      decoration: BoxDecoration(
                                                                        color:
                                                                            isSystem
                                                                            ? Theme.of(
                                                                                context,
                                                                              ).colorScheme.secondaryContainer
                                                                            : Theme.of(
                                                                                context,
                                                                              ).colorScheme.surfaceContainer,
                                                                        borderRadius:
                                                                            BorderRadius.circular(
                                                                              8,
                                                                            ),
                                                                      ),
                                                                      child: const Icon(
                                                                        Icons
                                                                            .music_note,
                                                                      ),
                                                                    ),
                                                                  )
                                                                : Container(
                                                                    width: 50,
                                                                    height: 50,
                                                                    decoration: BoxDecoration(
                                                                      color: Colors
                                                                          .grey[300],
                                                                      borderRadius:
                                                                          BorderRadius.circular(
                                                                            8,
                                                                          ),
                                                                    ),
                                                                    child: const Icon(
                                                                      Icons
                                                                          .music_note,
                                                                      color: Colors
                                                                          .grey,
                                                                    ),
                                                                  ),
                                                          ),
                                                        ],
                                                      ),
                                                      title: Text(
                                                        item.title ??
                                                            LocaleProvider.tr(
                                                              'title_unknown',
                                                            ),
                                                        style: Theme.of(
                                                          context,
                                                        ).textTheme.titleMedium,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                      ),
                                                      subtitle: Text(
                                                        _artistWithDurationText(
                                                          artist: item.artist,
                                                          fallbackArtist:
                                                              LocaleProvider.tr(
                                                                'artist_unknown',
                                                              ),
                                                          durationText:
                                                              item.durationText,
                                                          durationMs:
                                                              item.durationMs,
                                                        ),
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                          color: isAmoled
                                                              ? Colors.white
                                                                    .withValues(
                                                                      alpha:
                                                                          0.8,
                                                                    )
                                                              : null,
                                                        ),
                                                      ),
                                                      trailing: _buildPlayTrailingButton(
                                                        item,
                                                        fallbackThumbUrl:
                                                            _currentPlaylist?['thumbUrl'],
                                                        fallbackArtist:
                                                            LocaleProvider.tr(
                                                              'artist_unknown',
                                                            ),
                                                        queueItems:
                                                            _playlistSongs,
                                                        initialIndex: idx,
                                                        playAsQueue: true,
                                                        queueSource:
                                                            _currentPlaylist?['title']
                                                                ?.toString() ??
                                                            'YouTube Music',
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                    ],
                                  ),
                                );
                              } else if (_expandedCategory == 'playlists') {
                                // Mostrar solo todas las listas de reproducción con botón de volver
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: ListView.builder(
                                        key: PageStorageKey(
                                          'yt_playlists_list_$_searchSessionId',
                                        ),
                                        controller: _playlistScrollController,
                                        padding: EdgeInsets.only(
                                          bottom: bottomSpace,
                                        ),
                                        itemCount:
                                            _playlistResults.length +
                                            (_loadingMorePlaylists ? 1 : 0),
                                        itemBuilder: (context, idx) {
                                          if (_loadingMorePlaylists &&
                                              idx == _playlistResults.length) {
                                            return Container(
                                              padding: const EdgeInsets.all(16),
                                              child: Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  SizedBox(
                                                    width: 20,
                                                    height: 20,
                                                    child: LoadingIndicator(),
                                                  ),
                                                  const SizedBox(width: 12),
                                                  TranslatedText(
                                                    'loading_more',
                                                    style: TextStyle(
                                                      fontSize: 14,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            );
                                          }
                                          final playlist =
                                              _playlistResults[idx];

                                          final isDark =
                                              Theme.of(context).brightness ==
                                              Brightness.dark;
                                          final cardColor = isAmoled && isDark
                                              ? Colors.white.withAlpha(20)
                                              : isDark
                                              ? Theme.of(context)
                                                    .colorScheme
                                                    .secondary
                                                    .withValues(alpha: 0.06)
                                              : Theme.of(context)
                                                    .colorScheme
                                                    .secondary
                                                    .withValues(alpha: 0.07);

                                          final bool isFirst = idx == 0;
                                          final bool isLast =
                                              idx ==
                                              _playlistResults.length - 1;
                                          final bool isOnly =
                                              _playlistResults.length == 1;

                                          BorderRadius borderRadius;
                                          if (isOnly) {
                                            borderRadius =
                                                BorderRadius.circular(20);
                                          } else if (isFirst) {
                                            borderRadius =
                                                const BorderRadius.only(
                                                  topLeft: Radius.circular(20),
                                                  topRight: Radius.circular(20),
                                                  bottomLeft: Radius.circular(
                                                    4,
                                                  ),
                                                  bottomRight: Radius.circular(
                                                    4,
                                                  ),
                                                );
                                          } else if (isLast) {
                                            borderRadius =
                                                const BorderRadius.only(
                                                  topLeft: Radius.circular(4),
                                                  topRight: Radius.circular(4),
                                                  bottomLeft: Radius.circular(
                                                    20,
                                                  ),
                                                  bottomRight: Radius.circular(
                                                    20,
                                                  ),
                                                );
                                          } else {
                                            borderRadius =
                                                BorderRadius.circular(4);
                                          }

                                          return LayoutBuilder(
                                            builder: (context, constraints) {
                                              final titleText =
                                                  playlist['title'] ??
                                                  LocaleProvider.tr(
                                                    'title_unknown',
                                                  );
                                              final style = Theme.of(
                                                context,
                                              ).textTheme.titleMedium;

                                              final textPainter = TextPainter(
                                                text: TextSpan(
                                                  text: titleText,
                                                  style: style,
                                                ),
                                                maxLines: 2,
                                                textDirection:
                                                    TextDirection.ltr,
                                              );

                                              // Estimated available width: Width - horizontal padding (32) - leading (50) - gap (16) - trailing (48) - gap (16)
                                              final availableWidth =
                                                  constraints.maxWidth - 162;
                                              textPainter.layout(
                                                maxWidth: availableWidth > 0
                                                    ? availableWidth
                                                    : 0,
                                              );
                                              final isTwoLines =
                                                  textPainter
                                                      .computeLineMetrics()
                                                      .length >
                                                  1;
                                              final verticalPadding = isTwoLines
                                                  ? 5.0
                                                  : 12.0;

                                              return Padding(
                                                padding: EdgeInsets.only(
                                                  bottom: isLast ? 0 : 4,
                                                  left: 16,
                                                  right: 16,
                                                ),
                                                child: Card(
                                                  color: cardColor,
                                                  margin: EdgeInsets.zero,
                                                  elevation: 0,
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius: borderRadius,
                                                  ),
                                                  child: InkWell(
                                                    borderRadius: borderRadius,
                                                    onTap: () async {
                                                      if (playlist['browseId'] ==
                                                          null) {
                                                        return;
                                                      }
                                                      setState(() {
                                                        _expandedCategory =
                                                            'playlist';
                                                        _loadingPlaylistSongs =
                                                            true;
                                                        _playlistSongs = [];
                                                        _currentPlaylist = {
                                                          'title':
                                                              playlist['title'],
                                                          'thumbUrl':
                                                              playlist['thumbUrl'],
                                                          'id':
                                                              playlist['browseId'],
                                                        };
                                                      });
                                                      final songs =
                                                          await getPlaylistSongs(
                                                            playlist['browseId']!,
                                                          );
                                                      if (!mounted) return;
                                                      setState(() {
                                                        _playlistSongs = songs;
                                                        _loadingPlaylistSongs =
                                                            false;
                                                      });
                                                    },
                                                    child: ListTile(
                                                      contentPadding:
                                                          EdgeInsets.symmetric(
                                                            horizontal: 16,
                                                            vertical:
                                                                verticalPadding,
                                                          ),
                                                      leading: ClipRRect(
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                        child:
                                                            playlist['thumbUrl'] !=
                                                                null
                                                            ? _buildSafeNetworkImage(
                                                                playlist['thumbUrl']!,
                                                                width: 50,
                                                                height: 50,
                                                                fit: BoxFit
                                                                    .cover,
                                                                fallback: Container(
                                                                  width: 50,
                                                                  height: 50,
                                                                  decoration: BoxDecoration(
                                                                    color:
                                                                        isSystem
                                                                        ? Theme.of(
                                                                            context,
                                                                          ).colorScheme.secondaryContainer
                                                                        : Theme.of(
                                                                            context,
                                                                          ).colorScheme.surfaceContainer,
                                                                    borderRadius:
                                                                        BorderRadius.circular(
                                                                          8,
                                                                        ),
                                                                  ),
                                                                  child: const Icon(
                                                                    Icons
                                                                        .playlist_play,
                                                                    size: 24,
                                                                  ),
                                                                ),
                                                              )
                                                            : Container(
                                                                width: 50,
                                                                height: 50,
                                                                decoration: BoxDecoration(
                                                                  color: Colors
                                                                      .grey[300],
                                                                  borderRadius:
                                                                      BorderRadius.circular(
                                                                        8,
                                                                      ),
                                                                ),
                                                                child: const Icon(
                                                                  Icons
                                                                      .playlist_play,
                                                                  size: 24,
                                                                  color: Colors
                                                                      .grey,
                                                                ),
                                                              ),
                                                      ),
                                                      title: Text(
                                                        playlist['title'] ??
                                                            LocaleProvider.tr(
                                                              'title_unknown',
                                                            ),
                                                        style: Theme.of(
                                                          context,
                                                        ).textTheme.titleMedium,
                                                        maxLines: 2,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                      ),
                                                      trailing: IconButton(
                                                        style: IconButton.styleFrom(
                                                          backgroundColor:
                                                              Theme.of(context)
                                                                  .colorScheme
                                                                  .primary
                                                                  .withAlpha(
                                                                    20,
                                                                  ),
                                                        ),
                                                        icon: const Icon(
                                                          Icons.link_rounded,
                                                          size: 20,
                                                        ),
                                                        tooltip:
                                                            LocaleProvider.tr(
                                                              'copy_link',
                                                            ),
                                                        onPressed: () {
                                                          Clipboard.setData(
                                                            ClipboardData(
                                                              text:
                                                                  'https://www.youtube.com/playlist?list=${playlist['browseId']}',
                                                            ),
                                                          );
                                                        },
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              );
                                            },
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                );
                              } else {
                                // Vista normal: resumen de ambas categorías
                                return ListView(
                                  key: PageStorageKey(
                                    'yt_main_results_list_$_searchSessionId',
                                  ),
                                  padding: EdgeInsets.only(bottom: bottomSpace),
                                  children: [
                                    // Sección Artistas
                                    if (_artistResults.isNotEmpty)
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          const SizedBox(height: 24),
                                          Padding(
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 4,
                                              horizontal: 16,
                                            ),
                                            child: Row(
                                              children: [
                                                const SizedBox(width: 14),
                                                Text(
                                                  LocaleProvider.tr('artists'),
                                                  style: TextStyle(
                                                    fontSize: 16,
                                                    fontWeight: FontWeight.w600,
                                                    color: Theme.of(
                                                      context,
                                                    ).colorScheme.primary,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(height: 12),
                                          Column(
                                            children: _artistResults.take(3).toList().asMap().entries.map((
                                              entry,
                                            ) {
                                              final idx = entry.key;
                                              final artist = entry.value;
                                              final artistName =
                                                  artist['name'] ??
                                                  LocaleProvider.tr(
                                                    'artist_unknown',
                                                  );
                                              final thumbUrl =
                                                  artist['thumbUrl'];
                                              final browseId =
                                                  artist['browseId'];
                                              final resultsCount =
                                                  _artistResults.take(3).length;

                                              final isDark =
                                                  Theme.of(
                                                    context,
                                                  ).brightness ==
                                                  Brightness.dark;
                                              final cardColor =
                                                  isAmoled && isDark
                                                  ? Colors.white.withAlpha(20)
                                                  : isDark
                                                  ? Theme.of(context)
                                                        .colorScheme
                                                        .secondary
                                                        .withValues(alpha: 0.06)
                                                  : Theme.of(context)
                                                        .colorScheme
                                                        .secondary
                                                        .withValues(
                                                          alpha: 0.07,
                                                        );

                                              final bool isFirst = idx == 0;
                                              final bool isLast =
                                                  idx == resultsCount - 1;
                                              final bool isOnly =
                                                  resultsCount == 1;

                                              BorderRadius borderRadius;
                                              if (isOnly) {
                                                borderRadius =
                                                    BorderRadius.circular(20);
                                              } else if (isFirst) {
                                                borderRadius =
                                                    const BorderRadius.only(
                                                      topLeft: Radius.circular(
                                                        20,
                                                      ),
                                                      topRight: Radius.circular(
                                                        20,
                                                      ),
                                                      bottomLeft:
                                                          Radius.circular(4),
                                                      bottomRight:
                                                          Radius.circular(4),
                                                    );
                                              } else if (isLast) {
                                                borderRadius =
                                                    const BorderRadius.only(
                                                      topLeft: Radius.circular(
                                                        4,
                                                      ),
                                                      topRight: Radius.circular(
                                                        4,
                                                      ),
                                                      bottomLeft:
                                                          Radius.circular(20),
                                                      bottomRight:
                                                          Radius.circular(20),
                                                    );
                                              } else {
                                                borderRadius =
                                                    BorderRadius.circular(4);
                                              }

                                              return Padding(
                                                padding: EdgeInsets.only(
                                                  bottom: isLast ? 0 : 4,
                                                  left: 16,
                                                  right: 16,
                                                ),
                                                child: Card(
                                                  color: cardColor,
                                                  margin: EdgeInsets.zero,
                                                  elevation: 0,
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius: borderRadius,
                                                  ),
                                                  child: InkWell(
                                                    borderRadius: borderRadius,
                                                    onTap: () {
                                                      Navigator.of(
                                                        context,
                                                      ).push(
                                                        PageRouteBuilder(
                                                          settings:
                                                              const RouteSettings(
                                                                name: '/artist',
                                                              ),
                                                          pageBuilder:
                                                              (
                                                                context,
                                                                animation,
                                                                secondaryAnimation,
                                                              ) => ArtistScreen(
                                                                artistName:
                                                                    artistName,
                                                                browseId:
                                                                    browseId,
                                                              ),
                                                          transitionsBuilder:
                                                              (
                                                                context,
                                                                animation,
                                                                secondaryAnimation,
                                                                child,
                                                              ) {
                                                                const begin =
                                                                    Offset(
                                                                      1.0,
                                                                      0.0,
                                                                    );
                                                                const end =
                                                                    Offset.zero;
                                                                const curve = Curves
                                                                    .easeInOutCubic;
                                                                var tween =
                                                                    Tween(
                                                                      begin:
                                                                          begin,
                                                                      end: end,
                                                                    ).chain(
                                                                      CurveTween(
                                                                        curve:
                                                                            curve,
                                                                      ),
                                                                    );
                                                                return SlideTransition(
                                                                  position:
                                                                      animation
                                                                          .drive(
                                                                            tween,
                                                                          ),
                                                                  child: child,
                                                                );
                                                              },
                                                          transitionDuration:
                                                              const Duration(
                                                                milliseconds:
                                                                    300,
                                                              ),
                                                        ),
                                                      );
                                                    },
                                                    child: ListTile(
                                                      contentPadding:
                                                          EdgeInsets.symmetric(
                                                            horizontal: 16,
                                                            vertical:
                                                                artist['subscribers'] ==
                                                                    null
                                                                ? 12
                                                                : 5,
                                                          ),
                                                      leading: ClipRRect(
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              25,
                                                            ),
                                                        child:
                                                            thumbUrl != null &&
                                                                thumbUrl
                                                                    .isNotEmpty
                                                            ? _buildSafeNetworkImage(
                                                                thumbUrl,
                                                                width: 50,
                                                                height: 50,
                                                                fit: BoxFit
                                                                    .cover,
                                                              )
                                                            : Container(
                                                                width: 50,
                                                                height: 50,
                                                                decoration: BoxDecoration(
                                                                  color:
                                                                      isSystem
                                                                      ? Theme.of(
                                                                          context,
                                                                        ).colorScheme.secondaryContainer
                                                                      : Theme.of(
                                                                          context,
                                                                        ).colorScheme.surfaceContainer,
                                                                  shape: BoxShape
                                                                      .circle,
                                                                ),
                                                                child: const Icon(
                                                                  Icons.person,
                                                                  size: 28,
                                                                ),
                                                              ),
                                                      ),
                                                      title: Text(
                                                        artistName,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: Theme.of(
                                                          context,
                                                        ).textTheme.titleMedium,
                                                      ),
                                                      subtitle:
                                                          artist['subscribers'] !=
                                                              null
                                                          ? Text(
                                                              _formatArtistSubtitle(
                                                                artist['subscribers'],
                                                              )!,
                                                              maxLines: 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              style: TextStyle(
                                                                color: isAmoled
                                                                    ? Colors
                                                                          .white
                                                                          .withValues(
                                                                            alpha:
                                                                                0.8,
                                                                          )
                                                                    : null,
                                                              ),
                                                            )
                                                          : null,
                                                      trailing: IconButton(
                                                        onPressed: () {
                                                          Navigator.of(
                                                            context,
                                                          ).push(
                                                            PageRouteBuilder(
                                                              settings:
                                                                  const RouteSettings(
                                                                    name:
                                                                        '/artist',
                                                                  ),
                                                              pageBuilder:
                                                                  (
                                                                    context,
                                                                    animation,
                                                                    secondaryAnimation,
                                                                  ) => ArtistScreen(
                                                                    artistName:
                                                                        artistName,
                                                                    browseId:
                                                                        browseId,
                                                                  ),
                                                              transitionsBuilder:
                                                                  (
                                                                    context,
                                                                    animation,
                                                                    secondaryAnimation,
                                                                    child,
                                                                  ) {
                                                                    const begin =
                                                                        Offset(
                                                                          1.0,
                                                                          0.0,
                                                                        );
                                                                    const end =
                                                                        Offset
                                                                            .zero;
                                                                    const curve =
                                                                        Curves
                                                                            .easeInOutCubic;
                                                                    var tween =
                                                                        Tween(
                                                                          begin:
                                                                              begin,
                                                                          end:
                                                                              end,
                                                                        ).chain(
                                                                          CurveTween(
                                                                            curve:
                                                                                curve,
                                                                          ),
                                                                        );
                                                                    return SlideTransition(
                                                                      position: animation
                                                                          .drive(
                                                                            tween,
                                                                          ),
                                                                      child:
                                                                          child,
                                                                    );
                                                                  },
                                                              transitionDuration:
                                                                  const Duration(
                                                                    milliseconds:
                                                                        300,
                                                                  ),
                                                            ),
                                                          );
                                                        },
                                                        icon: const Icon(
                                                          Icons.chevron_right,
                                                          size: 20,
                                                        ),
                                                        style: IconButton.styleFrom(
                                                          backgroundColor:
                                                              Theme.of(context)
                                                                  .colorScheme
                                                                  .primary
                                                                  .withAlpha(
                                                                    20,
                                                                  ),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              );
                                            }).toList(),
                                          ),
                                        ],
                                      ),
                                    // Sección Canciones
                                    if (_songResults.isNotEmpty) ...[
                                      const SizedBox(height: 24),
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          InkWell(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            onTap: () {
                                              setState(() {
                                                _expandedCategory = 'songs';
                                                _animateToCategory('songs');
                                              });
                                            },
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 4,
                                                    horizontal: 16,
                                                  ),
                                              child: Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment
                                                        .spaceBetween,
                                                children: [
                                                  Row(
                                                    children: [
                                                      SizedBox(width: 14),
                                                      Text(
                                                        LocaleProvider.tr(
                                                          'songs_search',
                                                        ),
                                                        style: TextStyle(
                                                          fontSize: 16,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                          color: Theme.of(
                                                            context,
                                                          ).colorScheme.primary,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                  Icon(
                                                    Icons.chevron_right,
                                                    color: Theme.of(
                                                      context,
                                                    ).colorScheme.onSurface,
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 12),
                                          AnimatedSize(
                                            duration: const Duration(
                                              milliseconds: 300,
                                            ),
                                            curve: Curves.easeInOut,
                                            child: Column(
                                              children: _songResults.take(3).map((
                                                item,
                                              ) {
                                                final index = _songResults
                                                    .indexOf(item);
                                                final videoId = item.videoId;
                                                final isSelected =
                                                    videoId != null &&
                                                    _selectedIndexes.contains(
                                                      'song-$videoId',
                                                    );

                                                final isDark =
                                                    Theme.of(
                                                      context,
                                                    ).brightness ==
                                                    Brightness.dark;
                                                final cardColor =
                                                    isAmoled && isDark
                                                    ? Colors.white.withAlpha(20)
                                                    : isDark
                                                    ? Theme.of(context)
                                                          .colorScheme
                                                          .secondary
                                                          .withValues(
                                                            alpha: 0.06,
                                                          )
                                                    : Theme.of(context)
                                                          .colorScheme
                                                          .secondary
                                                          .withValues(
                                                            alpha: 0.07,
                                                          );

                                                final int totalToShow =
                                                    _songResults.length < 3
                                                    ? _songResults.length
                                                    : 3;
                                                final bool isFirst = index == 0;
                                                final bool isLast =
                                                    index == totalToShow - 1;
                                                final bool isOnly =
                                                    totalToShow == 1;

                                                BorderRadius borderRadius;
                                                if (isOnly) {
                                                  borderRadius =
                                                      BorderRadius.circular(20);
                                                } else if (isFirst) {
                                                  borderRadius =
                                                      const BorderRadius.only(
                                                        topLeft:
                                                            Radius.circular(20),
                                                        topRight:
                                                            Radius.circular(20),
                                                        bottomLeft:
                                                            Radius.circular(4),
                                                        bottomRight:
                                                            Radius.circular(4),
                                                      );
                                                } else if (isLast) {
                                                  borderRadius =
                                                      const BorderRadius.only(
                                                        topLeft:
                                                            Radius.circular(4),
                                                        topRight:
                                                            Radius.circular(4),
                                                        bottomLeft:
                                                            Radius.circular(20),
                                                        bottomRight:
                                                            Radius.circular(20),
                                                      );
                                                } else {
                                                  borderRadius =
                                                      BorderRadius.circular(4);
                                                }

                                                return Padding(
                                                  padding: EdgeInsets.only(
                                                    bottom: isLast ? 0 : 4,
                                                    left: 16,
                                                    right: 16,
                                                  ),
                                                  child: Card(
                                                    color: cardColor,
                                                    margin: EdgeInsets.zero,
                                                    elevation: 0,
                                                    shape:
                                                        RoundedRectangleBorder(
                                                          borderRadius:
                                                              borderRadius,
                                                        ),
                                                    child: InkWell(
                                                      borderRadius:
                                                          borderRadius,
                                                      onLongPress: () {
                                                        HapticFeedback.selectionClick();
                                                        final item =
                                                            _songResults[index];
                                                        final videoId =
                                                            item.videoId;
                                                        if (videoId == null) {
                                                          return;
                                                        }
                                                        if (_isSelectionMode) {
                                                          _toggleSelection(
                                                            index,
                                                            isVideo: false,
                                                          );
                                                          return;
                                                        }
                                                        _showSongActionsModal(
                                                          item,
                                                          selectionKey:
                                                              'song-$videoId',
                                                        );
                                                      },
                                                      onTap: () async {
                                                        if (_isSelectionMode) {
                                                          _toggleSelection(
                                                            index,
                                                            isVideo: false,
                                                          );
                                                        } else {
                                                          await _playInMainPlayer(
                                                            _songResults[index],
                                                          );
                                                        }
                                                      },
                                                      child: ListTile(
                                                        contentPadding:
                                                            const EdgeInsets.symmetric(
                                                              horizontal: 16,
                                                              vertical: 4,
                                                            ),
                                                        leading: Row(
                                                          mainAxisSize:
                                                              MainAxisSize.min,
                                                          children: [
                                                            if (_isSelectionMode)
                                                              Checkbox(
                                                                value:
                                                                    isSelected,
                                                                onChanged: (checked) {
                                                                  setState(() {
                                                                    if (videoId ==
                                                                        null) {
                                                                      return;
                                                                    }
                                                                    final key =
                                                                        'song-$videoId';
                                                                    if (checked ==
                                                                        true) {
                                                                      _selectedIndexes
                                                                          .add(
                                                                            key,
                                                                          );
                                                                    } else {
                                                                      _selectedIndexes
                                                                          .remove(
                                                                            key,
                                                                          );
                                                                      if (_selectedIndexes
                                                                          .isEmpty) {
                                                                        _isSelectionMode =
                                                                            false;
                                                                      }
                                                                    }
                                                                  });
                                                                },
                                                              ),
                                                            ClipRRect(
                                                              borderRadius:
                                                                  BorderRadius.circular(
                                                                    8,
                                                                  ),
                                                              child:
                                                                  item.thumbUrl !=
                                                                      null
                                                                  ? _buildSafeNetworkImage(
                                                                      item.thumbUrl!,
                                                                      width: 50,
                                                                      height:
                                                                          50,
                                                                      fit: BoxFit
                                                                          .cover,
                                                                      fallback: Container(
                                                                        width:
                                                                            50,
                                                                        height:
                                                                            50,
                                                                        decoration: BoxDecoration(
                                                                          color:
                                                                              isSystem
                                                                              ? Theme.of(
                                                                                  context,
                                                                                ).colorScheme.secondaryContainer
                                                                              : Theme.of(
                                                                                  context,
                                                                                ).colorScheme.surfaceContainer,
                                                                          borderRadius:
                                                                              BorderRadius.circular(
                                                                                8,
                                                                              ),
                                                                        ),
                                                                        child: const Icon(
                                                                          Icons
                                                                              .music_note,
                                                                          size:
                                                                              24,
                                                                          color:
                                                                              Colors.grey,
                                                                        ),
                                                                      ),
                                                                    )
                                                                  : Container(
                                                                      width: 50,
                                                                      height:
                                                                          50,
                                                                      decoration: BoxDecoration(
                                                                        color: Colors
                                                                            .grey[300],
                                                                        borderRadius:
                                                                            BorderRadius.circular(
                                                                              8,
                                                                            ),
                                                                      ),
                                                                      child: const Icon(
                                                                        Icons
                                                                            .music_note,
                                                                        size:
                                                                            24,
                                                                      ),
                                                                    ),
                                                            ),
                                                          ],
                                                        ),
                                                        title: Text(
                                                          item.title ??
                                                              LocaleProvider.tr(
                                                                'title_unknown',
                                                              ),
                                                          style:
                                                              Theme.of(context)
                                                                  .textTheme
                                                                  .titleMedium,
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                        ),
                                                        subtitle: Text(
                                                          _artistWithDurationText(
                                                            artist: item.artist,
                                                            fallbackArtist:
                                                                LocaleProvider.tr(
                                                                  'artist_unknown',
                                                                ),
                                                            durationText: item
                                                                .durationText,
                                                            durationMs:
                                                                item.durationMs,
                                                          ),
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style: TextStyle(
                                                            color: isAmoled
                                                                ? Colors.white
                                                                      .withValues(
                                                                        alpha:
                                                                            0.8,
                                                                      )
                                                                : null,
                                                          ),
                                                        ),
                                                        trailing:
                                                            _buildPlayTrailingButton(
                                                              item,
                                                            ),
                                                      ),
                                                    ),
                                                  ),
                                                );
                                              }).toList(),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                    // Sección Videos
                                    if (_videoResults.isNotEmpty) ...[
                                      SizedBox(height: 24),
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          InkWell(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            onTap: () {
                                              setState(() {
                                                _expandedCategory = 'videos';
                                                _animateToCategory('videos');
                                              });
                                            },
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 4,
                                                    horizontal: 16,
                                                  ),
                                              child: Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment
                                                        .spaceBetween,
                                                children: [
                                                  Row(
                                                    children: [
                                                      const SizedBox(width: 14),
                                                      Text(
                                                        LocaleProvider.tr(
                                                          'videos',
                                                        ),
                                                        style: TextStyle(
                                                          fontSize: 16,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                          color: Theme.of(
                                                            context,
                                                          ).colorScheme.primary,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                  Icon(Icons.chevron_right),
                                                ],
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 12),
                                          AnimatedSize(
                                            duration: const Duration(
                                              milliseconds: 300,
                                            ),
                                            curve: Curves.easeInOut,
                                            child: Column(
                                              children: _videoResults.take(3).map((
                                                item,
                                              ) {
                                                final index = _videoResults
                                                    .indexOf(item);
                                                final videoId = item.videoId;
                                                final isSelected =
                                                    videoId != null &&
                                                    _selectedIndexes.contains(
                                                      'video-$videoId',
                                                    );

                                                final isDark =
                                                    Theme.of(
                                                      context,
                                                    ).brightness ==
                                                    Brightness.dark;
                                                final cardColor =
                                                    isAmoled && isDark
                                                    ? Colors.white.withAlpha(20)
                                                    : isDark
                                                    ? Theme.of(context)
                                                          .colorScheme
                                                          .secondary
                                                          .withValues(
                                                            alpha: 0.06,
                                                          )
                                                    : Theme.of(context)
                                                          .colorScheme
                                                          .secondary
                                                          .withValues(
                                                            alpha: 0.07,
                                                          );

                                                final int totalToShow =
                                                    _videoResults.length < 3
                                                    ? _videoResults.length
                                                    : 3;
                                                final bool isFirst = index == 0;
                                                final bool isLast =
                                                    index == totalToShow - 1;
                                                final bool isOnly =
                                                    totalToShow == 1;

                                                BorderRadius borderRadius;
                                                if (isOnly) {
                                                  borderRadius =
                                                      BorderRadius.circular(20);
                                                } else if (isFirst) {
                                                  borderRadius =
                                                      const BorderRadius.only(
                                                        topLeft:
                                                            Radius.circular(20),
                                                        topRight:
                                                            Radius.circular(20),
                                                        bottomLeft:
                                                            Radius.circular(4),
                                                        bottomRight:
                                                            Radius.circular(4),
                                                      );
                                                } else if (isLast) {
                                                  borderRadius =
                                                      const BorderRadius.only(
                                                        topLeft:
                                                            Radius.circular(4),
                                                        topRight:
                                                            Radius.circular(4),
                                                        bottomLeft:
                                                            Radius.circular(20),
                                                        bottomRight:
                                                            Radius.circular(20),
                                                      );
                                                } else {
                                                  borderRadius =
                                                      BorderRadius.circular(4);
                                                }

                                                return Padding(
                                                  padding: EdgeInsets.only(
                                                    bottom: isLast ? 0 : 4,
                                                    left: 16,
                                                    right: 16,
                                                  ),
                                                  child: Card(
                                                    color: cardColor,
                                                    margin: EdgeInsets.zero,
                                                    elevation: 0,
                                                    shape:
                                                        RoundedRectangleBorder(
                                                          borderRadius:
                                                              borderRadius,
                                                        ),
                                                    child: InkWell(
                                                      borderRadius:
                                                          borderRadius,
                                                      onLongPress: () {
                                                        HapticFeedback.selectionClick();
                                                        final item =
                                                            _videoResults[index];
                                                        final videoId =
                                                            item.videoId;
                                                        if (videoId == null) {
                                                          return;
                                                        }
                                                        if (_isSelectionMode) {
                                                          _toggleSelection(
                                                            index,
                                                            isVideo: true,
                                                          );
                                                          return;
                                                        }
                                                        _showSongActionsModal(
                                                          item,
                                                          selectionKey:
                                                              'video-$videoId',
                                                        );
                                                      },
                                                      onTap: () async {
                                                        if (_isSelectionMode) {
                                                          _toggleSelection(
                                                            index,
                                                            isVideo: true,
                                                          );
                                                        } else {
                                                          await _playInMainPlayer(
                                                            _videoResults[index],
                                                          );
                                                        }
                                                      },
                                                      child: ListTile(
                                                        contentPadding:
                                                            const EdgeInsets.symmetric(
                                                              horizontal: 16,
                                                              vertical: 4,
                                                            ),
                                                        leading: Row(
                                                          mainAxisSize:
                                                              MainAxisSize.min,
                                                          children: [
                                                            if (_isSelectionMode)
                                                              Checkbox(
                                                                value:
                                                                    isSelected,
                                                                onChanged: (checked) {
                                                                  setState(() {
                                                                    if (videoId ==
                                                                        null) {
                                                                      return;
                                                                    }
                                                                    final key =
                                                                        'video-$videoId';
                                                                    if (checked ==
                                                                        true) {
                                                                      _selectedIndexes
                                                                          .add(
                                                                            key,
                                                                          );
                                                                    } else {
                                                                      _selectedIndexes
                                                                          .remove(
                                                                            key,
                                                                          );
                                                                      if (_selectedIndexes
                                                                          .isEmpty) {
                                                                        _isSelectionMode =
                                                                            false;
                                                                      }
                                                                    }
                                                                  });
                                                                },
                                                              ),
                                                            ClipRRect(
                                                              borderRadius:
                                                                  BorderRadius.circular(
                                                                    8,
                                                                  ),
                                                              child:
                                                                  item.thumbUrl !=
                                                                      null
                                                                  ? _buildSafeNetworkImage(
                                                                      item.thumbUrl!,
                                                                      width: 50,
                                                                      height:
                                                                          50,
                                                                      fit: BoxFit
                                                                          .cover,
                                                                      fallback: Container(
                                                                        width:
                                                                            50,
                                                                        height:
                                                                            50,
                                                                        decoration: BoxDecoration(
                                                                          color:
                                                                              isSystem
                                                                              ? Theme.of(
                                                                                  context,
                                                                                ).colorScheme.secondaryContainer
                                                                              : Theme.of(
                                                                                  context,
                                                                                ).colorScheme.surfaceContainer,
                                                                          borderRadius:
                                                                              BorderRadius.circular(
                                                                                8,
                                                                              ),
                                                                        ),
                                                                        child: const Icon(
                                                                          Icons
                                                                              .music_note,
                                                                          size:
                                                                              24,
                                                                        ),
                                                                      ),
                                                                    )
                                                                  : Container(
                                                                      width: 50,
                                                                      height:
                                                                          50,
                                                                      decoration: BoxDecoration(
                                                                        color: Colors
                                                                            .grey[300],
                                                                        borderRadius:
                                                                            BorderRadius.circular(
                                                                              8,
                                                                            ),
                                                                      ),
                                                                      child: const Icon(
                                                                        Icons
                                                                            .music_video,
                                                                        size:
                                                                            24,
                                                                        color: Colors
                                                                            .grey,
                                                                      ),
                                                                    ),
                                                            ),
                                                          ],
                                                        ),
                                                        title: Text(
                                                          item.title ??
                                                              LocaleProvider.tr(
                                                                'title_unknown',
                                                              ),
                                                          style:
                                                              Theme.of(context)
                                                                  .textTheme
                                                                  .titleMedium,
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                        ),
                                                        subtitle: Text(
                                                          _artistWithDurationText(
                                                            artist: item.artist,
                                                            fallbackArtist:
                                                                LocaleProvider.tr(
                                                                  'artist_unknown',
                                                                ),
                                                            durationText: item
                                                                .durationText,
                                                            durationMs:
                                                                item.durationMs,
                                                          ),
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style: TextStyle(
                                                            color: isAmoled
                                                                ? Colors.white
                                                                      .withValues(
                                                                        alpha:
                                                                            0.8,
                                                                      )
                                                                : null,
                                                          ),
                                                        ),
                                                        trailing:
                                                            _buildPlayTrailingButton(
                                                              item,
                                                            ),
                                                      ),
                                                    ),
                                                  ),
                                                );
                                              }).toList(),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                    // Sección Listas de Reproducción
                                    if (_playlistResults.isNotEmpty) ...[
                                      SizedBox(height: 24),
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          InkWell(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            onTap: () {
                                              setState(() {
                                                _expandedCategory = 'playlists';
                                                _animateToCategory('playlists');
                                              });
                                            },
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 4,
                                                    horizontal: 16,
                                                  ),
                                              child: Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment
                                                        .spaceBetween,
                                                children: [
                                                  Row(
                                                    children: [
                                                      const SizedBox(width: 14),
                                                      Text(
                                                        LocaleProvider.tr(
                                                          'playlists',
                                                        ),
                                                        style: TextStyle(
                                                          fontSize: 16,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                          color: Theme.of(
                                                            context,
                                                          ).colorScheme.primary,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                  Icon(Icons.chevron_right),
                                                ],
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 12),
                                          AnimatedSize(
                                            duration: const Duration(
                                              milliseconds: 300,
                                            ),
                                            curve: Curves.easeInOut,
                                            child: Column(
                                              children: _playlistResults.take(3).map((
                                                playlist,
                                              ) {
                                                final index = _playlistResults
                                                    .indexOf(playlist);

                                                final isDark =
                                                    Theme.of(
                                                      context,
                                                    ).brightness ==
                                                    Brightness.dark;
                                                final cardColor =
                                                    isAmoled && isDark
                                                    ? Colors.white.withAlpha(20)
                                                    : isDark
                                                    ? Theme.of(context)
                                                          .colorScheme
                                                          .secondary
                                                          .withValues(
                                                            alpha: 0.06,
                                                          )
                                                    : Theme.of(context)
                                                          .colorScheme
                                                          .secondary
                                                          .withValues(
                                                            alpha: 0.07,
                                                          );

                                                final int totalToShow =
                                                    _playlistResults.length < 3
                                                    ? _playlistResults.length
                                                    : 3;
                                                final bool isFirst = index == 0;
                                                final bool isLast =
                                                    index == totalToShow - 1;
                                                final bool isOnly =
                                                    totalToShow == 1;

                                                BorderRadius borderRadius;
                                                if (isOnly) {
                                                  borderRadius =
                                                      BorderRadius.circular(20);
                                                } else if (isFirst) {
                                                  borderRadius =
                                                      const BorderRadius.only(
                                                        topLeft:
                                                            Radius.circular(20),
                                                        topRight:
                                                            Radius.circular(20),
                                                        bottomLeft:
                                                            Radius.circular(4),
                                                        bottomRight:
                                                            Radius.circular(4),
                                                      );
                                                } else if (isLast) {
                                                  borderRadius =
                                                      const BorderRadius.only(
                                                        topLeft:
                                                            Radius.circular(4),
                                                        topRight:
                                                            Radius.circular(4),
                                                        bottomLeft:
                                                            Radius.circular(20),
                                                        bottomRight:
                                                            Radius.circular(20),
                                                      );
                                                } else {
                                                  borderRadius =
                                                      BorderRadius.circular(4);
                                                }

                                                return LayoutBuilder(
                                                  builder: (context, constraints) {
                                                    final titleText =
                                                        playlist['title'] ??
                                                        LocaleProvider.tr(
                                                          'title_unknown',
                                                        );
                                                    final style = Theme.of(
                                                      context,
                                                    ).textTheme.titleMedium;

                                                    final textPainter =
                                                        TextPainter(
                                                          text: TextSpan(
                                                            text: titleText,
                                                            style: style,
                                                          ),
                                                          maxLines: 2,
                                                          textDirection:
                                                              TextDirection.ltr,
                                                        );

                                                    // Estimated available width: Width - horizontal padding (32) - leading (50) - gap (16) - trailing (48) - gap (16)
                                                    final availableWidth =
                                                        constraints.maxWidth -
                                                        162;
                                                    textPainter.layout(
                                                      maxWidth:
                                                          availableWidth > 0
                                                          ? availableWidth
                                                          : 0,
                                                    );
                                                    final isTwoLines =
                                                        textPainter
                                                            .computeLineMetrics()
                                                            .length >
                                                        1;
                                                    final verticalPadding =
                                                        isTwoLines ? 3.0 : 10.0;

                                                    return Padding(
                                                      padding: EdgeInsets.only(
                                                        bottom: isLast ? 0 : 4,
                                                        left: 16,
                                                        right: 16,
                                                      ),
                                                      child: Card(
                                                        color: cardColor,
                                                        margin: EdgeInsets.zero,
                                                        elevation: 0,
                                                        shape:
                                                            RoundedRectangleBorder(
                                                              borderRadius:
                                                                  borderRadius,
                                                            ),
                                                        child: InkWell(
                                                          borderRadius:
                                                              borderRadius,
                                                          onTap: () async {
                                                            if (playlist['browseId'] ==
                                                                null) {
                                                              return;
                                                            }
                                                            setState(() {
                                                              _expandedCategory =
                                                                  'playlist';
                                                              _loadingPlaylistSongs =
                                                                  true;
                                                              _playlistSongs =
                                                                  [];
                                                              _currentPlaylist = {
                                                                'title':
                                                                    playlist['title'],
                                                                'thumbUrl':
                                                                    playlist['thumbUrl'],
                                                                'id':
                                                                    playlist['browseId'],
                                                              };
                                                            });
                                                            final songs =
                                                                await getPlaylistSongs(
                                                                  playlist['browseId']!,
                                                                );
                                                            if (!mounted) {
                                                              return;
                                                            }
                                                            setState(() {
                                                              _playlistSongs =
                                                                  songs;
                                                              _loadingPlaylistSongs =
                                                                  false;
                                                            });
                                                          },
                                                          child: ListTile(
                                                            contentPadding:
                                                                EdgeInsets.symmetric(
                                                                  horizontal:
                                                                      16,
                                                                  vertical:
                                                                      verticalPadding,
                                                                ),
                                                            leading: ClipRRect(
                                                              borderRadius:
                                                                  BorderRadius.circular(
                                                                    8,
                                                                  ),
                                                              child:
                                                                  playlist['thumbUrl'] !=
                                                                      null
                                                                  ? _buildSafeNetworkImage(
                                                                      playlist['thumbUrl']!,
                                                                      width: 50,
                                                                      height:
                                                                          50,
                                                                      fit: BoxFit
                                                                          .cover,
                                                                      fallback: Container(
                                                                        width:
                                                                            50,
                                                                        height:
                                                                            50,
                                                                        decoration: BoxDecoration(
                                                                          color:
                                                                              isSystem
                                                                              ? Theme.of(
                                                                                  context,
                                                                                ).colorScheme.secondaryContainer
                                                                              : Theme.of(
                                                                                  context,
                                                                                ).colorScheme.surfaceContainer,
                                                                          borderRadius:
                                                                              BorderRadius.circular(
                                                                                8,
                                                                              ),
                                                                        ),
                                                                        child: const Icon(
                                                                          Icons
                                                                              .playlist_play,
                                                                          size:
                                                                              24,
                                                                        ),
                                                                      ),
                                                                    )
                                                                  : Container(
                                                                      width: 50,
                                                                      height:
                                                                          50,
                                                                      decoration: BoxDecoration(
                                                                        color: Colors
                                                                            .grey[300],
                                                                        borderRadius:
                                                                            BorderRadius.circular(
                                                                              8,
                                                                            ),
                                                                      ),
                                                                      child: const Icon(
                                                                        Icons
                                                                            .playlist_play,
                                                                        size:
                                                                            24,
                                                                        color: Colors
                                                                            .grey,
                                                                      ),
                                                                    ),
                                                            ),
                                                            title: Text(
                                                              playlist['title'] ??
                                                                  LocaleProvider.tr(
                                                                    'title_unknown',
                                                                  ),
                                                              style:
                                                                  Theme.of(
                                                                        context,
                                                                      )
                                                                      .textTheme
                                                                      .titleMedium,
                                                              maxLines: 2,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                            ),
                                                            trailing: IconButton(
                                                              style: IconButton.styleFrom(
                                                                backgroundColor:
                                                                    Theme.of(
                                                                          context,
                                                                        )
                                                                        .colorScheme
                                                                        .primary
                                                                        .withAlpha(
                                                                          20,
                                                                        ),
                                                              ),
                                                              icon: const Icon(
                                                                Icons
                                                                    .link_rounded,
                                                                size: 20,
                                                              ),
                                                              tooltip:
                                                                  LocaleProvider.tr(
                                                                    'copy_link',
                                                                  ),
                                                              onPressed: () {
                                                                Clipboard.setData(
                                                                  ClipboardData(
                                                                    text:
                                                                        'https://www.youtube.com/playlist?list=${playlist['browseId']}',
                                                                  ),
                                                                );
                                                              },
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    );
                                                  },
                                                );
                                              }).toList(),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                    // Sección Álbumes
                                    if (_albumResults.isNotEmpty) ...[
                                      SizedBox(height: 24),
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          InkWell(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            onTap: () {
                                              setState(() {
                                                _expandedCategory = 'albums';
                                                _animateToCategory('albums');
                                              });
                                            },
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 4,
                                                    horizontal: 16,
                                                  ),
                                              child: Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment
                                                        .spaceBetween,
                                                children: [
                                                  Row(
                                                    children: [
                                                      SizedBox(width: 14),
                                                      Text(
                                                        LocaleProvider.tr(
                                                          'albums',
                                                        ),
                                                        style: TextStyle(
                                                          fontSize: 16,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                          color: Theme.of(
                                                            context,
                                                          ).colorScheme.primary,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                  Icon(Icons.chevron_right),
                                                ],
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 12),
                                          SizedBox(
                                            height: 180,
                                            child: ListView.separated(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 16,
                                                  ),
                                              key: ValueKey(
                                                'yt_albums_horizontal_$_searchSessionId',
                                              ),
                                              scrollDirection: Axis.horizontal,
                                              itemCount: _albumResults.length,
                                              separatorBuilder: (_, _) =>
                                                  const SizedBox(width: 12),
                                              itemBuilder: (context, index) {
                                                final item =
                                                    _albumResults[index];
                                                YtMusicResult album;
                                                if (item is YtMusicResult) {
                                                  album = item;
                                                } else if (item is Map) {
                                                  final map =
                                                      item
                                                          as Map<
                                                            String,
                                                            dynamic
                                                          >;
                                                  album = YtMusicResult(
                                                    title:
                                                        map['title'] as String?,
                                                    artist:
                                                        map['artist']
                                                            as String?,
                                                    thumbUrl:
                                                        map['thumbUrl']
                                                            as String?,
                                                    videoId:
                                                        map['browseId']
                                                            as String?,
                                                  );
                                                } else {
                                                  album = YtMusicResult();
                                                }
                                                return AnimatedTapButton(
                                                  onTap: () async {
                                                    if (album.videoId == null) {
                                                      return;
                                                    }
                                                    setState(() {
                                                      _expandedCategory =
                                                          'album';
                                                      _loadingAlbumSongs = true;
                                                      _albumSongs = [];
                                                      _currentAlbum = {
                                                        'id': album.videoId,
                                                        'title': album.title,
                                                        'artist': album.artist,
                                                        'thumbUrl':
                                                            album.thumbUrl,
                                                      };
                                                    });
                                                    final songs =
                                                        await getAlbumSongs(
                                                          album.videoId!,
                                                        );
                                                    if (!mounted) return;
                                                    setState(() {
                                                      _albumSongs = songs;
                                                      _loadingAlbumSongs =
                                                          false;
                                                    });
                                                  },
                                                  child: SizedBox(
                                                    width: 120,
                                                    child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        AspectRatio(
                                                          aspectRatio: 1,
                                                          child: ClipRRect(
                                                            borderRadius:
                                                                BorderRadius.circular(
                                                                  12,
                                                                ),
                                                            child:
                                                                album.thumbUrl !=
                                                                    null
                                                                ? _buildSafeNetworkImage(
                                                                    album
                                                                        .thumbUrl!,
                                                                    width: 120,
                                                                    height: 120,
                                                                    fit: BoxFit
                                                                        .cover,
                                                                    fallback: Container(
                                                                      color:
                                                                          isSystem
                                                                          ? Theme.of(
                                                                              context,
                                                                            ).colorScheme.secondaryContainer
                                                                          : Theme.of(
                                                                              context,
                                                                            ).colorScheme.surfaceContainer,
                                                                      child: const Icon(
                                                                        Icons
                                                                            .album,
                                                                        size:
                                                                            40,
                                                                      ),
                                                                    ),
                                                                  )
                                                                : Container(
                                                                    color:
                                                                        isSystem
                                                                        ? Theme.of(
                                                                            context,
                                                                          ).colorScheme.secondaryContainer
                                                                        : Theme.of(
                                                                            context,
                                                                          ).colorScheme.surfaceContainer,
                                                                    child: const Icon(
                                                                      Icons
                                                                          .album,
                                                                      size: 40,
                                                                    ),
                                                                  ),
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                          height: 8,
                                                        ),
                                                        Flexible(
                                                          child: Text(
                                                            album.title ??
                                                                LocaleProvider.tr(
                                                                  'title_unknown',
                                                                ),
                                                            maxLines: 2,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style:
                                                                Theme.of(
                                                                      context,
                                                                    )
                                                                    .textTheme
                                                                    .titleMedium,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                );
                                              },
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ],
                                );
                              }
                            },
                          ),
                        ),
                      if (!_loading &&
                          _hasSearched &&
                          _songResults.isEmpty &&
                          _videoResults.isEmpty &&
                          _error == null)
                        Expanded(
                          child: Center(
                            child: TranslatedText(
                              'no_results',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: null,
    );
  }

  Future<void> _playInMainPlayer(
    YtMusicResult item, {
    String? fallbackThumbUrl,
    String? fallbackArtist,
    List<YtMusicResult>? queueItems,
    int? initialIndex,
    bool playAsQueue = false,
    String? queueSource,
  }) async {
    final videoId = item.videoId?.trim();
    if (videoId == null || videoId.isEmpty) {
      _showMessage('Error', 'No se pudo obtener el ID del video');
      return;
    }

    if (playLoadingNotifier.value) return;
    playLoadingNotifier.value = true;
    openPlayerPanelNotifier.value = true;

    try {
      final List<ConnectivityResult> connectivity = await Connectivity()
          .checkConnectivity();
      if (connectivity.contains(ConnectivityResult.none)) {
        playLoadingNotifier.value = false;
        _showMessage('Error', LocaleProvider.tr('no_internet_retry'));
        return;
      }

      if (!audioServiceReady.value || audioHandler == null) {
        await initializeAudioServiceSafely();
      }
      final handler = audioHandler;
      if (handler == null) {
        throw Exception('AudioService no disponible');
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'last_queue_source',
        (queueSource?.trim().isNotEmpty ?? false)
            ? queueSource!.trim()
            : 'YouTube Music',
      );

      if (playAsQueue) {
        final source = (queueItems ?? const <YtMusicResult>[])
            .where((entry) => (entry.videoId?.trim().isNotEmpty ?? false))
            .toList();
        if (source.isEmpty) {
          source.add(item);
        }
        final selectedQueueIndex = source.indexWhere(
          (entry) => entry.videoId?.trim() == videoId,
        );
        final queueInitialIndex = selectedQueueIndex >= 0
            ? selectedQueueIndex
            : ((initialIndex != null &&
                      initialIndex >= 0 &&
                      initialIndex < source.length)
                  ? initialIndex
                  : 0);
        final queuePayload = source.map((entry) {
          final id = entry.videoId?.trim() ?? '';
          final entryDurationText = entry.durationText?.trim();
          final entryDurationMs =
              (entry.durationMs != null && entry.durationMs! > 0)
              ? entry.durationMs
              : _parseDurationTextToMilliseconds(entryDurationText);
          return <String, dynamic>{
            'videoId': id,
            'title': (entry.title?.trim().isNotEmpty ?? false)
                ? entry.title!.trim()
                : LocaleProvider.tr('title_unknown'),
            'artist': (entry.artist?.trim().isNotEmpty ?? false)
                ? entry.artist!.trim()
                : ((fallbackArtist?.trim().isNotEmpty ?? false)
                      ? fallbackArtist!.trim()
                      : LocaleProvider.tr('artist_unknown')),
            'artUri': (entry.thumbUrl?.trim().isNotEmpty ?? false)
                ? entry.thumbUrl!.trim()
                : 'https://i.ytimg.com/vi/$id/hqdefault.jpg',
            if (entryDurationMs != null && entryDurationMs > 0)
              'durationMs': entryDurationMs,
            if (entryDurationText != null && entryDurationText.isNotEmpty)
              'durationText': entryDurationText,
          };
        }).toList();
        await handler
            .customAction('playYtStreamQueue', {
              'items': queuePayload,
              'initialIndex': queueInitialIndex,
              'autoPlay': true,
            })
            .timeout(const Duration(seconds: 15));
      } else {
        final artist = item.artist?.trim();
        final fallbackArtistTrimmed = fallbackArtist?.trim();
        final durationText = item.durationText?.trim();
        final durationMs = (item.durationMs != null && item.durationMs! > 0)
            ? item.durationMs
            : _parseDurationTextToMilliseconds(durationText);
        final fallbackArtworkUri = _buildPlayerArtworkFallbackUrl(
          videoId,
          preferredThumbUrl: item.thumbUrl,
          fallbackThumbUrl: fallbackThumbUrl,
        );
        final cachedArtworkUri = await _readCachedPlayerArtworkUri(videoId);
        final immediateArtworkUri =
            (cachedArtworkUri != null && cachedArtworkUri.trim().isNotEmpty)
            ? cachedArtworkUri
            : fallbackArtworkUri;

        // Abrir el reproductor con metadatos inmediatos; el stream se resuelve
        // dentro del handler para evitar bloquear la navegación del panel.
        await handler
            .customAction('playYtStreamQueue', {
              'items': [
                {
                  'videoId': videoId,
                  'title': (item.title?.trim().isNotEmpty ?? false)
                      ? item.title!.trim()
                      : LocaleProvider.tr('title_unknown'),
                  'artist': (artist != null && artist.isNotEmpty)
                      ? artist
                      : ((fallbackArtistTrimmed != null &&
                                fallbackArtistTrimmed.isNotEmpty)
                            ? fallbackArtistTrimmed
                            : LocaleProvider.tr('artist_unknown')),
                  'artUri': immediateArtworkUri,
                  if (item.thumbUrl?.trim().isNotEmpty == true)
                    'displayArtUri': item.thumbUrl!.trim(),
                  if (durationMs != null && durationMs > 0)
                    'durationMs': durationMs,
                  if (durationText != null && durationText.isNotEmpty)
                    'durationText': durationText,
                },
              ],
              'initialIndex': 0,
              'autoPlay': true,
              'autoStartRadio': true,
            })
            .timeout(const Duration(seconds: 15));

        unawaited(
          _refreshPlayerArtworkInBackground(
            handler: handler,
            videoId: videoId,
            preferredThumbUrl: item.thumbUrl,
            fallbackThumbUrl: fallbackThumbUrl,
          ),
        );
      }
    } catch (_) {
      playLoadingNotifier.value = false;
      // Error silencioso por solicitud del usuario:
      // no mostrar popup aunque exista fallo transitorio en el arranque.
    }
  }

  Future<String?> _readCachedPlayerArtworkUri(String videoId) async {
    if (videoId.trim().isEmpty) return null;
    try {
      final tempDir = await getTemporaryDirectory();
      final coverFile = File('${tempDir.path}/yt_stream_cover_v2_$videoId.jpg');
      if (await coverFile.exists() && await coverFile.length() > 500) {
        return Uri.file(coverFile.path).toString();
      }
    } catch (_) {}
    return null;
  }

  Future<void> _refreshPlayerArtworkInBackground({
    required AudioHandler handler,
    required String videoId,
    String? preferredThumbUrl,
    String? fallbackThumbUrl,
  }) async {
    final artworkUri =
        await _buildPlayerArtworkUri(
          videoId,
          preferredThumbUrl: preferredThumbUrl,
          fallbackThumbUrl: fallbackThumbUrl,
        ).timeout(
          const Duration(seconds: 8),
          onTimeout: () => _buildPlayerArtworkFallbackUrl(
            videoId,
            preferredThumbUrl: preferredThumbUrl,
            fallbackThumbUrl: fallbackThumbUrl,
          ),
        );

    final normalizedArtwork = artworkUri.trim();
    if (normalizedArtwork.isEmpty) return;

    try {
      await handler.customAction('refreshCurrentStreamArtwork', {
        'videoId': videoId,
        'artUri': normalizedArtwork,
        if (preferredThumbUrl?.trim().isNotEmpty == true)
          'displayArtUri': preferredThumbUrl!.trim(),
      });
    } catch (_) {}
  }

  String _buildPlayerArtworkFallbackUrl(
    String videoId, {
    String? preferredThumbUrl,
    String? fallbackThumbUrl,
  }) {
    final normalizedPreferred = preferredThumbUrl?.trim();
    final normalizedFallback = fallbackThumbUrl?.trim();

    if (normalizedPreferred != null && normalizedPreferred.isNotEmpty) {
      return normalizedPreferred;
    }

    if (normalizedFallback != null && normalizedFallback.isNotEmpty) {
      return normalizedFallback;
    }

    // Último fallback: miniatura oficial de YouTube.
    if (videoId.isNotEmpty) {
      return 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';
    }

    return '';
  }

  String _getCoverQualityPref(SharedPreferences prefs) {
    final q = prefs.getString('cover_quality');
    if (q == 'high' || q == 'medium' || q == 'low') return q!;
    final old = prefs.getBool('cover_quality_high');
    return old == false ? 'low' : 'medium';
  }

  String _googleThumbSizeForQuality(String quality) {
    switch (quality) {
      case 'medium':
        return 's600';
      case 'low':
        return 's300';
      default:
        return 's1200';
    }
  }

  String _ytThumbFileForQuality(String quality) {
    switch (quality) {
      case 'medium':
        return 'sddefault.jpg';
      case 'low':
        return 'hqdefault.jpg';
      default:
        return 'maxresdefault.jpg';
    }
  }

  String _applySavedCoverQualityToThumb(
    String rawUrl,
    String quality, {
    String? videoId,
  }) {
    final normalized = rawUrl.trim();
    if (normalized.isEmpty || normalized == 'null') return normalized;

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

  Future<String> _resolvedSavedThumbWithQuality(
    String rawUrl, {
    String? videoId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final quality = _getCoverQualityPref(prefs);
    return _applySavedCoverQualityToThumb(rawUrl, quality, videoId: videoId);
  }

  String? _firstMatchingLh3Thumb(
    List<YtMusicResult> items,
    String targetVideoId,
  ) {
    final normalizedTarget = targetVideoId.trim();
    if (normalizedTarget.isEmpty) return null;

    for (final item in items) {
      final id = item.videoId?.trim();
      final thumb = item.thumbUrl?.trim();
      if (id != normalizedTarget || thumb == null || thumb.isEmpty) continue;
      if (thumb.toLowerCase().contains('googleusercontent.com')) {
        return thumb;
      }
    }

    return null;
  }

  Future<String?> _resolveLh3ThumbForVideoId(
    String videoId, {
    String? queryHint,
  }) async {
    final normalizedVideoId = videoId.trim();
    if (normalizedVideoId.isEmpty) return null;

    final cached = _resolvedLh3ThumbByVideoId[normalizedVideoId];
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    final queries = <String>[];
    final normalizedHint = queryHint?.trim();
    if (normalizedHint != null && normalizedHint.isNotEmpty) {
      queries.add(normalizedHint);
    }
    queries.add(normalizedVideoId);

    try {
      for (final query in queries) {
        final songResults = await searchSongsOnly(query);
        final songLh3 = _firstMatchingLh3Thumb(songResults, normalizedVideoId);
        if (songLh3 != null && songLh3.isNotEmpty) {
          _resolvedLh3ThumbByVideoId[normalizedVideoId] = songLh3;
          return songLh3;
        }

        final videoResults = await _searchVideosOnly(query);
        final videoLh3 = _firstMatchingLh3Thumb(
          videoResults,
          normalizedVideoId,
        );
        if (videoLh3 != null && videoLh3.isNotEmpty) {
          _resolvedLh3ThumbByVideoId[normalizedVideoId] = videoLh3;
          return videoLh3;
        }
      }
    } catch (_) {}

    return null;
  }

  Future<String> _buildPlayerArtworkUri(
    String videoId, {
    String? preferredThumbUrl,
    String? fallbackThumbUrl,
  }) async {
    final fallbackUri = _buildPlayerArtworkFallbackUrl(
      videoId,
      preferredThumbUrl: preferredThumbUrl,
      fallbackThumbUrl: fallbackThumbUrl,
    );

    if (videoId.trim().isEmpty) {
      return fallbackUri;
    }

    try {
      final tempDir = await getTemporaryDirectory();
      // v2: fuerza regeneración para evitar reutilizar miniaturas antiguas sin recorte.
      final coverFile = File('${tempDir.path}/yt_stream_cover_v2_$videoId.jpg');
      if (await coverFile.exists() && await coverFile.length() > 500) {
        return Uri.file(coverFile.path).toString();
      }

      final prefs = await SharedPreferences.getInstance();
      final quality = _getCoverQualityPref(prefs);

      final coverUrlMax =
          'https://img.youtube.com/vi/$videoId/maxresdefault.jpg';
      final coverUrlSD = 'https://img.youtube.com/vi/$videoId/sddefault.jpg';
      final coverUrlHQ = 'https://img.youtube.com/vi/$videoId/hqdefault.jpg';
      final normalizedPreferred = preferredThumbUrl?.trim();
      final normalizedFallback = fallbackThumbUrl?.trim();

      final List<String> urlsToTry = [];
      void addCandidate(String? url) {
        final value = url?.trim();
        if (value == null || value.isEmpty) return;
        if (!urlsToTry.contains(value)) {
          urlsToTry.add(value);
        }
      }

      // Priorizar miniatura propia de YT Music para mantener carátula recortada.
      addCandidate(normalizedPreferred);

      for (final url in switch (quality) {
        'high' => [coverUrlMax, coverUrlSD, coverUrlHQ],
        'medium' => [coverUrlSD, coverUrlHQ],
        _ => [coverUrlHQ],
      }) {
        addCandidate(url);
      }

      addCandidate(normalizedFallback);
      addCandidate(fallbackUri);

      Uint8List? bytes;
      String? selectedUrl;

      for (final url in urlsToTry) {
        try {
          final response = await http
              .get(Uri.parse(url), headers: headers)
              .timeout(const Duration(seconds: 4));
          if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
            bytes = response.bodyBytes;
            selectedUrl = url;
            break;
          }
        } catch (_) {}
      }

      if (bytes == null) {
        return fallbackUri;
      }

      final sourceUrl = selectedUrl?.toLowerCase() ?? '';
      final isVideoThumbnail =
          sourceUrl.contains('i.ytimg.com/vi/') ||
          sourceUrl.contains('img.youtube.com/vi/');
      if (isVideoThumbnail) {
        final cropFn =
            sourceUrl.contains('hqdefault') || sourceUrl.contains('sddefault')
            ? decodeAndCropImageHQ
            : decodeAndCropImage;
        final cropped = await compute(cropFn, bytes);
        if (cropped != null && cropped.isNotEmpty) {
          bytes = cropped;
        }
      }

      await coverFile.writeAsBytes(bytes, flush: true);
      return Uri.file(coverFile.path).toString();
    } catch (_) {
      return fallbackUri;
    }
  }

  // Función para mostrar mensajes con diseño elegante
  void _showMessage(String title, String message) {
    showDialog(
      context: context,
      builder: (context) => ValueListenableBuilder<AppColorScheme>(
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
                    title == 'Error'
                        ? Icons.error_rounded
                        : Icons.task_alt_rounded,
                    size: 32,
                    color: title == 'Error'
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.onSurface,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    title,
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
                      message,
                      style: TextStyle(
                        fontSize: 14,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withAlpha(160),
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Padding(
                    padding: const EdgeInsets.only(right: 24, bottom: 8),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => Navigator.of(context).pop(),
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
      ),
    );
  }
}

class YtPreviewPlayer extends StatefulWidget {
  final List<YtMusicResult> results;
  final int currentIndex;
  final String? fallbackThumbUrl;
  final String? fallbackArtist;
  const YtPreviewPlayer({
    super.key,
    required this.results,
    required this.currentIndex,
    this.fallbackThumbUrl,
    this.fallbackArtist,
  });

  @override
  State<YtPreviewPlayer> createState() => YtPreviewPlayerState();
}

class YtPreviewPlayerState extends State<YtPreviewPlayer>
    with TickerProviderStateMixin {
  final AudioPlayer _player = AudioPlayer();
  bool _loading = false;
  bool _playing = false;
  bool _loadingArtist = false;
  Duration? _duration;
  String? _audioUrl;
  late int _currentIndex;
  late YtMusicResult _currentItem;
  int _loadToken = 0; // Token para cancelar cargas previas
  StreamSubscription<PlayerState>? _playerStateSubscription;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.currentIndex;
    _currentItem = widget.results[_currentIndex];

    _playerStateSubscription = _player.playerStateStream.listen((state) {
      if (!mounted) return;
      setState(() {
        _playing =
            state.playing && state.processingState != ProcessingState.completed;
        // _loading solo debe ser true si está cargando y reproduciendo
        // pero aquí no lo cambiamos salvo que quieras lógica especial
      });
    });
  }

  @override
  void dispose() {
    _playerStateSubscription?.cancel();
    _player.dispose();
    super.dispose();
  }

  // Función helper para manejar imágenes de red de forma segura
  /*
  Widget _buildSafeNetworkImage(String? imageUrl, {double? width, double? height, BoxFit? fit, Widget? fallback}) {
    if (imageUrl == null || imageUrl.isEmpty) {
      return fallback ?? const Icon(Icons.music_note, size: 32);
    }
    
    return Image.network(
      imageUrl,
      width: width,
      height: height,
      fit: fit ?? BoxFit.cover,
      errorBuilder: (context, error, stackTrace) {
        return fallback ?? const Icon(Icons.music_note, size: 32);
      },
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: LoadingIndicator(
              color: Colors.transparent,
              value: loadingProgress.expectedTotalBytes != null
                  ? loadingProgress.cumulativeBytesLoaded / loadingProgress.expectedTotalBytes!
                  : null,
            ),
          ),
        );
      },
    );
  }
  */

  // Función helper para manejar imágenes de red con recorte de carátula (para YtPreviewModal)
  Widget _buildSafeNetworkImageWithCrop(
    String? imageUrl, {
    double? width,
    double? height,
    BoxFit? fit,
    Widget? fallback,
  }) {
    if (imageUrl == null || imageUrl.isEmpty) {
      return fallback ?? const Icon(Icons.music_note, size: 32);
    }

    // Verificar si la imagen ya está en caché
    if (_imageCache.containsKey(imageUrl)) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(
          _imageCache[imageUrl]!,
          width: width,
          height: height,
          fit: fit ?? BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            return fallback ?? const Icon(Icons.music_note, size: 32);
          },
        ),
      );
    }

    return FutureBuilder<Uint8List?>(
      future: _downloadAndCropImage(imageUrl),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          // Mostrar la imagen original mientras se procesa el recorte
          // Gracias al caché de Flutter, si ya se mostró en la lista se verá instantánea
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: CachedNetworkImage(
              imageUrl: imageUrl,
              width: width,
              height: height,
              fit: fit ?? BoxFit.cover,
              fadeInDuration: Duration.zero,
              fadeOutDuration: Duration.zero,
              errorWidget: (context, url, error) =>
                  fallback ?? const Icon(Icons.music_note, size: 32),
              placeholder: (context, url) {
                return Container(
                  width: width,
                  height: height,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(child: LoadingIndicator()),
                );
              },
            ),
          );
        }

        if (snapshot.hasError || snapshot.data == null) {
          return fallback ?? const Icon(Icons.music_note, size: 32);
        }

        // Guardar en caché antes de mostrar
        _imageCache[imageUrl] = snapshot.data!;

        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            snapshot.data!,
            width: width,
            height: height,
            fit: fit ?? BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              return fallback ?? const Icon(Icons.music_note, size: 32);
            },
          ),
        );
      },
    );
  }

  // Función para descargar y recortar imagen
  Future<Uint8List?> _downloadAndCropImage(String imageUrl) async {
    // Verificar si ya está en caché
    if (_imageCache.containsKey(imageUrl)) {
      return _imageCache[imageUrl];
    }

    try {
      final response = await http.get(Uri.parse(imageUrl), headers: headers);
      if (response.statusCode == 200) {
        final bytes = response.bodyBytes;

        Uint8List? processedBytes;
        // Determinar si es maxresdefault o una variante 4:3 (sddefault/hqdefault)
        if (imageUrl.contains('hqdefault') || imageUrl.contains('sddefault')) {
          // Para sddefault/hqdefault, usar recorte especial (mismo método para media y baja)
          processedBytes = await compute(decodeAndCropImageHQ, bytes);
        } else {
          // Para maxresdefault, usar recorte normal centrado
          processedBytes = await compute(decodeAndCropImage, bytes);
        }

        // Guardar en caché si el procesamiento fue exitoso
        if (processedBytes != null) {
          _imageCache[imageUrl] = processedBytes;
        }

        return processedBytes;
      }
    } catch (e) {
      // print('Error descargando imagen: $e');
    }
    return null;
  }

  void _playPrevious() {
    if (_currentIndex > 0) {
      setState(() {
        _currentIndex--;
        _currentItem = widget.results[_currentIndex];
        _audioUrl = null;
        _duration = null;
        _player.stop();
        _playing = false;
        _loading = false;
      });
      // Resetear posición a 0 para la nueva canción
      _player.seek(Duration.zero);
      // No cargar nada hasta que el usuario presione play
    }
  }

  void _playNext() {
    if (_currentIndex < widget.results.length - 1) {
      setState(() {
        _currentIndex++;
        _currentItem = widget.results[_currentIndex];
        _audioUrl = null;
        _duration = null;
        _player.stop();
        _playing = false;
        _loading = false;
      });
      // Resetear posición a 0 para la nueva canción
      _player.seek(Duration.zero);
      // No cargar nada hasta que el usuario presione play
    }
  }

  Future<void> _loadAndPlay() async {
    _loadToken++;
    final int thisLoad = _loadToken;
    setState(() {
      _loading = true;
    });
    await Future.delayed(const Duration(milliseconds: 200));
    if (thisLoad != _loadToken) {
      await _player.stop();
      _audioUrl = null;
      _duration = null;
      if (!mounted) return;
      setState(() {
        _playing = false;
        _loading = false;
      });
      return; // Cancelado
    }
    // Verificar conexión a internet antes de reproducir
    final List<ConnectivityResult> connectivityResult = await Connectivity()
        .checkConnectivity();
    if (connectivityResult.contains(ConnectivityResult.none)) {
      if (!mounted) return;
      _showMessage('Error', LocaleProvider.tr('no_internet_retry'));
      setState(() {
        _loading = false;
      });
      return;
    }
    // Si ya tenemos la URL y duración, solo reproducir
    if (_audioUrl != null && _duration != null) {
      setState(() {
        _playing = true;
        _loading = false;
      });
      await _player.play();
      return;
    }
    try {
      if (audioHandler?.playbackState.value.playing ?? false) {
        await audioHandler?.pause();
      }

      // Usar StreamService con cache
      final audioUrl = await StreamService.getBestAudioUrl(
        _currentItem.videoId!,
        reportError: true,
      );
      if (thisLoad != _loadToken) {
        await _player.stop();
        _audioUrl = null;
        _duration = null;
        if (!mounted) return;
        setState(() {
          _playing = false;
          _loading = false;
        });
        return; // Cancelado
      }

      if (audioUrl == null) {
        throw Exception('No se encontró stream de audio válido.');
      }
      _audioUrl = audioUrl;
      if (thisLoad != _loadToken) {
        await _player.stop();
        _audioUrl = null;
        _duration = null;
        if (!mounted) return;
        setState(() {
          _playing = false;
          _loading = false;
        });
        return; // Cancelado
      }
      await _player.setUrl(_audioUrl!);
      _duration = _player.duration;
      if (thisLoad != _loadToken) {
        await _player.stop();
        _audioUrl = null;
        _duration = null;
        if (!mounted) return;
        setState(() {
          _playing = false;
          _loading = false;
        });
        return; // Cancelado justo antes de reproducir
      }
      if (!mounted) return;
      setState(() {
        _playing = true;
        _loading = false;
      });
      await _player.play();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _playing = false;
        _loading = false;
      });
      if (!mounted) return;
      _showMessage('Error', 'Error al reproducir el preview de la canción');
    }
  }

  Future<void> _pause() async {
    await _player.pause();
    if (!mounted) return;
    setState(() {
      _playing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isSystem = colorSchemeNotifier.value == AppColorScheme.system;
    return Card(
      shadowColor: Colors.transparent,
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: isAmoled && isDark
            ? const BorderSide(color: Colors.white, width: 1)
            : BorderSide.none,
      ),
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 0),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Info de la canción
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Primer Row: carátula y botones
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      onTap: () {
                        final imageUrl =
                            _currentItem.thumbUrl ?? widget.fallbackThumbUrl;
                        if (imageUrl != null && imageUrl.isNotEmpty) {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => ImageViewer(
                                imageUrl: imageUrl,
                                title: _currentItem.title,
                                subtitle: _artistWithDurationText(
                                  artist: _currentItem.artist,
                                  fallbackArtist: widget.fallbackArtist,
                                  durationText: _currentItem.durationText,
                                  durationMs: _currentItem.durationMs,
                                ),
                                videoId: _currentItem.videoId,
                              ),
                            ),
                          );
                        }
                      },
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child:
                            (_currentItem.thumbUrl != null &&
                                _currentItem.thumbUrl!.isNotEmpty)
                            ? _buildSafeNetworkImageWithCrop(
                                _currentItem.thumbUrl!,
                                width: 64,
                                height: 64,
                                fit: BoxFit.cover,
                                fallback: Container(
                                  width: 64,
                                  height: 64,
                                  decoration: BoxDecoration(
                                    color: isSystem
                                        ? Theme.of(
                                            context,
                                          ).colorScheme.secondaryContainer
                                        : Theme.of(
                                            context,
                                          ).colorScheme.surfaceContainer,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Icon(Icons.music_note, size: 32),
                                ),
                              )
                            : (widget.fallbackThumbUrl != null &&
                                  widget.fallbackThumbUrl!.isNotEmpty)
                            ? _buildSafeNetworkImageWithCrop(
                                widget.fallbackThumbUrl!,
                                width: 64,
                                height: 64,
                                fit: BoxFit.cover,
                                fallback: Container(
                                  width: 64,
                                  height: 64,
                                  decoration: BoxDecoration(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainer,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Icon(Icons.music_note, size: 32),
                                ),
                              )
                            : Container(
                                width: 64,
                                height: 64,
                                color: Colors.grey[300],
                                child: const Icon(Icons.music_note, size: 32),
                              ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Align(
                        alignment: Alignment.topRight,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SimpleDownloadButton(item: _currentItem),
                            const SizedBox(width: 8),
                            // Botón para ir al artista
                            SizedBox(
                              height: 50,
                              width: 50,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Material(
                                  color: isAmoled
                                      ? Colors.white
                                      : Theme.of(
                                          context,
                                        ).colorScheme.secondaryContainer,
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(8),
                                    onTap: _loadingArtist
                                        ? null
                                        : () async {
                                            final artistName =
                                                _currentItem.artist ??
                                                widget.fallbackArtist;
                                            if (artistName == null ||
                                                artistName.trim().isEmpty) {
                                              _showMessage(
                                                'Error',
                                                LocaleProvider.tr(
                                                  'artist_unknown',
                                                ),
                                              );
                                              return;
                                            }

                                            setState(() {
                                              _loadingArtist = true;
                                            });

                                            try {
                                              // Buscar el artista
                                              final results =
                                                  await searchArtists(
                                                    artistName,
                                                    limit: 1,
                                                  );
                                              if (!mounted) return;

                                              setState(() {
                                                _loadingArtist = false;
                                              });

                                              if (results.isEmpty) {
                                                _showMessage(
                                                  LocaleProvider.tr('error'),
                                                  LocaleProvider.tr(
                                                    'artist_not_found',
                                                  ).replaceAll(
                                                    '{artistName}',
                                                    artistName,
                                                  ),
                                                );
                                                return;
                                              }

                                              final artist = results.first;
                                              final browseId =
                                                  artist['browseId'];
                                              if (browseId == null) {
                                                _showMessage(
                                                  LocaleProvider.tr('error'),
                                                  LocaleProvider.tr(
                                                    'could_not_get_artist_info',
                                                  ),
                                                );
                                                return;
                                              }

                                              if (!mounted) return;

                                              // Navegar a la pantalla del artista
                                              if (!context.mounted) return;

                                              // Cerrar el modal primero y obtener el contexto raíz
                                              Navigator.of(context).pop();

                                              // Esperar un frame para que el modal se cierre completamente
                                              await Future.delayed(
                                                const Duration(
                                                  milliseconds: 50,
                                                ),
                                              );
                                              if (!mounted ||
                                                  !context.mounted) {
                                                return;
                                              }

                                              // Usar el navigator raíz, no el del modal
                                              final navigator = Navigator.of(
                                                context,
                                                rootNavigator: false,
                                              );

                                              // Eliminar todas las ArtistScreen del stack usando popUntil
                                              // Buscamos si hay alguna ArtistScreen en el stack
                                              navigator.popUntil((route) {
                                                // Si es la primera ruta (puede ser el home), detenemos
                                                if (route.isFirst) {
                                                  return true;
                                                }

                                                // Verificar las rutas por su nombre
                                                final settings = route.settings;

                                                // Si encontramos una ruta que no es ArtistScreen, nos detenemos
                                                if (settings.name != null &&
                                                    settings.name !=
                                                        '/artist') {
                                                  return true;
                                                }

                                                // Si la ruta es ArtistScreen (sin nombre o con '/artist'),
                                                // la eliminamos retornando false para continuar haciendo pop
                                                if (settings.name == null ||
                                                    settings.name ==
                                                        '/artist') {
                                                  return false; // Continuar haciendo pop
                                                }

                                                return true; // Detenernos por seguridad
                                              });

                                              // Ahora hacer push de la nueva pantalla
                                              navigator.push(
                                                PageRouteBuilder(
                                                  settings: const RouteSettings(
                                                    name: '/artist',
                                                  ),
                                                  pageBuilder:
                                                      (
                                                        context,
                                                        animation,
                                                        secondaryAnimation,
                                                      ) => ArtistScreen(
                                                        artistName: artistName,
                                                        browseId: browseId,
                                                      ),
                                                  transitionsBuilder:
                                                      (
                                                        context,
                                                        animation,
                                                        secondaryAnimation,
                                                        child,
                                                      ) {
                                                        const begin = Offset(
                                                          1.0,
                                                          0.0,
                                                        );
                                                        const end = Offset.zero;
                                                        const curve = Curves
                                                            .easeInOutCubic;
                                                        var tween =
                                                            Tween(
                                                              begin: begin,
                                                              end: end,
                                                            ).chain(
                                                              CurveTween(
                                                                curve: curve,
                                                              ),
                                                            );
                                                        var offsetAnimation =
                                                            animation.drive(
                                                              tween,
                                                            );
                                                        return SlideTransition(
                                                          position:
                                                              offsetAnimation,
                                                          child: child,
                                                        );
                                                      },
                                                ),
                                              );
                                            } catch (e) {
                                              if (!mounted) return;
                                              setState(() {
                                                _loadingArtist = false;
                                              });
                                              _showMessage(
                                                'Error',
                                                'Error al buscar el artista: ${e.toString()}',
                                              );
                                            }
                                          },
                                    child: Center(
                                      child: _loadingArtist
                                          ? SizedBox(
                                              width: 20,
                                              height: 20,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 3,
                                                valueColor:
                                                    AlwaysStoppedAnimation<
                                                      Color
                                                    >(
                                                      isAmoled
                                                          ? Colors.black
                                                          : Theme.of(context)
                                                                .colorScheme
                                                                .onSecondaryContainer,
                                                    ),
                                              ),
                                            )
                                          : Tooltip(
                                              message: LocaleProvider.tr(
                                                'go_to_artist',
                                              ),
                                              child: Icon(
                                                Icons.person,
                                                size: 24,
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onSecondaryContainer,
                                              ),
                                            ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Botón para abrir en YouTube Music
                    SizedBox(
                      height: 50,
                      width: 50,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: _currentItem.videoId != null
                              ? () async {
                                  try {
                                    final ytMusicUrl =
                                        'https://music.youtube.com/watch?v=${_currentItem.videoId}';
                                    final url = Uri.parse(ytMusicUrl);
                                    if (await canLaunchUrl(url)) {
                                      await launchUrl(
                                        url,
                                        mode: LaunchMode.externalApplication,
                                      );
                                    }
                                  } catch (e) {
                                    // Manejar error silenciosamente
                                  }
                                }
                              : null,
                          child: Center(
                            child: Tooltip(
                              message: LocaleProvider.tr(
                                'open_in_youtube_music',
                              ),
                              child: Image.asset(
                                'assets/icon/Youtube_Music_icon.png',
                                width: 44,
                                height: 44,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // Segundo Row: título y artista
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _currentItem.title ??
                                LocaleProvider.tr('title_unknown'),
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            _artistWithDurationText(
                              artist: _currentItem.artist,
                              fallbackArtist: widget.fallbackArtist,
                              durationText: _currentItem.durationText,
                              durationMs: _currentItem.durationMs,
                            ),
                            style: TextStyle(
                              fontSize: 15,
                              color: isAmoled
                                  ? Colors.white.withValues(alpha: 0.8)
                                  : null,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 20),
            // Controles
            Row(
              children: [
                // Play/Pause con diseño del overlay
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    customBorder: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(
                        _playing
                            ? 13.33
                            : 20, // mainIconSize / 3 : mainIconSize / 2
                      ),
                    ),
                    splashColor: Colors.transparent,
                    highlightColor: Colors.transparent,
                    onTap: _loading
                        ? null
                        : () async {
                            if (_playing) {
                              _pause();
                            } else {
                              if (_audioUrl == null) {
                                _loadAndPlay();
                              } else {
                                // Si la posición está al final, reinicia
                                final pos = _player.position;
                                if (_duration != null && pos >= _duration!) {
                                  await _player.seek(Duration.zero);
                                }
                                await _player.play();
                                // Ya no es necesario setState aquí, el listener lo maneja
                              }
                            }
                          },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeInOut,
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color:
                            colorSchemeNotifier.value == AppColorScheme.amoled
                            ? Colors.white
                            : Theme.of(context).brightness == Brightness.dark
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.onPrimaryContainer
                                  .withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(
                          _playing
                              ? 13.33
                              : 20, // mainIconSize / 3 : mainIconSize / 2
                        ),
                      ),
                      child: Center(
                        child: _loading
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  strokeCap: StrokeCap.round,
                                  color:
                                      colorSchemeNotifier.value ==
                                          AppColorScheme.amoled
                                      ? Colors.black
                                      : Theme.of(context).brightness ==
                                            Brightness.dark
                                      ? Theme.of(context).colorScheme.onPrimary
                                      : Theme.of(
                                          context,
                                        ).colorScheme.surfaceContainer,
                                ),
                              )
                            : Icon(
                                _playing
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                grade: 200,
                                size: 24,
                                fill: 1,
                                color:
                                    colorSchemeNotifier.value ==
                                        AppColorScheme.amoled
                                    ? Colors.black
                                    : Theme.of(context).brightness ==
                                          Brightness.dark
                                    ? Theme.of(context).colorScheme.onPrimary
                                    : Theme.of(
                                        context,
                                      ).colorScheme.surfaceContainer,
                              ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Duración
                Expanded(
                  child: StreamBuilder<Duration>(
                    stream: _player.positionStream,
                    builder: (context, snapshot) {
                      final pos = snapshot.data ?? Duration.zero;
                      final total = _duration ?? Duration.zero;
                      return Text(
                        '${_formatDuration(pos)} / ${_formatDuration(total)}',
                        style: TextStyle(fontWeight: FontWeight.w500),
                      );
                    },
                  ),
                ),
                // Botón anterior
                IconButton(
                  icon: const Icon(
                    Icons.skip_previous_rounded,
                    grade: 200,
                    fill: 1,
                  ),
                  onPressed: (!_loading && _currentIndex > 0)
                      ? _playPrevious
                      : null,
                ),
                // Botón siguiente
                IconButton(
                  icon: const Icon(
                    Icons.skip_next_rounded,
                    grade: 200,
                    fill: 1,
                  ),
                  onPressed:
                      (!_loading && _currentIndex < widget.results.length - 1)
                      ? _playNext
                      : null,
                ),
              ],
            ),
            // Barra de progreso SIEMPRE visible
            const SizedBox(height: 8),
            StreamBuilder<Duration>(
              stream: _player.positionStream,
              builder: (context, positionSnapshot) {
                return StreamBuilder<Duration>(
                  stream: _player.bufferedPositionStream,
                  builder: (context, bufferedSnapshot) {
                    if (_duration == null) {
                      return LinearProgressIndicator(
                        value: 0.0,
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(8),
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.2),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Theme.of(context).colorScheme.primary,
                        ),
                      );
                    }

                    final pos = positionSnapshot.data ?? Duration.zero;
                    final buffered = bufferedSnapshot.data ?? Duration.zero;
                    final total = _duration!.inMilliseconds;

                    final progress = total > 0
                        ? pos.inMilliseconds / total
                        : 0.0;
                    final bufferedProgress = total > 0
                        ? buffered.inMilliseconds / total
                        : 0.0;

                    return LayoutBuilder(
                      builder: (context, constraints) {
                        return GestureDetector(
                          onTapDown: (details) {
                            if (_duration != null &&
                                _duration!.inMilliseconds > 0) {
                              final tapPosition = details.localPosition.dx;
                              final tapProgress =
                                  tapPosition / constraints.maxWidth;
                              final newPosition = Duration(
                                milliseconds:
                                    (_duration!.inMilliseconds *
                                            tapProgress.clamp(0.0, 1.0))
                                        .round(),
                              );
                              _player.seek(newPosition);
                            }
                          },
                          child: Container(
                            height: 8,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              color: Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: 0.2),
                            ),
                            child: Stack(
                              children: [
                                // Progreso de carga (buffered) - fondo más claro
                                if (bufferedProgress > 0)
                                  Positioned(
                                    left: 0,
                                    top: 0,
                                    bottom: 0,
                                    width:
                                        constraints.maxWidth *
                                        bufferedProgress.clamp(0.0, 1.0),
                                    child: Container(
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(8),
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary
                                            .withValues(alpha: 0.5),
                                      ),
                                    ),
                                  ),
                                // Progreso de reproducción - más visible
                                if (progress > 0)
                                  Positioned(
                                    left: 0,
                                    top: 0,
                                    bottom: 0,
                                    width:
                                        constraints.maxWidth *
                                        progress.clamp(0.0, 1.0),
                                    child: Container(
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(8),
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
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
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    if (d.inHours > 0) {
      final hours = d.inHours.toString().padLeft(2, '0');
      final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
      final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
      return '$hours:$minutes:$seconds';
    } else {
      final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
      final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
      return '$minutes:$seconds';
    }
  }

  // Función para mostrar mensajes con diseño elegante
  void _showMessage(String title, String message) {
    showDialog(
      context: context,
      builder: (context) => ValueListenableBuilder<AppColorScheme>(
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
                    title == 'Error' ? Icons.error_rounded : Icons.info_rounded,
                    size: 32,
                    color: title == 'Error'
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.onSurface,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    title,
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
                      message,
                      style: TextStyle(
                        fontSize: 14,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withAlpha(160),
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Padding(
                    padding: const EdgeInsets.only(right: 24, bottom: 8),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => Navigator.of(context).pop(),
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
