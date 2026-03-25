import 'dart:convert';
import 'dart:developer' as developer;
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/locale_provider.dart';

CancelToken? _searchCancelToken;

const domain = "https://music.youtube.com/";
const String baseUrl = '${domain}youtubei/v1/';
const fixedParms =
    '?prettyPrint=false&alt=json&key=AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30';
const userAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36';
const bool _ytLibraryDebugLogs = true;
String? _cachedVisitorId;
bool _visitorIdLoadAttempted = false;

void _ytLibLog(String message) {
  if (!_ytLibraryDebugLogs) return;
  developer.log(message, name: 'YT-LIB');
}

String _cookieDebugSummary(String? cookieHeader) {
  final raw = cookieHeader?.trim();
  if (raw == null || raw.isEmpty) return 'none';
  final names = raw
      .split(';')
      .map((entry) => entry.trim())
      .where((entry) => entry.isNotEmpty && entry.contains('='))
      .map((entry) => entry.substring(0, entry.indexOf('=')))
      .toList();
  final preview = names.take(6).join(',');
  final suffix = names.length > 6 ? ',...' : '';
  return 'len=${raw.length}, names=[$preview$suffix]';
}

String? _getCookieValueByName(String? cookieHeader, String cookieName) {
  final raw = cookieHeader?.trim();
  if (raw == null || raw.isEmpty) return null;
  final target = cookieName.trim().toLowerCase();
  if (target.isEmpty) return null;

  for (final part in raw.split(';')) {
    final entry = part.trim();
    if (entry.isEmpty || !entry.contains('=')) continue;
    final separator = entry.indexOf('=');
    if (separator <= 0) continue;
    final name = entry.substring(0, separator).trim().toLowerCase();
    if (name != target) continue;
    final value = entry.substring(separator + 1).trim();
    if (value.isEmpty) return null;
    return value;
  }
  return null;
}

String? _extractSapisidFromCookieHeader(String? cookieHeader) {
  final secure3p = _getCookieValueByName(cookieHeader, '__Secure-3PAPISID');
  if (secure3p != null && secure3p.isNotEmpty) return secure3p;

  final sapisid = _getCookieValueByName(cookieHeader, 'SAPISID');
  if (sapisid != null && sapisid.isNotEmpty) return sapisid;

  final apisid = _getCookieValueByName(cookieHeader, 'APISID');
  if (apisid != null && apisid.isNotEmpty) return apisid;

  return null;
}

String? _buildSapisidAuthorization(String? cookieHeader, {String? origin}) {
  final sapisid = _extractSapisidFromCookieHeader(cookieHeader);
  if (sapisid == null || sapisid.isEmpty) return null;

  final normalizedOrigin = (origin ?? domain).replaceFirst(RegExp(r'/$'), '');
  final unixTimestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final input = '$unixTimestamp $sapisid $normalizedOrigin';
  final digest = sha1.convert(utf8.encode(input)).toString();
  return 'SAPISIDHASH ${unixTimestamp}_$digest';
}

final Map<String, String> headers = {
  'user-agent': userAgent,
  'accept': '*/*',
  'accept-encoding': 'gzip, deflate',
  'content-type': 'application/json',
  'content-encoding': 'gzip',
  'origin': domain,
  'cookie': 'SOCS=CAI; CONSENT=YES+1',
};

const String _ytAuthCookieHeaderPrefKey = 'yt_music_auth_cookie_header_v1';
String? _cachedYtAuthCookieHeader;

String? _normalizeCookieHeader(String? rawCookieHeader) {
  final raw = rawCookieHeader?.trim();
  if (raw == null || raw.isEmpty) return null;

  final parts = raw
      .split(';')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty && e.contains('='))
      .toList();
  if (parts.isEmpty) return null;

  final normalizedByName = <String, String>{};
  for (final part in parts) {
    final separator = part.indexOf('=');
    if (separator <= 0) continue;
    final name = part.substring(0, separator).trim();
    final value = part.substring(separator + 1).trim();
    if (name.isEmpty || value.isEmpty) continue;
    normalizedByName[name] = value;
  }

  if (normalizedByName.isEmpty) return null;
  return normalizedByName.entries
      .map((entry) => '${entry.key}=${entry.value}')
      .join('; ');
}

String _composeCookieHeader(String? authCookieHeader) {
  final baseCookie = headers['cookie']?.trim() ?? '';
  final auth = _normalizeCookieHeader(authCookieHeader);
  if (auth == null || auth.isEmpty) return baseCookie;

  if (auth.contains('CONSENT=')) {
    return auth;
  }
  if (baseCookie.isEmpty) return auth;
  return '$baseCookie; $auth';
}

Map<String, String> _buildRequestHeaders({String? authCookieHeader}) {
  final requestHeaders = Map<String, String>.from(headers);
  if (_cachedVisitorId != null && _cachedVisitorId!.trim().isNotEmpty) {
    requestHeaders['x-goog-visitor-id'] = _cachedVisitorId!.trim();
  }
  requestHeaders['cookie'] = _composeCookieHeader(authCookieHeader);
  final origin = domain.replaceFirst(RegExp(r'/$'), '');
  final authorization = _buildSapisidAuthorization(
    authCookieHeader,
    origin: origin,
  );
  if (authorization != null && authorization.isNotEmpty) {
    requestHeaders['authorization'] = authorization;
    requestHeaders['x-origin'] = origin;
    requestHeaders['x-goog-authuser'] = '0';
    requestHeaders['referer'] = '$origin/';
  }
  return requestHeaders;
}

Future<void> _ensureVisitorIdLoaded() async {
  if (_visitorIdLoadAttempted) return;
  _visitorIdLoadAttempted = true;

  try {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 12),
      ),
    );
    final response = await dio.get<String>(
      domain,
      options: Options(
        headers: {
          'user-agent': userAgent,
          'accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        },
      ),
    );
    final html = response.data ?? '';
    if (html.isEmpty) {
      _ytLibLog('_ensureVisitorIdLoaded no html response');
      return;
    }

    final matches = RegExp(
      r'ytcfg\.set\s*\(\s*({.+?})\s*\)\s*;',
      dotAll: true,
    ).allMatches(html);
    for (final match in matches) {
      final jsonChunk = match.group(1);
      if (jsonChunk == null || jsonChunk.isEmpty) continue;
      try {
        final parsed = jsonDecode(jsonChunk);
        if (parsed is Map && parsed['VISITOR_DATA'] is String) {
          final visitor = (parsed['VISITOR_DATA'] as String).trim();
          if (visitor.isNotEmpty) {
            _cachedVisitorId = visitor;
            _ytLibLog(
              '_ensureVisitorIdLoaded visitorId loaded len=${visitor.length}',
            );
            return;
          }
        }
      } catch (_) {
        // Continuar con el siguiente bloque ytcfg.
      }
    }
    _ytLibLog('_ensureVisitorIdLoaded visitorId not found in ytcfg');
  } catch (e) {
    _ytLibLog('_ensureVisitorIdLoaded exception: $e');
  }
}

String _buildCurrentClientVersion() {
  final nowUtc = DateTime.now().toUtc();
  final year = nowUtc.year.toString().padLeft(4, '0');
  final month = nowUtc.month.toString().padLeft(2, '0');
  final day = nowUtc.day.toString().padLeft(2, '0');
  return '1.$year$month$day.01.00';
}

Future<String?> getYtMusicAuthCookieHeader() async {
  if (_cachedYtAuthCookieHeader != null) return _cachedYtAuthCookieHeader;
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_ytAuthCookieHeaderPrefKey);
    _cachedYtAuthCookieHeader = _normalizeCookieHeader(raw);
    _ytLibLog(
      'getYtMusicAuthCookieHeader loaded: ${_cookieDebugSummary(_cachedYtAuthCookieHeader)}',
    );
    return _cachedYtAuthCookieHeader;
  } catch (_) {
    _ytLibLog('getYtMusicAuthCookieHeader failed to load cookie');
    return null;
  }
}

Future<void> setYtMusicAuthCookieHeader(String rawCookieHeader) async {
  final normalized = _normalizeCookieHeader(rawCookieHeader);
  final prefs = await SharedPreferences.getInstance();
  if (normalized == null || normalized.isEmpty) {
    await prefs.remove(_ytAuthCookieHeaderPrefKey);
    _cachedYtAuthCookieHeader = null;
    return;
  }
  await prefs.setString(_ytAuthCookieHeaderPrefKey, normalized);
  _cachedYtAuthCookieHeader = normalized;
}

Future<void> clearYtMusicAuthCookieHeader() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_ytAuthCookieHeaderPrefKey);
  _cachedYtAuthCookieHeader = null;
}

Future<bool> hasYtMusicAuthCookieHeader() async {
  final cookie = await getYtMusicAuthCookieHeader();
  final hasCookie = cookie != null && cookie.trim().isNotEmpty;
  _ytLibLog(
    'hasYtMusicAuthCookieHeader -> $hasCookie (${_cookieDebugSummary(cookie)})',
  );
  return hasCookie;
}

final Map<String, dynamic> ytServiceContext = {
  'context': {
    'client': {
      "clientName": "WEB_REMIX",
      "clientVersion": _buildCurrentClientVersion(),
    },
    'user': {},
  },
};

final Map<String, Map<String, String?>> _songTypeInfoByVideoIdCache =
    <String, Map<String, String?>>{};
final Map<String, Future<Map<String, String?>>> _songTypeInfoInFlightByVideoId =
    <String, Future<Map<String, String?>>>{};

class YtMusicResult {
  final String? title;
  final String? artist;
  final String? thumbUrl;
  final String? videoId;
  final String? durationText;
  final int? durationMs;
  final String? resultType;
  final String? videoType;

  YtMusicResult({
    this.title,
    this.artist,
    this.thumbUrl,
    this.videoId,
    this.durationText,
    this.durationMs,
    this.resultType,
    this.videoType,
  });
}

String? _normalizeYtResultType(String? raw) {
  final value = raw?.trim().toLowerCase();
  if (value == null || value.isEmpty) return null;
  return value;
}

String? _normalizeYtVideoType(String? raw) {
  final value = raw?.trim();
  if (value == null || value.isEmpty) return null;
  return value.toUpperCase();
}

String? _extractRendererMusicVideoType(dynamic renderer) {
  if (renderer == null) return null;

  final overlayType = nav(renderer, [
    'overlay',
    'musicItemThumbnailOverlayRenderer',
    'content',
    'musicPlayButtonRenderer',
    'playNavigationEndpoint',
    'watchEndpoint',
    'watchEndpointMusicSupportedConfigs',
    'watchEndpointMusicConfig',
    'musicVideoType',
  ])?.toString();

  final navigationType = nav(renderer, [
    'navigationEndpoint',
    'watchEndpoint',
    'watchEndpointMusicSupportedConfigs',
    'watchEndpointMusicConfig',
    'musicVideoType',
  ])?.toString();

  final menuType = nav(renderer, [
    'menu',
    'menuRenderer',
    'items',
    0,
    'menuNavigationItemRenderer',
    'navigationEndpoint',
    'watchEndpoint',
    'watchEndpointMusicSupportedConfigs',
    'watchEndpointMusicConfig',
    'musicVideoType',
  ])?.toString();

  return _normalizeYtVideoType(overlayType ?? navigationType ?? menuType);
}

String _inferResultTypeFromVideoType(
  String? videoType, {
  String fallback = 'video',
}) {
  final normalizedVideoType = _normalizeYtVideoType(videoType);
  if (normalizedVideoType == 'MUSIC_VIDEO_TYPE_ATV' ||
      normalizedVideoType == 'MUSIC_VIDEO_TYPE_PRIVATELY_OWNED_TRACK') {
    return 'song';
  }
  if (normalizedVideoType == 'MUSIC_VIDEO_TYPE_PODCAST_EPISODE') {
    return 'episode';
  }
  return _normalizeYtResultType(fallback) ?? 'video';
}

Future<Map<String, String?>> getSongTypeInfoByVideoId(String videoId) async {
  final normalizedVideoId = videoId.trim();
  if (normalizedVideoId.isEmpty) {
    // ignore: avoid_print
    print('[YT_TYPE_DEBUG] getSongTypeInfoByVideoId:skip_empty_video_id');
    return const <String, String?>{'resultType': null, 'videoType': null};
  }

  final cached = _songTypeInfoByVideoIdCache[normalizedVideoId];
  if (cached != null) {
    // ignore: avoid_print
    print(
      '[YT_TYPE_DEBUG] getSongTypeInfoByVideoId:cache_hit videoId=$normalizedVideoId resultType=${cached['resultType']} videoType=${cached['videoType']}',
    );
    return Map<String, String?>.from(cached);
  }

  final inFlight = _songTypeInfoInFlightByVideoId[normalizedVideoId];
  if (inFlight != null) {
    // ignore: avoid_print
    print(
      '[YT_TYPE_DEBUG] getSongTypeInfoByVideoId:inflight_hit videoId=$normalizedVideoId',
    );
    return await inFlight;
  }

  final future = () async {
    // ignore: avoid_print
    print(
      '[YT_TYPE_DEBUG] getSongTypeInfoByVideoId:request_start videoId=$normalizedVideoId',
    );
    try {
      final data = <String, dynamic>{
        ...ytServiceContext,
        'videoId': normalizedVideoId,
        // ytmusicapi usa `video_id` en get_song; enviamos ambos por compatibilidad.
        'video_id': normalizedVideoId,
      };
      final response = (await sendRequest('player', data)).data;
      final rawVideoType = nav(response, [
        'videoDetails',
        'musicVideoType',
      ])?.toString();
      final videoType = _normalizeYtVideoType(rawVideoType);
      final resultType = videoType == null
          ? null
          : _inferResultTypeFromVideoType(videoType);
      final payload = <String, String?>{
        'resultType': resultType,
        'videoType': videoType,
      };
      // ignore: avoid_print
      print(
        '[YT_TYPE_DEBUG] getSongTypeInfoByVideoId:request_done videoId=$normalizedVideoId resultType=$resultType videoType=$videoType',
      );
      _songTypeInfoByVideoIdCache[normalizedVideoId] = payload;
      return payload;
    } catch (e) {
      // ignore: avoid_print
      print(
        '[YT_TYPE_DEBUG] getSongTypeInfoByVideoId:request_error videoId=$normalizedVideoId error=$e',
      );
      return const <String, String?>{'resultType': null, 'videoType': null};
    } finally {
      _songTypeInfoInFlightByVideoId.remove(normalizedVideoId);
      // ignore: avoid_print
      print(
        '[YT_TYPE_DEBUG] getSongTypeInfoByVideoId:request_end videoId=$normalizedVideoId',
      );
    }
  }();

  _songTypeInfoInFlightByVideoId[normalizedVideoId] = future;
  return await future;
}

class YtMusicLibraryPlaylist {
  final String playlistId;
  final String title;
  final String? author;
  final String? thumbUrl;
  final String? countText;
  final int? trackCount;

  const YtMusicLibraryPlaylist({
    required this.playlistId,
    required this.title,
    this.author,
    this.thumbUrl,
    this.countText,
    this.trackCount,
  });
}

void _collectMapsByKey(
  dynamic node,
  String key,
  List<Map<String, dynamic>> out,
) {
  if (node == null) return;
  if (node is Map) {
    final value = node[key];
    if (value is Map<String, dynamic>) {
      out.add(value);
    } else if (value is Map) {
      out.add(Map<String, dynamic>.from(value));
    }
    for (final child in node.values) {
      _collectMapsByKey(child, key, out);
    }
    return;
  }
  if (node is List) {
    for (final child in node) {
      _collectMapsByKey(child, key, out);
    }
  }
}

int? _parseCountFromText(String? text) {
  final normalized = text?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  final match = RegExp(r'(\d[\d\.,]*)').firstMatch(normalized);
  if (match == null) return null;
  final digits = match.group(1)?.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits == null || digits.isEmpty) return null;
  return int.tryParse(digits);
}

String? _extractPlaylistIdFromTwoRowRenderer(Map<String, dynamic> renderer) {
  String? browseId = nav(renderer, [
    'title',
    'runs',
    0,
    'navigationEndpoint',
    'browseEndpoint',
    'browseId',
  ])?.toString();

  browseId ??= nav(renderer, [
    'overlay',
    'musicItemThumbnailOverlayRenderer',
    'content',
    'musicPlayButtonRenderer',
    'playNavigationEndpoint',
    'watchPlaylistEndpoint',
    'playlistId',
  ])?.toString();

  browseId ??= nav(renderer, [
    'overlay',
    'musicItemThumbnailOverlayRenderer',
    'content',
    'musicPlayButtonRenderer',
    'playNavigationEndpoint',
    'watchEndpoint',
    'playlistId',
  ])?.toString();

  final menuItems = nav(renderer, ['menu', 'menuRenderer', 'items']);
  if ((browseId == null || browseId.isEmpty) && menuItems is List) {
    for (final raw in menuItems) {
      if (raw is! Map) continue;
      final menuRenderer = raw['menuNavigationItemRenderer'];
      if (menuRenderer is! Map) continue;

      final endpoint = menuRenderer['navigationEndpoint'];
      if (endpoint is! Map) continue;

      final fromBrowse = nav(endpoint, [
        'browseEndpoint',
        'browseId',
      ])?.toString().trim();
      if (fromBrowse != null && fromBrowse.isNotEmpty) {
        browseId = fromBrowse;
        break;
      }

      final fromWatchPlaylist = nav(endpoint, [
        'watchPlaylistEndpoint',
        'playlistId',
      ])?.toString().trim();
      if (fromWatchPlaylist != null && fromWatchPlaylist.isNotEmpty) {
        browseId = fromWatchPlaylist;
        break;
      }

      final fromWatch = nav(endpoint, [
        'watchEndpoint',
        'playlistId',
      ])?.toString().trim();
      if (fromWatch != null && fromWatch.isNotEmpty) {
        browseId = fromWatch;
        break;
      }
    }
  }

  final raw = browseId?.trim();
  if (raw == null || raw.isEmpty) return null;
  if (raw.startsWith('VL')) {
    final trimmed = raw.substring(2).trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  return raw;
}

YtMusicLibraryPlaylist? _parseLibraryPlaylistRenderer(
  Map<String, dynamic> renderer,
) {
  final pageType = nav(renderer, [
    'title',
    'runs',
    0,
    'navigationEndpoint',
    'browseEndpoint',
    'browseEndpointContextSupportedConfigs',
    'browseEndpointContextMusicConfig',
    'pageType',
  ])?.toString();
  if (pageType != null &&
      pageType.isNotEmpty &&
      !pageType.contains('PLAYLIST')) {
    return null;
  }

  final playlistId = _extractPlaylistIdFromTwoRowRenderer(renderer);
  if (playlistId == null || playlistId.isEmpty) return null;

  final title =
      nav(renderer, ['title', 'runs', 0, 'text'])?.toString().trim() ??
      nav(renderer, ['title', 'simpleText'])?.toString().trim();
  if (title == null || title.isEmpty) return null;

  dynamic thumbnails = nav(renderer, [
    'thumbnailRenderer',
    'musicThumbnailRenderer',
    'thumbnail',
    'thumbnails',
  ]);
  thumbnails ??= nav(renderer, [
    'thumbnail',
    'musicThumbnailRenderer',
    'thumbnail',
    'thumbnails',
  ]);
  thumbnails ??= nav(renderer, [
    'thumbnail',
    'croppedSquareThumbnailRenderer',
    'thumbnail',
    'thumbnails',
  ]);

  String? thumbUrl;
  if (thumbnails is List && thumbnails.isNotEmpty) {
    final rawThumb = thumbnails.last['url']?.toString().trim();
    if (rawThumb != null && rawThumb.isNotEmpty) {
      thumbUrl = _cleanThumbnailUrl(rawThumb, highQuality: true);
    }
  }

  final subtitleRuns = nav(renderer, ['subtitle', 'runs']);
  String? countText;
  int? trackCount;
  String? author;

  if (subtitleRuns is List) {
    for (final rawRun in subtitleRuns) {
      if (rawRun is! Map) continue;
      final text = rawRun['text']?.toString().trim();
      if (text == null || text.isEmpty || text == '•' || text == '·') {
        continue;
      }

      final lower = text.toLowerCase();
      if (countText == null &&
          (lower.contains('song') ||
              lower.contains('track') ||
              lower.contains('video') ||
              lower.contains('canci') ||
              lower.contains('tema'))) {
        countText = text;
        trackCount = _parseCountFromText(text) ?? trackCount;
      }

      if (author == null && rawRun['navigationEndpoint'] is Map) {
        final browseId = nav(rawRun, [
          'navigationEndpoint',
          'browseEndpoint',
          'browseId',
        ])?.toString();
        if (browseId != null &&
            browseId.isNotEmpty &&
            (browseId.startsWith('UC') || browseId.startsWith('MPLA'))) {
          author = text;
        }
      }
    }
  }

  return YtMusicLibraryPlaylist(
    playlistId: playlistId,
    title: title,
    author: author,
    thumbUrl: thumbUrl,
    countText: countText,
    trackCount: trackCount,
  );
}

YtMusicLibraryPlaylist? _parseLibraryPlaylistResponsiveRenderer(
  Map<String, dynamic> renderer,
) {
  String? browseId = nav(renderer, [
    'flexColumns',
    0,
    'musicResponsiveListItemFlexColumnRenderer',
    'text',
    'runs',
    0,
    'navigationEndpoint',
    'browseEndpoint',
    'browseId',
  ])?.toString();

  browseId ??= nav(renderer, [
    'overlay',
    'musicItemThumbnailOverlayRenderer',
    'content',
    'musicPlayButtonRenderer',
    'playNavigationEndpoint',
    'watchPlaylistEndpoint',
    'playlistId',
  ])?.toString();

  final normalizedBrowseId = browseId?.trim();
  if (normalizedBrowseId == null || normalizedBrowseId.isEmpty) return null;
  final playlistId = normalizedBrowseId.startsWith('VL')
      ? normalizedBrowseId.substring(2)
      : normalizedBrowseId;
  if (playlistId.isEmpty) return null;

  final title =
      nav(renderer, [
        'flexColumns',
        0,
        'musicResponsiveListItemFlexColumnRenderer',
        'text',
        'runs',
        0,
        'text',
      ])?.toString().trim() ??
      nav(renderer, [
        'flexColumns',
        0,
        'musicResponsiveListItemFlexColumnRenderer',
        'text',
        'simpleText',
      ])?.toString().trim();
  if (title == null || title.isEmpty) return null;

  dynamic thumbnails = nav(renderer, [
    'thumbnail',
    'musicThumbnailRenderer',
    'thumbnail',
    'thumbnails',
  ]);
  thumbnails ??= nav(renderer, [
    'thumbnail',
    'croppedSquareThumbnailRenderer',
    'thumbnail',
    'thumbnails',
  ]);
  String? thumbUrl;
  if (thumbnails is List && thumbnails.isNotEmpty) {
    final rawThumb = thumbnails.last['url']?.toString().trim();
    if (rawThumb != null && rawThumb.isNotEmpty) {
      thumbUrl = _cleanThumbnailUrl(rawThumb, highQuality: true);
    }
  }

  final subtitleRuns = nav(renderer, [
    'flexColumns',
    1,
    'musicResponsiveListItemFlexColumnRenderer',
    'text',
    'runs',
  ]);
  String? countText;
  int? trackCount;
  String? author;
  if (subtitleRuns is List) {
    for (final rawRun in subtitleRuns) {
      if (rawRun is! Map) continue;
      final text = rawRun['text']?.toString().trim();
      if (text == null || text.isEmpty || text == '•' || text == '·') {
        continue;
      }

      final lower = text.toLowerCase();
      if (countText == null &&
          (lower.contains('song') ||
              lower.contains('track') ||
              lower.contains('video') ||
              lower.contains('canci') ||
              lower.contains('tema'))) {
        countText = text;
        trackCount = _parseCountFromText(text) ?? trackCount;
      }

      if (author == null && rawRun['navigationEndpoint'] is Map) {
        final artistId = nav(rawRun, [
          'navigationEndpoint',
          'browseEndpoint',
          'browseId',
        ])?.toString();
        if (artistId != null &&
            artistId.isNotEmpty &&
            (artistId.startsWith('UC') || artistId.startsWith('MPLA'))) {
          author = text;
        }
      }
    }
  }

  return YtMusicLibraryPlaylist(
    playlistId: playlistId,
    title: title,
    author: author,
    thumbUrl: thumbUrl,
    countText: countText,
    trackCount: trackCount,
  );
}

String? _extractLibraryPlaylistsContinuationToken(dynamic response) {
  final direct =
      nav(response, [
        'continuationContents',
        'gridContinuation',
        'continuations',
        0,
        'nextContinuationData',
        'continuation',
      ]) ??
      nav(response, [
        'continuationContents',
        'musicShelfContinuation',
        'continuations',
        0,
        'nextContinuationData',
        'continuation',
      ]) ??
      nav(response, [
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
  final normalized = direct?.toString().trim();
  if (normalized == null || normalized.isEmpty) return null;
  return normalized;
}

List<YtMusicLibraryPlaylist> _parseLibraryPlaylists(dynamic response) {
  final renderers = <Map<String, dynamic>>[];
  _collectMapsByKey(response, 'musicTwoRowItemRenderer', renderers);

  final responsiveRenderers = <Map<String, dynamic>>[];
  _collectMapsByKey(
    response,
    'musicResponsiveListItemRenderer',
    responsiveRenderers,
  );

  final parsed = <YtMusicLibraryPlaylist>[];
  final seenIds = <String>{};

  for (final renderer in renderers) {
    final playlist = _parseLibraryPlaylistRenderer(renderer);
    if (playlist == null) continue;
    if (!seenIds.add(playlist.playlistId)) continue;
    parsed.add(playlist);
  }

  for (final renderer in responsiveRenderers) {
    final playlist = _parseLibraryPlaylistResponsiveRenderer(renderer);
    if (playlist == null) continue;
    if (!seenIds.add(playlist.playlistId)) continue;
    parsed.add(playlist);
  }

  return parsed;
}

String? _normalizeAccountAvatarUrl(String? rawUrl) {
  final trimmed = rawUrl?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  final withScheme = trimmed.startsWith('//') ? 'https:$trimmed' : trimmed;
  if (!withScheme.startsWith('http')) return null;
  return _cleanThumbnailUrl(withScheme);
}

String? _extractAccountAvatarUrl(dynamic response) {
  final urls = <String>[];

  void collect(dynamic node) {
    if (node is Map) {
      for (final entry in node.entries) {
        final key = entry.key.toString().toLowerCase();
        final value = entry.value;
        if (key == 'url' && value is String) {
          final lower = value.toLowerCase();
          if (lower.contains('yt3.ggpht.com') ||
              lower.contains('googleusercontent.com') ||
              lower.contains('ggpht.com')) {
            urls.add(value);
          }
        }
        collect(value);
      }
      return;
    }
    if (node is List) {
      for (final child in node) {
        collect(child);
      }
    }
  }

  collect(response);
  for (final raw in urls) {
    final normalized = _normalizeAccountAvatarUrl(raw);
    if (normalized == null || normalized.isEmpty) continue;
    return normalized;
  }
  return null;
}

Future<List<YtMusicLibraryPlaylist>> getLibraryPlaylists({
  int? limit = 100,
}) async {
  final data = {...ytServiceContext, 'browseId': 'FEmusic_liked_playlists'};
  final all = <YtMusicLibraryPlaylist>[];
  final seenIds = <String>{};
  final visitedTokens = <String>{};

  try {
    final authCookie = await getYtMusicAuthCookieHeader();
    _ytLibLog(
      'getLibraryPlaylists start: limit=$limit, auth=${_cookieDebugSummary(authCookie)}',
    );

    final firstRequest = await sendRequest('browse', data);
    final firstResponse = firstRequest.data;
    _ytLibLog(
      'getLibraryPlaylists first request status=${firstRequest.statusCode}',
    );
    final debugTwoRow = <Map<String, dynamic>>[];
    _collectMapsByKey(firstResponse, 'musicTwoRowItemRenderer', debugTwoRow);
    final debugResponsive = <Map<String, dynamic>>[];
    _collectMapsByKey(
      firstResponse,
      'musicResponsiveListItemRenderer',
      debugResponsive,
    );
    _ytLibLog(
      'getLibraryPlaylists first renderer counts: twoRow=${debugTwoRow.length}, responsive=${debugResponsive.length}',
    );

    final firstPage = _parseLibraryPlaylists(firstResponse);
    _ytLibLog('getLibraryPlaylists first parsed count=${firstPage.length}');
    for (final playlist in firstPage) {
      if (!seenIds.add(playlist.playlistId)) continue;
      all.add(playlist);
      if (limit != null && all.length >= limit) {
        _ytLibLog(
          'getLibraryPlaylists done by limit on first page: ${all.length}',
        );
        return all.take(limit).toList();
      }
    }

    String? nextToken = _extractLibraryPlaylistsContinuationToken(
      firstResponse,
    );
    _ytLibLog(
      'getLibraryPlaylists first continuation present=${nextToken != null && nextToken.isNotEmpty}',
    );
    while (nextToken != null &&
        nextToken.isNotEmpty &&
        visitedTokens.add(nextToken)) {
      final encoded = Uri.encodeQueryComponent(nextToken);
      final continuationRequest = await sendRequest(
        'browse',
        data,
        additionalParams: '&ctoken=$encoded&continuation=$encoded',
      );
      final continuationResponse = continuationRequest.data;
      _ytLibLog(
        'getLibraryPlaylists continuation status=${continuationRequest.statusCode}, tokenLen=${nextToken.length}',
      );

      final page = _parseLibraryPlaylists(continuationResponse);
      _ytLibLog('getLibraryPlaylists continuation parsed count=${page.length}');
      if (page.isEmpty) break;

      for (final playlist in page) {
        if (!seenIds.add(playlist.playlistId)) continue;
        all.add(playlist);
        if (limit != null && all.length >= limit) {
          _ytLibLog(
            'getLibraryPlaylists done by limit with continuations: ${all.length}',
          );
          return all.take(limit).toList();
        }
      }

      nextToken = _extractLibraryPlaylistsContinuationToken(
        continuationResponse,
      );
    }
    _ytLibLog('getLibraryPlaylists done: total=${all.length}');
  } catch (e) {
    _ytLibLog('getLibraryPlaylists exception while loading playlists: $e');
    return all;
  }

  return all;
}

Future<String?> getYtMusicAccountAvatarUrl() async {
  String? parseAvatar(dynamic response) {
    final direct = nav(response, [
      'actions',
      0,
      'openPopupAction',
      'popup',
      'multiPageMenuRenderer',
      'header',
      'activeAccountHeaderRenderer',
      'accountPhoto',
      'thumbnails',
      0,
      'url',
    ])?.toString();
    final normalizedDirect = _normalizeAccountAvatarUrl(direct);
    if (normalizedDirect != null && normalizedDirect.isNotEmpty) {
      return normalizedDirect;
    }
    return _extractAccountAvatarUrl(response);
  }

  try {
    final response = (await sendRequest('account/account_menu', {
      ...ytServiceContext,
    })).data;
    final avatarUrl = parseAvatar(response);
    final rootKeys = response is Map
        ? response.keys.take(10).toList()
        : const [];
    _ytLibLog(
      'getYtMusicAccountAvatarUrl account/account_menu -> ${avatarUrl != null && avatarUrl.isNotEmpty}, rootKeys=$rootKeys',
    );
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      return avatarUrl;
    }
  } catch (e) {
    _ytLibLog('getYtMusicAccountAvatarUrl account/account_menu exception: $e');
  }

  // Fallback para variantes antiguas.
  try {
    final data = {...ytServiceContext};
    final response = (await sendRequest('account/get_account_menu', data)).data;
    final avatarUrl = parseAvatar(response);
    _ytLibLog(
      'getYtMusicAccountAvatarUrl account/get_account_menu -> ${avatarUrl != null && avatarUrl.isNotEmpty}',
    );
    return avatarUrl;
  } catch (e) {
    _ytLibLog('getYtMusicAccountAvatarUrl exception: $e');
    return null;
  }
}

String? _extractTextFromRuns(dynamic runs) {
  if (runs is! List) return null;
  final buffer = StringBuffer();
  for (final run in runs) {
    final text = run is Map ? run['text']?.toString() : null;
    if (text == null || text.trim().isEmpty) continue;
    buffer.write(text);
  }
  final value = buffer.toString().trim();
  return value.isEmpty ? null : value;
}

String? _extractAccountDisplayName(dynamic response) {
  final candidates = <String?>[
    nav(response, [
      'actions',
      0,
      'openPopupAction',
      'popup',
      'multiPageMenuRenderer',
      'header',
      'activeAccountHeaderRenderer',
      'accountName',
      'simpleText',
    ])?.toString(),
    _extractTextFromRuns(
      nav(response, [
        'actions',
        0,
        'openPopupAction',
        'popup',
        'multiPageMenuRenderer',
        'header',
        'activeAccountHeaderRenderer',
        'accountName',
        'runs',
      ]),
    ),
    nav(response, [
      'actions',
      0,
      'openPopupAction',
      'popup',
      'multiPageMenuRenderer',
      'header',
      'activeAccountHeaderRenderer',
      'channelHandle',
      'simpleText',
    ])?.toString(),
    _extractTextFromRuns(
      nav(response, [
        'actions',
        0,
        'openPopupAction',
        'popup',
        'multiPageMenuRenderer',
        'header',
        'activeAccountHeaderRenderer',
        'channelHandle',
        'runs',
      ]),
    ),
    nav(response, [
      'actions',
      0,
      'openPopupAction',
      'popup',
      'multiPageMenuRenderer',
      'header',
      'activeAccountHeaderRenderer',
      'email',
      'simpleText',
    ])?.toString(),
  ];

  for (final candidate in candidates) {
    final normalized = candidate?.trim();
    if (normalized != null && normalized.isNotEmpty) {
      return normalized;
    }
  }

  final activeHeader = _findObjectByKey(
    response,
    'activeAccountHeaderRenderer',
  );
  if (activeHeader is Map) {
    final fallback = _extractTextFromRuns(
      nav(activeHeader, ['accountName', 'runs']),
    );
    if (fallback != null && fallback.isNotEmpty) return fallback;
  }

  return null;
}

Future<String?> getYtMusicAccountDisplayName() async {
  try {
    final response = (await sendRequest('account/account_menu', {
      ...ytServiceContext,
    })).data;
    final name = _extractAccountDisplayName(response);
    _ytLibLog(
      'getYtMusicAccountDisplayName account/account_menu -> ${name != null && name.isNotEmpty}',
    );
    if (name != null && name.isNotEmpty) return name;
  } catch (e) {
    _ytLibLog(
      'getYtMusicAccountDisplayName account/account_menu exception: $e',
    );
  }

  try {
    final response = (await sendRequest('account/get_account_menu', {
      ...ytServiceContext,
    })).data;
    final name = _extractAccountDisplayName(response);
    _ytLibLog(
      'getYtMusicAccountDisplayName account/get_account_menu -> ${name != null && name.isNotEmpty}',
    );
    return name;
  } catch (e) {
    _ytLibLog('getYtMusicAccountDisplayName exception: $e');
    return null;
  }
}

// Búsqueda recursiva de una clave dentro de un árbol Map/List
dynamic _findObjectByKey(dynamic node, String key) {
  if (node == null) return null;
  if (node is Map) {
    if (node.containsKey(key)) return node[key];
    for (final v in node.values) {
      final found = _findObjectByKey(v, key);
      if (found != null) return found;
    }
  } else if (node is List) {
    for (final item in node) {
      final found = _findObjectByKey(item, key);
      if (found != null) return found;
    }
  }
  return null;
}

// Helper para buscar texto dentro de 'runs' usando palabras clave
String? _findTextInRuns(
  dynamic container,
  List<List<String>> paths,
  List<String> keywords,
) {
  for (var path in paths) {
    // Construimos la ruta completa a 'runs'
    var fullPath = [...path, 'runs'];
    final runs = nav(container, fullPath);

    if (runs is List) {
      for (var run in runs) {
        final text = run['text']?.toString();
        if (text != null) {
          // Verificar si contiene alguna de las palabras clave
          for (var keyword in keywords) {
            if (text.toLowerCase().contains(keyword.toLowerCase())) {
              return text;
            }
          }
        }
      }
    }
  }
  return null;
}

// Obtiene información detallada de un artista usando su browseId
Future<Map<String, dynamic>?> getArtistDetails(String browseId) async {
  String normalizedId = browseId;
  if (normalizedId.startsWith('MPLA')) {
    normalizedId = normalizedId.substring(4);
  }

  final data = {...ytServiceContext, 'browseId': normalizedId};
  try {
    final ctx = (data['context'] as Map);
    final client = (ctx['client'] as Map);
    final locale = languageNotifier.value;
    client['hl'] = locale.startsWith('es') ? 'es' : 'en';
  } catch (_) {}

  try {
    final response = (await sendRequest("browse", data)).data;

    // Buscar header
    var header =
        nav(response, ['header', 'musicImmersiveHeaderRenderer']) ??
        nav(response, ['header', 'musicVisualHeaderRenderer']) ??
        nav(response, ['header', 'musicResponsiveHeaderRenderer']);

    header ??= nav(response, [
      'contents',
      'singleColumnBrowseResultsRenderer',
      'tabs',
      0,
      'tabRenderer',
      'content',
      'sectionListRenderer',
      'contents',
      0,
      'musicResponsiveHeaderRenderer',
    ]);

    String? name;
    String? subscribers;
    String? thumbUrl;
    String? monthlyListeners;

    if (header != null) {
      name = nav(header, ['title', 'runs', 0, 'text']);

      // 1. OBTENER SUSCRIPTORES
      // Intento directo desde el botón
      subscribers = nav(header, [
        'subscriptionButton',
        'subscribeButtonRenderer',
        'subscriberCountText',
        'runs',
        0,
        'text',
      ]);

      // Si falla, buscar textualmente en los campos de texto del header
      subscribers ??= _findTextInRuns(
        header,
        [
          ['subtitle'],
          ['secondSubtitle'],
          ['straplineTextOne'],
        ],
        ['subscri', 'suscri'], // Keywords para suscriptores
      );

      // 2. OBTENER OYENTES MENSUALES (Público mensual)
      // Buscar en los mismos campos pero con keywords de audiencia
      monthlyListeners = _findTextInRuns(
        header,
        [
          ['straplineTextOne'],
          ['subtitle'],
          ['secondSubtitle'],
        ],
        [
          'oyentes',
          'listeners',
          'publico',
          'público',
          'audiencia',
          'audience',
          'audiences',
          'viewers',
          'vistas',
        ],
      );

      // Thumbnail
      var thumbnails =
          nav(header, [
            'thumbnail',
            'musicThumbnailRenderer',
            'thumbnail',
            'thumbnails',
          ]) ??
          nav(header, [
            'thumbnail',
            'croppedSquareThumbnailRenderer',
            'thumbnail',
            'thumbnails',
          ]);

      if (thumbnails == null && header is Map) {
        final possibleThumb = _findObjectByKey(header, 'thumbnails');
        if (possibleThumb is List) thumbnails = possibleThumb;
      }

      if (thumbnails is List && thumbnails.isNotEmpty) {
        thumbUrl = thumbnails.last['url'];
        if (thumbUrl != null) {
          thumbUrl = _cleanThumbnailUrl(thumbUrl);
        }
      }
    }

    // Descripción
    String? description;
    final results = nav(response, [
      'contents',
      'singleColumnBrowseResultsRenderer',
      'tabs',
      0,
      'tabRenderer',
      'content',
      'sectionListRenderer',
      'contents',
    ]);

    if (results != null) {
      final descRenderer = _findObjectByKey(
        results,
        'musicDescriptionShelfRenderer',
      );
      if (descRenderer is Map) {
        final runs = nav(descRenderer, ['description', 'runs']);
        if (runs is List && runs.isNotEmpty) {
          description = runs.map((r) => r['text']).whereType<String>().join('');
        }
      }
    }

    /*
    print("Nombre: $name");
    print("Thumbnail: $thumbUrl");
    print("Suscriptores: $subscribers");
    print("Oyentes Mensuales: $monthlyListeners");
    */

    return {
      'name': name,
      'description': description,
      'thumbUrl': thumbUrl,
      'subscribers': subscribers,
      'monthlyListeners': monthlyListeners,
      'browseId': normalizedId,
    };
  } catch (_) {
    return null;
  }
}

// Helper: busca por nombre y devuelve info detallada del primer artista
Future<Map<String, dynamic>?> getArtistInfoByName(String name) async {
  try {
    final results = await searchArtists(name, limit: 1);
    if (results.isEmpty) return null;
    final first = results.first;
    final browseId = first['browseId'];
    if (browseId == null) return null;
    return await getArtistDetails(browseId);
  } catch (_) {
    return null;
  }
}

// Función para obtener canciones específicas de un artista (con paginación)
Future<Map<String, dynamic>> getArtistSongs(
  String browseId, {
  String? params,
  int initialLimit = 20,
}) async {
  // Si viene con MPLA, quitarlo
  String normalizedId = browseId;
  if (normalizedId.startsWith('MPLA')) {
    normalizedId = normalizedId.substring(4);
  }

  try {
    // Primero, obtener la página del artista
    final artistData = {...ytServiceContext, 'browseId': normalizedId};

    // Configurar idioma
    try {
      final ctx = (artistData['context'] as Map);
      final client = (ctx['client'] as Map);
      final locale = languageNotifier.value;
      client['hl'] = locale.startsWith('es') ? 'es' : 'en';
    } catch (_) {}

    final artistResponse = (await sendRequest("browse", artistData)).data;

    // Buscar las secciones de contenido
    final sections = nav(artistResponse, [
      'contents',
      'singleColumnBrowseResultsRenderer',
      'tabs',
      0,
      'tabRenderer',
      'content',
      'sectionListRenderer',
      'contents',
    ]);

    if (sections == null || sections is! List) {
      return {'results': [], 'continuationToken': null, 'browseEndpoint': null};
    }

    // Buscar el endpoint de "Songs" o "Top songs"
    Map<String, dynamic>? songsEndpoint;
    List<dynamic>? topSongsPreview;

    for (var section in sections) {
      // Buscar en musicShelfRenderer
      if (section.containsKey('musicShelfRenderer')) {
        final shelf = section['musicShelfRenderer'];
        final title = nav(shelf, ['title', 'runs', 0, 'text']);

        if (title != null &&
            (title.toString().toLowerCase().contains('song') ||
                title.toString().toLowerCase().contains('cancion'))) {
          final browseEndpoint = nav(shelf, [
            'bottomEndpoint',
            'browseEndpoint',
          ]);

          if (browseEndpoint != null) {
            songsEndpoint = browseEndpoint;
          }

          final contentList = nav(shelf, ['contents']);
          if (contentList is List) {
            topSongsPreview = contentList;
          }
          break;
        }
      }

      // Buscar en musicCarouselShelfRenderer
      if (section.containsKey('musicCarouselShelfRenderer')) {
        final shelf = section['musicCarouselShelfRenderer'];
        final title = nav(shelf, [
          'header',
          'musicCarouselShelfBasicHeaderRenderer',
          'title',
          'runs',
          0,
          'text',
        ]);

        if (title != null &&
            (title.toString().toLowerCase().contains('song') ||
                title.toString().toLowerCase().contains('cancion'))) {
          final browseEndpoint = nav(shelf, [
            'header',
            'musicCarouselShelfBasicHeaderRenderer',
            'moreContentButton',
            'buttonRenderer',
            'navigationEndpoint',
            'browseEndpoint',
          ]);

          if (browseEndpoint != null) {
            songsEndpoint = browseEndpoint;
          }

          final contentList = nav(shelf, ['contents']);
          if (contentList is List) {
            topSongsPreview = contentList;
          }
          break;
        }
      }
    }

    // Si solo hay preview sin endpoint, devolver eso (sin paginación)
    if (songsEndpoint == null && topSongsPreview != null) {
      final results = <YtMusicResult>[];
      parseSongs(topSongsPreview, results);
      return {
        'results': results.take(initialLimit).toList(),
        'continuationToken': null,
        'browseEndpoint': null,
      };
    }

    if (songsEndpoint == null) {
      return {'results': [], 'continuationToken': null, 'browseEndpoint': null};
    }

    // Obtener las canciones usando el endpoint específico
    final songsBrowseData = {...ytServiceContext};
    songsBrowseData['browseId'] = songsEndpoint['browseId'];
    if (songsEndpoint['params'] != null) {
      songsBrowseData['params'] = songsEndpoint['params'];
    }

    final songResponse = (await sendRequest("browse", songsBrowseData)).data;
    final results = <YtMusicResult>[];

    // Extraer las canciones
    final contents = nav(songResponse, [
      'contents',
      'singleColumnBrowseResultsRenderer',
      'tabs',
      0,
      'tabRenderer',
      'content',
      'sectionListRenderer',
      'contents',
      0,
    ]);

    if (contents != null) {
      var shelfContents = nav(contents, [
        'musicPlaylistShelfRenderer',
        'contents',
      ]);
      shelfContents ??= nav(contents, ['musicShelfRenderer', 'contents']);

      if (shelfContents is List) {
        // Parsear solo los primeros items (sin continuación)
        final itemsToParse = shelfContents.where((item) {
          // Filtrar el continuationItemRenderer
          return item.containsKey('musicResponsiveListItemRenderer');
        }).toList();

        parseSongs(itemsToParse, results);
      }

      // Extraer token de continuación
      String? continuationToken;

      // Buscar en el último item del shelf
      if (shelfContents is List && shelfContents.isNotEmpty) {
        final lastItem = shelfContents.last;
        if (lastItem.containsKey('continuationItemRenderer')) {
          continuationToken = nav(lastItem, [
            'continuationItemRenderer',
            'continuationEndpoint',
            'continuationCommand',
            'token',
          ]);
        }
      }

      // Si no encontramos en el último item, buscar en el shelf mismo
      continuationToken ??= nav(contents, [
        'musicPlaylistShelfRenderer',
        'continuations',
        0,
        'nextContinuationData',
        'continuation',
      ]);

      continuationToken ??= nav(contents, [
        'musicShelfRenderer',
        'continuations',
        0,
        'nextContinuationData',
        'continuation',
      ]);

      return {
        'results': results.take(initialLimit).toList(),
        'continuationToken': continuationToken,
        'browseEndpoint': songsEndpoint, // Guardar para continuaciones
      };
    }

    return {'results': [], 'continuationToken': null, 'browseEndpoint': null};
  } catch (e) {
    // print('❌ Error en getArtistSongs: $e');
    return {'results': [], 'continuationToken': null, 'browseEndpoint': null};
  }
}

// Función para obtener más canciones del artista (continuación)
Future<Map<String, dynamic>> getArtistSongsContinuation({
  required Map<String, dynamic> browseEndpoint,
  required String continuationToken,
  int limit = 20,
}) async {
  try {
    final data = {...ytServiceContext};
    data['browseId'] = browseEndpoint['browseId'];
    if (browseEndpoint['params'] != null) {
      data['params'] = browseEndpoint['params'];
    }

    // Agregar el token de continuación
    final additionalParams =
        '&ctoken=$continuationToken&continuation=$continuationToken';

    final response = (await sendRequest(
      "browse",
      data,
      additionalParams: additionalParams,
    )).data;
    final results = <YtMusicResult>[];

    // Buscar en onResponseReceivedActions (estructura de continuación)
    var contentList = nav(response, [
      'onResponseReceivedActions',
      0,
      'appendContinuationItemsAction',
      'continuationItems',
    ]);

    // Fallback a continuationContents
    contentList ??= nav(response, [
      'continuationContents',
      'musicPlaylistShelfContinuation',
      'contents',
    ]);

    contentList ??= nav(response, [
      'continuationContents',
      'musicShelfContinuation',
      'contents',
    ]);

    if (contentList is List) {
      // Filtrar solo los items de canciones
      final songItems = contentList.where((item) {
        return item.containsKey('musicResponsiveListItemRenderer');
      }).toList();

      parseSongs(songItems, results);

      // Buscar el siguiente token de continuación
      String? nextToken;

      // Buscar en el último item
      final lastItem = contentList.last;
      if (lastItem.containsKey('continuationItemRenderer')) {
        nextToken = nav(lastItem, [
          'continuationItemRenderer',
          'continuationEndpoint',
          'continuationCommand',
          'token',
        ]);
      }

      // Fallback a otras ubicaciones
      nextToken ??= nav(response, [
        'continuationContents',
        'musicPlaylistShelfContinuation',
        'continuations',
        0,
        'nextContinuationData',
        'continuation',
      ]);

      nextToken ??= nav(response, [
        'continuationContents',
        'musicShelfContinuation',
        'continuations',
        0,
        'nextContinuationData',
        'continuation',
      ]);

      nextToken ??= nav(response, [
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

      return {
        'results': results.take(limit).toList(),
        'continuationToken': nextToken,
      };
    }

    return {'results': [], 'continuationToken': null};
  } catch (e) {
    // print('❌ Error en getArtistSongsContinuation: $e');
    return {'results': [], 'continuationToken': null};
  }
}

// Helper: limpia parámetros de recorte de URLs de thumbnails
String _cleanThumbnailUrl(String url, {bool highQuality = false}) {
  if (url.isEmpty) return url;

  // Si es una URL de Google User Content (usada por YTM para artistas)
  if (url.contains('googleusercontent.com') || url.contains('ggpht.com')) {
    // Estas URLs suelen terminar en =sNNN or =wNNN-hNNN
    // Queremos forzar una resolución alta para que no se vea pixeleada
    if (url.contains('=')) {
      final baseUrl = url.split('=')[0];
      // s1200 proporciona una excelente calidad para imágenes de fondo
      // w544-h544 es suficiente para listas y carga mucho más rápido
      return highQuality ? '$baseUrl=s1200' : '$baseUrl=w544-h544';
    }
  }

  // Fallback para otros casos de YouTube (vía parámetros ? o &)
  // Remover parámetros de recorte comunes
  url = url.replaceAll(RegExp(r'[?&]w\d+-h\d+'), '');
  url = url.replaceAll(RegExp(r'[?&]crop=\d+'), '');
  url = url.replaceAll(RegExp(r'[?&]rs=\d+'), '');

  // Limpiar parámetros dobles
  url = url.replaceAll(RegExp(r'[?&]{2,}'), '&');
  url = url.replaceAll(RegExp(r'[?&]$'), '');

  // Si queda solo ?, removerlo
  if (url.endsWith('?')) {
    url = url.substring(0, url.length - 1);
  }

  return url;
}

// ===== Wikipedia Fallback =====
List<String> _getArtistNameVariations(String name) {
  // Variaciones genéricas para cualquier artista, ordenadas por probabilidad de éxito
  // Las más comunes aparecen primero para optimizar las llamadas a la API
  return [
    '$name (cantante)',
    '$name (artista)',
    '$name (músico)',
    '$name (música)',
    '$name (banda)',
    '$name (grupo musical)',
    '$name (cantante mexicano)',
    '$name (cantante mexicana)',
    '$name (cantante estadounidense)',
    '$name (cantante español)',
    '$name (cantante española)',
    '$name (cantante colombiano)',
    '$name (cantante colombiana)',
    '$name (cantante argentino)',
    '$name (cantante argentina)',
    '$name (cantante venezolano)',
    '$name (cantante venezolana)',
    '$name (cantante puertorriqueño)',
    '$name (cantante puertorriqueña)',
    '$name (cantante cubano)',
    '$name (cantante cubana)',
    '$name (cantante chileno)',
    '$name (cantante chilena)',
    '$name (cantante peruano)',
    '$name (cantante peruana)',
  ];
}

Future<String?> _getWikipediaSummary(String title, {String lang = 'es'}) async {
  try {
    final dio = Dio();
    final encoded = Uri.encodeComponent(title);
    final url = 'https://$lang.wikipedia.org/api/rest_v1/page/summary/$encoded';
    final res = await dio.get(
      url,
      options: Options(
        headers: {'accept': 'application/json', 'user-agent': userAgent},
        validateStatus: (s) => s != null && s >= 200 && s < 500,
      ),
    );
    if (res.statusCode == 200 && res.data is Map) {
      final map = res.data as Map;

      // Verificar si es una página de desambiguación
      final type = map['type']?.toString();
      if (type == 'disambiguation') {
        // Intentar variaciones más específicas para artistas
        final variations = _getArtistNameVariations(title);

        // Limitar a las primeras 10 variaciones más probables para evitar demasiadas llamadas
        final limitedVariations = variations.take(10).toList();

        for (final variation in limitedVariations) {
          final variationResult = await _getWikipediaSummary(
            variation,
            lang: lang,
          );
          if (variationResult != null && variationResult.trim().isNotEmpty) {
            return variationResult;
          }
        }

        // Si no se encuentra ninguna variación específica, devolver null
        return null;
      }

      final extract = map['extract']?.toString();
      if (extract != null && extract.trim().isNotEmpty) {
        return extract;
      }
    }
  } catch (_) {}
  return null;
}

Future<String?> getArtistWikipediaDescription(String name) async {
  // Obtener el idioma actual de la app
  final currentLang = languageNotifier.value;
  final wikiLang = currentLang == 'en' ? 'en' : 'es';

  String? desc = await _getWikipediaSummary(name, lang: wikiLang);
  /*
  if (desc != null && desc.trim().isNotEmpty) {
    // ignore: avoid_print
    print('👻 Wikipedia $wikiLang description for "$name": '
        '${desc.substring(0, desc.length.clamp(0, 300))}${desc.length > 300 ? '…' : ''}');
    return desc;
  }
  */
  // Si no se encuentra en el idioma principal, intentar con el idioma alternativo
  if (desc == null || desc.trim().isEmpty) {
    final fallbackLang = currentLang == 'en' ? 'es' : 'en';
    desc = await _getWikipediaSummary(name, lang: fallbackLang);
    /*
    if (desc != null && desc.trim().isNotEmpty) {
      // ignore: avoid_print
      print('👻 Wikipedia $fallbackLang fallback description for "$name": '
          '${desc.substring(0, desc.length.clamp(0, 300))}${desc.length > 300 ? '…' : ''}');
    } else {
      // ignore: avoid_print
      print('👻 Wikipedia description not found for "$name" ($wikiLang/$fallbackLang)');
    }
    */
  }
  return desc;
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
String? getSearchParamsWithLimit(
  String? filter,
  String? scope,
  bool ignoreSpelling, {
  int limit = 50,
}) {
  final baseParams = getSearchParams(filter, scope, ignoreSpelling);
  if (baseParams == null) return null;

  // Agregar parámetro de límite si es necesario
  // YouTube Music usa diferentes parámetros para controlar el número de resultados
  return baseParams;
}

String? _getParam2(String filter) {
  final filterParams = {
    'songs': 'I', // Parámetro específico para canciones
    'videos': 'Q',
    'albums': 'Y',
    'artists': 'g',
    'playlists': 'o',
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
Future<Response> sendRequest(
  String action,
  Map<dynamic, dynamic> data, {
  String additionalParams = "",
  CancelToken? cancelToken,
}) async {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
    ),
  );
  final url = "$baseUrl$action$fixedParms$additionalParams";
  try {
    await _ensureVisitorIdLoaded();
    final authCookieHeader = await getYtMusicAuthCookieHeader();
    final requestHeaders = _buildRequestHeaders(
      authCookieHeader: authCookieHeader,
    );
    final browseId = data['browseId']?.toString();
    final isLibraryBrowse =
        action == 'browse' && browseId == 'FEmusic_liked_playlists';
    if (isLibraryBrowse) {
      _ytLibLog(
        'sendRequest browse FEmusic_liked_playlists: additionalParamsLen=${additionalParams.length}, auth=${_cookieDebugSummary(authCookieHeader)}',
      );
    }
    if (action == 'account/account_menu' ||
        action == 'account/get_account_menu') {
      _ytLibLog(
        'sendRequest $action visitorId=${_cachedVisitorId != null && _cachedVisitorId!.isNotEmpty}, auth=${_cookieDebugSummary(authCookieHeader)}',
      );
    }
    final response = await dio.post(
      url,
      options: Options(
        headers: requestHeaders,
        validateStatus: (status) {
          return (status != null && (status >= 200 && status < 300)) ||
              status == 400;
        },
      ),
      data: jsonEncode(data),
      cancelToken: cancelToken,
    );
    if (isLibraryBrowse) {
      final payload = response.data;
      final keys = payload is Map ? payload.keys.take(8).toList() : const [];
      _ytLibLog(
        'sendRequest library status=${response.statusCode}, rootKeys=$keys',
      );
    }
    return response;
  } on DioException catch (e) {
    final browseId = data['browseId']?.toString();
    if (action == 'browse' && browseId == 'FEmusic_liked_playlists') {
      _ytLibLog(
        'sendRequest library DioException type=${e.type}, message=${e.message}',
      );
    }
    if (e.type == DioExceptionType.connectionError ||
        (e.type == DioExceptionType.unknown &&
            (e.error.toString().contains('SocketException') ||
                e.error.toString().contains('HttpException')))) {
      return Response(
        requestOptions: e.requestOptions,
        statusCode: 503,
        statusMessage: 'No hay conexión a internet',
        data: {}, // Data vacía para evitar errores de parseo
      );
    }
    rethrow;
  }
}

Future<Map<String, dynamic>> getWatchRadioTracks({
  required String videoId,
  int limit = 24,
  String? playlistId,
  String? additionalParamsNext,
}) async {
  return _getWatchRadioTracksLegacy(
    videoId: videoId,
    limit: limit,
    playlistId: playlistId,
    additionalParamsNext: additionalParamsNext,
  );
}

Future<Map<String, dynamic>> _getWatchRadioTracksLegacy({
  required String videoId,
  int limit = 24,
  String? playlistId,
  String? additionalParamsNext,
}) async {
  final normalizedVideoId = videoId.trim();
  if (normalizedVideoId.isEmpty) {
    return {
      'tracks': <Map<String, dynamic>>[],
      'additionalParamsForNext': null,
    };
  }

  final normalizedPlaylistId = (playlistId ?? 'RDAMVM$normalizedVideoId')
      .trim()
      .replaceFirst(RegExp(r'^VL'), '');

  final data = <String, dynamic>{
    ...ytServiceContext,
    'enablePersistentPlaylistPanel': true,
    'isAudioOnly': true,
    'tunerSettingValue': 'AUTOMIX_SETTING_NORMAL',
    'videoId': normalizedVideoId,
    'playlistId': normalizedPlaylistId,
    'params': 'wAEB',
  };

  final tracks = <Map<String, dynamic>>[];
  final seenVideoIds = <String>{};
  final visitedParams = <String>{};
  String? pendingParams = additionalParamsNext?.trim();
  String? nextParams;

  // Si venimos con continuation explícita, hacemos una sola página
  // para mantener la operación ligera.
  final bool singlePage = pendingParams != null && pendingParams.isNotEmpty;
  int safety = 0;

  while (tracks.length < limit && safety < 6) {
    final currentParams = (pendingParams != null && pendingParams.isNotEmpty)
        ? pendingParams
        : '';
    if (currentParams.isNotEmpty && !visitedParams.add(currentParams)) {
      break;
    }

    final response = (await sendRequest(
      'next',
      data,
      additionalParams: currentParams,
    )).data;

    final panel = _extractWatchPlaylistPanel(response);
    if (panel == null) {
      break;
    }

    final parsedTracks = _parsePlaylistPanelTracks(panel);
    for (final track in parsedTracks) {
      final id = track['videoId']?.toString().trim();
      if (id == null || id.isEmpty) continue;
      if (!seenVideoIds.add(id)) continue;
      tracks.add(track);
      if (tracks.length >= limit) break;
    }

    final continuationToken = _extractPlaylistPanelContinuationToken(panel);
    if (continuationToken == null || continuationToken.isEmpty) {
      nextParams = null;
      break;
    }

    nextParams = _buildContinuationParams(continuationToken);
    if (tracks.length >= limit || singlePage) {
      break;
    }

    pendingParams = nextParams;
    safety++;
  }

  return {
    'tracks': tracks.take(limit).toList(),
    'additionalParamsForNext': nextParams,
    'provider': 'legacy_next_api',
  };
}

Map<String, dynamic>? _extractWatchPlaylistPanel(dynamic response) {
  final continuationPanel = nav(response, [
    'continuationContents',
    'playlistPanelContinuation',
  ]);
  if (continuationPanel is Map<String, dynamic>) {
    return continuationPanel;
  }
  if (continuationPanel is Map) {
    return Map<String, dynamic>.from(continuationPanel);
  }

  final panel = nav(response, [
    'contents',
    'singleColumnMusicWatchNextResultsRenderer',
    'tabbedRenderer',
    'watchNextTabbedResultsRenderer',
    'tabs',
    0,
    'tabRenderer',
    'content',
    'musicQueueRenderer',
    'content',
    'playlistPanelRenderer',
  ]);

  if (panel is Map<String, dynamic>) {
    return panel;
  }
  if (panel is Map) {
    return Map<String, dynamic>.from(panel);
  }
  return null;
}

List<Map<String, dynamic>> _parsePlaylistPanelTracks(
  Map<String, dynamic> panel,
) {
  dynamic rawItems = panel['contents'];
  rawItems ??= panel['items'];
  if (rawItems is! List) return const [];

  final results = <Map<String, dynamic>>[];
  for (final item in rawItems) {
    final parsed = _parsePlaylistPanelTrack(item);
    if (parsed != null) {
      results.add(parsed);
    }
  }
  return results;
}

Map<String, dynamic>? _parsePlaylistPanelTrack(dynamic rawItem) {
  if (rawItem is! Map) return null;

  dynamic renderer = rawItem['playlistPanelVideoRenderer'];
  if (renderer == null && rawItem['playlistPanelVideoWrapperRenderer'] is Map) {
    final wrapper = rawItem['playlistPanelVideoWrapperRenderer'] as Map;
    final primary = wrapper['primaryRenderer'];
    if (primary is Map) {
      renderer = primary['playlistPanelVideoRenderer'] ?? primary;
    }
  }

  if (renderer is! Map) return null;
  if (renderer['unplayableText'] != null) return null;

  final videoId = renderer['videoId']?.toString().trim();
  if (videoId == null || videoId.isEmpty) return null;

  final titleRaw = nav(renderer, ['title', 'runs', 0, 'text'])?.toString();
  final title = (titleRaw == null || titleRaw.trim().isEmpty)
      ? LocaleProvider.tr('title_unknown')
      : titleRaw.trim();

  final artist = _extractWatchTrackArtist(
    nav(renderer, ['longBylineText', 'runs']),
  );

  dynamic thumbnails = nav(renderer, ['thumbnail', 'thumbnails']);
  thumbnails ??= nav(renderer, [
    'thumbnail',
    'musicThumbnailRenderer',
    'thumbnail',
    'thumbnails',
  ]);
  String? thumbUrl;
  if (thumbnails is List && thumbnails.isNotEmpty) {
    final rawUrl = thumbnails.last['url']?.toString().trim();
    if (rawUrl != null && rawUrl.isNotEmpty) {
      thumbUrl = _cleanThumbnailUrl(rawUrl, highQuality: true);
    }
  }

  final durationMs = _parseDurationTextMs(
    nav(renderer, ['lengthText', 'runs', 0, 'text'])?.toString(),
  );
  final videoType = _extractRendererMusicVideoType(renderer);
  final resultType = _inferResultTypeFromVideoType(videoType, fallback: 'song');

  return {
    'videoId': videoId,
    'title': title,
    'artist': artist,
    'thumbUrl': thumbUrl,
    'durationMs': durationMs,
    'resultType': resultType,
    'videoType': videoType,
  };
}

String? _extractWatchTrackArtist(dynamic runs) {
  if (runs is! List || runs.isEmpty) return null;

  String? fallback;
  for (final run in runs) {
    if (run is! Map) continue;
    final text = run['text']?.toString().trim();
    if (text == null ||
        text.isEmpty ||
        text == '•' ||
        text == '·' ||
        text == '-') {
      continue;
    }

    fallback ??= text;
    if (run['navigationEndpoint'] is Map) {
      final browseId = nav(run, [
        'navigationEndpoint',
        'browseEndpoint',
        'browseId',
      ])?.toString();
      if (browseId != null && browseId.isNotEmpty) {
        return text;
      }
    }
  }
  return fallback;
}

String? _extractPlaylistPanelContinuationToken(Map<String, dynamic> panel) {
  final token =
      nav(panel, [
        'continuations',
        0,
        'nextRadioContinuationData',
        'continuation',
      ]) ??
      nav(panel, [
        'continuations',
        0,
        'nextContinuationData',
        'continuation',
      ]) ??
      nav(panel, [
        'continuations',
        0,
        'reloadContinuationData',
        'continuation',
      ]);
  final normalized = token?.toString().trim();
  if (normalized == null || normalized.isEmpty) return null;
  return normalized;
}

String _buildContinuationParams(String continuationToken) {
  final encoded = Uri.encodeQueryComponent(continuationToken);
  return '&ctoken=$encoded&continuation=$encoded';
}

int? _parseDurationTextMs(String? text) {
  final value = text?.trim();
  if (value == null || value.isEmpty) return null;

  final parts = value.split(':');
  if (parts.isEmpty || parts.length > 3) return null;

  int totalSeconds = 0;
  for (final part in parts) {
    final parsed = int.tryParse(part.trim());
    if (parsed == null) return null;
    totalSeconds = totalSeconds * 60 + parsed;
  }

  if (totalSeconds <= 0) return null;
  return totalSeconds * 1000;
}

String? _extractDurationText(dynamic renderer) {
  if (renderer is! Map) return null;
  const pattern = r'^(\d+:)*\d+:\d+$';

  final candidates = <dynamic>[
    nav(renderer, [
      'fixedColumns',
      0,
      'musicResponsiveListItemFixedColumnRenderer',
      'text',
      'simpleText',
    ]),
    nav(renderer, [
      'fixedColumns',
      0,
      'musicResponsiveListItemFixedColumnRenderer',
      'text',
      'runs',
      0,
      'text',
    ]),
    nav(renderer, ['lengthText', 'simpleText']),
    nav(renderer, ['lengthText', 'runs', 0, 'text']),
  ];

  for (final candidate in candidates) {
    final text = candidate?.toString().trim();
    if (text != null && text.isNotEmpty && RegExp(pattern).hasMatch(text)) {
      return text;
    }
  }

  final subtitleRuns = nav(renderer, [
    'flexColumns',
    1,
    'musicResponsiveListItemFlexColumnRenderer',
    'text',
    'runs',
  ]);
  if (subtitleRuns is List) {
    for (final run in subtitleRuns) {
      if (run is! Map) continue;
      final text = run['text']?.toString().trim();
      if (text != null && text.isNotEmpty && RegExp(pattern).hasMatch(text)) {
        return text;
      }
    }
  }

  return null;
}

// Función para parsear canciones específicamente
void parseSongs(List items, List<YtMusicResult> results) {
  for (var item in items) {
    final renderer = item['musicResponsiveListItemRenderer'];
    if (renderer != null) {
      // Verificar si es una canción (no un video)
      final videoType = _extractRendererMusicVideoType(renderer);

      // Solo procesar si es una canción (MUSIC_VIDEO_TYPE_ATV) o si no hay tipo específico
      if (videoType == null || videoType == 'MUSIC_VIDEO_TYPE_ATV') {
        final title =
            renderer['flexColumns']?[0]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs']?[0]?['text'];
        final durationText = _extractDurationText(renderer);
        final durationMs = _parseDurationTextMs(durationText);

        final subtitleRuns =
            renderer['flexColumns']?[1]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'];
        String? artist;
        if (subtitleRuns is List) {
          for (var run in subtitleRuns) {
            if (run['navigationEndpoint']?['browseEndpoint']?['browseEndpointContextSupportedConfigs'] !=
                    null ||
                run['navigationEndpoint']?['browseEndpoint']?['browseId']
                        ?.startsWith('UC') ==
                    true) {
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
        final thumbnails =
            renderer['thumbnail']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'];
        if (thumbnails is List && thumbnails.isNotEmpty) {
          thumbUrl = thumbnails.last['url'];
          if (thumbUrl != null) thumbUrl = _cleanThumbnailUrl(thumbUrl);
        }

        final videoId =
            renderer['overlay']?['musicItemThumbnailOverlayRenderer']?['content']?['musicPlayButtonRenderer']?['playNavigationEndpoint']?['watchEndpoint']?['videoId'];

        if (videoId != null && title != null) {
          results.add(
            YtMusicResult(
              title: title,
              artist: artist,
              thumbUrl: thumbUrl,
              videoId: videoId,
              durationText: durationText,
              durationMs: durationMs,
              resultType: 'song',
              videoType: videoType,
            ),
          );
        }
      }
    }
  }
}

String _normalizeLooseText(String value) {
  final lower = value.toLowerCase();
  const withAccents = 'áàäâãéèëêíìïîóòöôõúùüûñ';
  const withoutAccents = 'aaaaaeeeeiiiiooooouuuun';
  var normalized = lower;
  for (int i = 0; i < withAccents.length; i++) {
    normalized = normalized.replaceAll(withAccents[i], withoutAccents[i]);
  }
  return normalized;
}

bool _matchesListenAgainTitle(String? rawTitle) {
  final title = _normalizeLooseText(rawTitle?.trim() ?? '');
  if (title.isEmpty) return false;
  return title.contains('listen again') ||
      title.contains('escuchar de nuevo') ||
      title.contains('vuelve a escucharlo') ||
      title.contains('volver a escuchar') ||
      title.contains('rehor') ||
      title.contains('ecouter a nouveau');
}

bool _matchesNewDiscoveriesTitle(String? rawTitle) {
  final title = _normalizeLooseText(rawTitle?.trim() ?? '');
  if (title.isEmpty) return false;
  return title.contains('nuevos descubrimientos') ||
      title.contains('nuevo descubrimiento') ||
      title.contains('new discoveries') ||
      title.contains('new discovery') ||
      title.contains('discover mix') ||
      title.contains('mix para descubrir');
}

bool _matchesVersionsRemixesTitle(String? rawTitle) {
  final title = _normalizeLooseText(rawTitle?.trim() ?? '');
  if (title.isEmpty) return false;
  return title.contains('versiones y remixes') ||
      title.contains('versiones') ||
      title.contains('remixes') ||
      title.contains('remix');
}

String? _extractShelfTitle(dynamic shelfRenderer) {
  final text =
      nav(shelfRenderer, [
        'header',
        'musicCarouselShelfBasicHeaderRenderer',
        'title',
        'runs',
        0,
        'text',
      ]) ??
      nav(shelfRenderer, [
        'header',
        'musicCarouselShelfBasicHeaderRenderer',
        'title',
        'simpleText',
      ]) ??
      nav(shelfRenderer, ['title', 'runs', 0, 'text']) ??
      nav(shelfRenderer, ['title', 'simpleText']);
  final value = text?.toString().trim();
  return (value == null || value.isEmpty) ? null : value;
}

String? _extractArtistFromRuns(dynamic runs) {
  if (runs is! List || runs.isEmpty) return null;
  String? fallback;
  for (final run in runs) {
    if (run is! Map) continue;
    final text = run['text']?.toString().trim();
    if (text == null ||
        text.isEmpty ||
        text == '•' ||
        text == '·' ||
        text == '-' ||
        text == '|' ||
        text == ',') {
      continue;
    }

    fallback ??= text;
    final browseId = nav(run, [
      'navigationEndpoint',
      'browseEndpoint',
      'browseId',
    ])?.toString();
    if (browseId != null && browseId.isNotEmpty) {
      return text;
    }
  }
  return fallback;
}

String? _extractDurationFromRuns(dynamic runs) {
  if (runs is! List || runs.isEmpty) return null;
  final regex = RegExp(r'^(\d+:)*\d+:\d+$');
  for (final run in runs) {
    if (run is! Map) continue;
    final text = run['text']?.toString().trim();
    if (text == null || text.isEmpty) continue;
    if (regex.hasMatch(text)) return text;
  }
  return null;
}

YtMusicResult? _parseTwoRowRendererToResult(Map<String, dynamic> renderer) {
  final videoId =
      nav(renderer, [
        'navigationEndpoint',
        'watchEndpoint',
        'videoId',
      ])?.toString().trim() ??
      nav(renderer, [
        'overlay',
        'musicItemThumbnailOverlayRenderer',
        'content',
        'musicPlayButtonRenderer',
        'playNavigationEndpoint',
        'watchEndpoint',
        'videoId',
      ])?.toString().trim();
  if (videoId == null || videoId.isEmpty) return null;

  final videoType = _extractRendererMusicVideoType(renderer);
  if (videoType != null &&
      videoType.isNotEmpty &&
      videoType.contains('PODCAST')) {
    return null;
  }

  final title =
      nav(renderer, ['title', 'runs', 0, 'text'])?.toString().trim() ??
      nav(renderer, ['title', 'simpleText'])?.toString().trim();
  if (title == null || title.isEmpty) return null;

  final subtitleRuns = nav(renderer, ['subtitle', 'runs']);
  final artist = _extractArtistFromRuns(subtitleRuns);
  final durationText = _extractDurationFromRuns(subtitleRuns);
  final durationMs = _parseDurationTextMs(durationText);

  dynamic thumbnails = nav(renderer, [
    'thumbnailRenderer',
    'musicThumbnailRenderer',
    'thumbnail',
    'thumbnails',
  ]);
  thumbnails ??= nav(renderer, [
    'thumbnail',
    'musicThumbnailRenderer',
    'thumbnail',
    'thumbnails',
  ]);
  String? thumbUrl;
  if (thumbnails is List && thumbnails.isNotEmpty) {
    final raw = thumbnails.last['url']?.toString().trim();
    if (raw != null && raw.isNotEmpty) {
      thumbUrl = _cleanThumbnailUrl(raw, highQuality: true);
    }
  }

  return YtMusicResult(
    title: title,
    artist: artist,
    thumbUrl: thumbUrl,
    videoId: videoId,
    durationText: durationText,
    durationMs: durationMs,
    resultType: _inferResultTypeFromVideoType(videoType),
    videoType: videoType,
  );
}

YtMusicResult? _parseResponsiveRendererToResult(Map<String, dynamic> renderer) {
  final title =
      nav(renderer, [
        'flexColumns',
        0,
        'musicResponsiveListItemFlexColumnRenderer',
        'text',
        'runs',
        0,
        'text',
      ])?.toString().trim() ??
      nav(renderer, [
        'flexColumns',
        0,
        'musicResponsiveListItemFlexColumnRenderer',
        'text',
        'simpleText',
      ])?.toString().trim();
  if (title == null || title.isEmpty) return null;

  final videoId =
      nav(renderer, [
        'overlay',
        'musicItemThumbnailOverlayRenderer',
        'content',
        'musicPlayButtonRenderer',
        'playNavigationEndpoint',
        'watchEndpoint',
        'videoId',
      ])?.toString().trim() ??
      nav(renderer, [
        'navigationEndpoint',
        'watchEndpoint',
        'videoId',
      ])?.toString().trim();
  if (videoId == null || videoId.isEmpty) return null;

  final videoType = _extractRendererMusicVideoType(renderer);
  if (videoType != null &&
      videoType.isNotEmpty &&
      videoType.contains('PODCAST')) {
    return null;
  }

  final subtitleRuns = nav(renderer, [
    'flexColumns',
    1,
    'musicResponsiveListItemFlexColumnRenderer',
    'text',
    'runs',
  ]);
  final artist = _extractArtistFromRuns(subtitleRuns);
  final durationText = _extractDurationText(renderer);
  final durationMs = _parseDurationTextMs(durationText);

  dynamic thumbnails = nav(renderer, [
    'thumbnail',
    'musicThumbnailRenderer',
    'thumbnail',
    'thumbnails',
  ]);
  thumbnails ??= nav(renderer, ['thumbnail', 'thumbnails']);
  String? thumbUrl;
  if (thumbnails is List && thumbnails.isNotEmpty) {
    final raw = thumbnails.last['url']?.toString().trim();
    if (raw != null && raw.isNotEmpty) {
      thumbUrl = _cleanThumbnailUrl(raw, highQuality: true);
    }
  }

  return YtMusicResult(
    title: title,
    artist: artist,
    thumbUrl: thumbUrl,
    videoId: videoId,
    durationText: durationText,
    durationMs: durationMs,
    resultType: _inferResultTypeFromVideoType(videoType),
    videoType: videoType,
  );
}

List<YtMusicResult> _parseHomeSectionResults(
  dynamic sectionRenderer, {
  required int limit,
}) {
  final contents = nav(sectionRenderer, ['contents']);
  if (contents is! List || contents.isEmpty) return const [];

  final results = <YtMusicResult>[];
  final seenVideoIds = <String>{};

  for (final item in contents) {
    if (results.length >= limit) break;
    if (item is! Map) continue;

    final twoRows = <Map<String, dynamic>>[];
    _collectMapsByKey(item, 'musicTwoRowItemRenderer', twoRows);
    for (final renderer in twoRows) {
      if (results.length >= limit) break;
      final parsed = _parseTwoRowRendererToResult(renderer);
      final videoId = parsed?.videoId?.trim();
      if (videoId == null || videoId.isEmpty) continue;
      if (!seenVideoIds.add(videoId)) continue;
      results.add(parsed!);
    }

    if (results.length >= limit) break;

    final responsive = <Map<String, dynamic>>[];
    _collectMapsByKey(item, 'musicResponsiveListItemRenderer', responsive);
    for (final renderer in responsive) {
      if (results.length >= limit) break;
      final parsed = _parseResponsiveRendererToResult(renderer);
      final videoId = parsed?.videoId?.trim();
      if (videoId == null || videoId.isEmpty) continue;
      if (!seenVideoIds.add(videoId)) continue;
      results.add(parsed!);
    }
  }

  return results;
}

List<YtMusicLibraryPlaylist> _parseHomeSectionPlaylists(
  dynamic sectionRenderer, {
  required int limit,
}) {
  final contents = nav(sectionRenderer, ['contents']);
  if (contents is! List || contents.isEmpty) return const [];

  final twoRow = <Map<String, dynamic>>[];
  final responsive = <Map<String, dynamic>>[];
  _collectMapsByKey(contents, 'musicTwoRowItemRenderer', twoRow);
  _collectMapsByKey(contents, 'musicResponsiveListItemRenderer', responsive);

  final parsed = <YtMusicLibraryPlaylist>[];
  final seenIds = <String>{};

  for (final renderer in twoRow) {
    if (parsed.length >= limit) break;
    final item = _parseLibraryPlaylistRenderer(renderer);
    if (item == null) continue;
    if (!seenIds.add(item.playlistId)) continue;
    parsed.add(item);
  }

  for (final renderer in responsive) {
    if (parsed.length >= limit) break;
    final item = _parseLibraryPlaylistResponsiveRenderer(renderer);
    if (item == null) continue;
    if (!seenIds.add(item.playlistId)) continue;
    parsed.add(item);
  }

  return parsed;
}

Future<Map<String, dynamic>> getHomeListenAgainSection({int limit = 18}) async {
  final data = {...ytServiceContext, 'browseId': 'FEmusic_home'};
  try {
    final ctx = (data['context'] as Map);
    final client = (ctx['client'] as Map);
    final locale = languageNotifier.value;
    client['hl'] = locale.startsWith('es') ? 'es' : 'en';
  } catch (_) {}

  try {
    final response = (await sendRequest('browse', data)).data;
    final sections = nav(response, [
      'contents',
      'singleColumnBrowseResultsRenderer',
      'tabs',
      0,
      'tabRenderer',
      'content',
      'sectionListRenderer',
      'contents',
    ]);
    if (sections is! List || sections.isEmpty) {
      return {'title': null, 'results': <YtMusicResult>[]};
    }

    String? selectedTitle;
    List<YtMusicResult> selectedResults = const <YtMusicResult>[];
    var bestScore = -1;

    for (final section in sections) {
      if (section is! Map) continue;
      final shelfRenderer =
          section['musicCarouselShelfRenderer'] ??
          section['musicShelfRenderer'];
      if (shelfRenderer is! Map) continue;

      final title = _extractShelfTitle(shelfRenderer);
      final parsed = _parseHomeSectionResults(shelfRenderer, limit: limit);
      if (parsed.isEmpty) continue;

      var score = parsed.length;
      if (_matchesListenAgainTitle(title)) {
        score += 1000;
      } else {
        final normalizedTitle = _normalizeLooseText(title ?? '');
        if (normalizedTitle.contains('listen') &&
            normalizedTitle.contains('again')) {
          score += 700;
        }
      }

      if (score > bestScore) {
        bestScore = score;
        selectedTitle = title;
        selectedResults = parsed;
      }
    }

    if (selectedResults.isEmpty) {
      return {'title': null, 'results': <YtMusicResult>[]};
    }

    return {
      'title': selectedTitle,
      'results': selectedResults.take(limit).toList(),
    };
  } catch (_) {
    return {'title': null, 'results': <YtMusicResult>[]};
  }
}

Future<Map<String, dynamic>> getHomeDiscoverySection({int limit = 12}) async {
  final data = {...ytServiceContext, 'browseId': 'FEmusic_home'};
  try {
    final ctx = (data['context'] as Map);
    final client = (ctx['client'] as Map);
    final locale = languageNotifier.value;
    client['hl'] = locale.startsWith('es') ? 'es' : 'en';
  } catch (_) {}

  try {
    final response = (await sendRequest('browse', data)).data;
    final sections = nav(response, [
      'contents',
      'singleColumnBrowseResultsRenderer',
      'tabs',
      0,
      'tabRenderer',
      'content',
      'sectionListRenderer',
      'contents',
    ]);
    if (sections is! List || sections.isEmpty) {
      return {'title': null, 'results': <YtMusicResult>[]};
    }

    String? selectedTitle;
    List<YtMusicResult> selectedResults = const <YtMusicResult>[];
    var bestScore = -1;

    for (final section in sections) {
      if (section is! Map) continue;
      final shelfRenderer =
          section['musicCarouselShelfRenderer'] ??
          section['musicShelfRenderer'];
      if (shelfRenderer is! Map) continue;

      final title = _extractShelfTitle(shelfRenderer);
      final parsed = _parseHomeSectionResults(shelfRenderer, limit: limit);
      if (parsed.isEmpty) continue;

      // Mantener esta sección estricta: solo "Nuevos descubrimientos"
      // (o su equivalente en inglés), sin fallback a otras shelves.
      if (!_matchesNewDiscoveriesTitle(title)) continue;

      final normalizedTitle = _normalizeLooseText(title ?? '');
      var score = parsed.length;
      score += 4000;
      if (normalizedTitle.contains('mix')) {
        score += 250;
      }
      if (_matchesVersionsRemixesTitle(title)) {
        score -= 1200;
      }
      if (_matchesListenAgainTitle(title)) {
        score -= 400;
      }

      if (score > bestScore) {
        bestScore = score;
        selectedTitle = title;
        selectedResults = parsed;
      }
    }

    if (selectedResults.isEmpty) {
      return {'title': null, 'results': <YtMusicResult>[]};
    }

    return {
      'title': selectedTitle,
      'results': selectedResults.take(limit).toList(),
    };
  } catch (_) {
    return {'title': null, 'results': <YtMusicResult>[]};
  }
}

Future<Map<String, dynamic>> getHomeNewDiscoveriesMixesSection({
  int limit = 12,
}) async {
  final data = {...ytServiceContext, 'browseId': 'FEmusic_home'};
  try {
    final ctx = (data['context'] as Map);
    final client = (ctx['client'] as Map);
    final locale = languageNotifier.value;
    client['hl'] = locale.startsWith('es') ? 'es' : 'en';
  } catch (_) {}

  try {
    final response = (await sendRequest('browse', data)).data;
    final sections = nav(response, [
      'contents',
      'singleColumnBrowseResultsRenderer',
      'tabs',
      0,
      'tabRenderer',
      'content',
      'sectionListRenderer',
      'contents',
    ]);
    if (sections is! List || sections.isEmpty) {
      return {'title': null, 'results': <YtMusicLibraryPlaylist>[]};
    }

    String? selectedTitle;
    List<YtMusicLibraryPlaylist> selectedResults =
        const <YtMusicLibraryPlaylist>[];
    var bestScore = -1;

    for (final section in sections) {
      if (section is! Map) continue;
      final shelfRenderer =
          section['musicCarouselShelfRenderer'] ??
          section['musicShelfRenderer'];
      if (shelfRenderer is! Map) continue;

      final title = _extractShelfTitle(shelfRenderer);
      if (!_matchesNewDiscoveriesTitle(title)) continue;

      final parsed = _parseHomeSectionPlaylists(shelfRenderer, limit: limit);
      if (parsed.isEmpty) continue;

      final normalizedTitle = _normalizeLooseText(title ?? '');
      var score = parsed.length + 4000;
      if (normalizedTitle.contains('mix')) {
        score += 300;
      }

      if (score > bestScore) {
        bestScore = score;
        selectedTitle = title;
        selectedResults = parsed;
      }
    }

    if (selectedResults.isEmpty) {
      return {'title': null, 'results': <YtMusicLibraryPlaylist>[]};
    }

    return {
      'title': selectedTitle,
      'results': selectedResults.take(limit).toList(),
    };
  } catch (_) {
    return {'title': null, 'results': <YtMusicLibraryPlaylist>[]};
  }
}

// Función para buscar solo canciones con paginación
Future<List<YtMusicResult>> searchSongsOnly(
  String query, {
  String? continuationToken,
  bool cancelPrevious = true,
}) async {
  CancelToken? requestCancelToken;
  if (cancelPrevious) {
    // Cancela la búsqueda anterior si existe
    _searchCancelToken?.cancel();
    _searchCancelToken = CancelToken();
    requestCancelToken = _searchCancelToken;
  }

  final data = {
    ...ytServiceContext,
    'query': query,
    'params': getSearchParams('songs', null, false),
  };

  if (continuationToken != null) {
    data['continuation'] = continuationToken;
  }

  try {
    final response = (await sendRequest(
      "search",
      data,
      cancelToken: requestCancelToken,
    )).data;
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
        'contents',
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
        'continuationItems',
      ]);

      contents ??= nav(response, [
        'continuationContents',
        'musicShelfContinuation',
        'contents',
      ]);

      if (contents is List) {
        final songItems = contents
            .where((item) => item['musicResponsiveListItemRenderer'] != null)
            .toList();
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
Future<List<YtMusicResult>> searchSongsWithPagination(
  String query, {
  int maxPages = 3,
}) async {
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
        'contents',
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
        'musicShelfRenderer',
      ]);
      if (shelfRenderer != null && shelfRenderer['continuations'] != null) {
        nextToken =
            shelfRenderer['continuations'][0]['nextContinuationData']['continuation'];
      }
    } else {
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
        final songItems = contents
            .where((item) => item['musicResponsiveListItemRenderer'] != null)
            .toList();
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
          'token',
        ]);
        nextTokenTry ??= nav(response, [
          'continuationContents',
          'musicShelfContinuation',
          'continuations',
          0,
          'nextContinuationData',
          'continuation',
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
    'contents',
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
      'musicShelfRenderer',
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

    final suggestions =
        nav(responseData, [
          'contents',
          0,
          'searchSuggestionsSectionRenderer',
          'contents',
        ]) ??
        [];

    return suggestions
        .map<String?>((item) {
          return nav(item, [
            'searchSuggestionRenderer',
            'navigationEndpoint',
            'searchEndpoint',
            'query',
          ])?.toString();
        })
        .whereType<String>()
        .toList();
  } catch (e) {
    return [];
  }
}

Future<List<YtMusicResult>> searchVideosWithPagination(
  String query, {
  int maxPages = 3,
}) async {
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
            final videoType = _extractRendererMusicVideoType(renderer);
            if (videoType == 'MUSIC_VIDEO_TYPE_MV' ||
                videoType == 'MUSIC_VIDEO_TYPE_OMV' ||
                videoType == 'MUSIC_VIDEO_TYPE_UGC' ||
                videoType == 'MUSIC_VIDEO_TYPE_OFFICIAL_SOURCE_MUSIC') {
              final title =
                  renderer['flexColumns']?[0]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs']?[0]?['text'];
              final subtitleRuns =
                  renderer['flexColumns']?[1]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'];
              String? artist;
              if (subtitleRuns is List) {
                for (var run in subtitleRuns) {
                  if (run['navigationEndpoint']?['browseEndpoint']?['browseEndpointContextSupportedConfigs'] !=
                          null ||
                      run['navigationEndpoint']?['browseEndpoint']?['browseId']
                              ?.startsWith('UC') ==
                          true) {
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
              final thumbnails =
                  renderer['thumbnail']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'];
              if (thumbnails is List && thumbnails.isNotEmpty) {
                thumbUrl = thumbnails.last['url'];
              }
              final videoId =
                  renderer['overlay']?['musicItemThumbnailOverlayRenderer']?['content']?['musicPlayButtonRenderer']?['playNavigationEndpoint']?['watchEndpoint']?['videoId'];
              final durationText = _extractDurationText(renderer);
              final durationMs = _parseDurationTextMs(durationText);
              if (videoId != null && title != null) {
                results.add(
                  YtMusicResult(
                    title: title,
                    artist: artist,
                    thumbUrl: thumbUrl,
                    videoId: videoId,
                    durationText: durationText,
                    durationMs: durationMs,
                    resultType: 'video',
                    videoType: videoType,
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
        continuationToken =
            shelfRenderer['continuations'][0]['nextContinuationData']['continuation'];
      } else {
        continuationToken = null;
      }
    } else {
      // Continuaciones
      final data = {...ytServiceContext, 'continuation': continuationToken};
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
        final videoItems = contents
            .where((item) => item['musicResponsiveListItemRenderer'] != null)
            .toList();
        for (var item in videoItems) {
          final renderer = item['musicResponsiveListItemRenderer'];
          if (renderer != null) {
            final videoType = _extractRendererMusicVideoType(renderer);
            if (videoType == 'MUSIC_VIDEO_TYPE_MV' ||
                videoType == 'MUSIC_VIDEO_TYPE_OMV' ||
                videoType == 'MUSIC_VIDEO_TYPE_UGC' ||
                videoType == 'MUSIC_VIDEO_TYPE_OFFICIAL_SOURCE_MUSIC') {
              final title =
                  renderer['flexColumns']?[0]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs']?[0]?['text'];
              final subtitleRuns =
                  renderer['flexColumns']?[1]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'];
              String? artist;
              if (subtitleRuns is List) {
                for (var run in subtitleRuns) {
                  if (run['navigationEndpoint']?['browseEndpoint']?['browseEndpointContextSupportedConfigs'] !=
                          null ||
                      run['navigationEndpoint']?['browseEndpoint']?['browseId']
                              ?.startsWith('UC') ==
                          true) {
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
              final thumbnails =
                  renderer['thumbnail']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'];
              if (thumbnails is List && thumbnails.isNotEmpty) {
                thumbUrl = thumbnails.last['url'];
              }
              final videoId =
                  renderer['overlay']?['musicItemThumbnailOverlayRenderer']?['content']?['musicPlayButtonRenderer']?['playNavigationEndpoint']?['watchEndpoint']?['videoId'];
              final durationText = _extractDurationText(renderer);
              final durationMs = _parseDurationTextMs(durationText);
              if (videoId != null && title != null) {
                results.add(
                  YtMusicResult(
                    title: title,
                    artist: artist,
                    thumbUrl: thumbUrl,
                    videoId: videoId,
                    durationText: durationText,
                    durationMs: durationMs,
                    resultType: 'video',
                    videoType: videoType,
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
          'continuation',
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

// Función mejorada para buscar álbumes con paginación
Future<List<Map<String, String>>> searchAlbumsWithPagination(
  String query, {
  int maxPages = 3,
}) async {
  final allResults = <Map<String, String>>[];
  String? continuationToken;
  int currentPage = 0;

  while (currentPage < maxPages) {
    final data = {
      ...ytServiceContext,
      'query': query,
      'params': getSearchParams('albums', null, false),
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
          'contents',
        ]);

        if (sections is List) {
          for (var section in sections) {
            final shelf = section['musicShelfRenderer'];
            if (shelf != null && shelf['contents'] is List) {
              for (var item in shelf['contents']) {
                final renderer = item['musicResponsiveListItemRenderer'];
                if (renderer != null) {
                  final albumData = _parseAlbumItem(renderer);
                  if (albumData != null) {
                    results.add(albumData);
                  }
                }
              }

              // Obtener token de continuación
              if (shelf['continuations'] != null) {
                nextToken =
                    shelf['continuations'][0]['nextContinuationData']['continuation'];
              }
            }
          }
        }
      } else {
        // Continuaciones
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
          final albumItems = contents
              .where((item) => item['musicResponsiveListItemRenderer'] != null)
              .toList();

          for (var item in albumItems) {
            final renderer = item['musicResponsiveListItemRenderer'];
            if (renderer != null) {
              final albumData = _parseAlbumItem(renderer);
              if (albumData != null) {
                results.add(albumData);
              }
            }
          }
        }

        // Obtener siguiente token
        try {
          var nextTokenTry = nav(response, [
            'onResponseReceivedActions',
            0,
            'appendContinuationItemsAction',
            'continuationItems',
          ]);

          // Buscar el token en el último elemento si existe
          if (nextTokenTry is List && nextTokenTry.isNotEmpty) {
            final lastItem = nextTokenTry.last;
            if (lastItem is Map &&
                lastItem.containsKey('continuationItemRenderer')) {
              nextTokenTry = nav(lastItem, [
                'continuationItemRenderer',
                'continuationEndpoint',
                'continuationCommand',
                'token',
              ]);
            } else {
              nextTokenTry = null;
            }
          }

          nextTokenTry ??= nav(response, [
            'continuationContents',
            'musicShelfContinuation',
            'continuations',
            0,
            'nextContinuationData',
            'continuation',
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
    } catch (e) {
      // print('Error en búsqueda de álbumes: $e');
      break;
    }
  }

  return allResults;
}

// Función auxiliar para parsear un item de álbum - CORREGIDA
Map<String, String>? _parseAlbumItem(Map<String, dynamic> renderer) {
  // Extraer browseId del álbum - SOLO buscar IDs que empiecen con MPRE
  String? browseId;

  // PRIMERO: Buscar en el título (navigationEndpoint) - Esta es la fuente más confiable
  browseId = nav(renderer, [
    'flexColumns',
    0,
    'musicResponsiveListItemFlexColumnRenderer',
    'text',
    'runs',
    0,
    'navigationEndpoint',
    'browseEndpoint',
    'browseId',
  ])?.toString();

  // Verificar que sea un ID de álbum válido (MPRE)
  if (browseId != null && !browseId.startsWith('MPRE')) {
    browseId = null;
  }

  // SEGUNDO: Si no encontramos en el título, buscar en el menú
  if (browseId == null) {
    final menuItems = nav(renderer, ['menu', 'menuRenderer', 'items']);
    if (menuItems is List) {
      for (var menuItem in menuItems) {
        final endpoint =
            menuItem['menuNavigationItemRenderer']?['navigationEndpoint']?['browseEndpoint'];
        if (endpoint != null && endpoint['browseId'] != null) {
          final id = endpoint['browseId'].toString();
          if (id.startsWith('MPRE')) {
            browseId = id;
            break;
          }
        }
      }
    }
  }

  // TERCERO: Buscar audioPlaylistId para obtener el MPRE después
  String? audioPlaylistId;
  if (browseId == null) {
    // Buscar en overlay el playlistId
    audioPlaylistId = nav(renderer, [
      'overlay',
      'musicItemThumbnailOverlayRenderer',
      'content',
      'musicPlayButtonRenderer',
      'playNavigationEndpoint',
      'watchPlaylistEndpoint',
      'playlistId',
    ])?.toString();

    // También buscar en el menú
    if (audioPlaylistId == null) {
      final menuItems = nav(renderer, ['menu', 'menuRenderer', 'items']);
      if (menuItems is List) {
        for (var menuItem in menuItems) {
          // Buscar en watchPlaylistEndpoint
          final watchEndpoint =
              menuItem['menuNavigationItemRenderer']?['navigationEndpoint']?['watchPlaylistEndpoint'];
          if (watchEndpoint != null && watchEndpoint['playlistId'] != null) {
            audioPlaylistId = watchEndpoint['playlistId'].toString();
            break;
          }
        }
      }
    }
  }

  // Si solo tenemos audioPlaylistId, usarlo como browseId temporal
  // getAlbumSongs lo convertirá después
  if (browseId == null && audioPlaylistId != null) {
    browseId = audioPlaylistId;
  }

  if (browseId == null) return null;

  // Extraer título
  final title = nav(renderer, [
    'flexColumns',
    0,
    'musicResponsiveListItemFlexColumnRenderer',
    'text',
    'runs',
    0,
    'text',
  ]);

  if (title == null) return null;

  // Extraer artista y año
  final subtitleRuns = nav(renderer, [
    'flexColumns',
    1,
    'musicResponsiveListItemFlexColumnRenderer',
    'text',
    'runs',
  ]);

  String? artist;
  String? year;
  String? albumType;

  if (subtitleRuns is List) {
    for (var i = 0; i < subtitleRuns.length; i++) {
      final text = subtitleRuns[i]['text']?.toString();
      if (text == null || text == ' • ') continue;

      // El primer elemento suele ser el tipo (Album, Single, EP)
      if (albumType == null &&
          (text == 'Album' ||
              text == 'Single' ||
              text == 'EP' ||
              text == 'Álbum' ||
              text == 'Sencillo')) {
        albumType = text;
        continue;
      }

      // Si parece un año (4 dígitos)
      if (RegExp(r'^\d{4}$').hasMatch(text)) {
        year = text;
        continue;
      }

      // Lo demás probablemente es el artista
      if (artist == null && text.isNotEmpty) {
        artist = text;
      }
    }
  }

  // Extraer thumbnail
  String? thumbUrl;
  final thumbnails = nav(renderer, [
    'thumbnail',
    'musicThumbnailRenderer',
    'thumbnail',
    'thumbnails',
  ]);
  if (thumbnails is List && thumbnails.isNotEmpty) {
    thumbUrl = thumbnails.last['url'];
    if (thumbUrl != null) thumbUrl = _cleanThumbnailUrl(thumbUrl);
  }

  return {
    'title': title,
    'artist': artist ?? '',
    'year': year ?? '',
    'albumType': albumType ?? 'Album',
    'thumbUrl': thumbUrl ?? '',
    'browseId': browseId,
  };
}

// Función simple para compatibilidad (usa la versión con paginación)
Future<List<Map<String, String>>> searchAlbumsOnly(String query) async {
  return await searchAlbumsWithPagination(query, maxPages: 3);
}

// Función getAlbumSongs CORREGIDA para manejar diferentes tipos de IDs
Future<List<YtMusicResult>> getAlbumSongs(String browseId) async {
  // Si el browseId es un playlist ID (OLAK5uy...), convertirlo a MPRE
  String actualBrowseId = browseId;
  if (browseId.contains('OLAK5uy') ||
      browseId.startsWith('OLAK') ||
      browseId.startsWith('PL')) {
    try {
      actualBrowseId = await getAlbumBrowseId(browseId);
    } catch (e) {
      // Si falla, intentar con el ID original
      actualBrowseId = browseId;
    }
  }

  final data = {...ytServiceContext, 'browseId': actualBrowseId};
  final response = (await sendRequest("browse", data)).data;

  // ============================================
  // PASO 1: Extraer el artista del HEADER del álbum
  // ============================================
  String? albumArtist;
  String? albumThumbUrl;

  // Intentar obtener el header del álbum (múltiples rutas posibles)
  var header = nav(response, [
    'contents',
    'twoColumnBrowseResultsRenderer',
    'tabs',
    0,
    'tabRenderer',
    'content',
    'sectionListRenderer',
    'contents',
    0,
    'musicResponsiveHeaderRenderer',
  ]);
  header ??= nav(response, ['header', 'musicDetailHeaderRenderer']);

  if (header != null) {
    // Extraer artista desde straplineTextOne (ubicación principal del artista del álbum)
    final straplineRuns = nav(header, ['straplineTextOne', 'runs']);
    if (straplineRuns is List && straplineRuns.isNotEmpty) {
      albumArtist = straplineRuns[0]['text'];
    }

    // Si no está en straplineTextOne, buscar en subtitle (runs a partir del índice 2)
    if (albumArtist == null) {
      final subtitleRuns = nav(header, ['subtitle', 'runs']);
      if (subtitleRuns is List && subtitleRuns.length > 2) {
        // El artista generalmente está en el índice 2 después del tipo de álbum
        albumArtist = subtitleRuns[2]['text'];
      }
    }

    // Obtener thumbnail del álbum para usarlo como fallback
    final thumbnails =
        nav(header, [
          'thumbnail',
          'croppedSquareThumbnailRenderer',
          'thumbnail',
          'thumbnails',
        ]) ??
        nav(header, [
          'thumbnail',
          'musicThumbnailRenderer',
          'thumbnail',
          'thumbnails',
        ]);

    if (thumbnails is List && thumbnails.isNotEmpty) {
      albumThumbUrl = thumbnails.last['url'];
    }
  }

  // ============================================
  // PASO 2: Obtener las canciones del álbum
  // ============================================
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

  // Ruta adicional para algunos álbumes
  shelf ??= nav(response, [
    'contents',
    'twoColumnBrowseResultsRenderer',
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
        final title =
            renderer['flexColumns']?[0]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs']?[0]?['text'];

        // ============================================
        // PASO 3: Intentar obtener artista de la canción,
        //         si no existe, usar el del álbum
        // ============================================
        final subtitleRuns =
            renderer['flexColumns']?[1]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'];

        String? artist;
        if (subtitleRuns is List && subtitleRuns.isNotEmpty) {
          // Buscar artista en los runs de la canción
          final artistRuns = subtitleRuns
              .where((run) => run['text'] != ' • ' && run['text'] != null)
              .toList();

          if (artistRuns.isNotEmpty) {
            // Si hay runs con navigationEndpoint hacia un artista, usarlos
            final artistWithNav = artistRuns.firstWhere(
              (run) =>
                  run['navigationEndpoint']?['browseEndpoint']?['browseId']
                      ?.toString()
                      .startsWith('UC') ==
                  true,
              orElse: () => null,
            );

            if (artistWithNav != null) {
              artist = artistWithNav['text'];
            } else if (artistRuns.first['text'] != null) {
              // Si no, verificar que el primer run no sea solo información de duración
              final firstText = artistRuns.first['text'].toString();
              // Solo usar si no parece ser duración (formato X:XX)
              if (!RegExp(r'^\d+:\d+$').hasMatch(firstText)) {
                artist = firstText;
              }
            }
          }
        }

        // FALLBACK: Si no encontramos artista en la canción, usar el del álbum
        artist ??= albumArtist;

        // Thumbnail: usar el de la canción si existe, si no el del álbum
        String? thumbUrl;
        final thumbnails =
            renderer['thumbnail']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'];
        if (thumbnails is List && thumbnails.isNotEmpty) {
          thumbUrl = thumbnails.last['url'];
        }
        thumbUrl ??= albumThumbUrl;

        // Obtener videoId - múltiples ubicaciones
        String? videoId = nav(renderer, ['playlistItemData', 'videoId']);

        videoId ??= nav(renderer, [
          'overlay',
          'musicItemThumbnailOverlayRenderer',
          'content',
          'musicPlayButtonRenderer',
          'playNavigationEndpoint',
          'watchEndpoint',
          'videoId',
        ]);

        // Buscar en flexColumns si aún no tenemos videoId
        if (videoId == null) {
          final titleNav = nav(renderer, [
            'flexColumns',
            0,
            'musicResponsiveListItemFlexColumnRenderer',
            'text',
            'runs',
            0,
            'navigationEndpoint',
            'watchEndpoint',
            'videoId',
          ]);
          if (titleNav != null) {
            videoId = titleNav.toString();
          }
        }

        if (videoId != null && title != null) {
          final videoType = _extractRendererMusicVideoType(renderer);
          final durationText = _extractDurationText(renderer);
          final durationMs = _parseDurationTextMs(durationText);
          results.add(
            YtMusicResult(
              title: title,
              artist: artist,
              thumbUrl: thumbUrl,
              videoId: videoId,
              durationText: durationText,
              durationMs: durationMs,
              resultType: 'song',
              videoType: videoType,
            ),
          );
        }
      }
    }
  }
  return results;
}

// Función mejorada para buscar listas de reproducción con paginación
Future<List<Map<String, String>>> searchPlaylistsWithPagination(
  String query, {
  int maxPages = 3,
}) async {
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
          'contents',
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
          'musicShelfRenderer',
        ]);

        if (shelfRenderer != null && shelfRenderer['continuations'] != null) {
          nextToken =
              shelfRenderer['continuations'][0]['nextContinuationData']['continuation'];
        }
      } else {
        // Continuaciones
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
          final playlistItems = contents
              .where((item) => item['musicResponsiveListItemRenderer'] != null)
              .toList();

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
            'token',
          ]);

          nextToken ??= nav(response, [
            'continuationContents',
            'musicShelfContinuation',
            'continuations',
            0,
            'nextContinuationData',
            'continuation',
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

// Función auxiliar mejorada para parsear items de playlist individuales
Map<String, String>? _parsePlaylistItem(Map<String, dynamic> renderer) {
  // Extraer browseId de los menús (más robusto que la implementación anterior)
  String? browseId;
  final menuItems = nav(renderer, ['menu', 'menuRenderer', 'items']);

  if (menuItems is List) {
    for (var menuItem in menuItems) {
      final endpoint =
          menuItem['menuNavigationItemRenderer']?['navigationEndpoint']?['browseEndpoint'];
      if (endpoint != null && endpoint['browseId'] != null) {
        final id = endpoint['browseId'].toString();
        // Aceptar diferentes tipos de IDs de playlist, incluyendo playlists de canales
        if (id.startsWith('VL') ||
            id.startsWith('PL') ||
            id.startsWith('OL') ||
            id.startsWith('OLAK') ||
            id.startsWith('OLAD') ||
            id.startsWith('OLAT')) {
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
      'playlistId',
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
      'browseId',
    ])?.toString();
  }

  if (browseId == null) return null;

  // Extraer título
  final title =
      renderer['flexColumns']?[0]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs']?[0]?['text'];
  if (title == null) return null;

  // Extraer número de elementos
  final subtitleRuns =
      renderer['flexColumns']?[1]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'];
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
  final thumbnails =
      renderer['thumbnail']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'];
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

Future<String> _resolvePlaylistBrowseId(String playlistId) async {
  String browseId;

  // Manejar diferentes tipos de IDs de playlist
  if (playlistId.startsWith("VL")) {
    browseId = playlistId;
  } else if (playlistId.startsWith("OLAK") ||
      playlistId.startsWith("OLAD") ||
      playlistId.startsWith("OLAT") ||
      playlistId.startsWith("OL")) {
    // Para playlists de canales, usar el ID tal como está
    browseId = playlistId;

    // Si es un OLAK5uy, intentar obtener el browseId real del álbum
    if (playlistId.contains("OLAK5uy")) {
      try {
        browseId = await getAlbumBrowseId(playlistId);
      } catch (e) {
        // Si falla, usar el ID original
        browseId = playlistId;
      }
    }
  } else {
    // Para otros tipos de playlist, agregar prefijo VL
    browseId = "VL$playlistId";
  }
  return browseId;
}

List<dynamic>? _extractPlaylistContinuationItems(dynamic continuationResponse) {
  var continuationItems = nav(continuationResponse, [
    'continuationContents',
    'musicPlaylistShelfContinuation',
    'contents',
  ]);

  continuationItems ??= nav(continuationResponse, [
    'onResponseReceivedActions',
    0,
    'appendContinuationItemsAction',
    'continuationItems',
  ]);

  continuationItems ??= nav(continuationResponse, [
    'continuationContents',
    'musicShelfContinuation',
    'contents',
  ]);

  continuationItems ??= nav(continuationResponse, [
    'contents',
    'twoColumnBrowseResultsRenderer',
    'tabs',
    0,
    'tabRenderer',
    'content',
    'sectionListRenderer',
    'contents',
    0,
    'musicPlaylistShelfRenderer',
    'contents',
  ]);

  continuationItems ??= nav(continuationResponse, [
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
    'contents',
  ]);

  if (continuationItems is List) {
    return continuationItems;
  }
  return null;
}

Future<Map<String, dynamic>> getPlaylistSongsPage(
  String playlistId, {
  String? continuationToken,
  int limit = 100,
}) async {
  if (limit <= 0) {
    return {
      'results': <YtMusicResult>[],
      'continuationToken': continuationToken,
    };
  }

  try {
    if (continuationToken == null || continuationToken.trim().isEmpty) {
      final browseId = await _resolvePlaylistBrowseId(playlistId);
      final data = {...ytServiceContext, 'browseId': browseId};
      final response = (await sendRequest("browse", data)).data;

      final contents = _findPlaylistContents(response);
      final pageResults = contents is List
          ? _parsePlaylistItems(contents)
          : <YtMusicResult>[];
      final nextToken = _getPlaylistContinuationTokenImproved(response);

      return {
        'results': pageResults.take(limit).toList(),
        'continuationToken': nextToken,
      };
    }

    final data = {
      ...ytServiceContext,
      'continuation': continuationToken.trim(),
    };
    final continuationResponse = (await sendRequest("browse", data)).data;
    final continuationItems = _extractPlaylistContinuationItems(
      continuationResponse,
    );
    final pageResults = continuationItems == null
        ? <YtMusicResult>[]
        : _parsePlaylistItems(continuationItems);
    final nextToken = _getPlaylistContinuationTokenImproved(
      continuationResponse,
    );

    return {
      'results': pageResults.take(limit).toList(),
      'continuationToken': nextToken,
    };
  } catch (e) {
    return {'results': <YtMusicResult>[], 'continuationToken': null};
  }
}

// Función principal mejorada para obtener canciones de una lista de reproducción
Future<List<YtMusicResult>> getPlaylistSongs(
  String playlistId, {
  int? limit,
}) async {
  final maxItems = limit ?? 999999;
  final results = <YtMusicResult>[];
  String? continuationToken;
  bool firstPage = true;
  int safety = 0;

  try {
    while (results.length < maxItems && safety < 80) {
      final page = await getPlaylistSongsPage(
        playlistId,
        continuationToken: firstPage ? null : continuationToken,
        limit: 100,
      );
      firstPage = false;

      final pageResults =
          (page['results'] as List?)?.whereType<YtMusicResult>().toList() ??
          <YtMusicResult>[];
      results.addAll(pageResults);

      final next = page['continuationToken']?.toString().trim();
      continuationToken = (next != null && next.isNotEmpty) ? next : null;
      if (continuationToken == null || pageResults.isEmpty) {
        break;
      }
      safety++;
    }

    return limit != null ? results.take(limit).toList() : results;
  } catch (e) {
    return [];
  }
}

// Función mejorada para encontrar el contenido de la playlist (inspirada en Harmony)
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
    'contents',
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
    'contents',
  ]);

  // Agregar más rutas de búsqueda
  contents ??= nav(response, [
    'contents',
    'twoColumnBrowseResultsRenderer',
    'secondaryContents',
    'sectionListRenderer',
    'contents',
    0,
    'musicShelfRenderer',
    'contents',
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
    'contents',
  ]);

  // Buscar en la estructura de playlist específica
  contents ??= nav(response, [
    'contents',
    'twoColumnBrowseResultsRenderer',
    'tabs',
    0,
    'tabRenderer',
    'content',
    'sectionListRenderer',
    'contents',
    0,
    'musicPlaylistShelfRenderer',
    'contents',
  ]);

  // Buscar en estructura de single column con tabs
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
    'contents',
  ]);

  // Buscar en estructura de two column con tabs
  contents ??= nav(response, [
    'contents',
    'twoColumnBrowseResultsRenderer',
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
            'playlistEditEndpoint',
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
      'watchEndpoint',
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
    'text',
  ]);

  if (title == null || title == 'Song deleted') return null;

  // Obtener artista
  String? artist;
  final subtitleRuns = nav(renderer, [
    'flexColumns',
    1,
    'musicResponsiveListItemFlexColumnRenderer',
    'text',
    'runs',
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

  final durationText = _extractDurationText(renderer);
  final durationMs = _parseDurationTextMs(durationText);
  final videoType = _extractRendererMusicVideoType(renderer);

  // Obtener thumbnail
  String? thumbUrl;
  final thumbnails = nav(renderer, [
    'thumbnail',
    'musicThumbnailRenderer',
    'thumbnail',
    'thumbnails',
  ]);
  if (thumbnails is List && thumbnails.isNotEmpty) {
    thumbUrl = thumbnails.last['url'];
    if (thumbUrl != null) {
      // Mantener la misma normalizacion de miniaturas que en busqueda general.
      thumbUrl = _cleanThumbnailUrl(thumbUrl);
    }
  }

  return YtMusicResult(
    title: title,
    artist: artist,
    thumbUrl: thumbUrl,
    videoId: videoId,
    durationText: durationText,
    durationMs: durationMs,
    resultType: 'song',
    videoType: videoType,
  );
}

// Función corregida para obtener el token de continuación
String? _getPlaylistContinuationTokenImproved(Map<String, dynamic> response) {
  // print('🔍 Buscando token de continuación...');

  // PRIMERO: Buscar en el último elemento de contents (como hace Harmony)
  var contents = _findPlaylistContents(response);
  if (contents is List && contents.isNotEmpty) {
    final lastItem = contents.last;
    if (lastItem is Map && lastItem.containsKey('continuationItemRenderer')) {
      final token = nav(lastItem, [
        'continuationItemRenderer',
        'continuationEndpoint',
        'continuationCommand',
        'token',
      ]);
      if (token != null) {
        // print('🔍 Token encontrado en último elemento de contents: Encontrado');
        return token;
      }
    }
  }
  // print('🔍 Token en último elemento de contents: No encontrado');

  // SEGUNDO: Buscar en las ubicaciones tradicionales (como respaldo)
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
    'continuation',
  ]);
  // print('🔍 Token en twoColumnBrowseResultsRenderer->secondaryContents: ${token != null ? "Encontrado" : "No encontrado"}');

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
    'continuation',
  ]);
  // print('🔍 Token en singleColumnBrowseResultsRenderer->tabs: ${token != null ? "Encontrado" : "No encontrado"}');

  token ??= nav(response, [
    'continuationContents',
    'musicPlaylistShelfContinuation',
    'continuations',
    0,
    'nextContinuationData',
    'continuation',
  ]);
  // print('🔍 Token en continuationContents->musicPlaylistShelfContinuation: ${token != null ? "Encontrado" : "No encontrado"}');

  // Buscar en estructura de tabs
  token ??= nav(response, [
    'contents',
    'twoColumnBrowseResultsRenderer',
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
    'continuation',
  ]);
  // print('🔍 Token en twoColumnBrowseResultsRenderer->tabs: ${token != null ? "Encontrado" : "No encontrado"}');

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
    'musicShelfRenderer',
    'continuations',
    0,
    'nextContinuationData',
    'continuation',
  ]);
  // print('🔍 Token en singleColumnBrowseResultsRenderer->tabs->musicShelfRenderer: ${token != null ? "Encontrado" : "No encontrado"}');

  // Buscar en onResponseReceivedActions
  token ??= nav(response, [
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
  // print('🔍 Token en onResponseReceivedActions: ${token != null ? "Encontrado" : "No encontrado"}');

  // Buscar en continuationContents
  token ??= nav(response, [
    'continuationContents',
    'musicShelfContinuation',
    'continuations',
    0,
    'nextContinuationData',
    'continuation',
  ]);
  // print('🔍 Token en continuationContents->musicShelfContinuation: ${token != null ? "Encontrado" : "No encontrado"}');

  // Buscar en continuationContents->musicPlaylistShelfContinuation
  token ??= nav(response, [
    'continuationContents',
    'musicPlaylistShelfContinuation',
    'continuations',
    0,
    'nextContinuationData',
    'continuation',
  ]);
  // print('🔍 Token en continuationContents->musicPlaylistShelfContinuation: ${token != null ? "Encontrado" : "No encontrado"}');

  // Buscar en el último elemento de continuationItems (para respuestas de continuación)
  var continuationItems = nav(response, [
    'onResponseReceivedActions',
    0,
    'appendContinuationItemsAction',
    'continuationItems',
  ]);
  if (continuationItems is List && continuationItems.isNotEmpty) {
    final lastItem = continuationItems.last;
    if (lastItem is Map && lastItem.containsKey('continuationItemRenderer')) {
      final continuationToken = nav(lastItem, [
        'continuationItemRenderer',
        'continuationEndpoint',
        'continuationCommand',
        'token',
      ]);
      if (continuationToken != null) {
        token = continuationToken;
        // print('🔍 Token encontrado en último elemento de continuationItems: Encontrado');
      }
    }
  }
  // print('🔍 Token en último elemento de continuationItems: ${token != null ? "Encontrado" : "No encontrado"}');

  // print('🔍 Token final: ${token != null ? "Encontrado" : "No encontrado"}');
  return token;
}

// Función para obtener browseId de álbum (como en Harmony Music)
Future<String> getAlbumBrowseId(String audioPlaylistId) async {
  try {
    final dio = Dio();
    final response = await dio.get(
      "${domain}playlist",
      options: Options(headers: headers),
      queryParameters: {"list": audioPlaylistId},
    );

    final reg = RegExp(r'\"MPRE.+?\"');
    final match = reg.firstMatch(response.data.toString());
    if (match != null) {
      final x = (match[0])!;
      final res = (x.substring(1)).split("\\")[0];
      return res;
    }
    return audioPlaylistId;
  } catch (e) {
    return audioPlaylistId;
  }
}

// Función para obtener información de la playlist (título, autor, etc.)
Future<Map<String, dynamic>?> getPlaylistInfo(String playlistId) async {
  String browseId;

  // Manejar diferentes tipos de IDs de playlist
  if (playlistId.startsWith("VL")) {
    browseId = playlistId;
  } else if (playlistId.startsWith("OLAK") ||
      playlistId.startsWith("OLAD") ||
      playlistId.startsWith("OLAT") ||
      playlistId.startsWith("OL")) {
    // Para playlists de canales, usar el ID tal como está
    browseId = playlistId;

    // Si es un OLAK5uy, intentar obtener el browseId real del álbum
    if (playlistId.contains("OLAK5uy")) {
      try {
        browseId = await getAlbumBrowseId(playlistId);
      } catch (e) {
        // Si falla, usar el ID original
        browseId = playlistId;
      }
    }
  } else {
    // Para otros tipos de playlist, agregar prefijo VL
    browseId = "VL$playlistId";
  }

  final data = {...ytServiceContext, 'browseId': browseId};

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
      'musicResponsiveHeaderRenderer',
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
      'text',
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
      'thumbnails',
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

// Función corregida para buscar artistas específicamente
Future<List<Map<String, dynamic>>> searchArtists(
  String query, {
  int limit = 20,
}) async {
  // print('🚀 Iniciando búsqueda de artistas para: $query');

  final data = {
    ...ytServiceContext,
    'query': query,
    'params': getSearchParams('artists', null, false),
  };

  try {
    // print('📡 Enviando petición a YouTube Music API...');
    final response = (await sendRequest("search", data)).data;
    // print('📡 Respuesta recibida, status: ${response != null ? 'OK' : 'NULL'}');
    final results = <Map<String, dynamic>>[];

    // print('🔍 Buscando artistas para: $query');
    // print('🔍 Parámetros de búsqueda: ${data['params']}');

    // Buscar directamente en la estructura de resultados
    final contents = nav(response, [
      'contents',
      'tabbedSearchResultsRenderer',
      'tabs',
      0,
      'tabRenderer',
      'content',
      'sectionListRenderer',
      'contents',
    ]);

    // print('🔍 Contenidos encontrados: ${contents?.length ?? 0}');

    if (contents is List) {
      for (var section in contents) {
        final shelf = section['musicShelfRenderer'];
        if (shelf != null && shelf['contents'] is List) {
          // print('🔍 Procesando shelf con ${shelf['contents'].length} items');
          for (var item in shelf['contents']) {
            final artist = _parseArtistItem(item);
            if (artist != null) {
              // Verificar si ya existe un artista con el mismo nombre y browseId
              final existingArtist = results.firstWhere(
                (existing) =>
                    existing['name'] == artist['name'] &&
                    existing['browseId'] == artist['browseId'],
                orElse: () => {},
              );

              // Solo agregar si no existe ya
              if (existingArtist.isEmpty) {
                // print('🎵 Artista encontrado: ${artist['name']} - BrowseId: ${artist['browseId']} - Thumb: ${artist['thumbUrl'] != null ? 'Sí' : 'No'}');
                results.add(artist);
                if (results.length >= limit) break;
              } else {
                // print('🔄 Artista duplicado ignorado: ${artist['name']} - BrowseId: ${artist['browseId']}');
              }
            }
          }
        }
        if (results.length >= limit) break;
      }
    }

    // print('🔍 Total artistas encontrados: ${results.length}');
    return results.take(limit).toList();
  } on DioException catch (_) {
    // print('❌ Error de red buscando artistas: ${e.message}');
    // print('❌ Tipo de error: ${e.type}');
    return [];
  } catch (e) {
    // print('❌ Error general buscando artistas: $e');
    return [];
  }
}

// Función auxiliar mejorada para parsear un item de artista
Map<String, dynamic>? _parseArtistItem(Map<String, dynamic> item) {
  final renderer = item['musicResponsiveListItemRenderer'];
  if (renderer == null) {
    // ('❌ No se encontró musicResponsiveListItemRenderer');
    return null;
  }

  // Extraer nombre del artista
  final title = nav(renderer, [
    'flexColumns',
    0,
    'musicResponsiveListItemFlexColumnRenderer',
    'text',
    'runs',
    0,
    'text',
  ]);

  if (title == null) {
    // print('❌ No se encontró título del artista');
    return null;
  }

  // print('🔍 Procesando artista: $title');

  // Extraer browseId del artista - buscar en múltiples ubicaciones
  String? browseId;

  // Debug: imprimir estructura del renderer
  // print('🔍 Estructura del renderer para $title: ${renderer.keys.toList()}');

  // Primero intentar desde el título
  browseId = nav(renderer, [
    'flexColumns',
    0,
    'musicResponsiveListItemFlexColumnRenderer',
    'text',
    'runs',
    0,
    'navigationEndpoint',
    'browseEndpoint',
    'browseId',
  ])?.toString();

  // print('🔍 BrowseId desde título: $browseId');

  // Si no está ahí, buscar en el menú
  if (browseId == null) {
    final menuItems = nav(renderer, ['menu', 'menuRenderer', 'items']);
    if (menuItems is List) {
      // print('🔍 Buscando en menú con ${menuItems.length} items');
      for (var menuItem in menuItems) {
        final endpoint = nav(menuItem, [
          'menuNavigationItemRenderer',
          'navigationEndpoint',
          'browseEndpoint',
          'browseId',
        ]);
        if (endpoint != null) {
          browseId = endpoint.toString();
          // print('🔍 BrowseId encontrado en menú: $browseId');
          break;
        }
      }
    }
  }

  // Buscar en otras ubicaciones posibles

  // Intentar en la estructura completa del renderer si browseId sigue siendo null
  browseId ??= _findObjectByKey(renderer, 'browseId')?.toString();
  // print('🔍 BrowseId desde búsqueda recursiva: $browseId');

  // 3. EXTRAER AUDIENCIA O SUSCRIPTORES
  // YouTube suele mandar: ["Artista", " • ", "15.9M monthly audience"]
  String? listenersOrSubscribers;
  final subtitleRuns = nav(renderer, [
    'flexColumns',
    1,
    'musicResponsiveListItemFlexColumnRenderer',
    'text',
    'runs',
  ]);

  if (subtitleRuns is List && subtitleRuns.isNotEmpty) {
    // Recorremos buscando el dato numérico
    for (var run in subtitleRuns) {
      final text = run['text']?.toString();
      if (text == null || text == ' • ') continue;

      // Si el texto NO es "Artist" ni "Artista", probablemente es el dato que buscamos
      if (text != 'Artist' && text != 'Artista') {
        listenersOrSubscribers = text;

        // Si queremos ser específicos y preferir el dato que tenga números:
        if (RegExp(r'\d').hasMatch(text)) {
          listenersOrSubscribers = text;
          break; // Encontramos el dato numérico, nos quedamos con este
        }
      }
    }
  }

  // Extraer thumbnail - buscar en múltiples ubicaciones
  String? thumbUrl;

  // Primera ubicación: thumbnail directo
  var thumbnails = nav(renderer, [
    'thumbnail',
    'musicThumbnailRenderer',
    'thumbnail',
    'thumbnails',
  ]);

  // print('🔍 Thumbnails (musicThumbnailRenderer): ${thumbnails != null ? thumbnails.length : 'null'}');

  // Segunda ubicación: thumbnail cropped
  thumbnails ??= nav(renderer, [
    'thumbnail',
    'croppedSquareThumbnailRenderer',
    'thumbnail',
    'thumbnails',
  ]);
  // print('🔍 Thumbnails (croppedSquareThumbnailRenderer): ${thumbnails != null ? thumbnails.length : 'null'}');

  // Tercera ubicación: buscar en cualquier estructura de thumbnail
  if (thumbnails == null) {
    final thumbnail = nav(renderer, ['thumbnail']);
    // print('🔍 Estructura de thumbnail completa: ${thumbnail?.keys.toList()}');

    // Intentar diferentes estructuras
    if (thumbnail is Map) {
      for (var key in thumbnail.keys) {
        final subThumb = thumbnail[key];
        if (subThumb is Map && subThumb.containsKey('thumbnails')) {
          thumbnails = subThumb['thumbnails'];
          // print('🔍 Thumbnails encontrados en $key: ${thumbnails?.length}');
          break;
        }
      }
    }
  }

  if (thumbnails is List && thumbnails.isNotEmpty) {
    // Usar la imagen de mayor resolución disponible
    thumbUrl = thumbnails.last['url'];
    if (thumbUrl != null) thumbUrl = _cleanThumbnailUrl(thumbUrl);
    // ('✅ Thumbnail encontrado: $thumbUrl');
  } else {
    // print('❌ No se encontraron thumbnails para $title');
  }

  return {
    'name': title,
    'browseId': browseId,
    'subscribers': listenersOrSubscribers,
    'thumbUrl': thumbUrl,
  };
}

// Función para obtener Sencillos (Singles) de un artista.
// Por defecto trae colección completa; en modo rápido devuelve solo preview.
Future<Map<String, dynamic>> getArtistSingles(
  String browseId, {
  bool loadFullCollection = true,
  int previewLimit = 20,
}) async {
  String normalizedId = browseId;
  if (normalizedId.startsWith('MPLA')) {
    normalizedId = normalizedId.substring(4);
  }

  try {
    final artistData = {...ytServiceContext, 'browseId': normalizedId};

    // Configurar idioma para asegurar consistencia en títulos
    try {
      final ctx = (artistData['context'] as Map);
      final client = (ctx['client'] as Map);
      final locale = languageNotifier.value;
      client['hl'] = locale.startsWith('es') ? 'es' : 'en';
    } catch (_) {}

    final artistResponse = (await sendRequest("browse", artistData)).data;

    final sections = nav(artistResponse, [
      'contents',
      'singleColumnBrowseResultsRenderer',
      'tabs',
      0,
      'tabRenderer',
      'content',
      'sectionListRenderer',
      'contents',
    ]);

    if (sections == null || sections is! List) {
      return {
        'results': <Map<String, String>>[],
        'continuationToken': null,
        'browseEndpoint': null,
      };
    }

    Map<String, dynamic>? singlesEndpoint;
    List<dynamic>? topSinglesPreview;
    String? previewContinuationToken;

    List<Map<String, String>> parseSinglesPreview(List<dynamic> previewItems) {
      final results = <Map<String, String>>[];
      for (var item in previewItems) {
        if (item['musicTwoRowItemRenderer'] != null) {
          final parsed = _parseTwoRowItem(item['musicTwoRowItemRenderer']);
          if (parsed != null) results.add(parsed);
        } else if (item['musicResponsiveListItemRenderer'] != null) {
          final parsed = _parseAlbumItem(
            item['musicResponsiveListItemRenderer'],
          );
          if (parsed != null) results.add(parsed);
        }
      }
      if (previewLimit > 0 && results.length > previewLimit) {
        return results.take(previewLimit).toList();
      }
      return results;
    }

    // Palabras clave para buscar la sección
    final keywords = [
      'singles',
      'sencillos',
      'ep',
      'eps',
      'singles & eps',
      'sencillos y ep',
    ];

    for (var section in sections) {
      // 1. Buscar en musicShelfRenderer
      if (section.containsKey('musicShelfRenderer')) {
        final shelf = section['musicShelfRenderer'];
        final title = nav(shelf, ['title', 'runs', 0, 'text']);

        if (title != null &&
            keywords.any((k) => title.toString().toLowerCase().contains(k))) {
          singlesEndpoint = nav(shelf, ['bottomEndpoint', 'browseEndpoint']);
          previewContinuationToken = nav(shelf, [
            'continuations',
            0,
            'nextContinuationData',
            'continuation',
          ]);

          final contentList = nav(shelf, ['contents']);
          if (contentList is List) {
            topSinglesPreview = contentList;
          }
          break;
        }
      }

      // 2. Buscar en musicCarouselShelfRenderer
      if (section.containsKey('musicCarouselShelfRenderer')) {
        final shelf = section['musicCarouselShelfRenderer'];
        final title = nav(shelf, [
          'header',
          'musicCarouselShelfBasicHeaderRenderer',
          'title',
          'runs',
          0,
          'text',
        ]);

        if (title != null &&
            keywords.any((k) => title.toString().toLowerCase().contains(k))) {
          singlesEndpoint = nav(shelf, [
            'header',
            'musicCarouselShelfBasicHeaderRenderer',
            'moreContentButton',
            'buttonRenderer',
            'navigationEndpoint',
            'browseEndpoint',
          ]);

          final contentList = nav(shelf, ['contents']);
          if (contentList is List) {
            topSinglesPreview = contentList;
          }
          break;
        }
      }
    }

    // Modo rápido para carga inicial: usar preview y evitar segunda petición pesada.
    if (!loadFullCollection && topSinglesPreview != null) {
      final results = parseSinglesPreview(topSinglesPreview);
      return {
        'results': results,
        'continuationToken': previewContinuationToken,
        'browseEndpoint': singlesEndpoint,
      };
    }

    // Si solo hay preview sin botón "Ver más", devolver el preview
    if (singlesEndpoint == null && topSinglesPreview != null) {
      final results = parseSinglesPreview(topSinglesPreview);
      return {
        'results': results,
        'continuationToken': null,
        'browseEndpoint': null,
      };
    }

    if (singlesEndpoint == null) {
      return {
        'results': <Map<String, String>>[],
        'continuationToken': null,
        'browseEndpoint': null,
      };
    }

    // 3. Obtener TODOS los singles usando el endpoint
    final singlesBrowseData = {...ytServiceContext};
    singlesBrowseData['browseId'] = singlesEndpoint['browseId'];
    if (singlesEndpoint['params'] != null) {
      singlesBrowseData['params'] = singlesEndpoint['params'];
    }

    final singlesResponse = (await sendRequest(
      "browse",
      singlesBrowseData,
    )).data;
    final results = <Map<String, String>>[];

    // Extraer del grid renderer (los albums/singles suelen venir en grids)
    final contents = nav(singlesResponse, [
      'contents',
      'singleColumnBrowseResultsRenderer',
      'tabs',
      0,
      'tabRenderer',
      'content',
      'sectionListRenderer',
      'contents',
      0,
    ]);

    if (contents != null) {
      var gridItems = nav(contents, ['gridRenderer', 'items']);

      if (gridItems is List) {
        for (var item in gridItems) {
          if (item['musicTwoRowItemRenderer'] != null) {
            final parsed = _parseTwoRowItem(item['musicTwoRowItemRenderer']);
            if (parsed != null) results.add(parsed);
          }
        }
      }

      // Token de continuación para Grid
      String? continuationToken = nav(contents, [
        'gridRenderer',
        'continuations',
        0,
        'nextContinuationData',
        'continuation',
      ]);

      return {
        'results': results,
        'continuationToken': continuationToken,
        'browseEndpoint': singlesEndpoint,
      };
    }

    return {
      'results': <Map<String, String>>[],
      'continuationToken': null,
      'browseEndpoint': null,
    };
  } catch (e) {
    return {
      'results': <Map<String, String>>[],
      'continuationToken': null,
      'browseEndpoint': null,
    };
  }
}

// Función de continuación para Singles/Albums (usa Grid)
Future<Map<String, dynamic>> getArtistAlbumsOrSinglesContinuation({
  required Map<String, dynamic> browseEndpoint,
  required String continuationToken,
}) async {
  try {
    final data = {...ytServiceContext};
    data['browseId'] = browseEndpoint['browseId'];
    if (browseEndpoint['params'] != null) {
      data['params'] = browseEndpoint['params'];
    }

    final additionalParams =
        '&ctoken=$continuationToken&continuation=$continuationToken';

    final response = (await sendRequest(
      "browse",
      data,
      additionalParams: additionalParams,
    )).data;
    final results = <Map<String, String>>[];

    final continuationContents = nav(response, [
      'continuationContents',
      'gridContinuation',
    ]);

    if (continuationContents != null) {
      final items = continuationContents['items'];
      if (items is List) {
        for (var item in items) {
          if (item['musicTwoRowItemRenderer'] != null) {
            final parsed = _parseTwoRowItem(item['musicTwoRowItemRenderer']);
            if (parsed != null) results.add(parsed);
          }
        }
      }

      final nextToken = nav(continuationContents, [
        'continuations',
        0,
        'nextContinuationData',
        'continuation',
      ]);

      return {'results': results, 'continuationToken': nextToken};
    }

    return {'results': <Map<String, String>>[], 'continuationToken': null};
  } catch (e) {
    return {'results': <Map<String, String>>[], 'continuationToken': null};
  }
}

// Obtiene la primera página de álbumes/sencillos a partir de su browseEndpoint.
Future<Map<String, dynamic>> getArtistAlbumsOrSinglesFirstPage({
  required Map<String, dynamic> browseEndpoint,
}) async {
  try {
    final data = {...ytServiceContext};
    data['browseId'] = browseEndpoint['browseId'];
    if (browseEndpoint['params'] != null) {
      data['params'] = browseEndpoint['params'];
    }

    final response = (await sendRequest("browse", data)).data;
    final results = <Map<String, String>>[];

    final contents = nav(response, [
      'contents',
      'singleColumnBrowseResultsRenderer',
      'tabs',
      0,
      'tabRenderer',
      'content',
      'sectionListRenderer',
      'contents',
      0,
    ]);

    if (contents != null) {
      final gridItems = nav(contents, ['gridRenderer', 'items']);

      if (gridItems is List) {
        for (var item in gridItems) {
          if (item['musicTwoRowItemRenderer'] != null) {
            final parsed = _parseTwoRowItem(item['musicTwoRowItemRenderer']);
            if (parsed != null) results.add(parsed);
          }
        }
      }

      final continuationToken = nav(contents, [
        'gridRenderer',
        'continuations',
        0,
        'nextContinuationData',
        'continuation',
      ]);

      return {'results': results, 'continuationToken': continuationToken};
    }

    return {'results': <Map<String, String>>[], 'continuationToken': null};
  } catch (e) {
    return {'results': <Map<String, String>>[], 'continuationToken': null};
  }
}

Map<String, String>? _parseTwoRowItem(Map<String, dynamic> renderer) {
  final browseId = nav(renderer, [
    'navigationEndpoint',
    'browseEndpoint',
    'browseId',
  ]);
  if (browseId == null) return null;

  final title = nav(renderer, ['title', 'runs', 0, 'text']);
  final subtitleRuns = nav(renderer, ['subtitle', 'runs']);
  String artist = '';
  String? year;
  String? type;

  if (subtitleRuns is List && subtitleRuns.isNotEmpty) {
    artist = subtitleRuns.map((r) => r['text'].toString()).join('');

    // Intentar extraer año y tipo como en _parseAlbumItem
    for (var run in subtitleRuns) {
      final text = run['text']?.toString();
      if (text == null || text == ' • ') continue;

      if (text == 'Album' ||
          text == 'Single' ||
          text == 'EP' ||
          text == 'Álbum' ||
          text == 'Sencillo') {
        type = text;
      } else if (RegExp(r'^\d{4}$').hasMatch(text)) {
        year = text;
      }
    }
  }

  String? thumbUrl;
  final thumbnails = nav(renderer, [
    'thumbnailRenderer',
    'musicThumbnailRenderer',
    'thumbnail',
    'thumbnails',
  ]);
  if (thumbnails is List && thumbnails.isNotEmpty) {
    thumbUrl = thumbnails.last['url'];
  }

  return {
    'title': title?.toString() ?? '',
    'artist': artist,
    'year': year ?? '',
    'type': type ?? '',
    'thumbUrl': thumbUrl != null ? _cleanThumbnailUrl(thumbUrl) : '',
    'browseId': browseId.toString(),
  };
}
