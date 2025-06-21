import 'package:youtube_explode_dart/youtube_explode_dart.dart';

enum Codec { mp4a, opus }

class StreamProvider {
  final bool playable;
  final List<Audio>? audioFormats;
  final String statusMSG;

  StreamProvider({
    required this.playable,
    this.audioFormats,
    this.statusMSG = "",
  });

  static StreamProvider fromManifest(StreamManifest manifest) {
    final audio = manifest.audioOnly;
    return StreamProvider(
      playable: true,
      statusMSG: "OK",
      audioFormats: audio
          .map(
            (e) => Audio(
              itag: e.tag,
              audioCodec: e.audioCodec.contains('mp') ? Codec.mp4a : Codec.opus,
              bitrate: e.bitrate.bitsPerSecond,
              duration: 0,
              loudnessDb: 0.0,
              url: e.url.toString(),
              size: e.size.totalBytes,
            ),
          )
          .toList(),
    );
  }

  Audio? get highestBitrateMp4aAudio => audioFormats?.lastWhere(
    (item) => item.itag == 140 || item.itag == 139,
    orElse: () => audioFormats!.first,
  );

  Audio? get highestBitrateOpusAudio => audioFormats?.lastWhere(
    (item) => item.itag == 251 || item.itag == 250,
    orElse: () => audioFormats!.first,
  );
}

class Audio {
  final int itag;
  final Codec audioCodec;
  final int bitrate;
  final int duration;
  final int size;
  final double loudnessDb;
  final String url;

  Audio({
    required this.itag,
    required this.audioCodec,
    required this.bitrate,
    required this.duration,
    required this.loudnessDb,
    required this.url,
    required this.size,
  });
}
