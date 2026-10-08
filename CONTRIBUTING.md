# Contributing

Pull requests are welcome: a fix, a router we have not tried, a provider, a better page.
This file says how to build what CI builds, which checks cover which part, and what a
pull request is held to before it is merged.

A security problem goes through [SECURITY.md](SECURITY.md), not a pull request or an issue.

## The flow

1. Fork the repository and branch from `main`.
2. Make the change, with its scenario and its check (see [What a pull request is held to](#what-a-pull-request-is-held-to)).
3. Run the checks that cover it locally, then open a pull request against `main`.
4. CI runs on the pull request, on GitHub's arm64 runners. The slowest leg takes about half
   an hour. Every check listed on `main`'s branch protection must be green before a merge.
5. A maintainer reviews and merges. A merged change reaches routers only when the feed is
   next published (see [Releases](#releases)).

## Building locally

You need Docker on an aarch64 host: an Apple silicon Mac or an arm64 Linux machine. The
OpenWrt SDK is not needed. On an x86 host the same commands run under QEMU and are very slow.

These are the commands CI runs, in its order:

```sh
# the agent, also relabelled for the Flint 2, Brume 2 and Beryl AX (aarch64_cortex-a53)
EXTRA_ARCHES=aarch64_cortex-a53 ./package/hermes-agent/build-in-container.sh aarch64_generic

# the Telegram add-on; it refuses to build before the base tree exists
./package/hermes-agent-telegram/build-in-container.sh aarch64_generic

# the LuCI app
./package/luci-app-hermes/build.sh

# openwrt-mcp, which hermes-agent depends on, from the commit CI pins
git clone https://github.com/TAIPANBOX/openwrt-mcp openwrt-mcp-src
git -C openwrt-mcp-src checkout fb25c7d95113c5d080ba152ca30bbdfb3560851f
OPENWRT_MCP_SRC="$PWD/openwrt-mcp-src" ./scripts/build-openwrt-mcp.sh aarch64_generic
```

The last one needs Go at the version in `openwrt-mcp-src/go.mod`. The pinned commit is the
one in `.github/workflows/ci.yml`; if they ever differ, the workflow is right.

## Which checks cover what

Every gate installs the built packages into OpenWrt's own published rootfs and asks the
running system. Run them with `ARCH=aarch64_generic`, after the builds above.

| You changed | Run |
|---|---|
| the package, its init script or its install and removal | `./scripts/gate-package.sh` and `./scripts/teeth.sh` |
| the gateway wrapper, UCI handling, providers, profiles, MCP | `./scripts/gate-runtime.sh` (it ends with its mutation tests, `teeth-runtime.py`) |
| the LuCI app | `./scripts/gate-luci.sh` and `./scripts/teeth-luci.sh` |
| the owner unlock, the second factor, Telegram `/unlock` | `./scripts/gate-unlock.sh` and `./scripts/teeth-unlock.sh` |
| `hermes-usb` or anything about the stick | `./scripts/gate-usb.sh` and `./scripts/teeth-usb.sh` |
| the Telegram add-on | `./scripts/gate-telegram.sh` and `./scripts/teeth-telegram.sh` |
| the upstream pin or its libraries | `./scripts/gate-upstream.sh` and `./scripts/teeth-upstream.sh` |
| file ownership in a package | `./scripts/gate-apk-owner.sh` and `./scripts/teeth-apk-owner.sh` |
| anything, docs included | `./scripts/gate-scenarios-bound.sh` and `./scripts/gate-named-routers.sh` |

The teeth scripts plant faults in the product and require the matching check to catch each
one. The long ones take a shard, as CI runs them: `SHARD=0/4 ./scripts/teeth-usb.sh`.
[What is checked, and how](README.md#what-is-checked-and-how) describes every gate.

## What a pull request is held to

1. **New behaviour has a scenario.** It goes in `features/*.feature`, in plain words, and
   names the check that proves it. `gate-scenarios-bound.sh` fails on a scenario without a
   check and on a check without a scenario.
2. **A new check fails first.** Run it against the code before your change and put the
   command and the failure in the pull request. A check that has never failed proves nothing.
3. **A new check has teeth.** Add a fault to the matching teeth script that only your check
   catches.
4. **The invariants stay true.** [CLAUDE.md](CLAUDE.md) lists them, each with the gate that
   holds it. A change that alters one updates its text and its gate in the same pull request.
5. **No secret goes anywhere it can be read.** Keys and tokens stay out of tests, logs,
   command lines, UCI and procd's service table. Use synthetic ones in tests.
6. **The scope stays.** OpenWrt 25.12, apk, ARM. The repository names only the routers it is
   tested on, the Flint 2, Brume 2 and Beryl AX, and `gate-named-routers.sh` enforces it;
   results from another router are welcome in an issue, described by its architecture.

A pull request that only changes documentation needs rule 6 and the two checks in the last
row of the table.

## If you ran it on a router

Say which router, `cat /etc/apk/arch`, `cat /etc/openwrt_release`, the package versions
(`apk list --installed | grep -E 'hermes|openwrt-mcp'`) and what you ran. Before pasting a
log, look for keys and tokens in it. The [test report template](https://github.com/TAIPANBOX/hermes-openwrt/issues/new/choose)
asks for the same.

## Releases

CI builds and gates, and never signs. The feed is signed with a key that lives on a
maintainer's workstation and published from there with `scripts/publish-feed.sh`, because
a router that trusts the key keeps trusting anything it signs (see
[The signed feed](README.md#the-signed-feed)). A merged pull request therefore reaches
routers with the next published package revision, not at the moment it is merged.

## License

The repository is under the [MIT License](LICENSE). A contribution is accepted under the
same license.
