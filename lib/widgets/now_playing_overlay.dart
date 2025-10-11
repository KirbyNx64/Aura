import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:music/main.dart'
    show audioHandler, audioServiceReady, overlayVisibleNotifier;
import 'package:music/screens/play/player_screen.dart';
import 'package:music/widgets/hero_cached.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'marquee.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:music/utils/gesture_preferences.dart';

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
    ).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeInOut,
      ),
    );
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
      child: ScaleTransition(
        scale: _scaleAnimation,
        child: widget.child,
      ),
    );
  }
}

class NowPlayingOverlay extends StatefulWidget {
  final bool showBar;

  const NowPlayingOverlay({super.key, required this.showBar});

  @override
  State<NowPlayingOverlay> createState() => _NowPlayingOverlayState();
}

class _NowPlayingOverlayState extends State<NowPlayingOverlay> {
  MediaItem? _lastKnownMediaItem;
  Timer? _temporaryItemTimer;
  Timer? _playingDebounce;
  final ValueNotifier<bool> _isPlayingNotifier = ValueNotifier<bool>(false);
  
  // Preferencias de gestos
  bool _disableOpenPlayerGesture = false;
  VoidCallback? _gesturePreferencesListener;

  @override
  void initState() {
    super.initState();
    _loadGesturePreferences();
    _setupGesturePreferencesListener();

    // Escuchar cambios en el estado de reproducción con debounce mínimo
    audioHandler?.playbackState.listen((state) {
      _playingDebounce?.cancel();
      _playingDebounce = Timer(const Duration(milliseconds: 25), () { // Reducido de 100ms a 25ms
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

  /// Carga las preferencias de gestos
  Future<void> _loadGesturePreferences() async {
    final preferences = await GesturePreferences.getAllGesturePreferences();
    if (mounted) {
      setState(() {
        _disableOpenPlayerGesture = preferences['openPlayer'] ?? false;
      });
    }
  }

  /// Configura el listener para cambios en las preferencias de gestos
  void _setupGesturePreferencesListener() {
    _gesturePreferencesListener = () {
      if (mounted) {
        _loadGesturePreferences();
      }
    };
    gesturePreferencesChanged.addListener(_gesturePreferencesListener!);
  }

  @override
  void dispose() {
    _temporaryItemTimer?.cancel();
    _playingDebounce?.cancel();
    _isPlayingNotifier.dispose();
    if (_gesturePreferencesListener != null) {
      gesturePreferencesChanged.removeListener(_gesturePreferencesListener!);
    }
    super.dispose();
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
                  onTap: () async {
                    if (!overlayVisibleNotifier.value) {
                      overlayVisibleNotifier.value = true;
                    }
                    if (isLoading || !navigationEnabled) return;
                    final songId = currentSong.extras?['songId'] ?? 0;
                    final songPath = currentSong.extras?['data'] ?? '';
                    final artUri = await getOrCacheArtwork(songId, songPath);
                    if (!context.mounted) return;
                    Navigator.of(context).push(
                      PageRouteBuilder(
                        pageBuilder: (context, animation, secondaryAnimation) =>
                            FullPlayerScreen(
                              initialMediaItem: currentSong,
                              initialArtworkUri: artUri,
                            ),
                        transitionsBuilder:
                            (context, animation, secondaryAnimation, child) {
                              // El Hero se anima solo, solo animamos el resto del contenido
                              return SlideTransition(
                                position:
                                    Tween<Offset>(
                                      begin: const Offset(0, 1),
                                      end: Offset.zero,
                                    ).animate(
                                      CurvedAnimation(
                                        parent: animation,
                                        curve: Curves.easeOutCubic,
                                      ),
                                    ),
                                child: child,
                              );
                            },
                        transitionDuration: const Duration(milliseconds: 350),
                      ),
                    );
                  },
                  onVerticalDragEnd: (details) async {
                    if (!overlayVisibleNotifier.value) {
                      overlayVisibleNotifier.value = true;
                    }
                    if (isLoading || !navigationEnabled || _disableOpenPlayerGesture) return;
                    if (details.primaryVelocity != null &&
                        details.primaryVelocity! < 0) {
                      final currentSong = song;
                      final songId = currentSong?.extras?['songId'] ?? 0;
                      final songPath = currentSong?.extras?['data'] ?? '';
                      final artUri = await getOrCacheArtwork(songId, songPath);
                      if (!context.mounted) return;
                      Navigator.of(context).push(
                        PageRouteBuilder(
                          pageBuilder:
                              (context, animation, secondaryAnimation) =>
                                  FullPlayerScreen(
                                    initialMediaItem: currentSong,
                                    initialArtworkUri: artUri,
                                  ),
                          transitionsBuilder:
                              (context, animation, secondaryAnimation, child) {
                                final offsetAnimation =
                                    Tween<Offset>(
                                      begin: const Offset(0, 1),
                                      end: Offset.zero,
                                    ).animate(
                                      CurvedAnimation(
                                        parent: animation,
                                        curve: Curves.easeOutCubic,
                                      ),
                                    );
                                return SlideTransition(
                                  position: offsetAnimation,
                                  child: child,
                                );
                              },
                          transitionDuration: const Duration(milliseconds: 350),
                        ),
                      );
                    }
                  },
                  child: ValueListenableBuilder<AppColorScheme>(
                    valueListenable: colorSchemeNotifier,
                    builder: (context, colorScheme, child) {
                      // final isSystem = colorScheme == AppColorScheme.system;
                      final isLight = Theme.of(context).brightness == Brightness.light;
                      // final isDark = Theme.of(context).brightness == Brightness.dark;
                      return Container(
                        margin: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: isLight ? Theme.of(context).colorScheme.secondaryContainer 
                                  : Theme.of(context).colorScheme.onSecondaryFixed,
                          borderRadius: BorderRadius.circular(16),
                        ),
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
                              valueListenable: (audioHandler as MyAudioHandler)
                                  .initializingNotifier,
                              builder: (context, isLoading, child) {
                                if (isLoading) {
                                  return Container(
                                    width: 50,
                                    height: 50,
                                    decoration: BoxDecoration(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.surfaceContainerHighest,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Center(
                                      child: SizedBox(
                                        width: 28,
                                        height: 28,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 3,
                                        ),
                                      ),
                                    ),
                                  );
                                }

                                final artUri = currentSong.artUri;

                                return ArtworkHeroCached(
                                  artUri: artUri,
                                  size: 50,
                                  borderRadius: BorderRadius.circular(8),
                                  heroTag:
                                      'now_playing_artwork_${(currentSong.extras?['songId'] ?? currentSong.id).toString()}',
                                  showPlaceholderIcon: true,
                                  isLoading:
                                      false, // El overlay maneja el loading externamente
                                );
                              },
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ValueListenableBuilder<bool>(
                                    valueListenable: overlayNextButtonEnabled,
                                    builder: (context, nextButtonEnabled, child) {
                                      // Ajustar el ancho máximo según si el botón next está habilitado
                                      final maxWidth = nextButtonEnabled 
                                          ? MediaQuery.of(context).size.width - 210 // Más espacio cuando hay botón next
                                          : MediaQuery.of(context).size.width - 162; // Espacio normal
                                      
                                      return TitleMarquee(
                                        text: currentSong.title,
                                        maxWidth: maxWidth,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleMedium,
                                      );
                                    },
                                  ),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          (currentSong.artist == null ||
                                                  currentSong.artist!.trim().isEmpty)
                                              ? 'Desconocido'
                                              : currentSong.artist!,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodyMedium,
                                        ),
                                      ),
                                      Icon(
                                        Symbols.person_rounded,
                                        size: 14,
                                        color: Colors.transparent,
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
                                    valueListenable: _isPlayingNotifier,
                                    builder: (context, isPlaying, child) {
                                      return ValueListenableBuilder<AppColorScheme>(
                                        valueListenable: colorSchemeNotifier,
                                        builder: (context, colorScheme, child) {
                                          return Material(
                                            color: Colors.transparent,
                                            child: InkWell(
                                              customBorder: RoundedRectangleBorder(
                                                borderRadius: BorderRadius.circular(
                                                  isPlaying ? (40 / 3) : (40 / 2),
                                                ),
                                              ),
                                              splashColor: Colors.transparent,
                                              highlightColor: Colors.transparent,
                                              onTap: () {
                                                // Actualizar el estado inmediatamente para mejor UX
                                                _isPlayingNotifier.value = !isPlaying;
                                                
                                                // Ejecutar la acción de audio de forma asíncrona para no bloquear la UI
                                                Future.microtask(() {
                                                  if (isPlaying) {
                                                    audioHandler?.pause();
                                                  } else {
                                                    audioHandler?.play();
                                                  }
                                                });
                                              },
                                              child: AnimatedContainer(
                                                duration: const Duration(milliseconds: 250),
                                                curve: Curves.easeInOut,
                                                width: 40,
                                                height: 40,
                                                decoration: BoxDecoration(
                                                  color: colorScheme == AppColorScheme.amoled
                                                      ? Colors.white
                                                      : Theme.of(context).brightness == Brightness.light
                                                          ? Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.7)
                                                          : Theme.of(context).colorScheme.primary,
                                                  borderRadius: BorderRadius.circular(
                                                    isPlaying ? (40 / 3) : (40 / 2),
                                                  ),
                                                ),
                                                child: Center(
                                                  child: Icon(
                                                    isPlaying ? Symbols.pause_rounded : Symbols.play_arrow_rounded,
                                                    grade: 200,
                                                    size: 28,
                                                    fill: 1,
                                                    color: colorScheme == AppColorScheme.amoled
                                                        ? Colors.black
                                                        : Theme.of(context).brightness == Brightness.light
                                                          ? Theme.of(context).colorScheme.secondaryContainer
                                                          : Theme.of(context).colorScheme.onPrimary,
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
                                  valueListenable: overlayNextButtonEnabled,
                                  builder: (context, nextButtonEnabled, child) {
                                    if (!nextButtonEnabled) return const SizedBox.shrink();
                                    
                                    return Padding(
                                      padding: const EdgeInsets.only(left: 8.0),
                                      child: RepaintBoundary(
                                        child: ValueListenableBuilder<AppColorScheme>(
                                          valueListenable: colorSchemeNotifier,
                                          builder: (context, colorScheme, child) {
                                            return ScaleAnimatedButton(
                                              onTap: () {
                                                if (isLoading || !navigationEnabled) return;
                                                audioHandler?.skipToNext();
                                              },
                                              child: AnimatedContainer(
                                                duration: const Duration(milliseconds: 250),
                                                curve: Curves.easeInOut,
                                                width: 40,
                                                height: 40,
                                                decoration: BoxDecoration(
                                                  color: colorScheme == AppColorScheme.amoled
                                                      ? Colors.white
                                                      : Theme.of(context).brightness == Brightness.light
                                                          ? Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.7)
                                                          : Theme.of(context).colorScheme.primary,
                                                  borderRadius: BorderRadius.circular(20),
                                                ),
                                                child: Center(
                                                  child: Icon(
                                                    Symbols.skip_next_rounded,
                                                    grade: 200,
                                                    size: 24,
                                                    fill: 1,
                                                    color: colorScheme == AppColorScheme.amoled
                                                        ? Colors.black
                                                        : Theme.of(context).brightness == Brightness.light
                                                          ? Theme.of(context).colorScheme.secondaryContainer
                                                          : Theme.of(context).colorScheme.onPrimary,
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
                            valueListenable: colorSchemeNotifier,
                            builder: (context, colorScheme, child) {
                              return StreamBuilder<Duration>(
                                stream:
                                    (audioHandler as MyAudioHandler).positionStream,
                                initialData: Duration.zero,
                                builder: (context, posSnapshot) {
                                  final position =
                                      posSnapshot.data ?? Duration.zero;
                                  final hasDuration =
                                      duration != null &&
                                      duration.inMilliseconds > 0;

                                  return StreamBuilder<Duration?>(
                                    stream: (audioHandler as MyAudioHandler)
                                        .player
                                        .durationStream,
                                    builder: (context, durationSnapshot) {
                                      final fallbackDuration =
                                          durationSnapshot.data;
                                      final total = hasDuration
                                          ? duration.inMilliseconds
                                          : (fallbackDuration?.inMilliseconds ?? 1);
                                      final current = position.inMilliseconds.clamp(
                                        0,
                                        total,
                                      );

                                      return Column(
                                        children: [
                                          Container(
                                            decoration: BoxDecoration(
                                              borderRadius: BorderRadius.circular(8),
                                              border: Border.all(
                                                color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
                                                width: 0.5,
                                              ),
                                            ),
                                            child: ClipRRect(
                                              borderRadius: BorderRadius.circular(8),
                                              child: LinearProgressIndicator(
                                                // ignore: deprecated_member_use
                                                year2023: false,
                                                key: ValueKey(total),
                                                value: total > 0
                                                    ? current / total
                                                    : 0,
                                                minHeight: 4,
                                                borderRadius: BorderRadius.circular(
                                                  8,
                                                ),
                                                backgroundColor: Theme.of(
                                                  context,
                                                ).colorScheme.primary.withValues(alpha: 0.3),
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
