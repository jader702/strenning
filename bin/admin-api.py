#!/usr/bin/env python3
import os
import re
import shlex
import subprocess
from pathlib import Path

from flask import Flask, jsonify, request

APP = Flask(__name__)

PROJECT_DIR = Path("/opt/camera-streaming")
CHANNELS_FILE = PROJECT_DIR / "config" / "channels.env"
SECRETS_DIR = PROJECT_DIR / "secrets"
HLS_DIR = Path("/var/www/cameras/hls")
SYSTEMD_DIR = Path("/etc/systemd/system")

SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{1,48}$")


def run(cmd, timeout=20):
    return subprocess.run(
        cmd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )


def shell_quote(value):
    return shlex.quote(value)


def env_key(slug):
    return slug.replace("-", "_")


def parse_channels_env():
    channels = []
    current_ids = []
    values = {}
    if CHANNELS_FILE.exists():
        for raw in CHANNELS_FILE.read_text().splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            value = value.strip().strip('"')
            values[key] = value
        current_ids = values.get("CHANNELS", "").split()
        for slug in current_ids:
            key = env_key(slug)
            channels.append(
                {
                    "id": slug,
                    "name": values.get(f"CHANNEL_{key}_NAME", slug),
                    "public_path": values.get(f"CHANNEL_{key}_PUBLIC_PATH", f"/hls/{slug}.m3u8"),
                    "service": values.get(f"CHANNEL_{key}_SERVICE", f"camera-stream-{slug}.service"),
                }
            )
    return current_ids, values, channels


def write_channels_env(ids, values):
    lines = [
        "# Public camera channel metadata. Do not put RTSP URLs or passwords here.",
        f'CHANNELS="{" ".join(ids)}"',
        "",
    ]
    for slug in ids:
        key = env_key(slug)
        lines.extend(
            [
                f'CHANNEL_{key}_NAME="{values[f"CHANNEL_{key}_NAME"]}"',
                f'CHANNEL_{key}_PUBLIC_PATH="{values[f"CHANNEL_{key}_PUBLIC_PATH"]}"',
                f'CHANNEL_{key}_PLAYLIST="{values[f"CHANNEL_{key}_PLAYLIST"]}"',
                f'CHANNEL_{key}_SEGMENT_DIR="{values[f"CHANNEL_{key}_SEGMENT_DIR"]}"',
                f'CHANNEL_{key}_SERVICE="{values[f"CHANNEL_{key}_SERVICE"]}"',
                "",
            ]
        )
    tmp = CHANNELS_FILE.with_suffix(".env.tmp")
    tmp.write_text("\n".join(lines))
    os.chown(tmp, 0, 0)
    os.chmod(tmp, 0o644)
    tmp.replace(CHANNELS_FILE)


def normalize_source_url(source_url):
    if source_url.startswith(("http://", "https://")) and source_url.split("?", 1)[0].endswith(".ts"):
        base, _, query = source_url.partition("?")
        base = base.rsplit("/", 1)[0] + "/playlist.m3u8"
        return base + (("?" + query) if query else "")
    return source_url


def validate_payload(data):
    name = str(data.get("name", "")).strip()
    slug = str(data.get("slug", "")).strip().lower()
    source_url = normalize_source_url(str(data.get("source_url") or data.get("rtsp_url", "")).strip())
    mode = str(data.get("mode", "copy")).strip()

    if not name:
        return None, "Nome do canal e obrigatorio."
    if not SLUG_RE.match(slug):
        return None, "Caminho deve usar apenas letras minusculas, numeros e hifens."
    if not source_url.startswith(("rtsp://", "http://", "https://")):
        return None, "URL deve comecar com rtsp://, http:// ou https://."
    if mode not in {"copy", "transcode"}:
        return None, "Modo invalido."

    return {"name": name, "slug": slug, "source_url": source_url, "mode": mode}, None


def write_channel_service(payload):
    slug = payload["slug"]
    secret_file = SECRETS_DIR / f"{slug}.env"
    service_name = f"camera-stream-{slug}.service"
    unit_file = SYSTEMD_DIR / service_name
    playlist = HLS_DIR / f"{slug}.m3u8"
    segment = HLS_DIR / f"{slug}-%05d.ts"
    systemd_segment = str(segment).replace("%", "%%")

    SECRETS_DIR.mkdir(parents=True, exist_ok=True)
    HLS_DIR.mkdir(parents=True, exist_ok=True)

    secret_tmp = secret_file.with_suffix(".env.tmp")
    secret_tmp.write_text("SOURCE_URL=" + shell_quote(payload["source_url"]) + "\n")
    os.chown(secret_tmp, 0, 0)
    os.chmod(secret_tmp, 0o600)
    secret_tmp.replace(secret_file)

    if payload["mode"] == "copy":
        video_args = "-an -c:v copy"
    else:
        video_args = "-an -c:v libx264 -preset veryfast -tune zerolatency -profile:v main -pix_fmt yuv420p -r 24 -g 48 -keyint_min 48 -sc_threshold 0"

    unit = f"""[Unit]
Description=Camera HLS stream - {payload["name"]}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile={secret_file}
ExecStartPre=/usr/bin/mkdir -p {HLS_DIR}
ExecStartPre=/usr/bin/find {HLS_DIR} -maxdepth 1 -type f -name '{slug}*' -delete
ExecStart=/bin/sh -c 'case "$SOURCE_URL" in rtsp://*) transport="-rtsp_transport tcp" ;; *) transport="" ;; esac; exec /usr/bin/ffmpeg -hide_banner -nostdin -loglevel warning $transport -i "$SOURCE_URL" {video_args} -f hls -hls_time 2 -hls_list_size 6 -hls_flags delete_segments+program_date_time+independent_segments -hls_segment_filename {systemd_segment} {playlist}'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
"""
    tmp = unit_file.with_suffix(".service.tmp")
    tmp.write_text(unit)
    os.chown(tmp, 0, 0)
    os.chmod(tmp, 0o644)
    tmp.replace(unit_file)

    return service_name, str(playlist)


@APP.get("/admin/api/channels")
def list_channels():
    _, _, channels = parse_channels_env()
    return jsonify({"channels": channels})


@APP.post("/admin/api/channels")
def add_channel():
    data = request.get_json(silent=True) or {}
    payload, error = validate_payload(data)
    if error:
        return jsonify({"ok": False, "error": error}), 400

    ids, values, _ = parse_channels_env()
    slug = payload["slug"]
    if slug in ids:
        return jsonify({"ok": False, "error": "Ja existe canal com esse caminho."}), 409

    service_name, playlist = write_channel_service(payload)
    key = env_key(slug)
    ids.append(slug)
    values[f"CHANNEL_{key}_NAME"] = payload["name"]
    values[f"CHANNEL_{key}_PUBLIC_PATH"] = f"/hls/{slug}.m3u8"
    values[f"CHANNEL_{key}_PLAYLIST"] = playlist
    values[f"CHANNEL_{key}_SEGMENT_DIR"] = str(HLS_DIR)
    values[f"CHANNEL_{key}_SERVICE"] = service_name
    write_channels_env(ids, values)

    run(["systemctl", "daemon-reload"])
    enable = run(["systemctl", "enable", "--now", service_name], timeout=30)
    run([str(PROJECT_DIR / "bin" / "generate-status.sh")], timeout=30)

    if enable.returncode != 0:
        return jsonify({"ok": False, "error": "Canal criado, mas o servico nao iniciou.", "service": service_name}), 500

    return jsonify(
        {
            "ok": True,
            "id": slug,
            "name": payload["name"],
            "service": service_name,
            "public_path": f"/hls/{slug}.m3u8",
        }
    )


@APP.post("/admin/api/probe")
def probe_channel():
    data = request.get_json(silent=True) or {}
    source_url = normalize_source_url(str(data.get("source_url") or data.get("rtsp_url", "")).strip())
    if not source_url.startswith(("rtsp://", "http://", "https://")):
        return jsonify({"ok": False, "error": "URL deve comecar com rtsp://, http:// ou https://."}), 400

    cmd = [
        "/usr/bin/ffprobe",
        "-v",
        "error",
    ]
    if source_url.startswith("rtsp://"):
        cmd.extend(["-rtsp_transport", "tcp"])
    cmd.extend(
        [
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=codec_name,width,height",
            "-of",
            "default=noprint_wrappers=1",
            source_url,
        ]
    )

    result = run(cmd, timeout=18)
    if result.returncode != 0:
        return jsonify({"ok": False, "error": "Nao foi possivel testar o RTSP."}), 400

    info = {}
    for line in result.stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            info[key] = value
    return jsonify({"ok": True, "source_url_normalized": source_url != str(data.get("source_url") or data.get("rtsp_url", "")).strip(), "stream": info})


if __name__ == "__main__":
    APP.run(host="127.0.0.1", port=8092)
