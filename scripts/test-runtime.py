#!/usr/bin/env python3
"""Runtime regressions against the Python payload actually shipped on OpenWrt.

@codex 2026-09-19: runs in the package test container, with no model/API calls.
"""
import importlib.util
import json
import os
import random
import shlex
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from unittest.mock import patch

import yaml
from hermes_cli.tools_config import _get_platform_tools

ROOT = Path(__file__).resolve().parents[1]
FILES = Path(os.environ.get("PRODUCT_FILES", str(ROOT / "package/hermes-agent/files")))


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.env = dict(os.environ, HERMES_HOME=str(self.home),
                        HERMES_DISABLE_LAZY_INSTALLS="1", PYTHONDONTWRITEBYTECODE="1")

    def configure(self, tools="memory", mcp=None, endpoint=None, model="runtime-model", profile=None):
        if profile is not None and endpoint is None:
            # profile is only ever the argument after model (argv[6]); force the
            # full mcp/endpoint/model form so it lands there unambiguously, the
            # same shape both the init and the wrapper always call it with.
            endpoint = "http://127.0.0.1:9/v1"
        args = ["python3", str(FILES / "set-toolsets.py"), str(self.home), tools]
        if mcp is not None or endpoint is not None:
            args.append(mcp or "")
        if endpoint is not None:
            args += [endpoint, model]
        if profile is not None:
            args.append(profile)
        return subprocess.run(args, env=self.env, text=True, check=False, capture_output=True)

    def config(self):
        return yaml.safe_load((self.home / "config.yaml").read_text())

    def test_gateway_selection(self):
        self.assertEqual(self.configure().returncode, 0)
        for platform in ("telegram", "cron"):
            actual = _get_platform_tools(self.config(), platform)
            self.assertIn("memory", actual)
            self.assertFalse({"terminal", "file", "code_execution"} & actual, actual)

    def test_empty_selection(self):
        self.assertEqual(self.configure("").returncode, 0)
        for platform in ("telegram", "cron"):
            self.assertFalse({"terminal", "file", "memory"} &
                             _get_platform_tools(self.config(), platform))

    def test_bad_yaml_is_fatal_and_preserved(self):
        for content in ("[broken", "- a-list", "platform_toolsets: 7\n"):
            with self.subTest(content=content):
                (self.home / "config.yaml").write_text(content)
                self.assertNotEqual(self.configure().returncode, 0)
                self.assertEqual((self.home / "config.yaml").read_text(), content)

    def test_unknown_toolset_is_fatal(self):
        self.assertNotEqual(self.configure("memory,not-a-real-toolset").returncode, 0)

    def test_mcp_configuration(self):
        self.assertEqual(self.configure(mcp="http://127.0.0.1:8730/mcp").returncode, 0)
        servers = self.config()["mcp_servers"]
        ours = servers["openwrt"]
        self.assertEqual(ours["url"], "http://127.0.0.1:8730/mcp")
        self.assertEqual(ours["headers"]["Authorization"], "Bearer ${OPENWRT_MCP_TOKEN}")
        self.assertEqual(self.configure(mcp="").returncode, 0)
        self.assertNotIn("openwrt", self.config().get("mcp_servers", {}))

    def test_mcp_collision_preserved(self):
        original = {"mcp_servers": {"openwrt": {"command": "operator-owned"}}}
        (self.home / "config.yaml").write_text(yaml.safe_dump(original))
        self.assertNotEqual(self.configure(mcp="http://127.0.0.1:8730/mcp").returncode, 0)
        self.assertEqual(self.config(), original)

    def test_mcp_identical_manual_entry_is_adopted(self):
        url = "http://127.0.0.1:8730/mcp"
        manual = {"mcp_servers": {"openwrt": {"url": url,
                  "headers": {"Authorization": "Bearer ${OPENWRT_MCP_TOKEN}"}}}}
        (self.home / "config.yaml").write_text(yaml.safe_dump(manual))
        result = self.configure(mcp=url)
        self.assertEqual(result.returncode, 0, result.stderr)
        config = self.config()
        self.assertEqual(config["mcp_servers"]["openwrt"], manual["mcp_servers"]["openwrt"])
        self.assertTrue(config.get("_openwrt_mcp_managed"))
        self.assertEqual(self.configure(mcp="").returncode, 0)
        self.assertNotIn("openwrt", self.config().get("mcp_servers", {}))

    def test_config_preserves_other_settings(self):
        original = {"model": "operator-model", "platform_toolsets": {"discord": ["web"]},
                    "mcp_servers": {"other": {"command": "operator-command"}}}
        (self.home / "config.yaml").write_text(yaml.safe_dump(original))
        self.assertEqual(self.configure("memory,memory", "https://localhost/mcp").returncode, 0)
        config = self.config()
        self.assertEqual(config["model"], original["model"])
        self.assertEqual(config["platform_toolsets"]["discord"], ["web"])
        self.assertEqual(config["platform_toolsets"]["telegram"], ["memory"])
        self.assertEqual(config["mcp_servers"]["other"], original["mcp_servers"]["other"])
        inode = (self.home / "config.yaml").stat().st_ino
        self.assertEqual(self.configure("memory,memory", "https://localhost/mcp").returncode, 0)
        self.assertEqual(inode, (self.home / "config.yaml").stat().st_ino)
        self.assertEqual((self.home / "config.yaml").stat().st_mode & 0o777, 0o600)

    def test_config_untouched_when_already_current(self):
        self.assertEqual(self.configure().returncode, 0)
        path = self.home / "config.yaml"
        with path.open("a", encoding="utf-8") as stream:
            stream.write('# operator note\noperator_note: "Привіт"\n')
        before = path.read_bytes()
        self.assertEqual(self.configure().returncode, 0)
        self.assertEqual(path.read_bytes(), before)

    def test_config_rewrite_keeps_unicode_readable(self):
        (self.home / "config.yaml").write_text('operator_note: "Привіт"\n', encoding="utf-8")
        self.assertEqual(self.configure("memory,web").returncode, 0)
        text = (self.home / "config.yaml").read_text(encoding="utf-8")
        self.assertIn("Привіт", text)
        self.assertNotIn("\\u", text)
        self.assertEqual(yaml.safe_load(text)["operator_note"], "Привіт")

    def test_existing_plugin_and_mcp_selection_survives(self):
        config = {
            "platform_toolsets": {p: ["terminal", "operator_plugin", "no_mcp"] for p in ("telegram", "cron")},
            "known_plugin_toolsets": {p: ["operator_plugin", "disabled_plugin"] for p in ("telegram", "cron")},
        }
        (self.home / "config.yaml").write_text(yaml.safe_dump(config))
        self.assertEqual(self.configure().returncode, 0)
        for platform in ("telegram", "cron"):
            selected = self.config()["platform_toolsets"][platform]
            self.assertIn("operator_plugin", selected)
            self.assertIn("no_mcp", selected)
            self.assertNotIn("terminal", selected)
            with patch("hermes_cli.tools_config._get_plugin_toolset_keys",
                       return_value={"operator_plugin", "disabled_plugin"}):
                actual = _get_platform_tools(self.config(), platform)
            self.assertIn("operator_plugin", actual)
            self.assertNotIn("disabled_plugin", actual)

    def test_mcp_url_rejection_preserves_config(self):
        rng = random.Random(20260919)
        urls = ["file:///etc/passwd", "https://user:secret@localhost/mcp",
                "http://localhost:65536/mcp", "http://localhost:bad/mcp", "http://[bad"]
        urls += ["http://localhost/" + chr(rng.randrange(1, 33)) for _ in range(64)]
        for url in urls:
            (self.home / "config.yaml").write_text("model: unchanged\n")
            with self.subTest(url=repr(url)):
                self.assertNotEqual(self.configure(mcp=url).returncode, 0)
                self.assertEqual((self.home / "config.yaml").read_text(), "model: unchanged\n")

    def test_mcp_upstream_loader_receives_token(self):
        self.assertEqual(self.configure(mcp="http://127.0.0.1:8730/mcp").returncode, 0)
        command = "from tools.mcp_tool import _load_mcp_config; " + \
                  "c=_load_mcp_config(); assert c['openwrt']['headers']['Authorization']=='Bearer runtime-token'"
        result = subprocess.run(["python3", "-c", command], check=False, capture_output=True, text=True,
                                env=dict(self.env, OPENWRT_MCP_TOKEN="runtime-token"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("runtime-token", (self.home / "config.yaml").read_text())

    def test_wrapper_rotation_and_disabled_credentials(self):
        # Replace only the final CLI in this disposable container; execute the real wrapper.
        cli = Path("/usr/bin/hermes")
        original = cli.read_bytes()
        self.addCleanup(cli.write_bytes, original)
        cli.write_text("#!/bin/sh\nexec python3 -c 'import json,os; print(json.dumps(dict(os.environ)))'\n")
        files = {"provider": self.home / "provider", "telegram": self.home / "telegram", "mcp": self.home / "mcp"}
        self.assertEqual(self.configure(endpoint="http://127.0.0.1:9/v1").returncode, 0)
        env = dict(self.env, OPENAI_BASE_URL="http://127.0.0.1:9/v1", HERMES_MODEL="runtime-model",
                   HERMES_MEM_MAX_MB="0", HERMES_TELEGRAM_TOKEN_FILE=str(files["telegram"]),
                   HERMES_MCP_TOKEN_FILE=str(files["mcp"]), HERMES_OPENWRT_TOOLSETS="memory",
                   HERMES_OPENWRT_MCP_URL="http://127.0.0.1:8730/mcp")
        for rotation in range(2):
            values = {"provider": f"provider-{rotation}", "telegram": f"123456:{'A' * 30}{rotation}",
                      "mcp": f"mcp-{rotation}"}
            for name, path in files.items():
                path.write_text(values[name])
            result = subprocess.run(["sh", str(FILES / "hermes-gateway"), str(files["provider"])],
                                    env=env, check=False, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            child = json.loads(result.stdout)
            for name, key in (("provider", "OPENAI_API_KEY"), ("telegram", "TELEGRAM_BOT_TOKEN"),
                              ("mcp", "OPENWRT_MCP_TOKEN")):
                self.assertEqual(child[key], values[name])
        env.pop("HERMES_TELEGRAM_TOKEN_FILE")
        env.pop("HERMES_MCP_TOKEN_FILE")
        env.update(TELEGRAM_BOT_TOKEN="stale", OPENWRT_MCP_TOKEN="stale")
        result = subprocess.run(["sh", str(FILES / "hermes-gateway"), str(files["provider"])],
                                env=env, check=False, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        child = json.loads(result.stdout)
        self.assertNotIn("TELEGRAM_BOT_TOKEN", child)
        self.assertNotIn("OPENWRT_MCP_TOKEN", child)

    def test_wrapper_reapplies_uci_after_model_switch(self):
        # Upstream's own /model switch drops base_url/api_mode/api_key for a named
        # provider and persists only default/provider. UCI must win back at the very
        # next exec, not merely at the init's first start.
        endpoint = "http://127.0.0.1:9/v1"
        self.assertEqual(self.configure(endpoint=endpoint).returncode, 0)
        switched = {"model": {"default": "chat-choice", "provider": "openrouter"}}
        (self.home / "config.yaml").write_text(yaml.safe_dump(switched))
        cli = Path("/usr/bin/hermes")
        original = cli.read_bytes()
        self.addCleanup(cli.write_bytes, original)
        cli.write_text("#!/bin/sh\nexec python3 -c 'import json,os; print(json.dumps(dict(os.environ)))'\n")
        key = self.home / "key"
        key.write_text("provider-runtime-canary")
        env = dict(self.env, HERMES_OPENWRT_TOOLSETS="memory", HERMES_OPENWRT_MCP_URL="",
                   HERMES_MEM_MAX_MB="0", OPENAI_BASE_URL=endpoint, HERMES_MODEL="runtime-model")
        result = subprocess.run(["sh", str(FILES / "hermes-gateway"), str(key)],
                                env=env, check=False, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        model = self.config()["model"]
        self.assertEqual(model["default"], "runtime-model")
        self.assertEqual(model["provider"], "custom")
        self.assertEqual(model["base_url"], endpoint)

    def test_wrapper_drops_mcp_when_token_missing(self):
        cli = Path("/usr/bin/hermes")
        original = cli.read_bytes()
        self.addCleanup(cli.write_bytes, original)
        cli.write_text("#!/bin/sh\nexec python3 -c 'import json,os; print(json.dumps(dict(os.environ)))'\n")
        endpoint = "http://127.0.0.1:9/v1"
        self.assertEqual(self.configure(endpoint=endpoint).returncode, 0)
        key = self.home / "key"
        key.write_text("provider-runtime-canary")
        mcp_token_file = self.home / "mcp-missing"
        env = dict(self.env, HERMES_OPENWRT_TOOLSETS="memory",
                   HERMES_OPENWRT_MCP_URL="http://127.0.0.1:8730/mcp",
                   HERMES_MCP_TOKEN_FILE=str(mcp_token_file),
                   HERMES_MEM_MAX_MB="0", OPENAI_BASE_URL=endpoint, HERMES_MODEL="runtime-model")
        result = subprocess.run(["sh", str(FILES / "hermes-gateway"), str(key)],
                                env=env, check=False, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        child = json.loads(result.stdout)
        self.assertNotIn("OPENWRT_MCP_TOKEN", child)
        self.assertNotIn("openwrt", self.config().get("mcp_servers", {}))
        self.assertIn(str(mcp_token_file), result.stderr)

    def test_wrapper_names_the_missing_credential(self):
        endpoint = "http://127.0.0.1:9/v1"
        self.assertEqual(self.configure(endpoint=endpoint).returncode, 0)
        env = dict(self.env, HERMES_OPENWRT_TOOLSETS="memory", HERMES_OPENWRT_MCP_URL="",
                   HERMES_MEM_MAX_MB="0", OPENAI_BASE_URL=endpoint, HERMES_MODEL="runtime-model")
        missing_key = self.home / "missing-key"
        result = subprocess.run(["sh", str(FILES / "hermes-gateway"), str(missing_key)],
                                env=env, check=False, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("provider key", result.stderr)
        self.assertIn(str(missing_key), result.stderr)

        key = self.home / "key"
        key.write_text("provider-runtime-canary")
        missing_tg = self.home / "missing-telegram"
        env2 = dict(env, HERMES_TELEGRAM_TOKEN_FILE=str(missing_tg))
        result2 = subprocess.run(["sh", str(FILES / "hermes-gateway"), str(key)],
                                 env=env2, check=False, capture_output=True, text=True)
        self.assertNotEqual(result2.returncode, 0)
        self.assertIn("Telegram token", result2.stderr)

    def test_memory_validation_and_identity(self):
        spec = importlib.util.spec_from_file_location("memory_limit", FILES / "memory-limit.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        rng = random.Random(20260919)
        for value in [0, 1, 512, 1048576] + [rng.randrange(1048577) for _ in range(128)]:
            self.assertEqual(module.limit_bytes(str(value)), value * 1048576)
        for bad in ("", "-1", "+2", "1.5", "1e3", "1048577", "9" * 1000, " 1", "1\n"):
            with self.assertRaises(ValueError):
                module.limit_bytes(bad)
        module.apply("0")
        membership = self.home / "membership"
        module.MEMBERSHIP = membership
        module.CGROUP_ROOT = self.home / "cgroups"
        for identity in ("/", "/services/other/instance1", "/services/hermes-agent/instance2"):
            membership.write_text("0::" + identity)
            with self.assertRaises(RuntimeError):
                module.apply("64")
        membership.write_text("0::/services/hermes-agent/instance1")
        for parent in ("", "services", "services/hermes-agent"):
            path = module.CGROUP_ROOT / parent
            path.mkdir(parents=True, exist_ok=True)
            (path / "cgroup.controllers").write_text("memory")
            (path / "cgroup.subtree_control").write_text("memory")
        leaf = module.CGROUP_ROOT / module.INSTANCE.lstrip("/")
        leaf.mkdir()
        module.apply("64")
        self.assertEqual((leaf / "memory.max").read_text(), "67108864")
        self.assertEqual((leaf / "memory.swap.max").read_text(), "0")
        self.assertEqual((leaf / "memory.oom.group").read_text(), "1")
        (module.CGROUP_ROOT / "cgroup.controllers").write_text("cpu")
        with self.assertRaises(RuntimeError):
            module.apply("64")

    def test_memory_kernel_and_fail_closed(self):
        cli = Path("/usr/bin/hermes")
        original = cli.read_bytes()
        self.addCleanup(cli.write_bytes, original)
        cli.write_text("#!/bin/sh\nexec python3 -c 'x=bytearray(128*1024*1024); print(len(x))'\n")
        key = self.home / "key"
        key.write_text("synthetic")
        self.assertEqual(self.configure(endpoint="http://127.0.0.1:9/v1").returncode, 0)
        env = dict(self.env, HERMES_MEM_MAX_MB="64", OPENAI_BASE_URL="http://127.0.0.1:9/v1",
                   HERMES_MODEL="runtime-model", HERMES_OPENWRT_TOOLSETS="memory",
                   HERMES_OPENWRT_MCP_URL="")
        wrapper = ["sh", str(FILES / "hermes-gateway"), str(key)]
        wrong = subprocess.run(wrapper, env=env, check=False, capture_output=True, text=True)
        self.assertNotEqual(wrong.returncode, 0, "wrapper ran without its cgroup")
        self.assertIn("refusing unbounded start", wrong.stderr)
        group = Path("/sys/fs/cgroup/services/hermes-agent/instance1")
        group.mkdir(parents=True, exist_ok=True)
        # An earlier test, or an earlier run of this one in the same long-lived
        # container, can leave this real cgroup with its own ceiling already in place
        # and its own oom_kill count already above zero. Neither may be allowed to make
        # this run pass without this run itself proving anything: the ceiling is reset
        # before the wrapper is asked to apply its own, and only the DELTA in oom_kill
        # is asserted, never the absolute count.
        for name in ("memory.max", "memory.swap.max"):
            target = group / name
            if target.exists():
                target.write_text("max")
        events_path = group / "memory.events"
        if events_path.exists():
            before = dict(line.split() for line in events_path.read_text().splitlines())
            oom_before = int(before.get("oom_kill", 0))
        else:
            oom_before = 0
        command = 'echo $$ > ' + str(group / "cgroup.procs") + '; exec ' + shlex.join(wrapper)
        child = subprocess.run(["sh", "-c", command], env=env, check=False, capture_output=True, text=True, timeout=30)
        self.assertEqual(child.returncode, -9, child.stdout + child.stderr)
        self.assertEqual((group / "memory.max").read_text().strip(), "67108864")
        self.assertEqual((group / "memory.swap.max").read_text().strip(), "0")
        events = dict(line.split() for line in (group / "memory.events").read_text().splitlines())
        oom_after = int(events["oom_kill"])
        self.assertGreater(oom_after - oom_before, 0)
        print("kernel proof: memory.max=67108864, swap.max=0, child SIGKILL, oom_kill delta=" +
              str(oom_after - oom_before))

    def test_memory_zero_lifts_previous_ceiling(self):
        spec = importlib.util.spec_from_file_location("memory_limit_zero", FILES / "memory-limit.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        membership = self.home / "membership"
        module.MEMBERSHIP = membership
        module.CGROUP_ROOT = self.home / "cgroups"
        for parent in ("", "services", "services/hermes-agent"):
            path = module.CGROUP_ROOT / parent
            path.mkdir(parents=True, exist_ok=True)
            (path / "cgroup.controllers").write_text("memory")
            (path / "cgroup.subtree_control").write_text("memory")
        leaf = module.CGROUP_ROOT / module.INSTANCE.lstrip("/")
        leaf.mkdir()
        membership.write_text("0::" + module.INSTANCE)
        module.apply("64")
        self.assertEqual((leaf / "memory.max").read_text(), "67108864")
        module.apply("0")
        self.assertEqual((leaf / "memory.max").read_text(), "max")
        self.assertEqual((leaf / "memory.swap.max").read_text(), "max")
        self.assertEqual((leaf / "memory.oom.group").read_text(), "0")

        # Outside its own cgroup, zero must leave a limited group alone: a wrapper run
        # by hand with mem_max_mb=0 must not lift the ceiling of the service that is
        # running in that group.
        module.apply("64")
        membership.write_text("0::/services/other/instance1")
        module.apply("0")
        self.assertEqual((leaf / "memory.max").read_text(), "67108864")
        self.assertEqual((leaf / "memory.swap.max").read_text(), "0")
        self.assertEqual((leaf / "memory.oom.group").read_text(), "1")

    def test_memory_kernel_zero_lifts_ceiling(self):
        cli = Path("/usr/bin/hermes")
        original = cli.read_bytes()
        self.addCleanup(cli.write_bytes, original)
        cli.write_text("#!/bin/sh\necho started\n")
        key = self.home / "key"
        key.write_text("synthetic")
        self.assertEqual(self.configure(endpoint="http://127.0.0.1:9/v1").returncode, 0)
        group = Path("/sys/fs/cgroup/services/hermes-agent/instance1")
        group.mkdir(parents=True, exist_ok=True)
        wrapper = ["sh", str(FILES / "hermes-gateway"), str(key)]
        base_env = dict(self.env, OPENAI_BASE_URL="http://127.0.0.1:9/v1", HERMES_MODEL="runtime-model",
                        HERMES_OPENWRT_TOOLSETS="memory", HERMES_OPENWRT_MCP_URL="")

        def run_in_group(mem):
            env = dict(base_env, HERMES_MEM_MAX_MB=mem)
            command = 'echo $$ > ' + str(group / "cgroup.procs") + '; exec ' + shlex.join(wrapper)
            return subprocess.run(["sh", "-c", command], env=env, check=False,
                                  capture_output=True, text=True, timeout=30)

        # 256, not 64: this run must leave enough headroom for the wrapper's own Python
        # helpers (memory-limit.py, set-toolsets.py, runtime-check.py) to run to
        # completion; it is proving the LIFT, not another OOM kill.
        result = run_in_group("256")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((group / "memory.max").read_text().strip(), "268435456")

        result = run_in_group("0")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((group / "memory.max").read_text().strip(), "max")
        self.assertEqual((group / "memory.swap.max").read_text().strip(), "max")

    def test_runtime_override_conflicts_are_refused(self):
        endpoint = "http://127.0.0.1:9/v1"
        self.assertEqual(self.configure(endpoint=endpoint).returncode, 0)
        baseline = self.config()
        env = dict(self.env, OPENAI_BASE_URL=endpoint, HERMES_MODEL="runtime-model",
                   OPENAI_API_KEY="provider-runtime-canary", OPENROUTER_API_KEY="provider-runtime-canary")
        def preflight(extra=None):
            return subprocess.run(["python3", str(FILES / "runtime-check.py")],
                                  env=dict(env, **(extra or {})), check=False, capture_output=True, text=True)
        clean = preflight()
        self.assertEqual(clean.returncode, 0, clean.stderr)
        for name in ("OPENAI_API_KEY", "TELEGRAM_BOT_TOKEN", "OPENWRT_MCP_TOKEN", "HERMES_MODEL"):
            with self.subTest(env=name):
                dotenv = self.home / ".env"
                dotenv.write_text(name + "=conflict-canary\n")
                result = preflight()
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("conflict-canary", result.stdout + result.stderr)
                self.assertEqual(dotenv.read_text(), name + "=conflict-canary\n")
                dotenv.unlink()
        self.assertNotEqual(preflight({"CUSTOM_BASE_URL": "http://127.0.0.1:8/v1"}).returncode, 0)
        for kind in ("header", "provider", "provider_header"):
            config = json.loads(json.dumps(baseline))
            if kind == "header":
                config["model"]["default_headers"] = {"aUtHoRiZaTiOn": "Bearer conflict-canary"}
            elif kind == "provider":
                config["providers"] = {"custom": {"base_url": "http://127.0.0.1:8/v1",
                                                  "api_key": "conflict-canary"}}
            else:
                config["providers"] = {"side": {"base_url": endpoint,
                                                "extra_headers": {"Authorization": "Bearer conflict-canary"}}}
            (self.home / "config.yaml").write_text(yaml.safe_dump(config))
            result = preflight()
            self.assertNotEqual(result.returncode, 0, kind)
            self.assertNotIn("conflict-canary", result.stdout + result.stderr)
            self.assertEqual(self.config(), config)
        config = json.loads(json.dumps(baseline))
        config["model"]["default_headers"] = {"User-Agent": "operator-client"}
        config["model"]["api"] = "legacy-unused-key"
        (self.home / "config.yaml").write_text(yaml.safe_dump(config))
        self.assertEqual(preflight().returncode, 0)
        config["custom_providers"] = [{"name": "stored", "base_url": endpoint}]
        (self.home / "config.yaml").write_text(yaml.safe_dump(config))
        auth = {"credential_pool": {"custom:stored": [{"id": "test", "auth_type": "api_key",
                "source": "manual", "access_token": "conflict-canary", "base_url": endpoint}]}}
        (self.home / "auth.json").write_text(json.dumps(auth))
        result = preflight()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("conflict-canary", result.stdout + result.stderr)
        stored = json.loads((self.home / "auth.json").read_text())
        self.assertEqual(stored["credential_pool"]["custom:stored"][0]["access_token"], "conflict-canary")

    def test_credential_conflicts_preserve_bytes_and_secondary_keys(self):
        endpoint = "http://127.0.0.1:9/v1"
        self.assertEqual(self.configure(endpoint=endpoint).returncode, 0)
        env = dict(self.env, OPENAI_BASE_URL=endpoint, HERMES_MODEL="runtime-model",
                   OPENAI_API_KEY="provider-runtime-canary")
        command = ["python3", str(FILES / "runtime-check.py")]
        dotenv = self.home / ".env"
        for raw in ("OPENAI_API_KEY=conflict-canary\n".encode("utf-16"),
                    b"OPENAI_API_KEY=conflict-\x00canary\n"):
            dotenv.write_bytes(raw)
            result = subprocess.run(command, env=env, check=False, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(dotenv.read_bytes(), raw)
        dotenv.write_text("OPENROUTER_API_KEY=secondary-canary\n")
        result = subprocess.run(command, env=env, check=False, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(dotenv.read_text(), "OPENROUTER_API_KEY=secondary-canary\n")
        dotenv.unlink()
        config = self.config()
        config["custom_providers"] = [{"name": "stored", "base_url": endpoint}]
        (self.home / "config.yaml").write_text(yaml.safe_dump(config))
        auth = {"credential_pool": {"custom:stored": [
            {"id": "primary", "auth_type": "api_key", "source": "manual", "priority": 0,
             "access_token": "provider-runtime-canary", "base_url": endpoint},
            {"id": "spare", "auth_type": "api_key", "source": "manual", "priority": 1,
             "access_token": "conflict-canary", "base_url": endpoint}]}}
        path = self.home / "auth.json"
        path.write_text(json.dumps(auth))
        result = subprocess.run(command, env=env, check=False, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0, "matching first key masked a conflicting spare")
        self.assertEqual(json.loads(path.read_text())["credential_pool"], auth["credential_pool"])

    def test_operator_model_key_is_preserved(self):
        original = {"model": {"api_key": "operator-owned-key", "max_tokens": 1234}}
        (self.home / "config.yaml").write_text(yaml.safe_dump(original))
        self.assertNotEqual(self.configure(endpoint="http://127.0.0.1:9/v1").returncode, 0)
        self.assertEqual(self.config(), original)
        original["model"].pop("api_key")
        (self.home / "config.yaml").write_text(yaml.safe_dump(original))
        self.assertEqual(self.configure(endpoint="http://127.0.0.1:9/v1").returncode, 0)
        self.assertEqual(self.config()["model"]["max_tokens"], 1234)

    def test_model_endpoint_produces_agent_reply(self):
        received = []
        class Endpoint(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                if self.path != "/v1/chat/completions":
                    self.send_error(404)
                    return
                received.append((self.path, request.get("model"), self.headers.get("Authorization")))
                data = json.dumps({"id": "runtime-proof", "object": "chat.completion", "created": 1,
                                   "model": "runtime-model", "choices": [{"index": 0,
                                   "message": {"role": "assistant", "content": "HERMES_RUNTIME_OK"},
                                   "finish_reason": "stop"}],
                                   "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}).encode()
                self.send_response(200)
                content_type = "application/json"
                if request.get("stream"):
                    content_type = "text/event-stream"
                    chunks = [
                        {"id": "runtime-proof", "object": "chat.completion.chunk", "created": 1,
                         "model": "runtime-model", "choices": [{"index": 0, "delta": {
                         "role": "assistant", "content": "HERMES_RUNTIME_OK"}, "finish_reason": None}]},
                        {"id": "runtime-proof", "object": "chat.completion.chunk", "created": 1,
                         "model": "runtime-model", "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]},
                    ]
                    data = ("".join("data: " + json.dumps(chunk) + "\n\n" for chunk in chunks)
                            + "data: [DONE]\n\n").encode()
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
        server = HTTPServer(("127.0.0.1", 0), Endpoint)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        url = f"http://127.0.0.1:{server.server_port}/v1"
        (self.home / "config.yaml").write_text("model: old-model\n")
        configured = self.configure(endpoint=url)
        self.assertEqual(configured.returncode, 0, configured.stderr)
        self.assertEqual(self.config()["model"]["base_url"], url)
        self.assertEqual(self.config()["model"]["default"], "runtime-model")
        env = dict(self.env, OPENAI_API_KEY="provider-runtime-canary", OPENAI_BASE_URL=url,
                   HERMES_MODEL="runtime-model", NO_PROXY="127.0.0.1,localhost")
        result = subprocess.run(["hermes", "-z", "Reply briefly", "-t", "memory"], env=env,
                                check=False, capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("HERMES_RUNTIME_OK", result.stdout)
        self.assertEqual(received, [("/v1/chat/completions", "runtime-model", "Bearer provider-runtime-canary")])
        command = "from gateway.run import _resolve_gateway_model; assert _resolve_gateway_model()=='runtime-model'"
        gateway = subprocess.run(["python3", "-c", command], env=env, check=False, capture_output=True, text=True)
        self.assertEqual(gateway.returncode, 0, gateway.stderr)

    def _service_instance_json(self, provider=False):
        extra = ("printf '%s' 'claude-canary-runtime' > /etc/hermes-agent/claude.key; "
                 "uci set hermes.claude=provider; uci set hermes.claude.base_url=https://api.anthropic.com/v1; "
                 "uci set hermes.claude.model=claude-haiku-4-5") if provider else ""
        # Real OpenWrt config and procd serializers, only the ubus submission is replaced.
        # Shared by every test that needs to know exactly what procd would be handed,
        # rather than each building its own copy of the same script.
        script = f'''
mkdir -p /etc/hermes-agent /srv/hermes /var/lock /var/run /var/state
printf '%s' 'provider-canary-runtime' > /etc/hermes-agent/provider.key
printf '%s' '123456:telegramCanary012345678901234567890' > /etc/hermes-agent/telegram.token
printf '%s' 'mcp-canary-runtime' > /etc/hermes-agent/router-mcp.token
uci set hermes.main.enabled=1
uci set hermes.main.mem_max_mb=0
uci set hermes.main.data_dir={shlex.quote(str(self.home))}
uci set hermes.main.router_mcp_url=http://127.0.0.1:8730/mcp
uci set hermes.telegram.enabled=1
uci -q delete hermes.telegram.allow_user_id
uci add_list hermes.telegram.allow_user_id=123456789
{extra}
uci commit hermes
. /lib/functions.sh
. /lib/functions/procd.sh
initscript=/etc/init.d/hermes-agent
. {shlex.quote(str(FILES / "hermes-agent.init"))}
_procd_ubus_call() {{ json_dump; }}
procd_open_service hermes-agent /etc/init.d/hermes-agent
start_service || exit 1
procd_close_service
'''
        if provider:
            self.addCleanup(subprocess.run, ["sh", "-c", "uci -q delete hermes.claude; uci commit hermes"])
        result = subprocess.run(["sh", "-c", script], text=True, check=False, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout), result.stdout

    def test_all_secrets_absent_from_procd(self):
        _parsed, raw = self._service_instance_json()
        for secret in ("provider-canary-runtime", "telegramCanary", "mcp-canary-runtime"):
            self.assertNotIn(secret, raw)

    def test_procd_respawn_is_bounded(self):
        parsed, _raw = self._service_instance_json()
        instance = parsed["instances"]["instance1"]
        self.assertEqual(instance["respawn"], ["3600", "5", "5"])
        self.assertIn("HERMES_OPENWRT_TOOLSETS", instance["env"])
        self.assertIn("HERMES_OPENWRT_MCP_URL", instance["env"])

    def test_gateway_runs_below_the_routers_own_work(self):
        # 2026-09-24, a Brume 2 carrying a WireGuard tunnel at 580 Mbit/s: while a
        # conversation ran at the default priority the tunnel lost a third of its
        # throughput, at nice 10 a quarter. procd applies it to the wrapper; the
        # gateway it execs and every tool process the gateway starts inherit it.
        parsed, _raw = self._service_instance_json()
        self.assertEqual(parsed["instances"]["instance1"].get("nice"), 10)

    # ---- Profiles: assistant governs terminal, code execution and file; admin does not ----

    def test_assistant_profile_removes_command_and_file_tools(self):
        # The default UCI toolset list (hermes-agent.config's own `list toolsets`
        # block) includes file and terminal; the assistant profile must remove
        # them from what upstream actually hands out regardless.
        default_toolsets = "file,terminal,web,memory,skills,cronjob,clarify"
        configured = self.configure(tools=default_toolsets, endpoint="http://127.0.0.1:9/v1", profile="assistant")
        self.assertEqual(configured.returncode, 0, configured.stderr)
        config = self.config()
        self.assertEqual(config["agent"]["disabled_toolsets"], ["code_execution", "file", "terminal"])
        # profile is argv[6], appended after mcp-url/base-url/model: guard against
        # the two blocks' argv-length checks drifting apart again (they did during
        # development -- appending profile silently made len(sys.argv) skip the
        # model block's `== 6` check, so a profile-bearing call wrote no model at
        # all until the check became `in (6, 7)`).
        self.assertEqual(config["model"]["default"], "runtime-model")
        self.assertEqual(config["model"]["base_url"], "http://127.0.0.1:9/v1")
        # Heavier upstream modules (registry discovery, cron) run in a subprocess,
        # matching test_mcp_upstream_loader_receives_token and
        # test_model_endpoint_produces_agent_reply rather than importing them
        # into this process directly.
        command = (
            "import yaml; from hermes_cli.config import get_config_path; "
            "from hermes_cli.tools_config import _get_platform_tools; "
            "import model_tools; from cron.scheduler import _resolve_cron_disabled_toolsets; "
            "config = yaml.safe_load(get_config_path().read_text()); "
            "enabled = sorted(_get_platform_tools(config, 'telegram')); "
            "disabled = config['agent']['disabled_toolsets']; "
            "defs = model_tools.get_tool_definitions(enabled_toolsets=enabled, "
            "disabled_toolsets=disabled, quiet_mode=True); "
            "names = {d['function']['name'] for d in defs}; "
            "governed_tools = {'terminal', 'process', 'execute_code', 'read_file', "
            "'write_file', 'patch', 'search_files'}; "
            "assert not (names & governed_tools), names & governed_tools; "
            "cron_disabled = set(_resolve_cron_disabled_toolsets(config)); "
            "assert {'code_execution', 'file', 'terminal'} <= cron_disabled, cron_disabled"
        )
        check = subprocess.run(["python3", "-c", command], env=self.env, check=False,
                               capture_output=True, text=True)
        self.assertEqual(check.returncode, 0, check.stdout + check.stderr)

    def test_admin_profile_restores_them_and_keeps_operator_entries(self):
        (self.home / "config.yaml").write_text(yaml.safe_dump(
            {"agent": {"disabled_toolsets": ["browser", "file", "terminal", "code_execution"]}}))
        configured = self.configure(tools="file,terminal,web,memory", endpoint="http://127.0.0.1:9/v1",
                                    profile="admin")
        self.assertEqual(configured.returncode, 0, configured.stderr)
        config = self.config()
        self.assertEqual(config["agent"]["disabled_toolsets"], ["browser"])
        command = (
            "import yaml; from hermes_cli.config import get_config_path; "
            "from hermes_cli.tools_config import _get_platform_tools; "
            "import model_tools; "
            "config = yaml.safe_load(get_config_path().read_text()); "
            "enabled = sorted(_get_platform_tools(config, 'telegram')); "
            "disabled = config['agent']['disabled_toolsets']; "
            "defs = model_tools.get_tool_definitions(enabled_toolsets=enabled, "
            "disabled_toolsets=disabled, quiet_mode=True); "
            "names = {d['function']['name'] for d in defs}; "
            "assert 'terminal' in names, names; "
            "assert 'read_file' in names, names"
        )
        check = subprocess.run(["python3", "-c", command], env=self.env, check=False,
                               capture_output=True, text=True)
        self.assertEqual(check.returncode, 0, check.stdout + check.stderr)

    def test_assistant_profile_reads_an_empty_restriction_as_empty(self):
        # YAML leaves `agent:` or `disabled_toolsets:` with no value as null, and
        # upstream reads both as empty (`... or []`, `... or {}`). The bridge must
        # agree rather than refuse a start over a configuration upstream accepts.
        for content in ("agent:\n  disabled_toolsets:\n  max_turns: 5\n", "agent:\n"):
            with self.subTest(content=content):
                (self.home / "config.yaml").write_text(content)
                configured = self.configure(profile="assistant")
                self.assertEqual(configured.returncode, 0, configured.stderr)
                self.assertEqual(self.config()["agent"]["disabled_toolsets"],
                                 ["code_execution", "file", "terminal"])

    def test_admin_profile_removes_empty_disabled_toolsets_key(self):
        # admin's choice, stated in the bridge's own comment: when removing the
        # governed names empties the list, drop the key rather than leave `[]`
        # behind. Proven here rather than merely asserted, since the bridge could
        # just as consistently have kept an empty list.
        (self.home / "config.yaml").write_text(yaml.safe_dump(
            {"agent": {"disabled_toolsets": ["file", "terminal", "code_execution"], "max_turns": 5}}))
        configured = self.configure(profile="admin")
        self.assertEqual(configured.returncode, 0, configured.stderr)
        config = self.config()
        self.assertNotIn("disabled_toolsets", config["agent"])
        self.assertEqual(config["agent"]["max_turns"], 5)

    def test_profile_refuses_non_list_disabled_toolsets(self):
        cases = (
            (yaml.safe_dump({"agent": {"disabled_toolsets": "not-a-list"}}), "assistant"),
            (yaml.safe_dump({"agent": "not-a-mapping"}), "admin"),
            (yaml.safe_dump({"agent": {"disabled_toolsets": ["file", 7, "terminal"]}}), "assistant"),
        )
        for content, profile in cases:
            with self.subTest(profile=profile):
                (self.home / "config.yaml").write_text(content)
                result = self.configure(profile=profile)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("agent", result.stderr)
                self.assertEqual((self.home / "config.yaml").read_text(), content)

    def test_profile_defaults_to_admin_and_refuses_unknown(self):
        # It sets profile=root below; leave UCI as the next test expects it.
        self.addCleanup(subprocess.run, ["sh", "-c", "uci -q delete hermes.main.profile; uci commit hermes"])
        # No `profile` option at all (e.g. a router upgraded from before this
        # feature existed) must default to admin, the same as the shipped config's
        # own default value, independent of it. The default was assistant for a few
        # hours on 2026-09-24; a live bot showed that without openwrt-mcp it cannot
        # reach the router at all, so admin became the default and assistant opt-in.
        script = f'''
mkdir -p /etc/hermes-agent /srv/hermes /var/lock /var/run /var/state
printf '%s' 'provider-canary-runtime' > /etc/hermes-agent/provider.key
uci set hermes.main.enabled=1
uci set hermes.main.mem_max_mb=0
uci set hermes.main.data_dir={shlex.quote(str(self.home))}
uci -q delete hermes.main.profile
uci commit hermes
. /lib/functions.sh
. /lib/functions/procd.sh
initscript=/etc/init.d/hermes-agent
. {shlex.quote(str(FILES / "hermes-agent.init"))}
_procd_ubus_call() {{ json_dump; }}
procd_open_service hermes-agent /etc/init.d/hermes-agent
start_service || exit 1
procd_close_service
'''
        result = subprocess.run(["sh", "-c", script], text=True, check=False, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        parsed = json.loads(result.stdout)
        self.assertEqual(parsed["instances"]["instance1"]["env"]["HERMES_OPENWRT_PROFILE"], "admin")

        refuse_script = f'''
mkdir -p /etc/hermes-agent /srv/hermes /var/lock /var/run /var/state
printf '%s' 'provider-canary-runtime' > /etc/hermes-agent/provider.key
uci set hermes.main.enabled=1
uci set hermes.main.mem_max_mb=0
uci set hermes.main.data_dir={shlex.quote(str(self.home))}
uci set hermes.main.profile=root
uci commit hermes
. /lib/functions.sh
. /lib/functions/procd.sh
initscript=/etc/init.d/hermes-agent
. {shlex.quote(str(FILES / "hermes-agent.init"))}
_procd_ubus_call() {{ json_dump; }}
procd_open_service hermes-agent /etc/init.d/hermes-agent
start_service
exit $?
'''
        refused = subprocess.run(["sh", "-c", refuse_script], text=True, check=False, capture_output=True)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("hermes.main.profile", refused.stderr)
        self.assertIn("assistant", refused.stderr)
        self.assertIn("admin", refused.stderr)
        self.assertIn("root", refused.stderr)

        # The bridge itself refuses the same value directly, config untouched.
        (self.home / "config.yaml").write_text("model: unchanged\n")
        bridge_result = self.configure(profile="root")
        self.assertNotEqual(bridge_result.returncode, 0)
        self.assertEqual((self.home / "config.yaml").read_text(), "model: unchanged\n")

    def test_wrapper_reapplies_profile_at_exec(self):
        # Mirrors test_wrapper_reapplies_uci_after_model_switch: a chat command or
        # a file edit can drop a governed name from agent.disabled_toolsets, and
        # the wrapper must put it back at the very next exec, not only at the
        # init's own first start.
        endpoint = "http://127.0.0.1:9/v1"
        self.assertEqual(self.configure(endpoint=endpoint, profile="assistant").returncode, 0)
        tampered = self.config()
        tampered["agent"]["disabled_toolsets"] = ["code_execution", "file"]  # terminal dropped
        (self.home / "config.yaml").write_text(yaml.safe_dump(tampered))
        cli = Path("/usr/bin/hermes")
        original = cli.read_bytes()
        self.addCleanup(cli.write_bytes, original)
        cli.write_text("#!/bin/sh\nexec python3 -c 'import json,os; print(json.dumps(dict(os.environ)))'\n")
        key = self.home / "key"
        key.write_text("provider-runtime-canary")
        env = dict(self.env, HERMES_OPENWRT_TOOLSETS="memory", HERMES_OPENWRT_MCP_URL="",
                   HERMES_MEM_MAX_MB="0", OPENAI_BASE_URL=endpoint, HERMES_MODEL="runtime-model",
                   HERMES_OPENWRT_PROFILE="assistant")
        result = subprocess.run(["sh", str(FILES / "hermes-gateway"), str(key)],
                                env=env, check=False, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.config()["agent"]["disabled_toolsets"], ["code_execution", "file", "terminal"])

        # Unset entirely -- an older procd env, or a service-list edge case --
        # must default to admin here too, the same as the init's own config_get
        # default: the governed names come out, the operator's entry stays.
        tampered2 = self.config()
        tampered2["agent"]["disabled_toolsets"] = ["code_execution", "browser"]
        (self.home / "config.yaml").write_text(yaml.safe_dump(tampered2))
        env.pop("HERMES_OPENWRT_PROFILE")
        result2 = subprocess.run(["sh", str(FILES / "hermes-gateway"), str(key)],
                                 env=env, check=False, capture_output=True, text=True)
        self.assertEqual(result2.returncode, 0, result2.stderr)
        self.assertEqual(self.config()["agent"]["disabled_toolsets"], ["browser"])

    def test_assistant_profile_tells_the_agent_what_it_cannot_do(self):
        # 2026-09-24, a Telegram bot on a test router in the assistant profile: asked
        # for the router's uptime, gpt-4o-mini looped on the memory tool for 90
        # model calls before it gave up, because nothing told it it had no shell.
        # The bridge now says so in agent.system_prompt, which the gateway loads as
        # its ephemeral system prompt, and keeps the operator's own text around it.
        (self.home / "config.yaml").write_text(yaml.safe_dump({"agent": {"system_prompt": "Be brief."}}))
        self.assertEqual(self.configure(profile="assistant").returncode, 0)
        prompt = self.config()["agent"]["system_prompt"]
        self.assertTrue(prompt.startswith("Be brief.\n\n"), prompt)
        self.assertIn("no terminal", prompt)
        env = {k: v for k, v in self.env.items() if k != "HERMES_EPHEMERAL_SYSTEM_PROMPT"}
        loaded = subprocess.run(["python3", "-c", "from gateway.run import GatewayRunner; "
                                 "print(GatewayRunner._load_ephemeral_system_prompt())"],
                                env=env, check=False, capture_output=True, text=True)
        self.assertEqual(loaded.returncode, 0, loaded.stderr)
        self.assertIn("Be brief.", loaded.stdout)
        self.assertIn("no terminal", loaded.stdout)
        before = (self.home / "config.yaml").read_bytes()
        self.assertEqual(self.configure(profile="assistant").returncode, 0)
        self.assertEqual((self.home / "config.yaml").read_bytes(), before)
        self.assertEqual(self.configure(profile="admin").returncode, 0)
        self.assertEqual(self.config()["agent"]["system_prompt"], "Be brief.")
        # Exactly the operator's text, whitespace around it included: a YAML block
        # scalar ends in a newline. A second start in assistant leaves the file alone.
        (self.home / "config.yaml").write_text(yaml.safe_dump({"agent": {"system_prompt": "  Be brief.\n"}}))
        self.assertEqual(self.configure(profile="assistant").returncode, 0)
        before = (self.home / "config.yaml").read_bytes()
        self.assertEqual(self.configure(profile="assistant").returncode, 0)
        self.assertEqual((self.home / "config.yaml").read_bytes(), before)
        self.assertEqual(self.configure(profile="admin").returncode, 0)
        self.assertEqual(self.config()["agent"]["system_prompt"], "  Be brief.\n")
        (self.home / "config.yaml").write_text("{}\n")
        self.assertEqual(self.configure(profile="assistant").returncode, 0)
        self.assertIn("no terminal", self.config()["agent"]["system_prompt"])
        self.assertEqual(self.configure(profile="admin").returncode, 0)
        self.assertNotIn("system_prompt", self.config().get("agent") or {})
        content = yaml.safe_dump({"agent": {"system_prompt": ["not", "text"]}})
        (self.home / "config.yaml").write_text(content)
        self.assertNotEqual(self.configure(profile="assistant").returncode, 0)
        self.assertEqual((self.home / "config.yaml").read_text(), content)

    def test_max_turns_comes_from_uci(self):
        # The same run hit upstream's own budget of 90 model calls per turn. UCI now
        # sets it, 20 unless changed; the gateway reads agent.max_turns into the
        # budget it enforces; a value that is not a whole number from 1 to 500
        # refuses the start and leaves the file alone.
        def bridge(value, profile="admin"):
            env = dict(self.env)
            if value is not None:
                env["HERMES_OPENWRT_MAX_TURNS"] = value
            args = ["python3", str(FILES / "set-toolsets.py"), str(self.home), "memory", "",
                    "http://127.0.0.1:9/v1", "runtime-model", profile]
            return subprocess.run(args, env=env, check=False, capture_output=True, text=True)
        self.assertEqual(bridge("20").returncode, 0)
        self.assertEqual(self.config()["agent"]["max_turns"], 20)
        budget = subprocess.run(["python3", "-c", "import gateway.run as g; print(g._current_max_iterations())"],
                                env=self.env, check=False, capture_output=True, text=True)
        self.assertEqual(budget.returncode, 0, budget.stderr)
        self.assertEqual(budget.stdout.strip().splitlines()[-1], "20")
        for bad in ("0", "501", "twenty", "-3"):
            with self.subTest(bad=bad):
                before = (self.home / "config.yaml").read_text()
                refused = bridge(bad)
                self.assertNotEqual(refused.returncode, 0)
                self.assertIn("max_turns", refused.stderr)
                self.assertEqual((self.home / "config.yaml").read_text(), before)
        parsed, _raw = self._service_instance_json()
        self.assertEqual(parsed["instances"]["instance1"]["env"]["HERMES_OPENWRT_MAX_TURNS"], "20")


    # ---- Further providers: UCI sections, offered by /model per chat ----

    PROVIDERS = ("claude|Anthropic|https://api.anthropic.com/v1|/etc/hermes-agent/claude.key|claude-haiku-4-5;"
                 "local|Local model|http://127.0.0.1:8/v1|/etc/hermes-agent/local.key|local-model")

    def configure_providers(self, raw, endpoint="http://127.0.0.1:9/v1"):
        env = dict(self.env, HERMES_OPENWRT_PROVIDERS=raw)
        args = ["python3", str(FILES / "set-toolsets.py"), str(self.home), "memory", "", endpoint, "runtime-model"]
        return subprocess.run(args, env=env, text=True, check=False, capture_output=True)

    def upstream(self, code, **extra):
        # Upstream's own resolvers, run the way the gateway runs them, in a subprocess
        # with the keys the wrapper would have exported.
        env = dict(self.env, OPENAI_API_KEY="main-key-canary", **extra)
        return subprocess.run(["python3", "-c", code], env=env, check=False, capture_output=True, text=True)

    def test_extra_providers_reach_upstream(self):
        # 2026-09-25: three agents at once on three providers, asked for on the router.
        # Each UCI provider has to be one upstream resolves, lists in /model and
        # switches a chat to, with the key the wrapper read from its file.
        result = self.configure_providers(self.PROVIDERS)
        self.assertEqual(result.returncode, 0, result.stderr)
        providers = self.config()["providers"]
        self.assertEqual(providers["claude"]["key_env"], "HERMES_PROVIDER_CLAUDE_KEY")
        self.assertEqual(providers["local"]["api"], "http://127.0.0.1:8/v1")
        self.assertNotIn("sk-", yaml.safe_dump(self.config()))
        code = (
            "from hermes_cli.config import load_config, get_compatible_custom_providers\n"
            "from hermes_cli.runtime_provider import resolve_runtime_provider\n"
            "from hermes_cli.model_switch import list_picker_providers, switch_model\n"
            "cfg = load_config()\n"
            "r = resolve_runtime_provider(requested='claude')\n"
            "assert r['base_url'] == 'https://api.anthropic.com/v1', r\n"
            "assert r['api_key'] == 'claude-key-canary'\n"
            "slugs = [p.get('slug') for p in list_picker_providers(current_provider='custom', "
            "current_base_url='http://127.0.0.1:9/v1', current_model='runtime-model', "
            "user_providers=cfg.get('providers'), custom_providers=get_compatible_custom_providers(cfg), max_models=5)]\n"
            "assert 'claude' in slugs and 'local' in slugs, slugs\n"
            "s = switch_model(raw_input='local-model', explicit_provider='local', current_provider='custom', "
            "current_model='runtime-model', current_base_url='http://127.0.0.1:9/v1', current_api_key='main-key-canary', "
            "user_providers=cfg.get('providers'), custom_providers=get_compatible_custom_providers(cfg))\n"
            "assert s.success and s.base_url == 'http://127.0.0.1:8/v1' and s.api_key == 'local-key-canary', s\n"
        )
        check = self.upstream(code, HERMES_PROVIDER_CLAUDE_KEY="claude-key-canary",
                              HERMES_PROVIDER_LOCAL_KEY="local-key-canary")
        self.assertEqual(check.returncode, 0, check.stdout + check.stderr)
        # And the main provider still passes the preflight beside them.
        env = dict(self.env, OPENAI_BASE_URL="http://127.0.0.1:9/v1", HERMES_MODEL="runtime-model",
                   OPENAI_API_KEY="main-key-canary", HERMES_PROVIDER_CLAUDE_KEY="claude-key-canary")
        pre = subprocess.run(["python3", str(FILES / "runtime-check.py")], env=env, check=False,
                             capture_output=True, text=True)
        self.assertEqual(pre.returncode, 0, pre.stderr)

    def test_provider_names_upstream_owns_are_refused(self):
        # Upstream resolves its built-in providers before `providers`, so a section
        # called anthropic would send the chat to the native provider, not this one.
        for raw in ("anthropic|A|https://api.anthropic.com/v1|/k|m",
                    "openrouter|O|https://openrouter.ai/api/v1|/k|m",
                    "custom|C|http://127.0.0.1:9/v1|/k|m",
                    "Bad Name|B|http://127.0.0.1:9/v1|/k|m",
                    "ftp|F|ftp://127.0.0.1/v1|/k|m",
                    "nomodel|N|http://127.0.0.1:9/v1|/k|",
                    "twice|T|http://127.0.0.1:9/v1|/k|m;twice|T|http://127.0.0.1:9/v1|/k|m",
                    "short|S|http://127.0.0.1:9/v1"):
            with self.subTest(raw=raw):
                content = "model_catalog: {}\n"
                (self.home / "config.yaml").write_text(content)
                result = self.configure_providers(raw)
                self.assertNotEqual(result.returncode, 0, raw)
                self.assertEqual((self.home / "config.yaml").read_text(), content)

    def test_operator_provider_entries_survive(self):
        mine = {"api": "http://127.0.0.1:7/v1", "api_key": "operator-owned"}
        (self.home / "config.yaml").write_text(yaml.safe_dump({"providers": {"mine": mine}}))
        self.assertEqual(self.configure_providers(self.PROVIDERS).returncode, 0)
        self.assertEqual(self.config()["providers"]["mine"], mine)
        # A UCI provider dropped from UCI leaves; the operator's stays.
        self.assertEqual(self.configure_providers(self.PROVIDERS.split(";")[0]).returncode, 0)
        self.assertEqual(sorted(self.config()["providers"]), ["claude", "mine"])
        self.assertEqual(self.configure_providers("").returncode, 0)
        self.assertEqual(self.config()["providers"], {"mine": mine})
        # An operator entry with a UCI provider's name is refused, not overwritten.
        before = (self.home / "config.yaml").read_text()
        result = self.configure_providers("mine|Mine|http://127.0.0.1:9/v1|/k|m")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.home / "config.yaml").read_text(), before)
        # Unset means untouched: callers that predate providers change nothing here.
        self.assertEqual(self.configure(endpoint="http://127.0.0.1:9/v1").returncode, 0)
        self.assertEqual(self.config()["providers"], {"mine": mine})

    def test_wrapper_exports_provider_keys_and_drops_missing_ones(self):
        cli = Path("/usr/bin/hermes")
        original = cli.read_bytes()
        self.addCleanup(cli.write_bytes, original)
        cli.write_text("#!/bin/sh\nexec python3 -c 'import json,os; print(json.dumps(dict(os.environ)))'\n")
        endpoint = "http://127.0.0.1:9/v1"
        key = self.home / "key"
        key.write_text("main-key-canary")
        claude_key = self.home / "claude.key"
        claude_key.write_text("  claude-key-canary\n")
        missing = self.home / "local.key"
        raw = (f"claude|Anthropic|https://api.anthropic.com/v1|{claude_key}|claude-haiku-4-5;"
               f"local|Local|http://127.0.0.1:9/v1|{missing}|local-model")
        env = dict(self.env, HERMES_OPENWRT_TOOLSETS="memory", HERMES_OPENWRT_MCP_URL="",
                   HERMES_MEM_MAX_MB="0", OPENAI_BASE_URL=endpoint, HERMES_MODEL="runtime-model",
                   HERMES_OPENWRT_PROVIDERS=raw, HERMES_PROVIDER_STALE_KEY="stale-canary")
        result = subprocess.run(["sh", str(FILES / "hermes-gateway"), str(key)],
                                env=env, check=False, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        child = json.loads(result.stdout)
        self.assertEqual(child["HERMES_PROVIDER_CLAUDE_KEY"], "claude-key-canary")
        self.assertNotIn("HERMES_PROVIDER_LOCAL_KEY", child)
        self.assertNotIn("HERMES_PROVIDER_STALE_KEY", child)
        self.assertNotIn("HERMES_OPENWRT_PROVIDERS", child)
        self.assertEqual(sorted(self.config()["providers"]), ["claude"])
        self.assertIn(str(missing), result.stderr)

    def test_provider_keys_absent_from_procd(self):
        _parsed, raw = self._service_instance_json(provider=True)
        self.assertNotIn("claude-canary-runtime", raw)
        parsed = json.loads(raw)
        self.assertIn("/etc/hermes-agent/claude.key", parsed["instances"]["instance1"]["env"]["HERMES_OPENWRT_PROVIDERS"])

    def test_bad_provider_section_refuses_the_start(self):
        # A bad section anywhere, not only the last one: OpenWrt's config_foreach
        # carries on past a failing callback and reports only the last status.
        script = f'''
mkdir -p /etc/hermes-agent /var/lock /var/run /var/state
printf '%s' 'provider-canary-runtime' > /etc/hermes-agent/provider.key
uci set hermes.main.enabled=1
uci set hermes.main.mem_max_mb=0
uci set hermes.main.data_dir={shlex.quote(str(self.home))}
uci set hermes.telegram.enabled=0
uci set hermes.broken=provider
uci set hermes.broken.base_url=http://127.0.0.1:9/v1
uci set hermes.fine=provider
uci set hermes.fine.base_url=http://127.0.0.1:9/v1
uci set hermes.fine.model=m
uci commit hermes
. /lib/functions.sh
. /lib/functions/procd.sh
initscript=/etc/init.d/hermes-agent
. {shlex.quote(str(FILES / "hermes-agent.init"))}
_procd_ubus_call() {{ json_dump; }}
procd_open_service hermes-agent /etc/init.d/hermes-agent
start_service; echo "start=$?"
'''
        self.addCleanup(subprocess.run, ["sh", "-c", "uci -q delete hermes.broken; uci -q delete hermes.fine; uci commit hermes"])
        result = subprocess.run(["sh", "-c", script], text=True, check=False, capture_output=True)
        self.assertIn("start=1", result.stdout, result.stdout + result.stderr)
        self.assertIn("provider 'broken' needs base_url and model", result.stderr)

    def test_preflight_protects_provider_keys(self):
        self.assertEqual(self.configure_providers(self.PROVIDERS.split(";")[0]).returncode, 0)
        env = dict(self.env, OPENAI_BASE_URL="http://127.0.0.1:9/v1", HERMES_MODEL="runtime-model",
                   OPENAI_API_KEY="main-key-canary", HERMES_PROVIDER_CLAUDE_KEY="claude-key-canary")
        (self.home / ".env").write_text("HERMES_PROVIDER_CLAUDE_KEY=conflict-canary\n")
        result = subprocess.run(["python3", str(FILES / "runtime-check.py")], env=env, check=False,
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("conflict-canary", result.stdout + result.stderr)
        self.assertIn("HERMES_PROVIDER_CLAUDE_KEY", result.stderr)

    def test_openai_api_is_hidden_from_the_picker(self):
        # OPENAI_API_KEY carries the main key for whatever endpoint UCI names; upstream
        # read it as a signed-in OpenAI API and offered "openai-api" in /model, which
        # would send that key to api.openai.com.
        (self.home / "config.yaml").write_text(yaml.safe_dump({"model_catalog": {"excluded_providers": ["nous"]}}))
        self.assertEqual(self.configure(endpoint="http://127.0.0.1:9/v1").returncode, 0)
        excluded = self.config()["model_catalog"]["excluded_providers"]
        self.assertEqual(excluded, ["nous", "openai-api"])
        code = (
            "from hermes_cli.config import load_config, get_compatible_custom_providers\n"
            "from hermes_cli.model_switch import list_picker_providers\n"
            "cfg = load_config()\n"
            "slugs = [p.get('slug') for p in list_picker_providers(current_provider='custom', "
            "current_base_url='http://127.0.0.1:9/v1', current_model='runtime-model', "
            "user_providers=cfg.get('providers'), custom_providers=get_compatible_custom_providers(cfg), "
            "max_models=5, excluded_providers=cfg['model_catalog']['excluded_providers'])]\n"
            "assert 'openai-api' not in slugs, slugs\n"
        )
        check = self.upstream(code)
        self.assertEqual(check.returncode, 0, check.stdout + check.stderr)

    def test_native_anthropic_provider_is_installed(self):
        # /model picks upstream's native Anthropic transport for api.anthropic.com
        # whatever a provider entry says, and that transport needs the SDK.
        check = self.upstream("import anthropic; from agent.anthropic_adapter import build_anthropic_client; "
                              "print(anthropic.__version__)")
        self.assertEqual(check.returncode, 0, check.stderr)

    def test_login_helper_uses_the_service_home(self):
        helper = FILES / "hermes-login"
        self.assertTrue(helper.exists(), "hermes-login is not installed")
        self.addCleanup(subprocess.run, ["sh", "-c", "uci set hermes.main.data_dir=/srv/hermes; uci commit hermes"])
        subprocess.run(["sh", "-c", f"uci set hermes.main.data_dir={shlex.quote(str(self.home))}; uci commit hermes"], check=True)
        shown = subprocess.run(["sh", str(helper), "chatgpt", "--print-home"], check=False, capture_output=True, text=True)
        self.assertEqual(shown.returncode, 0, shown.stderr)
        self.assertEqual(shown.stdout.strip(), str(self.home))
        bad = subprocess.run(["sh", str(helper), "other"], check=False, capture_output=True, text=True)
        self.assertEqual(bad.returncode, 2)

    def test_login_helper_signs_out(self):
        # The Providers page signs out with hermes-login chatgpt --logout; upstream's own
        # logout has to clear the tokens it filed under openai-codex, in the service's
        # data directory.
        helper = FILES / "hermes-login"
        self.assertTrue(helper.exists(), "hermes-login is not installed")
        self.addCleanup(subprocess.run, ["sh", "-c", "uci set hermes.main.data_dir=/srv/hermes; uci commit hermes"])
        subprocess.run(["sh", "-c", f"uci set hermes.main.data_dir={shlex.quote(str(self.home))}; uci commit hermes"], check=True)
        saved = self.upstream("from hermes_cli.auth import _save_codex_tokens\n"
                              "_save_codex_tokens({'access_token': 'codex-access-canary', 'refresh_token': 'codex-refresh-canary'}, None)\n")
        self.assertEqual(saved.returncode, 0, saved.stderr)
        self.assertIn("codex-access-canary", (self.home / "auth.json").read_text())
        out = subprocess.run(["sh", str(helper), "chatgpt", "--logout"], check=False, capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertNotIn("codex-access-canary", (self.home / "auth.json").read_text())
        self.assertNotIn("codex-access-canary", out.stdout + out.stderr)

    def test_chatgpt_login_does_not_trip_the_preflight(self):
        # hermes-login stores the subscription's tokens with upstream's own saver and
        # points model.provider at it; the next start puts UCI's model back and the
        # preflight, which guards the main key only, still passes.
        self.assertEqual(self.configure(endpoint="http://127.0.0.1:9/v1").returncode, 0)
        code = ("from hermes_cli.auth import _save_codex_tokens, _update_config_for_provider\n"
                "_save_codex_tokens({'access_token': 'codex-access-canary', 'refresh_token': 'codex-refresh-canary'}, None)\n"
                "_update_config_for_provider('openai-codex', 'https://chatgpt.com/backend-api/codex')\n")
        saved = self.upstream(code)
        self.assertEqual(saved.returncode, 0, saved.stderr)
        self.assertEqual(self.configure(endpoint="http://127.0.0.1:9/v1").returncode, 0)
        self.assertEqual(self.config()["model"]["provider"], "custom")
        env = dict(self.env, OPENAI_BASE_URL="http://127.0.0.1:9/v1", HERMES_MODEL="runtime-model",
                   OPENAI_API_KEY="main-key-canary")
        pre = subprocess.run(["python3", str(FILES / "runtime-check.py")], env=env, check=False,
                             capture_output=True, text=True)
        self.assertEqual(pre.returncode, 0, pre.stderr)


if __name__ == "__main__":
    if "--selftest" in os.sys.argv:
        for name in unittest.defaultTestLoader.getTestCaseNames(RuntimeTests):
            print("check_" + name.removeprefix("test_"))
    else:
        unittest.main(verbosity=2)
