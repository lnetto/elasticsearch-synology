#!/bin/bash
#
# Build the patched image and smoke-test it.
#
#   ./build.sh            build the newest stable 9.x release
#   ./build.sh 9.5.5      build a specific version
#   ./build.sh --no-test  skip the smoke test (combine with a version if needed)
#
# The smoke test boots a throwaway single-node container, indexes a document and
# searches for it. Run on a kernel without seccomp (Synology), it also checks
# that the patched warning was logged, i.e. that the patched code path ran.

set -euo pipefail
cd "$(dirname "$0")"

TEST=1 VERSION=""
for arg in "$@"; do
  case "$arg" in
    --no-test) TEST=0 ;;
    [0-9]*.[0-9]*.[0-9]*) VERSION="$arg" ;;
    *) echo "usage: $0 [VERSION] [--no-test]" >&2; exit 2 ;;
  esac
done

if [ -z "$VERSION" ]; then
  VERSION=$(curl -fsSL 'https://hub.docker.com/v2/repositories/library/elasticsearch/tags?page_size=100&name=9.' |
    grep -oE '"name":"9\.[0-9]+\.[0-9]+"' | cut -d'"' -f4 | sort -V | tail -1)
  [ -n "$VERSION" ] || { echo "could not find the latest 9.x release" >&2; exit 1; }
fi
IMAGE="elasticsearch-synology:$VERSION"

echo "==> building $IMAGE"
docker build --build-arg ES_VERSION="$VERSION" -t "$IMAGE" .

[ "$TEST" = 1 ] || exit 0

NAME="es-synology-test-$$"
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT
echo "==> smoke test"
docker run -d --name "$NAME" \
  -e discovery.type=single-node -e xpack.security.enabled=false \
  -e ES_JAVA_OPTS="-Xms1g -Xmx1g" -e node.store.allow_mmap=false \
  "$IMAGE" >/dev/null

es() { docker exec "$NAME" curl -fsS "$@"; }
for _ in $(seq 1 60); do
  es -o /dev/null http://localhost:9200 2>/dev/null && break
  docker inspect -f '{{.State.Running}}' "$NAME" | grep -q true || { docker logs --tail 40 "$NAME"; exit 1; }
  sleep 3
done
es -X PUT -H 'Content-Type: application/json' 'http://localhost:9200/smoke/_doc/1?refresh=true' \
  -d '{"msg":"hello synology"}' >/dev/null
HITS=$(es 'http://localhost:9200/smoke/_search?q=msg:synology' | grep -oE '"total":\{"value":[0-9]+' | grep -oE '[0-9]+$')
[ "$HITS" = 1 ] || { echo "search returned ${HITS:-nothing}, expected 1" >&2; exit 1; }
echo "    index + search OK"

if grep -q '^Seccomp:' /proc/self/status; then
  echo "    this kernel has seccomp, so the patched path wasn't exercised (expected on normal Linux)"
elif LOGS=$(docker logs "$NAME" 2>&1) && grep -q 'patched for kernels without seccomp' <<<"$LOGS"; then
  echo "    kernel without seccomp: patched warning logged, node started"
else
  echo "kernel has no seccomp but the patched warning is missing" >&2; exit 1
fi
echo "==> $IMAGE OK"
