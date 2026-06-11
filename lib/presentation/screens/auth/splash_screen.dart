// lib/presentation/screens/auth/splash_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../widgets/app_loading_indicator.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  bool _showTagline = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) setState(() => _showTagline = true);
    });
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) context.go(AppRoutes.auth);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: AppColors.mirageRed,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: const Icon(Icons.videocam, color: Colors.white, size: 32),
                  ),
                  const SizedBox(height: AppSpacing.xxl),
                  Text(
                    'ReCapture',
                    style: Theme.of(context).textTheme.displayLarge,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  AnimatedOpacity(
                    opacity: _showTagline ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 400),
                    child: Text(
                      'Preparing capture tools…',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(bottom: AppSpacing.huge),
            child: AppLoadingIndicator(size: 24),
          ),
        ],
      ),
    );
  }
}
