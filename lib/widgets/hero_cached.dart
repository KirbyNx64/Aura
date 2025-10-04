import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:async';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:music/utils/audio/background_audio_handler.dart';

class ArtworkHeroCached extends StatefulWidget {
  final Uri? artUri;
  final double size;
  final BorderRadius borderRadius;
  final String heroTag;
  final bool showPlaceholderIcon;
  final bool isLoading;
  final String? songPath; // Para verificar caché cuando artUri es null

  const ArtworkHeroCached({
    super.key,
    required this.artUri,
    required this.size,
    required this.borderRadius,
    required this.heroTag,
    this.showPlaceholderIcon = true,
    this.isLoading = false,
    this.songPath,
  });

  @override
  State<ArtworkHeroCached> createState() => _ArtworkHeroCachedState();

  // Método estático para limpiar el fallback desde otras pantallas
  static void clearFallback() {
    _ArtworkHeroCachedState._clearAllFallbacks();
  }
}

class _ArtworkHeroCachedState extends State<ArtworkHeroCached> {
  Uri? _previousArtUri;
  Timer? _fallbackTimer;
  bool _hasFallback = false;
  
  // Lista estática para rastrear todas las instancias activas
  static final Set<_ArtworkHeroCachedState> _activeInstances = <_ArtworkHeroCachedState>{};
  
  // Método estático para limpiar todos los fallbacks
  static void _clearAllFallbacks() {
    for (final instance in _activeInstances) {
      instance._clearFallback();
    }
  }
  
  // Método para limpiar el fallback de esta instancia específica
  void _clearFallback() {
    _fallbackTimer?.cancel();
    if (mounted) {
      setState(() {
        _hasFallback = false;
        _previousArtUri = null;
      });
    }
  }

  @override
  void didUpdateWidget(ArtworkHeroCached oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    // Si cambió la carátula
    if (widget.artUri != oldWidget.artUri) {
      _fallbackTimer?.cancel();
      
      // Si teníamos carátula y ahora es null, mantener la anterior temporalmente
      if (oldWidget.artUri != null && widget.artUri == null) {
        _previousArtUri = oldWidget.artUri;
        _hasFallback = true;
        
        // Limpiar fallback después de un tiempo corto
        _fallbackTimer = Timer(const Duration(milliseconds: 300), () {
          _clearFallback();
        });
      } else {
        // Cambio normal, limpiar fallback
        _clearFallback();
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _activeInstances.add(this);
  }

  @override
  void dispose() {
    _activeInstances.remove(this);
    _fallbackTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: heroAnimationNotifier,
      builder: (context, useHeroAnimation, child) {
        final content = ClipRRect(
          borderRadius: widget.borderRadius,
          child: _buildContent(context),
        );

        // Si las animaciones hero están deshabilitadas, devolver solo el contenido
        if (!useHeroAnimation) {
          return content;
        }

        // Si están habilitadas, usar Hero
        return Hero(
          key: Key(widget.heroTag),
          tag: widget.heroTag,
          child: content,
        );
      },
    );
  }

  Widget _buildContent(BuildContext context) {
    // Si está cargando, mostrar contenedor transparente
    if (widget.isLoading) {
      return Container(
        width: widget.size,
        height: widget.size,
        color: Colors.transparent,
      );
    }

    // Prioridad 1: Si hay carátula actual en artUri, mostrarla inmediatamente
    if (widget.artUri != null) {
      return Image.file(
        File(widget.artUri!.toFilePath()),
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          return _buildPlaceholder(context);
        },
      );
    }

    // Prioridad 2: Si tenemos fallback temporal, mostrarlo
    if (_hasFallback && _previousArtUri != null) {
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

    // Prioridad 3: Verificar caché inmediatamente (más rápido que esperar)
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

    // Si no hay carátula disponible, mostrar placeholder
    return _buildPlaceholder(context);
  }

  Widget _buildPlaceholder(BuildContext context) {
    final isSystem = colorSchemeNotifier.value == AppColorScheme.system;
    return Container(
      width: widget.size,
      height: widget.size,
      color: isSystem ? Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.5) : Theme.of(context).colorScheme.surfaceContainer,
      child: widget.showPlaceholderIcon
          ? Icon(Icons.music_note, size: widget.size * 0.6)
          : null,
    );
  }
}