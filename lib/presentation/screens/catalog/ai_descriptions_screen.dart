// lib/presentation/screens/catalog/ai_descriptions_screen.dart
//
// `/catalog/ai-descriptions` — "Write descriptions for the dishes without one"
// (more-customization Stage 13.2). The AI suggests one line per dish in the
// catalog's tone; the owner ticks, edits and saves. Nothing is saved without a
// tick, and saved descriptions go live on the next publish like any edit.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/menu_translations_provider.dart';
import '../../../data/repositories/ai_repository.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/catalog_products_repository.dart';
import '../../../domain/catalog/menu_import.dart';
import '../../../domain/entities/catalog_product.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';

const int _kChunk = 40;

class AiDescriptionsScreen extends ConsumerStatefulWidget {
  const AiDescriptionsScreen({super.key});

  @override
  ConsumerState<AiDescriptionsScreen> createState() => _AiDescriptionsScreenState();
}

class _AiDescriptionsScreenState extends ConsumerState<AiDescriptionsScreen> {
  String? _tone;
  bool _busy = false;
  String? _error;

  /// Product id → editable suggestion, and whether to save it.
  final Map<String, TextEditingController> _text = {};
  final Map<String, bool> _pick = {};

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _setTone(String tone) async {
    setState(() => _tone = tone);
    try {
      await ref.read(aiRepositoryProvider(null)).setTone(tone);
    } on CatalogFailure {
      // The tone is a preference; the next request just uses the old one.
    }
  }

  Future<void> _write(List<CatalogProduct> dishes) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(aiRepositoryProvider(null));
      for (var i = 0; i < dishes.length; i += _kChunk) {
        final chunk = dishes.skip(i).take(_kChunk).map((d) => d.id).toList();
        final suggestions = await repo.describe(chunk, perDish: 1);
        if (!mounted) return;
        setState(() {
          for (final s in suggestions) {
            if (s.options.isEmpty) continue;
            (_text[s.productId] ??= TextEditingController()).text = s.options.first;
            _pick[s.productId] = true;
          }
        });
      }
    } on CatalogFailure catch (f) {
      if (mounted) setState(() => _error = f.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final messenger = CatalogFeedback.of(context);
    setState(() => _busy = true);
    var saved = 0;
    try {
      final products = ref.read(catalogProductsRepositoryProvider);
      for (final e in _pick.entries.where((e) => e.value)) {
        final text = _text[e.key]?.text.trim() ?? '';
        if (text.isEmpty) continue;
        await products.update(e.key, description: text);
        saved += 1;
      }
      ref.invalidate(menuTranslationsProvider);
      if (!mounted) return;
      CatalogFeedback.confirm(messenger, '$saved descriptions saved. They show after your next publish.');
      setState(() {
        _text.clear();
        _pick.clear();
      });
    } on CatalogFailure catch (f) {
      if (mounted) CatalogFeedback.failure(messenger, f, subject: 'descriptions');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(menuTranslationsProvider);
    final status = ref.watch(aiStatusProvider(null)).valueOrNull ?? AiStatus.off;
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: AppColors.textMuted);

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, title: const Text('AI descriptions')),
      body: data.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => CatalogMessage(
          icon: Icons.auto_awesome,
          title: 'Could not load your dishes',
          body: e is CatalogFailure ? e.message : 'Something went wrong. Please try again.',
          actionLabel: 'Try again',
          onAction: () => ref.invalidate(menuTranslationsProvider),
        ),
        data: (menu) {
          final missing = [
            for (final p in menu?.products ?? const <CatalogProduct>[])
              if (!p.isArchived && (p.description ?? '').trim().isEmpty) p,
          ];
          final chosen = _pick.values.where((v) => v).length;
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.screenPadding),
                children: [
                  Text('Tone', style: text.titleMedium),
                  const SizedBox(height: AppSpacing.xs),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'casual', label: Text('Casual')),
                      ButtonSegment(value: 'premium', label: Text('Premium')),
                      ButtonSegment(value: 'fun', label: Text('Fun')),
                    ],
                    selected: {_tone ?? status.tone},
                    onSelectionChanged: _busy ? null : (s) => _setTone(s.first),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    missing.isEmpty
                        ? 'Every dish already has a description.'
                        : '${missing.length} dishes have no description.',
                    style: text.titleMedium,
                  ),
                  Text('Suggestions only describe what the dish name says — check each before saving.',
                      style: muted),
                  const SizedBox(height: AppSpacing.md),
                  if (!status.budgetLeft && status.enabled)
                    Text('The AI budget for this month is used up.',
                        style: text.bodySmall?.copyWith(color: AppColors.warning)),
                  if (_error != null)
                    Text(_error!, style: text.bodySmall?.copyWith(color: AppColors.warning)),
                  if (_text.isEmpty && missing.isNotEmpty)
                    AppButton(
                      key: const Key('ai-write-all'),
                      label: 'Write ${missing.length} descriptions',
                      icon: Icons.auto_awesome,
                      isLoading: _busy,
                      onPressed: _busy || !status.enabled || !status.budgetLeft ? null : () => _write(missing),
                    ),
                  for (final p in missing)
                    if (_text[p.id] != null)
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.sm),
                        child: AppCard(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Checkbox(
                                value: _pick[p.id] ?? false,
                                onChanged: (v) => setState(() => _pick[p.id] = v ?? false),
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(p.displayName, style: text.titleSmall),
                                    TextField(controller: _text[p.id], maxLines: 3, minLines: 1, maxLength: 160),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  if (_text.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.lg),
                    AppButton(
                      key: const Key('ai-save-descriptions'),
                      label: 'Save $chosen descriptions',
                      isLoading: _busy,
                      onPressed: _busy || chosen == 0 ? null : _save,
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
