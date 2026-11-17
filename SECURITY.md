# Security policy

## Status

`tmux-control` is no longer maintained, and its repository is archived. No
version is supported, and security issues will not be fixed here. If you
depend on it, fix them in a fork; the threat model below says where to look.

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
that is in scope.
