# Raspberry Pi Network Reimage Payload

`node-reimage-stage` builds the destructive reimage payload on the target node
by default. It unpacks the node's current Raspberry Pi initramfs, injects a
small `scripts/local-top/home-ops-reimage` hook plus manifest/env files, then
writes the staged initramfs and cmdline under
`/boot/firmware/home-ops-reimage`.

The staged hook verifies the Pi serial and target disk serial, configures the
same IPv4 network path the node is already using, downloads `imageUrl`, verifies
`imageSha256`, writes the image to the target disk, syncs, and reboots.

The optional `--payload-dir` escape hatch can still provide a local
`initramfs.img` and `cmdline.txt` pair, but the normal path is remote payload
construction from the target's known-good kernel/initramfs.

Raspberry Pi firmware loads `tryboot.txt` instead of `config.txt` only when the
node is rebooted with `reboot '0 tryboot'`; the flag is one-shot, so a crash
before rewriting the disk falls back to the normal boot path on the next boot.
