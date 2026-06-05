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

# Live integration tests: assert that the rendered Eat buffer matches tmux's
# own `capture-pane' for the same screen, across plain text / colors /
# box-drawing / wide lines.  These need a real tmux on PATH -- they use a
# dedicated `tc-ert-test' socket and never touch other servers, and each test
# skips (rather than fails) where tmux is unavailable.  Slower and
# environment-dependent, so kept out of the default `make test'.
#
#   make test-integration
.PHONY: test-integration
test-integration:
	$(EMACS) -Q --batch \
	  -L "$(EAT_DIR)" -L . \
	  -l tmux-control.el \
	  -l test/tmux-control-integration.el \
	  -f ert-run-tests-batch-and-exit
