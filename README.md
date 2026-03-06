# Codex Auth (local-only)

This project provides a single Zig tool: `codex-auth`, a local-only ChatGPT account manager for Codex.

- It never calls OpenAI APIs, so it does not affect your OpenAI account security through remote API requests.
- All data is read locally from Codex files under `~/.codex` (including `sessions/` and related auth files).

## Full Commands

```shell
codex-auth list # list all accounts
codex-auth add [--no-login] # add current account (runs `codex login` by default)
codex-auth switch <email> # switch active account (interactive or non-interactive)
codex-auth import <path> [--name <name>] # smart import: file -> single import, folder -> batch import
codex-auth remove # remove accounts (interactive multi-select)
```

### Examples

List accounts (default table with borders):

```shell
codex-auth list
```

Add the currently logged-in Codex account:

```shell
codex-auth add
```

Import an auth.json backup:

```shell
codex-auth import /path/to/auth.json --name personal
```

Batch import from a folder:

```shell
codex-auth import /path/to/auth-exports
```

Switch accounts (interactive list shows email, 5h, weekly, last activity):

```shell
codex-auth switch               # arrow + number input
```

Switch account non-interactively (for scripts/other CLIs):

```shell
codex-auth switch user@example.com
```

Remove accounts (interactive multi-select):

```shell
codex-auth remove
```

## Install

- Linux/macOS/WSL2 (one-line, latest release):

```shell
curl -fsSL https://raw.githubusercontent.com/loongphy/codex-auth/main/scripts/install.sh | bash
```

  The installer writes the install dir to your shell profile by default.
  Supported profiles: `~/.bashrc`/`~/.bash_profile`/`~/.profile`, `~/.zshrc`/`~/.zprofile`, `~/.config/fish/config.fish`.
  Use `--no-add-to-path` to skip profile updates.

- Windows (PowerShell, one-line, latest release):

```powershell
irm https://raw.githubusercontent.com/loongphy/codex-auth/main/scripts/install.ps1 | iex
```

  The installer adds the install dir to current/user `PATH` by default.
  Use `-NoAddToPath` to skip user `PATH` persistence.
