// lib/utils/constants.dart
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'app_env.dart';

/// Runtime + compile-time configuration for ReCapture.
///
/// Values are sourced from two places:
///   1. flutter_dotenv (.env.dev / .env.staging / .env.prod loaded at startup)
///      → runtime values, readable after dotenv.load() completes in main.dart
///   2. dart-define (--dart-define=KEY=value at flutter run / flutter build)
///      → compile-time constants, available immediately via String.fromEnvironment
///
/// RULE: Never hardcode environment-specific values (URLs, keys, flags) anywhere
/// in the codebase. Always read from AppConfig.
///
/// USAGE:
///   AppConfig.apiBaseUrl        → 'https://recapture-api.onrender.com'
///   AppConfig.environment       → AppEnvironment.prod
///   AppConfig.isProduction      → true
abstract final class AppConfig {

  // ── App Identity ─────────────────────────────────────────────────────────

  static const String appName     = 'ReCapture';
  static const String packageName = 'com.mayasabhaxr.recapture';

  // ── Environment ──────────────────────────────────────────────────────────

  /// Current build environment (dev / staging / prod).
  /// Determined at compile time via --dart-define=ENV.
  static AppEnvironment get environment => kAppEnvironment;

  /// Convenience alias.
  static bool get isProduction => kAppEnvironment.isProduction;

  /// Convenience alias.
  static bool get isDebugLogging => kAppEnvironment.isDebugLogging;

  // ── API ──────────────────────────────────────────────────────────────────

  /// Base URL for the recapture-api backend.
  /// Read from dotenv key API_BASE_URL.
  /// Falls back to localhost:3000 for safety — never crashes if key is missing.
  static String get apiBaseUrl =>
      dotenv.env['API_BASE_URL'] ?? 'http://localhost:3000';

  /// API request connect timeout.
  static const Duration connectTimeout = Duration(seconds: 15);

  /// API request receive timeout.
  static const Duration receiveTimeout = Duration(seconds: 30);

  /// API upload timeout — longer for chunked photo uploads.
  static const Duration uploadTimeout = Duration(minutes: 10);

  // ── Storage ──────────────────────────────────────────────────────────────

  /// CloudFront base URL for model/artifact delivery.
  /// Read from dotenv key CLOUDFRONT_BASE_URL.
  static String get cloudfrontBaseUrl =>
      dotenv.env['CLOUDFRONT_BASE_URL'] ?? '';

  // ── Hive Box Names ────────────────────────────────────────────────────────

  static const String boxSession  = 'session';
  static const String boxProjects = 'projects';
  static const String boxCapture  = 'capture';
  static const String boxUpload   = 'upload';

  // ── Native Channel Names ──────────────────────────────────────────────────
  // Must match channel IDs in Android CaptureModule.kt and iOS CaptureModuleController.swift

  static const String channelCapture = 'com.mayasabhaxr.recapture/capture';
  static const String channelSensors = 'com.mayasabhaxr.recapture/sensors';

  // ── Feature Flags ─────────────────────────────────────────────────────────

  /// Whether manual capture mode is available in this build.
  static bool get manualCaptureEnabled =>
      dotenv.env['FEATURE_MANUAL_CAPTURE'] == 'true';

  /// Whether the AR preview feature is enabled in this build.
  static bool get arPreviewEnabled =>
      dotenv.env['FEATURE_AR_PREVIEW'] != 'false'; // default true

  // ── Capture Defaults ─────────────────────────────────────────────────────

  static const int defaultSegmentCountSmall  = 36;
  static const int defaultSegmentCountMedium = 30;
  static const int defaultSegmentCountLarge  = 24;
  static const int minPhotosPerRingSmall     = 30;
  static const int minPhotosPerRingMedium    = 24;
  static const int minPhotosPerRingLarge     = 18;
}
