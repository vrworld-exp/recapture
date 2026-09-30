// Stage 16 — which outlet the owner is editing.
//
// The API scopes every `/catalog/…` call by the `X-Outlet-Id` header (absent =
// the main / only outlet, which is how every standalone restaurant works). The
// selected id lives here, next to the interceptor that sends it, so the whole
// app switches outlet by changing one provider.
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The outlet being edited, or null for the main / only one.
final selectedOutletIdProvider = StateProvider<String?>((ref) => null);

class OutletInterceptor extends Interceptor {
  OutletInterceptor(this._ref);

  final Ref _ref;

  static const header = 'X-Outlet-Id';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final outletId = _ref.read(selectedOutletIdProvider);
    final path = options.path;
    final isCatalogCall = path == '/catalog' || path.startsWith('/catalog/') ||
        path.startsWith('/catalog?');
    if (outletId != null && isCatalogCall && !options.headers.containsKey(header)) {
      options.headers[header] = outletId;
    }
    handler.next(options);
  }
}
