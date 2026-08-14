# build-step.sh -- sourced.  Runs one build step and STOPS THE BUILD if it fails.
#
#   . "$HERE/tools/build-step.sh"
#   run_step 3 python3 "$HERE/src/patch_modelb.py" "$OUT"
#
# WHY THIS EXISTS
#
# Every byte-patch script in src/ asserts the OLD bytes before writing the new ones, and
# aborts if they are not there.  That assertion is the single most important safety property
# of this port: the patchers address the kernel by hard-coded offsets, so a patcher firing at
# a moved target does not fail -- it patches something else.
#
# Until 2026-08-14 all 43 of them were invoked as
#
#     python3 src/patch_foo.py "$OUT" | tail -3
#
# and in POSIX sh the exit status of a pipeline is the status of its LAST command.  `tail`
# always succeeds.  So `set -e` never saw the failure: the ABORT text scrolled past on stderr,
# the build patched on into a half-patched image, and it printed `[OK] built` at the end.
#
#     $ sh -c 'set -e; (exit 3) | tail -1; echo "still here, status=$?"'
#     still here, status=0
#
# That is the exact failure mode tools/verify-stock.sh was written to refuse -- "the build
# works and the result is quietly wrong" -- reintroduced one layer up, in the build script
# that runs the checks.  Hence: no build step goes through a pipe any more.
#
# MODE is what to show when the step SUCCEEDS.  On failure everything is shown, always.
#   <n>      last n lines (what the old `| tail -n` was for)
#   all      the whole output
#   indent   the whole output, indented six spaces
#   quiet    nothing

# Where the step's output is captured.  One file, reused; removed on exit.
_STEP_LOG=$(mktemp "${TMPDIR:-/tmp}/amix-build-step.XXXXXX") || exit 1
trap 'rm -f "$_STEP_LOG"' EXIT
trap 'rm -f "$_STEP_LOG"; exit 130' INT
trap 'rm -f "$_STEP_LOG"; exit 143' TERM

run_step() {
	_rs_mode=$1
	shift

	# `cmd || _rs_status=$?` and not `if cmd; then`: the `if` form makes $? the status of the
	# IF, which is 0 when no branch ran -- the failure banner then reports "exit status 0".
	# (Caught by the unit test below, which is why it prints the status at all.)  The `||` also
	# keeps the caller's `set -e` from killing the shell before the diagnostics are printed.
	_rs_status=0
	"$@" >"$_STEP_LOG" 2>&1 || _rs_status=$?

	if [ "$_rs_status" -eq 0 ]; then
		case "$_rs_mode" in
		quiet)  ;;
		all)    cat "$_STEP_LOG" ;;
		indent) sed 's/^/      /' "$_STEP_LOG" ;;
		*)      tail -"$_rs_mode" "$_STEP_LOG" ;;
		esac
		return 0
	fi

	echo
	echo "[FAIL] ==================================================================="
	echo "[FAIL] build step failed, exit status $_rs_status:"
	echo "[FAIL]     $*"
	echo "[FAIL] ==================================================================="
	echo
	sed 's/^/    /' "$_STEP_LOG"
	echo
	echo "       The build stops here.  If this was a byte-pattern ABORT, the patch target"
	echo "       has moved: the image being patched is not the one the offset was measured"
	echo "       against, and continuing would write correct bytes to the wrong address."
	echo "       Whatever is in the output file now is PARTIALLY PATCHED -- do not boot it."
	exit 1
}
