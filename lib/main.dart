import 'dart:async';

import 'package:flutter/material.dart';

import 'pages/home_page.dart';
import 'services/background_service.dart';
import 'services/hotspot_service.dart';
import 'services/share_intent_service.dart';
import 'services/tcp_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  HotspotService.instance.attach(TcpService.instance);
  BackgroundService.instance.attach(TcpService.instance);
  unawaited(ShareIntentService.instance.init());
  runApp(const LanShareApp());
}

/// Root widget for the LANShare app.
///
/// The app has no backend and no persistent app-level state beyond what
/// [TcpService] (a simple singleton) tracks in memory, so a plain
/// MaterialApp with a fixed set of pages is all that's needed.
class LanShareApp extends StatelessWidget {
  const LanShareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LANShare',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
        appBarTheme: const AppBarTheme(centerTitle: true),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            minimumSize: const Size.fromHeight(56),
            textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
        ),
      ),
      home: const HomePage(),
    );
  }
}
