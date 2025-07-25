// lib/l10n/app_localizations_en.dart

const Map<String, String> appLocalizationsEn = {
  // General
  'settings': 'Settings',
  'cancel': 'Cancel',
  'delete': 'Delete',
  'remove': 'Remove',
  'ok': 'OK',
  'information': 'Information',
  'yes': 'Yes',
  'no': 'No',

  // Preferences
  'preferences': 'Preferences',
  'select_theme': 'Select theme',
  'select_color': 'Select color',
  'system_default': 'System default',
  'light_mode': 'Light mode',
  'dark_mode': 'Dark mode',
  'change_language': 'Change language',
  'spanish': 'Spanish',
  'english': 'English',

  // Downloads
  'downloads': 'Downloads',
  'save_path': 'Save path',
  'not_selected': 'Not selected',
  'download_type': 'Download type',
  'download_type_desc': 'Choose the method to download audio',
  'explode': 'Explode',
  'direct': 'Direct',
  'audio_processor': 'Audio processor',
  'audio_processor_desc': 'Choose how to process and tag audio',
  'ffmpeg': 'FFmpeg',
  'audiotags': 'AudioTags',
  'grant_all_files_permission': 'Grant all files permission',
  'grant_all_files_permission_desc': 'Grant full access to device files (Android 11+ only)',
  'permission_granted': 'Permission granted',
  'permission_denied': 'Permission denied',
  'permission_granted_desc': 'You now have access to all files.',
  'permission_denied_desc': 'Permission not granted. Go to settings to grant it manually.',
  'default_path_set': 'Default path set to Music folder due to Android 9 compatibility.',

  // Music and playback
  'music_and_playback': 'Music and playback',
  'index_songs_on_startup': 'Index song files',
  'index_songs_on_startup_desc': 'Automatically sync the database with device files',
  'delete_lyrics': 'Delete song lyrics',
  'delete_lyrics_desc': 'Delete all cached synced lyrics',
  'delete_lyrics_confirm': 'Are you sure you want to delete all stored lyrics? This action cannot be undone.',
  'lyrics_deleted': 'Lyrics deleted',
  'lyrics_deleted_desc': 'Song lyrics have been deleted successfully.',
  'clear_artwork_cache': 'Clear artwork cache',
  'clear_artwork_cache_desc': 'Remove cached artwork images',
  'clear_artwork_cache_confirm': 'Are you sure you want to delete all cached artwork? This action cannot be undone.',
  'artwork_cache_cleared': 'Artwork cache cleared',
  'artwork_cache_cleared_desc': 'Artwork cache has been cleared successfully.',
  'ignore_battery_optimization': 'Ignore battery optimization',
  'ignore_battery_optimization_desc': 'If you have issues with background playback due to system optimization, please enable this option',
  'status_checking': 'Status: checking...',
  'status_enabled': 'Status: Enabled',
  'status_disabled': 'Status: Disabled',
  'battery_optimization_info': 'Battery optimization is already disabled',

  // App settings
  'app_settings': 'App settings',
  'artwork_quality': 'Artwork quality when playing',
  'artwork_quality_description': 'Select the quality of artwork when playing music',
  'hero_animation': 'Hero animation',
  'hero_animation_desc': 'Enable Hero animation between overlay and player.',
  '100_percent_maximum': '100% (Maximum)',
  '80_percent_recommended': '80% (Recommended)',
  '60_percent_performance': '60% (Performance)',
  '40_percent_low': '40% (Low)',
  '20_percent_minimum': '20% (Minimum)',
  'app_updates': 'App updates',
  'check_for_updates': 'Check for app updates',
  'about': 'About',
  'app_info': 'App information',
  'version': 'Version',
  'app_description': 'Aura Music is an app to play your local music quickly and easily. Enjoy your favorite songs, create playlists, and more.',

  // Dialogs
  'confirm_clear_lyrics': 'Delete song lyrics?',
  'confirm_clear_artwork': 'Clear artwork cache?',
  'confirm': 'Confirm',
  'success': 'Success',
  'error': 'Error',
  'are_you_sure': 'Are you sure?',
  // Backup
  'backup': 'Backup',
  'export_backup': 'Export backup',
  'export_backup_desc': 'Export your favorites, playlists, recents and most played to a JSON file',
  'import_backup': 'Import backup',
  'import_backup_desc': 'Import a backup and replace all current data',
  'backup_exported': 'Backup exported successfully!',
  'backup_imported': 'Backup imported successfully!',
  'import_confirm': 'This will erase all current data and replace it with the backup. Continue?',
  'import': 'Import',
  'restart_app': 'Close app',

  // Others (add as needed)
  'search': 'Search',
  'search_in_youtube_music': 'Search in YouTube Music',
  'info': 'Information',
  'search_music_in_ytm': 'Search and download music from YouTube Music.',
  'understood': 'Understood',
  'songs_search': 'Songs',
  'videos': 'Videos',
  'albums': 'Albums',
  'no_results': 'No results',
  'write_song_or_artist': 'Type the name of a song or artist',
  'loading_more': 'Loading more results...',
  'copy_link': 'Copy link',
  'title_unknown': 'Untitled',
  'artist_unknown': 'Unknown artist',

  // Favorites screen
  'favorites': 'Favorites',
  'select_all': 'Select all',
  'add': 'Add',
  'add_from_recents': 'Add from recents',
  'search_by_title_or_artist': 'Search by title or artist',
  'no_songs': 'No songs',
  'remove_from_favorites': 'Remove from favorites',
  'unknown_artist': 'Unknown',
  'last_added': 'Last added',
  'invert_order': 'Invert order',
  'alphabetical_az': 'Alphabetical (A-Z)',
  'alphabetical_za': 'Alphabetical (Z-A)',
  'default': 'Default',
  'select_songs': 'Select songs',
  'confirm_remove_favorites': 'Are you sure you want to remove these songs from favorites?',
  'confirm_remove_favorite': 'Are you sure you want to remove this song from favorites?',

  // Bottom Navigation
  'home': 'Home',
  'nav_search': 'Search',
  'nav_favorites': 'Favorites',
  'folders': 'Folders',
  'nav_downloads': 'Downloads',

  // Folders screen
  'folders_title': 'Folders',
  'reload': 'Reload',
  'no_folders': 'No folders',
  'unpin_shortcut': 'Unpin shortcut',
  'pin_shortcut': 'Pin shortcut',
  'select': 'Select',
  'edit_date_newest_first': 'Edit date (ascending)',
  'edit_date_oldest_first': 'Edit date (descending)',
  'delete_from_device': 'Delete from device',
  'could_not_delete_song': 'Could not delete the song from the device. \n\nIf you have problems, try granting all files permission.',
  'delete_folder': 'Delete folder',
  'delete_folder_confirm': 'Are you sure you want to delete this folder and all its songs from the device?',
  'could_not_delete_folder': 'Could not delete all songs in the folder. \n\nIf you have problems, try granting all files permission.',
  'select_playlist': 'Select playlist',
  'create_playlist': 'Create playlist',
  'new_playlist_name': 'New playlist name',
  'cancel_selection': 'Cancel selection',
  'no_songs_in_folder': 'No songs in this folder',
  'play_all': 'Play all',
  'add_to_favorites': 'Add to favorites',
  'add_to_playlist': 'Add to playlist',
  'remove_from_playlist': 'Remove from playlist',
  'delete_song': 'Delete song',
  'delete_song_confirm': 'Are you sure you want to delete this song?',
  'song_deleted': 'Song deleted',
  'song_deleted_desc': 'The song has been deleted successfully.',
  'error_loading_folders': 'Error loading folders',
  'error_loading_songs': 'Error loading songs',
  'songs': 'songs',

  // Download screen
  'download': 'Downloads',
  'youtube_link': 'YouTube Link',
  'paste_link': 'Paste link',
  'large_playlist_detected': 'Large playlist detected',
  'fetching_playlist_info': 'Fetching playlist information... (Not downloading yet)',
  'videos_found_so_far': 'Videos found so far',
  'continue_anyway': 'Continue anyway',
  'total_videos': 'Total videos',
  'will_download_available': 'The videos found so far will be downloaded.',
  'download_audio': 'Download Audio',
  'playlist_partial_fetch': 'Playlist partially fetched',
  'processing_audio': 'Processing audio...',
  'downloading': 'Downloading...',
  'downloading_audio': 'Downloading audio...',
  'downloading_playlist': 'Downloading playlist...',
  'choose_folder': 'Choose folder',
  'folder_ready': 'Folder ready',
  'file_permissions': 'File permissions',
  'getting_info': 'Getting information...',
  'playlist_detected': 'Playlist detected',
  'videos_found': 'videos found',
  'download_complete_playlist': 'Download',
  'large_playlist_confirmation': 'Large playlist detected',
  'large_playlist_confirmation_desc': 'The playlist is very large, the following videos will be downloaded',
  'video_of': 'Video',
  'of': 'of',
  'downloaded': 'Downloaded',
  'not_selected_folder': 'Not selected',
  'app_documents': 'App documents',
  'download_method': 'Download:',
  'audio_processing': 'Process audio:',
  'folder_not_selected': 'Folder not selected',
  'folder_not_selected_desc': 'You must select a folder before downloading audio.',
  'download_accept': 'Accept',
  'video_unavailable': 'Video unavailable',
  'video_unavailable_desc': 'The video is not available. It may have been deleted, is private, or is restricted by YouTube.',
  'download_failed_title': 'Download failed',
  'download_failed_desc': 'An error occurred, try again.',
  'playlist_error': 'Error getting playlist',
  'playlist_error_desc': 'Could not get playlist information',
  'playlist_completed': 'Playlist completed',
  'playlist_completed_desc': 'Downloaded',
  'playlist_error_download': 'Playlist error',
  'playlist_error_download_desc': 'Error downloading playlist',
  'recommend_seal': 'Want more options?',
  'recommend_seal_desc': 'We recommend the free Seal app for downloading music and videos from many sources.',
  'seal_github': 'Want Seal\'s GitHub repository?',
  'open': 'Open',
  'could_not_open_browser': 'Could not open browser',
  'what_means_each_option': 'What does each option mean?',
  'download_method_title': 'Download method:',
  'download_method_desc': '• Explode: Uses the youtube_explode_dart library to get streams and download audio from YouTube.\n• Direct: Downloads audio directly from the stream provided by youtube_explode_dart.\n\nBoth methods work for individual videos and playlists.',
  'audio_processing_title': 'Process audio:',
  'audio_processing_desc': '• FFmpeg: Converts and adds metadata using FFmpeg. Allows greater compatibility and quality, but requires more resources.\n• AudioTags: Only adds metadata using the audiotags library. Faster, but less flexible.',
  'download_understood_2': 'Understood',
  'download_info_title': 'Information',
  'download_info_desc': 'This function downloads audio from individual videos and complete playlists from YouTube or YouTube Music.',
  'download_works_with': 'Works with:\n• Individual videos\n• Public playlists (Could be slow)',
  'download_not_works_with': 'Does not work with private videos or copyright-protected content.',
  'download_may_fail': 'Download may fail due to YouTube blocks.',
  'grant_file_permissions': 'Grant file permissions?',
  'grant_file_permissions_desc': 'This function is NOT necessary for most users.\n\nUse it only if you have problems processing audio or saving files.\n\nDo you want to continue and grant access to all files?',
  'grant_permissions': 'Grant permissions',
  'permission_granted_already': 'Permission granted',
  'permission_granted_already_desc': 'You already have access to all files.',
  'not_necessary': 'Not necessary',
  'not_necessary_desc': 'You don\'t need to grant this permission on your Android version.',
  'android_only': 'Android only',
  'android_only_desc': 'This function only applies to Android.',
  'android_9_or_lower': 'On Android 9 or lower, the Music folder will be used by default.',
  'file_in_use': 'File in use',
  'file_in_use_desc': 'Cannot overwrite the file because it is playing. Please stop playback before downloading again.',
  'audio_processing_error': 'Error processing audio',
  'audio_processing_error_desc': 'Error processing audio, try using another folder.',
  'metadata_error': 'Error writing metadata to audio',
  'mp3_exists_error': 'The MP3 file already exists and could not be deleted.',
  'metadata_write_error': 'Error writing metadata',
  'no_cover_error': 'Could not download any cover',
  'no_valid_stream': 'No valid AAC/mp4a stream found.',
  'no_audio_stream': 'No valid audio stream found.',
  'queue_info': '{count} more in queue',
  'download_failed_generic': 'Download failed.',
  'no_audio_available': 'Audio not available',
  'no_audio_available_desc': 'Could not get audio stream.',
  'invalid_url': 'Invalid URL',
  'want_more_options': 'Want more options?',
  'seal_recommendation': 'We recommend the free Seal app for downloading music and videos from many sources.\n\nWant Seal\'s GitHub repository?',
  'browser_open_error': 'Could not open browser',
  'no_internet_connection': 'No internet connection. Please check your connection and try again.',
  'no_internet_retry': 'No internet connection, please check your connection and try again.',
  
  // Home screen
  'recent': 'Recent',
  'recent_playlists': 'Recent playlists',
  'no_recent_playlists': 'No recent playlists.',
  'quick_pick_songs': 'quick pick',
  'quick_access_songs': 'quick access',
  'recent_songs_title': 'recent songs',
  'playing_from': 'Playing from ',
  'favorites_title': 'favorites',
  'confirm_remove_from_playlist': 'Are you sure you want to remove this song from the playlist?',
  'recent_songs': 'Recent songs',
  'no_recent_songs': 'No recent songs.',
  'new_version_available': 'New version',
  'available': 'available!',
  'update': 'Update',
  'quick_access': 'Quick access',
  'no_songs_to_show': 'No songs to show yet.',
  'quick_pick': 'Quick pick',
  'create_new_playlist': 'Create new playlist',
  'new_playlist': 'New playlist',
  'playlist_name': 'Playlist name',
  'create': 'Create',
  'no_playlists': 'No playlists.',
  'rename_playlist': 'Rename playlist',
  'new_name': 'New name',
  'save': 'Save',
  'delete_playlist': 'Delete playlist',
  'no_songs_in_playlist': 'No songs in this playlist',
  'delete_playlist_confirm': 'Are you sure you want to delete this playlist?',
  'could_not_get_video': 'Could not get video.',
  'no_videos_in_playlist': 'No videos found in playlist',
  'could_not_extract_playlist': 'Could not extract playlist ID',

  // Player screen
  'share_audio_file': 'Share audio file',
  'sleep_timer_remaining': 'Time remaining',
  'sleep_timer': 'Sleep timer',
  'song_info': 'Song information',
  'title': 'Title',
  'artist': 'Artist',
  'album': 'Album',
  'location': 'Location',
  'duration': 'Duration',
  'close': 'Close',
  'no_song_playing': 'No song playing',
  'lyrics_not_found': 'Lyrics not found.',
  'playlist': 'Playlist',
  'one_minute': '1 minute',
  'five_minutes': '5 minutes',
  'show_lyrics': 'Show lyrics',
  'fifteen_minutes': '15 minutes',
  'thirty_minutes': '30 minutes',
  'one_hour': '1 hour',
  'until_song_ends': 'Until song ends',
  'cancel_timer': 'Cancel timer',
  'lyrics': 'Lyrics',
  'shuffle': 'Shuffle',
  'repeat': 'Repeat',
  'song_not_found': 'Original song not found',
  'save_to_playlist': 'Save to playlist',
  'no_playlists_yet': 'You don\'t have playlists yet.\nCreate a new one below.',
  'pause_preview': 'Pause preview',
  'play_preview': 'Play preview',
  
  // OTA Update screen
  'checking_update': 'Checking for updates...',
  'no_updates_available': 'No updates available.',
  'ready_to_download': 'Ready to download',
  'downloading_update': 'Downloading update...',
  'download_complete': 'Download complete',
  'install': 'Install',
  'changes': 'Changes:',
  'dont_exit_app': 'Please don\'t exit the app while downloading.',
  'press_button_to_check': 'Press the button to check for updates',
  'check_for_update': 'Check for update',
  'new_update_available': 'New update available!',
  'status': 'Status',
  
  // Search suggestions
  'suggestions': 'Suggestions',
  'recent_searches': 'Recent searches',
  'no_suggestions': 'No suggestions available',
  'clear_history': 'Clear history',
  'no_recent_searches': 'No recent searches',
  'no_folders_with_songs': 'No folders with songs found.',
  'download_selected': 'Download selected',
  'selected': 'selected',
  'remove_from_recents': 'Remove from recents',
  'ignore_file': 'Ignore file',
  'unignore_file': 'Unignore file',
}; 