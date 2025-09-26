import 'package:flutter/material.dart';
import 'package:music/utils/yt_search/yt_screen.dart';
import 'package:music/utils/yt_search/service.dart';
import 'package:music/l10n/locale_provider.dart';

/// Muestra el YtPreviewPlayer como un modal
class YtPreviewModal {
  static void show(BuildContext context, List<dynamic> results) {
    try {
      if (results.isEmpty) {
        _showErrorDialog(context, LocaleProvider.tr('error'), LocaleProvider.tr('youtube_no_results'));
        return;
      }
      
      // Convertir los resultados a YtMusicResult
      final List<YtMusicResult> ytResults = results.map((result) {
        try {
          if (result is YtMusicResult) {
            // Quitar "- topic" del artista si existe
            String? artist = result.artist;
            if (artist != null && artist.endsWith(' - Topic')) {
              artist = artist.substring(0, artist.length - 8);
              return YtMusicResult(
                title: result.title,
                artist: artist,
                thumbUrl: result.thumbUrl,
                videoId: result.videoId,
              );
            }
            return result;
          } else if (result is Map) {
            // Si es un Map, convertirlo a YtMusicResult
            String? artist = result['artist']?.toString();
            // Quitar "- topic" del artista
            if (artist != null && artist.endsWith(' - Topic')) {
              artist = artist.substring(0, artist.length - 8);
            }
            return YtMusicResult(
              title: result['title']?.toString(),
              artist: artist,
              thumbUrl: result['thumbUrl']?.toString(),
              videoId: result['videoId']?.toString(),
            );
          } else {
            throw Exception('Tipo de resultado no válido: ${result.runtimeType}');
          }
        } catch (e) {
          // print(LocaleProvider.tr('youtube_conversion_error').replaceAll('@error', e.toString()));
          // Crear un resultado por defecto si falla la conversión
          return YtMusicResult(
            title: LocaleProvider.tr('youtube_unknown_video'),
            artist: LocaleProvider.tr('youtube_unknown_artist'),
            thumbUrl: null,
            videoId: null,
          );
        }
      }).toList();
      
      // Verificar que al menos un resultado sea válido
      if (ytResults.any((result) => result.videoId != null)) {
        showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          builder: (context) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                child: YtPreviewPlayer(
                  results: ytResults,
                  currentIndex: 0,
                ),
              ),
            );
          },
        );
      } else {
        _showErrorDialog(context, LocaleProvider.tr('error'), LocaleProvider.tr('youtube_no_valid_videos'));
      }
    } catch (e) {
      // print(LocaleProvider.tr('youtube_modal_show_error').replaceAll('@error', e.toString()));
      _showErrorDialog(context, LocaleProvider.tr('error'), LocaleProvider.tr('youtube_modal_show_error').replaceAll('@error', e.toString()));
    }
  }

  /// Muestra un diálogo de error
  static void _showErrorDialog(BuildContext context, String title, String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(LocaleProvider.tr('ok')),
          ),
        ],
      ),
    );
  }
}
