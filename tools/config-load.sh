# config-load.sh -- sourced by every script that needs anything outside the repository.
#
#   . "$(cd "$(dirname "$0")" && pwd)/tools/config-load.sh"
#
# Does three things, in this order, and the order is the point:
#
#   1. reads config.sh, so we know where the toolchain lives;
#   2. sources the toolchain's own env.sh, which sets PATH, the sysroot and the kernel CFLAGS;
#   3. reads config.sh AGAIN, so that YOUR settings win.
#
# Step 3 exists because the cross toolchain's env.sh exports AMIX_ROOT itself, hard-coded to
# whatever the machine that BUILT the toolchain used.  Without the re-read, a correct
# config.sh would be silently overridden by a stale path and the build would patch someone
# else's kernel -- which is exactly the class of failure this repository refuses to have.
#
# Refuses to continue without config.sh rather than falling back to defaults: a wrong
# toolchain that happens to exist is worse than no toolchain.

_cfg_find() {
	for d in "$(cd "$(dirname "$0")" && pwd)" \
	         "$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)" \
	         "$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)"; do
		[ -f "$d/config.sh" ] && { echo "$d"; return 0; }
	done
	return 1
}
_CFG_ROOT=$(_cfg_find) || {
	echo "ERROR: config.sh not found." >&2
	echo "       cp config.sh.example config.sh   and edit it; then sh tools/check-env.sh" >&2
	exit 1
}

. "$_CFG_ROOT/config.sh"
[ -f "$GCC_CROSS_ENV" ] && . "$GCC_CROSS_ENV"
. "$_CFG_ROOT/config.sh"

PATH="$AMIX_CROSS/bin:${M68K_GNU_BIN:-/usr/bin}:$PATH"
# Exported because the Python helpers read them from the environment rather than re-parsing
# config.sh.  VA2000_SRC and the Z3660 pair were added 2026-08-16: until then the scripts that
# use them held a hard-coded path under one developer's home directory, so the variables were
# checked by check-env.sh and then ignored by the build.
export PATH AMIX_ROOT AMIX_CROSS NETBSD_SYSSRC
export XSVGA_EXP VA2000_SRC Z3660_SCSI_SRC Z3660_NET_SRC
