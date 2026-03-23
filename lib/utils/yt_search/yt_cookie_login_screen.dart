import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

const String _ytMusicMainUrl = 'https://music.youtube.com/';
const String _ytLoginUrl =
    'https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fmusic.youtube.com%2F';

class YtCookieLoginScreen extends StatefulWidget {
  const YtCookieLoginScreen({super.key});

  @override
  State<YtCookieLoginScreen> createState() => _YtCookieLoginScreenState();
}

class _YtCookieLoginScreenState extends State<YtCookieLoginScreen> {
  bool _capturingCookies = false;
  bool _showProgress = true;
  int _progress = 0;
  String? _currentUrl;

  Future<void> _showStyledDialog({
    required String title,
    required String message,
    IconData? icon,
    Color? iconColor,
  }) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          surfaceTintColor: Colors.transparent,
          title: Row(
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  color: iconColor ?? Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          content: Text(message, style: const TextStyle(fontSize: 16)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Aceptar'),
            ),
          ],
        );
      },
    );
  }

  bool _isYtMusicMainPage(Uri? uri) {
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    final isMusicHost =
        host == 'music.youtube.com' || host.endsWith('.music.youtube.com');
    return isMusicHost;
  }

  /*
  Future<void> _clearAllCookies() async {
    try {
      await clearYtWebViewSessionData();
      await _showStyledDialog(
        title: 'Sesión limpiada',
        message: 'Las cookies y datos del WebView se eliminaron correctamente.',
        icon: Icons.check_circle_outline_rounded,
      );
    } catch (_) {
      await _showStyledDialog(
        title: 'No se pudo limpiar',
        message: 'No se pudieron eliminar las cookies del WebView.',
        icon: Icons.error_outline_rounded,
      );
    }
  }
  */

  Future<String?> _extractCookieHeader() async {
    final manager = CookieManager.instance();
    final targets = <WebUri>[
      WebUri(_ytMusicMainUrl),
      WebUri('https://www.youtube.com/'),
      WebUri('https://youtube.com/'),
    ];

    final mergedByName = <String, String>{};
    for (final target in targets) {
      try {
        final cookies = await manager.getCookies(url: target);
        for (final cookie in cookies) {
          final name = cookie.name.trim();
          final value = cookie.value.trim();
          if (name.isEmpty || value.isEmpty) continue;
          mergedByName[name] = value;
        }
      } catch (_) {
        // Continuar con otros dominios.
      }
    }

    if (mergedByName.isEmpty) return null;
    return mergedByName.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join('; ');
  }

  Future<void> _tryFinishWithCookies(Uri? uri) async {
    if (_capturingCookies) return;
    if (!_isYtMusicMainPage(uri)) return;

    _capturingCookies = true;
    final cookieHeader = await _extractCookieHeader();
    if (!mounted) return;

    if (cookieHeader == null || cookieHeader.trim().isEmpty) {
      _capturingCookies = false;
      await _showStyledDialog(
        title: 'No se pudo iniciar sesión',
        message: 'No se pudieron extraer cookies, intenta de nuevo.',
        icon: Icons.error_outline_rounded,
      );
      return;
    }

    Navigator.of(context).pop(cookieHeader);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Iniciar sesión YouTube')),
      body: Column(
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: _showProgress
                ? LinearProgressIndicator(
                    key: const ValueKey('yt_cookie_login_progress'),
                    value: _progress >= 100 ? null : _progress / 100,
                  )
                : const SizedBox.shrink(
                    key: ValueKey('yt_cookie_login_progress_hidden'),
                  ),
          ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(_ytLoginUrl)),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                thirdPartyCookiesEnabled: true,
                clearCache: false,
                userAgent:
                    'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 '
                    '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
              ),
              onLoadStart: (controller, url) {
                setState(() {
                  _showProgress = true;
                  _currentUrl = url?.toString();
                });
                unawaited(_tryFinishWithCookies(url?.uriValue));
              },
              onLoadStop: (controller, url) async {
                if (!mounted) return;
                setState(() {
                  _showProgress = false;
                  _progress = 100;
                  _currentUrl = url?.toString();
                });
                await _tryFinishWithCookies(url?.uriValue);
              },
              onProgressChanged: (controller, progress) {
                if (!mounted) return;
                setState(() {
                  _showProgress = progress < 100;
                  _progress = progress;
                });
              },
            ),
          ),
          if (_currentUrl != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(
                _currentUrl!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

Future<void> clearYtWebViewSessionData() async {
  try {
    await CookieManager.instance().deleteAllCookies();
  } catch (_) {
    // Ignorar; intentaremos limpiar otros almacenamientos.
  }

  try {
    final webStorage = WebStorageManager.instance();
    await webStorage.deleteAllData();
  } catch (_) {
    // Algunos entornos no soportan esta limpieza completa.
  }
}
