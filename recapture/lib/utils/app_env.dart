// lib/utils/app_env.dart

/// The build-time environment for this ReCapture binary.
///
/// Set via --dart-define=ENV=dev|staging|prod at flutter run / flutter build.
/// Defaults to 'dev' if ENV is not provided (safe for local development).
///
/// HOW IT WORKS:
///   String.fromEnvironment reads a value injected by --dart-define at compile time.
///   This is NOT a runtime value — changing .env files does not change this.
///   You must rebuild the app to change the environment.
///
/// USAGE:
///   flutter run --dart-define=ENV=dev       → AppEnvironment.dev
///   flutter run --dart-define=ENV=staging   → AppEnvironment.staging
///   flutter build apk --dart-define=ENV=prod → AppEnvironment.prod
///
///   Or use the Makefile targets (recommended):
///   make run.dev
///   make run.staging
///   make build.apk.prod
enum AppEnvironment {
  dev,
  staging,
  prod;

  /// The env file name to load for this environment.
  /// Loaded by flutter_dotenv in main.dart.
  String get envFileName => switch (this) {
    AppEnvironment.dev     => '.env.dev',
    AppEnvironment.staging => '.env.staging',
    AppEnvironment.prod    => '.env.prod',
  };

  /// Human-readable name for logging and debug banners.
  String get displayName => switch (this) {
    AppEnvironment.dev     => 'Development',
    AppEnvironment.staging => 'Staging',
    AppEnvironment.prod    => 'Production',
  };

  /// Whether this is a production build.
  /// Use to gate debug-only features, verbose logging, etc.
  bool get isProduction => this == AppEnvironment.prod;

  /// Whether debug-level logging should be enabled.
  bool get isDebugLogging => this != AppEnvironment.prod;
}

/// The current build environment, determined at compile time.
///
/// Reads the --dart-define=ENV value baked in at build time.
/// Falls back to [AppEnvironment.dev] if ENV is not provided.
///
/// This constant is evaluated once at startup and never changes at runtime.
final AppEnvironment kAppEnvironment = _resolveEnvironment();

AppEnvironment _resolveEnvironment() {
  const envString = String.fromEnvironment('ENV', defaultValue: 'dev');
  return switch (envString.toLowerCase()) {
    'staging' => AppEnvironment.staging,
    'prod'    => AppEnvironment.prod,
    _         => AppEnvironment.dev, // dev is safe fallback for any unrecognised value
  };
}
