import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'dart:typed_data';

class ArtworkHeroCached extends StatefulWidget {
  final int songId;
  final double size;
  final BorderRadius borderRadius;
  final String heroTag;
  final int? currentIndex;
  final List<int>? songIdList;

  const ArtworkHeroCached({
    super.key,
    required this.songId,
    required this.size,
    required this.borderRadius,
    required this.heroTag,
    this.currentIndex,
    this.songIdList,
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
    final data = await OnAudioQuery().queryArtwork(
      currentId,
      ArtworkType.AUDIO,
      format: ArtworkFormat.PNG,
      size: widget.size.toInt() * widget.size.toInt(),
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
    if (widget.currentIndex == null || widget.songIdList == null) return;
    final start = (widget.currentIndex! - 25).clamp(
      0,
      widget.songIdList!.length - 1,
    );
    final end = (widget.currentIndex! + 25).clamp(
      0,
      widget.songIdList!.length - 1,
    );

    for (int i = start; i <= end; i++) {
      final id = widget.songIdList![i];
      if (_artworkCache.containsKey(id)) continue;
      final data = await OnAudioQuery().queryArtwork(
        id,
        ArtworkType.AUDIO,
        format: ArtworkFormat.PNG,
        size: widget.size.toInt() * widget.size.toInt(),
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
                width: widget.size,
                height: widget.size,
                fit: BoxFit.cover,
              )
            : Container(
                color: Theme.of(context).colorScheme.surfaceContainer,
                width: widget.size,
                height: widget.size,
                child: Center(
                  child: Icon(
                    Icons.music_note,
                    color: Colors.white70,
                    size: widget.size * 0.5,
                  ),
                ),
              ),
      ),
    );
  }
}
