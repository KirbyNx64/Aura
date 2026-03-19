import 'package:hive_ce/hive_ce.dart';

class HomeYoutubeCacheDB {
  static const String _boxName = 'home_youtube_cache';
  static const String _sharedPoolKey = 'shared_pool';
  static const String _updatedAtKey = 'updated_at';

  static final HomeYoutubeCacheDB _instance = HomeYoutubeCacheDB._internal();
  factory HomeYoutubeCacheDB() => _instance;
  HomeYoutubeCacheDB._internal();

  Box<Map>? _box;

  Future<Box<Map>> get box async {
    if (_box != null) return _box!;
    _box = await Hive.openBox<Map>(_boxName);
    return _box!;
  }

  Future<List<Map<String, dynamic>>> getSharedPool() async {
    final b = await box;
    final raw = b.get(_sharedPoolKey);
    if (raw == null) return const [];

    final entries = raw['items'];
    if (entries is! List) return const [];

    return entries
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Future<void> saveSharedPool(List<Map<String, dynamic>> items) async {
    final b = await box;
    final safeItems = items
        .where((item) => item['videoId']?.toString().trim().isNotEmpty == true)
        .map((item) => Map<String, dynamic>.from(item))
        .toList();

    await b.put(_sharedPoolKey, <String, dynamic>{'items': safeItems});
    await b.put(_updatedAtKey, <String, dynamic>{
      'value': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<int?> getLastUpdatedAt() async {
    final b = await box;
    final raw = b.get(_updatedAtKey);
    if (raw == null) return null;
    final value = raw['value'];
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}
