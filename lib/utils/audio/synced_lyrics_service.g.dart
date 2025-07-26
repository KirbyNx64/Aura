// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'synced_lyrics_service.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class LyricsDataAdapter extends TypeAdapter<LyricsData> {
  @override
  final int typeId = 0;

  @override
  LyricsData read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return LyricsData(
      id: fields[0] as String,
      synced: fields[1] as String?,
      plainLyrics: fields[2] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, LyricsData obj) {
    writer
      ..writeByte(3)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.synced)
      ..writeByte(2)
      ..write(obj.plainLyrics);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LyricsDataAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
