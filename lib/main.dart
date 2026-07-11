// lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app/app.dart';
import 'data/local/hive_init.dart';
import 'utils/app_env.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // ignore: avoid_print
  print(
      '[ReCapture] env=${kAppEnvironment.name}  file=${kAppEnvironment.envFileName}');
  await _loadEnv();
  await initHive();
  runApp(const ProviderScope(child: ReCapture()));
}

/// Loads the per-environment file (.env.dev/.env.staging/.env.prod) with the
/// root `.env` as an override: any value set in `.env` (e.g. API_BASE_URL) is
/// what the app uses; commented-out lines in `.env` fall through to the
/// environment file's value. Missing files are skipped (isOptional).
Future<void> _loadEnv() async {
  await dotenv.load(
    fileName: kAppEnvironment.envFileName,
    overrideWithFiles: ['.env'],
    isOptional: true,
  );
  // ignore: avoid_print
  print('[ReCapture] API_BASE_URL=${dotenv.env['API_BASE_URL'] ?? '(unset)'}');
}
