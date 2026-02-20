import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:palette_generator_master/palette_generator_master.dart';
import 'package:audio_service/audio_service.dart';
import 'package:music/utils/audio/background_audio_handler.dart'
    show artworkCache, getOrCacheArtwork;
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/theme_preferences.dart';

/// Controlador de tema dinámico.
/// Escucha los cambios de canción y extrae el color dominante de la carátula.
class ThemeController {
  ThemeController._();
  static final ThemeController instance = ThemeController._();

  /// Color dominante extraído de la carátula actual
  final ValueNotifier<Color?> dominantColor = ValueNotifier<Color?>(null);

  /// ID de la canción para la cual ya se extrajo el color exitosamente
  String? _extractedSongId;

  /// Flag para evitar procesamiento concurrente
  bool _processing = false;

  Timer? _debounceTimer;
  MediaItem? _pendingMediaItem;
  String? _pendingSongId;
  bool _retryPending = false;

  /// Suscripción al stream de mediaItem
  StreamSubscription<MediaItem?>? _subscription;

  /// Inicia la escucha del stream de mediaItem del audioHandler.
  void startListening(Stream<MediaItem?> mediaItemStream) {
    _subscription?.cancel();
    _subscription = mediaItemStream.listen(_onMediaItemChanged);
  }

  /// Detiene la escucha
  void stopListening() {
    _subscription?.cancel();
    _subscription = null;
  }

  /// Callback cuando cambia el mediaItem
  void _onMediaItemChanged(MediaItem? mediaItem) {
    if (colorSchemeNotifier.value != AppColorScheme.dynamic &&
        !useDynamicColorBackgroundNotifier.value) {
      return;
    }
    if (mediaItem == null) return;

    final songId = (mediaItem.extras?['songId'] ?? mediaItem.id).toString();

    // Cancelar timer anterior
    _debounceTimer?.cancel();

    // Actualizar estado pendiente
    _pendingMediaItem = mediaItem;
    _pendingSongId = songId;
    _retryPending = false;

    // Iniciar nuevo timer (debounce de 300ms)
    _debounceTimer = Timer(const Duration(milliseconds: 200), _processPending);
  }

  /// Procesa la canción pendiente si es necesario
  Future<void> _processPending() async {
    if (_processing) {
      _retryPending = true;
      return;
    }

    final item = _pendingMediaItem;
    final id = _pendingSongId;

    if (item == null || id == null) return;
    if (id == _extractedSongId) return;

    _processing = true;
    try {
      await _resolveAndExtract(item, id);
    } finally {
      _processing = false;
      if (_retryPending) {
        _retryPending = false;
        _processPending();
      }
    }
  }

  /// Resuelve la imagen de la carátula y extrae el color
  Future<void> _resolveAndExtract(MediaItem mediaItem, String songId) async {
    // La guardia _processing ahora se maneja en _processPending

    ImageProvider? imageProvider;

    // 1. Intentar desde artUri del mediaItem
    final artUri = mediaItem.artUri;
    if (artUri != null) {
      imageProvider = _providerFromUri(artUri);
    }

    // 2. Intentar desde artworkCache global
    if (imageProvider == null) {
      final songPath = mediaItem.extras?['data'] as String?;
      if (songPath != null) {
        final cachedUri = artworkCache[songPath];
        if (cachedUri != null) {
          imageProvider = _providerFromUri(cachedUri);
        }

        // 3. Si aún no hay imagen, cargarla con getOrCacheArtwork
        if (imageProvider == null) {
          final songIdInt = mediaItem.extras?['songId'] as int?;
          if (songIdInt != null) {
            try {
              final uri = await getOrCacheArtwork(
                songIdInt,
                songPath,
              ).timeout(const Duration(seconds: 3));
              if (uri != null) {
                imageProvider = _providerFromUri(uri);
              }
            } catch (_) {}
          }
        }
      }
    }

    if (imageProvider != null) {
      await _extractColor(imageProvider, songId);
    }
  }

  /// Crea un ImageProvider desde un Uri, verificando que el archivo exista
  ImageProvider? _providerFromUri(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'file' || scheme == 'content') {
      try {
        final file = File(uri.toFilePath());
        if (file.existsSync() && file.lengthSync() > 0) {
          return FileImage(file);
        }
      } catch (_) {}
    } else if (scheme == 'http' || scheme == 'https') {
      return NetworkImage(uri.toString());
    }
    return null;
  }

  /// Extrae el color dominante de la imagen
  Future<void> _extractColor(ImageProvider imageProvider, String songId) async {
    // La guardia y estado _processing se manejan en _processPending

    try {
      final generator = await PaletteGeneratorMaster.fromImageProvider(
        ResizeImage(imageProvider, height: 50, width: 50),
        maximumColorCount: 16,
      );

      final paletteColor =
          generator.vibrantColor ??
          generator.dominantColor ??
          generator.darkVibrantColor ??
          generator.lightVibrantColor ??
          generator.mutedColor;

      if (paletteColor != null) {
        dominantColor.value = paletteColor.color;
        _extractedSongId = songId;
      }
    } catch (_) {
      // Error silencioso — mantener el color anterior
    }
  }
}
