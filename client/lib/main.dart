import 'package:flutter/material.dart';

import 'src/connect_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const JumpApp());
}

class JumpApp extends StatelessWidget {
  const JumpApp({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF4F8CFF),
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: const Color(0xFF0B0D10),
    );
    return MaterialApp(
      title: 'Wherever',
      debugShowCheckedModeBanner: false,
      theme: theme,
      darkTheme: theme,
      themeMode: ThemeMode.dark,
      home: const ConnectPage(),
    );
  }
}
