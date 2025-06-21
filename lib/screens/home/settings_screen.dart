import 'package:flutter/material.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ajustes')),
      body: const Center(
        child: Text(
          'Pantalla de ajustes (vacía por ahora)',
          style: TextStyle(fontSize: 18),
        ),
      ),
    );
  }
}
