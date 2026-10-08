# How it is built

## The fact everything here rests on

One thing had to be measured rather than assumed, because it decides between a native
package and a 950 MB container image:

> **pip on OpenWrt resolves musllinux wheels, and every wheel Hermes needs exists.**

On `openwrt/rootfs:aarch64_generic-25.12.4`, `pip debug --verbose` reports
`cp313-cp313-musllinux_1_2_aarch64` as its top tag. A `pydantic-core` wheel, which is
compiled Rust, installs and imports and validates. For Hermes 0.21.5 the router profile
is 77 packages in under 30 seconds with nothing compiled and no toolchain present.

So Hermes does not need to be built for OpenWrt. It needs to be assembled for it, and
that is what this repository does.

### Which Hermes, and from where

The package carries **Hermes 0.21.5** (upstream tag `v2026.9.24`). PyPI stops at 0.19.0,
and upstream's own `setup.py` now refuses to build a wheel anywhere but inside its Nix
build, so the package is built the way that Nix build does it:

- from the archive of one pinned upstream commit, whose checksum is checked before a byte
  is unpacked (`package/upstream/upstream.env`);
- every library at the version upstream's `uv.lock` names at that commit, not whatever
  PyPI serves that day;
- skills, optional skills, translations and the MCP catalogue beside the wheel, under
  `/usr/share/hermes-agent`, found through the same `HERMES_BUNDLED_*` variables upstream's
  Nix wrapper sets.

Two upstream dependencies are left out, about 49 MB of an unpacked 278 MB: NVIDIA's Relay
runtime (`nemo-relay`), for which upstream falls back to a no-op host, and the HEIC/AVIF
image decoder (`pillow-heif`), which upstream imports only if it is there. Everything else
upstream depends on ships. The router records what it carries in
`/usr/lib/hermes-agent/upstream`, and `gate-upstream.sh` checks all of it.

## The signed feed

The index (`packages.adb`) and every package in it are signed with an EC prime256v1 key
through `apk adbsign`; the router trusts it through `/etc/apk/keys/hermes-openwrt.pem`.
An untrusted feed is refused in silence: apk drops the repository, so the package merely
appears not to exist.

**Signing happens on a workstation, not in CI.** A key held as a repository secret is
readable by anyone who can push a workflow to the default branch, and this one cannot be
revoked: a router that has trusted the public half keeps trusting anything signed with the
private half until a person logs in and deletes the file. So CI builds and gates, and
`scripts/publish-feed.sh` signs and publishes from the machine where the key lives.

## How a package is built

![Upstream, built inside the target release, one shim, packaged, signed locally](build.svg)

```sh
# 25.12, Python 3.13. EXTRA_ARCHES relabels the same tree for the Flint 2 and Brume 2.
EXTRA_ARCHES=aarch64_cortex-a53 ./package/hermes-agent/build-in-container.sh aarch64_generic
```

Docker is required; the OpenWrt SDK is not. The build runs **inside** the OpenWrt release
it targets, so the libc resolving the wheels is the one the router has. Cross-downloading
with `pip --platform` looks simpler and does not work: `pydantic-core` ships stable-ABI
wheels tagged `cp39-abi3`, and pinning `--implementation cp --python-version 3.13` narrows
the tag set until pip reports no matching distribution for a wheel that plainly exists.
`build.sh` refuses to run on a glibc interpreter rather than produce a package that would
only fail on the device.

### The one shim

OpenWrt splits the standard library into packages and ships no `webbrowser` at all, the
same way it ships no `tkinter`. Without it the gateway does not start and the ChatGPT sign-in
cannot load (until 0.21.5 the CLI could not even print its own version; it now imports the
module lazily, so `hermes --version` alone no longer shows the gap). The shim
implements the real contract rather than a stub: `open()` returns `False`, which is the
honest answer on a machine with no screen and the one upstream's own headless path
expects, and the URL is logged so a pairing step is still completable by hand.

Everything else Hermes needs is already packaged by OpenWrt: sqlite3, ssl, ctypes,
asyncio, multiprocessing, email, http, xml, decimal, curses, readline.

## Status

- [x] Native package for OpenWrt 25.12 (apk); 24.10 was served until 2026-09-25 and is not any more
- [x] Hermes 0.21.5 from a pinned upstream commit, libraries at upstream's locked versions
- [x] `aarch64_cortex-a53` for the Flint 2 and Brume 2, plus `aarch64_generic`
- [x] LuCI interface with write-only key handling
- [x] Signed feed, signed on a workstation
- [x] Every gate runs on OpenWrt's own rootfs images in CI
- [x] **Run on real hardware.** Two GL.iNet routers on vanilla OpenWrt 25.12.5; see the figures above
- [x] **Service controls on real procd**: bounded respawn, the memory ceiling and its removal, UCI back in place after a crash (Flint 2 and Brume 2, 25.12.5)
- [x] **A full agent turn on a router**, model calling a tool and answering from what it read
- [x] **Measured under load** on 0.21.5: concurrent conversations, thermals, throughput through the router
- [x] **The feed installs on hardware** with its signature verified and no `--allow-untrusted`
- [x] Telegram, as a two-distribution add-on package
- [x] Three profiles, owner by default, assistant and root by choice; `admin` accepted as root
- [x] The agent runs as an unprivileged user, `hermes`, unless the profile says root
- [x] The owner profile reads the router through openwrt-mcp and changes it only through it, refused until a second factor is set and unlocked (stage 3 of 5: the policies, the factor's settings, the refusals, per-agent unlock and the rollback)
- [x] The unlock from Telegram: `/unlock` and `/lock`, the message deleted and kept from the model, the logs and the conversation, a scheduled job refused (stage 4 of 5, 0.21.5-r4)
- [x] The LuCI Security page that sets a PIN and adds a phone by QR code, and the SSH enrolment that prints the QR code in the terminal (stage 5 of 5, LuCI r13)
- [x] A router with no `/srv` starts the agent, and the agent is told when the owner has unlocked changes (0.21.5-r5, from what a QEMU OpenWrt and a Brume 2 showed on 2026-10-02)
- [x] A per-turn limit on model calls, set on the router
- [x] Several providers at once, each chat on the one it picks, a ChatGPT subscription included
- [x] Upstream's native Anthropic provider
- [x] A Providers page: further providers with write-only keys, ChatGPT sign-in and sign-out
- [x] Hermes's data on a USB stick with one command, `hermes-usb` (0.21.5-r6), and no start without the stick; extroot measured on a Beryl AX and a Brume 2
- [x] A daily check opens an issue when upstream tags a release newer than the pinned one (`scripts/upstream-watch.sh`); moving to it stays a reviewed change, built, gated and run on both routers first
- [x] An upgrade leaves the service's start at boot as the owner set it; only an install switches it on (0.21.5-r7)
- [x] An endpoint on the LAN starts: the wrapper exports `CUSTOM_BASE_URL` equal to the endpoint in UCI (0.21.5-r8)
- [x] The agent can ping as its own user: the package depends on iputils-ping, BusyBox's ping needing root (0.21.5-r9)
- [x] `hermes` run from a shell never pip-installs, as the gateway never did (0.21.5-r9)

## Prior art, and what is not ours

[`Dedrimer/hermes-openwrt`](https://github.com/Dedrimer/hermes-openwrt) is an independent
native port that arrived at the same `webbrowser` shim from the same wall. It carries no
licence file, so no code from it is used here; the overlap is two people meeting the same
constraint.

[`GlassOnTin/openwrt-mcp`](https://github.com/GlassOnTin/openwrt-mcp) is the router-side
MCP server this pairs with, and its apk packaging for OpenWrt 25.12 came from
[a pull request out of this work](https://github.com/GlassOnTin/openwrt-mcp/pull/1).

Hermes Agent is Nous Research's and is MIT licensed. This repository is not affiliated
with them; the packaging is what is new here, and it is MIT too.
