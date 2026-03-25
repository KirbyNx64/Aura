import 'package:hive_ce/hive_ce.dart';

class ArtistSongsCacheDB {
  static final ArtistSongsCacheDB _instance = ArtistSongsCacheDB._internal();
  factory ArtistSongsCacheDB() => _instance;
  ArtistSongsCacheDB._internal();

  static const String _boxName = 'artist_songs_cache';
  Box<Map>? _box;

  Future<Box<Map>> get box async {
    if (_box != null && _box!.isOpen) return _box!;
    _box = await Hive.openBox<Map>(_boxName);
    return _box!;
  }

  String _normalizeArtistName(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  Future<void> cacheArtistSongs({
    required String artistName,
    String? browseId,
    required List<Map<String, dynamic>> songsMeta,
    Duration cacheDuration = const Duration(days: 7),
  }) async {
    final normalizedArtistName = artistName.trim();
    if (normalizedArtistName.isEmpty || songsMeta.isEmpty) return;

    final key = _normalizeArtistName(normalizedArtistName);
    if (key.isEmpty) return;

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final expiresAtMs = nowMs + cacheDuration.inMilliseconds;
    final cleanSongs = <Map<String, dynamic>>[];

    for (final raw in songsMeta) {
      final title = raw['title']?.toString().trim();
      final artist = raw['artist']?.toString().trim();
      final videoId = raw['videoId']?.toString().trim();
      final artUri = raw['artUri']?.toString().trim();
      final durationText = raw['durationText']?.toString().trim();
      final durationMs = _asPositiveInt(raw['durationMs']);
      final resultType = raw['resultType']?.toString().trim();
      final videoType = raw['videoType']?.toString().trim();
      final path = raw['path']?.toString().trim();

      final safeVideoId = (videoId != null && videoId.isNotEmpty)
          ? videoId
          : _extractVideoIdFromPath(path);
      if (safeVideoId == null || safeVideoId.isEmpty) continue;

      cleanSongs.add(<String, dynamic>{
        'path': (path != null && path.isNotEmpty) ? path : 'yt:$safeVideoId',
        if (title != null && title.isNotEmpty) 'title': title,
        if (artist != null && artist.isNotEmpty) 'artist': artist,
        'videoId': safeVideoId,
        if (artUri != null && artUri.isNotEmpty) 'artUri': artUri,
        if (durationText != null && durationText.isNotEmpty)
          'durationText': durationText,
        if (durationMs != null) 'durationMs': durationMs,
        if (resultType != null && resultType.isNotEmpty)
          'resultType': resultType.toLowerCase(),
        if (videoType != null && videoType.isNotEmpty)
          'videoType': videoType.toUpperCase(),
      });
    }

    if (cleanSongs.isEmpty) return;

    final b = await box;
    await b.put(key, <String, dynamic>{
      'artistName': normalizedArtistName,
      if (browseId != null && browseId.trim().isNotEmpty)
        'browseId': browseId.trim(),
      'songs': cleanSongs,
      'cachedAt': nowMs,
      'expiresAt': expiresAtMs,
    });
  }

  Future<List<Map<String, dynamic>>> getArtistSongs(
    String artistName, {
    String? browseId,
  }) async {
    final normalizedArtistName = artistName.trim();
    if (normalizedArtistName.isEmpty) return const [];

    final key = _normalizeArtistName(normalizedArtistName);
    if (key.isEmpty) return const [];

    final b = await box;
    final raw = b.get(key);
    if (raw == null) return const [];

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final expiresAtMs = _asPositiveInt(raw['expiresAt']) ?? 0;
    if (expiresAtMs <= nowMs) {
      await b.delete(key);
      return const [];
    }

    final cachedBrowseId = raw['browseId']?.toString().trim();
    final requestedBrowseId = browseId?.trim();
    if (requestedBrowseId != null &&
        requestedBrowseId.isNotEmpty &&
        cachedBrowseId != null &&
        cachedBrowseId.isNotEmpty &&
        cachedBrowseId != requestedBrowseId) {
      return const [];
    }

    final songsRaw = raw['songs'];
    if (songsRaw is! List) return const [];

    final songs = <Map<String, dynamic>>[];
    for (final row in songsRaw) {
      if (row is! Map) continue;
      songs.add(Map<String, dynamic>.from(row));
    }
    return songs;
  }

  Future<void> clearAllCache() async {
    final b = await box;
    await b.clear();
  }

  int? _asPositiveInt(dynamic value) {
    if (value == null) return null;
    int? parsed;
    if (value is int) {
      parsed = value;
    } else if (value is num) {
      parsed = value.toInt();
    } else if (value is String) {
      parsed = int.tryParse(value);
    }
    if (parsed == null || parsed <= 0) return null;
    return parsed;
  }

  String? _extractVideoIdFromPath(String? value) {
    final normalized = value?.trim() ?? '';
    if (normalized.isEmpty) return null;
    if (normalized.startsWith('yt:') && normalized.length > 3) {
      return normalized.substring(3).trim();
    }
    return null;
  }
}
