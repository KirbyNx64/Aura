import 'package:flutter/material.dart';
import 'package:music/widgets/marquee.dart';

class TitleMarquee extends StatelessWidget {
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
  Widget build(BuildContext context) {
    // Sanitize style to ensure fontSize is finite
    TextStyle? safeStyle = style;
    if (safeStyle?.fontSize != null && !safeStyle!.fontSize!.isFinite) {
      safeStyle = safeStyle.copyWith(fontSize: 14.0);
    }

    final textPainter = TextPainter(
      text: TextSpan(text: text, style: safeStyle),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();

    final textWidth = textPainter.size.width;
    final double height = textPainter.height * 1.2;

    if (textWidth > maxWidth) {
      // Siempre usar Marquee desde el inicio, con delay de 3s antes de scrollear
      return SizedBox(
        height: height,
        width: maxWidth,
        child: ShaderMask(
          shaderCallback: (Rect bounds) {
            return LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: const [Colors.white, Colors.white, Colors.transparent],
              // El último 10% del ancho se desvanece (siempre presente)
              stops: const [0.0, 0.9, 1.0],
            ).createShader(bounds);
          },
          blendMode: BlendMode.dstIn,
          child: Center(
            child: Marquee(
              key: ValueKey(text),
              text: text,
              style: safeStyle,
              velocity: 30.0,
              blankSpace: 120.0,
              startPadding: 0.0,
              startAfter: const Duration(seconds: 3),
              fadingEdgeStartFraction: 0.1,
              fadingEdgeEndFraction:
                  0.0, // El fading derecho se maneja en ShaderMask
              showFadingOnlyWhenScrolling: false,
              pauseAfterRound: const Duration(seconds: 3),
            ),
          ),
        ),
      );
    } else {
      return SizedBox(
        height: height,
        width: maxWidth,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            text,
            style: safeStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
  }
}
