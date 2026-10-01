#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="/opt/camera-streaming"
CHANNELS_FILE="$PROJECT_DIR/config/channels.env"
OUTPUT="$PROJECT_DIR/admin/status.json"
DOMAIN="cameras.radiowebcriativa.com.br"

if [ -r "$CHANNELS_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CHANNELS_FILE"
else
  CHANNELS=""
fi

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().rstrip("\n"))[1:-1])'
}

cert_not_after="$(
  openssl x509 -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" -noout -enddate 2>/dev/null |
    sed 's/^notAfter=//' || true
)"
cert_iso="$(
  if [ -n "$cert_not_after" ]; then
    date -u -d "$cert_not_after" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true
  fi
)"

if command -v docker >/dev/null 2>&1; then
  containers_summary="$(docker ps --format '{{.Names}}|{{.Image}}|{{.Status}}' 2>/dev/null | head -20 || true)"
  containers_state="available"
else
  containers_summary=""
  containers_state="not_installed"
fi

tmp="$(mktemp)"
{
  printf '{\n'
  printf '  "generated_at": "%s",\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '  "domain": "%s",\n' "$DOMAIN"
  printf '  "certificate": {\n'
  printf '    "not_after": "%s",\n' "$(printf '%s' "$cert_not_after" | json_escape)"
  printf '    "not_after_iso": "%s"\n' "$(printf '%s' "$cert_iso" | json_escape)"
  printf '  },\n'
  printf '  "containers": {\n'
  printf '    "state": "%s",\n' "$containers_state"
  printf '    "summary": "%s"\n' "$(printf '%s' "$containers_summary" | json_escape)"
  printf '  },\n'
  printf '  "channels": [\n'

  first=1
  now="$(date +%s)"
  for channel in ${CHANNELS:-}; do
    key="${channel//-/_}"
    eval "name=\${CHANNEL_${key}_NAME:-$channel}"
    eval "public_path=\${CHANNEL_${key}_PUBLIC_PATH:-}"
    eval "playlist=\${CHANNEL_${key}_PLAYLIST:-}"
    eval "segment_dir=\${CHANNEL_${key}_SEGMENT_DIR:-}"
    eval "service=\${CHANNEL_${key}_SERVICE:-}"

    status="offline"
    age=""
    size=0
    latest_segment=""
    service_state="unknown"

    if [ -n "$service" ]; then
      service_state="$(systemctl is-active "$service" 2>/dev/null || true)"
    fi

    if [ -f "$playlist" ]; then
      mtime="$(stat -c %Y "$playlist" 2>/dev/null || echo 0)"
      age="$((now - mtime))"
      size="$(stat -c %s "$playlist" 2>/dev/null || echo 0)"
      latest_segment="$(awk '/^[^#].*\.ts$/ { last=$0 } END { print last }' "$playlist" 2>/dev/null || true)"
      if [ "$age" -le 20 ] && [ "$size" -gt 0 ]; then
        status="online"
      fi
    fi

    [ "$first" -eq 1 ] || printf ',\n'
    first=0
    printf '    {\n'
    printf '      "id": "%s",\n' "$(printf '%s' "$channel" | json_escape)"
    printf '      "name": "%s",\n' "$(printf '%s' "$name" | json_escape)"
    printf '      "status": "%s",\n' "$status"
    printf '      "service": "%s",\n' "$(printf '%s' "$service" | json_escape)"
    printf '      "service_state": "%s",\n' "$(printf '%s' "$service_state" | json_escape)"
    printf '      "public_path": "%s",\n' "$(printf '%s' "$public_path" | json_escape)"
    printf '      "playlist_age_seconds": "%s",\n' "$(printf '%s' "$age" | json_escape)"
    printf '      "playlist_size_bytes": %s,\n' "$size"
    printf '      "latest_segment": "%s",\n' "$(printf '%s' "$latest_segment" | json_escape)"
    printf '      "segment_dir": "%s"\n' "$(printf '%s' "$segment_dir" | json_escape)"
    printf '    }'
  done
  printf '\n  ]\n'
  printf '}\n'
} > "$tmp"

install -o root -g www-data -m 0640 "$tmp" "$OUTPUT"
rm -f "$tmp"

