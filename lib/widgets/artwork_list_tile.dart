import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/theme_preferences.dart';

class ArtworkListTile extends StatefulWidget {
  final int songId;
  final String songPath;
  final Uri? artUri;
  final double? width;
  final double? height;
  final double size;
  final BorderRadius borderRadius;

  const ArtworkListTile({
    super.key,
    required this.songId,
    required this.songPath,
    this.size = 50,
    this.width,
    this.height,
    required this.borderRadius,
    this.artUri,
  });

  @override
  State<ArtworkListTile> createState() => _ArtworkListTileState();
}

class _ArtworkListTileState extends State<ArtworkListTile> {
  Uri? _artUri;

  bool _isRemoteUri(Uri uri) => uri.isScheme('http') || uri.isScheme('https');

  bool _isLocalFileUri(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    return scheme.isEmpty || scheme == 'file';
  }

  bool _isValidCachedFile(Uri uri) {
    if (!_isLocalFileUri(uri)) return false;
    try {
      final file = File(uri.toFilePath());
      return file.existsSync() && file.lengthSync() > 0;
    } catch (_) {
      return false;
    }
  }

  void _setArtUriIfChanged(Uri? nextUri) {
    if (_artUri == nextUri) return;
    if (!mounted) return;
    setState(() => _artUri = nextUri);
  }

  @override
  void initState() {
    super.initState();
    // Prioridad 1: usar artUri explícito del item (local o remoto).
    if (widget.artUri != null) {
      _artUri = widget.artUri;
      return;
    }

    // Prioridad 2: usar caché local solo si el archivo sigue siendo válido.
    final cachedArtwork = artworkCache[widget.songPath];
    if (cachedArtwork != null && _isValidCachedFile(cachedArtwork)) {
      _artUri = cachedArtwork;
      return;
    }

    _loadArtwork();
  }

  @override
  void didUpdateWidget(ArtworkListTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    final songChanged =
        oldWidget.songId != widget.songId ||
        oldWidget.songPath != widget.songPath;
    final artUriChanged = oldWidget.artUri != widget.artUri;

    // Si llega una carátula nueva desde la cola (ej: primera canción), reflejarla al instante.
    if (artUriChanged && widget.artUri != null) {
      _setArtUriIfChanged(widget.artUri);
      return;
    }

    if (songChanged || artUriChanged) {
      if (songChanged) {
        _artUri = null;
      }
      _loadArtwork();
    }
  }

  Future<void> _loadArtwork() async {
    // Si hay artUri en el MediaItem, úsala directamente.
    if (widget.artUri != null) {
      _setArtUriIfChanged(widget.artUri);
      return;
    }

    if (widget.songId <= 0 || widget.songPath.isEmpty) {
      _setArtUriIfChanged(null);
      return;
    }

    // Verificar si está en caché primero
    final cache = artworkCache;
    final cachedArtwork = cache[widget.songPath];
    if (cachedArtwork != null && _isValidCachedFile(cachedArtwork)) {
      _setArtUriIfChanged(cachedArtwork);
      return;
    }

    // Si no está en caché, cargar desde la base de datos
    final uri = await getOrCacheArtwork(widget.songId, widget.songPath);
    if (!mounted) return;

    if (uri != null && _isValidCachedFile(uri)) {
      _setArtUriIfChanged(uri);
    } else {
      _setArtUriIfChanged(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Optimización: evitar LayoutBuilder si width y height están definidos
    // Optimización: evitar LayoutBuilder si width y height están definidos y son finitos
    if (widget.width != null &&
        widget.height != null &&
        widget.width!.isFinite &&
        widget.height!.isFinite) {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: _buildArtworkContent(widget.width!, widget.height!),
      );
    }

    // Solo usar LayoutBuilder si es necesario (width o height son null/infinitos)
    return LayoutBuilder(
      builder: (context, constraints) {
        double w = widget.width ?? widget.size;
        double h = widget.height ?? widget.size;

        if (w.isInfinite) {
          w = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : widget.size;
        }
        if (h.isInfinite) {
          h = constraints.maxHeight.isFinite
              ? constraints.maxHeight
              : widget.size;
        }

        return SizedBox(width: w, height: h, child: _buildArtworkContent(w, h));
      },
    );
  }

  Widget _buildArtworkContent(double w, double h) {
    // IMPORTANT: for listas, decodificar al tamaño real evita jank en scroll.
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final int cacheW = max(1, (w * dpr).round());

    final effectiveArtUri = widget.artUri ?? _artUri;
    if (effectiveArtUri != null && _isRemoteUri(effectiveArtUri)) {
      return ClipRRect(
        borderRadius: widget.borderRadius,
        child: Image.network(
          effectiveArtUri.toString(),
          width: w,
          height: h,
          fit: BoxFit.cover,
          alignment: Alignment.center,
          gaplessPlayback: true,
          // Decodificar cerca del tamaño final reduce trabajo en scroll.
          cacheWidth: cacheW,
          filterQuality: FilterQuality.low,
          errorBuilder: (context, error, stackTrace) {
            return _buildFallbackIcon(w, h);
          },
        ),
      );
    }
    if (effectiveArtUri != null && _isLocalFileUri(effectiveArtUri)) {
      return ClipRRect(
        borderRadius: widget.borderRadius,
        child: Builder(
          builder: (context) {
            try {
              return Image.file(
                File(effectiveArtUri.toFilePath()),
                width: w,
                height: h,
                fit: BoxFit.cover,
                alignment: Alignment.center,
                gaplessPlayback: true,
                // Decodificar cerca del tamaño final reduce trabajo en scroll.
                cacheWidth: cacheW,
                filterQuality: FilterQuality.low,
                errorBuilder: (context, error, stackTrace) {
                  return _buildFallbackIcon(w, h);
                },
              );
            } catch (_) {
              return _buildFallbackIcon(w, h);
            }
          },
        ),
      );
    }

    return _buildFallbackIcon(w, h);
  }

  Widget _buildFallbackIcon(double w, double h) {
    final isSystem = colorSchemeNotifier.value == AppColorScheme.system;
    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: isSystem
            ? Theme.of(
                context,
              ).colorScheme.secondaryContainer.withValues(alpha: 0.5)
            : Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: widget.borderRadius,
      ),
      child: Icon(
        Icons.music_note,
        size: (w < h ? w : h) * 0.5,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
  }
}
