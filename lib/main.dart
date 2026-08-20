import "package:flutter/material.dart";

import "package:thortoolbox/src/settings_page.dart";

void main() => runApp(const LauncherApp());

class LauncherApp extends StatelessWidget {
  const LauncherApp({super.key});

  static const _seed = Color(0xFF3F7FBF);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "AYN Thor",
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: _seed, brightness: Brightness.light),
      darkTheme: ThemeData(colorSchemeSeed: _seed, brightness: Brightness.dark),

      themeMode: ThemeMode.system,
      home: const SettingsPage(),
    );
  }
}
