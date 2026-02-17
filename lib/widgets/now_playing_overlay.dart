import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:music/main.dart'
    show audioHandler, audioServiceReady, overlayVisibleNotifier;
import 'package:music/widgets/hero_cached.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'marquee.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/theme_preferences.dart';

/// Widget con animación de escala al presionar
class ScaleAnimatedButton extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final double scaleFactor;

  const ScaleAnimatedButton({
    super.key,
    required this.child,
    required this.onTap,
    this.scaleFactor = 0.85,
  });

  @override
  State<ScaleAnimatedButton> createState() => _ScaleAnimatedButtonState();
}

class _ScaleAnimatedButtonState extends State<ScaleAnimatedButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 100),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: widget.scaleFactor,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTap() {
    // Ejecutar el callback inmediatamente
    widget.onTap();

    // Ejecutar la animación visual en paralelo
    _controller.forward().then((_) {
      if (mounted) {
        _controller.reverse();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _handleTap,
      child: ScaleTransition(scale: _scaleAnimation, child: widget.child),
    );
  }
}

class NowPlayingOverlay extends StatefulWidget {
  final bool showBar;
  final VoidCallback? onTap;

  const NowPlayingOverlay({super.key, required this.showBar, this.onTap});

  @override
  State<NowPlayingOverlay> createState() => _NowPlayingOverlayState();
}

class _NowPlayingOverlayState extends State<NowPlayingOverlay> {
  MediaItem? _lastKnownMediaItem;
  Timer? _temporaryItemTimer;
  Timer? _playingDebounce;
  final ValueNotifier<bool> _isPlayingNotifier = ValueNotifier<bool>(false);

  // Cache del widget de fondo AMOLED para evitar reconstrucciones
  Widget? _cachedAmoledBackground;
  String? _cachedBackgroundSongId;

  // Cache de la imagen con blur pre-renderizada (blur estático)
  ui.Image? _cachedBlurredImage;
  String? _cachedBlurredImageSongId;

  @override
  void initState() {
    super.initState();

    // Escuchar cambios en el estado de reproducción con debounce mínimo
    audioHandler?.playbackState.listen((state) {
      _playingDebounce?.cancel();
      _playingDebounce = Timer(const Duration(milliseconds: 25), () {
        // Reducido de 100ms a 25ms
        if (mounted) {
          _isPlayingNotifier.value = state.playing;
        }
      });

      // Actualización inmediata para estados críticos
      if (state.playing != _isPlayingNotifier.value) {
        _isPlayingNotifier.value = state.playing;
      }
    });
  }

  @override
  void dispose() {
    _temporaryItemTimer?.cancel();
    _playingDebounce?.cancel();
    _isPlayingNotifier.dispose();
    super.dispose();
  }

  // Construye el fondo con la carátula para el tema AMOLED
  Widget? _buildAmoledBackground(MediaItem? mediaItem) {
    if (mediaItem == null) return null;

    // Verificar si podemos usar el cache
    final songId = (mediaItem.extras?['songId'] ?? mediaItem.id).toString();
    if (_cachedBackgroundSongId == songId && _cachedAmoledBackground != null) {
      return _cachedAmoledBackground;
    }

    final artUri = mediaItem.artUri;
    ImageProvider? imageProvider;

    // Prioridad 1: Si hay artUri, usarlo directamente
    if (artUri != null) {
      final scheme = artUri.scheme.toLowerCase();

      // Si es un archivo local, usar FileImage
      if (scheme == 'file' || scheme == 'content') {
        try {
          imageProvider = FileImage(File(artUri.toFilePath()));
        } catch (e) {
          imageProvider = null;
        }
      }
      // Si es una URL de red, usar NetworkImage
      else if (scheme == 'http' || scheme == 'https') {
        imageProvider = NetworkImage(artUri.toString());
      }
    }

    // Prioridad 2: Verificar caché si no hay artUri
    if (imageProvider == null) {
      final songPath = mediaItem.extras?['data'];
      if (songPath != null) {
        final cachedArtwork = artworkCache[songPath];
        if (cachedArtwork != null) {
          try {
            imageProvider = FileImage(File(cachedArtwork.toFilePath()));
          } catch (e) {
            imageProvider = null;
          }
        }
      }
    }

    // Si no hay imagen disponible, no mostrar fondo
    if (imageProvider == null) {
      _cachedAmoledBackground = null;
      _cachedBackgroundSongId = null;
      _cachedBlurredImage = null;
      _cachedBlurredImageSongId = null;
      return null;
    }

    imageProvider = ResizeImage(imageProvider, width: 150);

    // Construir y cachear el widget
    // Construir y cachear el widget con blur estático
    final backgroundWidget = RepaintBoundary(
      key: ValueKey('amoled_bg_overlay_$songId'),
      child: ClipRRect(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
          bottomLeft: Radius.circular(4),
          bottomRight: Radius.circular(4),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Renderizar el blur a baja resolución y escalar el resultado.
                  const double scale = 6.0;
                  final w = constraints.maxWidth / scale;
                  final h = constraints.maxHeight / scale;

                  if (w <= 0 || h <= 0) return const SizedBox.shrink();

                  // Usar un widget que cachea el blur como imagen estática
                  return _StaticBlurImage(
                    imageProvider: imageProvider!,
                    width: w,
                    height: h,
                    scale: scale + 0.1,
                    cachedImage: _cachedBlurredImageSongId == songId
                        ? _cachedBlurredImage
                        : null,
                    onImageCached: (image) {
                      if (_cachedBlurredImageSongId != songId) {
                        _cachedBlurredImage = image;
                        _cachedBlurredImageSongId = songId;
                      }
                    },
                  );
                },
              ),
            ),
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.1),
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.4),
                      Colors.black.withValues(alpha: 0.15),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    // Guardar en cache
    _cachedAmoledBackground = backgroundWidget;
    _cachedBackgroundSongId = songId;

    return backgroundWidget;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: audioServiceReady,
      builder: (context, ready, _) {
        if (!ready || audioHandler == null) {
          return const SizedBox.shrink();
        }
        return StreamBuilder<MediaItem?>(
          stream: audioHandler?.mediaItem,
          builder: (context, snapshot) {
            final song = snapshot.data;

            // Mantener el último MediaItem conocido
            if (song != null && song.id.isNotEmpty) {
              _lastKnownMediaItem = song;
            }

            // Usar la canción actual o la última conocida
            final currentSong = song ?? _lastKnownMediaItem;
            final duration = currentSong?.duration;

            if (!widget.showBar ||
                currentSong == null ||
                currentSong.id.isEmpty) {
              return const SizedBox.shrink();
            }

            final isLoading =
                (audioHandler as MyAudioHandler).initializingNotifier.value;

            return ValueListenableBuilder<bool>(
              valueListenable: overlayPlayerNavigationEnabled,
              builder: (context, navigationEnabled, _) {
                return GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () {
                    if (!overlayVisibleNotifier.value) {
                      overlayVisibleNotifier.value = true;
                    }
                    if (!navigationEnabled) return;
                    widget.onTap?.call();
                  },
                  // Solo manejar arrastre si no hay onTap (modo standalone).
                  // Cuando hay onTap (modo panel), el SlidingUpPanel maneja el arrastre.
                  onVerticalDragEnd: null,
                  child: ValueListenableBuilder<bool>(
                    valueListenable: useArtworkAsBackgroundOverlayNotifier,
                    builder: (context, useArtworkBg, child) {
                      return ValueListenableBuilder<AppColorScheme>(
                        valueListenable: colorSchemeNotifier,
                        builder: (context, colorScheme, child) {
                          final isAmoled = colorScheme == AppColorScheme.amoled;
                          final isSystem = colorScheme == AppColorScheme.system;
                          final isLight =
                              Theme.of(context).brightness == Brightness.light;
                          final isDark =
                              Theme.of(context).brightness == Brightness.dark;
                          final showBackground =
                              isAmoled && isDark && useArtworkBg;

                          final backgroundColor = Theme.of(
                            context,
                          ).colorScheme.onSecondaryFixed;

                          return Stack(
                            children: [
                              // Capa trasera (más oscura)
                              Positioned.fill(
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.surface,
                                    borderRadius: BorderRadius.only(
                                      topLeft: Radius.circular(20),
                                      topRight: Radius.circular(20),
                                      bottomLeft: Radius.circular(4),
                                      bottomRight: Radius.circular(4),
                                    ),
                                  ),
                                ),
                              ),
                              // Capa frontal (origen)
                              Container(
                                decoration: BoxDecoration(
                                  color: isAmoled
                                      ? Colors.black
                                      : isLight
                                      ? Theme.of(context).colorScheme.primary
                                            .withAlpha(isDark ? 40 : 25)
                                      : isSystem
                                      ? Theme.of(context).colorScheme.primary
                                            .withAlpha(isDark ? 40 : 25)
                                      : Color.lerp(
                                          backgroundColor,
                                          Colors.white,
                                          0.04,
                                        ),
                                  borderRadius: BorderRadius.only(
                                    topLeft: Radius.circular(20),
                                    topRight: Radius.circular(20),
                                    bottomLeft: Radius.circular(4),
                                    bottomRight: Radius.circular(4),
                                  ),
                                ),
                                child: Stack(
                                  children: [
                                    if (showBackground)
                                      Positioned.fill(
                                        child: AnimatedSwitcher(
                                          duration: const Duration(
                                            milliseconds: 200,
                                          ),
                                          child:
                                              _buildAmoledBackground(
                                                currentSong,
                                              ) ??
                                              const SizedBox.shrink(
                                                key: ValueKey(
                                                  'empty_bg_overlay',
                                                ),
                                              ),
                                        ),
                                      ),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 10,
                                      ),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Row(
                                            children: [
                                              ValueListenableBuilder<bool>(
                                                valueListenable:
                                                    (audioHandler
                                                            as MyAudioHandler)
                                                        .initializingNotifier,
                                                builder: (context, isLoading, child) {
                                                  if (isLoading) {
                                                    return Container(
                                                      width: 50,
                                                      height: 50,
                                                      decoration: BoxDecoration(
                                                        color: Theme.of(context)
                                                            .colorScheme
                                                            .surfaceContainerHighest,
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                      ),
                                                      child: const Center(
                                                        child: SizedBox(
                                                          width: 28,
                                                          height: 28,
                                                          child:
                                                              CircularProgressIndicator(
                                                                strokeWidth: 3,
                                                              ),
                                                        ),
                                                      ),
                                                    );
                                                  }

                                                  final artUri =
                                                      currentSong.artUri;

                                                  return AnimatedSwitcher(
                                                    duration: const Duration(
                                                      milliseconds: 200,
                                                    ),
                                                    child: ArtworkHeroCached(
                                                      key: ValueKey(
                                                        'overlay_art_${(currentSong.extras?['songId'] ?? currentSong.id).toString()}',
                                                      ),
                                                      artUri: artUri,
                                                      size: 50,
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            8,
                                                          ),
                                                      heroTag:
                                                          'now_playing_artwork_${(currentSong.extras?['songId'] ?? currentSong.id).toString()}',
                                                      showPlaceholderIcon: true,
                                                      isLoading:
                                                          false, // El overlay maneja el loading externamente
                                                    ),
                                                  );
                                                },
                                              ),
                                              const SizedBox(width: 9),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    ValueListenableBuilder<
                                                      bool
                                                    >(
                                                      valueListenable:
                                                          overlayNextButtonEnabled,
                                                      builder:
                                                          (
                                                            context,
                                                            nextButtonEnabled,
                                                            child,
                                                          ) {
                                                            // Ajustar el ancho máximo según si el botón next está habilitado
                                                            final maxWidth =
                                                                nextButtonEnabled
                                                                ? MediaQuery.of(
                                                                        context,
                                                                      ).size.width -
                                                                      187 // Más espacio cuando hay botón next
                                                                : MediaQuery.of(
                                                                        context,
                                                                      ).size.width -
                                                                      146; // Espacio normal

                                                            return TitleMarquee(
                                                              text: currentSong
                                                                  .title,
                                                              maxWidth:
                                                                  maxWidth,
                                                              style:
                                                                  Theme.of(
                                                                        context,
                                                                      )
                                                                      .textTheme
                                                                      .titleMedium,
                                                            );
                                                          },
                                                    ),
                                                    Row(
                                                      children: [
                                                        Expanded(
                                                          child: Text(
                                                            (currentSong.artist ==
                                                                        null ||
                                                                    currentSong
                                                                        .artist!
                                                                        .trim()
                                                                        .isEmpty)
                                                                ? 'Desconocido'
                                                                : currentSong
                                                                      .artist!,
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style:
                                                                Theme.of(
                                                                      context,
                                                                    )
                                                                    .textTheme
                                                                    .bodyMedium,
                                                          ),
                                                        ),
                                                        Icon(
                                                          Icons.person_rounded,
                                                          size: 14,
                                                          color: Colors
                                                              .transparent,
                                                        ),
                                                      ],
                                                    ),
                                                  ],
                                                ),
                                              ),

                                              Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  RepaintBoundary(
                                                    child: ValueListenableBuilder<bool>(
                                                      valueListenable:
                                                          _isPlayingNotifier,
                                                      builder: (context, isPlaying, child) {
                                                        return ValueListenableBuilder<
                                                          AppColorScheme
                                                        >(
                                                          valueListenable:
                                                              colorSchemeNotifier,
                                                          builder:
                                                              (
                                                                context,
                                                                colorScheme,
                                                                child,
                                                              ) {
                                                                return Material(
                                                                  color: Colors
                                                                      .transparent,
                                                                  child: InkWell(
                                                                    customBorder: RoundedRectangleBorder(
                                                                      borderRadius: BorderRadius.circular(
                                                                        isPlaying
                                                                            ? (40 /
                                                                                  3)
                                                                            : (40 / 2),
                                                                      ),
                                                                    ),
                                                                    splashColor:
                                                                        Colors
                                                                            .transparent,
                                                                    highlightColor:
                                                                        Colors
                                                                            .transparent,
                                                                    onTap: () {
                                                                      // Actualizar el estado inmediatamente para mejor UX
                                                                      _isPlayingNotifier
                                                                              .value =
                                                                          !isPlaying;

                                                                      // Ejecutar la acción de audio de forma asíncrona para no bloquear la UI
                                                                      Future.microtask(() {
                                                                        if (isPlaying) {
                                                                          audioHandler
                                                                              ?.pause();
                                                                        } else {
                                                                          audioHandler
                                                                              ?.play();
                                                                        }
                                                                      });
                                                                    },
                                                                    child:
                                                                        showBackground
                                                                        ? SizedBox(
                                                                            width:
                                                                                40,
                                                                            height:
                                                                                40,
                                                                            child:
                                                                                TweenAnimationBuilder<
                                                                                  double
                                                                                >(
                                                                                  tween:
                                                                                      Tween<
                                                                                        double
                                                                                      >(
                                                                                        end: isPlaying
                                                                                            ? (40.0 /
                                                                                                  3)
                                                                                            : (40.0 /
                                                                                                  2),
                                                                                      ),
                                                                                  duration: const Duration(
                                                                                    milliseconds: 250,
                                                                                  ),
                                                                                  curve: Curves.easeInOut,
                                                                                  builder:
                                                                                      (
                                                                                        context,
                                                                                        radius,
                                                                                        _,
                                                                                      ) {
                                                                                        return CustomPaint(
                                                                                          painter: _HolePunchPainter(
                                                                                            color: Colors.white,
                                                                                            radius: radius,
                                                                                            icon: isPlaying
                                                                                                ? Icons.pause_rounded
                                                                                                : Icons.play_arrow_rounded,
                                                                                            iconSize: 28,
                                                                                          ),
                                                                                        );
                                                                                      },
                                                                                ),
                                                                          )
                                                                        : AnimatedContainer(
                                                                            duration: const Duration(
                                                                              milliseconds: 250,
                                                                            ),
                                                                            curve:
                                                                                Curves.easeInOut,
                                                                            width:
                                                                                40,
                                                                            height:
                                                                                40,
                                                                            decoration: BoxDecoration(
                                                                              color:
                                                                                  colorScheme ==
                                                                                      AppColorScheme.amoled
                                                                                  ? Colors.white
                                                                                  : Theme.of(
                                                                                      context,
                                                                                    ).colorScheme.primary,
                                                                              borderRadius: BorderRadius.circular(
                                                                                isPlaying
                                                                                    ? (40 /
                                                                                          3)
                                                                                    : (40 /
                                                                                          2),
                                                                              ),
                                                                            ),
                                                                            child: Center(
                                                                              child: Icon(
                                                                                isPlaying
                                                                                    ? Icons.pause_rounded
                                                                                    : Icons.play_arrow_rounded,
                                                                                grade: 200,
                                                                                size: 28,
                                                                                fill: 1,
                                                                                color:
                                                                                    colorScheme ==
                                                                                        AppColorScheme.amoled
                                                                                    ? Colors.black
                                                                                    : Theme.of(
                                                                                            context,
                                                                                          ).brightness ==
                                                                                          Brightness.light
                                                                                    ? Theme.of(
                                                                                        context,
                                                                                      ).colorScheme.secondaryContainer
                                                                                    : Theme.of(
                                                                                        context,
                                                                                      ).colorScheme.onPrimary,
                                                                              ),
                                                                            ),
                                                                          ),
                                                                  ),
                                                                );
                                                              },
                                                        );
                                                      },
                                                    ),
                                                  ),

                                                  // Botón de siguiente (solo si está habilitado)
                                                  ValueListenableBuilder<bool>(
                                                    valueListenable:
                                                        overlayNextButtonEnabled,
                                                    builder:
                                                        (
                                                          context,
                                                          nextButtonEnabled,
                                                          child,
                                                        ) {
                                                          if (!nextButtonEnabled) {
                                                            return const SizedBox.shrink();
                                                          }

                                                          return Padding(
                                                            padding:
                                                                const EdgeInsets.only(
                                                                  left: 8.0,
                                                                ),
                                                            child: RepaintBoundary(
                                                              child: ValueListenableBuilder<AppColorScheme>(
                                                                valueListenable:
                                                                    colorSchemeNotifier,
                                                                builder:
                                                                    (
                                                                      context,
                                                                      colorScheme,
                                                                      child,
                                                                    ) {
                                                                      return ScaleAnimatedButton(
                                                                        onTap: () {
                                                                          if (isLoading ||
                                                                              !navigationEnabled) {
                                                                            return;
                                                                          }
                                                                          audioHandler
                                                                              ?.skipToNext();
                                                                        },
                                                                        child:
                                                                            showBackground
                                                                            ? SizedBox(
                                                                                width: 40,
                                                                                height: 40,
                                                                                child: CustomPaint(
                                                                                  painter: _HolePunchPainter(
                                                                                    color: Colors.white,
                                                                                    radius: 20,
                                                                                    icon: Icons.skip_next_rounded,
                                                                                    iconSize: 24,
                                                                                  ),
                                                                                ),
                                                                              )
                                                                            : AnimatedContainer(
                                                                                duration: const Duration(
                                                                                  milliseconds: 250,
                                                                                ),
                                                                                curve: Curves.easeInOut,
                                                                                width: 40,
                                                                                height: 40,
                                                                                decoration: BoxDecoration(
                                                                                  color:
                                                                                      colorScheme ==
                                                                                          AppColorScheme.amoled
                                                                                      ? Colors.white
                                                                                      : Theme.of(
                                                                                          context,
                                                                                        ).colorScheme.primary,
                                                                                  borderRadius: BorderRadius.circular(
                                                                                    20,
                                                                                  ),
                                                                                ),
                                                                                child: Center(
                                                                                  child: Icon(
                                                                                    Icons.skip_next_rounded,
                                                                                    grade: 200,
                                                                                    size: 24,
                                                                                    fill: 1,
                                                                                    color:
                                                                                        colorScheme ==
                                                                                            AppColorScheme.amoled
                                                                                        ? Colors.black
                                                                                        : Theme.of(
                                                                                                context,
                                                                                              ).brightness ==
                                                                                              Brightness.light
                                                                                        ? Theme.of(
                                                                                            context,
                                                                                          ).colorScheme.secondaryContainer
                                                                                        : Theme.of(
                                                                                            context,
                                                                                          ).colorScheme.onPrimary,
                                                                                  ),
                                                                                ),
                                                                              ),
                                                                      );
                                                                    },
                                                              ),
                                                            ),
                                                          );
                                                        },
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 6),

                                          RepaintBoundary(
                                            child: ValueListenableBuilder<AppColorScheme>(
                                              valueListenable:
                                                  colorSchemeNotifier,
                                              builder: (context, colorScheme, child) {
                                                return StreamBuilder<Duration>(
                                                  stream:
                                                      (audioHandler
                                                              as MyAudioHandler)
                                                          .positionStream,
                                                  initialData: Duration.zero,
                                                  builder: (context, posSnapshot) {
                                                    final position =
                                                        posSnapshot.data ??
                                                        Duration.zero;
                                                    final hasDuration =
                                                        duration != null &&
                                                        duration.inMilliseconds >
                                                            0;

                                                    return StreamBuilder<
                                                      Duration?
                                                    >(
                                                      stream:
                                                          (audioHandler
                                                                  as MyAudioHandler)
                                                              .player
                                                              .durationStream,
                                                      builder: (context, durationSnapshot) {
                                                        final fallbackDuration =
                                                            durationSnapshot
                                                                .data;
                                                        final total =
                                                            hasDuration
                                                            ? duration
                                                                  .inMilliseconds
                                                            : (fallbackDuration
                                                                      ?.inMilliseconds ??
                                                                  1);
                                                        final current = position
                                                            .inMilliseconds
                                                            .clamp(0, total);

                                                        return Column(
                                                          children: [
                                                            Container(
                                                              decoration: BoxDecoration(
                                                                borderRadius:
                                                                    BorderRadius.circular(
                                                                      8,
                                                                    ),
                                                                border: Border.all(
                                                                  color:
                                                                      Theme.of(
                                                                        context,
                                                                      ).colorScheme.outline.withValues(
                                                                        alpha:
                                                                            0.1,
                                                                      ),
                                                                  width: 0.5,
                                                                ),
                                                              ),
                                                              child: ClipRRect(
                                                                borderRadius:
                                                                    BorderRadius.circular(
                                                                      8,
                                                                    ),
                                                                child: LinearProgressIndicator(
                                                                  // ignore: deprecated_member_use
                                                                  year2023:
                                                                      false,
                                                                  key: ValueKey(
                                                                    total,
                                                                  ),
                                                                  value:
                                                                      total > 0
                                                                      ? current /
                                                                            total
                                                                      : 0,
                                                                  minHeight: 4,
                                                                  borderRadius:
                                                                      BorderRadius.circular(
                                                                        8,
                                                                      ),
                                                                  backgroundColor:
                                                                      Theme.of(
                                                                        context,
                                                                      ).colorScheme.primary.withValues(
                                                                        alpha:
                                                                            0.3,
                                                                      ),
                                                                  color: Theme.of(
                                                                    context,
                                                                  ).colorScheme.primary,
                                                                ),
                                                              ),
                                                            ),
                                                          ],
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
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      );
                    },
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

class TitleMarquee extends StatefulWidget {
  final String text;
  final double maxWidth;
  final TextStyle? style;

  const TitleMarquee({
    super.key,
    required this.text,
    required this.maxWidth,
    this.style,
  });

  @override
  State<TitleMarquee> createState() => _TitleMarqueeState();
}

class _TitleMarqueeState extends State<TitleMarquee> {
  bool _showMarquee = false;

  @override
  void didUpdateWidget(covariant TitleMarquee oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      setState(() => _showMarquee = false);
      Future.delayed(const Duration(milliseconds: 1000), () {
        if (mounted) setState(() => _showMarquee = true);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 3000), () {
      if (mounted) setState(() => _showMarquee = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final textStyle = widget.style ?? DefaultTextStyle.of(context).style;
    final textPainter = TextPainter(
      text: TextSpan(text: widget.text, style: textStyle),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();

    final textHeight = textPainter.height;
    final textWidth = textPainter.size.width;

    final boxHeight = textHeight + 4; // pequeño margen

    if (textWidth > widget.maxWidth) {
      if (!_showMarquee) {
        return SizedBox(
          height: boxHeight,
          width: widget.maxWidth,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              widget.text,
              style: textStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      }
      return SizedBox(
        height: boxHeight,
        width: widget.maxWidth,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Marquee(
            key: ValueKey(widget.text),
            text: widget.text,
            style: textStyle,
            velocity: 30.0,
            blankSpace: 80.0,
            startPadding: 0.0,
            fadingEdgeStartFraction: 0.1,
            fadingEdgeEndFraction: 0.1,
            showFadingOnlyWhenScrolling: false,
            pauseAfterRound: const Duration(seconds: 3),
          ),
        ),
      );
    } else {
      return SizedBox(
        height: boxHeight,
        width: widget.maxWidth,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            widget.text,
            style: textStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
  }
}

class _HolePunchPainter extends CustomPainter {
  final Color color;
  final double radius;
  final IconData icon;
  final double iconSize;

  _HolePunchPainter({
    required this.color,
    required this.radius,
    required this.icon,
    required this.iconSize,
  });

  @override
  void paint(ui.Canvas canvas, Size size) {
    canvas.saveLayer(Offset.zero & size, ui.Paint());

    final paint = ui.Paint()
      ..color = color
      ..style = ui.PaintingStyle.fill;

    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)),
      paint,
    );

    final textPainter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: iconSize,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          foreground: ui.Paint()..blendMode = ui.BlendMode.dstOut,
        ),
      ),
      textDirection: TextDirection.ltr,
    );

    textPainter.layout();
    final center = Offset(
      (size.width - textPainter.width) / 2,
      (size.height - textPainter.height) / 2,
    );
    textPainter.paint(canvas, center);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _HolePunchPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.radius != radius ||
        oldDelegate.icon != icon;
  }
}

class _StaticBlurImage extends StatefulWidget {
  final ImageProvider imageProvider;
  final double width;
  final double height;
  final double scale;
  final ui.Image? cachedImage;
  final ValueChanged<ui.Image> onImageCached;

  const _StaticBlurImage({
    required this.imageProvider,
    required this.width,
    required this.height,
    required this.scale,
    this.cachedImage,
    required this.onImageCached,
  });

  @override
  State<_StaticBlurImage> createState() => _StaticBlurImageState();
}

class _StaticBlurImageState extends State<_StaticBlurImage> {
  ui.Image? _blurredImage;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _blurredImage = widget.cachedImage;
    if (_blurredImage == null) {
      _loadAndBlurImage();
    }
  }

  @override
  void didUpdateWidget(_StaticBlurImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Si cambió la imagen o no tenemos cache, cargar de nuevo
    if (oldWidget.imageProvider != widget.imageProvider ||
        _blurredImage == null) {
      _loadAndBlurImage();
    }
  }

  Future<void> _loadAndBlurImage() async {
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
    });

    try {
      // Cargar la imagen
      final ImageStream stream = widget.imageProvider.resolve(
        const ImageConfiguration(),
      );

      final completer = Completer<ui.Image>();
      late ImageStreamListener listener;

      listener = ImageStreamListener(
        (ImageInfo info, bool _) {
          completer.complete(info.image);
          stream.removeListener(listener);
        },
        onError: (exception, stackTrace) {
          completer.completeError(exception);
          stream.removeListener(listener);
        },
      );

      stream.addListener(listener);

      final image = await completer.future;

      // Renderizar el blur en una imagen estática
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final paint = ui.Paint();

      // Aplicar blur usando ImageFilter
      final blurFilter = ui.ImageFilter.blur(sigmaX: 9, sigmaY: 9);
      canvas.saveLayer(
        Offset.zero & Size(widget.width, widget.height),
        paint..imageFilter = blurFilter,
      );

      // Dibujar la imagen escalada
      final srcRect = Rect.fromLTWH(
        0,
        0,
        image.width.toDouble(),
        image.height.toDouble(),
      );
      final dstRect = Rect.fromLTWH(0, 0, widget.width, widget.height);
      canvas.drawImageRect(
        image,
        srcRect,
        dstRect,
        ui.Paint()..filterQuality = FilterQuality.low,
      );

      canvas.restore();

      // Convertir a imagen
      final picture = recorder.endRecording();
      final blurredImage = await picture.toImage(
        widget.width.toInt(),
        widget.height.toInt(),
      );

      if (mounted) {
        setState(() {
          _blurredImage = blurredImage;
          _isLoading = false;
        });

        // Notificar al padre para cachear la imagen
        widget.onImageCached(blurredImage);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_blurredImage == null) {
      // Mientras carga, mostrar el blur dinámico (solo la primera vez)
      return RepaintBoundary(
        child: Transform.scale(
          scale: widget.scale,
          child: Center(
            child: SizedBox(
              width: widget.width,
              height: widget.height,
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 9, sigmaY: 9),
                child: Image(
                  image: widget.imageProvider,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.low,
                  errorBuilder: (context, error, stackTrace) =>
                      const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      );
    }

    // Mostrar la imagen con blur pre-renderizada (estática)
    return RepaintBoundary(
      child: Transform.scale(
        scale: widget.scale,
        child: Center(
          child: SizedBox(
            width: widget.width,
            height: widget.height,
            child: CustomPaint(
              painter: _BlurredImagePainter(_blurredImage!),
              size: Size(widget.width, widget.height),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    // No disposear la imagen cacheada, se reutiliza
    super.dispose();
  }
}

// CustomPainter para dibujar la imagen con blur pre-renderizada
class _BlurredImagePainter extends CustomPainter {
  final ui.Image blurredImage;

  _BlurredImagePainter(this.blurredImage);

  @override
  void paint(ui.Canvas canvas, Size size) {
    final srcRect = Rect.fromLTWH(
      0,
      0,
      blurredImage.width.toDouble(),
      blurredImage.height.toDouble(),
    );
    final dstRect = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawImageRect(
      blurredImage,
      srcRect,
      dstRect,
      ui.Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(covariant _BlurredImagePainter oldDelegate) {
    return oldDelegate.blurredImage != blurredImage;
  }
}
