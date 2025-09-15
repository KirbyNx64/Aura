import 'package:hive/hive.dart';
import 'package:on_audio_query/on_audio_query.dart';

class ArtistsDB {
  static final ArtistsDB _instance = ArtistsDB._internal();
  factory ArtistsDB() => _instance;
  ArtistsDB._internal();

  Box<Map<String, dynamic>>? _box;

  Future<Box<Map<String, dynamic>>> get box async {
    if (_box != null) return _box!;
    _box = await Hive.openBox<Map<String, dynamic>>('artists_index');
    return _box!;
  }

  /// Verifica si la base de datos necesita ser indexada
  Future<bool> needsIndexing() async {
    final b = await box;
    return b.isEmpty;
  }

  /// Indexa todos los artistas desde las canciones
  Future<void> indexArtists(List<SongModel> songs) async {
    // print('🎵 ArtistsDB: Iniciando indexación con ${songs.length} canciones');
    final b = await box;
    await b.clear();

    // Contar canciones por artista
    final Map<String, List<SongModel>> artistSongs = {};
    int ignoredCount = 0;
    
    for (final song in songs) {
      final artist = song.artist ?? 'Artista desconocido';
      
      // Log para depuración - mostrar algunos nombres de artistas
      if (ignoredCount < 5) {
        // print('🎵 ArtistsDB: Procesando artista: "$artist"');
      }
      
      // Ignorar artistas desconocidos o vacíos
      if (artist.isEmpty || 
          artist.toLowerCase() == 'unknown' || 
          artist.toLowerCase() == 'unknown artist' ||
          artist.toLowerCase() == 'artista desconocido' ||
          artist.toLowerCase() == 'unknown artist' ||
          artist.toLowerCase() == 'desconocido' ||
          artist.toLowerCase().contains('unknown') ||
          artist.toLowerCase().contains('desconocido') ||
          artist.trim().isEmpty) {
        ignoredCount++;
        continue;
      }
      
      if (artistSongs.containsKey(artist)) {
        artistSongs[artist]!.add(song);
      } else {
        artistSongs[artist] = [song];
      }
    }
    
    // print('🎵 ArtistsDB: Ignorados $ignoredCount artistas desconocidos');

    // print('🎵 ArtistsDB: Encontrados ${artistSongs.length} artistas únicos');

    // Guardar artistas con sus canciones usando hash como clave
    int artistId = 0;
    for (final entry in artistSongs.entries) {
      final artist = entry.key;
      final songs = entry.value;
      
      // Obtener la primera canción del artista para usar su portada
      final firstSong = songs.first;
      
      // Usar un ID numérico como clave para evitar el límite de 255 caracteres
      final key = 'artist_$artistId';
      
      await b.put(key, {
        'name': artist,
        'song_count': songs.length,
        'first_song_path': firstSong.data,
        'first_song_id': firstSong.id,
        'songs': songs.map((s) => s.data).toList(),
      });
      
      artistId++;
    }
    
    // print('🎵 ArtistsDB: Indexación completada, ${artistSongs.length} artistas guardados');
  }

  /// Obtiene los artistas más populares (con más canciones)
  Future<List<Map<String, dynamic>>> getTopArtists({int limit = 20}) async {
    try {
      // print('🎵 ArtistsDB: Obteniendo top artistas (límite: $limit)');
      final b = await box;
      final artists = <Map<String, dynamic>>[];
      
      // print('🎵 ArtistsDB: Total de artistas en DB: ${b.length}');
      
      for (final value in b.values) {
        try {
          // Convertir de Map<dynamic, dynamic> a Map<String, dynamic> de forma segura
          final artistData = <String, dynamic>{};
          for (final entry in (value as Map).entries) {
            artistData[entry.key.toString()] = entry.value;
          }
          
          final artistName = artistData['name'] as String? ?? '';
          
          // Filtrar artistas desconocidos también en la recuperación
          if (artistName.isNotEmpty && 
              !artistName.toLowerCase().contains('unknown') &&
              !artistName.toLowerCase().contains('desconocido') &&
              artistName.trim().isNotEmpty) {
            artists.add(artistData);
          }
        } catch (e) {
          // print('🎵 ArtistsDB: Error procesando artista: $e');
          continue;
        }
      }
      
      // Ordenar por cantidad de canciones (descendente)
      artists.sort((a, b) => (b['song_count'] as int).compareTo(a['song_count'] as int));
      
      final result = artists.take(limit).toList();
      // print('🎵 ArtistsDB: Retornando ${result.length} artistas (después de filtrar desconocidos)');
      
      return result;
    } catch (e) {
      // print('🎵 ArtistsDB: Error en getTopArtists: $e');
      return [];
    }
  }

  /// Obtiene las canciones de un artista específico
  Future<List<String>> getArtistSongs(String artistName) async {
    final b = await box;
    
    // Buscar el artista por nombre en todos los valores
    for (final value in b.values) {
      // Convertir de Map<dynamic, dynamic> a Map<String, dynamic> de forma segura
      final artistData = <String, dynamic>{};
      for (final entry in (value as Map).entries) {
        artistData[entry.key.toString()] = entry.value;
      }
      
      if (artistData['name'] == artistName) {
        return List<String>.from(artistData['songs'] ?? []);
      }
    }
    
    return [];
  }

  /// Obtiene información de un artista específico
  Future<Map<String, dynamic>?> getArtistInfo(String artistName) async {
    final b = await box;
    
    // Buscar el artista por nombre en todos los valores
    for (final value in b.values) {
      // Convertir de Map<dynamic, dynamic> a Map<String, dynamic> de forma segura
      final artistData = <String, dynamic>{};
      for (final entry in (value as Map).entries) {
        artistData[entry.key.toString()] = entry.value;
      }
      
      if (artistData['name'] == artistName) {
        return artistData;
      }
    }
    
    return null;
  }

  /// Limpia la base de datos
  Future<void> clear() async {
    final b = await box;
    await b.clear();
  }

  /// Fuerza la reindexación
  Future<void> forceReindex(List<SongModel> songs) async {
    await clear();
    await indexArtists(songs);
  }
}
