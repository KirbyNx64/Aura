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
import 'package:just_audio/just_audio.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'package:dio/dio.dart';

class YtSearchTestScreen extends StatefulWidget {
  final String? initialQuery;
  const YtSearchTestScreen({super.key, this.initialQuery});

  @override
  State<YtSearchTestScreen> createState() => _YtSearchTestScreenState();
}

class _YtSearchTestScreenState extends State<YtSearchTestScreen>
    with WidgetsBindingObserver {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  List<YtMusicResult> _songResults = [];
  List<YtMusicResult> _videoResults = [];
  List<dynamic> _albumResults = [];
  String? _expandedCategory; // 'songs', 'videos', 'album', o null
  bool _loading = false;
  String? _error;
  double _lastViewInset = 0;
  bool _hasSearched = false;
  bool _showSuggestions = false;
  bool _noInternet = false; // Nuevo estado para internet
  bool _loadingMoreSongs = false;
  bool _loadingMoreVideos = false;
  List<YtMusicResult> _albumSongs = [];
  Map<String, dynamic>? _currentAlbum;
  bool _loadingAlbumSongs = false;

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
  int _songPage = 1;
  int _videoPage = 1;
  bool _hasMoreSongs = true;
  bool _hasMoreVideos = true;


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
                  'musicVideoType'
                ]);
                if (videoType == 'MUSIC_VIDEO_TYPE_MV' || videoType == 'MUSIC_VIDEO_TYPE_OMV' || videoType == 'MUSIC_VIDEO_TYPE_UGC') {
                  final title = renderer['flexColumns']?[0]
                      ?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs']?[0]?['text'];
                  final subtitleRuns = renderer['flexColumns']?[1]
                      ?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'];
                  String? artist;
                  if (subtitleRuns is List) {
                    for (var run in subtitleRuns) {
                      if (run['navigationEndpoint']?['browseEndpoint']?['browseEndpointContextSupportedConfigs'] != null ||
                          run['navigationEndpoint']?['browseEndpoint']?['browseId']?.startsWith('UC') == true) {
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
                  final thumbnails = renderer['thumbnail']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'];
                  if (thumbnails is List && thumbnails.isNotEmpty) {
                    thumbUrl = thumbnails.last['url'];
                  }
                  final videoId = renderer['overlay']?['musicItemThumbnailOverlayRenderer']?['content']?['musicPlayButtonRenderer']?['playNavigationEndpoint']?['watchEndpoint']?['videoId'];
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
      _songPage = 1;
      _videoPage = 1;
      _hasMoreSongs = true;
      _hasMoreVideos = true;
      _loadingMoreSongs = true;
      _loadingMoreVideos = true;
    });
    final List<ConnectivityResult> connectivityResult = await Connectivity().checkConnectivity();
    if (connectivityResult.contains(ConnectivityResult.none)) {
      if (mounted) {
        setState(() {
          _noInternet = true;
          _loading = false;
          _songResults = [];
          _videoResults = [];
          _albumResults = [];
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
      _error = null;
      _hasSearched = true;
      _loadingMoreSongs = false;
      _loadingMoreVideos = false;
    });
    try {
      // 1. Obtener los primeros 20 resultados rápidamente
      final songFuture = searchSongsOnly(_controller.text);
      final videoFuture = _searchVideosOnly(_controller.text);
      final albumFuture = searchAlbumsOnly(_controller.text);
      final results = await Future.wait([songFuture, videoFuture, albumFuture]);
      if (!mounted) return;
      setState(() {
        _songResults = (results[0] as List).cast<YtMusicResult>();
        _videoResults = (results[1] as List).cast<YtMusicResult>();
        _albumResults = (results[2] as List); // No cast<YtMusicResult> aquí
        // print('Álbumes encontrados:  [32m${_albumResults.length} [0m');
        _loading = false;
      });
      // 2. En segundo plano, cargar más resultados (hasta 100)
      // Para canciones
      searchSongsWithPagination(_controller.text, maxPages: 5).then((moreSongs) {
        if (!mounted) return;
        setState(() {
          final existingIds = _songResults.map((e) => e.videoId).toSet();
          final newOnes = moreSongs.where((e) => !existingIds.contains(e.videoId)).toList();
          _songResults.addAll(newOnes);
          _loadingMoreSongs = false;
        });
      });
      // Para videos: si tienes paginación, implementa aquí la llamada extendida
      searchVideosWithPagination(_controller.text, maxPages: 5).then((moreVideos) {
        if (!mounted) return;
        setState(() {
          final existingIds = _videoResults.map((e) => e.videoId).toSet();
          final newOnes = moreVideos.where((e) => !existingIds.contains(e.videoId)).toList();
          _videoResults.addAll(newOnes);
          _loadingMoreVideos = false;
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
          _songScrollController.position.pixels >= _songScrollController.position.maxScrollExtent - 10) {
        _loadMoreSongs();
      }
    });
    _videoScrollController.addListener(() {
      if (_expandedCategory == 'videos' &&
          !_loadingMoreVideos &&
          _videoScrollController.position.pixels >= _videoScrollController.position.maxScrollExtent - 10) {
        _loadMoreVideos();
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
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    final viewInsets = PlatformDispatcher.instance.views.first.viewInsets.bottom;
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
      _error = null;
      _hasSearched = false;
      _loading = false;
      _loadingMoreSongs = false;
      _loadingMoreVideos = false;
      _showSuggestions = true;
      _selectedIndexes.clear();
      _isSelectionMode = false;
    });
  }

  // Métodos para manejar el progreso de descarga
  void _onDownloadProgress(double progress) {
    downloadProgressNotifier.value = progress;
  }

  void _onDownloadStart(String title, String artist) {
    // Actualizar la longitud de la cola
    final downloadQueue = DownloadQueue();
    queueLengthNotifier.value = downloadQueue.queueLength;
    
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
    }
  }

  void _onDownloadSuccess(String title, String message) {
    final downloadQueue = DownloadQueue();
    
    // Solo limpiar el estado si no hay más descargas en la cola
    if (downloadQueue.queueLength == 0) {
      isDownloadingNotifier.value = false;
      isProcessingNotifier.value = false;
      downloadProgressNotifier.value = 0.0;
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
    }
    
    // Actualizar la longitud de la cola
    queueLengthNotifier.value = downloadQueue.queueLength;
  }

  // Método para manejar cuando se agrega una descarga a la cola
  void _onDownloadAddedToQueue(String title, String artist) {
    final downloadQueue = DownloadQueue();
    queueLengthNotifier.value = downloadQueue.queueLength;
    
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

  Future<void> _checkHistory() async {
  }

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

  Future<void> _pickDirectory() async {
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    final sdkInt = androidInfo.version.sdkInt;

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

    final String? path = await getDirectoryPath();
    if (path != null && path.isNotEmpty) {
      downloadDirectoryNotifier.value = path;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('download_directory', path);
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
              orElse: () => YtMusicResult(title: null, artist: null, thumbUrl: null, videoId: null),
            );
          } else if (key.startsWith('song-')) {
            final videoId = key.substring(5);
            return _songResults.firstWhere(
              (item) => item.videoId == videoId,
              orElse: () => YtMusicResult(title: null, artist: null, thumbUrl: null, videoId: null),
            );
          } else if (key.startsWith('album-')) {
            final videoId = key.substring(6);
            return _albumSongs.firstWhere(
              (item) => item.videoId == videoId,
              orElse: () => YtMusicResult(title: null, artist: null, thumbUrl: null, videoId: null),
            );
          } else {
            return YtMusicResult(title: null, artist: null, thumbUrl: null, videoId: null);
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
  }

  Future<void> _loadMoreSongs() async {
    if (_loadingMoreSongs || !_hasMoreSongs) return;
    setState(() { _loadingMoreSongs = true; });
    final nextPage = _songPage + 1;
    final moreSongs = await searchSongsWithPagination(_controller.text, maxPages: nextPage);
    if (!mounted) return;
    setState(() {
      final existingIds = _songResults.map((e) => e.videoId).toSet();
      final newOnes = moreSongs.where((e) => !existingIds.contains(e.videoId)).toList();
      _songResults.addAll(newOnes);
      _songPage = nextPage;
      _loadingMoreSongs = false;
      _hasMoreSongs = newOnes.isNotEmpty;
    });
  }

  Future<void> _loadMoreVideos() async {
    if (_loadingMoreVideos || !_hasMoreVideos) return;
    setState(() { _loadingMoreVideos = true; });
    final nextPage = _videoPage + 1;
    final moreVideos = await searchVideosWithPagination(_controller.text, maxPages: nextPage);
    if (!mounted) return;
    setState(() {
      final existingIds = _videoResults.map((e) => e.videoId).toSet();
      final newOnes = moreVideos.where((e) => !existingIds.contains(e.videoId)).toList();
      _videoResults.addAll(newOnes);
      _videoPage = nextPage;
      _loadingMoreVideos = false;
      _hasMoreVideos = newOnes.isNotEmpty;
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
    return Scaffold(
        appBar: AppBar(
          title: _isSelectionMode
              ? Text('${_selectedIndexes.length} ${LocaleProvider.tr('selected')}')
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
                              title: TranslatedText('info'),
                              content: TranslatedText('search_music_in_ytm'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(context).pop(),
                                  child: TranslatedText('ok'),
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
            // Barra de progreso de descarga arriba de la barra de búsqueda
            ValueListenableBuilder<bool>(
              valueListenable: isDownloadingNotifier,
              builder: (context, isDownloading, _) {
                return ValueListenableBuilder<bool>(
                  valueListenable: isProcessingNotifier,
                  builder: (context, isProcessing, _) {
                    return ValueListenableBuilder<int>(
                      valueListenable: queueLengthNotifier,
                      builder: (context, queueLength, _) {
                        if (!isDownloading && !isProcessing && queueLength == 0) return SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12, left: 16, right: 16, top: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    isProcessing ? Icons.audio_file : Icons.download,
                                    size: 20,
                                    color: Theme.of(context).colorScheme.primary,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      isProcessing
                                          ? LocaleProvider.tr('processing_audio')
                                          : LocaleProvider.tr('downloading_audio'),
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                        color: Theme.of(context).colorScheme.onSurface,
                                      ),
                                    ),
                                  ),
                                  ValueListenableBuilder<double>(
                                    valueListenable: downloadProgressNotifier,
                                    builder: (context, progress, _) => Text(
                                      '${(progress * 100).round()}%',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                        color: Theme.of(context).colorScheme.primary,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              
                              // Mostrar información de la cola si hay más de una descarga
                              if (queueLength > 0)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2, left: 28),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.queue_music,
                                        size: 12,
                                        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.8),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        LocaleProvider.tr('queue_info').replaceAll('{count}', queueLength.toString()),
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.8),
                                          fontStyle: FontStyle.italic,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              const SizedBox(height: 8),
                              ValueListenableBuilder<double>(
                                valueListenable: downloadProgressNotifier,
                                builder: (context, progress, _) => ClipRRect(
                                  borderRadius: BorderRadius.circular(8), // Barra redondeada
                                  child: LinearProgressIndicator(
                                    borderRadius: BorderRadius.circular(8),
                                    minHeight: 8, // Más gruesa y moderna
                                    value: progress,
                                    backgroundColor: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      Theme.of(context).colorScheme.primary,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                );
              },
            ),
            // Contenido principal
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: StreamBuilder<MediaItem?>(
                  stream: audioHandler?.mediaItem,
                  builder: (context, snapshot) {
                    // print('DEBUG: StreamBuilder rebuild, mediaItem: ${snapshot.data != null}');
                    final mediaItem = snapshot.data;
                    // Calcular espacio inferior considerando overlay de reproducción
                    // (ya no sumamos espacio para la barra de progreso)
                    double bottomSpace = 0.0;
                    if (mediaItem != null) {
                      bottomSpace += 85.0; // Overlay de reproducción
                    }
                    return Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: ValueListenableBuilder<String>(
                                valueListenable: languageNotifier,
                                builder: (context, lang, child) {
                                  return TextField(
                                    controller: _controller,
                                    focusNode: _focusNode,
                                    decoration: InputDecoration(
                                      suffixIcon: _controller.text.isNotEmpty
                                          ? IconButton(
                                              icon: const Icon(Icons.clear),
                                              onPressed: () {
                                                _controller.clear();
                                                _clearResults();
                                                setState(() {
                                                  _showSuggestions = true;
                                                });
                                              },
                                            )
                                          : null,
                                      labelText: LocaleProvider.tr('search_in_youtube_music'),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(
                                          8,
                                        ), // Cambiado a cuadrado
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(
                                          8,
                                        ), // Cambiado a cuadrado
                                        borderSide: const BorderSide(color: Colors.grey),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(
                                          8,
                                        ), // Cambiado a cuadrado
                                        borderSide: BorderSide(
                                          color: Theme.of(context).colorScheme.primary,
                                          width: 2,
                                        ),
                                      ),
                                    ),
                                    onChanged: (value) {
                                      setState(() {
                                        _showSuggestions = true;
                                        _noInternet = false;
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
                                        if (_controller.text.isEmpty) {
                                          _showSuggestions = true;
                                        }
                                      });
                                    },
                                  );
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              height: 56,
                              width: 56,
                              child: Material(
                                borderRadius: BorderRadius.circular(8),
                                color: Theme.of(context).colorScheme.secondaryContainer,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: _loading ? null : _search,
                                  child: ValueListenableBuilder<String>(
                                    valueListenable: languageNotifier,
                                    builder: (context, lang, child) {
                                      return Tooltip(
                                        message: LocaleProvider.tr('search'),
                                        child: Icon(
                                          Icons.search,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSecondaryContainer,
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        // SOLO UNO de estos bloques se muestra a la vez
                        if (_error != null)
                          Text(_error!, style: const TextStyle(color: Colors.red))
                        else if (_loading)
                          const Expanded(child: Center(child: CircularProgressIndicator()))
                        else if (_noInternet)
                          Expanded(
                            child: Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.wifi_off,
                                    size: 48,
                                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    LocaleProvider.tr('no_internet_connection'),
                                    style: TextStyle(
                                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                                      fontSize: 14,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ),
                            ),
                          )
                        else if (_showSuggestions && !_loading && !_hasSearched && _controller.text.isEmpty)
                          Expanded(
                            child: FutureBuilder<List<String>>(
                              future: SearchHistory.getHistory(),
                              builder: (context, snapshot) {
                                final hasHistory = snapshot.hasData && snapshot.data!.isNotEmpty;
                                if (!hasHistory) {
                                  return Center(
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          Icons.history,
                                          size: 48,
                                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          LocaleProvider.tr('no_recent_searches'),
                                          style: TextStyle(
                                            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
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
                        else if (_showSuggestions && !_loading && !_hasSearched && _controller.text.isNotEmpty)
                          Expanded(
                            child: SearchSuggestionsWidget(
                              query: _controller.text,
                              onSuggestionSelected: _onSuggestionSelected,
                              onClearHistory: _onClearHistory,
                            ),
                          )
                        else if (!_loading && (_songResults.isNotEmpty || _videoResults.isNotEmpty) && _hasSearched)
                          Expanded(
                            child: Padding(
                              padding: EdgeInsets.only(bottom: bottomSpace),
                              child: Builder(
                                builder: (context) {
                                  if (_expandedCategory == 'songs') {
                                    // Mostrar solo todas las canciones con botón de volver
                                    return Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            IconButton(
                                              icon: Icon(Icons.arrow_back),
                                              tooltip: 'Volver',
                                              onPressed: () {
                                                setState(() {
                                                  _expandedCategory = null;
                                                });
                                              },
                                            ),
                                            Text(LocaleProvider.tr('songs_search'), style: Theme.of(context).textTheme.titleMedium),
                                          ],
                                        ),
                                        Expanded(
                                          child: ListView.builder(
                                            controller: _songScrollController,
                                            itemCount: _songResults.length + (_loadingMoreSongs ? 1 : 0),
                                            itemBuilder: (context, idx) {
                                              if (_loadingMoreSongs && idx == _songResults.length) {
                                                return Container(
                                                  padding: const EdgeInsets.all(16),
                                                  child: Row(
                                                    mainAxisAlignment: MainAxisAlignment.center,
                                                    children: [
                                                      const SizedBox(
                                                        width: 20,
                                                        height: 20,
                                                        child: CircularProgressIndicator(strokeWidth: 2),
                                                      ),
                                                      const SizedBox(width: 12),
                                                      TranslatedText('loading_more', style: TextStyle(fontSize: 14)),
                                                    ],
                                                  ),
                                                );
                                              }
                                              final item = _songResults[idx];
                                              final videoId = item.videoId;
                                              final isSelected = videoId != null && _selectedIndexes.contains('song-$videoId');
                                              return GestureDetector(
                                                onLongPress: () {
                                                  HapticFeedback.selectionClick();
                                                  _toggleSelection(idx, isVideo: false);
                                                },
                                                onTap: () {
                                                  if (_isSelectionMode) {
                                                    _toggleSelection(idx, isVideo: false);
                                                  } else {
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
                                                            padding: const EdgeInsets.all(24),
                                                            child: _YtPreviewPlayer(
                                                              results: _songResults,
                                                              currentIndex: idx,
                                                            ),
                                                          ),
                                                        );
                                                      },
                                                    );
                                                  }
                                                },
                                                child: Container(
                                                  width: double.infinity,
                                                  margin: const EdgeInsets.symmetric(),
                                                  child: ListTile(
                                                    contentPadding: const EdgeInsets.symmetric(
                                                      horizontal: 0,
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
                                                                  _selectedIndexes.remove(key);
                                                                  if (_selectedIndexes.isEmpty) _isSelectionMode = false;
                                                                }
                                                              });
                                                            },
                                                          ),
                                                        ClipRRect(
                                                          borderRadius: BorderRadius.circular(8),
                                                          child: item.thumbUrl != null
                                                              ? Image.network(
                                                                  item.thumbUrl!,
                                                                  width: 56,
                                                                  height: 56,
                                                                  fit: BoxFit.cover,
                                                                )
                                                              : Container(
                                                                  width: 56,
                                                                  height: 56,
                                                                  decoration: BoxDecoration(
                                                                    color: Colors.grey[300],
                                                                    borderRadius: BorderRadius.circular(12),
                                                                  ),
                                                                  child: const Icon(
                                                                    Icons.music_note,
                                                                    size: 32,
                                                                    color: Colors.grey,
                                                                  ),
                                                                ),
                                                        ),
                                                      ],
                                                    ),
                                                    title: Text(
                                                      item.title ?? LocaleProvider.tr('title_unknown'),
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                    ),
                                                    subtitle: Text(
                                                      item.artist ?? LocaleProvider.tr('artist_unknown'),
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                    ),
                                                    trailing: IconButton(
                                                      icon: const Icon(Icons.link),
                                                      tooltip: LocaleProvider.tr('copy_link'),
                                                      onPressed: () {
                                                        Clipboard.setData(ClipboardData(
                                                            text: 'https://music.youtube.com/watch?v=${item.videoId}'));
                                                        ScaffoldMessenger.of(context).showSnackBar(
                                                          SnackBar(content: Text('Link copiado al portapapeles')),
                                                        );
                                                      },
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
                                        Row(
                                          children: [
                                            IconButton(
                                              icon: Icon(Icons.arrow_back),
                                              tooltip: 'Volver',
                                              onPressed: () {
                                                setState(() {
                                                  _expandedCategory = null;
                                                });
                                              },
                                            ),
                                            Text(LocaleProvider.tr('videos'), style: Theme.of(context).textTheme.titleMedium),
                                          ],
                                        ),
                                        Expanded(
                                          child: ListView.builder(
                                            controller: _videoScrollController,
                                            itemCount: _videoResults.length + (_loadingMoreVideos ? 1 : 0),
                                            itemBuilder: (context, idx) {
                                              if (_loadingMoreVideos && idx == _videoResults.length) {
                                                return Container(
                                                  padding: const EdgeInsets.all(16),
                                                  child: Row(
                                                    mainAxisAlignment: MainAxisAlignment.center,
                                                    children: [
                                                      const SizedBox(
                                                        width: 20,
                                                        height: 20,
                                                        child: CircularProgressIndicator(strokeWidth: 2),
                                                      ),
                                                      const SizedBox(width: 12),
                                                      TranslatedText('loading_more', style: TextStyle(fontSize: 14)),
                                                    ],
                                                  ),
                                                );
                                              }
                                              final item = _videoResults[idx];
                                              final videoId = item.videoId;
                                              final isSelected = videoId != null && _selectedIndexes.contains('video-$videoId');
                                              return GestureDetector(
                                                onLongPress: () {
                                                  HapticFeedback.selectionClick();
                                                  _toggleSelection(idx, isVideo: true);
                                                },
                                                onTap: () {
                                                  if (_isSelectionMode) {
                                                    _toggleSelection(idx, isVideo: true);
                                                  } else {
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
                                                            padding: const EdgeInsets.all(24),
                                                            child: _YtPreviewPlayer(
                                                              results: _videoResults,
                                                              currentIndex: idx,
                                                            ),
                                                          ),
                                                        );
                                                      },
                                                    );
                                                  }
                                                },
                                                child: Container(
                                                  width: double.infinity,
                                                  margin: const EdgeInsets.symmetric(),
                                                  child: ListTile(
                                                    contentPadding: const EdgeInsets.symmetric(
                                                      horizontal: 0,
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
                                                                  _selectedIndexes.remove(key);
                                                                  if (_selectedIndexes.isEmpty) _isSelectionMode = false;
                                                                }
                                                              });
                                                            },
                                                          ),
                                                        ClipRRect(
                                                          borderRadius: BorderRadius.circular(8),
                                                          child: item.thumbUrl != null
                                                              ? Image.network(
                                                                  item.thumbUrl!,
                                                                  width: 56,
                                                                  height: 56,
                                                                  fit: BoxFit.cover,
                                                                )
                                                              : Container(
                                                                  width: 56,
                                                                  height: 56,
                                                                  decoration: BoxDecoration(
                                                                    color: Colors.grey[300],
                                                                    borderRadius: BorderRadius.circular(12),
                                                                  ),
                                                                  child: const Icon(
                                                                    Icons.music_video,
                                                                    size: 32,
                                                                    color: Colors.grey,
                                                                  ),
                                                                ),
                                                        ),
                                                      ],
                                                    ),
                                                    title: Text(
                                                      item.title ?? LocaleProvider.tr('title_unknown'),
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                    ),
                                                    subtitle: Text(
                                                      item.artist ?? LocaleProvider.tr('artist_unknown'),
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                    ),
                                                    trailing: IconButton(
                                                      icon: const Icon(Icons.link),
                                                      tooltip: LocaleProvider.tr('copy_link'),
                                                      onPressed: () {
                                                        Clipboard.setData(ClipboardData(
                                                            text: 'https://music.youtube.com/watch?v=${item.videoId}'));
                                                        ScaffoldMessenger.of(context).showSnackBar(
                                                          SnackBar(content: Text('Link copiado al portapapeles')),
                                                        );
                                                      },
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
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            IconButton(
                                              icon: Icon(Icons.arrow_back),
                                              tooltip: 'Volver',
                                              onPressed: () {
                                                setState(() {
                                                  _expandedCategory = null;
                                                  _albumSongs = [];
                                                  _currentAlbum = null;
                                                });
                                              },
                                            ),
                                            if (_currentAlbum != null)
                                              ...[
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
                                                Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Text(_currentAlbum!['title'] ?? '', style: Theme.of(context).textTheme.titleMedium),
                                                    Text(_currentAlbum!['artist'] ?? '', style: Theme.of(context).textTheme.bodySmall),
                                                  ],
                                                ),
                                              ],
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        if (_loadingAlbumSongs)
                                          const Expanded(child: Center(child: CircularProgressIndicator()))
                                        else if (_albumSongs.isEmpty)
                                          Expanded(child: Center(child: TranslatedText('no_results', textAlign: TextAlign.center)))
                                        else
                                          Expanded(
                                            child: ListView.builder(
                                              itemCount: _albumSongs.length,
                                              itemBuilder: (context, idx) {
                                                final item = _albumSongs[idx];
                                                final videoId = item.videoId;
                                                final isSelected = videoId != null && _selectedIndexes.contains('album-$videoId');
                                                return GestureDetector(
                                                  onLongPress: () {
                                                    HapticFeedback.selectionClick();
                                                    if (videoId == null) return;
                                                    setState(() {
                                                      final key = 'album-$videoId';
                                                      if (_selectedIndexes.contains(key)) {
                                                        _selectedIndexes.remove(key);
                                                        if (_selectedIndexes.isEmpty) _isSelectionMode = false;
                                                      } else {
                                                        _selectedIndexes.add(key);
                                                        _isSelectionMode = true;
                                                      }
                                                    });
                                                  },
                                                  onTap: () {
                                                    if (_isSelectionMode) {
                                                      if (videoId == null) return;
                                                      setState(() {
                                                        final key = 'album-$videoId';
                                                        if (_selectedIndexes.contains(key)) {
                                                          _selectedIndexes.remove(key);
                                                          if (_selectedIndexes.isEmpty) _isSelectionMode = false;
                                                        } else {
                                                          _selectedIndexes.add(key);
                                                          _isSelectionMode = true;
                                                        }
                                                      });
                                                    } else {
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
                                                              padding: const EdgeInsets.all(24),
                                                              child: _YtPreviewPlayer(
                                                                results: _albumSongs,
                                                                currentIndex: idx,
                                                                fallbackThumbUrl: _currentAlbum?['thumbUrl'],
                                                                fallbackArtist: _currentAlbum?['artist'],
                                                              ),
                                                            ),
                                                          );
                                                        },
                                                      );
                                                    }
                                                  },
                                                  child: ListTile(
                                                    contentPadding: const EdgeInsets.symmetric(horizontal: 0, vertical: 4),
                                                    leading: Row(
                                                      mainAxisSize: MainAxisSize.min,
                                                      children: [
                                                        if (_isSelectionMode)
                                                          Checkbox(
                                                            value: isSelected,
                                                            onChanged: (checked) {
                                                              setState(() {
                                                                if (videoId == null) return;
                                                                final key = 'album-$videoId';
                                                                if (checked == true) {
                                                                  _selectedIndexes.add(key);
                                                                } else {
                                                                  _selectedIndexes.remove(key);
                                                                  if (_selectedIndexes.isEmpty) _isSelectionMode = false;
                                                                }
                                                              });
                                                            },
                                                          ),
                                                        ClipRRect(
                                                          borderRadius: BorderRadius.circular(8),
                                                          child: (item.thumbUrl != null && item.thumbUrl!.isNotEmpty)
                                                              ? Image.network(
                                                                  item.thumbUrl!,
                                                                  width: 56,
                                                                  height: 56,
                                                                  fit: BoxFit.cover,
                                                                )
                                                              : (_currentAlbum != null && _currentAlbum!['thumbUrl'] != null && (_currentAlbum!['thumbUrl'] as String).isNotEmpty)
                                                                  ? Image.network(
                                                                      _currentAlbum!['thumbUrl'],
                                                                      width: 56,
                                                                      height: 56,
                                                                      fit: BoxFit.cover,
                                                                    )
                                                                  : Container(
                                                                      width: 56,
                                                                      height: 56,
                                                                      decoration: BoxDecoration(
                                                                        color: Colors.grey[300],
                                                                        borderRadius: BorderRadius.circular(12),
                                                                      ),
                                                                      child: const Icon(
                                                                        Icons.music_note,
                                                                        size: 32,
                                                                        color: Colors.grey,
                                                                      ),
                                                                    ),
                                                        ),
                                                      ],
                                                    ),
                                                    title: Text(
                                                      item.title ?? LocaleProvider.tr('title_unknown'),
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                    ),
                                                    subtitle: Text(
                                                      (item.artist != null && item.artist!.trim().isNotEmpty)
                                                        ? item.artist!
                                                        : (_currentAlbum?['artist'] ?? LocaleProvider.tr('artist_unknown')),
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                    ),
                                                    trailing: IconButton(
                                                      icon: const Icon(Icons.link),
                                                      tooltip: LocaleProvider.tr('copy_link'),
                                                      onPressed: () {
                                                        Clipboard.setData(ClipboardData(
                                                            text: 'https://music.youtube.com/watch?v=${item.videoId}'));
                                                        ScaffoldMessenger.of(context).showSnackBar(
                                                          SnackBar(content: Text('Link copiado al portapapeles')),
                                                        );
                                                      },
                                                    ),
                                                  ),
                                                );
                                              },
                                            ),
                                          ),
                                      ],
                                    );
                                  }
                                  else {
                                    // Vista normal: resumen de ambas categorías
                                    return ListView(
                                      children: [
                                        // Sección Canciones
                                        if (_songResults.isNotEmpty)
                                          Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              InkWell(
                                                borderRadius: BorderRadius.circular(8),
                                                onTap: () {
                                                  setState(() {
                                                    _expandedCategory = 'songs';
                                                  });
                                                },
                                                child: Padding(
                                                  padding: const EdgeInsets.symmetric(vertical: 4),
                                                  child: Row(
                                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                                    children: [
                                                      Text(LocaleProvider.tr('songs_search'), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 20)),
                                                      Icon(Icons.chevron_right),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                              AnimatedSize(
                                                duration: const Duration(milliseconds: 300),
                                                curve: Curves.easeInOut,
                                                child: Column(
                                                  children: _songResults.take(3).map((item) {
                                                    final index = _songResults.indexOf(item);
                                                    final videoId = item.videoId;
                                                    final isSelected = videoId != null && _selectedIndexes.contains('song-$videoId');
                                                    return GestureDetector(
                                                      onLongPress: () {
                                                        HapticFeedback.selectionClick();
                                                        _toggleSelection(index, isVideo: false);
                                                      },
                                                      onTap: () {
                                                        if (_isSelectionMode) {
                                                          _toggleSelection(index, isVideo: false);
                                                        } else {
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
                                                                  padding: const EdgeInsets.all(24),
                                                                  child: _YtPreviewPlayer(
                                                                    results: _songResults,
                                                                    currentIndex: index,
                                                                  ),
                                                                ),
                                                              );
                                                            },
                                                          );
                                                        }
                                                      },
                                                      child: Container(
                                                        width: double.infinity,
                                                        margin: const EdgeInsets.symmetric(),
                                                        child: ListTile(
                                                          contentPadding: const EdgeInsets.symmetric(
                                                            horizontal: 0,
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
                                                                        _selectedIndexes.remove(key);
                                                                        if (_selectedIndexes.isEmpty) _isSelectionMode = false;
                                                                      }
                                                                    });
                                                                  },
                                                                ),
                                                              ClipRRect(
                                                                borderRadius: BorderRadius.circular(8),
                                                                child: item.thumbUrl != null
                                                                    ? Image.network(
                                                                        item.thumbUrl!,
                                                                        width: 56,
                                                                        height: 56,
                                                                        fit: BoxFit.cover,
                                                                      )
                                                                    : Container(
                                                                        width: 56,
                                                                        height: 56,
                                                                        decoration: BoxDecoration(
                                                                          color: Colors.grey[300],
                                                                          borderRadius: BorderRadius.circular(12),
                                                                        ),
                                                                        child: const Icon(
                                                                          Icons.music_note,
                                                                          size: 32,
                                                                          color: Colors.grey,
                                                                        ),
                                                                      ),
                                                              ),
                                                            ],
                                                          ),
                                                          title: Text(
                                                            item.title ?? LocaleProvider.tr('title_unknown'),
                                                            maxLines: 1,
                                                            overflow: TextOverflow.ellipsis,
                                                          ),
                                                          subtitle: Text(
                                                            item.artist ?? LocaleProvider.tr('artist_unknown'),
                                                            maxLines: 1,
                                                            overflow: TextOverflow.ellipsis,
                                                          ),
                                                          trailing: IconButton(
                                                            icon: const Icon(Icons.link),
                                                            tooltip: LocaleProvider.tr('copy_link'),
                                                            onPressed: () {
                                                              Clipboard.setData(ClipboardData(
                                                                  text: 'https://music.youtube.com/watch?v=${item.videoId}'));
                                                              ScaffoldMessenger.of(context).showSnackBar(
                                                                SnackBar(content: Text('Link copiado al portapapeles')),
                                                              );
                                                            },
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
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              InkWell(
                                                borderRadius: BorderRadius.circular(8),
                                                onTap: () {
                                                  setState(() {
                                                    _expandedCategory = 'videos';
                                                  });
                                                },
                                                child: Padding(
                                                  padding: const EdgeInsets.symmetric(vertical: 4),
                                                  child: Row(
                                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                                    children: [
                                                      Text(LocaleProvider.tr('videos'), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 20)),
                                                      Icon(Icons.chevron_right),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                              AnimatedSize(
                                                duration: const Duration(milliseconds: 300),
                                                curve: Curves.easeInOut,
                                                child: Column(
                                                  children: _videoResults.take(3).map((item) {
                                                    final index = _videoResults.indexOf(item);
                                                    final videoId = item.videoId;
                                                    final isSelected = videoId != null && _selectedIndexes.contains('video-$videoId');
                                                    return GestureDetector(
                                                      onLongPress: () {
                                                        HapticFeedback.selectionClick();
                                                        _toggleSelection(index, isVideo: true);
                                                      },
                                                      onTap: () {
                                                        if (_isSelectionMode) {
                                                          _toggleSelection(index, isVideo: true);
                                                        } else {
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
                                                                  padding: const EdgeInsets.all(24),
                                                                  child: _YtPreviewPlayer(
                                                                    results: _videoResults,
                                                                    currentIndex: index,
                                                                  ),
                                                                ),
                                                              );
                                                            },
                                                          );
                                                        }
                                                      },
                                                      child: Container(
                                                        width: double.infinity,
                                                        margin: const EdgeInsets.symmetric(),
                                                        child: ListTile(
                                                          contentPadding: const EdgeInsets.symmetric(
                                                            horizontal: 0,
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
                                                                        _selectedIndexes.remove(key);
                                                                        if (_selectedIndexes.isEmpty) _isSelectionMode = false;
                                                                      }
                                                                    });
                                                                  },
                                                                ),
                                                              ClipRRect(
                                                                borderRadius: BorderRadius.circular(8),
                                                                child: item.thumbUrl != null
                                                                    ? Image.network(
                                                                        item.thumbUrl!,
                                                                        width: 56,
                                                                        height: 56,
                                                                        fit: BoxFit.cover,
                                                                      )
                                                                    : Container(
                                                                        width: 56,
                                                                        height: 56,
                                                                        decoration: BoxDecoration(
                                                                          color: Colors.grey[300],
                                                                          borderRadius: BorderRadius.circular(12),
                                                                        ),
                                                                        child: const Icon(
                                                                          Icons.music_video,
                                                                          size: 32,
                                                                          color: Colors.grey,
                                                                        ),
                                                                      ),
                                                              ),
                                                            ],
                                                          ),
                                                          title: Text(
                                                            item.title ?? LocaleProvider.tr('title_unknown'),
                                                            maxLines: 1,
                                                            overflow: TextOverflow.ellipsis,
                                                          ),
                                                          subtitle: Text(
                                                            item.artist ?? LocaleProvider.tr('artist_unknown'),
                                                            maxLines: 1,
                                                            overflow: TextOverflow.ellipsis,
                                                          ),
                                                          trailing: IconButton(
                                                            icon: const Icon(Icons.link),
                                                            tooltip: LocaleProvider.tr('copy_link'),
                                                            onPressed: () {
                                                              Clipboard.setData(ClipboardData(
                                                                  text: 'https://music.youtube.com/watch?v=${item.videoId}'));
                                                              ScaffoldMessenger.of(context).showSnackBar(
                                                                SnackBar(content: Text('Link copiado al portapapeles')),
                                                              );
                                                            },
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
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Padding(
                                                padding: const EdgeInsets.symmetric(vertical: 4),
                                                child: Text(LocaleProvider.tr('albums'), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 20)),
                                              ),
                                              ..._albumResults.map((item) {
                                                YtMusicResult album;
                                                if (item is YtMusicResult) {
                                                  album = item;
                                                } else if (item is Map) {
                                                  final map = item as Map<String, dynamic>;
                                                  album = YtMusicResult(
                                                    title: map['title'] as String?,
                                                    artist: map['artist'] as String?,
                                                    thumbUrl: map['thumbUrl'] as String?,
                                                    videoId: map['browseId'] as String?,
                                                  );
                                                } else {
                                                  album = YtMusicResult();
                                                }
                                                return ListTile(
                                                  contentPadding: const EdgeInsets.symmetric(horizontal: 0, vertical: 4),
                                                  leading: album.thumbUrl != null
                                                      ? ClipRRect(
                                                          borderRadius: BorderRadius.circular(8),
                                                          child: Image.network(
                                                            album.thumbUrl!,
                                                            width: 56,
                                                            height: 56,
                                                            fit: BoxFit.cover,
                                                          ),
                                                        )
                                                      : Container(
                                                          width: 56,
                                                          height: 56,
                                                          decoration: BoxDecoration(
                                                            color: Colors.grey[300],
                                                            borderRadius: BorderRadius.circular(12),
                                                          ),
                                                          child: const Icon(
                                                            Icons.album,
                                                            size: 32,
                                                            color: Colors.grey,
                                                          ),
                                                        ),
                                                  title: Text(album.title ?? LocaleProvider.tr('title_unknown'),
                                                      maxLines: 1, overflow: TextOverflow.ellipsis),
                                                  subtitle: Text(album.artist ?? LocaleProvider.tr('artist_unknown'),
                                                      maxLines: 1, overflow: TextOverflow.ellipsis),
                                                  onTap: () async {
                                                    if (album.videoId == null) return;
                                                    setState(() {
                                                      _expandedCategory = 'album';
                                                      _loadingAlbumSongs = true;
                                                      _albumSongs = [];
                                                      _currentAlbum = {
                                                        'title': album.title,
                                                        'artist': album.artist,
                                                        'thumbUrl': album.thumbUrl,
                                                      };
                                                    });
                                                    final songs = await getAlbumSongs(album.videoId!);
                                                    if (!mounted) return;
                                                    setState(() {
                                                      _albumSongs = songs;
                                                      _loadingAlbumSongs = false;
                                                    });
                                                  },
                                                );
                                              }),
                                            ],
                                          ),
                                      ],
                                    );
                                  }
                                },
                              ),
                            ),
                          ),
                        if (!_loading && _hasSearched && _songResults.isEmpty && _videoResults.isEmpty && _error == null)
                          Expanded(child: Center(child: TranslatedText('no_results', textAlign: TextAlign.center))),

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
}

class _YtPreviewPlayer extends StatefulWidget {
  final List<YtMusicResult> results;
  final int currentIndex;
  final String? fallbackThumbUrl;
  final String? fallbackArtist;
  const _YtPreviewPlayer({required this.results, required this.currentIndex, this.fallbackThumbUrl, this.fallbackArtist});

  @override
  State<_YtPreviewPlayer> createState() => _YtPreviewPlayerState();
}

class _YtPreviewPlayerState extends State<_YtPreviewPlayer> {
  final AudioPlayer _player = AudioPlayer();
  bool _loading = false;
  bool _playing = false;
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
        _playing = state.playing && state.processingState != ProcessingState.completed;
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
      // No cargar nada hasta que el usuario presione play
    }
  }

  Future<void> _loadAndPlay() async {
    _loadToken++;
    final int thisLoad = _loadToken;
    setState(() { _loading = true; });
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
    final List<ConnectivityResult> connectivityResult = await Connectivity().checkConnectivity();
    if (connectivityResult.contains(ConnectivityResult.none)) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Error'),
          content: Text(LocaleProvider.tr('no_internet_retry')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      setState(() { _loading = false; });
      return;
    }
    // Si ya tenemos la URL y duración, solo reproducir
    if (_audioUrl != null && _duration != null) {
      setState(() { _playing = true; _loading = false; });
      await _player.play();
      return;
    }
    try {
      if (audioHandler?.playbackState.value.playing ?? false) {
        await audioHandler?.pause();
      }
      final yt = YoutubeExplode();
      final manifest = await yt.videos.streamsClient.getManifest(_currentItem.videoId!);
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
      final audio = manifest.audioOnly
        .where((s) => s.codec.mimeType == 'audio/mp4' || s.codec.toString().contains('mp4a'))
        .toList()
        ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
      final audioStreamInfo = audio.isNotEmpty ? audio.first : null;
      if (audioStreamInfo == null) throw Exception('No se encontró stream de audio válido.');
      _audioUrl = audioStreamInfo.url.toString();
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
      setState(() { _playing = true; _loading = false; });
      await _player.play();
    } catch (e) {
      if (!mounted) return;
      setState(() { _playing = false; _loading = false; });
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Error'),
          content: Text('Error al reproducir el preview de la canción'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _pause() async {
    await _player.pause();
    if (!mounted) return;
    setState(() { _playing = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainer,
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 0),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
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
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: (_currentItem.thumbUrl != null && _currentItem.thumbUrl!.isNotEmpty)
                          ? Image.network(
                              _currentItem.thumbUrl!,
                              width: 64,
                              height: 64,
                              fit: BoxFit.cover,
                            )
                          : (widget.fallbackThumbUrl != null && widget.fallbackThumbUrl!.isNotEmpty)
                              ? Image.network(
                                  widget.fallbackThumbUrl!,
                                  width: 64,
                                  height: 64,
                                  fit: BoxFit.cover,
                                )
                              : Container(
                                  width: 64,
                                  height: 64,
                                  color: Colors.grey[300],
                                  child: const Icon(
                                    Icons.music_note,
                                    size: 32,
                                    color: Colors.grey,
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
                            const SizedBox(width: 12),
                            SizedBox(
                              height: 50,
                              width: 50,
                              child: Material(
                                color: _isAmoled(context)
                                    ? Theme.of(context).colorScheme.primaryContainer
                                    : Theme.of(context).colorScheme.secondaryContainer,
                                borderRadius: BorderRadius.circular(8),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: _currentItem.videoId != null
                                      ? () {
                                          Clipboard.setData(ClipboardData(
                                              text:
                                                  'https://music.youtube.com/watch?v=${_currentItem.videoId}'));
                                          // Navigator.pop(context); // Ya no cerramos el modal al copiar el link
                                        }
                                      : null,
                                  child: Tooltip(
                                    message: LocaleProvider.tr('copy_link'),
                                    child: Icon(
                                      Icons.link,
                                      color: _isAmoled(context)
                                          ? Theme.of(context).colorScheme.onPrimaryContainer
                                          : Theme.of(context).colorScheme.onSecondaryContainer,
                                      size: 20,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
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
                            _currentItem.title ?? LocaleProvider.tr('title_unknown'),
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            (_currentItem.artist != null && _currentItem.artist!.trim().isNotEmpty)
                              ? _currentItem.artist!
                              : (widget.fallbackArtist ?? LocaleProvider.tr('artist_unknown')),
                            style: const TextStyle(
                              fontSize: 15,
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
                // Play/Pause
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: _loading
                      ? Center(
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                _isAmoled(context)
                                    ? Colors.black
                                    : Theme.of(context).colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                        )
                      : IconButton(
                          icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                          color: Theme.of(context).colorScheme.onPrimaryContainer,
                          tooltip: _playing ? LocaleProvider.tr('pause_preview') : LocaleProvider.tr('play_preview'),
                          splashColor: Colors.transparent,
                          onPressed: _loading
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
                  icon: const Icon(Icons.skip_previous),
                  onPressed: (!_loading && _currentIndex > 0) ? _playPrevious : null,
                ),
                // Botón siguiente
                IconButton(
                  icon: const Icon(Icons.skip_next),
                  onPressed: (!_loading && _currentIndex < widget.results.length - 1) ? _playNext : null,
                ),
              ],
            ),
            // Barra de progreso SIEMPRE visible
            const SizedBox(height: 8),
            StreamBuilder<Duration>(
              stream: _player.positionStream,
              builder: (context, snapshot) {
                if (_duration == null) {
                  return LinearProgressIndicator(
                    value: 0.0,
                    minHeight: 6,
                    backgroundColor: Theme.of(context).colorScheme.outline.withValues(alpha: 0.15),
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Theme.of(context).colorScheme.primary,
                    ),
                  );
                }
                final pos = snapshot.data ?? Duration.zero;
                final progress = _duration!.inMilliseconds > 0
                    ? pos.inMilliseconds / _duration!.inMilliseconds
                    : 0.0;
                return LinearProgressIndicator(
                  borderRadius: BorderRadius.circular(8),
                  value: progress.clamp(0.0, 1.0),
                  minHeight: 6,
                  backgroundColor: Theme.of(context).colorScheme.outline.withValues(alpha: 0.15),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    Theme.of(context).colorScheme.primary,
                  ),
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
}

// Helper para detectar tema AMOLED
bool _isAmoled(BuildContext context) {
  return colorSchemeNotifier.value == AppColorScheme.amoled;
}
