#!/usr/bin/env bash
set -euo pipefail

image=${1:?A locally loaded image is required}
version=${2:?The expected application version is required}
platform=${3:?The image platform is required}
container=
cleanup() {
    status=$?
    if [[ -n $container ]]; then
        if ((status != 0)); then
            docker inspect --format '{{json .State}}' "$container" >&2 || true
            docker logs "$container" >&2 || true
        fi
        docker rm --force --volumes "$container" > /dev/null || true
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

container=$(docker create --pull=never --platform "$platform" --network none \
    --label "io.tuxcrate.smoke-test=${TUXCRATE_TEST_ID:-manual-lidarr-$$}" "$image")
docker start "$container" > /dev/null
docker exec "$container" sh -eu -c '
    test "$(id -u)" = 1000
    test "$(id -g)" = 1000
    test "$(id -un)" = tuxcrate
    test "$(id -gn)" = tuxcrate
    test -w /config
    test ! -w /opt/lidarr/bin
    /opt/lidarr/bin/fpcalc -version
'
for attempt in {1..120}; do
    if response=$(docker exec "$container" sh -eu -c '
        test -s /config/lidarr.db
        test -s /config/config.xml
        wget -T 2 -q -O - http://127.0.0.1:8686/ping
    ' 2>/dev/null) && grep -Eq '"status"[[:space:]]*:[[:space:]]*"OK"' <<< "$response"; then
        break
    fi
    [[ $(docker inspect --format '{{.State.Running}}' "$container") == true ]]
    if ((attempt == 120)); then echo 'Lidarr readiness timed out.' >&2; exit 1; fi
    sleep 1
done
system_status=$(docker exec "$container" sh -eu -c '
    api_key=$(sed -n "s:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p" /config/config.xml)
    test -n "$api_key"
    wget -T 10 -q -O - --header "X-Api-Key: $api_key" http://127.0.0.1:8686/api/v1/system/status
')
jq -e --arg version "$version" --arg package "${PACKAGE_VERSION:-${version}-local}" \
    '.version == $version and .packageVersion == $package and .packageAuthor == "[Tuxcrate](https://tuxcrate.com)"' \
    <<< "$system_status" > /dev/null
docker stop --time 30 "$container" > /dev/null
[[ $(docker wait "$container") == 0 ]]
