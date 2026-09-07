;;; tmux-control-scroll-trace.el --- GUI scroll trajectories -*- lexical-binding: t; -*-

;; Developer tool, not loaded by the package.  Replay through Emacs's normal
;; command queue and keymaps.  This measures software state and redisplay
;; opportunities, NOT OS input latency, display presentation, or frame rate.
;; Use the numbered ASCII fixture in scroll-trace-workload.py.  Rows must fit
;; the window without wrapping and have uniform height.  See docs/guide.md.

(require 'cl-lib)
(require 'json)
(require 'pixel-scroll)
(require 'tmux-control)

(defvar tmux-control-trace--run nil)
(defvar tmux-control-trace--timers nil)
(defvar tmux-control-trace--active nil)
(defvar tmux-control-trace--input-timer nil)

(defun tmux-control-trace--now ()
  (* 1000 (- (float-time) (plist-get tmux-control-trace--run :epoch))))

(defun tmux-control-trace--position ()
  "Return content-relative pixels, or nil if the numbered anchor was lost.
Eat trims by characters and can leave a partial first row.  For that one
case, infer its number from the next complete fixture row and label it."
  (let ((window (plist-get tmux-control-trace--run :window)))
    (when (window-live-p window)
      (with-current-buffer (window-buffer window)
        (save-excursion
          (goto-char (window-start window))
          (beginning-of-line)
          (let ((row (cond
                      ((looking-at "ROW \\([0-9]+\\)")
                       (setf (plist-get tmux-control-trace--run :anchor-kind) "exact")
                       (string-to-number (match-string 1)))
                      ((and (= (point) (point-min))
                            (derived-mode-p 'tmux-control-mode)
                            (= (forward-line 1) 0)
                            (looking-at "ROW \\([0-9]+\\)"))
                       (setf (plist-get tmux-control-trace--run :anchor-kind) "inferred-next-row")
                       (1- (string-to-number (match-string 1)))))))
            (unless row (setf (plist-get tmux-control-trace--run :anchor-kind) "unknown"))
            (when row
              (+ (* (1- row) (plist-get tmux-control-trace--run :row-height))
                 (window-vscroll window t)))))))))

(defun tmux-control-trace--observe (kind)
  (when tmux-control-trace--run
    (let ((begin (float-time)))
      (push (list :time_ms (tmux-control-trace--now) :kind kind
                  :position_px (tmux-control-trace--position)
                  :anchor_kind (plist-get tmux-control-trace--run :anchor-kind)
                  :started (plist-get tmux-control-trace--run :started)
                  :completed (plist-get tmux-control-trace--run :completed))
            (plist-get tmux-control-trace--run :observations))
      (cl-incf (plist-get tmux-control-trace--run :observer-ms)
               (* 1000 (- (float-time) begin))))))

(defun tmux-control-trace--redisplay (window)
  (when (and tmux-control-trace--run
             (eq window (plist-get tmux-control-trace--run :window)))
    (tmux-control-trace--observe "pre-redisplay")))

(defun tmux-control-trace--before-command ()
  (when tmux-control-trace--run
    (when-let* ((sample (gethash last-command-event
                               (plist-get tmux-control-trace--run :pending))))
      (setq tmux-control-trace--active sample)
      (setf (plist-get sample :start_ms) (tmux-control-trace--now)
            (plist-get sample :before_px) (tmux-control-trace--position)
            (plist-get tmux-control-trace--run :started) (plist-get sample :id)))))

(defun tmux-control-trace--after-command ()
  (when (and tmux-control-trace--run tmux-control-trace--active)
    (let ((sample tmux-control-trace--active))
      (setf (plist-get sample :finish_ms) (tmux-control-trace--now)
            (plist-get sample :after_px) (tmux-control-trace--position)
            (plist-get sample :command) (symbol-name this-command)
            (plist-get tmux-control-trace--run :completed) (plist-get sample :id))
      (setq tmux-control-trace--active nil)
      (tmux-control-trace--observe "post-command"))))

(defun tmux-control-trace--enqueue (sample)
  (when tmux-control-trace--run
    (let* ((window (plist-get tmux-control-trace--run :window))
           (delta (plist-get sample :delta_px))
           ;; Pixel-scroll reads the fifth element as (DX . DY).  Positive
           ;; DY means wheel-up / movement toward older content in Emacs.
           (event (list (if (> delta 0) 'wheel-up 'wheel-down)
                        (list window (window-start window) '(10 . 10) 0)
                        nil 1 (cons 0 delta))))
      (setf (plist-get sample :enqueue_ms) (tmux-control-trace--now))
      (puthash event sample (plist-get tmux-control-trace--run :pending))
      (setq unread-command-events
            (nconc unread-command-events (list (cons 'no-record event)))))))

(defun tmux-control-trace--dispatch-due ()
  "Enqueue overdue inputs and schedule only the next absolute deadline.
Keeping hundreds of timers pending makes timer insertion itself allocate
heavily.  A rolling timer preserves the original schedule, including a
burst of overdue inputs after a main-loop pause."
  (setq tmux-control-trace--input-timer nil)
  (when tmux-control-trace--run
    (let ((now (tmux-control-trace--now)))
      (while (and (plist-get tmux-control-trace--run :remaining)
                  (<= (plist-get (car (plist-get tmux-control-trace--run :remaining))
                                 :scheduled_ms) now))
        (tmux-control-trace--enqueue
         (pop (plist-get tmux-control-trace--run :remaining)))))
    (when-let* ((sample (car (plist-get tmux-control-trace--run :remaining))))
      (setq tmux-control-trace--input-timer
            (run-at-time (seconds-to-time
                          (+ (plist-get tmux-control-trace--run :epoch)
                             (/ (plist-get sample :scheduled_ms) 1000)))
                         nil #'tmux-control-trace--dispatch-due)))))

(defun tmux-control-trace--after-gc ()
  "Record a collection's completion and elapsed GC time since the last one.
The hook runs after collection; its timestamp is not a measured GC start.
Keep function names only, never stack arguments or buffer contents."
  (when tmux-control-trace--run
    (let ((elapsed gc-elapsed))
      (push (list :completion_ms (tmux-control-trace--now)
                  :gc_ms (* 1000 (- elapsed (plist-get tmux-control-trace--run :gc-last)))
                  :stack (vconcat
                          (mapcar (lambda (frame)
                                    (let ((fn (nth 1 frame)))
                                      (if (symbolp fn) (symbol-name fn) "lambda")))
                                  (backtrace-frames))))
            (plist-get tmux-control-trace--run :gc-events))
      (setf (plist-get tmux-control-trace--run :gc-last) elapsed))))

(defun tmux-control-trace-plan (hz)
  "Return the same five-second movement at HZ events per second.
Three seconds up at 960 pixels/sec, a half-second hold, one second down
at 480 pixels/sec, and a final half-second hold.  60 and 120 divide both
rates exactly.  The holds expose drift and delayed movement after input."
  (unless (memq hz '(60 120)) (error "Use 60 or 120 Hz"))
  (let ((id 0) samples)
    (dotimes (i (* 3 hz))
      (push (list :id (cl-incf id) :scheduled_ms (+ 250 (* i (/ 1000.0 hz)))
                  :delta_px (/ 960 hz)
                  :enqueue_ms nil :start_ms nil :finish_ms nil
                  :before_px nil :after_px nil :command nil) samples))
    (dotimes (i hz)
      (push (list :id (cl-incf id) :scheduled_ms (+ 3750 (* i (/ 1000.0 hz)))
                  :delta_px (- (/ 480 hz))
                  :enqueue_ms nil :start_ms nil :finish_ms nil
                  :before_px nil :after_px nil :command nil) samples))
    (nreverse samples)))

(defun tmux-control-scroll-trace-start (label directory &optional hz)
  "Replay a fixed pixel-input trace in the selected fixture window.
Write LABEL.json into DIRECTORY after six seconds.  HZ defaults to 60.
Do not type or scroll in this window during the replay.  The queue follows
normal keymaps, and no redisplay is forced during recording.  Timer wakeup,
queue delay, command cost, content position, and pre-redisplay observations
are recorded separately.  Existing scrolling preferences are untouched."
  (interactive "sRun label: \nDOutput directory: ")
  (when tmux-control-trace--run (user-error "A scroll trace is already running"))
  (unless (and (display-graphic-p) (bound-and-true-p pixel-scroll-precision-mode))
    (user-error "Use GUI Emacs with pixel-scroll-precision-mode enabled"))
  (unless (derived-mode-p 'tmux-control-mode 'tmux-control-scrollback-mode)
    (user-error "Select a numbered tmux-control fixture buffer"))
  (unless (string-match-p "\\`[a-zA-Z0-9_-]+\\'" label)
    (user-error "Use a simple filename label"))
  (let* ((window (selected-window))
         (height (car (window-line-height 1 window)))
         (samples (tmux-control-trace-plan (or hz 60))))
    (unless height (user-error "Redisplay the fixture window before starting"))
    (setq tmux-control-trace--run
          (list :epoch (float-time) :window window :row-height height
                :label label :directory (expand-file-name directory)
                :hz (or hz 60) :samples samples :remaining samples :pending (make-hash-table :test 'eq)
                :observations nil :started 0 :completed 0 :observer-ms 0 :anchor-kind nil
                :gc-start gcs-done :gc-seconds-start gc-elapsed
                :gc-last gc-elapsed :gc-events nil :allocation-start (memory-use-counts)
                :metadata
                (list :emacs emacs-version :row_height_px height
                      :decoder_build (if (byte-code-function-p
                                          (symbol-function 'tmux-control--decode-output))
                                         "byte-compiled" "source-or-native")
                      :recorder_build (if (byte-code-function-p
                                           (symbol-function 'tmux-control-scroll-trace-start))
                                          "byte-compiled" "source-or-native")
                      :mode (symbol-name major-mode)
                      :initial_depth tmux-control--scrollback-depth
                      :initial_buffer_chars (buffer-size)
                      :window_width (window-body-width window)
                      :window_height_px (window-body-height window t)
                      :history_limit eat-term-scrollback-size
                      :extension_rows tmux-control-scrollback-extend-lines
                      :prefetch_screens tmux-control-scrollback-prefetch-screens
                      :interpolation_threshold pixel-scroll-precision-large-scroll-height
                      :gc_threshold gc-cons-threshold :gc_percentage gc-cons-percentage
                      :input_scheduler "rolling-absolute-deadline")))
    (unless (tmux-control-trace--position)
      (setq tmux-control-trace--run nil)
      (user-error "Window must start on a numbered ROW fixture line"))
    (add-hook 'pre-command-hook #'tmux-control-trace--before-command)
    (add-hook 'post-command-hook #'tmux-control-trace--after-command)
    (add-hook 'pre-redisplay-functions #'tmux-control-trace--redisplay)
    (add-hook 'post-gc-hook #'tmux-control-trace--after-gc)
    (tmux-control-trace--observe "initial")
    (tmux-control-trace--dispatch-due)
    ;; The heartbeat samples idle/hold periods, including history trimming.
    ;; Its own arrival is recorded; it does not pretend to be a frame clock.
    (push (run-at-time .02 .02 #'tmux-control-trace--observe "heartbeat")
          tmux-control-trace--timers)
    (push (run-at-time 6 nil #'tmux-control-scroll-trace-stop)
          tmux-control-trace--timers)
    (message "Recording %s at %d Hz; keep this window selected" label (or hz 60))))

(defun tmux-control-scroll-trace-stop ()
  "Stop recording, remove hooks/timers and save the trace collected so far."
  (interactive)
  (when tmux-control-trace--run
    (tmux-control-trace--observe "final")
    (dolist (timer tmux-control-trace--timers) (cancel-timer timer))
    (when (timerp tmux-control-trace--input-timer)
      (cancel-timer tmux-control-trace--input-timer))
    (setq tmux-control-trace--input-timer nil)
    (setq tmux-control-trace--timers nil tmux-control-trace--active nil)
    (remove-hook 'pre-command-hook #'tmux-control-trace--before-command)
    (remove-hook 'post-command-hook #'tmux-control-trace--after-command)
    (remove-hook 'pre-redisplay-functions #'tmux-control-trace--redisplay)
    (remove-hook 'post-gc-hook #'tmux-control-trace--after-gc)
    (let* ((run tmux-control-trace--run)
           (gc-count (- gcs-done (plist-get run :gc-start)))
           (gc-ms (* 1000 (- gc-elapsed (plist-get run :gc-seconds-start))))
           (allocations (cl-mapcar #'- (memory-use-counts)
                                   (plist-get run :allocation-start)))
           (directory (plist-get run :directory))
           (file (expand-file-name (concat (plist-get run :label) ".json") directory)))
      ;; Drop only our still-queued events if stopped early; preserve user input.
      (setq unread-command-events
            (cl-remove-if
             (lambda (entry)
               (gethash (if (eq (car-safe entry) 'no-record) (cdr entry) entry)
                        (plist-get run :pending))) unread-command-events))
      (setq tmux-control-trace--run nil)
      (make-directory directory t)
      (with-temp-file file
        (insert (json-serialize
                 (list :label (plist-get run :label) :hz (plist-get run :hz)
                       :metadata (plist-get run :metadata)
                       :gc_count gc-count :gc_ms gc-ms
                       :gc_events (vconcat (nreverse (plist-get run :gc-events)))
                       :allocation_counts (vconcat allocations)
                       :observer_elapsed_ms (plist-get run :observer-ms)
                       :final_depth
                       (when (window-live-p (plist-get run :window))
                         (buffer-local-value 'tmux-control--scrollback-depth
                                             (window-buffer (plist-get run :window))))
                       :events (vconcat (plist-get run :samples))
                       :observations (vconcat (nreverse (plist-get run :observations))))
                 :null-object nil :false-object :false)))
      (message "Scroll trace saved: %s" file))))

(provide 'tmux-control-scroll-trace)
;;; tmux-control-scroll-trace.el ends here
