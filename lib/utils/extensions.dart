// lib/utils/extensions.dart
//
// Dart extension methods used across the app.

/// Relative-time formatting for timestamps shown in the UI.
extension DateTimeRelative on DateTime {
  /// Compact "time ago" label, e.g. "Just now", "5m ago", "2h ago", "3d ago".
  /// Falls back to a short date for anything older than ~a week.
  String get timeAgo {
    final diff = DateTime.now().difference(this);
    if (diff.isNegative) return 'Just now';
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '$day/$month/$year';
  }
}
