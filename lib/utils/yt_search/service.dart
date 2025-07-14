import 'dart:convert';
import 'package:dio/dio.dart';

const domain = "https://music.youtube.com/";
const String baseUrl = '${domain}youtubei/v1/';
const fixedParms =
    '?prettyPrint=false&alt=json&key=AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30';
const userAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36';

final Map<String, String> headers = {
  'user-agent': userAgent,
  'accept': '*/*',
  'accept-encoding': 'gzip, deflate',
  'content-type': 'application/json',
  'content-encoding': 'gzip',
  'origin': domain,
  'cookie': 'CONSENT=YES+1',
};

final Map<String, dynamic> context = {
  'context': {
    'client': {"clientName": "WEB_REMIX", "clientVersion": "1.20230213.01.00"},
    'user': {},
  },
};

class YtMusicResult {
  final String? title;
  final String? artist;
  final String? thumbUrl;
  final String? videoId;

  YtMusicResult({this.title, this.artist, this.thumbUrl, this.videoId});
}

// Función para generar parámetros de búsqueda específicos para canciones
String? getSearchParams(String? filter, String? scope, bool ignoreSpelling) {
  String filteredParam1 = 'EgWKAQI';
  String? params;
  String? param1;
  String? param2;
  String? param3;

  if (filter == null && scope == null && !ignoreSpelling) {
    return params;
  }

  if (scope == null && filter != null) {
    if (filter == 'playlists') {
      params = 'Eg-KAQwIABAAGAAgACgB';
      if (!ignoreSpelling) {
        params += 'MABqChAEEAMQCRAFEAo%3D';
      } else {
        params += 'MABCAggBagoQBBADEAkQBRAK';
      }
    } else if (filter.contains('playlists')) {
      param1 = 'EgeKAQQoA';
      if (filter == 'featured_playlists') {
        param2 = 'Dg';
      } else {
        param2 = 'EA';
      }
      if (!ignoreSpelling) {
        param3 = 'BagwQDhAKEAMQBBAJEAU%3D';
      } else {
        param3 = 'BQgIIAWoMEA4QChADEAQQCRAF';
      }
    } else {
      param1 = filteredParam1;
      param2 = _getParam2(filter);
      if (!ignoreSpelling) {
        param3 = 'AWoMEA4QChADEAQQCRAF';
      } else {
        param3 = 'AUICCAFqDBAOEAoQAxAEEAkQBQ%3D%3D';
      }
    }
  }

  if (scope == null && filter == null && ignoreSpelling) {
    params = 'EhGKAQ4IARABGAEgASgAOAFAAUICCAE%3D';
  }

  return params ?? (param1! + param2! + param3!);
}

// Función para generar parámetros con límite de resultados
String? getSearchParamsWithLimit(String? filter, String? scope, bool ignoreSpelling, {int limit = 50}) {
  final baseParams = getSearchParams(filter, scope, ignoreSpelling);
  if (baseParams == null) return null;
  
  // Agregar parámetro de límite si es necesario
  // YouTube Music usa diferentes parámetros para controlar el número de resultados
  return baseParams;
}

String? _getParam2(String filter) {
  final filterParams = {
    'songs': 'I',      // Parámetro específico para canciones
    'videos': 'Q',
    'albums': 'Y',
    'artists': 'g',
    'playlists': 'o'
  };
  return filterParams[filter];
}

// Función utilitaria para navegar el JSON
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

// Función para enviar la petición
Future<Response> sendRequest(String action, Map<dynamic, dynamic> data, {String additionalParams = ""}) async {
  final dio = Dio();
  final url = "$baseUrl$action$fixedParms$additionalParams";
  return await dio.post(
    url,
    options: Options(headers: headers),
    data: jsonEncode(data),
  );
}

// Función para parsear canciones específicamente
void parseSongs(List items, List<YtMusicResult> results) {
  for (var item in items) {
    final renderer = item['musicResponsiveListItemRenderer'];
    if (renderer != null) {
      // Verificar si es una canción (no un video)
      final videoType = nav(renderer, [
        'overlay',
        'musicItemThumbnailOverlayRenderer',
        'content',
        'musicPlayButtonRenderer',
        'playNavigationEndpoint',
        'watchEndpoint',
        'watchEndpointMusicSupportedConfigs',
        'watchEndpointMusicConfig',
        'musicVideoType'
      ]);
      
      // Solo procesar si es una canción (MUSIC_VIDEO_TYPE_ATV) o si no hay tipo específico
      if (videoType == null || videoType == 'MUSIC_VIDEO_TYPE_ATV') {
        final title = renderer['flexColumns']?[0]
            ?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs']?[0]?['text'];

        final subtitleRuns = renderer['flexColumns']?[1]
            ?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'];
        String? artist;
        if (subtitleRuns is List) {
          for (var run in subtitleRuns) {
            if (run['navigationEndpoint']?['browseEndpoint']?['browseEndpointContextSupportedConfigs'] != null ||
                run['navigationEndpoint']?['browseEndpoint']?['browseId']?.startsWith('UC') == true) {
              artist = run['text'];
              break;
            }
          }
          artist ??= subtitleRuns.firstWhere(
            (run) => run['text'] != ' • ',
            orElse: () => {'text': null},
          )['text'];
        }

        String? thumbUrl;
        final thumbnails = renderer['thumbnail']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'];
        if (thumbnails is List && thumbnails.isNotEmpty) {
          thumbUrl = thumbnails.last['url'];
        }

        final videoId = renderer['overlay']?['musicItemThumbnailOverlayRenderer']?['content']?['musicPlayButtonRenderer']?['playNavigationEndpoint']?['watchEndpoint']?['videoId'];

        if (videoId != null && title != null) {
          results.add(
            YtMusicResult(
              title: title,
              artist: artist,
              thumbUrl: thumbUrl,
              videoId: videoId,
            ),
          );
        }
      }
    }
  }
}

// Función para buscar solo canciones con paginación
Future<List<YtMusicResult>> searchSongsOnly(String query, {String? continuationToken}) async {
  final data = {
    ...context,
    'query': query,
    'params': getSearchParams('songs', null, false),
  };

  // Si hay un token de continuación, usarlo para obtener más resultados
  if (continuationToken != null) {
    data['continuation'] = continuationToken;
  }

  final response = (await sendRequest("search", data)).data;
  final results = <YtMusicResult>[];

  // Si es una búsqueda inicial
  if (continuationToken == null) {
    final contents = nav(response, [
      'contents',
      'tabbedSearchResultsRenderer',
      'tabs',
      0,
      'tabRenderer',
      'content',
      'sectionListRenderer',
      'contents',
      0,
      'musicShelfRenderer',
      'contents'
    ]);

    if (contents is List) {
      parseSongs(contents, results);
    }
  } else {
    // Si es una continuación, la estructura es diferente
    // print('Respuesta de continuación: ${response.keys.toList()}');
    
    // Intentar diferentes rutas para la continuación
    var contents = nav(response, [
      'onResponseReceivedActions',
      0,
      'appendContinuationItemsAction',
      'continuationItems'
    ]);

    contents ??= nav(response, [
      'continuationContents',
      'musicShelfContinuation',
      'contents'
    ]);

    // print('Continuación - elementos encontrados: ${contents?.length ?? 0}');
    
    if (contents is List) {
      // Filtrar solo los elementos que son canciones (no el token de continuación)
      final songItems = contents.where((item) => 
        item['musicResponsiveListItemRenderer'] != null
      ).toList();
      
      // print('Continuación - canciones encontradas: ${songItems.length}');
      
      if (songItems.isNotEmpty) {
        parseSongs(songItems, results);
      }
    }
  }

  return results;
}

// Función para buscar con más resultados por página
Future<List<YtMusicResult>> searchSongsWithMoreResults(String query) async {
  final data = {
    ...context,
    'query': query,
    'params': getSearchParams('songs', null, false),
  };

  final response = (await sendRequest("search", data)).data;
  final results = <YtMusicResult>[];

  // Obtener todos los contenidos de la respuesta
  final contents = nav(response, [
    'contents',
    'tabbedSearchResultsRenderer',
    'tabs',
    0,
    'tabRenderer',
    'content',
    'sectionListRenderer',
    'contents'
  ]);

  if (contents is List) {
    // Procesar todas las secciones que contengan canciones
    for (var section in contents) {
      final shelfRenderer = section['musicShelfRenderer'];
      if (shelfRenderer != null) {
        final sectionContents = shelfRenderer['contents'];
        if (sectionContents is List) {
          parseSongs(sectionContents, results);
        }
      }
    }
  }

  return results;
}

// Función para obtener el token de continuación
String? getContinuationToken(Map<String, dynamic> response) {
  try {
    final shelfRenderer = nav(response, [
      'contents',
      'tabbedSearchResultsRenderer',
      'tabs',
      0,
      'tabRenderer',
      'content',
      'sectionListRenderer',
      'contents',
      0,
      'musicShelfRenderer'
    ]);

    if (shelfRenderer != null && shelfRenderer['continuations'] != null) {
      return shelfRenderer['continuations'][0]['nextContinuationData']['continuation'];
    }
  } catch (e) {
    // Si no hay token de continuación, retornar null
  }
  return null;
}

// Función para buscar con múltiples páginas
Future<List<YtMusicResult>> searchSongsWithPagination(String query, {int maxPages = 3}) async {
  final allResults = <YtMusicResult>[];
  String? continuationToken;
  int currentPage = 0;

  while (currentPage < maxPages) {
    // print('Buscando página ${currentPage + 1}...');
    final results = await searchSongsOnly(query, continuationToken: continuationToken);
    // print('Resultados en página ${currentPage + 1}: ${results.length}');
    allResults.addAll(results);

    // Si no hay más resultados, parar
    if (results.isEmpty) {
      // print('No hay más resultados, parando...');
      break;
    }

    // Obtener el token de continuación para la siguiente página
    if (currentPage == 0) {
      final response = (await sendRequest("search", {
        ...context,
        'query': query,
        'params': getSearchParams('songs', null, false),
      })).data;
      continuationToken = getContinuationToken(response);
      // print('Token de continuación obtenido: ${continuationToken != null ? 'Sí' : 'No'}');
    } else {
      // Para páginas subsiguientes, necesitamos hacer otra petición para obtener el siguiente token
      final response = (await sendRequest("search", {
        ...context,
        'continuation': continuationToken,
      })).data;
      
      // Obtener el siguiente token de continuación
      try {
        final nextToken = nav(response, [
          'onResponseReceivedActions',
          0,
          'appendContinuationItemsAction',
          'continuationItems',
          0,
          'continuationItemRenderer',
          'continuationEndpoint',
          'continuationCommand',
          'token'
        ]);
        continuationToken = nextToken;
        // print('Siguiente token obtenido: ${continuationToken != null ? 'Sí' : 'No'}');
      } catch (e) {
        // print('Error obteniendo siguiente token: $e');
        continuationToken = null;
      }
    }

    // Si no hay token de continuación, parar
    if (continuationToken == null) {
      // print('No hay token de continuación, parando...');
      break;
    }

    currentPage++;
  }

  // print('Total de resultados obtenidos: ${allResults.length}');
  return allResults;
}

// Función para obtener sugerencias de búsqueda de YouTube Music
Future<List<String>> getSearchSuggestion(String queryStr) async {
  try {
    final data = Map<String, dynamic>.from(context);
    data['input'] = queryStr;
    
    final response = await sendRequest("music/get_search_suggestions", data);
    final responseData = response.data;
    
    final suggestions = nav(responseData, [
      'contents', 
      0, 
      'searchSuggestionsSectionRenderer', 
      'contents'
    ]) ?? [];
    
    return suggestions
        .map<String?>((item) {
          return nav(item, [
            'searchSuggestionRenderer',
            'navigationEndpoint',
            'searchEndpoint',
            'query'
          ])?.toString();
        })
        .whereType<String>()
        .toList();
  } catch (e) {
    return [];
  }
}

