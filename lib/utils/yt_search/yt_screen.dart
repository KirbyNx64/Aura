import 'dart:ui';
import 'package:audio_service/audio_service.dart';
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
import 'package:material_symbols_icons/symbols.dart';
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
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

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

class YtSearchTestScreen extends StatefulWidget {
  final String? initialQuery;
  const YtSearchTestScreen({super.key, this.initialQuery});

  @override
  State<YtSearchTestScreen> createState() => _YtSearchTestScreenState();
}

// Caché global para imágenes procesadas
final Map<String, Uint8List> _imageCache = {};

class _YtSearchTestScreenState extends State<YtSearchTestScreen>
    with WidgetsBindingObserver {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
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

  // ScrollControllers para paginación incremental
  final ScrollController _songScrollController = ScrollController();
  final ScrollController _videoScrollController = ScrollController();
  final ScrollController _playlistScrollController = ScrollController();
  int _songPage = 1;
  int _videoPage = 1;
  int _playlistPage = 1;
  bool _hasMoreSongs = true;
  bool _hasMoreVideos = true;
  bool _hasMorePlaylists = true;

  Future<List<YtMusicResult>> _searchVideosOnly(String query) async {
    final data = {
      ...ytServiceContext,
      'query': query,
      'params': getSearchParams('videos', null, false),
    };
    final response = (await sendRequest("search", data)).data;
    final results = <YtMusicResult>[];
    // Obtener videos de la respuesta
    final contents = nav(response, [
      'contents',
      'tabbedSearchResultsRenderer',
      'tabs',
      0,
      'tabRenderer',
      'content',
      'sectionListRenderer',
      'contents',
    ]);
    if (contents is List) {
      for (var section in contents) {
        final shelfRenderer = section['musicShelfRenderer'];
        if (shelfRenderer != null) {
          final sectionContents = shelfRenderer['contents'];
          if (sectionContents is List) {
            // parseSongs filtra solo canciones, así que parseamos manualmente para videos
            for (var item in sectionContents) {
              final renderer = item['musicResponsiveListItemRenderer'];
              if (renderer != null) {
                // Verificar si es un video
                final videoType = nav(renderer, [
                  'overlay',
                  'musicItemThumbnailOverlayRenderer',
                  'content',
                  'musicPlayButtonRenderer',
                  'playNavigationEndpoint',
                  'watchEndpoint',
                  'watchEndpointMusicSupportedConfigs',
                  'watchEndpointMusicConfig',
                  'musicVideoType',
                ]);
                if (videoType == 'MUSIC_VIDEO_TYPE_MV' ||
                    videoType == 'MUSIC_VIDEO_TYPE_OMV' ||
                    videoType == 'MUSIC_VIDEO_TYPE_UGC') {
                  final title =
                      renderer['flexColumns']?[0]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs']?[0]?['text'];
                  final subtitleRuns =
                      renderer['flexColumns']?[1]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'];
                  String? artist;
                  if (subtitleRuns is List) {
                    for (var run in subtitleRuns) {
                      if (run['navigationEndpoint']?['browseEndpoint']?['browseEndpointContextSupportedConfigs'] !=
                              null ||
                          run['navigationEndpoint']?['browseEndpoint']?['browseId']
                                  ?.startsWith('UC') ==
                              true) {
                        artist = run['text'];
                        break;
                      }
                    }
                    artist ??= subtitleRuns.firstWhere(
                      (run) => run['text'] != ' • ',
                      orElse: () => {'text': null},
                    )['text'];
                  }
                  String? thumbUrl;
                  final thumbnails =
                      renderer['thumbnail']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'];
                  if (thumbnails is List && thumbnails.isNotEmpty) {
                    thumbUrl = thumbnails.last['url'];
                  }
                  final videoId =
                      renderer['overlay']?['musicItemThumbnailOverlayRenderer']?['content']?['musicPlayButtonRenderer']?['playNavigationEndpoint']?['watchEndpoint']?['videoId'];
                  if (videoId != null && title != null) {
                    results.add(
                      YtMusicResult(
                        title: title,
                        artist: artist,
                        thumbUrl: thumbUrl,
                        videoId: videoId,
                      ),
                    );
                  }
                }
              }
            }
          }
        }
      }
    }
    return results;
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
          final existingIds = _videoResults.map((e) => e.videoId).toSet();
          final newOnes = moreVideos
              .where((e) => !existingIds.contains(e.videoId))
              .toList();
          _videoResults.addAll(newOnes);
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Mostrar sugerencias por defecto
    _showSuggestions = true;

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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focusNode.dispose();
    _controller.dispose();
    downloadProgressNotifier.dispose();
    isDownloadingNotifier.dispose();
    isProcessingNotifier.dispose();
    queueLengthNotifier.dispose();
    _songScrollController.dispose();
    _videoScrollController.dispose();
    _playlistScrollController.dispose();
    super.dispose();
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
            child: CircularProgressIndicator(
              color: Colors.transparent,
              value: loadingProgress.expectedTotalBytes != null
                  ? loadingProgress.cumulativeBytesLoaded /
                        loadingProgress.expectedTotalBytes!
                  : null,
            ),
          ),
        );
      },
    );
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
      _selectedIndexes.clear();
      _isSelectionMode = false;
      // Limpiar también los resultados de URL
      _isUrlSearch = false;
      _urlVideoResult = null;
      _loadingUrlVideo = false;
      _urlVideoError = null;
    });
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

    if (_urlVideoResult == null) return const SizedBox.shrink();

    return SingleChildScrollView(
      child: Column(
        children: [
          // Resultado del video
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isSystem
                  ? Theme.of(
                      context,
                    ).colorScheme.secondaryContainer.withValues(alpha: 0.5)
                  : Theme.of(context).colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha((0.05 * 255).toInt()),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Thumbnail y información básica
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Thumbnail
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        'https://img.youtube.com/vi/${_urlVideoResult!.id}/maxresdefault.jpg',
                        width: 120,
                        height: 120,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) {
                          return Container(
                            width: 120,
                            height: 120,
                            decoration: BoxDecoration(
                              color: Colors.grey[300],
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(Icons.music_video, size: 40),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 16),

                    // Información del video
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
                          const SizedBox(height: 8),
                          Text(
                            _urlVideoResult!.author.replaceFirst(
                              RegExp(r' - Topic$'),
                              '',
                            ),
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              fontSize: 14,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 16),

                // Botón de acción
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      if (_urlVideoResult != null) {
                        // Agregar a la cola de descargas
                        final downloadQueue = DownloadQueue();
                        await downloadQueue.addToQueue(
                          context: context,
                          videoId: _urlVideoResult!.id.toString(),
                          title: _urlVideoResult!.title,
                          artist: _urlVideoResult!.author.replaceFirst(
                            RegExp(r' - Topic$'),
                            '',
                          ),
                        );

                        // Mostrar mensaje de confirmación
                        _showMessage(
                          LocaleProvider.tr('success'),
                          LocaleProvider.tr('download_started'),
                        );
                      }
                    },
                    icon: const Icon(Icons.download),
                    label: Text(LocaleProvider.tr('download')),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      foregroundColor: Theme.of(context).colorScheme.onPrimary,
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
    final isSystem = colorSchemeNotifier.value == AppColorScheme.system;

    if (_urlPlaylistVideos.isEmpty) return const SizedBox.shrink();

    return StreamBuilder<MediaItem?>(
      stream: audioHandler?.mediaItem,
      builder: (context, snapshot) {
        final mediaItem = snapshot.data;
        // Calcular espacio inferior considerando overlay de reproducción
        double bottomSpace = mediaItem != null ? 100.0 : 0.0;

        return Padding(
          padding: EdgeInsets.only(bottom: bottomSpace),
          child: SingleChildScrollView(
            child: Column(
              children: [
                // Resultado de la playlist
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: isSystem
                        ? Theme.of(context).colorScheme.secondaryContainer
                              .withValues(alpha: 0.5)
                        : Theme.of(context).colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withAlpha((0.05 * 255).toInt()),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Título de la playlist
                      Row(
                        children: [
                          Icon(
                            Icons.playlist_play,
                            size: 24,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _urlPlaylistTitle ?? 'Playlist',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 18,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            onPressed: () async {
                              final downloadQueue = DownloadQueue();
                              for (final song in _urlPlaylistVideos) {
                                await downloadQueue.addToQueue(
                                  context: context,
                                  videoId: song.videoId ?? '',
                                  title: song.title ?? 'Sin título',
                                  artist:
                                      song.artist?.replaceFirst(
                                        RegExp(r' - Topic$'),
                                        '',
                                      ) ??
                                      'Artista desconocido',
                                );
                              }
                              _showMessage(
                                LocaleProvider.tr('success'),
                                '${_urlPlaylistVideos.length} ${LocaleProvider.tr('songs_added_to_queue')}',
                              );
                            },
                            icon: const Icon(Icons.download),
                            style: IconButton.styleFrom(
                              backgroundColor: Theme.of(
                                context,
                              ).colorScheme.primary,
                              foregroundColor: Theme.of(
                                context,
                              ).colorScheme.onPrimary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Text(
                            '${_urlPlaylistVideos.length} canciones',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              fontSize: 14,
                            ),
                          ),
                          if (_loadingUrlPlaylist) ...[
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Cargando...',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.primary,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Lista de canciones
                      ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: _urlPlaylistVideos.length,
                        itemBuilder: (context, index) {
                          final song = _urlPlaylistVideos[index];
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 0,
                              vertical: 2,
                            ),
                            dense: true,
                            leading: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.network(
                                song.thumbUrl ??
                                    'https://img.youtube.com/vi/${song.videoId}/maxresdefault.jpg',
                                width: 48,
                                height: 48,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) {
                                  return Container(
                                    width: 48,
                                    height: 48,
                                    decoration: BoxDecoration(
                                      color: Colors.grey[300],
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Icon(
                                      Icons.music_video,
                                      size: 20,
                                    ),
                                  );
                                },
                              ),
                            ),
                            title: Text(
                              song.title ?? 'Sin título',
                              style: Theme.of(context).textTheme.titleMedium,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              song.artist?.replaceFirst(
                                    RegExp(r' - Topic$'),
                                    '',
                                  ) ??
                                  'Artista desconocido',
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                                fontSize: 12,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.download),
                              onPressed: () async {
                                // Agregar a la cola de descargas
                                final downloadQueue = DownloadQueue();
                                await downloadQueue.addToQueue(
                                  context: context,
                                  videoId: song.videoId ?? '',
                                  title: song.title ?? 'Sin título',
                                  artist:
                                      song.artist?.replaceFirst(
                                        RegExp(r' - Topic$'),
                                        '',
                                      ) ??
                                      'Artista desconocido',
                                );
                              },
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
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
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    if (!mounted) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Android 9 or lower: use default Music folder
    if (sdkInt <= 28) {
      final path = '/storage/emulated/0/Music';
      downloadDirectoryNotifier.value = path;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('download_directory', path);
      if (!mounted) return;
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
          content: Text(LocaleProvider.tr('android_9_or_lower')),
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

            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white, width: 1)
                    : BorderSide.none,
              ),
              title: Center(
                child: Text(
                  LocaleProvider.tr('select_common_folder'),
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (commonFolders.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Text(
                          LocaleProvider.tr('no_common_folders'),
                          style: Theme.of(context).textTheme.bodyMedium,
                          textAlign: TextAlign.center,
                        ),
                      )
                    else
                      ...commonFolders.map(
                        (folder) => ListTile(
                          leading: const Icon(Icons.folder),
                          title: Text(
                            folder.split('/').last.isEmpty
                                ? folder
                                : folder.split('/').last,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            formatFolderPath(folder),
                            style: Theme.of(context).textTheme.bodySmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () {
                            Navigator.of(context).pop();
                            _selectFolder(folder);
                          },
                        ),
                      ),
                    if (commonFolders.isNotEmpty) SizedBox(height: 16),
                    // Botón para elegir otra carpeta con diseño especial
                    InkWell(
                      onTap: () async {
                        Navigator.of(context).pop();
                        await _pickNewFolder();
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: (isAmoled && isDark
                              ? Colors.white.withValues(alpha: 0.2)
                              : Theme.of(context).colorScheme.primaryContainer),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: (isAmoled && isDark
                                ? Colors.white.withValues(alpha: 0.4)
                                : Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.3)),
                            width: 2,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: (isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.2)
                                    : Theme.of(context).colorScheme.primary
                                          .withValues(alpha: 0.1)),
                              ),
                              child: Icon(
                                Icons.folder_open,
                                size: 30,
                                color: (isAmoled && isDark
                                    ? Colors.white
                                    : Theme.of(context).colorScheme.primary),
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                LocaleProvider.tr('choose_other_folder'),
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: (isAmoled && isDark
                                      ? Colors.white
                                      : Theme.of(context).colorScheme.primary),
                                ),
                              ),
                            ),
                            Icon(
                              Icons.arrow_forward_ios,
                              size: 20,
                              color: (isAmoled && isDark
                                  ? Colors.white
                                  : Theme.of(context).colorScheme.primary),
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

  Future<void> _downloadSelected() async {
    final items = _selectedIndexes
        .map<YtMusicResult>((key) {
          if (key.startsWith('video-')) {
            final videoId = key.substring(6);
            return _videoResults.firstWhere(
              (item) => item.videoId == videoId,
              orElse: () => YtMusicResult(
                title: null,
                artist: null,
                thumbUrl: null,
                videoId: null,
              ),
            );
          } else if (key.startsWith('song-')) {
            final videoId = key.substring(5);
            return _songResults.firstWhere(
              (item) => item.videoId == videoId,
              orElse: () => YtMusicResult(
                title: null,
                artist: null,
                thumbUrl: null,
                videoId: null,
              ),
            );
          } else if (key.startsWith('album-')) {
            final videoId = key.substring(6);
            return _albumSongs.firstWhere(
              (item) => item.videoId == videoId,
              orElse: () => YtMusicResult(
                title: null,
                artist: null,
                thumbUrl: null,
                videoId: null,
              ),
            );
          } else {
            return YtMusicResult(
              title: null,
              artist: null,
              thumbUrl: null,
              videoId: null,
            );
          }
        })
        .where((item) => item.videoId != null)
        .toList();

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
      final existingIds = _videoResults.map((e) => e.videoId).toSet();
      final newOnes = moreVideos
          .where((e) => !existingIds.contains(e.videoId))
          .toList();
      _videoResults.addAll(newOnes);
      _videoPage = nextPage;
      _loadingMoreVideos = false;
      _hasMoreVideos = newOnes.isNotEmpty;
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
    // print('canPopInternally: $_expandedCategory');
    return _expandedCategory != null;
  }

  void handleInternalPop() {
    setState(() {
      _expandedCategory = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isSystem = colorSchemeNotifier.value == AppColorScheme.system;

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
            : Row(
                children: [
                  Icon(Icons.search, size: 28),
                  const SizedBox(width: 8),
                  TranslatedText('search'),
                ],
              ),
        leading: _isSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: _clearSelection,
              )
            : null,
        actions: _isSelectionMode
            ? [
                if (_selectedIndexes.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.download),
                    tooltip: LocaleProvider.tr('download_selected'),
                    onPressed: _downloadSelected,
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
                          builder: (context) => AlertDialog(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                              side: isAmoled && isDark
                                  ? const BorderSide(
                                      color: Colors.white,
                                      width: 1,
                                    )
                                  : BorderSide.none,
                            ),
                            title: Center(
                              child: Text(
                                LocaleProvider.tr('info'),
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                            content: TranslatedText('search_music_in_ytm'),
                            actions: [
                              SizedBox(height: 16),
                              InkWell(
                                onTap: () => Navigator.of(context).pop(),
                                borderRadius: BorderRadius.circular(16),
                                child: Container(
                                  width: double.infinity,
                                  padding: EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: isAmoled && isDark
                                        ? Colors.white.withValues(alpha: 0.2)
                                        : Theme.of(
                                            context,
                                          ).colorScheme.primaryContainer,
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: isAmoled && isDark
                                          ? Colors.white.withValues(alpha: 0.4)
                                          : Theme.of(context)
                                                .colorScheme
                                                .primary
                                                .withValues(alpha: 0.3),
                                      width: 2,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        padding: EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          color: isAmoled && isDark
                                              ? Colors.white.withValues(
                                                  alpha: 0.2,
                                                )
                                              : Theme.of(context)
                                                    .colorScheme
                                                    .primary
                                                    .withValues(alpha: 0.1),
                                        ),
                                        child: Icon(
                                          Icons.check_circle,
                                          size: 30,
                                          color: isAmoled && isDark
                                              ? Colors.white
                                              : Theme.of(
                                                  context,
                                                ).colorScheme.primary,
                                        ),
                                      ),
                                      SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              LocaleProvider.tr('ok'),
                                              style: TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.w600,
                                                color: isAmoled && isDark
                                                    ? Colors.white
                                                    : Theme.of(
                                                        context,
                                                      ).colorScheme.primary,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ],
      ),
      body: Column(
        children: [
          // Contenido principal
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: StreamBuilder<MediaItem?>(
                stream: audioHandler?.mediaItem,
                builder: (context, snapshot) {
                  // print('DEBUG: StreamBuilder rebuild, mediaItem: ${snapshot.data != null}');
                  final mediaItem = snapshot.data;
                  // Calcular espacio inferior considerando overlay de reproducción
                  // (ya no sumamos espacio para la barra de progreso)
                  double bottomSpace = mediaItem != null ? 100.0 : 0.0;
                  return Column(
                    children: [
                      ValueListenableBuilder<String>(
                        valueListenable: languageNotifier,
                        builder: (context, lang, child) {
                          final isDark =
                              Theme.of(context).brightness == Brightness.dark;
                          final barColor = isDark
                              ? Theme.of(
                                  context,
                                ).colorScheme.onSecondary.withValues(alpha: 0.5)
                              : Theme.of(context).colorScheme.secondaryContainer
                                    .withValues(alpha: 0.5);

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
                              hintText: LocaleProvider.tr(
                                'search_in_youtube_music',
                              ),
                              hintStyle: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
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
                      const SizedBox(height: 14),
                      // SOLO UNO de estos bloques se muestra a la vez
                      if (_error != null)
                        Text(_error!, style: const TextStyle(color: Colors.red))
                      else if (_isUrlSearch && _loadingUrlVideo)
                        const Expanded(
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (_isUrlSearch && _urlVideoError != null)
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
                                  _urlVideoError!,
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
                      else if (_isUrlSearch && _urlVideoResult != null)
                        Expanded(child: _buildUrlVideoResult())
                      else if (_isUrlPlaylistSearch && _loadingUrlPlaylist)
                        const Expanded(
                          child: Center(child: CircularProgressIndicator()),
                        )
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
                        const Expanded(
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (_noInternet)
                        Expanded(
                          child: Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.wifi_off,
                                  size: 48,
                                  color: Theme.of(context).colorScheme.onSurface
                                      .withValues(alpha: 0.6),
                                ),
                                const SizedBox(height: 8),
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
                              ],
                            ),
                          ),
                        )
                      else if (_showSuggestions &&
                          !_loading &&
                          _controller.text.isEmpty)
                        Expanded(
                          child: FutureBuilder<List<String>>(
                            future: SearchHistory.getHistory(),
                            builder: (context, snapshot) {
                              final hasHistory =
                                  snapshot.hasData && snapshot.data!.isNotEmpty;
                              if (!hasHistory) {
                                return Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.history,
                                        size: 48,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.6),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        LocaleProvider.tr('no_recent_searches'),
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
                        )
                      else if (_showSuggestions &&
                          !_loading &&
                          _controller.text.isNotEmpty &&
                          !_hasSearched)
                        Expanded(
                          child: SearchSuggestionsWidget(
                            query: _controller.text,
                            onSuggestionSelected: _onSuggestionSelected,
                            onClearHistory: _onClearHistory,
                          ),
                        )
                      else if (!_loading &&
                          (_songResults.isNotEmpty ||
                              _videoResults.isNotEmpty) &&
                          _hasSearched)
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(bottom: bottomSpace),
                            child: Builder(
                              builder: (context) {
                                if (_expandedCategory == 'songs') {
                                  // Mostrar solo todas las canciones con botón de volver
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          IconButton(
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
                                                color:
                                                    Theme.of(
                                                          context,
                                                        ).brightness ==
                                                        Brightness.dark
                                                    ? Theme.of(context)
                                                          .colorScheme
                                                          .onSecondary
                                                          .withValues(
                                                            alpha: 0.5,
                                                          )
                                                    : Theme.of(context)
                                                          .colorScheme
                                                          .secondaryContainer
                                                          .withValues(
                                                            alpha: 0.5,
                                                          ),
                                              ),
                                              child: const Icon(
                                                Icons.arrow_back,
                                                size: 24,
                                              ),
                                            ),
                                            tooltip: 'Volver',
                                            onPressed: () {
                                              setState(() {
                                                _expandedCategory = null;
                                              });
                                            },
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            LocaleProvider.tr('songs_search'),
                                            style: Theme.of(
                                              context,
                                            ).textTheme.titleMedium,
                                          ),
                                        ],
                                      ),
                                      Expanded(
                                        child: ListView.builder(
                                          controller: _songScrollController,
                                          padding: EdgeInsets.zero,
                                          itemCount:
                                              _songResults.length +
                                              (_loadingMoreSongs ? 1 : 0),
                                          itemBuilder: (context, idx) {
                                            if (_loadingMoreSongs &&
                                                idx == _songResults.length) {
                                              return Container(
                                                padding: const EdgeInsets.all(
                                                  16,
                                                ),
                                                child: Row(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.center,
                                                  children: [
                                                    const SizedBox(
                                                      width: 20,
                                                      height: 20,
                                                      child:
                                                          CircularProgressIndicator(
                                                            strokeWidth: 2,
                                                          ),
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
                                            final cardColor = isDark
                                                ? Theme.of(context)
                                                      .colorScheme
                                                      .onSecondary
                                                      .withValues(alpha: 0.5)
                                                : Theme.of(context)
                                                      .colorScheme
                                                      .secondaryContainer
                                                      .withValues(alpha: 0.5);

                                            final bool isFirst = idx == 0;
                                            final bool isLast =
                                                idx == _songResults.length - 1;
                                            final bool isOnly =
                                                _songResults.length == 1;

                                            BorderRadius borderRadius;
                                            if (isOnly) {
                                              borderRadius =
                                                  BorderRadius.circular(16);
                                            } else if (isFirst) {
                                              borderRadius =
                                                  const BorderRadius.only(
                                                    topLeft: Radius.circular(
                                                      16,
                                                    ),
                                                    topRight: Radius.circular(
                                                      16,
                                                    ),
                                                    bottomLeft: Radius.circular(
                                                      4,
                                                    ),
                                                    bottomRight:
                                                        Radius.circular(4),
                                                  );
                                            } else if (isLast) {
                                              borderRadius =
                                                  const BorderRadius.only(
                                                    topLeft: Radius.circular(4),
                                                    topRight: Radius.circular(
                                                      4,
                                                    ),
                                                    bottomLeft: Radius.circular(
                                                      16,
                                                    ),
                                                    bottomRight:
                                                        Radius.circular(16),
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
                                                    _toggleSelection(
                                                      idx,
                                                      isVideo: false,
                                                    );
                                                  },
                                                  onTap: () {
                                                    if (_isSelectionMode) {
                                                      _toggleSelection(
                                                        idx,
                                                        isVideo: false,
                                                      );
                                                    } else {
                                                      showModalBottomSheet(
                                                        context: context,
                                                        shape: const RoundedRectangleBorder(
                                                          borderRadius:
                                                              BorderRadius.vertical(
                                                                top:
                                                                    Radius.circular(
                                                                      16,
                                                                    ),
                                                              ),
                                                        ),
                                                        builder: (context) {
                                                          return SafeArea(
                                                            child: Padding(
                                                              padding:
                                                                  const EdgeInsets.all(
                                                                    24,
                                                                  ),
                                                              child: YtPreviewPlayer(
                                                                results:
                                                                    _songResults,
                                                                currentIndex:
                                                                    idx,
                                                              ),
                                                            ),
                                                          );
                                                        },
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
                                                      item.artist ??
                                                          LocaleProvider.tr(
                                                            'artist_unknown',
                                                          ),
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                    trailing: IconButton(
                                                      icon: const Icon(
                                                        Icons.link,
                                                      ),
                                                      tooltip:
                                                          LocaleProvider.tr(
                                                            'copy_link',
                                                          ),
                                                      onPressed: () {
                                                        Clipboard.setData(
                                                          ClipboardData(
                                                            text:
                                                                'https://music.youtube.com/watch?v=${item.videoId}',
                                                          ),
                                                        );
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
                                } else if (_expandedCategory == 'videos') {
                                  // Mostrar solo todos los videos con botón de volver
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          IconButton(
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
                                                color:
                                                    Theme.of(
                                                          context,
                                                        ).brightness ==
                                                        Brightness.dark
                                                    ? Theme.of(context)
                                                          .colorScheme
                                                          .onSecondary
                                                          .withValues(
                                                            alpha: 0.5,
                                                          )
                                                    : Theme.of(context)
                                                          .colorScheme
                                                          .secondaryContainer
                                                          .withValues(
                                                            alpha: 0.5,
                                                          ),
                                              ),
                                              child: const Icon(
                                                Icons.arrow_back,
                                                size: 24,
                                              ),
                                            ),
                                            tooltip: 'Volver',
                                            onPressed: () {
                                              setState(() {
                                                _expandedCategory = null;
                                              });
                                            },
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            LocaleProvider.tr('videos'),
                                            style: Theme.of(
                                              context,
                                            ).textTheme.titleMedium,
                                          ),
                                        ],
                                      ),
                                      Expanded(
                                        child: ListView.builder(
                                          controller: _videoScrollController,
                                          padding: EdgeInsets.zero,
                                          itemCount:
                                              _videoResults.length +
                                              (_loadingMoreVideos ? 1 : 0),
                                          itemBuilder: (context, idx) {
                                            if (_loadingMoreVideos &&
                                                idx == _videoResults.length) {
                                              return Container(
                                                padding: const EdgeInsets.all(
                                                  16,
                                                ),
                                                child: Row(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.center,
                                                  children: [
                                                    const SizedBox(
                                                      width: 20,
                                                      height: 20,
                                                      child:
                                                          CircularProgressIndicator(
                                                            strokeWidth: 2,
                                                          ),
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
                                            final cardColor = isDark
                                                ? Theme.of(context)
                                                      .colorScheme
                                                      .onSecondary
                                                      .withValues(alpha: 0.5)
                                                : Theme.of(context)
                                                      .colorScheme
                                                      .secondaryContainer
                                                      .withValues(alpha: 0.5);

                                            final bool isFirst = idx == 0;
                                            final bool isLast =
                                                idx == _videoResults.length - 1;
                                            final bool isOnly =
                                                _videoResults.length == 1;

                                            BorderRadius borderRadius;
                                            if (isOnly) {
                                              borderRadius =
                                                  BorderRadius.circular(16);
                                            } else if (isFirst) {
                                              borderRadius =
                                                  const BorderRadius.only(
                                                    topLeft: Radius.circular(
                                                      16,
                                                    ),
                                                    topRight: Radius.circular(
                                                      16,
                                                    ),
                                                    bottomLeft: Radius.circular(
                                                      4,
                                                    ),
                                                    bottomRight:
                                                        Radius.circular(4),
                                                  );
                                            } else if (isLast) {
                                              borderRadius =
                                                  const BorderRadius.only(
                                                    topLeft: Radius.circular(4),
                                                    topRight: Radius.circular(
                                                      4,
                                                    ),
                                                    bottomLeft: Radius.circular(
                                                      16,
                                                    ),
                                                    bottomRight:
                                                        Radius.circular(16),
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
                                                    _toggleSelection(
                                                      idx,
                                                      isVideo: true,
                                                    );
                                                  },
                                                  onTap: () {
                                                    if (_isSelectionMode) {
                                                      _toggleSelection(
                                                        idx,
                                                        isVideo: true,
                                                      );
                                                    } else {
                                                      showModalBottomSheet(
                                                        context: context,
                                                        shape: const RoundedRectangleBorder(
                                                          borderRadius:
                                                              BorderRadius.vertical(
                                                                top:
                                                                    Radius.circular(
                                                                      16,
                                                                    ),
                                                              ),
                                                        ),
                                                        builder: (context) {
                                                          return SafeArea(
                                                            child: Padding(
                                                              padding:
                                                                  const EdgeInsets.all(
                                                                    24,
                                                                  ),
                                                              child: YtPreviewPlayer(
                                                                results:
                                                                    _videoResults,
                                                                currentIndex:
                                                                    idx,
                                                              ),
                                                            ),
                                                          );
                                                        },
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
                                                      item.artist ??
                                                          LocaleProvider.tr(
                                                            'artist_unknown',
                                                          ),
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                    trailing: IconButton(
                                                      icon: const Icon(
                                                        Icons.link,
                                                      ),
                                                      tooltip:
                                                          LocaleProvider.tr(
                                                            'copy_link',
                                                          ),
                                                      onPressed: () {
                                                        Clipboard.setData(
                                                          ClipboardData(
                                                            text:
                                                                'https://www.youtube.com/watch?v=${item.videoId}',
                                                          ),
                                                        );
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
                                } else if (_expandedCategory == 'albums') {
                                  // Mostrar solo álbumes con botón de volver
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          IconButton(
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
                                                color:
                                                    Theme.of(
                                                          context,
                                                        ).brightness ==
                                                        Brightness.dark
                                                    ? Theme.of(context)
                                                          .colorScheme
                                                          .onSecondary
                                                          .withValues(
                                                            alpha: 0.5,
                                                          )
                                                    : Theme.of(context)
                                                          .colorScheme
                                                          .secondaryContainer
                                                          .withValues(
                                                            alpha: 0.5,
                                                          ),
                                              ),
                                              child: const Icon(
                                                Icons.arrow_back,
                                                size: 24,
                                              ),
                                            ),
                                            tooltip: 'Volver',
                                            onPressed: () {
                                              setState(() {
                                                _expandedCategory = null;
                                              });
                                            },
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            LocaleProvider.tr('albums'),
                                            style: Theme.of(
                                              context,
                                            ).textTheme.titleMedium,
                                          ),
                                        ],
                                      ),
                                      Expanded(
                                        child: ListView.builder(
                                          padding: EdgeInsets.zero,
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
                                                artist:
                                                    map['artist'] as String?,
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
                                            final cardColor = isDark
                                                ? Theme.of(context)
                                                      .colorScheme
                                                      .onSecondary
                                                      .withValues(alpha: 0.5)
                                                : Theme.of(context)
                                                      .colorScheme
                                                      .secondaryContainer
                                                      .withValues(alpha: 0.5);

                                            final bool isFirst = index == 0;
                                            final bool isLast =
                                                index ==
                                                _albumResults.length - 1;
                                            final bool isOnly =
                                                _albumResults.length == 1;

                                            BorderRadius borderRadius;
                                            if (isOnly) {
                                              borderRadius =
                                                  BorderRadius.circular(16);
                                            } else if (isFirst) {
                                              borderRadius =
                                                  const BorderRadius.only(
                                                    topLeft: Radius.circular(
                                                      16,
                                                    ),
                                                    topRight: Radius.circular(
                                                      16,
                                                    ),
                                                    bottomLeft: Radius.circular(
                                                      4,
                                                    ),
                                                    bottomRight:
                                                        Radius.circular(4),
                                                  );
                                            } else if (isLast) {
                                              borderRadius =
                                                  const BorderRadius.only(
                                                    topLeft: Radius.circular(4),
                                                    topRight: Radius.circular(
                                                      4,
                                                    ),
                                                    bottomLeft: Radius.circular(
                                                      16,
                                                    ),
                                                    bottomRight:
                                                        Radius.circular(16),
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
                                                          ? Image.network(
                                                              album.thumbUrl!,
                                                              width: 56,
                                                              height: 56,
                                                              fit: BoxFit.cover,
                                                            )
                                                          : Container(
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
                                                    ),
                                                    trailing: IconButton(
                                                      icon: const Icon(
                                                        Icons.link,
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
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          IconButton(
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
                                                color:
                                                    Theme.of(
                                                          context,
                                                        ).brightness ==
                                                        Brightness.dark
                                                    ? Theme.of(context)
                                                          .colorScheme
                                                          .onSecondary
                                                          .withValues(
                                                            alpha: 0.5,
                                                          )
                                                    : Theme.of(context)
                                                          .colorScheme
                                                          .secondaryContainer
                                                          .withValues(
                                                            alpha: 0.5,
                                                          ),
                                              ),
                                              child: const Icon(
                                                Icons.arrow_back,
                                                size: 24,
                                              ),
                                            ),
                                            tooltip: 'Volver',
                                            onPressed: () {
                                              setState(() {
                                                _expandedCategory = null;
                                                _albumSongs = [];
                                                _currentAlbum = null;
                                                _playlistSongs = [];
                                                _currentPlaylist = null;
                                              });
                                            },
                                          ),
                                          const SizedBox(width: 8),
                                          if (_currentAlbum != null) ...[
                                            if (_currentAlbum!['thumbUrl'] !=
                                                null)
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  right: 12,
                                                ),
                                                child: ClipRRect(
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                  child: _buildSafeNetworkImage(
                                                    _currentAlbum!['thumbUrl'],
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
                                            IconButton.filled(
                                              icon: Icon(
                                                Icons.download,
                                                size: 24,
                                                color: isAmoled && isDark
                                                    ? Colors.black
                                                    : null,
                                              ),
                                              tooltip: LocaleProvider.tr(
                                                'download_entire_album',
                                              ),
                                              onPressed: () async {
                                                if (_albumSongs.isNotEmpty) {
                                                  final downloadQueue =
                                                      DownloadQueue();
                                                  for (final song
                                                      in _albumSongs) {
                                                    await downloadQueue.addToQueue(
                                                      context: context,
                                                      videoId:
                                                          song.videoId ?? '',
                                                      title:
                                                          song.title ??
                                                          'Sin título',
                                                      artist:
                                                          song.artist
                                                              ?.replaceFirst(
                                                                RegExp(
                                                                  r' - Topic$',
                                                                ),
                                                                '',
                                                              ) ??
                                                          'Artista desconocido',
                                                    );
                                                  }
                                                  _showMessage(
                                                    LocaleProvider.tr(
                                                      'success',
                                                    ),
                                                    '${_albumSongs.length} ${LocaleProvider.tr('songs_added_to_queue')}',
                                                  );
                                                }
                                              },
                                            ),
                                          ],
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      if (_loadingAlbumSongs)
                                        const Expanded(
                                          child: Center(
                                            child: CircularProgressIndicator(),
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
                                            padding: EdgeInsets.zero,
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
                                              final cardColor = isDark
                                                  ? Theme.of(context)
                                                        .colorScheme
                                                        .onSecondary
                                                        .withValues(alpha: 0.5)
                                                  : Theme.of(context)
                                                        .colorScheme
                                                        .secondaryContainer
                                                        .withValues(alpha: 0.5);

                                              final bool isFirst = idx == 0;
                                              final bool isLast =
                                                  idx == _albumSongs.length - 1;
                                              final bool isOnly =
                                                  _albumSongs.length == 1;

                                              BorderRadius borderRadius;
                                              if (isOnly) {
                                                borderRadius =
                                                    BorderRadius.circular(16);
                                              } else if (isFirst) {
                                                borderRadius =
                                                    const BorderRadius.only(
                                                      topLeft: Radius.circular(
                                                        16,
                                                      ),
                                                      topRight: Radius.circular(
                                                        16,
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
                                                          Radius.circular(16),
                                                      bottomRight:
                                                          Radius.circular(16),
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
                                                    onTap: () {
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
                                                        showModalBottomSheet(
                                                          context: context,
                                                          shape: const RoundedRectangleBorder(
                                                            borderRadius:
                                                                BorderRadius.vertical(
                                                                  top:
                                                                      Radius.circular(
                                                                        16,
                                                                      ),
                                                                ),
                                                          ),
                                                          builder: (context) {
                                                            return SafeArea(
                                                              child: Padding(
                                                                padding:
                                                                    const EdgeInsets.all(
                                                                      24,
                                                                    ),
                                                                child: YtPreviewPlayer(
                                                                  results:
                                                                      _albumSongs,
                                                                  currentIndex:
                                                                      idx,
                                                                  fallbackThumbUrl:
                                                                      _currentAlbum?['thumbUrl'],
                                                                  fallbackArtist:
                                                                      _currentAlbum?['artist'] ??
                                                                      LocaleProvider.tr(
                                                                        'artist_unknown',
                                                                      ),
                                                                ),
                                                              ),
                                                            );
                                                          },
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
                                                          ClipRRect(
                                                            borderRadius:
                                                                BorderRadius.circular(
                                                                  8,
                                                                ),
                                                            child:
                                                                (item.thumbUrl !=
                                                                        null &&
                                                                    item
                                                                        .thumbUrl!
                                                                        .isNotEmpty)
                                                                ? _buildSafeNetworkImage(
                                                                    item.thumbUrl!,
                                                                    width: 50,
                                                                    height: 50,
                                                                    fit: BoxFit
                                                                        .cover,
                                                                  )
                                                                : (_currentAlbum !=
                                                                          null &&
                                                                      _currentAlbum!['thumbUrl'] !=
                                                                          null &&
                                                                      (_currentAlbum!['thumbUrl']
                                                                              as String)
                                                                          .isNotEmpty)
                                                                ? _buildSafeNetworkImage(
                                                                    _currentAlbum!['thumbUrl'],
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
                                                                        size:
                                                                            20,
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
                                                                      size: 20,
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
                                                        (item.artist != null &&
                                                                item.artist!
                                                                    .trim()
                                                                    .isNotEmpty)
                                                            ? item.artist!
                                                            : (_currentAlbum?['artist'] ??
                                                                  LocaleProvider.tr(
                                                                    'artist_unknown',
                                                                  )),
                                                        style: Theme.of(
                                                          context,
                                                        ).textTheme.bodySmall,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                      ),
                                                      trailing: IconButton(
                                                        icon: const Icon(
                                                          Icons.link,
                                                        ),
                                                        tooltip:
                                                            LocaleProvider.tr(
                                                              'copy_link',
                                                            ),
                                                        onPressed: () {
                                                          Clipboard.setData(
                                                            ClipboardData(
                                                              text:
                                                                  'https://music.youtube.com/watch?v=${item.videoId}',
                                                            ),
                                                          );
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
                                } else if (_expandedCategory == 'playlist') {
                                  // Mostrar canciones de una playlist específica
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          IconButton(
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
                                                color:
                                                    Theme.of(
                                                          context,
                                                        ).brightness ==
                                                        Brightness.dark
                                                    ? Theme.of(context)
                                                          .colorScheme
                                                          .onSecondary
                                                          .withValues(
                                                            alpha: 0.5,
                                                          )
                                                    : Theme.of(context)
                                                          .colorScheme
                                                          .secondaryContainer
                                                          .withValues(
                                                            alpha: 0.5,
                                                          ),
                                              ),
                                              child: const Icon(
                                                Icons.arrow_back,
                                                size: 24,
                                              ),
                                            ),
                                            tooltip: 'Volver',
                                            onPressed: () {
                                              setState(() {
                                                _expandedCategory = null;
                                                _albumSongs = [];
                                                _currentAlbum = null;
                                                _playlistSongs = [];
                                                _currentPlaylist = null;
                                              });
                                            },
                                          ),
                                          const SizedBox(width: 8),
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
                                            IconButton.filled(
                                              icon: Icon(
                                                Icons.download,
                                                size: 24,
                                                color: isAmoled && isDark
                                                    ? Colors.black
                                                    : null,
                                              ),
                                              tooltip: LocaleProvider.tr(
                                                'download_entire_playlist',
                                              ),
                                              onPressed: () async {
                                                if (_playlistSongs.isNotEmpty) {
                                                  final downloadQueue =
                                                      DownloadQueue();
                                                  for (final song
                                                      in _playlistSongs) {
                                                    await downloadQueue.addToQueue(
                                                      context: context,
                                                      videoId:
                                                          song.videoId ?? '',
                                                      title:
                                                          song.title ??
                                                          'Sin título',
                                                      artist:
                                                          song.artist
                                                              ?.replaceFirst(
                                                                RegExp(
                                                                  r' - Topic$',
                                                                ),
                                                                '',
                                                              ) ??
                                                          'Artista desconocido',
                                                    );
                                                  }
                                                  _showMessage(
                                                    LocaleProvider.tr(
                                                      'success',
                                                    ),
                                                    '${_playlistSongs.length} ${LocaleProvider.tr('songs_added_to_queue')}',
                                                  );
                                                }
                                              },
                                            ),
                                          ],
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      if (_loadingPlaylistSongs)
                                        const Expanded(
                                          child: Center(
                                            child: CircularProgressIndicator(),
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
                                            padding: EdgeInsets.zero,
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
                                              final cardColor = isDark
                                                  ? Theme.of(context)
                                                        .colorScheme
                                                        .onSecondary
                                                        .withValues(alpha: 0.5)
                                                  : Theme.of(context)
                                                        .colorScheme
                                                        .secondaryContainer
                                                        .withValues(alpha: 0.5);

                                              final bool isFirst = idx == 0;
                                              final bool isLast =
                                                  idx ==
                                                  _playlistSongs.length - 1;
                                              final bool isOnly =
                                                  _playlistSongs.length == 1;

                                              BorderRadius borderRadius;
                                              if (isOnly) {
                                                borderRadius =
                                                    BorderRadius.circular(16);
                                              } else if (isFirst) {
                                                borderRadius =
                                                    const BorderRadius.only(
                                                      topLeft: Radius.circular(
                                                        16,
                                                      ),
                                                      topRight: Radius.circular(
                                                        16,
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
                                                          Radius.circular(16),
                                                      bottomRight:
                                                          Radius.circular(16),
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
                                                    onTap: () {
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
                                                        showModalBottomSheet(
                                                          context: context,
                                                          shape: const RoundedRectangleBorder(
                                                            borderRadius:
                                                                BorderRadius.vertical(
                                                                  top:
                                                                      Radius.circular(
                                                                        16,
                                                                      ),
                                                                ),
                                                          ),
                                                          builder: (context) {
                                                            return SafeArea(
                                                              child: Padding(
                                                                padding:
                                                                    const EdgeInsets.all(
                                                                      24,
                                                                    ),
                                                                child: YtPreviewPlayer(
                                                                  results:
                                                                      _playlistSongs,
                                                                  currentIndex:
                                                                      idx,
                                                                  fallbackThumbUrl:
                                                                      _currentPlaylist?['thumbUrl'],
                                                                  fallbackArtist:
                                                                      LocaleProvider.tr(
                                                                        'artist_unknown',
                                                                      ),
                                                                ),
                                                              ),
                                                            );
                                                          },
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
                                                        item.artist ??
                                                            LocaleProvider.tr(
                                                              'artist_unknown',
                                                            ),
                                                        style: Theme.of(
                                                          context,
                                                        ).textTheme.bodySmall,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                      ),
                                                      trailing: IconButton(
                                                        icon: const Icon(
                                                          Icons.link,
                                                        ),
                                                        tooltip:
                                                            LocaleProvider.tr(
                                                              'copy_link',
                                                            ),
                                                        onPressed: () {
                                                          Clipboard.setData(
                                                            ClipboardData(
                                                              text:
                                                                  'https://music.youtube.com/watch?v=${item.videoId}',
                                                            ),
                                                          );
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
                                } else if (_expandedCategory == 'playlists') {
                                  // Mostrar solo todas las listas de reproducción con botón de volver
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          IconButton(
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
                                                color:
                                                    Theme.of(
                                                          context,
                                                        ).brightness ==
                                                        Brightness.dark
                                                    ? Theme.of(context)
                                                          .colorScheme
                                                          .onSecondary
                                                          .withValues(
                                                            alpha: 0.5,
                                                          )
                                                    : Theme.of(context)
                                                          .colorScheme
                                                          .secondaryContainer
                                                          .withValues(
                                                            alpha: 0.5,
                                                          ),
                                              ),
                                              child: const Icon(
                                                Icons.arrow_back,
                                                size: 24,
                                              ),
                                            ),
                                            tooltip: 'Volver',
                                            onPressed: () {
                                              setState(() {
                                                _expandedCategory = null;
                                              });
                                            },
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            LocaleProvider.tr('playlists'),
                                            style: Theme.of(
                                              context,
                                            ).textTheme.titleMedium,
                                          ),
                                        ],
                                      ),
                                      Expanded(
                                        child: ListView.builder(
                                          controller: _playlistScrollController,
                                          padding: EdgeInsets.zero,
                                          itemCount:
                                              _playlistResults.length +
                                              (_loadingMorePlaylists ? 1 : 0),
                                          itemBuilder: (context, idx) {
                                            if (_loadingMorePlaylists &&
                                                idx ==
                                                    _playlistResults.length) {
                                              return Container(
                                                padding: const EdgeInsets.all(
                                                  16,
                                                ),
                                                child: Row(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.center,
                                                  children: [
                                                    const SizedBox(
                                                      width: 20,
                                                      height: 20,
                                                      child:
                                                          CircularProgressIndicator(
                                                            strokeWidth: 2,
                                                          ),
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
                                            final cardColor = isDark
                                                ? Theme.of(context)
                                                      .colorScheme
                                                      .onSecondary
                                                      .withValues(alpha: 0.5)
                                                : Theme.of(context)
                                                      .colorScheme
                                                      .secondaryContainer
                                                      .withValues(alpha: 0.5);

                                            final bool isFirst = idx == 0;
                                            final bool isLast =
                                                idx ==
                                                _playlistResults.length - 1;
                                            final bool isOnly =
                                                _playlistResults.length == 1;

                                            BorderRadius borderRadius;
                                            if (isOnly) {
                                              borderRadius =
                                                  BorderRadius.circular(16);
                                            } else if (isFirst) {
                                              borderRadius =
                                                  const BorderRadius.only(
                                                    topLeft: Radius.circular(
                                                      16,
                                                    ),
                                                    topRight: Radius.circular(
                                                      16,
                                                    ),
                                                    bottomLeft: Radius.circular(
                                                      4,
                                                    ),
                                                    bottomRight:
                                                        Radius.circular(4),
                                                  );
                                            } else if (isLast) {
                                              borderRadius =
                                                  const BorderRadius.only(
                                                    topLeft: Radius.circular(4),
                                                    topRight: Radius.circular(
                                                      4,
                                                    ),
                                                    bottomLeft: Radius.circular(
                                                      16,
                                                    ),
                                                    bottomRight:
                                                        Radius.circular(16),
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
                                                          playlist['thumbUrl'] !=
                                                              null
                                                          ? _buildSafeNetworkImage(
                                                              playlist['thumbUrl']!,
                                                              width: 50,
                                                              height: 50,
                                                              fit: BoxFit.cover,
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
                                                                color:
                                                                    Colors.grey,
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
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),

                                                    trailing: IconButton(
                                                      icon: const Icon(
                                                        Icons.link,
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
                                        ),
                                      ),
                                    ],
                                  );
                                } else {
                                  // Vista normal: resumen de ambas categorías
                                  return ListView(
                                    children: [
                                      // Sección Artistas
                                      if (_artistResults.isNotEmpty)
                                        Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 4,
                                                  ),
                                              child: Text(
                                                LocaleProvider.tr('artists'),
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .titleMedium
                                                    ?.copyWith(fontSize: 20),
                                              ),
                                            ),
                                            const SizedBox(height: 2),
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
                                                    _artistResults
                                                        .take(3)
                                                        .length;

                                                final isDark =
                                                    Theme.of(
                                                      context,
                                                    ).brightness ==
                                                    Brightness.dark;
                                                final cardColor = isDark
                                                    ? Theme.of(context)
                                                          .colorScheme
                                                          .onSecondary
                                                          .withValues(
                                                            alpha: 0.5,
                                                          )
                                                    : Theme.of(context)
                                                          .colorScheme
                                                          .secondaryContainer
                                                          .withValues(
                                                            alpha: 0.5,
                                                          );

                                                final bool isFirst = idx == 0;
                                                final bool isLast =
                                                    idx == resultsCount - 1;
                                                final bool isOnly =
                                                    resultsCount == 1;

                                                BorderRadius borderRadius;
                                                if (isOnly) {
                                                  borderRadius =
                                                      BorderRadius.circular(16);
                                                } else if (isFirst) {
                                                  borderRadius =
                                                      const BorderRadius.only(
                                                        topLeft:
                                                            Radius.circular(16),
                                                        topRight:
                                                            Radius.circular(16),
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
                                                            Radius.circular(16),
                                                        bottomRight:
                                                            Radius.circular(16),
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
                                                    shape:
                                                        RoundedRectangleBorder(
                                                          borderRadius:
                                                              borderRadius,
                                                        ),
                                                    child: InkWell(
                                                      borderRadius:
                                                          borderRadius,
                                                      onTap: () {
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
                                                      child: ListTile(
                                                        contentPadding:
                                                            const EdgeInsets.symmetric(
                                                              horizontal: 16,
                                                              vertical: 10,
                                                            ),
                                                        leading: ClipRRect(
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                25,
                                                              ),
                                                          child:
                                                              thumbUrl !=
                                                                      null &&
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
                                                                    Icons
                                                                        .person,
                                                                    size: 28,
                                                                  ),
                                                                ),
                                                        ),
                                                        title: Text(
                                                          artistName,
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style:
                                                              Theme.of(context)
                                                                  .textTheme
                                                                  .titleMedium,
                                                        ),
                                                        trailing: const Icon(
                                                          Icons.chevron_right,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                );
                                              }).toList(),
                                            ),
                                            const SizedBox(height: 16),
                                          ],
                                        ),
                                      // Sección Canciones
                                      if (_songResults.isNotEmpty)
                                        Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            InkWell(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              onTap: () {
                                                setState(() {
                                                  _expandedCategory = 'songs';
                                                });
                                              },
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      vertical: 4,
                                                    ),
                                                child: Row(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment
                                                          .spaceBetween,
                                                  children: [
                                                    Text(
                                                      LocaleProvider.tr(
                                                        'songs_search',
                                                      ),
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .titleMedium
                                                          ?.copyWith(
                                                            fontSize: 20,
                                                          ),
                                                    ),
                                                    Icon(Icons.chevron_right),
                                                  ],
                                                ),
                                              ),
                                            ),
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
                                                  final cardColor = isDark
                                                      ? Theme.of(context)
                                                            .colorScheme
                                                            .onSecondary
                                                            .withValues(
                                                              alpha: 0.5,
                                                            )
                                                      : Theme.of(context)
                                                            .colorScheme
                                                            .secondaryContainer
                                                            .withValues(
                                                              alpha: 0.5,
                                                            );

                                                  final int totalToShow =
                                                      _songResults.length < 3
                                                      ? _songResults.length
                                                      : 3;
                                                  final bool isFirst =
                                                      index == 0;
                                                  final bool isLast =
                                                      index == totalToShow - 1;
                                                  final bool isOnly =
                                                      totalToShow == 1;

                                                  BorderRadius borderRadius;
                                                  if (isOnly) {
                                                    borderRadius =
                                                        BorderRadius.circular(
                                                          16,
                                                        );
                                                  } else if (isFirst) {
                                                    borderRadius =
                                                        const BorderRadius.only(
                                                          topLeft:
                                                              Radius.circular(
                                                                16,
                                                              ),
                                                          topRight:
                                                              Radius.circular(
                                                                16,
                                                              ),
                                                          bottomLeft:
                                                              Radius.circular(
                                                                4,
                                                              ),
                                                          bottomRight:
                                                              Radius.circular(
                                                                4,
                                                              ),
                                                        );
                                                  } else if (isLast) {
                                                    borderRadius =
                                                        const BorderRadius.only(
                                                          topLeft:
                                                              Radius.circular(
                                                                4,
                                                              ),
                                                          topRight:
                                                              Radius.circular(
                                                                4,
                                                              ),
                                                          bottomLeft:
                                                              Radius.circular(
                                                                16,
                                                              ),
                                                          bottomRight:
                                                              Radius.circular(
                                                                16,
                                                              ),
                                                        );
                                                  } else {
                                                    borderRadius =
                                                        BorderRadius.circular(
                                                          4,
                                                        );
                                                  }

                                                  return Padding(
                                                    padding: EdgeInsets.only(
                                                      bottom: isLast ? 0 : 4,
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
                                                          _toggleSelection(
                                                            index,
                                                            isVideo: false,
                                                          );
                                                        },
                                                        onTap: () {
                                                          if (_isSelectionMode) {
                                                            _toggleSelection(
                                                              index,
                                                              isVideo: false,
                                                            );
                                                          } else {
                                                            showModalBottomSheet(
                                                              context: context,
                                                              shape: const RoundedRectangleBorder(
                                                                borderRadius:
                                                                    BorderRadius.vertical(
                                                                      top:
                                                                          Radius.circular(
                                                                            16,
                                                                          ),
                                                                    ),
                                                              ),
                                                              builder: (context) {
                                                                return SafeArea(
                                                                  child: Padding(
                                                                    padding:
                                                                        const EdgeInsets.all(
                                                                          24,
                                                                        ),
                                                                    child: YtPreviewPlayer(
                                                                      results:
                                                                          _songResults,
                                                                      currentIndex:
                                                                          index,
                                                                    ),
                                                                  ),
                                                                );
                                                              },
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
                                                                MainAxisSize
                                                                    .min,
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
                                                                        width:
                                                                            50,
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
                                                                            borderRadius: BorderRadius.circular(
                                                                              8,
                                                                            ),
                                                                          ),
                                                                          child: const Icon(
                                                                            Icons.music_note,
                                                                            size:
                                                                                24,
                                                                            color:
                                                                                Colors.grey,
                                                                          ),
                                                                        ),
                                                                      )
                                                                    : Container(
                                                                        width:
                                                                            50,
                                                                        height:
                                                                            50,
                                                                        decoration: BoxDecoration(
                                                                          color:
                                                                              Colors.grey[300],
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
                                                                Theme.of(
                                                                      context,
                                                                    )
                                                                    .textTheme
                                                                    .titleMedium,
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                          ),
                                                          subtitle: Text(
                                                            item.artist ??
                                                                LocaleProvider.tr(
                                                                  'artist_unknown',
                                                                ),
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                          ),
                                                          trailing: IconButton(
                                                            icon: const Icon(
                                                              Icons.link,
                                                            ),
                                                            tooltip:
                                                                LocaleProvider.tr(
                                                                  'copy_link',
                                                                ),
                                                            onPressed: () {
                                                              Clipboard.setData(
                                                                ClipboardData(
                                                                  text:
                                                                      'https://music.youtube.com/watch?v=${item.videoId}',
                                                                ),
                                                              );
                                                            },
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
                                      // Sección Videos
                                      if (_videoResults.isNotEmpty)
                                        SizedBox(height: 16),
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
                                              });
                                            },
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 4,
                                                  ),
                                              child: Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment
                                                        .spaceBetween,
                                                children: [
                                                  Text(
                                                    LocaleProvider.tr('videos'),
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .titleMedium
                                                        ?.copyWith(
                                                          fontSize: 20,
                                                        ),
                                                  ),
                                                  Icon(Icons.chevron_right),
                                                ],
                                              ),
                                            ),
                                          ),
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
                                                final cardColor = isDark
                                                    ? Theme.of(context)
                                                          .colorScheme
                                                          .onSecondary
                                                          .withValues(
                                                            alpha: 0.5,
                                                          )
                                                    : Theme.of(context)
                                                          .colorScheme
                                                          .secondaryContainer
                                                          .withValues(
                                                            alpha: 0.5,
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
                                                      BorderRadius.circular(16);
                                                } else if (isFirst) {
                                                  borderRadius =
                                                      const BorderRadius.only(
                                                        topLeft:
                                                            Radius.circular(16),
                                                        topRight:
                                                            Radius.circular(16),
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
                                                            Radius.circular(16),
                                                        bottomRight:
                                                            Radius.circular(16),
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
                                                        _toggleSelection(
                                                          index,
                                                          isVideo: true,
                                                        );
                                                      },
                                                      onTap: () {
                                                        if (_isSelectionMode) {
                                                          _toggleSelection(
                                                            index,
                                                            isVideo: true,
                                                          );
                                                        } else {
                                                          showModalBottomSheet(
                                                            context: context,
                                                            shape: const RoundedRectangleBorder(
                                                              borderRadius:
                                                                  BorderRadius.vertical(
                                                                    top:
                                                                        Radius.circular(
                                                                          16,
                                                                        ),
                                                                  ),
                                                            ),
                                                            builder: (context) {
                                                              return SafeArea(
                                                                child: Padding(
                                                                  padding:
                                                                      const EdgeInsets.all(
                                                                        24,
                                                                      ),
                                                                  child: YtPreviewPlayer(
                                                                    results:
                                                                        _videoResults,
                                                                    currentIndex:
                                                                        index,
                                                                  ),
                                                                ),
                                                              );
                                                            },
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
                                                          item.artist ??
                                                              LocaleProvider.tr(
                                                                'artist_unknown',
                                                              ),
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                        ),
                                                        trailing: IconButton(
                                                          icon: const Icon(
                                                            Icons.link,
                                                          ),
                                                          tooltip:
                                                              LocaleProvider.tr(
                                                                'copy_link',
                                                              ),
                                                          onPressed: () {
                                                            Clipboard.setData(
                                                              ClipboardData(
                                                                text:
                                                                    'https://www.youtube.com/watch?v=${item.videoId}',
                                                              ),
                                                            );
                                                          },
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
                                      // Sección Listas de Reproducción
                                      if (_playlistResults.isNotEmpty)
                                        SizedBox(height: 16),
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
                                              });
                                            },
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 4,
                                                  ),
                                              child: Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment
                                                        .spaceBetween,
                                                children: [
                                                  Text(
                                                    LocaleProvider.tr(
                                                      'playlists',
                                                    ),
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .titleMedium
                                                        ?.copyWith(
                                                          fontSize: 20,
                                                        ),
                                                  ),
                                                  Icon(Icons.chevron_right),
                                                ],
                                              ),
                                            ),
                                          ),
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
                                                final cardColor = isDark
                                                    ? Theme.of(context)
                                                          .colorScheme
                                                          .onSecondary
                                                          .withValues(
                                                            alpha: 0.5,
                                                          )
                                                    : Theme.of(context)
                                                          .colorScheme
                                                          .secondaryContainer
                                                          .withValues(
                                                            alpha: 0.5,
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
                                                      BorderRadius.circular(16);
                                                } else if (isFirst) {
                                                  borderRadius =
                                                      const BorderRadius.only(
                                                        topLeft:
                                                            Radius.circular(16),
                                                        topRight:
                                                            Radius.circular(16),
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
                                                            Radius.circular(16),
                                                        bottomRight:
                                                            Radius.circular(16),
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
                                                          _playlistSongs =
                                                              songs;
                                                          _loadingPlaylistSongs =
                                                              false;
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
                                                          style:
                                                              Theme.of(context)
                                                                  .textTheme
                                                                  .titleMedium,
                                                          maxLines: 2,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                        ),
                                                        trailing: IconButton(
                                                          icon: const Icon(
                                                            Icons.link,
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
                                              }).toList(),
                                            ),
                                          ),
                                        ],
                                      ),
                                      // Sección Álbumes
                                      if (_albumResults.isNotEmpty)
                                        SizedBox(height: 16),
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
                                              });
                                            },
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 4,
                                                  ),
                                              child: Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment
                                                        .spaceBetween,
                                                children: [
                                                  Text(
                                                    LocaleProvider.tr('albums'),
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .titleMedium
                                                        ?.copyWith(
                                                          fontSize: 20,
                                                        ),
                                                  ),
                                                  Icon(Icons.chevron_right),
                                                ],
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          SizedBox(
                                            height: 180,
                                            child: ListView.separated(
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
                                  );
                                }
                              },
                            ),
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

  // Función para mostrar mensajes con diseño elegante
  void _showMessage(String title, String message) {
    showDialog(
      context: context,
      builder: (context) => ValueListenableBuilder<AppColorScheme>(
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
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
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
                        message,
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
                  // Tarjeta de aceptar
                  InkWell(
                    onTap: () => Navigator.of(context).pop(),
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      width: double.infinity,
                      padding: EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: isAmoled && isDark
                            ? Colors.white.withValues(
                                alpha: 0.2,
                              ) // Color personalizado para amoled
                            : Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isAmoled && isDark
                              ? Colors.white.withValues(
                                  alpha: 0.4,
                                ) // Borde personalizado para amoled
                              : Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.3),
                          width: 2,
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              color: isAmoled && isDark
                                  ? Colors.white.withValues(
                                      alpha: 0.2,
                                    ) // Fondo del ícono para amoled
                                  : Theme.of(context).colorScheme.primary
                                        .withValues(alpha: 0.1),
                            ),
                            child: Icon(
                              Icons.check_circle,
                              size: 30,
                              color: isAmoled && isDark
                                  ? Colors
                                        .white // Ícono blanco para amoled
                                  : Theme.of(context).colorScheme.primary,
                            ),
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  LocaleProvider.tr('ok'),
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: isAmoled && isDark
                                        ? Colors
                                              .white // Texto blanco para amoled
                                        : Theme.of(context).colorScheme.primary,
                                  ),
                                ),
                              ],
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
    // Limpiar caché de imágenes al cerrar el modal
    _clearImageCache();
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
            child: CircularProgressIndicator(
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
          return Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Center(
              child: CircularProgressIndicator(strokeWidth: 3),
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
      final response = await http.get(Uri.parse(imageUrl));
      if (response.statusCode == 200) {
        final bytes = response.bodyBytes;

        Uint8List? processedBytes;
        // Determinar si es una imagen hqdefault (480x360) o maxresdefault
        if (imageUrl.contains('hqdefault')) {
          // Para hqdefault, usar recorte especial para eliminar franjas negras
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

  // Función para limpiar el caché de imágenes (opcional, para liberar memoria)
  void _clearImageCache() {
    _imageCache.clear();
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
        borderRadius: BorderRadius.circular(16),
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
                                subtitle:
                                    _currentItem.artist ??
                                    widget.fallbackArtist,
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
                                  color: Theme.of(
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
                                                strokeWidth: 2.5,
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onSecondaryContainer,
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
                            (_currentItem.artist != null &&
                                    _currentItem.artist!.trim().isNotEmpty)
                                ? _currentItem.artist!
                                : (widget.fallbackArtist ??
                                      LocaleProvider.tr('artist_unknown')),
                            style: const TextStyle(fontSize: 15),
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
                                    ? Symbols.pause_rounded
                                    : Symbols.play_arrow_rounded,
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
                    Symbols.skip_previous_rounded,
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
                    Symbols.skip_next_rounded,
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
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
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
                        message,
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
                  // Tarjeta de aceptar
                  InkWell(
                    onTap: () => Navigator.of(context).pop(),
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      width: double.infinity,
                      padding: EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: isAmoled && isDark
                            ? Colors.white.withValues(
                                alpha: 0.2,
                              ) // Color personalizado para amoled
                            : Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isAmoled && isDark
                              ? Colors.white.withValues(
                                  alpha: 0.4,
                                ) // Borde personalizado para amoled
                              : Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.3),
                          width: 2,
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              color: isAmoled && isDark
                                  ? Colors.white.withValues(
                                      alpha: 0.2,
                                    ) // Fondo del ícono para amoled
                                  : Theme.of(context).colorScheme.primary
                                        .withValues(alpha: 0.1),
                            ),
                            child: Icon(
                              Icons.check_circle,
                              size: 30,
                              color: isAmoled && isDark
                                  ? Colors
                                        .white // Ícono blanco para amoled
                                  : Theme.of(context).colorScheme.primary,
                            ),
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  LocaleProvider.tr('ok'),
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: isAmoled && isDark
                                        ? Colors
                                              .white // Texto blanco para amoled
                                        : Theme.of(context).colorScheme.primary,
                                  ),
                                ),
                              ],
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
