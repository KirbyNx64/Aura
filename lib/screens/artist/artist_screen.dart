import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:music/main.dart'
    show
        audioHandler,
        audioServiceReady,
        initializeAudioServiceSafely,
        overlayVisibleNotifier;
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/yt_search/service.dart';
import 'package:music/utils/db/artist_images_cache_db.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/notification_service.dart';
import 'package:music/utils/simple_yt_download.dart';
import 'package:music/utils/yt_search/stream_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:music/widgets/animated_tap_button.dart';
import 'package:music/widgets/now_playing_overlay.dart';
import 'package:music/utils/db/favorites_db.dart';
import 'package:music/utils/db/playlists_db.dart';
import 'package:music/utils/song_info_dialog.dart';
import 'package:music/screens/play/player_screen.dart' as player_screen;
import 'package:music/widgets/sliding_up_panel/sliding_up_panel_overlay.dart'
    as overlay_panel;
import 'package:material_loading_indicator/loading_indicator.dart';
import 'package:share_plus/share_plus.dart';

class ArtistScreen extends StatefulWidget {
  final String artistName;
  final String? browseId;
  const ArtistScreen({super.key, required this.artistName, this.browseId});

  static int _activeInstances = 0;
  static bool get hasActiveInstance => _activeInstances > 0;

  @override
  State<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends State<ArtistScreen> {
  bool _loading = true;
  Map<String, dynamic>? _artist;
  bool _descExpanded = false;
  String? _expandedCategory; // 'songs', 'videos', 'albums', o null
  String? _previousCategory; // Para volver a la vista anterior
  List<YtMusicResult> _songs = [];
  List<YtMusicResult> _videos = [];
  List<Map<String, String>> _albums = [];
  List<Map<String, String>> _singles = [];

  // Estado para álbum seleccionado
  List<YtMusicResult> _albumSongs = [];
  Map<String, dynamic>? _currentAlbum;
  bool _loadingAlbumSongs = false;
  bool _loadingContent = false;

  // Estado para selección múltiple
  final Set<String> _selectedIndexes = {};
  bool _isSelectionMode = false;

  // Estado para paginación de canciones
  String? _songsContinuationToken;
  bool _loadingMoreSongs = false;
  bool _hasMoreSongs = true;
  Map<String, dynamic>? _songsBrowseEndpoint; // Para usar en continuación

  // Estado para paginación de videos
  String? _videosContinuationToken;
  bool _loadingMoreVideos = false;
  bool _hasMoreVideos = true;

  // ScrollController para detectar el final del scroll
  late ScrollController _scrollController;
  final overlay_panel.PanelController _overlayPanelController =
      overlay_panel.PanelController();
  final ValueNotifier<double> _panelPositionNotifier = ValueNotifier(0.0);
  bool _playlistOpen = false;
  Widget? _playerScreenWidget;

  @override
  void initState() {
    super.initState();
    ArtistScreen._activeInstances++;
    _scrollController = ScrollController();
    _scrollController.addListener(_onScroll);
    openPlayerPanelNotifier.addListener(_onOpenPlayerPanelRequested);
    _load();
  }

  @override
  void dispose() {
    if (ArtistScreen._activeInstances > 0) {
      ArtistScreen._activeInstances--;
    }
    openPlayerPanelNotifier.removeListener(_onOpenPlayerPanelRequested);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _panelPositionNotifier.dispose();
    super.dispose();
  }

  void _onOpenPlayerPanelRequested() {
    if (openPlayerPanelNotifier.value &&
        _overlayPanelController.isAttached &&
        overlayVisibleNotifier.value) {
      _overlayPanelController.open();
      openPlayerPanelNotifier.value = false;
    }
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
    if (text.toLowerCase().contains('audiencia mensual')) {
      return '${LocaleProvider.tr('monthly_audience_label')} ${cleanNumber(text, 'audiencia mensual')}';
    }
    if (text.toLowerCase().contains('monthly listeners')) {
      return '${LocaleProvider.tr('monthly_audience_label')} ${cleanNumber(text, 'monthly listeners')}';
    }

    if (text.toLowerCase().contains('subscribers')) {
      return '${cleanNumber(text, 'subscribers')} ${LocaleProvider.tr('subscribers_label')}';
    }
    if (text.toLowerCase().contains('suscriptores')) {
      return '${cleanNumber(text, 'suscriptores')} ${LocaleProvider.tr('subscribers_label')}';
    }

    return text;
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

  String _formatYtArtistWithDuration(
    YtMusicResult item, {
    String? fallbackArtist,
  }) {
    final artist = item.artist?.trim().isNotEmpty == true
        ? item.artist!.trim()
        : (fallbackArtist?.trim().isNotEmpty == true
              ? fallbackArtist!.trim()
              : LocaleProvider.tr('artist_unknown'));

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

  int? _parseYtDurationTextMs(String? text) {
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

  String? _extractYtDurationTextFromRenderer(dynamic renderer) {
    if (renderer is! Map) return null;
    const pattern = r'^(\d+:)*\d+:\d+$';

    final candidates = <dynamic>[
      nav(renderer, [
        'fixedColumns',
        0,
        'musicResponsiveListItemFixedColumnRenderer',
        'text',
        'simpleText',
      ]),
      nav(renderer, [
        'fixedColumns',
        0,
        'musicResponsiveListItemFixedColumnRenderer',
        'text',
        'runs',
        0,
        'text',
      ]),
      nav(renderer, ['lengthText', 'simpleText']),
      nav(renderer, ['lengthText', 'runs', 0, 'text']),
    ];

    for (final candidate in candidates) {
      final text = candidate?.toString().trim();
      if (text != null && text.isNotEmpty && RegExp(pattern).hasMatch(text)) {
        return text;
      }
    }

    final subtitleRuns = nav(renderer, [
      'flexColumns',
      1,
      'musicResponsiveListItemFlexColumnRenderer',
      'text',
      'runs',
    ]);
    if (subtitleRuns is List) {
      for (final run in subtitleRuns) {
        if (run is! Map) continue;
        final text = run['text']?.toString().trim();
        if (text != null && text.isNotEmpty && RegExp(pattern).hasMatch(text)) {
          return text;
        }
      }
    }

    return null;
  }

  // Función helper para manejar imágenes de red de forma segura
  Widget _buildSafeNetworkImage(
    String? imageUrl, {
    double? width,
    double? height,
    BoxFit? fit,
    Widget? fallback,
    Alignment alignment = Alignment.center,
  }) {
    if (imageUrl == null || imageUrl.isEmpty) {
      return fallback ??
          const Icon(Icons.music_note, size: 32, color: Colors.transparent);
    }

    return CachedNetworkImage(
      imageUrl: imageUrl,
      width: width,
      height: height,
      fit: fit ?? BoxFit.cover,
      alignment: alignment,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      errorWidget: (context, url, error) {
        // Manejar errores de imagen de forma silenciosa
        return fallback ??
            const Icon(Icons.music_note, size: 32, color: Colors.transparent);
      },
      placeholder: (context, url) {
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
          if (mounted) {
            setState(() {
              _artist = detailed;
              _loading = false;
              _loadingContent = true;
            });
            // Cargar contenido del artista
            _loadArtistContent(detailed);
          }
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
              'thumbUrl': detailed['thumbUrl'] ?? info['thumbUrl'],
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
                'thumbUrl': detailed['thumbUrl'] ?? info['thumbUrl'],
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
                'thumbUrl': detailed['thumbUrl'] ?? info['thumbUrl'],
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
        if (result != null) {
          _loadingContent = true;
        }
      });

      // Cargar contenido del artista simulando búsqueda como yt_screen
      if (result != null) {
        _loadArtistContent(result);
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
      final String? browseId = artistInfo['browseId'];

      // Si tenemos browseId, usar getArtistSongs (ahora con paginación)
      // sino, usar búsqueda general como fallback
      final songFuture = (browseId != null && browseId.isNotEmpty)
          ? getArtistSongs(browseId, initialLimit: 20)
          : _loadSongsWithPagination(widget.artistName);

      final videoFuture = _loadVideosWithPagination(widget.artistName);
      final albumFuture = searchAlbumsOnly(widget.artistName);
      final singlesFuture = (browseId != null && browseId.isNotEmpty)
          ? getArtistSingles(browseId)
          : Future.value({
              'results': <Map<String, String>>[],
              'continuationToken': null,
              'browseEndpoint': null,
            });

      final searchResults = await Future.wait([
        songFuture,
        videoFuture,
        albumFuture,
        singlesFuture,
      ]);

      if (mounted) {
        final videosData = searchResults[1] as Map<String, dynamic>;
        final allAlbums = (searchResults[2] as List)
            .cast<Map<String, String>>();

        setState(() {
          // getArtistSongs ahora devuelve un Map con paginación
          final songsData = searchResults[0] as Map<String, dynamic>;
          final singlesData = searchResults[3] as Map<String, dynamic>;

          // Si viene de getArtistSongs (con browseId)
          if (songsData.containsKey('browseEndpoint')) {
            _songs = songsData['results'] as List<YtMusicResult>;
            _songsContinuationToken = songsData['continuationToken'] as String?;
            _songsBrowseEndpoint =
                songsData['browseEndpoint'] as Map<String, dynamic>?;
            _hasMoreSongs = _songsContinuationToken != null;
          } else {
            // Si usamos búsqueda general
            _songs = _filterSongsByArtist(
              songsData['songs'] as List<YtMusicResult>,
              widget.artistName,
            );
            _songsContinuationToken = songsData['continuationToken'] as String?;
            _songsBrowseEndpoint = null;
            _hasMoreSongs = _songsContinuationToken != null;
          }

          // Videos
          _videos = videosData['videos'] as List<YtMusicResult>;
          _videosContinuationToken = videosData['continuationToken'] as String?;
          _hasMoreVideos = _videosContinuationToken != null;

          _albums = allAlbums;
          _singles = singlesData['results'] as List<Map<String, String>>;
          _loadingContent = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingContent = false;
        });
      }
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
          ? 'album-${_albumSongs[index].videoId}'
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

  void _clearSelection() {
    setState(() {
      _selectedIndexes.clear();
      _isSelectionMode = false;
    });
  }

  // Métodos para pop interno desde el home
  bool canPopInternally() {
    return _expandedCategory != null;
  }

  void handleInternalPop() {
    setState(() {
      if (_expandedCategory == 'album' && _previousCategory != null) {
        _expandedCategory = _previousCategory;
        _previousCategory = null;
      } else {
        _expandedCategory = null;
        _previousCategory = null;
      }
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
                final durationText = _extractYtDurationTextFromRenderer(
                  renderer,
                );
                final durationMs = _parseYtDurationTextMs(durationText);
                if (videoId != null && title != null) {
                  results.add(
                    YtMusicResult(
                      title: title,
                      artist: artist,
                      thumbUrl: thumbUrl,
                      videoId: videoId,
                      durationText: durationText,
                      durationMs: durationMs,
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
                  final durationText = _extractYtDurationTextFromRenderer(
                    renderer,
                  );
                  final durationMs = _parseYtDurationTextMs(durationText);
                  if (videoId != null && title != null) {
                    results.add(
                      YtMusicResult(
                        title: title,
                        artist: artist,
                        thumbUrl: thumbUrl,
                        videoId: videoId,
                        durationText: durationText,
                        durationMs: durationMs,
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
      Map<String, dynamic> songsData;

      // Si tenemos browseEndpoint, usar getArtistSongsContinuation
      if (_songsBrowseEndpoint != null) {
        songsData = await getArtistSongsContinuation(
          browseEndpoint: _songsBrowseEndpoint!,
          continuationToken: _songsContinuationToken!,
          limit: 20,
        );
      } else {
        // Usar búsqueda general
        songsData = await _loadSongsWithPagination(
          widget.artistName,
          continuationToken: _songsContinuationToken,
        );
      }

      if (mounted) {
        // getArtistSongsContinuation devuelve 'results', búsqueda general devuelve 'songs'
        final newSongs =
            (songsData.containsKey('results')
                    ? songsData['results']
                    : songsData['songs'])
                as List<YtMusicResult>;

        // Solo filtrar si usamos búsqueda general
        final songsToAdd = _songsBrowseEndpoint != null
            ? newSongs
            : _filterSongsByArtist(newSongs, widget.artistName);

        setState(() {
          _songs.addAll(songsToAdd);
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

  String _cleanDescription(String text) {
    if (text.isEmpty) return text;

    // Patrones para detectar y eliminar la atribución de fuente al final
    final patterns = [
      RegExp(
        r'\s*(?:Fuente|Source|Data from):\s+Wikipedia.*$',
        caseSensitive: false,
        dotAll: true,
      ),
      RegExp(
        r'\s*Description summary from Wikipedia.*$',
        caseSensitive: false,
        dotAll: true,
      ),
      RegExp(
        r'\n?\s*https?://[a-zA-Z]{2}\.wikipedia\.org\S*',
        caseSensitive: false,
      ),
    ];

    String cleaned = text;
    for (var pattern in patterns) {
      cleaned = cleaned.replaceFirst(pattern, '');
    }

    return cleaned.trim();
  }

  Future<void> _playStreamingFromList({
    required List<YtMusicResult> results,
    required int tappedIndex,
    required String queueSource,
    bool playAsQueue = false,
  }) async {
    if (tappedIndex < 0 || tappedIndex >= results.length) return;
    final targetVideoId = results[tappedIndex].videoId?.trim();
    if (targetVideoId == null || targetVideoId.isEmpty) return;
    if (playLoadingNotifier.value) return;

    playLoadingNotifier.value = true;
    if (!overlayVisibleNotifier.value) {
      overlayVisibleNotifier.value = true;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_overlayPanelController.isAttached) {
        _overlayPanelController.open();
      }
    });
    var loadingReleased = false;
    StreamSubscription<PlaybackState>? playbackWatchSub;
    Timer? loadingGuard;
    void releaseLoading() {
      if (loadingReleased) return;
      loadingReleased = true;
      playLoadingNotifier.value = false;
      loadingGuard?.cancel();
      loadingGuard = null;
      playbackWatchSub?.cancel();
      playbackWatchSub = null;
    }

    loadingGuard = Timer(const Duration(seconds: 8), releaseLoading);

    try {
      if (!audioServiceReady.value || audioHandler == null) {
        await initializeAudioServiceSafely();
      }
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

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_queue_source', queueSource);

      if (playAsQueue) {
        final queueItems = results
            .where((entry) => (entry.videoId?.trim().isNotEmpty ?? false))
            .toList();
        final selectedQueueIndex = queueItems.indexWhere(
          (entry) => entry.videoId?.trim() == targetVideoId,
        );
        final queuePayload = queueItems.map((entry) {
          final id = entry.videoId?.trim() ?? '';
          return <String, dynamic>{
            'videoId': id,
            'title': entry.title?.trim().isNotEmpty == true
                ? entry.title!.trim()
                : LocaleProvider.tr('title_unknown'),
            'artist': entry.artist?.trim().isNotEmpty == true
                ? entry.artist!.trim()
                : LocaleProvider.tr('artist_unknown'),
            'artUri': entry.thumbUrl?.trim().isNotEmpty == true
                ? entry.thumbUrl!.trim()
                : 'https://i.ytimg.com/vi/$id/hqdefault.jpg',
          };
        }).toList();
        await handler
            .customAction('playYtStreamQueue', {
              'items': queuePayload,
              'initialIndex': selectedQueueIndex >= 0 ? selectedQueueIndex : 0,
              'autoPlay': true,
            })
            .timeout(const Duration(seconds: 20));
      } else {
        final selected = results[tappedIndex];
        final streamUrl = await StreamService.getBestAudioUrl(
          targetVideoId,
          reportError: true,
        ).timeout(const Duration(seconds: 6));
        if (streamUrl == null || streamUrl.isEmpty) return;
        final artUri = selected.thumbUrl?.trim().isNotEmpty == true
            ? selected.thumbUrl!.trim()
            : 'https://i.ytimg.com/vi/$targetVideoId/hqdefault.jpg';
        final title = selected.title?.trim().isNotEmpty == true
            ? selected.title!.trim()
            : LocaleProvider.tr('title_unknown');
        final artist = selected.artist?.trim().isNotEmpty == true
            ? selected.artist!.trim()
            : LocaleProvider.tr('artist_unknown');

        await handler
            .customAction('playYtStream', {
              'streamUrl': streamUrl,
              'videoId': targetVideoId,
              'mediaId': 'yt:$targetVideoId',
              'title': title,
              'artist': artist,
              'artUri': artUri,
              'radioMode': true,
              'autoPlay': true,
            })
            .timeout(const Duration(seconds: 20));
      }
    } catch (_) {
      // Ignorar para no mostrar error si inició correctamente entre transiciones.
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

  Widget _buildPlayTrailingButton({
    required List<YtMusicResult> results,
    required int tappedIndex,
    required String queueSource,
    bool playAsQueue = false,
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
        onPressed: () {
          _playStreamingFromList(
            results: results,
            tappedIndex: tappedIndex,
            queueSource: queueSource,
            playAsQueue: playAsQueue,
          );
        },
      ),
    );
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
    await SimpleYtDownload.downloadVideoWithArtist(
      context,
      videoId,
      item.title ?? LocaleProvider.tr('title_unknown'),
      item.artist ?? LocaleProvider.tr('artist_unknown'),
    );
  }

  Future<void> _addSongToFavorites(
    YtMusicResult item, {
    String? fallbackArtist,
    String? fallbackThumbUrl,
  }) async {
    final videoId = item.videoId?.trim();
    if (videoId == null || videoId.isEmpty) return;
    final title = item.title?.trim().isNotEmpty == true
        ? item.title!.trim()
        : LocaleProvider.tr('title_unknown');
    final artist = item.artist?.trim().isNotEmpty == true
        ? item.artist!.trim()
        : (fallbackArtist?.trim().isNotEmpty == true
              ? fallbackArtist!.trim()
              : LocaleProvider.tr('artist_unknown'));
    final artUri = item.thumbUrl?.trim().isNotEmpty == true
        ? item.thumbUrl!.trim()
        : (fallbackThumbUrl?.trim().isNotEmpty == true
              ? fallbackThumbUrl!.trim()
              : 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg');
    await FavoritesDB().addFavoritePath(
      'yt:$videoId',
      title: title,
      artist: artist,
      videoId: videoId,
      artUri: artUri,
      durationText: item.durationText,
      durationMs: item.durationMs,
    );
    favoritesShouldReload.value = !favoritesShouldReload.value;
  }

  Future<void> _showSongInfo(
    YtMusicResult item, {
    String? fallbackArtist,
    String? fallbackThumbUrl,
  }) async {
    final videoId = item.videoId?.trim();
    if (videoId == null || videoId.isEmpty) return;
    final durationText = item.durationText?.trim();
    final durationMs = item.durationMs ?? _parseYtDurationTextMs(durationText);
    final mediaItem = MediaItem(
      id: 'yt:$videoId',
      title: item.title?.trim().isNotEmpty == true
          ? item.title!.trim()
          : LocaleProvider.tr('title_unknown'),
      artist: item.artist?.trim().isNotEmpty == true
          ? item.artist!.trim()
          : (fallbackArtist?.trim().isNotEmpty == true
                ? fallbackArtist!.trim()
                : LocaleProvider.tr('artist_unknown')),
      duration: (durationMs != null && durationMs > 0)
          ? Duration(milliseconds: durationMs)
          : null,
      artUri: Uri.tryParse(
        item.thumbUrl?.trim().isNotEmpty == true
            ? item.thumbUrl!.trim()
            : (fallbackThumbUrl?.trim().isNotEmpty == true
                  ? fallbackThumbUrl!.trim()
                  : 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg'),
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

  Future<void> _showAddSongToPlaylistDialog(
    YtMusicResult item, {
    String? fallbackArtist,
    String? fallbackThumbUrl,
  }) async {
    final videoId = item.videoId?.trim();
    if (videoId == null || videoId.isEmpty) return;
    final allPlaylists = await PlaylistsDB().getAllPlaylists();
    final textController = TextEditingController();
    if (!mounted) return;

    final title = item.title?.trim().isNotEmpty == true
        ? item.title!.trim()
        : LocaleProvider.tr('title_unknown');
    final artist = item.artist?.trim().isNotEmpty == true
        ? item.artist!.trim()
        : (fallbackArtist?.trim().isNotEmpty == true
              ? fallbackArtist!.trim()
              : LocaleProvider.tr('artist_unknown'));
    final artUri = item.thumbUrl?.trim().isNotEmpty == true
        ? item.thumbUrl!.trim()
        : (fallbackThumbUrl?.trim().isNotEmpty == true
              ? fallbackThumbUrl!.trim()
              : 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg');
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
                                  title: Text(
                                    pl.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
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

  Future<void> _searchSongOnYouTube(
    YtMusicResult item, {
    String? fallbackArtist,
  }) async {
    final title = item.title?.trim() ?? '';
    if (title.isEmpty) return;
    final resolvedArtist = item.artist?.replaceFirst(RegExp(r' - Topic$'), '');
    final artist =
        (resolvedArtist?.trim().isNotEmpty == true
            ? resolvedArtist!.trim()
            : fallbackArtist?.trim()) ??
        '';
    var searchQuery = title;
    if (artist.isNotEmpty) {
      searchQuery = '$artist $title';
    }
    final encodedQuery = Uri.encodeComponent(searchQuery);
    final url = Uri.parse(
      'https://www.youtube.com/results?search_query=$encodedQuery',
    );
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  Future<void> _searchSongOnYouTubeMusic(
    YtMusicResult item, {
    String? fallbackArtist,
  }) async {
    final title = item.title?.trim() ?? '';
    if (title.isEmpty) return;
    final resolvedArtist = item.artist?.replaceFirst(RegExp(r' - Topic$'), '');
    final artist =
        (resolvedArtist?.trim().isNotEmpty == true
            ? resolvedArtist!.trim()
            : fallbackArtist?.trim()) ??
        '';
    var searchQuery = title;
    if (artist.isNotEmpty) {
      searchQuery = '$artist $title';
    }
    final encodedQuery = Uri.encodeComponent(searchQuery);
    final url = Uri.parse('https://music.youtube.com/search?q=$encodedQuery');
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  Future<void> _showSongSearchOptions(
    YtMusicResult item, {
    String? fallbackArtist,
  }) async {
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
                        _searchSongOnYouTube(
                          item,
                          fallbackArtist: fallbackArtist,
                        );
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
                        _searchSongOnYouTubeMusic(
                          item,
                          fallbackArtist: fallbackArtist,
                        );
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

  Future<void> _showSongActionsModal(
    YtMusicResult item, {
    required String selectionKey,
    String? fallbackArtist,
    String? fallbackThumbUrl,
  }) async {
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
    final videoUrl = videoId != null && videoId.isNotEmpty
        ? 'https://music.youtube.com/watch?v=$videoId'
        : null;

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
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: () async {
                          Navigator.of(modalContext).pop();
                          await _showSongSearchOptions(
                            item,
                            fallbackArtist: fallbackArtist,
                          );
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
                  leading: const Icon(Icons.favorite_outline_rounded),
                  title: TranslatedText('add_to_favorites'),
                  onTap: () async {
                    Navigator.of(modalContext).pop();
                    await _addSongToFavorites(
                      item,
                      fallbackArtist: fallbackArtist,
                      fallbackThumbUrl: fallbackThumbUrl,
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.playlist_add_rounded),
                  title: TranslatedText('add_to_playlist'),
                  onTap: () async {
                    Navigator.of(modalContext).pop();
                    await _showAddSongToPlaylistDialog(
                      item,
                      fallbackArtist: fallbackArtist,
                      fallbackThumbUrl: fallbackThumbUrl,
                    );
                  },
                ),
                if (artist.trim().isNotEmpty &&
                    artist.trim() != LocaleProvider.tr('artist_unknown'))
                  ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: const TranslatedText('go_to_artist'),
                    onTap: () async {
                      Navigator.of(modalContext).pop();
                      final name = artist.trim();
                      if (name.isEmpty) return;
                      await Future.delayed(Duration.zero);
                      if (!mounted) return;
                      Navigator.of(context).pushReplacement(
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
                    if (videoUrl != null && videoUrl.isNotEmpty) {
                      await SharePlus.instance.share(
                        ShareParams(text: videoUrl),
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
                    await _showSongInfo(
                      item,
                      fallbackArtist: fallbackArtist,
                      fallbackThumbUrl: fallbackThumbUrl,
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
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
    // final isLight = Theme.of(context).brightness == Brightness.light;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;

        if (_overlayPanelController.isAttached &&
            _overlayPanelController.isPanelOpen) {
          if (_playlistOpen) return;
          _overlayPanelController.close();
          return;
        }

        if (canPopInternally()) {
          handleInternalPop();
        } else {
          Navigator.of(context).pop();
        }
      },
      child: Stack(
        children: [
          Scaffold(
            extendBody: true,
            bottomNavigationBar: SizedBox(
              height: MediaQuery.of(context).padding.bottom,
              child: GestureDetector(
                onVerticalDragStart: (_) {},
                behavior: HitTestBehavior.translucent,
              ),
            ),
            appBar: AppBar(
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
              leading: _isSelectionMode
                  ? IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: _clearSelection,
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
                          color: isDark
                              ? Theme.of(
                                  context,
                                ).colorScheme.secondary.withValues(alpha: 0.06)
                              : Theme.of(
                                  context,
                                ).colorScheme.secondary.withValues(alpha: 0.07),
                        ),
                        child: const Icon(Icons.arrow_back, size: 24),
                      ),
                      onPressed: () {
                        if (canPopInternally()) {
                          handleInternalPop();
                        } else {
                          Navigator.of(context).pop();
                        }
                      },
                    ),
              title: _isSelectionMode
                  ? Text(
                      '${_selectedIndexes.length} ${LocaleProvider.tr('selected')}',
                    )
                  : TranslatedText(
                      'artist',
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
              actions: [
                if (_isSelectionMode && _selectedIndexes.isNotEmpty)
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
                        await _downloadSelectedItems();
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
                if (!_isSelectionMode) ...[
                  // Dialogo de informacion de la pantalla
                  IconButton(
                    icon: const Icon(Icons.info_outline, size: 28),
                    tooltip: LocaleProvider.tr('info'),
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (context) {
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
                              24,
                              24,
                              24,
                              8,
                            ),
                            icon: Icon(
                              Icons.info_rounded,
                              size: 32,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                            title: Text(
                              LocaleProvider.tr('info'),
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w500,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            content: SingleChildScrollView(
                              child: Text(
                                LocaleProvider.tr('artist_info'),
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                      height: 1.5,
                                      fontSize: 16,
                                    ),
                                textAlign: TextAlign.start,
                              ),
                            ),
                            actionsPadding: const EdgeInsets.all(16),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(context).pop(),
                                child: Text(
                                  LocaleProvider.tr('ok'),
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: isAmoled && isDark
                                        ? Colors.white
                                        : Theme.of(context).colorScheme.primary,
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
                ? Center(child: LoadingIndicator())
                : _artist == null
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
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
                            Icons.person,
                            size: 50,
                            color:
                                Theme.of(context).brightness == Brightness.light
                                ? Theme.of(
                                    context,
                                  ).colorScheme.onSurface.withValues(alpha: 0.7)
                                : Theme.of(context).colorScheme.onSurface
                                      .withValues(alpha: 0.7),
                          ),
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
                : CustomScrollView(
                    controller: _scrollController,
                    physics: const ClampingScrollPhysics(),
                    slivers: [
                      SliverToBoxAdapter(
                        child: Stack(
                          alignment: Alignment.bottomLeft,
                          children: [
                            ClipRRect(
                              child: Stack(
                                children: [
                                  _buildSafeNetworkImage(
                                    _artist!['thumbUrl'],
                                    width: double.infinity,
                                    height: 220,
                                    fit: BoxFit.cover,
                                    alignment: Alignment.topCenter,
                                    fallback: Container(
                                      width: double.infinity,
                                      height: 300,
                                      decoration: BoxDecoration(
                                        color:
                                            colorSchemeNotifier.value ==
                                                AppColorScheme.amoled
                                            ? Colors.white.withValues(
                                                alpha: 0.1,
                                              )
                                            : Theme.of(context)
                                                  .colorScheme
                                                  .secondaryContainer
                                                  .withValues(alpha: 0.8),
                                        borderRadius: const BorderRadius.only(
                                          bottomLeft: Radius.circular(32),
                                          bottomRight: Radius.circular(32),
                                        ),
                                      ),
                                      child: const Icon(
                                        Icons.person,
                                        size: 120,
                                      ),
                                    ),
                                  ),
                                  Positioned.fill(
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.bottomCenter,
                                          end: Alignment.topCenter,
                                          colors: [
                                            Theme.of(
                                              context,
                                            ).scaffoldBackgroundColor,
                                            Theme.of(context)
                                                .scaffoldBackgroundColor
                                                .withValues(alpha: 0),
                                          ],
                                          stops: const [0.0, 0.7],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(
                                top: 10,
                                bottom: 10,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(left: 16),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.start,
                                      children: [
                                        Flexible(
                                          child: Text(
                                            _artist!['name']?.toString() ??
                                                widget.artistName,
                                            style: Theme.of(context)
                                                .textTheme
                                                .headlineSmall
                                                ?.copyWith(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 34,
                                                ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: Padding(
                                      padding: const EdgeInsets.only(left: 16),
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.start,
                                        children: [
                                          if (_artist!['subscribers'] != null &&
                                              _artist!['subscribers']
                                                  .toString()
                                                  .isNotEmpty) ...[
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 12,
                                                    vertical: 6,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: isAmoled && isDark
                                                    ? Colors.white.withValues(
                                                        alpha: 0.1,
                                                      )
                                                    : Theme.of(context)
                                                          .colorScheme
                                                          .surfaceContainerHighest
                                                          .withValues(
                                                            alpha: 0.5,
                                                          ),
                                                borderRadius:
                                                    BorderRadius.circular(20),
                                                border: Border.all(
                                                  color:
                                                      (isAmoled && isDark
                                                              ? Colors.white
                                                              : Theme.of(
                                                                      context,
                                                                    )
                                                                    .colorScheme
                                                                    .onSurface)
                                                          .withValues(
                                                            alpha: 0.1,
                                                          ),
                                                ),
                                              ),
                                              child: Row(
                                                children: [
                                                  Icon(
                                                    Icons.people_alt_outlined,
                                                    size: 16,
                                                    color: isAmoled && isDark
                                                        ? Colors.white
                                                              .withValues(
                                                                alpha: 0.7,
                                                              )
                                                        : Theme.of(context)
                                                              .colorScheme
                                                              .secondary,
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Text(
                                                    _formatArtistSubtitle(
                                                          _artist!['subscribers'],
                                                        ) ??
                                                        '',
                                                    style: TextStyle(
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.w500,
                                                      color: isAmoled && isDark
                                                          ? Colors.white
                                                                .withValues(
                                                                  alpha: 0.9,
                                                                )
                                                          : Theme.of(context)
                                                                .colorScheme
                                                                .onSurface,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                          ],
                                          if (_artist!['monthlyListeners'] !=
                                                  null &&
                                              _artist!['monthlyListeners']
                                                  .toString()
                                                  .isNotEmpty) ...[
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 12,
                                                    vertical: 6,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: isAmoled && isDark
                                                    ? Colors.white.withValues(
                                                        alpha: 0.1,
                                                      )
                                                    : Theme.of(context)
                                                          .colorScheme
                                                          .surfaceContainerHighest
                                                          .withValues(
                                                            alpha: 0.5,
                                                          ),
                                                borderRadius:
                                                    BorderRadius.circular(20),
                                                border: Border.all(
                                                  color:
                                                      (isAmoled && isDark
                                                              ? Colors.white
                                                              : Theme.of(
                                                                      context,
                                                                    )
                                                                    .colorScheme
                                                                    .onSurface)
                                                          .withValues(
                                                            alpha: 0.1,
                                                          ),
                                                ),
                                              ),
                                              child: Row(
                                                children: [
                                                  Icon(
                                                    Icons.headset_outlined,
                                                    size: 16,
                                                    color: isAmoled && isDark
                                                        ? Colors.white
                                                              .withValues(
                                                                alpha: 0.7,
                                                              )
                                                        : Theme.of(context)
                                                              .colorScheme
                                                              .secondary,
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Text(
                                                    _formatArtistSubtitle(
                                                          _artist!['monthlyListeners'],
                                                        ) ??
                                                        '',
                                                    style: TextStyle(
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.w500,
                                                      color: isAmoled && isDark
                                                          ? Colors.white
                                                                .withValues(
                                                                  alpha: 0.9,
                                                                )
                                                          : Theme.of(context)
                                                                .colorScheme
                                                                .onSurface,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                          ],
                                          // Botón de búsqueda externa (YT Music)
                                          InkWell(
                                            onTap: () async {
                                              final artistName =
                                                  _artist?['name']
                                                      ?.toString() ??
                                                  widget.artistName;
                                              await _showArtistSearchOptions(
                                                artistName,
                                              );
                                            },
                                            borderRadius: BorderRadius.circular(
                                              20,
                                            ),
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 12,
                                                    vertical: 6,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: isAmoled && isDark
                                                    ? Colors.white.withValues(
                                                        alpha: 0.1,
                                                      )
                                                    : Theme.of(context)
                                                          .colorScheme
                                                          .surfaceContainerHighest
                                                          .withValues(
                                                            alpha: 0.5,
                                                          ),
                                                borderRadius:
                                                    BorderRadius.circular(20),
                                                border: Border.all(
                                                  color:
                                                      (isAmoled && isDark
                                                              ? Colors.white
                                                              : Theme.of(
                                                                      context,
                                                                    )
                                                                    .colorScheme
                                                                    .onSurface)
                                                          .withValues(
                                                            alpha: 0.1,
                                                          ),
                                                ),
                                              ),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Image.asset(
                                                    'assets/icon/Youtube_Music_icon.png',
                                                    width: 18,
                                                    height: 18,
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Text(
                                                    'YouTube Music',
                                                    style: TextStyle(
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.w500,
                                                      color: isAmoled && isDark
                                                          ? Colors.white
                                                                .withValues(
                                                                  alpha: 0.9,
                                                                )
                                                          : Theme.of(context)
                                                                .colorScheme
                                                                .onSurface,
                                                    ),
                                                  ),
                                                ],
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
                          ],
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        sliver: SliverToBoxAdapter(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 12),
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
                                child: AnimatedSize(
                                  duration: const Duration(milliseconds: 300),
                                  curve: Curves.easeInOut,
                                  alignment: Alignment.topCenter,
                                  child: Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: isAmoled
                                          ? Colors.white.withAlpha(30)
                                          : Theme.of(context)
                                                .colorScheme
                                                .secondaryContainer
                                                .withValues(alpha: 0.4),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: Text(
                                            (_artist!['description'] != null &&
                                                    _artist!['description']
                                                        .toString()
                                                        .trim()
                                                        .isNotEmpty)
                                                ? _cleanDescription(
                                                    _artist!['description']
                                                        .toString(),
                                                  )
                                                : LocaleProvider.tr(
                                                    'no_description',
                                                  ),
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodyMedium,
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
                                                  ? Colors.white.withAlpha(30)
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
                                            child: AnimatedRotation(
                                              turns: _descExpanded ? 0.5 : 0,
                                              duration: const Duration(
                                                milliseconds: 300,
                                              ),
                                              child: Icon(
                                                Icons.expand_more,
                                                size: 20,
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.onSurface,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              if (_loadingContent)
                                Padding(
                                  padding: const EdgeInsets.all(32.0),
                                  child: Center(child: LoadingIndicator()),
                                ),
                            ],
                          ),
                        ),
                      ),
                      // Mostrar contenido del artista con diseño de YouTube
                      if (_expandedCategory == 'songs') ...[
                        // Vista de solo canciones con botón de volver
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          sliver: SliverToBoxAdapter(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 24),
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
                                                    .secondary
                                                    .withValues(alpha: 0.06)
                                              : Theme.of(context)
                                                    .colorScheme
                                                    .secondary
                                                    .withValues(alpha: 0.07),
                                        ),
                                        child: const Icon(
                                          Icons.arrow_back,
                                          size: 24,
                                        ),
                                      ),
                                      tooltip: 'Volver',
                                      onPressed: handleInternalPop,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      LocaleProvider.tr('songs_search'),
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
                                const SizedBox(height: 8),
                              ],
                            ),
                          ),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          sliver: SliverList(
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                // Mostrar indicador de carga al final
                                if (_loadingMoreSongs &&
                                    index == _songs.length) {
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

                                final cardColor = isAmoled
                                    ? Colors.white.withAlpha(20)
                                    : isDark
                                    ? Theme.of(context).colorScheme.secondary
                                          .withValues(alpha: 0.06)
                                    : Theme.of(context).colorScheme.secondary
                                          .withValues(alpha: 0.07);

                                final bool isFirst = index == 0;
                                final bool isLast = index == _songs.length - 1;
                                final bool isOnly =
                                    _songs.length == 1 && !_loadingMoreSongs;

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
                                } else if (isLast && !_loadingMoreSongs) {
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
                                  padding: EdgeInsets.only(
                                    bottom: isLast && !_loadingMoreSongs
                                        ? 0
                                        : 4,
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
                                        final videoId = item.videoId;
                                        if (videoId == null) return;
                                        if (_isSelectionMode) {
                                          _toggleSelection(
                                            index,
                                            isVideo: false,
                                          );
                                          return;
                                        }
                                        _showSongActionsModal(
                                          item,
                                          selectionKey: 'song-$videoId',
                                          fallbackArtist: _artist?['name']
                                              ?.toString(),
                                        );
                                      },
                                      onTap: () {
                                        if (_isSelectionMode) {
                                          _toggleSelection(
                                            index,
                                            isVideo: false,
                                          );
                                        } else {
                                          _playStreamingFromList(
                                            results: _songs,
                                            tappedIndex: index,
                                            queueSource:
                                                _artist?['name']?.toString() ??
                                                widget.artistName,
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
                                                    final key = 'song-$videoId';
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
                                          _formatYtArtistWithDuration(item),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: isAmoled
                                                ? Colors.white.withValues(
                                                    alpha: 0.8,
                                                  )
                                                : null,
                                          ),
                                        ),
                                        trailing: _buildPlayTrailingButton(
                                          results: _songs,
                                          tappedIndex: index,
                                          queueSource:
                                              _artist?['name']?.toString() ??
                                              widget.artistName,
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                              childCount:
                                  _songs.length + (_loadingMoreSongs ? 1 : 0),
                            ),
                          ),
                        ),
                      ],
                      if (_expandedCategory == 'videos') ...[
                        // Vista de solo videos con botón de volver
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          sliver: SliverToBoxAdapter(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 24),
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
                                                    .secondary
                                                    .withValues(alpha: 0.06)
                                              : Theme.of(context)
                                                    .colorScheme
                                                    .secondary
                                                    .withValues(alpha: 0.07),
                                        ),
                                        child: const Icon(
                                          Icons.arrow_back,
                                          size: 24,
                                        ),
                                      ),
                                      tooltip: 'Volver',
                                      onPressed: handleInternalPop,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      LocaleProvider.tr('videos'),
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
                                const SizedBox(height: 8),
                              ],
                            ),
                          ),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          sliver: SliverList(
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                // Mostrar indicador de carga al final
                                if (_loadingMoreVideos &&
                                    index == _videos.length) {
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

                                final cardColor = isAmoled
                                    ? Colors.white.withAlpha(20)
                                    : isDark
                                    ? Theme.of(context).colorScheme.secondary
                                          .withValues(alpha: 0.06)
                                    : Theme.of(context).colorScheme.secondary
                                          .withValues(alpha: 0.07);

                                final bool isFirst = index == 0;
                                final bool isLast = index == _videos.length - 1;
                                final bool isOnly =
                                    _videos.length == 1 && !_loadingMoreVideos;

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
                                } else if (isLast && !_loadingMoreVideos) {
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
                                  padding: EdgeInsets.only(
                                    bottom: isLast && !_loadingMoreVideos
                                        ? 0
                                        : 4,
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
                                        final videoId = item.videoId;
                                        if (videoId == null) return;
                                        if (_isSelectionMode) {
                                          _toggleSelection(
                                            index,
                                            isVideo: true,
                                          );
                                          return;
                                        }
                                        _showSongActionsModal(
                                          item,
                                          selectionKey: 'video-$videoId',
                                          fallbackArtist: _artist?['name']
                                              ?.toString(),
                                        );
                                      },
                                      onTap: () {
                                        if (_isSelectionMode) {
                                          _toggleSelection(
                                            index,
                                            isVideo: true,
                                          );
                                        } else {
                                          _playStreamingFromList(
                                            results: _videos,
                                            tappedIndex: index,
                                            queueSource:
                                                _artist?['name']?.toString() ??
                                                widget.artistName,
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
                                                    Icons.play_circle_fill,
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
                                          _formatYtArtistWithDuration(item),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: isAmoled
                                                ? Colors.white.withValues(
                                                    alpha: 0.8,
                                                  )
                                                : null,
                                          ),
                                        ),
                                        trailing: _buildPlayTrailingButton(
                                          results: _videos,
                                          tappedIndex: index,
                                          queueSource:
                                              _artist?['name']?.toString() ??
                                              widget.artistName,
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                              childCount:
                                  _videos.length + (_loadingMoreVideos ? 1 : 0),
                            ),
                          ),
                        ),
                      ],
                      if (_expandedCategory == 'singles') ...[
                        // Vista de lista de todos los sencillos
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          sliver: SliverToBoxAdapter(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 24),
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
                                                    .secondary
                                                    .withValues(alpha: 0.06)
                                              : Theme.of(context)
                                                    .colorScheme
                                                    .secondary
                                                    .withValues(alpha: 0.07),
                                        ),
                                        child: const Icon(
                                          Icons.arrow_back,
                                          size: 24,
                                        ),
                                      ),
                                      tooltip: 'Volver',
                                      onPressed: handleInternalPop,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      LocaleProvider.tr('singles'),
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
                                const SizedBox(height: 16),
                              ],
                            ),
                          ),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          sliver: SliverList(
                            delegate: SliverChildBuilderDelegate((
                              context,
                              index,
                            ) {
                              final single = _singles[index];

                              final cardColor = isAmoled
                                  ? Colors.white.withAlpha(20)
                                  : isDark
                                  ? Theme.of(context).colorScheme.secondary
                                        .withValues(alpha: 0.06)
                                  : Theme.of(context).colorScheme.secondary
                                        .withValues(alpha: 0.07);

                              final bool isFirst = index == 0;
                              final bool isLast = index == _singles.length - 1;
                              final bool isOnly = _singles.length == 1;

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
                                      // todo: impl selection
                                    },
                                    onTap: () async {
                                      if (single['browseId'] == null) {
                                        return;
                                      }
                                      setState(() {
                                        _previousCategory = 'singles';
                                        _expandedCategory = 'album';
                                        _loadingAlbumSongs = true;
                                        _albumSongs = [];
                                        _currentAlbum = {
                                          'title': single['title'],
                                          'artist': single['artist'],
                                          'thumbUrl': single['thumbUrl'],
                                        };
                                        _resetScroll();
                                      });
                                      final songs = await getAlbumSongs(
                                        single['browseId']!,
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
                                            horizontal: 12,
                                            vertical: 4,
                                          ),
                                      leading: ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child:
                                            single['thumbUrl'] != null &&
                                                single['thumbUrl']!.isNotEmpty
                                            ? _buildSafeNetworkImage(
                                                single['thumbUrl']!,
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
                                                      BorderRadius.circular(12),
                                                ),
                                                child: Icon(
                                                  Icons.album,
                                                  size: 32,
                                                  color: Theme.of(
                                                    context,
                                                  ).colorScheme.onSurface,
                                                ),
                                              ),
                                      ),
                                      title: Text(
                                        single['title'] ?? 'Título desconocido',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleMedium,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      subtitle: Text(
                                        (single['year'] != null &&
                                                single['year']
                                                    .toString()
                                                    .isNotEmpty)
                                            ? '${single['year']} • ${single['type'] == 'EP' ? 'EP' : LocaleProvider.tr('singles')}'
                                            : single['artist'] ??
                                                  'Artista desconocido',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      trailing: IconButton(
                                        style: IconButton.styleFrom(
                                          backgroundColor: Theme.of(
                                            context,
                                          ).colorScheme.primary.withAlpha(20),
                                        ),
                                        icon: const Icon(
                                          Icons.chevron_right,
                                          size: 20,
                                        ),
                                        onPressed: () async {
                                          if (single['browseId'] == null) {
                                            return;
                                          }
                                          setState(() {
                                            _previousCategory = 'singles';
                                            _expandedCategory = 'album';
                                            _loadingAlbumSongs = true;
                                            _albumSongs = [];
                                            _currentAlbum = {
                                              'title': single['title'],
                                              'artist': single['artist'],
                                              'thumbUrl': single['thumbUrl'],
                                            };
                                            _resetScroll();
                                          });
                                          final songs = await getAlbumSongs(
                                            single['browseId']!,
                                          );
                                          if (!mounted) return;
                                          setState(() {
                                            _albumSongs = songs;
                                            _loadingAlbumSongs = false;
                                          });
                                        },
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }, childCount: _singles.length),
                          ),
                        ),
                      ],
                      if (_expandedCategory == 'albums') ...[
                        // Vista de solo álbumes con botón de volver
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          sliver: SliverToBoxAdapter(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 24),
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
                                                    .secondary
                                                    .withValues(alpha: 0.06)
                                              : Theme.of(context)
                                                    .colorScheme
                                                    .secondary
                                                    .withValues(alpha: 0.07),
                                        ),
                                        child: const Icon(
                                          Icons.arrow_back,
                                          size: 24,
                                        ),
                                      ),
                                      tooltip: 'Volver',
                                      onPressed: handleInternalPop,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      LocaleProvider.tr('albums'),
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
                                const SizedBox(height: 16),
                              ],
                            ),
                          ),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          sliver: SliverList(
                            delegate: SliverChildBuilderDelegate((
                              context,
                              index,
                            ) {
                              final album = _albums[index];

                              final cardColor = isAmoled
                                  ? Colors.white.withAlpha(20)
                                  : isDark
                                  ? Theme.of(context).colorScheme.secondary
                                        .withValues(alpha: 0.06)
                                  : Theme.of(context).colorScheme.secondary
                                        .withValues(alpha: 0.07);

                              final bool isFirst = index == 0;
                              final bool isLast = index == _albums.length - 1;
                              final bool isOnly = _albums.length == 1;

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
                                      if (album['browseId'] == null) {
                                        return;
                                      }
                                      setState(() {
                                        _previousCategory = 'albums';
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
                                    child: ListTile(
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 4,
                                          ),
                                      leading: ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child:
                                            album['thumbUrl'] != null &&
                                                album['thumbUrl']!.isNotEmpty
                                            ? _buildSafeNetworkImage(
                                                album['thumbUrl']!,
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
                                                      BorderRadius.circular(12),
                                                ),
                                                child: Icon(
                                                  Icons.album,
                                                  size: 32,
                                                  color: Theme.of(
                                                    context,
                                                  ).colorScheme.onSurface,
                                                ),
                                              ),
                                      ),
                                      title: Text(
                                        album['title'] ?? 'Título desconocido',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleMedium,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      subtitle: Text(
                                        (album['year'] != null &&
                                                album['year']
                                                    .toString()
                                                    .isNotEmpty)
                                            ? '${album['year']} • ${album['artist'] ?? 'Artista desconocido'}'
                                            : album['artist'] ??
                                                  'Artista desconocido',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      trailing: IconButton(
                                        style: IconButton.styleFrom(
                                          backgroundColor: Theme.of(
                                            context,
                                          ).colorScheme.primary.withAlpha(20),
                                        ),
                                        icon: const Icon(
                                          Icons.chevron_right,
                                          size: 20,
                                        ),
                                        onPressed: () async {
                                          if (album['browseId'] == null) {
                                            return;
                                          }
                                          setState(() {
                                            _previousCategory = 'albums';
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
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }, childCount: _albums.length),
                          ),
                        ),
                      ],
                      if (_expandedCategory == 'album') ...[
                        // Vista de canciones del álbum seleccionado
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          sliver: SliverToBoxAdapter(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 24),
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
                                                    .secondary
                                                    .withValues(alpha: 0.06)
                                              : Theme.of(context)
                                                    .colorScheme
                                                    .secondary
                                                    .withValues(alpha: 0.07),
                                        ),
                                        child: const Icon(
                                          Icons.arrow_back,
                                          size: 24,
                                        ),
                                      ),
                                      tooltip: 'Volver',
                                      onPressed: handleInternalPop,
                                    ),
                                    const SizedBox(width: 8),
                                    if (_currentAlbum != null) ...[
                                      if (_currentAlbum!['thumbUrl'] != null)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            right: 12,
                                          ),
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            child: CachedNetworkImage(
                                              imageUrl:
                                                  _currentAlbum!['thumbUrl'],
                                              width: 40,
                                              height: 40,
                                              fit: BoxFit.cover,
                                              fadeInDuration: Duration.zero,
                                              fadeOutDuration: Duration.zero,
                                              errorWidget:
                                                  (context, url, error) =>
                                                      const Icon(
                                                        Icons.album,
                                                        size: 24,
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
                                            for (final song in _albumSongs) {
                                              await downloadQueue.addToQueue(
                                                context: context,
                                                videoId: song.videoId ?? '',
                                                title:
                                                    song.title ?? 'Sin título',
                                                artist:
                                                    song.artist?.replaceFirst(
                                                      RegExp(r' - Topic$'),
                                                      '',
                                                    ) ??
                                                    'Artista desconocido',
                                              );
                                            }
                                            if (!mounted) return;
                                            _showMessage(
                                              LocaleProvider.tr('success'),
                                              '${_albumSongs.length} ${LocaleProvider.tr('songs_added_to_queue')}',
                                            );
                                          }
                                        },
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 16),
                              ],
                            ),
                          ),
                        ),
                        if (_loadingAlbumSongs)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.all(32.0),
                              child: Center(child: LoadingIndicator()),
                            ),
                          )
                        else if (_albumSongs.isEmpty)
                          const SliverToBoxAdapter(
                            child: Center(
                              child: Text('No se encontraron canciones'),
                            ),
                          )
                        else
                          SliverPadding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            sliver: SliverList(
                              delegate: SliverChildBuilderDelegate((
                                context,
                                index,
                              ) {
                                final item = _albumSongs[index];
                                final videoId = item.videoId;
                                final isSelected =
                                    videoId != null &&
                                    _selectedIndexes.contains('album-$videoId');

                                final cardColor = isAmoled
                                    ? Colors.white.withAlpha(20)
                                    : isDark
                                    ? Theme.of(context).colorScheme.secondary
                                          .withValues(alpha: 0.06)
                                    : Theme.of(context).colorScheme.secondary
                                          .withValues(alpha: 0.07);

                                final bool isFirst = index == 0;
                                final bool isLast =
                                    index == _albumSongs.length - 1;
                                final bool isOnly = _albumSongs.length == 1;

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
                                        if (videoId == null) return;
                                        if (_isSelectionMode) {
                                          _toggleSelection(
                                            index,
                                            isVideo: false,
                                            isAlbum: true,
                                          );
                                          return;
                                        }
                                        _showSongActionsModal(
                                          item,
                                          selectionKey: 'album-$videoId',
                                          fallbackArtist:
                                              _currentAlbum?['artist']
                                                  ?.toString(),
                                          fallbackThumbUrl:
                                              _currentAlbum?['thumbUrl']
                                                  ?.toString(),
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
                                          _playStreamingFromList(
                                            results: _albumSongs,
                                            tappedIndex: index,
                                            queueSource:
                                                _currentAlbum?['title']
                                                    ?.toString() ??
                                                (_artist?['name']?.toString() ??
                                                    widget.artistName),
                                            playAsQueue: true,
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
                                            SizedBox(
                                              width: 56,
                                              height: 56,
                                              child: Center(
                                                child: Text(
                                                  '${index + 1}',
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .titleMedium
                                                      ?.copyWith(
                                                        fontWeight:
                                                            FontWeight.w600,
                                                        color: isAmoled
                                                            ? Colors.white
                                                                  .withValues(
                                                                    alpha: 0.85,
                                                                  )
                                                            : Theme.of(context)
                                                                  .colorScheme
                                                                  .onSurface
                                                                  .withValues(
                                                                    alpha: 0.8,
                                                                  ),
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
                                          _formatYtArtistWithDuration(
                                            item,
                                            fallbackArtist:
                                                _currentAlbum?['artist']
                                                    ?.toString(),
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: isAmoled
                                                ? Colors.white.withValues(
                                                    alpha: 0.8,
                                                  )
                                                : null,
                                          ),
                                        ),
                                        trailing: _buildPlayTrailingButton(
                                          results: _albumSongs,
                                          tappedIndex: index,
                                          queueSource:
                                              _currentAlbum?['title']
                                                  ?.toString() ??
                                              (_artist?['name']?.toString() ??
                                                  widget.artistName),
                                          playAsQueue: true,
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              }, childCount: _albumSongs.length),
                            ),
                          ),
                      ],
                      if (_expandedCategory == null) ...[
                        SliverToBoxAdapter(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
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
                                          _previousCategory = _expandedCategory;
                                          _expandedCategory = 'songs';
                                          _resetScroll();
                                        });
                                      },
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 4,
                                        ),
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
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
                                                    fontWeight: FontWeight.w600,
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

                                          final cardColor = isAmoled
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

                                          final int totalToShow =
                                              _songs.length < 3
                                              ? _songs.length
                                              : 3;
                                          final bool isFirst = index == 0;
                                          final bool isLast =
                                              index == totalToShow - 1;
                                          final bool isOnly = totalToShow == 1;

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
                                                  final videoId = item.videoId;
                                                  if (videoId == null) return;
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
                                                    fallbackArtist:
                                                        _artist?['name']
                                                            ?.toString(),
                                                  );
                                                },
                                                onTap: () {
                                                  if (_isSelectionMode) {
                                                    _toggleSelection(
                                                      index,
                                                      isVideo: false,
                                                    );
                                                  } else {
                                                    _playStreamingFromList(
                                                      results: _songs,
                                                      tappedIndex: index,
                                                      queueSource:
                                                          _artist?['name']
                                                              ?.toString() ??
                                                          widget.artistName,
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
                                                                  ? Theme.of(
                                                                          context,
                                                                        )
                                                                        .colorScheme
                                                                        .secondaryContainer
                                                                  : Theme.of(
                                                                          context,
                                                                        )
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
                                                              color:
                                                                  Theme.of(
                                                                        context,
                                                                      )
                                                                      .colorScheme
                                                                      .onSurface,
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                  title: Text(
                                                    item.title ??
                                                        'Título desconocido',
                                                    style: Theme.of(
                                                      context,
                                                    ).textTheme.titleMedium,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                  subtitle: Text(
                                                    _formatYtArtistWithDuration(
                                                      item,
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
                                                        results: _songs,
                                                        tappedIndex: index,
                                                        queueSource:
                                                            _artist?['name']
                                                                ?.toString() ??
                                                            widget.artistName,
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
                                                SizedBox(
                                                  width: 20,
                                                  height: 20,
                                                  child: LoadingIndicator(),
                                                ),
                                                const SizedBox(width: 12),
                                                TranslatedText(
                                                  'loading_more',
                                                  style: const TextStyle(
                                                    fontSize: 14,
                                                  ),
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
                                const SizedBox(height: 24),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    InkWell(
                                      borderRadius: BorderRadius.circular(8),
                                      onTap: () {
                                        setState(() {
                                          _previousCategory = _expandedCategory;
                                          _expandedCategory = 'albums';
                                          _resetScroll();
                                        });
                                      },
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 4,
                                        ),
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            Row(
                                              children: [
                                                SizedBox(width: 14),
                                                Text(
                                                  LocaleProvider.tr('albums'),
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
                                            Icon(Icons.chevron_right),
                                          ],
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    SizedBox(
                                      height:
                                          180, // Aumentar altura para evitar overflow
                                      child: ListView.separated(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                        ),
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
                                                _previousCategory =
                                                    _expandedCategory;
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
                                                          BorderRadius.circular(
                                                            12,
                                                          ),
                                                      child:
                                                          album['thumbUrl'] !=
                                                              null
                                                          ? CachedNetworkImage(
                                                              imageUrl:
                                                                  album['thumbUrl']!,
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
                                                            )
                                                          : Container(
                                                              color: isSystem
                                                                  ? Theme.of(
                                                                          context,
                                                                        )
                                                                        .colorScheme
                                                                        .secondaryContainer
                                                                  : Theme.of(
                                                                          context,
                                                                        )
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
                                                      overflow:
                                                          TextOverflow.ellipsis,
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

                              // Sección Sencillos
                              if (_singles.isNotEmpty) ...[
                                const SizedBox(height: 24),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    InkWell(
                                      // No hay vista expandida de singles por ahora, así que no es clickable
                                      // O podríamos hacer que abra la vista de álbum con todos los singles si quisieramos
                                      // Por ahora solo mostramos el título
                                      borderRadius: BorderRadius.circular(8),
                                      onTap: () {
                                        setState(() {
                                          _previousCategory = _expandedCategory;
                                          _expandedCategory = 'singles';
                                          _resetScroll();
                                        });
                                      },
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 4,
                                        ),
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            Row(
                                              children: [
                                                SizedBox(width: 14),
                                                Text(
                                                  LocaleProvider.tr(
                                                    'singles', // Hardcoded or LocaleProvider.tr('singles')
                                                  ),
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
                                            Icon(Icons.chevron_right),
                                          ],
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    SizedBox(
                                      height: 180, // Altura igual a albums
                                      child: ListView.separated(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                        ),
                                        scrollDirection: Axis.horizontal,
                                        itemCount: _singles.length,
                                        separatorBuilder: (_, _) =>
                                            const SizedBox(width: 12),
                                        itemBuilder: (context, index) {
                                          final single = _singles[index];
                                          return AnimatedTapButton(
                                            onTap: () async {
                                              // Cargar canciones del sencillo (igual que álbum)
                                              if (single['browseId'] == null) {
                                                return;
                                              }
                                              setState(() {
                                                _previousCategory =
                                                    _expandedCategory;
                                                _expandedCategory =
                                                    'album'; // Usamos vista de álbum
                                                _loadingAlbumSongs = true;
                                                _albumSongs = [];
                                                _currentAlbum = {
                                                  'title': single['title'],
                                                  'artist': single['artist'],
                                                  'thumbUrl':
                                                      single['thumbUrl'],
                                                };
                                                _resetScroll();
                                              });
                                              final songs = await getAlbumSongs(
                                                single['browseId']!,
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
                                                          BorderRadius.circular(
                                                            12,
                                                          ),
                                                      child:
                                                          single['thumbUrl'] !=
                                                              null
                                                          ? CachedNetworkImage(
                                                              imageUrl:
                                                                  single['thumbUrl']!,
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
                                                            )
                                                          : Container(
                                                              color: isSystem
                                                                  ? Theme.of(
                                                                          context,
                                                                        )
                                                                        .colorScheme
                                                                        .secondaryContainer
                                                                  : Theme.of(
                                                                          context,
                                                                        )
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
                                                      single['title'] ?? '',
                                                      maxLines: 2,
                                                      overflow:
                                                          TextOverflow.ellipsis,
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
                                const SizedBox(height: 24),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    InkWell(
                                      borderRadius: BorderRadius.circular(8),
                                      onTap: () {
                                        setState(() {
                                          _previousCategory = _expandedCategory;
                                          _expandedCategory = 'videos';
                                          _resetScroll();
                                        });
                                      },
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 4,
                                        ),
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            Row(
                                              children: [
                                                SizedBox(width: 14),
                                                Text(
                                                  LocaleProvider.tr('videos'),
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
                                            Icon(Icons.chevron_right),
                                          ],
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 12),
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

                                          final cardColor = isAmoled
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

                                          final int totalToShow =
                                              _videos.length < 3
                                              ? _videos.length
                                              : 3;
                                          final bool isFirst = index == 0;
                                          final bool isLast =
                                              index == totalToShow - 1;
                                          final bool isOnly = totalToShow == 1;

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
                                                  final videoId = item.videoId;
                                                  if (videoId == null) return;
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
                                                    fallbackArtist:
                                                        _artist?['name']
                                                            ?.toString(),
                                                  );
                                                },
                                                onTap: () {
                                                  if (_isSelectionMode) {
                                                    _toggleSelection(
                                                      index,
                                                      isVideo: true,
                                                    );
                                                  } else {
                                                    _playStreamingFromList(
                                                      results: _videos,
                                                      tappedIndex: index,
                                                      queueSource:
                                                          _artist?['name']
                                                              ?.toString() ??
                                                          widget.artistName,
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
                                                                  ? Theme.of(
                                                                          context,
                                                                        )
                                                                        .colorScheme
                                                                        .secondaryContainer
                                                                  : Theme.of(
                                                                          context,
                                                                        )
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
                                                              color:
                                                                  Theme.of(
                                                                        context,
                                                                      )
                                                                      .colorScheme
                                                                      .onSurface,
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                  title: Text(
                                                    item.title ??
                                                        'Título desconocido',
                                                    style: Theme.of(
                                                      context,
                                                    ).textTheme.titleMedium,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                  subtitle: Text(
                                                    _formatYtArtistWithDuration(
                                                      item,
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
                                                        results: _videos,
                                                        tappedIndex: index,
                                                        queueSource:
                                                            _artist?['name']
                                                                ?.toString() ??
                                                            widget.artistName,
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
                                                SizedBox(
                                                  width: 20,
                                                  height: 20,
                                                  child: LoadingIndicator(),
                                                ),
                                                const SizedBox(width: 12),
                                                TranslatedText(
                                                  'loading_more',
                                                  style: const TextStyle(
                                                    fontSize: 14,
                                                  ),
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
                          ),
                        ),
                      ],
                      // Spacing para no tapar el contenido con el mini overlay.
                      ValueListenableBuilder<bool>(
                        valueListenable: overlayVisibleNotifier,
                        builder: (context, overlayActive, _) {
                          final bottomPadding = MediaQuery.of(
                            context,
                          ).padding.bottom;
                          final extraSpace = overlayActive ? 100.0 : 0.0;
                          return SliverToBoxAdapter(
                            child: SizedBox(height: bottomPadding + extraSpace),
                          );
                        },
                      ),
                    ],
                  ),
          ),
          Positioned.fill(
            child: ValueListenableBuilder<bool>(
              valueListenable: audioServiceReady,
              builder: (context, ready, _) {
                if (!ready || audioHandler == null) {
                  return const SizedBox.shrink();
                }
                return StreamBuilder<MediaItem?>(
                  stream: audioHandler?.mediaItem,
                  builder: (context, snapshot) {
                    if (snapshot.data != null &&
                        !overlayVisibleNotifier.value) {
                      overlayVisibleNotifier.value = true;
                    }

                    return ValueListenableBuilder<bool>(
                      valueListenable: overlayVisibleNotifier,
                      builder: (context, overlayActive, _) {
                        if (!overlayActive) {
                          return const SizedBox.shrink();
                        }

                        if (openPlayerPanelNotifier.value) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (openPlayerPanelNotifier.value &&
                                _overlayPanelController.isAttached) {
                              _overlayPanelController.open();
                              openPlayerPanelNotifier.value = false;
                            }
                          });
                        }

                        final mediaQuery = MediaQuery.of(context);
                        final bottomPadding = mediaQuery.padding.bottom;
                        final bottomViewPadding = mediaQuery.viewPadding.bottom;
                        final hasBottomInset = bottomViewPadding > 0;
                        // Heurística Android:
                        // - gestos: inset inferior pequeño
                        // - botones: inset inferior más grande
                        final isGestureNavigation =
                            hasBottomInset && bottomViewPadding < 32.0;
                        final isButtonNavigation = bottomViewPadding >= 32.0;
                        final overlayBottomPadding = isGestureNavigation
                            ? (bottomPadding - 2.0)
                                  .clamp(0.0, double.infinity)
                                  .toDouble()
                            : isButtonNavigation
                            ? (bottomPadding - 6.0)
                                  .clamp(0.0, double.infinity)
                                  .toDouble()
                            : bottomPadding;
                        final collapsedBaseHeight = isButtonNavigation
                            ? 90.0
                            : isGestureNavigation
                            ? 80.0
                            : 90.0;
                        final screenHeight = MediaQuery.of(context).size.height;

                        return overlay_panel.SlidingUpPanel(
                          controller: _overlayPanelController,
                          // En ArtistScreen no existe la barra inferior con tabs;
                          // dejamos más alto el estado colapsado para que la línea
                          // del artista no quede comprimida.
                          minHeight: collapsedBaseHeight + bottomPadding,
                          maxHeight: screenHeight,
                          renderPanelSheet: false,
                          boxShadow: const [],
                          color: Colors.transparent,
                          isDraggable: !_playlistOpen,
                          panelSnapping: true,
                          backdropEnabled: false,
                          defaultPanelState: overlay_panel.PanelState.closed,
                          onPanelSlide: (position) {
                            _panelPositionNotifier.value = position;
                          },
                          onPanelClosed: () {
                            if (_playlistOpen) {
                              setState(() {
                                _playlistOpen = false;
                              });
                            }
                          },
                          collapsed: ValueListenableBuilder<double>(
                            valueListenable: _panelPositionNotifier,
                            builder: (context, position, child) {
                              return Opacity(
                                opacity: (1.0 - (position / 0.3)).clamp(
                                  0.0,
                                  1.0,
                                ),
                                child: child,
                              );
                            },
                            child: RepaintBoundary(
                              child: Padding(
                                padding: EdgeInsets.only(
                                  bottom: overlayBottomPadding,
                                ),
                                child: NowPlayingOverlay(
                                  showBar: true,
                                  onTap: () {
                                    if (_overlayPanelController.isAttached) {
                                      _overlayPanelController.open();
                                    }
                                  },
                                ),
                              ),
                            ),
                          ),
                          panel: Builder(
                            builder: (context) {
                              final data = MediaQuery.of(context);
                              _playerScreenWidget ??=
                                  player_screen.FullPlayerScreen(
                                    initialMediaItem: snapshot.data,
                                    panelPositionNotifier:
                                        _panelPositionNotifier,
                                    onClose: () {
                                      if (_overlayPanelController.isAttached) {
                                        _overlayPanelController.close();
                                      }
                                    },
                                    onPlaylistStateChanged: (isOpen) {
                                      if (_playlistOpen != isOpen) {
                                        setState(() {
                                          _playlistOpen = isOpen;
                                        });
                                      }
                                    },
                                  );

                              return MediaQuery(
                                data: data.copyWith(
                                  padding: data.padding.copyWith(
                                    bottom: data.viewPadding.bottom,
                                  ),
                                ),
                                child: RepaintBoundary(
                                  child: ClipRRect(
                                    borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(20),
                                    ),
                                    child:
                                        _playerScreenWidget ??
                                        const SizedBox.shrink(),
                                  ),
                                ),
                              );
                            },
                          ),
                          body: const SizedBox.expand(),
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // Función para construir una opción de acción
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

  Future<void> _showArtistSearchOptions(String artistName) async {
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
                      'search_artist',
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
                        _searchArtistOnYouTube(artistName);
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
                        _searchArtistOnYouTubeMusic(artistName);
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

  // Función para descargar elementos seleccionados
  List<YtMusicResult> _getSelectedItems() {
    final List<YtMusicResult> items = [];
    for (final key in _selectedIndexes) {
      if (key.startsWith('song-')) {
        final videoId = key.substring(5);
        try {
          items.add(_songs.firstWhere((s) => s.videoId == videoId));
        } catch (_) {}
      } else if (key.startsWith('video-')) {
        final videoId = key.substring(6);
        try {
          items.add(_videos.firstWhere((v) => v.videoId == videoId));
        } catch (_) {}
      } else if (key.startsWith('album-')) {
        final videoId = key.substring(6);
        try {
          items.add(_albumSongs.firstWhere((s) => s.videoId == videoId));
        } catch (_) {}
      }
    }
    return items
        .where((item) => item.videoId?.trim().isNotEmpty == true)
        .toList();
  }

  Future<void> _addSelectedToFavorites() async {
    final items = _getSelectedItems();
    if (items.isEmpty) return;
    for (final item in items) {
      await _addSongToFavorites(
        item,
        fallbackArtist: _artist?['name']?.toString(),
      );
    }
    _clearSelection();
  }

  Future<void> _addSelectedToPlaylist() async {
    final items = _getSelectedItems();
    if (items.isEmpty) return;
    final allPlaylists = await PlaylistsDB().getAllPlaylists();
    final textController = TextEditingController();
    if (!mounted) return;

    Future<void> addItemsToPlaylist(String playlistId) async {
      for (final item in items) {
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
    final List<YtMusicResult> itemsToDownload = _getSelectedItems();

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
              Icons.task_alt_rounded,
              size: 32,
              color: Theme.of(context).colorScheme.onSurface,
            ),
            title: Text(
              title,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w500,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
            content: SingleChildScrollView(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.5,
                  fontSize: 16,
                ),
                textAlign: TextAlign.start,
              ),
            ),
            actionsPadding: const EdgeInsets.all(16),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  LocaleProvider.tr('ok'),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: isAmoled && isDark
                        ? Colors.white
                        : Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ],
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
