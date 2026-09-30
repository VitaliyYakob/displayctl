# Changelog

All notable changes to `displayctl` are documented in this file.

[Описание изменений на русском](CHANGELOG.ru.md)

## 1.0.2 — 2026-09-30

- Fixed Adaptive Sync detection when the optional VRR interface is unavailable.
  Fixed refresh-rate modes remain usable in that case.
- Confirm brightness and Night Shift using two consecutive matching readings.
  Stable settings finish confirmation after 0.3 seconds instead of always
  waiting 0.6 seconds; missing or transient readings are not accepted.
- Bound firmware lookup to five seconds, prevent subprocess pipe deadlocks,
  and omit metadata when it cannot be matched to a display unambiguously.
- Keep `info` available when profile, refresh-rate, or resolution tables fail.
  Report the reason in text output and an optional JSON `warnings` array.
- Initialize system services only when needed and avoid reading color-feature
  status for unrelated setting changes.
- Separate CLI parsing and localized help without changing command syntax.
- Add 34 regression tests and run them in GitHub Actions.

## 1.0.1

- Added bilingual Russian and English output and documentation.
- Added display information, firmware, serial number, brightness, reference
  presets, refresh rates, Retina resolutions, layout, and mirroring commands.
- Added per-display and multi-display setting blocks.
- Added manual and automatic brightness modes.
- Added True Tone and Night Shift control with profile compatibility checks.
- Added JSON output and dry-run validation.
- Added GitHub Actions release-build verification.
