import 'package:hive_ce/hive_ce.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'songs_index_db.dart';

class MostPlayedDB {
  static final MostPlayedDB _instance = MostPlayedDB._internal();
  factory MostPlayedDB() => _instance;
  MostPlayedDB._internal();

  Box<Map>? _box;
  Box<Map>? _metaBox;

  Future<Box<Map>> get box async {
    if (_box != null) return _box!;
    _box = await Hive.openBox<Map>('most_played');
    return _box!;
  }

  Future<Box<Map>> get metaBox async {
    if (_metaBox != null) return _metaBox!;
    _metaBox = await Hive.openBox<Map>('most_played_meta');
    return _metaBox!;
  }

  Future<void> incrementPlayCount(SongModel song) async {
    final b = await box;
    final path = song.data;
    final playCount = b.get(path)?['play_count'] ?? 0;
    await b.put(path, {'play_count': playCount + 1});
  }

  /// Incrementa el contador de una canción por path (usado para streaming y locales)
  Future<void> incrementPlayCountByPath(
    String path, {
    String? title,
    String? artist,
    String? videoId,
    String? artUri,
    int? durationMs,
  }) async {
    final b = await box;
    final playCount = b.get(path)?['play_count'] ?? 0;
    await b.put(path, {'play_count': playCount + 1});

    // Guardar metadata si se proporciona (importante para streaming)
    final mb = await metaBox;
    final existingRaw = mb.get(path);
    final existing = existingRaw == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(existingRaw);
    final next = <String, dynamic>{
      ...existing,
      if (title != null && title.trim().isNotEmpty) 'title': title.trim(),
      if (artist != null && artist.trim().isNotEmpty) 'artist': artist.trim(),
      if (videoId != null && videoId.trim().isNotEmpty)
        'videoId': videoId.trim(),
      if (artUri != null && artUri.trim().isNotEmpty) 'artUri': artUri.trim(),
      if (durationMs != null && durationMs > 0) 'durationMs': durationMs,
    };
    if (next.isNotEmpty) {
      await mb.put(path, next);
    }
  }

  Future<Map<String, dynamic>?> getMostPlayedMeta(String path) async {
    final mb = await metaBox;
    final raw = mb.get(path);
    if (raw == null) return null;
    return Map<String, dynamic>.from(raw);
  }

  /// Obtiene todos los paths más reproducidos (locales y streaming) con sus contadores
  Future<List<String>> getMostPlayedPaths({int limit = 40}) async {
    final b = await box;
    final entries = b.toMap().entries.toList();
    entries.sort(
      (a, b) => (b.value['play_count'] as int).compareTo(
        a.value['play_count'] as int,
      ),
    );
    return entries.take(limit).map((e) => e.key as String).toList();
  }

  Future<List<SongModel>> getMostPlayed({int limit = 20}) async {
    final b = await box;
    final entries = b.toMap().entries.toList();
    entries.sort(
      (a, b) => (b.value['play_count'] as int).compareTo(
        a.value['play_count'] as int,
      ),
    );
    final paths = entries.take(limit).map((e) => e.key as String).toList();

    // Usar SongsIndexDB para obtener solo canciones no ignoradas (locales)
    final SongsIndexDB songsIndex = SongsIndexDB();
    final indexedSongs = await songsIndex.getIndexedSongs();

    List<SongModel> ordered = [];
    for (final path in paths) {
      final match = indexedSongs.where((s) => s.data == path);
      if (match.isNotEmpty) {
        ordered.add(match.first);
      }
      // Si no se encuentra en canciones locales, podría ser una canción de streaming
      // En ese caso, se omite de la lista ya que SongModel requiere archivo local
      // La información de streaming se maneja por metadata
    }
    return ordered;
  }

  Future<int> getPlayCount(String path) async {
    final b = await box;
    return b.get(path)?['play_count'] ?? 0;
  }

  Future<void> removeMostPlayed(String path) async {
    final b = await box;
    await b.delete(path);
    final mb = await metaBox;
    await mb.delete(path);
  }
}
