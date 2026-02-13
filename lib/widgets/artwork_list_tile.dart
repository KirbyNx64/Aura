import 'dart:io';
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

  @override
  void initState() {
    super.initState();
    // Intento de carga síncrona desde caché para evitar el parpadeo inicial
    final cachedArtwork = artworkCache[widget.songPath];
    if (cachedArtwork != null) {
      _artUri = cachedArtwork;
    } else if (widget.artUri != null &&
        (widget.artUri!.isScheme('http') || widget.artUri!.isScheme('https'))) {
      _artUri = widget.artUri;
    } else {
      _loadArtwork();
    }
  }

  @override
  void didUpdateWidget(ArtworkListTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.songId != widget.songId ||
        oldWidget.songPath != widget.songPath) {
      _loadArtwork();
    }
  }

  Future<void> _loadArtwork() async {
    // Si hay artUri remota, no busques local
    if (widget.artUri != null &&
        (widget.artUri!.isScheme('http') || widget.artUri!.isScheme('https'))) {
      if (mounted) setState(() => _artUri = widget.artUri);
      return;
    }

    // Verificar si está en caché primero
    final cache = artworkCache;
    final cachedArtwork = cache[widget.songPath];
    if (cachedArtwork != null) {
      if (mounted) setState(() => _artUri = cachedArtwork);
      return;
    }

    // Si no está en caché, cargar desde la base de datos
    final uri = await getOrCacheArtwork(widget.songId, widget.songPath);
    if (mounted) {
      setState(() => _artUri = uri);
    }
  }

  @override
  Widget build(BuildContext context) {
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
    if (widget.artUri != null &&
        (widget.artUri!.isScheme('http') || widget.artUri!.isScheme('https'))) {
      return ClipRRect(
        borderRadius: widget.borderRadius,
        child: Image.network(
          widget.artUri.toString(),
          width: w,
          height: h,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          cacheWidth: 400,
          cacheHeight: 400,
          errorBuilder: (context, error, stackTrace) {
            return _buildFallbackIcon(w, h);
          },
        ),
      );
    }
    if (_artUri != null) {
      return ClipRRect(
        borderRadius: widget.borderRadius,
        child: Image.file(
          File(_artUri!.toFilePath()),
          width: w,
          height: h,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) {
            return _buildFallbackIcon(w, h);
          },
        ),
      );
    } else {
      return _buildFallbackIcon(w, h);
    }
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
