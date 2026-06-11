// lib/presentation/widgets/app_scaffold.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_typography.dart';

/// Standard AppBar for ReCapture skeleton screens.
/// If showBack is true and context.canPop(), shows a back arrow using context.pop().
/// If showBack is true but context.canPop() is false, no back arrow is shown.
AppBar rcAppBar(
  BuildContext context, {
  required String title,
  List<Widget>? actions,
  bool showBack = true,
}) {
  return AppBar(
    backgroundColor: AppColors.bgPrimary,
    elevation: 0,
    scrolledUnderElevation: 0,
    title: Text(
      title,
      style: const TextStyle(
        color: AppColors.textPrimary,
        fontSize: AppTypography.sizeHeadline,
        fontWeight: FontWeight.w600,
      ),
    ),
    leading: showBack
        ? IconButton(
            icon: const Icon(Icons.arrow_back_ios_new,
                color: AppColors.textPrimary, size: 18),
            onPressed: () {
              if (context.canPop()) {
                context.pop();
              }
            },
          )
        : null,
    automaticallyImplyLeading: false,
    actions: actions,
  );
}
