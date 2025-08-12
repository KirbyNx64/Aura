import 'package:flutter/material.dart';
import 'dart:io';

class ArtworkHeroCached extends StatelessWidget {
  final Uri? artUri;
  final double size;
  final BorderRadius borderRadius;
  final String heroTag;
  final bool showPlaceholderIcon;

  const ArtworkHeroCached({
    super.key,
    required this.artUri,
    required this.size,
    required this.borderRadius,
    required this.heroTag,
    this.showPlaceholderIcon = true,
  });

  @override
  Widget build(BuildContext context) {
    return Hero(
      key: Key(heroTag),
      tag: heroTag,
      child: ClipRRect(
        borderRadius: borderRadius,
        child: artUri != null && File(artUri!.toFilePath()).existsSync()
            ? Image.file(
                File(artUri!.toFilePath()),
                width: size,
                height: size,
                fit: BoxFit.cover,
              )
            : Container(
                width: size,
                height: size,
                color: Theme.of(context).colorScheme.surfaceContainer,
                child: showPlaceholderIcon
                    ? Icon(Icons.music_note, size: size * 0.6)
                    : null,
              ),
      ),
    );
  }
}