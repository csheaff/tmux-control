;;; vt-oracle-render.el --- Render byte streams the way tmux-control does -*- lexical-binding: t; -*-

;; Developer tool for test/vt-oracle.py, not loaded by the package.
;;
;;   emacs -Q --batch -L EAT -L . -l tmux-control.el \
;;     -l test/vt-oracle-render.el CASES.json OUT.json
;;
;; CASES.json is [{"w": W, "h": H, "b64": BYTES}, ...]: the bytes a pane's
;; program wrote, as tmux delivers them in %output.  Each case is fed through
;; tmux-control's own output path (`tmux-control--feed-terminal', which applies
;; its UTF-8 reassembly and any Eat adjustments, then
;; `tmux-control--flush-display') into a fresh WxH terminal.
;; OUT.json gets each screen's rows, the cursor as shown (1-based) and as
;; the terminal records it, or the error the render signalled.  With
;; TMUX_CONTROL_RENDERER=ghostel in the environment, and Ghostel on the
;; load path, the terminal is Ghostel's.

;;; Code:

(require 'json)
(require 'tmux-control)

(defun tmux-control-vt-oracle--visible (beg end)
  "Return the text from BEG to END without Eat's invisible padding cells.
Eat follows a double-width glyph with an invisible cell standing in for its
second column; `capture-pane' prints only the glyph."
  (let ((out nil))
    (while (< beg end)
      (unless (get-text-property beg 'invisible)
        (push (char-after beg) out))
      (setq beg (1+ beg)))
    (apply #'string (nreverse out))))

(when-let* ((renderer (getenv "TMUX_CONTROL_RENDERER")))
  (setq tmux-control-renderer (intern renderer)))

(defun tmux-control-vt-oracle--render (width height bytes)
  "Render BYTES in a fresh WIDTHxHEIGHT tmux-control terminal; return an alist."
  (with-temp-buffer
    (tmux-control--reset-buffer)
    (when (and (eq tmux-control-renderer 'ghostel) (not tmux-control--ghostel))
      (error "Ghostel did not load"))
    (tmux-control--term-resize width height)
    (tmux-control--feed-terminal (decode-coding-string bytes 'utf-8-unix))
    (tmux-control--flush-display nil)
    (let* ((top (tmux-control--term-screen-start))
           (rows (split-string (tmux-control--term-screen-text) "\n"))
           (shown (tmux-control--term-cursor))
           (bol (save-excursion (goto-char shown) (line-beginning-position)))
           ;; The terminal's own record of the cursor.  After a character
           ;; fills the last column Eat holds column WIDTH+1, a pending
           ;; wrap, as tmux does, while the cursor is shown on that
           ;; character.  Ghostel keeps it on the last column.
           (cursor (tmux-control--term-cursor-xy)))
      `((rows . ,(vconcat rows))
        (cy . ,(1+ (count-lines top bol)))
        (cx . ,(1+ (string-width (tmux-control-vt-oracle--visible bol shown))))
        (sy . ,(1+ (cdr cursor)))
        (sx . ,(1+ (car cursor)))
        (wrap . ,(if (tmux-control--term-pending-wrap-known-p) t :json-false))))))

(let* ((in (pop command-line-args-left))
       (out (pop command-line-args-left))
       (json-array-type 'list)
       (results
        (mapcar (lambda (case)
                  (condition-case err
                      (tmux-control-vt-oracle--render
                       (alist-get 'w case) (alist-get 'h case)
                       (base64-decode-string (alist-get 'b64 case)))
                    (error `((error . ,(error-message-string err))))))
                (json-read-file in))))
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-file out
      (insert (json-encode (vconcat results))))))

;;; vt-oracle-render.el ends here
