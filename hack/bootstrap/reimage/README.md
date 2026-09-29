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
network reimage, rejoins the node, labels it with the current system-upgrade
Plan hash, runs host services, and cleans up the image server. It leaves final
uncordon to the operator.

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

Image builds require a kernel build that matches the committed kernel inputs;
see Custom Kernel below. `node-reimage-full` also verifies the kernel build on
the joined node and labels it `node.home-ops.sh/kernel-build=<build-id>`.

## Custom Kernel

Node images run a rebuild of the Raspberry Pi OS kernel with kernel BTF, pressure
stall information enabled by default, a built-in `/proc/config.gz`, and uprobe
and fprobe tracing. Cilium 1.20.2 and later need kernel BTF, which the stock
Raspberry Pi kernel does not provide (cilium/cilium#48778).

The inputs are committed under `hack/bootstrap/nodes/kernel/`:

- `source.yaml` pins the Raspberry Pi OS `linux` source package: version, file
  hashes, and the `buildSuffix` added to the package version.
- `config.2712.delta` holds the kernel config lines added to the Raspberry Pi 5
  flavour. The build fails if any line does not survive `oldconfig` verbatim.

Refresh the pin to the archive's current kernel source. The script verifies the
archive `InRelease` signature with rpi-image-gen's keyring, and that the signed
release is for the `trixie` suite, before trusting any hash:

```sh
just node-kernel-source-lock
```

Build the packages in the Lima image builder (roughly 15 minutes on an Apple
Silicon Mac):

```sh
just node-kernel-build
```

The build rebuilds only the `rpi-2712` flavour, keeps the stock package names
and `uname -r`, and records the four packages under
`hack/bootstrap/.out/kernel/<build-id>/`. Image builds for every node reuse that
build; rerunning `just node-kernel-build` is a no-op while the build still
matches the committed inputs (`--force` rebuilds). The build is local to this
checkout, so a fresh clone compiles once. After changing `config.2712.delta`, run
`just node-kernel-source-lock --build-suffix +btfN` with `N` greater than the
current `buildSuffix` so nodes see a new package version; the lock refuses a
lower suffix, and builds refuse a delta that does not match the lock.

`hack/bootstrap/.out/kernel/<build-id>/` is the only copy of the packages that
reimaged nodes run. It is gitignored, and the Raspberry Pi archive may stop
serving the pinned source once a newer kernel ships, so a lost build may not be
reproducible. Back it up before reimaging, and restore it to the same checkout
path: the build state records absolute package paths, and image builds refuse a
build whose packages are missing or changed. Durable artifact storage for kernel
builds is a planned follow-up.

`node-reimage-build` bakes that build into the image instead of the stock
kernel:

- a `home-ops-rpi5` device layer replaces rpi-image-gen's `rpi5` layer, which
  would install the stock archive kernel;
- the four packages install through the config `packages` section;
- `/etc/apt/preferences.d/90-home-ops-kernel` pins Raspberry Pi archive
  `rpi-2712` kernel packages to priority -1, so the monthly OS update keeps the
  rebuilt kernel. Moving a node to a different build is a reimage or an
  in-place update; see In-Place Kernel Updates below;
- `/etc/home-ops/kernel-build` records the build, and
  `/usr/local/sbin/home-ops-verify-kernel-build` checks the running release,
  the running build version (`uname -v`), the installed package state and
  version, `/sys/kernel/btf/vmlinux`, and `CONFIG_DEBUG_INFO_BTF=y` in
  `/proc/config.gz`.

`home-ops-firstboot` runs the verifier before anything else. On the wrong kernel
the firstboot marker is never written, so `node-reimage-apply` and node-prep stop
with the verifier output in `firstboot_probe`.

The image build holds the four kernel packages with `apt-mark hold`, as an
rpi-image-gen `cleanup-hooks` step that runs after the config `packages`
section installs them. The pin keeps archive kernels out, but it cannot stop
`apt-get full-upgrade` and `autoremove --purge` from removing the rebuilt kernel
if an archive package ever declares a `Breaks` against it. With the packages
held, the monthly OS update cannot remove or replace them: apt keeps the
conflicting update back or the upgrade job fails, and the node keeps its kernel.
`node-kernel-update` unholds the four packages around its install and holds
them again afterwards, re-holding them even when the install fails; reimaging
installs a new build without either step.

Every node's cmdline carries `panic=30` once node-prep, an in-place kernel
update, or a reimage has applied it, so any kernel panic (this custom build or
the stock kernel) self-reboots the node after 30 seconds instead of hanging; a
node that panics on every boot boot-loops 30 seconds apart rather than staying
down for inspection, and the panic trace survives only on the serial console
(`console=serial0,115200`, `BOOT_UART=1`).

List the kernel build on each node with:

```sh
kubectl get nodes -L node.home-ops.sh/kernel-build
```

## In-Place Kernel Updates

`node-kernel-update` moves one live node to another recorded kernel build
without reimaging it. It trial-boots the new kernel once through the Raspberry
Pi one-shot tryboot flag with the current kernel armed as the fallback:

```sh
just node-kernel-update k3s-worker-0
just node-status k3s-worker-0
just node-uncordon k3s-worker-0
```

Like `node-reimage-full`, it leaves the node cordoned and the final uncordon to
the operator; that pair is what it prints as its `next=` line. Its options are
`--build-id ID`, `--resume`, `--drill-fallback`, `--skip-smoke`, and `--yes`.

The phases are preflight, drain, stage, an optional fallback drill, tryboot,
verify, commit, and kernel-build-label:

- preflight resolves the target build, which defaults to the build for the
  committed kernel source lock, hands off the control-plane API when the target
  holds it, requires the node Ready in its expected role, installs
  `/usr/local/sbin/home-ops-kernel-update`, reads the node's state, refuses to
  drain a node running a CNPG primary, and prints a summary to confirm;
- drain runs the normal `node-drain` path, and is skipped when the node is
  already cordoned with nothing but DaemonSets left on it;
- stage ships the build's four packages, their `SHA256SUMS`, and
  `kernel-build.env` to `/var/tmp/home-ops-kernel/<build-id>/`, then runs
  `prepare` on the node (the kernel verifier, state, disk space, package holds,
  and that the boot set really is the running kernel) and `stage`, which copies
  the running boot set aside, appends the fallback block, writes `tryboot.txt`,
  adds the repo's Raspberry Pi cmdline args to the trial command line, and
  installs the packages;
- tryboot reboots with `systemctl --reboot-argument="0 tryboot" reboot` and
  waits for a new boot ID, Cilium, and Longhorn;
- verify requires the node back in state S1 and runs the CNI smoke pod;
- commit strips the fallback block, removes `tryboot.txt` and the fallback
  directory, and purges the superseded packages on a release bump;
- kernel-build-label runs the kernel verifier on the node and sets
  `node.home-ops.sh/kernel-build=<build-id>`.

Each completed update records
`hack/bootstrap/.out/kernel-update/live/<node>/state/update.json`.

While a trial is staged or booted and not yet committed, the node holds
`/boot/firmware/home-ops-kernel-prev/`:

- `kernel_2712.img` and `initramfs_2712`, copies of the pre-update boot set;
- `cmdline.txt`, the pre-update command line plus `home_ops_kernel_fallback=1`;
- `config.txt.orig`, the pre-update `config.txt`;
- `META`, the previous build id, package version, release, and a SHA256 of each
  copied file;
- `TRIAL`, the staged build id, written only by a stage that ran to completion.

The fallback `cmdline.txt` is frozen at stage time. It never gains an argument
added to the node afterwards, which is what you want from a known-good kernel.
On a node that has not been through node-prep since `panic=30` landed, that
cuts both ways: `stage` adds the repo's cmdline args to the trial line, so the
trial kernel has `panic=30`, while the fallback line does not. A fallback
kernel that panics there still needs a power cycle, exactly as that node
behaved before the update.

`stage` appends exactly this block to `/boot/firmware/config.txt`:

```ini
# BEGIN home-ops kernel fallback (home-ops-kernel-update)
[all]
kernel=home-ops-kernel-prev/kernel_2712.img
initramfs home-ops-kernel-prev/initramfs_2712 followkernel
cmdline=home-ops-kernel-prev/cmdline.txt
# END home-ops kernel fallback (home-ops-kernel-update)
```

and writes `tryboot.txt` as the pre-update `config.txt`. The firmware reads
`tryboot.txt` only for the one boot after `reboot "0 tryboot"`. Every other
boot reads `config.txt` and therefore the previous kernel, so power-cycling a
node with a pending trial returns it to the kernel it was running before the
update, and so does the `panic=30` reboot described above when a trial kernel
panics. `commit` is what makes the new kernel the default boot.

Do not run node-prep against a node with a pending trial. `just ansible-run`,
`just ansible-bootstrap`, and the join path behind `just node-join` and
`just node-converge` rewrite `/boot/firmware/config.txt` and `cmdline.txt`;
Ansible's `blockinfile` leaves the fallback block intact only because its own
managed-block markers are already in the file. A boot-level change on an
already-joined node then makes node-prep stop and tell you to drain and reboot
that node through the node lifecycle flow. Doing that mid-trial reboots the
node onto the previous kernel without saying so, because that is what
`config.txt` boots.

`home-ops-kernel-update status` classifies the node into one of four states,
and every phase reads it:

- `S0`, clean: no fallback copy, no fallback block, no `tryboot.txt`. A run
  whose target build the node already runs stops in preflight with
  `already running kernel build <build-id>; nothing to do` and exits 0.
- `S1`, a trial booted and uncommitted: rerun with `--resume` to verify and
  commit it, or reboot the node to fall back. A resumed run commits only the
  build it was asked for; when a different trial is booted it stops and names
  the one to pass, as `--build-id <booted-build-id> --resume`.
- `S2`, the fallback armed and running: a stage that was never rebooted, a
  failed package install, and a trial that fell back all land here. Rerunning
  re-stages.
- `S3`, inconsistent: the flow refuses to continue and prints the whole status
  block. The header comment of `hack/bootstrap/nodes/kernel/update-node.sh`
  names the two narrow crash windows that land in S3, shows that
  `trial_pending` is what tells them apart, and gives the remedy, which is
  removing the fallback directory. Read those fields before touching anything
  on the node.

`booted_via_fallback`, read from `/proc/cmdline`, is what tells a fallback boot
from a trial boot.

Roll a node back by naming the build it should return to:

```sh
just node-kernel-update k3s-worker-0 --build-id <previous-build-id>
```

`--build-id` takes any build recorded under
`hack/bootstrap/.out/kernel/<build-id>/` and binds nothing to the committed
source lock or config delta, which is what makes a rollback possible. Keep the
build directory for every build a node may need to go back to, under the same
backup rule as reimaging. The failure messages name the id to pass: a trial
that falls back offers `--build-id <previous-build-id>`, and a rerun that finds
an uncommitted trial offers `--build-id <booted-build-id> --resume`.

`--drill-fallback` is the canary to run before trusting the fallback on new
hardware or firmware. After staging, it reboots the node normally once and
requires it back on the previous kernel, then runs the trial boot as usual.
Four outcomes:

- `fallback drill ok`: the node booted the fallback copy, with
  `home_ops_kernel_fallback=1` on its command line.
- `the firmware ignored the fallback block`: the node came back on neither the
  fallback kernel nor the fallback command line. Inspect
  `/boot/firmware/config.txt` on the node.
- the firmware honoured `cmdline=` but not `kernel=`: the node came back on the
  new kernel, and the fallback is NOT armed on this hardware. Do not
  power-cycle expecting a rollback, and do not proceed to the fleet; verify the
  node by hand and commit, or reimage.
- the firmware honoured `kernel=` but not `cmdline=`: the node is on the
  previous kernel, but `home_ops_kernel_fallback=1` is absent from
  `/proc/cmdline`, so a fallback boot cannot be told from a trial boot. Do not
  proceed to the fleet.

Every drill failure leaves the node staged and cordoned and prints the status
block. `--drill-fallback` is refused on a resumed run, which never stages and
so could never prove a fallback.

A same-release rebuild and a release bump behave differently on the node. A
`+btfN` rebuild keeps the package names and `uname -r`, so installing it
overwrites the running kernel's modules under `/lib/modules/<release>` on the
root filesystem: a node that falls back runs the previous kernel image against
the rebuilt modules. Same source and same vermagic is what makes that
recoverable, and a full rollback with `--build-id <previous-build-id>`
reinstalls the previous packages over them. A release bump installs alongside
the running kernel instead, and `commit` purges `linux-image-<old-release>` and
`linux-base-<old-release>` once the trial is committed; when that purge fails
the run warns and leaves them for you to remove. `commit` also compares the
stripped `config.txt` against the copy it took at stage time, and the run warns
`config.txt on <node> changed during the update; review it before the next
reboot` when the two differ. That is the automated signal for the node-prep
hazard above: something rewrote the file while the trial was pending.

One update runs at a time. The flow takes
`hack/bootstrap/.out/kernel-update/.update.lock` and releases it on exit,
because every node stages through the same per-build package directory under
that output root. A lock left behind by a crashed run is reported with the
node, context, and start time it recorded, and the message gives the `rm -rf`
that clears it.

After the trial boot, and before the commit, the flow proves the rebooted node
still resolves in-cluster DNS through its CNI. It runs a pinned busybox pod
(`NODE_KERNEL_UPDATE_SMOKE_IMAGE` in `hack/bootstrap/nodes/lib/config.sh`) in
namespace `home-ops-kernel-smoke`, pinned to the cordoned node with `nodeName`
and a blanket toleration so it schedules there, resolving
`kubernetes.default.svc.cluster.local` and printing `cni-smoke-ok`. The pod is
deleted again before the commit. A failure that mentions `ImagePullBackOff` is
a pull problem and not a kernel problem: pre-pull the image on the node with
`sudo k3s crictl pull <image>`, or rerun with `--skip-smoke` and check
in-cluster DNS by hand.

A run that dies with a staged, uncommitted kernel prints which of the two
shapes the node is in, so no reboot has to be a guess: either the fallback is
armed and any boot but the trial returns the previous kernel, or the firmware
proved it is not armed and only the new kernel will boot. Past the commit there
is no fallback left to discuss, and the run prints the `kubectl label` command
to finish by hand instead.

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
