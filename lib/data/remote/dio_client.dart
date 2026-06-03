import 'package:dio/dio.dart';
import '../../utils/logger.dart';

class DioClient {
  DioClient._();

  static Dio get instance => _instance;

  static final Dio _instance = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
    ),
  )..interceptors.addAll([
      LogInterceptor(
        requestBody: true,
        responseBody: true,
        logPrint: (log) => appLogger.d(log),
      ),
    ]);
}
