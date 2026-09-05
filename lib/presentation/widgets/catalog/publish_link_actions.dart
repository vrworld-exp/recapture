// lib/presentation/widgets/catalog/publish_link_actions.dart
//
// Copy / Share / Open for the public catalog link.
//
// One widget, used by the publish screen's success card and the QR screen, so
// the two can never drift into offering different actions for the same link.
//
// WHICH BUTTONS APPEAR IS ASKED, NOT ASSUMED. `CatalogLinkActions` reports what
// the platform can do (a share sheet exists on a phone; a new tab exists in a
// browser) and this renders only those. That is a genuine capability
// difference — the kind `kIsWeb` is for — but it is still not spelled `kIsWeb`
// here, because the day a desktop target lands with a different mix, the
// capability flags move and this file does not.
//
// THE COPY CONFIRMATION IS PART OF THE FEATURE. Copying puts nothing on screen
// by itself, and on web the clipboard write can be refused outright (an
// insecure context, a browser that wants a user gesture it did not see). A
// button that silently may or may not have worked is worse than one that says
// which.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/catalog_link_service.dart';
import 'catalog_feedback.dart';

class PublishLinkActions extends ConsumerWidget {
  const PublishLinkActions({super.key, required this.url});

  /// `catalog.publicUrl`, VERBATIM. Never composed, normalised or rebuilt —
  /// every printed QR resolves through it (feature 32).
  final String url;

  Future<void> _run(
    BuildContext context,
    Future<void> Function() action,
    String confirmation,
  ) async {
    final messenger = CatalogFeedback.of(context);
    try {
      await action();
      CatalogFeedback.confirm(messenger, confirmation);
    } catch (_) {
      // Mapped copy only. A clipboard refusal or a dismissed share sheet
      // arrives as a platform exception whose text is not for a user — and it
      // carries no envelope code either, so this is one sentence written here.
      CatalogFeedback.confirm(
        messenger,
        "That didn't work — you can select the link above and copy it by hand.",
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ref.watch(catalogLinkActionsProvider);

    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        OutlinedButton.icon(
          key: const ValueKey('link_copy'),
          icon: const Icon(Icons.link, size: 16),
          label: const Text('Copy link'),
          onPressed: () =>
              _run(context, () => actions.copy(url), 'Link copied.'),
        ),
        if (actions.canShare)
          OutlinedButton.icon(
            key: const ValueKey('link_share'),
            icon: const Icon(Icons.ios_share, size: 16),
            label: const Text('Share'),
            onPressed: () => _run(
              context,
              () => actions.share(url, subject: 'My catalog'),
              'Shared.',
            ),
          ),
        if (actions.canOpen)
          OutlinedButton.icon(
            key: const ValueKey('link_open'),
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('Open'),
            onPressed: () =>
                _run(context, () => actions.open(url), 'Opened in a new tab.'),
          ),
      ],
    );
  }
}
