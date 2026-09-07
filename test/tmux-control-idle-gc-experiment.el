;;; tmux-control-idle-gc-experiment.el --- Temporary GC scheduling probe -*- lexical-binding: t; -*-

;; Developer experiment only.  Not loaded by tmux-control.  Collection is
;; global to Emacs even though eligibility is gated on a selected fixture.
;; It cannot predict when input will resume.  Automatic GC limits are intact.
(require 'cl-lib)

(defvar tmux-control-idle-gc--timer nil)
(defvar tmux-control-idle-gc--buffer nil)
(defvar tmux-control-idle-gc--last-command 0)
(defvar tmux-control-idle-gc--cons-at-gc 0)
(defvar tmux-control-idle-gc--decisions nil)
(defvar tmux-control-idle-gc--quiet-seconds 1.0)
(defvar tmux-control-idle-gc--cons-budget 10000000)

(defun tmux-control-idle-gc--note-command ()
  (setq tmux-control-idle-gc--last-command (float-time)))

(defun tmux-control-idle-gc--note-collection ()
  (setq tmux-control-idle-gc--cons-at-gc (car (memory-use-counts))))

(defun tmux-control-idle-gc--eligible-p (idle-seconds allocated pending)
  "Whether IDLE-SECONDS and ALLOCATED warrant a collection with PENDING input."
  (and (not pending)
       (>= idle-seconds tmux-control-idle-gc--quiet-seconds)
       (>= allocated tmux-control-idle-gc--cons-budget)))

(defun tmux-control-idle-gc--check ()
  (if (not (buffer-live-p tmux-control-idle-gc--buffer))
      (tmux-control-idle-gc-experiment-stop)
    (when (eq (window-buffer (selected-window)) tmux-control-idle-gc--buffer)
      (let* ((now (float-time))
             (idle (- now tmux-control-idle-gc--last-command))
             (conses (- (car (memory-use-counts)) tmux-control-idle-gc--cons-at-gc)))
        (when (tmux-control-idle-gc--eligible-p idle conses (input-pending-p))
          (push (list :started_at now :idle_seconds idle :conses_since_gc conses)
                tmux-control-idle-gc--decisions)
          (garbage-collect))))))

(defun tmux-control-idle-gc-experiment-start (buffer)
  "Start temporary idle collection for selected fixture BUFFER.
Use actual command activity and allocation counters, without inspecting
future trace inputs or changing automatic GC thresholds.  Stop explicitly
with `tmux-control-idle-gc-experiment-stop' after the experiment."
  (when tmux-control-idle-gc--timer (error "An idle GC experiment is running"))
  (setq tmux-control-idle-gc--buffer buffer
        tmux-control-idle-gc--decisions nil)
  (tmux-control-idle-gc--note-command)
  (tmux-control-idle-gc--note-collection)
  (add-hook 'post-command-hook #'tmux-control-idle-gc--note-command)
  (add-hook 'post-gc-hook #'tmux-control-idle-gc--note-collection)
  (setq tmux-control-idle-gc--timer (run-at-time .05 .05 #'tmux-control-idle-gc--check)))

(defun tmux-control-idle-gc-experiment-stop ()
  "Remove the experiment's timer and hooks.  No GC settings need restoring."
  (interactive)
  (when (timerp tmux-control-idle-gc--timer) (cancel-timer tmux-control-idle-gc--timer))
  (setq tmux-control-idle-gc--timer nil tmux-control-idle-gc--buffer nil)
  (remove-hook 'post-command-hook #'tmux-control-idle-gc--note-command)
  (remove-hook 'post-gc-hook #'tmux-control-idle-gc--note-collection))

(provide 'tmux-control-idle-gc-experiment)
