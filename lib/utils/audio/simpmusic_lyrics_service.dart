import 'package:dio/dio.dart';
import 'package:audio_service/audio_service.dart';
import 'package:music/utils/audio/synced_lyrics_service.dart';
import 'package:music/utils/connectivity_helper.dart';
import 'package:music/utils/db/download_history_hive.dart';
import 'package:music/utils/yt_search/service.dart';

class SimpMusicLyricsService {
  static const String _apiBaseUrl = 'https://api-lyrics.simpmusic.org';
  static String get userAgent => SyncedLyricsService.userAgent;

  static Future<bool> isApiAvailable() async {
    try {
      final hasConnection =
          await ConnectivityHelper.hasInternetConnectionWithTimeout(
            timeout: const Duration(seconds: 5),
          );

      if (!hasConnection) {
        return false;
      }

      final dio = Dio();
      dio.options.connectTimeout = const Duration(seconds: 10);
      dio.options.receiveTimeout = const Duration(seconds: 10);

      // We use /v1/dQw4w9WgXcQ (direct lookup) as a health check
      final response = await dio.get(
        '$_apiBaseUrl/v1/dQw4w9WgXcQ',
        options: Options(
          headers: {'User-Agent': userAgent},
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      // print('SimpMusic API availability check status: ${response.statusCode}');
      return response.statusCode != null && response.statusCode! < 500;
    } catch (e) {
      // print('SimpMusic API availability check error: $e');
      return false;
    }
  }

  static Future<LyricsResult> getLyricsWithResult(
    MediaItem song, {
    bool forceReload = false,
  }) async {
    final lyricsBox = await SyncedLyricsService.box;

    if (!forceReload) {
      final existingLyrics = lyricsBox.get(song.id);
      if (existingLyrics != null) {
        // print('SimpMusic: Found lyrics in cache for ${song.title}');
        return LyricsResult(type: LyricsResultType.found, data: existingLyrics);
      }
    }

    // print('SimpMusic: Fetching lyrics for ${song.title} - ${song.artist}');

    final isAvailable = await isApiAvailable();
    if (!isAvailable) {
      // print('SimpMusic: API no disponible');
      final hasConnection = await ConnectivityHelper.hasInternetConnection();
      if (!hasConnection) {
        return LyricsResult(type: LyricsResultType.noConnection);
      }
      return LyricsResult(type: LyricsResultType.apiUnavailable);
    }

    // Attempt to find by videoId if present in extras
    var videoId = song.extras?['videoId'];

    // Si no está en extras, buscar en el historial de Hive por el path (song.id)
    if (videoId == null || videoId.toString().isEmpty) {
      final historyItem = await DownloadHistoryHive.getDownloadByPath(song.id);
      if (historyItem != null) {
        videoId = historyItem.videoId;
        // print('SimpMusic: videoId encontrado en Hive: $videoId');
      }
    } else {
      // print('SimpMusic: videoId encontrado en extras: $videoId');
    }

    if (videoId != null && videoId.toString().isNotEmpty) {
      final result = await getLyricsByVideoId(videoId.toString(), song.id);
      if (result.type == LyricsResultType.found) {
        // print('SimpMusic: Letras encontradas usando videoId: $videoId');
        return result;
      }
    }

    // print(
    //   'SimpMusic: videoId no encontrado o falló la obtención. Intentando búsqueda general...',
    // );

    // print(
    //   'SimpMusic: No videoId in extras or lyrics not found by videoId, falling back to search',
    // );

    // Fallback: search by title and artist
    return await searchAndGetLyrics(song);
  }

  static Future<LyricsResult> getLyricsByVideoId(
    String videoId,
    String songId,
  ) async {
    final dio = Dio();
    dio.options.connectTimeout = const Duration(seconds: 10);
    dio.options.receiveTimeout = const Duration(seconds: 10);

    try {
      final requestUrl = '$_apiBaseUrl/v1/$videoId';
      // print('SimpMusic: Requesting lyrics by videoId: $requestUrl');
      final response = await dio.get(
        requestUrl,
        options: Options(
          headers: {'User-Agent': userAgent},
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      // print('SimpMusic: Response status for videoId: ${response.statusCode}');
      if (response.statusCode == 200 && response.data != null) {
        final responseData = response.data;
        if (responseData is Map<String, dynamic>) {
          Map<String, dynamic>? actualData;

          // La API puede devolver los datos directamente o envueltos en "data" (como lista o mapa)
          if (responseData.containsKey('data')) {
            final wrapped = responseData['data'];
            if (wrapped is List && wrapped.isNotEmpty) {
              actualData = wrapped.first as Map<String, dynamic>;
            } else if (wrapped is Map<String, dynamic>) {
              actualData = wrapped;
            }
          } else if (responseData.containsKey('syncedLyrics') ||
              responseData.containsKey('plainLyrics') ||
              responseData.containsKey('plainLyric')) {
            actualData = responseData;
          }

          if (actualData != null) {
            // print('SimpMusic: Lyrics parsed correctly for videoId: $videoId');
            final lyricsData = LyricsData(
              id: songId,
              synced: actualData["syncedLyrics"],
              plainLyrics:
                  actualData["plainLyric"] ?? actualData["plainLyrics"],
            );
            final lyricsBox = await SyncedLyricsService.box;
            await lyricsBox.put(songId, lyricsData);
            return LyricsResult(type: LyricsResultType.found, data: lyricsData);
          }
        }
      }
      // print(
      //   'SimpMusic: Lyrics NOT FOUND or invalid format for videoId: $videoId',
      // );
    } catch (e) {
      // print('SimpMusic: Error fetching lyrics by videoId: $e');
    }
    // print('SimpMusic: Lyrics not found for videoId: $videoId');
    return LyricsResult(type: LyricsResultType.notFound);
  }

  static Future<LyricsResult> searchAndGetLyrics(MediaItem song) async {
    try {
      final query = '${song.artist ?? ""} ${song.title}'.trim();
      // print('SimpMusic: Searching for lyrics with query: $query');
      
      // Buscar en YouTube Music para obtener los videoIds correspondientes
      final ytResults = await searchSongsOnly(query, cancelPrevious: false);
      if (ytResults.isNotEmpty) {
        // Intentar obtener las letras para los mejores resultados
        for (final ytResult in ytResults) {
          final videoId = ytResult.videoId;
          if (videoId != null && videoId.isNotEmpty) {
            final result = await getLyricsByVideoId(videoId, song.id);
            if (result.type == LyricsResultType.found) {
              return result;
            }
          }
        }
      }
    } catch (e) {
      // print('SimpMusic: Search error: $e');
    }
    // print('SimpMusic: No lyrics found in results for query');
    return LyricsResult(type: LyricsResultType.notFound);
  }
}
