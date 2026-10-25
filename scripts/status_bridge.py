#!/usr/bin/env python3
"""Local bridge for Matter patch status and capability checks."""
import hmac
import json
import os
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"
PORT = 18764
SCRIPT = "/config/core_patches/check_matter_patch.sh"
TOKEN_FILE = "/config/core_patches/bridge_token"
INSTALL_SCRIPT = "/config/custom_components/matter_patch_manager/scripts/patch_matter.sh"

def read_token():
    st = os.stat(TOKEN_FILE)
    if st.st_mode & 0o077:
        raise RuntimeError("Token file must be accessible only to its owner (chmod 600)")
    with open(TOKEN_FILE, encoding="utf-8") as f:
        token = f.read().strip()
    if len(token) < 32:
        raise RuntimeError("Token too short")
    return token

TOKEN = read_token()
INSTALL_LOCK = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/status", "/capabilities"):
            return self.respond(404, {"error": "not_found"})
        supplied = self.headers.get("Authorization", "")
        if not hmac.compare_digest(supplied, "Bearer " + TOKEN):
            return self.respond(401, {"error": "unauthorized"})
        if self.path == "/capabilities":
            return self.respond(200, {
                "status_check": True,
                "install_script_present": os.path.isfile(INSTALL_SCRIPT) and os.access(INSTALL_SCRIPT, os.R_OK),
                "installation_enabled": True,
            })
        try:
            result = subprocess.run(
                ["bash", SCRIPT], capture_output=True, text=True,
                timeout=90, check=False,
            )
            data = json.loads(result.stdout)
            if not isinstance(data, dict) or data.get("status") not in {
                "installed", "available", "incompatible", "error"
            }:
                raise ValueError("invalid status")
        except (OSError, subprocess.TimeoutExpired, ValueError, json.JSONDecodeError):
            data = {"status": "error", "detail": "status_check_failed"}
        self.respond(200, data)

    def do_POST(self):
        if self.path != "/install":
            return self.respond(404, {"error": "not_found"})

        supplied = self.headers.get("Authorization", "")
        if not hmac.compare_digest(supplied, "Bearer " + TOKEN):
            return self.respond(401, {"error": "unauthorized"})

        if self.headers.get("Content-Length", "0") != "0":
            return self.respond(400, {"error": "body_not_allowed"})

        if not INSTALL_LOCK.acquire(blocking=False):
            return self.respond(409, {"error": "installation_in_progress"})

        try:
            if not os.path.isfile(INSTALL_SCRIPT):
                return self.respond(503, {"error": "installer_missing"})

            try:
                result = subprocess.run(
                    ["bash", SCRIPT],
                    capture_output=True,
                    text=True,
                    timeout=90,
                    check=False,
                )
                status = (
                    json.loads(result.stdout).get("status")
                    if result.returncode == 0
                    else None
                )
            except (OSError, ValueError, subprocess.TimeoutExpired):
                status = None

            if status != "available":
                return self.respond(409, {"error": "patch_not_available"})

            try:
                result = subprocess.run(
                    ["bash", INSTALL_SCRIPT],
                    capture_output=True,
                    text=True,
                    timeout=240,
                    check=False,
                )
            except (OSError, subprocess.TimeoutExpired):
                return self.respond(500, {"error": "installer_failed"})

            if result.returncode != 0:
                return self.respond(500, {"error": "installer_failed"})

            return self.respond(200, {
                "status": "installed",
                "restart_required": True,
            })
        finally:
            INSTALL_LOCK.release()

    def respond(self, code, body):
        payload = json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        pass  # Never log authorization headers.

if __name__ == "__main__":
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
