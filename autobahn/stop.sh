#!/bin/bash -e

podman stop fuzzingserver || true
podman stop fuzzingclient || true
