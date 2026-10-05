#!/usr/bin/env python3
"""Runtime regressions against the Python payload actually shipped on OpenWrt.

@codex 2026-09-19: runs in the package test container, with no model/API calls.
"""
import importlib.util
import json
import os
import pwd
import random
import shlex
import shutil
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


DROP = ["python3", "-I", "-B", "/usr/libexec/hermes-drop"]


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        # The data directory belongs to the user the agent runs as (owner is the default
        # profile), as the init leaves it: the wrapper runs its helpers and the gateway
        # as that user, so a directory root made would be one it cannot write in.
        shutil.chown(self.home, "hermes", "hermes")
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
        # The entry as the package writes it since r3, with the unlock tools hidden from the
        # model; the earlier shape, without that key, is adopted too (next test).
        manual = {"mcp_servers": {"openwrt": {"url": url,
                  "headers": {"Authorization": "Bearer ${OPENWRT_MCP_TOKEN}"},
                  "tools": {"exclude": ["mfa_unlock", "mfa_lock"]}}}}
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
        command = "from tools.mcp_tool_config import _load_mcp_config; " + \
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
        self.assertEqual(model["provider"], "uci")
        self.assertEqual(model["base_url"], endpoint)
        self.assertEqual(self.config()["providers"]["uci"]["key_env"], "OPENAI_API_KEY")

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

    def fake_endpoint(self, host="127.0.0.1"):
        # An OpenAI-compatible endpoint that answers every chat call with HERMES_RUNTIME_OK and
        # records (path, model, Authorization, whether tools were offered) for each one.
        received = []
        class Endpoint(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                if self.path != "/v1/chat/completions":
                    self.send_error(404)
                    return
                received.append((self.path, request.get("model"), self.headers.get("Authorization"),
                                 bool(request.get("tools"))))
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
        server = HTTPServer((host, 0), Endpoint)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://{host}:{server.server_port}/v1", received

    def test_model_endpoint_produces_agent_reply(self):
        url, received = self.fake_endpoint()
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
        # Every call reaches the endpoint UCI names, with its model and key. Exactly one is
        # the agent's turn, with tools; from 0.21 upstream also names the session with one
        # more call to the same model, without tools, which is allowed and nothing else is.
        self.assertTrue(received)
        for call in received:
            self.assertEqual(call[:3], ("/v1/chat/completions", "runtime-model", "Bearer provider-runtime-canary"))
        self.assertEqual(sum(1 for call in received if call[3]), 1, received)
        self.assertLessEqual(len(received), 2, received)
        command = "from gateway.run import _resolve_gateway_model; assert _resolve_gateway_model()=='runtime-model'"
        gateway = subprocess.run(["python3", "-c", command], env=env, check=False, capture_output=True, text=True)
        self.assertEqual(gateway.returncode, 0, gateway.stderr)

    def wrapper_env(self, endpoint, key="provider-runtime-canary"):
        # The real wrapper, as procd runs it, down to the exec of the gateway, which is replaced
        # by a print of the environment the gateway would have started with.
        cli = Path("/usr/bin/hermes")
        original = cli.read_bytes()
        try:
            cli.write_text("#!/bin/sh\nexec python3 -c 'import json,os; print(json.dumps(dict(os.environ)))'\n")
            key_file = self.home / "key"
            key_file.write_text(key)
            env = dict(self.env, HERMES_OPENWRT_TOOLSETS="memory", HERMES_OPENWRT_MCP_URL="",
                       HERMES_MEM_MAX_MB="0", OPENAI_BASE_URL=endpoint, HERMES_MODEL="runtime-model")
            return subprocess.run(["sh", str(FILES / "hermes-gateway"), str(key_file)],
                                  env=env, check=False, capture_output=True, text=True)
        finally:
            cli.write_bytes(original)

    def test_endpoint_on_the_lan_starts_and_answers(self):
        # On a Flint 2 at 0.21.5-r7 (2026-10-05), UCI named a model gateway on the LAN and every
        # start was refused (AuthError) until procd gave up. Upstream's auxiliary clients (the
        # session title, for one) resolve bare `custom`, which takes model.base_url only when
        # model.provider is `custom` or the host is loopback by name (upstream #14676); ours is
        # `uci`, so bare custom fell through to OpenRouter's default address with no key. Every
        # other endpoint in these tests is 127.0.0.1, which upstream trusts by name, so none of
        # them could show it. This one is a documentation address (TEST-NET-2), put on this
        # container's loopback device so the agent can reach it.
        host = "198.51.100.10"
        subprocess.run(["ip", "addr", "replace", host + "/32", "dev", "lo"], check=True, capture_output=True)
        url, received = self.fake_endpoint(host)
        self.assertEqual(self.configure(endpoint=url).returncode, 0)
        started = self.wrapper_env(url)
        self.assertEqual(started.returncode, 0, started.stderr)
        gateway = json.loads(started.stdout)
        # Both routes the gateway resolves, the main model and bare custom, land on that
        # endpoint with the main key ...
        code = ("from hermes_cli.runtime_provider import resolve_runtime_provider as r\n"
                "for x in (r(), r(requested='custom')):\n"
                f"    assert (x['base_url'].rstrip('/'), x['api_key']) == ({url!r}, 'provider-runtime-canary'), x\n")
        resolved = subprocess.run(["python3", "-c", code], env=gateway, check=False, capture_output=True, text=True)
        self.assertEqual(resolved.returncode, 0, resolved.stderr)
        # ... and an agent run in the gateway's own environment gets its answer from there,
        # every call with the model and key UCI names.
        result = subprocess.run(["hermes", "-z", "Reply briefly", "-t", "memory"],
                                env=dict(gateway, NO_PROXY=host + ",127.0.0.1,localhost"),
                                check=False, capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("HERMES_RUNTIME_OK", result.stdout)
        self.assertTrue(received)
        for call in received:
            self.assertEqual(call[:3], ("/v1/chat/completions", "runtime-model", "Bearer provider-runtime-canary"))
        self.assertEqual(sum(1 for call in received if call[3]), 1, received)
        self.assertLessEqual(len(received), 2, received)

    def test_dotenv_cannot_move_the_endpoint_the_wrapper_names(self):
        # The wrapper hands upstream CUSTOM_BASE_URL equal to the UCI endpoint (above). An upstream
        # .env that set it again would take bare `custom`, and the main key with it, somewhere UCI
        # never named. A router that worked round the refusal with that one line in .env, the same
        # address as UCI's, keeps starting after the upgrade.
        url = "http://198.51.100.10:4110/v1"
        self.assertEqual(self.configure(endpoint=url).returncode, 0)
        dotenv = self.home / ".env"
        moved = "CUSTOM_BASE_URL=http://conflict-canary.invalid/v1\n"
        dotenv.write_text(moved)
        refused = self.wrapper_env(url)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("overrides UCI-managed CUSTOM_BASE_URL", refused.stderr)
        self.assertNotIn("conflict-canary", refused.stdout + refused.stderr)
        self.assertEqual(dotenv.read_text(), moved)
        dotenv.write_text(f"CUSTOM_BASE_URL={url}\n")
        started = self.wrapper_env(url)
        self.assertEqual(started.returncode, 0, started.stderr)

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

    def test_profile_defaults_to_owner_and_refuses_unknown(self):
        # Every start leaves UCI as the next test expects it.
        self.addCleanup(subprocess.run, ["sh", "-c", "uci -q delete hermes.main.profile; uci commit hermes"])

        def start(profile):
            setup = "uci -q delete hermes.main.profile" if profile is None else f"uci set hermes.main.profile={profile}"
            script = f'''
mkdir -p /etc/hermes-agent /srv/hermes /var/lock /var/run /var/state
printf '%s' 'provider-canary-runtime' > /etc/hermes-agent/provider.key
uci set hermes.main.enabled=1
uci set hermes.main.mem_max_mb=0
uci set hermes.main.data_dir={shlex.quote(str(self.home))}
{setup}
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
            return subprocess.run(["sh", "-c", script], text=True, check=False, capture_output=True)

        # No `profile` option at all (a router whose file never had one) is the owner
        # profile: the agent runs as hermes, and the start says it is the default. It was
        # admin, running as root, until 0.21.5-r3, and assistant for a few hours on
        # 2026-09-24 before that.
        unset = start(None)
        self.assertEqual(unset.returncode, 0, unset.stderr)
        self.assertEqual(json.loads(unset.stdout)["instances"]["instance1"]["env"]["HERMES_OPENWRT_PROFILE"], "owner")
        self.assertIn("profile 'owner'", unset.stderr)
        self.assertIn("none is set", unset.stderr)
        for chosen, canonical in (("owner", "owner"), ("assistant", "assistant"), ("root", "root"), ("admin", "root")):
            with self.subTest(profile=chosen):
                result = start(chosen)
                self.assertEqual(result.returncode, 0, result.stderr)
                env = json.loads(result.stdout)["instances"]["instance1"]["env"]
                self.assertEqual(env["HERMES_OPENWRT_PROFILE"], canonical)
                if canonical == "root":
                    # What running as root allows, said at every start.
                    self.assertIn("runs as root", result.stderr)
                    self.assertIn("no unlock", result.stderr)
                if chosen == "admin":
                    self.assertIn("old name of 'root'", result.stderr)
        refused = start("superuser")
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("hermes.main.profile", refused.stderr)
        for name in ("owner", "assistant", "root", "superuser"):
            self.assertIn(name, refused.stderr)

        # The bridge itself refuses the same value directly, config untouched.
        (self.home / "config.yaml").write_text("model: unchanged\n")
        bridge_result = self.configure(profile="superuser")
        self.assertNotEqual(bridge_result.returncode, 0)
        self.assertEqual((self.home / "config.yaml").read_text(), "model: unchanged\n")
        for accepted in ("owner", "root", "admin"):
            self.assertEqual(self.configure(profile=accepted).returncode, 0, accepted)

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
        # The stand-in also says who it runs as: the profile decides that, and so does the
        # default when none is passed.
        cli.write_text("#!/bin/sh\nexec python3 -c 'import json,os; "
                       "print(json.dumps(dict(os.environ, GATE_UID=str(os.getuid()))))'\n")
        hermes_uid = str(pwd.getpwnam("hermes").pw_uid)
        key = self.home / "key"
        key.write_text("provider-runtime-canary")
        env = dict(self.env, HERMES_OPENWRT_TOOLSETS="memory", HERMES_OPENWRT_MCP_URL="",
                   HERMES_MEM_MAX_MB="0", OPENAI_BASE_URL=endpoint, HERMES_MODEL="runtime-model",
                   HERMES_OPENWRT_PROFILE="assistant")
        result = subprocess.run(["sh", str(FILES / "hermes-gateway"), str(key)],
                                env=env, check=False, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.config()["agent"]["disabled_toolsets"], ["code_execution", "file", "terminal"])
        self.assertEqual(json.loads(result.stdout)["GATE_UID"], hermes_uid)

        # Unset entirely -- an older procd env, or a service-list edge case --
        # must default to owner here too, the same as the init's own default: the
        # governed names come out, the operator's entry stays, and it is not root.
        tampered2 = self.config()
        tampered2["agent"]["disabled_toolsets"] = ["code_execution", "browser"]
        (self.home / "config.yaml").write_text(yaml.safe_dump(tampered2))
        env.pop("HERMES_OPENWRT_PROFILE")
        result2 = subprocess.run(["sh", str(FILES / "hermes-gateway"), str(key)],
                                 env=env, check=False, capture_output=True, text=True)
        self.assertEqual(result2.returncode, 0, result2.stderr)
        self.assertEqual(self.config()["agent"]["disabled_toolsets"], ["browser"])
        self.assertEqual(json.loads(result2.stdout)["GATE_UID"], hermes_uid)
        self.assertNotIn("HERMES_OPENWRT_AS_ROOT", json.loads(result2.stdout))
        # root, and its old name, run as root and tell the launcher not to second-guess that.
        for name in ("root", "admin"):
            with self.subTest(profile=name):
                rooted = subprocess.run(["sh", str(FILES / "hermes-gateway"), str(key)],
                                        env=dict(env, HERMES_OPENWRT_PROFILE=name), check=False,
                                        capture_output=True, text=True)
                self.assertEqual(rooted.returncode, 0, rooted.stderr)
                child = json.loads(rooted.stdout)
                self.assertEqual(child["GATE_UID"], "0")
                self.assertEqual(child["HERMES_OPENWRT_AS_ROOT"], "1")
        # A profile that is not one stops the wrapper rather than guess.
        refused = subprocess.run(["sh", str(FILES / "hermes-gateway"), str(key)],
                                 env=dict(env, HERMES_OPENWRT_PROFILE="superuser"), check=False,
                                 capture_output=True, text=True)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("unknown profile", refused.stderr)

    def test_wrapper_runs_everything_after_the_credentials_as_the_agents_user(self):
        # The wrapper is root because it has to read the key files and apply the memory
        # ceiling. Its two helpers read and write what the agent can write, and run
        # upstream's own code over it, so they run as the agent's user too, never as root.
        endpoint = "http://127.0.0.1:9/v1"
        self.assertEqual(self.configure(endpoint=endpoint).returncode, 0)
        recorded = {}
        for name in ("hermes-set-toolsets", "hermes-runtime-check"):
            helper = Path("/usr/libexec") / name
            original = helper.read_bytes()
            self.addCleanup(helper.write_bytes, original)
            marker = self.home / f"{name}.uid"
            recorded[name] = marker
            helper.write_text(f"import os\nopen({str(marker)!r}, 'w').write(str(os.getuid()))\n")
        cli = Path("/usr/bin/hermes")
        original = cli.read_bytes()
        self.addCleanup(cli.write_bytes, original)
        cli.write_text("#!/bin/sh\nexit 0\n")
        key = self.home / "key"
        key.write_text("provider-runtime-canary")
        env = dict(self.env, HERMES_OPENWRT_TOOLSETS="memory", HERMES_OPENWRT_MCP_URL="",
                   HERMES_MEM_MAX_MB="0", OPENAI_BASE_URL=endpoint, HERMES_MODEL="runtime-model")
        hermes_uid = str(pwd.getpwnam("hermes").pw_uid)
        for profile, want in (("owner", hermes_uid), ("assistant", hermes_uid), ("root", "0")):
            with self.subTest(profile=profile):
                for marker in recorded.values():
                    marker.unlink(missing_ok=True)
                result = subprocess.run(["sh", str(FILES / "hermes-gateway"), str(key)],
                                        env=dict(env, HERMES_OPENWRT_PROFILE=profile), check=False,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                for name, marker in recorded.items():
                    self.assertEqual(marker.read_text().strip(), want, f"{name} ran as the wrong user")

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


    # ---- The owner profile: no root, and the router only through openwrt-mcp ----

    def bridge(self, profile, factor=None, mcp="", tools="file,terminal,memory"):
        env = dict(self.env)
        if factor is not None:
            env["HERMES_OPENWRT_FACTOR"] = factor
        args = ["python3", str(FILES / "set-toolsets.py"), str(self.home), tools, mcp,
                "http://127.0.0.1:9/v1", "runtime-model", profile]
        return subprocess.run(args, env=env, check=False, capture_output=True, text=True)

    def test_owner_profile_enables_the_unlock_plugin_and_the_others_take_it_out_again(self):
        # The unlock plugin is the control that keeps the owner's PIN from the model, so the
        # owner profile switches it on whatever the operator's lists say, and the operator's
        # own names stay. The other profiles take out only what this bridge put there.
        (self.home / "config.yaml").write_text(yaml.safe_dump(
            {"plugins": {"enabled": ["kept"], "disabled": ["openwrt-unlock", "other"]}}))
        self.assertEqual(self.bridge("owner", factor="pin").returncode, 0)
        plugins = self.config()["plugins"]
        self.assertEqual(plugins["enabled"], ["kept", "openwrt-unlock"])
        self.assertEqual(plugins["disabled"], ["other"])
        self.assertEqual(self.bridge("owner", factor="pin").returncode, 0)
        self.assertEqual(self.config()["plugins"]["enabled"], ["kept", "openwrt-unlock"], "listed twice")
        for other in ("assistant", "root"):
            self.assertEqual(self.bridge(other).returncode, 0)
            self.assertEqual(self.config()["plugins"]["enabled"], ["kept"], other)
            self.assertNotIn("_openwrt_unlock_managed", self.config())
            self.assertEqual(self.bridge("owner", factor="pin").returncode, 0)
        # a name the operator listed themselves, with no marker from this bridge, is theirs
        (self.home / "config.yaml").write_text(yaml.safe_dump({"plugins": {"enabled": ["openwrt-unlock"]}}))
        self.assertEqual(self.bridge("assistant").returncode, 0)
        self.assertEqual(self.config()["plugins"]["enabled"], ["openwrt-unlock"])

    def test_owner_profile_keeps_tools_and_its_note_follows_the_factor(self):
        # owner runs as hermes with every selected tool, like admin did; what it tells the
        # agent depends on whether a second factor is set up, and neither note touches the
        # operator's own prompt.
        (self.home / "config.yaml").write_text(yaml.safe_dump({"agent": {
            "system_prompt": "Be brief.", "disabled_toolsets": ["browser", "file", "terminal", "code_execution"]}}))
        result = self.bridge("owner")
        self.assertEqual(result.returncode, 0, result.stderr)
        agent = self.config()["agent"]
        self.assertEqual(agent["disabled_toolsets"], ["browser"])
        prompt = agent["system_prompt"]
        self.assertTrue(prompt.startswith("Be brief.\n\n[hermes-openwrt: owner profile]\n"), prompt)
        self.assertIn("LuCI", prompt)
        self.assertNotIn("/unlock", prompt)
        check = subprocess.run(["python3", "-c", (
            "import json, yaml; from hermes_cli.config import get_config_path; "
            "from hermes_cli.tools_config import _get_platform_tools; import model_tools; "
            "config = yaml.safe_load(get_config_path().read_text()); "
            "enabled = sorted(_get_platform_tools(config, 'telegram')); "
            "defs = model_tools.get_tool_definitions(enabled_toolsets=enabled, "
            "disabled_toolsets=config['agent'].get('disabled_toolsets') or [], quiet_mode=True); "
            "print(json.dumps(sorted(d['function']['name'] for d in defs)))")],
            env=self.env, check=False, capture_output=True, text=True)
        self.assertEqual(check.returncode, 0, check.stderr)
        names = json.loads(check.stdout.strip().splitlines()[-1])
        self.assertIn("terminal", names)
        self.assertIn("read_file", names)
        for factor in ("pin", "totp", "pin+totp"):
            with self.subTest(factor=factor):
                self.assertEqual(self.bridge("owner", factor).returncode, 0)
                prompt = self.config()["agent"]["system_prompt"]
                self.assertTrue(prompt.startswith("Be brief.\n\n"), prompt)
                self.assertEqual(prompt.count("[hermes-openwrt: owner profile]"), 1)
                self.assertIn("send /unlock in the private chat", prompt)
                self.assertIn("Never ask the owner for a PIN or a code in a message", prompt)
                self.assertNotIn("LuCI", prompt)
        before = (self.home / "config.yaml").read_bytes()
        self.assertEqual(self.bridge("owner", "pin+totp").returncode, 0)
        self.assertEqual((self.home / "config.yaml").read_bytes(), before)
        # Another profile replaces the note, root takes it out, the operator's text comes back.
        self.assertEqual(self.bridge("assistant").returncode, 0)
        prompt = self.config()["agent"]["system_prompt"]
        self.assertNotIn("owner profile", prompt)
        self.assertIn("no terminal", prompt)
        self.assertEqual(self.config()["agent"]["disabled_toolsets"], ["browser", "code_execution", "file", "terminal"])
        self.assertEqual(self.bridge("root").returncode, 0)
        self.assertEqual(self.config()["agent"]["system_prompt"], "Be brief.")
        self.assertEqual(self.config()["agent"]["disabled_toolsets"], ["browser"])
        # A factor that is not one refuses and leaves the file alone.
        before = (self.home / "config.yaml").read_bytes()
        self.assertNotEqual(self.bridge("owner", "sms").returncode, 0)
        self.assertEqual((self.home / "config.yaml").read_bytes(), before)

    def test_mcp_entry_hides_the_unlock_tools_and_adopts_the_earlier_shape(self):
        # The owner proves who they are through openwrt-mcp's mfa_unlock; a model offered it
        # would be asking for a PIN. Upstream's own filter decides what registers.
        url = "http://127.0.0.1:8730/mcp"
        for profile in ("owner", "assistant", "root"):
            with self.subTest(profile=profile):
                (self.home / "config.yaml").unlink(missing_ok=True)
                self.assertEqual(self.bridge(profile, mcp=url).returncode, 0)
                self.assertEqual(self.config()["mcp_servers"]["openwrt"]["tools"],
                                 {"exclude": ["mfa_unlock", "mfa_lock"]})
        code = ("import yaml; from hermes_cli.config import get_config_path; "
                "from tools.mcp_tool_registration import _make_tool_filter; "
                "entry = yaml.safe_load(get_config_path().read_text())['mcp_servers']['openwrt']; "
                "keep = _make_tool_filter('openwrt', entry); "
                "print(keep('ubus_call'), keep('uci_apply'), keep('mfa_unlock'), keep('mfa_lock'))")
        check = subprocess.run(["python3", "-c", code], env=self.env, check=False, capture_output=True, text=True)
        self.assertEqual(check.returncode, 0, check.stderr)
        self.assertEqual(check.stdout.strip().splitlines()[-1], "True True False False")
        # The entry as releases before the unlock wrote it, pasted by hand, is the package's
        # own shape: adopted and brought up to date, not refused.
        (self.home / "config.yaml").write_text(yaml.safe_dump({"mcp_servers": {"openwrt": {
            "url": url, "headers": {"Authorization": "Bearer ${OPENWRT_MCP_TOKEN}"}}}}))
        result = self.bridge("owner", mcp=url)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.config()["mcp_servers"]["openwrt"]["tools"], {"exclude": ["mfa_unlock", "mfa_lock"]})
        self.assertTrue(self.config().get("_openwrt_mcp_managed"))

    def test_config_written_by_root_takes_the_data_dir_owner(self):
        # A root-owned config.yaml is one the gateway, which is hermes, cannot update.
        self.assertEqual(self.configure().returncode, 0)
        hermes = pwd.getpwnam("hermes")
        stat = (self.home / "config.yaml").stat()
        self.assertEqual((stat.st_uid, stat.st_gid), (hermes.pw_uid, hermes.pw_gid))
        read = subprocess.run(DROP + ["hermes", "python3", "-c", f"print(len(open('{self.home}/config.yaml').read()))"],
                              check=False, capture_output=True, text=True)
        self.assertEqual(read.returncode, 0, read.stderr)

    def test_hermes_drop_gives_up_root_and_refuses_what_it_cannot_do(self):
        hermes = pwd.getpwnam("hermes")
        probe = ("import os\nprint(os.getresuid(), os.getresgid(), os.getgroups())\n"
                 "print(os.environ['HOME'], os.environ['USER'], os.environ['LOGNAME'], os.getcwd())\n"
                 "try:\n    os.setuid(0)\nexcept OSError:\n    print('setuid(0) refused')\n")
        inaccessible = tempfile.mkdtemp(prefix="drop-cwd-")
        self.addCleanup(shutil.rmtree, inaccessible, True)
        os.chmod(inaccessible, 0o700)
        ids = f"({hermes.pw_uid}, {hermes.pw_uid}, {hermes.pw_uid}) ({hermes.pw_gid}, {hermes.pw_gid}, {hermes.pw_gid}) []"
        ran = subprocess.run(DROP + ["hermes", "python3", "-c", probe], cwd=inaccessible, env=self.env,
                             check=False, capture_output=True, text=True)
        self.assertEqual(ran.returncode, 0, ran.stderr)
        lines = ran.stdout.strip().splitlines()
        self.assertEqual(lines[0], ids)
        # HOME is the data directory when HERMES_HOME names one; the directory root was in,
        # which the new user cannot enter, is left for it.
        self.assertEqual(lines[1], f"{self.home} hermes hermes {self.home}")
        self.assertEqual(lines[2], "setuid(0) refused")
        away = subprocess.run(DROP + ["hermes", "python3", "-c", "import os; print(os.environ['HOME'])"],
                              env=dict(self.env, HERMES_HOME="/no/such/directory"), check=False,
                              capture_output=True, text=True)
        self.assertEqual(away.stdout.strip(), hermes.pw_dir)
        # A root target is a plain exec: nothing is lowered.
        plain = subprocess.run(DROP + ["root", "python3", "-c", "import os; print(os.getuid())"],
                               check=False, capture_output=True, text=True)
        self.assertEqual(plain.stdout.strip(), "0")
        # What it will not do, and that the command then never runs. An account that is root
        # under another name is not a drop either.
        passwd = Path("/etc/passwd")
        saved = passwd.read_bytes()
        self.addCleanup(passwd.write_bytes, saved)
        with passwd.open("a") as stream:
            stream.write("rootalias:x:0:0:alias:/root:/bin/sh\n")
        marker = self.home / "ran"
        for argv, status, words in ((["no-such-user", "touch", str(marker)], 1, "no user"),
                                    (["rootalias", "touch", str(marker)], 1, "not a drop"),
                                    (["hermes"], 2, "usage")):
            with self.subTest(argv=argv):
                refused = subprocess.run(DROP + argv, check=False, capture_output=True, text=True)
                self.assertEqual(refused.returncode, status)
                self.assertIn(words, refused.stderr)
                self.assertFalse(marker.exists())
        missing = subprocess.run(DROP + ["hermes", "/no/such/command"], check=False, capture_output=True, text=True)
        self.assertEqual(missing.returncode, 1)
        # Not root, so it cannot become anyone else; being the target already is fine.
        other = subprocess.run(DROP + ["hermes"] + DROP + ["nobody", "touch", str(marker)], check=False,
                               capture_output=True, text=True)
        self.assertEqual(other.returncode, 1)
        self.assertIn("not root", other.stderr)
        self.assertFalse(marker.exists())
        same = subprocess.run(DROP + ["hermes"] + DROP + ["hermes", "id", "-u"], check=False,
                              capture_output=True, text=True)
        self.assertEqual(same.stdout.strip(), str(hermes.pw_uid))

    def test_launcher_runs_as_the_user_who_owns_the_data_directory(self):
        # `HERMES_HOME=/srv/hermes hermes cron create ...` over SSH is root, and the gateway is
        # hermes: left as root it would write files the gateway cannot update. The launcher
        # puts upstream's entry point in front of a stand-in that says who runs it.
        main = Path("/usr/lib/hermes-agent/site-packages/hermes_cli/main.py")
        original = main.read_bytes()
        self.addCleanup(main.write_bytes, original)
        main.write_text("import os\nprint(os.getuid(), os.environ.get('HOME'))\n")
        hermes = pwd.getpwnam("hermes")
        rootdir = Path(tempfile.mkdtemp(prefix="launcher-root-"))
        self.addCleanup(shutil.rmtree, rootdir, True)

        def run(home, as_user=None, **extra):
            env = {k: v for k, v in self.env.items() if k != "HERMES_HOME"}
            if home is not None:
                env["HERMES_HOME"] = str(home)
            env.update(extra)
            command = ["/usr/bin/hermes"]
            if as_user:
                command = DROP + [as_user] + command
            return subprocess.run(command, env=env, check=False, capture_output=True, text=True, cwd="/")

        owned = run(self.home)
        self.assertEqual(owned.stdout.strip(), f"{hermes.pw_uid} {self.home}", owned.stderr)
        self.assertEqual(run(rootdir).stdout.split()[0], "0")
        self.assertEqual(run(self.home, HERMES_OPENWRT_AS_ROOT="1").stdout.split()[0], "0")
        self.assertEqual(run(self.home, as_user="hermes").stdout.split()[0], str(hermes.pw_uid))
        # No directory named and none at ~/.hermes: nothing says hermes, so it stays root.
        self.assertEqual(run(None, HOME=str(rootdir)).stdout.split()[0], "0")

    def test_owner_policies_are_ordered_idempotent_and_leave_other_sections_alone(self):
        config = Path("/etc/config/openwrt-mcp")
        original = config.read_bytes() if config.exists() else None

        def restore():
            if original is None:
                config.unlink(missing_ok=True)
            else:
                config.write_bytes(original)
        self.addCleanup(restore)
        self.addCleanup(subprocess.run, ["openwrt-mcp", "unpair", "hermes-unit"], capture_output=True)
        config.write_text("config server\n\toption listen '127.0.0.1:8730'\n\n"
                          "config policy 'mine'\n\toption client 'someone-else'\n\tlist tools 'logread'\n")
        token = self.home / "unit.token"
        token.unlink(missing_ok=True)

        def agent(factor, name="unit", window="20m", token_file=None):
            script = (f". /lib/functions.sh; . {shlex.quote(str(FILES / 'hermes-agent.init'))}; "
                      f"hermes_mcp_agent {name} {shlex.quote(str(token_file or token))} {factor} {window} 3 1h")
            return subprocess.run(["sh", "-c", script], check=False, capture_output=True, text=True)

        def show():
            return subprocess.run(["uci", "-q", "show", "openwrt-mcp"], check=True, capture_output=True,
                                  text=True).stdout.splitlines()

        def sections(lines):
            return [line.split("=")[0].split(".")[1] for line in lines if line.endswith("=policy")]

        def section(lines, name):
            return {line.split(".", 2)[2].split("=", 1)[0]: line.split("=", 1)[1] for line in lines
                    if line.startswith(f"openwrt-mcp.{name}.")}
        mine = [line for line in show() if line.startswith("openwrt-mcp.mine")]
        result = agent("pin")
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = show()
        # openwrt-mcp takes the first policy of a client that covers a call, so the reads come
        # first, one tool each, and the change policy, which wants the factor, last.
        self.assertEqual(sections(lines), ["mine", "hermes_unit_read_ubus", "hermes_unit_read_uci",
                                           "hermes_unit_read_log", "hermes_unit_change"])
        self.assertEqual([line for line in lines if line.startswith("openwrt-mcp.mine")], mine)
        for name, tool in (("read_ubus", "ubus_call"), ("read_uci", "uci_get"), ("read_log", "logread")):
            body = section(lines, f"hermes_unit_{name}")
            self.assertEqual(body["client"], "'hermes-unit'")
            self.assertEqual(body["tools"], f"'{tool}'")
            self.assertNotIn("mfa_tools", body)
        ubus = section(lines, "hermes_unit_read_ubus")["scopes"].replace("'", "").split()
        for scope in ubus:
            # One method each, never a whole object: system.* would take in system.reboot.
            self.assertFalse(scope.endswith("*"), scope)
        self.assertNotIn("system.reboot", ubus)
        uci = section(lines, "hermes_unit_read_uci")["scopes"].replace("'", "").split()
        self.assertFalse([scope for scope in uci if scope.startswith("wireless")], uci)
        self.assertNotIn("network", uci)
        self.assertNotIn("network.*", uci)
        change = section(lines, "hermes_unit_change")
        self.assertEqual(change["tools"], "'ubus_call' 'uci_apply' 'uci_confirm'")
        self.assertEqual((change["scopes"], change["mfa_tools"], change["mfa_factor"]), ("'*'", "'*'", "'pin'"))
        self.assertEqual((change["mfa_window"], change["mfa_max_failures"], change["mfa_lockout"]),
                         ("'20m'", "'3'", "'1h'"))
        # openwrt-mcp's own parser accepts what was written.
        policies = subprocess.run(["openwrt-mcp", "policies"], check=False, capture_output=True, text=True)
        self.assertEqual(policies.returncode, 0, policies.stderr)
        self.assertIn("hermes-unit", policies.stdout)
        # The token: root-only, made once, and a start that changes nothing writes nothing.
        self.assertEqual(token.stat().st_mode & 0o777, 0o600)
        first = token.read_bytes()
        self.assertTrue(first.strip())
        before, inode = config.read_bytes(), config.stat().st_ino
        self.assertEqual(agent("pin").returncode, 0)
        self.assertEqual(config.read_bytes(), before)
        self.assertEqual(config.stat().st_ino, inode, "the file was written again though nothing changed")
        self.assertEqual(token.read_bytes(), first)
        # A token that went missing is replaced, not kept as something nobody holds.
        token.unlink()
        self.assertEqual(agent("pin").returncode, 0)
        self.assertNotEqual(token.read_bytes(), first)
        # No factor: no change policy at all, so a change finds no policy that grants it.
        self.assertEqual(agent("none").returncode, 0)
        lines = show()
        self.assertEqual(sections(lines), ["mine", "hermes_unit_read_ubus", "hermes_unit_read_uci",
                                           "hermes_unit_read_log"])
        self.assertEqual(subprocess.run(["openwrt-mcp", "policies"], check=False, capture_output=True).returncode, 0)
        # Another agent is another set of sections and another client, and the first is left.
        self.addCleanup(subprocess.run, ["openwrt-mcp", "unpair", "hermes-second"], capture_output=True)
        second_token = self.home / "second.token"
        second = agent("pin", name="second", token_file=second_token)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(sections(show()), ["mine", "hermes_unit_read_ubus", "hermes_unit_read_uci",
                                            "hermes_unit_read_log", "hermes_second_read_ubus",
                                            "hermes_second_read_uci", "hermes_second_read_log",
                                            "hermes_second_change"])
        self.assertNotEqual(second_token.read_bytes(), token.read_bytes())
        # A name that cannot be part of a section name is refused, writing nothing.
        before = config.read_bytes()
        self.assertNotEqual(agent("pin", name="Bad-Name").returncode, 0)
        self.assertEqual(config.read_bytes(), before)

    def _start(self, uci, data_dir=None, path=None):
        """The init's own start_service as root, after some UCI lines; the CompletedProcess."""
        script = f'''
mkdir -p /etc/hermes-agent /var/lock /var/run /var/state
printf '%s' 'provider-canary-runtime' > /etc/hermes-agent/provider.key
uci set hermes.main.enabled=1
uci set hermes.main.mem_max_mb=0
uci set hermes.main.data_dir={shlex.quote(str(data_dir or self.home))}
uci -q delete hermes.main.profile
uci -q delete hermes.security
uci set hermes.telegram.enabled=0
{uci}
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
        self.addCleanup(subprocess.run, ["sh", "-c", "uci -q delete hermes.security; uci commit hermes"])
        env = dict(os.environ, PATH=path + ":" + os.environ["PATH"]) if path else None
        return subprocess.run(["sh", "-c", script], text=True, check=False, capture_output=True, env=env)

    def test_security_options_refuse_bad_values(self):
        good = self._start("uci set hermes.security=security\nuci set hermes.security.factor=pin+totp\n"
                           "uci set hermes.security.window=1h30m\nuci set hermes.security.max_failures=3\n"
                           "uci set hermes.security.lockout=2d")
        self.assertEqual(good.returncode, 0, good.stderr)
        self.assertEqual(json.loads(good.stdout)["instances"]["instance1"]["env"]["HERMES_OPENWRT_FACTOR"], "pin+totp")
        for option, value in (("factor", "sms"), ("window", "15"), ("window", "soon"), ("lockout", "-5m"),
                              ("max_failures", "0"), ("max_failures", "five")):
            with self.subTest(option=option, value=value):
                result = self._start(f"uci set hermes.security=security\nuci set hermes.security.{option}={value}")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("hermes.security", result.stderr)
        # Left alone, nothing is configured: the factor is none.
        unset = self._start("")
        self.assertEqual(json.loads(unset.stdout)["instances"]["instance1"]["env"]["HERMES_OPENWRT_FACTOR"], "none")
        # And only the owner profile has one.
        assistant = self._start("uci set hermes.main.profile=assistant\nuci set hermes.security=security\n"
                                "uci set hermes.security.factor=sms")
        self.assertEqual(assistant.returncode, 0, assistant.stderr)

    def test_init_runs_the_bridge_as_the_agents_user(self):
        # The init checks the configuration before it opens an instance, by running the
        # same bridge the wrapper runs, and for the same reason as the wrapper's: it writes
        # and reads what the agent can write, so it is run as the agent's user.
        helper = Path("/usr/libexec/hermes-set-toolsets")
        original = helper.read_bytes()
        self.addCleanup(helper.write_bytes, original)
        marker = self.home / "bridge.uid"
        helper.write_text(f"import os\nopen({str(marker)!r}, 'w').write(str(os.getuid()))\n")
        for profile, want in (("owner", str(pwd.getpwnam("hermes").pw_uid)), ("assistant", str(pwd.getpwnam("hermes").pw_uid)),
                              ("root", "0")):
            with self.subTest(profile=profile):
                marker.unlink(missing_ok=True)
                result = self._start(f"uci set hermes.main.profile={profile}")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(marker.read_text().strip(), want)

    def test_start_refuses_a_data_dir_it_cannot_give_to_the_agent(self):
        # The agent has to be able to write where its data is. A directory chown cannot give
        # away (a read-only mount) or whose ownership the filesystem ignores (FAT) would
        # otherwise start a gateway that dies on its first write.
        plain = self.home / "plain"
        plain.mkdir()
        stubs = Path(tempfile.mkdtemp(prefix="stub-chown-"))
        self.addCleanup(shutil.rmtree, stubs, True)
        (stubs / "chown").write_text("#!/bin/sh\nexit 0\n")
        (stubs / "chown").chmod(0o755)
        ignored = self._start("", data_dir=plain, path=str(stubs))
        self.assertNotEqual(ignored.returncode, 0)
        self.assertIn("cannot write in", ignored.stderr)
        self.assertIn("Unix ownership", ignored.stderr)
        mount = self.home / "ro"
        mount.mkdir()
        subprocess.run(["mount", "-t", "tmpfs", "-o", "ro,size=1m", "tmpfs", str(mount)], check=True)
        self.addCleanup(subprocess.run, ["umount", str(mount)])
        locked = self._start("", data_dir=mount)
        self.assertNotEqual(locked.returncode, 0)
        self.assertIn("cannot give", locked.stderr)
        # With a chown that works, the same kind of directory is handed over and starts.
        fine = self.home / "fine"
        fine.mkdir()
        started = self._start("", data_dir=fine)
        self.assertEqual(started.returncode, 0, started.stderr)
        self.assertEqual(fine.stat().st_uid, pwd.getpwnam("hermes").pw_uid)
        # The root profile hands it to root instead, and asks nothing of hermes.
        started_root = self._start("uci set hermes.main.profile=root", data_dir=fine)
        self.assertEqual(started_root.returncode, 0, started_root.stderr)
        self.assertEqual(fine.stat().st_uid, 0)

    # ---- Further providers: UCI sections, offered by /model per chat ----

    PROVIDERS = ("claude|Anthropic|https://api.anthropic.com/v1|/etc/hermes-agent/claude.key|claude-haiku-4-5;"
                 "local|Local model|http://127.0.0.1:8/v1|/etc/hermes-agent/local.key|local-model")

    def configure_providers(self, raw, endpoint="http://127.0.0.1:9/v1"):
        env = dict(self.env, HERMES_OPENWRT_PROVIDERS=raw)
        args = ["python3", str(FILES / "set-toolsets.py"), str(self.home), "memory", "", endpoint, "runtime-model"]
        return subprocess.run(args, env=env, text=True, check=False, capture_output=True)

    def upstream(self, code, as_agent=False, **extra):
        # Upstream's own resolvers, run the way the gateway runs them, in a subprocess
        # with the keys the wrapper would have exported. as_agent runs them as the user the
        # agent runs as, for what the agent itself would have written into its data directory.
        env = dict(self.env, OPENAI_API_KEY="main-key-canary", **extra)
        command = (DROP + ["hermes"] if as_agent else []) + ["python3", "-c", code]
        return subprocess.run(command, env=env, check=False, capture_output=True, text=True)

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
                    "uci|U|http://127.0.0.1:9/v1|/k|m",
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
        # uci is the main model's own entry, written with the endpoint.
        self.assertEqual(sorted(self.config()["providers"]), ["claude", "mine", "uci"])
        self.assertEqual(self.configure_providers("").returncode, 0)
        self.assertEqual(sorted(self.config()["providers"]), ["mine", "uci"])
        self.assertEqual(self.config()["providers"]["mine"], mine)
        # An operator entry with a UCI provider's name is refused, not overwritten.
        before = (self.home / "config.yaml").read_text()
        result = self.configure_providers("mine|Mine|http://127.0.0.1:9/v1|/k|m")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.home / "config.yaml").read_text(), before)
        # Unset means untouched: callers that predate providers change nothing here.
        self.assertEqual(self.configure(endpoint="http://127.0.0.1:9/v1").returncode, 0)
        self.assertEqual(self.config()["providers"]["mine"], mine)
        # So is an operator entry that took the main model's name.
        config = self.config()
        config["providers"]["uci"] = mine
        (self.home / "config.yaml").write_text(yaml.safe_dump(config))
        before = (self.home / "config.yaml").read_text()
        result = self.configure(endpoint="http://127.0.0.1:9/v1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.home / "config.yaml").read_text(), before)

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
        # uci is the main model's own entry; local, whose key is missing, is left out.
        self.assertEqual(sorted(self.config()["providers"]), ["claude", "uci"])
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

    SWITCH_CHECK = (
        # What the gateway does on /model, step by step, with upstream's own pieces: the
        # current route comes from _ModelSwitchContext.read_config, which never reads a
        # key (only a session override carries one), the picker's button is the slug of
        # the current entry, and the next turn rebuilds the agent from the override.
        "import sys\n"
        "from pathlib import Path\n"
        "from gateway.run import GatewayRunner, _resolve_runtime_agent_kwargs_for_provider\n"
        "from gateway.slash_commands_model import _ModelSwitchContext\n"
        "from hermes_cli.model_switch import switch_model\n"
        "from hermes_cli.model_switch_providers import list_picker_providers\n"
        "from run_agent import AIAgent\n"
        "import os\n"
        "endpoint, how = sys.argv[1], sys.argv[2]\n"
        "ctx = _ModelSwitchContext(session_key='s', source=None, config_path=Path(os.environ['HERMES_HOME']) / 'config.yaml',"
        " persist_global=False)\n"
        "ctx.read_config()\n"
        "assert ctx.current_api_key == '', 'the gateway now reads a key here; this check no longer models it'\n"
        # The button a person presses: the current provider's, the one the picker ticks.
        "current = [p['slug'] for p in list_picker_providers(current_provider=ctx.current_provider, "
        "current_base_url=ctx.current_base_url, current_model=ctx.current_model, user_providers=ctx.user_provs, "
        "custom_providers=ctx.custom_provs, excluded_providers=ctx.excluded_provs, max_models=5, "
        "non_blocking_catalogs=True, probe_custom_providers=False, probe_current_custom_provider=False) "
        "if p.get('is_current')]\n"
        "assert len(current) == 1, current\n"
        "explicit = current[0] if how == 'button' else ''\n"
        "s = switch_model(raw_input='vendor/other-model', explicit_provider=explicit, current_provider=ctx.current_provider, "
        "current_model=ctx.current_model, current_base_url=ctx.current_base_url, current_api_key=ctx.current_api_key, "
        "user_providers=ctx.user_provs, custom_providers=ctx.custom_provs)\n"
        "assert s.success, s.error_message\n"
        "override = {'model': s.new_model, 'provider': s.target_provider, 'api_key': s.api_key, "
        "'base_url': s.base_url, 'api_mode': s.api_mode}\n"
        "runner = object.__new__(GatewayRunner)\n"
        "runner._session_model_override = lambda key: override\n"
        "model, kwargs = runner._apply_session_model_override('s', ctx.current_model, "
        "_resolve_runtime_agent_kwargs_for_provider(s.target_provider, target_model=s.new_model))\n"
        "for name in ('model', 'request_overrides', 'capabilities'):\n"
        "    kwargs.pop(name, None)\n"
        "agent = AIAgent(model=model, quiet_mode=True, skip_context_files=True, skip_memory=True, **kwargs)\n"
        "assert model == 'vendor/other-model', model\n"
        "assert str(agent.client.base_url).rstrip('/') == endpoint, agent.client.base_url\n"
        "assert agent.client.api_key == os.environ['OPENAI_API_KEY'], 'the rebuilt agent lost the main key'\n"
    )

    def test_model_switch_keeps_the_main_key(self):
        # @measured 2026-09-25 on a Brume 2 with a Telegram bot: after /model picked a
        # model with the buttons, the next turn failed "No LLM provider configured".
        # The picker's button for a bare `custom` provider came back with no key, the
        # next turn laid that empty key over the real one, and upstream sends a custom
        # route on openrouter.ai to its own OpenRouter provider, which wants a key the
        # wrapper does not set. OpenRouter is the default endpoint, so it hit everyone.
        # The LAN address is one upstream does not trust by name (0.21.5-r8), and the
        # environment is the one the wrapper hands the gateway, CUSTOM_BASE_URL included.
        for endpoint in ("https://openrouter.ai/api/v1", "http://127.0.0.1:9/v1", "http://198.51.100.10:4110/v1"):
            self.assertEqual(self.configure(endpoint=endpoint).returncode, 0)
            for how in ("button", "typed"):
                with self.subTest(endpoint=endpoint, how=how):
                    check = subprocess.run(["python3", "-c", self.SWITCH_CHECK, endpoint, how], check=False,
                                           capture_output=True, text=True,
                                           env=dict(self.env, OPENAI_API_KEY="main-key-canary",
                                                    OPENAI_BASE_URL=endpoint, CUSTOM_BASE_URL=endpoint,
                                                    HERMES_MODEL="runtime-model"))
                    self.assertEqual(check.returncode, 0, check.stdout + check.stderr[-2000:])

    def test_provider_on_the_main_endpoint_uses_its_own_key(self):
        # @measured 2026-09-25 on a Brume 2: a UCI provider on the main model's own
        # OpenRouter address refused the start ("primary credential pool conflicts"), and
        # a chat switched to it went out with the main key, while the bare `custom` main
        # model shared its address. A second account on the same service is a real case.
        endpoint = "https://openrouter.ai/api/v1"
        raw = "flash|Flash|https://openrouter.ai/api/v1|/etc/hermes-agent/flash.key|vendor/flash-model"
        self.assertEqual(self.configure_providers(raw, endpoint=endpoint).returncode, 0)
        env = dict(self.env, OPENAI_BASE_URL=endpoint, HERMES_MODEL="runtime-model",
                   OPENAI_API_KEY="main-key-canary", HERMES_PROVIDER_FLASH_KEY="flash-key-canary")
        pre = subprocess.run(["python3", str(FILES / "runtime-check.py")], env=env, check=False,
                             capture_output=True, text=True)
        self.assertEqual(pre.returncode, 0, pre.stderr)
        code = (
            "from hermes_cli.config import load_config, get_compatible_custom_providers\n"
            "from hermes_cli.model_switch import switch_model\n"
            "cfg = load_config()\n"
            "s = switch_model(raw_input='vendor/flash-model', explicit_provider='flash', "
            "current_provider=cfg['model']['provider'], current_model='runtime-model', "
            f"current_base_url='{endpoint}', current_api_key='', user_providers=cfg.get('providers'), "
            "custom_providers=get_compatible_custom_providers(cfg))\n"
            "assert s.success and s.target_provider == 'flash', s\n"
            "assert s.api_key == 'flash-key-canary', 'switched with ' + ('the main key' if s.api_key == 'main-key-canary' else 'no key')\n"
        )
        check = self.upstream(code, HERMES_PROVIDER_FLASH_KEY="flash-key-canary")
        self.assertEqual(check.returncode, 0, check.stdout + check.stderr[-1500:])

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
        # Who the sign-in's own python runs as is recorded by a sitecustomize in the package's
        # private site-packages, which only an interpreter started with that on its path (the
        # sign-in's, not hermes-drop's isolated one) imports.
        site = Path("/usr/lib/hermes-agent/site-packages/sitecustomize.py")
        self.assertFalse(site.exists())
        self.addCleanup(site.unlink, True)
        who = self.home / "signin.uid"
        site.write_text("import os\nf = os.environ.get('GATE_UID_FILE')\n"
                        "if f:\n    open(f, 'a').write(str(os.getuid()) + '\\n')\n")
        # Written as the agent writes it: the sign-in runs as the user who owns the data
        # directory, so the tokens it files are that user's.
        saved = self.upstream("from hermes_cli.auth import _save_codex_tokens\n"
                              "_save_codex_tokens({'access_token': 'codex-access-canary', 'refresh_token': 'codex-refresh-canary'}, None)\n",
                              as_agent=True)
        self.assertEqual(saved.returncode, 0, saved.stderr)
        self.assertIn("codex-access-canary", (self.home / "auth.json").read_text())
        who.unlink(missing_ok=True)
        out = subprocess.run(["sh", str(helper), "chatgpt", "--logout"], check=False, capture_output=True, text=True,
                             env=dict(os.environ, GATE_UID_FILE=str(who)))
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertNotIn("codex-access-canary", (self.home / "auth.json").read_text())
        self.assertNotIn("codex-access-canary", out.stdout + out.stderr)
        # And it ran as the agent's user, not as the root shell that started it.
        self.assertEqual(who.read_text().split(), [str(pwd.getpwnam("hermes").pw_uid)])

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
        self.assertEqual(self.config()["model"]["provider"], "uci")
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
