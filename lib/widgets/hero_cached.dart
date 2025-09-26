import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:async';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/theme_preferences.dart';

class ArtworkHeroCached extends StatefulWidget {
  final Uri? artUri;
  final double size;
  final BorderRadius borderRadius;
  final String heroTag;
  final bool showPlaceholderIcon;
  final bool isLoading;

  const ArtworkHeroCached({
    super.key,
    required this.artUri,
    required this.size,
    required this.borderRadius,
    required this.heroTag,
    this.showPlaceholderIcon = true,
    this.isLoading = false,
  });

  @override
  State<ArtworkHeroCached> createState() => _ArtworkHeroCachedState();
}

class _ArtworkHeroCachedState extends State<ArtworkHeroCached> {
  Uri? _currentArtUri;
  Uri? _previousArtUri;
  Timer? _transitionTimer;
  bool _hasTemporaryFallback = false;

  @override
  void didUpdateWidget(ArtworkHeroCached oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Si la carátula cambió
    if (widget.artUri != oldWidget.artUri) {
      _transitionTimer?.cancel();

      // Si tenemos carátula actual y la nueva es null
      if (_currentArtUri != null && widget.artUri == null) {
        // Verificar si deberíamos mantener la anterior temporalmente
        // (cuando estamos cargando o en un cambio rápido de canciones)
        final shouldKeepFallback =
            widget.isLoading ||
            (oldWidget.artUri != null && widget.artUri == null);

        if (shouldKeepFallback) {
          // Mantener la anterior temporalmente
          _previousArtUri = _currentArtUri;
          _hasTemporaryFallback = true;

          // Limpiar después de un tiempo corto pero razonable
          _transitionTimer = Timer(const Duration(milliseconds: 200), () {
            if (mounted) {
              setState(() {
                _hasTemporaryFallback = false;
                _previousArtUri = null;
              });
            }
          });
        } else {
          // Cambio inmediato a placeholder
          _hasTemporaryFallback = false;
          _previousArtUri = null;
        }
      } else {
        // Cambio normal o nueva carátula disponible
        _hasTemporaryFallback = false;
        _previousArtUri = null;
      }

      _currentArtUri = widget.artUri;
    }
  }

  @override
  void initState() {
    super.initState();
    _currentArtUri = widget.artUri;
  }

  @override
  void dispose() {
    _transitionTimer?.cancel();
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

    // Si hay carátula actual, mostrarla
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

    // Si estamos esperando una nueva carátula y tenemos fallback, mostrar la anterior
    if (_hasTemporaryFallback && _previousArtUri != null) {
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

    // Si no hay carátula, mostrar placeholder
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