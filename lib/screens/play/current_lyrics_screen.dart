import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:music/widgets/sliding_up_panel/sliding_up_panel.dart';
import 'package:audio_service/audio_service.dart';
import 'package:music/main.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:music/widgets/title_marquee.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'package:music/utils/theme_controller.dart';
import 'package:music/utils/audio/synced_lyrics_service.dart';
import 'package:material_loading_indicator/loading_indicator.dart';
import 'package:translator/translator.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:music/screens/play/lyrics_search_screen.dart';
import 'package:flutter/rendering.dart';
import 'dart:ui' as ui;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:palette_generator_master/palette_generator_master.dart';
import 'package:cached_network_image/cached_network_image.dart';

class LyricLine {
  final Duration time;
  final String text;
  LyricLine(this.time, this.text);
}

String _currentStreamingCoverQualityForLyrics() {
  final quality = coverQualityNotifier.value;
  if (quality == 'high' ||
      quality == 'medium' ||
      quality == 'medium_low' ||
      quality == 'low') {
    return quality;
  }
  return 'medium';
}

String _ytThumbFileForQualityForLyrics(String quality) {
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

String _googleThumbSizeForQualityForLyrics(String quality) {
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

String? _extractVideoIdFromMediaItemForLyrics(MediaItem mediaItem) {
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

String? _applyStreamingArtworkQualityForLyrics(
  String? rawUrl, {
  String? videoId,
}) {
  final normalized = rawUrl?.trim();
  if (normalized == null || normalized.isEmpty || normalized == 'null') {
    return null;
  }

  final quality = _currentStreamingCoverQualityForLyrics();
  final lower = normalized.toLowerCase();

  if (lower.contains('googleusercontent.com')) {
    final size = _googleThumbSizeForQualityForLyrics(quality);
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

  final qualityFile = _ytThumbFileForQualityForLyrics(quality);
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

class CurrentLyricsScreen extends StatefulWidget {
  final MediaItem? currentMediaItem;
  final VoidCallback? onClose;
  final PanelController? panelController;

  const CurrentLyricsScreen({
    super.key,
    required this.currentMediaItem,
    this.onClose,
    this.panelController,
  });

  @override
  State<CurrentLyricsScreen> createState() => _CurrentLyricsScreenState();
}

class _CurrentLyricsScreenState extends State<CurrentLyricsScreen> {
  LyricsResult? _lyricsResult;
  bool _isLoading = true;
  bool _hasError = false;
  List<LyricLine>? _parsedLyrics;
  MediaItem? _currentMediaItem;
  final Map<String, Future<LyricsResult>> _lyricsCache = {};

  @override
  void initState() {
    super.initState();
    _currentMediaItem = widget.currentMediaItem;
    if (_currentMediaItem != null) {
      _loadLyrics();
    }
    lyricsUpdatedNotifier.addListener(_onLyricsUpdated);
  }

  void _onLyricsUpdated() {
    final updatedId = lyricsUpdatedNotifier.value;
    if (updatedId != null && updatedId == _currentMediaItem?.id) {
      _lyricsCache.remove(updatedId);
      _loadLyrics();
    }
  }

  @override
  void dispose() {
    lyricsUpdatedNotifier.removeListener(_onLyricsUpdated);
    super.dispose();
  }

  @override
  void didUpdateWidget(CurrentLyricsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentMediaItem?.id != oldWidget.currentMediaItem?.id) {
      _currentMediaItem = widget.currentMediaItem;
      if (_currentMediaItem != null) {
        _loadLyrics();
      }
    }
  }

  Future<void> _loadLyrics() async {
    if (!mounted || _currentMediaItem == null) return;

    setState(() {
      _isLoading = true;
      _hasError = false;
    });

    try {
      final cacheKey = _currentMediaItem!.id;
      Future<LyricsResult> future;

      if (_lyricsCache.containsKey(cacheKey)) {
        future = _lyricsCache[cacheKey]!;
      } else {
        future = SyncedLyricsService.getSyncedLyricsWithResult(
          _currentMediaItem!,
        );
        _lyricsCache[cacheKey] = future;
      }

      final result = await future;
      if (!mounted) return;

      List<LyricLine>? parsed;
      if (result.type == LyricsResultType.found &&
          result.data?.synced != null) {
        final synced = result.data!.synced!;
        final lines = synced.split('\n');
        parsed = <LyricLine>[];
        final reg = RegExp(r'\[(\d{2}):(\d{2})(?:\.(\d{2,3}))?\](.*)');
        for (final line in lines) {
          final match = reg.firstMatch(line);
          if (match != null) {
            final min = int.parse(match.group(1)!);
            final sec = int.parse(match.group(2)!);
            final ms = match.group(3) != null
                ? int.parse(match.group(3)!.padRight(3, '0'))
                : 0;
            final text = match.group(4)!.trim();
            parsed.add(
              LyricLine(
                Duration(minutes: min, seconds: sec, milliseconds: ms),
                text,
              ),
            );
          }
        }
      }

      setState(() {
        _lyricsResult = result;
        _parsedLyrics = parsed;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _hasError = true;
        _isLoading = false;
      });
    }
  }

  static Color normalizePaletteColor(Color color) {
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

  Widget _buildModalArtwork(MediaItem mediaItem) {
    final artUri = mediaItem.artUri;
    if (artUri != null) {
      final scheme = artUri.scheme.toLowerCase();
      final videoId = _extractVideoIdFromMediaItemForLyrics(mediaItem);
      if (scheme == 'file' || scheme == 'content') {
        try {
          return Image.file(
            File(artUri.toFilePath()),
            width: 52,
            height: 52,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => _buildFallbackIcon(),
          );
        } catch (e) {
          return _buildFallbackIcon();
        }
      } else if (scheme == 'http' || scheme == 'https') {
        final imageUrl = _applyStreamingArtworkQualityForLyrics(
          artUri.toString(),
          videoId: videoId,
        );
        if (imageUrl == null || imageUrl.isEmpty) return _buildFallbackIcon();
        return CachedNetworkImage(
          imageUrl: imageUrl,
          width: 52,
          height: 52,
          fit: BoxFit.cover,
          fadeInDuration: Duration.zero,
          fadeOutDuration: Duration.zero,
          memCacheWidth: 200,
          memCacheHeight: 200,
          errorWidget: (context, url, error) => _buildFallbackIcon(),
        );
      }
    }

    final songId = mediaItem.extras?['songId'];
    final songPath = mediaItem.extras?['data'];

    if (songId != null && songPath != null) {
      // We can iterate cache check if needed, but for now simple future builder or relying on image cache
      return FutureBuilder<Uri?>(
        future: getOrCacheArtwork(songId, songPath),
        builder: (context, snapshot) {
          if (snapshot.hasData && snapshot.data != null) {
            return Image.file(
              File(snapshot.data!.toFilePath()),
              width: 52,
              height: 52,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) =>
                  _buildFallbackIcon(),
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
      width: 52,
      height: 52,
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
      backgroundColor: Colors.transparent,
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
                  child: Column(
                    children: [
                      // Header (Copied logic from CurrentPlaylistScreen/LyricsModal)
                      Listener(
                        behavior: HitTestBehavior.translucent,
                        onPointerDown: (_) {
                          widget.panelController?.setScrollingEnabled(false);
                        },
                        onPointerUp: (_) {
                          Future.delayed(const Duration(milliseconds: 300), () {
                            if (mounted) {
                              widget.panelController?.setScrollingEnabled(true);
                            }
                          });
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Row(
                            children: [
                              if (_currentMediaItem != null) ...[
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: _buildModalArtwork(_currentMediaItem!),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      TitleMarquee(
                                        text: _currentMediaItem!.title,
                                        maxWidth:
                                            MediaQuery.of(context).size.width -
                                            150,
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface, // Correct color from LyricsModal
                                        ),
                                      ),
                                      Text(
                                        _currentMediaItem!.artist ??
                                            LocaleProvider.tr('unknown_artist'),
                                        style: TextStyle(
                                          fontSize:
                                              14, // Consistent with LyricsModal
                                          color: isAmoled
                                              ? Colors.white.withValues(
                                                  alpha: 0.85,
                                                )
                                              : null,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                // Lyrics Search Button and Play/Pause
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      onPressed: () async {
                                        // Close panel before navigating as requested
                                        widget.panelController?.close();

                                        await Navigator.of(context).push(
                                          PageRouteBuilder(
                                            pageBuilder:
                                                (
                                                  context,
                                                  animation,
                                                  secondaryAnimation,
                                                ) => LyricsSearchScreen(
                                                  currentSong:
                                                      _currentMediaItem!,
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
                                                  const curve = Curves.ease;
                                                  final tween =
                                                      Tween(
                                                        begin: begin,
                                                        end: end,
                                                      ).chain(
                                                        CurveTween(
                                                          curve: curve,
                                                        ),
                                                      );
                                                  return SlideTransition(
                                                    position: animation.drive(
                                                      tween,
                                                    ),
                                                    child: child,
                                                  );
                                                },
                                          ),
                                        );
                                        // Reload lyrics after return?
                                        _lyricsCache.remove(
                                          _currentMediaItem?.id,
                                        );
                                        _loadLyrics(); // Force reload if changed
                                      },
                                      icon: const Icon(
                                        Icons.lyrics_outlined,
                                        size: 24,
                                      ),
                                      tooltip: LocaleProvider.tr(
                                        'search_lyrics',
                                      ),
                                    ),
                                    StreamBuilder<PlaybackState>(
                                      stream: audioHandler?.playbackState,
                                      builder: (context, snapshot) {
                                        final playing =
                                            snapshot.data?.playing ?? false;
                                        return IconButton(
                                          onPressed: () {
                                            if (playing) {
                                              audioHandler?.pause();
                                            } else {
                                              audioHandler?.play();
                                            }
                                          },
                                          icon: Icon(
                                            playing
                                                ? Icons.pause_rounded
                                                : Icons.play_arrow_rounded,
                                            size: 34,
                                            grade: 200,
                                            fill: 1,
                                          ),
                                        );
                                      },
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: Listener(
                          // Ensure scrolling works in panel
                          behavior: HitTestBehavior.translucent,
                          onPointerDown: (_) {
                            widget.panelController?.setScrollingEnabled(true);
                          },
                          child: ShaderMask(
                            shaderCallback: (Rect bounds) {
                              return const LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.transparent,
                                  Colors.white,
                                  Colors.white,
                                  Colors.transparent,
                                ],
                                stops: [0.0, 0.1, 0.9, 1.0],
                              ).createShader(bounds);
                            },
                            blendMode: BlendMode.dstIn,
                            child: _buildLyricsContent(
                              context,
                              isAmoled,
                              isDark,
                              _currentMediaItem!,
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
        },
      ),
    );
  }

  Widget _buildLyricsContent(
    BuildContext context,
    bool isAmoled,
    bool isDark,
    MediaItem currentMediaItem,
  ) {
    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [LoadingIndicator()],
        ),
      );
    }

    if (_hasError) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 64,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              LocaleProvider.tr('api_unavailable'),
              style: TextStyle(
                fontSize: 16,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ],
        ),
      );
    }

    final result = _lyricsResult;
    if (result == null) {
      return _buildNoLyricsFound(context, currentMediaItem, isAmoled);
    }

    if (result.type == LyricsResultType.noConnection) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.wifi_off,
              size: 64,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              LocaleProvider.tr('no_connection'),
              style: TextStyle(
                fontSize: 16,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      );
    }

    if (_parsedLyrics != null && _parsedLyrics!.isNotEmpty) {
      return _LyricsWithTranslationView(
        lyricLines: _parsedLyrics!,
        isAmoled: isAmoled,
        isDark: isDark,
        currentMediaItem: currentMediaItem,
      );
    }

    return _buildNoLyricsFound(context, currentMediaItem, isAmoled);
  }

  Widget _buildNoLyricsFound(
    BuildContext context,
    MediaItem currentMediaItem,
    bool isAmoled,
  ) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.lyrics_outlined,
            size: 64,
            color: isAmoled
                ? Colors.white
                : Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            LocaleProvider.tr('no_lyrics_found'),
            style: TextStyle(
              fontSize: 16,
              color: isAmoled
                  ? Colors.white
                  : Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () async {
              // Close panel before navigating as requested
              widget.panelController?.close();

              await Navigator.of(context).push(
                PageRouteBuilder(
                  pageBuilder: (context, animation, secondaryAnimation) =>
                      LyricsSearchScreen(currentSong: currentMediaItem),
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
              _lyricsCache.remove(currentMediaItem.id);
              _loadLyrics();
            },
            icon: const Icon(Icons.search_rounded),
            label: Text(LocaleProvider.tr('search_lyrics')),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Theme.of(context).colorScheme.onPrimary,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LyricsWithTranslationView extends StatefulWidget {
  final List<LyricLine> lyricLines;
  final bool isAmoled;
  final bool isDark;
  final MediaItem currentMediaItem;

  const _LyricsWithTranslationView({
    required this.lyricLines,
    required this.isAmoled,
    required this.isDark,
    required this.currentMediaItem,
  });

  @override
  State<_LyricsWithTranslationView> createState() =>
      _LyricsWithTranslationViewState();
}

class _LyricsWithTranslationViewState
    extends State<_LyricsWithTranslationView> {
  bool _showTranslation = false;
  bool _isTranslating = false;
  List<String>? _translatedLines;

  bool _isSelectionMode = false;
  final Set<int> _selectedIndices = {};

  void _onLineSelected(int index) {
    setState(() {
      if (_selectedIndices.contains(index)) {
        _selectedIndices.remove(index);
      } else {
        if (_selectedIndices.length < 5) {
          _selectedIndices.add(index);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: Theme.of(context).colorScheme.onSurface,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              content: Text(
                LocaleProvider.tr('max_lyrics_reached'),
                style: TextStyle(color: Theme.of(context).colorScheme.surface),
              ),
              duration: const Duration(seconds: 1),
            ),
          );
        }
      }
    });
  }

  void _toggleSelectionMode() {
    setState(() {
      _isSelectionMode = !_isSelectionMode;
      if (!_isSelectionMode) {
        _selectedIndices.clear();
      }
    });
  }

  Future<void> _shareLyrics() async {
    if (_selectedIndices.isEmpty) return;

    final sortedItems = _selectedIndices.toList()..sort();
    final selectedLyrics = sortedItems
        .map((i) => widget.lyricLines[i])
        .toList();

    showDialog(
      context: context,
      builder: (context) => _LyricShareDialog(
        lyrics: selectedLyrics,
        mediaItem: widget.currentMediaItem,
      ),
    );
  }

  Future<void> _toggleTranslation() async {
    if (_showTranslation) {
      setState(() {
        _showTranslation = false;
        _translatedLines = null;
      });
      return;
    }

    setState(() {
      _isTranslating = true;
    });

    try {
      final lyricsText = widget.lyricLines.map((line) => line.text).join('\n');
      final targetLanguage = translationLanguageNotifier.value == 'auto'
          ? Localizations.localeOf(context).languageCode
          : translationLanguageNotifier.value;

      final translator = GoogleTranslator();
      final translation = await translator.translate(
        lyricsText,
        to: targetLanguage,
      );

      if (mounted) {
        setState(() {
          _translatedLines = translation.text.split('\n');
          _showTranslation = true;
          _isTranslating = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isTranslating = false;
        });

        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(LocaleProvider.tr('translation_error')),
            content: Text(LocaleProvider.tr('check_internet_connection')),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(LocaleProvider.tr('ok')),
              ),
            ],
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ValueListenableBuilder<bool>(
          valueListenable: translationReplaceOriginalNotifier,
          builder: (context, replaceOriginal, _) => _LyricsModalListView(
            lyricLines: widget.lyricLines,
            isAmoled: widget.isAmoled,
            isDark: widget.isDark,
            showTranslation: _showTranslation,
            translatedLines: _translatedLines,
            replaceOriginalWithTranslation: replaceOriginal,
            isSelectionMode: _isSelectionMode,
            selectedIndices: _selectedIndices,
            onLineSelected: _onLineSelected,
          ),
        ),
        if (!_isSelectionMode) ...[
          Positioned(
            right: 24,
            bottom: 140,
            child: FloatingActionButton.small(
              heroTag: 'lyric_selection_toggle_btn',
              onPressed: _toggleSelectionMode,
              tooltip: LocaleProvider.tr('share'),
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
              child: const Icon(Icons.share_rounded, size: 20),
            ),
          ),
          Positioned(
            right: 24,
            bottom: 70,
            child: FloatingActionButton(
              heroTag: 'lyric_translate_btn',
              onPressed: _isTranslating ? null : _toggleTranslation,
              tooltip: _showTranslation
                  ? LocaleProvider.tr('hide_translation')
                  : LocaleProvider.tr('translate_lyrics'),
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
              child: _isTranslating
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Theme.of(context).colorScheme.onPrimaryContainer,
                        ),
                      ),
                    )
                  : Icon(_showTranslation ? Icons.close : Icons.translate),
            ),
          ),
        ] else ...[
          Positioned(
            right: 24,
            bottom: 140,
            child: FloatingActionButton.small(
              heroTag: 'lyric_cancel_selection_btn',
              onPressed: _toggleSelectionMode,
              tooltip: LocaleProvider.tr('cancel'),
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
              foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
              child: const Icon(Icons.close, size: 20),
            ),
          ),
          Positioned(
            right: 24,
            bottom: 70,
            child: FloatingActionButton(
              heroTag: 'lyric_confirm_share_btn',
              onPressed: _selectedIndices.isEmpty ? null : _shareLyrics,
              tooltip: LocaleProvider.tr('share'),
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
              child: const Icon(Icons.check_rounded),
            ),
          ),
        ],
      ],
    );
  }
}

class _LyricsModalListView extends StatefulWidget {
  final List<LyricLine> lyricLines;
  final bool isAmoled;
  final bool isDark;
  final bool showTranslation;
  final List<String>? translatedLines;
  final bool replaceOriginalWithTranslation;
  final bool isSelectionMode;
  final Set<int> selectedIndices;
  final ValueChanged<int> onLineSelected;

  const _LyricsModalListView({
    required this.lyricLines,
    required this.isAmoled,
    required this.isDark,
    this.showTranslation = false,
    this.translatedLines,
    this.replaceOriginalWithTranslation = false,
    required this.isSelectionMode,
    required this.selectedIndices,
    required this.onLineSelected,
  });

  @override
  State<_LyricsModalListView> createState() => _LyricsModalListViewState();
}

class _LyricsModalListViewState extends State<_LyricsModalListView>
    with WidgetsBindingObserver {
  late final AutoScrollController _scrollController;
  int _currentLyricIndex = 0;
  int _lastCurrentIndex = -1;
  Timer? _scrollTimer;
  bool _isManualScrolling = false;

  bool _isBackground = false;
  int? _tappedLyricIndex;
  Timer? _tappedLyricTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController = AutoScrollController();

    _calculateCurrentLyricIndex();

    _startPositionListener();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToCurrentLyric();
    });

    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (_scrollController.hasClients &&
        _scrollController.position.isScrollingNotifier.value) {
      _isManualScrolling = true;
      Timer(const Duration(milliseconds: 500), () {
        if (mounted) {
          _isManualScrolling = false;
        }
      });
    }
  }

  void _calculateCurrentLyricIndex() {
    final position =
        audioHandler?.playbackState.value.position ?? Duration.zero;

    int currentIndex = 0;
    for (int i = 0; i < widget.lyricLines.length; i++) {
      if (position >= widget.lyricLines[i].time) {
        currentIndex = i;
      } else {
        break;
      }
    }

    _currentLyricIndex = currentIndex;
    _lastCurrentIndex = currentIndex;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollTimer?.cancel();
    _tappedLyricTimer?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _isBackground = true;
    } else if (state == AppLifecycleState.resumed) {
      _isBackground = false;
      _updatePosition();
    }
  }

  void _startPositionListener() {
    _scrollTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (!mounted) return;
      if (_isBackground) {
        return;
      }
      _updatePosition();
    });
  }

  void _updatePosition() {
    if (!mounted) return;

    final position =
        audioHandler?.playbackState.value.position ?? Duration.zero;

    int currentIndex = 0;
    for (int i = 0; i < widget.lyricLines.length; i++) {
      if (position >= widget.lyricLines[i].time) {
        currentIndex = i;
      } else {
        break;
      }
    }

    if (currentIndex != _currentLyricIndex) {
      final int previousIndex = _currentLyricIndex;
      setState(() {
        _currentLyricIndex = currentIndex;
      });

      if (_currentLyricIndex != _lastCurrentIndex &&
          !_isManualScrolling &&
          !widget.isSelectionMode) {
        _lastCurrentIndex = _currentLyricIndex;
        _scrollToCurrentLyric(previousIndex);
      }
    }
  }

  Future<void> _scrollToCurrentLyric([int? previousIndex]) async {
    if (_currentLyricIndex >= 0 &&
        _currentLyricIndex < widget.lyricLines.length) {
      Duration duration = const Duration(milliseconds: 500);
      bool shouldJumpFirst = false;

      if (previousIndex != null) {
        final int diff = (_currentLyricIndex - previousIndex).abs();
        if (diff > 4) {
          duration = const Duration(milliseconds: 1);
          shouldJumpFirst = true;
        }
      }

      if (shouldJumpFirst && _scrollController.hasClients) {
        try {
          final double estimatedOffset = _currentLyricIndex * 40.0;
          _scrollController.jumpTo(estimatedOffset);
          await Future.delayed(const Duration(milliseconds: 50));
        } catch (_) {}
      }

      await _scrollController.scrollToIndex(
        _currentLyricIndex,
        preferPosition: AutoScrollPosition.middle,
        duration: duration,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ListView.builder(
          controller: _scrollController,
          padding: EdgeInsets.only(
            top: 60,
            bottom:
                MediaQuery.of(context).padding.bottom +
                80, // Add padding for FAB
          ),
          itemCount: widget.lyricLines.length,
          itemBuilder: (context, index) {
            final isCurrent = index == _currentLyricIndex;
            final isSelected = widget.selectedIndices.contains(index);
            // Text style copied from PlayerScreen line 6119
            final textStyle = TextStyle(
              color: widget.isSelectionMode
                  ? (isSelected
                        ? (widget.isAmoled && widget.isDark
                              ? Colors.white
                              : Theme.of(context).colorScheme.primary)
                        : (widget.isAmoled && widget.isDark
                              ? Theme.of(
                                  context,
                                ).colorScheme.onSurface.withValues(alpha: 0.3)
                              : Theme.of(
                                  context,
                                ).colorScheme.onSurface.withValues(alpha: 0.4)))
                  : (isCurrent
                        ? (widget.isAmoled && widget.isDark
                              ? Colors.white
                              : Theme.of(context).colorScheme.primary)
                        : widget.isAmoled && widget.isDark
                        ? Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.5)
                        : Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.7)),
              fontWeight: FontWeight.bold,
              fontSize: 22,
            );

            return AutoScrollTag(
              key: ValueKey(index),
              controller: _scrollController,
              index: index,
              child: GestureDetector(
                onTap: () {
                  if (widget.isSelectionMode) {
                    widget.onLineSelected(index);
                    return;
                  }
                  final targetTime = widget.lyricLines[index].time;
                  audioHandler?.seek(targetTime);

                  _isManualScrolling = true;

                  _tappedLyricTimer?.cancel();
                  setState(() {
                    _currentLyricIndex = index;
                    _lastCurrentIndex = index;
                    _tappedLyricIndex = index;
                  });

                  _tappedLyricTimer = Timer(const Duration(seconds: 2), () {
                    if (mounted) {
                      setState(() {
                        _tappedLyricIndex = null;
                      });
                    }
                  });

                  Timer(const Duration(seconds: 3), () {
                    _isManualScrolling = false;
                  });
                },
                child: AnimatedContainer(
                  duration: Duration(
                    milliseconds: _tappedLyricIndex == index ? 100 : 150,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: widget.isSelectionMode
                        ? (isSelected
                              ? (widget.isAmoled
                                        ? Colors.white
                                        : Theme.of(context).colorScheme.primary)
                                    .withValues(alpha: 0.1)
                              : Colors.transparent)
                        : (_tappedLyricIndex == index
                              ? (widget.isAmoled
                                        ? Colors.white
                                        : Theme.of(context).colorScheme.primary)
                                    .withValues(alpha: 0.05)
                              : Colors.transparent),
                  ),
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 16,
                  ),
                  child:
                      widget.showTranslation &&
                          widget.translatedLines != null &&
                          index < widget.translatedLines!.length
                      ? widget.replaceOriginalWithTranslation
                            ? Text(
                                widget.translatedLines![index],
                                textAlign: TextAlign.left,
                                style: textStyle.copyWith(
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                ),
                              )
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.lyricLines[index].text,
                                    textAlign: TextAlign.left,
                                    style: textStyle.copyWith(
                                      color: textStyle.color?.withValues(
                                        alpha: 0.6,
                                      ),
                                      fontSize: 18,
                                      fontWeight: FontWeight.normal,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    widget.translatedLines![index],
                                    textAlign: TextAlign.left,
                                    style: textStyle.copyWith(
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              )
                      : Text(
                          widget.lyricLines[index].text,
                          textAlign: TextAlign.left,
                          style: textStyle,
                        ),
                ),
              ),
            );
          },
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 30,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onVerticalDragStart: (_) {},
            onVerticalDragUpdate: (_) {},
          ),
        ),
      ],
    );
  }
}

class _LyricShareDialog extends StatefulWidget {
  final List<LyricLine> lyrics;
  final MediaItem mediaItem;

  const _LyricShareDialog({required this.lyrics, required this.mediaItem});

  @override
  State<_LyricShareDialog> createState() => _LyricShareDialogState();
}

class _LyricShareDialogState extends State<_LyricShareDialog> {
  final GlobalKey _globalKey = GlobalKey();
  bool _isGenerating = false;
  Color? _extractedColor;

  @override
  void initState() {
    super.initState();
    _fetchDominantColor();
  }

  Future<void> _fetchDominantColor() async {
    final artUri = widget.mediaItem.artUri;
    if (artUri == null) return;

    ImageProvider? provider;
    final scheme = artUri.scheme.toLowerCase();
    if (scheme == 'file' || scheme == 'content') {
      try {
        final file = File(artUri.toFilePath());
        if (file.existsSync() && file.lengthSync() > 0) {
          provider = FileImage(file);
        }
      } catch (_) {}
    } else if (scheme == 'http' || scheme == 'https') {
      final videoId = _extractVideoIdFromMediaItemForLyrics(widget.mediaItem);
      final imageUrl = _applyStreamingArtworkQualityForLyrics(
        artUri.toString(),
        videoId: videoId,
      );
      if (imageUrl != null && imageUrl.isNotEmpty) {
        provider = NetworkImage(imageUrl);
      }
    }

    if (provider == null) return;

    try {
      final generator = await PaletteGeneratorMaster.fromImageProvider(
        ResizeImage(provider, height: 50, width: 50),
        filters: [
          (HSLColor hsl) => hsl.lightness > 0.15 && hsl.lightness < 0.7,
          avoidRedBlackWhitePaletteFilterMaster,
        ],
      );

      final paletteColor =
          generator.dominantColor ??
          generator.darkVibrantColor ??
          generator.lightVibrantColor ??
          generator.vibrantColor ??
          generator.mutedColor;

      if (paletteColor != null && mounted) {
        setState(() {
          _extractedColor = paletteColor.color;
        });
      }
    } catch (_) {}
  }

  Future<void> _captureAndShare() async {
    setState(() {
      _isGenerating = true;
    });

    try {
      final boundary =
          _globalKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return;

      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;

      final uint8List = byteData.buffer.asUint8List();
      final tempDir = await getTemporaryDirectory();
      final file = await File(
        '${tempDir.path}/lyrics_share_${DateTime.now().millisecondsSinceEpoch}.png',
      ).create();
      await file.writeAsBytes(uint8List);

      //ignore: deprecated_member_use
      await Share.shareXFiles([XFile(file.path)], text: widget.mediaItem.title);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error al generar la imagen')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isGenerating = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      contentPadding: EdgeInsets.zero,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RepaintBoundary(
            key: _globalKey,
            child: _LyricShareWidget(
              lyrics: widget.lyrics,
              mediaItem: widget.mediaItem,
              extractedColor: _extractedColor,
            ),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FloatingActionButton.extended(
                onPressed: _isGenerating
                    ? null
                    : () => Navigator.of(context).pop(),
                label: Text(LocaleProvider.tr('cancel')),
                icon: const Icon(Icons.close),
                backgroundColor: Colors.white10,
                foregroundColor: Colors.white,
                elevation: 0,
              ),
              const SizedBox(width: 16),
              FloatingActionButton.extended(
                onPressed: _isGenerating ? null : _captureAndShare,
                label: Text(
                  _isGenerating
                      ? LocaleProvider.tr('generating')
                      : LocaleProvider.tr('share'),
                ),
                icon: _isGenerating
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.black,
                          ),
                        ),
                      )
                    : const Icon(Icons.share_rounded),
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LyricShareWidget extends StatelessWidget {
  final List<LyricLine> lyrics;
  final MediaItem mediaItem;
  final Color? extractedColor;

  const _LyricShareWidget({
    required this.lyrics,
    required this.mediaItem,
    this.extractedColor,
  });

  Widget _buildArtwork() {
    final artUri = mediaItem.artUri;
    if (artUri != null) {
      final scheme = artUri.scheme.toLowerCase();
      final videoId = _extractVideoIdFromMediaItemForLyrics(mediaItem);
      if (scheme == 'file' || scheme == 'content') {
        return Image.file(
          File(artUri.toFilePath()),
          width: 60,
          height: 60,
          fit: BoxFit.cover,
        );
      } else if (scheme == 'http' || scheme == 'https') {
        final imageUrl = _applyStreamingArtworkQualityForLyrics(
          artUri.toString(),
          videoId: videoId,
        );
        if (imageUrl == null || imageUrl.isEmpty) {
          return Container(
            width: 60,
            height: 60,
            color: Colors.white10,
            child: const Icon(Icons.music_note, color: Colors.white, size: 30),
          );
        }
        return CachedNetworkImage(
          imageUrl: imageUrl,
          width: 60,
          height: 60,
          fit: BoxFit.cover,
          fadeInDuration: Duration.zero,
          fadeOutDuration: Duration.zero,
          errorWidget: (context, url, error) => Container(
            width: 60,
            height: 60,
            color: Colors.white10,
            child: const Icon(Icons.music_note, color: Colors.white, size: 30),
          ),
        );
      }
    }
    return Container(
      width: 60,
      height: 60,
      color: Colors.white10,
      child: const Icon(Icons.music_note, color: Colors.white, size: 30),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Color?>(
      valueListenable: ThemeController.instance.dominantColor,
      builder: (context, domColor, _) {
        final baseColor = extractedColor ?? domColor ?? const Color(0xFF1A1A1A);
        final normalizedColor = _CurrentLyricsScreenState.normalizePaletteColor(
          baseColor,
        );
        // Creamos el fondo oscuro (negro + 20% del color normalizado) para que sea idéntico a la pantalla
        final bgColor = Color.alphaBlend(
          normalizedColor.withValues(alpha: 0.4),
          Colors.black,
        );

        return Container(
          width: 400,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: _buildArtwork(),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          mediaItem.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          mediaItem.artist ?? 'Artista desconocido',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7),
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
              const SizedBox(height: 10),
              Divider(color: Colors.white.withValues(alpha: 0.2)),
              const SizedBox(height: 10),
              ...lyrics.map(
                (line) => Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    line.text,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      height: 1.3,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  SvgPicture.asset(
                    'assets/icon/icon_foreground.svg',
                    height: 32,
                    colorFilter: const ColorFilter.mode(
                      Colors.white70,
                      BlendMode.srcIn,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Aura Music',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
