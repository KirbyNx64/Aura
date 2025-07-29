import 'package:flutter/material.dart';
import 'dart:typed_data';
import '../utils/audio/optimized_album_art_loader.dart';

/// Widget optimizado para mostrar carátulas con cancelación
class OptimizedArtworkWidget extends StatefulWidget {
  final int songId;
  final String songPath;
  final double size;
  final double? borderRadius;
  final Widget? placeholder;
  final Widget? errorWidget;
  final BoxFit fit;

  const OptimizedArtworkWidget({
    super.key,
    required this.songId,
    required this.songPath,
    required this.size,
    this.borderRadius,
    this.placeholder,
    this.errorWidget,
    this.fit = BoxFit.cover,
  });

  @override
  State<OptimizedArtworkWidget> createState() => _OptimizedArtworkWidgetState();
}

class _OptimizedArtworkWidgetState extends State<OptimizedArtworkWidget> {
  Uint8List? _artworkBytes;
  bool _isLoading = false;
  bool _hasError = false;
  CancellationToken? _cancellationToken;

  @override
  void initState() {
    super.initState();
    _loadArtwork();
  }

  @override
  void didUpdateWidget(OptimizedArtworkWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    // Si cambió la canción, cancelar carga anterior y cargar nueva
    if (oldWidget.songId != widget.songId || oldWidget.songPath != widget.songPath) {
      _cancellationToken?.cancel();
      _loadArtwork();
    }
  }

  @override
  void dispose() {
    _cancellationToken?.cancel();
    super.dispose();
  }

  Future<void> _loadArtwork() async {
    if (!mounted) return;

    setState(() {
      _isLoading = true;
      _hasError = false;
      _artworkBytes = null;
    });

    // Crear nuevo token de cancelación
    _cancellationToken = CancellationToken();

    try {
      final loader = OptimizedAlbumArtLoader();
      final bytes = await loader.loadAlbumArt(
        widget.songId,
        widget.songPath,
        size: widget.size,
        token: _cancellationToken,
      );

      if (!mounted) return;

      if (bytes != null) {
        setState(() {
          _artworkBytes = bytes;
          _isLoading = false;
          _hasError = false;
        });
      } else {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _hasError = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return _buildLoadingWidget();
    }

    if (_hasError || _artworkBytes == null) {
      return _buildErrorWidget();
    }

    return _buildArtworkWidget();
  }

  Widget _buildLoadingWidget() {
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: Colors.grey[300],
        borderRadius: widget.borderRadius != null 
            ? BorderRadius.circular(widget.borderRadius!)
            : null,
      ),
      child: widget.placeholder ?? const Center(
        child: CircularProgressIndicator(),
      ),
    );
  }

  Widget _buildErrorWidget() {
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: widget.borderRadius != null 
            ? BorderRadius.circular(widget.borderRadius!)
            : null,
      ),
      child: widget.errorWidget ?? const Center(
        child: Icon(Icons.music_note, color: Colors.grey),
      ),
    );
  }

  Widget _buildArtworkWidget() {
    return ClipRRect(
      borderRadius: widget.borderRadius != null 
          ? BorderRadius.circular(widget.borderRadius!)
          : BorderRadius.zero,
      child: Image.memory(
        _artworkBytes!,
        width: widget.size,
        height: widget.size,
        fit: widget.fit,
        errorBuilder: (context, error, stackTrace) => _buildErrorWidget(),
      ),
    );
  }
}

/// Widget para lista optimizada de carátulas
class OptimizedArtworkList extends StatefulWidget {
  final List<Map<String, dynamic>> songs;
  final double itemSize;
  final int crossAxisCount;
  final double spacing;
  final Widget Function(BuildContext, int)? itemBuilder;

  const OptimizedArtworkList({
    super.key,
    required this.songs,
    required this.itemSize,
    this.crossAxisCount = 3,
    this.spacing = 8.0,
    this.itemBuilder,
  });

  @override
  State<OptimizedArtworkList> createState() => _OptimizedArtworkListState();
}

class _OptimizedArtworkListState extends State<OptimizedArtworkList> {
  CancellationToken? _cancellationToken;

  @override
  void initState() {
    super.initState();
    _preloadArtworks();
  }

  @override
  void didUpdateWidget(OptimizedArtworkList oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    // Si cambió la lista, cancelar precarga anterior y precargar nueva
    if (oldWidget.songs != widget.songs) {
      _cancellationToken?.cancel();
      _preloadArtworks();
    }
  }

  @override
  void dispose() {
    _cancellationToken?.cancel();
    super.dispose();
  }

  Future<void> _preloadArtworks() async {
    if (widget.songs.isEmpty) return;

    _cancellationToken = CancellationToken();
    
    try {
      final loader = OptimizedAlbumArtLoader();
      await loader.loadMultipleAlbumArts(
        widget.songs,
        token: _cancellationToken,
      );
    } catch (e) {
      // Error silencioso
    }
  }

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: widget.crossAxisCount,
        childAspectRatio: 1.0,
        crossAxisSpacing: widget.spacing,
        mainAxisSpacing: widget.spacing,
      ),
      itemCount: widget.songs.length,
      itemBuilder: widget.itemBuilder ?? _defaultItemBuilder,
    );
  }

  Widget _defaultItemBuilder(BuildContext context, int index) {
    final song = widget.songs[index];
    final songId = song['id'] as int;
    final songPath = song['data'] as String;

    return OptimizedArtworkWidget(
      songId: songId,
      songPath: songPath,
      size: widget.itemSize,
      borderRadius: 8.0,
    );
  }
}

/// Widget para carátula con placeholder personalizado
class OptimizedArtworkWithPlaceholder extends StatelessWidget {
  final int songId;
  final String songPath;
  final double size;
  final Widget placeholder;
  final Widget? errorWidget;
  final double? borderRadius;

  const OptimizedArtworkWithPlaceholder({
    super.key,
    required this.songId,
    required this.songPath,
    required this.size,
    required this.placeholder,
    this.errorWidget,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    return OptimizedArtworkWidget(
      songId: songId,
      songPath: songPath,
      size: size,
      placeholder: placeholder,
      errorWidget: errorWidget,
      borderRadius: borderRadius,
    );
  }
} 