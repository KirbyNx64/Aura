import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:music/utils/db/recent_db.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<SongModel> _recentSongs = [];
  bool _showingRecents = false;

  Future<void> _loadRecents() async {
    try {
      final recents = await RecentsDB().getRecents();
      setState(() {
        _recentSongs = recents;
        _showingRecents = true;
      });
    } catch (e) {
      setState(() {
        _recentSongs = [];
        _showingRecents = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_showingRecents ? 'Canciones recientes' : 'Listas'),
      ),
      body: _showingRecents
          ? _recentSongs.isEmpty
                ? const Center(child: Text('No hay canciones recientes'))
                : ListView.builder(
                    itemCount: _recentSongs.length,
                    itemBuilder: (context, index) {
                      final song = _recentSongs[index];
                      return ListTile(
                        leading: QueryArtworkWidget(
                          id: song.id,
                          type: ArtworkType.AUDIO,
                          nullArtworkWidget: const Icon(Icons.music_note),
                        ),
                        title: Text(song.title),
                        subtitle: Text(
                          (song.artist?.trim().isEmpty ?? true)
                              ? 'Desconocido'
                              : song.artist!,
                        ),
                        onTap: () async {
                          await RecentsDB().addRecentPath(song.data);
                          // Aquí podrías iniciar la reproducción
                        },
                      );
                    },
                  )
          : Center(
              child: ElevatedButton.icon(
                icon: const Icon(Icons.history),
                label: const Text('Canciones recientes'),
                onPressed: _loadRecents,
              ),
            ),
    );
  }
}
