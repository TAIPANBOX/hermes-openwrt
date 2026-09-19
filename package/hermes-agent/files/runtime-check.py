#!/usr/bin/env python3
"""@codex 2026-09-19: refuse conflicting upstream overrides of UCI runtime settings."""
import hmac
import io
import os
import sys
from pathlib import Path


class RuntimeConflict(Exception):
    """A diagnostic containing names only, never credential values."""


def main() -> int:
    protected = ("HERMES_HOME", "OPENAI_BASE_URL", "HERMES_MODEL", "OPENAI_API_KEY",
                 "TELEGRAM_BOT_TOKEN", "OPENWRT_MCP_TOKEN",
                 "TELEGRAM_ALLOWED_USERS", "TELEGRAM_ALLOW_ALL_USERS", "TELEGRAM_HOME_CHANNEL",
                 "HERMES_DISABLE_LAZY_INSTALLS")
    expected = {name: os.environ.get(name) for name in protected}
    try:
        from hermes_cli.config import _sanitize_env_lines
        from hermes_cli.env_loader import load_hermes_dotenv
        dotenv = Path(expected["HERMES_HOME"] or "/srv/hermes") / ".env"
        if dotenv.exists():
            raw = dotenv.read_bytes()
            if b"\x00" in raw:
                raise RuntimeConflict(".env requires normalization; reconcile it before startup")
            lines = io.StringIO(raw.decode("utf-8-sig"), newline=None).readlines()
            if _sanitize_env_lines(lines) != lines:
                raise RuntimeConflict(".env requires normalization; reconcile it before startup")
        load_hermes_dotenv()
        for name, value in expected.items():
            if os.environ.get(name) != value:
                raise RuntimeConflict(f"upstream environment overrides UCI-managed {name}")
        from hermes_cli.config import get_custom_provider_extra_headers, load_config
        from hermes_cli.runtime_provider import resolve_runtime_provider
        config = load_config()
        model = config.get("model", {})
        # A primary pool can rotate to another credential after startup. UCI owns
        # this primary key, so matching pools require operator reconciliation.
        from agent.credential_pool import get_custom_provider_pool_key
        from hermes_cli.auth import read_credential_pool
        pool_key = get_custom_provider_pool_key(expected["OPENAI_BASE_URL"], provider_name="custom")
        if pool_key and read_credential_pool(pool_key):
            raise RuntimeConflict("primary credential pool conflicts with the UCI key file")
        runtime = resolve_runtime_provider()
        if runtime.get("credential_pool") is not None:
            raise RuntimeConflict("primary credential pool conflicts with the UCI key file")
        endpoint = expected["OPENAI_BASE_URL"] or ""
        key = expected["OPENAI_API_KEY"] or ""
        if (not endpoint or not key or not isinstance(model, dict)
                or model.get("default") != expected["HERMES_MODEL"]
                or runtime.get("base_url", "").rstrip("/") != endpoint.rstrip("/")
                or runtime.get("api_mode") != "chat_completions"
                or not hmac.compare_digest(str(runtime.get("api_key") or ""), key)):
            raise RuntimeConflict("upstream provider, endpoint, model or credential conflicts with UCI")
        headers = dict(model.get("default_headers") or {})
        headers.update(get_custom_provider_extra_headers(endpoint, config=config))
        for name, value in headers.items():
            if name.lower() == "authorization" and str(value) != "Bearer " + key:
                raise RuntimeConflict("upstream Authorization header conflicts with the UCI credential")
    except Exception as exc:  # noqa: BLE001 - never print upstream exceptions containing secrets
        message = str(exc) if isinstance(exc, RuntimeConflict) else type(exc).__name__
        sys.stderr.write(f"hermes-runtime: startup refused ({message}); operator configuration preserved\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
