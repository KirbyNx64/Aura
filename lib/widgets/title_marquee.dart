import 'dart:async';
import 'package:flutter/material.dart';
import 'package:music/widgets/marquee.dart';

class TitleMarquee extends StatefulWidget {
  final String text;
  final double maxWidth;
  final TextStyle? style;

  const TitleMarquee({
    super.key,
    required this.text,
    required this.maxWidth,
    this.style,
  });

  @override
  State<TitleMarquee> createState() => _TitleMarqueeState();
}

class _TitleMarqueeState extends State<TitleMarquee> {
  bool _showMarquee = false;
  Timer? _marqueeTimer;

  @override
  void didUpdateWidget(covariant TitleMarquee oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      // Cancelar timer anterior si existe
      _marqueeTimer?.cancel();
      setState(() => _showMarquee = false);

      // Crear nuevo timer para la nueva canción
      _marqueeTimer = Timer(const Duration(milliseconds: 3000), () {
        if (mounted) setState(() => _showMarquee = true);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _marqueeTimer = Timer(const Duration(milliseconds: 3000), () {
      if (mounted) setState(() => _showMarquee = true);
    });
  }

  @override
  void dispose() {
    _marqueeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Sanitize style to ensure fontSize is finite
    TextStyle? safeStyle = widget.style;
    if (safeStyle?.fontSize != null && !safeStyle!.fontSize!.isFinite) {
      safeStyle = safeStyle.copyWith(fontSize: 14.0);
    }

    final textPainter = TextPainter(
      text: TextSpan(text: widget.text, style: safeStyle),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();

    final textWidth = textPainter.size.width;

    final double height = textPainter.height * 1.2;

    if (textWidth > widget.maxWidth) {
      if (!_showMarquee) {
        return SizedBox(
          height: height,
          width: widget.maxWidth,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              widget.text,
              style: safeStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      }
      return SizedBox(
        height: height,
        width: widget.maxWidth,
        child: Center(
          child: Marquee(
            key: ValueKey(widget.text),
            text: widget.text,
            style: safeStyle,
            velocity: 30.0,
            blankSpace: 120.0,
            startPadding: 0.0,
            fadingEdgeStartFraction: 0.1,
            fadingEdgeEndFraction: 0.1,
            showFadingOnlyWhenScrolling: false,
            pauseAfterRound: const Duration(seconds: 3),
          ),
        ),
      );
    } else {
      return SizedBox(
        height: height,
        width: widget.maxWidth,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            widget.text,
            style: safeStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
  }
}
