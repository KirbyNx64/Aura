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

  Timer? _debounceTimer;
  MediaItem? _pendingMediaItem;
  String? _pendingSongId;
  int _requestSequence = 0;
  int _latestRequestSequence = 0;
  DateTime? _lastMediaItemChangeAt;

  // Debounce adaptativo: rápido cuando el usuario se queda en una canción,
  // un poco más largo cuando está saltando varias muy seguido.
  static const Duration _songChangeDebounce = Duration(milliseconds: 90);
  static const Duration _songChangeDebounceRapid = Duration(milliseconds: 170);
  static const Duration _rapidSongChangeWindow = Duration(milliseconds: 420);
  // Evita que la resolución de carátula bloquee demasiado la siguiente canción.
  static const Duration _artworkResolveTimeout = Duration(milliseconds: 100);
  // Limita el tiempo de extracción de paleta para mantener sensación fluida.
  static const Duration _paletteExtractTimeout = Duration(milliseconds: 900);

  /// Suscripción al stream de mediaItem
  StreamSubscription<MediaItem?>? _subscription;

  /// Inicia la escucha del stream de mediaItem del audioHandler.
  void startListening(Stream<MediaItem?> mediaItemStream) {
    _subscription?.cancel();
    _subscription = mediaItemStream.listen(_onMediaItemChanged);
  }

  /// Detiene la escucha
  void stopListening() {
    _debounceTimer?.cancel();
    _pendingMediaItem = null;
    _pendingSongId = null;
    _subscription?.cancel();
    _subscription = null;
  }

  bool _isRequestCurrent(int requestSequence) {
    return requestSequence == _latestRequestSequence;
  }

  void _onMediaItemChanged(MediaItem? mediaItem) {
    if (colorSchemeNotifier.value != AppColorScheme.dynamic &&
        !useDynamicColorBackgroundNotifier.value &&
        !useDynamicColorInDialogsNotifier.value) {
      return;
    }
    if (mediaItem == null) return;

    final songId = (mediaItem.extras?['songId'] ?? mediaItem.id).toString();

    // Cancelar timer anterior
    _debounceTimer?.cancel();

    // Actualizar estado pendiente
    _pendingMediaItem = mediaItem;
    _pendingSongId = songId;

    final now = DateTime.now();
    final useRapidDebounce =
        _lastMediaItemChangeAt != null &&
        now.difference(_lastMediaItemChangeAt!) <= _rapidSongChangeWindow;
    _lastMediaItemChangeAt = now;
    final effectiveDebounce = useRapidDebounce
        ? _songChangeDebounceRapid
        : _songChangeDebounce;

    // Iniciar nuevo timer (debounce corto con trailing update).
    final requestSequence = ++_requestSequence;
    _latestRequestSequence = requestSequence;
    _debounceTimer = Timer(effectiveDebounce, () {
      unawaited(_processPending(requestSequence));
    });
  }

  /// Procesa la canción pendiente si es necesario
  Future<void> _processPending(int requestSequence) async {
    if (!_isRequestCurrent(requestSequence)) return;
    final item = _pendingMediaItem;
    final id = _pendingSongId;

    if (item == null || id == null) return;
    if (id == _extractedSongId) return;

    await _resolveAndExtract(item, id, requestSequence);
  }

  /// Resuelve la imagen de la carátula y extrae el color
  Future<void> _resolveAndExtract(
    MediaItem mediaItem,
    String songId,
    int requestSequence,
  ) async {
    if (!_isRequestCurrent(requestSequence)) return;
    ImageProvider? imageProvider;

    // 1. Intentar desde displayArtUri (suele ser más rápido y estable para stream).
    final displayArtRaw = mediaItem.extras?['displayArtUri']?.toString().trim();
    if (displayArtRaw != null && displayArtRaw.isNotEmpty) {
      final displayArtUri = Uri.tryParse(displayArtRaw);
      if (displayArtUri != null) {
        imageProvider = _providerFromUri(displayArtUri);
      }
    }

    // 2. Intentar desde artUri del mediaItem
    final artUri = mediaItem.artUri;
    if (imageProvider == null && artUri != null) {
      imageProvider = _providerFromUri(artUri);
    }

    if (!_isRequestCurrent(requestSequence)) return;

    // 3. Intentar desde artworkCache global
    if (imageProvider == null) {
      final songPath = mediaItem.extras?['data'] as String?;
      if (songPath != null) {
        final cachedUri = artworkCache[songPath];
        if (cachedUri != null) {
          imageProvider = _providerFromUri(cachedUri);
        }

        // 4. Si aún no hay imagen, cargarla con getOrCacheArtwork
        if (imageProvider == null) {
          final songIdInt = mediaItem.extras?['songId'] as int?;
          if (songIdInt != null) {
            try {
              final uri = await getOrCacheArtwork(
                songIdInt,
                songPath,
              ).timeout(_artworkResolveTimeout);
              if (!_isRequestCurrent(requestSequence)) return;
              if (uri != null) {
                imageProvider = _providerFromUri(uri);
              }
            } catch (_) {}
          }
        }
      }
    }

    if (imageProvider != null && _isRequestCurrent(requestSequence)) {
      await _extractColor(imageProvider, songId, requestSequence);
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
  Future<void> _extractColor(
    ImageProvider imageProvider,
    String songId,
    int requestSequence,
  ) async {
    if (!_isRequestCurrent(requestSequence)) return;
    try {
      final generator = await PaletteGeneratorMaster.fromImageProvider(
        ResizeImage(imageProvider, height: 50, width: 50),
        filters: [
          // Permitir colores un poco más oscuros y más claros para capturar tonos más ricos
          (HSLColor hsl) => hsl.lightness > 0.12 && hsl.lightness < 0.75,
          avoidRedBlackWhitePaletteFilterMaster,
        ],
      ).timeout(_paletteExtractTimeout);

      if (!_isRequestCurrent(requestSequence)) return;

      final paletteColor =
          generator.dominantColor ??
          generator.vibrantColor ??
          generator.lightVibrantColor ??
          generator.darkVibrantColor ??
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
