import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../connectivity_helper.dart';

part 'synced_lyrics_service.g.dart';

@HiveType(typeId: 0)
class LyricsData extends HiveObject {
  @HiveField(0)
  String id;

  @HiveField(1)
  String? synced;

  @HiveField(2)
  String? plainLyrics;

  LyricsData({
    required this.id,
    this.synced,
    this.plainLyrics,
  });
}

enum LyricsResultType {
  found,
  notFound,
  apiUnavailable,
  noConnection,
}

class LyricsResult {
  final LyricsResultType type;
  final LyricsData? data;

  LyricsResult({required this.type, this.data});
}

class SyncedLyricsService {
  static const String _boxName = 'lyrics_box';
  static Box<LyricsData>? _box;
  static const String _apiBaseUrl = 'https://lrclib.net';
  static const String _apiEndpoint = '/api/get';

  static Future<Box<LyricsData>> get box async {
    if (_box != null) return _box!;
    _box = await Hive.openBox<LyricsData>(_boxName);
    return _box!;
  }

  static Future<void> initialize() async {
    await Hive.initFlutter();
    Hive.registerAdapter(LyricsDataAdapter());
  }

  // Verificar si la API está disponible usando el endpoint de búsqueda
  static Future<bool> _isApiAvailable() async {
    try {
      // Verificar conectividad usando el helper
      final hasConnection = await ConnectivityHelper.hasInternetConnectionWithTimeout(
        timeout: const Duration(seconds: 5),
      );
      
      if (!hasConnection) {
        return false;
      }

      // Hacer una petición de prueba al endpoint de búsqueda de la API
      final dio = Dio();
      dio.options.connectTimeout = const Duration(seconds: 10);
      dio.options.receiveTimeout = const Duration(seconds: 10);
      
      final response = await dio.get(
        '$_apiBaseUrl/api/search',
        queryParameters: {
          'q': 'hello'
        },
        options: Options(
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      
      // La API está disponible si responde correctamente (200, 404, etc.)
      return response.statusCode != null && response.statusCode! < 500;
    } catch (e) {
      return false;
    }
  }

  static Future<LyricsData?> getSyncedLyrics(
    MediaItem song, {
    int? durInSec,
  }) async {
    final result = await getSyncedLyricsWithResult(song, durInSec: durInSec);
    return result.data;
  }

  static Future<LyricsResult> getSyncedLyricsWithResult(
    MediaItem song, {
    int? durInSec,
  }) async {
    final lyricsBox = await box;

    // Buscar en la base local primero
    final existingLyrics = lyricsBox.get(song.id);
    if (existingLyrics != null) {
      return LyricsResult(type: LyricsResultType.found, data: existingLyrics);
    }

    // Verificar conectividad antes de intentar cualquier operación de red
    final hasConnection = await ConnectivityHelper.hasInternetConnectionWithTimeout(
      timeout: const Duration(seconds: 3),
    );
    
    if (!hasConnection) {
      return LyricsResult(type: LyricsResultType.noConnection);
    }

    // Verificar si la API está disponible antes de intentar cargar
    final isApiAvailable = await _isApiAvailable();
    if (!isApiAvailable) {
      return LyricsResult(type: LyricsResultType.apiUnavailable);
    }

    // Si la API está disponible, intentar cargar las letras
    final dur = song.duration?.inSeconds ?? durInSec ?? 0;
    final url =
        '$_apiBaseUrl$_apiEndpoint?artist_name=${Uri.encodeComponent(song.artist ?? "")}'
        '&track_name=${Uri.encodeComponent(song.title)}'
        '&duration=$dur';

    try {
      // Verificar conectividad una vez más antes de la petición final
      final finalConnectionCheck = await ConnectivityHelper.hasInternetConnection();
      if (!finalConnectionCheck) {
        return LyricsResult(type: LyricsResultType.noConnection);
      }

      final dio = Dio();
      dio.options.connectTimeout = const Duration(seconds: 10);
      dio.options.receiveTimeout = const Duration(seconds: 10);
      
      final response = await dio.get(
        url,
        options: Options(
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        final data = response.data;
        if (data is Map<String, dynamic> && 
            (data["syncedLyrics"] != null || data["plainLyrics"] != null)) {
          final lyricsData = LyricsData(
            id: song.id,
            synced: data["syncedLyrics"],
            plainLyrics: data["plainLyrics"],
          );
          await lyricsBox.put(song.id, lyricsData);
          return LyricsResult(type: LyricsResultType.found, data: lyricsData);
        }
      } else if (response.statusCode == 404) {
        // API está funcionando pero no encontró la letra
        return LyricsResult(type: LyricsResultType.notFound);
      }
    } on DioException catch (e) {
      // Si es un error de conectividad, marcar como API no disponible
      if (e.type == DioExceptionType.connectionTimeout || 
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.connectionError) {
        return LyricsResult(type: LyricsResultType.apiUnavailable);
      }
    } catch (e) {
      // Error inesperado
    }
    return LyricsResult(type: LyricsResultType.notFound);
  }

  static Future<void> clearLyrics() async {
    final lyricsBox = await box;
    await lyricsBox.clear();
  }
}
