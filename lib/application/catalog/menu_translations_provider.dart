// lib/application/catalog/menu_translations_provider.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/menu_translations_repository.dart';

/// The Translations screen's data (more-customization Stage 6): the profile
/// (languages, announcement / badge text), every dish and every section.
///
/// autoDispose: it is a whole-catalog read, wanted only while that screen is
/// open, and a fresh open should show what other screens changed meanwhile.
/// Null when the owner has no catalog yet.
final menuTranslationsProvider = FutureProvider.autoDispose<MenuTranslationsData?>(
  (ref) => ref.watch(menuTranslationsRepositoryProvider).load(),
);
