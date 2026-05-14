# Raspberry Pi Network Reimage

`node-reimage-image-source` renders the per-node `rpi-image-gen` source tree
for the replacement OS image. It uses inventory for hostname, Ansible user,
static IP, and the SSH public key derived from the inventory private key, and
renders a small first-boot layer for systemd-networkd, passwordless sudo, SSH,
Raspberry Pi boot defaults, and basic packages.

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

## Verified Flow

This flow was live-tested on `k3s-worker-0` on May 14, 2026. The node was
drained, Longhorn-evacuated, deleted from Kubernetes, reimaged over the
network to Raspberry Pi OS Trixie, SSH host-key refreshed, and then prepared
again with `just ansible-host-services k3s-worker-0`.

The verified image was hosted from `k3s-master-0` so the worker could fetch it
on the cluster VLAN:

```sh
image_url=http://192.168.99.10:18080/home-ops-k3s-worker-0.img.xz
image_sha=3145bac1147525a500a545245f57fe72f55731e9f7a037ae62bd687595c4acbb
```

The server log showed the full image fetch:

```text
"GET /home-ops-k3s-worker-0.img.xz HTTP/1.1" 200 -
```

Post-boot checks confirmed the fresh OS and expanded root filesystem:

```text
Debian 13 Trixie
/dev/disk/by-slot/system mounted as /
/var/lib/home-ops/firstboot-complete present
```

## Build The Image

Render the per-node source tree from inventory:

```sh
just node-reimage-image-source k3s-worker-0
```

Build from a checked-out `rpi-image-gen` repository. The generated source
README under `hack/bootstrap/.out/reimage/live/<node>/source/` contains the
exact command:

```sh
./rpi-image-gen build \
  -S /Users/ethan.shold/git/home-ops/hack/bootstrap/.out/reimage/live/k3s-worker-0/source \
  -c home-ops-node.yaml
```

Copy the resulting compressed image back under `.out/reimage/live/<node>/` and
compute its checksum:

```sh
sha256sum hack/bootstrap/.out/reimage/live/k3s-worker-0/home-ops-k3s-worker-0.img.xz
```

The image first boot layer expands the root filesystem, disables
`dphys-swapfile`, refreshes the generated initramfs with
`update-initramfs -u -k all`, and writes
`/var/lib/home-ops/firstboot-complete`. The Ansible node-prep phase waits for
that marker before installing packages so a newly imaged node fails early if
root growth did not complete.

## Host The Image

The node must be able to reach the image URL from the initramfs network path.
The successful proof hosted the image from an existing cluster node:

```sh
just node-cmd k3s-master-0 'mkdir -p /tmp/home-ops-reimage'
```

Copy the image to the host by SSH or `scp`, then run a simple HTTP server on
the cluster-facing address:

```sh
scp -i ~/ansiblekey \
  hack/bootstrap/.out/reimage/live/k3s-worker-0/home-ops-k3s-worker-0.img.xz \
  ethan@192.168.99.10:/tmp/home-ops-reimage/

just node-cmd k3s-master-0 \
  'nohup sh -c "cd /tmp/home-ops-reimage && exec python3 -m http.server 18080 --bind 192.168.99.10" >/tmp/home-ops-reimage/http.log 2>&1 & echo $! >/tmp/home-ops-reimage/http.pid'
```

Keep the server running until the reimaging node has fetched the full image.
Afterward, remove the temporary hosting directory:

```sh
just node-cmd k3s-master-0 \
  'if [ -f /tmp/home-ops-reimage/http.pid ]; then kill "$(cat /tmp/home-ops-reimage/http.pid)" || true; fi; rm -rf /tmp/home-ops-reimage'
```

## Stage And Reboot

Render the metadata sidecar for the exact image URL and checksum:

```sh
just node-reimage-metadata k3s-worker-0 "$image_url" "$image_sha" \
  > hack/bootstrap/.out/reimage/live/k3s-worker-0/home-ops-k3s-worker-0.img.xz.metadata.json
```

Run the normal node replacement gates first:

```sh
just node-status k3s-worker-0
just node-drain k3s-worker-0
just node-longhorn-evict k3s-worker-0
just node-delete k3s-worker-0
```

Stage the payload only after the Kubernetes Node is deleted:

```sh
just node-reimage-stage k3s-worker-0 "$image_url" "$image_sha" \
  --metadata-file hack/bootstrap/.out/reimage/live/k3s-worker-0/home-ops-k3s-worker-0.img.xz.metadata.json
```

Reboot into one-shot tryboot mode:

```sh
just node-reimage-reboot k3s-worker-0
```

Watch the image server log for a full `GET`, then wait for the node to reboot
into the fresh image. Ping can return before SSH is ready.

## Join After Reimage

The fresh image changes the host key. Refresh it before running Ansible:

```sh
just node-refresh-ssh-host-key k3s-worker-0
```

Then join and finalize as usual:

```sh
just node-join k3s-worker-0
just node-uncordon k3s-worker-0
just node-status k3s-worker-0
```

Host services can also be run directly while proving the fresh OS:

```sh
just ansible-host-services k3s-worker-0
```

`node-join` and `node-uncordon` intentionally do not fail the Kubernetes node
replacement path on optional host-service setup. Run host services separately
after the node is schedulable when you want the reporter or Actions runner
installed.

## Implementation Notes

Staging builds from the target node's installed Raspberry Pi initramfs with
`unmkinitramfs`, then injects the reimage hook and repacks it. This matters on
Trixie because the generated image's initial `initramfs_2712` was not a full
bootable initramfs until `update-initramfs -u -k all` ran.

If `unmkinitramfs` extracts the real root under `main/`, staging repacks from
that root and fails closed if any other top-level extraction path contains
files. That keeps the payload tied to the initramfs shape we have verified
instead of silently dropping early boot content.

The staged `tryboot.txt` intentionally includes the normal firmware config:

```ini
[all]
include config.txt
[all]
initramfs home-ops-reimage/initramfs.img followkernel
cmdline=home-ops-reimage/cmdline.txt
```

The reimage hook is self-contained and does not source `/scripts/functions`.
That keeps it independent of initramfs-tools helper availability and limits the
runtime contract to the explicit commands checked during staging.

The runtime supports `.xz`, `.gz`, `.zst`, and uncompressed image artifacts.
It verifies the Raspberry Pi serial, target disk serial, metadata, and SHA256
before writing to disk.
