;;; tmux-control-test.el --- Tests for tmux-control -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the pure helpers in tmux-control.  These cover the
;; string/encoding logic and the scrollback-compaction pipeline without
;; needing a live tmux server or Eat terminal.  Run with:
;;
;;   make test
;;
;; or directly:
;;
;;   emacs -Q --batch -L <eat-dir> -L . \
;;     -l tmux-control.el -l test/tmux-control-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tmux-control)

;; Scrollback compaction is driven by user-configured patterns
;; (`tmux-control-scrollback-frame-start-regexp' and
;; `tmux-control-scrollback-chrome-regexps'), which default to nil so
;; scrollback is verbatim out of the box.  These are the Claude Code TUI
;; patterns the compaction tests exercise the mechanism with.
(defconst tmux-control-test--frame-re "\\`\\s-*\\[Session\\]")
(defconst tmux-control-test--chrome-res
  '("\\`\\[Session\\]" "AI Credits:" "\\`/ commands"
    "\\`[─━]\\{10,\\}\\'" "\\`❯\\'"))

(defmacro tmux-control-test--with-compaction (&rest body)
  "Evaluate BODY with the Claude Code compaction patterns bound."
  `(let ((tmux-control-scrollback-frame-start-regexp tmux-control-test--frame-re)
         (tmux-control-scrollback-chrome-regexps tmux-control-test--chrome-res))
     ,@body))

;;; Window-index validation.

(ert-deftest tmux-control-test-normalize-window-index ()
  (should (equal (tmux-control--normalize-window-index "3") "3"))
  (should (equal (tmux-control--normalize-window-index 3) "3"))
  (should (equal (tmux-control--normalize-window-index "0") "0"))
  (should-error (tmux-control--normalize-window-index "abc") :type 'user-error)
  (should-error (tmux-control--normalize-window-index "") :type 'user-error)
  (should-error (tmux-control--normalize-window-index "1a") :type 'user-error)
  (should-error (tmux-control--normalize-window-index -1) :type 'user-error))

;;; tmux argument quoting.

(ert-deftest tmux-control-test-quote-tmux-arg ()
  (should (equal (tmux-control--quote-tmux-arg "plain") "\"plain\""))
  (should (equal (tmux-control--quote-tmux-arg "two words") "\"two words\""))
  (should (equal (tmux-control--quote-tmux-arg "") "\"\""))
  ;; A double quote is backslash-escaped.
  (should (equal (tmux-control--quote-tmux-arg "has\"quote") "\"has\\\"quote\""))
  ;; A backslash is doubled.
  (should (equal (tmux-control--quote-tmux-arg "back\\slash") "\"back\\\\slash\""))
  ;; SECURITY: control characters are stripped. Control mode is line-based, so
  ;; a newline in a name would otherwise break out of the quoted argument and
  ;; inject a second control-mode command (e.g. run-shell = RCE on the host).
  (should (equal (tmux-control--quote-tmux-arg "a\nrun-shell foo") "\"arun-shell foo\""))
  (should (equal (tmux-control--quote-tmux-arg "a\r\tb\0c") "\"abc\""))
  ;; ...and a normal name is untouched.
  (should (equal (tmux-control--quote-tmux-arg "my proj") "\"my proj\"")))

(ert-deftest tmux-control-test-ssh-args-prepends-options-and-checks-host ()
  ;; Every ssh invocation goes through --ssh-args: the configured options come
  ;; first (so a dead link is detected / the connect is bounded), then the
  ;; validated host, then the remote command.
  (let ((tmux-control-ssh-options '("-o" "ConnectTimeout=10")))
    (should (equal (tmux-control--ssh-args "dev" "echo hi")
                   '("-o" "ConnectTimeout=10" "dev" "echo hi"))))
  (let ((tmux-control-ssh-options nil))
    (should (equal (tmux-control--ssh-args "dev" "x") '("dev" "x"))))
  ;; The host is still validated (option-like host rejected).
  (should-error (tmux-control--ssh-args "-oProxyCommand=pwned" "x")
                :type 'user-error))

(ert-deftest tmux-control-test-check-host-rejects-option-like ()
  ;; SECURITY: an ssh destination starting with `-' is read by ssh as an option
  ;; (e.g. -oProxyCommand=...), which runs a local command -> local RCE. Reject.
  (should (equal (tmux-control--check-host "dev") "dev"))
  (should (equal (tmux-control--check-host "user@host.example") "user@host.example"))
  (should (equal (tmux-control--check-host nil) nil))
  (should-error (tmux-control--check-host "-oProxyCommand=touch /tmp/pwned")
                :type 'user-error)
  (should-error (tmux-control--check-host "-Fevil") :type 'user-error)
  ;; A non-nil, non-string host is rejected rather than reaching the process layer.
  (should-error (tmux-control--check-host 42) :type 'user-error))

(ert-deftest tmux-control-test-window-target-quotes-session ()
  ;; A session name with a space must be quoted so tmux's control-mode parser
  ;; reads "name with space":INDEX as a single target token; an unquoted
  ;; space splits the argument and tmux errors ("too many arguments").  A
  ;; normal name is quoted too -- harmless, tmux strips the quotes.
  (should (equal (tmux-control--window-target "my proj" 2) "\"my proj\":2"))
  (should (equal (tmux-control--window-target "my proj") "\"my proj\":"))
  (should (equal (tmux-control--window-target "main" 0) "\"main\":0"))
  ;; An empty index (the pinned-size warn path's empty current-window) targets
  ;; the session with no specific window, like a nil index.
  (should (equal (tmux-control--window-target "main" "") "\"main\":")))

(ert-deftest tmux-control-test-quote-tmux-name-neutralizes-hash ()
  ;; A window NAME is format-expanded by rename-window/new-window -n, so a
  ;; literal #{...}/#(...) must be doubled to ## (tmux collapses ## back to a
  ;; single # when it expands the argument).  --quote-tmux-arg, which is for
  ;; targets, must NOT do this -- hence a separate name quoter.
  (should (equal (tmux-control--quote-tmux-name "plain") "\"plain\""))
  (should (equal (tmux-control--quote-tmux-name "a#{pane_id}b")
                 "\"a##{pane_id}b\""))
  (should (equal (tmux-control--quote-tmux-name "x#(echo hi)y")
                 "\"x##(echo hi)y\""))
  ;; A lone # is doubled too -- harmless, it round-trips back to a literal #.
  (should (equal (tmux-control--quote-tmux-name "feat#1") "\"feat##1\"")))

(ert-deftest tmux-control-test-window-state-command-quotes-session ()
  ;; The in-band window-state query drives tiling and every %layout-change
  ;; retile.  A spaced session name must be quoted or tmux's parser errors
  ;; ("too many arguments") and tiling reads no layout.
  (with-temp-buffer
    (setq-local tmux-control--session "my proj")
    (should (string-prefix-p "list-panes -t \"my proj\": -F \""
                             (tmux-control--window-state-command)))))

(ert-deftest tmux-control-test-refresh-window-targets-quote-session ()
  ;; The in-band list-windows / list-panes refreshers (which feed the tab bar
  ;; and the pane->window output routing map) must quote the session, like every
  ;; other control-mode target.  A spaced session name otherwise makes tmux's
  ;; parser split the argument ("too many arguments") so the window list never
  ;; populates and routing breaks.
  (let (cmds)
    (cl-letf (((symbol-function 'tmux-control--send-command)
               (lambda (cmd &rest _) (push cmd cmds)))
              ((symbol-function 'process-live-p) (lambda (_) t)))
      (with-temp-buffer
        (setq-local tmux-control--session "my proj")
        (setq-local tmux-control--process 'live)
        (let ((tmux-control-window-tab-bar t))
          (tmux-control--refresh-windows)
          (tmux-control--refresh-pane-window-map))
        (should (= (length cmds) 2))
        (dolist (c cmds)
          (should (string-match-p "-t \"my proj\":" c))
          (should-not (string-match-p "-t my proj" c)))))))

(ert-deftest tmux-control-test-fallback-control-target-quotes-session ()
  ;; The connect-window fallback target (send-keys/paste before the pane id
  ;; is known) must quote the session for the control-mode parser, while the
  ;; raw --fallback-target stays unquoted for CLI argv use.
  (with-temp-buffer
    (setq-local tmux-control--fallback-target "my proj:")
    (should (equal (tmux-control--fallback-control-target) "\"my proj\":"))
    (setq-local tmux-control--fallback-target "main:")
    (should (equal (tmux-control--fallback-control-target) "\"main\":"))
    (setq-local tmux-control--fallback-target nil)
    (should (null (tmux-control--fallback-control-target)))))

(ert-deftest tmux-control-test-quote-target-quotes-session-fallback ()
  ;; In-band control-mode targets (the scrollback pager's capture and
  ;; history_size queries): a pane/window id is already a safe token; the
  ;; connect-window session fallback "SESSION:" must be re-quoted so a spaced
  ;; name parses as one token.  The CLI argv capture keeps the raw target.
  (should (equal (tmux-control--quote-target "%3") "%3"))
  (should (equal (tmux-control--quote-target "@2") "@2"))
  (should (equal (tmux-control--quote-target "my proj:") "\"my proj\":"))
  (should (equal (tmux-control--quote-target "main:") "\"main\":"))
  (should (equal (tmux-control--quote-target nil) nil)))

;;; Control-mode output decoding.

(ert-deftest tmux-control-test-octal-digit-p ()
  (should (tmux-control--octal-digit-p ?0))
  (should (tmux-control--octal-digit-p ?7))
  (should-not (tmux-control--octal-digit-p ?8))
  (should-not (tmux-control--octal-digit-p ?9))
  (should-not (tmux-control--octal-digit-p ?a)))

(ert-deftest tmux-control-test-decode-output ()
  (should (equal (tmux-control--decode-output "abc") "abc"))
  ;; \033 is octal for ESC.
  (should (equal (tmux-control--decode-output "\\033") "\e"))
  ;; \101 is octal for ?A.
  (should (equal (tmux-control--decode-output "a\\101b") "aAb"))
  ;; A backslash not followed by three octal digits is left literal.
  (should (equal (tmux-control--decode-output "x\\07") "x\\07"))
  (should (equal (tmux-control--decode-output "no\\backslash") "no\\backslash")))

(ert-deftest tmux-control-test-extended-output-parse ()
  ;; With flow control on, output arrives as %extended-output with an age
  ;; (and reserved) field before a colon; the value is decoded like %output.
  (let ((tmux-control--collecting-command nil)
        (tmux-control--output-batch nil)
        (tmux-control--active-pane nil))
    (tmux-control--handle-line "%extended-output %3 0 : hello\\012")
    (should (equal tmux-control--active-pane "%3"))
    (should (equal tmux-control--output-batch '("hello\n")))))

(ert-deftest tmux-control-test-batch-pane-output-routes-active ()
  ;; The first output bootstraps the active pane; output from other panes is
  ;; dropped so a split-pane window does not interleave into one terminal.
  (let ((tmux-control--active-pane nil)
        (tmux-control--output-batch nil))
    (tmux-control--batch-pane-output "%1" "from-one\\012")
    (should (equal tmux-control--active-pane "%1"))
    (should (equal tmux-control--output-batch '("from-one\n")))
    ;; A different pane's output is ignored, not interleaved.
    (tmux-control--batch-pane-output "%2" "from-two\\012")
    (should (equal tmux-control--output-batch '("from-one\n")))
    ;; More output from the active pane is queued (reverse order in the batch).
    (tmux-control--batch-pane-output "%1" "more\\012")
    (should (equal tmux-control--output-batch '("more\n" "from-one\n")))))

(ert-deftest tmux-control-test-batch-pane-output-tiled-routes ()
  ;; In tiling mode each pane's output is fanned into that pane's own render
  ;; buffer -- never interleaved -- and output for an unknown pane is dropped.
  (let ((buf1 (generate-new-buffer " *tc-test-pane1*"))
        (buf2 (generate-new-buffer " *tc-test-pane2*")))
    (unwind-protect
        (let ((tmux-control--tiled t)
              (tmux-control--panes (list (cons "%1" buf1) (cons "%2" buf2))))
          (with-current-buffer buf1 (setq-local tmux-control--output-batch nil))
          (with-current-buffer buf2 (setq-local tmux-control--output-batch nil))
          (tmux-control--batch-pane-output "%1" "one\\012")
          (tmux-control--batch-pane-output "%2" "two\\012")
          (tmux-control--batch-pane-output "%1" "more\\012")
          ;; Output for a pane with no render buffer is dropped, not an error.
          (tmux-control--batch-pane-output "%9" "ghost\\012")
          ;; Each buffer holds only its own output (reverse order in the batch).
          (should (equal (buffer-local-value 'tmux-control--output-batch buf1)
                         '("more\n" "one\n")))
          (should (equal (buffer-local-value 'tmux-control--output-batch buf2)
                         '("two\n"))))
      (kill-buffer buf1)
      (kill-buffer buf2))))

(ert-deftest tmux-control-test-handle-pause-resumes ()
  ;; A %pause reseeds the active pane and asks tmux to continue streaming.
  (let ((sent '())
        (seeded nil))
    (cl-letf (((symbol-function 'tmux-control--seed-screen)
               (lambda () (setq seeded t)))
              ((symbol-function 'tmux-control--send-command)
               (lambda (cmd &optional _kind) (push cmd sent))))
      (let ((tmux-control--active-pane "%0"))
        (tmux-control--handle-pause "%0")))
    (should seeded)
    (should (member "refresh-client -A \"%0:continue\"" sent))))

(ert-deftest tmux-control-test-handle-pause-tiled-discards-stale-batch ()
  ;; In tiling mode a %pause reseeds the paused pane's own buffer
  ;; synchronously; its pre-pause output batch must be discarded, or
  ;; `tmux-control--flush-tiled-panes' (end of chunk) replays that stale
  ;; backlog over the fresh seed -- the very thing %pause means to skip.
  (let ((panebuf (generate-new-buffer " *tc-pane*"))
        (seeded nil) (sent '()))
    (unwind-protect
        (cl-letf (((symbol-function 'tmux-control--seed-pane-buffer-sync)
                   (lambda (b) (setq seeded b)))
                  ((symbol-function 'tmux-control--send-command)
                   (lambda (cmd &optional _kind) (push cmd sent))))
          (with-current-buffer panebuf
            (setq-local tmux-control--output-batch (list "stale" "output")))
          (with-temp-buffer
            (setq-local tmux-control--tiled t
                        tmux-control--panes (list (cons "%4" panebuf)))
            (tmux-control--handle-pause "%4"))
          (should (eq seeded panebuf))
          (should (null (buffer-local-value 'tmux-control--output-batch panebuf)))
          (should (member "refresh-client -A \"%4:continue\"" sent)))
      (kill-buffer panebuf))))

;;; UTF-8 stream reassembly (multibyte characters tmux split across messages).

(ert-deftest tmux-control-test-utf8-complete-len ()
  ;; ASCII and complete multibyte sequences: the whole string is complete.
  (should (= 3 (tmux-control--utf8-complete-len (unibyte-string ?a ?b ?c))))
  (should (= 3 (tmux-control--utf8-complete-len (unibyte-string #xe2 #x94 #x80)))) ; ─
  (should (= 0 (tmux-control--utf8-complete-len (unibyte-string))))
  ;; Incomplete trailing sequences are held back.
  (should (= 0 (tmux-control--utf8-complete-len (unibyte-string #xe2 #x94))))     ; ─ less one
  (should (= 1 (tmux-control--utf8-complete-len (unibyte-string ?x #xe2))))       ; lead byte only
  ;; A 4-byte lead (emoji) missing two continuation bytes.
  (should (= 2 (tmux-control--utf8-complete-len (unibyte-string ?x ?y #xf0 #x9f)))))

(ert-deftest tmux-control-test-utf8-decode-stream-reassembles-split ()
  ;; A ─ (E2 94 80) split across two feeds is reassembled, not left as bytes.
  (let* ((e2 (decode-char 'eight-bit #xe2))
         (b94 (decode-char 'eight-bit #x94))
         (b80 (decode-char 'eight-bit #x80))
         (r1 (tmux-control--utf8-decode-stream "" (string e2 b94)))
         (r2 (tmux-control--utf8-decode-stream (cdr r1) (string b80))))
    (should (equal (car r1) ""))               ; nothing complete yet
    (should (equal (car r2) (string #x2500)))  ; reassembled ─
    (should (equal (cdr r2) "")))              ; nothing carried
  ;; Plain (already-complete) text passes through with no carry.
  (let ((r (tmux-control--utf8-decode-stream "" "héllo")))
    (should (equal (car r) "héllo"))
    (should (equal (cdr r) ""))))

;;; Input hex encoding.

(ert-deftest tmux-control-test-string-to-hex-args ()
  (should (equal (tmux-control--string-to-hex-args "") ""))
  (should (equal (tmux-control--string-to-hex-args "A") "41"))
  (should (equal (tmux-control--string-to-hex-args "AB") "41 42"))
  ;; Multibyte characters are encoded as their UTF-8 bytes.
  (should (equal (tmux-control--string-to-hex-args "é") "c3 a9")))

(ert-deftest tmux-control-test-bytes-to-hex-args ()
  (let ((bytes (encode-coding-string "ABC" 'utf-8-unix)))
    (should (equal (tmux-control--bytes-to-hex-args bytes 0 3) "41 42 43"))
    ;; A sub-range hexes only those bytes.
    (should (equal (tmux-control--bytes-to-hex-args bytes 1 3) "42 43"))
    ;; An empty range is the empty string.
    (should (equal (tmux-control--bytes-to-hex-args bytes 0 0) ""))))

(ert-deftest tmux-control-test-send-input-chunks-large-paste ()
  ;; A paste larger than the chunk size is split into several bounded
  ;; send-keys commands (tmux drops an over-long control command).
  (let ((sent '()))
    (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
              ((symbol-function 'tmux-control--send-command)
               (lambda (cmd &optional _kind) (push cmd sent))))
      (let ((tmux-control--process 'fake)
            (tmux-control--active-pane "%0")
            (tmux-control--suppress-responses nil))
        ;; 2500 ASCII bytes with a 1024-byte chunk -> 1024 + 1024 + 452.
        (tmux-control--send-input nil (make-string 2500 ?x))))
    (setq sent (nreverse sent))
    (should (= 3 (length sent)))
    (dolist (c sent)
      (should (string-prefix-p "send-keys -t %0 -H " c)))
    (let ((counts (mapcar
                   (lambda (c)
                     (length (split-string
                              (substring c (length "send-keys -t %0 -H ")) " " t)))
                   sent)))
      (should (equal counts '(1024 1024 452))))))

;;; Trailing/blank line trimming and squeezing.

(ert-deftest tmux-control-test-trim-trailing-blank-lines ()
  (should (equal (tmux-control--trim-trailing-blank-lines "a\n\n\n") "a\n"))
  (should (equal (tmux-control--trim-trailing-blank-lines "a\n  \t\n") "a\n"))
  (should (equal (tmux-control--trim-trailing-blank-lines "a") "a"))
  (should (equal (tmux-control--trim-trailing-blank-lines "a\nb\n") "a\nb\n")))

(ert-deftest tmux-control-test-squeeze-blank-lines ()
  (should (equal (tmux-control--squeeze-blank-lines "a\n\n\n\nb") "a\n\nb"))
  (should (equal (tmux-control--squeeze-blank-lines "a\n \n \n \nb") "a\n\nb"))
  ;; Two consecutive newlines (one blank line) are left untouched.
  (should (equal (tmux-control--squeeze-blank-lines "a\n\nb") "a\n\nb")))

(ert-deftest tmux-control-test-trim-blank-line-list ()
  (should (equal (tmux-control--trim-blank-line-list '("" "a" "")) '("a")))
  (should (equal (tmux-control--trim-blank-line-list '(" " "a" "b" "  "))
                 '("a" "b")))
  (should (equal (tmux-control--trim-blank-line-list '("" "")) nil))
  (should (equal (tmux-control--trim-blank-line-list '("a")) '("a"))))

;;; Line-list predicates.

(ert-deftest tmux-control-test-line-list-has-content-p ()
  (should (tmux-control--line-list-has-content-p '("" "x")))
  (should-not (tmux-control--line-list-has-content-p '("" "  ")))
  (should-not (tmux-control--line-list-has-content-p nil)))

(ert-deftest tmux-control-test-line-list-contains-p ()
  (should (tmux-control--line-list-contains-p '("a" "b" "c") '("b" "c")))
  (should (tmux-control--line-list-contains-p '("a" "b" "c") '("a" "b" "c")))
  (should-not (tmux-control--line-list-contains-p '("a" "b") '("b" "x")))
  ;; A needle longer than the haystack never matches.
  (should-not (tmux-control--line-list-contains-p '("a") '("a" "b"))))

(ert-deftest tmux-control-test-line-list-safe-overlap-p ()
  (should (tmux-control--line-list-safe-overlap-p '("a" "b")))
  (should (tmux-control--line-list-safe-overlap-p '("a" "b" "c")))
  ;; Fewer than two distinctive (nonblank) lines is not safe.
  (should-not (tmux-control--line-list-safe-overlap-p '("a" "")))
  (should-not (tmux-control--line-list-safe-overlap-p '("" ""))))

(ert-deftest tmux-control-test-line-list-overlap ()
  (let ((tmux-control-compact-scrollback-window 300))
    ;; Two distinctive trailing lines of LEFT match the leading lines of RIGHT.
    (should (= (tmux-control--line-list-overlap '("x" "a" "b") '("a" "b" "y"))
               2))
    ;; No shared boundary.
    (should (= (tmux-control--line-list-overlap '("a" "b") '("c" "d")) 0))
    ;; A boundary that is not distinctive enough is rejected.
    (should (= (tmux-control--line-list-overlap '("x" "a" "") '("a" "" "y"))
               0))))

;;; Scrollback chunking and chrome detection.

(ert-deftest tmux-control-test-scrollback-frame-start-line-p ()
  ;; With no frame pattern configured (the default) nothing is a frame start.
  (let ((tmux-control-scrollback-frame-start-regexp nil))
    (should-not (tmux-control--scrollback-frame-start-line-p "[Session] foo")))
  (tmux-control-test--with-compaction
   (should (tmux-control--scrollback-frame-start-line-p "[Session] foo"))
   (should (tmux-control--scrollback-frame-start-line-p "   [Session]"))
   (should-not (tmux-control--scrollback-frame-start-line-p "x [Session]"))
   (should-not (tmux-control--scrollback-frame-start-line-p "hello"))))

(ert-deftest tmux-control-test-scrollback-chrome-line-p ()
  ;; With no chrome patterns configured (the default) nothing is chrome.
  (let ((tmux-control-scrollback-chrome-regexps nil))
    (should-not (tmux-control--scrollback-chrome-line-p "[Session] x"))
    (should-not (tmux-control--scrollback-chrome-line-p "❯")))
  (tmux-control-test--with-compaction
   (should (tmux-control--scrollback-chrome-line-p "[Session] x"))
   (should (tmux-control--scrollback-chrome-line-p "  AI Credits: 99"))
   (should (tmux-control--scrollback-chrome-line-p "/ commands here"))
   (should (tmux-control--scrollback-chrome-line-p "──────────"))
   (should (tmux-control--scrollback-chrome-line-p "❯"))
   (should-not (tmux-control--scrollback-chrome-line-p "regular line"))
   ;; A short rule is not chrome.
   (should-not (tmux-control--scrollback-chrome-line-p "─────"))))

(ert-deftest tmux-control-test-regexp-matches-p-tolerates-bad-regexp ()
  ;; The frame-start/chrome patterns are user defcustoms tested inside the
  ;; capture's process-filter callback; a malformed one must degrade to nil,
  ;; not throw and abort the scrollback open.
  (should (tmux-control--regexp-matches-p "foo" "a foo b"))
  (should-not (tmux-control--regexp-matches-p "foo" "bar"))
  ;; Invalid regexp -> nil, no error.
  (should-not (tmux-control--regexp-matches-p "[" "abc"))
  (should-not (tmux-control--regexp-matches-p "\\(" "abc"))
  ;; A non-string element (e.g. a stray nil in the chrome list) -> nil.
  (should-not (tmux-control--regexp-matches-p nil "abc"))
  ;; And the predicates that route through it survive a bad user pattern.
  (let ((tmux-control-scrollback-frame-start-regexp "["))
    (should-not (tmux-control--scrollback-frame-start-line-p "abc")))
  (let ((tmux-control-scrollback-chrome-regexps '("[" nil "valid")))
    (should-not (tmux-control--scrollback-chrome-line-p "abc"))
    (should (tmux-control--scrollback-chrome-line-p "this is valid here"))))

(ert-deftest tmux-control-test-scrollback-chunks ()
  (tmux-control-test--with-compaction
   (should (equal (tmux-control--scrollback-chunks
                   "[Session] a\nb\n[Session] c\nd")
                  '(("[Session] a" "b") ("[Session] c" "d"))))
   ;; Trailing whitespace on each line is trimmed.
   (should (equal (tmux-control--scrollback-chunks "a  \nb\t")
                  '(("a" "b"))))))

;;; The full compaction pipeline.

(ert-deftest tmux-control-test-compact-repeated-redraw-lines-dedups ()
  (let ((tmux-control-compact-scrollback-window 300)
        (tmux-control-scrollback-frame-start-regexp tmux-control-test--frame-re)
        (tmux-control-scrollback-chrome-regexps tmux-control-test--chrome-res))
    ;; A frame repeated verbatim collapses to a single copy, and the
    ;; "[Session]" chrome lines are stripped.
    (should (equal (tmux-control--compact-repeated-redraw-lines
                    "[Session] x\nhello\nworld\n[Session] x\nhello\nworld")
                   "hello\nworld"))))

(ert-deftest tmux-control-test-compact-repeated-redraw-lines-keeps-distinct ()
  (let ((tmux-control-compact-scrollback-window 300)
        (tmux-control-scrollback-frame-start-regexp tmux-control-test--frame-re)
        (tmux-control-scrollback-chrome-regexps tmux-control-test--chrome-res))
    ;; Distinct frames are preserved, separated by a single blank line.
    (should (equal (tmux-control--compact-repeated-redraw-lines
                    "[Session] x\nalpha\nbeta\n[Session] x\ngamma\ndelta")
                   "alpha\nbeta\n\ngamma\ndelta"))))

(ert-deftest tmux-control-test-compact-strips-redrawn-body-behind-new-lines ()
  (let ((tmux-control-compact-scrollback-window 300)
        (tmux-control-scrollback-frame-start-regexp tmux-control-test--frame-re)
        (tmux-control-scrollback-chrome-regexps tmux-control-test--chrome-res))
    ;; A repeated full-screen panel (6+ distinctive lines) wrapped in new
    ;; volatile lines (an evolving prompt) collapses: the panel survives
    ;; once and only the genuinely new prompt line is appended.
    (should (equal (tmux-control--compact-repeated-redraw-lines
                    (concat "[Session]\nA\nB\nC\nD\nE\nF\n"
                            "[Session]\nXP\nA\nB\nC\nD\nE\nF"))
                   "A\nB\nC\nD\nE\nF\n\nXP"))))

(ert-deftest tmux-control-test-compact-keeps-short-repeats ()
  (let ((tmux-control-compact-scrollback-window 300)
        (tmux-control-scrollback-frame-start-regexp tmux-control-test--frame-re)
        (tmux-control-scrollback-chrome-regexps tmux-control-test--chrome-res))
    ;; Short repeated blocks (below the redraw-run threshold) are NOT
    ;; stripped, so ordinary repeated command output is never lost.
    (should (equal (tmux-control--compact-repeated-redraw-lines
                    "[Session]\nA\nB\nC\nD\n[Session]\nXP\nA\nB\nC\nD")
                   "A\nB\nC\nD\n\nXP\nA\nB\nC\nD"))))

(ert-deftest tmux-control-test-compact-respects-window-for-runs ()
  ;; A repeated body older than the recent window is not stripped: the
  ;; interior-run search only looks back `tmux-control-compact-scrollback-window'
  ;; lines.
  (let ((tmux-control-compact-scrollback-window 2)
        (tmux-control-scrollback-frame-start-regexp tmux-control-test--frame-re)
        (tmux-control-scrollback-chrome-regexps tmux-control-test--chrome-res))
    (should (equal (tmux-control--compact-repeated-redraw-lines
                    (concat "[Session]\nA\nB\nC\nD\nE\nF\n"
                            "[Session]\nXP\nA\nB\nC\nD\nE\nF"))
                   "A\nB\nC\nD\nE\nF\n\nXP\nA\nB\nC\nD\nE\nF"))))

(ert-deftest tmux-control-test-strip-seen-runs ()
  (let ((tmux-control-compact-scrollback-window 300))
    ;; A distinctive 6-line run already in OUT is removed, leaving the
    ;; new leading line.
    (should (equal (tmux-control--strip-seen-runs
                    '("A" "B" "C" "D" "E" "F")
                    '("new" "A" "B" "C" "D" "E" "F"))
                   '("new")))
    ;; A short run (below threshold) is preserved.
    (should (equal (tmux-control--strip-seen-runs
                    '("A" "B" "C" "D")
                    '("new" "A" "B" "C" "D"))
                   '("new" "A" "B" "C" "D")))))

(ert-deftest tmux-control-test-redraw-run-distinctive-p ()
  ;; Needs >=4 nonblank lines and >=3 distinct ones.
  (should (tmux-control--redraw-run-distinctive-p '("a" "b" "c" "d")))
  (should-not (tmux-control--redraw-run-distinctive-p '("a" "b" "c")))
  (should-not (tmux-control--redraw-run-distinctive-p '("a" "a" "a" "a")))
  (should-not (tmux-control--redraw-run-distinctive-p '("a" "" "b" "" "c"))))

;;; Compaction invariants (property tests over a realistic fixture).
;;
;; These guard the *class* of "repeated content in scrollback" bugs rather
;; than one hand-picked example: they assert structural invariants on the
;; compacted output instead of an exact string, so a regression that lets a
;; redrawn panel through is caught even if its exact shape differs.

(defun tmux-control-test--window-repeats-p (text n)
  "Return non-nil when some run of N consecutive lines repeats in TEXT."
  (let* ((lines (split-string text "\n"))
         (len (length lines))
         (seen (make-hash-table :test #'equal))
         (found nil)
         (i 0))
    (while (and (<= (+ i n) len) (not found))
      (let ((window (mapconcat #'identity (cl-subseq lines i (+ i n)) "\n")))
        (if (gethash window seen)
            (setq found t)
          (puthash window t seen)))
      (setq i (1+ i)))
    found))

(defconst tmux-control-test--copilot-redraw
  (let ((panel (concat "  | file_alpha.py\n"
                       "  | file_beta.py\n"
                       "  | file_gamma.py\n"
                       "  | file_delta.py\n"
                       "  | file_epsilon.py\n"
                       "  | file_zeta.py\n"
                       "  | file_eta.py\n"
                       "  + 7 lines"))
        (status " @ files . # issues                  Auto -> GPT"))
    (mapconcat (lambda (prompt)
                 (concat "[Session]\n" panel "\n" prompt "\n" status))
               '("> s" "> se" "> sea")
               "\n"))
  "A copilot-style capture: one panel redrawn across three keystroke frames,
each wrapped in an evolving prompt line and a status bar.")

(ert-deftest tmux-control-test-compact-no-repeated-redraw-run ()
  ;; The panel body (8 distinctive lines) must appear at most once: no run
  ;; of 6 consecutive lines may repeat in the compacted output.
  (let* ((tmux-control-compact-scrollback-window 300)
         (tmux-control-scrollback-frame-start-regexp tmux-control-test--frame-re)
         (tmux-control-scrollback-chrome-regexps tmux-control-test--chrome-res)
         (out (tmux-control--compact-repeated-redraw-lines
               tmux-control-test--copilot-redraw)))
    (should-not (tmux-control-test--window-repeats-p out 6))
    ;; The distinctive panel survives exactly once.
    (should (= 1 (length (seq-filter (lambda (l) (equal l "  | file_eta.py"))
                                     (split-string out "\n")))))))

(ert-deftest tmux-control-test-compact-is-idempotent ()
  ;; Compacting already-compacted text changes nothing: a stable fixpoint.
  (let* ((tmux-control-compact-scrollback-window 300)
         (tmux-control-scrollback-frame-start-regexp tmux-control-test--frame-re)
         (tmux-control-scrollback-chrome-regexps tmux-control-test--chrome-res)
         (once (tmux-control--compact-repeated-redraw-lines
                tmux-control-test--copilot-redraw))
         (twice (tmux-control--compact-repeated-redraw-lines once)))
    (should (equal once twice))))

(ert-deftest tmux-control-test-compact-output-is-subset-of-input ()
  ;; Compaction only ever drops lines: every nonblank line in the output
  ;; must have appeared verbatim in the input, and the output is no longer
  ;; than the input.  This catches accidental duplication or fabrication.
  (let* ((tmux-control-compact-scrollback-window 300)
         (tmux-control-scrollback-frame-start-regexp tmux-control-test--frame-re)
         (tmux-control-scrollback-chrome-regexps tmux-control-test--chrome-res)
         (input tmux-control-test--copilot-redraw)
         (in-lines (split-string input "\n"))
         (out (tmux-control--compact-repeated-redraw-lines input))
         (out-lines (split-string out "\n")))
    (should (<= (length out-lines) (length in-lines)))
    (dolist (line out-lines)
      (unless (string-empty-p (string-trim line))
        (should (member line in-lines))))))

;;; Generic (auto-detected) frame start -- compaction without a per-app regexp.

(ert-deftest tmux-control-test-auto-frame-start-line-detects ()
  ;; With NO frame-start regexp configured, the repeated screen-top line is
  ;; found automatically: among lines that recur once per frame, the earliest
  ;; (the actual top) wins the tie.
  (let ((tmux-control-scrollback-frame-start-regexp nil)
        (tmux-control-compact-scrollback-window 300))
    (should (equal (tmux-control--auto-frame-start-line
                    (mapcar #'string-trim-right
                            (split-string tmux-control-test--copilot-redraw "\n")))
                   "[Session]"))))

(ert-deftest tmux-control-test-auto-frame-start-line-nil-on-plain ()
  ;; Ordinary scrollback (no repeating frame) yields no marker, so auto
  ;; compaction is a no-op and never mangles plain output.
  (let ((tmux-control-scrollback-frame-start-regexp nil)
        (tmux-control-compact-scrollback-window 300))
    ;; All-distinct lines: nothing recurs.
    (should-not (tmux-control--auto-frame-start-line
                 '("ls -la" "total 5" "drwxr-xr-x a" "drwxr-xr-x b"
                   "-rw-r--r-- c" "echo hi" "hi there" "make all" "done now")))
    ;; A block repeated only twice is below the recurrence threshold.
    (should-not (tmux-control--auto-frame-start-line
                 '("HEAD" "aa" "bb" "cc" "dd" "HEAD" "aa" "bb" "cc" "dd")))))

(ert-deftest tmux-control-test-auto-compaction-collapses-without-regexp ()
  ;; The whole pipeline collapses a repainted panel using ONLY auto-detection
  ;; (no frame-start regexp, no chrome regexps): the panel body survives once.
  (let* ((tmux-control-compact-scrollback-window 300)
         (tmux-control-scrollback-frame-start-regexp nil)
         (tmux-control-scrollback-chrome-regexps nil)
         (auto (tmux-control--auto-frame-start-line
                (mapcar #'string-trim-right
                        (split-string tmux-control-test--copilot-redraw "\n")))))
    (should (equal auto "[Session]"))
    (let* ((tmux-control--auto-frame-start auto)
           (out (tmux-control--compact-repeated-redraw-lines
                 tmux-control-test--copilot-redraw)))
      (should-not (tmux-control-test--window-repeats-p out 6))
      (should (= 1 (length (seq-filter (lambda (l) (equal l "  | file_eta.py"))
                                       (split-string out "\n"))))))))

(ert-deftest tmux-control-test-auto-compaction-keeps-surrounding-plain ()
  ;; Real scrollback is mixed: plain command output before and after a
  ;; repainting block must survive; only the repeated frames collapse.
  (let* ((tmux-control-compact-scrollback-window 300)
         (tmux-control-scrollback-frame-start-regexp nil)
         (tmux-control-scrollback-chrome-regexps nil)
         (text (concat "$ ls -la\ntotal 9\nfile-one.txt\nfile-two.txt\n"
                       tmux-control-test--copilot-redraw
                       "\n$ git status\nclean tree\n"))
         (auto (tmux-control--auto-frame-start-line
                (mapcar #'string-trim-right (split-string text "\n"))))
         (tmux-control--auto-frame-start auto)
         (out (tmux-control--compact-repeated-redraw-lines text)))
    (should (equal auto "[Session]"))
    ;; Surrounding plain lines survive.
    (should (string-match-p "ls -la" out))
    (should (string-match-p "file-two.txt" out))
    (should (string-match-p "git status" out))
    (should (string-match-p "clean tree" out))
    ;; The repeated panel collapsed.
    (should-not (tmux-control-test--window-repeats-p out 6))))

(ert-deftest tmux-control-test-auto-compaction-marker-above-volatile-line ()
  ;; A capture that begins mid-frame leaves the tie-winning frame edge sitting
  ;; just above a volatile line (a token counter).  The shared redraw body is
  ;; then one line BELOW the marker, not at it; compaction must still detect
  ;; the frame and collapse it while keeping every volatile line.  (Regression:
  ;; the share-body check used to require the run to start at the marker, so it
  ;; vetoed this marker and disabled compaction entirely.)
  (let* ((tmux-control-compact-scrollback-window 300)
         (tmux-control-scrollback-frame-start-regexp nil)
         (tmux-control-scrollback-chrome-regexps nil)
         (frame (concat "==== panel bottom ====\n"
                        "  tokens: %d\n"
                        "---- panel top ----\n"
                        "  Claude Code\n"
                        "  > Try edit a file\n"
                        "  Ask me to build code\n"
                        "  explain this code\n"
                        "  ? for shortcuts\n"
                        "  ready.\n"))
         (text (concat (format frame 100) (format frame 200)
                       (format frame 300) (format frame 400)))
         (auto (tmux-control--auto-frame-start-line
                (mapcar #'string-trim-right (split-string text "\n"))))
         (tmux-control--auto-frame-start auto)
         (out (tmux-control--compact-repeated-redraw-lines text))
         (lines (split-string out "\n")))
    ;; A marker is found despite the volatile line right after it.
    (should auto)
    ;; The repeated panel body survives exactly once...
    (should (= 1 (length (seq-filter (lambda (l) (equal l "  Claude Code")) lines))))
    ;; ...while every per-frame token line is preserved.
    (dolist (n '(100 200 300 400))
      (should (member (format "  tokens: %d" n) lines)))))

(ert-deftest tmux-control-test-scrollback-match-key ()
  ;; The match key is width-insensitive: a trailing padded gutter glyph, the
  ;; length of a stretched rule, and alignment padding all wash out, while
  ;; content differences survive.
  (let ((key #'tmux-control--scrollback-match-key))
    ;; Right-edge gutter at different columns -> same key.
    (should (equal (funcall key "  hello world           ┃")
                   (funcall key "  hello world   ┃")))
    (should (equal (funcall key "  hello world   ┃") "hello world"))
    ;; A glyph with no padding before it is content, not a gutter.
    (should (equal (funcall key "└────┘┃") "└────┘┃"))
    ;; Rules stretched to different pane widths -> same key.
    (should (equal (funcall key (make-string 120 ?─))
                   (funcall key (make-string 100 ?─))))
    ;; Right-aligned status text -> padding collapses.
    (should (equal (funcall key " /proj        Session: 9 AIC used")
                   (funcall key " /proj   Session: 9 AIC used")))
    ;; Content still distinguishes.
    (should-not (equal (funcall key "alpha   ┃") (funcall key "beta   ┃")))
    (should-not (equal (funcall key "Session: 9 AIC used")
                       (funcall key "Session: 12 AIC used")))))

(ert-deftest tmux-control-test-auto-compaction-collapses-resized-redraws ()
  ;; A TUI repainted across pane RESIZES re-emits each line dressed for the
  ;; new width: gutter glyph at the last column, status text right-aligned,
  ;; rules stretched.  Raw comparison sees all-new content; key comparison
  ;; collapses the repeats.  Modeled on the GitHub Copilot CLI, which also has
  ;; no stable frame-top chrome (its status line carries a changing credit
  ;; counter), so detection must anchor on a recurring body line.
  (let* ((tmux-control-compact-scrollback t)
         (tmux-control-compact-scrollback-window 300)
         (tmux-control-scrollback-frame-start-regexp nil)
         (tmux-control-scrollback-chrome-regexps nil)
         (frame
          (lambda (w)
            (concat
             (format " /proj%sSession: 3 AIC used\n" (make-string (- w 30) ?\s))
             (mapconcat
              (lambda (word)
                (let ((body (format "  build step %s done" word)))
                  (concat body (make-string (- w (length body) 1) ?\s) "┃\n")))
              '("alpha" "beta" "gamma" "delta" "epsilon" "zeta" "eta" "theta")
              "")
             (make-string w ?─) "\n"
             "❯ waiting\n"
             (format " / commands · ? help%sClaude\n" (make-string (- w 26) ?\s)))))
         (text (concat (funcall frame 80) (funcall frame 60)
                       (funcall frame 80) (funcall frame 60)))
         (out (tmux-control--prepare-scrollback-text text))
         (out-keys (mapcar #'tmux-control--scrollback-match-key
                           (split-string out "\n"))))
    ;; Every body line survives exactly once, despite no two frames being
    ;; raw-identical neighbours.
    (dolist (word '("alpha" "beta" "gamma" "delta" "epsilon" "zeta"))
      (should (= 1 (seq-count
                    (lambda (k) (equal k (format "build step %s done" word)))
                    out-keys))))))

(ert-deftest tmux-control-test-merge-overlap-strips-remainder ()
  ;; A few lines of suffix/prefix overlap must not smuggle in a repeated
  ;; frame body: the post-overlap remainder is still stripped of runs
  ;; already present in OUT.  (Regression: the overlap path used to append
  ;; the remainder verbatim, so a chunk that happened to extend OUT by a
  ;; couple of lines re-added a whole already-seen redraw.)
  (let ((tmux-control-compact-scrollback-window 300))
    (should (equal (tmux-control--merge-scrollback-chunk
                    '("P1" "P2" "A" "B" "C" "D" "E" "F")
                    '("E" "F" "X" "A" "B" "C" "D" "E" "F"))
                   '("P1" "P2" "A" "B" "C" "D" "E" "F" "X")))))

(ert-deftest tmux-control-test-auto-compaction-skips-subthreshold-frequent-line ()
  ;; The most frequent candidate is not blindly accepted.  A small panel whose
  ;; shared body is below the redraw-run threshold recurs more often than a
  ;; larger one, but cannot anchor compaction; the detector must fall through
  ;; to the larger panel that genuinely repaints.  (Regression: detection used
  ;; to commit to the single most frequent line and give up if it failed.)
  (let* ((tmux-control-compact-scrollback-window 300)
         (tmux-control-scrollback-frame-start-regexp nil)
         (tmux-control-scrollback-chrome-regexps nil)
         (small (concat "== small ==\n  s-a\n  s-b\n  uniq-%d\n"))      ; shared body 3 lines (< 6)
         (big (concat "[ big panel ]\n  b-1\n  b-2\n  b-3\n  b-4\n"
                      "  b-5\n  b-6\n  count %d\n"))                     ; shared body 7 lines
         (text (concat (format small 1) (format small 2) (format small 3)
                       (format small 4) (format small 5)
                       (format big 1) (format big 2) (format big 3) (format big 4)))
         (auto (tmux-control--auto-frame-start-line
                (mapcar #'string-trim-right (split-string text "\n"))))
         (tmux-control--auto-frame-start auto)
         (out (tmux-control--compact-repeated-redraw-lines text))
         (lines (split-string out "\n")))
    (should auto)
    ;; The big panel body collapsed to a single copy...
    (should (= 1 (length (seq-filter (lambda (l) (equal l "  b-3")) lines))))
    ;; ...its per-frame counts are kept...
    (dolist (n '(1 2 3 4))
      (should (member (format "  count %d" n) lines)))
    ;; ...and the sub-threshold small panel is left intact (all 5 uniq lines).
    (dolist (n '(1 2 3 4 5))
      (should (member (format "  uniq-%d" n) lines)))))

;;; Live-state decision logic (pure predicates extracted from the
;;; side-effecting wheel/alt-screen code, so the truth tables can be
;;; exhaustively tested without a live tmux server or Eat terminal).

(ert-deftest tmux-control-test-interpret-alt-screen-reply-window ()
  ;; Window-level query: "on"/"off" resolve; anything else means inherit.
  (should (equal (tmux-control--interpret-alt-screen-reply '("on") nil)
                 '(:honored . t)))
  (should (equal (tmux-control--interpret-alt-screen-reply '("off") nil)
                 '(:honored . nil)))
  ;; Whitespace around a real value is trimmed.
  (should (equal (tmux-control--interpret-alt-screen-reply '("  on  ") nil)
                 '(:honored . t)))
  ;; Empty / blank / missing replies fall through to a global lookup.
  (should (eq (tmux-control--interpret-alt-screen-reply '() nil) :inherit))
  (should (eq (tmux-control--interpret-alt-screen-reply '("") nil) :inherit))
  (should (eq (tmux-control--interpret-alt-screen-reply '("   ") nil) :inherit))
  ;; An unrecognized value is treated as inherit, not silently honored.
  (should (eq (tmux-control--interpret-alt-screen-reply '("maybe") nil)
              :inherit)))

(ert-deftest tmux-control-test-interpret-alt-screen-reply-global ()
  ;; Global default: on unless explicitly "off".  This is the branch that
  ;; the phantom-alt-screen fix depends on.
  (should (equal (tmux-control--interpret-alt-screen-reply '("off") t)
                 '(:honored . nil)))
  (should (equal (tmux-control--interpret-alt-screen-reply '("on") t)
                 '(:honored . t)))
  ;; A missing global value means the built-in default (on).
  (should (equal (tmux-control--interpret-alt-screen-reply '() t)
                 '(:honored . t)))
  (should (equal (tmux-control--interpret-alt-screen-reply '("") t)
                 '(:honored . t))))

(ert-deftest tmux-control-test-alt-screen-warning-throttled ()
  ;; Issue #102: one warning per connection when alternate-screen is off,
  ;; never when honored, never when suppressed.
  (let (warnings)
    (cl-letf (((symbol-function 'display-warning)
               (lambda (&rest _) (push t warnings))))
      ;; honored -> no warning
      (with-temp-buffer
        (setq-local tmux-control--alt-screen-honored t)
        (setq-local tmux-control--alt-screen-warned nil)
        (let ((tmux-control-warn-on-alternate-screen-off t))
          (tmux-control--maybe-warn-alternate-screen-off))
        (should (null warnings)))
      ;; off + enabled -> exactly one warning across repeated refreshes
      (with-temp-buffer
        (setq-local tmux-control--alt-screen-honored nil)
        (setq-local tmux-control--alt-screen-warned nil)
        (setq-local tmux-control--host nil)
        (setq-local tmux-control--session "s")
        (let ((tmux-control-warn-on-alternate-screen-off t))
          (tmux-control--maybe-warn-alternate-screen-off)
          (tmux-control--maybe-warn-alternate-screen-off))
        (should (= (length warnings) 1))
        (should tmux-control--alt-screen-warned))
      ;; suppressed -> never
      (setq warnings nil)
      (with-temp-buffer
        (setq-local tmux-control--alt-screen-honored nil)
        (setq-local tmux-control--alt-screen-warned nil)
        (let ((tmux-control-warn-on-alternate-screen-off nil))
          (tmux-control--maybe-warn-alternate-screen-off))
        (should (null warnings))))))

(ert-deftest tmux-control-test-alt-screen-effective-p ()
  ;; Truly on the alternate screen only when tmux honors it AND Eat reports
  ;; it.  The phantom case (Eat says alt, tmux says not honored) is nil.
  (should (eq (tmux-control--alt-screen-effective-p t t) t))
  (should (eq (tmux-control--alt-screen-effective-p t nil) nil))
  (should (eq (tmux-control--alt-screen-effective-p nil t) nil))
  (should (eq (tmux-control--alt-screen-effective-p nil nil) nil))
  ;; Always returns a normalized boolean, never a truthy non-t value.
  (should (eq (tmux-control--alt-screen-effective-p t "alt") t)))

(ert-deftest tmux-control-test-no-line-wrap ()
  ;; Terminal grid rows must truncate, not wrap.  The helper runs AFTER the
  ;; major mode because a globalized `visual-line-mode' re-enables itself (and
  ;; `word-wrap') on `after-change-major-mode-hook', undoing a mode-body
  ;; setting -- so it must force truncation even when visual-line-mode is
  ;; already on (stood in for here).
  (with-temp-buffer
    (visual-line-mode 1)
    (should (bound-and-true-p visual-line-mode))
    (should word-wrap)                  ; precondition: visual-line set it
    (tmux-control--no-line-wrap)
    (should-not (bound-and-true-p visual-line-mode))
    (should-not word-wrap)
    (should truncate-lines))
  ;; The scrollback pager deliberately keeps the opposite: it wraps to show
  ;; overflowing history, so the two must not drift into agreement.
  (with-temp-buffer
    (tmux-control-scrollback-mode)
    (should-not truncate-lines)))

(ert-deftest tmux-control-test-coalesced-wheel-events-bound ()
  ;; A fast flick coalesces into double-/triple-wheel; those must route to
  ;; the same handlers as a single tick, not fall through to pixel-scroll.
  (dolist (ev '([double-wheel-up] [triple-wheel-up]))
    (should (eq (lookup-key tmux-control--override-map ev)
                #'tmux-control-wheel-scroll))
    (should (eq (lookup-key tmux-control--char-mode-map ev)
                #'tmux-control-wheel-scroll)))
  (dolist (ev '([double-wheel-down] [triple-wheel-down]))
    (should (eq (lookup-key tmux-control--override-map ev)
                #'tmux-control-wheel-down))
    (should (eq (lookup-key tmux-control--char-mode-map ev)
                #'tmux-control-wheel-down))
    (should (eq (lookup-key tmux-control-scrollback-mode-map ev)
                #'tmux-control-scrollback-wheel-down))
    (should (eq (lookup-key tmux-control--scrollback-override-map ev)
                #'tmux-control-scrollback-wheel-down))))

(ert-deftest tmux-control-test-effective-alt-screen-honored ()
  ;; The phantom-alt-screen correction is resolved only in the controller
  ;; buffer; a render buffer (per-window or tiled pane) must defer to its
  ;; controller, not read its own frozen-`t' local -- else wheel-up would
  ;; forward to the pane instead of opening scrollback under
  ;; `alternate-screen off'.
  (let ((controller (generate-new-buffer " *tc-test-ctrl*")))
    (unwind-protect
        (progn
          (with-current-buffer controller
            (setq-local tmux-control--alt-screen-honored nil) ; resolved: off
            (setq-local tmux-control--controller nil))        ; it IS the controller
          ;; A render buffer keeps the conservative `t' it was created with...
          (with-temp-buffer
            (setq-local tmux-control--alt-screen-honored t)
            (setq-local tmux-control--controller controller)
            ;; ...but the effective value comes from the controller.
            (should (eq (tmux-control--effective-alt-screen-honored) nil)))
          ;; The controller itself reads its own resolved local.
          (with-current-buffer controller
            (should (eq (tmux-control--effective-alt-screen-honored) nil))
            (setq-local tmux-control--alt-screen-honored t)
            (should (eq (tmux-control--effective-alt-screen-honored) t)))
          ;; A dead controller falls back to the buffer's own local.
          (with-temp-buffer
            (setq-local tmux-control--alt-screen-honored t)
            (setq-local tmux-control--controller (generate-new-buffer " *dead*"))
            (kill-buffer tmux-control--controller)
            (should (eq (tmux-control--effective-alt-screen-honored) t))))
      (when (buffer-live-p controller) (kill-buffer controller)))))

(ert-deftest tmux-control-test-wheel-should-enter-scrollback-p ()
  ;; The full gate: enter scrollback only on wheel-up, when enabled and
  ;; detectable, over a normal-screen pane that has not grabbed the mouse.
  (should (tmux-control--wheel-should-enter-scrollback-p
           'wheel-up t t nil nil))
  ;; Wheel-down is always forwarded.
  (should-not (tmux-control--wheel-should-enter-scrollback-p
               'wheel-down t t nil nil))
  ;; Disabled by configuration.
  (should-not (tmux-control--wheel-should-enter-scrollback-p
               'wheel-up nil t nil nil))
  ;; Screen state cannot be read -> stay conservative, forward the event.
  (should-not (tmux-control--wheel-should-enter-scrollback-p
               'wheel-up t nil nil nil))
  ;; Genuine alternate-screen application keeps the wheel.
  (should-not (tmux-control--wheel-should-enter-scrollback-p
               'wheel-up t t t nil))
  ;; Mouse-aware application keeps the wheel.
  (should-not (tmux-control--wheel-should-enter-scrollback-p
               'wheel-up t t nil t)))

(ert-deftest tmux-control-test-parse-pane-size ()
  ;; A well-formed reply yields a (WIDTH . HEIGHT) cons of positive ints.
  ;; The reply list arrives in reverse order, possibly padded with blanks.
  (should (equal '(92 . 44)
                 (tmux-control--parse-pane-size '("92x44"))))
  (should (equal '(90 . 24)
                 (tmux-control--parse-pane-size '("" "90x24" ""))))
  ;; Surrounding whitespace is tolerated.
  (should (equal '(80 . 25)
                 (tmux-control--parse-pane-size '("  80x25  "))))
  ;; Zero or negative dimensions are rejected.
  (should-not (tmux-control--parse-pane-size '("0x44")))
  (should-not (tmux-control--parse-pane-size '("92x0")))
  ;; Malformed or empty replies yield nil rather than a bogus size.
  (should-not (tmux-control--parse-pane-size '("can't find pane")))
  (should-not (tmux-control--parse-pane-size '("92 44")))
  (should-not (tmux-control--parse-pane-size '("")))
  (should-not (tmux-control--parse-pane-size nil)))

(ert-deftest tmux-control-test-parse-cursor-pos ()
  ;; A well-formed "X,Y" reply yields a (X . Y) cons of 0-indexed coords.
  (should (equal '(42 . 2) (tmux-control--parse-cursor-pos '("42,2"))))
  (should (equal '(0 . 0) (tmux-control--parse-cursor-pos '("0,0"))))
  (should (equal '(13 . 48) (tmux-control--parse-cursor-pos '("13,48,1"))))
  (should (equal '(13 . 48) (tmux-control--parse-cursor-pos '("13,48,"))))
  ;; Reverse-order/padded reply lists and surrounding whitespace are tolerated.
  (should (equal '(7 . 3) (tmux-control--parse-cursor-pos '("" "  7,3 " ""))))
  ;; Malformed or empty replies yield nil rather than a bogus position.
  (should-not (tmux-control--parse-cursor-pos '("42 2")))
  (should-not (tmux-control--parse-cursor-pos '("nope")))
  (should-not (tmux-control--parse-cursor-pos '("")))
  (should-not (tmux-control--parse-cursor-pos nil)))

(ert-deftest tmux-control-test-parse-cursor-visible ()
  ;; tmux's cursor_flag is carried alongside the cursor coordinates.
  (should (eq :visible (tmux-control--parse-cursor-visible '("13,48,1"))))
  (should (eq :hidden (tmux-control--parse-cursor-visible '("13,48,0"))))
  ;; Older or malformed replies leave the current Eat cursor visibility alone.
  (should (eq :unknown (tmux-control--parse-cursor-visible '("13,48"))))
  (should (eq :unknown (tmux-control--parse-cursor-visible '("13,48,"))))
  (should (eq :unknown (tmux-control--parse-cursor-visible '("13,48,2"))))
  (should (eq :unknown (tmux-control--parse-cursor-visible nil))))

(ert-deftest tmux-control-test-capture-n-supported-p ()
  ;; capture-pane -N landed in tmux 3.1.
  (should (tmux-control--capture-n-supported-p "3.1"))
  (should (tmux-control--capture-n-supported-p "3.6a"))
  (should (tmux-control--capture-n-supported-p "next-3.5"))
  (should (tmux-control--capture-n-supported-p "4.0"))
  (should-not (tmux-control--capture-n-supported-p "3.0a"))
  (should-not (tmux-control--capture-n-supported-p "2.9"))
  (should-not (tmux-control--capture-n-supported-p "1.8"))
  (should-not (tmux-control--capture-n-supported-p nil))
  (should-not (tmux-control--capture-n-supported-p "garbage")))

(ert-deftest tmux-control-test-screen-seed-sequence-cursor ()
  ;; With no live terminal the grid defaults to 80x24.  The seed string
  ;; paints the captured lines and ends with a cursor-positioning escape
  ;; derived from tmux's 0-indexed (X . Y), converted to 1-based row/column.
  (let ((tmux-control--terminal nil))
    (let ((seq (tmux-control--screen-seed-sequence "line one\nline two\n" '(42 . 2))))
      (should (string-match-p "line one" seq))
      (should (string-match-p "line two" seq))
      (should (string-suffix-p "\e[3;43H" seq)))
    ;; Without a queried cursor, fall back to the bottom-left of the grid.
    (should (string-suffix-p
             "\e[24;1H"
             (tmux-control--screen-seed-sequence "x\n" nil)))
    ;; Out-of-range coordinates are clamped to the grid.
    (should (string-suffix-p
             "\e[24;80H"
             (tmux-control--screen-seed-sequence "x\n" '(200 . 100))))
    ;; Known cursor visibility is restored before the cursor is positioned.
    (should (string-suffix-p
             "\e[?25h\e[m\e[3;43H"
             (tmux-control--screen-seed-sequence "x\n" '(42 . 2) :visible)))
    (should (string-suffix-p
             "\e[?25l\e[m\e[3;43H"
             (tmux-control--screen-seed-sequence "x\n" '(42 . 2) :hidden)))))

(ert-deftest tmux-control-test-screen-seed-sequence-preserves-trailing ()
  ;; A captured line with a trailing background fill (as `capture-pane -N'
  ;; produces for a full-width panel) must keep its trailing cells -- not be
  ;; right-trimmed -- and the row must be reset+erased BEFORE the line is
  ;; painted so the fill is preserved rather than cleared away after it.
  (let ((tmux-control--terminal nil))
    (let ((seq (tmux-control--screen-seed-sequence
                (concat "\e[42mbox" (make-string 5 ?\s) "\n") nil)))
      (should (string-match-p (concat "box" (make-string 5 ?\s)) seq))
      (should (string-match-p "\e\\[1;1H\e\\[m\e\\[K\e\\[42mbox" seq)))))

(ert-deftest tmux-control-test-screen-seed-sequence-no-shared-literal ()
  ;; The escape list ends in `nreverse', which rewires its tail in place.
  ;; Built from a shared quoted literal it leaked the prior frame into every
  ;; later seed and buried the home+clear mid-stream.  Built fresh, every
  ;; call -- not just the first -- must still BEGIN with the home+clear so no
  ;; stale content can survive ahead of it.
  (let ((tmux-control--terminal nil))
    (dotimes (_ 5)
      (let ((seq (tmux-control--screen-seed-sequence "alpha\nbeta\n" '(1 . 1))))
        (should (string-prefix-p "\e[H\e[2J" seq))))))

;;; Session and window listing (parsing only; the process call is stubbed).

(ert-deftest tmux-control-test-list-sessions-parses ()
  (cl-letf (((symbol-function 'tmux-control--call)
             (lambda (&rest _) "0\nwork\nscratch\n")))
    (should (equal (tmux-control--list-sessions nil "main")
                   '("0" "work" "scratch")))))

(ert-deftest tmux-control-test-list-sessions-error-is-nil ()
  (cl-letf (((symbol-function 'tmux-control--call)
             (lambda (&rest _) (error "no server running"))))
    ;; The listing failure is non-fatal; it logs a diagnostic and returns nil.
    (let ((inhibit-message t))
      (should (null (tmux-control--list-sessions nil "bogus"))))))

(ert-deftest tmux-control-test-list-windows-parses ()
  (cl-letf (((symbol-function 'tmux-control--call)
             (lambda (&rest _)
               "0\tbash\t1\n1\tvim\t0\n2\teditor pane\t0\ngarbage-line")))
    (should (equal (tmux-control--list-windows nil "main" "0")
                   '(("0" . "0: bash (active)")
                     ("1" . "1: vim")
                     ("2" . "2: editor pane"))))))

(ert-deftest tmux-control-test-list-panes-parses ()
  ;; Session-wide listing: pane id, window index+name, pane index, pane
  ;; active, window active, command, title.
  (cl-letf (((symbol-function 'tmux-control--call)
             (lambda (&rest _)
               (concat "%0\t0\tcode\t0\t1\t1\tbash\tclays-mbp\n"
                       ;; active pane of an INACTIVE window: not "[active]"
                       "%3\t1\tagents\t0\t1\t0\tnode\tcoder\n"
                       "%2\t1\tagents\t1\t0\t0\tnode\tnode\n"
                       "garbage-line"))))
    (should (equal (tmux-control--list-panes nil "main" "emacs")
                   ;; window:name.pane command (title-when-distinct) [active]
                   '(("%0" . "0:code.0 bash (clays-mbp) [active]")
                     ("%3" . "1:agents.0 node (coder)")
                     ;; title == command -> no redundant "(node)"
                     ("%2" . "1:agents.1 node"))))))

;;; Window-management command construction.

(defun tmux-control-test--capture-commands (thunk)
  "Call THUNK with command sending stubbed; return the list of sent commands."
  (let ((sent '()))
    (cl-letf (((symbol-function 'tmux-control--ensure-live) #'ignore)
              ((symbol-function 'tmux-control--refresh-active-pane) #'ignore)
              ((symbol-function 'tmux-control--send-command)
               (lambda (command &optional _kind) (push command sent))))
      (let ((tmux-control--session "0"))
        (funcall thunk)))
    (nreverse sent)))

(ert-deftest tmux-control-test-select-window-command ()
  ;; The session is quoted in the target so a name with spaces parses as one
  ;; token; tmux strips the quotes from a plain name like "0".
  (should (equal (tmux-control-test--capture-commands
                  (lambda () (tmux-control-select-window "2")))
                 '("select-window -t \"0\":2"))))

(ert-deftest tmux-control-test-new-window-command ()
  (should (equal (tmux-control-test--capture-commands
                  (lambda () (tmux-control-new-window "my win")))
                 '("new-window -t \"0\": -n \"my win\"")))
  (should (equal (tmux-control-test--capture-commands
                  (lambda () (tmux-control-new-window nil)))
                 '("new-window -t \"0\":"))))

(ert-deftest tmux-control-test-kill-window-command ()
  (should (equal (tmux-control-test--capture-commands
                  (lambda () (tmux-control-kill-window "1")))
                 '("kill-window -t \"0\":1"))))

(ert-deftest tmux-control-test-rename-window-command ()
  (should (equal (tmux-control-test--capture-commands
                  (lambda () (tmux-control-rename-window "1" "new name")))
                 '("rename-window -t \"0\":1 \"new name\"")))
  ;; An empty name is rejected.
  (should-error (tmux-control-test--capture-commands
                 (lambda () (tmux-control-rename-window "1" "")))
                :type 'user-error))

(ert-deftest tmux-control-test-split-pane-command ()
  ;; Split rides the control connection (`split-window -h'/`-v' at the active
  ;; pane).  From the single-pane controller view it auto-tiles so both panes
  ;; show; NOT from a render buffer (which must untile, not tile), NOT when
  ;; already tiled (the %layout-change re-tiles), and NOT when the option is
  ;; off.  `kill-pane' targets the active pane after confirmation.
  (let ((cmds '()) (tiles 0) (tiled-p nil))
    (cl-letf (((symbol-function 'tmux-control--ensure-live) #'ignore)
              ((symbol-function 'tmux-control--send-command)
               (lambda (c &optional _k) (push c cmds)))
              ((symbol-function 'tmux-control--tiled-mode-p)
               (lambda () tiled-p))
              ((symbol-function 'tmux-control-tile) (lambda () (cl-incf tiles))))
      (with-temp-buffer
        (setq-local tmux-control--active-pane "%3")
        (setq-local tmux-control--controller nil)
        ;; single-pane view, option on -> split + auto-tile
        (let ((tmux-control-split-pane-tiles t))
          (tmux-control-split-pane-right)
          (should (equal (car cmds) "split-window -h -t %3"))
          (should (= tiles 1))
          (tmux-control-split-pane-below)
          (should (equal (car cmds) "split-window -v -t %3"))
          (should (= tiles 2)))
        ;; option off -> split only
        (setq cmds nil tiles 0)
        (let ((tmux-control-split-pane-tiles nil))
          (tmux-control-split-pane-right)
          (should (equal cmds '("split-window -h -t %3")))
          (should (= tiles 0)))
        ;; render buffer (controller set) -> split only
        (setq cmds nil tiles 0 tmux-control--controller (current-buffer))
        (let ((tmux-control-split-pane-tiles t))
          (tmux-control-split-pane-right)
          (should (= tiles 0)))
        ;; already tiled -> no auto-tile
        (setq cmds nil tiles 0 tmux-control--controller nil tiled-p (current-buffer))
        (let ((tmux-control-split-pane-tiles t))
          (tmux-control-split-pane-right)
          (should (= tiles 0)))
        (setq tiled-p nil)
        ;; kill-pane targets the active pane after confirm
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
          (setq cmds nil)
          (tmux-control-kill-pane)
          (should (equal cmds '("kill-pane -t %3"))))))))

;;; ANSI escape stripping / display width (seed-screen color handling).

(ert-deftest tmux-control-test-strip-ansi-plain ()
  (should (equal (tmux-control--strip-ansi "hello") "hello")))

(ert-deftest tmux-control-test-strip-ansi-sgr ()
  (should (equal (tmux-control--strip-ansi "\e[31mRED\e[0m") "RED"))
  (should (equal (tmux-control--strip-ansi "\e[1m\e[32m dir \e[0m\e[39m\e[49m")
                 " dir ")))

(ert-deftest tmux-control-test-strip-ansi-truecolor-colon ()
  ;; Colon-delimited truecolor SGR (ESC[38:2::r:g:b m).
  (should (equal (tmux-control--strip-ansi "\e[38:2::255:0:0mX\e[0m") "X")))

(ert-deftest tmux-control-test-strip-ansi-osc-hyperlink ()
  ;; OSC 8 hyperlink, terminated by ST (ESC backslash).
  (should (equal (tmux-control--strip-ansi
                  "\e]8;;https://example.com\e\\link\e]8;;\e\\")
                 "link")))

(ert-deftest tmux-control-test-display-width-ignores-escapes ()
  (should (= (tmux-control--display-width "\e[31mRED\e[0m") 3))
  (should (= (tmux-control--display-width "\e[38:2::255:0:0mX\e[0m") 1))
  (should (= (tmux-control--display-width "plain") 5)))

;;; Window-layout string parsing (multi-pane tiling).

(ert-deftest tmux-control-test-layout-strip-checksum ()
  (should (equal (tmux-control--layout-strip-checksum "bf3a,80x24,0,0,1")
                 "80x24,0,0,1"))
  ;; All-digit checksum is still stripped (hex digits, then a comma).
  (should (equal (tmux-control--layout-strip-checksum "1234,80x24,0,0,1")
                 "80x24,0,0,1"))
  ;; An already-stripped string is returned unchanged: dims have an "x"
  ;; before any comma, so they never look like a checksum.
  (should (equal (tmux-control--layout-strip-checksum "80x24,0,0,1")
                 "80x24,0,0,1")))

(ert-deftest tmux-control-test-parse-layout-single ()
  (let ((node (tmux-control--parse-layout "bf3a,80x24,0,0,1")))
    (should (eq (plist-get node :type) 'leaf))
    (should (= (plist-get node :w) 80))
    (should (= (plist-get node :h) 24))
    (should (= (plist-get node :x) 0))
    (should (= (plist-get node :y) 0))
    (should (equal (plist-get node :id) "1"))))

(ert-deftest tmux-control-test-parse-layout-horizontal ()
  ;; Two panes side by side: a row, split horizontally.
  (let ((node (tmux-control--parse-layout
               "c2d8,80x24,0,0{40x24,0,0,1,39x24,41,0,2}")))
    (should (eq (plist-get node :type) 'split))
    (should (eq (plist-get node :dir) 'h))
    (let ((kids (plist-get node :children)))
      (should (= (length kids) 2))
      (should (equal (plist-get (nth 0 kids) :id) "1"))
      (should (= (plist-get (nth 0 kids) :w) 40))
      (should (equal (plist-get (nth 1 kids) :id) "2"))
      (should (= (plist-get (nth 1 kids) :x) 41)))))

(ert-deftest tmux-control-test-parse-layout-vertical ()
  ;; Two panes stacked: a column, split vertically.
  (let ((node (tmux-control--parse-layout
               "abcd,80x24,0,0[80x12,0,0,1,80x11,0,13,2]")))
    (should (eq (plist-get node :type) 'split))
    (should (eq (plist-get node :dir) 'v))
    (let ((kids (plist-get node :children)))
      (should (= (length kids) 2))
      (should (= (plist-get (nth 0 kids) :h) 12))
      (should (= (plist-get (nth 1 kids) :y) 13)))))

(ert-deftest tmux-control-test-parse-layout-nested ()
  ;; A row whose right child is itself a column of two panes:
  ;; left pane 1, right column of panes 2 (top) and 3 (bottom).
  (let* ((node (tmux-control--parse-layout
                "f00d,80x24,0,0{40x24,0,0,1,39x24,41,0[39x12,41,0,2,39x11,41,13,3]}"))
         (kids (plist-get node :children)))
    (should (eq (plist-get node :dir) 'h))
    (should (= (length kids) 2))
    (should (eq (plist-get (nth 0 kids) :type) 'leaf))
    (should (equal (plist-get (nth 0 kids) :id) "1"))
    (let ((right (nth 1 kids)))
      (should (eq (plist-get right :type) 'split))
      (should (eq (plist-get right :dir) 'v))
      (should (= (length (plist-get right :children)) 2)))
    ;; Leaves come back in reading order: 1, 2, 3.
    (should (equal (mapcar (lambda (l) (plist-get l :id))
                           (tmux-control--layout-leaves node))
                   '("1" "2" "3")))))

(ert-deftest tmux-control-test-parse-layout-leaves-single ()
  (let ((node (tmux-control--parse-layout "bf3a,80x24,0,0,1")))
    (should (equal (mapcar (lambda (l) (plist-get l :id))
                           (tmux-control--layout-leaves node))
                   '("1")))))

(ert-deftest tmux-control-test-parse-layout-malformed ()
  (should (null (tmux-control--parse-layout "")))
  (should (null (tmux-control--parse-layout "   ")))
  (should (null (tmux-control--parse-layout nil)))
  ;; Truncated / unterminated lists return nil rather than signalling.
  (should (null (tmux-control--parse-layout "bf3a,80x24,0,0{40x24,0,0,1")))
  (should (null (tmux-control--parse-layout "bf3a,not-a-layout"))))

(ert-deftest tmux-control-test-parse-window-state ()
  ;; The in-band `list-panes' reply (tab-separated: layout, then each pane's
  ;; geometry / cursor / cmd / title) parses to (LAYOUT . PANES) -- the layout
  ;; from the first line, the panes in order with their plists.
  (let* ((lines (list (mapconcat #'identity
                                 '("LAY" "%0" "0" "0" "40" "24" "1"
                                   "5" "3" "1" "bash" "tty")
                                 "\t")
                      (mapconcat #'identity
                                 '("LAY" "%1" "41" "0" "39" "24" "0"
                                   "0" "0" "0" "vim" "edit")
                                 "\t")))
         (state (tmux-control--parse-window-state lines))
         (panes (cdr state)))
    (should (equal (car state) "LAY"))
    (should (equal (mapcar #'car panes) '("%0" "%1")))
    (let ((p0 (cdr (assoc "%0" panes))))
      (should (= (plist-get p0 :left) 0))
      (should (= (plist-get p0 :width) 40))
      (should (eq (plist-get p0 :active) t))
      (should (equal (plist-get p0 :cursor) '(5 . 3)))
      (should (equal (plist-get p0 :cmd) "bash"))
      (should (equal (plist-get p0 :title) "tty")))
    (let ((p1 (cdr (assoc "%1" panes))))
      (should (eq (plist-get p1 :active) nil))
      (should (equal (plist-get p1 :cmd) "vim")))
    ;; A short/garbled line is skipped, not parsed into a bogus pane.
    (should (null (cdr (tmux-control--parse-window-state '("LAY\t%0\t0"))))))
  ;; Empty trailing fields (an unset pane title, sometimes an empty command)
  ;; must NOT drop the pane or shift columns: `split-string' with an explicit
  ;; separator keeps empty fields, so the line is still 12 fields.
  (let* ((line (concat "LAY\t%7\t0\t0\t80\t24\t1\t0\t0\t1\t\t")) ; empty cmd + title
         (panes (cdr (tmux-control--parse-window-state (list line))))
         (p (cdr (assoc "%7" panes))))
    (should (= (length panes) 1))
    (should p)
    (should (= (plist-get p :width) 80))     ; columns did not shift
    (should (equal (plist-get p :cmd) ""))
    (should (equal (plist-get p :title) ""))))

(ert-deftest tmux-control-test-parse-window-state-validates-pane-id ()
  ;; SECURITY: the pane id comes from the untrusted reply stream and is later
  ;; used as a command TARGET; only a canonical "%N" is accepted, so a crafted
  ;; id is dropped rather than smuggled into a command.
  (let* ((fields (lambda (id)
                   (mapconcat #'identity
                              (list "LAY" id "0" "0" "80" "24" "1" "0" "0" "1"
                                    "bash" "title")
                              "\t")))
         (panes (cdr (tmux-control--parse-window-state
                      (list (funcall fields "%2")
                            (funcall fields "%3; kill-server")
                            (funcall fields "%4 -t evil")
                            (funcall fields "@5")))))) ; window id, not a pane id
    (should (assoc "%2" panes))
    (should-not (assoc "%3; kill-server" panes))
    (should-not (assoc "%4 -t evil" panes))
    (should-not (assoc "@5" panes))
    (should (= (length panes) 1))))

(ert-deftest tmux-control-test-parse-window-state-tab-in-title ()
  ;; `pane_title' is the last field, but an app can set a title containing a
  ;; literal TAB (OSC 2).  It must be preserved whole, not truncated to its
  ;; pre-TAB fragment, and the pane must not be dropped or mis-counted.
  (let* ((line (mapconcat #'identity
                          '("LAY" "%0" "0" "0" "80" "24" "1"
                            "5" "6" "1" "bash" "a\tb\tc")
                          "\t"))
         (panes (cdr (tmux-control--parse-window-state (list line))))
         (p (cdr (assoc "%0" panes))))
    (should (= (length panes) 1))
    (should (equal (plist-get p :cmd) "bash"))
    (should (equal (plist-get p :title) "a\tb\tc"))))

(ert-deftest tmux-control-test-build-tiling-callback-aborts-when-cleared ()
  ;; The build is async: a teardown (untile, disconnect) during an in-flight
  ;; layout query clears `tmux-control--tiling-build-active', and the reply
  ;; callback must then ABORT rather than rebuild the torn-down view -- so a
  ;; late reply cannot resurrect a tiling the user just dismissed.
  (with-temp-buffer
    (setq-local tmux-control--tiling-build-active nil ; teardown cleared it
                tmux-control--tiled nil
                tmux-control--panes nil)
    ;; No error, no apply, no resurrection.
    (tmux-control--build-tiling-callback (current-buffer) '("ignored reply"))
    (should-not tmux-control--tiled)
    (should (null tmux-control--panes))))

(ert-deftest tmux-control-test-build-tiling-unmatched-exhaustion-clears-suppression ()
  ;; A persistent layout/pane-list mismatch retries a few times then gives
  ;; up.  The give-up path must reset the retry count AND release any
  ;; focus-follow suppression a window switch armed -- the flag is otherwise
  ;; cleared only by a SUCCESSFUL build, so a stuck mismatch would strand it
  ;; and silently stop a focused pane from selecting itself in tmux.
  (with-temp-buffer
    (let ((proc (make-pipe-process :name "tc-tile-test" :buffer (current-buffer)
                                   :noquery t)))
      (unwind-protect
          (cl-letf (((symbol-function 'tmux-control--schedule-retile)
                     (lambda (_controller) nil)))
            (setq-local tmux-control--process proc
                        tmux-control--tiled-layout nil
                        tmux-control--panes nil
                        tmux-control--unmatched-retries 4 ; one short of the cap
                        tmux-control--suppress-focus-follow t)
            ;; Leaf pane "0" at (0,0); geometry names a different pane at
            ;; different coords, so the leaf cannot be matched and the build
            ;; exhausts its retries.
            (tmux-control--build-tiling-apply
             (current-buffer) "bf3a,80x24,0,0,0" '(("%9" . (:left 5 :top 5))))
            (should (= tmux-control--unmatched-retries 0))
            (should-not tmux-control--suppress-focus-follow))
        (delete-process proc)))))

;;; Window tab bar.

(ert-deftest tmux-control-test-update-windows-parses-and-sorts ()
  ;; Reply lines may arrive in any order (the filter collects command output in
  ;; reverse); the parsed list is sorted by index, the active window becomes
  ;; current, and that window's stale activity marker is cleared.
  (with-temp-buffer
    (setq-local tmux-control--activity (make-hash-table :test 'equal))
    (puthash "2" t tmux-control--activity)
    (tmux-control--update-windows
     '("2\tgamma\t1\t0" "0\talpha\t0\t0" "1\tbeta\t0\t1"))
    (should (equal (mapcar (lambda (w) (plist-get w :index)) tmux-control--windows)
                   '("0" "1" "2")))
    (should (equal (mapcar (lambda (w) (plist-get w :name)) tmux-control--windows)
                   '("alpha" "beta" "gamma")))
    (should (equal tmux-control--current-window "2"))
    (should-not (gethash "2" tmux-control--activity))
    (should (plist-get (nth 2 tmux-control--windows) :active))
    (should (plist-get (nth 1 tmux-control--windows) :bell))))

(ert-deftest tmux-control-test-window-tab-bar-renders ()
  ;; The bar shows every window, marks the busy one, and faces each tab by
  ;; state; a tiled view shows no bar.
  (with-temp-buffer
    (setq-local tmux-control--tiled nil)
    (setq-local tmux-control--windows
                '((:index "0" :name "alpha" :active t :bell nil)
                  (:index "1" :name "beta" :active nil :bell nil)
                  (:index "2" :name "gamma" :active nil :bell nil)))
    (setq-local tmux-control--activity (make-hash-table :test 'equal))
    (puthash "2" t tmux-control--activity)
    (let ((bar (tmux-control--window-tab-bar)))
      (should (string-match-p "0:alpha" bar))
      (should (string-match-p "1:beta" bar))
      (should (string-match-p "2:gamma ●" bar))
      (should (eq (get-text-property (string-match "0:alpha" bar) 'face bar)
                  'tmux-control-tab-active))
      (should (eq (get-text-property (string-match "1:beta" bar) 'face bar)
                  'tmux-control-tab-inactive))
      (should (eq (get-text-property (string-match "2:gamma" bar) 'face bar)
                  'tmux-control-tab-activity))
      ;; Tabs are clickable by default; NO-KEYMAP makes them inert (scrollback).
      (should (get-text-property (string-match "0:alpha" bar) 'keymap bar))
      (let ((plain (tmux-control--window-tab-bar t)))
        (should-not (get-text-property (string-match "0:alpha" plain)
                                       'keymap plain))))
    (setq-local tmux-control--tiled t)
    (should (equal (tmux-control--window-tab-bar) ""))))

(ert-deftest tmux-control-test-note-pane-activity ()
  ;; Output in a background window flags it; output in the current window, or
  ;; during the post-repaint quiet period, does not.
  (with-temp-buffer
    (setq-local tmux-control--tiled nil)
    (setq-local tmux-control--current-window "0")
    (setq-local tmux-control--activity (make-hash-table :test 'equal))
    (setq-local tmux-control--pane-window (make-hash-table :test 'equal))
    (puthash "%0" (cons "0" "@0") tmux-control--pane-window)
    (puthash "%1" (cons "1" "@1") tmux-control--pane-window)
    (setq-local tmux-control--activity-quiet-until 0)
    (let ((tmux-control-window-tab-bar t))
      (tmux-control--note-pane-activity "%0")
      (should-not (gethash "0" tmux-control--activity))
      (tmux-control--note-pane-activity "%1")
      (should (gethash "1" tmux-control--activity))
      (clrhash tmux-control--activity)
      (setq-local tmux-control--activity-quiet-until (+ (float-time) 100))
      (tmux-control--note-pane-activity "%1")
      (should-not (gethash "1" tmux-control--activity)))
    ;; With the tab bar disabled the hot path is a no-op (its only consumer).
    (let ((tmux-control-window-tab-bar nil))
      (clrhash tmux-control--activity)
      (setq-local tmux-control--activity-quiet-until 0)
      (tmux-control--note-pane-activity "%1")
      (should-not (gethash "1" tmux-control--activity)))))

(ert-deftest tmux-control-test-paste-remapped-to-terminal ()
  ;; GUI / macOS paste gestures -- Cmd-V (`s-v'), the `[paste]' event, the
  ;; Edit > Paste menu -- resolve to the `yank' / `clipboard-yank' commands.
  ;; Eat's own map only rebinds C-y, M-y, S-insert and mouse yank, so those
  ;; gestures otherwise fall through to plain `yank' and insert into the Eat
  ;; buffer instead of sending to the pane.  tmux-control-mode-map must remap
  ;; every paste gesture -- including Eat's own C-y/M-y bindings, via the
  ;; eat-yank remaps -- to the tmux paste-buffer commands, which let tmux
  ;; apply bracketed paste exactly when the pane requested it.
  (dolist (cmd '(yank clipboard-yank eat-yank))
    (should (eq (lookup-key tmux-control-mode-map (vector 'remap cmd))
                'tmux-control-yank)))
  (dolist (cmd '(yank-pop eat-yank-from-kill-ring))
    (should (eq (lookup-key tmux-control-mode-map (vector 'remap cmd))
                'tmux-control-yank-from-kill-ring))))

(ert-deftest tmux-control-test-session-window-changed-external-reseeds ()
  ;; A %session-window-changed from an EXTERNAL switch (another client, a tmux
  ;; key binding, a script) must reseed the live view onto the new window's
  ;; active pane, so the view -- and scrollback, which captures
  ;; `tmux-control--active-pane' -- follows the tab bar instead of stranding on
  ;; the previous pane.  When THIS client initiated the switch,
  ;; `tmux-control--refresh-active-pane' already reseeded and recorded a
  ;; pending self-reseed, so the event tmux echoes back must NOT reseed again
  ;; (it would double-paint); it consumes one pending count.  A COUNT (not a
  ;; single flag) is needed so several rapid self-switches are each absorbed,
  ;; and a deadline clears a stale count so it never swallows a real external.
  (with-temp-buffer
    (setq-local tmux-control--tiled nil)
    (let ((reseeds 0) (refreshes 0)
          ;; This exercises the in-place reseed path; per-window buffers
          ;; replace it with a buffer swap (tested separately).
          (tmux-control-window-buffers nil))
      (cl-letf (((symbol-function 'tmux-control--flush-output-batch) #'ignore)
                ((symbol-function 'tmux-control--refresh-windows)
                 (lambda () (cl-incf refreshes)))
                ((symbol-function 'tmux-control--refresh-active-pane)
                 (lambda (&optional _self) (cl-incf reseeds))))
        ;; External switch: no pending self-reseed -> follow it (reseed).
        (setq-local tmux-control--self-reseed-pending 0)
        (setq-local tmux-control--self-reseed-until 0)
        (tmux-control--handle-line "%session-window-changed $0 @2")
        (should (= refreshes 1))
        (should (= reseeds 1))
        ;; Two rapid self-initiated switches in flight: each echoed event is
        ;; absorbed (no reseed) and consumes exactly one pending count -- a
        ;; single flag would absorb only the first and double-paint the second.
        (setq-local tmux-control--self-reseed-pending 2)
        (setq-local tmux-control--self-reseed-until (+ (float-time) 100))
        (tmux-control--handle-line "%session-window-changed $0 @3")
        (should (= refreshes 2))
        (should (= reseeds 1))
        (should (= tmux-control--self-reseed-pending 1))
        (tmux-control--handle-line "%session-window-changed $0 @4")
        (should (= refreshes 3))
        (should (= reseeds 1))
        (should (= tmux-control--self-reseed-pending 0))
        ;; A genuine external switch right afterwards still reseeds (the count
        ;; was fully consumed, not left armed).
        (tmux-control--handle-line "%session-window-changed $0 @0")
        (should (= refreshes 4))
        (should (= reseeds 2))
        ;; A stale pending count -- a self-switch that produced no event (a
        ;; no-op select, a background kill) -- does not permanently swallow
        ;; externals: once the deadline passes it is cleared and the switch is
        ;; followed.
        (setq-local tmux-control--self-reseed-pending 1)
        (setq-local tmux-control--self-reseed-until (- (float-time) 1))
        (tmux-control--handle-line "%session-window-changed $0 @1")
        (should (= refreshes 5))
        (should (= reseeds 3))
        (should (= tmux-control--self-reseed-pending 0))))))

(ert-deftest tmux-control-test-session-window-changed-tiled-retiles ()
  ;; In tiling mode the notification re-tiles to the new window's panes rather
  ;; than reseeding a single pane.
  (with-temp-buffer
    (setq-local tmux-control--tiled t)
    (setq-local tmux-control--retile-pending nil)
    (let ((reseeds 0))
      (cl-letf (((symbol-function 'tmux-control--flush-output-batch) #'ignore)
                ((symbol-function 'tmux-control--refresh-active-pane)
                 (lambda (&optional _self) (cl-incf reseeds))))
        (tmux-control--handle-line "%session-window-changed $0 @2")
        (should tmux-control--retile-pending)
        (should (= reseeds 0))))))

(ert-deftest tmux-control-test-eager-register-new-panes ()
  ;; A %layout-change that introduces a new pane registers a render buffer for
  ;; it NOW, marked fed-live, so its %output streams in live from the first
  ;; byte and the re-tile never seeds it (which would double-paint a freshly
  ;; split pane's opening screenful).  Existing panes are left untouched, and
  ;; nothing happens when the controller is not tiled.
  (let ((made '()))
    (cl-letf (((symbol-function 'tmux-control--make-pane-buffer)
               (lambda (pane-id &rest _)
                 (push pane-id made)
                 (generate-new-buffer (format " *tc-test-eager-%s*" pane-id)))))
      (with-temp-buffer
        (setq-local tmux-control--tiled t)
        (let ((buf0 (generate-new-buffer " *tc-test-eager-existing*")))
          (setq-local tmux-control--panes (list (cons "%0" buf0)))
          (unwind-protect
              (progn
                ;; A horizontal split of panes %0 (existing) and %1 (new).
                (tmux-control--eager-register-new-panes
                 (current-buffer)
                 "abcd,80x24,0,0{40x24,0,0,0,39x24,41,0,1}")
                ;; Only the NEW pane is made; the existing one is not remade.
                (should (equal made '("%1")))
                (should (assoc "%1" tmux-control--panes))
                (should (buffer-local-value 'tmux-control--pane-fed-live
                                            (cdr (assoc "%1" tmux-control--panes))))
                (should (eq (cdr (assoc "%0" tmux-control--panes)) buf0)))
            (dolist (c tmux-control--panes)
              (when (buffer-live-p (cdr c)) (kill-buffer (cdr c)))))))
      ;; Not tiled: a no-op (single-pane mode owns no per-pane buffers).
      (setq made '())
      (with-temp-buffer
        (setq-local tmux-control--tiled nil)
        (setq-local tmux-control--panes nil)
        (tmux-control--eager-register-new-panes
         (current-buffer) "abcd,80x24,0,0{40x24,0,0,0,39x24,41,0,1}")
        (should (null made))
        (should (null tmux-control--panes))))))

(ert-deftest tmux-control-test-cycle-session-wraps ()
  ;; next/previous-session step through the host/socket's sessions in tmux's
  ;; list order, wrapping at the ends, routing the target through
  ;; --connect-or-switch (reuse-or-connect).
  (with-temp-buffer
    (setq-local tmux-control--host nil)
    (setq-local tmux-control--socket-name "s")
    (setq-local tmux-control--session "b")
    (let ((switched nil))
      (cl-letf (((symbol-function 'tmux-control--list-sessions)
                 (lambda (_host _socket) '("a" "b" "c")))
                ((symbol-function 'tmux-control--connect-or-switch)
                 (lambda (_host _socket session) (setq switched session))))
        (tmux-control-next-session)       (should (equal switched "c"))
        (tmux-control-previous-session)   (should (equal switched "a"))
        (setq-local tmux-control--session "c")
        (tmux-control-next-session)       (should (equal switched "a"))   ; wrap fwd
        (setq-local tmux-control--session "a")
        (tmux-control-previous-session)   (should (equal switched "c")))))) ; wrap back

(ert-deftest tmux-control-test-select-session-requires-match ()
  ;; C-c C-s must not let a typo spawn a session: completing-read is called
  ;; with REQUIRE-MATCH non-nil, so only an existing session can be chosen.
  (with-temp-buffer
    (setq-local tmux-control--host nil)
    (setq-local tmux-control--socket-name "s")
    (setq-local tmux-control--session "a")
    (let ((require-match-arg 'unset))
      (cl-letf (((symbol-function 'tmux-control--list-sessions)
                 (lambda (_host _socket) '("a" "b")))
                ((symbol-function 'completing-read)
                 (lambda (_prompt _coll &optional _pred require-match &rest _)
                   (setq require-match-arg require-match)
                   "b"))
                ((symbol-function 'tmux-control--connect-or-switch) #'ignore))
        (tmux-control-select-session)
        (should require-match-arg)))))

(ert-deftest tmux-control-test-cycle-session-single-is-noop ()
  ;; With only the current session present, cycling does nothing.
  (with-temp-buffer
    (setq-local tmux-control--host nil)
    (setq-local tmux-control--socket-name "s")
    (setq-local tmux-control--session "only")
    (let ((switched nil))
      (cl-letf (((symbol-function 'tmux-control--list-sessions)
                 (lambda (_host _socket) '("only")))
                ((symbol-function 'tmux-control--connect-or-switch)
                 (lambda (&rest _) (setq switched t)))
                ((symbol-function 'tmux-control--message) #'ignore))
        (tmux-control-next-session)
        (should-not switched)))))

(ert-deftest tmux-control-test-live-session-buffers-filters ()
  ;; The flock view collects only plain live session buffers: not tiling pane
  ;; buffers (which carry a controller), not tiled controllers (which render
  ;; nothing), not dead connections; result sorted by buffer name.
  (let ((live (generate-new-buffer "*tmux-control:local:s1*"))
        (pane (generate-new-buffer "*tmux-control:local:s2pane*"))
        (tiled (generate-new-buffer "*tmux-control:local:s3*"))
        (dead (generate-new-buffer "*tmux-control:local:s4*")))
    (unwind-protect
        (progn
          (with-current-buffer live
            (setq-local tmux-control--session "s1")
            (setq-local tmux-control--process 'live))
          (with-current-buffer pane
            (setq-local tmux-control--session "s2")
            (setq-local tmux-control--controller live)
            (setq-local tmux-control--process 'live))
          (with-current-buffer tiled
            (setq-local tmux-control--session "s3")
            (setq-local tmux-control--tiled t)
            (setq-local tmux-control--process 'live))
          (with-current-buffer dead
            (setq-local tmux-control--session "s4")
            (setq-local tmux-control--process 'dead))
          (cl-letf (((symbol-function 'process-live-p)
                     (lambda (p) (eq p 'live))))
            (let ((got (mapcar #'buffer-name (tmux-control--live-session-buffers))))
              (should (member "*tmux-control:local:s1*" got))
              (should-not (member "*tmux-control:local:s2pane*" got))
              (should-not (member "*tmux-control:local:s3*" got))
              (should-not (member "*tmux-control:local:s4*" got)))))
      (kill-buffer live) (kill-buffer pane)
      (kill-buffer tiled) (kill-buffer dead))))

(ert-deftest tmux-control-test-connect-all-sessions-skips-live ()
  ;; C-u flock connects every session on the host/socket that is not already
  ;; live, and leaves the live ones alone.
  (with-temp-buffer
    (setq-local tmux-control--host nil)
    (setq-local tmux-control--socket-name "sk")
    (setq-local tmux-control--session "a")
    (let ((connected '()))
      (cl-letf (((symbol-function 'tmux-control--list-sessions)
                 (lambda (_host _socket) '("a" "b" "c")))
                ;; "a" is already live; "b"/"c" are not.
                ((symbol-function 'tmux-control--session-live-buffer)
                 (lambda (_host session) (equal session "a")))
                ((symbol-function 'tmux-control-connect)
                 (lambda (_host _socket session) (push session connected))))
        (tmux-control--connect-all-sessions)
        (should (equal (sort connected #'string<) '("b" "c")))))))

(ert-deftest tmux-control-test-note-session-activity-flags-offscreen ()
  ;; Output to an off-screen session past its quiet period flags it.
  (with-temp-buffer
    (setq-local tmux-control--session "s")
    (setq-local tmux-control--activity-quiet-until 0)
    (setq-local tmux-control--session-activity nil)
    (let ((tmux-control-session-activity t))
      (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) nil))
                ((symbol-function 'force-mode-line-update) #'ignore))
        (tmux-control--note-session-activity)
        (should tmux-control--session-activity)))))

(ert-deftest tmux-control-test-note-session-activity-visible-and-quiet-noop ()
  ;; A visible session, or one inside its quiet period, is never flagged.
  (let ((tmux-control-session-activity t))
    (with-temp-buffer
      (setq-local tmux-control--activity-quiet-until 0)
      (setq-local tmux-control--session-activity nil)
      (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) 'win))
                ((symbol-function 'force-mode-line-update) #'ignore))
        (tmux-control--note-session-activity)
        (should-not tmux-control--session-activity)))      ; visible → no flag
    (with-temp-buffer
      (setq-local tmux-control--activity-quiet-until (+ (float-time) 100))
      (setq-local tmux-control--session-activity nil)
      (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) nil))
                ((symbol-function 'force-mode-line-update) #'ignore))
        (tmux-control--note-session-activity)
        (should-not tmux-control--session-activity)))))    ; quiet → no flag

(ert-deftest tmux-control-test-session-corner-lists-others-and-clears-self ()
  ;; The corner names other flagged sessions (not unflagged ones, not self),
  ;; and composing the header clears the current session's own flag.
  (let ((self (generate-new-buffer "*tmux-control:local:self*"))
        (other (generate-new-buffer "*tmux-control:local:other*"))
        (quiet (generate-new-buffer "*tmux-control:local:quiet*")))
    (unwind-protect
        (progn
          (with-current-buffer self
            (setq-local tmux-control--session "self")
            (setq-local tmux-control--tiled nil)
            (setq-local tmux-control--process 'live)
            (setq-local tmux-control--session-activity t))
          (with-current-buffer other
            (setq-local tmux-control--session "other")
            (setq-local tmux-control--process 'live)
            (setq-local tmux-control--session-activity t))
          (with-current-buffer quiet
            (setq-local tmux-control--session "quiet")
            (setq-local tmux-control--process 'live)
            (setq-local tmux-control--session-activity nil))
          ;; Exercise the real flagged-buffer scan (process-live-p mocked).
          (cl-letf (((symbol-function 'process-live-p) (lambda (p) (eq p 'live))))
            (with-current-buffer self
              (let* ((tmux-control-session-activity t)
                     (tmux-control-window-tab-bar nil)
                     (corner (tmux-control--corner-render
                              (tmux-control--flagged-other-session-buffers))))
                (should (string-match-p "other" corner))    ; flagged other listed
                (should-not (string-match-p "quiet" corner)) ; unflagged omitted
                (should-not (string-match-p "self" corner))  ; self omitted
                ;; Composing the header clears self's own flag (you see it).
                (tmux-control--header-line)
                (should-not tmux-control--session-activity)))))
      (kill-buffer self) (kill-buffer other) (kill-buffer quiet))))

(ert-deftest tmux-control-test-session-corner-groups-by-server ()
  ;; The corner groups flagged sessions by SERVER: a host is named once and
  ;; only when it differs from the one you are viewing, so sessions on your
  ;; own (current) server show bare names while other hosts are prefixed.
  (let ((a (generate-new-buffer "*tmux-control:hostA:0*"))
        (b (generate-new-buffer "*tmux-control:hostB:0*"))
        (loc (generate-new-buffer "*tmux-control:local:0*"))
        (empty (generate-new-buffer "*tmux-control:emptyhost:le*")))
    (unwind-protect
        (progn
          (with-current-buffer a
            (setq-local tmux-control--session "0")
            (setq-local tmux-control--host "hostA")
            (setq-local tmux-control--process 'live)
            (setq-local tmux-control--session-activity t))
          (with-current-buffer b
            (setq-local tmux-control--session "0")
            (setq-local tmux-control--host "hostB")
            (setq-local tmux-control--process 'live)
            (setq-local tmux-control--session-activity t))
          (with-current-buffer loc
            (setq-local tmux-control--session "0")
            (setq-local tmux-control--host nil)   ; local, same server as viewer
            (setq-local tmux-control--process 'live)
            (setq-local tmux-control--session-activity t))
          (with-current-buffer empty
            (setq-local tmux-control--session "le")
            (setq-local tmux-control--host "")    ; empty host is also local
            (setq-local tmux-control--process 'live)
            (setq-local tmux-control--session-activity t))
          (cl-letf (((symbol-function 'process-live-p) (lambda (p) (eq p 'live))))
            ;; Viewer is a local session, so "local" is the CURRENT server.
            (with-temp-buffer
              (setq-local tmux-control--session "viewer")
              (setq-local tmux-control--host nil)
              (let ((corner (tmux-control--corner-render
                             (tmux-control--flagged-other-session-buffers))))
                ;; Remote servers are named (once), local server is NOT (it's
                ;; the current server -- no redundant prefix).
                (should (string-match-p "hostA" corner))
                (should (string-match-p "hostB" corner))
                (should-not (string-match-p "local" corner))
                ;; Each remote "0" sits under its host label; the local
                ;; siblings ("0" and "le") show bare.
                (should (string-match-p "hostA[^●]*0" corner))
                (should (string-match-p "hostB[^●]*0" corner))
                (should (string-match-p "le" corner))
                (should-not (string-match-p "●:" corner))))))
      (kill-buffer a) (kill-buffer b) (kill-buffer loc) (kill-buffer empty))))

(ert-deftest tmux-control-test-server-label-disambiguates-socket ()
  ;; The default socket reads as just "local"; a non-default socket is
  ;; appended so two local servers don't both collapse to "local".
  (should (equal (tmux-control--server-label nil tmux-control-default-socket-name)
                 "local"))
  (should (equal (tmux-control--server-label "" tmux-control-default-socket-name)
                 "local"))
  (should (equal (tmux-control--server-label nil "scratch") "local/scratch"))
  ;; An empty socket is absent, not a non-default server (no "local/").
  (should (equal (tmux-control--server-label nil "") "local"))
  (should (equal (tmux-control--server-label "aurora" tmux-control-default-socket-name)
                 "aurora"))
  (should (equal (tmux-control--server-label "aurora" "work") "aurora/work")))

(ert-deftest tmux-control-test-corner-collapses-to-count ()
  ;; When the named corner won't fit, it collapses to a bright count.
  (let ((c (tmux-control--corner-collapsed 3)))
    (should (string-match-p "●3" (substring-no-properties c)))
    (should (get-text-property (1- (length c)) 'keymap c))))

(ert-deftest tmux-control-test-session-label-names-host-and-session ()
  ;; The persistent header label names the current connection: HOST:SESSION
  ;; for a remote, local:SESSION for the local server (nil or empty host),
  ;; and it appears in the composed header line.
  (with-temp-buffer
    (setq-local tmux-control--host "aurora")
    (setq-local tmux-control--session "0")
    (let ((tmux-control-session-label t)
          (tmux-control-window-tab-bar nil)
          (tmux-control-session-activity nil))
      (should (string-match-p "aurora:0" (tmux-control--session-label)))
      ;; ...and it actually makes it into the header line.
      (should (string-match-p "aurora:0" (tmux-control--header-line)))))
  ;; Empty-string host is local -> "local:SESSION".
  (with-temp-buffer
    (setq-local tmux-control--host "")
    (setq-local tmux-control--session "work")
    (should (string-match-p "local:work" (tmux-control--session-label))))
  ;; nil host is local too.
  (with-temp-buffer
    (setq-local tmux-control--host nil)
    (setq-local tmux-control--session "0")
    (should (string-match-p "local:0" (tmux-control--session-label))))
  ;; Disabled -> no label in the header line.
  (with-temp-buffer
    (setq-local tmux-control--host "aurora")
    (setq-local tmux-control--session "0")
    (let ((tmux-control-session-label nil)
          (tmux-control-window-tab-bar nil)
          (tmux-control-session-activity nil))
      (should-not (string-match-p "aurora" (tmux-control--header-line))))))

(ert-deftest tmux-control-test-tab-bar-mouse-face-is-per-tab ()
  ;; Header-line mouse highlighting spans the maximal contiguous run of text
  ;; sharing one `eq' mouse-face value, so adjacent tabs must carry distinct
  ;; values -- otherwise hovering one window lights up the whole bar.
  (with-temp-buffer
    (setq-local tmux-control--windows
                '((:index "0" :name "bash" :active t)
                  (:index "1" :name "vim"  :active nil)))
    (let* ((bar (tmux-control--window-tab-bar))
           (mf1 (get-text-property 1 'mouse-face bar))
           (chg (next-single-property-change 1 'mouse-face bar))
           (mf2 (and chg (get-text-property chg 'mouse-face bar))))
      ;; Both tabs carry a mouse-face...
      (should mf1)
      (should mf2)
      ;; ...but not the SAME object, so the highlight stops at the boundary.
      (should-not (eq mf1 mf2)))))

(ert-deftest tmux-control-test-switch-to-flagged-buffer-handles-killed ()
  ;; A corner entry / switcher captures a controller buffer that may be killed
  ;; before the user clicks (server died, manual kill). Switching to it must
  ;; report it, not signal "Selecting deleted buffer".
  (let ((dead (generate-new-buffer "*tmux-control:local:gone*"))
        (msg nil))
    (kill-buffer dead)                     ; now a dead buffer object
    (cl-letf (((symbol-function 'message) (lambda (fmt &rest args)
                                            (setq msg (apply #'format fmt args))))
              ((symbol-function 'pop-to-buffer)
               (lambda (&rest _) (error "should not be reached for a dead buffer"))))
      ;; Must not error, and should tell the user it's gone.
      (tmux-control--switch-to-flagged-buffer dead)
      (should (string-match-p "gone" msg)))))

(ert-deftest tmux-control-test-quiet-activity-targets-controller ()
  ;; The quiet-window deadline is read on the controller (the %output path runs
  ;; there), so it must be WRITTEN on the controller even when a command calls
  ;; --quiet-activity from a per-window render buffer -- otherwise the burst it
  ;; suppresses would spuriously flag windows.
  (let ((ctrl (generate-new-buffer "*tmux-control:local:ctrl*"))
        (render (generate-new-buffer "*tmux-control:local:render*")))
    (unwind-protect
        (progn
          (with-current-buffer ctrl (setq-local tmux-control--activity-quiet-until 0))
          (with-current-buffer render
            (setq-local tmux-control--controller ctrl)
            (setq-local tmux-control--activity-quiet-until 0)
            (tmux-control--quiet-activity 5))
          ;; Deadline landed on the controller, not the render buffer.
          (should (> (buffer-local-value 'tmux-control--activity-quiet-until ctrl) 0))
          (should (= (buffer-local-value 'tmux-control--activity-quiet-until render) 0))
          ;; A stale (killed) controller must not signal "Selecting deleted
          ;; buffer" -- guard liveness and no-op.
          (with-current-buffer render
            (let ((dead (generate-new-buffer "*tmux-control:local:dead*")))
              (kill-buffer dead)
              (setq-local tmux-control--controller dead)
              (tmux-control--quiet-activity 5))))   ; must not error
      (kill-buffer ctrl) (kill-buffer render))))

(ert-deftest tmux-control-test-window-jump-keys-bound ()
  ;; The window-jump keys are bound in BOTH the override map (high precedence,
  ;; over Eat) and the major-mode map, and `l' really exits scrollback.
  (dolist (map (list tmux-control--override-map tmux-control-mode-map))
    (should (eq (lookup-key map (kbd "C-c C-w")) 'tmux-control-select-window))
    (should (eq (lookup-key map (kbd "C-c TAB")) 'tmux-control-last-window))
    (should (eq (lookup-key map (kbd "C-c x")) 'tmux-control-kill-pane))
    (should (eq (lookup-key map (kbd "C-c 0")) 'tmux-control-select-window-by-key))
    (should (eq (lookup-key map (kbd "C-c 7")) 'tmux-control-select-window-by-key)))
  (should (eq (lookup-key tmux-control-scrollback-mode-map (kbd "l"))
              'tmux-control-live)))

(ert-deftest tmux-control-test-select-window-by-key-uses-digit ()
  ;; The digit that invoked the command is the window index it switches to.
  (let (got)
    (cl-letf (((symbol-function 'tmux-control-select-window)
               (lambda (idx) (setq got idx))))
      (let ((last-command-event ?5)) (tmux-control-select-window-by-key))
      (should (equal got "5"))
      (let ((last-command-event ?0)) (tmux-control-select-window-by-key))
      (should (equal got "0")))))

(ert-deftest tmux-control-test-selection-function-gated ()
  ;; SECURITY: pane-driven OSC 52 clipboard manipulation is ignored unless the
  ;; user opts in, so untrusted pane output cannot poison/read the kill-ring.
  (let ((tmux-control-allow-clipboard-write nil))
    (should (eq (tmux-control--selection-function) #'ignore)))
  (when (fboundp 'eat--manipulate-kill-ring)
    (let ((tmux-control-allow-clipboard-write t))
      (should (eq (tmux-control--selection-function) #'eat--manipulate-kill-ring)))))

(ert-deftest tmux-control-test-mode-line-safe-doubles-percent ()
  (should (equal (tmux-control--mode-line-safe "a%b") "a%%b"))
  (should (equal (tmux-control--mode-line-safe "%999m") "%%999m"))
  (should (null (tmux-control--mode-line-safe nil))))

(ert-deftest tmux-control-test-window-tab-bar-escapes-percent ()
  ;; SECURITY: a window name (attacker-influenced) reaches the header line, an
  ;; :eval result whose %-constructs the mode-line engine expands. A name like
  ;; "%b%f" must be doubled to "%%b%%f" so the engine shows it literally rather
  ;; than leaking the buffer name / visited file.
  ;; (format-mode-line returns "" in batch, so assert on the produced string.)
  (with-temp-buffer
    (setq-local tmux-control--windows '((:index "0" :name "%b%f" :active t)))
    (let* ((tmux-control--tiled nil)
           (raw (substring-no-properties (tmux-control--window-tab-bar))))
      (should (string-match-p "%%b%%f" raw))
      ;; no lone "%b" / "%f" that the engine would expand
      (should-not (string-match-p "[^%]%[bf]" raw)))))

(ert-deftest tmux-control-test-pane-mode-line-escapes-percent ()
  ;; SECURITY: the pane id, command, and (app-settable, via OSC 2) title all
  ;; reach the mode line; each "%" must be doubled -- a field width like %999m
  ;; would otherwise pad to a huge string (a DoS at %999999999m).
  (with-temp-buffer
    (setq-local tmux-control--active-pane "%3")
    (setq-local tmux-control--pane-info '(:cmd "x%n" :title "%999m"))
    (let ((raw (substring-no-properties (tmux-control--pane-mode-line))))
      (should (string-match-p "%%3" raw))
      (should (string-match-p "x%%n" raw))
      (should (string-match-p "%%999m" raw)))))

(ert-deftest tmux-control-test-flock-other-frame-ordering ()
  ;; flock-other-frame: with a prefix it connects all first, then focuses the
  ;; dedicated frame and flocks; without a prefix it skips connect-all.
  (let ((calls '()))
    (cl-letf (((symbol-function 'tmux-control--connect-all-sessions)
               (lambda () (push 'connect-all calls)))
              ((symbol-function 'tmux-control--sessions-frame)
               (lambda () (push 'frame calls) 'dummy-frame))
              ((symbol-function 'select-frame-set-input-focus)
               (lambda (_f) (push 'focus calls)))
              ((symbol-function 'tmux-control-flock)
               (lambda (&rest _) (push 'flock calls))))
      (tmux-control-flock-other-frame t)
      (should (equal (nreverse calls) '(connect-all frame focus flock)))
      (setq calls '())
      (tmux-control-flock-other-frame nil)
      (should (equal (nreverse calls) '(frame focus flock))))))

(ert-deftest tmux-control-test-inline-preview-commit ()
  ;; The inline window preview previews the highlighted candidate (switching
  ;; the live view) and, on selection, commits it.
  (let ((switched '())
        (choices (list (cons (propertize "0: a (active)" 'tmux-window-active t) "0")
                       (cons "1: b" "1")
                       (cons "2: c" "2"))))
    (cl-letf (((symbol-function 'tmux-control--window-choices) (lambda () choices))
              ((symbol-function 'tmux-control--do-select-window)
               (lambda (idx) (push idx switched)))
              ((symbol-function 'consult--read)
               (lambda (_cands &rest opts)
                 (funcall (plist-get opts :state) 'preview "2: c") ; navigate-preview
                 "2: c")))                                          ; select-commit
      (tmux-control--select-window-inline)
      ;; previewed window 2, then committed window 2
      (should (equal (nreverse switched) '("2" "2"))))))

(ert-deftest tmux-control-test-inline-preview-cancel-restores ()
  ;; Cancelling (a `quit') restores the window we started on, even though a
  ;; different one was previewed -- via the `unwind-protect'.
  (let ((switched '())
        (choices (list (cons (propertize "0: a (active)" 'tmux-window-active t) "0")
                       (cons "1: b" "1")
                       (cons "2: c" "2"))))
    (cl-letf (((symbol-function 'tmux-control--window-choices) (lambda () choices))
              ((symbol-function 'tmux-control--do-select-window)
               (lambda (idx) (push idx switched)))
              ((symbol-function 'consult--read)
               (lambda (_cands &rest opts)
                 (funcall (plist-get opts :state) 'preview "1: b") ; preview window 1
                 (signal 'quit nil))))                             ; cancel
      (ignore-error quit (tmux-control--select-window-inline))
      ;; previewed window 1, then restored the original active window 0
      (should (equal (nreverse switched) '("1" "0"))))))

(ert-deftest tmux-control-test-read-with-preview-cancel-calls-restore ()
  ;; The shared preview reader previews the navigated candidate and, on a
  ;; `quit', invokes RESTORE (and does not return a value).
  (let ((previewed nil) (restored nil))
    (cl-letf (((symbol-function 'consult--read)
               (lambda (_cands &rest opts)
                 (funcall (plist-get opts :state) 'preview "x")
                 (signal 'quit nil))))
      (ignore-error quit
        (tmux-control--read-with-preview
         "P: " '(("x" . 1) ("y" . 2))
         (lambda (v) (setq previewed v))
         (lambda () (setq restored t))))
      (should (eq previewed 1))
      (should restored))))

(ert-deftest tmux-control-test-session-inline-previews-connected-commits ()
  ;; Session preview shows an already-connected session in place (not an
  ;; unconnected one) and commits the chosen session via --connect-or-switch.
  (let ((bbuf (generate-new-buffer " tc-test-b"))
        (previewed '()) (committed nil))
    (unwind-protect
        (cl-letf (((symbol-function 'tmux-control--session-live-buffer)
                   (lambda (_host s) (when (equal s "b") bbuf))) ; only "b" connected
                  ((symbol-function 'set-window-buffer)
                   (lambda (_w buf) (push buf previewed)))
                  ((symbol-function 'tmux-control--connect-or-switch)
                   (lambda (_h _s session) (setq committed session)))
                  ((symbol-function 'consult--read)
                   (lambda (_cands &rest opts)
                     (funcall (plist-get opts :state) 'preview "a (current)") ; unconnected → skip
                     (funcall (plist-get opts :state) 'preview "b")           ; connected → preview
                     "b")))
          (tmux-control--select-session-inline nil "sock" '("a" "b" "c") "a")
          (should (memq bbuf previewed))        ; previewed b's buffer
          (should-not (memq nil previewed))     ; unconnected "a" did not preview
          (should (equal committed "b")))       ; committed b
      (kill-buffer bbuf))))

(ert-deftest tmux-control-test-untile-resolves-pane-in-band ()
  ;; Untile must re-resolve the active pane and seed over the live control
  ;; connection (in-band, async) -- NOT via a blocking out-of-band ssh
  ;; display-message, which freezes Emacs for a full SSH round trip on remote.
  (let ((queries '()) (seeded 0) (ran-tmux nil))
    (cl-letf (((symbol-function 'tmux-control--teardown-tiling) #'ignore)
              ((symbol-function 'tmux-control--write-terminal) #'ignore)
              ((symbol-function 'tmux-control--resize-to-window) #'ignore)
              ((symbol-function 'tmux-control--run-tmux)
               (lambda (_args) (setq ran-tmux t) ""))
              ((symbol-function 'tmux-control--query)
               (lambda (cmd cb) (push cmd queries) (funcall cb '("%7"))))
              ((symbol-function 'tmux-control--seed-screen)
               (lambda () (cl-incf seeded))))
      (with-temp-buffer
        (setq-local tmux-control--tiled t
                    tmux-control--controller nil
                    tmux-control--active-pane "%0"
                    tmux-control-window-tab-bar nil)
        (tmux-control-untile)
        (should-not ran-tmux)                ; no blocking out-of-band ssh
        (should (cl-some (lambda (q) (string-match-p "pane_id" q)) queries))
        (should (equal tmux-control--active-pane "%7")) ; reply applied
        (should (= seeded 1))))))            ; seeded in the callback

;;; Tiling preserves a foreign (non-tmux) window sharing the frame.

(ert-deftest tmux-control-test-our-tiling-window-p ()
  "`tmux-control--our-tiling-window-p' recognizes the controller window and a
tagged pane window as ours, and a foreign window as not ours."
  (let ((ctrl-buf (generate-new-buffer " tc-test-ctrl"))
        (foreign-buf (generate-new-buffer " tc-test-foreign")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let* ((cw (selected-window))
                 (ow (split-window cw nil 'right)))
            (set-window-buffer cw ctrl-buf)
            (set-window-buffer ow foreign-buf)
            (should (tmux-control--our-tiling-window-p cw ctrl-buf))      ; controller
            (should-not (tmux-control--our-tiling-window-p ow ctrl-buf))  ; foreign
            (set-window-parameter ow 'tmux-control-pane "%3")
            (should (tmux-control--our-tiling-window-p ow ctrl-buf))))    ; tagged pane
      (kill-buffer ctrl-buf)
      (kill-buffer foreign-buf))))

(ert-deftest tmux-control-test-collapse-preserves-foreign-window ()
  "`tmux-control--collapse-tile-windows' removes the tiling's own windows but
leaves a foreign window sharing the frame untouched -- the regression behind
\"switching tmux windows clobbers my other buffer\"."
  (let ((ctrl-buf (generate-new-buffer " tc-test-ctrl"))
        (foreign-buf (generate-new-buffer " tc-test-foreign")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let* ((root (selected-window))
                 (foreign-win (split-window root nil 'right)))
            (set-window-buffer root ctrl-buf)
            (set-window-buffer foreign-win foreign-buf)
            (let ((pane2 (split-window root nil 'below)))
              (set-window-parameter root 'tmux-control-pane "%1")
              (set-window-parameter pane2 'tmux-control-pane "%2")
              (tmux-control--collapse-tile-windows root)
              (should (window-live-p foreign-win))                  ; foreign survives
              (should (eq (window-buffer foreign-win) foreign-buf)) ; still its buffer
              (should-not (window-live-p pane2))                    ; sibling pane collapsed
              (should (window-live-p root))                         ; keeper survives
              (should-not (window-parameter root 'tmux-control-pane))))) ; marker cleared
      (kill-buffer ctrl-buf)
      (kill-buffer foreign-buf))))

(ert-deftest tmux-control-test-tiled-region-size-subtracts-foreign ()
  "`tmux-control--tiled-region-size' owns the full width with a positive row
budget when no foreign window shares the frame, and a full-height foreign
window steals columns while leaving the rows untouched (a side split).  The
exact row count is a pixel measurement (inner height less the minibuffer and
the real mode-line height, so it matches the window body and the bottom pane
does not clip) and so is verified live, not pinned here; this locks the
foreign-subtraction logic, which is display-independent."
  (let ((ctrl-buf (generate-new-buffer " tc-test-ctrl"))
        (foreign-buf (generate-new-buffer " tc-test-foreign")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let* ((frame (selected-frame))
                 (cw (selected-window)))
            (set-window-buffer cw ctrl-buf)
            (let ((whole (tmux-control--tiled-region-size frame ctrl-buf)))
              (should (= (car whole) (frame-text-cols frame)))  ; full width
              (should (> (cdr whole) 0))                        ; a real row budget
              (let ((fw (split-window cw nil 'right)))
                (set-window-buffer fw foreign-buf)
                (let ((reduced (tmux-control--tiled-region-size frame ctrl-buf)))
                  (should (< (car reduced) (car whole)))     ; foreign steals columns
                  (should (= (cdr reduced) (cdr whole))))))))  ; rows unchanged (side split)
      (kill-buffer ctrl-buf)
      (kill-buffer foreign-buf))))

;;; Pane-directory-aware file commands.

(ert-deftest tmux-control-test-remote-file-method-honors-config ()
  "`tmux-control--remote-file-method' uses the user's configured TRAMP method
\(e.g. tramp-rpc's \"rpc\"), not a hardcoded one, and ignores a user@ prefix."
  (require 'tramp)
  (let ((tramp-default-method-alist nil))
    (let ((tramp-default-method "rpc"))
      (should (equal (tmux-control--remote-file-method "somehost") "rpc"))
      (should (equal (tmux-control--remote-file-method "me@somehost") "rpc")))
    (let ((tramp-default-method "sshx"))
      (should (equal (tmux-control--remote-file-method "somehost") "sshx")))))

(ert-deftest tmux-control-test-pane-directory-wraps-remote ()
  "`tmux-control--pane-directory' returns the pane's cwd as a directory --
plain for a local session, wrapped with the user's TRAMP method for a remote
host -- and nil when the path cannot be read."
  (cl-letf (((symbol-function 'derived-mode-p) (lambda (&rest _) t))
            ;; Pin the resolved method so the test does not depend on the
            ;; ambient `tramp-default-method'.
            ((symbol-function 'tmux-control--remote-file-method)
             (lambda (_) "rpc")))
    (let ((tmux-control--active-pane "%0")
          (tmux-control--socket-name "s"))
      (cl-letf (((symbol-function 'tmux-control--run-tmux)
                 (lambda (_) "/home/u/proj")))
        (let ((tmux-control--host nil))
          (should (equal (tmux-control--pane-directory) "/home/u/proj/")))
        (let ((tmux-control--host ""))
          (should (equal (tmux-control--pane-directory) "/home/u/proj/")))
        (let ((tmux-control--host "dev"))
          (should (equal (tmux-control--pane-directory)
                         "/rpc:dev:/home/u/proj/"))))
      ;; An empty/failed query yields nil, so callers fall back to local.
      (cl-letf (((symbol-function 'tmux-control--run-tmux) (lambda (_) "")))
        (let ((tmux-control--host "dev"))
          (should-not (tmux-control--pane-directory)))))))

(ert-deftest tmux-control-test-call-in-pane-directory ()
  "`tmux-control--call-in-pane-directory' roots at the pane dir, but uses the
buffer's own directory with a prefix arg or when the option is off."
  (let ((seen nil))
    (cl-letf (((symbol-function 'tmux-control--pane-directory)
               (lambda () "/ssh:host:/proj/"))
              ((symbol-function 'tmux-control-test--record-dir)
               (lambda () (interactive) (setq seen default-directory))))
      (let ((default-directory "/local/")
            (tmux-control-pane-aware-find-file t))
        (tmux-control--call-in-pane-directory 'tmux-control-test--record-dir nil)
        (should (equal seen "/ssh:host:/proj/"))           ; no prefix -> pane dir
        (tmux-control--call-in-pane-directory 'tmux-control-test--record-dir t)
        (should (equal seen "/local/"))                    ; prefix -> local
        (let ((tmux-control-pane-aware-find-file nil))
          (tmux-control--call-in-pane-directory 'tmux-control-test--record-dir nil)
          (should (equal seen "/local/")))))))             ; option off -> local

;;; In-band command replies: id-matched block termination, closure queries.

(defmacro tmux-control-test--with-reply-buffer (&rest body)
  "Run BODY in a temp buffer with clean command-reply state."
  `(with-temp-buffer
     (setq-local tmux-control--command-queue nil
                 tmux-control--current-command-kind :ignore
                 tmux-control--collecting-command nil
                 tmux-control--command-output nil
                 tmux-control--command-block-number nil
                 tmux-control--output-batch nil)
     ,@body))

(ert-deftest tmux-control-test-block-end-requires-matching-number ()
  ;; A captured pane can CONTAIN lines that look like protocol -- someone
  ;; viewing a control-mode transcript -- so %end/%error close the block
  ;; only when their command number matches the %begin's, and a %begin
  ;; inside a block is content, not a new block.
  (tmux-control-test--with-reply-buffer
   (let (got)
     (setq tmux-control--command-queue
           (list (cons (lambda (lines) (setq got lines)) (float-time))))
     (tmux-control--handle-line "%begin 1717 42 1")
     (should tmux-control--collecting-command)
     (tmux-control--handle-line "real content")
     (tmux-control--handle-line "%end 999 7 0")      ; wrong number: content
     (tmux-control--handle-line "%begin 5 5 0")      ; inside block: content
     (tmux-control--handle-line "%error 999 7 0")    ; wrong number: content
     (should tmux-control--collecting-command)
     (tmux-control--handle-line "%end 1718 42 1")    ; same number, later time
     (should-not tmux-control--collecting-command)
     (should (equal got '("real content"
                          "%end 999 7 0"
                          "%begin 5 5 0"
                          "%error 999 7 0"))))))

(ert-deftest tmux-control-test-query-callback-gets-nil-on-error ()
  ;; %error completes a closure query with nil so an async consumer can
  ;; show the failure instead of waiting forever.
  (tmux-control-test--with-reply-buffer
   (let ((called :not-called))
     (setq tmux-control--command-queue
           (list (cons (lambda (lines) (setq called lines)) (float-time))))
     (tmux-control--handle-line "%begin 1 9 0")
     (tmux-control--handle-line "some diagnostics")
     (tmux-control--handle-line "%error 2 9 0")
     (should (null called))
     (should-not tmux-control--collecting-command))))

(ert-deftest tmux-control-test-block-collects-notification-shaped-content ()
  ;; Lines that look like %exit/%pause/%continue but arrive INSIDE a reply
  ;; block are captured pane content (a control-mode transcript), not
  ;; protocol: collect them verbatim and fire no side effects -- a stray
  ;; %pause must not reseed/enqueue a continue, a stray %exit must not print
  ;; a false "session ended".
  (tmux-control-test--with-reply-buffer
   (let (got (paused nil))
     (cl-letf (((symbol-function 'tmux-control--handle-pause)
                (lambda (pane) (setq paused pane))))
       (setq tmux-control--command-queue
             (list (cons (lambda (lines) (setq got lines)) (float-time))))
       (tmux-control--handle-line "%begin 1 7 0")
       (tmux-control--handle-line "%pause %0")
       (tmux-control--handle-line "%exit")
       (tmux-control--handle-line "%continue %0")
       (should tmux-control--collecting-command)
       (tmux-control--handle-line "%end 2 7 0")
       (should-not tmux-control--collecting-command)
       (should (null paused))
       (should (equal got '("%pause %0" "%exit" "%continue %0")))))))

(ert-deftest tmux-control-test-scrollback-capture-command ()
  ;; The DEFAULT is raw rows, no -J: tmux re-wraps pane history to the
  ;; pane's current width, so an unjoined capture always fits the window,
  ;; while joining resurrects rows at the width they were painted before a
  ;; resize (field report: wide window -> half screen -> scrollback showed
  ;; pre-resize rows Emacs-wrapped into fragments and phantom blanks).
  (should-not (default-value 'tmux-control-scrollback-join-wrapped-lines))
  (let ((tmux-control-scrollback-join-wrapped-lines nil))
    (should (equal (tmux-control--scrollback-capture-command "%5" 10000 nil)
                   "capture-pane -p -e -S -10000 -t %5"))
    (should (equal (tmux-control--scrollback-capture-command nil 200 t)
                   "capture-pane -p -e -N -S -200"))
    ;; END-BACK caps the end so a lazy-extend delta covers only the lines
    ;; strictly older than what is already loaded: from -NEW-DEPTH back up
    ;; to (but not including) the previous top at -(OLD-DEPTH+1).
    (should (equal (tmux-control--scrollback-capture-command "%5" 2500 nil 501)
                   "capture-pane -p -e -S -2500 -E -501 -t %5")))
  (let ((tmux-control-scrollback-join-wrapped-lines t))
    (should (equal (tmux-control--scrollback-capture-command "%1" 50 nil)
                   "capture-pane -p -e -J -S -50 -t %1"))))

(ert-deftest tmux-control-test-scrollback-request-uses-in-band-query ()
  ;; With a live connection the scrollback capture rides the control
  ;; connection as a query; the callback fills the buffer through the
  ;; compaction pipeline.
  (tmux-control-test--with-reply-buffer
   (let* ((tmux-control-scrollback-join-wrapped-lines nil)
          (live (current-buffer))
          (sent nil)
          (sb (generate-new-buffer " *tc-sb-test*")))
     (unwind-protect
         (progn
           (setq-local tmux-control--process 'fake-proc)
           (with-current-buffer sb
             (setq-local tmux-control--live-buffer live))
           (cl-letf (((symbol-function 'process-live-p) (lambda (p) (eq p 'fake-proc)))
                     ((symbol-function 'tmux-control--query)
                      (lambda (command callback) (setq sent (cons command callback)))))
             (with-current-buffer sb
               (tmux-control--scrollback-request sb "%3" 500 nil)))
           (should (equal (car sent) "capture-pane -p -e -S -500 -t %3"))
           ;; Deliver the reply; the buffer fills and follows the bottom.
           (funcall (cdr sent) '("line one" "line two"))
           (with-current-buffer sb
             (should (string-match-p "line one\nline two"
                                     (buffer-substring-no-properties
                                      (point-min) (point-max))))
             (should (eobp))))
       (kill-buffer sb)))))
;;; Command-queue watchdog.

(defmacro tmux-control-test--with-watchdog-buffer (&rest body)
  "Run BODY in a temp buffer with watchdog state and a live mock process."
  `(with-temp-buffer
     (setq-local tmux-control--command-queue nil
                 tmux-control--command-watchdog-timer nil
                 tmux-control--command-watchdog-warned nil
                 tmux-control--current-command-kind :ignore
                 tmux-control--collecting-command nil
                 tmux-control--command-output nil
                 tmux-control--output-batch nil
                 tmux-control--process nil)
     (cl-letf (((symbol-function 'process-live-p) (lambda (_) t)))
       (unwind-protect
           (progn ,@body)
         (when tmux-control--command-watchdog-timer
           (cancel-timer tmux-control--command-watchdog-timer))))))

(ert-deftest tmux-control-test-command-watchdog-warns-once-when-stuck ()
  ;; An overdue head entry produces exactly one warning per stuck episode,
  ;; leaves the queue untouched (replies pair strictly in order), and keeps
  ;; the watchdog armed so recovery or drain is still noticed.
  (tmux-control-test--with-watchdog-buffer
   (let ((tmux-control-command-timeout 10))
     (setq tmux-control--command-queue
           (list (cons :capture (- (float-time) 60))))
     (tmux-control--command-watchdog-check (current-buffer))
     (should tmux-control--command-watchdog-warned)
     (should (string-match-p "connection may be stuck" (buffer-string)))
     (should (= 1 (length tmux-control--command-queue)))
     (should tmux-control--command-watchdog-timer)
     (cancel-timer tmux-control--command-watchdog-timer)
     (setq tmux-control--command-watchdog-timer nil)
     ;; Still stuck at the next check: no second warning.
     (tmux-control--command-watchdog-check (current-buffer))
     (should (= 1 (cl-count-if
                   (lambda (line)
                     (string-match-p "connection may be stuck" line))
                   (split-string (buffer-string) "\n")))))))

(ert-deftest tmux-control-test-command-watchdog-rearms-for-fresh-head ()
  ;; A head entry younger than the timeout neither warns nor pops; the
  ;; check just re-arms for the remaining wait.
  (tmux-control-test--with-watchdog-buffer
   (let ((tmux-control-command-timeout 10))
     (setq tmux-control--command-queue
           (list (cons :ignore (- (float-time) 2))))
     (tmux-control--command-watchdog-check (current-buffer))
     (should-not tmux-control--command-watchdog-warned)
     (should-not (string-match-p "stuck" (buffer-string)))
     (should tmux-control--command-watchdog-timer))))

(ert-deftest tmux-control-test-command-watchdog-clears-on-drain ()
  ;; A drained queue ends the episode: the flag resets and the watchdog
  ;; does not re-arm.
  (tmux-control-test--with-watchdog-buffer
   (let ((tmux-control-command-timeout 10))
     (setq tmux-control--command-watchdog-warned t)
     (tmux-control--command-watchdog-check (current-buffer))
     (should-not tmux-control--command-watchdog-warned)
     (should-not tmux-control--command-watchdog-timer))))

(ert-deftest tmux-control-test-begin-reply-pairs-kind-and-recovers ()
  ;; A %begin reply takes its kind from the queue entry cons and, after a
  ;; warned episode, announces recovery and clears the flag.
  (tmux-control-test--with-watchdog-buffer
   (setq tmux-control--command-queue
         (list (cons :capture (float-time))))
   (setq tmux-control--command-watchdog-warned t)
   (tmux-control--handle-line "%begin 1717171717 42 1")
   (should (eq tmux-control--current-command-kind :capture))
   (should-not tmux-control--command-queue)
   (should-not tmux-control--command-watchdog-warned)
   (should (string-match-p "recovered" (buffer-string)))))
;;; Process-filter fuzz: chunking invariance.
;;
;; The filter may receive the control-mode stream torn at ANY character
;; boundary -- mid-line, mid-octal-escape, between the bytes of an escaped
;; multibyte character (a real bug once: a box-drawing char split across two
;; %output messages rendered as raw octal).  Feeding one fixed transcript in
;; many different chunkings must produce byte-identical terminal output and
;; identical client state, with no errors.

(defconst tmux-control-test--fuzz-transcript
  (concat
   "%begin 1 1 0\n"
   "%0\n"
   "%end 1 1 0\n"
   "%output %0 plain hello\n"
   ;; Control bytes arrive octal-escaped on the wire (decoded by
   ;; `tmux-control--decode-output').
   "%output %0 color \\033[31mRED\\033[0m ok\n"
   ;; Intact multibyte arrives as real characters: the wire carries raw
   ;; UTF-8 and the process coding already decoded it.
   "%output %0 box ┌─┐ done\n"
   ;; A multibyte char SPLIT across two %output messages: each half is
   ;; invalid UTF-8 on its own, so process decoding leaves raw eight-bit
   ;; chars for `tmux-control--utf8-decode-stream' to reassemble (a real
   ;; bug once: the halves rendered as octal).
   (format "%%output %%0 split-pair %s\n"
           (decode-coding-string "\342\224" 'utf-8))
   (format "%%output %%0 %s joined\n"
           (decode-coding-string "\200" 'utf-8))
   ;; A CR-terminated line: the filter must strip the trailing \r.
   "%output %0 cr-line\r\n"
   ;; Output for a non-active pane is dropped in single-pane mode.
   "%output %1 other-pane-dropped\n"
   "%window-pane-changed @1 %1\n"
   "%output %1 now-active\n"
   "%output %0 dropped-now\n"
   "%layout-change @1 c5d2,80x24,0,0,1\n"
   "%session-window-changed $1 @2\n"
   "%window-add @3\n"
   "%window-renamed @3 build\n"
   "%unknown-notification future tmux says hi\n"
   "%pause %1\n"
   "%continue %1\n"
   "%begin 2 2 0\n"
   "reply line one\n"
   "%output %0 not-output-while-collecting\n"
   "%end 2 2 0\n"
   "%exit\n")
  "A control-mode session transcript exercising every hot filter path.
Models the stream as the filter sees it: after the process coding system
has decoded the wire, so intact UTF-8 is characters, a multibyte char
tmux split across messages is raw eight-bit chars, and control bytes are
octal text.")

(defun tmux-control-test--lcg-chunks (string seed)
  "Split STRING into chunks of pseudo-random length 1..9, driven by SEED.
A tiny linear congruential generator keeps the chunking deterministic
across Emacs versions, unlike a seeded `random'."
  (let ((s seed) (chunks '()) (i 0) (n (length string)))
    (while (< i n)
      (setq s (mod (+ (* 1103515245 s) 12345) 2147483648))
      (let ((len (min (- n i) (1+ (mod s 9)))))
        (push (substring string i (+ i len)) chunks)
        (setq i (+ i len))))
    (nreverse chunks)))

(defun tmux-control-test--run-filter-chunked (chunks)
  "Feed CHUNKS through the real filter against stubbed side effects.
Returns a plist of observable state: :fed (concatenated terminal
output), :calls (side-effect invocations in order), :active-pane,
:accumulator, and :messages (the buffer text)."
  (with-temp-buffer
    (let ((proc (make-pipe-process :name "tc-fuzz" :buffer (current-buffer)
                                   :noquery t))
          ;; The invariance property targets the base filter; the per-window
          ;; buffer layer on top has its own tests.
          (tmux-control-window-buffers nil)
          (fed '())
          (calls '()))
      (unwind-protect
          (progn
            (setq-local tmux-control--accumulator ""
                        tmux-control--output-batch nil
                        tmux-control--utf8-carry ""
                        tmux-control--collecting-command nil
                        tmux-control--current-command-kind :ignore
                        tmux-control--command-queue nil
                        tmux-control--command-output nil
                        tmux-control--active-pane nil
                        tmux-control--tiled nil
                        tmux-control--retile-pending nil
                        tmux-control--panes nil
                        tmux-control--self-reseed-pending 0
                        tmux-control--self-reseed-until 0
                        ;; A stand-in terminal: `--feed-terminal' runs for
                        ;; real (UTF-8 carry included); only the Eat API
                        ;; calls below it are stubbed.
                        tmux-control--terminal 'tc-fuzz-term
                        tmux-control--display-dirty nil)
            (cl-letf (((symbol-function 'eat-term-live-p)
                       (lambda (_) t))
                      ((symbol-function 'eat-term-process-output)
                       (lambda (_term s) (push s fed)))
                      ((symbol-function 'tmux-control--seed-screen)
                       (lambda () (push 'seed calls)))
                      ((symbol-function 'tmux-control--refresh-alt-screen-option)
                       (lambda () (push 'alt calls)))
                      ((symbol-function 'tmux-control--refresh-pane-size)
                       (lambda () (push 'size calls)))
                      ((symbol-function 'tmux-control--refresh-windows)
                       (lambda () (push 'windows calls)))
                      ((symbol-function 'tmux-control--refresh-pane-window-map)
                       (lambda () (push 'pane-map calls)))
                      ((symbol-function 'tmux-control--refresh-active-pane)
                       (lambda (&rest _) (push 'active calls)))
                      ((symbol-function 'tmux-control--handle-pause)
                       (lambda (pane) (push (cons 'pause pane) calls)))
                      ((symbol-function 'tmux-control--note-pane-activity)
                       (lambda (_) nil))
                      ((symbol-function 'tmux-control--note-session-activity)
                       (lambda () nil))
                      ((symbol-function 'tmux-control--current-sync-windows)
                       (lambda () nil))
                      ((symbol-function 'tmux-control--flush-display)
                       (lambda (&rest _) nil)))
              (dolist (chunk chunks)
                (tmux-control--filter proc chunk)))
            (list :fed (apply #'concat (nreverse fed))
                  :calls (nreverse calls)
                  :active-pane tmux-control--active-pane
                  :accumulator tmux-control--accumulator
                  :messages (buffer-substring-no-properties
                             (point-min) (point-max))))
        (delete-process proc)))))

(ert-deftest tmux-control-test-filter-fuzz-chunking-invariance ()
  ;; The same transcript, torn at arbitrary character boundaries by 12
  ;; deterministic chunkings (plus a line-by-line feed), must yield exactly
  ;; the state of feeding it whole.
  (let ((reference (tmux-control-test--run-filter-chunked
                    (list tmux-control-test--fuzz-transcript))))
    ;; Sanity: the reference itself decoded the escapes, reassembled the
    ;; split multibyte char, stripped the CR, and routed panes.
    (should (string-match-p "box ┌─┐ done" (plist-get reference :fed)))
    (should (string-match-p "split-pair ─ joined" (plist-get reference :fed)))
    (should (string-match-p "cr-line" (plist-get reference :fed)))
    (should-not (string-match-p "cr-line\r" (plist-get reference :fed)))
    (should (string-match-p "now-active" (plist-get reference :fed)))
    (should-not (string-match-p "dropped" (plist-get reference :fed)))
    (should-not (string-match-p "not-output-while-collecting"
                                (plist-get reference :fed)))
    (should (equal (plist-get reference :accumulator) ""))
    (dolist (chunks (append
                     ;; Line-by-line, and one character at a time -- the
                     ;; latter exercises every possible tear point.
                     (list (mapcar (lambda (l) (concat l "\n"))
                                   (split-string
                                    tmux-control-test--fuzz-transcript "\n" t))
                           (mapcar #'string
                                   (string-to-list
                                    tmux-control-test--fuzz-transcript)))
                     (mapcar (lambda (seed)
                               (tmux-control-test--lcg-chunks
                                tmux-control-test--fuzz-transcript seed))
                             (number-sequence 1 12))))
      (should (equal (tmux-control-test--run-filter-chunked chunks)
                     reference)))))

;;; Per-window render buffers.

(ert-deftest tmux-control-test-window-buffer-registry ()
  ;; Register/lookup round-trips; killing a render buffer deregisters it.
  (with-temp-buffer
    (let ((ctrl (current-buffer))
          (buf (generate-new-buffer " *tc-wb-test*")))
      (with-current-buffer buf
        (setq-local tmux-control--window-id "@7"
                    tmux-control--controller ctrl)
        (add-hook 'kill-buffer-hook #'tmux-control--window-buffer-killed nil t))
      (tmux-control--register-window-buffer "@7" buf)
      (should (eq (tmux-control--window-buffer "@7") buf))
      (should-not (tmux-control--window-buffer "@9"))
      (kill-buffer buf)
      (should-not (tmux-control--window-buffer "@7"))
      (should-not (assoc "@7" tmux-control--window-buffers)))))

(ert-deftest tmux-control-test-update-windows-claims-controller-window ()
  ;; The first window list binds the controller buffer to its own window id
  ;; and registers it as that window's render buffer.
  (with-temp-buffer
    (let ((tmux-control-window-buffers t))
      (tmux-control--update-windows
       '("0\tcode\t1\t0\t@5" "1\tbuild\t0\t0\t@6"))
      (should (equal tmux-control--current-window "0"))
      (should (equal tmux-control--window-id "@5"))
      (should (eq (tmux-control--window-buffer "@5") (current-buffer)))
      (should (equal (tmux-control--window-id-for-index "1") "@6")))))

(ert-deftest tmux-control-test-batch-pane-output-routes-to-window-buffer ()
  ;; Output for a pane whose window has a render buffer accumulates in THAT
  ;; buffer; panes without one keep the controller's active-pane behavior.
  (with-temp-buffer
    (let ((tmux-control-window-buffers t)
          (ctrl (current-buffer))
          (buf (generate-new-buffer " *tc-wb-route*")))
      (unwind-protect
          (progn
            (setq-local tmux-control--tiled nil
                        tmux-control--active-pane "%0"
                        tmux-control--output-batch nil
                        tmux-control--pane-window (make-hash-table :test 'equal))
            (puthash "%0" (cons "0" "@5") tmux-control--pane-window)
            (puthash "%1" (cons "1" "@6") tmux-control--pane-window)
            (with-current-buffer buf
              (setq-local tmux-control--active-pane "%1"
                          tmux-control--output-batch nil))
            (tmux-control--register-window-buffer "@6" buf)
            (cl-letf (((symbol-function 'tmux-control--note-pane-activity)
                       #'ignore)
                      ((symbol-function 'tmux-control--note-session-activity)
                       #'ignore))
              ;; Background window's pane -> its buffer.
              (tmux-control--batch-pane-output "%1" "bg-line")
              (should (equal (buffer-local-value 'tmux-control--output-batch buf)
                             '("bg-line")))
              (should-not tmux-control--output-batch)
              ;; Controller's own pane (no sibling buffer for it) -> controller.
              (tmux-control--batch-pane-output "%0" "fg-line")
              (should (equal tmux-control--output-batch '("fg-line")))))
        (kill-buffer buf)))))

(ert-deftest tmux-control-test-session-window-changed-swaps-display ()
  ;; With per-window buffers on, a window switch -- ours or external -- swaps
  ;; the displayed buffer; the in-place reseed machinery is bypassed.
  (with-temp-buffer
    (setq-local tmux-control--tiled nil)
    (let ((tmux-control-window-buffers t)
          (swapped nil) (reseeds 0))
      (cl-letf (((symbol-function 'tmux-control--flush-output-batch) #'ignore)
                ((symbol-function 'tmux-control--refresh-windows) #'ignore)
                ((symbol-function 'tmux-control--display-window-buffer)
                 (lambda (id) (setq swapped id)))
                ((symbol-function 'tmux-control--refresh-active-pane)
                 (lambda (&optional _self) (cl-incf reseeds))))
        (tmux-control--handle-line "%session-window-changed $0 @3")
        (should (equal swapped "@3"))
        (should (= reseeds 0))))))

(ert-deftest tmux-control-test-window-close-kills-render-buffer ()
  ;; %window-close takes the closed window's render buffer with it.
  (with-temp-buffer
    (setq-local tmux-control--tiled nil)
    (let ((tmux-control-window-buffers t)
          (buf (generate-new-buffer " *tc-wb-close*")))
      (with-current-buffer buf
        (setq-local tmux-control--window-id "@4"
                    tmux-control--controller (current-buffer)))
      (tmux-control--register-window-buffer "@4" buf)
      (cl-letf (((symbol-function 'tmux-control--flush-output-batch) #'ignore)
                ((symbol-function 'tmux-control--refresh-windows) #'ignore)
                ((symbol-function 'tmux-control--refresh-pane-window-map)
                 #'ignore))
        (tmux-control--handle-line "%window-close @4"))
      (should-not (buffer-live-p buf))
      (should-not (tmux-control--window-buffer "@4")))))

(ert-deftest tmux-control-test-session-display-buffer-fallback ()
  ;; Without a render buffer for the current window the controller itself
  ;; represents the session.
  (with-temp-buffer
    (let ((tmux-control-window-buffers t))
      (setq-local tmux-control--current-window "0"
                  tmux-control--windows '((:index "0" :name "x" :id "@1")))
      (should (eq (tmux-control--session-display-buffer) (current-buffer))))))

(ert-deftest tmux-control-test-scrollback-toggle-compaction ()
  ;; The pager toggle flips the buffer-local compaction flag and re-renders,
  ;; without touching the global default.
  (let ((global-before (default-value 'tmux-control-compact-scrollback)))
    (with-temp-buffer
      (tmux-control-scrollback-mode)
      (setq-local tmux-control-compact-scrollback t)
      (let ((refreshed 0))
        (cl-letf (((symbol-function 'tmux-control-scrollback-refresh)
                   (lambda () (cl-incf refreshed))))
          (tmux-control-scrollback-toggle-compaction)
          (should-not tmux-control-compact-scrollback)
          (should (= refreshed 1))
          (tmux-control-scrollback-toggle-compaction)
          (should tmux-control-compact-scrollback)
          (should (= refreshed 2))))
      ;; The global default was never mutated by the buffer-local toggle.
      (should (eq (default-value 'tmux-control-compact-scrollback)
                  global-before)))))

(ert-deftest tmux-control-test-display-swap-survives-stale-window-index ()
  ;; THE menu-switch race: rapid successive switches deliver the second
  ;; %session-window-changed before the :windows reply has updated
  ;; `tmux-control--current-window'.  The swap must track the displayed
  ;; buffer explicitly, not derive it from that stale index -- deriving it
  ;; found no window showing the (wrong) "old" buffer and silently left the
  ;; view stranded on the previous window.
  (with-temp-buffer
    (let* ((tmux-control-window-buffers t)
           (ctrl (current-buffer))
           (buf-b (generate-new-buffer " *tc-race-b*"))
           (buf-c (generate-new-buffer " *tc-race-c*"))
           (win (selected-window))
           (orig (window-buffer win)))
      (unwind-protect
          (progn
            (setq-local tmux-control--window-id "@1")
            ;; Window list STALE throughout: current-window says index 0
            ;; (the controller's own window) the whole time.
            (setq-local tmux-control--current-window "0")
            (setq-local tmux-control--windows
                        '((:index "0" :name "a" :active t :id "@1")
                          (:index "1" :name "b" :id "@2")
                          (:index "2" :name "c" :id "@3")))
            (tmux-control--register-window-buffer "@1" ctrl)
            (dolist (pair `(("@2" . ,buf-b) ("@3" . ,buf-c)))
              (with-current-buffer (cdr pair)
                (setq-local tmux-control--window-id (car pair)
                            tmux-control--controller ctrl))
              (tmux-control--register-window-buffer (car pair) (cdr pair)))
            (set-window-buffer win ctrl)
            ;; First switch: ctrl -> B.
            (tmux-control--display-window-buffer "@2")
            (should (eq (window-buffer win) buf-b))
            ;; Second switch lands while current-window is STILL "0":
            ;; must swap B -> C anyway.
            (tmux-control--display-window-buffer "@3")
            (should (eq (window-buffer win) buf-c))
            (should (eq (tmux-control--session-display-buffer ctrl) buf-c))
            ;; And back to the controller's own window.
            (tmux-control--display-window-buffer "@1")
            (should (eq (window-buffer win) ctrl)))
        (set-window-buffer win orig)
        (kill-buffer buf-b)
        (kill-buffer buf-c)))))

(ert-deftest tmux-control-test-do-select-window-swaps-optimistically ()
  ;; A menu/tab selection knows its target window, so the display swaps
  ;; IMMEDIATELY -- zero round trips, no dependence on tmux echoing
  ;; %session-window-changed.  (The echo re-runs the swap idempotently.)
  (with-temp-buffer
    (let* ((tmux-control-window-buffers t)
           (ctrl (current-buffer))
           (buf-b (generate-new-buffer " *tc-opt-b*"))
           (win (selected-window))
           (orig (window-buffer win))
           (sent nil))
      (unwind-protect
          (cl-letf (((symbol-function 'tmux-control--ensure-live) #'ignore)
                    ((symbol-function 'tmux-control--send-command)
                     (lambda (cmd &optional _kind) (push cmd sent))))
            (setq-local tmux-control--session "s"
                        tmux-control--window-id "@1"
                        tmux-control--current-window "0"
                        tmux-control--windows
                        '((:index "0" :name "a" :active t :id "@1")
                          (:index "1" :name "b" :id "@2")))
            (tmux-control--register-window-buffer "@1" ctrl)
            (with-current-buffer buf-b
              (setq-local tmux-control--window-id "@2"
                          tmux-control--controller ctrl))
            (tmux-control--register-window-buffer "@2" buf-b)
            (set-window-buffer win ctrl)
            ;; Select window 1: the swap happens NOW, before any reply.
            (tmux-control--do-select-window "1")
            (should (eq (window-buffer win) buf-b))
            (should (cl-some (lambda (c) (string-match-p "select-window" c))
                             sent))
            ;; Unknown index (no id cached): no swap, no error; the echo
            ;; will handle it.
            (tmux-control--do-select-window "7")
            (should (eq (window-buffer win) buf-b)))
        (set-window-buffer win orig)
        (kill-buffer buf-b)))))

(ert-deftest tmux-control-test-select-pane-crosses-windows ()
  ;; `tmux-control-select-pane' can be handed (or complete to) a pane in
  ;; another window, but tmux's bare `select-pane' cannot move the session
  ;; there -- so the command must switch the window first, then focus the
  ;; pane.  (Regression: the old single-buffer client followed
  ;; %window-pane-changed unconditionally, which made the bare command
  ;; LOOK like a cross-window jump; per-window buffers routed the change
  ;; to the other window's buffer and the view stayed put.)
  (with-temp-buffer
    (let ((sent '()) (window-selected nil))
      (cl-letf (((symbol-function 'tmux-control--ensure-live) #'ignore)
                ((symbol-function 'tmux-control--do-select-window)
                 (lambda (idx) (setq window-selected idx)))
                ((symbol-function 'tmux-control--send-command)
                 (lambda (cmd &optional _kind) (push cmd sent))))
        (setq-local tmux-control--session "s"
                    tmux-control--current-window "0"
                    tmux-control--pane-window (make-hash-table :test 'equal))
        (puthash "%0" (cons "0" "@1") tmux-control--pane-window)
        (puthash "%5" (cons "1" "@2") tmux-control--pane-window)
        ;; Same-window pane: no window switch, just select-pane.
        (tmux-control-select-pane "%0")
        (should-not window-selected)
        (should (equal (car sent) "select-pane -t %0"))
        ;; Cross-window pane: switch the window, then focus the pane.
        (tmux-control-select-pane "%5")
        (should (equal window-selected "1"))
        (should (equal (car sent) "select-pane -t %5"))))))

(ert-deftest tmux-control-test-display-swap-recovers-desynced-pointer ()
  ;; The swap keys off the windows REALLY showing session buffers, not the
  ;; display pointer.  Displaying a render buffer by hand (`switch-to-buffer',
  ;; a window-config restore) desyncs the pointer from the frame; a
  ;; pointer-keyed swap then either hunted for an "old" buffer no window was
  ;; showing, or -- when the pointer already claimed the target -- declined
  ;; to swap at all.  Field report: with the pointer stuck on the other
  ;; window's buffer, every switch toward it was a silent no-op.
  (with-temp-buffer
    (let* ((tmux-control-window-buffers t)
           (ctrl (current-buffer))
           (buf-b (generate-new-buffer " *tc-desync-b*"))
           (win (selected-window))
           (orig (window-buffer win)))
      (unwind-protect
          (progn
            (setq-local tmux-control--window-id "@1")
            (setq-local tmux-control--windows
                        '((:index "0" :name "a" :id "@1")
                          (:index "1" :name "b" :active t :id "@2")))
            (tmux-control--register-window-buffer "@1" ctrl)
            (with-current-buffer buf-b
              (setq-local tmux-control--window-id "@2"
                          tmux-control--controller ctrl))
            (tmux-control--register-window-buffer "@2" buf-b)
            ;; Out-of-band display: the frame shows the controller while the
            ;; pointer still claims B is on screen.
            (set-window-buffer win ctrl)
            (setq-local tmux-control--session-display buf-b)
            ;; Swapping "to" B -- which the pointer believes needs nothing --
            ;; must still converge the frame on B.
            (tmux-control--display-window-buffer "@2")
            (should (eq (window-buffer win) buf-b))
            (should (eq (tmux-control--session-display-buffer ctrl) buf-b))
            ;; And the view keeps following normal swaps afterwards.
            (tmux-control--display-window-buffer "@1")
            (should (eq (window-buffer win) ctrl)))
        (set-window-buffer win orig)
        (kill-buffer buf-b)))))

(ert-deftest tmux-control-test-select-pane-jumps-from-viewed-window ()
  ;; The cross-window jump triggers off the window the invoking buffer
  ;; renders, not only off tmux's current window.  With the session already
  ;; current on the pane's window but the frame showing another window's
  ;; buffer (an out-of-band display), the bare select-pane changes nothing
  ;; tmux would notify about -- the command itself must route through the
  ;; window switch so the view converges.
  (with-temp-buffer
    (let ((sent '()) (window-selected nil))
      (cl-letf (((symbol-function 'tmux-control--ensure-live) #'ignore)
                ((symbol-function 'tmux-control--do-select-window)
                 (lambda (idx) (setq window-selected idx)))
                ((symbol-function 'tmux-control--send-command)
                 (lambda (cmd &optional _kind) (push cmd sent))))
        (setq-local tmux-control--session "s"
                    tmux-control--window-id "@1" ; this buffer renders w0
                    tmux-control--current-window "1" ; tmux sits on w1
                    tmux-control--pane-window (make-hash-table :test 'equal))
        (puthash "%0" (cons "0" "@1") tmux-control--pane-window)
        (puthash "%5" (cons "1" "@2") tmux-control--pane-window)
        ;; Pane of the session's current window but NOT of the rendered one:
        ;; the regression -- must jump, not send a bare invisible select-pane.
        (tmux-control-select-pane "%5")
        (should (equal window-selected "1"))
        (should (equal (car sent) "select-pane -t %5"))
        ;; Pane of the rendered window while the session is current
        ;; elsewhere: still a jump (the current-window clause).
        (setq window-selected nil)
        (tmux-control-select-pane "%0")
        (should (equal window-selected "0"))
        ;; Pane of the window both rendered and current: plain select-pane.
        (setq-local tmux-control--current-window "0")
        (setq window-selected nil)
        (tmux-control-select-pane "%0")
        (should-not window-selected)
        (should (equal (car sent) "select-pane -t %0"))))))

(ert-deftest tmux-control-test-flush-anchors-only-tiled-panes ()
  ;; The screen-top anchor exists for TILED panes.  It counts buffer lines
  ;; back from point-max, which lands above eat's display-beginning whenever
  ;; a screen row is a wrapped continuation -- so in a per-window render
  ;; buffer (which also sets `tmux-control--controller') every output flush
  ;; re-anchored the view away from where eat's keystroke-time scroll sync
  ;; had just put it, and typing into a TUI bounced the screen up and down
  ;; once per character (field report).  The anchor must run only when the
  ;; buffer's controller is actually tiling.
  (let ((anchored 0)
        (eat--synchronize-scroll-function #'ignore))
    (cl-letf (((symbol-function 'tmux-control--anchor-windows-to-screen-top)
               (lambda (_) (cl-incf anchored)))
              ((symbol-function 'eat-term-redisplay) #'ignore)
              ((symbol-function 'eat-term-live-p) (lambda (_) t))
              ((symbol-function 'tmux-control--keep-cursor-visible) #'ignore))
      (let ((ctrl (generate-new-buffer " *tc-anchor-ctrl*")))
        (unwind-protect
            (progn
              ;; Per-window render buffer: controller NOT tiled -> no anchor.
              (with-temp-buffer
                (setq-local tmux-control--terminal t
                            tmux-control--display-dirty t
                            tmux-control--controller ctrl)
                (tmux-control--flush-display (list (selected-window))))
              (should (= anchored 0))
              ;; The controller buffer itself (no --controller): no anchor.
              (with-temp-buffer
                (setq-local tmux-control--terminal t
                            tmux-control--display-dirty t)
                (tmux-control--flush-display (list (selected-window))))
              (should (= anchored 0))
              ;; Tiled pane buffer: controller tiling -> anchored.
              (with-current-buffer ctrl
                (setq-local tmux-control--tiled t))
              (with-temp-buffer
                (setq-local tmux-control--terminal t
                            tmux-control--display-dirty t
                            tmux-control--controller ctrl)
                (tmux-control--flush-display (list (selected-window))))
              (should (= anchored 1)))
          (when (buffer-live-p ctrl)
            (kill-buffer ctrl)))))))

(ert-deftest tmux-control-test-scrollback-recapture-on-resize ()
  ;; Raw scrollback rows fit only the width they were captured for, so a
  ;; window resize must re-capture: ask tmux for the new size FIRST, then
  ;; capture -- both ride the one connection in order, so the capture sees
  ;; the re-wrapped history.  (Field report: wide -> half -> wide again
  ;; left the view hard-wrapped at the narrow width.)
  (let ((calls '()))
    (cl-letf (((symbol-function 'tmux-control--resize)
               (lambda (w h) (push (list 'resize w h) calls)))
              ((symbol-function 'tmux-control--scrollback-request)
               (lambda (&rest _) (push 'capture calls)))
              ;; Refresh also re-queries history_size (re-wrapping on a resize
              ;; changes it); not the subject of this ordering test.
              ((symbol-function 'tmux-control--scrollback-update-history-rows)
               #'ignore)
              ((symbol-function 'process-live-p)
               (lambda (p) (eq p 'fake-proc))))
      (let ((live (generate-new-buffer " *tc-sb-live*"))
            (sb (generate-new-buffer " *tc-sb-view*"))
            (win (selected-window))
            (orig (window-buffer)))
        (unwind-protect
            (progn
              (with-current-buffer live
                (setq-local tmux-control--process 'fake-proc))
              (with-current-buffer sb
                (tmux-control-scrollback-mode)
                (setq-local tmux-control--scrollback-target "%1"
                            tmux-control--live-buffer live
                            ;; A size no real window has, so the follower
                            ;; sees a change.
                            tmux-control--scrollback-size '(9999 . 9999)))
              (set-window-buffer win sb)
              ;; A size change from the recorded one arms the debounce.
              (tmux-control--scrollback-follow-resize (selected-frame))
              (with-current-buffer sb
                (should (timerp tmux-control--scrollback-resize-timer))
                (cancel-timer tmux-control--scrollback-resize-timer))
              ;; The recapture resizes tmux BEFORE capturing again.
              (tmux-control--scrollback-resize-recapture sb)
              (let ((order (reverse calls)))
                (should (eq (car (car order)) 'resize))
                (should (eq (car (last order)) 'capture)))
              ;; An unchanged size arms nothing.
              (setq calls '())
              (tmux-control--scrollback-follow-resize (selected-frame))
              (with-current-buffer sb
                (should-not tmux-control--scrollback-resize-timer))
              (should-not calls))
          (set-window-buffer win orig)
          (kill-buffer sb)
          (kill-buffer live))))))

(ert-deftest tmux-control-test-resize-skips-unchanged ()
  ;; Emacs core fires the window-size hook on many redisplays where the size
  ;; did not change; a same-size resize must not re-send refresh-client or
  ;; re-query the pane size (the redundant remote round trips).  A real size
  ;; change still fires.
  (let ((sent '()) (refreshed 0))
    (cl-letf (((symbol-function 'tmux-control--send-command)
               (lambda (cmd &optional _k) (push cmd sent)))
              ((symbol-function 'tmux-control--refresh-pane-size)
               (lambda () (cl-incf refreshed)))
              ((symbol-function 'tmux-control--apply-eat-size) (lambda (_w _h) nil))
              ((symbol-function 'tmux-control--wb-controller)
               (lambda () (current-buffer))))
      (with-temp-buffer
        (let ((tmux-control-window-buffers nil))
          (setq-local tmux-control--requested-client-size nil)
          ;; First resize: cache nil -> fires.
          (tmux-control--resize 120 40)
          (should (= refreshed 1))
          (should (cl-some (lambda (c) (string-match-p "refresh-client -C 120x40" c))
                           sent))
          (should (equal tmux-control--requested-client-size '(120 . 40)))
          ;; Same size again: skipped (no round trips).
          (setq sent nil)
          (tmux-control--resize 120 40)
          (should (= refreshed 1))
          (should (null sent))
          ;; A real change: fires again.
          (tmux-control--resize 100 30)
          (should (= refreshed 2))
          (should (cl-some (lambda (c) (string-match-p "refresh-client -C 100x30" c))
                           sent)))))))

(ert-deftest tmux-control-test-pinned-size-warns-once-and-recovers ()
  ;; tmux silently refusing our size requests (window-size manual after any
  ;; resize-window, or a competing client) must be surfaced: one probe+warn
  ;; per episode, episode cleared when a reconciliation matches again.
  (with-temp-buffer
    (let ((queries '()))
      (cl-letf (((symbol-function 'tmux-control--query)
                 (lambda (cmd cb) (push cmd queries) (funcall cb '("manual"))))
                ((symbol-function 'message) #'ignore))
        (setq-local tmux-control--session "s"
                    tmux-control--current-window "0"
                    tmux-control--window-id "@7" ; the displayed window
                    tmux-control--requested-client-size (cons 124 37)
                    tmux-control--size-pin-warned nil)
        ;; Mismatched WINDOW width: probe fires -- targeting the displayed
        ;; window by stable @id, as a -w window option -- and the warning
        ;; names the pin in-buffer.
        (tmux-control--maybe-warn-pinned-size (cons 100 20))
        (should tmux-control--size-pin-warned)
        (should (= 1 (length queries)))
        (should (string-match-p "show-options -wqv -t @7 window-size"
                                (car queries)))
        (should (string-match-p "window-size manual" (buffer-string)))
        ;; Still mismatched: no second probe, no second warning.
        (tmux-control--maybe-warn-pinned-size (cons 100 20))
        (should (= 1 (length queries)))
        ;; tmux follows again: the episode ends.
        (tmux-control--maybe-warn-pinned-size (cons 124 36))
        (should-not tmux-control--size-pin-warned)))))

(ert-deftest tmux-control-test-adopt-window-size-unpins ()
  ;; The recovery command unpins the rendered window and resizes to the
  ;; Emacs window, clearing the warning episode.
  (with-temp-buffer
    (let ((sent '()) (resized nil))
      (cl-letf (((symbol-function 'tmux-control--ensure-live) #'ignore)
                ((symbol-function 'tmux-control--resize-to-window)
                 (lambda () (setq resized t)))
                ((symbol-function 'tmux-control--send-command)
                 (lambda (cmd &optional _kind) (push cmd sent)))
                ((symbol-function 'message) #'ignore))
        (setq-local tmux-control--session "s"
                    tmux-control--window-id "@2"
                    tmux-control--current-window "0"
                    tmux-control--windows
                    '((:index "0" :name "a" :id "@1")
                      (:index "1" :name "b" :id "@2"))
                    tmux-control--size-pin-warned t)
        (tmux-control-adopt-window-size)
        ;; Targets the window THIS buffer renders (@2 -> index 1).
        (should (equal (car sent) "set-option -w -t \"s\":1 window-size latest"))
        (should resized)
        (should-not tmux-control--size-pin-warned)))))

(ert-deftest tmux-control-test-escape-sends-escape-immediately ()
  ;; A bare ESC press should reach the pane the moment it is pressed.  In
  ;; GUI Emacs the unbound `escape' event decays into the meta prefix and
  ;; waits indefinitely for a second key -- vim's mode switch and an
  ;; agent TUI's interrupt did nothing until the NEXT keystroke.  It is
  ;; bound in the major mode map ONLY: a modal package's ESC binding
  ;; (xah-fly-keys/evil/viper, in a minor-mode map) must keep winning, so
  ;; ESC must NOT sit in the high-precedence emulation override map (a
  ;; regression that swallowed xah-fly-keys' command-mode-activate).
  (should (eq (lookup-key tmux-control-mode-map [escape])
              #'tmux-control-send-escape))
  (should-not (lookup-key tmux-control--override-map [escape]))
  (let ((sent '()))
    (cl-letf (((symbol-function 'eat-self-input)
               (lambda (_n event) (push event sent))))
      (tmux-control-send-escape)
      (should (equal sent '(?\e))))))

(defvar tmux-control-test--fake-modal nil
  "Stands in for a modal minor mode in the ESC precedence test.")

(ert-deftest tmux-control-test-escape-yields-to-minor-mode-map ()
  ;; The regression was about keymap PRECEDENCE, not which map names the
  ;; binding: ESC lived in an emulation map, which outranks minor-mode
  ;; maps, so a modal package's ESC binding lost.  Exercise the live
  ;; `key-binding' resolution through the full stack a real buffer has --
  ;; emulation override (active in semi-char mode) over minor-mode maps
  ;; over the major mode map -- so reintroducing ESC into the override
  ;; map fails here even though the static binding would still "look"
  ;; right.
  (let* ((sentinel (lambda () (interactive) 'modal-switch))
         (modal-map (let ((m (make-sparse-keymap)))
                      (define-key m [escape] sentinel)
                      m)))
    (with-temp-buffer
      (tmux-control-mode)
      ;; Reproduce a live buffer: the override emulation map is active.
      (setq-local emulation-mode-map-alists
                  (cons tmux-control--emulation-mode-map-alist
                        emulation-mode-map-alists))
      (setq tmux-control--keys-active t)
      (let ((minor-mode-map-alist
             (cons (cons 'tmux-control-test--fake-modal modal-map)
                   minor-mode-map-alist)))
        ;; Modal package active: its minor-mode ESC wins.
        (setq tmux-control-test--fake-modal t)
        (should (eq (key-binding [escape]) sentinel))
        ;; No modal package: ESC falls through to the pane.
        (setq tmux-control-test--fake-modal nil)
        (should (eq (key-binding [escape]) #'tmux-control-send-escape))))))

(ert-deftest tmux-control-test-quote-tmux-data-octal-escapes ()
  ;; Newlines (and every non-alphanumeric byte) ride control commands as
  ;; octal escapes inside double quotes -- the one representation tmux's
  ;; parser decodes that a one-line command can always carry.
  (let* ((s "ab 1\n$\"\\#{x}\t")
         (bytes (encode-coding-string s 'utf-8-unix))
         (quoted (tmux-control--quote-tmux-data bytes 0 (length bytes))))
    (should (string-prefix-p "\"" quoted))
    (should (string-suffix-p "\"" quoted))
    ;; Literal alphanumerics and spaces survive.
    (should (string-match-p "ab 1" quoted))
    ;; Newline, dollar, quote, backslash, hash, tab are all octal.
    (should (string-match-p "\\\\012" quoted))   ; \n
    (should (string-match-p "\\\\044" quoted))   ; $
    (should (string-match-p "\\\\042" quoted))   ; "
    (should (string-match-p "\\\\134" quoted))   ; backslash
    (should (string-match-p "\\\\043" quoted))   ; #
    (should (string-match-p "\\\\011" quoted))   ; tab
    ;; And nothing hazardous remains bare (backslashes appear only as
    ;; the escape introducer, always followed by three octal digits).
    (should-not (string-match-p "[$#\n\t]" (substring quoted 1 -1)))
    (should-not (string-match-p "\\\\[^0-7]" (substring quoted 1 -1)))
    ;; Stable across calls: the builder must not mutate a shared list
    ;; literal (the original did, via nreverse -- every paste after the
    ;; first came out byte-reversed with debris).
    (should (equal quoted
                   (tmux-control--quote-tmux-data bytes 0 (length bytes))))
    (should (equal quoted
                   (tmux-control--quote-tmux-data bytes 0 (length bytes))))))

(ert-deftest tmux-control-test-paste-rides-tmux-paste-buffer ()
  ;; Pastes go through set-buffer + paste-buffer -p so that tmux applies
  ;; bracketed paste exactly when the pane requested it.  A client-side
  ;; send-keys cannot know that state: a 3-line paste into bash executed
  ;; line by line (verified live) instead of arriving as one reviewable
  ;; block.
  (let ((sent '()))
    (cl-letf (((symbol-function 'tmux-control--send-command)
               (lambda (cmd &optional _kind) (push cmd sent))))
      (with-temp-buffer
        (tmux-control-mode)
        (setq-local tmux-control--active-pane "%5")
        (tmux-control--paste-to-pane "echo one\necho two"))
      (let ((cmds (nreverse sent)))
        (should (= 2 (length cmds)))
        (should (string-match-p "\\`set-buffer -b tmux-control-paste-[0-9]+ \""
                                (nth 0 cmds)))
        (should (string-match-p "echo one\\\\012echo two" (nth 0 cmds)))
        (should (string-match-p
                 "\\`paste-buffer -p -d -b tmux-control-paste-[0-9]+ -t %5\\'"
                 (nth 1 cmds)))))))

(ert-deftest tmux-control-test-paste-chunks-large-text ()
  ;; A paste longer than one command's worth appends with set-buffer -a,
  ;; in order, before the single paste-buffer delivery.
  (let ((sent '()))
    (cl-letf (((symbol-function 'tmux-control--send-command)
               (lambda (cmd &optional _kind) (push cmd sent))))
      (with-temp-buffer
        (tmux-control-mode)
        (setq-local tmux-control--active-pane "%1")
        (tmux-control--paste-to-pane (make-string 2500 ?x)))
      (let ((cmds (nreverse sent)))
        (should (= 4 (length cmds)))          ; 3 chunks of 1024 + paste
        (should (string-prefix-p "set-buffer -b" (nth 0 cmds)))
        (should (string-prefix-p "set-buffer -a -b" (nth 1 cmds)))
        (should (string-prefix-p "set-buffer -a -b" (nth 2 cmds)))
        (should (string-prefix-p "paste-buffer -p -d -b" (nth 3 cmds)))))))

(ert-deftest tmux-control-test-char-mode-swaps-override-map ()
  ;; Char mode exists to send EVERY key to the pane -- C-c above all --
  ;; but the override emulation map outranks char mode's own keymap, so
  ;; C-c stayed a prefix there.  The advices swap the full override map
  ;; for the wheel-only map on entry and restore it on return.
  (with-temp-buffer
    (tmux-control-mode)
    (setq-local tmux-control--keys-active t
                tmux-control--char-mode-keys nil)
    ;; Enter char mode (orig-fn stubbed: Eat's own toggling is not under
    ;; test, the tmux-control gating is).
    (tmux-control--eat-char-mode-advice #'ignore)
    (should-not tmux-control--keys-active)
    (should tmux-control--char-mode-keys)
    ;; The wheel-only map still handles wheel-up; C-c is NOT bound in it
    ;; (not even as a prefix), so char mode's own C-c reaches the pane.
    (should (eq (lookup-key tmux-control--char-mode-map [wheel-up])
                #'tmux-control-wheel-scroll))
    (should-not (lookup-key tmux-control--char-mode-map (kbd "C-c")))
    ;; Back to semi-char: full map restored.
    (tmux-control--eat-semi-char-mode-advice #'ignore)
    (should tmux-control--keys-active)
    (should-not tmux-control--char-mode-keys)))
(ert-deftest tmux-control-test-snap-to-live-screen-on-arrival ()
  ;; A window ARRIVING at a live render buffer is pointed at the live
  ;; screen.  Emacs restores the window's remembered per-buffer point,
  ;; which goes stale by however much the buffer streamed while it was
  ;; off screen -- returning after a background flood landed the view
  ;; thousands of lines up, on ancient scrollback (field report: Top L1
  ;; of an 18k-line buffer).
  (let ((synced '()))
    (cl-letf (((symbol-function 'eat--synchronize-scroll)
               (lambda (windows) (push windows synced)))
              ((symbol-function 'eat-term-live-p) (lambda (_) t))
              ;; Batch redisplay never runs, so window-old-buffer is not
              ;; maintained; pin the "buffer changed" answer explicitly.
              ((symbol-function 'window-old-buffer) (lambda (_) nil)))
      (save-window-excursion
        (with-temp-buffer
          (tmux-control-mode)
          (setq-local tmux-control--terminal t)
          (set-window-buffer (selected-window) (current-buffer))
          (tmux-control--snap-to-live-screen (selected-window))
          (should (equal synced (list (list (selected-window))))))))))

(ert-deftest tmux-control-test-snap-skips-unchanged-and-tiled ()
  ;; The buffer-local `window-buffer-change-functions' hook also fires
  ;; for windows whose buffer did NOT change (any change on the frame
  ;; triggers it); those windows -- e.g. a live view the user scrolled
  ;; up on purpose -- must not be yanked back to the bottom.  Tiled pane
  ;; buffers are anchored by the tiling layer and are skipped too.
  (let ((synced 0))
    (cl-letf (((symbol-function 'eat--synchronize-scroll)
               (lambda (_) (cl-incf synced)))
              ((symbol-function 'eat-term-live-p) (lambda (_) t)))
      ;; Same buffer as last redisplay: no snap.
      (cl-letf (((symbol-function 'window-old-buffer)
                 (lambda (w) (window-buffer w))))
        (save-window-excursion
          (with-temp-buffer
            (tmux-control-mode)
            (setq-local tmux-control--terminal t)
            (set-window-buffer (selected-window) (current-buffer))
            (tmux-control--snap-to-live-screen (selected-window))
            (should (= synced 0)))))
      ;; Tiled pane buffer: tiling owns the arrangement.
      (cl-letf (((symbol-function 'window-old-buffer) (lambda (_) nil)))
        (let ((ctrl (generate-new-buffer " *tc-snap-ctrl*")))
          (unwind-protect
              (progn
                (with-current-buffer ctrl
                  (setq-local tmux-control--tiled t))
                (save-window-excursion
                  (with-temp-buffer
                    (tmux-control-mode)
                    (setq-local tmux-control--terminal t
                                tmux-control--controller ctrl)
                    (set-window-buffer (selected-window) (current-buffer))
                    (tmux-control--snap-to-live-screen (selected-window))
                    (should (= synced 0)))))
            (kill-buffer ctrl)))))))

(ert-deftest tmux-control-test-scrollback-wheel-down-exits-at-bottom ()
  ;; tmux copy-mode parity: scrolling back down to the bottom of the
  ;; pager leaves scrollback -- the gesture that took you in takes you
  ;; back out.  But ONLY after the user has scrolled up into history: you
  ;; enter by scrolling up, so the pager opens at the bottom, and a
  ;; wheel-down right then (the up-flick's momentum tail, or one arriving
  ;; while the "capturing…" placeholder makes the bottom trivially
  ;; visible) must NOT bounce straight back out (field report: a loop).
  (let ((lived 0) (dispatched 0) (at-bottom t))
    (cl-letf (((symbol-function 'tmux-control-live)
               (lambda () (cl-incf lived)))
              ((symbol-function 'tmux-control--dispatch-wheel)
               (lambda (_) (cl-incf dispatched)))
              ;; Batch windows never redisplay, so real visibility is
              ;; unanswerable here; pin it.  The live behavior is covered
              ;; by the interactive rig.
              ((symbol-function 'window-end)
               (lambda (&rest _) (if at-bottom (point-max) (point-min)))))
      (save-window-excursion
        (with-temp-buffer
          (tmux-control-scrollback-mode)
          (let ((inhibit-read-only t)) (insert "history line\n"))
          (setq-local tmux-control--scrollback-left-bottom nil)
          (set-window-buffer (selected-window) (current-buffer))
          ;; Fresh pager, at the bottom, never scrolled up: a wheel-down
          ;; does NOT leave -- it scrolls (a no-op on a short buffer).
          (tmux-control-scrollback-wheel-down
           (list 'wheel-down (list (selected-window))))
          (should (= lived 0))
          (should (= dispatched 1))
          ;; Scroll up off the bottom: normal scroll, and now the pager
          ;; remembers it has left the bottom.
          (setq at-bottom nil)
          (tmux-control-scrollback-wheel-down
           (list 'wheel-down (list (selected-window))))
          (should (= lived 0))
          (should (= dispatched 2))
          (should tmux-control--scrollback-left-bottom)
          ;; Back down to the bottom after viewing history: NOW it leaves.
          (setq at-bottom t)
          (tmux-control-scrollback-wheel-down
           (list 'wheel-down (list (selected-window))))
          (should (= lived 1))
          (should (= dispatched 2)))))))

(ert-deftest tmux-control-test-scrollback-prepend ()
  ;; Lazy extension prepends an older delta above the already-loaded
  ;; history: the new lines land at the top, a separator newline keeps the
  ;; delta's last line from gluing onto the old top line, and the loaded
  ;; depth advances to the freshly captured value.
  (let ((tmux-control-compact-scrollback nil))
    (with-temp-buffer
      (tmux-control-scrollback-mode)
      (let ((inhibit-read-only t)) (insert "old-top line\nlive tail\n"))
      (setq-local tmux-control--scrollback-depth 500)
      ;; A delta with no trailing newline must still be separated from the
      ;; existing top line.
      (tmux-control--scrollback-prepend "older-1\nolder-2" 2500)
      (should (equal (buffer-string)
                     "older-1\nolder-2\nold-top line\nlive tail\n"))
      (should (= tmux-control--scrollback-depth 2500)))))

(ert-deftest tmux-control-test-scrollback-drop-seam-overlap ()
  ;; Drops the new (older) chunk's tail when it duplicates the buffer head --
  ;; the drift overlap from a pane that scrolled while the pager was open --
  ;; but only on a SAFE (>=2 distinctive nonblank) overlap.
  (let ((tmux-control-compact-scrollback-window 200))
    ;; Two-line distinctive overlap: dropped.
    (should (equal (tmux-control--scrollback-drop-seam-overlap
                    '("old-1" "old-2" "dup-a" "dup-b")
                    '("dup-a" "dup-b" "loaded-1"))
                   '("old-1" "old-2")))
    ;; No overlap (the normal, non-drifting extend): unchanged.
    (should (equal (tmux-control--scrollback-drop-seam-overlap
                    '("old-1" "old-2" "old-3")
                    '("loaded-1" "loaded-2"))
                   '("old-1" "old-2" "old-3")))
    ;; A lone blank coincidental overlap is not safe, so not dropped.
    (should (equal (tmux-control--scrollback-drop-seam-overlap
                    '("old-1" "")
                    '("" "loaded-1"))
                   '("old-1" "")))))

(ert-deftest tmux-control-test-scrollback-prepend-dedups-seam ()
  ;; A pane that scrolls while the pager is open makes an extend re-capture
  ;; lines already at the top (tmux's -S/-E slide with the screen).  The
  ;; prepend must drop that overlapping tail instead of doubling it.
  (let ((tmux-control-compact-scrollback nil)
        (tmux-control-compact-scrollback-window 200))
    (with-temp-buffer
      (tmux-control-scrollback-mode)
      (let ((inhibit-read-only t))
        (insert "dup one\ndup two\nloaded tail\n"))
      (setq-local tmux-control--scrollback-depth 100)
      ;; The captured older chunk ends with the two lines already shown at the
      ;; top (the drift overlap); only "older A/B" are genuinely new.
      (tmux-control--scrollback-prepend
       "older A\nolder B\ndup one\ndup two" 200)
      (should (equal (buffer-string)
                     "older A\nolder B\ndup one\ndup two\nloaded tail\n"))
      ;; Depth is the captured -S depth of the TOP line ("older A"), which the
      ;; seam drop preserves (only the duplicate tail is removed), so it is
      ;; stored unchanged.
      (should (= tmux-control--scrollback-depth 200)))))

(ert-deftest tmux-control-test-scrollback-populate-arms-extension ()
  ;; The pager opens with extension HELD OFF (extending = t) so the one-line
  ;; "capturing…" placeholder -- which makes the top trivially visible --
  ;; cannot trip the scroll watcher into loading a second chunk before the
  ;; first arrives.  Populating with the initial content must clear that latch
  ;; so real scrolling can extend.
  (let ((tmux-control-compact-scrollback nil))
    (with-temp-buffer
      (tmux-control-scrollback-mode)
      (setq-local tmux-control--scrollback-extending t) ; held during placeholder
      (tmux-control--scrollback-populate (current-buffer) "L1\nL2\nL3" nil nil)
      (should-not tmux-control--scrollback-extending)
      (should (string-match-p "L1" (buffer-string))))))

(ert-deftest tmux-control-test-scrollback-prepend-pins-viewport ()
  ;; Prepending older history must keep the view on the same content line,
  ;; not jump it to the freshly loaded lines.  The anchor marker (insertion
  ;; type t) tracks the line at `window-start' across the insert-before, so
  ;; the line you were reading stays put while new history appears above it.
  (let ((tmux-control-compact-scrollback nil))
    (save-window-excursion
      (with-temp-buffer
        (tmux-control-scrollback-mode)
        (let ((inhibit-read-only t))
          (dotimes (i 20) (insert (format "orig %02d\n" i))))
        (setq-local tmux-control--scrollback-depth 500)
        (set-window-buffer (selected-window) (current-buffer))
        (let* ((win (selected-window))
               (target (save-excursion
                         (goto-char (point-min)) (forward-line 5) (point)))
               (line-at (lambda ()
                          (save-excursion
                            (goto-char (window-start win))
                            (buffer-substring-no-properties
                             (line-beginning-position) (line-end-position))))))
          (set-window-start win target)
          (should (equal (funcall line-at) "orig 05"))
          (tmux-control--scrollback-prepend "older A\nolder B\nolder C" 2500)
          ;; Same line is still at the top of the window.
          (should (equal (funcall line-at) "orig 05"))
          (should (= tmux-control--scrollback-depth 2500)))))))

(ert-deftest tmux-control-test-scrollback-extend-result ()
  ;; The seam math: with history_size known, depth is the requested row
  ;; offset (NEW-DEPTH) and the top is reached when it meets history_size --
  ;; independent of the reply's line count, which `-J' shrinks below the row
  ;; span.  Without history_size, the old line-count heuristic is the fallback.
  (cl-flet ((res #'tmux-control--scrollback-extend-result))
    ;; history known, no wrapping: depth = requested, not yet at top.
    (should (equal (res 500 2500 2000 10000) '(2500 . nil)))
    ;; history known, -J wrapped the rows so got (1500) < the 2000-row span:
    ;; depth still advances by the ROW span (2500), NOT old+got (2000), and it
    ;; does NOT falsely latch at-top.  This is the #4 bug the cap fixes.
    (should (equal (res 500 2500 1500 10000) '(2500 . nil)))
    ;; history known, the request reaches the oldest line -> at top.
    (should (equal (res 8000 10000 1800 10000) '(10000 . t)))
    (should (equal (res 8000 10000 9999 10000) '(10000 . t)))
    ;; history_size 0 (a pane with history disabled) is a valid count, not a
    ;; failed reply: already at the top, nothing older than the screen.
    (should (equal (res 0 0 0 0) '(0 . t)))
    ;; history UNKNOWN (reply not yet landed): fall back to the line count.
    ;; A full reply (got == span) advances by got and is not at top.
    (should (equal (res 500 2500 2000 nil) '(2500 . nil)))
    ;; A short reply means tmux clamped at the oldest line -> at top, and
    ;; depth advances only by what was actually returned.
    (should (equal (res 500 2500 1 nil) '(501 . t)))))

(ert-deftest tmux-control-test-scrollback-scroll-watch-gates-extend ()
  ;; The scroll watcher only schedules an extend when the view is near the
  ;; top of the loaded history, more history exists, and none is already in
  ;; flight -- and it latches `--scrollback-extending' so a burst of scroll
  ;; events coalesces into a single capture.  START is an argument (as
  ;; `window-scroll-functions' passes it), so the gating is exercised
  ;; without depending on batch redisplay settling a real window start.
  (let ((scheduled 0))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (&rest _) (cl-incf scheduled))))
      (save-window-excursion
        (with-temp-buffer
          (tmux-control-scrollback-mode)
          (let ((inhibit-read-only t))
            (dotimes (i 60) (insert (format "line %d\n" i))))
          (set-window-buffer (selected-window) (current-buffer))
          (let ((win (selected-window))
                (top (point-min))
                (deep (save-excursion
                        (goto-char (point-min)) (forward-line 50) (point))))
            (let ((tmux-control-scrollback-lines 10000))
              ;; Near the top, more to load, nothing in flight -> schedule,
              ;; and latch the in-flight guard.
              (setq-local tmux-control--scrollback-depth 500)
              (setq-local tmux-control--scrollback-extending nil)
              (tmux-control--scrollback-scroll-watch win top)
              (should (= scheduled 1))
              (should tmux-control--scrollback-extending)
              ;; Already extending: a second scroll event does not pile on.
              (tmux-control--scrollback-scroll-watch win top)
              (should (= scheduled 1))
              ;; Deep in the buffer (far from the top): no extend.
              (setq-local tmux-control--scrollback-extending nil)
              (tmux-control--scrollback-scroll-watch win deep)
              (should (= scheduled 1))
              (should-not tmux-control--scrollback-extending)
              ;; Reached the oldest line already: near the top no longer
              ;; schedules (nothing more to load).
              (setq-local tmux-control--scrollback-extending nil)
              (setq-local tmux-control--scrollback-at-top t)
              (tmux-control--scrollback-scroll-watch win top)
              (should (= scheduled 1))
              (should-not tmux-control--scrollback-extending)
              (setq-local tmux-control--scrollback-at-top nil))
            ;; At the cap, even pinned to the very top, nothing more loads.
            (let ((tmux-control-scrollback-lines 500))
              (setq-local tmux-control--scrollback-depth 500)
              (setq-local tmux-control--scrollback-extending nil)
              (tmux-control--scrollback-scroll-watch win top)
              (should (= scheduled 1))
              (should-not tmux-control--scrollback-extending))))))))

(ert-deftest tmux-control-test-window-buffer-mode-line-drops-process-status ()
  ;; A per-window render buffer owns no process (the controller does);
  ;; Eat's default ":%s" suffix would permanently show "no process" for
  ;; a perfectly live view.  The mode indicator survives, the status goes.
  (let ((ctrl (generate-new-buffer " *tc-ml-ctrl*"))
        (made nil))
    (unwind-protect
        (progn
          (with-current-buffer ctrl
            (tmux-control-mode)
            (setq-local tmux-control--host nil
                        tmux-control--socket-name "sock"
                        tmux-control--session "mlsess"
                        tmux-control--process nil
                        tmux-control--capture-trailing-p nil
                        tmux-control--fallback-target "mlsess:"
                        tmux-control--terminal nil))
          (setq made (tmux-control--make-window-buffer "@9" ctrl))
          (with-current-buffer made
            (should-not (member ":%s" mode-line-process))
            ;; The eat mode indicator part survives.
            (should (consp mode-line-process))))
      (when (buffer-live-p made)
        (let ((kill-buffer-query-functions nil)) (kill-buffer made)))
      (kill-buffer ctrl))))
(ert-deftest tmux-control-test-reconnect-reuses-saved-parameters ()
  ;; `tmux-control-reconnect' re-runs the connect with the buffer's own
  ;; saved host/socket/session -- nothing to re-enter after a dropped link.
  (let ((calls '()))
    (cl-letf (((symbol-function 'tmux-control-connect)
               (lambda (host socket session)
                 (push (list host socket session) calls))))
      (with-temp-buffer
        (tmux-control-mode)
        (setq-local tmux-control--host "aurora"
                    tmux-control--socket-name "main"
                    tmux-control--session "dev")
        (tmux-control-reconnect))
      (should (equal calls '(("aurora" "main" "dev")))))))

(ert-deftest tmux-control-test-reconnect-hops-to-controller ()
  ;; From a per-window render buffer the reconnect must use the
  ;; controller's parameters (the render buffer shares them, but the
  ;; controller is authoritative).
  (let ((calls '()))
    (cl-letf (((symbol-function 'tmux-control-connect)
               (lambda (host socket session)
                 (push (list host socket session) calls))))
      (let ((ctrl (generate-new-buffer " *tc-test-ctrl*")))
        (unwind-protect
            (progn
              (with-current-buffer ctrl
                (tmux-control-mode)
                (setq-local tmux-control--host nil
                            tmux-control--socket-name "sock"
                            tmux-control--session "sess"))
              (with-temp-buffer
                (tmux-control-mode)
                (setq-local tmux-control--controller ctrl)
                (tmux-control-reconnect))
              (should (equal calls '((nil "sock" "sess")))))
          (kill-buffer ctrl))))))

(ert-deftest tmux-control-test-reconnect-outside-session-errors ()
  (with-temp-buffer
    (fundamental-mode)
    (should-error (tmux-control-reconnect) :type 'user-error)))

(ert-deftest tmux-control-test-auto-reconnect-backoff-capped ()
  ;; The reconnect delay grows exponentially with attempts and caps at 30s.
  (with-temp-buffer
    (setq-local tmux-control--auto-reconnect-timer nil)
    (let (delays)
      (cl-letf (((symbol-function 'run-with-timer)
                 (lambda (delay &rest _) (push delay delays) 'a-timer))
                ((symbol-function 'tmux-control--message) #'ignore)
                ((symbol-function 'force-mode-line-update) #'ignore))
        (dolist (n '(0 1 3 10))
          (setq tmux-control--auto-reconnect-attempts n)
          (tmux-control--schedule-auto-reconnect (current-buffer)))
        (should (equal (nreverse delays) '(2 4 16 30)))))))

(ert-deftest tmux-control-test-auto-reconnect-now-readvances-count ()
  ;; The connect resets the buffer's locals (kill-all-local-variables); the
  ;; attempt count must be re-applied afterwards so a still-failing link
  ;; advances toward the cap instead of looping at zero.
  (with-temp-buffer
    (setq-local tmux-control--host nil tmux-control--socket-name "s"
                tmux-control--session "x" tmux-control--process nil
                tmux-control--auto-reconnect-attempts 2
                tmux-control--auto-reconnect-timer nil)
    (let ((buf (current-buffer)))
      (cl-letf (((symbol-function 'tmux-control-connect)
                 (lambda (&rest _)
                   (with-current-buffer buf
                     (setq tmux-control--auto-reconnect-attempts 0))))) ; connect "resets"
        (tmux-control--auto-reconnect-now buf)
        (should (= tmux-control--auto-reconnect-attempts 3))))))

(ert-deftest tmux-control-test-cancel-auto-reconnect-resets ()
  (with-temp-buffer
    (setq-local tmux-control--auto-reconnect-attempts 4
                tmux-control--auto-reconnect-timer nil)
    (tmux-control--cancel-auto-reconnect)
    (should (= tmux-control--auto-reconnect-attempts 0))
    (should (null tmux-control--auto-reconnect-timer))))

(ert-deftest tmux-control-test-sentinel-announces-only-unexpected-death ()
  ;; An SSH drop (or killed server) must say what happened and name the
  ;; recovery key; a deliberate disconnect must stay quiet.  Before this,
  ;; the polarity was reversed: deliberate kills printed noise ("deleted")
  ;; while a real "exited abnormally with code 255" died in silence.
  (let ((fake-proc (make-symbol "proc")))
    (cl-letf (((symbol-function 'process-buffer)
               (lambda (_p) (current-buffer))))
      ;; Unexpected death: announce + point at C-c C-r.  (The message
      ;; cannot know whether the tmux session survived, so it must be
      ;; conditional, not an assertion that it is still running.)
      (with-temp-buffer
        (tmux-control-mode)
        (setq-local tmux-control--disconnecting nil
                    tmux-control--process fake-proc)
        (tmux-control--sentinel fake-proc "exited abnormally with code 255\n")
        (should (string-match-p "connection lost" (buffer-string)))
        (should (string-match-p "C-c C-r" (buffer-string)))
        (should (string-match-p "if the tmux session is still running"
                                (buffer-string)))
        (should-not tmux-control--process))
      ;; Deliberate disconnect: quiet.
      (with-temp-buffer
        (tmux-control-mode)
        (setq-local tmux-control--disconnecting t
                    tmux-control--process fake-proc)
        (tmux-control--sentinel fake-proc "killed\n")
        (should-not (string-match-p "connection lost" (buffer-string)))
        ;; The flag is consumed: a LATER unexpected death still announces.
        (should-not tmux-control--disconnecting)))))

(ert-deftest tmux-control-test-sentinel-ignores-stale-process ()
  ;; The sentinel runs deferred, so a dead process's sentinel can fire
  ;; AFTER a quick reconnect installed a fresh process in the buffer.
  ;; It must not nil out the new process or announce a loss over a live
  ;; session -- only the buffer's current process reports its own death.
  (let ((old-proc (make-symbol "old-proc"))
        (new-proc (make-symbol "new-proc")))
    (cl-letf (((symbol-function 'process-buffer)
               (lambda (_p) (current-buffer))))
      (with-temp-buffer
        (tmux-control-mode)
        (setq-local tmux-control--process new-proc)
        (tmux-control--sentinel old-proc "exited abnormally with code 255\n")
        (should (eq tmux-control--process new-proc))
        (should-not (string-match-p "connection lost" (buffer-string)))))))

(ert-deftest tmux-control-test-dead-connection-typing-offers-reconnect ()
  ;; Keystrokes against a dead connection are the natural recovery
  ;; gesture; they must offer to reconnect instead of vanishing.
  (let ((offered nil) (reconnected nil))
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_prompt) (setq offered t) t))
              ((symbol-function 'tmux-control-reconnect)
               (lambda () (setq reconnected t))))
      (with-temp-buffer
        (tmux-control-mode)
        (setq-local tmux-control--session "dev"
                    tmux-control--process nil)
        (tmux-control--send-input nil "x")
        (should offered)
        (should reconnected)))))

(ert-deftest tmux-control-test-pane-changed-foreign-window-leaves-buffer-alone ()
  ;; %window-pane-changed for an UNVISITED other window (no render buffer
  ;; yet) must not retarget this buffer.  tmux-control-new-window emits
  ;; this for the created window BEFORE the %session-window-changed that
  ;; builds its buffer; adopting that pane aimed the controller at a
  ;; foreign pane, and when the window later closed (an agent's task
  ;; window) the controller was stranded on a DEAD pane -- empty screen,
  ;; keystrokes into "can't find pane" -- and window switches did not
  ;; heal it (chaos-soak find).
  (let ((seeded 0) (map-refreshed 0))
    (cl-letf (((symbol-function 'tmux-control--seed-screen)
               (lambda () (cl-incf seeded)))
              ((symbol-function 'tmux-control--refresh-alt-screen-option)
               #'ignore)
              ((symbol-function 'tmux-control--refresh-pane-size) #'ignore)
              ((symbol-function 'tmux-control--refresh-pane-window-map)
               (lambda () (cl-incf map-refreshed))))
      (with-temp-buffer
        (tmux-control-mode)
        (let ((tmux-control-window-buffers t))
          (setq-local tmux-control--window-id "@2"
                      tmux-control--active-pane "%2"
                      tmux-control--window-buffers nil
                      tmux-control--collecting-command nil)
          ;; Foreign window @7: pane stays ours, map refreshed, no reseed.
          (tmux-control--handle-line "%window-pane-changed @7 %9")
          (should (equal tmux-control--active-pane "%2"))
          (should (= seeded 0))
          (should (= map-refreshed 1))
          ;; Our own window @2: follow the pane change.
          (tmux-control--handle-line "%window-pane-changed @2 %5")
          (should (equal tmux-control--active-pane "%5"))
          (should (= seeded 1)))))))

(ert-deftest tmux-control-test-pane-changed-legacy-mode-follows-unconditionally ()
  ;; With per-window buffers OFF the single view mirrors the session and
  ;; has always followed %window-pane-changed unconditionally -- a
  ;; load-bearing affordance (it is how cross-window select-pane jumps
  ;; worked); the foreign-window guard must not change it.
  (let ((seeded 0))
    (cl-letf (((symbol-function 'tmux-control--seed-screen)
               (lambda () (cl-incf seeded)))
              ((symbol-function 'tmux-control--refresh-alt-screen-option)
               #'ignore)
              ((symbol-function 'tmux-control--refresh-pane-size) #'ignore))
      (with-temp-buffer
        (tmux-control-mode)
        (let ((tmux-control-window-buffers nil))
          (setq-local tmux-control--window-id "@2"
                      tmux-control--active-pane "%2"
                      tmux-control--collecting-command nil)
          (tmux-control--handle-line "%window-pane-changed @7 %9")
          (should (equal tmux-control--active-pane "%9"))
          (should (= seeded 1)))))))

(ert-deftest tmux-control-test-new-and-kill-window-skip-pane-requery-when-gated ()
  ;; With per-window buffers the echoed %session-window-changed swaps the
  ;; display; re-querying the active pane would aim THIS buffer at the
  ;; new window's pane while it still renders its own window -- the same
  ;; foreign-pane corruption, through the :pane-id reply.  The window
  ;; switch commands already gate this; new-window and kill-window must
  ;; too.
  (let ((requeried 0) (quieted 0) (sent '()))
    (cl-letf (((symbol-function 'tmux-control--refresh-active-pane)
               (lambda (&optional _self) (cl-incf requeried)))
              ((symbol-function 'tmux-control--quiet-activity)
               (lambda (&optional _secs) (cl-incf quieted)))
              ((symbol-function 'tmux-control--ensure-live) #'ignore)
              ((symbol-function 'tmux-control--send-command)
               (lambda (cmd &optional _kind) (push cmd sent)))
              ((symbol-function 'yes-or-no-p) (lambda (_) t)))
      (with-temp-buffer
        (tmux-control-mode)
        (setq-local tmux-control--session "s")
        (let ((tmux-control-window-buffers t))
          (tmux-control-new-window "agent")
          (tmux-control-kill-window "3")
          (should (= requeried 0))
          (should (= quieted 2)))
        (let ((tmux-control-window-buffers nil))
          (tmux-control-new-window "agent")
          (tmux-control-kill-window "3")
          (should (= requeried 2)))
        (should (cl-some (lambda (c) (string-prefix-p "new-window" c)) sent))
        (should (cl-some (lambda (c) (string-prefix-p "kill-window" c)) sent))))))

(ert-deftest tmux-control-test-eat-cursor-xy-reads-terminal-cursor ()
  ;; The drift detector compares tmux's 0-indexed #{cursor_x},#{cursor_y}
  ;; with Eat's own cursor; the accessor must convert Eat's 1-indexed
  ;; coordinates.
  (with-temp-buffer
    (tmux-control-mode)
    (setq tmux-control--terminal (eat-term-make (current-buffer) (point-min)))
    (eat-term-resize tmux-control--terminal 40 10)
    (let ((inhibit-read-only t))
      (eat-term-process-output tmux-control--terminal "ab")
      (eat-term-redisplay tmux-control--terminal))
    (should (equal (tmux-control--eat-cursor-xy) '(2 . 0)))
    (let ((inhibit-read-only t))
      (eat-term-process-output tmux-control--terminal "\r\ncd")
      (eat-term-redisplay tmux-control--terminal))
    (should (equal (tmux-control--eat-cursor-xy) '(2 . 1)))
    (eat-term-delete tmux-control--terminal)))

(ert-deftest tmux-control-test-verify-seed-reseeds-on-drift-bounded ()
  ;; A seed's cursor query and capture are separate reply blocks; %output
  ;; interleaved between them leaves the seeded baseline shifted -- one
  ;; row off, FOREVER, since deltas preserve relative consistency (chaos
  ;; soak find: a screen identical to the pane's but shifted one row,
  ;; stable for minutes).  After each seed the verifier compares tmux's
  ;; cursor with Eat's; drift triggers a bounded reseed, agreement resets
  ;; the budget.
  (let ((reseeds 0) (queries '()) (fresh "5,3") (mine '(5 . 3)))
    (cl-letf (((symbol-function 'tmux-control--query)
               (lambda (cmd cb) (push cmd queries) (funcall cb (list fresh))))
              ((symbol-function 'tmux-control--eat-cursor-xy)
               (lambda () mine)))
      (with-temp-buffer
        (tmux-control-mode)
        (setq-local tmux-control--active-pane "%7"
                    tmux-control--seed-verify-retries 0)
        ;; Agreement: no reseed, budget reset.
        (tmux-control--verify-seed (current-buffer)
                                   (lambda () (cl-incf reseeds)))
        (should (= reseeds 0))
        (should (= tmux-control--seed-verify-retries 0))
        (should (string-match-p "cursor_x.*cursor_y" (car queries)))
        ;; Drift: reseed, budget consumed.
        (setq mine '(5 . 2))
        (tmux-control--verify-seed (current-buffer)
                                   (lambda () (cl-incf reseeds)))
        (should (= reseeds 1))
        (should (= tmux-control--seed-verify-retries 1))
        ;; Drift persists: second (last) retry...
        (tmux-control--verify-seed (current-buffer)
                                   (lambda () (cl-incf reseeds)))
        (should (= reseeds 2))
        ;; ...then the budget is exhausted: no further reseed, reset.
        (tmux-control--verify-seed (current-buffer)
                                   (lambda () (cl-incf reseeds)))
        (should (= reseeds 2))
        (should (= tmux-control--seed-verify-retries 0))
        ;; Pane switched between issue and reply: not judged.  Defer the
        ;; reply so the switch can happen in between, as it would live.
        (let ((pending nil))
          (cl-letf (((symbol-function 'tmux-control--query)
                     (lambda (_cmd cb) (setq pending cb))))
            (tmux-control--verify-seed (current-buffer)
                                       (lambda () (cl-incf reseeds))))
          (setq tmux-control--active-pane "%9")
          (funcall pending (list fresh))
          (should (= reseeds 2)))))))

(ert-deftest tmux-control-test-seed-screen-issues-verification ()
  ;; Every controller seed is followed by the drift-check query.
  (let ((sent '()) (verified '()))
    (cl-letf (((symbol-function 'tmux-control--send-command)
               (lambda (cmd &optional kind) (push (cons kind cmd) sent)))
              ((symbol-function 'tmux-control--verify-seed)
               (lambda (buf _reseed) (push buf verified))))
      (with-temp-buffer
        (tmux-control-mode)
        (setq-local tmux-control--active-pane "%3")
        (tmux-control--seed-screen)
        (should (equal (mapcar #'car (nreverse sent))
                       '(:cursor-pos :capture)))
        (should (equal verified (list (current-buffer))))))))

(ert-deftest tmux-control-test-rtrim-screen-lines ()
  ;; Trailing blank lines drop; LEADING blanks are kept, so a one-row
  ;; downward scroll drift (an extra leading blank) is not normalized away.
  (should (equal (tmux-control--rtrim-screen-lines '("a  " "b" "" "  "))
                 '("a" "b")))
  (should (equal (tmux-control--rtrim-screen-lines '("" "a" "b"))
                 '("" "a" "b")))
  (should (equal (tmux-control--rtrim-screen-lines '("" "")) '())))

(ert-deftest tmux-control-test-heal-if-drifted ()
  ;; The drift heal reseeds ONLY when the rendered screen no longer matches
  ;; tmux's capture -- a match must not reseed (no needless flicker).
  (let ((reseeded 0))
    (cl-letf (((symbol-function 'tmux-control--query)
               (lambda (_cmd cb) (funcall cb '("a" "b"))))
              ((symbol-function 'tmux-control--seed-screen)
               (lambda () (cl-incf reseeded)))
              ((symbol-function 'tmux-control--wb-controller)
               (lambda () (current-buffer))))
      (with-temp-buffer
        (setq-local tmux-control--active-pane "%0")
        (cl-letf (((symbol-function 'tmux-control--visible-screen-lines)
                   (lambda (_b) '("a" "b"))))      ; matches capture
          (tmux-control--heal-if-drifted (current-buffer))
          (should (= reseeded 0)))
        (cl-letf (((symbol-function 'tmux-control--visible-screen-lines)
                   (lambda (_b) '("a" "STALE"))))  ; drifted
          (tmux-control--heal-if-drifted (current-buffer))
          (should (= reseeded 1)))))))

(ert-deftest tmux-control-test-maybe-heal-drift-gating ()
  ;; The idle check no-ops when the feature is off, when nothing changed
  ;; since the last check, and when the command queue is not drained; it
  ;; clears the dirty flag when it does run.
  (let ((healed 0))
    (cl-letf (((symbol-function 'tmux-control--heal-if-drifted)
               (lambda (_b) (cl-incf healed)))
              ((symbol-function 'tmux-control--alt-screen-p) (lambda () nil))
              ((symbol-function 'tmux-control--wb-controller)
               (lambda () (current-buffer))))
      (with-temp-buffer
        (cl-letf (((symbol-function 'tmux-control--displayed-render-buffers)
                   (let ((b (current-buffer))) (lambda () (list b)))))
          (setq-local tmux-control--render-dirty t
                      tmux-control--command-queue nil
                      tmux-control--collecting-command nil)
          (let ((tmux-control-auto-heal-drift nil)) ; off -> no heal
            (tmux-control--maybe-heal-drift)
            (should (= healed 0)))
          (let ((tmux-control-auto-heal-drift t))   ; on, dirty, drained -> heal
            (tmux-control--maybe-heal-drift)
            (should (= healed 1))
            (should-not tmux-control--render-dirty) ; cleared
            (tmux-control--maybe-heal-drift)        ; not dirty -> no repeat
            (should (= healed 1))
            (setq-local tmux-control--render-dirty t ; dirty but queue busy
                        tmux-control--command-queue '((:x . "cmd")))
            (tmux-control--maybe-heal-drift)
            (should (= healed 1))))))))

(ert-deftest tmux-control-test-controller-window-close-goes-homeless ()
  ;; When the CONTROLLER's own window closes (an agent's task window it
  ;; was homed on), the buffer survives -- it owns the process -- but its
  ;; window id and active pane are dead.  It must mark itself homeless
  ;; (id and pane nil, registry entry gone) instead of rendering a frozen
  ;; screen and sending keystrokes into "can't find pane" forever.
  (cl-letf (((symbol-function 'tmux-control--refresh-windows) #'ignore)
            ((symbol-function 'tmux-control--refresh-pane-window-map)
             #'ignore))
    (with-temp-buffer
      (tmux-control-mode)
      (let ((tmux-control-window-buffers t))
        (setq-local tmux-control--window-id "@2"
                    tmux-control--active-pane "%2"
                    tmux-control--collecting-command nil
                    tmux-control--window-buffers
                    (list (cons "@2" (current-buffer))))
        ;; Another window closing leaves the controller homed.
        (tmux-control--handle-line "%window-close @7")
        (should (equal tmux-control--window-id "@2"))
        ;; Its own window closing makes it homeless.
        (tmux-control--handle-line "%window-close @2")
        (should-not tmux-control--window-id)
        (should-not tmux-control--active-pane)
        (should tmux-control--homeless)
        (should-not (assoc "@2" tmux-control--window-buffers))
        ;; CRITICAL: the window-list refresh must NOT re-claim the
        ;; session's current window for a homeless controller.  That
        ;; binding exists for connect time only -- re-firing it here
        ;; orphaned the current window's render buffer from the
        ;; registry, routed its output to the hidden controller, and
        ;; froze the visible buffer (chaos-soak find: the same
        ;; split-brain twice, through two different re-homing paths).
        (tmux-control--update-windows '("5\tlive\t1\t0\t@9"))
        (should-not tmux-control--window-id)
        (should-not (assoc "@9" tmux-control--window-buffers))
        ;; Nor may the first arriving %output bootstrap a pane into it
        ;; (that exists for connect time, before :pane-id lands)...
        (tmux-control--batch-pane-output "%9" "stray")
        (should-not tmux-control--active-pane)
        (should-not tmux-control--output-batch)
        ;; ...nor a %window-pane-changed re-aim it -- every window's
        ;; pane event is foreign to a buffer that owns no window.
        (cl-letf (((symbol-function 'tmux-control--seed-screen)
                   (lambda () (error "homeless controller reseeded")))
                  ((symbol-function 'tmux-control--refresh-pane-window-map)
                   #'ignore))
          (tmux-control--handle-line "%window-pane-changed @9 %9"))
        (should-not tmux-control--active-pane)))))

(ert-deftest tmux-control-test-homeless-controller-drops-input-fallback ()
  ;; With the active pane nil, input and paste normally fall back to the
  ;; session target -- a connect-time affordance.  A HOMELESS controller
  ;; must not: it would silently drive the session's current pane (which
  ;; the user watches through a DIFFERENT buffer) from a frozen view.
  (let ((sent '()))
    (cl-letf (((symbol-function 'tmux-control--send-command)
               (lambda (cmd &optional _kind) (push cmd sent)))
              ((symbol-function 'tmux-control--message) #'ignore)
              ((symbol-function 'process-live-p) (lambda (_) t)))
      (with-temp-buffer
        (tmux-control-mode)
        (setq-local tmux-control--session "s"
                    tmux-control--process (make-symbol "proc")
                    tmux-control--active-pane nil
                    tmux-control--fallback-target "s:"
                    tmux-control--homeless t)
        (tmux-control--send-input nil "x")
        (tmux-control--paste-to-pane "clip")
        (should (null sent))
        ;; The connect-time fallback (NOT homeless) still works.
        (setq tmux-control--homeless nil)
        (tmux-control--send-input nil "x")
        (should (cl-some (lambda (c) (string-match-p "send-keys -t \"s\":" c))
                         sent))))))

(ert-deftest tmux-control-test-homeless-controller-stays-out-of-routing ()
  ;; A homeless controller does NOT adopt windows: a first cut that
  ;; re-registered the controller under the next displayed window id
  ;; created a SPLIT-BRAIN under churn -- two buffers claiming one
  ;; window, output routed to the hidden one, the displayed one frozen
  ;; (chaos-soak find).  The invariant is one window, one buffer: a
  ;; switch while the controller is homeless builds an ordinary render
  ;; buffer, and the controller keeps owning only the process.
  (let ((made 0))
    (cl-letf (((symbol-function 'tmux-control--make-window-buffer)
               (lambda (&rest _) (cl-incf made)
                 (generate-new-buffer " *tc-made*")))
              ((symbol-function 'tmux-control--seed-window-buffer) #'ignore)
              ((symbol-function 'tmux-control--resize-to-window) #'ignore))
      (with-temp-buffer
        (tmux-control-mode)
        (setq-local tmux-control--window-id nil
                    tmux-control--active-pane nil
                    tmux-control--window-buffers nil
                    tmux-control--session-display nil)
        (let ((new (tmux-control--display-window-buffer "@9")))
          (unwind-protect
              (progn
                ;; A fresh render buffer, not the controller.
                (should-not (eq new (current-buffer)))
                (should (= made 1))
                ;; The controller stays homeless and unregistered.
                (should-not tmux-control--window-id)
                (should-not (cl-rassoc (current-buffer)
                                       tmux-control--window-buffers)))
            (when (buffer-live-p new) (kill-buffer new))))))))

(ert-deftest tmux-control-test-wheel-down-forwards-to-mouse-app ()
  ;; Symmetry with wheel-up: a full-screen or mouse-tracking app must get
  ;; wheel-DOWN forwarded to it, not have it fall through to ordinary
  ;; scrolling.  Found in a config-loaded buffer: wheel-up scrolled vim
  ;; but wheel-down hit pixel-scroll-precision and scrolled the Emacs
  ;; buffer instead (vim never moved).  Bound in the high-precedence
  ;; maps so it beats a global wheel minor mode (pixel-scroll).
  (should (eq (lookup-key tmux-control--override-map [wheel-down])
              #'tmux-control-wheel-down))
  (should (eq (lookup-key tmux-control--char-mode-map [wheel-down])
              #'tmux-control-wheel-down))
  (let ((forwarded 0) (scrolled 0)
        (event (list 'wheel-down (list (selected-window) 1 '(0 . 0) 0))))
    (cl-letf (((symbol-function 'eat-self-input)
               (lambda (&rest _) (cl-incf forwarded)))
              ((symbol-function 'tmux-control--dispatch-wheel)
               (lambda (_) (cl-incf scrolled)))
              ((symbol-function 'posn-window) (lambda (_) (selected-window))))
      (save-window-excursion
        (with-temp-buffer
          (tmux-control-mode)
          (set-window-buffer (selected-window) (current-buffer))
          ;; Mouse-grabbing (or alt-screen) app: forward to the app.
          (cl-letf (((symbol-function 'tmux-control--alt-screen-p)
                     (lambda () nil))
                    ((symbol-function 'tmux-control--pane-grabs-mouse-p)
                     (lambda () t)))
            (tmux-control-wheel-down event)
            (should (= forwarded 1))
            (should (= scrolled 0)))
          ;; Plain normal-screen pane: ordinary scrolling, not forwarded.
          (cl-letf (((symbol-function 'tmux-control--alt-screen-p)
                     (lambda () nil))
                    ((symbol-function 'tmux-control--pane-grabs-mouse-p)
                     (lambda () nil)))
            (tmux-control-wheel-down event)
            (should (= forwarded 1))
            (should (= scrolled 1))))))))

(ert-deftest tmux-control-test-wheel-scrolls-live-history-routing ()
  ;; `tmux-control-wheel-scrolls-live-history' off: wheel-up over a
  ;; normal-screen pane opens the pager immediately (legacy behavior).  On:
  ;; while there is retained history to scroll into (or you have scrolled up
  ;; into it) wheel-up scrolls the live view in place; only when the whole
  ;; retained history already fits on screen -- so you are still at the live
  ;; screen and cannot scroll -- does it open the pager.  Crucially, being
  ;; scrolled up (not exhausted) never flings to the pager.
  (let ((scrolled 0) (pager 0) (exhausted nil)
        (event (list 'wheel-up (list (selected-window) 1 '(0 . 0) 0))))
    (cl-letf (((symbol-function 'tmux-control--wheel-should-enter-scrollback-p)
               (lambda (&rest _) t))
              ((symbol-function 'tmux-control--live-history-exhausted-p)
               (lambda (_w) exhausted))
              ((symbol-function 'tmux-control--scroll-live-history)
               (lambda (_e _w) (cl-incf scrolled)))
              ((symbol-function 'tmux-control-scrollback)
               (lambda () (cl-incf pager)))
              ((symbol-function 'posn-window) (lambda (_) (selected-window))))
      (save-window-excursion
        (with-temp-buffer
          (tmux-control-mode)
          (set-window-buffer (selected-window) (current-buffer))
          ;; OFF: pager immediately, no live-history scroll.
          (let ((tmux-control-wheel-scrolls-live-history nil))
            (tmux-control-wheel-scroll event)
            (should (= pager 1))
            (should (= scrolled 0)))
          ;; ON, history available / scrolled up (not exhausted): scroll in
          ;; place, never the pager -- no fling back to the live tail.
          (setq exhausted nil)
          (let ((tmux-control-wheel-scrolls-live-history t))
            (tmux-control-wheel-scroll event)
            (should (= scrolled 1))
            (should (= pager 1)))
          ;; ON, whole retained history on screen (at the live screen, cannot
          ;; scroll): open the pager -- seamless from the live tail.
          (setq exhausted t)
          (let ((tmux-control-wheel-scrolls-live-history t))
            (tmux-control-wheel-scroll event)
            (should (= pager 2))
            (should (= scrolled 1)))
          ;; ON but TILED: the feature is scoped out -- tiled panes keep the
          ;; plain pager-on-wheel-up, never the in-place live-history scroll.
          (setq exhausted nil)
          (cl-letf (((symbol-function 'tmux-control--tiled-mode-p)
                     (lambda () t)))
            (let ((tmux-control-wheel-scrolls-live-history t))
              (tmux-control-wheel-scroll event)
              (should (= pager 3))
              (should (= scrolled 1)))))))))

(ert-deftest tmux-control-test-sync-windows-holds-scrolled-away ()
  ;; The scroll-follow set.  With live-history scrolling ON it is keyed on
  ;; cursor visibility: a window showing the live cursor follows (win-a), one
  ;; scrolled away does not (win-b) -- so a scrolled-up reader holds and a
  ;; scrolled-back-down one resumes, regardless of where point sits.  Eat's
  ;; `buffer' point decision is preserved.  With it OFF, the set is exactly
  ;; what Eat reports -- byte-identical legacy behavior.
  (cl-letf (((symbol-function 'eat--synchronize-scroll-windows)
             (lambda (&rest _) (list 'buffer 'win-a 'win-b)))
            ((symbol-function 'eat-term-live-p) (lambda (_) t))
            ((symbol-function 'eat-term-display-cursor) (lambda (_) 42))
            ((symbol-function 'get-buffer-window-list)
             (lambda (&rest _) (list 'win-a 'win-b)))
            ;; The live cursor is visible only in win-a (accepts the PARTIALLY
            ;; arg the follow-set check now passes).
            ((symbol-function 'pos-visible-in-window-p)
             (lambda (_pos w &optional _partially) (eq w 'win-a))))
    (let ((tmux-control--terminal 'term))
      (let ((tmux-control-wheel-scrolls-live-history nil))
        (should (equal (tmux-control--current-sync-windows)
                       '(buffer win-a win-b))))
      ;; ON: keep `buffer' (point) + only the window showing the cursor.
      (let ((tmux-control-wheel-scrolls-live-history t))
        (should (equal (tmux-control--current-sync-windows)
                       '(buffer win-a))))
      ;; ON but TILED: scoped out -- the tiling layer anchors its own panes,
      ;; so the follow set stays exactly Eat's own list.
      (cl-letf (((symbol-function 'tmux-control--tiled-mode-p) (lambda () t)))
        (let ((tmux-control-wheel-scrolls-live-history t))
          (should (equal (tmux-control--current-sync-windows)
                         '(buffer win-a win-b))))))))

(defvar tmux-control-test--audit-modal nil
  "Stands in for a modal minor mode in the key-audit test.")

(ert-deftest tmux-control-test-audit-keys ()
  ;; The audit reports, for each tmux-control binding, whether it actually
  ;; resolves to its command in this buffer -- the institutionalized
  ;; version of the manual check that caught the ESC regression.  It must
  ;; (1) cover tmux-control's own bindings, (2) EXCLUDE bindings inherited
  ;; from eat-mode-map (the parent -- `map-keymap' descends into it), and
  ;; (3) flag a binding a higher-precedence config map overrides.
  (should-error (with-temp-buffer (fundamental-mode) (tmux-control-audit-keys))
                :type 'user-error)
  (let ((modal-map (let ((m (make-sparse-keymap)))
                     (define-key m [escape] (lambda () (interactive) 'modal))
                     m)))
    (with-temp-buffer
      (tmux-control-mode)
      (setq-local emulation-mode-map-alists
                  (cons tmux-control--emulation-mode-map-alist
                        emulation-mode-map-alists))
      (setq tmux-control--keys-active t)
      (let* ((rows (tmux-control--audit-rows))
             (nextwin (assoc "C-c C-n" rows))
             (escape (assoc "<escape>" rows)))
        ;; (1) own bindings present and active.
        (should nextwin)
        (should (eq (nth 1 nextwin) 'tmux-control-next-window))
        (should (eq (nth 3 nextwin) 'active))
        ;; (2) every intended command is tmux-control's own -- if the
        ;; eat-mode-map parent leaked in, some intended would be eat-*.
        (should (cl-every (lambda (r)
                            (string-prefix-p "tmux-control-"
                                             (symbol-name (nth 1 r))))
                          rows))
        ;; ESC is tmux-control's intended command, active when unclaimed.
        (should (eq (nth 1 escape) 'tmux-control-send-escape))
        (should (eq (nth 3 escape) 'active))
        ;; (3) a modal minor-mode ESC binding flips ESC to overridden --
        ;; exactly the relationship that lets xah-fly-keys keep command
        ;; mode (and that, reversed, was the regression).
        (let ((minor-mode-map-alist
               (cons (cons 'tmux-control-test--audit-modal modal-map)
                     minor-mode-map-alist)))
          (setq tmux-control-test--audit-modal t)
          (let ((escape2 (assoc "<escape>" (tmux-control--audit-rows))))
            (should (eq (nth 3 escape2) 'overridden))))))))

(ert-deftest tmux-control-test-kill-render-buffers-by-name ()
  ;; A reconnect must sweep stale render buffers even when the registry
  ;; has drifted out of sync -- so the sweep is by NAME, not the
  ;; registry.  Chaos-soak find: after visiting a window then
  ;; reconnecting, that window's render buffer survived holding the dead
  ;; process, and every key on it errored "process is not live".
  (let* ((ctrl (generate-new-buffer "*tmux-control:local:cs*"))
         (r0 (generate-new-buffer "*tmux-control:local:cs:@0*"))
         (r7 (generate-new-buffer "*tmux-control:local:cs:@7*"))
         ;; A pane (tiling) buffer uses ":%", and another session's
         ;; render buffer has a different controller name -- neither is
         ;; ours; both must survive.
         (pane (generate-new-buffer "*tmux-control:local:cs:%2*"))
         (other (generate-new-buffer "*tmux-control:local:other:@0*")))
    (unwind-protect
        (progn
          (tmux-control--kill-render-buffers ctrl)
          (should (buffer-live-p ctrl))      ; never kills the controller
          (should-not (buffer-live-p r0))    ; @-render buffers swept
          (should-not (buffer-live-p r7))
          (should (buffer-live-p pane))      ; :% pane buffer untouched
          (should (buffer-live-p other)))    ; other session untouched
      (dolist (b (list ctrl r0 r7 pane other))
        (when (buffer-live-p b)
          (let ((kill-buffer-query-functions nil)) (kill-buffer b)))))))

(ert-deftest tmux-control-test-scrollback-cancel-resize-timer ()
  ;; A pager killed within its resize-debounce window must not leak the timer.
  (with-temp-buffer
    (setq-local tmux-control--scrollback-resize-timer
                (run-with-timer 100 nil #'ignore))
    (let ((tm tmux-control--scrollback-resize-timer))
      (should (memq tm timer-list))
      (tmux-control--scrollback-cancel-resize-timer)
      (should-not (memq tm timer-list))
      (should (null tmux-control--scrollback-resize-timer)))))

(ert-deftest tmux-control-test-kill-process-cancels-retile-timer ()
  ;; Killing a tiled controller must cancel its pending re-tile timer -- it
  ;; lives on the global timer-list holding the dead controller, exactly like
  ;; the command watchdog the function already cancels.
  (with-temp-buffer
    (let ((tm (run-with-timer 100 nil #'ignore)))
      (setq-local tmux-control--retile-timer tm
                  tmux-control--tiled t
                  tmux-control--panes nil
                  tmux-control--window-buffers nil
                  tmux-control--process nil
                  tmux-control--command-watchdog-timer nil)
      (tmux-control--kill-process)
      (should-not (memq tm timer-list))
      (should (null tmux-control--retile-timer)))))

(provide 'tmux-control-test)
;;; tmux-control-test.el ends here
