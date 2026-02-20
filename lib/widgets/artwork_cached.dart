import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:async';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:music/utils/audio/background_audio_handler.dart';

/// Widget optimizado para mostrar carátulas en apps de música.
/// Evita parpadeos al cambiar de canción usando mejor el caché y manteniendo
/// la carátula anterior durante las transiciones.
class ArtworkCached extends StatefulWidget {
  final Uri? artUri;
  final double size;
  final BorderRadius borderRadius;
  final bool showPlaceholderIcon;
  final String? songPath; // Para verificar caché cuando artUri es null
  final int? songId; // Para cargar carátula si no está en caché

  const ArtworkCached({
    super.key,
    this.artUri,
    required this.size,
    required this.borderRadius,
    this.showPlaceholderIcon = true,
    this.songPath,
    this.songId,
  });

  @override
  State<ArtworkCached> createState() => _ArtworkCachedState();
}

class _ArtworkCachedState extends State<ArtworkCached> {
  Uri? _displayedArtUri;
  Uri? _previousArtUri;
  Timer? _loadTimer;
  Timer? _cacheCheckTimer;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    // Inicializar inmediatamente con lo que tengamos disponible
    _initializeArtwork();
  }

  void _initializeArtwork() {
    // Prioridad 1: Si hay artUri, usarlo inmediatamente
    if (widget.artUri != null) {
      _displayedArtUri = widget.artUri;
      _isLoading = false;
      return;
    }

    // Prioridad 2: Verificar caché inmediatamente (síncrono)
    if (widget.songPath != null) {
      final cache = artworkCache;
      final cachedArtwork = cache[widget.songPath!];
      if (cachedArtwork != null) {
        _displayedArtUri = cachedArtwork;
        _isLoading = false;
        return;
      }
    }

    // Si no hay nada disponible, intentar cargar de forma asíncrona
    _isLoading = true;
    if (widget.songPath != null && widget.songId != null) {
      // Cargar inmediatamente sin delay
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadArtworkAsync();
        // También verificar caché periódicamente mientras carga
        _startCacheCheckTimer();
      });
    } else {
      _isLoading = false;
    }
  }

  void _startCacheCheckTimer() {
    _cacheCheckTimer?.cancel();
    int attempts = 0;
    const maxAttempts = 10; // Verificar hasta 10 veces (2 segundos)
    
    _cacheCheckTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) {
      if (!mounted || _displayedArtUri != null || attempts >= maxAttempts) {
        timer.cancel();
        _cacheCheckTimer = null;
        return;
      }

      attempts++;
      
      // Verificar si la carátula apareció en el caché
      if (widget.songPath != null) {
        final cache = artworkCache;
        final cachedArtwork = cache[widget.songPath!];
        if (cachedArtwork != null && cachedArtwork != _displayedArtUri) {
          // Carátula encontrada en caché!
          _previousArtUri = _displayedArtUri;
          _displayedArtUri = cachedArtwork;
          _isLoading = false;
          timer.cancel();
          _cacheCheckTimer = null;
          setState(() {});
        }
      }
    });
  }

  @override
  void didUpdateWidget(ArtworkCached oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Si cambió la canción (songPath o songId)
    final songChanged = widget.songPath != oldWidget.songPath ||
        widget.songId != oldWidget.songId;

    // Si cambió el artUri o la canción
    if (widget.artUri != oldWidget.artUri || songChanged) {
      _updateDisplayedArtwork();
    }
  }

  void _updateDisplayedArtwork() {
    _loadTimer?.cancel();

    // Guardar la carátula anterior antes de cambiar
    final oldDisplayedUri = _displayedArtUri;

    // Prioridad 1: Si hay artUri nuevo, usarlo inmediatamente
    if (widget.artUri != null) {
      _previousArtUri = oldDisplayedUri;
      _displayedArtUri = widget.artUri;
      _isLoading = false;
      if (mounted) setState(() {});
      return;
    }

    // Prioridad 2: Verificar caché inmediatamente (más rápido)
    if (widget.songPath != null) {
      final cache = artworkCache;
      final cachedArtwork = cache[widget.songPath!];
      if (cachedArtwork != null) {
        // Usar inmediatamente lo que haya en caché
        _previousArtUri = oldDisplayedUri;
        _displayedArtUri = cachedArtwork;
        _isLoading = false;
        if (mounted) setState(() {});
        return;
      }
    }

    // Prioridad 3: Mantener carátula anterior durante transición
    if (oldDisplayedUri != null) {
      // Mantener la anterior mientras se carga la nueva
      _previousArtUri = oldDisplayedUri;
      _isLoading = true;
      if (mounted) setState(() {});

      // Intentar cargar desde caché o cargar de forma asíncrona
      if (widget.songPath != null && widget.songId != null) {
        // Cargar inmediatamente sin delay
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _loadArtworkAsync();
            // También verificar caché periódicamente mientras carga
            _startCacheCheckTimer();
          }
        });
      } else {
        // Si no hay datos para cargar, mantener la anterior
        _isLoading = false;
      }
    } else {
      // No hay carátula anterior, intentar cargar inmediatamente
      if (widget.songPath != null && widget.songId != null) {
        _isLoading = true;
        if (mounted) setState(() {});
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _loadArtworkAsync();
            // También verificar caché periódicamente mientras carga
            _startCacheCheckTimer();
          }
        });
      } else {
        _isLoading = false;
        _displayedArtUri = null;
        if (mounted) setState(() {});
      }
    }
  }

  Future<void> _loadArtworkAsync() async {
    if (widget.songPath == null || widget.songId == null) {
      _isLoading = false;
      if (mounted) setState(() {});
      return;
    }

    // Guardar valores actuales para verificar después de operaciones asíncronas
    final currentSongPath = widget.songPath;
    final currentSongId = widget.songId;

    if (!mounted) return;

    try {
      // Verificar caché nuevamente (puede haber cambiado mientras esperábamos)
      final cache = artworkCache;
      final cachedArtwork = cache[currentSongPath!];
      if (cachedArtwork != null) {
        try {
          final file = File(cachedArtwork.toFilePath());
          if (await file.exists() && await file.length() > 0) {
            if (mounted && widget.songPath == currentSongPath) {
              _previousArtUri = _displayedArtUri;
              _displayedArtUri = cachedArtwork;
              _isLoading = false;
              setState(() {});
              return;
            }
          }
        } catch (e) {
          // Archivo no válido, continuar con carga
        }
      }

      // Cargar desde el sistema de caché optimizado
      final artUri = await getOrCacheArtwork(
        currentSongId!,
        currentSongPath,
      ).timeout(const Duration(milliseconds: 2000));

      if (artUri != null && mounted) {
        // Verificar que aún es la misma canción
        if (widget.songPath == currentSongPath) {
          try {
            final file = File(artUri.toFilePath());
            if (await file.exists() && await file.length() > 0) {
              _previousArtUri = _displayedArtUri;
              _displayedArtUri = artUri;
              _isLoading = false;
              setState(() {});
              return;
            }
          } catch (e) {
            // Archivo no válido
          }
        }
      }

      // No se pudo cargar la carátula
      if (mounted && widget.songPath == currentSongPath && widget.artUri == null) {
        _isLoading = false;
        // Solo mostrar placeholder si realmente no hay nada que mostrar
        if (_displayedArtUri == null && _previousArtUri == null) {
          setState(() {});
        }
      }
    } catch (e) {
      // Error silencioso - mantener estado actual
      if (mounted && widget.songPath == currentSongPath) {
        _isLoading = false;
        // Solo actualizar si realmente no hay nada que mostrar
        if (_displayedArtUri == null && _previousArtUri == null) {
          setState(() {});
        }
      }
    }
  }

  @override
  void dispose() {
    _loadTimer?.cancel();
    _cacheCheckTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: widget.borderRadius,
      child: _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    // Si hay carátula para mostrar, mostrarla
    if (_displayedArtUri != null) {
      return Image.file(
        File(_displayedArtUri!.toFilePath()),
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          // Si la imagen se cargó sincrónicamente, mostrarla inmediatamente
          if (wasSynchronouslyLoaded) {
            return child;
          }
          // Si está cargando, mostrar con fade-in suave
          return AnimatedOpacity(
            opacity: frame == null ? 0.0 : 1.0,
            duration: const Duration(milliseconds: 0),
            child: child,
          );
        },
        errorBuilder: (context, error, stackTrace) {
          // Si hay error, intentar cargar desde caché nuevamente o mostrar placeholder
          if (widget.songPath != null) {
            final cache = artworkCache;
            final cachedArtwork = cache[widget.songPath!];
            if (cachedArtwork != null && cachedArtwork != _displayedArtUri) {
              // Intentar con otra carátula del caché
              return Image.file(
                File(cachedArtwork.toFilePath()),
                width: widget.size,
                height: widget.size,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) {
                  return _buildPlaceholder(context);
                },
              );
            }
          }
          return _buildPlaceholder(context);
        },
      );
    }

    // Si está cargando, intentar mostrar desde caché mientras carga
    if (_isLoading) {
      // Verificar caché una vez más antes de mostrar placeholder
      if (widget.songPath != null) {
        final cache = artworkCache;
        final cachedArtwork = cache[widget.songPath!];
        if (cachedArtwork != null) {
          return Image.file(
            File(cachedArtwork.toFilePath()),
            width: widget.size,
            height: widget.size,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              return _buildPlaceholder(context);
            },
          );
        }
      }

      // Si hay carátula anterior, mantenerla mientras carga
      if (_previousArtUri != null) {
        return Image.file(
          File(_previousArtUri!.toFilePath()),
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            return _buildPlaceholder(context);
          },
        );
      }

      // Aún no sabemos si tiene carátula y no hay nada que mostrar:
      // mostrar completamente transparente, sin fondo ni ícono.
      return SizedBox(
        width: widget.size,
        height: widget.size,
      );
    }

    // Si no hay carátula disponible, mostrar placeholder
    return _buildPlaceholder(context);
  }

  Widget _buildPlaceholder(BuildContext context) {
    final isSystem = colorSchemeNotifier.value == AppColorScheme.system;
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: isSystem
            ? Theme.of(context)
                .colorScheme
                .secondaryContainer
                .withValues(alpha: 0.5)
            : Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: widget.borderRadius,
      ),
      child: widget.showPlaceholderIcon
          ? Icon(Icons.music_note, size: widget.size * 0.6)
          : null,
    );
  }
}
