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

This flow was live-tested on `k3s-worker-1` on May 14, 2026. The node was
drained, Longhorn-evacuated, deleted from Kubernetes, reimaged over the
network to Raspberry Pi OS Trixie, joined back to the cluster, uncordoned, and
cleaned up with `node-reimage-cleanup`.

The verified image was built with `node-reimage-build`, hosted from
`k3s-master-0` with `node-reimage-serve`, and fetched by the staged initramfs
from the cluster VLAN.

The server log showed the full image fetch:

```text
"GET /home-ops-k3s-worker-1.img.zst HTTP/1.1" 200 -
```

Post-boot checks confirmed the fresh OS and expanded root filesystem:

```text
Debian 13 Trixie
/dev/disk/by-slot/system mounted as /
/var/lib/home-ops/firstboot-complete present
```

## Build The Image

For the proven rolling replacement path, use the full orchestrator:

```sh
just node-reimage-full k3s-worker-0
just node-uncordon k3s-worker-0
```

`node-reimage-full` runs the safety preflights, builds before node downtime,
selects a healthy serve host automatically, verifies target-to-server
reachability, drains, evicts Longhorn, deletes the Kubernetes Node, applies the
network reimage, rejoins the node, runs host services, and cleans up the image
server. It leaves final uncordon to the operator.

The remaining commands are the primitive flow for debugging or manual
resumption.

Build the image with the orchestrated builder:

```sh
just node-reimage-build k3s-worker-0
```

This renders the per-node source tree, runs `rpi-image-gen`, copies the image
artifact to `hack/bootstrap/.out/reimage/live/<node>/`, computes its SHA256,
and records `state/build.json`.

On macOS the build runs in the persistent `home-ops-rpi-image-builder` Lima VM.
That matches the verified path and avoids pretending `rpi-image-gen` is a
native macOS tool. On Linux, `--builder-mode local` can run the checked-out
`../rpi-image-gen` directly. Override the checkout with `RPI_IMAGE_GEN_DIR` or
`--rpi-image-gen-dir`.

The image first boot layer expands the root filesystem, disables
`dphys-swapfile`, refreshes the generated initramfs with
`update-initramfs -u -k all`, and writes
`/var/lib/home-ops/firstboot-complete`. The Ansible node-prep phase waits for
that marker before installing packages so a newly imaged node fails early if
root growth did not complete.

## Host The Image

The node must be able to reach the image URL from the initramfs network path.
Host the recorded artifact from an explicit healthy inventory node:

```sh
just node-reimage-serve k3s-worker-0 k3s-master-0
```

This copies the image and metadata to
`/tmp/home-ops-reimage/<node>/` on the host, starts `python3 -m http.server`,
and records URL/SHA/remote paths in `state/serve.json`.

## Stage And Reboot

Run the normal node replacement gates first:

```sh
just node-status k3s-worker-0
just node-drain k3s-worker-0
just node-longhorn-evict k3s-worker-0
just node-delete k3s-worker-0
```

Apply the recorded reimage only after the Kubernetes Node is deleted:

```sh
just node-reimage-apply k3s-worker-0
```

`node-reimage-apply` calls the existing stage and reboot primitives, waits for
SSH to go down and return, refreshes the host key, and waits for
`/var/lib/home-ops/firstboot-complete`. Ping can return before SSH is ready,
and SSH can return before firstboot has finished.
Between SSH going down and returning, it also logs best-effort ping
transitions: initial reboot into tryboot, initramfs image application, and final
reboot into the new OS. These ping logs are operator progress hints only; the
success gates remain SSH authentication and the firstboot marker.

Keep the image server running until the reimaging node has fetched the full
image. The server log is recorded in `state/serve.json`.

The lower-level primitives still exist for debugging:

```sh
just node-reimage-metadata k3s-worker-0 "$image_url" "$image_sha"
just node-reimage-stage k3s-worker-0 "$image_url" "$image_sha" --metadata-file <metadata.json>
just node-reimage-reboot k3s-worker-0
```

## Join And Cleanup

Join and finalize as usual:

```sh
just node-join k3s-worker-0
just node-uncordon k3s-worker-0
just node-status k3s-worker-0
```

Then stop the image server and remove the remote temporary directory:

```sh
just node-reimage-cleanup k3s-worker-0
```

Host services can also be run directly while proving the fresh OS:

```sh
just ansible-host-services k3s-worker-0
```

`node-join` and `node-uncordon` intentionally do not fail the Kubernetes node
replacement path on optional host-service setup. Run host services separately
after the node is schedulable when you want the reporter or Actions runner
installed.

Network reimage destroys `local-path` data that existed on the old OS. If a
replicated controller leaves a pod bound to a stale local-path PVC, verify the
instance is non-primary and the cluster has healthy peers before deleting only
that failed pod/PVC. In the verified run, CNPG rebuilt the affected Grafana
replica as a new instance after the stale local-path PVC was removed.

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
