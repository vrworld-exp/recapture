import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

abstract final class AppConstants {
  // API
  static String get apiBaseUrl {
    final url = dotenv.env['API_BASE_URL'];
    if (url == null || url.isEmpty) {
      debugPrint('WARNING: API_BASE_URL not set in .env — falling back to localhost.');
      return 'http://localhost:3000';
    }
    return url;
  }

  static const Duration connectTimeout = Duration(seconds: 15);
  static const Duration receiveTimeout = Duration(seconds: 30);

  // Hive box names — add new boxes here as features are built
  static const String boxSession = 'session';
  static const String boxProjects = 'projects';
  static const String boxCapture = 'capture';

  // Native channel names (must match Android/iOS channel identifiers)
  static const String channelCapture = 'com.mayasabhaxr.recapture/capture';
  static const String channelSensors = 'com.mayasabhaxr.recapture/sensors';
}
