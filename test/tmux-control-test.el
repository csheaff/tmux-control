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
  ;; Reverse-order/padded reply lists and surrounding whitespace are tolerated.
  (should (equal '(7 . 3) (tmux-control--parse-cursor-pos '("" "  7,3 " ""))))
  ;; Malformed or empty replies yield nil rather than a bogus position.
  (should-not (tmux-control--parse-cursor-pos '("42 2")))
  (should-not (tmux-control--parse-cursor-pos '("nope")))
  (should-not (tmux-control--parse-cursor-pos '("")))
  (should-not (tmux-control--parse-cursor-pos nil)))

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
             (tmux-control--screen-seed-sequence "x\n" '(200 . 100))))))

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
                  'tmux-control-tab-activity)))
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

(provide 'tmux-control-test)
;;; tmux-control-test.el ends here
