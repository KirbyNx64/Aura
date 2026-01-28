import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/yt_search/service.dart';
import 'package:music/utils/yt_search/yt_screen.dart' hide AnimatedTapButton;
import 'package:music/utils/db/artist_images_cache_db.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/notification_service.dart';
import 'package:music/utils/simple_yt_download.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:music/widgets/animated_tap_button.dart';

class ArtistScreen extends StatefulWidget {
  final String artistName;
  final String? browseId;
  const ArtistScreen({super.key, required this.artistName, this.browseId});

  @override
  State<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends State<ArtistScreen> {
  bool _loading = true;
  Map<String, dynamic>? _artist;
  bool _descExpanded = false;
  String? _expandedCategory; // 'songs', 'videos', 'albums', o null
  List<YtMusicResult> _songs = [];
  List<YtMusicResult> _videos = [];
  List<Map<String, String>> _albums = [];

  // Estado para álbum seleccionado
  List<YtMusicResult> _albumSongs = [];
  Map<String, dynamic>? _currentAlbum;
  bool _loadingAlbumSongs = false;

  // Estado para selección múltiple
  final Set<String> _selectedIndexes = {};
  bool _isSelectionMode = false;

  // Estado para paginación de canciones
  String? _songsContinuationToken;
  bool _loadingMoreSongs = false;
  bool _hasMoreSongs = true;

  // Estado para paginación de videos
  String? _videosContinuationToken;
  bool _loadingMoreVideos = false;
  bool _hasMoreVideos = true;

  // ScrollController para detectar el final del scroll
  late ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _scrollController.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
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
      return fallback ??
          const Icon(Icons.music_note, size: 32, color: Colors.grey);
    }

    return Image.network(
      imageUrl,
      width: width,
      height: height,
      fit: fit ?? BoxFit.cover,
      errorBuilder: (context, error, stackTrace) {
        // Manejar errores de imagen de forma silenciosa
        return fallback ??
            const Icon(Icons.music_note, size: 32, color: Colors.grey);
      },
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return SizedBox(
          width: width,
          height: height,
          child: const Center(
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.transparent,
            ),
          ),
        );
      },
    );
  }

  // Función para detectar el final del scroll y cargar más contenido automáticamente
  void _onScroll() {
    // Verificar que el ScrollController esté montado y tenga posición válida
    if (!mounted || !_scrollController.hasClients) {
      return;
    }

    try {
      if (_scrollController.position.pixels >=
          _scrollController.position.maxScrollExtent - 200) {
        // Si estamos cerca del final (200px antes del final) y hay más contenido disponible
        if (_expandedCategory == 'songs' &&
            _hasMoreSongs &&
            !_loadingMoreSongs) {
          _loadMoreSongs();
        } else if (_expandedCategory == 'videos' &&
            _hasMoreVideos &&
            !_loadingMoreVideos) {
          _loadMoreVideos();
        }
      }
    } catch (e) {
      // Capturar cualquier excepción relacionada con el scroll
      // No hacer print para evitar que la app se detenga
    }
  }

  // Función para reiniciar el scroll al principio
  void _resetScroll() {
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  Future<void> _load() async {
    try {
      // ignore: avoid_print
      // print('ArtistScreen._load start for: ${widget.artistName}');

      // Si tenemos browseId específico, usarlo directamente
      if (widget.browseId != null) {
        // print('🎯 ArtistScreen usando browseId específico: ${widget.browseId} para artista: ${widget.artistName}');
        final detailed = await getArtistDetails(widget.browseId!);
        if (detailed != null) {
          // print('✅ Artista cargado con browseId: ${widget.browseId} - Nombre: ${detailed['name']} - Thumb: ${detailed['thumbUrl'] != null ? 'Sí' : 'No'}');
          setState(() {
            _artist = detailed;
            _loading = false;
          });

          // Cargar contenido del artista
          _loadArtistContent(detailed);
          return;
        } else {
          // print('❌ No se pudo cargar artista con browseId: ${widget.browseId}');
        }
      }

      // 1) Intentar cache local como en home_screen
      final cached = await ArtistImagesCacheDB.getCachedArtistImage(
        widget.artistName,
      );
      Map<String, dynamic>? info;
      if (cached != null) {
        info = {
          'name': cached['name'] ?? widget.artistName,
          'thumbUrl': cached['thumbUrl'],
          'subscribers': cached['subscribers'],
          'browseId': cached['browseId'],
        };
        // 2) Si hay browseId, completar descripción desde browse
        if (cached['browseId'] != null) {
          final detailed = await getArtistDetails(cached['browseId']);
          if (detailed != null) {
            info = {
              ...info,
              'description': detailed['description'],
              'thumbUrl': info['thumbUrl'] ?? detailed['thumbUrl'],
              'name': info['name'] ?? detailed['name'],
              'subscribers': info['subscribers'] ?? detailed['subscribers'],
            };
            // Fallback Wikipedia si no hay descripción
            if ((info['description'] == null ||
                info['description'].toString().trim().isEmpty)) {
              final wiki = await getArtistWikipediaDescription(
                widget.artistName,
              );
              if (wiki != null) info['description'] = wiki;
            }
          }
        } else {
          // Si hay caché sin browseId, buscar para obtener browseId y forzar browse (para activar prints)
          final yt = await searchArtists(widget.artistName, limit: 1);
          if (yt.isNotEmpty && yt.first['browseId'] != null) {
            final bid = yt.first['browseId'];
            // ignore: avoid_print
            // print('ArtistScreen._load fetched browseId from search: $bid');
            final detailed = await getArtistDetails(bid);
            if (detailed != null) {
              info = {
                ...info,
                'browseId': bid,
                'description': detailed['description'],
                'thumbUrl': info['thumbUrl'] ?? detailed['thumbUrl'],
                'name': info['name'] ?? detailed['name'],
                'subscribers': info['subscribers'] ?? detailed['subscribers'],
              };
              if ((info['description'] == null ||
                  info['description'].toString().trim().isEmpty)) {
                final wiki = await getArtistWikipediaDescription(
                  widget.artistName,
                );
                if (wiki != null) info['description'] = wiki;
              }
            }
          }
        }
      } else {
        // 3) Buscar en YouTube Music y cachear como hace home_screen
        final yt = await searchArtists(widget.artistName, limit: 1);
        if (yt.isNotEmpty) {
          final a = yt.first;
          await ArtistImagesCacheDB.cacheArtistImage(
            artistName: widget.artistName,
            thumbUrl: a['thumbUrl'],
            browseId: a['browseId'],
            subscribers: a['subscribers'],
          );
          info = {
            'name': a['name'] ?? widget.artistName,
            'thumbUrl': a['thumbUrl'],
            'subscribers': a['subscribers'],
            'browseId': a['browseId'],
          };
          if (a['browseId'] != null) {
            final detailed = await getArtistDetails(a['browseId']);
            if (detailed != null) {
              info = {
                ...info,
                'description': detailed['description'],
                'thumbUrl': info['thumbUrl'] ?? detailed['thumbUrl'],
              };
              if ((info['description'] == null ||
                  info['description'].toString().trim().isEmpty)) {
                final wiki = await getArtistWikipediaDescription(
                  widget.artistName,
                );
                if (wiki != null) info['description'] = wiki;
              }
            }
          }
        } else {
          // 4) Fallback directo al helper por nombre
          info = await getArtistInfoByName(widget.artistName);
          if (info != null &&
              (info['description'] == null ||
                  info['description'].toString().trim().isEmpty)) {
            final wiki = await getArtistWikipediaDescription(widget.artistName);
            if (wiki != null) info['description'] = wiki;
          }
        }
      }

      // ignore: avoid_print
      // print('ArtistScreen._load done, has info: ${info != null}');
      // Fallback final: si no hay descripción todavía, intentar Wikipedia
      Map<String, dynamic>? result = info;
      if (result == null ||
          result['description'] == null ||
          result['description'].toString().trim().isEmpty) {
        final wiki = await getArtistWikipediaDescription(widget.artistName);
        if (wiki != null && wiki.trim().isNotEmpty) {
          result = {
            ...(result ?? {}),
            'name': (result?['name']?.toString().isNotEmpty ?? false)
                ? result!['name']
                : widget.artistName,
            'description': wiki,
          };
          // ignore: avoid_print
          // print('ArtistScreen._load used Wikipedia fallback for: ${widget.artistName}');
        }
      }
      if (!mounted) return;
      setState(() {
        _artist = result;
        _loading = false;
      });

      // Cargar contenido del artista simulando búsqueda como yt_screen
      if (result != null) {
        try {
          // Buscar canciones, videos y álbumes del artista
          final songFuture = _loadSongsWithPagination(widget.artistName);
          final videoFuture = _loadVideosWithPagination(widget.artistName);
          final albumFuture = searchAlbumsOnly(widget.artistName);

          final searchResults = await Future.wait([
            songFuture,
            videoFuture,
            albumFuture,
          ]);

          if (mounted) {
            final songsData = searchResults[0] as Map<String, dynamic>;
            final videosData = searchResults[1] as Map<String, dynamic>;
            final allAlbums = (searchResults[2] as List)
                .cast<Map<String, String>>();

            setState(() {
              // Filtrar canciones por artista
              _songs = _filterSongsByArtist(
                songsData['songs'] as List<YtMusicResult>,
                widget.artistName,
              );
              _songsContinuationToken =
                  songsData['continuationToken'] as String?;
              _hasMoreSongs = _songsContinuationToken != null;

              // Videos
              _videos = videosData['videos'] as List<YtMusicResult>;
              _videosContinuationToken =
                  videosData['continuationToken'] as String?;
              _hasMoreVideos = _videosContinuationToken != null;

              _albums = allAlbums;
            });
          }
        } catch (e) {
          // print('👻 ArtistScreen._load error loading content: $e');
        }
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    }
  }

  // Función para cargar contenido del artista (canciones, videos, álbumes)
  Future<void> _loadArtistContent(Map<String, dynamic> artistInfo) async {
    try {
      // Buscar canciones, videos y álbumes del artista
      final songFuture = _loadSongsWithPagination(widget.artistName);
      final videoFuture = _loadVideosWithPagination(widget.artistName);
      final albumFuture = searchAlbumsOnly(widget.artistName);

      final searchResults = await Future.wait([
        songFuture,
        videoFuture,
        albumFuture,
      ]);

      if (mounted) {
        final songsData = searchResults[0] as Map<String, dynamic>;
        final videosData = searchResults[1] as Map<String, dynamic>;
        final allAlbums = (searchResults[2] as List)
            .cast<Map<String, String>>();

        setState(() {
          // Filtrar canciones por artista
          _songs = _filterSongsByArtist(
            songsData['songs'] as List<YtMusicResult>,
            widget.artistName,
          );
          _songsContinuationToken = songsData['continuationToken'] as String?;
          _hasMoreSongs = _songsContinuationToken != null;

          // Videos
          _videos = videosData['videos'] as List<YtMusicResult>;
          _videosContinuationToken = videosData['continuationToken'] as String?;
          _hasMoreVideos = _videosContinuationToken != null;

          _albums = allAlbums;
        });
      }
    } catch (e) {
      // print('👻 ArtistScreen._loadArtistContent error: $e');
    }
  }

  // Función para alternar selección múltiple
  void _toggleSelection(
    int index, {
    required bool isVideo,
    bool isAlbum = false,
  }) {
    setState(() {
      final key = isAlbum
          ? 'album-$index'
          : isVideo
          ? 'video-${_videos[index].videoId}'
          : 'song-${_songs[index].videoId}';

      if (_selectedIndexes.contains(key)) {
        _selectedIndexes.remove(key);
        if (_selectedIndexes.isEmpty) {
          _isSelectionMode = false;
        }
      } else {
        _selectedIndexes.add(key);
        if (!_isSelectionMode) {
          _isSelectionMode = true;
        }
      }
    });
  }

  // Métodos para pop interno desde el home
  bool canPopInternally() {
    return _expandedCategory != null;
  }

  void handleInternalPop() {
    setState(() {
      _expandedCategory = null;
      _albumSongs = [];
      _currentAlbum = null;
      _resetScroll();
    });
  }

  // Función para filtrar canciones por artista
  List<YtMusicResult> _filterSongsByArtist(
    List<YtMusicResult> songs,
    String artistName,
  ) {
    if (artistName.trim().isEmpty) return songs;

    final normalizedArtistName = artistName.toLowerCase().trim();

    return songs.where((song) {
      if (song.artist == null || song.artist!.isEmpty) return false;

      final normalizedSongArtist = song.artist!.toLowerCase().trim();

      // Verificar coincidencia exacta o si el artista de la canción contiene el nombre buscado
      return normalizedSongArtist == normalizedArtistName ||
          normalizedSongArtist.contains(normalizedArtistName);
    }).toList();
  }

  // Función para cargar canciones con paginación
  Future<Map<String, dynamic>> _loadSongsWithPagination(
    String query, {
    String? continuationToken,
  }) async {
    final data = {
      ...ytServiceContext,
      'query': query,
      'params': getSearchParams('songs', null, false),
    };

    if (continuationToken != null) {
      data['continuation'] = continuationToken;
    }

    try {
      final response = (await sendRequest("search", data)).data;
      final results = <YtMusicResult>[];
      String? nextToken;

      // Si es una búsqueda inicial
      if (continuationToken == null) {
        final contents = nav(response, [
          'contents',
          'tabbedSearchResultsRenderer',
          'tabs',
          0,
          'tabRenderer',
          'content',
          'sectionListRenderer',
          'contents',
          0,
          'musicShelfRenderer',
          'contents',
        ]);

        if (contents is List) {
          parseSongs(contents, results);
        }

        // Obtener token de continuación
        final shelfRenderer = nav(response, [
          'contents',
          'tabbedSearchResultsRenderer',
          'tabs',
          0,
          'tabRenderer',
          'content',
          'sectionListRenderer',
          'contents',
          0,
          'musicShelfRenderer',
        ]);

        if (shelfRenderer != null && shelfRenderer['continuations'] != null) {
          nextToken =
              shelfRenderer['continuations'][0]['nextContinuationData']['continuation'];
        }
      } else {
        // Si es una continuación, la estructura es diferente
        var contents = nav(response, [
          'onResponseReceivedActions',
          0,
          'appendContinuationItemsAction',
          'continuationItems',
        ]);

        contents ??= nav(response, [
          'continuationContents',
          'musicShelfContinuation',
          'contents',
        ]);

        if (contents is List) {
          final songItems = contents
              .where((item) => item['musicResponsiveListItemRenderer'] != null)
              .toList();
          if (songItems.isNotEmpty) {
            parseSongs(songItems, results);
          }
        }

        // Obtener siguiente token
        try {
          nextToken = nav(response, [
            'onResponseReceivedActions',
            0,
            'appendContinuationItemsAction',
            'continuationItems',
            0,
            'continuationItemRenderer',
            'continuationEndpoint',
            'continuationCommand',
            'token',
          ]);
          nextToken ??= nav(response, [
            'continuationContents',
            'musicShelfContinuation',
            'continuations',
            0,
            'nextContinuationData',
            'continuation',
          ]);
        } catch (e) {
          nextToken = null;
        }
      }

      return {'songs': results, 'continuationToken': nextToken};
    } catch (e) {
      return {'songs': <YtMusicResult>[], 'continuationToken': null};
    }
  }

  // Función para cargar videos con paginación
  Future<Map<String, dynamic>> _loadVideosWithPagination(
    String query, {
    String? continuationToken,
  }) async {
    final data = {
      ...ytServiceContext,
      'query': query,
      'params': getSearchParams('videos', null, false),
    };

    if (continuationToken != null) {
      data['continuation'] = continuationToken;
    }

    try {
      final response = (await sendRequest("search", data)).data;
      final results = <YtMusicResult>[];
      String? nextToken;

      // Si es una búsqueda inicial
      if (continuationToken == null) {
        final contents = nav(response, [
          'contents',
          'tabbedSearchResultsRenderer',
          'tabs',
          0,
          'tabRenderer',
          'content',
          'sectionListRenderer',
          'contents',
          0,
          'musicShelfRenderer',
          'contents',
        ]);

        if (contents is List) {
          for (var item in contents) {
            final renderer = item['musicResponsiveListItemRenderer'];
            if (renderer != null) {
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

        // Obtener token de continuación
        final shelfRenderer = nav(response, [
          'contents',
          'tabbedSearchResultsRenderer',
          'tabs',
          0,
          'tabRenderer',
          'content',
          'sectionListRenderer',
          'contents',
          0,
          'musicShelfRenderer',
        ]);

        if (shelfRenderer != null && shelfRenderer['continuations'] != null) {
          nextToken =
              shelfRenderer['continuations'][0]['nextContinuationData']['continuation'];
        }
      } else {
        // Si es una continuación, la estructura es diferente
        var contents = nav(response, [
          'onResponseReceivedActions',
          0,
          'appendContinuationItemsAction',
          'continuationItems',
        ]);

        contents ??= nav(response, [
          'continuationContents',
          'musicShelfContinuation',
          'contents',
        ]);

        if (contents is List) {
          final videoItems = contents
              .where((item) => item['musicResponsiveListItemRenderer'] != null)
              .toList();
          if (videoItems.isNotEmpty) {
            for (var item in videoItems) {
              final renderer = item['musicResponsiveListItemRenderer'];
              if (renderer != null) {
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

        // Obtener siguiente token
        try {
          nextToken = nav(response, [
            'onResponseReceivedActions',
            0,
            'appendContinuationItemsAction',
            'continuationItems',
            0,
            'continuationItemRenderer',
            'continuationEndpoint',
            'continuationCommand',
            'token',
          ]);
          nextToken ??= nav(response, [
            'continuationContents',
            'musicShelfContinuation',
            'continuations',
            0,
            'nextContinuationData',
            'continuation',
          ]);
        } catch (e) {
          nextToken = null;
        }
      }

      return {'videos': results, 'continuationToken': nextToken};
    } catch (e) {
      return {'videos': <YtMusicResult>[], 'continuationToken': null};
    }
  }

  // Función para cargar más canciones
  Future<void> _loadMoreSongs() async {
    if (_loadingMoreSongs ||
        !_hasMoreSongs ||
        _songsContinuationToken == null) {
      return;
    }

    setState(() {
      _loadingMoreSongs = true;
    });

    try {
      final songsData = await _loadSongsWithPagination(
        widget.artistName,
        continuationToken: _songsContinuationToken,
      );

      if (mounted) {
        final newSongs = songsData['songs'] as List<YtMusicResult>;
        final filteredNewSongs = _filterSongsByArtist(
          newSongs,
          widget.artistName,
        );

        setState(() {
          _songs.addAll(filteredNewSongs);
          _songsContinuationToken = songsData['continuationToken'] as String?;
          _hasMoreSongs = _songsContinuationToken != null;
          _loadingMoreSongs = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingMoreSongs = false;
        });
      }
    }
  }

  // Función para cargar más videos
  Future<void> _loadMoreVideos() async {
    if (_loadingMoreVideos ||
        !_hasMoreVideos ||
        _videosContinuationToken == null) {
      return;
    }

    setState(() {
      _loadingMoreVideos = true;
    });

    try {
      final videosData = await _loadVideosWithPagination(
        widget.artistName,
        continuationToken: _videosContinuationToken,
      );

      if (mounted) {
        final newVideos = videosData['videos'] as List<YtMusicResult>;

        setState(() {
          _videos.addAll(newVideos);
          _videosContinuationToken = videosData['continuationToken'] as String?;
          _hasMoreVideos = _videosContinuationToken != null;
          _loadingMoreVideos = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingMoreVideos = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isSystem = colorSchemeNotifier.value == AppColorScheme.system;
    // final isLight = Theme.of(context).brightness == Brightness.light;

    return PopScope(
      canPop: !canPopInternally(),
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && canPopInternally()) {
          handleInternalPop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: IconButton(
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
                      ).colorScheme.onSecondary.withValues(alpha: 0.5)
                    : Theme.of(
                        context,
                      ).colorScheme.secondaryContainer.withValues(alpha: 0.5),
              ),
              child: const Icon(Icons.arrow_back, size: 24),
            ),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: const TranslatedText('artist'),
          actions: [
            if (_isSelectionMode && _selectedIndexes.isNotEmpty)
              IconButton(
                onPressed: _downloadSelectedItems,
                icon: const Icon(Icons.download),
                tooltip: 'Descargar (${_selectedIndexes.length})',
              ),
            if (_isSelectionMode && _selectedIndexes.isNotEmpty)
              IconButton(
                onPressed: () {
                  setState(() {
                    _selectedIndexes.clear();
                    _isSelectionMode = false;
                  });
                },
                icon: const Icon(Icons.close),
                tooltip: 'Cancelar selección',
              ),
            if (!_isSelectionMode) ...[
              IconButton(
                constraints: const BoxConstraints(
                  minWidth: 40,
                  minHeight: 40,
                  maxWidth: 40,
                  maxHeight: 40,
                ),
                padding: EdgeInsets.zero,
                onPressed: () async {
                  final artistName =
                      _artist?['name']?.toString() ?? widget.artistName;
                  await _showArtistSearchOptions(artistName);
                },
                icon: const Icon(Icons.arrow_outward, size: 28),
                tooltip: LocaleProvider.tr('search_artist'),
              ),
              // Dialogo de informacion de la pantalla
              IconButton(
                icon: const Icon(Icons.info_outline, size: 28),
                tooltip: LocaleProvider.tr('info'),
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (context) {
                      return AlertDialog(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: isAmoled && isDark
                              ? const BorderSide(color: Colors.white, width: 1)
                              : BorderSide.none,
                        ),
                        title: Center(
                          child: Text(
                            LocaleProvider.tr('info'),
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        content: Text(LocaleProvider.tr('artist_info')),
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
                                      : Theme.of(context).colorScheme.primary
                                            .withValues(alpha: 0.3),
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
                                          ? Colors.white.withValues(alpha: 0.2)
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
                      );
                    },
                  );
                },
              ),
            ],
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _artist == null
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.person,
                      size: 70,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                    const SizedBox(height: 12),
                    TranslatedText(
                      'no_results',
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
            : SingleChildScrollView(
                controller: _scrollController,
                padding: EdgeInsets.fromLTRB(
                  16,
                  16,
                  16,
                  16 + MediaQuery.of(context).padding.bottom,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(100),
                        child: _buildSafeNetworkImage(
                          _artist!['thumbUrl'],
                          width: 160,
                          height: 160,
                          fit: BoxFit.cover,
                          fallback: Container(
                            width: 160,
                            height: 160,
                            decoration: BoxDecoration(
                              color:
                                  colorSchemeNotifier.value ==
                                      AppColorScheme.amoled
                                  ? Colors.white.withValues(alpha: 0.1)
                                  : Theme.of(context)
                                        .colorScheme
                                        .secondaryContainer
                                        .withValues(alpha: 0.8),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.person, size: 120),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            _artist!['name']?.toString() ?? widget.artistName,
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.bold),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    GestureDetector(
                      onTap: () {
                        if (_artist!['description'] != null &&
                            _artist!['description']
                                .toString()
                                .trim()
                                .isNotEmpty) {
                          setState(() {
                            _descExpanded = !_descExpanded;
                          });
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isAmoled
                              ? Colors.white.withAlpha(30)
                              : Theme.of(context).colorScheme.secondaryContainer
                                    .withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                (_artist!['description'] != null &&
                                        _artist!['description']
                                            .toString()
                                            .trim()
                                            .isNotEmpty)
                                    ? _artist!['description'].toString()
                                    : LocaleProvider.tr('no_description'),
                                style: Theme.of(context).textTheme.bodyLarge,
                                maxLines: _descExpanded ? null : 3,
                                overflow: _descExpanded
                                    ? TextOverflow.visible
                                    : TextOverflow.ellipsis,
                              ),
                            ),
                            if (_artist!['description'] != null &&
                                _artist!['description']
                                    .toString()
                                    .trim()
                                    .isNotEmpty)
                              Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: isAmoled
                                      ? Colors.white.withAlpha(60)
                                      : isSystem
                                      ? Theme.of(context)
                                            .colorScheme
                                            .secondaryContainer
                                            .withValues(alpha: 0.5)
                                      : Theme.of(context)
                                            .colorScheme
                                            .secondaryContainer
                                            .withValues(alpha: 0.5),
                                ),
                                child: Icon(
                                  _descExpanded
                                      ? Icons.expand_less
                                      : Icons.expand_more,
                                  size: 20,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),

                    // Mostrar contenido del artista con diseño de YouTube
                    if (_expandedCategory == 'songs') ...[
                      // Vista de solo canciones con botón de volver
                      const SizedBox(height: 24),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
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
                                    color: isDark
                                        ? Theme.of(context)
                                              .colorScheme
                                              .onSecondary
                                              .withValues(alpha: 0.5)
                                        : Theme.of(context)
                                              .colorScheme
                                              .secondaryContainer
                                              .withValues(alpha: 0.5),
                                  ),
                                  child: const Icon(Icons.arrow_back, size: 24),
                                ),
                                tooltip: 'Volver',
                                onPressed: () {
                                  setState(() {
                                    _expandedCategory = null;
                                    _resetScroll();
                                  });
                                },
                              ),
                              const SizedBox(width: 8),
                              Text(
                                LocaleProvider.tr('songs_search'),
                                style: Theme.of(
                                  context,
                                ).textTheme.titleMedium?.copyWith(fontSize: 20),
                              ),
                            ],
                          ),
                          ListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            addAutomaticKeepAlives: false,
                            addRepaintBoundaries: true,
                            itemCount:
                                _songs.length + (_loadingMoreSongs ? 1 : 0),
                            itemBuilder: (context, index) {
                              // Mostrar indicador de carga al final
                              if (_loadingMoreSongs && index == _songs.length) {
                                return Container(
                                  padding: const EdgeInsets.all(16),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      TranslatedText(
                                        'loading_more',
                                        style: const TextStyle(fontSize: 14),
                                      ),
                                    ],
                                  ),
                                );
                              }

                              final item = _songs[index];
                              final videoId = item.videoId;
                              final isSelected =
                                  videoId != null &&
                                  _selectedIndexes.contains('song-$videoId');

                              final cardColor = isDark
                                  ? Theme.of(context).colorScheme.onSecondary
                                        .withValues(alpha: 0.5)
                                  : Theme.of(context)
                                        .colorScheme
                                        .secondaryContainer
                                        .withValues(alpha: 0.5);

                              final bool isFirst = index == 0;
                              final bool isLast = index == _songs.length - 1;
                              final bool isOnly =
                                  _songs.length == 1 && !_loadingMoreSongs;

                              BorderRadius borderRadius;
                              if (isOnly) {
                                borderRadius = BorderRadius.circular(16);
                              } else if (isFirst) {
                                borderRadius = const BorderRadius.only(
                                  topLeft: Radius.circular(16),
                                  topRight: Radius.circular(16),
                                  bottomLeft: Radius.circular(4),
                                  bottomRight: Radius.circular(4),
                                );
                              } else if (isLast && !_loadingMoreSongs) {
                                borderRadius = const BorderRadius.only(
                                  topLeft: Radius.circular(4),
                                  topRight: Radius.circular(4),
                                  bottomLeft: Radius.circular(16),
                                  bottomRight: Radius.circular(16),
                                );
                              } else {
                                borderRadius = BorderRadius.circular(4);
                              }

                              return Padding(
                                padding: EdgeInsets.only(
                                  bottom: isLast && !_loadingMoreSongs ? 0 : 4,
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
                                      _toggleSelection(index, isVideo: false);
                                    },
                                    onTap: () {
                                      if (_isSelectionMode) {
                                        _toggleSelection(index, isVideo: false);
                                      } else {
                                        // Mostrar preview de la canción
                                        showModalBottomSheet(
                                          context: context,
                                          shape: const RoundedRectangleBorder(
                                            borderRadius: BorderRadius.vertical(
                                              top: Radius.circular(16),
                                            ),
                                          ),
                                          builder: (context) {
                                            return SafeArea(
                                              child: Padding(
                                                padding: const EdgeInsets.all(
                                                  24,
                                                ),
                                                child: YtPreviewPlayer(
                                                  results: _songs,
                                                  currentIndex: index,
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
                                            horizontal: 12,
                                            vertical: 4,
                                          ),
                                      leading: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (_isSelectionMode)
                                            Checkbox(
                                              value: isSelected,
                                              onChanged: (checked) {
                                                setState(() {
                                                  if (videoId == null) return;
                                                  final key = 'song-$videoId';
                                                  if (checked == true) {
                                                    _selectedIndexes.add(key);
                                                  } else {
                                                    _selectedIndexes.remove(
                                                      key,
                                                    );
                                                    if (_selectedIndexes
                                                        .isEmpty) {
                                                      _isSelectionMode = false;
                                                    }
                                                  }
                                                });
                                              },
                                            ),
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            child: _buildSafeNetworkImage(
                                              item.thumbUrl,
                                              width: 56,
                                              height: 56,
                                              fit: BoxFit.cover,
                                              fallback: Container(
                                                width: 56,
                                                height: 56,
                                                decoration: BoxDecoration(
                                                  color: isSystem
                                                      ? Theme.of(context)
                                                            .colorScheme
                                                            .secondaryContainer
                                                      : Theme.of(context)
                                                            .colorScheme
                                                            .surfaceContainer,
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                ),
                                                child: Icon(
                                                  Icons.music_note,
                                                  size: 32,
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
                                        item.title ?? 'Título desconocido',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleMedium,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      subtitle: Text(
                                        item.artist ?? 'Artista desconocido',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      trailing: IconButton(
                                        icon: const Icon(Icons.link),
                                        tooltip: LocaleProvider.tr('copy_link'),
                                        onPressed: () {
                                          if (videoId != null) {
                                            Clipboard.setData(
                                              ClipboardData(
                                                text:
                                                    'https://music.youtube.com/watch?v=$videoId',
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
                        ],
                      ),
                    ] else if (_expandedCategory == 'album') ...[
                      // Vista de canciones del álbum seleccionado
                      const SizedBox(height: 24),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
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
                                    color: isDark
                                        ? Theme.of(context)
                                              .colorScheme
                                              .onSecondary
                                              .withValues(alpha: 0.5)
                                        : Theme.of(context)
                                              .colorScheme
                                              .secondaryContainer
                                              .withValues(alpha: 0.5),
                                  ),
                                  child: const Icon(Icons.arrow_back, size: 24),
                                ),
                                tooltip: 'Volver',
                                onPressed: () {
                                  setState(() {
                                    _expandedCategory = null;
                                    _albumSongs = [];
                                    _currentAlbum = null;
                                    _resetScroll();
                                  });
                                },
                              ),
                              const SizedBox(width: 8),
                              if (_currentAlbum != null) ...[
                                if (_currentAlbum!['thumbUrl'] != null)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 12),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: Image.network(
                                        _currentAlbum!['thumbUrl'],
                                        width: 40,
                                        height: 40,
                                        fit: BoxFit.cover,
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
                                      final scaffoldMessenger =
                                          ScaffoldMessenger.of(context);
                                      final downloadQueue = DownloadQueue();
                                      for (final song in _albumSongs) {
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
                                      if (!mounted) return;
                                      scaffoldMessenger.showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            '${_albumSongs.length} ${LocaleProvider.tr('songs_added_to_queue')}',
                                          ),
                                        ),
                                      );
                                    }
                                  },
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 16),
                          if (_loadingAlbumSongs)
                            const Center(child: CircularProgressIndicator())
                          else if (_albumSongs.isEmpty)
                            const Center(
                              child: Text('No se encontraron canciones'),
                            )
                          else
                            ListView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              addAutomaticKeepAlives: false,
                              addRepaintBoundaries: true,
                              itemCount: _albumSongs.length,
                              itemBuilder: (context, index) {
                                final item = _albumSongs[index];
                                final videoId = item.videoId;
                                final isSelected =
                                    videoId != null &&
                                    _selectedIndexes.contains('album-$videoId');

                                final cardColor = isDark
                                    ? Theme.of(context).colorScheme.onSecondary
                                          .withValues(alpha: 0.5)
                                    : Theme.of(context)
                                          .colorScheme
                                          .secondaryContainer
                                          .withValues(alpha: 0.5);

                                final bool isFirst = index == 0;
                                final bool isLast =
                                    index == _albumSongs.length - 1;
                                final bool isOnly = _albumSongs.length == 1;

                                BorderRadius borderRadius;
                                if (isOnly) {
                                  borderRadius = BorderRadius.circular(16);
                                } else if (isFirst) {
                                  borderRadius = const BorderRadius.only(
                                    topLeft: Radius.circular(16),
                                    topRight: Radius.circular(16),
                                    bottomLeft: Radius.circular(4),
                                    bottomRight: Radius.circular(4),
                                  );
                                } else if (isLast) {
                                  borderRadius = const BorderRadius.only(
                                    topLeft: Radius.circular(4),
                                    topRight: Radius.circular(4),
                                    bottomLeft: Radius.circular(16),
                                    bottomRight: Radius.circular(16),
                                  );
                                } else {
                                  borderRadius = BorderRadius.circular(4);
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
                                        if (videoId == null) return;
                                        HapticFeedback.selectionClick();
                                        _toggleSelection(
                                          index,
                                          isVideo: false,
                                          isAlbum: true,
                                        );
                                      },
                                      onTap: () {
                                        if (_isSelectionMode) {
                                          if (videoId == null) return;
                                          _toggleSelection(
                                            index,
                                            isVideo: false,
                                            isAlbum: true,
                                          );
                                        } else {
                                          // Mostrar preview de la canción del álbum
                                          showModalBottomSheet(
                                            context: context,
                                            shape: const RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.vertical(
                                                    top: Radius.circular(16),
                                                  ),
                                            ),
                                            builder: (context) {
                                              return SafeArea(
                                                child: Padding(
                                                  padding: const EdgeInsets.all(
                                                    24,
                                                  ),
                                                  child: YtPreviewPlayer(
                                                    results: _albumSongs,
                                                    currentIndex: index,
                                                    fallbackThumbUrl:
                                                        _currentAlbum?['thumbUrl'],
                                                    fallbackArtist:
                                                        _currentAlbum?['artist'],
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
                                              horizontal: 12,
                                              vertical: 4,
                                            ),
                                        leading: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (_isSelectionMode)
                                              Checkbox(
                                                value: isSelected,
                                                onChanged: (checked) {
                                                  setState(() {
                                                    if (videoId == null) {
                                                      return;
                                                    }
                                                    final key =
                                                        'album-$videoId';
                                                    if (checked == true) {
                                                      _selectedIndexes.add(key);
                                                    } else {
                                                      _selectedIndexes.remove(
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
                                                  BorderRadius.circular(8),
                                              child:
                                                  (item.thumbUrl != null &&
                                                      item.thumbUrl!.isNotEmpty)
                                                  ? _buildSafeNetworkImage(
                                                      item.thumbUrl!,
                                                      width: 56,
                                                      height: 56,
                                                      fit: BoxFit.cover,
                                                    )
                                                  : (_currentAlbum?['thumbUrl'] !=
                                                        null)
                                                  ? _buildSafeNetworkImage(
                                                      _currentAlbum!['thumbUrl'],
                                                      width: 56,
                                                      height: 56,
                                                      fit: BoxFit.cover,
                                                    )
                                                  : Container(
                                                      width: 56,
                                                      height: 56,
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
                                                              12,
                                                            ),
                                                      ),
                                                      child: Icon(
                                                        Icons.music_note,
                                                        size: 32,
                                                        color: Theme.of(
                                                          context,
                                                        ).colorScheme.onSurface,
                                                      ),
                                                    ),
                                            ),
                                          ],
                                        ),
                                        title: Text(
                                          item.title ?? 'Título desconocido',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleMedium,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        subtitle: Text(
                                          (item.artist != null &&
                                                  item.artist!.isNotEmpty)
                                              ? item.artist!
                                              : (_currentAlbum?['artist'] !=
                                                    null)
                                              ? _currentAlbum!['artist']
                                              : 'Artista desconocido',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        trailing: IconButton(
                                          icon: const Icon(Icons.link),
                                          tooltip: LocaleProvider.tr(
                                            'copy_link',
                                          ),
                                          onPressed: () {
                                            if (videoId != null) {
                                              Clipboard.setData(
                                                ClipboardData(
                                                  text:
                                                      'https://music.youtube.com/watch?v=$videoId',
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
                        ],
                      ),
                    ] else if (_expandedCategory == 'videos') ...[
                      // Vista de solo videos con botón de volver
                      const SizedBox(height: 24),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
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
                                    color: isDark
                                        ? Theme.of(context)
                                              .colorScheme
                                              .onSecondary
                                              .withValues(alpha: 0.5)
                                        : Theme.of(context)
                                              .colorScheme
                                              .secondaryContainer
                                              .withValues(alpha: 0.5),
                                  ),
                                  child: const Icon(Icons.arrow_back, size: 24),
                                ),
                                tooltip: 'Volver',
                                onPressed: () {
                                  setState(() {
                                    _expandedCategory = null;
                                    _resetScroll();
                                  });
                                },
                              ),
                              const SizedBox(width: 8),
                              Text(
                                LocaleProvider.tr('videos'),
                                style: Theme.of(
                                  context,
                                ).textTheme.titleMedium?.copyWith(fontSize: 20),
                              ),
                            ],
                          ),
                          ListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            addAutomaticKeepAlives: false,
                            addRepaintBoundaries: true,
                            itemCount:
                                _videos.length + (_loadingMoreVideos ? 1 : 0),
                            itemBuilder: (context, index) {
                              // Mostrar indicador de carga al final
                              if (_loadingMoreVideos &&
                                  index == _videos.length) {
                                return Container(
                                  padding: const EdgeInsets.all(16),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      TranslatedText(
                                        'loading_more',
                                        style: const TextStyle(fontSize: 14),
                                      ),
                                    ],
                                  ),
                                );
                              }

                              final item = _videos[index];
                              final videoId = item.videoId;
                              final isSelected =
                                  videoId != null &&
                                  _selectedIndexes.contains('video-$videoId');

                              final cardColor = isDark
                                  ? Theme.of(context).colorScheme.onSecondary
                                        .withValues(alpha: 0.5)
                                  : Theme.of(context)
                                        .colorScheme
                                        .secondaryContainer
                                        .withValues(alpha: 0.5);

                              final bool isFirst = index == 0;
                              final bool isLast = index == _videos.length - 1;
                              final bool isOnly =
                                  _videos.length == 1 && !_loadingMoreVideos;

                              BorderRadius borderRadius;
                              if (isOnly) {
                                borderRadius = BorderRadius.circular(16);
                              } else if (isFirst) {
                                borderRadius = const BorderRadius.only(
                                  topLeft: Radius.circular(16),
                                  topRight: Radius.circular(16),
                                  bottomLeft: Radius.circular(4),
                                  bottomRight: Radius.circular(4),
                                );
                              } else if (isLast && !_loadingMoreVideos) {
                                borderRadius = const BorderRadius.only(
                                  topLeft: Radius.circular(4),
                                  topRight: Radius.circular(4),
                                  bottomLeft: Radius.circular(16),
                                  bottomRight: Radius.circular(16),
                                );
                              } else {
                                borderRadius = BorderRadius.circular(4);
                              }

                              return Padding(
                                padding: EdgeInsets.only(
                                  bottom: isLast && !_loadingMoreVideos ? 0 : 4,
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
                                      _toggleSelection(index, isVideo: true);
                                    },
                                    onTap: () {
                                      if (_isSelectionMode) {
                                        _toggleSelection(index, isVideo: true);
                                      } else {
                                        // Mostrar preview del video
                                        showModalBottomSheet(
                                          context: context,
                                          shape: const RoundedRectangleBorder(
                                            borderRadius: BorderRadius.vertical(
                                              top: Radius.circular(16),
                                            ),
                                          ),
                                          builder: (context) {
                                            return SafeArea(
                                              child: Padding(
                                                padding: const EdgeInsets.all(
                                                  24,
                                                ),
                                                child: YtPreviewPlayer(
                                                  results: _videos,
                                                  currentIndex: index,
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
                                            horizontal: 12,
                                            vertical: 4,
                                          ),
                                      leading: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (_isSelectionMode)
                                            Checkbox(
                                              value: isSelected,
                                              onChanged: (checked) {
                                                setState(() {
                                                  if (videoId == null) return;
                                                  final key = 'video-$videoId';
                                                  if (checked == true) {
                                                    _selectedIndexes.add(key);
                                                  } else {
                                                    _selectedIndexes.remove(
                                                      key,
                                                    );
                                                    if (_selectedIndexes
                                                        .isEmpty) {
                                                      _isSelectionMode = false;
                                                    }
                                                  }
                                                });
                                              },
                                            ),
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            child: _buildSafeNetworkImage(
                                              item.thumbUrl,
                                              width: 56,
                                              height: 56,
                                              fit: BoxFit.cover,
                                              fallback: Container(
                                                width: 56,
                                                height: 56,
                                                decoration: BoxDecoration(
                                                  color: isSystem
                                                      ? Theme.of(context)
                                                            .colorScheme
                                                            .secondaryContainer
                                                      : Theme.of(context)
                                                            .colorScheme
                                                            .surfaceContainer,
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                ),
                                                child: Icon(
                                                  Icons.music_note,
                                                  size: 32,
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
                                        item.title ?? 'Título desconocido',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleMedium,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      subtitle: Text(
                                        item.artist ?? 'Artista desconocido',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      trailing: IconButton(
                                        icon: const Icon(Icons.link),
                                        tooltip: LocaleProvider.tr('copy_link'),
                                        onPressed: () {
                                          if (videoId != null) {
                                            Clipboard.setData(
                                              ClipboardData(
                                                text:
                                                    'https://music.youtube.com/watch?v=$videoId',
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
                        ],
                      ),
                    ] else if (_expandedCategory == 'albums') ...[
                      // Vista de solo álbumes con botón de volver
                      const SizedBox(height: 24),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
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
                                    color: isDark
                                        ? Theme.of(context)
                                              .colorScheme
                                              .onSecondary
                                              .withValues(alpha: 0.5)
                                        : Theme.of(context)
                                              .colorScheme
                                              .secondaryContainer
                                              .withValues(alpha: 0.5),
                                  ),
                                  child: const Icon(Icons.arrow_back, size: 24),
                                ),
                                tooltip: 'Volver',
                                onPressed: () {
                                  setState(() {
                                    _expandedCategory = null;
                                    _resetScroll();
                                  });
                                },
                              ),
                              const SizedBox(width: 8),
                              Text(
                                LocaleProvider.tr('albums'),
                                style: Theme.of(
                                  context,
                                ).textTheme.titleMedium?.copyWith(fontSize: 20),
                              ),
                            ],
                          ),
                          ListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            addAutomaticKeepAlives: false,
                            addRepaintBoundaries: true,
                            itemCount: _albums.length,
                            itemBuilder: (context, index) {
                              final album = _albums[index];
                              final isSelected = _selectedIndexes.contains(
                                'album-$index',
                              );

                              final cardColor = isDark
                                  ? Theme.of(context).colorScheme.onSecondary
                                        .withValues(alpha: 0.5)
                                  : Theme.of(context)
                                        .colorScheme
                                        .secondaryContainer
                                        .withValues(alpha: 0.5);

                              final bool isFirst = index == 0;
                              final bool isLast = index == _albums.length - 1;
                              final bool isOnly = _albums.length == 1;

                              BorderRadius borderRadius;
                              if (isOnly) {
                                borderRadius = BorderRadius.circular(16);
                              } else if (isFirst) {
                                borderRadius = const BorderRadius.only(
                                  topLeft: Radius.circular(16),
                                  topRight: Radius.circular(16),
                                  bottomLeft: Radius.circular(4),
                                  bottomRight: Radius.circular(4),
                                );
                              } else if (isLast) {
                                borderRadius = const BorderRadius.only(
                                  topLeft: Radius.circular(4),
                                  topRight: Radius.circular(4),
                                  bottomLeft: Radius.circular(16),
                                  bottomRight: Radius.circular(16),
                                );
                              } else {
                                borderRadius = BorderRadius.circular(4);
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
                                        index,
                                        isVideo: false,
                                        isAlbum: true,
                                      );
                                    },
                                    onTap: () async {
                                      if (_isSelectionMode) {
                                        _toggleSelection(
                                          index,
                                          isVideo: false,
                                          isAlbum: true,
                                        );
                                      } else {
                                        // Cargar canciones del álbum
                                        if (album['browseId'] == null) {
                                          return;
                                        }
                                        setState(() {
                                          _expandedCategory = 'album';
                                          _loadingAlbumSongs = true;
                                          _albumSongs = [];
                                          _currentAlbum = {
                                            'title': album['title'],
                                            'artist': album['artist'],
                                            'thumbUrl': album['thumbUrl'],
                                          };
                                          _resetScroll();
                                        });
                                        final songs = await getAlbumSongs(
                                          album['browseId']!,
                                        );
                                        if (!mounted) return;
                                        setState(() {
                                          _albumSongs = songs;
                                          _loadingAlbumSongs = false;
                                        });
                                      }
                                    },
                                    child: ListTile(
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 4,
                                          ),
                                      leading: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (_isSelectionMode)
                                            Checkbox(
                                              value: isSelected,
                                              onChanged: (checked) {
                                                setState(() {
                                                  final key = 'album-$index';
                                                  if (checked == true) {
                                                    _selectedIndexes.add(key);
                                                  } else {
                                                    _selectedIndexes.remove(
                                                      key,
                                                    );
                                                    if (_selectedIndexes
                                                        .isEmpty) {
                                                      _isSelectionMode = false;
                                                    }
                                                  }
                                                });
                                              },
                                            ),
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            child: album['thumbUrl'] != null
                                                ? Image.network(
                                                    album['thumbUrl']!,
                                                    width: 56,
                                                    height: 56,
                                                    fit: BoxFit.cover,
                                                  )
                                                : Container(
                                                    width: 56,
                                                    height: 56,
                                                    decoration: BoxDecoration(
                                                      color: Colors.grey[300],
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            12,
                                                          ),
                                                    ),
                                                    child: const Icon(
                                                      Icons.album,
                                                      size: 32,
                                                      color: Colors.grey,
                                                    ),
                                                  ),
                                          ),
                                        ],
                                      ),
                                      title: Text(
                                        album['title'] ?? 'Álbum desconocido',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleMedium,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      subtitle: Text(
                                        'Álbum',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      trailing: IconButton(
                                        icon: const Icon(Icons.link),
                                        tooltip: LocaleProvider.tr('copy_link'),
                                        onPressed: () {
                                          if (album['browseId'] != null) {
                                            Clipboard.setData(
                                              ClipboardData(
                                                text:
                                                    'https://music.youtube.com/browse/${album['browseId']}',
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
                        ],
                      ),
                    ] else if (_songs.isNotEmpty ||
                        _videos.isNotEmpty ||
                        _albums.isNotEmpty) ...[
                      const SizedBox(height: 24),

                      // Sección Canciones
                      if (_songs.isNotEmpty)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () {
                                setState(() {
                                  _expandedCategory = 'songs';
                                  _resetScroll();
                                });
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 4,
                                ),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      LocaleProvider.tr('songs_search'),
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(fontSize: 20),
                                    ),
                                    Icon(Icons.chevron_right),
                                  ],
                                ),
                              ),
                            ),
                            Column(
                              children: [
                                ..._songs.take(3).map((item) {
                                  final index = _songs.indexOf(item);
                                  final videoId = item.videoId;
                                  final isSelected =
                                      videoId != null &&
                                      _selectedIndexes.contains(
                                        'song-$videoId',
                                      );

                                  final cardColor = isDark
                                      ? Theme.of(context)
                                            .colorScheme
                                            .onSecondary
                                            .withValues(alpha: 0.5)
                                      : Theme.of(context)
                                            .colorScheme
                                            .secondaryContainer
                                            .withValues(alpha: 0.5);

                                  final int totalToShow = _songs.length < 3
                                      ? _songs.length
                                      : 3;
                                  final bool isFirst = index == 0;
                                  final bool isLast = index == totalToShow - 1;
                                  final bool isOnly = totalToShow == 1;

                                  BorderRadius borderRadius;
                                  if (isOnly) {
                                    borderRadius = BorderRadius.circular(16);
                                  } else if (isFirst) {
                                    borderRadius = const BorderRadius.only(
                                      topLeft: Radius.circular(16),
                                      topRight: Radius.circular(16),
                                      bottomLeft: Radius.circular(4),
                                      bottomRight: Radius.circular(4),
                                    );
                                  } else if (isLast) {
                                    borderRadius = const BorderRadius.only(
                                      topLeft: Radius.circular(4),
                                      topRight: Radius.circular(4),
                                      bottomLeft: Radius.circular(16),
                                      bottomRight: Radius.circular(16),
                                    );
                                  } else {
                                    borderRadius = BorderRadius.circular(4);
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
                                            // Mostrar preview de la canción
                                            showModalBottomSheet(
                                              context: context,
                                              shape:
                                                  const RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.vertical(
                                                          top: Radius.circular(
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
                                                      results: _songs,
                                                      currentIndex: index,
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
                                                horizontal: 12,
                                                vertical: 4,
                                              ),
                                          leading: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              if (_isSelectionMode)
                                                Checkbox(
                                                  value: isSelected,
                                                  onChanged: (checked) {
                                                    setState(() {
                                                      if (videoId == null) {
                                                        return;
                                                      }
                                                      final key =
                                                          'song-$videoId';
                                                      if (checked == true) {
                                                        _selectedIndexes.add(
                                                          key,
                                                        );
                                                      } else {
                                                        _selectedIndexes.remove(
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
                                                    BorderRadius.circular(8),
                                                child: _buildSafeNetworkImage(
                                                  item.thumbUrl,
                                                  width: 56,
                                                  height: 56,
                                                  fit: BoxFit.cover,
                                                  fallback: Container(
                                                    width: 56,
                                                    height: 56,
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
                                                            12,
                                                          ),
                                                    ),
                                                    child: Icon(
                                                      Icons.music_note,
                                                      size: 32,
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
                                            item.title ?? 'Título desconocido',
                                            style: Theme.of(
                                              context,
                                            ).textTheme.titleMedium,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          subtitle: Text(
                                            item.artist ??
                                                'Artista desconocido',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          trailing: IconButton(
                                            icon: const Icon(Icons.link),
                                            tooltip: LocaleProvider.tr(
                                              'copy_link',
                                            ),
                                            onPressed: () {
                                              if (videoId != null) {
                                                Clipboard.setData(
                                                  ClipboardData(
                                                    text:
                                                        'https://music.youtube.com/watch?v=$videoId',
                                                  ),
                                                );
                                              }
                                            },
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                }),

                                // Indicador de carga automática en vista principal (estilo yt_screen)
                                if (_loadingMoreSongs) ...[
                                  Container(
                                    padding: const EdgeInsets.all(16),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        TranslatedText(
                                          'loading_more',
                                          style: const TextStyle(fontSize: 14),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),

                      // Sección Álbumes
                      if (_albums.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () {
                                setState(() {
                                  _expandedCategory = 'albums';
                                  _resetScroll();
                                });
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 4,
                                ),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      LocaleProvider.tr('albums'),
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(fontSize: 20),
                                    ),
                                    Icon(Icons.chevron_right),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              height:
                                  180, // Aumentar altura para evitar overflow
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: _albums.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(width: 12),
                                itemBuilder: (context, index) {
                                  final album = _albums[index];
                                  return AnimatedTapButton(
                                    onTap: () async {
                                      // Cargar canciones del álbum
                                      if (album['browseId'] == null) {
                                        return;
                                      }
                                      setState(() {
                                        _expandedCategory = 'album';
                                        _loadingAlbumSongs = true;
                                        _albumSongs = [];
                                        _currentAlbum = {
                                          'title': album['title'],
                                          'artist': album['artist'],
                                          'thumbUrl': album['thumbUrl'],
                                        };
                                        _resetScroll();
                                      });
                                      final songs = await getAlbumSongs(
                                        album['browseId']!,
                                      );
                                      if (!mounted) return;
                                      setState(() {
                                        _albumSongs = songs;
                                        _loadingAlbumSongs = false;
                                      });
                                    },
                                    child: SizedBox(
                                      width: 120,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          AspectRatio(
                                            aspectRatio: 1,
                                            child: ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              child: album['thumbUrl'] != null
                                                  ? Image.network(
                                                      album['thumbUrl']!,
                                                      fit: BoxFit.cover,
                                                    )
                                                  : Container(
                                                      color: isSystem
                                                          ? Theme.of(context)
                                                                .colorScheme
                                                                .secondaryContainer
                                                          : Theme.of(context)
                                                                .colorScheme
                                                                .surfaceContainer,
                                                      child: const Icon(
                                                        Icons.album,
                                                        size: 40,
                                                      ),
                                                    ),
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          Flexible(
                                            child: Text(
                                              album['title'] ?? '',
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(
                                                context,
                                              ).textTheme.titleMedium,
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

                      // Sección Videos
                      if (_videos.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () {
                                setState(() {
                                  _expandedCategory = 'videos';
                                  _resetScroll();
                                });
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 4,
                                ),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      LocaleProvider.tr('videos'),
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(fontSize: 20),
                                    ),
                                    Icon(Icons.chevron_right),
                                  ],
                                ),
                              ),
                            ),
                            Column(
                              children: [
                                ..._videos.take(3).map((item) {
                                  final index = _videos.indexOf(item);
                                  final videoId = item.videoId;
                                  final isSelected =
                                      videoId != null &&
                                      _selectedIndexes.contains(
                                        'video-$videoId',
                                      );

                                  final cardColor = isDark
                                      ? Theme.of(context)
                                            .colorScheme
                                            .onSecondary
                                            .withValues(alpha: 0.5)
                                      : Theme.of(context)
                                            .colorScheme
                                            .secondaryContainer
                                            .withValues(alpha: 0.5);

                                  final int totalToShow = _videos.length < 3
                                      ? _videos.length
                                      : 3;
                                  final bool isFirst = index == 0;
                                  final bool isLast = index == totalToShow - 1;
                                  final bool isOnly = totalToShow == 1;

                                  BorderRadius borderRadius;
                                  if (isOnly) {
                                    borderRadius = BorderRadius.circular(16);
                                  } else if (isFirst) {
                                    borderRadius = const BorderRadius.only(
                                      topLeft: Radius.circular(16),
                                      topRight: Radius.circular(16),
                                      bottomLeft: Radius.circular(4),
                                      bottomRight: Radius.circular(4),
                                    );
                                  } else if (isLast) {
                                    borderRadius = const BorderRadius.only(
                                      topLeft: Radius.circular(4),
                                      topRight: Radius.circular(4),
                                      bottomLeft: Radius.circular(16),
                                      bottomRight: Radius.circular(16),
                                    );
                                  } else {
                                    borderRadius = BorderRadius.circular(4);
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
                                            // Mostrar preview del video
                                            showModalBottomSheet(
                                              context: context,
                                              shape:
                                                  const RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.vertical(
                                                          top: Radius.circular(
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
                                                      results: _videos,
                                                      currentIndex: index,
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
                                                horizontal: 12,
                                                vertical: 4,
                                              ),
                                          leading: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              if (_isSelectionMode)
                                                Checkbox(
                                                  value: isSelected,
                                                  onChanged: (checked) {
                                                    setState(() {
                                                      if (videoId == null) {
                                                        return;
                                                      }
                                                      final key =
                                                          'video-$videoId';
                                                      if (checked == true) {
                                                        _selectedIndexes.add(
                                                          key,
                                                        );
                                                      } else {
                                                        _selectedIndexes.remove(
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
                                                    BorderRadius.circular(8),
                                                child: _buildSafeNetworkImage(
                                                  item.thumbUrl,
                                                  width: 56,
                                                  height: 56,
                                                  fit: BoxFit.cover,
                                                  fallback: Container(
                                                    width: 56,
                                                    height: 56,
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
                                                            12,
                                                          ),
                                                    ),
                                                    child: Icon(
                                                      Icons.music_note,
                                                      size: 32,
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
                                            item.title ?? 'Título desconocido',
                                            style: Theme.of(
                                              context,
                                            ).textTheme.titleMedium,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          subtitle: Text(
                                            item.artist ??
                                                'Artista desconocido',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          trailing: IconButton(
                                            icon: const Icon(Icons.link),
                                            tooltip: LocaleProvider.tr(
                                              'copy_link',
                                            ),
                                            onPressed: () {
                                              if (videoId != null) {
                                                Clipboard.setData(
                                                  ClipboardData(
                                                    text:
                                                        'https://music.youtube.com/watch?v=$videoId',
                                                  ),
                                                );
                                              }
                                            },
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                }),

                                // Indicador de carga automática para videos en vista principal (estilo yt_screen)
                                if (_loadingMoreVideos) ...[
                                  Container(
                                    padding: const EdgeInsets.all(16),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        TranslatedText(
                                          'loading_more',
                                          style: const TextStyle(fontSize: 14),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ],
                    ],
                  ],
                ),
              ),
      ),
    );
  }

  // Función para mostrar opciones de búsqueda del artista
  Future<void> _showArtistSearchOptions(String artistName) async {
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
                  'search_artist',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
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
                        _searchArtistOnYouTube(artistName);
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: isAmoled && isDark
                              ? Colors.white.withValues(alpha: 0.1)
                              : Theme.of(
                                  context,
                                ).colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(16),
                            topRight: Radius.circular(16),
                            bottomLeft: Radius.circular(4),
                            bottomRight: Radius.circular(4),
                          ),
                          border: Border.all(
                            color: isAmoled && isDark
                                ? Colors.white.withValues(alpha: 0.2)
                                : Theme.of(
                                    context,
                                  ).colorScheme.outline.withValues(alpha: 0.1),
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
                                      ? Colors.white
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
                        _searchArtistOnYouTubeMusic(artistName);
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: isAmoled && isDark
                              ? Colors.white.withValues(alpha: 0.1)
                              : Theme.of(
                                  context,
                                ).colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(4),
                            topRight: Radius.circular(4),
                            bottomLeft: Radius.circular(16),
                            bottomRight: Radius.circular(16),
                          ),
                          border: Border.all(
                            color: isAmoled && isDark
                                ? Colors.white.withValues(alpha: 0.2)
                                : Theme.of(
                                    context,
                                  ).colorScheme.outline.withValues(alpha: 0.1),
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
      },
    );
  }

  // Función para descargar elementos seleccionados
  Future<void> _downloadSelectedItems() async {
    if (_selectedIndexes.isEmpty) return;

    // Obtener la carpeta de descarga
    final prefs = await SharedPreferences.getInstance();
    final downloadPath =
        prefs.getString('download_directory') ?? '/storage/emulated/0/Music';

    // Guardar el directorio por defecto si no existe
    if (!prefs.containsKey('download_directory')) {
      await prefs.setString('download_directory', '/storage/emulated/0/Music');
    }

    if (downloadPath.isEmpty) {
      _showMessage('Error', 'No se ha seleccionado una carpeta de descarga');
      return;
    }

    // Obtener elementos seleccionados
    final List<YtMusicResult> itemsToDownload = [];

    for (final key in _selectedIndexes) {
      if (key.startsWith('song-')) {
        final videoId = key.substring(5);
        final song = _songs.firstWhere((s) => s.videoId == videoId);
        itemsToDownload.add(song);
      } else if (key.startsWith('video-')) {
        final videoId = key.substring(6);
        final video = _videos.firstWhere((v) => v.videoId == videoId);
        itemsToDownload.add(video);
      } else if (key.startsWith('album-')) {
        // Para álbumes, descargar todas las canciones del álbum
        final albumIndex = int.parse(key.substring(6));
        if (albumIndex < _albums.length) {
          // Aquí necesitarías cargar las canciones del álbum
          // Por ahora, solo mostramos un mensaje
          _showMessage(
            'Info',
            'La descarga de álbumes completos no está implementada aún',
          );
          continue;
        }
      }
    }

    if (itemsToDownload.isEmpty) {
      _showMessage('Error', 'No hay elementos válidos para descargar');
      return;
    }

    // Descargar cada elemento
    for (int i = 0; i < itemsToDownload.length; i++) {
      final item = itemsToDownload[i];
      final notificationId = i + 1;

      try {
        // Configurar el throttler de notificaciones
        DownloadNotificationThrottler().setTitle(
          item.title ?? 'Canción desconocida',
        );

        // Descargar usando el servicio global
        if (!mounted) return;
        await SimpleYtDownload.downloadVideoWithArtist(
          context,
          item.videoId ?? '',
          item.title ?? 'Canción desconocida',
          item.artist ?? 'Artista desconocido',
        );
      } catch (e) {
        showDownloadFailedNotification(
          item.title ?? 'Canción desconocida',
          notificationId,
        );
      }
    }

    // Limpiar selección
    setState(() {
      _selectedIndexes.clear();
      _isSelectionMode = false;
    });

    _showMessage(
      LocaleProvider.tr('success'),
      LocaleProvider.tr(
        'download_started_for_elements',
      ).replaceAll('@count', itemsToDownload.length.toString()),
    );
  }

  // Función para mostrar mensajes
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

  // Función para buscar el artista en YouTube
  Future<void> _searchArtistOnYouTube(String artistName) async {
    try {
      // Codificar la consulta para la URL
      final encodedQuery = Uri.encodeComponent(artistName);
      final youtubeSearchUrl =
          'https://www.youtube.com/results?search_query=$encodedQuery';

      // Intentar abrir YouTube en el navegador o en la app
      final url = Uri.parse(youtubeSearchUrl);

      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      // ignore: avoid_print
      print('Error al abrir YouTube: $e');
    }
  }

  // Función para buscar el artista en YouTube Music
  Future<void> _searchArtistOnYouTubeMusic(String artistName) async {
    try {
      // Codificar la consulta para la URL
      final encodedQuery = Uri.encodeComponent(artistName);

      // URL correcta para búsqueda en YouTube Music
      final ytMusicSearchUrl =
          'https://music.youtube.com/search?q=$encodedQuery';

      // Intentar abrir YouTube Music en el navegador o en la app
      final url = Uri.parse(ytMusicSearchUrl);

      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      // ignore: avoid_print
      print('Error al abrir YouTube Music: $e');
    }
  }
}
