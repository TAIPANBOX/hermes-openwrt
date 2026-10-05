# Before you install, and removing it

## Before you test

- **The router.** Vanilla OpenWrt 25.12, not a vendor firmware, on an aarch64 router:
  `cat /etc/apk/arch` has to print `aarch64_cortex-a53` or `aarch64_generic`. Nothing else
  is built. The package is tested on a Flint 2 and a Brume 2, and on a Beryl AX for the case
  of 512 MB and little flash.
- **Memory.** 1 GB of RAM; on 512 MB one conversation at a time fits, with little to spare (see
  [Hermes on a USB stick](usb.md#hermes-on-a-usb-stick)). The gateway alone holds about 200 MB before it does any work
  (179 MB on 2026-09-25 with agent r1; 202 to 203 MB on 2026-10-04 with r5 in the owner
  profile and openwrt-mcp connected; what the difference is made of is not measured).
- **Flash.** About 350 MB for the packages and the Python they bring, then the data
  directory: 37 MB at the first start, growing from there. The data directory can live on a
  USB stick, and on a router with too little flash the packages too
  (see [Hermes on a USB stick](usb.md#hermes-on-a-usb-stick)).
- **A model.** A key for an OpenAI-compatible provider, a free one included: the service
  does not start without one. A ChatGPT subscription can be added beside it and picked
  with `/model`, not used instead of it (see [More than one provider](providers.md#more-than-one-provider)).
- **A way back.** Keep a backup off the router (`sysupgrade -b /tmp/backup.tar.gz`, then
  copy it away) and know how your router's recovery mode works before you start. On
  2026-10-02 a Brume 2 under test did not come back from a reboot that followed an
  unconfirmed change: no link on any port, and two power cycles did not help. It came back
  only by flashing the vendor firmware through its U-Boot recovery page, which refused the
  OpenWrt image, and then OpenWrt again from the vendor firmware; the reflash lost the logs.
  Repeating the sequence did not reproduce it, neither in an emulated OpenWrt nor on that
  router with the next build, so the cause is not known. On 2026-10-04 the same sequence on
  that router, on the published release, came back in 33 s with the change rolled back.
  Keep your router's vendor firmware image at hand all the same.

## Removing it

If Hermes's data is on a USB stick (`hermes-usb status` says so), bring it inside first with
`hermes-usb back`, or give a lost stick up with `hermes-usb forget --yes`; otherwise the
fstab keeps mounting the stick, and a later `rm -rf` of the data directory would empty the
stick.

```sh
/etc/init.d/hermes-agent stop
apk del luci-app-hermes hermes-agent-telegram hermes-agent openwrt-mcp
```

That removes the programs and the Python they brought. What stays is what the package made
at install and what changed while it ran: the data directory, the keys in
`/etc/hermes-agent`, `/etc/config/hermes` and `/etc/config/openwrt-mcp` once either was
changed (the owner profile rewrites the second at every start), openwrt-mcp's state in
`/etc/openwrt-mcp`, the feed's key and line, and the `hermes` account. To take all of it
away:

```sh
d=$(uci -q get hermes.main.data_dir); rm -rf "${d:-/srv/hermes}"
rm -rf /etc/hermes-agent /etc/openwrt-mcp
rm -f /etc/config/hermes /etc/config/openwrt-mcp /etc/apk/keys/hermes-openwrt.pem
sed -i '/taipanbox.github.io\/hermes-openwrt/d' /etc/apk/repositories.d/customfeeds.list
sed -i '/^hermes:/d' /etc/passwd /etc/shadow /etc/group
/etc/init.d/rpcd restart
```

If you used openwrt-mcp before this package, keep `/etc/openwrt-mcp` and its config: they
hold your other clients' pairings. The account is kept by `apk del` on purpose, so files it
owned never pass to an account created later with the same id; remove it only once its data
directory is gone, as above.
