;;; tmux-control-chaos.el --- Randomized live soak harness -*- lexical-binding: t; -*-

;;; Commentary:

;; A chaos soak for a LIVE, GUI tmux-control session: drive a random but
;; reproducible stream of realistic operations -- window switches, the
;; scrollback pager, typing, pastes, output floods, frame resizes,
;; char-mode round trips, reconnects, window and pane churn -- and check
;; invariants after every step:
;;
;;   - the displayed buffer's Eat screen matches tmux `capture-pane'
;;     (with one settle retry for in-flight output)
;;   - the command queue drains
;;   - the displayed buffer is a tmux-control buffer (no stranded view)
;;   - render buffers stay bounded (Eat's scrollback trim is working)
;;   - the timer list does not grow without bound
;;
;; This is a MANUAL tool, not part of `make test': it needs a GUI frame
;; (frame resizing is one of the ops) and minutes of wall clock.  It has
;; caught real bugs the scripted suites missed: a foreign-window
;; %window-pane-changed retargeting the controller onto a pane that
;; later died, and a one-row screen drift from %output interleaving a
;; seed's cursor and capture replies.
;;
;; Usage, from a GUI Emacs with tmux-control loaded:
;;
;;   (load "test/tmux-control-chaos.el")
;;   ;; throwaway server: tmux -L tc-chaos new-session -d -s chaos -x 120 -y 30
;;   ;; (plus a couple of extra windows), then connect tmux-control to it
;;   ;; and display the live buffer in the selected window.
;;   (tmux-control-chaos-run 120 1234)   ; STEPS SEED
;;
;; The same SEED replays the same operation sequence (an LCG; Emacs's
;; seeded `random' is not stable across builds).  A non-nil result lists
;; (STEP OP PROBLEMS) triples.  `tmux-control-chaos-run-until-failure'
;; stops at the first failure, leaving the live state frozen for
;; inspection.

;;; Code:

(require 'cl-lib)
(require 'tmux-control)

(defvar tmux-control-chaos-socket "tc-chaos"
  "tmux -L socket name the chaos ops drive out-of-band.")
(defvar tmux-control-chaos-session "chaos"
  "tmux session name the chaos ops target.")
(defvar tmux-control-chaos-windows 3
  "How many windows the soak assumes exist (switch targets 0..N-1).")

(defvar tmux-control-chaos--seed 1)
(defvar tmux-control-chaos--trace nil)
(defvar tmux-control-chaos--failures nil)
(defvar tmux-control-chaos--op-problems nil
  "Transient invariant violations recorded by the current op.
Some bugs live only in the un-settled window of an async operation -- a
wheel-down arriving while a scrollback capture is still pending, input
sent mid window-swap -- and are gone by the time the per-step
`tmux-control-chaos--check' runs.  Transient ops check those invariants
inline and push here; `tmux-control-chaos--check' merges and clears it.")

(defun tmux-control-chaos--flag (fmt &rest args)
  "Record a transient invariant violation for the current op."
  (push (apply #'format fmt args) tmux-control-chaos--op-problems))

(defun tmux-control-chaos--rand (n)
  (setq tmux-control-chaos--seed
        (mod (+ (* tmux-control-chaos--seed 1103515245) 12345) 2147483648))
  (mod (/ tmux-control-chaos--seed 65536) n))

(defun tmux-control-chaos--gui-frame ()
  (or (cl-find-if (lambda (f) (frame-parameter f 'window-system))
                  (frame-list))
      (error "tmux-control-chaos needs a GUI frame")))

(defun tmux-control-chaos--ctrl ()
  (or (cl-find-if (lambda (b)
                    (with-current-buffer b
                      (and (derived-mode-p 'tmux-control-mode)
                           (not tmux-control--controller)
                           (process-live-p tmux-control--process))))
                  (buffer-list))
      (error "No live tmux-control controller buffer")))

(defun tmux-control-chaos--win ()
  (frame-selected-window (tmux-control-chaos--gui-frame)))
(defun tmux-control-chaos--displayed ()
  (window-buffer (tmux-control-chaos--win)))
(defun tmux-control-chaos--in-displayed (fn)
  (with-selected-frame (tmux-control-chaos--gui-frame)
    (with-selected-window (tmux-control-chaos--win) (funcall fn))))

(defun tmux-control-chaos--screen-text (buf)
  "BUF's visible Eat screen, invisible padding stripped, tabs expanded."
  (with-current-buffer buf
    (let* ((term tmux-control--terminal)
           (raw (buffer-substring (eat-term-display-beginning term)
                                  (eat-term-end term)))
           (out ""))
      (let ((i 0) (n (length raw)))
        (while (< i n)
          (let ((next (or (next-single-property-change i 'invisible raw) n)))
            (unless (get-text-property i 'invisible raw)
              (setq out (concat out (substring raw i next))))
            (setq i next))))
      (with-temp-buffer (insert out) (untabify (point-min) (point-max))
                        (buffer-string)))))

(defun tmux-control-chaos--tmux (&rest args)
  (apply #'call-process "tmux" nil nil nil
         "-L" tmux-control-chaos-socket args))
(defun tmux-control-chaos--tmux-out (&rest args)
  (with-output-to-string
    (with-current-buffer standard-output
      (apply #'call-process "tmux" nil t nil
             "-L" tmux-control-chaos-socket args))))

(defun tmux-control-chaos--pump (secs)
  (let ((t0 (float-time)))
    (while (< (- (float-time) t0) secs)
      (accept-process-output nil 0.03))))

(defun tmux-control-chaos--settle (&optional secs)
  "Pump process output until the command queue drains (timeout SECS)."
  (let ((t0 (float-time)) (limit (or secs 8)))
    (while (and (< (- (float-time) t0) limit)
                (with-current-buffer (tmux-control-chaos--ctrl)
                  (or tmux-control--command-queue
                      tmux-control--collecting-command)))
      (accept-process-output nil 0.03))
    (tmux-control-chaos--pump 0.25)))

;;;; Operations

(defmacro tmux-control-chaos--defop (name weight &rest body)
  "Define chaos op NAME with selection WEIGHT and BODY."
  (declare (indent 2))
  `(progn
     (defun ,name () ,@body)
     (push (cons ',name ,weight) tmux-control-chaos--ops)))

(defvar tmux-control-chaos--ops nil)
(setq tmux-control-chaos--ops nil)

(tmux-control-chaos--defop tmux-control-chaos--op-switch-window 14
  (let ((idx (number-to-string
              (tmux-control-chaos--rand tmux-control-chaos-windows))))
    (tmux-control-chaos--in-displayed
     (lambda () (tmux-control-select-window idx)))
    (tmux-control-chaos--settle)))

(tmux-control-chaos--defop tmux-control-chaos--op-next-window 8
  (tmux-control-chaos--in-displayed #'tmux-control-next-window)
  (tmux-control-chaos--settle))

(tmux-control-chaos--defop tmux-control-chaos--op-prev-window 6
  (tmux-control-chaos--in-displayed #'tmux-control-previous-window)
  (tmux-control-chaos--settle))

(tmux-control-chaos--defop tmux-control-chaos--op-pager-roundtrip 10
  (when (with-current-buffer (tmux-control-chaos--displayed)
          (derived-mode-p 'tmux-control-mode))
    (tmux-control-chaos--in-displayed #'tmux-control-scrollback)
    (tmux-control-chaos--settle)
    (when (with-current-buffer (tmux-control-chaos--displayed)
            (derived-mode-p 'tmux-control-scrollback-mode))
      (tmux-control-chaos--in-displayed #'tmux-control-live))
    (tmux-control-chaos--settle)))

(tmux-control-chaos--defop tmux-control-chaos--op-wheel-exit 6
  ;; The real wheel-exit round trip: scroll up off the bottom (so the
  ;; pager records it left the bottom), then a wheel-down at the bottom
  ;; leaves to live.  A bare wheel-down at the bottom right after opening
  ;; does NOT leave (that is the no-bounce rule), so this op must drive
  ;; the up-then-down sequence -- and clean up unconditionally, or a
  ;; stranded pager poisons every later op with "process is not live".
  (when (with-current-buffer (tmux-control-chaos--displayed)
          (derived-mode-p 'tmux-control-mode))
    (tmux-control-chaos--in-displayed #'tmux-control-scrollback)
    (tmux-control-chaos--settle)
    (let ((w (tmux-control-chaos--win)))
      (when (with-current-buffer (window-buffer w)
              (derived-mode-p 'tmux-control-scrollback-mode))
        (with-selected-window w
          (with-current-buffer (window-buffer w)
            ;; up off the bottom: this wheel-down (above the bottom) sets
            ;; the left-bottom flag.
            (set-window-start w (point-min))
            (goto-char (point-min))
            (funcall (key-binding [wheel-down]) (list 'wheel-down (list w)))
            ;; back to the bottom: now a wheel-down leaves.
            (goto-char (point-max))
            (recenter -1)
            (funcall (key-binding [wheel-down]) (list 'wheel-down (list w)))))))
    ;; Robust cleanup: never leave the pager open for the next op.
    (when (with-current-buffer (tmux-control-chaos--displayed)
            (derived-mode-p 'tmux-control-scrollback-mode))
      (tmux-control-chaos--in-displayed #'tmux-control-live))
    (tmux-control-chaos--settle)))

(tmux-control-chaos--defop tmux-control-chaos--op-type 14
  (with-current-buffer (tmux-control-chaos--displayed)
    (when (derived-mode-p 'tmux-control-mode)
      (tmux-control--send-input tmux-control--terminal "\C-u")
      (tmux-control--send-input
       tmux-control--terminal
       (format " echo c%d" (tmux-control-chaos--rand 1000)))))
  (tmux-control-chaos--settle))

(tmux-control-chaos--defop tmux-control-chaos--op-clear-line 6
  (with-current-buffer (tmux-control-chaos--displayed)
    (when (derived-mode-p 'tmux-control-mode)
      (tmux-control--send-input tmux-control--terminal "\C-u")))
  (tmux-control-chaos--settle))

(tmux-control-chaos--defop tmux-control-chaos--op-paste 8
  (when (with-current-buffer (tmux-control-chaos--displayed)
          (derived-mode-p 'tmux-control-mode))
    (kill-new (format "p%d one\np%d two"
                      (tmux-control-chaos--rand 100)
                      (tmux-control-chaos--rand 100)))
    (tmux-control-chaos--in-displayed #'tmux-control-yank)
    (tmux-control-chaos--settle)
    (with-current-buffer (tmux-control-chaos--displayed)
      (when (derived-mode-p 'tmux-control-mode)
        (tmux-control--send-input tmux-control--terminal "\C-c")))
    (tmux-control-chaos--settle)))

(tmux-control-chaos--defop tmux-control-chaos--op-flood-burst 8
  (tmux-control-chaos--tmux
   "send-keys" "-t"
   (format "%s:%d" tmux-control-chaos-session
           (tmux-control-chaos--rand tmux-control-chaos-windows))
   (format "seq 1 %d" (+ 2000 (tmux-control-chaos--rand 4000)))
   "Enter")
  (tmux-control-chaos--settle 12))

(tmux-control-chaos--defop tmux-control-chaos--op-resize 6
  (set-frame-size (tmux-control-chaos--gui-frame)
                  (+ 90 (tmux-control-chaos--rand 40))
                  (+ 24 (tmux-control-chaos--rand 14)))
  (tmux-control-chaos--settle 10))

(tmux-control-chaos--defop tmux-control-chaos--op-char-mode-roundtrip 5
  (with-current-buffer (tmux-control-chaos--displayed)
    (when (derived-mode-p 'tmux-control-mode)
      (eat-char-mode)
      (eat-semi-char-mode)))
  (tmux-control-chaos--settle))

(tmux-control-chaos--defop tmux-control-chaos--op-clear-repaint 4
  (when (with-current-buffer (tmux-control-chaos--displayed)
          (derived-mode-p 'tmux-control-mode))
    (tmux-control-chaos--in-displayed #'tmux-control-clear-and-repaint)
    (tmux-control-chaos--settle)))

(tmux-control-chaos--defop tmux-control-chaos--op-new-then-kill-window 3
  (tmux-control-chaos--in-displayed
   (lambda () (tmux-control-new-window "tmp")))
  (tmux-control-chaos--settle)
  (dolist (line (split-string
                 (tmux-control-chaos--tmux-out
                  "list-windows" "-t" tmux-control-chaos-session
                  "-F" "#{window_index}\t#{window_name}")
                 "\n" t))
    (let ((cells (split-string line "\t")))
      (when (equal (cadr cells) "tmp")
        (tmux-control-chaos--tmux
         "kill-window" "-t" (format "%s:%s" tmux-control-chaos-session
                                    (car cells))))))
  (tmux-control-chaos--settle))

(tmux-control-chaos--defop tmux-control-chaos--op-split-then-kill-pane 4
  (let ((cur (string-trim
              (tmux-control-chaos--tmux-out
               "display-message" "-p" "-t" tmux-control-chaos-session
               "#{window_index}"))))
    (tmux-control-chaos--tmux
     "split-window" "-t" (format "%s:%s" tmux-control-chaos-session cur))
    (tmux-control-chaos--settle 10)
    (tmux-control-chaos--tmux
     "send-keys" "-t" (format "%s:%s" tmux-control-chaos-session cur)
     "seq 1 500" "Enter")
    (tmux-control-chaos--settle)
    (tmux-control-chaos--tmux
     "kill-pane" "-t" (format "%s:%s" tmux-control-chaos-session cur))
    (tmux-control-chaos--settle 10)))

(tmux-control-chaos--defop tmux-control-chaos--op-kill-controller-window 2
  (let ((wid (buffer-local-value 'tmux-control--window-id
                                 (tmux-control-chaos--ctrl))))
    (when wid
      ;; Replacement first: killing the session's last window would end
      ;; the session (and the soak) rather than exercise the close path.
      (tmux-control-chaos--tmux
       "new-window" "-d" "-t" (concat tmux-control-chaos-session ":"))
      (tmux-control-chaos--tmux "kill-window" "-t" wid)
      (tmux-control-chaos--settle 10))))

(tmux-control-chaos--defop tmux-control-chaos--op-reconnect 2
  (tmux-control-chaos--in-displayed #'tmux-control-reconnect)
  (tmux-control-chaos--settle 15))

;;;; Transient-probing ops
;;
;; The ops above settle (wait for the command queue to drain) before
;; checking anything -- so they exercise the calm, never the storm.  But
;; real bugs live in the un-settled window: input arriving while an async
;; capture is mid-flight, a stray wheel event during the one-line
;; "capturing…" placeholder, keys sent mid window-swap.  These ops fire
;; input DURING that window and assert inline, before settling.

(tmux-control-chaos--defop tmux-control-chaos--op-pager-wheel-during-capture 7
  ;; Open the pager and fire a wheel-down while the capture is still
  ;; pending -- the placeholder is a one-line buffer, so its bottom is
  ;; trivially visible.  The pager must NOT bounce to live: you enter by
  ;; scrolling up, so an immediate wheel-down has nothing below to leave
  ;; toward.  This is the exact scroll-bounce/loop bug.
  (when (with-current-buffer (tmux-control-chaos--displayed)
          (derived-mode-p 'tmux-control-mode))
    (tmux-control-chaos--in-displayed #'tmux-control-scrollback)
    ;; deliberately NO settle -- the placeholder is showing now
    (let ((w (tmux-control-chaos--win)))
      (when (with-current-buffer (window-buffer w)
              (derived-mode-p 'tmux-control-scrollback-mode))
        (with-selected-window w
          (funcall (key-binding [wheel-down]) (list 'wheel-down (list w))))
        (unless (with-current-buffer (window-buffer (tmux-control-chaos--win))
                  (derived-mode-p 'tmux-control-scrollback-mode))
          (tmux-control-chaos--flag
           "pager bounced to live on wheel-down during capture"))))
    (tmux-control-chaos--settle)
    ;; Back to live for the next op (whichever buffer we ended on).
    (when (with-current-buffer (tmux-control-chaos--displayed)
            (derived-mode-p 'tmux-control-scrollback-mode))
      (tmux-control-chaos--in-displayed #'tmux-control-live))
    (tmux-control-chaos--settle)))

(tmux-control-chaos--defop tmux-control-chaos--op-pager-jitter-flick 5
  ;; A jittery flick over the just-opened pager: down, up, down, before
  ;; the capture lands.  Must stay in the pager (no bounce) and, once
  ;; settled, the capture must still land (not be left in limbo).
  (when (with-current-buffer (tmux-control-chaos--displayed)
          (derived-mode-p 'tmux-control-mode))
    (tmux-control-chaos--in-displayed #'tmux-control-scrollback)
    (let ((w (tmux-control-chaos--win)))
      (when (with-current-buffer (window-buffer w)
              (derived-mode-p 'tmux-control-scrollback-mode))
        (with-selected-window w
          (dolist (dir '(wheel-down wheel-up wheel-down))
            (let ((b (key-binding (vector dir))))
              (when (commandp b)
                (funcall b (list dir (list w)))))))
        (unless (with-current-buffer (window-buffer (tmux-control-chaos--win))
                  (derived-mode-p 'tmux-control-scrollback-mode))
          (tmux-control-chaos--flag "pager bounced on jitter flick"))))
    (tmux-control-chaos--settle)
    (when (with-current-buffer (tmux-control-chaos--displayed)
            (derived-mode-p 'tmux-control-scrollback-mode))
      (tmux-control-chaos--in-displayed #'tmux-control-live))
    (tmux-control-chaos--settle)))

(tmux-control-chaos--defop tmux-control-chaos--op-switch-then-type 6
  ;; Send input the instant after a window switch, before the swap and
  ;; reseed settle.  The view must not strand and the input must reach a
  ;; pane (caught by the global oracle + stranded-view checks after the
  ;; settle); here we just provoke the transient.
  (let ((idx (number-to-string
              (tmux-control-chaos--rand tmux-control-chaos-windows))))
    (tmux-control-chaos--in-displayed
     (lambda () (tmux-control-select-window idx)))
    ;; NO settle -- type into whatever the swap is mid-installing.
    (with-current-buffer (tmux-control-chaos--displayed)
      (when (and (derived-mode-p 'tmux-control-mode) tmux-control--terminal)
        (tmux-control--send-input tmux-control--terminal "\C-u")
        (tmux-control--send-input
         tmux-control--terminal
         (format " echo t%d" (tmux-control-chaos--rand 1000)))))
    (tmux-control-chaos--settle)
    (with-current-buffer (tmux-control-chaos--displayed)
      (when (derived-mode-p 'tmux-control-mode)
        (tmux-control--send-input tmux-control--terminal "\C-u")))
    (tmux-control-chaos--settle)))

(tmux-control-chaos--defop tmux-control-chaos--op-reconnect-then-type 2
  ;; Type the instant after a reconnect, while the fresh connection is
  ;; still seeding.  Must not strand or lose the view.
  (tmux-control-chaos--in-displayed #'tmux-control-reconnect)
  (with-current-buffer (tmux-control-chaos--displayed)
    (when (and (derived-mode-p 'tmux-control-mode) tmux-control--terminal)
      (ignore-errors
        (tmux-control--send-input tmux-control--terminal "\C-u"))))
  (tmux-control-chaos--settle 15)
  (with-current-buffer (tmux-control-chaos--displayed)
    (when (derived-mode-p 'tmux-control-mode)
      (ignore-errors (tmux-control--send-input tmux-control--terminal "\C-u"))))
  (tmux-control-chaos--settle))

(defun tmux-control-chaos--pick-op ()
  (let* ((total (apply #'+ (mapcar #'cdr tmux-control-chaos--ops)))
         (r (tmux-control-chaos--rand total)))
    (catch 'pick
      (dolist (entry tmux-control-chaos--ops)
        (when (< r (cdr entry)) (throw 'pick (car entry)))
        (setq r (- r (cdr entry)))))))

;;;; Invariants

(defun tmux-control-chaos--screen-tail (buf n)
  (last (mapcar #'string-trim-right
                (split-string
                 (string-trim-right (tmux-control-chaos--screen-text buf))
                 "\n"))
        n))

(defun tmux-control-chaos--capture-tail (pane n)
  (last (mapcar #'string-trim-right
                (split-string
                 (string-trim-right
                  (tmux-control-chaos--tmux-out "capture-pane" "-p" "-t" pane))
                 "\n"))
        n))

(defun tmux-control-chaos--check (step op)
  ;; Transient problems the op detected inline (gone by now) come first.
  (let ((problems (prog1 tmux-control-chaos--op-problems
                    (setq tmux-control-chaos--op-problems nil))))
    ;; Stranded view?
    (let ((b (tmux-control-chaos--displayed)))
      (unless (with-current-buffer b
                (or (derived-mode-p 'tmux-control-mode)
                    (derived-mode-p 'tmux-control-scrollback-mode)))
        (push (format "stranded view: %s" (buffer-name b)) problems)))
    (let ((ctrl (ignore-errors (tmux-control-chaos--ctrl))))
      (if (not ctrl)
          (push "no live controller" problems)
        ;; Queue drained?
        (when (buffer-local-value 'tmux-control--command-queue ctrl)
          (push "queue not drained" problems))
        ;; Render oracle on the displayed live buffer.
        (let ((b (tmux-control-chaos--displayed)))
          (when (with-current-buffer b (derived-mode-p 'tmux-control-mode))
            (let ((pane (buffer-local-value 'tmux-control--active-pane b)))
              (when (and pane
                         (not (equal (tmux-control-chaos--screen-tail b 2)
                                     (tmux-control-chaos--capture-tail pane 2))))
                ;; Settle-retry: a diff is usually in-flight output, not a
                ;; failure.  A prompt's volatile bits settle a touch slower
                ;; (a starship prompt flashes "took Ns" for a finished
                ;; command, briefly differing between Eat and capture), so
                ;; pump a few times and re-compare; only a diff that
                ;; persists is a real desync.
                (let ((diff t))
                  (dotimes (_ 4)
                    (when diff
                      (tmux-control-chaos--pump 0.8)
                      (setq diff (not (equal (tmux-control-chaos--screen-tail b 2)
                                             (tmux-control-chaos--capture-tail pane 2))))))
                  (when diff
                    (push (format "oracle diff: eat=%S cap=%S"
                                  (mapcar #'substring-no-properties
                                          (tmux-control-chaos--screen-tail b 2))
                                  (tmux-control-chaos--capture-tail pane 2))
                          problems)))))))
        ;; Buffers bounded (Eat's scrollback trim at work).
        (dolist (b (buffer-list))
          (when (with-current-buffer b (derived-mode-p 'tmux-control-mode))
            (when (> (buffer-size b) 400000)
              (push (format "buffer %s grew to %d chars"
                            (buffer-name b) (buffer-size b))
                    problems))))
        ;; Timer sanity.
        (when (> (length timer-list) 25)
          (push (format "timer-list grew to %d" (length timer-list))
                problems))))
    (when problems
      (push (list step op problems) tmux-control-chaos--failures))
    problems))

;;;; Runners

(defun tmux-control-chaos--recover ()
  "Reconnect if the displayed buffer lost its connection.
A real user whose control client dies just reconnects (C-c C-r); without
this, ONE dropped connection makes every later op error \"process is not
live\" and the run reports a cascade of the same failure instead of
continuing.  Run between ops; returns non-nil if it reconnected."
  (let ((b (tmux-control-chaos--displayed)))
    (when (and (buffer-live-p b)
               (with-current-buffer b
                 (and (derived-mode-p 'tmux-control-mode)
                      tmux-control--session
                      (not (process-live-p tmux-control--process)))))
      (ignore-errors (tmux-control-chaos--in-displayed #'tmux-control-reconnect))
      (tmux-control-chaos--settle 15)
      t)))

(defun tmux-control-chaos-run (steps seed)
  "Run STEPS random ops from SEED; return the failure list (nil = clean)."
  (setq tmux-control-chaos--seed seed
        tmux-control-chaos--trace nil
        tmux-control-chaos--failures nil
        tmux-control-chaos--op-problems nil)
  (dotimes (i steps)
    (let ((op (tmux-control-chaos--pick-op)))
      (push (cons i op) tmux-control-chaos--trace)
      (condition-case err
          (funcall op)
        (error (push (list i op (list (format "OP ERROR: %S" err)))
                     tmux-control-chaos--failures)))
      (tmux-control-chaos--check i op)
      (tmux-control-chaos--recover)))
  (reverse tmux-control-chaos--failures))

(defun tmux-control-chaos-run-until-failure (steps seed)
  "Like `tmux-control-chaos-run' but stop at the first failure.
The live state is left frozen for inspection; `tmux-control-chaos--trace'
holds the operations that led there."
  (setq tmux-control-chaos--seed seed
        tmux-control-chaos--trace nil
        tmux-control-chaos--failures nil
        tmux-control-chaos--op-problems nil)
  (catch 'stop
    (dotimes (i steps)
      (let ((op (tmux-control-chaos--pick-op)))
        (push (cons i op) tmux-control-chaos--trace)
        (condition-case err
            (funcall op)
          (error (push (list i op (list (format "OP ERROR: %S" err)))
                       tmux-control-chaos--failures)))
        (when (tmux-control-chaos--check i op)
          (throw 'stop (car tmux-control-chaos--failures)))))
    :clean))

(provide 'tmux-control-chaos)
;;; tmux-control-chaos.el ends here