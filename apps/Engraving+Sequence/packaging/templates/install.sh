#!/bin/sh
set -eu
cd -- "$(dirname -- "$0")"
. /etc/os-release
if [ "$ID" != ubuntu ] || [ "$VERSION_ID" != 24.04 ] || [ "$(dpkg --print-architecture)" != amd64 ]; then
    printf '%s\n' 'This installer requires Ubuntu 24.04 amd64.' >&2
    exit 1
fi
sha256sum -c SHA256SUMS
if [ "$(id -u)" = 0 ]; then
    apt-get update
    apt-get install -y "./@PACKAGE@_@VERSION@_amd64.deb"
else
    sudo apt-get update
    sudo apt-get install -y "./@PACKAGE@_@VERSION@_amd64.deb"
fi
printf '%s\n' 'Installed @PACKAGE@. See README.md for service/client configuration.'
