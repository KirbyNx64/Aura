import 'package:hive/hive.dart';

class ShortcutsDB {
  static final ShortcutsDB _instance = ShortcutsDB._internal();
  factory ShortcutsDB() => _instance;
  ShortcutsDB._internal();

  static const int maxShortcuts = 18;
  Box<List>? _box;

  Future<Box<List>> get box async {
    if (_box != null) return _box!;
    _box = await Hive.openBox<List>('shortcuts');
    return _box!;
  }

  // Devuelve la lista de shortcuts (paths), ordenados
  Future<List<String>> getShortcuts() async {
    final b = await box;
    final shortcuts = b.get('shortcuts') ?? <String>[];
    return List<String>.from(shortcuts);
  }

  // Agrega un shortcut si no existe y hay espacio
  Future<void> addShortcut(String songPath) async {
    final b = await box;
    final shortcuts = await getShortcuts();
    if (shortcuts.contains(songPath)) return;
    if (shortcuts.length >= maxShortcuts) return;
    shortcuts.add(songPath);
    await b.put('shortcuts', shortcuts);
  }

  // Elimina un shortcut y reordena
  Future<void> removeShortcut(String songPath) async {
    final b = await box;
    final shortcuts = await getShortcuts();
    shortcuts.remove(songPath);
    await b.put('shortcuts', shortcuts);
  }

  // Verifica si existe el shortcut
  Future<bool> isShortcut(String songPath) async {
    final shortcuts = await getShortcuts();
    return shortcuts.contains(songPath);
  }

  // Borra todos los shortcuts
  Future<void> clearAll() async {
    final b = await box;
    await b.put('shortcuts', <String>[]);
  }
} 