// lib/presentation/screens/catalog/qr_style_screen.dart
//
// The branded QR editor (more-customization Stage 7.4): colours, the
// restaurant's logo in the centre, a line of frame text and the printed
// template — with a live preview drawn by the SERVER, the same renderer that
// makes the printed file, so what is previewed is what prints.
//
// Every preview is decoded server-side before it comes back; a style that does
// not scan returns the plain square with a warning, and that plain square is
// also what would be printed. Colours are checked here first (dark on light,
// far enough apart) so most bad choices never make the round trip.
//
// The counted standee download is unchanged — only its artwork follows this.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/business_profile_notifier.dart';
import '../../../application/catalog/catalog_qr_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/menu_extras_repository.dart';
import '../../../domain/catalog/color_contrast.dart';
import '../../../domain/catalog/menu_entitlements.dart';
import '../../../domain/catalog/menu_extras.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';
import '../../widgets/catalog/plan_lock_chip.dart';

class QrStyleScreen extends ConsumerWidget {
  const QrStyleScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(businessProfileProvider);
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () => navigateBack(context),
        ),
        title: Text('QR style', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: profileAsync.when(
        loading: () => const Center(child: AppLoadingIndicator()),
        error: (error, _) => CatalogMessage(
          icon: Icons.cloud_off_outlined,
          title: "We couldn't load your QR style",
          body: error is CatalogFailure
              ? CatalogFeedback.failureText(error)
              : CatalogFeedback.textForCode(null),
          actionLabel: 'Try again',
          onAction: () => ref.invalidate(businessProfileProvider),
        ),
        data: (profile) => profile == null
            ? const CatalogMessage(
                icon: Icons.storefront_outlined,
                title: 'No catalog yet',
                body: 'Create your catalog first.',
              )
            : _QrStyleEditor(
                key: ValueKey(profile.id),
                saved: profile.qrStyle,
                hasLogo: profile.logoUrl != null,
                hasCover: profile.coverImageUrl != null,
              ),
      ),
    );
  }
}

/// Ready-made pairs that pass the rules — the quickest way to a good code.
const List<(String, String, String)> _presets = [
  ('Classic', '#000000', '#FFFFFF'),
  ('Espresso', '#3B2418', '#FFF8EE'),
  ('Forest', '#1B4332', '#F1F8F2'),
  ('Navy', '#14213D', '#F4F6FB'),
  ('Wine', '#6A0F2A', '#FFF5F7'),
  ('Charcoal', '#222222', '#F2E8CF'),
];

class _QrStyleEditor extends ConsumerStatefulWidget {
  const _QrStyleEditor({
    super.key,
    required this.saved,
    required this.hasLogo,
    required this.hasCover,
  });

  final QrStyle saved;
  final bool hasLogo;
  final bool hasCover;

  @override
  ConsumerState<_QrStyleEditor> createState() => _QrStyleEditorState();
}

class _QrStyleEditorState extends ConsumerState<_QrStyleEditor> {
  late QrStyle _style = widget.saved;
  late QrStyle _baseline = widget.saved;
  late final TextEditingController _fg = TextEditingController(text: widget.saved.fg);
  late final TextEditingController _bg = TextEditingController(text: widget.saved.bg);
  late final TextEditingController _frame =
      TextEditingController(text: widget.saved.frameText ?? '');

  Timer? _debounce;
  QrPreview? _preview;
  bool _previewing = false;
  CatalogFailure? _previewError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _schedulePreview();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _fg.dispose();
    _bg.dispose();
    _frame.dispose();
    super.dispose();
  }

  void _update(QrStyle next) {
    setState(() => _style = next);
    _schedulePreview();
  }

  /// Half a second after the last change, and only for a style that could pass.
  void _schedulePreview() {
    _debounce?.cancel();
    if (_style.validate() != null) return;
    _debounce = Timer(const Duration(milliseconds: 500), _loadPreview);
  }

  Future<void> _loadPreview() async {
    final style = _style;
    setState(() {
      _previewing = true;
      _previewError = null;
    });
    try {
      final preview = await ref.read(menuExtrasRepositoryProvider).previewQr(style);
      if (!mounted || style != _style) return;
      setState(() {
        _preview = preview;
        _previewing = false;
      });
    } on CatalogFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _previewing = false;
        _previewError = failure;
      });
    }
  }

  Future<void> _save() async {
    final messenger = CatalogFeedback.of(context);
    setState(() => _saving = true);
    try {
      final profile = await ref.read(menuExtrasRepositoryProvider).updateQrStyle(_style);
      await ref.read(businessProfileProvider.notifier).refresh();
      // The QR screen's square follows the saved style.
      ref.invalidate(catalogQrProvider);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _style = profile.qrStyle;
        _baseline = profile.qrStyle;
      });
      CatalogFeedback.confirm(messenger, 'QR style saved. Your next download uses it.');
    } on CatalogFailure catch (failure) {
      if (!mounted) return;
      setState(() => _saving = false);
      CatalogFeedback.failure(messenger, failure, subject: 'QR style');
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: AppColors.textMuted);
    final problem = _style.validate();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              EntitlementLimitNote(
                text: (e) => e.entitlements.brandedQr
                    ? null
                    : 'Your plan prints the plain black-and-white code. Design here and it prints '
                        'once you move to ${planLabel(e.requiredPlan['brandedQr'])}.',
              ),
              // ── Preview ──────────────────────────────────────────────────
              Center(
                child: Container(
                  width: 260,
                  height: 300,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.surface1,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: _preview == null
                      ? (_previewing
                          ? const AppLoadingIndicator()
                          : Text(
                              _previewError != null
                                  ? CatalogFeedback.failureText(_previewError!)
                                  : 'Preview',
                              textAlign: TextAlign.center,
                              style: muted,
                            ))
                      : Stack(
                          alignment: Alignment.center,
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(AppSpacing.md),
                              child: Image.memory(
                                _preview!.bytes,
                                key: const Key('qr-style-preview'),
                                filterQuality: FilterQuality.none,
                                gaplessPlayback: true,
                              ),
                            ),
                            if (_previewing) const AppLoadingIndicator(),
                          ],
                        ),
                ),
              ),
              if (_preview?.fellBack == true) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  "These colours didn't scan reliably, so the plain black-and-white code "
                  'would be printed. Try darker code colour or a lighter background.',
                  key: const Key('qr-style-fallback'),
                  textAlign: TextAlign.center,
                  style: text.bodySmall?.copyWith(color: AppColors.warning),
                ),
              ],
              const SizedBox(height: AppSpacing.xl),

              // ── Colours ──────────────────────────────────────────────────
              Text('Colours', style: text.titleMedium),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final (label, fg, bg) in _presets)
                    ChoiceChip(
                      label: Text(label),
                      avatar: CircleAvatar(backgroundColor: _color(fg), radius: 7),
                      selected: _style.fg.toUpperCase() == fg && _style.bg.toUpperCase() == bg,
                      onSelected: (_) {
                        _fg.text = fg;
                        _bg.text = bg;
                        _update(_style.copyWith(fg: fg, bg: bg));
                      },
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('qr-style-fg'),
                      controller: _fg,
                      maxLength: 7,
                      decoration: const InputDecoration(labelText: 'Code colour', hintText: '#000000'),
                      onChanged: (v) => _update(_style.copyWith(fg: v.trim().toUpperCase())),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: TextField(
                      key: const Key('qr-style-bg'),
                      controller: _bg,
                      maxLength: 7,
                      decoration: const InputDecoration(labelText: 'Background', hintText: '#FFFFFF'),
                      onChanged: (v) => _update(_style.copyWith(bg: v.trim().toUpperCase())),
                    ),
                  ),
                ],
              ),
              if (problem != null)
                Text(problem, style: text.bodySmall?.copyWith(color: AppColors.warning)),

              // ── Centre + frame text ──────────────────────────────────────
              const SizedBox(height: AppSpacing.md),
              SwitchListTile(
                key: const Key('qr-style-logo'),
                contentPadding: EdgeInsets.zero,
                title: const Text('My logo in the centre'),
                subtitle: Text(
                  widget.hasLogo
                      ? 'Instead of the Mayasabha mark.'
                      : 'Add a logo on your business profile first.',
                  style: muted,
                ),
                value: _style.logoCenter,
                onChanged: widget.hasLogo ? (v) => _update(_style.copyWith(logoCenter: v)) : null,
              ),
              TextField(
                key: const Key('qr-style-frame'),
                controller: _frame,
                maxLength: kMaxQrFrameText,
                decoration: const InputDecoration(
                  labelText: 'Frame text (optional)',
                  hintText: 'Scan for our 3D menu',
                ),
                onChanged: (v) => _update(_style.copyWith(frameText: v.trim().isEmpty ? null : v)),
              ),

              // ── Printed template ─────────────────────────────────────────
              const SizedBox(height: AppSpacing.md),
              Text('Printed standee', style: text.titleMedium),
              const SizedBox(height: AppSpacing.xs),
              Text('How your downloaded A4 standees are laid out.', style: muted),
              // Hand-built rows rather than RadioListTile, like the category
              // manager's picker: Material's radio now wants a RadioGroup ancestor.
              for (final template in QrTemplate.values)
                ListTile(
                  key: Key('qr-style-template-${template.apiValue}'),
                  contentPadding: EdgeInsets.zero,
                  onTap: () => _update(_style.copyWith(template: template)),
                  leading: Icon(
                    _style.template == template
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: _style.template == template ? AppColors.royalGold : AppColors.textMuted,
                  ),
                  title: Text(template.label),
                  subtitle: Text(
                    template == QrTemplate.bold && !widget.hasCover
                        ? '${template.description} (No cover yet — the band is plain colour.)'
                        : template.description,
                    style: muted,
                  ),
                ),

              const SizedBox(height: AppSpacing.xl),
              AppButton(
                key: const Key('qr-style-save'),
                label: 'Save QR style',
                isLoading: _saving,
                onPressed: _style != _baseline && problem == null && !_saving ? _save : null,
              ),
              const SizedBox(height: AppSpacing.sm),
              TextButton(
                key: const Key('qr-style-reset'),
                onPressed: _saving
                    ? null
                    : () {
                        _fg.text = QrStyle.plain.fg;
                        _bg.text = QrStyle.plain.bg;
                        _frame.clear();
                        _update(QrStyle.plain);
                      },
                child: const Text('Back to plain black & white'),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Always test a printed code with two or three different phones before '
                'printing many.',
                textAlign: TextAlign.center,
                style: muted,
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Color _color(String hex) =>
      kHexColor.hasMatch(hex) ? Color(int.parse('FF${hex.substring(1)}', radix: 16)) : Colors.grey;
}
