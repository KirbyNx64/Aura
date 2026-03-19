import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
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
import 'package:music/widgets/scrollable_positioned_list/scrollable_positioned_list.dart'
    as spl;
import 'dart:io';

import 'package:music/utils/theme_controller.dart';

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
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  bool _didResolveInitialIndex = false;
  int _initialVisibleIndex = 0;
  bool _isListReady = false;

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
    getOrCacheArtwork(songId, songPath)
        .then((artUri) {
          if (artUri != null && mounted) {
            setState(() {});
          }
        })
        .catchError((error) {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Deja que la pantalla termine su apertura y luego renderiza la lista.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;
      setState(() {
        _isListReady = true;
      });
    });
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
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Color normalizePaletteColor(Color color) {
    final hsl = HSLColor.fromColor(color);
    // Si la saturación original es muy baja (gris/blanco/negro), mantenerla baja
    // para evitar colorear artificialmente imágenes en escala de grises.
    final isGrayscale = hsl.saturation < 0.15;

    // Si es muy oscuro (negro), forzar un poco de luminosidad para que se vea
    double effectiveLightness = hsl.lightness;
    if (effectiveLightness < 0.15) {
      effectiveLightness = 0.15;
    }

    // Ajustar el brillo: bajamos el rango para que el color sea más "rico"
    // y no se vea pálido (pastel), permitiendo que la saturación resalte.
    // Brillo dinámico: Si el color original es muy oscuro, le damos un pequeño boost
    // para que se note. Si es muy claro, lo oscurecemos para que no se vea pálido.
    double targetLightness;
    if (hsl.lightness < 0.2) {
      // Colores muy oscuros: subirlos un poco menos (0.18 - 0.28)
      targetLightness = 0.18 + (hsl.lightness * 0.5);
    } else if (hsl.lightness > 0.5) {
      // Colores muy claros: bajarlos más (0.3 - 0.4)
      targetLightness = 0.3 + (hsl.lightness * 0.1);
    } else {
      // Colores medios: rango más bajo
      targetLightness = hsl.lightness.clamp(0.2, 0.4);
    }

    final fixedLightness = targetLightness.clamp(0.15, 0.36);

    // Saturación extrema mantenida para que el color explote
    final fixedSaturation = isGrayscale
        ? hsl.saturation
        : (hsl.saturation * 1.7).clamp(0.8, 1.0);

    return hsl
        .withLightness(fixedLightness)
        .withSaturation(fixedSaturation)
        .toColor();
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

  String? _extractVideoIdFromMediaItem(MediaItem mediaItem) {
    final rawExtraVideoId = mediaItem.extras?['videoId']?.toString().trim();
    if (rawExtraVideoId != null && rawExtraVideoId.isNotEmpty) {
      return rawExtraVideoId;
    }

    final rawId = mediaItem.id.trim();
    if (rawId.startsWith('yt:')) {
      final id = rawId.substring(3).trim();
      return id.isNotEmpty ? id : null;
    }

    final uri = Uri.tryParse(rawId);
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
    if (idLike.hasMatch(rawId)) {
      return rawId;
    }

    return null;
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

  Uri? _displayArtUriFor(MediaItem mediaItem) {
    if (mediaItem.extras?['isStreaming'] == true) {
      final videoId = _extractVideoIdFromMediaItem(mediaItem);
      final preferred = mediaItem.extras?['displayArtUri']?.toString().trim();
      final fallback = mediaItem.artUri?.toString().trim();

      final normalized = _applyStreamingArtworkQuality(
        preferred?.isNotEmpty == true ? preferred : fallback,
        videoId: videoId,
      );
      if (normalized != null && normalized.isNotEmpty) {
        final parsed = Uri.tryParse(normalized);
        if (parsed != null) return parsed;
      }
    }
    return mediaItem.artUri;
  }

  Widget _buildCurrentSongArtwork(MediaItem mediaItem) {
    final artUri = _displayArtUriFor(mediaItem);
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
            alignment: Alignment.center,
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
        return CachedNetworkImage(
          imageUrl: artUri.toString(),
          width: 50,
          height: 50,
          fit: BoxFit.cover,
          alignment: Alignment.center,
          fadeInDuration: Duration.zero,
          fadeOutDuration: Duration.zero,
          placeholder: (context, url) => _buildFallbackIcon(),
          memCacheWidth: 200,
          errorWidget: (context, url, error) => _buildFallbackIcon(),
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
          alignment: Alignment.center,
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
              alignment: Alignment.center,
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
    // final isSystem = colorSchemeNotifier.value == AppColorScheme.system;
    return Container(
      width: 50,
      height: 50,
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(Icons.music_note, size: 25, color: Colors.transparent),
    );
  }

  int? _resolveCurrentQueueIndex({
    required int? liveQueueIndex,
    required MediaItem? liveCurrentMediaItem,
  }) {
    final mediaId = liveCurrentMediaItem?.id;
    final hasValidLiveQueueIndex =
        liveQueueIndex != null &&
        liveQueueIndex >= 0 &&
        liveQueueIndex < widget.queue.length;

    if (hasValidLiveQueueIndex) {
      if (mediaId == null || widget.queue[liveQueueIndex].id == mediaId) {
        return liveQueueIndex;
      }
    }

    if (mediaId == null) {
      return null;
    }

    final fallbackIndex = widget.queue.indexWhere((item) => item.id == mediaId);
    return fallbackIndex >= 0 ? fallbackIndex : null;
  }

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
    return Scaffold(
      backgroundColor: keyboardOpen ? Colors.black : Colors.transparent,
      resizeToAvoidBottomInset: false,
      body: AnimatedBuilder(
        animation: Listenable.merge([
          useDynamicColorBackgroundNotifier,
          useDynamicColorInDialogsNotifier,
          colorSchemeNotifier,
        ]),
        builder: (context, _) {
          final useDynamicBg = useDynamicColorBackgroundNotifier.value;
          final useDynamicDialogs = useDynamicColorInDialogsNotifier.value;
          final colorScheme = colorSchemeNotifier.value;
          final isAmoled = colorScheme == AppColorScheme.amoled;
          final isDark = Theme.of(context).brightness == Brightness.dark;
          final showDynamicBg =
              (useDynamicBg || useDynamicDialogs) && isAmoled && isDark;

          return Container(
            decoration: BoxDecoration(
              color: showDynamicBg
                  ? Colors.black
                  : Theme.of(context).scaffoldBackgroundColor,
            ),
            child: Stack(
              children: [
                if (showDynamicBg)
                  ValueListenableBuilder<Color?>(
                    valueListenable: ThemeController.instance.dominantColor,
                    builder: (context, domColor, _) {
                      return Positioned.fill(
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeInOut,
                          color: normalizePaletteColor(
                            domColor ?? Colors.black,
                          ).withValues(alpha: 0.35),
                        ),
                      );
                    },
                  ),
                SafeArea(
                  child: StreamBuilder<MediaItem?>(
                    stream: audioHandler?.mediaItem,
                    initialData: widget.currentMediaItem,
                    builder: (context, mediaItemSnapshot) {
                      final liveCurrentMediaItem =
                          mediaItemSnapshot.data ?? widget.currentMediaItem;
                      return StreamBuilder<PlaybackState>(
                        stream: audioHandler?.playbackState,
                        initialData: audioHandler?.playbackState.value,
                        builder: (context, playbackSnapshot) {
                          final int? liveQueueIndex =
                              playbackSnapshot.data?.queueIndex;
                          final currentQueueIndex = _resolveCurrentQueueIndex(
                            liveQueueIndex: liveQueueIndex,
                            liveCurrentMediaItem: liveCurrentMediaItem,
                          );
                          return Column(
                            children: [
                              // Current Song Info and Search Bar (from original header)
                              Listener(
                                behavior: HitTestBehavior.translucent,
                                onPointerDown: (_) {
                                  // Force panel dragging mode when touching header
                                  widget.panelController?.setScrollingEnabled(
                                    false,
                                  );
                                },
                                onPointerUp: (_) {
                                  // Re-enable scrolling mode when releasing, but scheduled to allow fling calculation
                                  Future.delayed(
                                    const Duration(milliseconds: 300),
                                    () {
                                      if (mounted) {
                                        widget.panelController
                                            ?.setScrollingEnabled(true);
                                      }
                                    },
                                  );
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 0,
                                  ),
                                  child: Column(
                                    children: [
                                      // Información de la canción actual
                                      if (liveCurrentMediaItem != null)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 12.0,
                                          ),
                                          child: Row(
                                            children: [
                                              // Carátula de la canción actual
                                              ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                child: SizedBox(
                                                  width: 54,
                                                  height: 54,
                                                  child:
                                                      _buildCurrentSongArtwork(
                                                        liveCurrentMediaItem,
                                                      ),
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              // Título y artista de la canción actual
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    TitleMarquee(
                                                      text: liveCurrentMediaItem
                                                          .title,
                                                      maxWidth:
                                                          MediaQuery.of(
                                                            context,
                                                          ).size.width -
                                                          160,
                                                      style: const TextStyle(
                                                        fontSize: 16,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                      ),
                                                    ),

                                                    Text(
                                                      liveCurrentMediaItem
                                                              .artist ??
                                                          LocaleProvider.tr(
                                                            'unknown_artist',
                                                          ),
                                                      style: TextStyle(
                                                        fontSize: 13,
                                                        color: isAmoled
                                                            ? Colors.white
                                                                  .withValues(
                                                                    alpha: 0.85,
                                                                  )
                                                            : null,
                                                      ),
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              // Botón de play/pause
                                              StreamBuilder<PlaybackState>(
                                                stream:
                                                    audioHandler?.playbackState,
                                                builder: (context, snapshot) {
                                                  final playing =
                                                      snapshot.data?.playing ??
                                                      false;
                                                  return InkWell(
                                                    onTap: () {
                                                      if (playing) {
                                                        audioHandler?.pause();
                                                      } else {
                                                        audioHandler?.play();
                                                      }
                                                    },
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          20,
                                                        ),
                                                    child: Container(
                                                      padding:
                                                          const EdgeInsets.all(
                                                            8,
                                                          ),
                                                      child: Icon(
                                                        playing
                                                            ? Icons
                                                                  .pause_rounded
                                                            : Icons
                                                                  .play_arrow_rounded,
                                                        size: 32,
                                                        color: Theme.of(
                                                          context,
                                                        ).colorScheme.onSurface,
                                                      ),
                                                    ),
                                                  );
                                                },
                                              ),
                                            ],
                                          ),
                                        ),

                                      // Barra de búsqueda con el mismo estilo de favorites
                                      Builder(
                                        builder: (context) {
                                          final colorScheme =
                                              colorSchemeNotifier.value;
                                          final isAmoled =
                                              colorScheme ==
                                              AppColorScheme.amoled;
                                          final isDark =
                                              Theme.of(context).brightness ==
                                              Brightness.dark;
                                          final barColor = isAmoled
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

                                          return TextField(
                                            controller: _searchController,
                                            focusNode: _searchFocusNode,
                                            cursorColor: Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                            decoration: InputDecoration(
                                              hintText: LocaleProvider.tr(
                                                'search_by_title_or_artist',
                                              ),
                                              hintStyle: TextStyle(
                                                color: isAmoled
                                                    ? Colors.white.withAlpha(
                                                        160,
                                                      )
                                                    : Theme.of(context)
                                                          .colorScheme
                                                          .onSurfaceVariant,
                                                fontSize: 15,
                                              ),
                                              prefixIcon: const Icon(
                                                Icons.search,
                                              ),
                                              suffixIcon:
                                                  _searchQuery.isNotEmpty
                                                  ? IconButton(
                                                      icon: const Icon(
                                                        Icons.close,
                                                      ),
                                                      onPressed: () {
                                                        _searchController
                                                            .clear();
                                                        setState(
                                                          () =>
                                                              _searchQuery = '',
                                                        );
                                                      },
                                                    )
                                                  : null,
                                              filled: true,
                                              fillColor: barColor,
                                              border: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(28),
                                                borderSide: BorderSide.none,
                                              ),
                                              enabledBorder: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(28),
                                                borderSide: BorderSide.none,
                                              ),
                                              focusedBorder: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(28),
                                                borderSide: BorderSide.none,
                                              ),
                                              contentPadding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 20,
                                                    vertical: 12,
                                                  ),
                                            ),
                                            onChanged: (value) {
                                              setState(
                                                () => _searchQuery = value
                                                    .toLowerCase(),
                                              );
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
                                child: RepaintBoundary(
                                  // Aislar el ListView para que el scroll no provoque repaints
                                  // del overlay AMOLED ni del header (reduce lag con tema dinámico)
                                  child: Listener(
                                    behavior: HitTestBehavior.translucent,
                                    onPointerDown: (_) {
                                      // Explicitly enable scrolling mode when touching the list area
                                      widget.panelController
                                          ?.setScrollingEnabled(true);
                                    },
                                    child: Builder(
                                      builder: (context) {
                                        // Pre-cálculos para evitar trabajo por-item durante el scroll
                                        final isAmoledTheme =
                                            colorSchemeNotifier.value ==
                                            AppColorScheme.amoled;
                                        final isDark =
                                            Theme.of(context).brightness ==
                                            Brightness.dark;
                                        final primaryColor = Theme.of(
                                          context,
                                        ).colorScheme.primary;
                                        final cardColor = isAmoledTheme
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
                                        final currentCardColor = isAmoledTheme
                                            ? cardColor
                                            : primaryColor.withAlpha(
                                                isDark ? 40 : 25,
                                              );
                                        final textColor = isAmoledTheme
                                            ? Colors.white
                                            : primaryColor;

                                        if (!_isListReady) {
                                          return Center(
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const SizedBox(
                                                  width: 40,
                                                  height: 40,
                                                  child:
                                                      CircularProgressIndicator(),
                                                ),
                                              ],
                                            ),
                                          );
                                        }

                                        // Mantener índice original para evitar ambigüedad
                                        // cuando hay IDs repetidos en radio.
                                        final indexedQueue = widget.queue
                                            .asMap()
                                            .entries
                                            .toList(growable: false);
                                        final filteredEntries =
                                            _searchQuery.isEmpty
                                            ? indexedQueue
                                            : indexedQueue
                                                  .where((entry) {
                                                    final item = entry.value;
                                                    final title = item.title
                                                        .toLowerCase();
                                                    final artist =
                                                        (item.artist ?? '')
                                                            .toLowerCase();
                                                    return title.contains(
                                                          _searchQuery,
                                                        ) ||
                                                        artist.contains(
                                                          _searchQuery,
                                                        );
                                                  })
                                                  .toList(growable: false);

                                        if (!_didResolveInitialIndex) {
                                          final visibleIndex =
                                              currentQueueIndex == null
                                              ? -1
                                              : filteredEntries.indexWhere(
                                                  (entry) =>
                                                      entry.key ==
                                                      currentQueueIndex,
                                                );
                                          _initialVisibleIndex =
                                              visibleIndex >= 0
                                              ? visibleIndex
                                              : 0;
                                          _didResolveInitialIndex = true;
                                        }

                                        if (filteredEntries.isEmpty) {
                                          return Center(
                                            child: Text(
                                              LocaleProvider.tr('no_results'),
                                            ),
                                          );
                                        }

                                        return spl
                                            .ScrollablePositionedList.builder(
                                          initialScrollIndex:
                                              _initialVisibleIndex.clamp(
                                                0,
                                                filteredEntries.length - 1,
                                              ),
                                          initialAlignment: 0,
                                          physics:
                                              const ClampingScrollPhysics(),
                                          minCacheExtent: 200,
                                          addAutomaticKeepAlives: false,
                                          addRepaintBoundaries: true,
                                          padding: EdgeInsets.only(
                                            top: 8,
                                            bottom: MediaQuery.of(
                                              context,
                                            ).padding.bottom,
                                          ),
                                          itemCount: filteredEntries.length,
                                          itemBuilder: (context, index) {
                                            final entry =
                                                filteredEntries[index];
                                            final realIndex = entry.key;
                                            final item = entry.value;
                                            final isCurrent =
                                                currentQueueIndex != null &&
                                                realIndex == currentQueueIndex;
                                            final songId =
                                                item.extras?['songId'] ?? 0;
                                            final songPath =
                                                item.extras?['data'] ?? '';
                                            final resolvedArtUri =
                                                _displayArtUriFor(item);

                                            // Agregar padding adicional al primer y último elemento para evitar recorte
                                            // Ya no es tan necesario como en el modal, pero ayuda visualmente
                                            // final isFirstItem = index == 0;
                                            // final isLastItem = index == filteredQueue.length - 1;

                                            // (colores ya memoizados arriba)

                                            // Calcular borderRadius según posición
                                            final bool isFirst = index == 0;
                                            final bool isLast =
                                                index ==
                                                filteredEntries.length -
                                                    1; // Usando filteredQueue.length aquí porque es lo que se muestra
                                            final bool isOnly =
                                                filteredEntries.length == 1;

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
                                              key: ValueKey(
                                                '${item.id}#$realIndex',
                                              ), // Key única para evitar intercambio de carátulas
                                              padding: EdgeInsets.only(
                                                left: 16,
                                                right: 16,
                                                top: isFirst ? 4.0 : 0.0,
                                                bottom: isLast ? 20.0 : 4.0,
                                              ),
                                              child: Card(
                                                color: isCurrent
                                                    ? currentCardColor
                                                    : cardColor,
                                                margin: EdgeInsets.zero,
                                                elevation: 0,
                                                shape: RoundedRectangleBorder(
                                                  borderRadius: borderRadius,
                                                ),
                                                // Evita un ClipRRect extra (menos costo por item)
                                                clipBehavior: Clip.antiAlias,
                                                child: ListTile(
                                                  leading: RepaintBoundary(
                                                    child: ArtworkListTile(
                                                      songId: songId,
                                                      songPath: songPath,
                                                      artUri: resolvedArtUri,
                                                      size: 48,
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            8,
                                                          ),
                                                    ),
                                                  ),
                                                  title: Row(
                                                    children: [
                                                      if (isCurrent)
                                                        StreamBuilder<
                                                          PlaybackState
                                                        >(
                                                          stream: audioHandler
                                                              ?.playbackState,
                                                          builder: (context, snapshot) {
                                                            final playing =
                                                                snapshot
                                                                    .data
                                                                    ?.playing ??
                                                                false;
                                                            return Padding(
                                                              padding:
                                                                  const EdgeInsets.only(
                                                                    right: 8.0,
                                                                  ),
                                                              child:
                                                                  MiniMusicVisualizer(
                                                                    color:
                                                                        textColor,
                                                                    width: 4,
                                                                    height: 15,
                                                                    radius: 4,
                                                                    animate:
                                                                        playing,
                                                                  ),
                                                            );
                                                          },
                                                        ),
                                                      Expanded(
                                                        child: Text(
                                                          item.title,
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style: TextStyle(
                                                            fontWeight:
                                                                isCurrent
                                                                ? FontWeight
                                                                      .bold
                                                                : Theme.of(
                                                                        context,
                                                                      )
                                                                      .textTheme
                                                                      .titleMedium
                                                                      ?.fontWeight,
                                                            color: isCurrent
                                                                ? textColor
                                                                : null,
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                  subtitle: Text(
                                                    item.artist ??
                                                        LocaleProvider.tr(
                                                          'unknown_artist',
                                                        ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      color: isCurrent
                                                          ? textColor
                                                          : isAmoledTheme
                                                          ? Colors.white
                                                                .withValues(
                                                                  alpha: 0.8,
                                                                )
                                                          : null,
                                                    ),
                                                  ),
                                                  tileColor: Colors.transparent,
                                                  splashColor: primaryColor
                                                      .withValues(alpha: 0.1),
                                                  onTap: () {
                                                    audioHandler
                                                        ?.skipToQueueItem(
                                                          realIndex,
                                                        );
                                                  },
                                                ),
                                              ),
                                            );
                                          },
                                        );
                                      },
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
