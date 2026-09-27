#!/usr/bin/env python3
"""Download and retain UniFi Network configuration backups."""

from __future__ import annotations

import logging
import os
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from urllib.parse import urljoin, urlparse

import requests
from requests.packages.urllib3.exceptions import InsecureRequestWarning

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
LOG = logging.getLogger("unifi-backup")


def env_bool(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    return default if value is None else value.lower() == "true"


@dataclass(frozen=True)
class Config:
    host: str
    api_key: str
    port: int = 443
    site: str = "default"
    verify_ssl: bool = False
    outdir: Path = Path(".")
    days: int = 0
    keep: int = 90
    healthchecks_id: str = ""

    @classmethod
    def from_env(cls) -> "Config":
        host = os.getenv("UNIFI_HOST", "").strip()
        api_key = os.getenv("UNIFI_API_KEY", "").strip()
        if not host:
            raise ValueError("UNIFI_HOST is required")
        if not api_key:
            raise ValueError("UNIFI_API_KEY is required")

        keep = int(os.getenv("UNIFI_KEEP", "90"))
        if keep < 1:
            raise ValueError("UNIFI_KEEP must be at least 1")

        return cls(
            host=host,
            api_key=api_key,
            port=int(os.getenv("UNIFI_PORT", "443")),
            site=os.getenv("UNIFI_SITE", "default"),
            verify_ssl=env_bool("UNIFI_VERIFY_SSL"),
            outdir=Path(os.getenv("UNIFI_OUTDIR", ".")),
            days=int(os.getenv("UNIFI_DAYS", "0")),
            keep=keep,
            healthchecks_id=os.getenv("HEALTHCHECKS_ID", "").strip(),
        )


class Healthchecks:
    def __init__(self, check_id: str, session: requests.Session | None = None):
        self.check_id = check_id.strip("/")
        self.session = session or requests.Session()

    def ping(self, status: str = "") -> None:
        if not self.check_id:
            return
        suffix = f"/{status}" if status else ""
        try:
            response = self.session.get(
                f"https://hc-ping.com/{self.check_id}{suffix}", timeout=10
            )
            response.raise_for_status()
        except requests.RequestException as error:
            LOG.warning("Healthchecks ping failed: %s", error)


class UniFiBackupClient:
    def __init__(
        self,
        config: Config,
        session: requests.Session | None = None,
    ) -> None:
        self.config = config
        self.base_url = f"https://{config.host}:{config.port}"
        self.session = session or requests.Session()
        self.session.verify = config.verify_ssl
        self.session.headers.update({"X-API-Key": config.api_key})
        if not config.verify_ssl:
            requests.packages.urllib3.disable_warnings(InsecureRequestWarning)

    def trigger(self) -> str:
        url = self._url(f"/proxy/network/api/s/{self.config.site}/cmd/backup")
        response = self.session.post(
            url,
            json={"cmd": "backup", "days": self.config.days},
            timeout=120,
        )
        response.raise_for_status()

        try:
            payload = response.json()
        except ValueError as error:
            raise RuntimeError("UniFi returned an invalid backup response") from error

        if payload.get("meta", {}).get("rc") != "ok":
            raise RuntimeError(f"UniFi backup request failed: {payload.get('meta', {})}")

        results = payload.get("data", [])
        backup_path = results[0].get("url") if results else None
        if not backup_path:
            raise RuntimeError("UniFi did not return a backup download path")

        LOG.info("UniFi generated backup at %s", backup_path)
        return backup_path

    def download(self, backup_path: str) -> Path:
        parsed_path = urlparse(backup_path).path
        if not parsed_path.startswith("/proxy/network"):
            parsed_path = f"/proxy/network{parsed_path}"

        source_name = Path(parsed_path).name
        if not source_name or source_name in {".", ".."}:
            raise RuntimeError("UniFi returned an invalid backup filename")
        if Path(source_name).suffix.lower() != ".unf":
            raise RuntimeError("UniFi returned a non-.unf backup filename")

        self.config.outdir.mkdir(parents=True, exist_ok=True)
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        destination = self.config.outdir / f"{timestamp}_{source_name}"
        partial = destination.with_suffix(f"{destination.suffix}.part")

        try:
            with self.session.get(
                self._url(parsed_path),
                stream=True,
                timeout=120,
                allow_redirects=False,
            ) as response:
                response.raise_for_status()
                content_type = response.headers.get("Content-Type", "").lower()
                if "text/html" in content_type:
                    raise RuntimeError("UniFi returned HTML instead of a backup")

                with partial.open("wb") as output:
                    for chunk in response.iter_content(chunk_size=65536):
                        if chunk:
                            output.write(chunk)

            if partial.stat().st_size == 0:
                raise RuntimeError("UniFi returned an empty backup")
            partial.replace(destination)
        except Exception:
            partial.unlink(missing_ok=True)
            raise

        LOG.info("Saved %d bytes to %s", destination.stat().st_size, destination)
        return destination

    def _url(self, path: str) -> str:
        return urljoin(f"{self.base_url}/", path.lstrip("/"))


def prune_backups(directory: Path, keep: int) -> list[Path]:
    backups = sorted(
        (path for path in directory.glob("*.unf") if path.is_file()),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    removed = []
    for backup in backups[keep:]:
        backup.unlink()
        removed.append(backup)
        LOG.info("Removed expired backup %s", backup)
    return removed


def execute(
    config: Config,
    client: UniFiBackupClient | None = None,
    healthchecks: Healthchecks | None = None,
) -> int:
    backup_client = client or UniFiBackupClient(config)
    checks = healthchecks or Healthchecks(config.healthchecks_id)
    checks.ping("start")

    try:
        backup_path = backup_client.trigger()
        backup_client.download(backup_path)
        prune_backups(config.outdir, config.keep)
    except Exception:
        LOG.exception("UniFi backup failed")
        checks.ping("fail")
        return 1

    checks.ping()
    return 0


def main() -> int:
    try:
        config = Config.from_env()
    except (TypeError, ValueError) as error:
        LOG.error("Invalid configuration: %s", error)
        return 1
    return execute(config)


if __name__ == "__main__":
    sys.exit(main())
