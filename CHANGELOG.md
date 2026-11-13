# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-11-13

### Added
- Layered diagnosis (L1 icon source, L2 shortcut content, L3 icon cache,
  L4 shell handler, L5 folder object, L6 folder ACL).
- Icon fingerprinting: signature comparison between the shell icon and the
  icon extracted straight from the target executable.
- Heuristic blank-icon detection (white ratio + mean saturation).
- `Get-IconReport` / `Invoke-IconDiagnosis` / `Invoke-IconRepair` public API.
- Safe repair pipeline with automatic backups and post-repair verification.
- Folder-object rebuild (`Reset-FolderObject`) with full rollback.
- Icon cache reset that survives Explorer's auto-restart.
- CLI entry point `bin/IconDoctor.ps1` with `-Scan`, `-Diagnose`, `-Fix`, `-Json`.
- Pester test suite and GitHub Actions CI running PSScriptAnalyzer + tests.
