# Security policy

## Reporting a vulnerability

Please report security issues **privately** via GitHub's
[**Report a vulnerability**](https://github.com/csheaff/tmux-control/security/advisories/new)
button on the repository's Security tab (private vulnerability reporting),
rather than opening a public issue. This is a single-maintainer project, so
response is best-effort, but security reports are prioritized.

## Supported versions

`tmux-control` is a rolling single-file package; fixes land on the `main`
branch. Please test against `main` before reporting.

## Threat model / what to look for

`tmux-control` sits between Emacs and a tmux server that is often **remote
(SSH)** and may be shared or driven by automated agents. The inputs that an
attacker could influence — and therefore the areas most worth scrutiny — are:

- **Names and titles** — tmux session, window, and pane names/titles, and the
  host/socket strings. These are interpolated into control-mode commands and
  into `ssh`/`call-process` argv. The primary risk class is **command /
  argument injection** when a name is not quoted for tmux's parser or for the
  shell (see the `tmux-control--quote-tmux-arg` / `--window-target` helpers and
  their call sites).
- **The control-mode reply/notification stream** — `%output`, `%begin`/`%end`/
  `%error`, `%layout-change`, `list-windows`/`list-panes` replies, etc. A
  hostile or buggy remote controls this stream entirely; parsing must not crash,
  hang, grow unbounded, or evaluate attacker data.
- **Pane content and escape sequences** fed into the Eat terminal emulator, and
  **remote file paths** (e.g. `pane_current_path`) used for `default-directory`.

If you find a way for any of the above to achieve code execution, command
injection, unsafe file access, data exfiltration, or a crash/hang of Emacs,
that is in scope — please report it.

## Automated checks

This repository runs Dependabot (GitHub Actions supply chain) and OpenSSF
Scorecard, and has GitHub secret scanning with push protection enabled.
