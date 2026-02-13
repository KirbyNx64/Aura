import 'package:flutter/material.dart';
import 'package:music/widgets/sliding_up_panel/sliding_up_panel.dart';
import 'package:audio_service/audio_service.dart';
import 'package:music/main.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:mini_music_visualizer/mini_music_visualizer.dart';
import 'package:music/widgets/title_marquee.dart';
import 'package:music/widgets/artwork_list_tile.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'dart:io';
import 'dart:math';

class CurrentPlaylistScreen extends StatefulWidget {
  final List<MediaItem> queue;
  final MediaItem? currentMediaItem;
  final int currentIndex;

  const CurrentPlaylistScreen({
    super.key,
    required this.queue,
    required this.currentMediaItem,
    required this.currentIndex,
    this.onClose,
    this.scrollController,
    this.panelController,
  });

  final VoidCallback? onClose;
  final ScrollController? scrollController;
  final PanelController? panelController;

  @override
  State<CurrentPlaylistScreen> createState() => _CurrentPlaylistScreenState();
}

class _CurrentPlaylistScreenState extends State<CurrentPlaylistScreen>
    with WidgetsBindingObserver {
  late final ScrollController _scrollController;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  bool _isShuffling = false;
  String _searchQuery = '';
  double _lastBottomInset = 0.0;

  /// Verifica si la carátula está en el caché del audio handler
  Uri? _getCachedArtwork(String songPath) {
    final cache = artworkCache;
    final cached = cache[songPath];
    return cached;
  }

  /// Carga carátula de forma asíncrona si no está en cache (para playlist)
  void _loadArtworkAsync(int songId, String songPath) {
    // Cargar de forma asíncrona usando el sistema unificado
    getOrCacheArtwork(songId, songPath)
        .then((artUri) {
          if (artUri != null && mounted) {
            // Forzar rebuild para mostrar la carátula cargada
            setState(() {});
          }
        })
        .catchError((error) {
          // print('❌ Error cargando carátula en playlist: $error');
        });
  }

  @override
  void initState() {
    super.initState();
    _scrollController = widget.scrollController ?? ScrollController();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    final bottomInset = View.of(context).viewInsets.bottom;
    if (_lastBottomInset > 0.0 && bottomInset == 0.0) {
      if (mounted && _searchFocusNode.hasFocus) {
        _searchFocusNode.unfocus();
      }
    }
    _lastBottomInset = bottomInset;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.scrollController == null) {
      _scrollController.dispose();
    }
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Widget _buildCurrentSongArtwork(MediaItem mediaItem) {
    final artUri = mediaItem.artUri;
    if (artUri != null) {
      final scheme = artUri.scheme.toLowerCase();

      // Si es un archivo local
      if (scheme == 'file' || scheme == 'content') {
        try {
          return Image.file(
            File(artUri.toFilePath()),
            width: 50,
            height: 50,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              return _buildFallbackIcon();
            },
          );
        } catch (e) {
          return _buildFallbackIcon();
        }
      }
      // Si es una URL remota
      else if (scheme == 'http' || scheme == 'https') {
        return Image.network(
          artUri.toString(),
          width: 50,
          height: 50,
          fit: BoxFit.cover,
          cacheWidth: 200,
          cacheHeight: 200,
          errorBuilder: (context, error, stackTrace) {
            return _buildFallbackIcon();
          },
        );
      }
    }

    // Si no hay artUri o no se puede cargar, verificar caché primero
    final songId = mediaItem.extras?['songId'];
    final songPath = mediaItem.extras?['data'];

    if (songId != null && songPath != null) {
      // Verificar si está en caché primero
      final cachedArtwork = _getCachedArtwork(songPath);
      if (cachedArtwork != null) {
        return Image.file(
          File(cachedArtwork.toFilePath()),
          width: 50,
          height: 50,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            return _buildFallbackIcon();
          },
        );
      } else {
        // Si no está en cache, cargar de forma asíncrona
        _loadArtworkAsync(songId, songPath);
      }

      // Si no está en caché, cargar desde la base de datos
      return FutureBuilder<Uri?>(
        future: getOrCacheArtwork(songId, songPath),
        builder: (context, snapshot) {
          if (snapshot.hasData && snapshot.data != null) {
            return Image.file(
              File(snapshot.data!.toFilePath()),
              width: 50,
              height: 50,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) {
                return _buildFallbackIcon();
              },
            );
          }
          return _buildFallbackIcon();
        },
      );
    }

    return _buildFallbackIcon();
  }

  Widget _buildFallbackIcon() {
    final isSystem = colorSchemeNotifier.value == AppColorScheme.system;
    return Container(
      width: 50,
      height: 50,
      decoration: BoxDecoration(
        color: isSystem
            ? Theme.of(
                context,
              ).colorScheme.secondaryContainer.withValues(alpha: 0.5)
            : Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        Icons.music_note,
        size: 25,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Current Song Info and Search Bar (from original header)
            Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) {
                // Force panel dragging mode when touching header
                widget.panelController?.setScrollingEnabled(false);
              },
              onPointerUp: (_) {
                // Re-enable scrolling mode when releasing, but scheduled to allow fling calculation
                Future.delayed(const Duration(milliseconds: 300), () {
                  if (mounted) {
                    widget.panelController?.setScrollingEnabled(true);
                  }
                });
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 0,
                ),
                child: Column(
                  children: [
                    // Información de la canción actual
                    if (widget.currentMediaItem != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12.0),
                        child: Row(
                          children: [
                            // Carátula de la canción actual
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: SizedBox(
                                width: 54,
                                height: 54,
                                child: _buildCurrentSongArtwork(
                                  widget.currentMediaItem!,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            // Título y artista de la canción actual
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  TitleMarquee(
                                    text: widget.currentMediaItem!.title,
                                    maxWidth:
                                        MediaQuery.of(context).size.width - 150,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),

                                  Text(
                                    widget.currentMediaItem!.artist ??
                                        LocaleProvider.tr('unknown_artist'),
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.color
                                          ?.withValues(alpha: 1),
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            // Ícono de aleatorio
                            InkWell(
                              onTap: _isShuffling
                                  ? null
                                  : () async {
                                      if (widget.queue.isNotEmpty &&
                                          !_isShuffling) {
                                        setState(() {
                                          _isShuffling = true;
                                        });

                                        final random = Random();
                                        final randomIndex = random.nextInt(
                                          widget.queue.length,
                                        );
                                        audioHandler?.skipToQueueItem(
                                          randomIndex,
                                        );

                                        // Delay de 500ms antes de permitir otro toque
                                        await Future.delayed(
                                          const Duration(milliseconds: 500),
                                        );

                                        if (mounted) {
                                          setState(() {
                                            _isShuffling = false;
                                          });
                                        }
                                      }
                                    },
                              borderRadius: BorderRadius.circular(20),
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                child: Icon(
                                  Icons.shuffle_rounded,
                                  size: 32,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface,
                                  weight: 600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                    // Barra de búsqueda con el mismo estilo de favorites
                    Builder(
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
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          cursorColor: Theme.of(context).colorScheme.primary,
                          decoration: InputDecoration(
                            hintText: LocaleProvider.tr(
                              'search_by_title_or_artist',
                            ),
                            hintStyle: TextStyle(
                              color: isAmoled
                                  ? Colors.white.withAlpha(160)
                                  : Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                              fontSize: 15,
                            ),
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: _searchQuery.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.close),
                                    onPressed: () {
                                      _searchController.clear();
                                      setState(() => _searchQuery = '');
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
                            setState(() => _searchQuery = value.toLowerCase());
                          },
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 8),

            Expanded(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) {
                  // Explicitly enable scrolling mode when touching the list area
                  widget.panelController?.setScrollingEnabled(true);
                },
                child: Builder(
                  builder: (context) {
                    // Filtrar la cola según la búsqueda
                    final filteredQueue = _searchQuery.isEmpty
                        ? widget.queue
                        : widget.queue.where((item) {
                            final title = item.title.toLowerCase();
                            final artist = (item.artist ?? '').toLowerCase();
                            return title.contains(_searchQuery) ||
                                artist.contains(_searchQuery);
                          }).toList();

                    return ListView.builder(
                      controller: _scrollController,
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.only(
                        top: 8,
                        bottom: MediaQuery.of(context).padding.bottom,
                      ),
                      itemCount: filteredQueue.length,
                      itemBuilder: (context, index) {
                        final item = filteredQueue[index];
                        // Encontrar el índice real en la cola original para skipToQueueItem
                        final realIndex = widget.queue.indexOf(item);
                        final isCurrent =
                            item.id == widget.currentMediaItem?.id;
                        final isAmoledTheme =
                            colorSchemeNotifier.value == AppColorScheme.amoled;
                        final songId = item.extras?['songId'] ?? 0;
                        final songPath = item.extras?['data'] ?? '';

                        // Agregar padding adicional al primer y último elemento para evitar recorte
                        // Ya no es tan necesario como en el modal, pero ayuda visualmente
                        // final isFirstItem = index == 0;
                        // final isLastItem = index == filteredQueue.length - 1;

                        // Variables para diseño Material3
                        final isDark =
                            Theme.of(context).brightness == Brightness.dark;
                        final cardColor = isAmoledTheme
                            ? Colors.white.withAlpha(20)
                            : isDark
                            ? Theme.of(
                                context,
                              ).colorScheme.secondary.withValues(alpha: 0.06)
                            : Theme.of(
                                context,
                              ).colorScheme.secondary.withValues(alpha: 0.07);

                        // Calcular borderRadius según posición
                        final bool isFirst = index == 0;
                        final bool isLast =
                            index ==
                            filteredQueue.length -
                                1; // Usando filteredQueue.length aquí porque es lo que se muestra
                        final bool isOnly = filteredQueue.length == 1;

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
                          key: ValueKey(
                            item.id,
                          ), // Key única para evitar intercambio de carátulas
                          padding: EdgeInsets.only(
                            left: 16,
                            right: 16,
                            top: isFirst ? 4.0 : 0.0,
                            bottom: isLast ? 20.0 : 4.0,
                          ),
                          child: Card(
                            color: isCurrent
                                ? Theme.of(context).colorScheme.primary
                                      .withAlpha(isDark ? 40 : 25)
                                : cardColor,
                            margin: EdgeInsets.zero,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: borderRadius,
                            ),
                            child: ClipRRect(
                              borderRadius: borderRadius,
                              child: ListTile(
                                leading: ArtworkListTile(
                                  songId: songId,
                                  songPath: songPath,
                                  artUri: item.artUri,
                                  size: 48,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                title: Row(
                                  children: [
                                    if (isCurrent)
                                      StreamBuilder<PlaybackState>(
                                        stream: audioHandler?.playbackState,
                                        builder: (context, snapshot) {
                                          final playing =
                                              snapshot.data?.playing ?? false;
                                          return Padding(
                                            padding: const EdgeInsets.only(
                                              right: 8.0,
                                            ),
                                            child: MiniMusicVisualizer(
                                              color: isAmoledTheme
                                                  ? Colors.white
                                                  : Theme.of(
                                                      context,
                                                    ).colorScheme.primary,
                                              width: 4,
                                              height: 15,
                                              radius: 4,
                                              animate: playing,
                                            ),
                                          );
                                        },
                                      ),
                                    Expanded(
                                      child: Text(
                                        item.title,
                                        maxLines: 1,
                                        style: TextStyle(
                                          fontWeight: isCurrent
                                              ? FontWeight.bold
                                              : Theme.of(context)
                                                    .textTheme
                                                    .titleMedium
                                                    ?.fontWeight,
                                          color: isCurrent
                                              ? (isAmoledTheme
                                                    ? Colors.white
                                                    : Theme.of(
                                                        context,
                                                      ).colorScheme.primary)
                                              : null,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                                subtitle: Text(
                                  item.artist ??
                                      LocaleProvider.tr('unknown_artist'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: isCurrent
                                        ? (isAmoledTheme
                                              ? Colors.white
                                              : Theme.of(
                                                  context,
                                                ).colorScheme.primary)
                                        : null,
                                  ),
                                ),
                                tileColor: Colors.transparent,
                                splashColor: Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.1),
                                onTap: () {
                                  audioHandler?.skipToQueueItem(realIndex);
                                },
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
