class DownloadRecord {
  final int? id;
  final String title;
  final String artist;
  final String filePath;
  final String fileName;
  final int fileSize;
  final String downloadUrl;
  final String thumbnailUrl;
  final DateTime downloadDate;
  final String status; // 'completed', 'failed', 'downloading'
  final String? errorMessage;
  final bool viewed; // true si el usuario ya vio esta descarga

  DownloadRecord({
    this.id,
    required this.title,
    required this.artist,
    required this.filePath,
    required this.fileName,
    required this.fileSize,
    required this.downloadUrl,
    required this.thumbnailUrl,
    required this.downloadDate,
    required this.status,
    this.errorMessage,
    this.viewed = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'file_path': filePath,
      'file_name': fileName,
      'file_size': fileSize,
      'download_url': downloadUrl,
      'thumbnail_url': thumbnailUrl,
      'download_date': downloadDate.millisecondsSinceEpoch,
      'status': status,
      'error_message': errorMessage,
      'viewed': viewed ? 1 : 0,
    };
  }

  factory DownloadRecord.fromMap(Map<String, dynamic> map) {
    return DownloadRecord(
      id: map['id'],
      title: map['title'],
      artist: map['artist'],
      filePath: map['file_path'],
      fileName: map['file_name'],
      fileSize: map['file_size'],
      downloadUrl: map['download_url'],
      thumbnailUrl: map['thumbnail_url'],
      downloadDate: DateTime.fromMillisecondsSinceEpoch(map['download_date']),
      status: map['status'],
      errorMessage: map['error_message'],
      viewed: (map['viewed'] ?? 0) == 1,
    );
  }

  DownloadRecord copyWith({
    int? id,
    String? title,
    String? artist,
    String? filePath,
    String? fileName,
    int? fileSize,
    String? downloadUrl,
    String? thumbnailUrl,
    DateTime? downloadDate,
    String? status,
    String? errorMessage,
    bool? viewed,
  }) {
    return DownloadRecord(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      filePath: filePath ?? this.filePath,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      downloadUrl: downloadUrl ?? this.downloadUrl,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      downloadDate: downloadDate ?? this.downloadDate,
      status: status ?? this.status,
      errorMessage: errorMessage ?? this.errorMessage,
      viewed: viewed ?? this.viewed,
    );
  }
}
