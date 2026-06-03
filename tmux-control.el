;;; tmux-control.el --- Drive a tmux pane through control mode -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Chris Sheaff
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (eat "0.9.4"))
;; Keywords: terminals, tmux
;; URL: https://github.com/csheaff/tmux-control

;;; Commentary:

;; tmux-control is an Emacs client for a tmux pane.  It uses tmux control
;; mode for persistence and Eat's terminal renderer for display and input.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'eat)

(defgroup tmux-control nil
  "Drive a tmux pane from Emacs using tmux control mode."
  :group 'terminals)

(defcustom tmux-control-default-host nil
  "Default SSH host for `tmux-control-connect'.

When nil or empty, connect to local tmux."
  :type '(choice (const :tag "Local" nil) string))

(defcustom tmux-control-default-socket-name "main"
  "Default tmux socket name."
  :type 'string)

(defcustom tmux-control-default-session "emacs"
  "Default tmux session name."
  :type 'string)

(defcustom tmux-control-remote-tmux-socket-setup
  "fs=$(stat -f -c %T \"$HOME\" 2>/dev/null); case \"$fs\" in nfs|nfs4|lustre|gpfs|cifs|smb*|afs) d=\"/tmp/tmux-$(id -u)-sock\";; *) d=\"$HOME/.tmux-sock\";; esac; mkdir -p \"$d\" && chmod 700 \"$d\" && export TMUX_TMPDIR=\"$d\""
  "Shell snippet used before running tmux on a remote host."
  :type 'string)

(defvar-local tmux-control--process nil)
(defvar-local tmux-control--terminal nil)
(defvar-local tmux-control--accumulator "")
(defvar-local tmux-control--active-pane nil)
(defvar-local tmux-control--fallback-target nil)
(defvar-local tmux-control--command-output nil)
(defvar-local tmux-control--expecting-pane-id nil)

(defvar tmux-control-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map eat-mode-map)
    (define-key map (kbd "C-c C-k") #'tmux-control-disconnect)
    (define-key map (kbd "C-c C-l") #'tmux-control-clear-and-repaint)
    map)
  "Keymap for `tmux-control-mode'.")

(define-derived-mode tmux-control-mode eat-mode "tmux-control"
  "Major mode for tmux-control buffers.")

;;;###autoload
(defun tmux-control-connect (&optional host socket-name session)
  "Connect to a tmux SESSION through control mode.

When HOST is nil or empty, connect locally.  Otherwise connect over SSH.
SOCKET-NAME defaults to `tmux-control-default-socket-name', and SESSION
defaults to `tmux-control-default-session'."
  (interactive
   (let* ((host (read-string "Host (empty for local): "
                             nil nil tmux-control-default-host))
          (socket-name (read-string "Socket name: "
                                    nil nil
                                    tmux-control-default-socket-name))
          (session (read-string "Session: "
                                nil nil
                                tmux-control-default-session)))
     (list (unless (string-empty-p host) host)
           socket-name
           session)))
  (setq socket-name (or socket-name tmux-control-default-socket-name))
  (setq session (or session tmux-control-default-session))
  (let* ((local (or (null host) (string-empty-p host)))
         (name (format "tmux-control:%s:%s"
                       (if local "local" host)
                       session))
         (buffer (get-buffer-create (format "*%s*" name)))
         (command (tmux-control--command host socket-name session)))
    (with-current-buffer buffer
      (tmux-control--reset-buffer)
      (setq tmux-control--fallback-target (concat session ":"))
      (setq tmux-control--process
            (make-process
             :name name
             :buffer buffer
             :command command
             :connection-type 'pipe
             :coding 'utf-8-unix
             :noquery t
             :filter #'tmux-control--filter
             :sentinel #'tmux-control--sentinel))
      (process-put tmux-control--process 'adjust-window-size-function
                   #'tmux-control--adjust-window-size)
      (setf (eat-term-parameter tmux-control--terminal 'eat--process)
            tmux-control--process)
      (setf (eat-term-parameter tmux-control--terminal 'eat--input-process)
            tmux-control--process)
      (setf (eat-term-parameter tmux-control--terminal 'eat--output-process)
            tmux-control--process)
      (add-hook 'kill-buffer-hook #'tmux-control--kill-process nil t))
    (pop-to-buffer buffer)
    (with-current-buffer buffer
      (tmux-control--resize-to-window)
      (tmux-control--send-command "display-message -p '#{pane_id}'")
      (setq tmux-control--expecting-pane-id t))
    buffer))

(defun tmux-control-disconnect ()
  "Disconnect the current tmux-control client."
  (interactive)
  (when (process-live-p tmux-control--process)
    (delete-process tmux-control--process)))

(defun tmux-control-clear-and-repaint ()
  "Ask the active pane to repaint itself."
  (interactive)
  (tmux-control--send-input nil "\f"))

(defun tmux-control--reset-buffer ()
  "Reset the current buffer for a fresh tmux-control session."
  (let ((inhibit-read-only t))
    (when (process-live-p tmux-control--process)
      (delete-process tmux-control--process))
    (remove-hook 'kill-buffer-hook #'tmux-control--kill-process t)
    (erase-buffer)
    (tmux-control-mode)
    (setq tmux-control--accumulator "")
    (setq tmux-control--active-pane nil)
    (setq tmux-control--command-output nil)
    (setq tmux-control--expecting-pane-id nil)
    (setq tmux-control--terminal (eat-term-make (current-buffer) (point-min)))
    (setq eat-terminal tmux-control--terminal)
    (eat-semi-char-mode)
    (setf (eat-term-parameter tmux-control--terminal 'input-function)
          #'tmux-control--send-input)
    (setf (eat-term-parameter tmux-control--terminal 'set-cursor-function)
          (if (fboundp 'eat--set-cursor) #'eat--set-cursor #'ignore))
    (setf (eat-term-parameter tmux-control--terminal 'grab-mouse-function)
          (if (fboundp 'eat--grab-mouse) #'eat--grab-mouse #'ignore))
    (setf (eat-term-parameter tmux-control--terminal 'ring-bell-function)
          (if (fboundp 'eat--bell) #'eat--bell #'ignore))
    (setf (eat-term-parameter tmux-control--terminal 'manipulate-selection-function)
          (if (fboundp 'eat--manipulate-kill-ring)
              #'eat--manipulate-kill-ring
            #'ignore))))

(defun tmux-control--command (host socket-name session)
  "Return process command for HOST, SOCKET-NAME, and SESSION."
  (let ((tmux-args `("tmux" "-L" ,socket-name "-C"
                     "new-session" "-A" "-s" ,session)))
    (if (or (null host) (string-empty-p host))
        tmux-args
      (list "ssh" host
            (concat tmux-control-remote-tmux-socket-setup
                    "; exec "
                    (mapconcat #'shell-quote-argument tmux-args " "))))))

(defun tmux-control--filter (process chunk)
  "Handle tmux control mode output CHUNK from PROCESS."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (setq tmux-control--accumulator
            (concat tmux-control--accumulator chunk))
      (let ((start 0)
            line-end)
        (while (setq line-end (string-match "\n" tmux-control--accumulator start))
          (let ((line (substring tmux-control--accumulator start line-end)))
            (when (and (> (length line) 0)
                       (= (aref line (1- (length line))) ?\r))
              (setq line (substring line 0 -1)))
            (tmux-control--handle-line line))
          (setq start (1+ line-end)))
        (setq tmux-control--accumulator
              (substring tmux-control--accumulator start))))))

(defun tmux-control--handle-line (line)
  "Handle one tmux control protocol LINE."
  (cond
   ((string-match "\\`%output \\(%[0-9]+\\)\\(?: \\(.*\\)\\)?\\'" line)
    (let ((pane (match-string 1 line))
          (payload (or (match-string 2 line) "")))
      (setq tmux-control--active-pane pane)
      (tmux-control--write-terminal (tmux-control--decode-output payload))))
   ((string-prefix-p "%begin " line)
    (setq tmux-control--command-output nil))
   ((string-prefix-p "%end " line)
    (tmux-control--finish-command-output))
   ((string-prefix-p "%error " line)
    (tmux-control--message "tmux command failed"))
   ((string-match "\\`%window-pane-changed [^ ]+ \\(%[0-9]+\\)\\'" line)
    (setq tmux-control--active-pane (match-string 1 line)))
   ((and tmux-control--expecting-pane-id
         (string-match "\\`%[0-9]+\\'" line))
    (setq tmux-control--active-pane line)
    (setq tmux-control--expecting-pane-id nil))
   ((and tmux-control--command-output
         (not (string-prefix-p "%" line)))
    (push line tmux-control--command-output))))

(defun tmux-control--finish-command-output ()
  "Handle the end of a tmux command reply."
  (when tmux-control--expecting-pane-id
    (let ((pane (cl-find-if (lambda (line)
                              (string-match-p "\\`%[0-9]+\\'" line))
                            tmux-control--command-output)))
      (when pane
        (setq tmux-control--active-pane pane)
        (setq tmux-control--expecting-pane-id nil))))
  (setq tmux-control--command-output nil))

(defun tmux-control--decode-output (payload)
  "Decode tmux control mode output PAYLOAD."
  (let ((i 0)
        (len (length payload))
        (out nil))
    (while (< i len)
      (if (and (= (aref payload i) ?\\)
               (<= (+ i 3) (1- len))
               (tmux-control--octal-digit-p (aref payload (1+ i)))
               (tmux-control--octal-digit-p (aref payload (+ i 2)))
               (tmux-control--octal-digit-p (aref payload (+ i 3))))
          (progn
            (push (+ (* 64 (- (aref payload (1+ i)) ?0))
                     (* 8 (- (aref payload (+ i 2)) ?0))
                     (- (aref payload (+ i 3)) ?0))
                  out)
            (setq i (+ i 4)))
        (push (aref payload i) out)
        (setq i (1+ i))))
    (apply #'string (nreverse out))))

(defun tmux-control--octal-digit-p (char)
  "Return non-nil when CHAR is an octal digit."
  (and (<= ?0 char) (<= char ?7)))

(defun tmux-control--write-terminal (output)
  "Write decoded terminal OUTPUT to Eat."
  (when (and tmux-control--terminal (eat-term-live-p tmux-control--terminal))
    (let ((inhibit-read-only t)
          (sync-windows (and (fboundp 'eat--synchronize-scroll-windows)
                             (eat--synchronize-scroll-windows))))
      (eat-term-process-output tmux-control--terminal output)
      (eat-term-redisplay tmux-control--terminal)
      (when (and sync-windows
                 (boundp 'eat--synchronize-scroll-function))
        (funcall eat--synchronize-scroll-function sync-windows))
      (run-hooks 'eat-update-hook))))

(defun tmux-control--send-input (_terminal string)
  "Send STRING as input to the active tmux pane."
  (when (and (process-live-p tmux-control--process)
             (> (length string) 0))
    (let ((target (or tmux-control--active-pane tmux-control--fallback-target)))
      (if target
          (tmux-control--send-command
           (format "send-keys -t %s -H %s"
                   target
                   (tmux-control--string-to-hex-args string)))
        (tmux-control--message "No active tmux pane yet")))))

(defun tmux-control--string-to-hex-args (string)
  "Return STRING encoded as space-separated UTF-8 hexadecimal bytes."
  (let* ((bytes (encode-coding-string string 'utf-8-unix))
         (hex nil))
    (dotimes (i (length bytes))
      (push (format "%02x" (aref bytes i)) hex))
    (string-join (nreverse hex) " ")))

(defun tmux-control--send-command (command)
  "Send tmux control mode COMMAND."
  (when (process-live-p tmux-control--process)
    (process-send-string tmux-control--process (concat command "\n"))))

(defun tmux-control--adjust-window-size (process windows)
  "Resize tmux and Eat for PROCESS according to WINDOWS."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (when (and tmux-control--terminal windows)
        (let* ((window (car windows))
               (width (max 1 (window-max-chars-per-line window)))
               (height (max 1 (with-selected-window window
                                (floor (window-screen-lines))))))
          (tmux-control--resize width height)
          (cons width height))))))

(defun tmux-control--resize-to-window ()
  "Resize tmux and Eat to the selected window."
  (when-let* ((window (get-buffer-window (current-buffer) t)))
    (tmux-control--resize
     (max 1 (window-max-chars-per-line window))
     (max 1 (with-selected-window window
              (floor (window-screen-lines)))))))

(defun tmux-control--resize (width height)
  "Resize the local renderer and tmux client to WIDTH by HEIGHT."
  (when (and tmux-control--terminal (eat-term-live-p tmux-control--terminal))
    (let ((inhibit-read-only t))
      (eat-term-resize tmux-control--terminal width height)
      (eat-term-redisplay tmux-control--terminal)))
  (tmux-control--send-command (format "refresh-client -C %dx%d" width height)))

(defun tmux-control--sentinel (process message)
  "Handle PROCESS exit with MESSAGE."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (unless (string-match-p "\\`finished\\|exited" message)
        (tmux-control--message (string-trim-right message)))
      (setq tmux-control--process nil))))

(defun tmux-control--kill-process ()
  "Delete the tmux control process for the current buffer."
  (when (process-live-p tmux-control--process)
    (delete-process tmux-control--process)))

(defun tmux-control--message (message)
  "Append MESSAGE to the current tmux-control buffer."
  (let ((inhibit-read-only t))
    (goto-char (point-max))
    (insert (propertize (format "\n[tmux-control] %s\n" message)
                        'face 'font-lock-comment-face))))

(provide 'tmux-control)

;;; tmux-control.el ends here
