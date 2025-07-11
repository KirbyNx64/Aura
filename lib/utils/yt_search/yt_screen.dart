import 'dart:ui';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:music/main.dart';
import 'package:music/utils/yt_search/service.dart';

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

  Future<void> _search() async {
    if (_controller.text.trim().isEmpty) {
      return;
    }
    _focusNode.unfocus(); // Quita el focus del TextField
    _isSearchCancelled = false;
    setState(() {
      _loading = true;
      _results = [];
      _error = null;
      _hasSearched = true;
      _loadingMore = false;
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
    });
    // print('DEBUG: After _clearResults(), _hasSearched: $_hasSearched');
  }

  @override
  Widget build(BuildContext context) {
    // print('DEBUG: build() called, _hasSearched: $_hasSearched, text: "${_controller.text}", loading: $_loading, results: ${_results.length}, error: $_error');
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.search, size: 28),
            const SizedBox(width: 8),
            const Text('Buscar'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline, size: 28),
            tooltip: 'Información',
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Información'),
                  content: const Text(
                    'Busca música en YouTube Music, copia enlaces de canciones.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Entendido'),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: StreamBuilder<MediaItem?>(
          stream: audioHandler.mediaItem,
          builder: (context, snapshot) {
            // print('DEBUG: StreamBuilder rebuild, mediaItem: ${snapshot.data != null}');
            final mediaItem = snapshot.data;
            final double bottomSpace = mediaItem != null ? 85.0 : 0.0;
            return Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        decoration: InputDecoration(
                          suffixIcon: _controller.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear),
                                  onPressed: () {
                                    _controller.clear();
                                    _clearResults();
                                  },
                                )
                              : null,
                          labelText: 'Buscar en YouTube Music',
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
                        onSubmitted: (_) => _search(),
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
                          child: Tooltip(
                            message: 'Buscar',
                            child: Icon(
                              Icons.search,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSecondaryContainer,
                            ),
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
                if (!_loading && _results.isNotEmpty && _controller.text.isNotEmpty && _hasSearched)
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
                                  Text(
                                    'Cargando más resultados...',
                                      style: TextStyle(
                                        fontSize: 14,
                                      ),
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
                                item.title ?? 'Sin título',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                item.artist ?? 'Sin artista',
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
                                    final url = item.videoId != null
                                        ? 'https://music.youtube.com/watch?v=${item.videoId}'
                                        : null;
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
                                                        item.title ?? 'Sin título',
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
                                                        item.artist ?? 'Sin artista',
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
                                                SizedBox(
                                                  height: 50,
                                                  width: 50,
                                                  child: Material(
                                                    color: Theme.of(
                                                      context,
                                                    ).colorScheme.secondaryContainer,
                                                    borderRadius:
                                                        BorderRadius.circular(8),
                                                    child: InkWell(
                                                      borderRadius:
                                                          BorderRadius.circular(8),
                                                      onTap: url != null
                                                          ? () {
                                                              Clipboard.setData(
                                                                ClipboardData(
                                                                  text: url,
                                                                ),
                                                              );
                                                              Navigator.pop(context);
                                                            }
                                                          : null,
                                                      child: Tooltip(
                                                        message: 'Copiar enlace',
                                                        child: Icon(
                                                          Icons.link,
                                                          color: Theme.of(context)
                                                              .colorScheme
                                                              .onSecondaryContainer,
                                                          size: 20,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
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
                if (!_loading && _results.isEmpty && _error == null && _hasSearched && _controller.text.isNotEmpty)
                  Expanded(child: Center(child: const Text('Sin resultados'))),
                if (!_loading && _results.isEmpty && _error == null && !_hasSearched)
                  Expanded(
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.search,
                            size: 80,
                            color: Colors.grey[400],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Busca música en YouTube Music',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              color: Colors.grey[600],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Escribe el nombre de una canción o artista',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[500],
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
