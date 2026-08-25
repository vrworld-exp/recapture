// lib/presentation/widgets/country_code_picker.dart
import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../domain/entities/country_code.dart';
import 'app_text_field.dart';

/// Compact dial-code selector shown as the first "part" of the phone input:
/// flag + dial code + dropdown chevron. Tapping it opens the searchable
/// country sheet ([showCountryCodePicker]); the parent owns the selection.
class CountryCodeButton extends StatelessWidget {
  const CountryCodeButton({
    super.key,
    required this.country,
    required this.onPressed,
  });

  final CountryCode country;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Country code, ${country.name} ${country.dialCode}',
      child: SizedBox(
        // Matches the standard filled-field height so the two phone "parts"
        // read as one control.
        height: 56,
        child: OutlinedButton(
          key: const ValueKey('country_code_button'),
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            // The app theme's OutlinedButton minimumSize is full-width
            // (Size(infinity, 48)) for CTA rows; inside this unbounded Row
            // that forces an infinite width and crashes layout. Size to
            // content instead.
            minimumSize: const Size(0, 56),
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            side: const BorderSide(color: AppColors.disabled),
            foregroundColor: AppColors.textPrimary,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(country.flagEmoji, style: const TextStyle(fontSize: 20)),
              const SizedBox(width: AppSpacing.xs),
              Text(
                country.dialCode,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const Icon(Icons.arrow_drop_down,
                  size: 20, color: AppColors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens the country dial-code sheet and resolves with the tapped country, or
/// null when dismissed. [selected] is highlighted and shows a check mark.
Future<CountryCode?> showCountryCodePicker(
  BuildContext context, {
  required CountryCode selected,
  List<CountryCode> countries = kCountryCodes,
}) {
  return showModalBottomSheet<CountryCode>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface1,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
    ),
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.8,
      child: _CountryCodeSheet(selected: selected, countries: countries),
    ),
  );
}

class _CountryCodeSheet extends StatefulWidget {
  const _CountryCodeSheet({required this.selected, required this.countries});

  final CountryCode selected;
  final List<CountryCode> countries;

  @override
  State<_CountryCodeSheet> createState() => _CountryCodeSheetState();
}

class _CountryCodeSheetState extends State<_CountryCodeSheet> {
  String _query = '';

  /// Case-insensitive match on the country name, dial code (with or without
  /// the typed `+`), or ISO code — so "ind", "91" and "+91" all find India.
  List<CountryCode> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.countries;
    final digits = q.startsWith('+') ? q.substring(1) : q;
    return widget.countries
        .where((c) =>
            c.name.toLowerCase().contains(q) ||
            c.iso2.toLowerCase() == q ||
            (digits.isNotEmpty && c.dialDigits.startsWith(digits)))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return Padding(
      // Keep the search field above the keyboard when it opens.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.sm),
            child: Text('Select country code',
                style: Theme.of(context).textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: AppTextField(
              key: const ValueKey('country_search_field'),
              label: 'Search',
              hint: 'Country name or code',
              prefixIcon: const Icon(Icons.search, size: 20),
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Text(
                      'No matching country',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  )
                : ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final country = filtered[index];
                      final isSelected = country == widget.selected;
                      return ListTile(
                        key: ValueKey('country_tile_${country.iso2}'),
                        leading: Text(country.flagEmoji,
                            style: const TextStyle(fontSize: 22)),
                        title: Text(
                          country.name,
                          style: Theme.of(context)
                              .textTheme
                              .bodyLarge
                              ?.copyWith(
                                color: isSelected
                                    ? AppColors.mirageRed
                                    : AppColors.textPrimary,
                              ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(country.dialCode,
                                style: Theme.of(context).textTheme.bodyMedium),
                            if (isSelected) ...[
                              const SizedBox(width: AppSpacing.sm),
                              const Icon(Icons.check,
                                  size: 18, color: AppColors.mirageRed),
                            ],
                          ],
                        ),
                        onTap: () => Navigator.of(context).pop(country),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
