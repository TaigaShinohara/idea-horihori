import 'package:flutter/material.dart';

import 'app_config.dart';
import 'screens/home_screen.dart';
import 'store.dart';
import 'widgets/glass.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = IdeaStore();
  await store.load();
  runApp(HorihoriApp(store: store));
}

class HorihoriApp extends StatelessWidget {
  final IdeaStore store;
  const HorihoriApp({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: kAccent),
        scaffoldBackgroundColor: Colors.transparent,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme:
            ColorScheme.fromSeed(seedColor: kAccent, brightness: Brightness.dark),
        scaffoldBackgroundColor: Colors.transparent,
      ),
      home: HomeScreen(store: store),
    );
  }
}
