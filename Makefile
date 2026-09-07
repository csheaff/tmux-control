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
PYTHON ?= python3

.PHONY: test
test:
	$(EMACS) -Q --batch \
	  -L "$(EAT_DIR)" -L . \
	  -l tmux-control.el \
	  -l test/tmux-control-test.el \
	  -f ert-run-tests-batch-and-exit

# Byte-compile with warnings promoted to errors.  Compiled and interpreted
# elisp can genuinely diverge (specialness of a let-bound variable is decided
# at compile time), so warnings here are treated as bugs.
.PHONY: compile
compile:
	$(EMACS) -Q --batch \
	  -L "$(EAT_DIR)" -L . \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile tmux-control.el

# Run the unit suite against the BYTE-COMPILED package.  Users run compiled
# builds, and a compiled build once behaved differently from the source load
# `make test' exercises (a let-binding compiled as lexical silently disabled
# memoization) -- so CI runs both.
.PHONY: test-elc
test-elc: compile
	$(EMACS) -Q --batch \
	  -L "$(EAT_DIR)" -L . \
	  -l tmux-control.elc \
	  -l test/tmux-control-test.el \
	  -f ert-run-tests-batch-and-exit

.PHONY: clean
clean:
	rm -f tmux-control.elc

# Repeatable CPU timings, separate from correctness tests.  Uses the compiled
# package just as a normal installation does; no running tmux is needed.
.PHONY: benchmark
benchmark: compile
	$(EMACS) -Q --batch \
	  -L "$(EAT_DIR)" -L . \
	  -l tmux-control.elc -l test/tmux-control-benchmark.el \
	  -f tmux-control-benchmark-run

# Check the GUI trace's input plan and coordinate/analysis math in batch.
.PHONY: test-scroll-trace
test-scroll-trace:
	$(EMACS) -Q --batch -L "$(EAT_DIR)" -L . -L test \
	  -l tmux-control.el -l test/tmux-control-scroll-trace.el \
	  -l test/tmux-control-scroll-trace-test.el \
	  -l test/tmux-control-idle-gc-experiment-test.el -f ert-run-tests-batch-and-exit
	$(PYTHON) -m unittest discover -s test -p 'test_scroll_*analysis.py'

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
