// lib/presentation/widgets/app_text_field.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Reusable text input for ReCapture.
///
/// Wraps TextFormField — works inside Flutter Form widgets for validation.
///
/// Usage:
///   AppTextField(
///     label: 'Project name',
///     hint: 'e.g. Wooden statue',
///     controller: _nameController,
///     errorText: _nameError,
///   )
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.label,
    this.hint,
    this.errorText,
    this.controller,
    this.focusNode,
    this.onChanged,
    this.onFieldSubmitted,
    this.validator,
    this.keyboardType,
    this.textInputAction,
    this.obscureText = false,
    this.autofocus = false,
    this.enabled = true,
    this.readOnly = false,
    this.maxLength,
    this.maxLines = 1,
    this.minLines,
    this.suffixIcon,
    this.prefixIcon,
    this.inputFormatters,
    this.autocorrect = true,
    this.enableSuggestions = true,
  });

  /// Persistent label — shown above field when focused/filled,
  /// inline when empty and unfocused.
  final String label;

  /// Placeholder hint shown inside the field when empty.
  final String? hint;

  /// Error message shown below the field in AppColors.error color.
  /// Pass null to hide the error state.
  final String? errorText;

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onFieldSubmitted;
  final FormFieldValidator<String>? validator;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final bool obscureText;
  final bool autofocus;
  final bool enabled;
  final bool readOnly;

  /// Max character count. Counter display is hidden (counterText: '').
  final int? maxLength;

  /// Number of visible lines. Default 1 (single-line).
  final int maxLines;
  final int? minLines;

  /// Widget shown at the end of the field (e.g. clear button, eye icon).
  final Widget? suffixIcon;

  /// Widget shown at the start of the field (e.g. search icon).
  final Widget? prefixIcon;

  final List<TextInputFormatter>? inputFormatters;
  final bool autocorrect;
  final bool enableSuggestions;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      onFieldSubmitted: onFieldSubmitted,
      validator: validator,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      obscureText: obscureText,
      autofocus: autofocus,
      enabled: enabled,
      readOnly: readOnly,
      maxLength: maxLength,
      maxLines: maxLines,
      minLines: minLines,
      inputFormatters: inputFormatters,
      autocorrect: autocorrect,
      enableSuggestions: enableSuggestions,
      style: Theme.of(context).textTheme.bodyLarge,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        errorText: errorText,
        suffixIcon: suffixIcon,
        prefixIcon: prefixIcon,
        counterText: '', // always hide character counter
      ),
    );
  }
}
