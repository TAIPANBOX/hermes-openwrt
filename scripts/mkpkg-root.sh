#!/bin/sh
# mkpkg-root.sh -- `apk mkpkg` with the packaged files owned by root, run inside the Alpine
# packaging container: sh /mkpkg-root <the arguments apk mkpkg takes>.
#
# apk mkpkg records each file's owner as it finds it on disk and has no option to say
# otherwise. The build hands its tree back to the invoking user (so later steps can edit it),
# and on a Linux CI runner that user is uid 1001: the package then installed /etc/hermes-agent
# and its key files owned by `nobody` (gate-unlock check_key_files_root_only, 2026-10-02).
# Docker Desktop shows a bind mount as root, so packages built on a Mac never showed it.
#
# So the tree is root's while it is packaged and the invoking user's again after, OWN being
# that user as uid:gid. The exit status is mkpkg's.
set -u
files=/work/tree
prev=
for a in "$@"; do
	case "$prev" in --files|-F) files=$a ;; esac
	case "$a" in --files=*) files=${a#--files=} ;; esac
	prev=$a
done
[ -d "$files" ] || { echo "mkpkg-root: no files directory $files" >&2; exit 1; }
chown -R 0:0 "$files"
apk mkpkg "$@"
rc=$?
[ -n "${OWN:-}" ] && chown -R "$OWN" "$files"
exit $rc
