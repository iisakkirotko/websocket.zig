#!/bin/bash -e

#zig build -freference-trace -Doptimize=ReleaseFast
zig build

url=ws://localhost:9001
msgs=$(echo "" | websocat "$url/getCaseCount")

if [ -z "$msgs" ]; then
    echo "ERROR: Empty response from Autobahn server"
    exit 1
fi

./zig-out/bin/autobahn_client "$msgs"
echo "" | websocat "$url/updateReports?agent=dummy"

if [ -z "$CI" ] && command -v open >/dev/null 2>&1; then
    open $(pwd)/autobahn/reports/clients/index.html
fi
