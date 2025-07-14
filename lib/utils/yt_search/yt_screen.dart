import 'dart:ui';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:music/main.dart';
import 'package:music/utils/yt_search/service.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/simple_yt_download.dart';
import 'package:music/utils/yt_search/search_history.dart';
import 'package:music/utils/yt_search/suggestions_widget.dart';

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
  List<YtMusicResult> _results = [];
  bool _loading = false;
  bool _loadingMore = false;
  String? _error;
  double _lastViewInset = 0;
  bool _hasSearched = false;
  bool _isSearchCancelled = false;
  bool _showSuggestions = false;

  // ValueNotifiers para el progreso de descarga
  final ValueNotifier<double> downloadProgressNotifier = ValueNotifier(0.0);
  final ValueNotifier<bool> isDownloadingNotifier = ValueNotifier(false);
  final ValueNotifier<bool> isProcessingNotifier = ValueNotifier(false);
  final ValueNotifier<int> queueLengthNotifier = ValueNotifier(0);


  Future<void> _search() async {
    if (_controller.text.trim().isEmpty) {
      return;
    }
    _focusNode.unfocus(); // Quita el focus del TextField
    _isSearchCancelled = false;
    
    // Guardar en el historial
    await SearchHistory.addToHistory(_controller.text.trim());
    
    setState(() {
      _loading = true;
      _results = [];
      _error = null;
      _hasSearched = true;
      _loadingMore = false;
      _showSuggestions = false;
    });
    // print('DEBUG: After search setState, _hasSearched: $_hasSearched');

    try {
      // Primero obtener los primeros 20 resultados rápidamente
      final initialResults = await searchSongsOnly(_controller.text);

      setState(() {
        _results = List<YtMusicResult>.from(initialResults);
        _loading = false;
      });

      // Luego cargar más resultados en segundo plano
      if (initialResults.length >= 20 && !_isSearchCancelled) {
        setState(() {
          _loadingMore = true;
        });

        try {
          final moreResults = await searchSongsWithPagination(_controller.text, maxPages: 5);
          if (!_isSearchCancelled) {
            setState(() {
              _results = List<YtMusicResult>.from(moreResults);
              _loadingMore = false;
            });
          }
        } catch (e) {
          // print('Error cargando más resultados: $e');
          if (!_isSearchCancelled) {
            setState(() {
              _loadingMore = false;
            });
          }
        }
      }
    } catch (e) {
      setState(() {
        _error = 'Error: $e';
        _loading = false;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Mostrar sugerencias por defecto
    _showSuggestions = true;

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
    // print('DEBUG: _clearResults() called');
    _isSearchCancelled = true;
    setState(() {
      _results = [];
      _error = null;
      _hasSearched = false;
      _loading = false;
      _loadingMore = false;
      _showSuggestions = true;
    });
    // print('DEBUG: After _clearResults(), _hasSearched: $_hasSearched');
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


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.search, size: 28),
            const SizedBox(width: 8),
            TranslatedText('search'),
          ],
        ),
        actions: [
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
                stream: audioHandler.mediaItem,
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
                if (_error != null)
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                if (_loading)
                  const Expanded(child: Center(child: CircularProgressIndicator())),
                if (_showSuggestions && !_loading && !_hasSearched && _controller.text.isEmpty)
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
                  ),
                if (_showSuggestions && !_loading && !_hasSearched && _controller.text.isNotEmpty)
                  Expanded(
                    child: SearchSuggestionsWidget(
                      query: _controller.text,
                      onSuggestionSelected: _onSuggestionSelected,
                      onClearHistory: _onClearHistory,
                    ),
                  ),
                if (!_loading && _results.isNotEmpty && _hasSearched)
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(bottom: bottomSpace),
                      child: ListView.builder(
                        itemCount: _results.length + (_loadingMore ? 1 : 0),
                        itemBuilder: (context, index) {
                          // Mostrar indicador de carga al final
                          if (_loadingMore && index == _results.length) {
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
                                  TranslatedText('loading_more',
                                    style: TextStyle(fontSize: 14),
                                  ),
                                ],
                              ),
                            );
                          }
                          final item = _results[index];
                          return Container(
                            width: double.infinity,
                            margin: const EdgeInsets.symmetric(),
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 0,
                                vertical: 4,
                              ),
                              leading: item.thumbUrl != null
                                  ? ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: Image.network(
                                        item.thumbUrl!,
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
                                        Icons.music_note,
                                        size: 32,
                                        color: Colors.grey,
                                      ),
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
                              onTap: () {
                                showModalBottomSheet(
                                  context: context,
                                  shape: const RoundedRectangleBorder(
                                    borderRadius: BorderRadius.vertical(
                                      top: Radius.circular(16),
                                    ),
                                  ),
                                  builder: (context) {
                                    // final url = item.videoId != null
                                    //     ? 'https://music.youtube.com/watch?v=${item.videoId}'
                                    //     : null;
                                    return SafeArea(
                                      child: Padding(
                                        padding: const EdgeInsets.all(24),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Row(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.center,
                                              children: [
                                                ClipRRect(
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                    12,
                                                  ),
                                                  child: item.thumbUrl != null
                                                      ? Image.network(
                                                          item.thumbUrl!,
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
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment.start,
                                                    mainAxisAlignment:
                                                        MainAxisAlignment.center,
                                                    children: [
                                                      Text(
                                                        item.title ?? LocaleProvider.tr('title_unknown'),
                                                        style: const TextStyle(
                                                          fontWeight:
                                                              FontWeight.bold,
                                                          fontSize: 18,
                                                        ),
                                                        maxLines: 1,
                                                        overflow:
                                                            TextOverflow.ellipsis,
                                                      ),
                                                      const SizedBox(height: 4),
                                                      Text(
                                                        item.artist ?? LocaleProvider.tr('artist_unknown'),
                                                        style: TextStyle(
                                                          fontSize: 15,
                                                        ),
                                                        maxLines: 1,
                                                        overflow:
                                                            TextOverflow.ellipsis,
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                // Botón de descargar
                                                SimpleDownloadButton(
                                                  item: item,
                                                ),
                                              ],
                                            ),

                                          ],
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
                if (!_loading && _results.isEmpty && _error == null && _hasSearched)
                  Expanded(child: Center(child: TranslatedText('no_results', textAlign: TextAlign.center))),

                ],
              );
            },
          ),
        ),
          ),
        ],
      ),
    );
  }
}
