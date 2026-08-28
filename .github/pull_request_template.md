<!-- .github/pull_request_template.md -->
<!-- This template auto-fills the PR description. Delete sections that don't apply. -->

## Summary

<!-- One or two sentences. What does this PR do? Why is it needed? -->


## Type

<!-- Check all that apply -->
- [ ] 🆕 New feature
- [ ] 🐛 Bug fix
- [ ] ♻️  Refactor (no behaviour change)
- [ ] ⚙️  Config / environment change
- [ ] 🏗️  Scaffold / infrastructure
- [ ] 📝 Docs / comments only

## Phase & Track

<!-- Which phase and track does this belong to? e.g. P0 › Flutter Setup -->
**Phase/Track:**
**Task:**

## Changes

<!-- Bullet list of specific changes made. Be concrete — file names, function names. -->
-
-
-

## Testing Done

<!-- How did you verify this works? Be specific. -->
- [ ] `flutter analyze` passes with zero issues
- [ ] `make run.dev` launches without errors
- [ ] Tested on Android emulator (API 24+)
- [ ] Tested on iOS simulator (iOS 14+) — skip if macOS not available
- [ ] Manually tested the specific flow: <!-- describe -->

## Screenshots / Recordings

<!-- For UI changes: attach before/after screenshots or a screen recording. -->
<!-- For non-UI changes: delete this section. -->


## Checklist

- [ ] No hardcoded color/font/spacing values (all from `AppColors.*`, `AppTypography.*`, `AppSpacing.*`)
- [ ] No raw hex `Color(0xFF...)` outside `app_colors.dart`
- [ ] No `AppConstants` references (use `AppConfig.*`)
- [ ] No secrets or real credentials committed (`.env.*` files are gitignored)
- [ ] No `// ignore:` lint suppressions added without a comment explaining why
- [ ] `CODEOWNERS` reviewer auto-assigned (no need to manually request)

## Related Issues

<!-- Link any related GitHub issues: Closes #123 -->
