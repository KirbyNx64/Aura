import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class SyncedLyricsService {
  static Database? _db;

  static Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  static Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'lyrics.db');
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE lyrics (
            id TEXT PRIMARY KEY,
            synced TEXT,
            plainLyrics TEXT
          )
        ''');
      },
    );
  }

  static Future<Map<String, dynamic>?> getSyncedLyrics(
    MediaItem song, {
    int? durInSec,
  }) async {
    final db = await database;

    // Buscar en la base local
    final result = await db.query(
      'lyrics',
      where: 'id = ?',
      whereArgs: [song.id],
      limit: 1,
    );
    if (result.isNotEmpty) {
      return result.first;
    }

    // Si no está, buscar online
    final dur = song.duration?.inSeconds ?? durInSec ?? 0;
    final url =
        'https://lrclib.net/api/get?artist_name=${Uri.encodeComponent(song.artist ?? "")}'
        '&track_name=${Uri.encodeComponent(song.title)}'
        '&duration=$dur';

    try {
      final response = (await Dio().get(url)).data;
      if (response["syncedLyrics"] != null) {
        final lyricsData = {
          "id": song.id,
          "synced": response["syncedLyrics"],
          "plainLyrics": response["plainLyrics"],
        };
        await db.insert(
          'lyrics',
          lyricsData,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        return lyricsData;
      }
    } on DioException {
      // Puedes loggear el error si quieres
    }
    return null;
  }
}
