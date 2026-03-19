import 'package:flutter/material.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/main.dart'
    show
        AudioHandlerSafeCast,
        audioHandler,
        audioServiceReady,
        getAudioServiceSafely,
        initializeAudioServiceSafely,
        overlayVisibleNotifier;
import 'package:music/utils/db/recent_db.dart';
import 'package:music/utils/db/discovery_found_db.dart';
import 'package:music/utils/db/favorites_db.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/yt_search/service.dart' as yt_service;
import 'package:music/utils/simple_yt_download.dart';
import 'package:music/utils/song_info_dialog.dart';
import 'package:music/screens/artist/artist_screen.dart';
import 'dart:async';
import 'dart:math';
import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:mini_music_visualizer/mini_music_visualizer.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

class HomeDiscoveryScreen extends StatefulWidget {
  const HomeDiscoveryScreen({super.key});

  @override
  State<HomeDiscoveryScreen> createState() => _HomeDiscoveryScreenState();
}

class _StreamingSeed {
  final String videoId;
  final String title;
  final String artist;
  final String artUri;

  const _StreamingSeed({
    required this.videoId,
    required this.title,
    required this.artist,
    required this.artUri,
  });
}

class _RadioTrack {
  final String videoId;
  final String title;
  final String artist;
  final String artUri;
  final int? durationMs;

  const _RadioTrack({
    required this.videoId,
    required this.title,
    required this.artist,
    required this.artUri,
    this.durationMs,
  });
}

class _HomeDiscoveryScreenState extends State<HomeDiscoveryScreen> {
  static const Duration _discoveryRefreshInterval = Duration(hours: 24);
  final Random _random = Random();

  bool _isLoading = true;
  String? _error;
  _StreamingSeed? _seed;
  List<_RadioTrack> _radioTracks = const [];
  MediaItem? _currentMediaItem;
  bool _isPlaying = false;
  StreamSubscription<MediaItem?>? _mediaItemSub;
  StreamSubscription<PlaybackState>? _playbackSub;

  void _onCoverQualityChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _loadDiscoveryData();
    _currentMediaItem = audioHandler?.mediaItem.valueOrNull;
    _isPlaying = audioHandler?.playbackState.valueOrNull?.playing ?? false;
    _mediaItemSub = audioHandler?.mediaItem.listen((item) {
      if (!mounted) return;
      final oldId = _currentMediaItem?.id;
      final newId = item?.id;
      if (oldId != newId) {
        setState(() {
          _currentMediaItem = item;
        });
      }
    });
    _playbackSub = audioHandler?.playbackState.listen((state) {
      if (!mounted) return;
      if (_isPlaying != state.playing) {
        setState(() {
          _isPlaying = state.playing;
        });
      }
    });
    coverQualityNotifier.addListener(_onCoverQualityChanged);
  }

  @override
  void dispose() {
    coverQualityNotifier.removeListener(_onCoverQualityChanged);
    _mediaItemSub?.cancel();
    _playbackSub?.cancel();
    super.dispose();
  }

  String _currentStreamingCoverQuality() {
    final quality = coverQualityNotifier.value;
    if (quality == 'high' || quality == 'medium' || quality == 'low') {
      return quality;
    }
    return 'medium';
  }

  String _ytThumbFileForQuality(String quality) {
    switch (quality) {
      case 'medium':
        return 'sddefault.jpg';
      case 'low':
        return 'hqdefault.jpg';
      default:
        return 'maxresdefault.jpg';
    }
  }

  String _googleThumbSizeForQuality(String quality) {
    switch (quality) {
      case 'medium':
        return 's600';
      case 'low':
        return 's300';
      default:
        return 's1200';
    }
  }

  String _qualityFallbackArtworkUrl(String videoId) {
    final qualityFile = _ytThumbFileForQuality(_currentStreamingCoverQuality());
    return 'https://i.ytimg.com/vi/$videoId/$qualityFile';
  }

  String? _applyStreamingArtworkQuality(String? rawUrl, {String? videoId}) {
    final normalized = rawUrl?.trim();
    if (normalized == null || normalized.isEmpty || normalized == 'null') {
      return null;
    }

    final quality = _currentStreamingCoverQuality();
    final lower = normalized.toLowerCase();

    if (lower.contains('googleusercontent.com')) {
      final size = _googleThumbSizeForQuality(quality);
      final replaced = normalized.replaceFirst(RegExp(r'=s\d+\b'), '=$size');
      if (replaced != normalized) return replaced;

      final eqIndex = normalized.lastIndexOf('=');
      if (eqIndex != -1 && eqIndex < normalized.length - 1) {
        final suffix = normalized.substring(eqIndex + 1);
        if (!suffix.contains('/')) {
          return '${normalized.substring(0, eqIndex + 1)}$size';
        }
      }
      return '$normalized=$size';
    }

    final uri = Uri.tryParse(normalized);
    if (uri == null) return normalized;

    final host = uri.host.toLowerCase();
    if (!host.contains('ytimg.com') && !host.contains('img.youtube.com')) {
      return normalized;
    }

    final qualityFile = _ytThumbFileForQuality(quality);
    final qualityWebp = qualityFile.replaceAll('.jpg', '.webp');
    final segments = List<String>.from(uri.pathSegments);

    if (segments.isNotEmpty) {
      final last = segments.last.toLowerCase();
      final isKnownThumb =
          last.contains('maxresdefault') ||
          last.contains('sddefault') ||
          last.contains('hqdefault') ||
          last.contains('mqdefault');
      if (isKnownThumb) {
        final useWebp = last.endsWith('.webp');
        segments[segments.length - 1] = useWebp ? qualityWebp : qualityFile;
        return uri.replace(pathSegments: segments).toString();
      }
    }

    final id = videoId?.trim();
    if (id != null && id.isNotEmpty) {
      return _qualityFallbackArtworkUrl(id);
    }

    return normalized;
  }

  String? _extractVideoIdFromPath(String path) {
    final normalized = path.trim();
    if (normalized.isEmpty) return null;
    if (normalized.startsWith('yt:')) {
      final id = normalized.substring(3).trim();
      return id.isEmpty ? null : id;
    }
    return null;
  }

  Future<List<_StreamingSeed>> _loadStreamingSeedsFromRecents() async {
    final paths = await RecentsDB().getRecentPaths();
    final seeds = <_StreamingSeed>[];
    final seen = <String>{};

    for (final path in paths) {
      final meta = await RecentsDB().getRecentMeta(path);
      final metaVideoId = meta?['videoId']?.toString().trim();
      final pathVideoId = _extractVideoIdFromPath(path);
      final videoId = (metaVideoId != null && metaVideoId.isNotEmpty)
          ? metaVideoId
          : pathVideoId;
      if (videoId == null || videoId.isEmpty) continue;
      if (!seen.add(videoId)) continue;

      final titleRaw = meta?['title']?.toString().trim();
      final artistRaw = meta?['artist']?.toString().trim();
      final artUriRaw = meta?['artUri']?.toString().trim();

      seeds.add(
        _StreamingSeed(
          videoId: videoId,
          title: (titleRaw != null && titleRaw.isNotEmpty)
              ? titleRaw
              : LocaleProvider.tr('title_unknown'),
          artist: (artistRaw != null && artistRaw.isNotEmpty)
              ? artistRaw
              : LocaleProvider.tr('artist_unknown'),
          artUri: (artUriRaw != null && artUriRaw.isNotEmpty)
              ? artUriRaw
              : _qualityFallbackArtworkUrl(videoId),
        ),
      );
    }

    return seeds;
  }

  _StreamingSeed? _seedFromMap(Map<String, dynamic>? raw) {
    if (raw == null) return null;
    final videoId = raw['videoId']?.toString().trim() ?? '';
    if (videoId.isEmpty) return null;
    final title = raw['title']?.toString().trim() ?? '';
    final artist = raw['artist']?.toString().trim() ?? '';
    final artUri = raw['artUri']?.toString().trim() ?? '';

    return _StreamingSeed(
      videoId: videoId,
      title: title.isNotEmpty ? title : LocaleProvider.tr('title_unknown'),
      artist: artist.isNotEmpty ? artist : LocaleProvider.tr('artist_unknown'),
      artUri: artUri.isNotEmpty ? artUri : _qualityFallbackArtworkUrl(videoId),
    );
  }

  Future<List<_RadioTrack>> _loadCachedTracks() async {
    final paths = await DiscoveryFoundDB().getFoundPaths();
    final tracks = <_RadioTrack>[];
    final seenIds = <String>{};

    for (final path in paths) {
      final map = await DiscoveryFoundDB().getFoundMeta(path);
      if (map == null) continue;
      final videoId = map['videoId']?.toString().trim();
      if (videoId == null || videoId.isEmpty) continue;
      if (!seenIds.add(videoId)) continue;

      final title = map['title']?.toString().trim();
      final artist = map['artist']?.toString().trim();
      final artUri = map['artUri']?.toString().trim();
      final durationMs = map['durationMs'] is int
          ? map['durationMs'] as int
          : null;

      tracks.add(
        _RadioTrack(
          videoId: videoId,
          title: (title != null && title.isNotEmpty)
              ? title
              : LocaleProvider.tr('title_unknown'),
          artist: (artist != null && artist.isNotEmpty)
              ? artist
              : LocaleProvider.tr('artist_unknown'),
          artUri: (artUri != null && artUri.isNotEmpty)
              ? artUri
              : _qualityFallbackArtworkUrl(videoId),
          durationMs: durationMs,
        ),
      );
    }
    return tracks;
  }

  Future<void> _loadDiscoveryData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final seedMeta = await DiscoveryFoundDB().getSeedMeta();
      final cacheExpired = _isDiscoveryCacheExpired(seedMeta);
      final cachedSeed = cacheExpired ? null : _seedFromMap(seedMeta);
      final cachedTracks = cacheExpired
          ? const <_RadioTrack>[]
          : await _loadCachedTracks();

      if (!mounted) return;
      if (cachedSeed != null && cachedTracks.isNotEmpty) {
        setState(() {
          _seed = cachedSeed;
          _radioTracks = cachedTracks;
          _isLoading = false;
          _error = null;
        });
        return;
      }

      final seeds = await _loadStreamingSeedsFromRecents();
      if (!mounted) return;
      if (seeds.isEmpty) {
        setState(() {
          _seed = null;
          _radioTracks = const [];
          _isLoading = false;
          _error = null;
        });
        return;
      }

      final selectedSeed = seeds[_random.nextInt(seeds.length)];
      final radioPayload = await yt_service.getWatchRadioTracks(
        videoId: selectedSeed.videoId,
        limit: 30,
      );
      if (!mounted) return;

      final rawTracks = radioPayload['tracks'];
      final parsedTracks = <_RadioTrack>[];
      final seenRadioIds = <String>{};

      if (rawTracks is List) {
        for (final raw in rawTracks) {
          if (raw is! Map) continue;
          final videoId = raw['videoId']?.toString().trim();
          if (videoId == null || videoId.isEmpty) continue;
          if (!seenRadioIds.add(videoId)) continue;

          final titleRaw = raw['title']?.toString().trim();
          final artistRaw = raw['artist']?.toString().trim();
          final thumbRaw = raw['thumbUrl']?.toString().trim();
          final durationMsRaw = raw['durationMs'];
          final durationMs = durationMsRaw is int ? durationMsRaw : null;

          parsedTracks.add(
            _RadioTrack(
              videoId: videoId,
              title: (titleRaw != null && titleRaw.isNotEmpty)
                  ? titleRaw
                  : LocaleProvider.tr('title_unknown'),
              artist: (artistRaw != null && artistRaw.isNotEmpty)
                  ? artistRaw
                  : LocaleProvider.tr('artist_unknown'),
              artUri: (thumbRaw != null && thumbRaw.isNotEmpty)
                  ? thumbRaw
                  : _qualityFallbackArtworkUrl(videoId),
              durationMs: durationMs,
            ),
          );
        }
      }

      if (parsedTracks.isNotEmpty) {
        await DiscoveryFoundDB().saveFound(
          seed: <String, dynamic>{
            'videoId': selectedSeed.videoId,
            'title': selectedSeed.title,
            'artist': selectedSeed.artist,
            'artUri': selectedSeed.artUri,
          },
          tracks: parsedTracks
              .map(
                (track) => <String, dynamic>{
                  'videoId': track.videoId,
                  'title': track.title,
                  'artist': track.artist,
                  'artUri': track.artUri,
                  if (track.durationMs != null) 'durationMs': track.durationMs,
                },
              )
              .toList(),
        );
      }

      setState(() {
        _seed = selectedSeed;
        _radioTracks = parsedTracks;
        _isLoading = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = LocaleProvider.tr('check_internet_connection');
      });
    }
  }

  bool _isDiscoveryCacheExpired(Map<String, dynamic>? seedMeta) {
    if (seedMeta == null) return true;

    final rawUpdatedAt = seedMeta['updatedAt'];
    int? updatedAtMs;

    if (rawUpdatedAt is int) {
      updatedAtMs = rawUpdatedAt;
    } else if (rawUpdatedAt is num) {
      updatedAtMs = rawUpdatedAt.toInt();
    } else if (rawUpdatedAt is String) {
      updatedAtMs = int.tryParse(rawUpdatedAt.trim());
    }

    if (updatedAtMs == null || updatedAtMs <= 0) return true;

    final updatedAt = DateTime.fromMillisecondsSinceEpoch(updatedAtMs);
    return DateTime.now().difference(updatedAt) >= _discoveryRefreshInterval;
  }

  Future<void> _playRadioTrack(int index) async {
    if (index < 0 || index >= _radioTracks.length) return;
    if (playLoadingNotifier.value) return;

    playLoadingNotifier.value = true;
    openPlayerPanelNotifier.value = true;
    try {
      if (!audioServiceReady.value || audioHandler == null) {
        await initializeAudioServiceSafely();
      }
      if (!mounted) return;
      final handler = await getAudioServiceSafely();
      if (handler == null) return;

      final queueItems = _radioTracks
          .map(
            (track) => <String, dynamic>{
              'videoId': track.videoId,
              'title': track.title,
              'artist': track.artist,
              'artUri': track.artUri,
              if (track.durationMs != null && track.durationMs! > 0)
                'durationMs': track.durationMs,
            },
          )
          .toList();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'last_queue_source',
        LocaleProvider.tr('discovery'),
      );

      await handler
          .customAction('playYtStreamQueue', {
            'items': queueItems,
            'initialIndex': index,
            'autoPlay': true,
            'autoStartRadio': true,
          })
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      playLoadingNotifier.value = false;
    }
  }

  String _formatDuration(int? durationMs) {
    if (durationMs == null || durationMs <= 0) return '';
    final totalSeconds = durationMs ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString()}:${seconds.toString().padLeft(2, '0')}';
  }

  bool _isCurrentRadioTrack(_RadioTrack track) {
    final current = _currentMediaItem;
    if (current == null) return false;
    final currentVideoId = current.extras?['videoId']?.toString().trim();
    final videoId = track.videoId.trim();
    if (currentVideoId != null && currentVideoId.isNotEmpty) {
      return currentVideoId == videoId;
    }
    return current.id == 'yt:$videoId';
  }

  String _formatArtistWithDuration(_RadioTrack track) {
    final artist = track.artist.trim().isNotEmpty
        ? track.artist.trim()
        : LocaleProvider.tr('artist_unknown');
    final duration = _formatDuration(track.durationMs);
    if (duration.isEmpty) return artist;
    return '$artist • $duration';
  }

  Widget _buildArtwork(_RadioTrack track) {
    final resolvedUrl =
        _applyStreamingArtworkQuality(track.artUri, videoId: track.videoId) ??
        _qualityFallbackArtworkUrl(track.videoId);
    return CachedNetworkImage(
      imageUrl: resolvedUrl,
      fit: BoxFit.cover,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      placeholder: (context, _) {
        return Container(
          color: Colors.transparent,
          child: Icon(Icons.music_note_rounded, color: Colors.transparent),
        );
      },
      errorWidget: (context, _, error) {
        return Container(
          color: Colors.transparent,
          child: Icon(Icons.music_note_rounded, color: Colors.transparent),
        );
      },
    );
  }

  Future<void> _addTrackToQueue(_RadioTrack track) async {
    final videoId = track.videoId.trim();
    if (videoId.isEmpty) return;

    final title = track.title.trim().isNotEmpty
        ? track.title.trim()
        : LocaleProvider.tr('title_unknown');
    final artist = track.artist.trim().isNotEmpty
        ? track.artist.trim()
        : LocaleProvider.tr('artist_unknown');
    final artUri =
        _applyStreamingArtworkQuality(track.artUri, videoId: videoId) ??
        _qualityFallbackArtworkUrl(videoId);

    await audioHandler?.customAction('addYtStreamToQueue', {
      'videoId': videoId,
      'title': title,
      'artist': artist,
      'artUri': artUri,
      if (track.durationMs != null && track.durationMs! > 0)
        'durationMs': track.durationMs,
    });
  }

  Future<void> _downloadTrack(_RadioTrack track) async {
    final videoId = track.videoId.trim();
    if (videoId.isEmpty) return;
    await SimpleYtDownload.downloadVideoWithArtist(
      context,
      videoId,
      track.title,
      track.artist,
      thumbUrl: track.artUri,
    );
  }

  Future<void> _showTrackOptions(_RadioTrack track) async {
    final videoId = track.videoId.trim();
    if (videoId.isEmpty || !mounted) return;

    final title = track.title.trim().isNotEmpty
        ? track.title.trim()
        : LocaleProvider.tr('title_unknown');
    final artist = track.artist.trim().isNotEmpty
        ? track.artist.trim()
        : LocaleProvider.tr('artist_unknown');
    final artUri =
        _applyStreamingArtworkQuality(track.artUri, videoId: videoId) ??
        _qualityFallbackArtworkUrl(videoId);
    final videoUrl = 'https://music.youtube.com/watch?v=$videoId';
    final rawPath = 'yt:$videoId';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 60,
                        height: 60,
                        child: _buildArtwork(track),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            style: Theme.of(context).textTheme.titleMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            artist,
                            style: const TextStyle(fontSize: 14),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: () async {
                        Navigator.of(context).pop();
                        await _showTrackSearchOptions(track);
                      },
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.onPrimaryContainer
                                    .withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.search,
                              size: 20,
                              color:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? Theme.of(context).colorScheme.onPrimary
                                  : Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainer,
                            ),
                            const SizedBox(width: 8),
                            TranslatedText(
                              'search',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                                color:
                                    Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? Theme.of(context).colorScheme.onPrimary
                                    : Theme.of(
                                        context,
                                      ).colorScheme.surfaceContainer,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(Icons.queue_music),
                title: const TranslatedText('add_to_queue'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await _addTrackToQueue(track);
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.favorite_outline_rounded,
                  weight: 600,
                ),
                title: const TranslatedText('add_to_favorites'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await FavoritesDB().addFavoritePath(
                    rawPath,
                    title: title,
                    artist: artist,
                    videoId: videoId,
                    artUri: artUri,
                    durationMs: track.durationMs,
                  );
                  favoritesShouldReload.value = !favoritesShouldReload.value;
                },
              ),
              if (artist.trim().isNotEmpty &&
                  artist.trim() != LocaleProvider.tr('artist_unknown'))
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: const TranslatedText('go_to_artist'),
                  onTap: () {
                    Navigator.of(context).pop();
                    final name = artist.trim();
                    if (name.isEmpty) return;
                    Navigator.of(context).push(
                      PageRouteBuilder(
                        pageBuilder: (context, animation, secondaryAnimation) =>
                            ArtistScreen(artistName: name),
                        transitionsBuilder:
                            (context, animation, secondaryAnimation, child) {
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
                  },
                ),
              ListTile(
                leading: const Icon(Icons.download_rounded),
                title: const TranslatedText('download'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await _downloadTrack(track);
                },
              ),
              ListTile(
                leading: const Icon(Icons.share_rounded),
                title: const TranslatedText('share_link'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await SharePlus.instance.share(ShareParams(text: videoUrl));
                },
              ),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const TranslatedText('song_info'),
                onTap: () async {
                  Navigator.of(context).pop();
                  final mediaItem = MediaItem(
                    id: rawPath,
                    title: title,
                    artist: artist,
                    artUri: Uri.tryParse(artUri),
                    extras: {
                      'data': rawPath,
                      'videoId': videoId,
                      'isStreaming': true,
                      'displayArtUri': artUri,
                    },
                  );
                  await SongInfoDialog.show(
                    context,
                    mediaItem,
                    colorSchemeNotifier,
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _searchTrackOnYouTube(_RadioTrack track) async {
    try {
      String searchQuery = track.title.trim();
      final artist = track.artist.trim();
      if (artist.isNotEmpty &&
          artist != LocaleProvider.tr('artist_unknown').trim()) {
        searchQuery = '$artist ${track.title.trim()}';
      }

      final encodedQuery = Uri.encodeComponent(searchQuery);
      final url = Uri.parse(
        'https://www.youtube.com/results?search_query=$encodedQuery',
      );

      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
  }

  Future<void> _searchTrackOnYouTubeMusic(_RadioTrack track) async {
    try {
      String searchQuery = track.title.trim();
      final artist = track.artist.trim();
      if (artist.isNotEmpty &&
          artist != LocaleProvider.tr('artist_unknown').trim()) {
        searchQuery = '$artist ${track.title.trim()}';
      }

      final encodedQuery = Uri.encodeComponent(searchQuery);
      final url = Uri.parse('https://music.youtube.com/search?q=$encodedQuery');

      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
  }

  Widget _buildSearchActionOption({
    required BuildContext context,
    required String title,
    required VoidCallback onTap,
    Widget? leading,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(28),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Row(
            children: [
              if (leading != null)
                SizedBox(width: 24, height: 24, child: Center(child: leading)),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showTrackSearchOptions(_RadioTrack track) async {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        final isAmoled =
            Theme.of(context).brightness == Brightness.dark &&
            Theme.of(context).colorScheme.surface == Colors.black;
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final primaryColor = Theme.of(context).colorScheme.primary;

        return AlertDialog(
          backgroundColor: isAmoled && isDark
              ? Colors.black
              : Theme.of(context).colorScheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
            side: isAmoled && isDark
                ? const BorderSide(color: Colors.white24, width: 1)
                : BorderSide.none,
          ),
          contentPadding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 400,
              maxHeight: MediaQuery.of(context).size.height * 0.8,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.search_rounded, size: 32),
                const SizedBox(height: 16),
                TranslatedText(
                  'search_song',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w500,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 16),
                _buildSearchActionOption(
                  context: context,
                  title: 'YouTube',
                  leading: Image.asset(
                    'assets/icon/Youtube_logo.png',
                    width: 24,
                    height: 24,
                  ),
                  onTap: () {
                    Navigator.of(context).pop();
                    _searchTrackOnYouTube(track);
                  },
                ),
                const SizedBox(height: 8),
                _buildSearchActionOption(
                  context: context,
                  title: 'YT Music',
                  leading: Image.asset(
                    'assets/icon/Youtube_Music_icon.png',
                    width: 24,
                    height: 24,
                  ),
                  onTap: () {
                    Navigator.of(context).pop();
                    _searchTrackOnYouTubeMusic(track);
                  },
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.only(right: 24, bottom: 8),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: TranslatedText(
                        'cancel',
                        style: TextStyle(
                          color: primaryColor,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isAmoled =
        isDark && Theme.of(context).colorScheme.surface == Colors.black;
    final cardColor = isAmoled
        ? Colors.white.withAlpha(20)
        : isDark
        ? Theme.of(context).colorScheme.secondary.withValues(alpha: 0.06)
        : Theme.of(context).colorScheme.secondary.withValues(alpha: 0.07);

    return ValueListenableBuilder<bool>(
      valueListenable: overlayVisibleNotifier,
      builder: (context, overlayVisible, child) {
        final bottomPadding = MediaQuery.of(context).padding.bottom;
        final space = (overlayVisible ? 100.0 : 0.0) + bottomPadding;
        return ListView(
          padding: EdgeInsets.fromLTRB(16, 12, 16, space),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(child: Text(_error!)),
              )
            else if (_seed == null)
              SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: SizedBox(
                  height: MediaQuery.of(context).size.height - 200,
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 80,
                          height: 80,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isDark
                                ? Theme.of(context).colorScheme.secondary
                                      .withValues(alpha: 0.04)
                                : Theme.of(context).colorScheme.secondary
                                      .withValues(alpha: 0.05),
                          ),
                          child: Icon(
                            Icons.music_note_rounded,
                            weight: 600,
                            size: 50,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.7),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          LocaleProvider.tr('no_recent_streaming_yet'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else if (_radioTracks.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    LocaleProvider.tr('no_radio_songs_found_for_seed'),
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else ...[
              ..._radioTracks.asMap().entries.map((entry) {
                final index = entry.key;
                final track = entry.value;
                final isCurrent = _isCurrentRadioTrack(track);
                final bool isFirst = index == 0;
                final bool isLast = index == _radioTracks.length - 1;
                final bool isOnly = _radioTracks.length == 1;

                BorderRadius borderRadius;
                if (isOnly) {
                  borderRadius = BorderRadius.circular(20);
                } else if (isFirst) {
                  borderRadius = const BorderRadius.only(
                    topLeft: Radius.circular(20),
                    topRight: Radius.circular(20),
                    bottomLeft: Radius.circular(4),
                    bottomRight: Radius.circular(4),
                  );
                } else if (isLast) {
                  borderRadius = const BorderRadius.only(
                    topLeft: Radius.circular(4),
                    topRight: Radius.circular(4),
                    bottomLeft: Radius.circular(20),
                    bottomRight: Radius.circular(20),
                  );
                } else {
                  borderRadius = BorderRadius.circular(4);
                }

                return Card(
                  elevation: 0,
                  margin: EdgeInsets.only(bottom: isLast ? 0 : 4),
                  color: isCurrent
                      ? isAmoled
                            ? cardColor
                            : Theme.of(
                                context,
                              ).colorScheme.primary.withAlpha(isDark ? 40 : 25)
                      : cardColor,
                  shape: RoundedRectangleBorder(borderRadius: borderRadius),
                  child: ClipRRect(
                    borderRadius: borderRadius,
                    child: ListTile(
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 50,
                          height: 50,
                          child: _buildArtwork(track),
                        ),
                      ),
                      title: Row(
                        children: [
                          if (isCurrent)
                            Padding(
                              padding: const EdgeInsets.only(right: 8.0),
                              child: MiniMusicVisualizer(
                                color: Theme.of(context).colorScheme.primary,
                                width: 4,
                                height: 15,
                                radius: 4,
                                animate: _isPlaying,
                              ),
                            ),
                          Expanded(
                            child: Text(
                              track.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: isCurrent
                                  ? Theme.of(
                                      context,
                                    ).textTheme.titleMedium?.copyWith(
                                      color: isAmoled
                                          ? Colors.white
                                          : Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                      fontWeight: FontWeight.bold,
                                    )
                                  : Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                        ],
                      ),
                      subtitle: Text(
                        _formatArtistWithDuration(track),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: isAmoled
                            ? TextStyle(
                                color: Colors.white.withValues(alpha: 0.8),
                              )
                            : null,
                      ),
                      trailing: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withAlpha(20),
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          icon: Icon(
                            isCurrent && _isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            grade: 200,
                            fill: 1,
                            color: isCurrent
                                ? Theme.of(context).colorScheme.primary
                                : null,
                          ),
                          onPressed: () {
                            if (isCurrent) {
                              _isPlaying
                                  ? audioHandler.myHandler?.pause()
                                  : audioHandler.myHandler?.play();
                            } else {
                              _playRadioTrack(index);
                            }
                          },
                        ),
                      ),
                      selected: isCurrent,
                      selectedTileColor: Colors.transparent,
                      shape: RoundedRectangleBorder(borderRadius: borderRadius),
                      onTap: () {
                        if (isCurrent) {
                          _isPlaying
                              ? audioHandler.myHandler?.pause()
                              : audioHandler.myHandler?.play();
                        } else {
                          _playRadioTrack(index);
                        }
                      },
                      onLongPress: () {
                        _showTrackOptions(track);
                      },
                    ),
                  ),
                );
              }),
            ],
          ],
        );
      },
    );
  }
}
