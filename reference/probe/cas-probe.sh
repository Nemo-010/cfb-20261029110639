#!/bin/sh
# cas-probe.sh -- verify that an S3-compatible store really implements conditional writes.
#
# Why this exists: celld uses a compare-and-swap on a small object in place of consensus. If
# the store silently ignores If-None-Match, two nodes can both "win" the same cell and serve
# it at once. That is silent data corruption, not an outage, and the good outcome and the bad
# outcome look identical from the outside. So probe it.
#
# Usage:
#   S3_ENDPOINT=http://127.0.0.1:8333 \
#   S3_KEY=... S3_SECRET=... S3_REGION=us-east-1 \
#   sh cas-probe.sh <bucket> [prefix]
#
# Exit 0: exactly one writer won (the store is safe).
# Exit 1: both won, or neither did (the store is NOT safe for celld).
# Exit 2: usage or connectivity error (inconclusive -- do not treat as pass).

set -eu

BUCKET=${1:-}
PREFIX=${2:-_cfb_probe}
: "${S3_ENDPOINT:?set S3_ENDPOINT}"
: "${S3_KEY:?set S3_KEY}"
: "${S3_SECRET:?set S3_SECRET}"
S3_REGION=${S3_REGION:-us-east-1}

if [ -z "$BUCKET" ]; then
  echo "usage: $0 <bucket> [prefix]" >&2
  exit 2
fi

KEY="$PREFIX/$(date -u +%Y%m%dT%H%M%SZ)-$$"
URL="$S3_ENDPOINT/$BUCKET/$KEY"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

sig() {
  # curl's built-in SigV4 signer; --user supplies the key pair, never the URL.
  printf '%s' "aws:amz:$S3_REGION:s3"
}

put() {
  # $1 = output file. Exactly one of these is expected to succeed.
  curl -qfsS --max-time 30 \
    --aws-sigv4 "$(sig)" \
    --user "$S3_KEY:$S3_SECRET" \
    -X PUT \
    -H 'If-None-Match: *' \
    -H 'content-type: application/octet-stream' \
    --data-binary "claim-$$-$(basename "$1")" \
    -o "$1" -w '%{http_code}' \
    "$URL" 2>"$1.err" || true
}

echo "probing $S3_ENDPOINT bucket=$BUCKET key=$KEY"

# Two writers, same key, at the same time. Each is a create-if-absent.
put "$TMP/a" >"$TMP/a.code" &
put "$TMP/b" >"$TMP/b.code" &
wait

A=$(cat "$TMP/a.code" 2>/dev/null || echo 000)
B=$(cat "$TMP/b.code" 2>/dev/null || echo 000)

echo "writer A: $A   writer B: $B"

# Clean up the probe object regardless of outcome.
curl -qfsS --max-time 30 \
  --aws-sigv4 "$(sig)" --user "$S3_KEY:$S3_SECRET" \
  -X DELETE "$URL" -o /dev/null 2>/dev/null || true

case "$A$B" in
  *000*)
    echo "FAIL: inconclusive -- a writer did not get an HTTP response" >&2
    cat "$TMP/a.err" "$TMP/b.err" >&2 2>/dev/null || true
    exit 2
    ;;
esac

OK=0; CONFLICT=0
for c in "$A" "$B"; do
  case "$c" in
    200|201|204) OK=$((OK+1)) ;;
    409|412)     CONFLICT=$((CONFLICT+1)) ;;
    *)           echo "unexpected status $c" >&2; exit 2 ;;
  esac
done

if [ "$OK" -eq 1 ] && [ "$CONFLICT" -eq 1 ]; then
  echo "PASS: exactly one writer won, one was rejected"
  exit 0
fi

if [ "$OK" -eq 2 ]; then
  echo "FAIL: both writers succeeded -- this store ignores If-None-Match: *" >&2
  echo "      Do not use it as a celld fleet bucket." >&2
  exit 1
fi

echo "FAIL: no writer succeeded ($OK ok, $CONFLICT conflicts)" >&2
exit 1
