import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:audiotags/audiotags.dart';
import 'package:file_selector/file_selector.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/notifiers.dart';
import 'package:audio_service/audio_service.dart';
import 'package:media_scanner/media_scanner.dart';
import 'package:music/main.dart' show audioHandler;
import 'package:music/utils/audio/background_audio_handler.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:material_loading_indicator/loading_indicator.dart';

class EditMetadataScreen extends StatefulWidget {
  final MediaItem song;

  const EditMetadataScreen({super.key, required this.song});

  @override
  State<EditMetadataScreen> createState() => _EditMetadataScreenState();
}

class _EditMetadataScreenState extends State<EditMetadataScreen> {
  late TextEditingController _titleController;
  late TextEditingController _artistController;
  late TextEditingController _albumController;

  Uint8List? _coverBytes;
  bool _isLoading = false;
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.song.title);
    _artistController = TextEditingController(text: widget.song.artist ?? '');
    _albumController = TextEditingController(text: widget.song.album ?? '');

    // Cargar carátula existente
    _loadExistingCover();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _artistController.dispose();
    _albumController.dispose();
    super.dispose();
  }

  Future<void> _loadExistingCover() async {
    try {
      final tag = await AudioTags.read(widget.song.id);
      if (tag?.pictures.isNotEmpty == true) {
        setState(() {
          _coverBytes = tag!.pictures.first.bytes;
        });
      }
    } catch (e) {
      // print('Error loading cover: $e');
    }
  }

  void _checkForChanges() {
    final hasChanges =
        _titleController.text != widget.song.title ||
        _artistController.text != (widget.song.artist ?? '') ||
        _albumController.text != (widget.song.album ?? '') ||
        _coverBytes != null;

    if (hasChanges != _hasChanges) {
      setState(() {
        _hasChanges = hasChanges;
      });
    }
  }

  Future<void> _updatePlayerMetadata() async {
    try {
      // Obtener el estado actual del reproductor
      final mediaItem = await audioHandler?.mediaItem.first;

      // Verificar si la canción actual es la que estamos editando
      if (mediaItem?.id == widget.song.id) {
        // Limpiar el cache de carátulas para esta canción
        final songId = widget.song.extras?['songId'] as int?;
        if (songId != null) {
          cancelArtworkLoad(songId);
          // También limpiar del cache global si existe
          artworkCache.remove(widget.song.id);
        }

        // Crear un nuevo MediaItem con los metadatos actualizados
        final updatedMediaItem = MediaItem(
          id: widget.song.id,
          album: _albumController.text.isNotEmpty
              ? _albumController.text
              : LocaleProvider.tr('unknown_album'),
          title: _titleController.text.isNotEmpty
              ? _titleController.text
              : LocaleProvider.tr('unknown_title'),
          artist: _artistController.text.isNotEmpty
              ? _artistController.text
              : LocaleProvider.tr('unknown_artist'),
          artUri: _coverBytes != null
              ? null
              : widget
                    .song
                    .artUri, // Mantener la carátula original si no se cambió
          extras: widget.song.extras,
        );

        // Actualizar el MediaItem en el reproductor
        await audioHandler?.updateMediaItem(updatedMediaItem);
        // print('👻 Metadatos actualizados en el reproductor y cache limpiado');
      }
    } catch (e) {
      // print('😢 Error al actualizar metadatos en el reproductor: $e');
      // No lanzar error aquí, solo logear
    }
  }

  Future<void> _selectCoverImage() async {
    try {
      final XFile? file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'images',
            extensions: ['jpg', 'jpeg', 'png', 'bmp', 'gif'],
          ),
        ],
      );

      if (file != null) {
        final bytes = await file.readAsBytes();
        setState(() {
          _coverBytes = bytes;
          _hasChanges = true;
        });
      }
    } catch (e) {
      _showErrorDialog(
        LocaleProvider.tr('error'),
        LocaleProvider.tr('error_selecting_image'),
      );
    }
  }

  Future<void> _saveChanges() async {
    if (!_hasChanges) return;

    setState(() {
      _isLoading = true;
    });

    try {
      // Verificar que el archivo existe
      final file = File(widget.song.id);
      if (!await file.exists()) {
        throw Exception(
          '${LocaleProvider.tr('file_not_found')}: ${widget.song.id}',
        );
      }

      // print('Guardando metadatos en: ${widget.song.id}');

      // En Android, usar siempre el método alternativo para evitar problemas de permisos
      if (Platform.isAndroid) {
        // print('Android detectado, usando método alternativo para evitar problemas de permisos');
      }

      final tag = Tag(
        title: _titleController.text.trim(),
        trackArtist: _artistController.text.trim(),
        album: _albumController.text.trim(),
        pictures: _coverBytes != null
            ? [
                Picture(
                  bytes: _coverBytes!,
                  mimeType: null,
                  pictureType: PictureType.other,
                ),
              ]
            : [],
      );

      // En Android, usar método alternativo que es más confiable
      if (Platform.isAndroid) {
        // print('Usando método alternativo para Android...');
        await _writeMetadataAlternative(tag);
      } else {
        // En otras plataformas, intentar método directo primero
        try {
          await AudioTags.write(widget.song.id, tag);
          // print('Metadatos guardados exitosamente');
        } catch (audioTagsError) {
          // print('Error con AudioTags.write: $audioTagsError');
          // Intentar método alternativo si AudioTags falla
          await _writeMetadataAlternative(tag);
        }
      }

      // Indexar el archivo en Android para que aparezca en la galería de música
      if (Platform.isAndroid) {
        try {
          await MediaScanner.loadMedia(path: widget.song.id);
          // print('Archivo indexado exitosamente en la galería de música');
        } catch (e) {
          // print('Error al indexar archivo: $e');
          // No lanzar error aquí, solo logear
        }
      }

      // Actualizar notifiers para refrescar la UI
      foldersShouldReload.value = !foldersShouldReload.value;
      favoritesShouldReload.value = !favoritesShouldReload.value;
      shortcutsShouldReload.value = !shortcutsShouldReload.value;

      // Actualizar el reproductor si está reproduciendo esta canción
      await _updatePlayerMetadata();

      if (mounted) {
        _showSuccessDialog();
      }
    } catch (e) {
      // print('Error saving metadata: $e');
      if (mounted) {
        // Verificar si es un error de formato incompatible
        if (e.toString().contains('INCOMPATIBLE_FORMAT')) {
          _showErrorDialog(
            LocaleProvider.tr('incompatible_audio_format'),
            LocaleProvider.tr('incompatible_audio_format_desc'),
          );
        } else {
          _showErrorDialog(
            LocaleProvider.tr('error_saving_changes'),
            '${LocaleProvider.tr('error_saving_changes_desc')}\n\nError: $e',
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _writeMetadataAlternative(Tag tag) async {
    try {
      final originalFile = File(widget.song.id);
      final tempDir = Directory.systemTemp;
      final originalExtension = widget.song.id.split('.').last;
      final tempFile = File(
        '${tempDir.path}/temp_audio_${DateTime.now().millisecondsSinceEpoch}.$originalExtension',
      );

      // print('Copiando archivo original a: ${tempFile.path}');

      // Copiar el archivo original al temporal
      await originalFile.copy(tempFile.path);

      // print('Escribiendo metadatos en archivo temporal...');

      // Verificar si el formato es compatible con AudioTags
      final fileExtension = tempFile.path.toLowerCase().split('.').last;
      final supportedFormats = ['mp3', 'm4a', 'aac', 'flac', 'wav'];

      if (!supportedFormats.contains(fileExtension)) {
        throw Exception('INCOMPATIBLE_FORMAT');
      }

      // Intentar escribir metadatos en el archivo temporal
      await AudioTags.write(tempFile.path, tag);

      // print('Metadatos escritos, reemplazando archivo original...');

      // Hacer backup del archivo original
      final backupFile = File('${widget.song.id}.backup');
      await originalFile.copy(backupFile.path);

      try {
        // Reemplazar el archivo original con el temporal usando copy (no rename)
        await originalFile.delete();
        await tempFile.copy(widget.song.id);

        // Eliminar backup si todo salió bien
        if (await backupFile.exists()) {
          await backupFile.delete();
        }

        // print('Metadatos guardados exitosamente usando método alternativo');

        // Indexar el archivo después de guardar exitosamente
        if (Platform.isAndroid) {
          try {
            await MediaScanner.loadMedia(path: widget.song.id);
            // print('Archivo indexado exitosamente después de edición');
          } catch (e) {
            // print('Error al indexar archivo después de edición: $e');
          }
        }
      } catch (copyError) {
        // print('Error al reemplazar archivo, restaurando backup: $copyError');
        // Restaurar backup si falla el copy
        if (await backupFile.exists()) {
          if (await originalFile.exists()) {
            await originalFile.delete();
          }
          await backupFile.copy(widget.song.id);
        }
        rethrow;
      }

      // Limpiar archivo temporal si existe
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    } catch (e) {
      // print('Error en método alternativo: $e');
      throw Exception('No se pudieron guardar los metadatos: $e');
    }
  }

  void _showSuccessDialog() {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: isAmoled && isDark
              ? const BorderSide(color: Colors.white, width: 1)
              : BorderSide.none,
        ),
        title: Text(LocaleProvider.tr('changes_saved')),
        content: Text(LocaleProvider.tr('changes_saved_desc')),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.of(context).pop();
            },
            child: Text(LocaleProvider.tr('ok')),
          ),
        ],
      ),
    );
  }

  void _showErrorDialog(String title, String message) {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: isAmoled && isDark
              ? const BorderSide(color: Colors.white, width: 1)
              : BorderSide.none,
        ),
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(LocaleProvider.tr('ok')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          constraints: const BoxConstraints(
            minWidth: 40,
            minHeight: 40,
            maxWidth: 40,
            maxHeight: 40,
          ),
          padding: EdgeInsets.zero,
          icon: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isDark
                  ? Theme.of(
                      context,
                    ).colorScheme.onSecondary.withValues(alpha: 0.5)
                  : Theme.of(
                      context,
                    ).colorScheme.secondaryContainer.withValues(alpha: 0.5),
            ),
            child: const Icon(Icons.arrow_back, size: 24),
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: TranslatedText(
          'edit_song_info',
          style: TextStyle(fontWeight: FontWeight.w500),
        ),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          IconButton(
            onPressed: () => showDialog(
              context: context,
              builder: (context) => AlertDialog(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: isAmoled && isDark
                      ? const BorderSide(color: Colors.white, width: 1)
                      : BorderSide.none,
                ),
                title: Center(
                  child: Text(
                    LocaleProvider.tr('edit_song_info'),
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                content: Text(LocaleProvider.tr('edit_song_info_desc')),
              ),
            ),
            icon: const Icon(Icons.info_outline, size: 26),
            tooltip: LocaleProvider.tr('information'),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Carátula
              Center(
                child: GestureDetector(
                  onTap: _selectCoverImage,
                  child: Stack(
                    children: [
                      Container(
                        width: 200,
                        height: 200,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Theme.of(context).dividerColor,
                            width: 1,
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: _coverBytes != null
                              ? Image.memory(_coverBytes!, fit: BoxFit.cover)
                              : Container(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainer,
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.music_note,
                                        size: 64,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.5),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        LocaleProvider.tr('no_cover'),
                                        style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: 0.5),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                        ),
                      ),
                      // Ícono de lápiz en la esquina superior derecha
                      Positioned(
                        top: 8,
                        right: 8,
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(
                            Icons.edit,
                            color: Colors.white,
                            size: 18,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 32),

              // Campos de texto
              TextField(
                controller: _titleController,
                decoration: InputDecoration(
                  labelText: LocaleProvider.tr('song_title'),
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.title),
                ),
                onChanged: (_) => _checkForChanges(),
              ),
              const SizedBox(height: 26),

              TextField(
                controller: _artistController,
                decoration: InputDecoration(
                  labelText: LocaleProvider.tr('song_artist'),
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.person),
                ),
                onChanged: (_) => _checkForChanges(),
              ),
              const SizedBox(height: 26),

              TextField(
                controller: _albumController,
                decoration: InputDecoration(
                  labelText: LocaleProvider.tr('song_album'),
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.album),
                ),
                onChanged: (_) => _checkForChanges(),
              ),
              const SizedBox(height: 32),

              // Botón de guardar
              Center(
                child: Container(
                  height: 60,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: _hasChanges && !_isLoading
                        ? Theme.of(context).colorScheme.primaryContainer
                        : Theme.of(context).colorScheme.surfaceContainer,
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: _hasChanges && !_isLoading ? _saveChanges : null,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 16,
                        ),
                        child: _isLoading
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: LoadingIndicator(),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    LocaleProvider.tr('saving'),
                                    style: TextStyle(
                                      color: _hasChanges && !_isLoading
                                          ? Theme.of(
                                              context,
                                            ).colorScheme.onPrimaryContainer
                                          : Theme.of(context)
                                                .colorScheme
                                                .onSurface
                                                .withValues(alpha: 0.5),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              )
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.save,
                                    color: _hasChanges && !_isLoading
                                        ? Theme.of(
                                            context,
                                          ).colorScheme.onPrimaryContainer
                                        : Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: 0.5),
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    LocaleProvider.tr('save_changes'),
                                    style: TextStyle(
                                      color: _hasChanges && !_isLoading
                                          ? Theme.of(
                                              context,
                                            ).colorScheme.onPrimaryContainer
                                          : Theme.of(context)
                                                .colorScheme
                                                .onSurface
                                                .withValues(alpha: 0.5),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
