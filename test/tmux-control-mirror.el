;;; tmux-control-mirror.el --- Check Emacs's copy of tmux's state -*- lexical-binding: t; -*-

;;; Commentary:

;; tmux-control keeps a copy of tmux's windows, sessions and panes, and its
;; tabs, buffers and keystrokes act on that copy.  docs/mirror-rules.md says
;; what must hold; `tmux-control-mirror-problems' checks each rule by asking
;; tmux over a connection of its own, so a wrong belief about tmux shows up
;; as a disagreement rather than passing in a model of the same belief.
;;
;; A run plays a random but reproducible sequence of steps against a
;; throwaway server with two sessions.  Some come from Emacs (switching,
;; new, kill, rename, moving between sessions) and some from outside (another
;; client making, killing, moving, sharing and renaming windows, and
;; switching in either session).  Some steps wait for quiet and check; the
;; rest fire back to back, so replies arrive late, as they do over SSH.
;;
;; It runs in batch or in a GUI Emacs:
;;
;;   emacs -Q --batch -L <eat-dir> -L . -l test/tmux-control-mirror.el \
;;     --eval '(tmux-control-mirror-batch 1 60)'      ; SEED STEPS
;;
;; A failure names the rule and the shortest sequence that still fails,
;; which `tmux-control-mirror-replay' plays again.
;;
;; Use a throwaway Emacs: each run erases *Messages*, where it looks for
;; Lisp errors, and loading this file advises `tmux-control--filter'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tmux-control)

(defvar tmux-control-mirror-socket (format "tc-mirror-%d" (emacs-pid))
  "The throwaway tmux server's socket name.")
(defvar tmux-control-mirror-patience 3.0
  "Seconds a disagreement must last to count.")
(defvar tmux-control-mirror-world '(:window-buffers all :names tab)
  "The options a run uses: `:window-buffers' and `:names'.")
(defvar tmux-control-mirror-verbose nil
  "Non-nil logs each step to standard error.")
(defvar tmux-control-mirror-skip nil
  "Rules not to count, to see past a known failure.")

(defvar tmux-control-mirror--prompt-problems nil
  "What went wrong with prompts during this run, as (RULE . DETAIL).")

(defconst tmux-control-mirror--hostile-names
  '("a b" "semi;colon" "it's" "say\"hi" "$(touch x)" "back\\slash" "日本語"
    "🙂 smile" "-dash" "%pct" "#[fg=red]" "tail " "x:y" "*star*")
  "Window names that have to survive quoting and parsing.")

;;;; Asking tmux

(defun tmux-control-mirror--tmux (&rest args)
  "Run tmux with ARGS on the run's server; return its output, or nil on failure."
  (with-temp-buffer
    (when (eq 0 (apply #'call-process "tmux" nil t nil
                       "-u" "-L" tmux-control-mirror-socket args))
      (buffer-string))))

(defun tmux-control-mirror--lines (&rest args)
  "The lines tmux prints for ARGS."
  (split-string (or (apply #'tmux-control-mirror--tmux args) "") "\n" t))

(defun tmux-control-mirror--windows-of (session)
  "tmux's own list of SESSION's windows, as plists in its order."
  (mapcar
   (lambda (line)
     (let ((cells (split-string line "\t")))
       (list :id (nth 0 cells) :index (nth 1 cells)
             :active (equal (nth 2 cells) "1")
             :last (equal (nth 3 cells) "1")
             :pane (nth 4 cells)
             :width (string-to-number (nth 5 cells))
             :height (string-to-number (nth 6 cells))
             :panes (string-to-number (nth 7 cells))
             :linked (equal (nth 8 cells) "1")
             :name (string-join (nthcdr 9 cells) "\t"))))
   (tmux-control-mirror--lines
    "list-windows" "-t" (concat "=" session ":")
    "-F" (concat "#{window_id}\t#{window_index}\t#{window_active}\t"
                 "#{window_last_flag}\t#{pane_id}\t#{pane_width}\t"
                 "#{pane_height}\t#{window_panes}\t#{window_linked}\t"
                 "#{window_name}"))))

(defun tmux-control-mirror--sessions ()
  "tmux's own list of session names, in its order."
  (tmux-control-mirror--lines "list-sessions" "-F" "#{session_name}"))

;;;; The rules

(defun tmux-control-mirror--owned-p (buffer controller)
  "Non-nil when BUFFER is CONTROLLER or one of its window's buffers."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (and (derived-mode-p 'tmux-control-mode)
              (or (eq buffer controller)
                  (eq tmux-control--controller controller))))))

(defun tmux-control-mirror--window-buffers (controller)
  "CONTROLLER's buffers for tmux windows, as (ID . BUFFER)."
  (with-current-buffer controller
    (let ((own (and tmux-control--window-id
                    (list (cons tmux-control--window-id controller)))))
      (append own
              (seq-filter (lambda (entry)
                            (and (buffer-live-p (cdr entry))
                                 (not (eq (cdr entry) controller))))
                          tmux-control--window-buffers)))))

(defun tmux-control-mirror--buffer-of (controller id)
  "CONTROLLER's buffer for window ID, or nil."
  (cdr (assoc id (tmux-control-mirror--window-buffers controller))))

(defun tmux-control-mirror--lit-tabs ()
  "The tabs of the current buffer's tab bar drawn as the current window's."
  (let* ((bar (tmux-control--window-tab-bar t))
         (i 0) lit)
    (while (< i (length bar))
      (let ((end (or (next-single-property-change i 'face bar) (length bar))))
        (when (eq (get-text-property i 'face bar) 'tmux-control-tab-active)
          (push (substring-no-properties bar i end) lit))
        (setq i end)))
    (nreverse lit)))

(defun tmux-control-mirror--screen-problems (buffer pane)
  "How BUFFER's screen differs from tmux's PANE, as a string, or nil."
  (let ((mine (tmux-control--rtrim-screen-lines
               (tmux-control--visible-screen-lines buffer)))
        (theirs (tmux-control--rtrim-screen-lines
                 (split-string
                  (string-trim-right
                   (or (tmux-control-mirror--tmux "capture-pane" "-p" "-t" pane) ""))
                  "\n"))))
    (unless (equal mine theirs)
      (let ((row (or (cl-mismatch mine theirs :test #'equal) 0)))
        (format "row %d: emacs %S, tmux %S" row (nth row mine) (nth row theirs))))))

(defun tmux-control-mirror-problems (controller)
  "Where CONTROLLER's copy of its session disagrees with tmux.
A list of (RULE . DETAIL)."
  (with-current-buffer controller
    (let* ((session tmux-control--session)
           (truth (tmux-control-mirror--windows-of session))
           (current (seq-find (lambda (w) (plist-get w :active)) truth))
           (buffers (and tmux-control-window-buffers
                         (tmux-control-mirror--window-buffers controller)))
           problems)
      (cl-flet ((flag (rule fmt &rest args)
                  (push (cons rule (concat session ": " (apply #'format fmt args)))
                        problems))
                (brief (windows keys)
                  (mapcar (lambda (w) (mapcar (lambda (k) (plist-get w k)) keys))
                          windows)))
        (when truth
          ;; windows
          (let ((mine (brief tmux-control--windows '(:id :index :name)))
                (theirs (brief truth '(:id :index :name))))
            (unless (equal mine theirs)
              (flag 'windows "emacs %S, tmux %S" mine theirs)))
          ;; current
          (let ((marked (seq-filter (lambda (w) (plist-get w :active))
                                    tmux-control--windows)))
            (unless (and (= (length marked) 1)
                         (equal (plist-get (car marked) :id)
                                (plist-get current :id))
                         (equal tmux-control--current-window
                                (plist-get current :index)))
              (flag 'current "emacs marks %S (index %S), tmux has %S"
                    (brief marked '(:id)) tmux-control--current-window
                    (plist-get current :id))))
          ;; view
          (when (and tmux-control-window-buffers (not tmux-control--tiled))
            (let ((wanted (tmux-control-mirror--buffer-of
                           controller (plist-get current :id))))
              (dolist (frame (frame-list))
                (dolist (window (window-list frame 'nomini))
                  (let ((shown (window-buffer window)))
                    (when (and (tmux-control-mirror--owned-p shown controller)
                               (not (eq shown wanted)))
                      (flag 'view "%s shows %s, tmux is on %s (%s)"
                            window (buffer-name shown) (plist-get current :id)
                            (and wanted (buffer-name wanted)))))))))
          ;; buffers
          (when tmux-control-window-buffers
            (let ((ids (mapcar (lambda (w) (plist-get w :id)) truth)))
              (dolist (entry buffers)
                (unless (member (car entry) ids)
                  (flag 'buffers "%s still has buffer %s"
                        (car entry) (buffer-name (cdr entry)))))
              (dolist (buffer (buffer-list))
                (when (and (not (eq buffer controller))
                           (tmux-control-mirror--owned-p buffer controller))
                  (let ((id (buffer-local-value 'tmux-control--window-id buffer)))
                    (when (and id (not (member id ids)))
                      (flag 'buffers "orphan %s for %s" (buffer-name buffer) id)))))
              (let ((seen (mapcar #'car buffers)))
                (unless (= (length seen) (length (delete-dups (copy-sequence seen))))
                  (flag 'buffers "two buffers for one window: %S" seen)))
              (when (eq tmux-control-window-buffers 'all)
                (dolist (id ids)
                  (unless (assoc id buffers)
                    (flag 'buffers "%s has no buffer" id))))))
          ;; typing, size, names, for each window with a buffer
          (unless tmux-control--tiled
            (dolist (w truth)
              (when-let* ((buffer (if tmux-control-window-buffers
                                      (cdr (assoc (plist-get w :id) buffers))
                                    (and (plist-get w :active) controller))))
                (let ((pane (buffer-local-value 'tmux-control--active-pane buffer)))
                  (unless (equal pane (plist-get w :pane))
                    (flag 'typing "%s aims at %S, tmux's active pane is %s"
                          (buffer-name buffer) pane (plist-get w :pane))))
                (with-current-buffer buffer
                  (let ((size (and tmux-control--terminal
                                   (tmux-control--term-size))))
                    (unless (or (null size)
                                (equal size (cons (plist-get w :width)
                                                  (plist-get w :height))))
                      (flag 'size "%s is %S, its pane %dx%d"
                            (buffer-name buffer) size
                            (plist-get w :width) (plist-get w :height)))))
                (when (eq tmux-control-window-buffer-names 'tab)
                  (let ((wanted (tmux-control--derived-buffer-name
                                 (tmux-control--buffer-name
                                  tmux-control--host tmux-control--socket-name session)
                                 (tmux-control--window-label w))))
                    (unless (string-prefix-p (string-remove-suffix "*" wanted)
                                             (buffer-name buffer))
                      (flag 'names "%s should be %s" (buffer-name buffer) wanted)))))))
          ;; tabs: the highlighted tab is the window on screen
          (dolist (frame (frame-list))
            (dolist (window (window-list frame 'nomini))
              (let ((shown (window-buffer window)))
                (when (and (not tmux-control--tiled)
                           (tmux-control-mirror--owned-p shown controller))
                  (let* ((id (if tmux-control-window-buffers
                                 (buffer-local-value 'tmux-control--window-id shown)
                               (plist-get current :id)))
                         (here (seq-find (lambda (w) (equal (plist-get w :id) id)) truth))
                         (lit (with-current-buffer shown
                                (tmux-control-mirror--lit-tabs))))
                    (unless (and here (= (length lit) 1)
                                 (string-prefix-p
                                  (format " %s:" (plist-get here :index)) (car lit)))
                      (flag 'tabs "%s lights %S, shows window %S"
                            (buffer-name shown) lit (plist-get here :index))))))))
          ;; fit: tmux sizes the shown window to its Emacs window
          (when (and current (not tmux-control--tiled)
                     (= (plist-get current :panes) 1)
                     (not (plist-get current :linked)))
            (when-let* ((buffer (if tmux-control-window-buffers
                                    (cdr (assoc (plist-get current :id) buffers))
                                  controller))
                        (windows (get-buffer-window-list buffer nil t)))
              (unless (cdr windows)
                (let ((size (with-current-buffer buffer
                              (tmux-control--window-size (car windows)))))
                  (unless (equal size (cons (plist-get current :width)
                                            (plist-get current :height)))
                    (flag 'fit "%s's window is %S, its pane %dx%d"
                          (buffer-name buffer) size
                          (plist-get current :width) (plist-get current :height)))))))
          ;; last
          (let ((predicted (tmux-control--predict-window "last-window"))
                (last (seq-find (lambda (w) (plist-get w :last)) truth)))
            (when (and predicted
                       (not (equal predicted (plist-get last :id))))
              (flag 'last "emacs would go to %s, tmux to %S"
                    predicted (plist-get last :id))))
          ;; screen
          (let* ((buffer (and current
                              (if tmux-control-window-buffers
                                  (cdr (assoc (plist-get current :id) buffers))
                                controller)))
                 (detail (and buffer (not tmux-control--tiled)
                              (get-buffer-window buffer t)
                              (tmux-control-mirror--screen-problems
                               buffer (plist-get current :pane)))))
            (when detail (flag 'screen "%s" detail))))
        ;; sessions
        (let ((theirs (tmux-control-mirror--sessions)))
          (unless (equal tmux-control--sessions theirs)
            (flag 'sessions "emacs %S, tmux %S" tmux-control--sessions theirs)))
        ;; settled
        (when (or tmux-control--command-queue tmux-control--collecting-command)
          (flag 'settled "commands unanswered: %d"
                (length tmux-control--command-queue)))
        (when (> tmux-control--switch-pending 0)
          (flag 'settled "switches unconfirmed: %d" tmux-control--switch-pending))
        (when (or (timerp tmux-control--retile-timer)
                  tmux-control--tiling-build-active)
          (flag 'settled "a re-tile is on its way")))
      (nreverse problems))))

(defun tmux-control-mirror--lisp-errors ()
  "Errors logged in *Messages* since the run began, as (errors . LINE)."
  (when-let* ((buffer (get-buffer "*Messages*")))
    (with-current-buffer buffer
      (save-excursion
        (goto-char (point-min))
        (let (found)
          (while (re-search-forward
                  "^\\(?:error in process \\(?:filter\\|sentinel\\)\\|Error running timer\\).*$"
                  nil t)
            (push (cons 'errors (match-string 0)) found))
          (nreverse found))))))

;;;; Latency

(defvar tmux-control-mirror-latency nil
  "Seconds to hold what tmux sends before Emacs reads it, to mimic SSH.")

(defvar tmux-control-mirror--replaying nil
  "Non-nil while a held chunk is being read.")

(defun tmux-control-mirror--hold-chunk (filter process chunk)
  "Call FILTER on PROCESS's CHUNK after `tmux-control-mirror-latency'."
  (if (or (null tmux-control-mirror-latency) tmux-control-mirror--replaying)
      (funcall filter process chunk)
    (run-at-time tmux-control-mirror-latency nil
                 (lambda ()
                   ;; A dead connection reads nothing more, held or not.
                   (when (process-live-p process)
                     (let ((tmux-control-mirror--replaying t))
                       (funcall filter process chunk)))))))

(advice-add 'tmux-control--filter :around #'tmux-control-mirror--hold-chunk)

;;;; Waiting for quiet

(defun tmux-control-mirror--run-controllers ()
  "The controllers of this run's server, connected or not."
  (seq-filter (lambda (buffer)
                (with-current-buffer buffer
                  (and (derived-mode-p 'tmux-control-mode)
                       (not tmux-control--controller)
                       (equal tmux-control--socket-name tmux-control-mirror-socket))))
              (buffer-list)))

(defun tmux-control-mirror--controllers ()
  "The live controllers of this run's server."
  (seq-filter (lambda (buffer)
                (let ((process (buffer-local-value 'tmux-control--process buffer)))
                  (and (processp process) (process-live-p process))))
              (tmux-control-mirror--run-controllers)))

(defvar tmux-control-mirror--connected nil
  "The sessions this run has been connected to.")

(defun tmux-control-mirror--session-names (controllers)
  "The sessions CONTROLLERS are for."
  (delq nil (mapcar (lambda (buffer)
                      (buffer-local-value 'tmux-control--session buffer))
                    controllers)))

(defun tmux-control-mirror--lost-connections ()
  "A (connection . DETAIL) for each session still there that lost its client.
The checks only visit live connections, so without this a run that lost
one would go on passing.  A controller names its session even if it
dropped before the first check."
  (let ((sessions (tmux-control-mirror--sessions))
        (live (tmux-control-mirror--session-names
               (tmux-control-mirror--controllers))))
    (setq tmux-control-mirror--connected
          (seq-filter (lambda (session) (member session sessions))
                      (delete-dups
                       (append (tmux-control-mirror--session-names
                                (tmux-control-mirror--run-controllers))
                               tmux-control-mirror--connected))))
    (mapcar (lambda (session)
              (cons 'connection (format "%s: lost its connection" session)))
            (seq-remove (lambda (session) (member session live))
                        tmux-control-mirror--connected))))

(defun tmux-control-mirror--run-retiles ()
  "Run the re-tiles waiting for Emacs to idle, which batch never does."
  (when noninteractive
    (dolist (controller (tmux-control-mirror--controllers))
      (with-current-buffer controller
        (when (timerp tmux-control--retile-timer)
          (let ((timer tmux-control--retile-timer))
            (cancel-timer timer)
            (apply (timer--function timer) (timer--args timer))))))))

(defun tmux-control-mirror--pump (secs)
  "Let process output, timers and redisplay run for SECS."
  (let ((end (+ (float-time) secs)))
    (while (< (float-time) end)
      (accept-process-output nil 0.01)
      (redisplay))))

(defun tmux-control-mirror--barrier (controller)
  "Wait for a round trip through CONTROLLER's connection."
  (let ((done nil)
        (end (+ (float-time) 5)))
    (with-current-buffer controller
      (tmux-control--query "display-message -p ok" (lambda (_) (setq done t))))
    (while (and (not done) (< (float-time) end)
                (buffer-live-p controller)
                (process-live-p (buffer-local-value 'tmux-control--process controller)))
      (accept-process-output nil 0.01))))

(defun tmux-control-mirror--check ()
  "Disagreements that last `tmux-control-mirror-patience', as (RULE . DETAIL)."
  (let ((end (+ (float-time) tmux-control-mirror-patience))
        problems)
    (while (progn
             (tmux-control-mirror--run-retiles)
             (mapc #'tmux-control-mirror--barrier (tmux-control-mirror--controllers))
             (setq problems
                   (seq-remove
                    (lambda (problem)
                      (memq (car problem) tmux-control-mirror-skip))
                    (append tmux-control-mirror--prompt-problems
                            (tmux-control-mirror--lost-connections)
                            (mapcan #'tmux-control-mirror-problems
                                    (tmux-control-mirror--controllers))
                            (tmux-control-mirror--lisp-errors))))
             (and problems (< (float-time) end)))
      (tmux-control-mirror--pump 0.15))
    problems))

;;;; Steps
;;
;; A step is (OP R PAUSE).  OP names a function of R, a random integer that
;; picks its target when it runs, so a sequence still means something with
;; steps taken out.  PAUSE is `check', to wait for quiet and check, or the
;; seconds to wait before the next step.

(defvar tmux-control-mirror--ops nil
  "Alist of (OP . WEIGHT).")

(defmacro tmux-control-mirror--defop (name weight arglist &rest body)
  "Define step NAME with selection WEIGHT, ARGLIST and BODY."
  (declare (indent 3))
  (let ((function (intern (format "tmux-control-mirror--op-%s" name))))
    `(progn
       (defun ,function ,arglist ,@body)
       (setf (alist-get ',name tmux-control-mirror--ops) ,weight))))

(defun tmux-control-mirror--pick (r list)
  "The element of LIST that R picks, or nil."
  (and list (nth (mod r (length list)) list)))

(defun tmux-control-mirror--shown-buffer ()
  "The buffer in the selected window."
  (window-buffer (selected-window)))

(defun tmux-control-mirror--shown-session ()
  "The session shown in the selected window, or \"a\"."
  (or (buffer-local-value 'tmux-control--session (tmux-control-mirror--shown-buffer))
      "a"))

(defun tmux-control-mirror--other-session ()
  "A session other than the one shown."
  (if (equal (tmux-control-mirror--shown-session) "a") "b" "a"))

(defun tmux-control-mirror--pick-window (r &optional session)
  "The window of SESSION, by default the one shown, that R picks."
  (tmux-control-mirror--pick
   r (tmux-control-mirror--windows-of
      (or session (tmux-control-mirror--shown-session)))))

(defun tmux-control-mirror--in-view (function &rest args)
  "Call FUNCTION with ARGS in the buffer in the selected window."
  (with-current-buffer (tmux-control-mirror--shown-buffer)
    (when (derived-mode-p 'tmux-control-mode)
      (apply function args))))

;; From Emacs

(tmux-control-mirror--defop select 12 (r)
  (when-let* ((w (tmux-control-mirror--pick-window r)))
    (tmux-control-mirror--in-view #'tmux-control-select-window (plist-get w :index))))

(tmux-control-mirror--defop next 8 (_r)
  (tmux-control-mirror--in-view #'tmux-control-next-window))

(tmux-control-mirror--defop previous 6 (_r)
  (tmux-control-mirror--in-view #'tmux-control-previous-window))

(tmux-control-mirror--defop last 8 (_r)
  (tmux-control-mirror--in-view #'tmux-control-last-window))

(tmux-control-mirror--defop new 5 (r)
  (tmux-control-mirror--in-view #'tmux-control-new-window (format "n%d" (mod r 100))))

(tmux-control-mirror--defop kill 5 (r)
  (let ((windows (tmux-control-mirror--windows-of
                  (tmux-control-mirror--shown-session))))
    (when (cdr windows)
      (tmux-control-mirror--in-view
       #'tmux-control-kill-window
       (plist-get (tmux-control-mirror--pick r windows) :index)))))

(tmux-control-mirror--defop rename 4 (r)
  (when-let* ((w (tmux-control-mirror--pick-window r)))
    (tmux-control-mirror--in-view
     #'tmux-control-rename-window (plist-get w :index)
     (tmux-control-mirror--pick r tmux-control-mirror--hostile-names))))

(tmux-control-mirror--defop next-session 3 (_r)
  (tmux-control-mirror--in-view #'tmux-control-next-session))

(tmux-control-mirror--defop previous-session 2 (_r)
  (tmux-control-mirror--in-view #'tmux-control-previous-session))

;; From outside, in the session shown

(tmux-control-mirror--defop out-new 4 (r)
  (tmux-control-mirror--tmux
   "new-window" "-d" "-t" (concat (tmux-control-mirror--shown-session) ":")
   "-n" (format "o%d" (mod r 100))))

(tmux-control-mirror--defop out-new-select 3 (r)
  (tmux-control-mirror--tmux
   "new-window" "-t" (concat (tmux-control-mirror--shown-session) ":")
   "-n" (format "s%d" (mod r 100))))

(tmux-control-mirror--defop out-kill 4 (r)
  (let ((windows (tmux-control-mirror--windows-of
                  (tmux-control-mirror--shown-session))))
    (when (cdr windows)
      (tmux-control-mirror--tmux
       "kill-window" "-t" (plist-get (tmux-control-mirror--pick r windows) :id)))))

(tmux-control-mirror--defop out-rename 3 (r)
  (when-let* ((w (tmux-control-mirror--pick-window r)))
    (tmux-control-mirror--tmux
     "rename-window" "-t" (plist-get w :id)
     (tmux-control-mirror--pick r tmux-control-mirror--hostile-names))))

(tmux-control-mirror--defop out-select 6 (r)
  (when-let* ((w (tmux-control-mirror--pick-window r)))
    (tmux-control-mirror--tmux
     "select-window" "-t" (format "%s:%s" (tmux-control-mirror--shown-session)
                                  (plist-get w :id)))))

(tmux-control-mirror--defop out-next 3 (_r)
  (tmux-control-mirror--tmux "next-window" "-t" (tmux-control-mirror--shown-session)))

(tmux-control-mirror--defop out-last 3 (_r)
  (tmux-control-mirror--tmux "last-window" "-t" (tmux-control-mirror--shown-session)))

;; Weight 0: tmux tells control clients nothing of a swap.
(tmux-control-mirror--defop out-swap 0 (r)
  (let* ((session (tmux-control-mirror--shown-session))
         (a (tmux-control-mirror--pick-window r session))
         (b (tmux-control-mirror--pick-window (1+ r) session)))
    (when (and a b (not (equal a b)))
      (tmux-control-mirror--tmux
       "swap-window" "-s" (format "%s:%s" session (plist-get a :index))
       "-t" (format "%s:%s" session (plist-get b :index))))))

(tmux-control-mirror--defop out-move 2 (r)
  (let ((session (tmux-control-mirror--shown-session)))
    (when-let* ((w (tmux-control-mirror--pick-window r session)))
      (tmux-control-mirror--tmux
       "move-window" "-s" (format "%s:%s" session (plist-get w :index))
       "-t" (format "%s:%d" session (+ 20 (mod r 5)))))))

;; Windows between sessions

(tmux-control-mirror--defop out-link 3 (r)
  (let ((here (tmux-control-mirror--shown-session))
        (there (tmux-control-mirror--other-session)))
    (when-let* ((w (tmux-control-mirror--pick-window r there)))
      (tmux-control-mirror--tmux
       "link-window" "-d" "-s" (format "%s:%s" there (plist-get w :index))
       "-t" (concat here ":")))))

(tmux-control-mirror--defop out-unlink 3 (r)
  (let ((session (tmux-control-mirror--shown-session)))
    (when-let* ((w (tmux-control-mirror--pick-window r session)))
      ;; tmux refuses this for a window linked to one session.
      (tmux-control-mirror--tmux
       "unlink-window" "-t" (format "%s:%s" session (plist-get w :index))))))

(tmux-control-mirror--defop out-move-away 2 (r)
  (let* ((here (tmux-control-mirror--shown-session))
         (windows (tmux-control-mirror--windows-of here)))
    (when (cdr windows)
      (tmux-control-mirror--tmux
       "move-window" "-s" (format "%s:%s" here
                                  (plist-get (tmux-control-mirror--pick r windows) :index))
       "-t" (concat (tmux-control-mirror--other-session) ":")))))

(tmux-control-mirror--defop other-select 5 (r)
  (let ((there (tmux-control-mirror--other-session)))
    (when-let* ((w (tmux-control-mirror--pick-window r there)))
      (tmux-control-mirror--tmux
       "select-window" "-t" (format "%s:%s" there (plist-get w :index))))))

(tmux-control-mirror--defop other-new 2 (_r)
  (tmux-control-mirror--tmux
   "new-window" "-t" (concat (tmux-control-mirror--other-session) ":")))

;; Sessions

(tmux-control-mirror--defop session-new 2 (r)
  (tmux-control-mirror--tmux "new-session" "-d" "-s" (format "x%d" (mod r 4))))

(tmux-control-mirror--defop session-kill 2 (r)
  (when-let* ((name (tmux-control-mirror--pick
                     r (seq-filter (lambda (s) (string-prefix-p "x" s))
                                   (tmux-control-mirror--sessions)))))
    (unless (equal name (tmux-control-mirror--shown-session))
      (tmux-control-mirror--tmux "kill-session" "-t" (concat "=" name)))))

;; Panes

(tmux-control-mirror--defop out-split 4 (r)
  (when-let* ((w (tmux-control-mirror--pick-window r)))
    (tmux-control-mirror--tmux "split-window" "-t" (plist-get w :id))))

(tmux-control-mirror--defop out-select-pane 3 (r)
  (when-let* ((w (tmux-control-mirror--pick-window r))
              (pane (tmux-control-mirror--pick
                     r (tmux-control-mirror--lines
                        "list-panes" "-t" (plist-get w :id) "-F" "#{pane_id}"))))
    (tmux-control-mirror--tmux "select-pane" "-t" pane)))

(tmux-control-mirror--defop out-kill-pane 3 (r)
  (when-let* ((w (tmux-control-mirror--pick-window r))
              (panes (tmux-control-mirror--lines
                      "list-panes" "-t" (plist-get w :id) "-F" "#{pane_id}")))
    (when (cdr panes)
      (tmux-control-mirror--tmux "kill-pane" "-t" (tmux-control-mirror--pick r panes)))))

(tmux-control-mirror--defop out-break-pane 2 (r)
  (when-let* ((w (tmux-control-mirror--pick-window r))
              (panes (tmux-control-mirror--lines
                      "list-panes" "-t" (plist-get w :id) "-F" "#{pane_id}")))
    (when (cdr panes)
      (tmux-control-mirror--tmux "break-pane" "-d" "-s"
                                 (tmux-control-mirror--pick r panes)))))

(tmux-control-mirror--defop out-type 3 (r)
  (when-let* ((w (tmux-control-mirror--pick-window r)))
    (tmux-control-mirror--tmux "send-keys" "-t" (plist-get w :id)
                               (format "echo m%d" (mod r 1000)) "Enter")))

;; What you do to buffers and windows in Emacs

(defun tmux-control-mirror--session-buffers ()
  "The live buffers of the session shown, as (ID . BUFFER)."
  (let ((shown (tmux-control-mirror--shown-buffer)))
    (when (buffer-local-value 'tmux-control--session shown)
      (tmux-control-mirror--window-buffers
       (or (buffer-local-value 'tmux-control--controller shown) shown)))))

(tmux-control-mirror--defop show-buffer 6 (r)
  (let ((window (selected-window))
        (entries (tmux-control-mirror--session-buffers)))
    (when-let* ((entry (tmux-control-mirror--pick r entries)))
      ;; Windows side by side are left alone, so `view' doesn't apply.
      (unless (seq-find (lambda (other)
                          (seq-find (lambda (e) (eq (cdr e) (window-buffer other)))
                                    entries))
                        (remq window (window-list nil 'nomini)))
        (set-window-buffer window (cdr entry))
        ;; Batch has no redisplay to run the hook.
        (when noninteractive
          (with-current-buffer (cdr entry)
            (tmux-control--follow-shown-window window)))))))

;; Weight 0: a window whose buffer you killed has none until the next list.
(tmux-control-mirror--defop kill-buffer 0 (r)
  (let ((shown (tmux-control-mirror--shown-buffer)))
    (when-let* ((entry (tmux-control-mirror--pick
                        r (seq-remove
                           (lambda (e)
                             (or (eq (cdr e) shown)
                                 (null (buffer-local-value
                                        'tmux-control--controller (cdr e)))))
                           (tmux-control-mirror--session-buffers)))))
      (kill-buffer (cdr entry)))))

(tmux-control-mirror--defop reconnect 2 (_r)
  (tmux-control-mirror--in-view #'tmux-control-reconnect))

(tmux-control-mirror--defop tile 2 (_r)
  (tmux-control-mirror--in-view #'tmux-control-toggle-tiling))

(tmux-control-mirror--defop emacs-split 3 (_r)
  (unless (or noninteractive (cdr (window-list nil 'nomini)))
    (split-window-right)))

(tmux-control-mirror--defop emacs-unsplit 3 (_r)
  (unless noninteractive (delete-other-windows)))

(tmux-control-mirror--defop frame-resize 3 (r)
  (unless noninteractive
    (set-frame-size (selected-frame) (+ 90 (mod r 50)) (+ 24 (mod r 20)))))

(defun tmux-control-mirror--press-later (keys)
  "Press each of KEYS in turn, a moment apart, once a prompt is reading.
Each is a key description; a prompt's preview needs time between them."
  (let ((delay 0.3))
    (dolist (key keys)
      (run-at-time delay nil
                   (lambda ()
                     (tmux-control-mirror--check-prompt)
                     (setq unread-command-events
                           (append unread-command-events
                                   (listify-key-sequence (kbd key))))))
      (setq delay (+ delay 0.3)))))

(defun tmux-control-mirror--check-prompt ()
  "Note it if the minibuffer window has lost the prompt."
  (let ((shown (window-buffer (minibuffer-window))))
    (unless (minibufferp shown)
      (push (cons 'prompt (format "the minibuffer window shows %s" (buffer-name shown)))
            tmux-control-mirror--prompt-problems))))

(defun tmux-control-mirror--watch-prompt (seconds)
  "Close a prompt that is still open after SECONDS, and say so."
  (run-at-time
   seconds nil
   (lambda ()
     (tmux-control-mirror--check-prompt)
     (when (> (minibuffer-depth) 0)
       (push (cons 'prompt
                   (format "prompt %S still open; its window shows %s"
                           (minibuffer-prompt)
                           (buffer-name
                            (window-buffer (active-minibuffer-window)))))
             tmux-control-mirror--prompt-problems)
       (abort-recursive-edit)))))

(defun tmux-control-mirror--pick-with (command r finish)
  "Run COMMAND from a real prompt: move R times, then press FINISH.
Only with a real minibuffer: batch would read standard input."
  (unless noninteractive
    (tmux-control-mirror--press-later
     (append (make-list (mod r 3) "<down>") (list finish)))
    (let ((watch (tmux-control-mirror--watch-prompt 4)))
      (unwind-protect
          (with-selected-window (selected-window)
            (with-current-buffer (tmux-control-mirror--shown-buffer)
              (when (derived-mode-p 'tmux-control-mode)
                ;; Inline waits for the answer; the chooser returns at once.
                (let ((tmux-control-window-preview 'inline))
                  (condition-case nil
                      (call-interactively command)
                    (quit nil))))))
        (cancel-timer watch)
        (tmux-control-mirror--check-prompt)))))

(tmux-control-mirror--defop pick-window 6 (r)
  (tmux-control-mirror--pick-with #'tmux-control-select-window r "RET"))

(tmux-control-mirror--defop pick-window-cancel 6 (r)
  (tmux-control-mirror--pick-with #'tmux-control-select-window r "C-g"))

(tmux-control-mirror--defop pick-session 3 (r)
  (tmux-control-mirror--pick-with #'tmux-control-select-session r "RET"))

(tmux-control-mirror--defop pick-session-cancel 3 (r)
  (tmux-control-mirror--pick-with #'tmux-control-select-session r "C-g"))

;;;; Sequences

(defun tmux-control-mirror--generator (seed)
  "A function giving the next pseudo-random integer from SEED.
An LCG: Emacs's seeded `random' differs between builds."
  (let ((state seed))
    (lambda (n)
      (setq state (mod (+ (* state 1103515245) 12345) 2147483648))
      (mod (/ state 65536) n))))

(defun tmux-control-mirror-sequence (seed steps)
  "STEPS random steps from SEED."
  (let* ((rand (tmux-control-mirror--generator seed))
         (ops (sort (copy-sequence tmux-control-mirror--ops)
                    (lambda (a b) (string< (car a) (car b)))))
         (total (apply #'+ (mapcar #'cdr ops))))
    (cl-loop
     repeat steps
     collect
     (let ((roll (funcall rand total)) op)
       (dolist (entry ops)
         (when (and (null op) (< roll (cdr entry)))
           (setq op (car entry)))
         (setq roll (- roll (cdr entry))))
       (list op (funcall rand 100000)
             (pcase (funcall rand 10)
               ((or 0 1 2 3 4 5) 'check)
               ((or 6 7) 0)
               (8 0.01)
               (_ 0.05)))))))

;;;; Playing

(defun tmux-control-mirror--clear ()
  "Close this run's connections and kill its server."
  (dolist (buffer (buffer-list))
    (when (and (buffer-live-p buffer)
               (with-current-buffer buffer
                 (and (derived-mode-p 'tmux-control-mode)
                      (equal tmux-control--socket-name tmux-control-mirror-socket))))
      (with-current-buffer buffer
        (when (process-live-p tmux-control--process)
          (set-process-sentinel tmux-control--process #'ignore)
          (delete-process tmux-control--process)))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buffer))))
  (tmux-control-mirror--tmux "kill-server")
  (setq tmux-control-mirror--prompt-problems nil
        tmux-control-mirror--connected nil)
  (when-let* ((buffer (get-buffer "*Messages*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)) (erase-buffer)))))

(defun tmux-control-mirror--start ()
  "Start a fresh server, connect to session a and show it.
Returns the controller."
  (tmux-control-mirror--clear)
  (tmux-control-mirror--tmux
   "-f" "/dev/null" "new-session" "-d" "-s" "a" "-n" "a0" "-x" "100" "-y" "30"
   ";" "set-option" "-g" "default-shell" "/bin/sh"
   ";" "set-option" "-g" "default-command" "/bin/sh")
  (dolist (name '("a1" "a2"))
    (tmux-control-mirror--tmux "new-window" "-d" "-t" "a:" "-n" name))
  (tmux-control-mirror--tmux "new-session" "-d" "-s" "b" "-n" "b0" "-x" "100" "-y" "30")
  (tmux-control-mirror--tmux "new-window" "-d" "-t" "b:" "-n" "b1")
  (let ((buffer (tmux-control-connect nil tmux-control-mirror-socket "a")))
    (delete-other-windows)
    (set-window-buffer (selected-window) buffer)
    (tmux-control-mirror--pump 0.5)
    buffer))

(defmacro tmux-control-mirror--with-world (&rest body)
  "Run BODY with `tmux-control-mirror-world' in force."
  (declare (indent 0))
  `(let ((tmux-control-window-buffers
          (plist-get tmux-control-mirror-world :window-buffers))
         (tmux-control-window-buffer-names
          (plist-get tmux-control-mirror-world :names))
         (tmux-control-auto-reconnect nil))
     ,@body))

(defun tmux-control-mirror--log (fmt &rest args)
  "Log FMT with ARGS when verbose."
  (when tmux-control-mirror-verbose
    (princ (concat (apply #'format fmt args) "\n") #'external-debugging-output)))

(defun tmux-control-mirror-play (sequence)
  "Play SEQUENCE on a fresh server.
Returns nil when every check passes, or (:step N :problems PROBLEMS)."
  (tmux-control-mirror--with-world
    (tmux-control-mirror--start)
    (let ((step 0) failure)
      (setq failure (let ((first (tmux-control-mirror--check)))
                      (and first (list :step -1 :problems first))))
      (while (and sequence (not failure))
        (pcase-let ((`(,op ,r ,pause) (pop sequence)))
          (tmux-control-mirror--log "%d %S %S %S" step op r pause)
          (condition-case err
              (funcall (intern (format "tmux-control-mirror--op-%s" op)) r)
            (user-error (tmux-control-mirror--log "  refused: %s" (cadr err)))
            (error (setq failure
                         (list :step step :problems
                               (list (cons 'errors (format "%s: %S" op err)))))))
          (unless failure
            (if (eq pause 'check)
                (when-let* ((problems (tmux-control-mirror--check)))
                  (setq failure (list :step step :problems problems)))
              (tmux-control-mirror--pump pause))))
        (cl-incf step))
      (or failure
          (when-let* ((problems (tmux-control-mirror--check)))
            (list :step step :problems problems))))))

(defun tmux-control-mirror--rule-of (failure)
  "The first rule FAILURE broke."
  (car (car (plist-get failure :problems))))

(defun tmux-control-mirror-shrink (sequence rule)
  "The shortest part of SEQUENCE found that still breaks RULE.
Tries dropping chunks of steps, halving their size."
  (let ((chunk (max 1 (/ (length sequence) 2))))
    (while (> chunk 0)
      (let ((start 0))
        (while (< start (length sequence))
          (let* ((candidate (append (seq-take sequence start)
                                    (seq-drop sequence (+ start chunk))))
                 (failure (and candidate (tmux-control-mirror-play candidate))))
            (if (and failure (eq (tmux-control-mirror--rule-of failure) rule))
                (setq sequence candidate)
              (setq start (+ start chunk))))))
      (setq chunk (/ chunk 2)))
    sequence))

(defun tmux-control-mirror-replay (sequence)
  "Play SEQUENCE and say what it breaks, leaving the world for inspection."
  (let ((failure (tmux-control-mirror-play sequence)))
    (message "%S" failure)
    failure))

(defun tmux-control-mirror-batch (seed steps &optional no-shrink)
  "Run SEED for STEPS, print the result as a Lisp form, and exit.
Exits 0 when clean.  NO-SHRINK skips shrinking a failure."
  (let* ((sequence (tmux-control-mirror-sequence seed steps))
         (failure (tmux-control-mirror-play sequence))
         (played (and failure
                      (seq-take sequence (+ 1 (max 0 (plist-get failure :step))))))
         (rule (and failure (tmux-control-mirror--rule-of failure)))
         (short (and failure
                     (if no-shrink played
                       (tmux-control-mirror-shrink played rule))))
         (final (and short (tmux-control-mirror-play short))))
    (tmux-control-mirror--clear)
    (princ (format "%S\n" (list :seed seed :world tmux-control-mirror-world
                                :rule rule
                                :failure (or final failure)
                                :sequence short)))
    (kill-emacs (if failure 1 0))))

(provide 'tmux-control-mirror)
;;; tmux-control-mirror.el ends here
