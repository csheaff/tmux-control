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
  (should (equal (tmux-control--quote-tmux-arg "back\\slash") "\"back\\\\slash\"")))

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

;;; Input hex encoding.

(ert-deftest tmux-control-test-string-to-hex-args ()
  (should (equal (tmux-control--string-to-hex-args "") ""))
  (should (equal (tmux-control--string-to-hex-args "A") "41"))
  (should (equal (tmux-control--string-to-hex-args "AB") "41 42"))
  ;; Multibyte characters are encoded as their UTF-8 bytes.
  (should (equal (tmux-control--string-to-hex-args "é") "c3 a9")))

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
  (should (tmux-control--scrollback-frame-start-line-p "[Session] foo"))
  (should (tmux-control--scrollback-frame-start-line-p "   [Session]"))
  (should-not (tmux-control--scrollback-frame-start-line-p "x [Session]"))
  (should-not (tmux-control--scrollback-frame-start-line-p "hello")))

(ert-deftest tmux-control-test-scrollback-chrome-line-p ()
  (should (tmux-control--scrollback-chrome-line-p "[Session] x"))
  (should (tmux-control--scrollback-chrome-line-p "  AI Credits: 99"))
  (should (tmux-control--scrollback-chrome-line-p "/ commands here"))
  (should (tmux-control--scrollback-chrome-line-p "──────────"))
  (should (tmux-control--scrollback-chrome-line-p "❯"))
  (should-not (tmux-control--scrollback-chrome-line-p "regular line"))
  ;; A short rule is not chrome.
  (should-not (tmux-control--scrollback-chrome-line-p "─────")))

(ert-deftest tmux-control-test-scrollback-chunks ()
  (should (equal (tmux-control--scrollback-chunks
                  "[Session] a\nb\n[Session] c\nd")
                 '(("[Session] a" "b") ("[Session] c" "d"))))
  ;; Trailing whitespace on each line is trimmed.
  (should (equal (tmux-control--scrollback-chunks "a  \nb\t")
                 '(("a" "b")))))

;;; The full compaction pipeline.

(ert-deftest tmux-control-test-compact-repeated-redraw-lines-dedups ()
  (let ((tmux-control-compact-scrollback-window 300))
    ;; A frame repeated verbatim collapses to a single copy, and the
    ;; "[Session]" chrome lines are stripped.
    (should (equal (tmux-control--compact-repeated-redraw-lines
                    "[Session] x\nhello\nworld\n[Session] x\nhello\nworld")
                   "hello\nworld"))))

(ert-deftest tmux-control-test-compact-repeated-redraw-lines-keeps-distinct ()
  (let ((tmux-control-compact-scrollback-window 300))
    ;; Distinct frames are preserved, separated by a single blank line.
    (should (equal (tmux-control--compact-repeated-redraw-lines
                    "[Session] x\nalpha\nbeta\n[Session] x\ngamma\ndelta")
                   "alpha\nbeta\n\ngamma\ndelta"))))

(ert-deftest tmux-control-test-compact-strips-redrawn-body-behind-new-lines ()
  (let ((tmux-control-compact-scrollback-window 300))
    ;; A repeated full-screen panel (6+ distinctive lines) wrapped in new
    ;; volatile lines (an evolving prompt) collapses: the panel survives
    ;; once and only the genuinely new prompt line is appended.
    (should (equal (tmux-control--compact-repeated-redraw-lines
                    (concat "[Session]\nA\nB\nC\nD\nE\nF\n"
                            "[Session]\nXP\nA\nB\nC\nD\nE\nF"))
                   "A\nB\nC\nD\nE\nF\n\nXP"))))

(ert-deftest tmux-control-test-compact-keeps-short-repeats ()
  (let ((tmux-control-compact-scrollback-window 300))
    ;; Short repeated blocks (below the redraw-run threshold) are NOT
    ;; stripped, so ordinary repeated command output is never lost.
    (should (equal (tmux-control--compact-repeated-redraw-lines
                    "[Session]\nA\nB\nC\nD\n[Session]\nXP\nA\nB\nC\nD")
                   "A\nB\nC\nD\n\nXP\nA\nB\nC\nD"))))

(ert-deftest tmux-control-test-compact-respects-window-for-runs ()
  ;; A repeated body older than the recent window is not stripped: the
  ;; interior-run search only looks back `tmux-control-compact-scrollback-window'
  ;; lines.
  (let ((tmux-control-compact-scrollback-window 2))
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
         (out (tmux-control--compact-repeated-redraw-lines
               tmux-control-test--copilot-redraw)))
    (should-not (tmux-control-test--window-repeats-p out 6))
    ;; The distinctive panel survives exactly once.
    (should (= 1 (length (seq-filter (lambda (l) (equal l "  | file_eta.py"))
                                     (split-string out "\n")))))))

(ert-deftest tmux-control-test-compact-is-idempotent ()
  ;; Compacting already-compacted text changes nothing: a stable fixpoint.
  (let* ((tmux-control-compact-scrollback-window 300)
         (once (tmux-control--compact-repeated-redraw-lines
                tmux-control-test--copilot-redraw))
         (twice (tmux-control--compact-repeated-redraw-lines once)))
    (should (equal once twice))))

(ert-deftest tmux-control-test-compact-output-is-subset-of-input ()
  ;; Compaction only ever drops lines: every nonblank line in the output
  ;; must have appeared verbatim in the input, and the output is no longer
  ;; than the input.  This catches accidental duplication or fabrication.
  (let* ((tmux-control-compact-scrollback-window 300)
         (input tmux-control-test--copilot-redraw)
         (in-lines (split-string input "\n"))
         (out (tmux-control--compact-repeated-redraw-lines input))
         (out-lines (split-string out "\n")))
    (should (<= (length out-lines) (length in-lines)))
    (dolist (line out-lines)
      (unless (string-empty-p (string-trim line))
        (should (member line in-lines))))))

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

(ert-deftest tmux-control-test-alt-screen-effective-p ()
  ;; Truly on the alternate screen only when tmux honors it AND Eat reports
  ;; it.  The phantom case (Eat says alt, tmux says not honored) is nil.
  (should (eq (tmux-control--alt-screen-effective-p t t) t))
  (should (eq (tmux-control--alt-screen-effective-p t nil) nil))
  (should (eq (tmux-control--alt-screen-effective-p nil t) nil))
  (should (eq (tmux-control--alt-screen-effective-p nil nil) nil))
  ;; Always returns a normalized boolean, never a truthy non-t value.
  (should (eq (tmux-control--alt-screen-effective-p t "alt") t)))

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
  (should (equal (tmux-control-test--capture-commands
                  (lambda () (tmux-control-select-window "2")))
                 '("select-window -t 0:2"))))

(ert-deftest tmux-control-test-new-window-command ()
  (should (equal (tmux-control-test--capture-commands
                  (lambda () (tmux-control-new-window "my win")))
                 '("new-window -t 0: -n \"my win\"")))
  (should (equal (tmux-control-test--capture-commands
                  (lambda () (tmux-control-new-window nil)))
                 '("new-window -t 0:"))))

(ert-deftest tmux-control-test-kill-window-command ()
  (should (equal (tmux-control-test--capture-commands
                  (lambda () (tmux-control-kill-window "1")))
                 '("kill-window -t 0:1"))))

(ert-deftest tmux-control-test-rename-window-command ()
  (should (equal (tmux-control-test--capture-commands
                  (lambda () (tmux-control-rename-window "1" "new name")))
                 '("rename-window -t 0:1 \"new name\"")))
  ;; An empty name is rejected.
  (should-error (tmux-control-test--capture-commands
                 (lambda () (tmux-control-rename-window "1" "")))
                :type 'user-error))

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

(provide 'tmux-control-test)
;;; tmux-control-test.el ends here
