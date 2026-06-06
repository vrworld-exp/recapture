import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'app/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load environment variables FIRST
  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {
    debugPrint(
      'ERROR: .env file not found. Copy .env.example to .env and fill in values.',
    );
    exit(1);
  }

  // Init Hive at app documents directory
  try {
    await Hive.initFlutter();
  } catch (e) {
    debugPrint('ERROR: Hive initialisation failed: $e');
    exit(1);
  }

  runApp(
    const ProviderScope(
      child: ReCapture(),
    ),
  );
}



