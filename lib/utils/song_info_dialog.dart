import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'package:on_audio_query/on_audio_query.dart';
import '../utils/theme_preferences.dart';
import '../screens/song_info_screen.dart';

class SongInfoDialog {
  static Future<void> show(
    BuildContext context,
    MediaItem mediaItem,
    ValueNotifier<AppColorScheme> colorSchemeNotifier,
  ) async {
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            SongInfoScreen(mediaItem: mediaItem),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(1.0, 0.0);
          const end = Offset.zero;
          const curve = Curves.ease;
          final tween = Tween(
            begin: begin,
            end: end,
          ).chain(CurveTween(curve: curve));
          return SlideTransition(
            position: animation.drive(tween),
            child: child,
          );
        },
      ),
    );
  }

  // Sobrecarga para SongModel
  static Future<void> showFromSong(
    BuildContext context,
    SongModel song,
    ValueNotifier<AppColorScheme> colorSchemeNotifier,
  ) async {
    // Convert SongModel to MediaItem
    final mediaItem = MediaItem(
      id: song.id.toString(),
      title: song.title,
      artist: song.artist,
      album: song.album,
      duration: Duration(milliseconds: song.duration ?? 0),
      // Use standard extras format for path
      extras: {'data': song.data, 'songId': song.id},
    );

    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            SongInfoScreen(mediaItem: mediaItem),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(1.0, 0.0);
          const end = Offset.zero;
          const curve = Curves.ease;
          final tween = Tween(
            begin: begin,
            end: end,
          ).chain(CurveTween(curve: curve));
          return SlideTransition(
            position: animation.drive(tween),
            child: child,
          );
        },
      ),
    );
  }
}
