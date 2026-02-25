import 'package:hive_ce/hive_ce.dart';

part 'download_history_model.g.dart';

@HiveType(typeId: 2)
class DownloadHistoryModel extends HiveObject {
  @HiveField(0)
  String path;

  @HiveField(1)
  String artist;

  @HiveField(2)
  String title;

  @HiveField(3)
  int duration;

  @HiveField(4)
  String videoId;

  DownloadHistoryModel({
    required this.path,
    required this.artist,
    required this.title,
    required this.duration,
    required this.videoId,
  });
}
