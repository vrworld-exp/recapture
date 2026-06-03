import 'package:flutter/material.dart';
import 'utils/constants.dart';
import 'utils/theme.dart';

void main() {
  runApp(const RecaptureApp());
}

class RecaptureApp extends StatelessWidget {
  const RecaptureApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: const Scaffold(
        body: Center(
          child: Text(
            AppConstants.appName,
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
