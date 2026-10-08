# Security

This package puts an agent on a router and, in the owner profile, lets it change that
router after the owner unlocks it. A flaw in that path matters more than most bugs, so
please report it privately.

## Reporting a vulnerability

Use GitHub's private report:
[Report a vulnerability](https://github.com/TAIPANBOX/hermes-openwrt/security/advisories/new).
Do not open a public issue for it.

Please include:

- what you did and what happened, with the commands, so it can be reproduced;
- the router's architecture (`cat /etc/apk/arch`) and OpenWrt version (`cat /etc/openwrt_release`);
- the package versions: `apk list --installed | grep -E 'hermes|openwrt-mcp'`;
- the profile (`uci get hermes.main.profile`) and, for anything about unlocking, the factor
  (`uci get hermes.security.factor`).

Never send a real key, token, PIN or authenticator secret. A synthetic one shows the
problem just as well.

A fix ships as a new package revision in the signed feed, and the advisory is published
once routers can upgrade to it.

## In scope

- the packages this repository builds: `hermes-agent`, `hermes-agent-telegram`,
  `luci-app-hermes`, and the `openwrt-mcp` build the feed carries;
- the feed and its signature;
- anything that lets the agent, a chat or a scheduled job change the router without the
  owner's unlock, reach a key, PIN or secret, or run as root outside the root profile.

## Not a vulnerability here

The README names the limits that are known and not fixed. Among them: a process running as
`hermes` can read the gateway's environment, where the keys are; openwrt-mcp's list of settings that run code
is a list, so a package it does not know can still be configured from an open window; LuCI over plain HTTP carries the PIN and the QR unencrypted. A way
past one of those that the README does not describe is still worth reporting.

A flaw in Hermes Agent itself belongs upstream, at
[NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent/security).
