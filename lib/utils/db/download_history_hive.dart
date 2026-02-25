import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'download_history_model.dart';

class DownloadHistoryHive {
  static const String _boxName = 'download_history_box';
  static Box<DownloadHistoryModel>? _box;

  static Future<Box<DownloadHistoryModel>> get box async {
    if (_box != null) return _box!;
    _box = await Hive.openBox<DownloadHistoryModel>(_boxName);
    return _box!;
  }

  static Future<void> addDownload({
    required String path,
    required String artist,
    required String title,
    required int duration,
    required String videoId,
  }) async {
    final b = await box;
    final download = DownloadHistoryModel(
      path: path,
      artist: artist,
      title: title,
      duration: duration,
      videoId: videoId,
    );
    await b.add(download);
  }

  static Future<List<DownloadHistoryModel>> getAllDownloads() async {
    final b = await box;
    return b.values.toList();
  }

  static Future<void> deleteDownload(int index) async {
    final b = await box;
    await b.deleteAt(index);
  }

  static Future<DownloadHistoryModel?> getDownloadByPath(String path) async {
    final b = await box;
    try {
      return b.values.firstWhere((d) => d.path == path);
    } catch (e) {
      return null;
    }
  }

  static Future<DownloadHistoryModel?> getDownloadByVideoId(
    String videoId,
  ) async {
    final normalized = videoId.trim();
    if (normalized.isEmpty) return null;

    final b = await box;
    try {
      return b.values.firstWhere((d) => d.videoId == normalized);
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearAll() async {
    final b = await box;
    await b.clear();
  }
}
