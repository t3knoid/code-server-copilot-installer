# GitHub Copilot Chat for code-server

A Bash installer that installs GitHub Copilot Chat into an existing code-server instance. It checks the VS Code version bundled with code-server, finds a compatible Copilot Chat release from the Visual Studio Marketplace, downloads and validates the VSIX, then installs it with `code-server`.

## Requirements

- Bash
- `code-server` available on `PATH`
- `curl`, `jq`, `unzip`, `gzip`, and standard command-line utilities (`sort`, `grep`, `head`, `tail`, and `tr`)
- A GitHub account with access to Copilot

## Usage

Run the installer as the same user that runs code-server:

```bash
bash install-copilot.sh
```

Restart code-server after installation, then sign in to GitHub in the editor.

```
sudo systemctl status code-server@frank
```

## Version selection and files

The installer reads the VS Code version reported by `code-server`, queries the Visual Studio Marketplace, and checks extension manifests to select a compatible release. It validates the downloaded VSIX before asking code-server to install it.

The compatibility cache is stored under `${XDG_CACHE_HOME:-$HOME/.cache}/code-server-copilot`. Temporary download files are placed under `${TMPDIR:-/tmp}/code-server-copilot` and removed when the installer exits.
