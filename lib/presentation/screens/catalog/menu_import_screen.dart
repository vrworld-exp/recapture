// lib/presentation/screens/catalog/menu_import_screen.dart
//
// "Import menu from photos" (more-customization Stage 13.1) — for the owner at
// `/catalog/import` and for a rep at `/rep/catalogs/:id/import`.
//
//   1. pick up to 10 photos (or one PDF)
//   2. upload each page through our API, then start
//   3. wait while the AI reads (progress per page, polled)
//   4. REVIEW: every dish editable; yellow = check this; a dish already on the
//      menu shows "update price?" instead of being added twice
//   5. apply → dishes appear as drafts (never published by this screen)
//   6. undo, while nobody has edited the imported dishes
import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../data/repositories/ai_repository.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/catalog/menu_import.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';
import '../../widgets/catalog/catalog_feedback.dart';

const int _kMaxPages = 10;
const int _kMaxBytes = 20 * 1024 * 1024;

/// A picked page, bytes in memory.
class _Page {
  const _Page(this.bytes, this.contentType);
  final Uint8List bytes;
  final String contentType;
}

/// Content type from the bytes themselves — never from a file name.
String? sniffPageType(Uint8List b) {
  if (b.length >= 4 && b[0] == 0x25 && b[1] == 0x50 && b[2] == 0x44 && b[3] == 0x46) return 'application/pdf';
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return 'image/jpeg';
  if (b.length >= 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return 'image/png';
  if (b.length >= 12 && b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
      b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
    return 'image/webp';
  }
  return null;
}

enum _Step { pick, sending, reading, review, applying, done }

class MenuImportScreen extends ConsumerStatefulWidget {
  const MenuImportScreen({super.key, this.repCatalogId});

  final String? repCatalogId;

  @override
  ConsumerState<MenuImportScreen> createState() => _MenuImportScreenState();
}

class _MenuImportScreenState extends ConsumerState<MenuImportScreen> {
  final List<_Page> _pages = [];
  _Step _step = _Step.pick;
  MenuImport? _import;
  String? _error;
  int _uploaded = 0;
  Timer? _poll;
  ApplyResult? _result;

  /// Draft key → apply "update price" to the matched existing dish.
  final Map<String, bool> _updateMatch = {};

  AiRepository get _repo => ref.read(aiRepositoryProvider(widget.repCatalogId));

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  // ── 1. pick ──

  Future<void> _pickPhotos() async {
    final files = await ImagePicker().pickMultiImage(
      limit: _kMaxPages,
      imageQuality: 85,
      maxWidth: 2400,
      maxHeight: 2400,
    );
    for (final f in files) {
      await _add(await f.readAsBytes());
    }
  }

  Future<void> _takePhoto() async {
    final f = await ImagePicker().pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
      maxWidth: 2400,
      maxHeight: 2400,
    );
    if (f != null) await _add(await f.readAsBytes());
  }

  Future<void> _pickPdf() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Choose a menu PDF',
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    if (file == null) return;
    final chunks = <int>[];
    await for (final c in file.readAsByteStream()) {
      chunks.addAll(c);
      if (chunks.length > _kMaxBytes) break;
    }
    await _add(Uint8List.fromList(chunks));
  }

  Future<void> _add(Uint8List bytes) async {
    final type = sniffPageType(bytes);
    setState(() {
      if (type == null) {
        _error = 'That file is not a JPG, PNG, WebP or PDF.';
      } else if (bytes.length > _kMaxBytes) {
        _error = 'Each page must be under 20 MB.';
      } else if (_pages.length >= _kMaxPages) {
        _error = 'Up to $_kMaxPages pages per import.';
      } else {
        _pages.add(_Page(bytes, type));
        _error = null;
      }
    });
  }

  // ── 2–3. send + read ──

  Future<void> _send() async {
    setState(() {
      _step = _Step.sending;
      _uploaded = 0;
      _error = null;
    });
    try {
      final created = await _repo.createImport([
        for (final p in _pages) (contentType: p.contentType, size: p.bytes.length),
      ]);
      for (var i = 0; i < _pages.length; i++) {
        await _repo.uploadPage(created.id, i + 1, _pages[i].bytes, _pages[i].contentType);
        if (mounted) setState(() => _uploaded = i + 1);
      }
      final started = await _repo.start(created.id);
      if (!mounted) return;
      setState(() {
        _import = started;
        _step = _Step.reading;
      });
      _poll = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
    } on CatalogFailure catch (f) {
      if (mounted) {
        setState(() {
          _step = _Step.pick;
          _error = f.message;
        });
      }
    }
  }

  Future<void> _refresh() async {
    final id = _import?.id;
    if (id == null) return;
    try {
      final next = await _repo.get(id);
      if (!mounted) return;
      if (next.status == MenuImportStatus.processing) {
        setState(() => _import = next);
        return;
      }
      _poll?.cancel();
      setState(() {
        _import = next;
        if (next.status == MenuImportStatus.ready) {
          _step = _Step.review;
          for (final c in next.categories) {
            for (final i in c.items) {
              final m = next.matches[i.key];
              if (m != null) _updateMatch[i.key] = i.price != null && i.price != m.price;
            }
          }
          _error = next.errorCode == 'PAGES_SKIPPED' ? next.errorMessage : null;
        } else {
          _step = _Step.pick;
          _error = next.errorMessage ?? 'The menu could not be read.';
        }
      });
    } on CatalogFailure {
      // A blip while polling is not an answer; the next tick tries again.
    }
  }

  // ── 5. apply ──

  Future<void> _apply() async {
    final draft = _import!;
    setState(() => _step = _Step.applying);
    final categories = <Map<String, dynamic>>[];
    for (final c in draft.categories) {
      final items = <Map<String, dynamic>>[];
      for (final i in c.items.where((i) => i.include && i.name.trim().isNotEmpty)) {
        final match = draft.matches[i.key];
        if (match != null) {
          // An existing dish: only its price, and only when asked.
          if (_updateMatch[i.key] == true && i.price != null) {
            items.add({'name': i.name.trim(), 'price': i.price, 'updateProductId': match.productId});
          }
          continue;
        }
        items.add({
          'name': i.name.trim(),
          if ((i.description ?? '').trim().isNotEmpty) 'description': i.description!.trim(),
          if (i.price != null) 'price': i.price,
          if (i.variants.length > 1)
            'variants': [for (final v in i.variants) {'label': v.label, 'price': v.price}],
          'foodType': i.foodType,
        });
      }
      if (items.isNotEmpty) categories.add({'name': c.name.trim().isEmpty ? 'Menu' : c.name.trim(), 'items': items});
    }
    try {
      final result = await _repo.apply(draft.id, categories);
      if (mounted) {
        setState(() {
          _result = result;
          _step = _Step.done;
        });
      }
    } on CatalogFailure catch (f) {
      if (mounted) {
        setState(() {
          _step = _Step.review;
          _error = f.message;
        });
      }
    }
  }

  Future<void> _undo() async {
    final messenger = CatalogFeedback.of(context);
    try {
      final (removed, kept) = await _repo.undo(_import!.id);
      if (!mounted) return;
      CatalogFeedback.confirm(
        messenger,
        kept == 0
            ? 'Import undone — $removed dishes removed.'
            : 'Removed $removed dishes. $kept you had already edited were kept.',
      );
      Navigator.of(context).maybePop();
    } on CatalogFailure catch (f) {
      if (mounted) CatalogFeedback.failure(messenger, f, subject: 'undo');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, title: const Text('Import menu')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: switch (_step) {
            _Step.pick => _pickView(),
            _Step.sending => _progress(
                'Uploading page $_uploaded of ${_pages.length}…', _uploaded / (_pages.length + 1)),
            _Step.reading => _progress(
                'Reading your menu… page ${_import?.pagesDone ?? 0} of ${_import?.pages ?? _pages.length}',
                (_import?.pagesDone ?? 0) / ((_import?.pages ?? 1).clamp(1, 99))),
            _Step.review => _reviewView(),
            _Step.applying => _progress('Adding dishes…', null),
            _Step.done => _doneView(),
          },
        ),
      ),
    );
  }

  Widget _progress(String label, double? value) => Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            LinearProgressIndicator(value: value),
            const SizedBox(height: AppSpacing.lg),
            Text(label, textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.sm),
            Text('You can keep this screen open — it usually takes under a minute per page.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textMuted)),
          ],
        ),
      );

  Widget _pickView() {
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: AppColors.textMuted);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      children: [
        Text('Photograph your printed menu', style: text.titleLarge),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'One page per photo, flat and in good light. We read the dishes and prices; you check '
          'them before anything is added. Nothing goes live until you publish.',
          style: muted,
        ),
        const SizedBox(height: AppSpacing.lg),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            OutlinedButton.icon(
              key: const Key('import-camera'),
              icon: const Icon(Icons.photo_camera_outlined),
              label: const Text('Take photo'),
              onPressed: _pages.length >= _kMaxPages ? null : _takePhoto,
            ),
            OutlinedButton.icon(
              key: const Key('import-gallery'),
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Choose photos'),
              onPressed: _pages.length >= _kMaxPages ? null : _pickPhotos,
            ),
            OutlinedButton.icon(
              key: const Key('import-pdf'),
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: const Text('PDF'),
              onPressed: _pages.length >= _kMaxPages ? null : _pickPdf,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        if (_pages.isNotEmpty)
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (var i = 0; i < _pages.length; i++)
                Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox.square(
                        dimension: 84,
                        child: _pages[i].contentType == 'application/pdf'
                            ? const ColoredBox(
                                color: AppColors.surface2,
                                child: Icon(Icons.picture_as_pdf, color: AppColors.textMuted))
                            : Image.memory(_pages[i].bytes, fit: BoxFit.cover),
                      ),
                    ),
                    Positioned(
                      right: 0,
                      top: 0,
                      child: IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => setState(() => _pages.removeAt(i)),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        Text('${_pages.length} of $_kMaxPages pages', style: muted),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.md),
          Text(_error!, style: text.bodySmall?.copyWith(color: AppColors.warning)),
        ],
        const SizedBox(height: AppSpacing.xl),
        AppButton(
          key: const Key('import-start'),
          label: 'Read my menu',
          icon: Icons.auto_awesome,
          onPressed: _pages.isEmpty ? null : _send,
        ),
      ],
    );
  }

  Widget _reviewView() {
    final draft = _import!;
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: AppColors.textMuted);
    final dishes = draft.categories.fold<int>(0, (n, c) => n + c.items.length);
    final chosen = draft.categories.fold<int>(0, (n, c) => n + c.items.where((i) => i.include).length);
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            children: [
              Text('Check what we read', style: text.titleLarge),
              const SizedBox(height: AppSpacing.xs),
              Text(
                '$dishes dishes found. Yellow rows need a second look. Untick anything you do not want.',
                style: muted,
              ),
              if (draft.duplicatesDropped.isNotEmpty)
                Text('Listed twice, kept once: ${draft.duplicatesDropped.join(', ')}', style: muted),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: Text(_error!, style: text.bodySmall?.copyWith(color: AppColors.warning)),
                ),
              for (final c in draft.categories) ...[
                const SizedBox(height: AppSpacing.lg),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        initialValue: c.name,
                        style: text.titleMedium,
                        decoration: const InputDecoration(labelText: 'Section'),
                        onChanged: (v) => c.name = v,
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        final all = c.items.every((i) => i.include);
                        for (final i in c.items) {
                          i.include = !all;
                        }
                      }),
                      child: Text(c.items.every((i) => i.include) ? 'Untick all' : 'Tick all'),
                    ),
                  ],
                ),
                for (final i in c.items) _ItemRow(
                  key: ValueKey(i.key),
                  item: i,
                  match: draft.matches[i.key],
                  updateMatch: _updateMatch[i.key] ?? false,
                  onChanged: () => setState(() {}),
                  onUpdateMatch: (v) => setState(() => _updateMatch[i.key] = v),
                ),
              ],
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            child: AppButton(
              key: const Key('import-apply'),
              label: 'Add $chosen dishes',
              onPressed: chosen == 0 ? null : _apply,
            ),
          ),
        ),
      ],
    );
  }

  Widget _doneView() {
    final r = _result!;
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      children: [
        const Icon(Icons.check_circle_outline, size: 48, color: AppColors.success),
        const SizedBox(height: AppSpacing.md),
        Text('${r.created} dishes added${r.updated > 0 ? ', ${r.updated} prices updated' : ''}.',
            style: text.titleLarge, textAlign: TextAlign.center),
        if (r.skipped > 0)
          Text('${r.skipped} were already on your menu and were left as they are.',
              textAlign: TextAlign.center, style: text.bodySmall?.copyWith(color: AppColors.textMuted)),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'They have no photos yet and are not live — add photos where you like, then publish.',
          textAlign: TextAlign.center,
          style: text.bodyMedium?.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: AppSpacing.xl),
        AppButton(label: 'Done', onPressed: () => Navigator.of(context).maybePop()),
        const SizedBox(height: AppSpacing.sm),
        AppButton.secondary(key: const Key('import-undo'), label: 'Undo this import', onPressed: _undo),
      ],
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    super.key,
    required this.item,
    required this.match,
    required this.updateMatch,
    required this.onChanged,
    required this.onUpdateMatch,
  });

  final DraftItem item;
  final DishMatch? match;
  final bool updateMatch;
  final VoidCallback onChanged;
  final ValueChanged<bool> onUpdateMatch;

  String _price(double? v) =>
      v == null ? '' : (v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2));

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: AppColors.textMuted);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: AppCard(
        child: Container(
          decoration: item.lowConfidence
              ? BoxDecoration(
                  border: Border(left: BorderSide(color: AppColors.warning.withValues(alpha: 0.9), width: 3)))
              : null,
          padding: item.lowConfidence ? const EdgeInsets.only(left: AppSpacing.sm) : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Checkbox(
                    value: item.include,
                    onChanged: (v) {
                      item.include = v ?? false;
                      onChanged();
                    },
                  ),
                  Expanded(
                    child: TextFormField(
                      initialValue: item.name,
                      decoration: const InputDecoration(isDense: true, hintText: 'Dish name'),
                      onChanged: (v) {
                        item.name = v;
                        onChanged();
                      },
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  SizedBox(
                    width: 90,
                    child: TextFormField(
                      initialValue: _price(item.price),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                      decoration: const InputDecoration(isDense: true, prefixText: '₹ ', hintText: 'Price'),
                      onChanged: (v) {
                        item.price = double.tryParse(v);
                        onChanged();
                      },
                    ),
                  ),
                ],
              ),
              if (item.variants.length > 1)
                Padding(
                  padding: const EdgeInsets.only(left: 48),
                  child: Text(
                    item.variants.map((v) => '${v.label} ₹${_price(v.price)}').join(' · '),
                    style: muted,
                  ),
                ),
              if (item.lowConfidence)
                Padding(
                  padding: const EdgeInsets.only(left: 48),
                  child: Text('Check this one', style: text.bodySmall?.copyWith(color: AppColors.warning)),
                ),
              if (match != null)
                Padding(
                  padding: const EdgeInsets.only(left: 36),
                  child: CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: updateMatch,
                    onChanged: item.price == null ? null : (v) => onUpdateMatch(v ?? false),
                    title: Text(
                      'Already on your menu (₹${_price(match!.price)}) — '
                      'update price to ₹${_price(item.price)}?',
                      style: text.bodySmall,
                    ),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(left: 48),
                  child: Wrap(
                    spacing: 4,
                    children: [
                      for (final (value, label) in const [('VEG', 'Veg'), ('NON_VEG', 'Non-veg'), ('NONE', '—')])
                        ChoiceChip(
                          visualDensity: VisualDensity.compact,
                          label: Text(label),
                          selected: item.foodType == value,
                          onSelected: (_) {
                            item.foodType = value;
                            onChanged();
                          },
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
