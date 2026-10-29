#!/bin/sh
# install.sh -- enrol this node with a cfb control plane.
#
# Idempotent: re-running upgrades the binary in place and leaves the node credential alone.
# Every step is outbound. No inbound port is opened at any point.
#
# Usage: sh install.sh --token <token> --control https://cfb.example

set -eu

CONTROL=""
TOKEN=""
BIN_URL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --token)   TOKEN=$2;   shift 2 ;;
    --control) CONTROL=$2; shift 2 ;;
    --binary)  BIN_URL=$2; shift 2 ;;
    -h|--help)
      sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$CONTROL" ] || { echo "--control is required" >&2; exit 2; }
[ -n "$TOKEN" ]   || { echo "--token is required"   >&2; exit 2; }
CONTROL=${CONTROL%/}
BIN_URL=${BIN_URL:-$CONTROL/dl/cfbd}

say() { printf '%s\n' "$*" >&2; }
die() { say "error: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
command -v curl >/dev/null || die "curl is required"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|aarch64) ;;
  *) die "unsupported architecture: $ARCH" ;;
esac
OS=$(uname -s)
[ "$OS" = "Linux" ] || die "only Linux is supported"

say "installing cfbd for $OS/$ARCH"

# --- binary ---------------------------------------------------------------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

curl -qfsSL "$BIN_URL" -o "$TMP/cfbd" || die "download failed: $BIN_URL"
curl -qfsSL "$BIN_URL.sha256" -o "$TMP/cfbd.sha256" || die "checksum download failed"

EXPECTED=$(cut -d' ' -f1 <"$TMP/cfbd.sha256")
ACTUAL=$(sha256sum "$TMP/cfbd" | cut -d' ' -f1)
[ "$EXPECTED" = "$ACTUAL" ] || die "checksum mismatch"

install -m 0755 "$TMP/cfbd" /usr/local/bin/cfbd

# --- config ---------------------------------------------------------------
mkdir -p /etc/cfbd /var/lib/cfbd

if [ ! -f /etc/cfbd/config.toml ]; then
  cat >/etc/cfbd/config.toml <<EOF
control_url  = "$CONTROL"
token_file   = "/etc/cfbd/node.token"
capabilities = ["exec", "container", "port.forward", "metrics"]
EOF
  chmod 0644 /etc/cfbd/config.toml
fi

# --- credential -----------------------------------------------------------
# The enrolment token is single use and expires in 15 minutes. Exchange it exactly once and
# never display the result. A second exchange is an alert, not a retry.
if [ ! -f /etc/cfbd/node.token ]; then
  say "exchanging enrolment token"
  RESP=$(curl -qfsS -X POST \
    -H "authorization: Bearer $TOKEN" \
    -H 'content-type: application/json' \
    --data '{"hostname":"'"$(hostname)"'","arch":"'"$ARCH"'"}' \
    "$CONTROL/api/v1/nodes/enroll/exchange") || die "token exchange failed"

  # Extract the credential without a JSON parser dependency.
  CRED=$(printf '%s' "$RESP" | sed -n 's/.*"credential":"\([^"]*\)".*/\1/p')
  [ -n "$CRED" ] || die "no credential in response"

  umask 077
  printf '%s' "$CRED" >/etc/cfbd/node.token
  chmod 0600 /etc/cfbd/node.token
  say "credential written to /etc/cfbd/node.token (0600)"
fi

# --- service --------------------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
  cat >/etc/systemd/system/cfbd.service <<'EOF'
[Unit]
Description=cfb node agent
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/cfbd run --config /etc/cfbd/config.toml
Restart=always
RestartSec=2
# KillMode=mixed: SIGTERM to the agent only, so it can stop children in order.
KillMode=mixed
TimeoutStopSec=30
StateDirectory=cfbd
RuntimeDirectory=cfbd
# The agent needs to supervise containers; it does not need a public port.
NoNewPrivileges=no
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now cfbd
  say "cfbd started"
else
  say "systemd not found; start manually: cfbd run --config /etc/cfbd/config.toml"
fi

say "node enrolled; check with: cfbd doctor"
