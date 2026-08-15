import 'package:flutter/material.dart';

import 'screens/demo_chat_screen.dart';
import 'screens/home_screen.dart';

const kDshBlue = Color(0xFF4D6BFE);
const kBackground = Color(0xFFF9FAFB);
const kSurface = Color(0xFFFFFFFF);
const kBorder = Color(0xFFE5E7EB);
const kTextPrimary = Color(0xFF111827);
const kTextSecondary = Color(0xFF6B7280);

void main() {
  runApp(const DshRemoteApp());
}

class DshRemoteApp extends StatelessWidget {
  const DshRemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: kDshBlue,
      primary: kDshBlue,
      surface: kSurface,
    );
    final isDemoChat = Uri.base.queryParameters['demo'] == 'chat';
    return MaterialApp(
      title: 'DSH Remote',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: kBackground,
        appBarTheme: const AppBarTheme(
          backgroundColor: kSurface,
          foregroundColor: kTextPrimary,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF3F4F6),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: kBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: kDshBlue, width: 1.5),
          ),
        ),
        cardTheme: CardThemeData(
          color: kSurface,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: kBorder),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: kDshBlue,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
      home: isDemoChat ? const DemoChatScreen() : const HomeScreen(),
    );
  }
}
