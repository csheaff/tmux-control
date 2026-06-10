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
  (cl-letf (((symbol-function 'tmux-control--call)
             (lambda (&rest _)
               (concat "%0\t0\t1\tbash\tclays-mbp\n"
                       "%3\t1\t0\tnode\tcoder\n"
                       "%2\t2\t0\tnode\tnode\n"
                       "garbage-line"))))
    (should (equal (tmux-control--list-panes nil "main" "emacs")
                   ;; index: command (title-when-distinct) [active]
                   '(("%0" . "0: bash (clays-mbp) [active]")
                     ("%3" . "1: node (coder)")
                     ;; title == command -> no redundant "(node)"
                     ("%2" . "2: node"))))))

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
    (puthash "%0" "0" tmux-control--pane-window)
    (puthash "%1" "1" tmux-control--pane-window)
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
  ;; the yank commands to the terminal yank.
  (should (eq (lookup-key tmux-control-mode-map [remap yank]) 'eat-yank))
  (should (eq (lookup-key tmux-control-mode-map [remap clipboard-yank]) 'eat-yank))
  (should (eq (lookup-key tmux-control-mode-map [remap yank-pop])
              'eat-yank-from-kill-ring)))

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
    (let ((reseeds 0) (refreshes 0))
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

(ert-deftest tmux-control-test-session-strip-lists-others-and-clears-self ()
  ;; The strip names other flagged sessions (not unflagged ones, not self) and
  ;; clears the current session's own flag (you are looking at it).
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
                     (strip (tmux-control--session-strip)))
                (should (string-match-p "other" strip))   ; flagged other listed
                (should-not (string-match-p "quiet" strip)) ; unflagged omitted
                (should-not (string-match-p "self" strip))  ; self omitted
                (should-not tmux-control--session-activity)))))   ; self-cleared
      (kill-buffer self) (kill-buffer other) (kill-buffer quiet))))

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
  "`tmux-control--tiled-region-size' is the whole frame with no foreign window
\(the old size, so a frame-owning tiling is unchanged), and fewer columns at
the same rows once a full-height foreign window shares the frame."
  (let ((ctrl-buf (generate-new-buffer " tc-test-ctrl"))
        (foreign-buf (generate-new-buffer " tc-test-foreign")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let* ((frame (selected-frame))
                 (cw (selected-window)))
            (set-window-buffer cw ctrl-buf)
            (let ((whole (tmux-control--tiled-region-size frame ctrl-buf)))
              (should (= (car whole) (frame-text-cols frame)))
              (should (= (cdr whole) (1- (frame-text-lines frame))))
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

(ert-deftest tmux-control-test-scrollback-capture-command ()
  (let ((tmux-control-scrollback-join-wrapped-lines nil))
    (should (equal (tmux-control--scrollback-capture-command "%5" 10000 nil)
                   "capture-pane -p -e -S -10000 -t %5"))
    (should (equal (tmux-control--scrollback-capture-command nil 200 t)
                   "capture-pane -p -e -N -S -200")))
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

(provide 'tmux-control-test)
;;; tmux-control-test.el ends here
