import 'package:flutter/material.dart';
import 'dart:ui';
import 'package:http/http.dart' as http;
import 'dart:io';
import 'package:flutter/rendering.dart';
import 'package:media_scanner/media_scanner.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:music/utils/notifiers.dart';

class ImageViewer extends StatefulWidget {
  final String imageUrl;
  final String? title;
  final String? subtitle;
  final String? videoId;

  const ImageViewer({
    super.key,
    required this.imageUrl,
    this.title,
    this.subtitle,
    this.videoId,
  });

  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer>
    with TickerProviderStateMixin {
  late AnimationController _fadeController;
  late AnimationController _scaleController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;
  
  String? _highQualityImageUrl;
  bool _isLoadingHighQuality = false;
  bool _isDownloading = false;
  
  final GlobalKey _imageKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _scaleController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    ));

    _scaleAnimation = Tween<double>(
      begin: 0.8,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _scaleController,
      curve: Curves.easeOut,
    ));

    _fadeController.forward();
    _scaleController.forward();
    
    // Cargar imagen de alta calidad si hay videoId
    if (widget.videoId != null) {
      _loadHighQualityImage();
    }
  }
  
  void _loadHighQualityImage() async {
    if (widget.videoId == null) return;
    
    setState(() {
      _isLoadingHighQuality = true;
    });
    
    // Intentar cargar maxresdefault primero
    final coverUrlMax = 'https://img.youtube.com/vi/${widget.videoId}/maxresdefault.jpg';
    final coverUrlHQ = 'https://img.youtube.com/vi/${widget.videoId}/hqdefault.jpg';
    
    try {
      // Verificar si maxresdefault existe
      final response = await Future.any([
        _checkImageExists(coverUrlMax),
        Future.delayed(const Duration(seconds: 2), () => false),
      ]);
      
      if (response && mounted) {
        setState(() {
          _highQualityImageUrl = coverUrlMax;
          _isLoadingHighQuality = false;
        });
        return;
      }
      
      // Si maxresdefault no existe, usar hqdefault
      if (mounted) {
        setState(() {
          _highQualityImageUrl = coverUrlHQ;
          _isLoadingHighQuality = false;
        });
      }
    } catch (e) {
      // Si falla, usar hqdefault como respaldo
      if (mounted) {
        setState(() {
          _highQualityImageUrl = coverUrlHQ;
          _isLoadingHighQuality = false;
        });
      }
    }
  }
  
  Future<bool> _checkImageExists(String url) async {
    try {
      final response = await Future.any([
        _makeHeadRequest(url),
        Future.delayed(const Duration(seconds: 1), () => false),
      ]);
      return response;
    } catch (e) {
      return false;
    }
  }
  
  Future<bool> _makeHeadRequest(String url) async {
    try {
      final response = await http.head(Uri.parse(url));
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }


  Future<void> _downloadImage() async {
    if (_isDownloading) return;
    
    setState(() {
      _isDownloading = true;
    });

    try {
      // Capturar la imagen tal como se muestra en el visor (recortada)
      final RenderRepaintBoundary boundary = 
          _imageKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ImageByteFormat.png);
      final pngBytes = byteData!.buffer.asUint8List();

      // Usar el directorio de música por defecto (donde se descargan las canciones)
      final directory = Directory('/storage/emulated/0/Music');

      // Crear nombre de archivo único
      final fileName = '${widget.title?.replaceAll(RegExp(r'[^\w\s-]'), '') ?? 'imagen'}_${DateTime.now().millisecondsSinceEpoch}.png';
      final filePath = '${directory.path}/$fileName';

      // Guardar la imagen capturada del visor
      final file = File(filePath);
      await file.writeAsBytes(pngBytes);

      // Indexar la imagen en el sistema (igual que las canciones)
      await MediaScanner.loadMedia(path: filePath);

      _showMessage(LocaleProvider.tr('success'), LocaleProvider.tr('image_saved_desc'));
      
    } catch (e) {
      _showMessage(LocaleProvider.tr('error'), '${LocaleProvider.tr('error')}: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isDownloading = false;
        });
      }
    }
  }

  void _showMessage(String title, String message) {
    showDialog(
      context: context,
      builder: (context) => ValueListenableBuilder<AppColorScheme>(
        valueListenable: colorSchemeNotifier,
        builder: (context, colorScheme, child) {
          final isAmoled = colorScheme == AppColorScheme.amoled;
          final isDark = Theme.of(context).brightness == Brightness.dark;
          
          return AlertDialog(
            title: Center(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(height: 18),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        message,
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                        textAlign: TextAlign.left,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  SizedBox(height: 20),
                  // Tarjeta de aceptar
                  InkWell(
                    onTap: () => Navigator.of(context).pop(),
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      width: double.infinity,
                      padding: EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: isAmoled && isDark
                            ? Colors.white.withValues(alpha: 0.2) // Color personalizado para amoled
                            : Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isAmoled && isDark
                              ? Colors.white.withValues(alpha: 0.4) // Borde personalizado para amoled
                              : Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                          width: 2,
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              color: isAmoled && isDark
                                  ? Colors.white.withValues(alpha: 0.2) // Fondo del ícono para amoled
                                  : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                            ),
                            child: Icon(
                              Icons.check_circle,
                              size: 30,
                              color: isAmoled && isDark
                                  ? Colors.white // Ícono blanco para amoled
                                  : Theme.of(context).colorScheme.primary,
                            ),
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  LocaleProvider.tr('ok'),
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: isAmoled && isDark
                                        ? Colors.white // Texto blanco para amoled
                                        : Theme.of(context).colorScheme.primary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _scaleController.dispose();
    super.dispose();
  }

  void _close() {
    _fadeController.reverse();
    _scaleController.reverse().then((_) {
      if (mounted) {
        Navigator.of(context).pop();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
           // Imagen de fondo con blur
           Positioned.fill(
             child: Image.network(
               _highQualityImageUrl ?? widget.imageUrl,
               fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) {
                return Container(
                  color: Colors.black,
                  child: const Center(
                    child: Icon(
                      Icons.music_note,
                      size: 100,
                      color: Colors.white54,
                    ),
                  ),
                );
              },
            ),
          ),
          // Overlay con blur
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(
                color: Colors.black.withValues(alpha: 0.3),
              ),
            ),
          ),
          // Contenido principal
          SafeArea(
            child: Column(
              children: [
                 // Barra superior con botón de cerrar
                 Padding(
                   padding: const EdgeInsets.fromLTRB(16.0, 8.0, 16.0, 8.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                       IconButton(
                         onPressed: _close,
                         icon: const Icon(
                           Icons.close,
                           color: Colors.white,
                           size: 28,
                         ),
                       ),
                      if (widget.title != null || widget.subtitle != null)
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              if (widget.title != null)
                                Text(
                                  widget.title!,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              if (widget.subtitle != null)
                                Text(
                                  widget.subtitle!,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 14,
                                  ),
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                            ],
                          ),
                        ),
                      IconButton(
                        onPressed: _isDownloading ? null : _downloadImage,
                        icon: _isDownloading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(
                                Icons.download,
                                color: Colors.white,
                                size: 28,
                              ),
                        tooltip: LocaleProvider.tr('download_image'),
                      ),
                    ],
                  ),
                ),
                // Imagen principal
                Expanded(
                  child: Center(
                    child: AnimatedBuilder(
                      animation: Listenable.merge([_fadeAnimation, _scaleAnimation]),
                      builder: (context, child) {
                        return FadeTransition(
                          opacity: _fadeAnimation,
                          child: ScaleTransition(
                            scale: _scaleAnimation,
                               child: RepaintBoundary(
                                 key: _imageKey,
                                 child: SizedBox(
                                   width: MediaQuery.of(context).size.width * 0.9,
                                   height: MediaQuery.of(context).size.width * 0.9,
                                   child: ClipRRect(
                                     borderRadius: BorderRadius.circular(12),
                                     child: Image.network(
                                       _highQualityImageUrl ?? widget.imageUrl,
                                       fit: BoxFit.cover,
                                       errorBuilder: (context, error, stackTrace) {
                                         return Container(
                                           width: 200,
                                           height: 200,
                                           decoration: BoxDecoration(
                                             color: Colors.grey[800],
                                             borderRadius: BorderRadius.circular(12),
                                           ),
                                           child: const Center(
                                             child: Icon(
                                               Icons.music_note,
                                               size: 80,
                                               color: Colors.white54,
                                             ),
                                           ),
                                         );
                                       },
                                       loadingBuilder: (context, child, loadingProgress) {
                                         if (loadingProgress == null) return child;
                                         return Container(
                                           width: 200,
                                           height: 200,
                                           decoration: BoxDecoration(
                                             color: Colors.grey[800],
                                             borderRadius: BorderRadius.circular(12),
                                           ),
                                           child: Center(
                                             child: CircularProgressIndicator(
                                               value: loadingProgress.expectedTotalBytes != null
                                                   ? loadingProgress.cumulativeBytesLoaded /
                                                       loadingProgress.expectedTotalBytes!
                                                   : null,
                                               color: Colors.white,
                                             ),
                                           ),
                                         );
                                       },
                                     ),
                                   ),
                                 ),
                               ),
                             ),
                           );
                      },
                    ),
                  ),
                ),
                 // Indicador de carga de alta calidad
                 if (_isLoadingHighQuality)
                   const Padding(
                     padding: EdgeInsets.all(16.0),
                     child: Row(
                       mainAxisAlignment: MainAxisAlignment.center,
                       children: [
                         SizedBox(
                           width: 16,
                           height: 16,
                           child: CircularProgressIndicator(
                             strokeWidth: 2,
                             color: Colors.white70,
                           ),
                         ),
                         SizedBox(width: 8),
                         Text(
                           'Cargando imagen de alta calidad...',
                           style: TextStyle(
                             color: Colors.white70,
                             fontSize: 12,
                           ),
                         ),
                       ],
                     ),
                   ),
                 // Espaciador inferior
                 const SizedBox(height: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
