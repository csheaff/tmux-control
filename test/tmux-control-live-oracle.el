;;; tmux-control-live-oracle.el --- Interactive render-fidelity oracle -*- lexical-binding: t; -*-

;;; Commentary:

;; A hands-on companion to the automated suites for the parts that can't be
;; checked in batch: the GUI multi-pane *tiling* (real frames, window splits,
;; focus-follow, frame-resize) running in a live GUI Emacs.
;;
;; The automated tests in `test/tmux-control-integration.el' already assert
;; render == `capture-pane' for the seed and the live %output stream.  This
;; file exposes the same comparison as commands you run against a RUNNING GUI
;; Emacs while exercising tiling by hand, so you can confirm every tiled pane
;; still matches tmux after a split / resize / window switch.
;;
;; Usage (in the live GUI Emacs, with a tiled tmux-control session, e.g. one
;; connected to `tmux -L main'):
;;
;;   M-x load-file RET .../test/tmux-control-live-oracle.el RET
;;   M-: (tmux-control-live-compare-all "main") RET   ; MATCH/DIFF per pane
;;   M-: (tmux-control-live-geom) RET                  ; grid/body/scroll geometry
;;
;; or drive it over emacsclient from a shell while screenshotting:
;;
;;   emacsclient -s "$EMACS_SOCKET" --eval '(tmux-control-live-compare-all "main")'
;;
;; The socket name argument ("main" above) is the tmux `-L' socket the live
;; session is on.  This file is a developer tool; it is not loaded by the
;; package or either `make' target.

;;; Code:

(require 'subr-x)
(require 'cl-lib)
(require 'tmux-control)

(defun tmux-control-live--rtrim (lines)
  "Right-trim LINES and drop trailing blank lines."
  (let ((ls (mapcar #'string-trim-right lines)))
    (while (and ls (string-empty-p (car (last ls))))
      (setq ls (butlast ls)))
    ls))

(defun tmux-control-live--visible-text (beg end)
  "Return buffer text BEG..END with Eat's invisible padding cells removed.
Eat models a double-width glyph (CJK, emoji, wide box-drawing) as the glyph
followed by an `invisible' padding cell for its second column, while
`capture-pane' emits only the glyph; drop the padding so wide characters do
not read as spurious trailing spaces against the ground truth."
  (let ((out nil) (i beg))
    (while (< i end)
      (unless (get-text-property i 'invisible)
        (push (char-after i) out))
      (setq i (1+ i)))
    (apply #'string (nreverse out))))

(defun tmux-control-live--pane-visible (buf)
  "Return BUF's Eat visible screen (last `height' rows) as normalized lines."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let ((h (cdr (eat-term-size tmux-control--terminal))))
        (save-excursion
          (goto-char (point-max))
          (forward-line (- (1- h)))
          (tmux-control-live--rtrim
           (split-string (tmux-control-live--visible-text
                          (line-beginning-position) (point-max))
                         "\n")))))))

(defun tmux-control-live--tmux-visible (socket pane)
  "Return tmux PANE's visible screen on SOCKET as normalized plain lines."
  (tmux-control-live--rtrim
   (split-string
    (with-temp-buffer
      (call-process "tmux" nil t nil "-L" socket "capture-pane" "-p" "-t" pane)
      (buffer-string))
    "\n")))

(defun tmux-control-live-compare (socket pane buf)
  "Compare BUF's render to tmux PANE on SOCKET.  Return a MATCH/DIFF string."
  (let ((tm (tmux-control-live--tmux-visible socket pane))
        (ea (tmux-control-live--pane-visible buf)))
    (if (equal tm ea)
        (format "MATCH %s (%d lines)" pane (length tm))
      (let ((i 0) (n (max (length tm) (length ea))) (diff nil))
        (while (and (< i n) (not diff))
          (unless (equal (nth i tm) (nth i ea))
            (setq diff (format "DIFF %s @line %d  tmlines=%d eatlines=%d\n   tmux=%S\n   eat =%S"
                               pane i (length tm) (length ea)
                               (nth i tm) (nth i ea))))
          (setq i (1+ i)))
        (or diff (format "DIFF %s (len tm=%d eat=%d)" pane (length tm) (length ea)))))))

;;;###autoload
(defun tmux-control-live-compare-all (socket)
  "Compare every tiled pane of the live tmux-control session to tmux on SOCKET.
Returns one MATCH/DIFF line per pane.  Run in a GUI Emacs that has a tiled
tmux-control session."
  (let* ((ctrl (get-buffer "*tmux-control:local:emacs*"))
         (panes (and ctrl (buffer-local-value 'tmux-control--panes ctrl))))
    (if (null panes)
        "no tiled panes (is a tmux-control session tiled?)"
      (mapconcat (lambda (np) (tmux-control-live-compare socket (car np) (cdr np)))
                 panes "\n"))))

;;;###autoload
(defun tmux-control-live-geom ()
  "Return per-pane grid/body/window-start geometry for the live tiling.
Handy for spotting clip/gutter (grid vs body) and scroll (window-start)."
  (let* ((ctrl (get-buffer "*tmux-control:local:emacs*"))
         (panes (and ctrl (buffer-local-value 'tmux-control--panes ctrl))))
    (mapconcat
     (lambda (np)
       (let* ((buf (cdr np))
              (w (and (buffer-live-p buf) (get-buffer-window buf t))))
         (if (and buf w)
             (with-current-buffer buf
               (format "%s grid=%S body=(%d %d) wstart=%d point=%d ptmax=%d"
                       (car np) (eat-term-size tmux-control--terminal)
                       (window-body-width w) (window-body-height w)
                       (line-number-at-pos (window-start w))
                       (line-number-at-pos (window-point w))
                       (line-number-at-pos (point-max))))
           (format "%s (no window)" (car np)))))
     panes "\n")))

(provide 'tmux-control-live-oracle)
;;; tmux-control-live-oracle.el ends here
