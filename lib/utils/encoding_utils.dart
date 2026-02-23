import 'dart:convert';
import 'package:on_audio_query/on_audio_query.dart';

/// Corrige mojibake: texto que era UTF-8 pero fue leído como Latin-1 (p. ej. por
/// MediaStore/on_audio_query). Ej.: "Â¿Por QuÃ©" → "¿Por Qué".
String fixUtf8Mojibake(String s) {
  if (s.isEmpty) return s;
  try {
    return utf8.decode(latin1.encode(s));
  } catch (_) {
    return s;
  }
}

/// Extensión para usar título, artista y álbum de [SongModel] con codificación
/// corregida cuando el índice (MediaStore/on_audio_query) devuelve mojibake.
extension SongModelEncoding on SongModel {
  String get displayTitle => fixUtf8Mojibake(title);
  String get displayArtist => fixUtf8Mojibake(artist ?? '');
  String get displayAlbum => fixUtf8Mojibake(album ?? '');
}
