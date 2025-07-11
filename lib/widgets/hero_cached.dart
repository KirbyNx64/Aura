import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:music/main.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'dart:typed_data';
import 'dart:math';

class ArtworkHeroCached extends StatefulWidget {
  final int songId;
  final double size;
  final BorderRadius borderRadius;
  final String heroTag;
  final int? currentIndex;
  final List<int>? songIdList;
  final bool forceHighQuality;

  const ArtworkHeroCached({
    super.key,
    required this.songId,
    required this.size,
    required this.borderRadius,
    required this.heroTag,
    this.currentIndex,
    this.songIdList,
    this.forceHighQuality = false,
  });

  @override
  State<ArtworkHeroCached> createState() => _ArtworkHeroCachedState();
}

class _ArtworkHeroCachedState extends State<ArtworkHeroCached> {
  static final Map<int, Uint8List> _artworkCache = {};
  Uint8List? _artwork;
  int? _lastRequestedId;

  @override
  void initState() {
    super.initState();
    _loadArtwork();
    _preloadNearbyArtworks();
  }

  Future<void> _loadArtwork() async {
    final currentId = widget.songId;
    _lastRequestedId = currentId;

    if (_artworkCache.containsKey(currentId)) {
      setState(() {
        _artwork = _artworkCache[currentId];
      });
      return;
    }
    
    // Determina el tamaño basado en el contexto
    int size = 256; // Tamaño por defecto para precarga rápida
    
    // Si se fuerza alta calidad Y es la canción actual, usar máxima calidad
    if (widget.forceHighQuality && widget.currentIndex != null && widget.songIdList != null) {
      final currentSongId = (audioHandler as MyAudioHandler).mediaItem.value?.extras?['songId'] as int?;
      if (currentSongId == currentId) {
        size = max(512, (widget.size * 2.5).toInt());
      } else {
        // Para las demás canciones en el player, usar calidad media
        size = max(384, (widget.size * 1.2).toInt());
      }
    }
    // Si es la canción actual en reproducción (sin forceHighQuality), usa alta calidad
    else if (widget.currentIndex != null && widget.songIdList != null) {
      final currentSongId = (audioHandler as MyAudioHandler).mediaItem.value?.extras?['songId'] as int?;
      if (currentSongId == currentId) {
        size = max(512, (widget.size * 2).toInt());
      }
    }
    // Si el widget es muy grande (>200px), siempre usa alta calidad
    else if (widget.size > 200) {
      size = max(512, (widget.size * 1.5).toInt());
    }
    
    final data = await OnAudioQuery().queryArtwork(
      currentId,
      ArtworkType.AUDIO,
      format: ArtworkFormat.PNG,
      size: size,
    );
    final artworkData = data ?? Uint8List(0);
    _artworkCache[currentId] = artworkData;
    if (mounted && _lastRequestedId == currentId) {
      setState(() {
        _artwork = artworkData;
      });
    } else if (mounted && _lastRequestedId != currentId) {
      _loadArtwork();
    }
  }

  Future<void> _preloadNearbyArtworks() async {
    if (widget.currentIndex == null ||
        widget.songIdList == null ||
        widget.songIdList!.isEmpty) {
      return;
    }

    final listLength = widget.songIdList!.length;
    final current = widget.currentIndex!.clamp(0, listLength - 1);
    final start = max(current - 25, 0);
    final end = min(current + 25, listLength - 1);

    for (int i = start; i <= end; i++) {
      final id = widget.songIdList![i];
      if (_artworkCache.containsKey(id)) continue;
      
      // Determina la calidad de precarga basada en la proximidad y si se fuerza alta calidad
      int preloadSize = 256; // Calidad baja por defecto
      
      if (widget.forceHighQuality) {
        // Si se fuerza alta calidad, usar calidad media para precarga (más rápido)
        final distance = (i - current).abs();
        if (distance <= 5) {
          preloadSize = 384; // Calidad media para las próximas 5 canciones
        } else if (distance <= 10) {
          preloadSize = 320; // Calidad media-baja para las próximas 10
        } else {
          preloadSize = 256; // Calidad baja para el resto
        }
      } else {
        // Calidad normal para precarga
        final distance = (i - current).abs();
        if (distance <= 5) {
          preloadSize = 384; // Calidad media para las próximas 5 canciones
        } else if (distance <= 10) {
          preloadSize = 320; // Calidad media-baja para las próximas 10
        }
      }

      final data = await OnAudioQuery().queryArtwork(
        id,
        ArtworkType.AUDIO,
        format: ArtworkFormat.PNG,
        size: preloadSize,
      );
      _artworkCache[id] = data ?? Uint8List(0);
    }
  }

  @override
  void didUpdateWidget(covariant ArtworkHeroCached oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.songId != widget.songId) {
      _artwork = null;
      _loadArtwork();
      _preloadNearbyArtworks();
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasArtwork = _artwork != null && _artwork!.isNotEmpty;
    return Hero(
      tag: widget.heroTag,
      child: ClipRRect(
        borderRadius: widget.borderRadius,
        child: hasArtwork
            ? Image.memory(
                _artwork!,
                width: max(widget.size, 1),
                height: max(widget.size, 1),
                fit: BoxFit.cover,
                // Solo limita el cache si no se está forzando alta calidad y la imagen es muy grande
                cacheWidth: widget.forceHighQuality ? null : max(widget.size.toInt(), 1),
              )
            : Container(
                width: max(widget.size, 1),
                height: max(widget.size, 1),
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Icon(Icons.music_note, size: widget.size * 0.6),
              ),
      ),
    );
  }
}

