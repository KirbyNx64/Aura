import 'package:hive_ce/hive_ce.dart';

class ShortcutsDB {
  static final ShortcutsDB _instance = ShortcutsDB._internal();
  factory ShortcutsDB() => _instance;
  ShortcutsDB._internal();

  static const int maxShortcuts = 18;
  Box<List>? _box;
  Box<Map>? _metaBox;

  Future<Box<List>> get box async {
    if (_box != null) return _box!;
    _box = await Hive.openBox<List>('shortcuts');
    return _box!;
  }

  Future<Box<Map>> get metaBox async {
    if (_metaBox != null) return _metaBox!;
    _metaBox = await Hive.openBox<Map>('shortcuts_meta');
    return _metaBox!;
  }

  // Devuelve la lista de shortcuts (paths), ordenados
  Future<List<String>> getShortcuts() async {
    final b = await box;
    final shortcuts = b.get('shortcuts') ?? <String>[];
    return List<String>.from(shortcuts)
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
  }

  // Agrega un shortcut si no existe y hay espacio. También permite guardar metadata.
  Future<void> addShortcut(
    String songPath, {
    String? title,
    String? artist,
    String? videoId,
    String? artUri,
    String? durationText,
    int? durationMs,
  }) async {
    await addShortcutPath(
      songPath,
      title: title,
      artist: artist,
      videoId: videoId,
      artUri: artUri,
      durationText: durationText,
      durationMs: durationMs,
    );
  }

  Future<void> addShortcutPath(
    String songPath, {
    String? title,
    String? artist,
    String? videoId,
    String? artUri,
    String? durationText,
    int? durationMs,
  }) async {
    final path = songPath.trim();
    if (path.isEmpty) return;
    final b = await box;
    final mb = await metaBox;
    final shortcuts = await getShortcuts();
    final alreadyExists = shortcuts.contains(path);

    if (!alreadyExists) {
      if (shortcuts.length >= maxShortcuts) return;
      shortcuts.add(path);
      await b.put('shortcuts', shortcuts);
    }

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
      if (durationText != null && durationText.trim().isNotEmpty)
        'durationText': durationText.trim(),
      if (durationMs != null && durationMs > 0) 'durationMs': durationMs,
    };
    if (next.isNotEmpty) {
      await mb.put(path, next);
    }
  }

  // Elimina un shortcut y reordena
  Future<void> removeShortcut(String songPath) async {
    final path = songPath.trim();
    if (path.isEmpty) return;
    final b = await box;
    final mb = await metaBox;
    final shortcuts = await getShortcuts();
    shortcuts.remove(path);
    await b.put('shortcuts', shortcuts);
    await mb.delete(path);
  }

  // Verifica si existe el shortcut
  Future<bool> isShortcut(String songPath) async {
    final path = songPath.trim();
    if (path.isEmpty) return false;
    final shortcuts = await getShortcuts();
    return shortcuts.contains(path);
  }

  Future<Map<String, dynamic>?> getShortcutMeta(String path) async {
    final normalized = path.trim();
    if (normalized.isEmpty) return null;
    final mb = await metaBox;
    final raw = mb.get(normalized);
    if (raw == null) return null;
    return Map<String, dynamic>.from(raw);
  }

  // Borra todos los shortcuts
  Future<void> clearAll() async {
    final b = await box;
    final mb = await metaBox;
    await b.put('shortcuts', <String>[]);
    await mb.clear();
  }
}
