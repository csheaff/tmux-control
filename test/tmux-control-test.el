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

(provide 'tmux-control-test)
;;; tmux-control-test.el ends here
