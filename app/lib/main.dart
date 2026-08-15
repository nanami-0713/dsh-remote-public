import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

void main() {
  runApp(const DshRemoteApp());
}

class DshRemoteApp extends StatelessWidget {
  const DshRemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DSH Remote',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
