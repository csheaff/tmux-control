;;; tmux-control-integration.el --- Live integration tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Integration tests that need a real tmux server and a live Eat terminal.
;; They assert that tmux-control's render of a pane is *faithful* -- that the
;; text it paints into an Eat buffer matches tmux's own `capture-pane' for the
;; same screen -- across plain text, colors, box-drawing/UTF-8, wide lines, and
;; double-width CJK/emoji glyphs.
;;
;; These are kept separate from the pure-logic suite (test/tmux-control-test.el,
;; `make test') because they spin up a tmux server and are therefore slower and
;; environment-dependent.  Run them with:
;;
;;   make test-integration
;;
;; or directly:
;;
;;   emacs -Q --batch -L <eat-dir> -L . \
;;     -l tmux-control.el -l test/tmux-control-integration.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; Each test `skip-unless' tmux is on PATH, so it is a no-op (not a failure)
;; where tmux is unavailable.  A dedicated socket (`tc-ert-test') is used and
;; the server is killed around every test, so the developer's own tmux servers
;; are never touched.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'tmux-control)

(defconst tmux-control-it--socket "tc-ert-test"
  "Dedicated tmux socket name for the integration tests.")

(defun tmux-control-it--available-p ()
  "Return non-nil when a real tmux is usable for integration tests."
  (and (executable-find "tmux") t))

(defun tmux-control-it--tmux (&rest args)
  "Run tmux on the test socket with ARGS; return stdout or signal on failure."
  (with-temp-buffer
    (let ((code (apply #'call-process "tmux" nil t nil
                       "-L" tmux-control-it--socket args)))
      (unless (eq code 0)
        (error "tmux %S failed (%s): %s" args code (string-trim (buffer-string))))
      (buffer-string))))

(defun tmux-control-it--tmux-ok (&rest args)
  "Run tmux on the test socket with ARGS, ignoring any failure."
  (ignore-errors (apply #'tmux-control-it--tmux args)))

(defun tmux-control-it--rtrim (lines)
  "Right-trim LINES and drop trailing blank lines (the oracle's normalization)."
  (let ((ls (mapcar #'string-trim-right lines)))
    (while (and ls (string-empty-p (car (last ls))))
      (setq ls (butlast ls)))
    ls))

(defun tmux-control-it--visible-text (beg end)
  "Return buffer text BEG..END with Eat's invisible padding cells removed.
Eat models a double-width glyph (CJK, emoji, wide box-drawing) as the glyph
followed by an `invisible' padding cell standing in for its second column.
`capture-pane' emits only the glyph, so the padding must be dropped before
comparing or every wide character reads as a spurious trailing space."
  (let ((out nil) (i beg))
    (while (< i end)
      (unless (get-text-property i 'invisible)
        (push (char-after i) out))
      (setq i (1+ i)))
    (apply #'string (nreverse out))))

(defun tmux-control-it--capture-lines (pane)
  "Return tmux PANE's visible screen as normalized plain lines (ground truth)."
  (tmux-control-it--rtrim
   (split-string (tmux-control-it--tmux "capture-pane" "-p" "-t" pane) "\n")))

(defun tmux-control-it--wait-settle (pane &optional timeout)
  "Block until PANE's capture is non-blank, up to TIMEOUT (default 5) seconds."
  (let ((deadline (+ (float-time) (or timeout 5))))
    (while (and (< (float-time) deadline)
                (string-empty-p
                 (string-trim
                  (tmux-control-it--tmux "capture-pane" "-p" "-t" pane))))
      (sleep-for 0.05))))

(defun tmux-control-it--render-seed (pane width height)
  "Render PANE through tmux-control's seed pipeline into a fresh Eat buffer.
Capture the pane, build the screen-seed escape sequence, feed it to a
WIDTHxHEIGHT Eat terminal, and return the rendered visible lines (normalized
the same way as `tmux-control-it--capture-lines').  This is exactly what a
\(re)tile paints into a pane's window, so comparing the two checks render
fidelity end to end."
  (let ((buf (generate-new-buffer " *tc-it-render*")))
    (unwind-protect
        (with-current-buffer buf
          (setq-local tmux-control--host nil)
          (setq-local tmux-control--socket-name tmux-control-it--socket)
          (setq-local tmux-control--capture-trailing-p t)
          (let ((term (eat-term-make buf (point-min))))
            (setq-local tmux-control--terminal term)
            (eat-term-resize term width height)
            (let* ((text (tmux-control--capture-pane-screen pane))
                   (seq (tmux-control--screen-seed-sequence text nil)))
              (eat-term-process-output term seq)
              (eat-term-redisplay term)
              (save-excursion
                (goto-char (point-max))
                (forward-line (- (1- height)))
                (tmux-control-it--rtrim
                 (split-string (tmux-control-it--visible-text
                                (line-beginning-position) (point-max))
                               "\n"))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(defmacro tmux-control-it--with-pane (content width height &rest body)
  "Run BODY with a fresh tmux pane (WIDTH x HEIGHT) displaying CONTENT.
CONTENT is written to a temp file and `cat'-ed so the screen is static and
has no shell prompt to vary.  Binds `pane' to the pane id and `width'/`height'
to the given sizes.  Skips when tmux is unavailable and always kills the
test server afterward."
  (declare (indent 3))
  `(progn
     (skip-unless (tmux-control-it--available-p))
     ;; Pin UTF-8 for the content file write and every tmux subprocess I/O so
     ;; double-width content survives a bare `emacs -Q --batch', which sets up
     ;; no locale and would otherwise mangle multibyte output (or prompt for a
     ;; coding system on write and hang the run).
     (let ((file (make-temp-file "tc-ert-content"))
           (width ,width)
           (height ,height)
           (coding-system-for-read 'utf-8-unix)
           (coding-system-for-write 'utf-8-unix))
       (unwind-protect
           (progn
             (with-temp-file file (insert ,content))
             (tmux-control-it--tmux-ok "kill-server")
             (tmux-control-it--tmux
              "new-session" "-d" "-s" "t"
              "-x" (number-to-string width) "-y" (number-to-string height)
              (format "cat %s; sleep 600" (shell-quote-argument file)))
             (let ((pane (string-trim
                          (tmux-control-it--tmux
                           "display-message" "-p" "-t" "t" "#{pane_id}"))))
               (tmux-control-it--wait-settle pane)
               ,@body))
         (tmux-control-it--tmux-ok "kill-server")
         (ignore-errors (delete-file file))))))

;;; Seed-render faithfulness across content types.

(ert-deftest tmux-control-it-seed-plain ()
  (tmux-control-it--with-pane "alpha line\nbravo line\ncharlie line\n" 80 24
    (should (equal (tmux-control-it--render-seed pane width height)
                   (tmux-control-it--capture-lines pane)))))

(ert-deftest tmux-control-it-seed-colors ()
  ;; SGR colors render as faces, not characters, so the plain text must match.
  (tmux-control-it--with-pane
      "\e[31mred\e[0m \e[1;32mbold-green\e[0m \e[44mon-blue\e[0m\nplain tail\n"
      80 24
    (should (equal (tmux-control-it--render-seed pane width height)
                   (tmux-control-it--capture-lines pane)))))

(ert-deftest tmux-control-it-seed-box-drawing ()
  ;; UTF-8 box-drawing must survive (this is the class that regressed as octal
  ;; when multibyte characters were split across %output messages).
  (tmux-control-it--with-pane
      "┌──────────┐\n│  hello   │\n│  world   │\n└──────────┘\n" 80 24
    (should (equal (tmux-control-it--render-seed pane width height)
                   (tmux-control-it--capture-lines pane)))))

(ert-deftest tmux-control-it-seed-wide-line ()
  ;; A line filling the width should render without wrap/clip surprises.
  (tmux-control-it--with-pane
      (concat (make-string 80 ?=) "\nshort\n") 80 24
    (should (equal (tmux-control-it--render-seed pane width height)
                   (tmux-control-it--capture-lines pane)))))

(ert-deftest tmux-control-it-seed-wide-chars ()
  ;; Double-width glyphs -- CJK across Han/Hiragana/Hangul, interleaved with
  ;; ASCII, and a standalone emoji -- must render faithfully.  Eat stores each
  ;; as the glyph plus an invisible padding cell for its second column; the
  ;; extraction drops that padding so the comparison is against the same single
  ;; glyph-per-column that capture-pane reports.  (Zero-width combining marks
  ;; and ZWJ emoji are a separate matter -- Eat does not retain them -- so they
  ;; are deliberately not exercised here.)
  (tmux-control-it--with-pane
      "ABC 你好世界 こんにちは 안녕 DEF\nmix 日本語ABC混在123 end\n10 \xf0\x9f\x8e\x89 done\n"
      80 24
    (should (equal (tmux-control-it--render-seed pane width height)
                   (tmux-control-it--capture-lines pane)))))

(ert-deftest tmux-control-it-seed-many-lines ()
  ;; More content lines than fit: only the last `height' rows are the screen.
  (tmux-control-it--with-pane
      (mapconcat (lambda (i) (format "row %02d" i)) (number-sequence 1 40) "\n")
      80 24
    (should (equal (tmux-control-it--render-seed pane width height)
                   (tmux-control-it--capture-lines pane)))))

;;; Live %output streaming: the full async pipeline, not just the seed.

(defun tmux-control-it--pump (secs)
  "Run the event loop for SECS seconds so subprocess output is processed."
  (let ((deadline (+ (float-time) secs)))
    (while (< (float-time) deadline)
      (accept-process-output nil 0.05))))

(defun tmux-control-it--pump-until (secs pred)
  "Pump the event loop until PRED returns non-nil, or SECS elapse.
Return what PRED last returned (non-nil on success)."
  (let ((deadline (+ (float-time) secs)) (ok nil))
    (while (and (< (float-time) deadline)
                (not (setq ok (funcall pred))))
      (accept-process-output nil 0.05))
    ok))

(defun tmux-control-it--buffer-text (buf)
  "Return BUF's whole text without properties."
  (with-current-buffer buf
    (buffer-substring-no-properties (point-min) (point-max))))

(defun tmux-control-it--buffer-visible (buf height)
  "Return the last HEIGHT rendered rows of BUF, normalized like a capture."
  (with-current-buffer buf
    (save-excursion
      (goto-char (point-max))
      (forward-line (- (1- height)))
      (tmux-control-it--rtrim
       (split-string (tmux-control-it--visible-text
                      (line-beginning-position) (point-max))
                     "\n")))))

(ert-deftest tmux-control-it-live-stream ()
  "Output produced AFTER connecting arrives via the live %output stream and
the rendered Eat buffer converges to exactly tmux's own screen -- exercising
the full async pipeline (process filter -> batch -> Eat), not just the seed."
  (skip-unless (tmux-control-it--available-p))
  (tmux-control-it--tmux-ok "kill-server")
  (tmux-control-it--tmux "new-session" "-d" "-s" "t" "-x" "80" "-y" "24")
  (let ((buf (tmux-control-connect nil tmux-control-it--socket "t"))
        (pane (string-trim
               (tmux-control-it--tmux "display-message" "-p" "-t" "t"
                                      "#{pane_id}"))))
    (unwind-protect
        (progn
          (tmux-control-it--pump 1.5)       ; let the initial seed land
          ;; Produce NEW output; it must reach the buffer via streaming, not
          ;; the connect-time capture.
          (tmux-control-it--tmux "send-keys" "-t" "t"
                                 "printf 'STREAM_ONE\\nSTREAM_TWO\\n'" "Enter")
          (should (tmux-control-it--pump-until
                   6 (lambda ()
                       (let ((s (tmux-control-it--buffer-text buf)))
                         (and (string-match-p "STREAM_ONE" s)
                              (string-match-p "STREAM_TWO" s))))))
          ;; The render converges to tmux's screen (retry absorbs frame lag
          ;; and any async prompt redraw).
          (let ((h (string-to-number
                    (string-trim
                     (tmux-control-it--tmux "display-message" "-p" "-t" pane
                                            "#{pane_height}")))))
            (should (tmux-control-it--pump-until
                     3 (lambda ()
                         (equal (tmux-control-it--buffer-visible buf h)
                                (tmux-control-it--capture-lines pane)))))))
      (when (buffer-live-p buf)
        (with-current-buffer buf (ignore-errors (tmux-control-disconnect)))
        (kill-buffer buf))
      (tmux-control-it--tmux-ok "kill-server"))))

;;; Per-pane isolation: each pane renders its own content, not a neighbor's.

(ert-deftest tmux-control-it-two-panes-isolated ()
  (skip-unless (tmux-control-it--available-p))
  (let ((fa (make-temp-file "tc-ert-a"))
        (fb (make-temp-file "tc-ert-b")))
    (unwind-protect
        (progn
          (with-temp-file fa (insert "AAA pane one\nstill A\n"))
          (with-temp-file fb (insert "BBB pane two\nstill B\n"))
          (tmux-control-it--tmux-ok "kill-server")
          (tmux-control-it--tmux
           "new-session" "-d" "-s" "t" "-x" "80" "-y" "24"
           (format "cat %s; sleep 600" (shell-quote-argument fa)))
          (tmux-control-it--tmux
           "split-window" "-h" "-t" "t"
           (format "cat %s; sleep 600" (shell-quote-argument fb)))
          (let* ((ids (split-string
                       (string-trim
                        (tmux-control-it--tmux "list-panes" "-t" "t"
                                               "-F" "#{pane_id}"))
                       "\n" t))
                 (pa (nth 0 ids))
                 (pb (nth 1 ids)))
            (tmux-control-it--wait-settle pa)
            (tmux-control-it--wait-settle pb)
            (let ((ga (tmux-control-it--capture-lines pa))
                  (gb (tmux-control-it--capture-lines pb)))
              ;; Each pane renders its own content...
              (should (equal (tmux-control-it--render-seed pa 40 24) ga))
              (should (equal (tmux-control-it--render-seed pb 40 24) gb))
              ;; ...and the two are genuinely different (no cross-feed).
              (should-not (equal ga gb))
              (should (string-match-p "AAA" (mapconcat #'identity ga "\n")))
              (should (string-match-p "BBB" (mapconcat #'identity gb "\n"))))))
      (tmux-control-it--tmux-ok "kill-server")
      (ignore-errors (delete-file fa))
      (ignore-errors (delete-file fb)))))

;;; Layout-leaf -> pane-id matching must be by id, not coordinates.

(ert-deftest tmux-control-it-leaf-id-matches-pane-id ()
  "A window-layout leaf's id is the pane number, so tiling resolves panes by
id -- robust even when `pane-border-status' shifts `pane_top'/`pane_left'
away from the layout coordinates (as pi-agents-tmux and similar tools cause).
A coordinate-only match silently fails there; matching by id does not."
  (skip-unless (tmux-control-it--available-p))
  (tmux-control-it--tmux-ok "kill-server")
  (tmux-control-it--tmux "new-session" "-d" "-s" "t" "-x" "80" "-y" "24")
  ;; A top pane-border title row shifts pane_top off the layout y.
  (tmux-control-it--tmux "set-option" "-t" "t" "pane-border-status" "top")
  (tmux-control-it--tmux "split-window" "-v" "-t" "t")
  (tmux-control-it--tmux "split-window" "-h" "-t" "t")
  (unwind-protect
      (let* ((layout (string-trim
                      (tmux-control-it--tmux "display-message" "-p" "-t" "t"
                                             "#{window_layout}")))
             (leaves (tmux-control--layout-leaves
                      (tmux-control--parse-layout layout)))
             (rows (split-string
                    (string-trim
                     (tmux-control-it--tmux "list-panes" "-t" "t" "-F"
                                            "#{pane_id} #{pane_top}"))
                    "\n" t))
             (pane-ids (mapcar (lambda (r) (car (split-string r))) rows)))
        (should (= (length leaves) 3))
        ;; Every leaf id resolves to a real pane as %<id> -- the invariant
        ;; tmux-control--build-tiling relies on.
        (dolist (leaf leaves)
          (should (member (concat "%" (plist-get leaf :id)) pane-ids))))
    (tmux-control-it--tmux-ok "kill-server")))

;;; Window navigation: next/previous/last switch the live view to the right
;;; window and reseed its screen.

(ert-deftest tmux-control-it-window-switching ()
  "next/previous/last-window change the session's active window in tmux order
(with wraparound and last-window toggle) and the single-pane view reseeds onto
the newly active window's screen."
  (skip-unless (tmux-control-it--available-p))
  (tmux-control-it--tmux-ok "kill-server")
  (tmux-control-it--tmux "new-session" "-d" "-s" "t" "-n" "w0" "-x" "80" "-y" "24")
  (tmux-control-it--tmux "new-window" "-t" "t:" "-n" "w1")
  (tmux-control-it--tmux "new-window" "-t" "t:" "-n" "w2")
  ;; A distinct marker per window, so the reseed is checked -- not just tmux's
  ;; active-window pointer.
  (tmux-control-it--tmux "send-keys" "-t" "t:0" "echo WIN_ZERO" "Enter")
  (tmux-control-it--tmux "send-keys" "-t" "t:1" "echo WIN_ONE" "Enter")
  (tmux-control-it--tmux "send-keys" "-t" "t:2" "echo WIN_TWO" "Enter")
  ;; This asserts the historical repaint-in-place path; the per-window
  ;; buffer path is asserted by `tmux-control-it-window-buffers-persist'.
  (let* ((tmux-control-window-buffers nil)
         (buf (tmux-control-connect nil tmux-control-it--socket "t")))
    (cl-flet ((shows (mark)
                (tmux-control-it--pump-until
                 5 (lambda ()
                     (cl-some (lambda (l) (string-match-p mark l))
                              (tmux-control-it--buffer-visible buf 24))))))
      (unwind-protect
          (progn
            (tmux-control-it--pump 1.5)
            (should (shows "WIN_TWO"))                                ; w2 (last created)
            (with-current-buffer buf (tmux-control-next-window))      ; 2 -> 0 (wrap)
            (should (shows "WIN_ZERO"))
            (with-current-buffer buf (tmux-control-next-window))      ; 0 -> 1
            (should (shows "WIN_ONE"))
            (with-current-buffer buf (tmux-control-previous-window))  ; 1 -> 0
            (should (shows "WIN_ZERO"))
            (with-current-buffer buf (tmux-control-last-window))      ; 0 <-> 1
            (should (shows "WIN_ONE")))
        (when (buffer-live-p buf)
          (with-current-buffer buf (ignore-errors (tmux-control-disconnect)))
          (kill-buffer buf))
        (tmux-control-it--tmux-ok "kill-server")))))

(ert-deftest tmux-control-it-window-buffers-persist ()
  "With per-window buffers, a switch creates a sibling render buffer for the
new window (seeded to its screen), the previous window's buffer keeps its
content, and output produced in the background window accumulates in its
buffer while another window is current."
  (skip-unless (tmux-control-it--available-p))
  (tmux-control-it--tmux-ok "kill-server")
  (tmux-control-it--tmux "new-session" "-d" "-s" "t" "-n" "w0" "-x" "80" "-y" "24")
  (tmux-control-it--tmux "new-window" "-t" "t:" "-n" "w1")
  (tmux-control-it--tmux "select-window" "-t" "t:0")
  (tmux-control-it--tmux "send-keys" "-t" "t:0" "echo WIN_ZERO" "Enter")
  (tmux-control-it--tmux "send-keys" "-t" "t:1" "echo WIN_ONE" "Enter")
  ;; Tab bar OFF on purpose: the window list and pane->window map that
  ;; routing depends on must be requested for per-window buffers on their
  ;; own, not as a tab-bar side effect (a real review catch).
  (let* ((tmux-control-window-buffers t)
         (tmux-control-window-tab-bar nil)
         (buf (tmux-control-connect nil tmux-control-it--socket "t")))
    (cl-flet ((buffer-has (b mark)
                (tmux-control-it--pump-until
                 6 (lambda ()
                     (and (buffer-live-p b)
                          (with-current-buffer b
                            (string-match-p
                             mark (buffer-substring-no-properties
                                   (point-min) (point-max)))))))))
      (unwind-protect
          (progn
            (tmux-control-it--pump 1.5)
            (should (buffer-has buf "WIN_ZERO"))
            ;; Switch: a sibling buffer appears for w1, seeded to its screen.
            (with-current-buffer buf (tmux-control-next-window))
            (let ((sibling
                   (progn
                     (tmux-control-it--pump-until
                      6 (lambda ()
                          (with-current-buffer buf
                            (cdr (cl-find-if
                                  (lambda (e) (not (eq (cdr e) buf)))
                                  tmux-control--window-buffers)))))
                     (with-current-buffer buf
                       (cdr (cl-find-if (lambda (e) (not (eq (cdr e) buf)))
                                        tmux-control--window-buffers))))))
              (should (buffer-live-p sibling))
              (should (buffer-has sibling "WIN_ONE"))
              ;; The previous window's buffer kept its content...
              (should (buffer-has buf "WIN_ZERO"))
              ;; ...and accumulates output produced while w1 is current.
              (tmux-control-it--tmux "send-keys" "-t" "t:0"
                                     "echo ZERO_WHILE_AWAY" "Enter")
              (should (buffer-has buf "ZERO_WHILE_AWAY"))
              ;; Both windows' content coexists; nothing was repainted away.
              (should (buffer-has buf "WIN_ZERO"))))
        (when (buffer-live-p buf)
          (with-current-buffer buf (ignore-errors (tmux-control-disconnect)))
          (kill-buffer buf))
        (tmux-control-it--tmux-ok "kill-server")))))

;;; Tab-bar activity: background output flags a window; visiting it clears it.

(ert-deftest tmux-control-it-window-activity ()
  "Output produced in a background window flags it in the tab bar's activity
set, the current window is never flagged, and switching to a flagged window
clears it."
  (skip-unless (tmux-control-it--available-p))
  (tmux-control-it--tmux-ok "kill-server")
  (tmux-control-it--tmux "new-session" "-d" "-s" "t" "-n" "w0" "-x" "80" "-y" "24")
  (tmux-control-it--tmux "new-window" "-t" "t:" "-n" "w1")
  (tmux-control-it--tmux "select-window" "-t" "t:0")   ; start on window 0
  (let ((buf (tmux-control-connect nil tmux-control-it--socket "t")))
    (unwind-protect
        (with-current-buffer buf
          (tmux-control-it--pump 2.0)                   ; past the connect quiet (1.5s)
          (tmux-control-it--tmux "send-keys" "-t" "t:1" "echo ACT" "Enter")
          (should (tmux-control-it--pump-until
                   6 (lambda () (and (hash-table-p tmux-control--activity)
                                     (gethash "1" tmux-control--activity)))))
          (should-not (gethash "0" tmux-control--activity)) ; current window never flags
          (tmux-control-next-window)                    ; 0 -> 1: arriving clears it
          (should (tmux-control-it--pump-until
                   6 (lambda () (not (gethash "1" tmux-control--activity))))))
      (when (buffer-live-p buf)
        (with-current-buffer buf (ignore-errors (tmux-control-disconnect)))
        (kill-buffer buf))
      (tmux-control-it--tmux-ok "kill-server"))))

(ert-deftest tmux-control-it-rapid-window-switching-converges ()
  "Back-to-back window switches (the preview menu's pattern) converge on the
last window selected.  Regression: the swap derived the displayed buffer
from the cached window index, which updates via a slower separate reply, so
the second of two quick switches found no window showing its notion of the
view and stranded the display on the previous window."
  (skip-unless (tmux-control-it--available-p))
  (tmux-control-it--tmux-ok "kill-server")
  (tmux-control-it--tmux "new-session" "-d" "-s" "t" "-n" "w0" "-x" "80" "-y" "24")
  (tmux-control-it--tmux "new-window" "-t" "t:" "-n" "w1")
  (tmux-control-it--tmux "new-window" "-t" "t:" "-n" "w2")
  (tmux-control-it--tmux "select-window" "-t" "t:0")
  (tmux-control-it--tmux "send-keys" "-t" "t:0" "echo MARK_ZERO" "Enter")
  (tmux-control-it--tmux "send-keys" "-t" "t:1" "echo MARK_ONE" "Enter")
  (tmux-control-it--tmux "send-keys" "-t" "t:2" "echo MARK_TWO" "Enter")
  (let* ((tmux-control-window-buffers t)
         (buf (tmux-control-connect nil tmux-control-it--socket "t")))
    (unwind-protect
        (progn
          (tmux-control-it--pump 1.5)
          ;; Burst: three switches with NO pumping between sends, so the
          ;; notifications and :windows replies interleave like a user
          ;; flicking through the menu over a remote link.
          (with-current-buffer buf
            (tmux-control--do-select-window "1")
            (tmux-control--do-select-window "2")
            (tmux-control--do-select-window "1"))
          ;; The display must converge on window 1's buffer.
          (should (tmux-control-it--pump-until
                   8 (lambda ()
                       (let ((shown (window-buffer (selected-window))))
                         (and (string-match-p ":@" (buffer-name shown))
                              (with-current-buffer shown
                                (and (equal tmux-control--window-id
                                            (with-current-buffer buf
                                              (tmux-control--window-id-for-index "1")))
                                     (string-match-p
                                      "MARK_ONE"
                                      (buffer-substring-no-properties
                                       (point-min) (point-max))))))))))
          ;; And the session's display pointer agrees with what is shown.
          (should (eq (tmux-control--session-display-buffer buf)
                      (window-buffer (selected-window)))))
      (when (buffer-live-p buf)
        (with-current-buffer buf (ignore-errors (tmux-control-disconnect)))
        (kill-buffer buf))
      (tmux-control-it--tmux-ok "kill-server"))))

(ert-deftest tmux-control-it-select-pane-jumps-to-other-window ()
  "`tmux-control-select-pane' given a pane id from ANOTHER window is a real
jump: the session switches to that window, and the view shows the pane.
\(Non-interactive here; the interactive picker resolves to the same call.)
The field-reported topology: two windows, one pane each, target the other
window's pane -- the view must not stay on the old window."
  (skip-unless (tmux-control-it--available-p))
  (tmux-control-it--tmux-ok "kill-server")
  (tmux-control-it--tmux "new-session" "-d" "-s" "t" "-n" "w0" "-x" "80" "-y" "24")
  (tmux-control-it--tmux "new-window" "-t" "t:" "-n" "w1")
  (tmux-control-it--tmux "select-window" "-t" "t:0")
  (tmux-control-it--tmux "send-keys" "-t" "t:0" "echo PANE_OF_W0" "Enter")
  (tmux-control-it--tmux "send-keys" "-t" "t:1" "echo PANE_OF_W1" "Enter")
  (let* ((tmux-control-window-buffers t)
         (buf (tmux-control-connect nil tmux-control-it--socket "t")))
    (unwind-protect
        (progn
          (tmux-control-it--pump 1.5)
          ;; Resolve window 1's pane id from tmux itself.
          (let ((target
                 (string-trim
                  (tmux-control-it--tmux
                   "list-panes" "-t" "t:1" "-F" "#{pane_id}"))))
            (with-current-buffer buf
              (tmux-control-select-pane target))
            ;; The view converges on window 1's buffer showing its pane.
            (should (tmux-control-it--pump-until
                     8 (lambda ()
                         (let ((shown (window-buffer (selected-window))))
                           (and (not (eq shown buf))
                                (with-current-buffer shown
                                  (string-match-p
                                   "PANE_OF_W1"
                                   (buffer-substring-no-properties
                                    (point-min) (point-max)))))))))))
      (when (buffer-live-p buf)
        (with-current-buffer buf (ignore-errors (tmux-control-disconnect)))
        (kill-buffer buf))
      (tmux-control-it--tmux-ok "kill-server"))))

(ert-deftest tmux-control-it-select-pane-recovers-desynced-view ()
  "Selecting a pane converges the view even when the session is ALREADY
current on the pane's window while the frame shows another window's buffer.
The desync is one hand-display away (`switch-to-buffer' on a render buffer,
a window-configuration restore); from it, the bare select-pane changes
nothing tmux notifies about, so nothing visibly happened -- the live field
report, reproduced end to end: jump to w1, display w0's buffer by hand,
select w1's pane again, and the view must come back to w1."
  (skip-unless (tmux-control-it--available-p))
  (tmux-control-it--tmux-ok "kill-server")
  (tmux-control-it--tmux "new-session" "-d" "-s" "t" "-n" "w0" "-x" "80" "-y" "24")
  (tmux-control-it--tmux "new-window" "-t" "t:" "-n" "w1")
  (tmux-control-it--tmux "select-window" "-t" "t:0")
  (tmux-control-it--tmux "send-keys" "-t" "t:0" "echo PANE_OF_W0" "Enter")
  (tmux-control-it--tmux "send-keys" "-t" "t:1" "echo PANE_OF_W1" "Enter")
  (let* ((tmux-control-window-buffers t)
         (buf (tmux-control-connect nil tmux-control-it--socket "t")))
    (cl-flet ((shows-w1 ()
                (tmux-control-it--pump-until
                 8 (lambda ()
                     (let ((shown (window-buffer (selected-window))))
                       (and (not (eq shown buf))
                            (with-current-buffer shown
                              (string-match-p
                               "PANE_OF_W1"
                               (buffer-substring-no-properties
                                (point-min) (point-max))))))))))
      (unwind-protect
          (progn
            (tmux-control-it--pump 1.5)
            (let ((target (string-trim
                           (tmux-control-it--tmux
                            "list-panes" "-t" "t:1" "-F" "#{pane_id}"))))
              ;; A legitimate jump first: view, pointer, and tmux all on w1.
              (with-current-buffer buf
                (tmux-control-select-pane target))
              (should (shows-w1))
              ;; Out-of-band: the user displays w0's render buffer by hand.
              ;; tmux still says current window 1; the display pointer still
              ;; says w1's buffer.
              (set-window-buffer (selected-window) buf)
              ;; Select w1's pane again.  tmux is already there -- no
              ;; notification will come -- so the command itself must bring
              ;; the view back.
              (with-current-buffer buf
                (tmux-control-select-pane target))
              (should (shows-w1))))
        (when (buffer-live-p buf)
          (with-current-buffer buf (ignore-errors (tmux-control-disconnect)))
          (kill-buffer buf))
        (tmux-control-it--tmux-ok "kill-server")))))

;;; Lazy-extend scrollback: instant open, then on-demand seam-correct growth.

(defun tmux-control-it--sb-indices (text)
  "Ordered list of the NNNN numbers from \"L<NNNN>\" lines in TEXT.
The lazy-extend test fills pane history with uniquely numbered lines so the
loaded history can be checked for contiguity (no dropped or duplicated line
at an extension seam) regardless of surrounding prompt/sleep chrome."
  (let ((idxs nil) (start 0))
    (while (string-match "^L\\([0-9]+\\)" text start)
      (push (string-to-number (match-string 1 text)) idxs)
      (setq start (match-end 0)))
    (nreverse idxs)))

(defun tmux-control-it--contiguous-p (idxs)
  "Non-nil when IDXS ascends by exactly 1 with no gap and no duplicate."
  (and idxs
       (let ((ok t) (prev (car idxs)))
         (dolist (cur (cdr idxs) ok)
           (unless (= cur (1+ prev)) (setq ok nil))
           (setq prev cur)))))

(ert-deftest tmux-control-it-scrollback-lazy-extend ()
  "The pager opens with only the initial chunk and extends toward older
history on demand: each extension is contiguous with what is already
loaded, depth caps at `tmux-control-scrollback-lines', a redundant extend
at the cap is a no-op that leaves no in-flight latch, and the fully
extended buffer equals a single capture of the same depth.  Uses small
limits and 600 numbered lines (well under tmux's default history) so it
runs fast without raising the server's history-limit."
  (skip-unless (tmux-control-it--available-p))
  (let ((tmux-control-scrollback-initial-lines 50)
        (tmux-control-scrollback-extend-lines 100)
        (tmux-control-scrollback-lines 300)
        (tmux-control-compact-scrollback nil)
        (content (mapconcat (lambda (i) (format "L%04d" i))
                            (number-sequence 1 600) "\n")))
    (tmux-control-it--with-pane (concat content "\n") 100 24
      ;; Suppress the scroll watcher so extends happen only when this test
      ;; drives them: in batch there is no redisplay, so a window's start
      ;; stays pinned at point-min and the watcher (invoked once by
      ;; `switch-to-buffer') would read the view as "at the top" and extend
      ;; spuriously.  The watcher's gating is covered by a unit test; here we
      ;; verify the extend MECHANISM deterministically.
      (cl-letf (((symbol-function 'tmux-control--scrollback-scroll-watch)
                 #'ignore))
      (let ((live (tmux-control-connect nil tmux-control-it--socket "t")))
        (unwind-protect
            (progn
              (tmux-control-it--pump-until
               5 (lambda () (with-current-buffer live tmux-control--active-pane)))
              (let* ((sb-name (format "*%s-scrollback*" (buffer-name live)))
                     (sb nil))
                (with-current-buffer live (tmux-control-scrollback))
                (setq sb (get-buffer sb-name))
                ;; Opened with just the initial chunk -- not the full history.
                (tmux-control-it--pump-until
                 10 (lambda () (with-current-buffer sb
                                 (not (string-match-p "capturing"
                                                      (buffer-string))))))
                (should (= (buffer-local-value 'tmux-control--scrollback-depth sb)
                           50))
                (should (tmux-control-it--contiguous-p
                         (tmux-control-it--sb-indices
                          (tmux-control-it--buffer-text sb))))
                ;; Drive five extends past the cap; every seam stays contiguous.
                (let ((depths nil))
                  (dotimes (_ 5)
                    (with-current-buffer sb
                      (setq tmux-control--scrollback-extending nil))
                    (tmux-control--scrollback-extend sb)
                    (tmux-control-it--pump-until
                     10 (lambda ()
                          (with-current-buffer sb
                            (not tmux-control--scrollback-extending))))
                    (should (tmux-control-it--contiguous-p
                             (tmux-control-it--sb-indices
                              (tmux-control-it--buffer-text sb))))
                    (push (buffer-local-value 'tmux-control--scrollback-depth sb)
                          depths))
                  ;; 50 -> 150 -> 250 -> 300 (cap) -> 300 -> 300.
                  (should (equal (nreverse depths) '(150 250 300 300 300))))
                ;; No stuck in-flight latch after it all settles.
                (should-not (buffer-local-value
                             'tmux-control--scrollback-extending sb))
                ;; The lazily-grown buffer equals one full capture at the cap.
                (should (equal
                         (tmux-control-it--sb-indices
                          (tmux-control-it--buffer-text sb))
                         (tmux-control-it--sb-indices
                          (tmux-control-it--tmux "capture-pane" "-p"
                                                 "-S" "-300" "-t" pane))))
                (when (buffer-live-p sb) (kill-buffer sb))))
          (when (buffer-live-p live)
            (when (process-live-p
                   (buffer-local-value 'tmux-control--process live))
              (delete-process (buffer-local-value 'tmux-control--process live)))
            (kill-buffer live))))))))

(ert-deftest tmux-control-it-scrollback-lazy-extend-hits-history-top ()
  "When the pane has less history than the cap, extension loads everything
older then stops: the depth settles at the ACTUAL number of lines tmux had
(not the requested cap), the `at-top' latch trips so further scrolls do not
re-query an empty range, and the buffer still equals one full capture with
no gap or duplicate at the final seam.  This is the case where recording the
requested depth instead of the received depth would risk a seam error."
  (skip-unless (tmux-control-it--available-p))
  (let ((tmux-control-scrollback-initial-lines 50)
        (tmux-control-scrollback-extend-lines 100)
        (tmux-control-scrollback-lines 5000)   ; cap far above real history
        (tmux-control-compact-scrollback nil)
        ;; ~120 lines of history -- well under the 5000 cap.
        (content (mapconcat (lambda (i) (format "L%04d" i))
                            (number-sequence 1 120) "\n")))
    (tmux-control-it--with-pane (concat content "\n") 100 24
      (cl-letf (((symbol-function 'tmux-control--scrollback-scroll-watch)
                 #'ignore))
        (let ((live (tmux-control-connect nil tmux-control-it--socket "t")))
          (unwind-protect
              (progn
                (tmux-control-it--pump-until
                 5 (lambda () (with-current-buffer live tmux-control--active-pane)))
                (let* ((sb-name (format "*%s-scrollback*" (buffer-name live)))
                       (sb nil))
                  (with-current-buffer live (tmux-control-scrollback))
                  (setq sb (get-buffer sb-name))
                  (tmux-control-it--pump-until
                   10 (lambda () (with-current-buffer sb
                                   (not (string-match-p "capturing"
                                                        (buffer-string))))))
                  ;; Drive extends past the real top of history.
                  (dotimes (_ 4)
                    (with-current-buffer sb
                      (setq tmux-control--scrollback-extending nil))
                    (tmux-control--scrollback-extend sb)
                    (tmux-control-it--pump-until
                     10 (lambda ()
                          (with-current-buffer sb
                            (not tmux-control--scrollback-extending)))))
                  ;; Reached the oldest line: latched, and depth is the actual
                  ;; history loaded -- far below the 5000 cap, not pinned to it.
                  (should (buffer-local-value
                           'tmux-control--scrollback-at-top sb))
                  (let ((depth (buffer-local-value
                                'tmux-control--scrollback-depth sb)))
                    (should (< depth 500))
                    (should (> depth 0)))
                  ;; Complete and seam-correct: every history line, once each.
                  (let ((got (tmux-control-it--sb-indices
                              (tmux-control-it--buffer-text sb))))
                    (should (tmux-control-it--contiguous-p got))
                    (should (equal got
                                   (tmux-control-it--sb-indices
                                    (tmux-control-it--tmux
                                     "capture-pane" "-p" "-S" "-5000"
                                     "-t" pane)))))
                  (when (buffer-live-p sb) (kill-buffer sb))))
            (when (buffer-live-p live)
              (when (process-live-p
                     (buffer-local-value 'tmux-control--process live))
                (delete-process
                 (buffer-local-value 'tmux-control--process live)))
              (kill-buffer live))))))))

(provide 'tmux-control-integration)
;;; tmux-control-integration.el ends here
