// lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'app/app.dart';
import 'utils/app_env.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // ignore: avoid_print
  print(
      '[ReCapture] env=${kAppEnvironment.name}  file=${kAppEnvironment.envFileName}');
  try {
    await dotenv.load(fileName: kAppEnvironment.envFileName);
  } catch (_) {
    // ignore: avoid_print
    print(
        '[ReCapture] WARNING: ${kAppEnvironment.envFileName} not found — env vars will be empty.');
  }
  await Hive.initFlutter();
  runApp(const ProviderScope(child: ReCapture()));
}
