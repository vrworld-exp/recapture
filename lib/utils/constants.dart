// ─── PREVIOUS CONTENT (backed up — P0 scaffold applied 2026-06-08) ──────────
// import 'package:flutter/foundation.dart';
// import 'package:flutter_dotenv/flutter_dotenv.dart';
//
// abstract final class AppConstants {
//   static String get apiBaseUrl {
//     final url = dotenv.env['API_BASE_URL'];
//     if (url == null || url.isEmpty) {
//       debugPrint('WARNING: API_BASE_URL not set in .env — falling back to localhost.');
//       return 'http://localhost:3000';
//     }
//     return url;
//   }
//
//   static const Duration connectTimeout = Duration(seconds: 15);
//   static const Duration receiveTimeout = Duration(seconds: 30);
//
//   static const String boxSession = 'session';
//   static const String boxProjects = 'projects';
//   static const String boxCapture = 'capture';
//
//   static const String channelCapture = 'com.mayasabhaxr.recapture/capture';
//   static const String channelSensors = 'com.mayasabhaxr.recapture/sensors';
// }
// ─────────────────────────────────────────────────────────────────────────────

// lib/utils/constants.dart
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

abstract final class AppConfig {
  static String get apiBaseUrl {
    final url = dotenv.env['API_BASE_URL'];
    if (url == null || url.isEmpty) {
      debugPrint('WARNING: API_BASE_URL not set — falling back to localhost.');
      return 'http://localhost:3000';
    }
    return url;
  }

  static const Duration connectTimeout = Duration(seconds: 15);
  static const Duration receiveTimeout = Duration(seconds: 30);

  static const String boxSession = 'session';
  static const String boxProjects = 'projects';
  static const String boxCapture = 'capture';

  static const String channelCapture = 'com.mayasabhaxr.recapture/capture';
  static const String channelSensors = 'com.mayasabhaxr.recapture/sensors';
  static const String channelCaptureEvents = 'com.mayasabhaxr.recapture/captureEvents';
}
