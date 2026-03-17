# Contributing to DFIR-Updater

Thank you for your interest in contributing to DFIR-Updater. This document provides guidelines and instructions for contributing.

## Reporting Bugs

Use [GitHub Issues](https://github.com/jameshenning/DFIR-Updater/issues) to report bugs. Before filing, please search existing issues to avoid duplicates.

When reporting a bug, include:

- A clear, descriptive title
- Steps to reproduce the problem
- Expected behavior vs. actual behavior
- Your OS version and PowerShell version (`$PSVersionTable.PSVersion`)
- Any relevant error messages or log output

## Requesting Features

Feature requests are also tracked through [GitHub Issues](https://github.com/jameshenning/DFIR-Updater/issues). Please include:

- A clear description of the feature and the problem it solves
- Examples of how the feature would be used
- Whether you are willing to help implement it

## Submitting Pull Requests

1. **Fork** the repository on GitHub.
2. **Clone** your fork locally.
3. **Create a branch** from `main` for your changes:
   ```
   git checkout -b feature/your-feature-name
   ```
4. **Make your changes** following the code style guidelines below.
5. **Test** your changes thoroughly (see Testing Guidelines).
6. **Commit** with a clear, descriptive message explaining what and why.
7. **Push** your branch to your fork.
8. **Open a Pull Request** against the `main` branch of this repository.

Keep pull requests focused on a single change. If you have multiple unrelated fixes or features, submit separate PRs.

## Code Style Guidelines

DFIR-Updater is a PowerShell project. Follow these conventions:

### Naming

- Use **approved PowerShell verbs** for function names (`Get-`, `Set-`, `New-`, `Remove-`, etc.). Run `Get-Verb` to see the full list.
- Use **PascalCase** for function names, parameters, and public variables.
- Use **camelCase** for local/private variables.
- Use descriptive names. Avoid abbreviations unless they are well-known (e.g., DFIR, GUI, API).

### Error Handling

- Use `try`/`catch` blocks for operations that may fail (file I/O, network requests, external commands).
- Provide meaningful error messages that help users diagnose the problem.
- Prefer non-terminating errors (`Write-Warning`, `Write-Error`) for recoverable issues and terminating errors (`throw`) for critical failures.

### Documentation

- Include **comment-based help** (`<# .SYNOPSIS ... #>`) for all public functions.
- Add inline comments for non-obvious logic.
- Keep comments concise and up to date with the code.

### General

- Use `[CmdletBinding()]` and `param()` blocks for functions that accept parameters.
- Support `-WhatIf` and `-Confirm` for functions that modify state.
- Avoid hardcoded paths. Use variables and relative paths where possible.
- Maintain compatibility with PowerShell 5.1 (the default on Windows 10/11).

## Testing Guidelines

Before submitting a pull request:

1. **Run the affected scripts** on a test USB drive or local folder to verify they work correctly.
2. **Test on a clean environment** where possible (no leftover config or temp files).
3. **Verify backward compatibility** -- changes should not break existing `tools-config.json` files or workflows.
4. **Test edge cases** such as missing files, no internet connection, drives with unexpected folder structures, and invalid JSON input.
5. **Check the GUI** if your changes affect `DFIR-Updater-GUI.ps1` -- verify the WPF window renders correctly and all buttons function.

If your change affects forensic integrity features (Forensic Mode, Write Protection, Forensic Cleanup), test those features especially carefully. Forensic tools must be reliable.

## Code of Conduct

All contributors are expected to follow the project's [Code of Conduct](CODE_OF_CONDUCT.md). Be respectful, constructive, and collaborative.

## Questions

If you have questions about contributing, open a discussion in [GitHub Issues](https://github.com/jameshenning/DFIR-Updater/issues). We are happy to help.
