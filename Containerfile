ARG BASE_IMAGE
FROM ${BASE_IMAGE} AS download

ARG APP_VERSION
ARG PACKAGE_VERSION
ARG TARGETARCH

RUN --mount=type=secret,id=github_token \
    set -eu; \
    : "${APP_VERSION:?APP_VERSION must be set}"; \
    github_auth=""; \
    if [ -s /run/secrets/github_token ]; then \
        github_auth="Authorization: Bearer $(cat /run/secrets/github_token)"; \
    fi; \
    apk add --no-cache ca-certificates curl jq; \
    case "$TARGETARCH" in amd64) arch=x64 ;; arm64) arch=arm64 ;; *) exit 1 ;; esac; \
    curl --header "$github_auth" --fail --location --retry 3 \
        "https://api.github.com/repos/Lidarr/Lidarr/releases/tags/v${APP_VERSION}" -o /tmp/release.json; \
    jq -e --arg tag "v${APP_VERSION}" \
        '.tag_name == $tag and .draft == false and (.prerelease | type == "boolean")' /tmp/release.json; \
    branch="$(jq -er 'if .prerelease then "develop" else "master" end' /tmp/release.json)"; \
    jq -ce --arg name "Lidarr.${branch}.${APP_VERSION}.linux-musl-core-${arch}.tar.gz" \
        '[.assets[] | select(.name == $name)] \
         | if length == 1 then .[0] else error("expected exactly one matching Lidarr asset") end' \
        /tmp/release.json > /tmp/asset.json; \
    digest="$(jq -er '.digest | select(test("^sha256:[0-9a-f]{64}$"))' /tmp/asset.json)"; \
    url="$(jq -er '.browser_download_url' /tmp/asset.json)"; \
    curl --fail --location --retry 3 --proto '=https' --proto-redir '=https' \
        "$url" -o /tmp/lidarr.tar.gz; \
    printf '%s  /tmp/lidarr.tar.gz\n' "${digest#sha256:}" | sha256sum -c -; \
    mkdir /lidarr /notices; \
    tar -xzf /tmp/lidarr.tar.gz -C /lidarr --strip-components=1; \
    rm -rf /lidarr/Lidarr.Update; \
    curl --fail --location --retry 3 \
        "https://raw.githubusercontent.com/Lidarr/Lidarr/v${APP_VERSION}/LICENSE.md" -o /notices/LICENSE.md; \
    printf 'Lidarr is licensed under GPL-3.0.\nCorresponding source: https://github.com/Lidarr/Lidarr/tree/v%s\nSource archive: https://github.com/Lidarr/Lidarr/archive/refs/tags/v%s.tar.gz\n' \
        "$APP_VERSION" "$APP_VERSION" > /notices/SOURCE; \
    printf 'UpdateMethod=docker\nBranch=%s\nPackageVersion=%s\nPackageAuthor=[Tuxcrate](https://tuxcrate.com)\n' \
        "$branch" "${PACKAGE_VERSION:-${APP_VERSION}-local}" > /package_info

FROM ${BASE_IMAGE}

ENV HOME=/config \
    XDG_CONFIG_HOME=/config/xdg \
    COMPlus_EnableDiagnostics=0

RUN set -eux; \
    apk upgrade --no-cache; \
    apk add --no-cache ca-certificates icu-data-full icu-libs libgcc libstdc++ libssl3 sqlite-libs tzdata zlib; \
    addgroup -g 1000 tuxcreate; \
    adduser -D -u 1000 -G tuxcreate -h /config -s /sbin/nologin tuxcreate; \
    mkdir -p /config /data; \
    chown 1000:1000 /config /data

# Lidarr reads ../package_info when its application directory is named bin.
COPY --from=download /lidarr /opt/lidarr/bin
COPY --from=download /package_info /opt/lidarr/package_info
COPY --from=download /notices /usr/share/doc/lidarr

USER 1000:1000
WORKDIR /config

EXPOSE 8686
ENTRYPOINT ["/opt/lidarr/bin/Lidarr", "-nobrowser", "-data=/config"]
