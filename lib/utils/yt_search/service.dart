import 'dart:convert';
import 'package:dio/dio.dart';
import '../connectivity_helper.dart';

CancelToken? _searchCancelToken;

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
  // Verificar conectividad antes de hacer la petición
  final hasConnection = await ConnectivityHelper.hasInternetConnectionWithTimeout(
    timeout: const Duration(seconds: 5),
  );
  
  if (!hasConnection) {
    throw DioException(
      requestOptions: RequestOptions(path: ''),
      error: 'No hay conexión a internet',
      type: DioExceptionType.connectionError,
    );
  }

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

// Función mejorada para buscar listas de reproducción con paginación
Future<List<Map<String, String>>> searchPlaylistsWithPagination(String query, {int maxPages = 3}) async {
  final allResults = <Map<String, String>>[];
  String? continuationToken;
  int currentPage = 0;

  while (currentPage < maxPages) {
    final data = {
      ...ytServiceContext,
      'query': query,
      'params': getSearchParams('playlists', null, false),
    };

    if (continuationToken != null) {
      data['continuation'] = continuationToken;
    }

    try {
      final response = (await sendRequest("search", data)).data;
      final results = <Map<String, String>>[];
      String? nextToken;

      if (continuationToken == null) {
        // Primera búsqueda
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
            final shelf = section['musicShelfRenderer'];
            if (shelf != null && shelf['contents'] is List) {
              for (var item in shelf['contents']) {
                final renderer = item['musicResponsiveListItemRenderer'];
                if (renderer != null) {
                  final playlistData = _parsePlaylistItem(renderer);
                  if (playlistData != null) {
                    results.add(playlistData);
                  }
                }
              }
            }
          }
        }

        // Obtener token de continuación
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
        // Continuaciones
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
          final playlistItems = contents.where((item) => 
            item['musicResponsiveListItemRenderer'] != null
          ).toList();

          for (var item in playlistItems) {
            final renderer = item['musicResponsiveListItemRenderer'];
            if (renderer != null) {
              final playlistData = _parsePlaylistItem(renderer);
              if (playlistData != null) {
                results.add(playlistData);
              }
            }
          }
        }

        // Obtener siguiente token
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
            'token'
          ]);

          nextToken ??= nav(response, [
            'continuationContents',
            'musicShelfContinuation',
            'continuations',
            0,
            'nextContinuationData',
            'continuation'
          ]);
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
    } catch (e) {
      // ('Error en búsqueda de playlists: $e');
      break;
    }
  }

  return allResults;
}

// Función simple para compatibilidad con el código existente
Future<List<Map<String, String>>> searchPlaylistsOnly(String query) async {
  return await searchPlaylistsWithPagination(query, maxPages: 1);
}

// Función auxiliar para parsear items de playlist individuales
Map<String, String>? _parsePlaylistItem(Map<String, dynamic> renderer) {
  // Extraer browseId de los menús (más robusto que la implementación anterior)
  String? browseId;
  final menuItems = renderer['menu']?['menuRenderer']?['items'];
  
  if (menuItems is List) {
    for (var menuItem in menuItems) {
      final endpoint = menuItem['menuNavigationItemRenderer']?['navigationEndpoint']?['browseEndpoint'];
      if (endpoint != null && endpoint['browseId'] != null) {
        final id = endpoint['browseId'].toString();
        // Aceptar diferentes tipos de IDs de playlist
        if (id.startsWith('VL') || id.startsWith('PL') || id.startsWith('OL')) {
          browseId = id;
          break;
        }
      }
    }
  }

  // Si no hay browseId en el menú, intentar extraerlo de otros lugares
  if (browseId == null) {
    // Intentar desde el overlay
    browseId = nav(renderer, [
      'overlay',
      'musicItemThumbnailOverlayRenderer',
      'content',
      'musicPlayButtonRenderer',
      'playNavigationEndpoint',
      'watchPlaylistEndpoint',
      'playlistId'
    ])?.toString();

    // O desde navigationEndpoint
    browseId ??= nav(renderer, [
      'flexColumns',
      0,
      'musicResponsiveListItemFlexColumnRenderer',
      'text',
      'runs',
      0,
      'navigationEndpoint',
      'browseEndpoint',
      'browseId'
    ])?.toString();
  }

  if (browseId == null) return null;

  // Extraer título
  final title = renderer['flexColumns']?[0]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs']?[0]?['text'];
  if (title == null) return null;

  // Extraer número de elementos
  final subtitleRuns = renderer['flexColumns']?[1]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'];
  String? itemCount;
  
  if (subtitleRuns is List) {
    // Buscar el número de elementos (generalmente el último run numérico)
    for (var i = subtitleRuns.length - 1; i >= 0; i--) {
      final text = subtitleRuns[i]['text'];
      if (text != null && RegExp(r'\d+').hasMatch(text)) {
        itemCount = text;
        break;
      }
    }
  }

  // Extraer thumbnail
  String? thumbUrl;
  final thumbnails = renderer['thumbnail']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'];
  if (thumbnails is List && thumbnails.isNotEmpty) {
    thumbUrl = thumbnails.last['url'];
  }

  return {
    'title': title,
    'browseId': browseId,
    'thumbUrl': thumbUrl ?? '',
    'itemCount': itemCount ?? '0',
  };
}

// Función principal para obtener canciones de una lista de reproducción
Future<List<YtMusicResult>> getPlaylistSongs(String playlistId, {int limit = 100}) async {
  // Convertir el ID de playlist al formato correcto
  String browseId = playlistId.startsWith("VL") ? playlistId : "VL$playlistId";
  
  final data = {
    ...ytServiceContext,
    'browseId': browseId,
  };

  try {
    final response = (await sendRequest("browse", data)).data;
    final results = <YtMusicResult>[];

    // Buscar las canciones en diferentes ubicaciones posibles
    var contents = _findPlaylistContents(response);
    
    if (contents is List) {
      // Parsear las canciones iniciales
      final initialSongs = _parsePlaylistItems(contents);
      results.addAll(initialSongs);

      // Si necesitamos más canciones y hay continuaciones, obtenerlas
      if (results.length < limit) {
        final continuationSongs = await _getPlaylistContinuations(
          response, 
          data, 
          limit - results.length
        );
        results.addAll(continuationSongs);
      }
    }

    return results.take(limit).toList();
  } catch (e) {
    // print('Error obteniendo canciones de playlist: $e');
    return [];
  }
}

// Función auxiliar para encontrar el contenido de la playlist
List<dynamic>? _findPlaylistContents(Map<String, dynamic> response) {
  // Intentar múltiples rutas para encontrar las canciones
  var contents = nav(response, [
    'contents',
    'twoColumnBrowseResultsRenderer',
    'secondaryContents',
    'sectionListRenderer',
    'contents',
    0,
    'musicPlaylistShelfRenderer',
    'contents'
  ]);

  contents ??= nav(response, [
    'contents',
    'singleColumnBrowseResultsRenderer',
    'tabs',
    0,
    'tabRenderer',
    'content',
    'sectionListRenderer',
    'contents',
    0,
    'musicPlaylistShelfRenderer',
    'contents'
  ]);

  contents ??= nav(response, [
    'contents',
    'twoColumnBrowseResultsRenderer',
    'secondaryContents',
    'sectionListRenderer',
    'contents',
    0,
    'musicShelfRenderer',
    'contents'
  ]);

  contents ??= nav(response, [
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
    'contents'
  ]);

  return contents;
}

// Función para parsear los items de la playlist
List<YtMusicResult> _parsePlaylistItems(List<dynamic> contents) {
  final results = <YtMusicResult>[];

  for (var item in contents) {
    final renderer = item['musicResponsiveListItemRenderer'];
    if (renderer != null) {
      final song = _parsePlaylistSong(renderer);
      if (song != null) {
        results.add(song);
      }
    }
  }

  return results;
}

// Función para parsear una canción individual de la playlist
YtMusicResult? _parsePlaylistSong(Map<String, dynamic> renderer) {
  // Obtener videoId de diferentes ubicaciones
  String? videoId = nav(renderer, ['playlistItemData', 'videoId']);
  
  // Si no está en playlistItemData, buscar en el menú
  if (videoId == null && renderer.containsKey('menu')) {
    final menuItems = nav(renderer, ['menu', 'menuRenderer', 'items']);
    if (menuItems is List) {
      for (var menuItem in menuItems) {
        if (menuItem.containsKey('menuServiceItemRenderer')) {
          final menuService = nav(menuItem, [
            'menuServiceItemRenderer',
            'serviceEndpoint',
            'playlistEditEndpoint'
          ]);
          if (menuService != null) {
            videoId = nav(menuService, ['actions', 0, 'removedVideoId']);
            if (videoId != null) break;
          }
        }
      }
    }
  }

  // Si aún no tenemos videoId, buscar en el botón de play
  if (videoId == null) {
    final playButton = nav(renderer, [
      'overlay',
      'musicItemThumbnailOverlayRenderer',
      'content',
      'musicPlayButtonRenderer',
      'playNavigationEndpoint',
      'watchEndpoint'
    ]);
    if (playButton != null) {
      videoId = playButton['videoId'];
    }
  }

  if (videoId == null) return null;

  // Obtener título
  final title = nav(renderer, [
    'flexColumns',
    0,
    'musicResponsiveListItemFlexColumnRenderer',
    'text',
    'runs',
    0,
    'text'
  ]);

  if (title == null || title == 'Song deleted') return null;

  // Obtener artista
  String? artist;
  final subtitleRuns = nav(renderer, [
    'flexColumns',
    1,
    'musicResponsiveListItemFlexColumnRenderer',
    'text',
    'runs'
  ]);

  if (subtitleRuns is List) {
    // Buscar el primer run que no sea " • " y que tenga navigationEndpoint
    for (var run in subtitleRuns) {
      if (run['text'] != ' • ' && 
          run['text'] != null && 
          run['navigationEndpoint'] != null) {
        artist = run['text'];
        break;
      }
    }
    
    // Si no encontramos artista con navigationEndpoint, tomar el primero que no sea " • "
    artist ??= subtitleRuns.firstWhere(
      (run) => run['text'] != ' • ' && run['text'] != null,
      orElse: () => {'text': null},
    )['text'];
  }

  // Obtener duración (comentado ya que YtMusicResult no tiene este campo)
  // String? duration;
  // final fixedColumns = nav(renderer, ['fixedColumns']);
  // if (fixedColumns != null && fixedColumns is List && fixedColumns.isNotEmpty) {
  //   final durationText = nav(fixedColumns[0], ['text', 'simpleText']) ??
  //       nav(fixedColumns[0], ['text', 'runs', 0, 'text']);
  //   duration = durationText;
  // }

  // Obtener thumbnail
  String? thumbUrl;
  final thumbnails = nav(renderer, [
    'thumbnail',
    'musicThumbnailRenderer',
    'thumbnail',
    'thumbnails'
  ]);
  if (thumbnails is List && thumbnails.isNotEmpty) {
    thumbUrl = thumbnails.last['url'];
  }

  return YtMusicResult(
    title: title,
    artist: artist,
    thumbUrl: thumbUrl,
    videoId: videoId,
  );
}

// Función para obtener continuaciones de la playlist
Future<List<YtMusicResult>> _getPlaylistContinuations(
  Map<String, dynamic> response, 
  Map<String, dynamic> data, 
  int limit
) async {
  final results = <YtMusicResult>[];
  
  // Buscar token de continuación
  String? continuationToken = _getPlaylistContinuationToken(response);
  
  while (continuationToken != null && results.length < limit) {
    try {
      final continuationData = {
        ...data,
        'continuation': continuationToken,
      };
      
      final continuationResponse = (await sendRequest("browse", continuationData)).data;
      
      // Buscar items de continuación
      var continuationItems = nav(continuationResponse, [
        'continuationContents',
        'musicPlaylistShelfContinuation',
        'contents'
      ]);
      
      continuationItems ??= nav(continuationResponse, [
        'onResponseReceivedActions',
        0,
        'appendContinuationItemsAction',
        'continuationItems'
      ]);

      if (continuationItems != null && continuationItems is List) {
        final songs = _parsePlaylistItems(continuationItems);
        results.addAll(songs);
        
        // Obtener siguiente token
        continuationToken = _getPlaylistContinuationToken(continuationResponse);
      } else {
        break;
      }
    } catch (e) {
      // print('Error en continuación de playlist: $e');
      break;
    }
  }
  
  return results;
}

// Función para obtener el token de continuación de playlist
String? _getPlaylistContinuationToken(Map<String, dynamic> response) {
  // Buscar en diferentes ubicaciones
  var token = nav(response, [
    'contents',
    'twoColumnBrowseResultsRenderer',
    'secondaryContents',
    'sectionListRenderer',
    'contents',
    0,
    'musicPlaylistShelfRenderer',
    'continuations',
    0,
    'nextContinuationData',
    'continuation'
  ]);

  token ??= nav(response, [
    'contents',
    'singleColumnBrowseResultsRenderer',
    'tabs',
    0,
    'tabRenderer',
    'content',
    'sectionListRenderer',
    'contents',
    0,
    'musicPlaylistShelfRenderer',
    'continuations',
    0,
    'nextContinuationData',
    'continuation'
  ]);

  token ??= nav(response, [
    'continuationContents',
    'musicPlaylistShelfContinuation',
    'continuations',
    0,
    'nextContinuationData',
    'continuation'
  ]);

  return token;
}

// Función para obtener información de la playlist (título, autor, etc.)
Future<Map<String, dynamic>?> getPlaylistInfo(String playlistId) async {
  String browseId = playlistId.startsWith("VL") ? playlistId : "VL$playlistId";
  
  final data = {
    ...ytServiceContext,
    'browseId': browseId,
  };

  try {
    final response = (await sendRequest("browse", data)).data;
    
    // Buscar header en diferentes ubicaciones
    var header = nav(response, ['header', 'musicDetailHeaderRenderer']);
    
    header ??= nav(response, [
      'contents',
      'twoColumnBrowseResultsRenderer',
      'tabs',
      0,
      'tabRenderer',
      'content',
      'sectionListRenderer',
      'contents',
      0,
      'musicResponsiveHeaderRenderer'
    ]);

    if (header == null) return null;

    // Extraer información del header
    final title = nav(header, ['title', 'runs', 0, 'text']);
    final description = nav(header, [
      'description',
      'musicDescriptionShelfRenderer',
      'description',
      'runs',
      0,
      'text'
    ]);

    // Extraer número de canciones
    String? songCount;
    final secondSubtitleRuns = nav(header, ['secondSubtitle', 'runs']);
    if (secondSubtitleRuns is List && secondSubtitleRuns.isNotEmpty) {
      final countText = nav(secondSubtitleRuns[0], ['text']);
      if (countText != null) {
        final match = RegExp(r'(\d+)').firstMatch(countText);
        songCount = match?.group(1);
      }
    }

    // Extraer thumbnail
    String? thumbUrl;
    final thumbnails = nav(header, [
      'thumbnail',
      'musicThumbnailRenderer',
      'thumbnail',
      'thumbnails'
    ]);
    if (thumbnails is List && thumbnails.isNotEmpty) {
      thumbUrl = thumbnails.last['url'];
    }

    return {
      'title': title,
      'description': description,
      'songCount': songCount,
      'thumbUrl': thumbUrl,
    };
  } catch (e) {
    // print('Error obteniendo información de playlist: $e');
    return null;
  }
}