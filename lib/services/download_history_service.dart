import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import '../models/download_record.dart';

class DownloadHistoryService {
  static final DownloadHistoryService _instance =
      DownloadHistoryService._internal();
  factory DownloadHistoryService() => _instance;
  DownloadHistoryService._internal();

  static Box<Map>? _recordsBox;
  static Box<int>? _metaBox;
  static Future<void>? _initializationFuture;
  static const String _recordsBoxName = 'download_history_records_box';
  static const String _metaBoxName = 'download_history_meta_box';
  static const String _nextIdKey = 'next_id';

  /// Pre-inicializa la base de datos para evitar lag en la primera apertura
  Future<void> preInitialize() async {
    await _ensureInitialized();
  }

  Future<void> _ensureInitialized() async {
    if (_recordsBox != null &&
        _recordsBox!.isOpen &&
        _metaBox != null &&
        _metaBox!.isOpen) {
      return;
    }

    if (_initializationFuture != null) {
      await _initializationFuture!;
      return;
    }

    _initializationFuture = _openBoxes();
    await _initializationFuture!;
    _initializationFuture = null;
  }

  Future<void> _openBoxes() async {
    _recordsBox = await Hive.openBox<Map>(_recordsBoxName);
    _metaBox = await Hive.openBox<int>(_metaBoxName);
    _metaBox!.put(_nextIdKey, _computeNextIdIfNeeded());
  }

  int _computeNextIdIfNeeded() {
    final explicitNextId = _metaBox!.get(_nextIdKey);
    if (explicitNextId != null && explicitNextId > 0) return explicitNextId;

    int maxId = 0;
    for (final key in _recordsBox!.keys) {
      final id = _asInt(key);
      if (id != null && id > maxId) maxId = id;
    }
    return maxId + 1;
  }

  Future<int> insertDownload(DownloadRecord download) async {
    await _ensureInitialized();
    final records = _recordsBox!;
    final meta = _metaBox!;

    final map = Map<String, dynamic>.from(download.toMap());
    final nextId = meta.get(_nextIdKey) ?? _computeNextIdIfNeeded();
    final id = download.id ?? nextId;
    map['id'] = id;
    map['viewed'] = (map['viewed'] ?? 0) == 1 ? 1 : 0;

    await records.put(id, map);
    if (id >= nextId) {
      await meta.put(_nextIdKey, id + 1);
    }
    return id;
  }

  Future<List<DownloadRecord>> getAllDownloads() async {
    await _ensureInitialized();
    final maps = _recordsBox!.values.map(_normalizeRecordMap).toList();
    maps.sort(
      (a, b) => (_asInt(b['download_date']) ?? 0).compareTo(
        _asInt(a['download_date']) ?? 0,
      ),
    );
    return maps.map(DownloadRecord.fromMap).toList();
  }

  Future<List<DownloadRecord>> getCompletedDownloads() async {
    await _ensureInitialized();
    final maps = _recordsBox!.values
        .map(_normalizeRecordMap)
        .where((m) => m['status'] == 'completed')
        .toList();
    maps.sort(
      (a, b) => (_asInt(b['download_date']) ?? 0).compareTo(
        _asInt(a['download_date']) ?? 0,
      ),
    );
    return maps.map(DownloadRecord.fromMap).toList();
  }

  Future<DownloadRecord?> getDownloadById(int id) async {
    await _ensureInitialized();
    final map = _recordsBox!.get(id);
    if (map == null) return null;
    return DownloadRecord.fromMap(_normalizeRecordMap(map));
  }

  Future<int> updateDownload(DownloadRecord download) async {
    await _ensureInitialized();
    final id = download.id;
    if (id == null) return 0;
    if (!_recordsBox!.containsKey(id)) return 0;

    final map = Map<String, dynamic>.from(download.toMap());
    map['id'] = id;
    map['viewed'] = (map['viewed'] ?? 0) == 1 ? 1 : 0;
    await _recordsBox!.put(id, map);
    return 1;
  }

  Future<int> deleteDownload(int id) async {
    await _ensureInitialized();
    final existed = _recordsBox!.containsKey(id);
    await _recordsBox!.delete(id);
    return existed ? 1 : 0;
  }

  Future<int> deleteAllDownloads() async {
    await _ensureInitialized();
    final count = _recordsBox!.length;
    await _recordsBox!.clear();
    await _metaBox!.put(_nextIdKey, 1);
    return count;
  }

  Future<int> getDownloadCount() async {
    await _ensureInitialized();
    return _recordsBox!.length;
  }

  Future<int> getCompletedDownloadCount() async {
    await _ensureInitialized();
    var count = 0;
    for (final row in _recordsBox!.values) {
      if (row['status'] == 'completed') count++;
    }
    return count;
  }

  /// Verifica si hay descargas sin ver
  Future<bool> hasUnviewedDownloads() async {
    await _ensureInitialized();
    for (final row in _recordsBox!.values) {
      if (row['status'] == 'completed' && (_asInt(row['viewed']) ?? 0) == 0) {
        return true;
      }
    }
    return false;
  }

  /// Marca todas las descargas como vistas
  Future<int> markAllAsViewed() async {
    await _ensureInitialized();
    int updated = 0;

    for (final key in _recordsBox!.keys) {
      final row = _recordsBox!.get(key);
      if (row == null) continue;

      if ((_asInt(row['viewed']) ?? 0) == 0) {
        row['viewed'] = 1;
        await _recordsBox!.put(key, row);
        updated++;
      }
    }
    return updated;
  }

  Future<void> close() async {
    if (_recordsBox != null && _recordsBox!.isOpen) {
      await _recordsBox!.close();
    }
    if (_metaBox != null && _metaBox!.isOpen) {
      await _metaBox!.close();
    }
    _recordsBox = null;
    _metaBox = null;
    _initializationFuture = null;
  }

  Map<String, dynamic> _normalizeRecordMap(Map map) {
    final normalized = Map<String, dynamic>.from(map);
    normalized['id'] = _asInt(normalized['id']);
    normalized['file_size'] = _asInt(normalized['file_size']) ?? 0;
    normalized['download_date'] = _asInt(normalized['download_date']) ?? 0;
    normalized['viewed'] = (_asInt(normalized['viewed']) ?? 0) == 1 ? 1 : 0;
    return normalized;
  }

  int? _asInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}
