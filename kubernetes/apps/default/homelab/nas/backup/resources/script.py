#!/usr/bin/env python3
"""
TrueNAS Config Backup – WebSocket API (core.download)
Keeps only the last <keep> backups locally.
"""

import argparse
import json
import os
import ssl
import sys
import time
import glob
import websocket
import requests
from urllib3.exceptions import InsecureRequestWarning

requests.packages.urllib3.disable_warnings(category=InsecureRequestWarning)


# ---------- helpers ----------
def send_and_receive(ws, method, params=None, msg_id=1):
    """JSON-RPC 2.0 request / response"""
    ws.send(json.dumps({
        "jsonrpc": "2.0",
        "id": msg_id,
        "method": method,
        "params": params or []
    }))
    resp = json.loads(ws.recv())
    if "error" in resp:
        raise RuntimeError(f"API error: {resp['error']}")
    return resp.get("result")


def download_file(url, output_path, verify_ssl=True):
    """Stream-download the generated tar"""
    print(f"Downloading from: {url}")
    with requests.get(url, verify=verify_ssl, stream=True) as r:
        r.raise_for_status()
        with open(output_path, "wb") as f:
            for chunk in r.iter_content(chunk_size=8192):
                f.write(chunk)
    print(f"Saved -> {output_path}")


def purge_old_backups(directory, pattern, keep):
    """Delete all but the <keep> newest files matching <pattern> in <directory>"""
    files = sorted(glob.glob(os.path.join(directory, pattern)), key=os.path.getmtime, reverse=True)
    for f in files[keep:]:
        os.remove(f)
        print(f"Purged old backup: {f}")


# ---------- main ----------
def main():
    parser = argparse.ArgumentParser(description="Backup TrueNAS configuration via WebSocket")
    parser.add_argument("-H", "--host", required=True, help="TrueNAS IP / hostname")
    parser.add_argument("-k", "--api-key", required=True, help="API key")
    parser.add_argument("-o", "--output-dir", default=".", help="Directory to store backups (default: current)")
    parser.add_argument("--no-verify-ssl", action="store_true", help="Skip TLS verification")
    parser.add_argument("--secret-seed", action="store_true", help="Include passwords/keys")
    parser.add_argument("--root-keys", action="store_true", help="Include root authorized_keys")
    parser.add_argument("--keep", type=int, default=40, help="Keep last N backups (default: 40)")
    args = parser.parse_args()

    ws_url = f"wss://{args.host}/api/current"
    sslopt = None if not args.no_verify_ssl else {"sslopt": {"cert_reqs": ssl.CERT_NONE}}

    ws = websocket.create_connection(ws_url, sslopt=sslopt)
    try:
        # 1. authenticate
        if not send_and_receive(ws, "auth.login_with_api_key", [args.api_key], 1):
            raise RuntimeError("Authentication failed")
        print("Authenticated")

        # 2. fetch version
        version: str = send_and_receive(ws, "system.version", [], 2)
        safe_version = version.replace(" ", "_").replace("/", "-")
        print(f"TrueNAS version: {version}")

        # 3. request config generation
        options = {
            "secretseed": args.secret_seed,
            "root_authorized_keys": args.root_keys,
        }
        filename = f"{safe_version}-{int(time.time())}.tar"

        job_id, dl_path = send_and_receive(
            ws, "core.download", ["config.save", [options], filename], 3
        )
        print(f"Config job {job_id} created")

        # 4. HTTP-download the file
        full_url = f"https://{args.host}{dl_path}"
        output_path = os.path.join(args.output_dir, filename)
        download_file(full_url, output_path, verify_ssl=not args.no_verify_ssl)

        # 5. housekeeping – purge older backups
        purge_old_backups(args.output_dir, "*.tar", args.keep)

    finally:
        ws.close()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit("\nAborted by user")
