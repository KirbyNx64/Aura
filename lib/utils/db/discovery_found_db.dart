import 'package:hive_ce/hive_ce.dart';

class DiscoveryFoundDB {
  static final DiscoveryFoundDB _instance = DiscoveryFoundDB._internal();
  factory DiscoveryFoundDB() => _instance;
  DiscoveryFoundDB._internal();

  static const String _seedMetaKey = '__seed__';
  Box<String>? _box;
  Box<Map>? _metaBox;

  Future<Box<String>> get box async {
    if (_box != null) return _box!;
    _box = await Hive.openBox<String>('discovery_found');
    return _box!;
  }

  Future<Box<Map>> get metaBox async {
    if (_metaBox != null) return _metaBox!;
    _metaBox = await Hive.openBox<Map>('discovery_found_meta');
    return _metaBox!;
  }

  Future<void> saveFound({
    required Map<String, dynamic> seed,
    required List<Map<String, dynamic>> tracks,
  }) async {
    final b = await box;
    final mb = await metaBox;

    await b.clear();
    await mb.clear();

    for (final track in tracks) {
      final videoId = track['videoId']?.toString().trim() ?? '';
      if (videoId.isEmpty) continue;
      final path = 'yt:$videoId';
      if (!b.values.contains(path)) {
        await b.add(path);
      }

      final title = track['title']?.toString().trim();
      final artist = track['artist']?.toString().trim();
      final artUri = track['artUri']?.toString().trim();
      final durationText = track['durationText']?.toString().trim();
      final durationMs = track['durationMs'];

      await mb.put(path, <String, dynamic>{
        if (title != null && title.isNotEmpty) 'title': title,
        if (artist != null && artist.isNotEmpty) 'artist': artist,
        'videoId': videoId,
        if (artUri != null && artUri.isNotEmpty) 'artUri': artUri,
        if (durationText != null && durationText.isNotEmpty)
          'durationText': durationText,
        if (durationMs is int && durationMs > 0) 'durationMs': durationMs,
      });
    }

    final seedVideoId = seed['videoId']?.toString().trim();
    await mb.put(_seedMetaKey, <String, dynamic>{
      if (seedVideoId != null && seedVideoId.isNotEmpty) 'videoId': seedVideoId,
      if (seed['title']?.toString().trim().isNotEmpty == true)
        'title': seed['title'].toString().trim(),
      if (seed['artist']?.toString().trim().isNotEmpty == true)
        'artist': seed['artist'].toString().trim(),
      if (seed['artUri']?.toString().trim().isNotEmpty == true)
        'artUri': seed['artUri'].toString().trim(),
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<Map<String, dynamic>?> getSeedMeta() async {
    final mb = await metaBox;
    final raw = mb.get(_seedMetaKey);
    if (raw == null) return null;
    return Map<String, dynamic>.from(raw);
  }

  Future<List<String>> getFoundPaths() async {
    final b = await box;
    return b.values
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
  }

  Future<Map<String, dynamic>?> getFoundMeta(String path) async {
    final mb = await metaBox;
    final raw = mb.get(path);
    if (raw == null) return null;
    return Map<String, dynamic>.from(raw);
  }

  Future<void> clear() async {
    final b = await box;
    await b.clear();
    final mb = await metaBox;
    await mb.clear();
  }
}
