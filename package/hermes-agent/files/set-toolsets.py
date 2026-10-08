#!/usr/bin/env python3
"""Merge UCI gateway defaults and the package-owned MCP connection into Hermes.

@codex 2026-09-19: platform_toolsets is the shipped gateway's actual contract.
This selects defaults, not an OS sandbox; explicit cron-job overrides and
operator-configured plugins/MCP servers retain their upstream semantics.

@decided 2026-09-24: two profiles; assistant turns off terminal, code execution and
file tools and applies wherever no profile is set, existing routers included; admin
keeps every selected tool, as root.

How, and why these three: an optional profile argument governs agent.disabled_toolsets,
which model_tools._compute_tool_definitions always subtracts after enabled_toolsets
is resolved (upstream #17309), which hermes_cli.tools_config._get_platform_tools
also subtracts last from the per-platform list above, and which cron/scheduler.py
layers over per-job overrides (#25752); delegated sub-agents inherit it. file goes
with the other two because the file tool's own sensitive-path guard does not cover
/usr/lib/hermes-agent and could otherwise rewrite the agent's own code to lift the
restriction. Entries outside those three are the operator's and are left alone
either way. Omitting the argument leaves agent.disabled_toolsets untouched.

@decided 2026-09-24, later the same day, superseding the default above: admin is the
default everywhere, existing routers included; assistant is opt-in; in assistant the
agent is told it has no terminal, code execution or file tools; the number of model
steps in one turn is capped.

How: the note is a delimited block in agent.system_prompt, which the gateway loads as
its ephemeral system prompt; the operator's own text around it is kept, and admin
removes only the block. The cap comes from UCI through HERMES_OPENWRT_MAX_TURNS into
agent.max_turns, which the gateway turns into its per-turn iteration budget.

@decided 2026-10-01, superseding the default above: four profile names. owner is the
default, wherever none is set, existing routers included: the agent runs as the
unprivileged user hermes with terminal, code and file tools on, and changes the router
only through openwrt-mcp, which refuses a change until the owner unlocks it. assistant is
as before. root is the old admin: every selected tool, as root, an explicit and warned
choice. admin is accepted as another name for root. owner, root and admin leave
agent.disabled_toolsets the way admin did; assistant fills it. owner's note in
agent.system_prompt says what the unlock needs and depends on HERMES_OPENWRT_FACTOR (the
init passes hermes.security.factor): with none the agent is told a factor has to be set
up first. The package-written mcp_servers.openwrt entry carries tools.exclude, so the
model is never offered openwrt-mcp's unlock or lock tools in any profile (upstream's
tools/mcp_tool_registration.py reads that key).

@claude 2026-10-08, 0.21.5-r10: exec and wg_new_client are excluded the same way, since the
agent's client is never granted them and models that saw them reached for them; every profile
writes tools.tool_search.enabled 'off' where the operator has set nothing, so upstream does not
defer the MCP tools behind its search tool.

@decided 2026-10-01 (the unlock plugin): in the owner profile the bridge also enables the
plugin openwrt-unlock, which ships in the package's own site-packages and takes /unlock and
/lock in Telegram (its own header says how). It adds the name to plugins.enabled, keeping
every name the operator listed, and takes it out of plugins.disabled, which would otherwise
win over the list and leave the owner's PIN to the model: in this profile that is not the
operator's to turn off, because the unlock is the control. The other profiles remove the name
again, but only when this bridge was what added it (the _openwrt_unlock_managed marker).

@decided 2026-09-25: more than one provider on one router. Every chat starts on the
UCI main model; the others are offered by /model and switch that chat only.

How: HERMES_OPENWRT_PROVIDERS carries the UCI `provider` sections, paths and names only,
as name|label|base_url|key_file|model separated by ';'. Each becomes an entry in upstream's
`providers` map whose key_env names HERMES_PROVIDER_<NAME>_KEY, the variable the exec
wrapper fills from key_file; that key_env shape is what marks an entry as this package's.
Names upstream already gives a built-in provider are refused, because upstream resolves
the built-in first and the chat would silently land somewhere else. The variable unset
leaves `providers` untouched; set and empty removes the entries this package wrote.
"""
from __future__ import annotations

import copy
import os
import re
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlsplit

# The three toolsets a non-root "assistant" profile must never receive. Fixed
# order: this is the order missing names are appended in, so the file is
# deterministic to read and to test.
GOVERNED = ("code_execution", "file", "terminal")

# What a profile tells the agent about itself. Without it a live Telegram bot asked for
# the router's uptime looped on the memory tool for 90 model calls before it gave up
# (2026-09-24). Each note is a delimited block, so a profile can take out exactly its own
# and nothing of the operator's own prompt.
def _markers(kind: str):
    return f"[hermes-openwrt: {kind} profile]", f"[/hermes-openwrt: {kind} profile]"


NOTE_KINDS = ("assistant", "owner")

ASSISTANT_NOTE = ("You run on an OpenWrt router in its assistant profile. You have no terminal, "
                  "code execution or file tools, so you cannot read or change this router yourself. "
                  "When you are asked about the router, say so at once instead of trying other tools, "
                  "and say that the owner can allow it by setting hermes.main.profile to owner or by "
                  "connecting an MCP server such as openwrt-mcp.")

OWNER_NOTE = ("You run on an OpenWrt router as an unprivileged user. You can read the router's "
              "state, interfaces and log through the openwrt tools without asking anyone. Change "
              "the router only through those tools, never by editing its files or running "
              "commands that reconfigure it. For network diagnostics (ping, traceroute, nslookup, "
              "ip, ifconfig) use your own terminal: they work there as your user. ")
OWNER_NOTE_LOCKED = ("A change is refused until the owner has unlocked it. When a tool answers that "
                     "a second factor is required, tell the owner to send /unlock in the private "
                     "chat with you, and try again once they say it is done. Never ask the owner "
                     "for a PIN or a code in a message, and never repeat one you were given. "
                     "The owner's PIN or code never reaches you: if one of their messages is "
                     "replaced by a notice that it was removed, the unlock is not something you "
                     "can see or finish. Answer what you were doing, then ask them to send "
                     "/unlock again in the private chat.")
OWNER_NOTE_NO_FACTOR = ("No second factor is set up on this router, so every change is refused. "
                        "When a change is refused, tell the owner that a factor has to be set up "
                        "in LuCI (Services -> Hermes Agent -> Security) first, and do not look for "
                        "another way to make the change. Never ask the owner for a PIN or a code "
                        "in a message.")

FACTORS = ("none", "pin", "totp", "pin+totp")


def _note_for(profile, factor: str):
    """The note a profile puts in agent.system_prompt, or None when it puts none."""
    if profile == "assistant":
        text = ASSISTANT_NOTE
    elif profile == "owner":
        text = OWNER_NOTE + (OWNER_NOTE_NO_FACTOR if factor == "none" else OWNER_NOTE_LOCKED)
    else:
        return None
    opening, closing = _markers(profile)
    return opening + "\n" + text + "\n" + closing


# Put between the operator's text and the note, and taken out with it, so the
# operator's text comes back exactly, whitespace around it included.
NOTE_SEP = "\n\n"


def _has_note(text: str) -> bool:
    return any(_markers(kind)[0] in text for kind in NOTE_KINDS)


def _without_note(text: str) -> str:
    """The operator's own text, exactly: everything but the notes and the separator
    put before each. Only called when a note is there."""
    for kind in NOTE_KINDS:
        opening, closing = _markers(kind)
        start = text.find(opening)
        if start == -1:
            continue
        end = text.find(closing, start)
        if end == -1:
            raise ValueError("agent.system_prompt holds an unterminated profile note")
        before, after = text[:start], text[end + len(closing):]
        if before.endswith(NOTE_SEP):
            before = before[:-len(NOTE_SEP)]
        text = before + after
    return text


def _validate_endpoint(value: str, label: str) -> None:
    parsed = urlsplit(value)
    if (parsed.scheme not in ("http", "https") or not parsed.hostname
            or parsed.username is not None or parsed.password is not None
            or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in value)):
        raise ValueError(f"{label} must be HTTP(S), without embedded credentials")
    # Also validate the port rather than persisting an unusable endpoint.
    _ = parsed.port


PROFILES = ("owner", "assistant", "root", "admin")

# The unlock plugin's name in plugins.enabled (its entry point's name, see build.sh).
UNLOCK_PLUGIN = "openwrt-unlock"
UNLOCK_MARKER = "_openwrt_unlock_managed"

# The tools of openwrt-mcp the model is never offered, in any profile. mfa_unlock and mfa_lock are
# how the OWNER proves who they are, and a model that could call them would be asking for a PIN.
# exec and wg_new_client are never granted to the agent's client (invariant 18), and a model that
# sees them reaches for them: on a Brume 2 on 2026-10-08 two models in a row pinged through exec,
# were refused, and reported ping as "blocked by policy" without trying their own terminal.
MCP_HIDDEN = ("mfa_unlock", "mfa_lock", "exec", "wg_new_client")
# What 0.21.5-r3 to r9 hid, so an entry those releases wrote, pasted back by hand, is still ours.
MCP_HIDDEN_R9 = ("mfa_unlock", "mfa_lock")

# Upstream's tools/tool_search.py defers every MCP tool behind a search tool by default
# (tools.tool_search.enabled "auto"), and on routers on 2026-10-08 the models never searched:
# they never saw openwrt-mcp's tools and looped on `uci` in the terminal, which as hermes fails
# with an I/O error. With "off" the same agent called mcp__openwrt__uci_apply. Written only where
# the operator has set nothing: an explicit enabled value, or the legacy bool, is theirs.
TOOL_SEARCH_OFF = "off"

# What marks a `providers` entry as written by this package rather than the operator.
KEY_ENV = re.compile(r"^HERMES_PROVIDER_[A-Z0-9_]+_KEY$")
PROVIDER_NAME = re.compile(r"^[a-z][a-z0-9-]{0,30}$")


# The main model's own entry in `providers`, written from the UCI endpoint. Its key_env
# is OPENAI_API_KEY, which is what marks it as this package's.
MAIN_PROVIDER = "uci"


def _main_entry(entry) -> bool:
    return isinstance(entry, dict) and entry.get("key_env") == "OPENAI_API_KEY"


def _key_env(name: str) -> str:
    return "HERMES_PROVIDER_" + name.upper().replace("-", "_") + "_KEY"


def _builtin_provider(name: str) -> bool:
    """Whether upstream has a provider of its own by exactly this name: it resolves that
    before any entry in `providers`, so a UCI section called that would never be reached.
    An alias (claude for anthropic, say) is not one: measured on a Brume 2 on 2026-09-25,
    an entry called claude resolved to itself, one called anthropic to the built-in."""
    from hermes_cli.auth import PROVIDER_REGISTRY
    from hermes_cli.models import _PROVIDER_MODELS
    return (name in ("custom", "auto", "openai", "openai-api", "openrouter")
            or name in PROVIDER_REGISTRY or name in _PROVIDER_MODELS)


def _uci_providers(raw: str) -> dict:
    wanted = {}
    for item in (part for part in raw.split(";") if part):
        fields = item.split("|")
        if len(fields) != 5:
            raise ValueError("a provider entry must read name|label|base_url|key_file|model")
        name, label, url, _key_file, model = fields
        if not PROVIDER_NAME.match(name):
            raise ValueError(f"provider name {name!r}: lower-case letters, digits and '-', starting with a letter")
        if name in wanted:
            raise ValueError(f"provider {name} is configured twice")
        if _builtin_provider(name):
            raise ValueError(f"provider name {name!r} is one upstream already uses; choose another")
        if name == "provider":
            raise ValueError("provider name 'provider' would share the main key's file; choose another")
        if name == MAIN_PROVIDER:
            raise ValueError(f"provider name {MAIN_PROVIDER!r} is the main model's own entry; choose another")
        _validate_endpoint(url, f"provider {name} base_url")
        for value, what in ((model, "model"), (label, "label")):
            if not value.strip() or any(ord(c) < 32 or ord(c) == 127 for c in value):
                raise ValueError(f"provider {name} {what} is empty or contains control characters")
        wanted[name] = {"name": label, "api": url, "key_env": _key_env(name),
                        "default_model": model, "models": [model]}
    return wanted


def main() -> int:
    if len(sys.argv) not in (3, 4, 6, 7):
        sys.stderr.write(
            "usage: set-toolsets.py <home> <comma,separated,tools> [mcp-url [base-url model [profile]]]\n")
        return 2
    home, raw = Path(sys.argv[1]), sys.argv[2]
    # profile only ever follows the full mcp-url/base-url/model form: both real
    # callers (the init and the exec wrapper) always pass all five before it, so
    # there is no shorter form in which a 4th or 5th argument could be mistaken
    # for a profile. Omitted entirely, agent.disabled_toolsets is left untouched,
    # which keeps every existing caller (and test) that predates profiles unchanged.
    profile = sys.argv[6] if len(sys.argv) == 7 else None
    if profile is not None and profile not in PROFILES:
        sys.stderr.write("hermes-config: profile must be 'owner', 'assistant' or 'root' "
                         f"('admin' is accepted for 'root'), not {profile!r}\n")
        return 2
    try:
        import yaml
        from toolsets import TOOLSETS, validate_toolset

        wanted = list(dict.fromkeys(t.strip() for t in raw.split(",") if t.strip()))
        if any(not validate_toolset(t) and t != "no_mcp" for t in wanted):
            raise ValueError("unknown toolset; check the configured tool names")
        path = home / "config.yaml"
        config = yaml.safe_load(path.read_text(encoding="utf-8")) if path.exists() else {}
        if config is None:
            config = {}
        if not isinstance(config, dict):
            raise TypeError("config.yaml must be a mapping")
        # Compared against at the end, by data rather than by rendered text, so a
        # human-added comment or a hand-typed quoting style is never destroyed by a
        # run that would not otherwise have changed anything.
        original = copy.deepcopy(config)
        platforms = config.setdefault("platform_toolsets", {})
        if not isinstance(platforms, dict):
            raise TypeError("platform_toolsets must be a mapping")
        known = config.get("known_plugin_toolsets") or {}
        if not isinstance(known, dict):
            raise TypeError("known_plugin_toolsets must be a mapping")
        for platform in ("telegram", "cron"):
            previous = platforms.get(platform, [])
            plugins = known.get(platform, []) or []
            if not isinstance(previous, list) or not isinstance(plugins, list):
                raise TypeError("platform selections must be lists")
            # Preserve explicit plugin/custom/MCP selections, including no_mcp.
            # Known-but-absent plugins stay disabled in upstream's resolver.
            extras = [name for name in previous if isinstance(name, str)
                      and (name not in TOOLSETS or name in plugins)]
            platforms[platform] = list(dict.fromkeys(wanted + extras))

        if len(sys.argv) >= 4:
            url = sys.argv[3]
            owned = config.get("_openwrt_mcp_managed") is True
            if url:
                _validate_endpoint(url, "MCP URL")
                servers = config.setdefault("mcp_servers", {})
                if not isinstance(servers, dict):
                    raise TypeError("mcp_servers must be a mapping")
                headers = {"Authorization": "Bearer ${OPENWRT_MCP_TOKEN}"}
                expected = {"url": url, "headers": headers, "tools": {"exclude": list(MCP_HIDDEN)}}
                # The entry as releases before the unlock wrote it, without the tools key.
                earlier = {"url": url, "headers": headers}
                # The entry as 0.21.5-r3 to r9 wrote it, hiding the unlock tools only.
                earlier_r9 = {"url": url, "headers": headers, "tools": {"exclude": list(MCP_HIDDEN_R9)}}
                # An operator may already have pasted in exactly this entry by hand,
                # e.g. from an earlier manual setup. Adopt it rather than refuse: only
                # a DIFFERENT entry is a real collision. The earlier shapes are ours too.
                if ("openwrt" in servers and not owned and servers["openwrt"] not in (expected, earlier)
                        and servers["openwrt"] != earlier_r9):
                    raise ValueError("mcp_servers.openwrt is operator-owned; rename it before enabling UCI MCP")
                servers["openwrt"] = expected
                config["_openwrt_mcp_managed"] = True
            elif owned:
                # Read-only here: an absent mcp_servers must not be created just to
                # immediately find there is nothing in it to remove.
                servers = config.get("mcp_servers")
                if isinstance(servers, dict):
                    servers.pop("openwrt", None)
                config.pop("_openwrt_mcp_managed", None)

        if len(sys.argv) in (6, 7):
            endpoint, model = sys.argv[4:6]
            _validate_endpoint(endpoint, "model endpoint")
            if not model.strip() or any(ord(c) < 32 for c in model):
                raise ValueError("model name is empty or contains control characters")
            model_config = config.get("model") or {}
            if isinstance(model_config, str):
                model_config = {"default": model_config}
            if not isinstance(model_config, dict):
                raise TypeError("model must be a mapping or model name")
            if model_config.get("api_key") not in (None, "", "${OPENAI_API_KEY}"):
                raise ValueError("model.api_key is operator-owned; move it before enabling the UCI model")
            # The main endpoint is a named entry, not upstream's bare `custom`: /model's
            # button for `custom` takes its key from the chat's earlier switch, which the
            # first switch has none of, and the next turn then built its agent keyless
            # (on openrouter.ai that fails outright). A named entry carries key_env, and
            # every path through /model reads the key from there.
            providers = config.get("providers")
            if providers is None:
                providers = {}
            if not isinstance(providers, dict):
                raise TypeError("providers must be a mapping")
            main_entry = {"name": f"Main ({urlsplit(endpoint).hostname})", "api": endpoint,
                          "key_env": "OPENAI_API_KEY", "default_model": model}
            previous = providers.get(MAIN_PROVIDER)
            if previous is not None and not _main_entry(previous):
                raise ValueError(f"providers.{MAIN_PROVIDER} is operator-owned; rename it before enabling the UCI model")
            config["providers"] = dict(providers, **{MAIN_PROVIDER: main_entry})
            model_config.update(default=model, provider=MAIN_PROVIDER, base_url=endpoint,
                                api_mode="chat_completions", api_key="${OPENAI_API_KEY}")
            config["model"] = model_config
            # OPENAI_API_KEY holds the main key for whatever endpoint UCI names, and
            # upstream takes its mere presence to mean the OpenAI API itself is signed
            # in: /model would offer "openai-api" and send this key to api.openai.com.
            catalog = config.get("model_catalog")
            if catalog is None:
                catalog = config["model_catalog"] = {}
            if not isinstance(catalog, dict):
                raise TypeError("model_catalog must be a mapping")
            excluded = catalog.get("excluded_providers")
            if excluded is None:
                excluded = []
            if not isinstance(excluded, list):
                raise TypeError("model_catalog.excluded_providers must be a list")
            if "openai-api" not in excluded:
                catalog["excluded_providers"] = list(excluded) + ["openai-api"]

        # Further providers, from the UCI `provider` sections: each chat starts on the
        # main model above and /model offers these beside it.
        raw_providers = os.environ.get("HERMES_OPENWRT_PROVIDERS")
        if raw_providers is not None:
            wanted = _uci_providers(raw_providers)
            providers = config.get("providers")
            if providers is None:
                providers = {}
            if not isinstance(providers, dict):
                raise TypeError("providers must be a mapping")
            providers = dict(providers)

            def ours(entry):
                return isinstance(entry, dict) and bool(KEY_ENV.match(str(entry.get("key_env") or "")))

            for name in list(providers):
                if ours(providers[name]) and name not in wanted:
                    del providers[name]
            for name, entry in wanted.items():
                if name in providers and not ours(providers[name]) and providers[name] != entry:
                    raise ValueError(f"providers.{name} is operator-owned; rename it or the UCI provider section")
                providers[name] = entry
            if providers:
                config["providers"] = providers
            else:
                config.pop("providers", None)

        # Profiles govern agent.disabled_toolsets, never platform_toolsets above:
        # see the module docstring for why (upstream subtracts it as a final,
        # always-applied step, so it holds regardless of what toolsets says).
        if profile == "assistant":
            # A key left with no value is null in YAML, and upstream reads null as
            # empty for both (`... or {}`, `... or []`), so this does too.
            if config.get("agent") is None:
                config["agent"] = {}
            agent_cfg = config["agent"]
            if not isinstance(agent_cfg, dict):
                raise ValueError("agent must be a mapping")
            disabled = agent_cfg.get("disabled_toolsets")
            if disabled is None:
                disabled = []
            if not isinstance(disabled, list) or not all(isinstance(t, str) for t in disabled):
                raise ValueError("agent.disabled_toolsets must be a list of strings")
            disabled = list(disabled)
            for name in GOVERNED:
                if name not in disabled:
                    disabled.append(name)
            agent_cfg["disabled_toolsets"] = disabled
        elif profile in ("owner", "root", "admin"):
            agent_cfg = config.get("agent")
            if agent_cfg is not None:
                if not isinstance(agent_cfg, dict):
                    raise ValueError("agent must be a mapping")
                disabled = agent_cfg.get("disabled_toolsets")
                if disabled is not None:
                    if not isinstance(disabled, list) or not all(isinstance(t, str) for t in disabled):
                        raise ValueError("agent.disabled_toolsets must be a list of strings")
                    kept = [name for name in disabled if name not in GOVERNED]
                    if kept:
                        agent_cfg["disabled_toolsets"] = kept
                    else:
                        # Consistent with the rest of this file: never leave a key
                        # behind that now holds nothing (see _openwrt_mcp_managed).
                        agent_cfg.pop("disabled_toolsets", None)

        # The unlock plugin, in the owner profile. Left alone when no profile was passed (the
        # callers that predate profiles), and taken out again by the others only when this
        # bridge put it there.
        if profile == "owner":
            plugins = config.get("plugins")
            if plugins is None:
                plugins = config["plugins"] = {}
            if not isinstance(plugins, dict):
                raise ValueError("plugins must be a mapping")
            listed = plugins.get("enabled")
            if listed is None:
                listed = []
            if not isinstance(listed, list) or not all(isinstance(n, str) for n in listed):
                raise ValueError("plugins.enabled must be a list of names")
            if UNLOCK_PLUGIN not in listed:
                plugins["enabled"] = list(listed) + [UNLOCK_PLUGIN]
            denied = plugins.get("disabled")
            if isinstance(denied, list) and UNLOCK_PLUGIN in denied:
                kept = [n for n in denied if n != UNLOCK_PLUGIN]
                if kept:
                    plugins["disabled"] = kept
                else:
                    plugins.pop("disabled", None)
            config[UNLOCK_MARKER] = True
        elif profile is not None and config.get(UNLOCK_MARKER) is True:
            plugins = config.get("plugins")
            if isinstance(plugins, dict) and isinstance(plugins.get("enabled"), list):
                remaining = [n for n in plugins["enabled"] if n != UNLOCK_PLUGIN]
                if remaining:
                    plugins["enabled"] = remaining
                else:
                    plugins.pop("enabled", None)
                if not plugins:
                    config.pop("plugins", None)
            config.pop(UNLOCK_MARKER, None)

        # The profile's note in agent.system_prompt: assistant's and owner's added, root's
        # (it has none) taking out whichever is there, the operator's own text kept either way.
        if profile is not None:
            factor = os.environ.get("HERMES_OPENWRT_FACTOR", "none")
            if factor not in FACTORS:
                raise ValueError("HERMES_OPENWRT_FACTOR must be none, pin, totp or pin+totp")
            note = _note_for(profile, factor)
            agent_cfg = config.get("agent")
            if agent_cfg is None and note:
                agent_cfg = config["agent"] = {}
            if agent_cfg is not None:
                if not isinstance(agent_cfg, dict):
                    raise ValueError("agent must be a mapping")
                current = agent_cfg.get("system_prompt")
                if current is not None and not isinstance(current, str):
                    raise ValueError("agent.system_prompt must be text")
                noted = bool(current) and _has_note(current)
                own = _without_note(current) if noted else (current or "")
                if note:
                    agent_cfg["system_prompt"] = (own + NOTE_SEP + note) if own else note
                elif noted and own:
                    agent_cfg["system_prompt"] = own
                elif noted:
                    agent_cfg.pop("system_prompt", None)

        # Upstream's tool search, off where the operator has set nothing (see TOOL_SEARCH_OFF),
        # in every profile, so the model sees openwrt-mcp's tools by name. Left alone when no
        # profile was passed, like the note and the plugin above.
        if profile is not None:
            tools_cfg = config.get("tools")
            if tools_cfg is None:
                tools_cfg = {}
            if not isinstance(tools_cfg, dict):
                raise ValueError("tools must be a mapping")
            search = tools_cfg.get("tool_search")
            if search is None:
                search = {}
            if isinstance(search, dict) and search.get("enabled") is None:
                tools_cfg["tool_search"] = dict(search, enabled=TOOL_SEARCH_OFF)
                config["tools"] = tools_cfg

        # The per-turn step budget, from UCI. Unset leaves whatever is there.
        turns = os.environ.get("HERMES_OPENWRT_MAX_TURNS")
        if turns is not None:
            if not turns.isdigit() or not 1 <= int(turns) <= 500:
                raise ValueError("max_turns must be a whole number from 1 to 500")
            if config.get("agent") is None:
                config["agent"] = {}
            if not isinstance(config["agent"], dict):
                raise ValueError("agent must be a mapping")
            config["agent"]["max_turns"] = int(turns)

        if path.exists() and config == original:
            return 0
        home.mkdir(parents=True, exist_ok=True)
        rendered = yaml.safe_dump(config, default_flow_style=False, sort_keys=False, allow_unicode=True)
        # A unique 0600 temporary file avoids following an old .yaml.tmp symlink.
        temp = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", dir=home, prefix=".config-", delete=False,
                                             encoding="utf-8") as stream:
                temp = Path(stream.name)
                stream.write(rendered)
                stream.flush()
                # Run as root over a directory that belongs to the agent (a person at a
                # shell may; the wrapper and the init do not, they run this as the agent),
                # the file goes to the directory's owner, not to root: a root-owned
                # config.yaml is one the gateway cannot update.
                if os.geteuid() == 0:
                    owner = home.stat()
                    os.fchown(stream.fileno(), owner.st_uid, owner.st_gid)
                os.fsync(stream.fileno())
            temp.replace(path)
        finally:
            if temp is not None and temp.exists():
                temp.unlink()
    except Exception as exc:  # noqa: BLE001 - fail closed without leaking YAML snippets
        # Do not log YAML exception snippets, which may contain operator secrets.
        message = str(exc) if isinstance(exc, ValueError) else type(exc).__name__
        sys.stderr.write(f"hermes-config: configuration refused ({message}); existing file preserved\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
