// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'download_history_model.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class DownloadHistoryModelAdapter extends TypeAdapter<DownloadHistoryModel> {
  @override
  final typeId = 2;

  @override
  DownloadHistoryModel read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return DownloadHistoryModel(
      path: fields[0] as String,
      artist: fields[1] as String,
      title: fields[2] as String,
      duration: (fields[3] as num).toInt(),
      videoId: fields[4] as String,
    );
  }

  @override
  void write(BinaryWriter writer, DownloadHistoryModel obj) {
    writer
      ..writeByte(5)
      ..writeByte(0)
      ..write(obj.path)
      ..writeByte(1)
      ..write(obj.artist)
      ..writeByte(2)
      ..write(obj.title)
      ..writeByte(3)
      ..write(obj.duration)
      ..writeByte(4)
      ..write(obj.videoId);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadHistoryModelAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
