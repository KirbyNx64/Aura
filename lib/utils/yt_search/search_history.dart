import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class SearchHistory {
  static const String _key = 'yt_search_history';
  static const int _maxHistorySize = 50;

  // Obtener historial de búsquedas
  static Future<List<String>> getHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final historyJson = prefs.getString(_key);
      if (historyJson != null) {
        final List<dynamic> historyList = jsonDecode(historyJson);
        return historyList.cast<String>();
      }
    } catch (e) {
      // print('Error obteniendo historial: $e');
    }
    return [];
  }

  // Agregar búsqueda al historial
  static Future<void> addToHistory(String query) async {
    try {
      if (query.trim().isEmpty) return;
      
      final prefs = await SharedPreferences.getInstance();
      final currentHistory = await getHistory();
      
      // Remover la búsqueda si ya existe (para moverla al principio)
      currentHistory.remove(query);
      
      // Agregar al principio
      currentHistory.insert(0, query.trim());
      
      // Limitar el tamaño del historial
      if (currentHistory.length > _maxHistorySize) {
        currentHistory.removeRange(_maxHistorySize, currentHistory.length);
      }
      
      // Guardar
      await prefs.setString(_key, jsonEncode(currentHistory));
    } catch (e) {
      // print('Error guardando en historial: $e');
    }
  }

  // Limpiar historial
  static Future<void> clearHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (e) {
      // print('Error limpiando historial: $e');
    }
  }

  // Buscar en el historial
  static Future<List<String>> searchInHistory(String query) async {
    try {
      final history = await getHistory();
      if (query.trim().isEmpty) return history;
      
      return history
          .where((item) => item.toLowerCase().contains(query.toLowerCase()))
          .toList();
    } catch (e) {
      // print('Error buscando en historial: $e');
      return [];
    }
  }
} 