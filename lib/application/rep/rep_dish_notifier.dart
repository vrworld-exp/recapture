// lib/application/rep/rep_dish_notifier.dart
//
// ONE dish on a delegated catalog: read it, edit it, replace its photo.
//
// THE HALF THE REP SURFACE WAS MISSING. Adding a dish has worked since stage 10;
// changing one had no door at all. A typo in a name, a price the owner revised
// at the table after the dish was entered, a photo shot before the kitchen
// plated it properly — every one of those needed the RESTAURANT to sign in and
// fix it later, while the person who could actually see the problem was standing
// in the room.
//
// Mirrors [ProductDetailNotifier] deliberately, down to the save-step enum and
// the commit-retry rule, and differs in exactly two places:
//   • it writes through /rep, so ownership comes from the delegation;
//   • it touches only the REP's own surfaces, never the owner's grid or catalog
//     header — those belong to a different user's catalog. See [_adopt] for why
//     even that is an invalidate rather than a read.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/catalog_products_repository.dart'
    show kCatalogUnchanged;
import '../../data/repositories/rep_repository.dart';
import '../../domain/entities/catalog_product.dart';
import '../../domain/entities/product_availability.dart';
import 'rep_restaurant_notifier.dart';

/// Which dish, on which restaurant.
///
/// A record rather than a bare product id: the delegated routes need both, and
/// records carry structural equality, so two reads of the same dish land on the
/// same provider instead of two racing fetches.
typedef RepDishRef = ({String catalogId, String productId});

/// Which leg of a save is running.
///
/// Named for the same reason the owner editor names its own: replacing a photo
/// is TWO round trips and the slow one is the upload. One undifferentiated
/// spinner over a 5 MiB body on restaurant wifi reads as a hang, and the two
/// halves fail for different reasons and retry differently.
enum RepDishSaveStep {
  idle,

  /// Bytes on the wire.
  uploadingImage,

  /// Binding the uploaded object to the dish.
  saving,
}

class RepDishNotifier
    extends AutoDisposeFamilyAsyncNotifier<CatalogProduct, RepDishRef> {
  RepRepository get _repo => ref.read(repRepositoryProvider);

  /// Which leg of a save is running. Not part of [state] because it is not the
  /// dish: an `AsyncValue` that flipped to loading mid-save would blank the form
  /// the rep is typing in.
  final ValueNotifier<RepDishSaveStep> step =
      ValueNotifier(RepDishSaveStep.idle);

  /// A photo that uploaded successfully but whose SAVE failed.
  ///
  /// Held so the retry is the save alone: the bytes are already in the bucket
  /// under this key, and asking a rep on café wifi to re-send 5 MiB because our
  /// second call failed is charging them for our problem.
  String? _uncommittedImageKey;

  String? get uncommittedImageKey => _uncommittedImageKey;

  @override
  Future<CatalogProduct> build(RepDishRef arg) async {
    ref.onDispose(step.dispose);
    return _repo.product(arg.catalogId, arg.productId);
  }

  /// Patches the editable fields.
  ///
  /// [price] and [categoryId] take the repository's sentinel semantics: pass
  /// null to CLEAR (no price / Uncategorized), omit to leave alone. Nothing else
  /// distinguishes "clear this" from "I did not touch it", and both are ordinary
  /// things a rep does at a table.
  ///
  /// Throws [CatalogFailure] and leaves state untouched, so the editor keeps the
  /// failure beside the fields the rep typed and never blanks the form.
  Future<CatalogProduct> save({
    String? name,
    String? description,
    Object? price = kCatalogUnchanged,
    Object? categoryId = kCatalogUnchanged,
    ProductAvailability? availability,
    String? imageKey,
  }) async {
    step.value = RepDishSaveStep.saving;
    try {
      final updated = await _repo.updateProduct(
        arg.catalogId,
        arg.productId,
        name: name,
        description: description,
        price: price,
        categoryId: categoryId,
        availability: availability,
        imageKey: imageKey,
      );
      // Only now: a save that threw leaves the key pending so the retry can
      // reuse it, and clearing it here would send the rep back to the picker.
      if (imageKey != null) _uncommittedImageKey = null;
      _adopt(updated);
      return updated;
    } finally {
      step.value = RepDishSaveStep.idle;
    }
  }

  /// Uploads a replacement photo and returns the key it landed on.
  ///
  /// Does NOT bind it — binding happens in [save], with the rest of the form, so
  /// a rep who changes the name and the photo together sends ONE write and
  /// cannot end up with half of it applied. The key is remembered in
  /// [uncommittedImageKey] so a failed save retries the save, never the upload.
  Future<String> uploadImage(
    Uint8List bytes, {
    required String contentType,
  }) async {
    step.value = RepDishSaveStep.uploadingImage;
    try {
      final key = await _repo.uploadImageBytes(
        arg.catalogId,
        bytes,
        contentType: contentType,
        productId: arg.productId,
      );
      _uncommittedImageKey = key;
      return key;
    } finally {
      step.value = RepDishSaveStep.idle;
    }
  }

  /// Adopts a server-returned dish and tells the surfaces that show it.
  void _adopt(CatalogProduct updated) {
    state = AsyncData(updated);

    // Every write bumps `draftRevision`, which is what the "not live yet" lines
    // on the details and preview screens read. INVALIDATE rather than reach for
    // the notifier: this editor is deep-linkable, so on a browser reload
    // straight onto it there is no catalog header alive to update, and
    // `ref.read(...notifier)` would BUILD one — a request nobody asked for, and
    // for `repCatalogProductsProvider`, a poll loop with no screen to die with.
    // Invalidate refreshes what is being watched and is a no-op for what is
    // not, which is exactly the rule this wants.
    ref.invalidate(repCatalogDocumentProvider(arg.catalogId));

    // The dish LIST is deliberately not touched here. Both screens that can
    // reach this editor already re-read on the way back — that path keeps the
    // rows on screen while it loads, where an invalidate from here would blank
    // them to a spinner and then race the screen's own read.
  }
}

/// ONE dish on a delegated catalog.
///
/// autoDispose and family-keyed: the fetch dies with the screen, and two dishes
/// never share a slot. It is also the resolver for a COLD DEEP LINK — a browser
/// reload on `/rep/catalogs/x/dishes/y` carries nothing but the two ids.
final repDishProvider = AsyncNotifierProvider.autoDispose
    .family<RepDishNotifier, CatalogProduct, RepDishRef>(
  RepDishNotifier.new,
);
