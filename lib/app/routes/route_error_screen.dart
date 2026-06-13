// lib/app/routes/route_error_screen.dart
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../../presentation/widgets/app_button.dart';

/// Shown by GoRouter's `errorBuilder` for unmatched / malformed routes. The
/// "Back to home" action is supplied by the router so it can respect auth state
/// (Projects Hub when signed in, login otherwise).
class RouteErrorScreen extends StatelessWidget {
  const RouteErrorScreen({super.key, required this.onGoHome});

  final VoidCallback onGoHome;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xxl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.explore_off_outlined,
                    color: AppColors.textMuted, size: 48),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  'Page not found',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  "That screen doesn't exist or the link is broken.",
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: AppColors.textSecondary),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.xxl),
                AppButton(
                  label: 'Back to home',
                  icon: Icons.home_outlined,
                  isFullWidth: false,
                  onPressed: onGoHome,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
