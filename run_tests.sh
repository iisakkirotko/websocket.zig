#!/bin/bash -e

#zig build -freference-trace -Doptimize=ReleaseFast
zig build

url=ws://localhost:9001
msgs=$(websocat "$url/getCaseCount" -E --jsonrpc)

./zig-out/bin/autobahn_client "$msgs"
websocat "$url/updateReports?agent=dummy" -E

if [ -z "$CI" ] && command -v open >/dev/null 2>&1; then
    open $(pwd)/autobahn/reports/clients/index.html
fi
