// lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'utils/app_env.dart';
import 'utils/constants.dart';
import 'utils/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await dotenv.load(fileName: kAppEnvironment.envFileName);
  } catch (e) {
    // ignore: avoid_print
    print('❌ Failed to load ${kAppEnvironment.envFileName}: $e');
    // ignore: avoid_print
    print('   Copy .env.example to ${kAppEnvironment.envFileName} and fill in values.');
    rethrow;
  }

  // ignore: avoid_print
  print('🌍 ReCapture [${kAppEnvironment.displayName}] | API: ${AppConfig.apiBaseUrl}');

  runApp(const RecaptureApp());
}

class RecaptureApp extends StatelessWidget {
  const RecaptureApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: const Scaffold(
        body: Center(
          child: Text(
            AppConfig.appName,
            style: TextStyle(
              color: AppColors.primaryText,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}
