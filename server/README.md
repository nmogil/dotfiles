# VPS Memory Guardrails

This directory contains the source templates for the personal agent/development VPS.

The main goals are:

- Keep remote access alive through Tailscale.
- Prevent SSH-launched agent sessions from inheriting strong OOM protection.
- Bound always-on user services so a single spike does not freeze the VPS.
- Provide bounded launchers for interactive Claude and Codex sessions.
- Add zram as high-priority compressed swap before relying on disk swap.

Apply order:

1. Copy system and user systemd drop-ins.
2. Reload systemd managers.
3. Normalize current SSH session OOM scores.
4. Install `systemd-zram-generator`, then copy `zram/zram-generator.conf`.
5. Apply `sysctl.d/99-vps-memory.conf` after zram is active.

## Herdr-era rebuild notes

Herdr replaced tmux/CMUX as the agent/session cockpit. On a rebuild,
`setup-linux.sh` installs Herdr, the Claude/Codex/Hermes integrations, the
Hermes `herdr` skill, and runs `scripts/patch-herdr-codex-detection.sh`
(makes Codex update/hook-review prompts classify as blocked instead of idle).

Only that patch script is tracked here. Herdr runtime state — sockets, logs,
session JSON under `~/.config/herdr/` and `~/.local/state/herdr/` — is
recreated by Herdr itself and must never be committed, same as Claude/Codex
auth files and Hermes sessions. If Herdr refreshes its remote agent manifests
and the Codex rules vanish, re-run the patch script; it reloads manifests in
the running server when possible.
