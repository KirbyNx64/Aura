import 'package:dio/dio.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'dart:convert';

class YouTubeMusicService {
  static const domain = "https://music.youtube.com/";
  static const String baseUrl = '${domain}youtubei/v1/';
  static const String fixedParams = '?prettyPrint=false&alt=json&key=AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30';
  static const userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36';
  
  // Constantes para continuaciones (copiadas de Harmony)
  static const continuationToken = [
    "continuationItemRenderer",
    "continuationEndpoint",
    "continuationCommand",
    "token"
  ];

  static const continuationItems = [
    "onResponseReceivedActions",
    0,
    "appendContinuationItemsAction",
    "continuationItems"
  ];
  
  final Map<String, String> headers = {
    'user-agent': userAgent,
    'accept': '*/*',
    'accept-encoding': 'gzip, deflate',
    'content-type': 'application/json',
    'content-encoding': 'gzip',
    'origin': domain,
    'cookie': 'CONSENT=YES+1',
  };
  
  final Map<String, dynamic> ytServiceContext = {
    'context': {
      'client': {"clientName": "WEB_REMIX", "clientVersion": "1.20230213.01.00"},
      'user': {},
    },
  };

  // Función para enviar la petición (copiada de service.dart)
  Future<Response> sendRequest(String action, Map<dynamic, dynamic> data, {String additionalParams = ""}) async {
    final dio = Dio();
    final url = "$baseUrl$action$fixedParams$additionalParams";
    return await dio.post(
      url,
      options: Options(
        headers: headers,
        validateStatus: (status) {
          return (status != null && (status >= 200 && status < 300)) || status == 400;
        },
      ),
      data: jsonEncode(data),
    );
  }

  // Función utilitaria para navegar el JSON (copiada de service.dart)
  dynamic nav(dynamic data, List<dynamic> path) {
    dynamic current = data;
    for (final key in path) {
      if (current == null) return null;
      if (key is int) {
        if (current is List && key < current.length) {
          current = current[key];
        } else {
          return null;
        }
      } else if (key is String) {
        if (current is Map && current.containsKey(key)) {
          current = current[key];
        } else {
          return null;
        }
      }
    }
    return current;
  }

  Future<List<Video>> getPlaylistVideos(String playlistId, {Function(Video video, int totalFound)? onVideoFound}) async {
    try {
      final data = {
        ...ytServiceContext,
        'browseId': 'VL$playlistId'
      };
      
      // print('🔍 Intentando obtener playlist con browseId: VL$playlistId');
      
      final response = await sendRequest("browse", data);
      
      // Debug: imprimir la estructura de la respuesta
      // print('🔍 Respuesta de YouTube Music API:');
      // print('Status: ${response.statusCode}');
      // print('Data keys: ${response.data.keys.toList()}');
      
      // Obtener resultados iniciales
      var results = nav(response.data, [
        "contents",
        "twoColumnBrowseResultsRenderer",
        "secondaryContents",
        "sectionListRenderer",
        "contents",
        0,
        "musicPlaylistShelfRenderer",
      ]);
      
      results ??= nav(response.data, [
        'contents',
        "singleColumnBrowseResultsRenderer",
        "tabs",
        0,
        "tabRenderer",
        "content",
        'sectionListRenderer',
        'contents',
        0,
        "musicPlaylistShelfRenderer"
      ]);
      
      if (results == null) {
        // print('❌ No se encontraron resultados');
        return [];
      }

      // Contador global para todos los videos encontrados
      int totalVideosFound = 0;

      // Obtener videos iniciales
      final initialVideos = await parsePlaylistItems(results['contents'], onVideoFound: (video, count) {
        totalVideosFound++;
        onVideoFound?.call(video, totalVideosFound);
      });
      // print('🎵 Videos iniciales: ${initialVideos.length}');

      // Función para hacer requests de continuación
      Future<Map<String, dynamic>> requestFunc(Map<String, dynamic> cont) async {
        final continuationData = {
          ...ytServiceContext,
          'browseId': 'VL$playlistId',
          ...cont
        };
        final continuationResponse = await sendRequest("browse", continuationData);
        return continuationResponse.data;
      }

      // Obtener videos adicionales usando continuaciones
      final additionalVideos = await getContinuationsPlaylist(
        results, 
        null, // Sin límite
        requestFunc, 
        (contents) async => await parsePlaylistItems(contents, onVideoFound: (video, count) {
          totalVideosFound++;
          onVideoFound?.call(video, totalVideosFound);
        })
      );

      // Combinar todos los videos
      final allVideos = [...initialVideos, ...additionalVideos];
      // print('🎵 Total videos con continuaciones: ${allVideos.length}');
      
      return allVideos;
      
    } catch (e) {
      // print('Error en YouTubeMusicService: $e');
      return _fallbackToYoutubeExplode(playlistId);
    }
  }



  Future<Video?> _createVideoFromData(Map<String, dynamic> videoData, String videoId) async {
    try {
      // Usar YouTube Explode para obtener información completa del video
      final yt = YoutubeExplode();
      try {
        final video = await yt.videos.get(videoId);
        return video;
      } finally {
        yt.close();
      }
    } catch (e) {
      // print('Error creating video from data: $e');
      return null;
    }
  }

  Future<List<Video>> _fallbackToYoutubeExplode(String playlistId) async {
    final yt = YoutubeExplode();
    final videos = <Video>[];
    
    try {
      await for (final video in yt.playlists.getVideos(playlistId)) {
        videos.add(video);
      }
    } finally {
      yt.close();
    }
    
    return videos;
  }

  Future<List<Video>> getPlaylistVideosWithContinuations(String playlistId, {Function(Video video, int totalFound)? onVideoFound}) async {
    // Usar el nuevo método que maneja continuaciones correctamente
    return await getPlaylistVideos(playlistId, onVideoFound: onVideoFound);
  }

  // Función para extraer el token de continuación (copiada de Harmony)
  String? getContinuationToken(List<dynamic> results) {
    return nav(results.last, continuationToken);
  }

  // Función para manejar continuaciones de playlist (copiada de Harmony)
  Future<List<Video>> getContinuationsPlaylist(
    Map<String, dynamic> results, 
    int? limit,
    Future<Map<String, dynamic>> Function(Map<String, dynamic>) requestFunc, 
    Future<List<Video>> Function(List<dynamic>) parseFunc,
    {Function(Video video, int totalFound)? onVideoFound}
  ) async {
    List<Video> items = [];
    String? continuationToken = getContinuationToken(results['contents']);

    while (continuationToken != null && (limit == null || items.length < limit)) {
      try {
        final response = await requestFunc({"continuation": continuationToken});
        final continuationItemsData = nav(response, continuationItems);

        if (continuationItemsData == null || continuationItemsData.isEmpty) break;

        final contents = await parseFunc(continuationItemsData);
        if (contents.isEmpty) break;

        items.addAll(contents);
        
        continuationToken = getContinuationToken(continuationItemsData);
        
        // Pausa para evitar rate limiting
        await Future.delayed(const Duration(milliseconds: 200));
        
      } catch (e) {
        // print('Error en continuación: $e');
        break;
      }
    }
    return items;
  }

  // Función para parsear items de playlist
  Future<List<Video>> parsePlaylistItems(List<dynamic> contents, {Function(Video video, int totalFound)? onVideoFound}) async {
    final videos = <Video>[];
    
    for (int i = 0; i < contents.length; i++) {
      final item = contents[i];
      final videoData = item['musicResponsiveListItemRenderer'];
      if (videoData != null) {
        final videoId = videoData['playlistItemData']?['videoId'];
        if (videoId != null) {
          // Crear video usando YouTube Explode
          final video = await _createVideoFromData(videoData, videoId);
          if (video != null) {
            videos.add(video);
            // Llamar al callback con el video encontrado
            onVideoFound?.call(video, 0); // El contador se maneja en el nivel superior
          }
        }
      }
    }
    
    return videos;
  }
} 