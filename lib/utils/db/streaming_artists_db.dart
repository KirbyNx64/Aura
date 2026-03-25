import 'package:hive_ce/hive_ce.dart';

class StreamingArtistsDB {
  static final StreamingArtistsDB _instance = StreamingArtistsDB._internal();
  factory StreamingArtistsDB() => _instance;
  StreamingArtistsDB._internal();

  Box<Map>? _artistsBox;

  Future<Box<Map>> get artistsBox async {
    if (_artistsBox != null) return _artistsBox!;
    _artistsBox = await Hive.openBox<Map>('streaming_artists');
    return _artistsBox!;
  }

  String _normalizeName(String input) =>
      input.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  List<String> _splitArtists(String? rawArtist) {
    final value = rawArtist?.trim() ?? '';
    if (value.isEmpty) return const [];

    final parts = value
        .split(RegExp(r'\s*(?:,|&|/|;|\|| feat\. | feat | ft\. | ft )\s*'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    final seen = <String>{};
    final output = <String>[];
    for (final p in parts) {
      final k = _normalizeName(p);
      if (k.isEmpty || seen.contains(k)) continue;
      seen.add(k);
      output.add(p);
      if (output.length >= 3) break;
    }
    return output;
  }

  Future<void> incrementArtistPlay({
    required String path,
    String? title,
    String? artist,
    String? videoId,
    String? artUri,
    String? durationText,
    int? durationMs,
    String? resultType,
    String? videoType,
  }) async {
    final normalizedPath = path.trim();
    if (normalizedPath.isEmpty) return;

    final artistNames = _splitArtists(artist);
    if (artistNames.isEmpty) return;

    final box = await artistsBox;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final songKey = (videoId != null && videoId.trim().isNotEmpty)
        ? 'yt:${videoId.trim()}'
        : normalizedPath;

    for (final artistName in artistNames) {
      final artistKey = _normalizeName(artistName);
      if (artistKey.isEmpty) continue;

      final existingRaw = box.get(artistKey);
      final existing = existingRaw == null
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(existingRaw);

      final songsRaw = existing['songs'];
      final songs = songsRaw is Map
          ? Map<String, dynamic>.from(songsRaw)
          : <String, dynamic>{};

      final songEntryRaw = songs[songKey];
      final songEntry = songEntryRaw is Map
          ? Map<String, dynamic>.from(songEntryRaw)
          : <String, dynamic>{};
      final nextSongPlayCount = ((songEntry['play_count'] as num?) ?? 0) + 1;

      songs[songKey] = <String, dynamic>{
        ...songEntry,
        'path': normalizedPath,
        if (title != null && title.trim().isNotEmpty) 'title': title.trim(),
        'artist': artistName,
        if (videoId != null && videoId.trim().isNotEmpty)
          'videoId': videoId.trim(),
        if (artUri != null && artUri.trim().isNotEmpty) 'artUri': artUri.trim(),
        if (durationText != null && durationText.trim().isNotEmpty)
          'durationText': durationText.trim(),
        if (durationMs != null && durationMs > 0) 'durationMs': durationMs,
        if (resultType != null && resultType.trim().isNotEmpty)
          'resultType': resultType.trim().toLowerCase(),
        if (videoType != null && videoType.trim().isNotEmpty)
          'videoType': videoType.trim().toUpperCase(),
        'play_count': nextSongPlayCount,
        'last_played_ms': nowMs,
      };

      final nextArtistPlayCount = ((existing['play_count'] as num?) ?? 0) + 1;
      final next = <String, dynamic>{
        ...existing,
        'name': artistName,
        'play_count': nextArtistPlayCount,
        'song_count': songs.length,
        'last_played_ms': nowMs,
        if (artUri != null && artUri.trim().isNotEmpty)
          'thumbUrl': artUri.trim(),
        'songs': songs,
      };

      await box.put(artistKey, next);
    }
  }

  Future<List<Map<String, dynamic>>> getTopArtists({int limit = 20}) async {
    final box = await artistsBox;
    final entries = box.toMap().entries.map((entry) {
      final map = Map<String, dynamic>.from(entry.value);
      return <String, dynamic>{
        'key': entry.key,
        'name': (map['name']?.toString().trim().isNotEmpty ?? false)
            ? map['name'].toString().trim()
            : entry.key.toString(),
        'play_count': ((map['play_count'] as num?) ?? 0).toInt(),
        'song_count': ((map['song_count'] as num?) ?? 0).toInt(),
        'last_played_ms': ((map['last_played_ms'] as num?) ?? 0).toInt(),
        if (map['thumbUrl']?.toString().trim().isNotEmpty == true)
          'thumbUrl': map['thumbUrl'].toString().trim(),
      };
    }).toList();

    entries.sort((a, b) {
      final countCompare = (b['play_count'] as int).compareTo(
        a['play_count'] as int,
      );
      if (countCompare != 0) return countCompare;
      return (b['last_played_ms'] as int).compareTo(a['last_played_ms'] as int);
    });

    return entries.take(limit).toList();
  }

  Future<List<Map<String, dynamic>>> getArtistSongs(
    String artistName, {
    int limit = 100,
  }) async {
    final key = _normalizeName(artistName);
    if (key.isEmpty) return const [];

    final box = await artistsBox;
    final raw = box.get(key);
    if (raw == null) return const [];

    final data = Map<String, dynamic>.from(raw);
    final songsRaw = data['songs'];
    if (songsRaw is! Map) return const [];

    final songs = songsRaw.entries.map((entry) {
      final map = entry.value is Map
          ? Map<String, dynamic>.from(entry.value as Map)
          : <String, dynamic>{};
      return <String, dynamic>{
        'key': entry.key,
        'path': map['path']?.toString().trim() ?? '',
        'title': map['title']?.toString().trim() ?? '',
        'artist': map['artist']?.toString().trim() ?? artistName,
        'videoId': map['videoId']?.toString().trim(),
        'artUri': map['artUri']?.toString().trim(),
        'durationText': map['durationText']?.toString().trim(),
        'durationMs': (map['durationMs'] as num?)?.toInt(),
        'resultType': map['resultType']?.toString().trim(),
        'videoType': map['videoType']?.toString().trim(),
        'play_count': ((map['play_count'] as num?) ?? 0).toInt(),
        'last_played_ms': ((map['last_played_ms'] as num?) ?? 0).toInt(),
      };
    }).toList();

    songs.sort((a, b) {
      final countCompare = (b['play_count'] as int).compareTo(
        a['play_count'] as int,
      );
      if (countCompare != 0) return countCompare;
      return (b['last_played_ms'] as int).compareTo(a['last_played_ms'] as int);
    });

    return songs.take(limit).toList();
  }
}
