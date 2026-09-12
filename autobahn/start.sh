#!/bin/bash -e

podman stop fuzzingserver || true
podman stop fuzzingclient || true

mkdir -p reports/clients
mkdir -p reports/servers

podman run -d --rm \
    --health-cmd='python -c "import socket; s=socket.socket(); s.connect((\"127.0.0.1\",9001)); s.close()"' \
    --health-interval=1s \
    --health-retries=30 \
    -v "${PWD}/config:/config" \
    -v "${PWD}/reports:/reports" \
    --name fuzzingserver \
    -p 9001:9001 \
    -p 8080:8080 \
    crossbario/autobahn-testsuite:25.10.1 \
    wstest --mode fuzzingserver --spec /config/functional.json

podman run -d --rm --network=host \
    -v "${PWD}/config:/config" \
    -v "${PWD}/reports:/reports" \
    --name fuzzingclient \
    crossbario/autobahn-testsuite:25.10.1 \
    wstest --mode fuzzingclient --spec /config/functional_server.json
