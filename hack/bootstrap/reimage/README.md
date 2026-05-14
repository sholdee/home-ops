# Raspberry Pi Network Reimage Payload

`node-reimage-stage` expects a local payload directory containing:

- `initramfs.img`: a bootable Raspberry Pi initramfs that reads
  `/boot/firmware/home-ops-reimage/manifest.json`, verifies the target disk,
  downloads `imageUrl`, verifies `imageSha256`, writes the image to the target
  disk, syncs, and reboots.
- `cmdline.txt`: the kernel command line for that initramfs.

The payload is intentionally not committed here. It is node-destructive boot
code and should be built and tested with a real image before being promoted.

Raspberry Pi firmware loads `tryboot.txt` instead of `config.txt` only when the
node is rebooted with `reboot '0 tryboot'`; the flag is one-shot, so a crash
before rewriting the disk falls back to the normal boot path on the next boot.
