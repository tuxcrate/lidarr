#!/bin/sh
set -eu

version=${1:?The expected application version is required}
test "$(id -u)" -ne 0
test -w /config
test ! -w /opt/lidarr/bin
/opt/lidarr/bin/fpcalc -version
data=$(mktemp -d)
pid=
cleanup() {
    status=$?
    trap - EXIT
    if [ -n "$pid" ]; then
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    if [ "$status" -ne 0 ]; then cat "$data/startup.log" >&2; fi
    rm -rf "$data"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

/opt/lidarr/bin/Lidarr -nobrowser "-data=$data" > "$data/startup.log" 2>&1 &
pid=$!
attempt=0
until wget -T 2 -q -O - http://127.0.0.1:8686/ping 2>/dev/null | grep -Eq '"status"[[:space:]]*:[[:space:]]*"OK"'; do
    kill -0 "$pid"
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 60 ]; then echo 'Lidarr readiness timed out.' >&2; exit 1; fi
    sleep 1
done
test -s "$data/lidarr.db"
test -s "$data/config.xml"
installed_version=$(sed -n 's/.*Bootstrap: Starting Lidarr .* - Version \([^ ]*\).*/\1/p' "$data/startup.log")
test "$installed_version" = "$version"
kill -TERM "$pid"
wait "$pid"
pid=
