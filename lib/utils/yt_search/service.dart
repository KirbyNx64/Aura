// import 'dart:convert';
// import 'package:dio/dio.dart';
// import 'package:sqflite/sqflite.dart';
// import 'package:path/path.dart';

// const domain = "https://music.youtube.com/";
// const String baseUrl = '${domain}youtubei/v1/';
// const String fixedParms = '?prettyPrint=false&key=AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30';
// const userAgent =
//     'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36';

// class YtMusicSong {
//   final String title;
//   final String artist;
//   final String videoId;
//   final String duration;
//   final String thumbnailUrl;

//   YtMusicSong({
//     required this.title,
//     required this.artist,
//     required this.videoId,
//     required this.duration,
//     required this.thumbnailUrl,
//   });
// }

// class MusicServices {
//   final Map<String, String> _headers = {
//     'user-agent': userAgent,
//     'accept': '*/*',
//     'accept-encoding': 'gzip, deflate',
//     'content-type': 'application/json',
//     'origin': domain,
//     'cookie': 'CONSENT=YES+1',
//   };

//   final Map<String, dynamic> _context = {
//     'context': {
//       'client': {
//         "clientName": "WEB_REMIX",
//         "clientVersion": "1.20240625.01.00",
//         "hl": "es"
//       },
//       'user': {}
//     }
//   };

//   Database? _db;
//   final dio = Dio();

//   Future<void> _initDb() async {
//     if (_db != null) return;
//     final dbPath = await getDatabasesPath();
//     _db = await openDatabase(
//       join(dbPath, 'app_prefs.db'),
//       version: 1,
//       onCreate: (db, version) async {
//         await db.execute('''
//           CREATE TABLE IF NOT EXISTS AppPrefs (
//             key TEXT PRIMARY KEY,
//             value TEXT,
//             exp INTEGER
//           )
//         ''');
//       },
//     );
//   }

//   Future<void> saveVisitorId(String visitorId, int exp) async {
//     await _initDb();
//     await _db!.insert(
//       'AppPrefs',
//       {'key': 'visitorId', 'value': visitorId, 'exp': exp},
//       conflictAlgorithm: ConflictAlgorithm.replace,
//     );
//   }

//   Future<Map<String, dynamic>?> getVisitorId() async {
//     await _initDb();
//     final result = await _db!.query(
//       'AppPrefs',
//       where: 'key = ?',
//       whereArgs: ['visitorId'],
//       limit: 1,
//     );
//     if (result.isNotEmpty) {
//       return result.first;
//     }
//     return null;
//   }

//   Future<void> init() async {
//     final date = DateTime.now();
//     _context['context']['client']['clientVersion'] =
//         "1.${date.year}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}.01.00";

//     final visitorData = await getVisitorId();
//     String? visitorId;
//     int now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
//     if (visitorData != null && visitorData['exp'] != null && visitorData['exp'] > now) {
//       visitorId = visitorData['value'] as String;
//     } else {
//       visitorId = await genrateVisitorId();
//       int exp = now + 2592000; // 30 días
//       if (visitorId != null) {
//         await saveVisitorId(visitorId, exp);
//       } else {
//         visitorId = "CgttN24wcmd5UzNSWSi2lvq2BjIKCgJKUBIEGgAgYQ%3D%3D";
//       }
//     }
//     _headers['X-Goog-Visitor-Id'] = visitorId;
//     _headers['x-youtube-client-name'] = '67';
//     _headers['x-youtube-client-version'] = _context['context']['client']['clientVersion'];
//     _headers['x-origin'] = domain;
//     _headers['x-goog-authuser'] = '0';
//     _headers['x-youtube-bootstrap-logged-in'] = 'false';
//   }

//   Future<String?> genrateVisitorId() async {
//     try {
//       final response = await dio.get(domain, options: Options(headers: _headers));
//       final reg = RegExp(r'ytcfg\.set\s*\(\s*({.+?})\s*\)\s*;');
//       final matches = reg.firstMatch(response.data.toString());
//       if (matches != null) {
//         final ytcfg = json.decode(matches.group(1).toString());
//         return ytcfg['VISITOR_DATA']?.toString();
//       }
//       return null;
//     } catch (e) {
//       return null;
//     }
//   }

//   Future<List<YtMusicSong>> buscarCanciones(String query) async {
//     await init();
//     final data = Map.from(_context);
//     data['query'] = query;

//     try {
//       final response = await dio.post(
//         "$baseUrl/search$fixedParms",
//         data: data,
//         options: Options(headers: _headers),
//       );

//       final json = response.data;
//       return _parseSongs(json);
//     } catch (e) {
//       print('Error en la búsqueda: $e');
//       return [];
//     }
//   }

//   List<YtMusicSong> _parseSongs(dynamic json) {
//     final List<YtMusicSong> canciones = [];
//     try {
//       final sections = json['contents']?['sectionListRenderer']?['contents'] ?? [];
//       for (final section in sections) {
//         final shelf = section['musicShelfRenderer'];
//         if (shelf != null) {
//           for (final item in shelf['contents']) {
//             final video = item['musicResponsiveListItemRenderer'];
//             if (video != null) {
//               final title = video['flexColumns'][0]['musicResponsiveListItemFlexColumnRenderer']['text']['runs'][0]['text'];
//               final subtitle = video['flexColumns'][1]['musicResponsiveListItemFlexColumnRenderer']['text']['runs'][0]['text'];
//               final videoId = video['navigationEndpoint']?['watchEndpoint']?['videoId'];
//               final duration = video['fixedColumns']?[0]?['musicResponsiveListItemFixedColumnRenderer']?['text']?['runs']?[0]?['text'];
//               final thumbnailUrl = video['thumbnail']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails']?.last?['url'] ?? '';
//               if (videoId != null && duration != null) {
//                 canciones.add(YtMusicSong(
//                   title: title,
//                   artist: subtitle,
//                   videoId: videoId,
//                   duration: duration,
//                   thumbnailUrl: thumbnailUrl,
//                 ));
//               }
//             }
//           }
//         }
//       }
//     } catch (e) {
//       // Si falla el parseo, retorna vacío
//     }
//     return canciones;
//   }
// }