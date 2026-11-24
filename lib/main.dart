import 'dart:async';

import 'package:flutter/material.dart';

import 'app_config.dart';
import 'screens/home_screen.dart';
import 'store.dart';
import 'widgets/glass.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final store = IdeaStore();
  runApp(HorihoriApp(store: store));
  unawaited(store.load());
}

class HorihoriApp extends StatelessWidget {
  final IdeaStore store;
  const HorihoriApp({super.key, required this.store});

  ThemeData _buildTheme(Brightness brightness) {
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: ColorScheme.fromSeed(
        seedColor: kAccent,
        brightness: brightness,
      ),
      scaffoldBackgroundColor: Colors.transparent,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: kButtonFill,
          foregroundColor: Colors.white,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      home: HomeScreen(store: store),
    );
  }
}
