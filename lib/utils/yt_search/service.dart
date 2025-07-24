import 'dart:convert';
import 'package:dio/dio.dart';

CancelToken? _searchCancelToken; // <-- Agregado para cancelación global

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

final Map<String, dynamic> ytServiceContext = {
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
Future<Response> sendRequest(String action, Map<dynamic, dynamic> data, {String additionalParams = "", CancelToken? cancelToken}) async {
  final dio = Dio();
  final url = "$baseUrl$action$fixedParms$additionalParams";
  return await dio.post(
    url,
    options: Options(
      headers: headers,
      validateStatus: (status) {
        return (status != null && (status >= 200 && status < 300)) || status == 400;
      },
    ),
    data: jsonEncode(data),
    cancelToken: cancelToken,
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
  // Cancela la búsqueda anterior si existe
  _searchCancelToken?.cancel();
  _searchCancelToken = CancelToken();

  final data = {
    ...ytServiceContext,
    'query': query,
    'params': getSearchParams('songs', null, false),
  };

  if (continuationToken != null) {
    data['continuation'] = continuationToken;
  }

  try {
    final response = (await sendRequest("search", data, cancelToken: _searchCancelToken)).data;
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

      if (contents is List) {
        final songItems = contents.where((item) => 
          item['musicResponsiveListItemRenderer'] != null
        ).toList();
        if (songItems.isNotEmpty) {
          parseSongs(songItems, results);
        }
      }
    }
    return results;
  } on DioException catch (e) {
    if (CancelToken.isCancel(e)) {
      // print('Búsqueda cancelada');
      return <YtMusicResult>[];
    }
    // Si es un error 400 (bad request), ignóralo y retorna lista vacía
    if (e.response?.statusCode == 400) {
      // print('Error 400 ignorado porque la búsqueda fue cancelada o la petición ya no es válida');
      return <YtMusicResult>[];
    }
    rethrow;
  }
}

// Función para buscar con múltiples páginas
Future<List<YtMusicResult>> searchSongsWithPagination(String query, {int maxPages = 3}) async {
  final allResults = <YtMusicResult>[];
  String? continuationToken;
  int currentPage = 0;

  while (currentPage < maxPages) {
    final data = {
      ...ytServiceContext,
      'params': getSearchParams('songs', null, false),
    };
    if (continuationToken == null) {
      data['query'] = query;
    } else {
      data['continuation'] = continuationToken;
    }
    final response = (await sendRequest("search", data)).data;
    final results = <YtMusicResult>[];
    String? nextToken;
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
        nextToken = shelfRenderer['continuations'][0]['nextContinuationData']['continuation'];
      }
    } else {
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
      if (contents is List) {
        final songItems = contents.where((item) => 
          item['musicResponsiveListItemRenderer'] != null
        ).toList();
        if (songItems.isNotEmpty) {
          parseSongs(songItems, results);
        }
      }
      String? nextTokenTry;
      try {
        nextTokenTry = nav(response, [
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
        nextTokenTry ??= nav(response, [
          'continuationContents',
          'musicShelfContinuation',
          'continuations',
          0,
          'nextContinuationData',
          'continuation'
        ]);
        nextToken = nextTokenTry;
      } catch (e) {
        nextToken = null;
      }
    }
    allResults.addAll(results);
    if (results.isEmpty || nextToken == null) {
      break;
    }
    continuationToken = nextToken;
    currentPage++;
  }
  return allResults;
}

// Función para buscar con más resultados por página
Future<List<YtMusicResult>> searchSongsWithMoreResults(String query) async {
  final data = {
    ...ytServiceContext,
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

// Función para obtener sugerencias de búsqueda de YouTube Music
Future<List<String>> getSearchSuggestion(String queryStr) async {
  try {
    final data = Map<String, dynamic>.from(ytServiceContext);
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

Future<List<YtMusicResult>> searchVideosWithPagination(String query, {int maxPages = 3}) async {
  final allResults = <YtMusicResult>[];
  String? continuationToken;
  int currentPage = 0;

  while (currentPage < maxPages) {
    List<YtMusicResult> results = [];
    if (continuationToken == null) {
      // Primera búsqueda
      final data = {
        ...ytServiceContext,
        'query': query,
        'params': getSearchParams('videos', null, false),
      };
      final response = (await sendRequest("search", data)).data;
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
        'contents',
      ]);
      if (contents is List) {
        for (var item in contents) {
          final renderer = item['musicResponsiveListItemRenderer'];
          if (renderer != null) {
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
            if (videoType == 'MUSIC_VIDEO_TYPE_MV' ||
                videoType == 'MUSIC_VIDEO_TYPE_OMV' ||
                videoType == 'MUSIC_VIDEO_TYPE_UGC') {
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
      // Obtener el token de continuación para la siguiente página
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
        'musicShelfRenderer',
      ]);
      if (shelfRenderer != null && shelfRenderer['continuations'] != null) {
        continuationToken = shelfRenderer['continuations'][0]['nextContinuationData']['continuation'];
      } else {
        continuationToken = null;
      }
    } else {
      // Continuaciones
      final data = {
        ...ytServiceContext,
        'continuation': continuationToken,
      };
      final response = (await sendRequest("search", data)).data;
      // Intenta ambas rutas, igual que en canciones
      var contents = nav(response, [
        'onResponseReceivedActions',
        0,
        'appendContinuationItemsAction',
        'continuationItems',
      ]);
      contents ??= nav(response, [
        'continuationContents',
        'musicShelfContinuation',
        'contents',
      ]);
      if (contents is List) {
        final videoItems = contents.where((item) => item['musicResponsiveListItemRenderer'] != null).toList();
        for (var item in videoItems) {
          final renderer = item['musicResponsiveListItemRenderer'];
          if (renderer != null) {
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
            if (videoType == 'MUSIC_VIDEO_TYPE_MV' ||
                videoType == 'MUSIC_VIDEO_TYPE_OMV' ||
                videoType == 'MUSIC_VIDEO_TYPE_UGC') {
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
      // Obtener el siguiente token de continuación
      String? nextToken;
      try {
        nextToken = nav(response, [
          'onResponseReceivedActions',
          0,
          'appendContinuationItemsAction',
          'continuationItems',
          0,
          'continuationItemRenderer',
          'continuationEndpoint',
          'continuationCommand',
          'token',
        ]);
        // Si no hay, intenta la ruta alternativa
        nextToken ??= nav(response, [
          'continuationContents',
          'musicShelfContinuation',
          'continuations',
          0,
          'nextContinuationData',
          'continuation'
        ]);
        continuationToken = nextToken;
      } catch (e) {
        continuationToken = null;
      }
    }
    if (results.isEmpty) break;
    allResults.addAll(results);
    if (continuationToken == null) break;
    currentPage++;
  }
  return allResults;
}

Future<List<Map<String, String>>> searchAlbumsOnly(String query) async {
  final data = {
    ...ytServiceContext,
    'query': query,
    // Puedes probar con o sin el filtro 'albums'
    // 'params': getSearchParams('albums', null, false),
  };
  final response = (await sendRequest("search", data)).data;
  final results = <Map<String, String>>[];

  final sections = nav(response, [
    'contents',
    'tabbedSearchResultsRenderer',
    'tabs',
    0,
    'tabRenderer',
    'content',
    'sectionListRenderer',
    'contents'
  ]);
  if (sections is List) {
    for (var section in sections) {
      // Busca cualquier shelf
      final shelf = section['musicShelfRenderer'];
      if (shelf != null && shelf['contents'] is List) {
        for (var item in shelf['contents']) {
          final renderer = item['musicResponsiveListItemRenderer'];
          if (renderer != null) {
            // Extraer browseId de cualquier menú
            String? browseId;
            final menuItems = renderer['menu']?['menuRenderer']?['items'];
            if (menuItems is List) {
              for (var menuItem in menuItems) {
                final endpoint = menuItem['menuNavigationItemRenderer']?['navigationEndpoint']?['browseEndpoint'];
                if (endpoint != null && endpoint['browseId'] != null && endpoint['browseId'].toString().startsWith('MPRE')) {
                  browseId = endpoint['browseId'];
                  break;
                }
              }
            }
            // Si no hay browseId, ignora el item
            if (browseId == null) continue;

            final title = renderer['flexColumns']?[0]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs']?[0]?['text'];
            final subtitleRuns = renderer['flexColumns']?[1]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'];
            String? artist;
            if (subtitleRuns is List) {
              artist = subtitleRuns.firstWhere(
                (run) => run['text'] != ' • ',
                orElse: () => {'text': null},
              )['text'];
            }
            String? thumbUrl;
            final thumbnails = renderer['thumbnail']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'];
            if (thumbnails is List && thumbnails.isNotEmpty) {
              thumbUrl = thumbnails.last['url'];
            }
            results.add({
              'title': title,
              'artist': artist ?? '',
              'thumbUrl': thumbUrl ?? '',
              'browseId': browseId,
            });
          }
        }
      }
    }
  }
  return results;
}

Future<List<YtMusicResult>> getAlbumSongs(String browseId) async {
  final data = {
    ...ytServiceContext,
    'browseId': browseId,
  };
  final response = (await sendRequest("browse", data)).data;

  // Intenta ambas rutas posibles
  var shelf = nav(response, [
    'contents',
    'twoColumnBrowseResultsRenderer',
    'secondaryContents',
    'sectionListRenderer',
    'contents',
    0,
    'musicShelfRenderer',
    'contents',
  ]);
  shelf ??= nav(response, [
    'contents',
    'singleColumnBrowseResultsRenderer',
    'tabs',
    0,
    'tabRenderer',
    'content',
    'sectionListRenderer',
    'contents',
    0,
    'musicShelfRenderer',
    'contents',
  ]);

  final results = <YtMusicResult>[];
  if (shelf is List) {
    for (var item in shelf) {
      final renderer = item['musicResponsiveListItemRenderer'];
      if (renderer != null) {
        final title = renderer['flexColumns']?[0]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs']?[0]?['text'];
        final subtitleRuns = renderer['flexColumns']?[1]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'];
        String? artist;
        if (subtitleRuns is List) {
          artist = subtitleRuns
              .where((run) => run['text'] != ' • ')
              .map((run) => run['text'])
              .join(', ');
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
  return results;
}