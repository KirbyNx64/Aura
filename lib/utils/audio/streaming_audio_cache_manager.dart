import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Gestiona el caché de audio en disco para reproducción vía streaming.
///
/// Estrategia:
/// - Los archivos se almacenan en `<tempDir>/aura_stream_audio/<videoId>.aac`
/// - Límite de tamaño configurable (default 1 GB)
/// - Si un solo archivo supera el 80% del límite → no se cachea (fallback a streaming)
/// - Limpieza LRU: borra los archivos menos usados (por lastModified) hasta
///   que el total baje del límite
class StreamingAudioCacheManager {
  static const String _prefKey = 'stream_audio_cache_limit_mb';
  static const int defaultLimitMb = 1024; // 1 GB
  static const double _maxSingleFileRatio = 0.8;
  static const String _cacheDirName = 'aura_stream_audio';

  /// Proveedor dinámico opcional de IDs activos/protegidos (ej. canción actual y siguiente en cola).
  static Set<String> Function()? activeVideoIdsProvider;

  /// IDs protegidos manualmente contra la eliminación por LRU.
  static final Set<String> _protectedVideoIds = <String>{};

  /// Agrega un videoId a la lista protegida contra eliminación.
  static void protectVideoId(String? videoId) {
    if (videoId != null && videoId.trim().isNotEmpty) {
      _protectedVideoIds.add(videoId.trim());
    }
  }

  /// Remueve un videoId de la lista protegida.
  static void unprotectVideoId(String? videoId) {
    if (videoId != null) {
      _protectedVideoIds.remove(videoId.trim());
    }
  }

  /// Actualiza la fecha de modificación del archivo al momento actual (LRU touch).
  /// Esto asegura que una canción reproducida desde la caché pase al final
  /// de la lista de eliminación (es la más recientemente usada).
  static Future<void> touch(String videoId) async {
    try {
      final file = await getCacheFile(videoId);
      if (file.existsSync()) {
        await file.setLastModified(DateTime.now());
      }
    } catch (_) {}
  }

  // ─────────────────────────────────────────
  //  Configuración
  // ─────────────────────────────────────────

  /// Devuelve el límite actual en MB. -1 = sin límite, 0 = sin caché.
  static Future<int> getLimitMb() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_prefKey) ?? defaultLimitMb;
  }

  /// Persiste el límite en MB. Usar null para "sin límite" (guarda -1).
  static Future<void> setLimitMb(int? mb) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefKey, mb ?? -1);
  }

  // ─────────────────────────────────────────
  //  Directorio y archivos
  // ─────────────────────────────────────────

  /// Directorio raíz del caché de audio.
  static Future<Directory> getCacheDir() async {
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/$_cacheDirName');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Archivo de caché para un videoId dado.
  static Future<File> getCacheFile(String videoId) async {
    final dir = await getCacheDir();
    return File('${dir.path}/$videoId.aac');
  }

  /// Archivo de metadatos (.meta) para un videoId dado.
  /// Contiene el tamaño esperado (Content-Length) del audio completo.
  static Future<File> getMetaFile(String videoId) async {
    final dir = await getCacheDir();
    return File('${dir.path}/$videoId.meta');
  }

  /// Guarda el tamaño esperado del archivo de audio en el .meta sidecar.
  static Future<void> saveExpectedSize(String videoId, int expectedBytes) async {
    try {
      final meta = await getMetaFile(videoId);
      await meta.writeAsString(expectedBytes.toString());
    } catch (_) {}
  }

  /// Lee el tamaño esperado guardado en el .meta sidecar.
  /// Retorna null si el archivo no existe o no es válido.
  static Future<int?> readExpectedSize(String videoId) async {
    try {
      final meta = await getMetaFile(videoId);
      if (!meta.existsSync()) return null;
      final raw = await meta.readAsString();
      return int.tryParse(raw.trim());
    } catch (_) {
      return null;
    }
  }

  /// Retorna true solo si el archivo de caché existe Y su tamaño coincide
  /// con el Content-Length registrado en el .meta sidecar.
  ///
  /// Si no hay .meta (descarga antigua), se considera completo para no
  /// romper archivos ya cacheados correctamente en versiones anteriores.
  static Future<bool> isCacheComplete(String videoId) async {
    try {
      final cacheFile = await getCacheFile(videoId);
      if (!cacheFile.existsSync() || cacheFile.lengthSync() == 0) return false;

      final expectedSize = await readExpectedSize(videoId);
      if (expectedSize == null) {
        // Sin metadatos: descarga de versión anterior, asumir completo.
        return true;
      }
      return cacheFile.lengthSync() >= expectedSize;
    } catch (_) {
      return false;
    }
  }

  /// Borra el archivo .aac y su .meta sidecar si el caché está incompleto.
  /// Retorna true si se borró algo, false si estaba completo o no existía.
  static Future<bool> deleteIfIncomplete(String videoId) async {
    try {
      final complete = await isCacheComplete(videoId);
      if (complete) return false;

      final cacheFile = await getCacheFile(videoId);
      final metaFile = await getMetaFile(videoId);
      try { if (cacheFile.existsSync()) cacheFile.deleteSync(); } catch (_) {}
      try { if (metaFile.existsSync()) metaFile.deleteSync(); } catch (_) {}
      return true;
    } catch (_) {
      return false;
    }
  }

  // ─────────────────────────────────────────
  //  Decisión de cachear
  // ─────────────────────────────────────────

  /// Devuelve true si el videoId debe reproducirse con LockCachingAudioSource.
  ///
  /// Devuelve false si:
  /// - El límite es 0 (caché deshabilitado)
  /// - El archivo ya existe en disco y supera el 80% del límite configurado
  static Future<bool> shouldCache(String videoId) async {
    final limitMb = await getLimitMb();
    if (limitMb == 0) return false;
    if (limitMb == -1) return true; // sin límite

    final limitBytes = limitMb * 1024 * 1024;
    final maxSingleBytes = (limitBytes * _maxSingleFileRatio).round();

    final file = await getCacheFile(videoId);
    if (file.existsSync()) {
      final size = file.lengthSync();
      if (size > maxSingleBytes) return false;
    }
    return true;
  }

  // ─────────────────────────────────────────
  //  Limpieza LRU
  // ─────────────────────────────────────────

  /// Limpia el caché si el tamaño total supera el límite configurado.
  ///
  /// Ordena los archivos por fecha de modificación (los más viejos primero)
  /// y los borra hasta que el total esté por debajo del límite.
  ///
  /// NUNCA borra archivos cuyos videoIds estén en [preserveVideoIds],
  /// en [_protectedVideoIds] o provistos por [activeVideoIdsProvider].
  static Future<void> evictIfNeeded({
    Iterable<String>? preserveVideoIds,
  }) async {
    try {
      final limitMb = await getLimitMb();
      if (limitMb == -1) return; // sin límite
      if (limitMb == 0) {
        await clearAll(preserveActive: true);
        return;
      }

      final limitBytes = limitMb * 1024 * 1024;
      final dir = await getCacheDir();
      if (!dir.existsSync()) return;

      final files = dir.listSync().whereType<File>().toList();
      if (files.isEmpty) return;

      int totalBytes = 0;
      for (final f in files) {
        try { totalBytes += f.lengthSync(); } catch (_) {}
      }

      if (totalBytes <= limitBytes) return;

      // Consolidar todos los IDs protegidos de eliminación
      final protected = <String>{
        ...?preserveVideoIds?.map((id) => id.trim()),
        ..._protectedVideoIds,
        ...?activeVideoIdsProvider?.call().map((id) => id.trim()),
      }..removeWhere((id) => id.isEmpty);

      // LRU: ordenar por lastModified ascendente (más viejos primero)
      files.sort((a, b) {
        final aTime = a.statSync().modified;
        final bTime = b.statSync().modified;
        return aTime.compareTo(bTime);
      });

      for (final f in files) {
        if (totalBytes <= limitBytes) break;

        // Solo considerar .aac para el cálculo de espacio
        if (!f.path.endsWith('.aac')) continue;

        final videoId = _extractVideoIdFromPath(f.path);
        if (videoId != null && protected.contains(videoId)) {
          // Proteger canción en reproducción o en cola
          continue;
        }

        try {
          final size = f.lengthSync();
          f.deleteSync();
          totalBytes -= size;
          // Borrar también el .meta sidecar si existe
          try {
            final dir = f.parent;
            final meta = File('${dir.path}/${videoId ?? ''}.meta');
            if (meta.existsSync()) meta.deleteSync();
          } catch (_) {}
        } catch (_) {}
      }
    } catch (_) {
      // Silenciar errores para no interrumpir reproducción
    }
  }

  static String? _extractVideoIdFromPath(String path) {
    final filename = path.split(Platform.pathSeparator).last;
    if (filename.endsWith('.aac')) {
      return filename.substring(0, filename.length - 4);
    }
    return null;
  }

  // ─────────────────────────────────────────
  //  Estadísticas
  // ─────────────────────────────────────────

  /// Retorna el uso actual del caché: bytes usados y cantidad de archivos.
  static Future<({int usedBytes, int fileCount})> getStats() async {
    try {
      final dir = await getCacheDir();
      if (!dir.existsSync()) return (usedBytes: 0, fileCount: 0);

      final files = dir.listSync().whereType<File>().toList();
      int totalBytes = 0;
      for (final f in files) {
        try { totalBytes += f.lengthSync(); } catch (_) {}
      }
      return (usedBytes: totalBytes, fileCount: files.length);
    } catch (_) {
      return (usedBytes: 0, fileCount: 0);
    }
  }

  // ─────────────────────────────────────────
  //  Limpieza completa
  // ─────────────────────────────────────────

  /// Borra todos los archivos del caché de audio.
  /// Si [preserveActive] es true, conserva las canciones en reproducción o protegidas.
  static Future<void> clearAll({bool preserveActive = false}) async {
    try {
      final dir = await getCacheDir();
      if (!dir.existsSync()) return;

      if (!preserveActive) {
        await dir.delete(recursive: true);
        return;
      }

      final protected = <String>{
        ..._protectedVideoIds,
        ...?activeVideoIdsProvider?.call().map((id) => id.trim()),
      }..removeWhere((id) => id.isEmpty);

      final files = dir.listSync().whereType<File>().toList();
      for (final f in files) {
        // Para .aac verificar si está protegido; para .meta borrar junto con .aac
        final videoId = _extractVideoIdFromPath(f.path);
        if (videoId != null && protected.contains(videoId)) {
          continue;
        }
        // Si es .meta y su .aac está protegido, también proteger el .meta
        if (f.path.endsWith('.meta')) {
          final metaBasename = f.path.split(Platform.pathSeparator).last;
          final metaVideoId = metaBasename.substring(0, metaBasename.length - 5);
          if (protected.contains(metaVideoId)) continue;
        }
        try {
          f.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }

  // ─────────────────────────────────────────
  //  Helpers de formato
  // ─────────────────────────────────────────

  /// Formatea bytes en cadena legible (ej. "342 MB", "1.2 GB").
  static String formatBytes(int bytes) {
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    } else if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    } else {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
  }

  /// Formatea el límite en MB en cadena legible (-1 → "∞").
  static String formatLimit(int limitMb) {
    if (limitMb == -1) return '∞';
    if (limitMb < 1024) return '$limitMb MB';
    final gb = limitMb / 1024;
    return '${gb % 1 == 0 ? gb.toStringAsFixed(0) : gb.toStringAsFixed(1)} GB';
  }
}
