# Run the tmux-control test suite in batch.
#
#   make test
#
# EAT_DIR must point at a directory containing eat.el (a hard dependency of
# tmux-control).  It defaults to the straight.el build path; override it if
# your eat package lives elsewhere:
#
#   make test EAT_DIR=/path/to/eat

EMACS  ?= emacs
EAT_DIR ?= $(HOME)/.emacs.d/straight/build/eat

.PHONY: test
test:
	$(EMACS) -Q --batch \
	  -L "$(EAT_DIR)" -L . \
	  -l tmux-control.el \
	  -l test/tmux-control-test.el \
	  -f ert-run-tests-batch-and-exit
