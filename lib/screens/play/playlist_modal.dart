import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'package:music/main.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:mini_music_visualizer/mini_music_visualizer.dart';
import 'package:music/widgets/title_marquee.dart';
import 'package:music/widgets/artwork_list_tile.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'package:music/utils/theme_controller.dart';
import 'dart:io';

/// Muestra el modal de la lista de reproducción actual
Future<void> showPlaylistModal(
  BuildContext context, {
  required List<MediaItem> queue,
  required MediaItem? currentMediaItem,
  required int currentIndex,
}) async {
  await Navigator.push(
    context,
    PageRouteBuilder(
      opaque: true,
      pageBuilder: (context, animation, secondaryAnimation) => _PlaylistModal(
        queue: queue,
        currentMediaItem: currentMediaItem,
        currentIndex: currentIndex,
      ),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        const begin = Offset(0.0, 1.0);
        const end = Offset.zero;
        const curve = Curves.easeInOut;
        var tween = Tween(
          begin: begin,
          end: end,
        ).chain(CurveTween(curve: curve));
        return SlideTransition(position: animation.drive(tween), child: child);
      },
    ),
  );
}

class _PlaylistModal extends StatelessWidget {
  final List<MediaItem> queue;
  final MediaItem? currentMediaItem;
  final int currentIndex;

  const _PlaylistModal({
    required this.queue,
    required this.currentMediaItem,
    required this.currentIndex,
  });

  Color normalizePaletteColor(Color color) {
    final hsl = HSLColor.fromColor(color);
    final isGrayscale = hsl.saturation < 0.15;
    double effectiveLightness = hsl.lightness;
    if (effectiveLightness < 0.15) {
      effectiveLightness = 0.15;
    }
    final fixedLightness = (effectiveLightness * 0.85).clamp(0.55, 0.85);
    final fixedSaturation = isGrayscale
        ? hsl.saturation
        : hsl.saturation.clamp(0.35, 1.0);

    return hsl
        .withLightness(fixedLightness)
        .withSaturation(fixedSaturation)
        .toColor();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<MediaItem?>(
      stream: audioHandler?.mediaItem,
      initialData: currentMediaItem,
      builder: (context, snapshot) {
        final currentMediaItem = snapshot.data;
        return ValueListenableBuilder<bool>(
          valueListenable: useDynamicColorBackgroundNotifier,
          builder: (context, useDynamicBg, _) {
            return ValueListenableBuilder<AppColorScheme>(
              valueListenable: colorSchemeNotifier,
              builder: (context, colorScheme, _) {
                final isAmoled = colorScheme == AppColorScheme.amoled;
                final isDark = Theme.of(context).brightness == Brightness.dark;
                final showDynamicBg = useDynamicBg && isAmoled && isDark;

                return Material(
                  type: MaterialType.transparency,
                  child: Container(
                    height: MediaQuery.of(context).size.height,
                    decoration: BoxDecoration(
                      color: showDynamicBg
                          ? Colors.black
                          : Theme.of(context).scaffoldBackgroundColor,
                      borderRadius: BorderRadius.zero,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      children: [
                        if (showDynamicBg)
                          ValueListenableBuilder<Color?>(
                            valueListenable:
                                ThemeController.instance.dominantColor,
                            builder: (context, domColor, _) {
                              return Positioned.fill(
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  curve: Curves.easeInOut,
                                  color: normalizePaletteColor(
                                    domColor ??
                                        Theme.of(
                                          context,
                                        ).scaffoldBackgroundColor,
                                  ).withValues(alpha: 0.2),
                                ),
                              );
                            },
                          ),
                        SafeArea(
                          child: PlaylistListView(
                            queue: queue,
                            currentMediaItem: currentMediaItem,
                            currentIndex: currentIndex,
                            maxHeight: MediaQuery.of(context).size.height,
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
    );
  }
}

class PlaylistListView extends StatefulWidget {
  final List<MediaItem> queue;
  final MediaItem? currentMediaItem;
  final int currentIndex;
  final double maxHeight;

  const PlaylistListView({
    super.key,
    required this.queue,
    required this.currentMediaItem,
    required this.currentIndex,
    required this.maxHeight,
  });

  @override
  State<PlaylistListView> createState() => _PlaylistListViewState();
}

class _PlaylistListViewState extends State<PlaylistListView>
    with WidgetsBindingObserver {
  late final ScrollController _scrollController;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  // 5final bool _isShuffling = false;
  bool _isReady = false; // Para carga diferida de la lista
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
    _scrollController = ScrollController();
    WidgetsBinding.instance.addObserver(this);

    // Carga diferida: marcar como listo después de que el modal esté visible
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _lastBottomInset = View.of(context).viewInsets.bottom;
        setState(() => _isReady = true);
      }
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
    _scrollController.dispose();
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

    final songId = mediaItem.extras?['songId'];
    final songPath = mediaItem.extras?['data'];

    if (songId != null && songPath != null) {
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
        _loadArtworkAsync(songId, songPath);
      }

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

  Widget _buildPlaceholderTile(BuildContext context, int index) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final cardColor = isAmoled
        ? Colors.white.withAlpha(20)
        : isDark
        ? Theme.of(context).colorScheme.secondary.withValues(alpha: 0.06)
        : Theme.of(context).colorScheme.secondary.withValues(alpha: 0.07);

    final placeholderCount = widget.queue.length.clamp(0, 10);
    final isFirst = index == 0;
    final isLast = index == placeholderCount - 1;

    BorderRadius borderRadius;
    if (placeholderCount == 1) {
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
        left: 16,
        right: 16,
        top: isFirst ? 140.0 : 0.0,
        bottom: isLast ? 20.0 : 4.0,
      ),
      child: Card(
        color: cardColor,
        margin: EdgeInsets.zero,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: borderRadius),
        child: ClipRRect(
          borderRadius: borderRadius,
          child: ListTile(
            leading: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            title: Container(
              height: 14,
              width: double.infinity,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            subtitle: Container(
              height: 12,
              width: 100,
              margin: const EdgeInsets.only(top: 4),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.surfaceContainer.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final indexedQueue = widget.queue.asMap().entries.toList(growable: false);
    final filteredEntries = _searchQuery.isEmpty
        ? indexedQueue
        : indexedQueue
              .where((entry) {
                final item = entry.value;
                final title = item.title.toLowerCase();
                final artist = (item.artist ?? '').toLowerCase();
                return title.contains(_searchQuery) ||
                    artist.contains(_searchQuery);
              })
              .toList(growable: false);

    return Column(
      children: [
        // Encabezado persistente
        GestureDetector(
          onVerticalDragEnd: (details) {
            if ((details.primaryVelocity ?? 0) > 500) {
              Navigator.of(context).pop();
            }
          },
          behavior: HitTestBehavior.translucent,
          child: ValueListenableBuilder<bool>(
            valueListenable: useDynamicColorBackgroundNotifier,
            builder: (context, useDynamicBg, _) {
              return ValueListenableBuilder<AppColorScheme>(
                valueListenable: colorSchemeNotifier,
                builder: (context, colorScheme, _) {
                  final isAmoled = colorScheme == AppColorScheme.amoled;
                  final isDark =
                      Theme.of(context).brightness == Brightness.dark;
                  final showDynamicBg = useDynamicBg && isAmoled && isDark;

                  return Container(
                    decoration: BoxDecoration(
                      color: showDynamicBg
                          ? Colors.transparent
                          : Theme.of(context).scaffoldBackgroundColor,
                      borderRadius: BorderRadius.zero,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.currentMediaItem != null)
                          Row(
                            children: [
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
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    TitleMarquee(
                                      text: widget.currentMediaItem!.title,
                                      maxWidth:
                                          MediaQuery.of(context).size.width -
                                          150,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
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
                              StreamBuilder<PlaybackState>(
                                stream: audioHandler?.playbackState,
                                builder: (context, snapshot) {
                                  final playing =
                                      snapshot.data?.playing ?? false;
                                  return InkWell(
                                    onTap: () {
                                      if (playing) {
                                        audioHandler?.pause();
                                      } else {
                                        audioHandler?.play();
                                      }
                                    },
                                    borderRadius: BorderRadius.circular(20),
                                    child: Container(
                                      padding: const EdgeInsets.all(8),
                                      child: Icon(
                                        playing
                                            ? Icons.pause_rounded
                                            : Icons.play_arrow_rounded,
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
                        const SizedBox(height: 12),
                        Builder(
                          builder: (context) {
                            final colorScheme = colorSchemeNotifier.value;
                            final isAmoled =
                                colorScheme == AppColorScheme.amoled;
                            final isDark =
                                Theme.of(context).brightness == Brightness.dark;
                            final barColor = isAmoled
                                ? Colors.white.withAlpha(20)
                                : isDark
                                ? Theme.of(context).colorScheme.secondary
                                      .withValues(alpha: 0.06)
                                : Theme.of(context).colorScheme.secondary
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
                                setState(
                                  () => _searchQuery = value.toLowerCase(),
                                );
                              },
                            );
                          },
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),

        // Lista de canciones
        Expanded(
          child: !_isReady
              ? ListView.builder(
                  controller: _scrollController,
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.of(context).padding.bottom,
                  ),
                  itemCount: widget.queue.length.clamp(0, 10),
                  itemBuilder: (context, index) =>
                      _buildPlaceholderTile(context, index),
                )
              : ListView.builder(
                  controller: _scrollController,
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.of(context).padding.bottom,
                  ),
                  itemCount: filteredEntries.length,
                  itemBuilder: (context, index) {
                    final entry = filteredEntries[index];
                    final realIndex = entry.key;
                    final item = entry.value;
                    final liveQueueIndex =
                        audioHandler?.playbackState.valueOrNull?.queueIndex;
                    final hasValidLiveQueueIndex =
                        liveQueueIndex != null &&
                        liveQueueIndex >= 0 &&
                        liveQueueIndex < widget.queue.length;
                    final activeIndex = hasValidLiveQueueIndex
                        ? liveQueueIndex
                        : widget.currentIndex;
                    final isCurrent = realIndex == activeIndex;
                    final isAmoledTheme =
                        colorSchemeNotifier.value == AppColorScheme.amoled;
                    final songId = item.extras?['songId'] ?? 0;
                    final songPath = item.extras?['data'] ?? '';

                    final isFirstItem = index == 0;
                    final isLastItem = index == filteredEntries.length - 1;

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

                    BorderRadius borderRadius;
                    if (filteredEntries.length == 1) {
                      borderRadius = BorderRadius.circular(16);
                    } else if (isFirstItem) {
                      borderRadius = const BorderRadius.only(
                        topLeft: Radius.circular(16),
                        topRight: Radius.circular(16),
                        bottomLeft: Radius.circular(4),
                        bottomRight: Radius.circular(4),
                      );
                    } else if (isLastItem) {
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
                      key: ValueKey('${item.id}#$realIndex'),
                      padding: EdgeInsets.only(
                        left: 16,
                        right: 16,
                        top: isFirstItem ? 10.0 : 0.0,
                        bottom: isLastItem ? 20.0 : 4.0,
                      ),
                      child: Card(
                        color: isCurrent
                            ? Theme.of(
                                context,
                              ).colorScheme.primary.withAlpha(isDark ? 40 : 25)
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
                                          : Theme.of(
                                              context,
                                            ).textTheme.titleMedium?.fontWeight,
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
                ),
        ),
      ],
    );
  }
}
