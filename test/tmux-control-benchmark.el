;;; tmux-control-benchmark.el --- Scrollback CPU benchmarks -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with `make benchmark'.  Synthetic data only; no live panes are read.
;; Measures synchronous work that can delay wheel events, not GUI frame times
;; or capture round-trip latency.  Compare runs using the same Emacs/build.

;;; Code:
(require 'benchmark)
(require 'tmux-control)

(defun tmux-control-benchmark--measure (label thunk)
  "Print average elapsed, GC time and allocation over five calls to THUNK.
LABEL names the case.  Allocation counters count created objects, not the
live heap or retained bytes; timing harness overhead is included."
  (funcall thunk) ; Warm library and face caches.
  (garbage-collect)
  (let* ((before (memory-use-counts))
         (result (benchmark-call thunk 5))
         (allocated (cl-mapcar #'- (memory-use-counts) before)))
    (princ (format "%-32s %9.3f ms  %9.3f ms GC  %d GCs  %.0f strings / %.0f string chars per call\n"
                   label (* 200 (car result)) (* 200 (nth 2 result))
                   (nth 1 result) (/ (nth 6 allocated) 5.0)
                   (/ (nth 4 allocated) 5.0)))))

(defun tmux-control-benchmark-run ()
  "Benchmark scrollback preparation, seam matching, and output decoding."
  (princ (format "Emacs %s; tmux-control %s; five iterations per case\n"
                 emacs-version
                 (if (byte-code-function-p
                      (symbol-function 'tmux-control--decode-output))
                     "byte-compiled" "source")))
  (let ((tmux-control-compact-scrollback nil)
        (tmux-control-compact-scrollback-window 300))
    (dolist (n '(500 2000 10000))
      (let* ((lines (mapcar (lambda (i)
                             (format "row %06d  output with padding                 " i))
                           (number-sequence 1 n)))
             (plain (string-join lines "\n"))
             (colored (mapconcat
                       (lambda (s) (concat "\e[32m" s "\e[0m")) lines "\n"))
             (head (mapcar (lambda (i) (format "newer row %06d" i))
                           (number-sequence 1 300))))
        (tmux-control-benchmark--measure
         (format "prepare plain / %d rows" n)
         (lambda () (tmux-control--prepare-scrollback-text plain)))
        (tmux-control-benchmark--measure
         (format "prepare ANSI / %d rows" n)
         (lambda () (tmux-control--prepare-scrollback-text colored)))
        (tmux-control-benchmark--measure
         (format "seam no overlap / %d rows" n)
         (lambda () (tmux-control--scrollback-drop-seam-overlap lines head)))))
    (dolist (escaped '(nil t))
      (let ((payload (apply #'concat
                            (make-list 1000
                                       (if escaped
                                           "row \\033[32mcolored\\033[0m output\\015\\012"
                                         "row plain output with padding        ")))))
        (tmux-control-benchmark--measure
         (if escaped "decode escaped / 1000 rows" "decode plain / 1000 rows")
         (lambda () (tmux-control--decode-output payload)))))))

(provide 'tmux-control-benchmark)
;;; tmux-control-benchmark.el ends here
