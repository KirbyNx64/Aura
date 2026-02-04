import 'package:flutter/material.dart';
import 'package:material_loading_indicator/loading_indicator.dart';

class HomeLoadingScreen extends StatelessWidget {
  const HomeLoadingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: Center(child: LoadingIndicator()));
  }
}
