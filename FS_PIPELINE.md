# LXC → Fabric Studio pipeline

Build minimal public-release LXC images and deploy them onto a Fabric Studio
(FortiPoC) pod as `vm_type: LXC` firmware. Repeatable and extensible — the
build, deploy, and (future) config layers are independent and parameterized.

```
 build (this repo, Docker)      deploy (fabric_studio_fixer)        config (later: Ansible)
 ┌────────────────────────┐     ┌──────────────────────────┐       ┌────────────────────────┐
 │ build-rocky-fleet.sh   │ zip │ tools/fs_lxc_deploy.py    │ ssh   │ evoke-image-builder     │
 │  → LXC_rocky_9.6.zip    ├────▶│  upload→create→install   ├──────▶│  packages / vars / .bin │
 │  → LXC_rocky_9.7.zip    │     │  →SSH-verify (key)       │       │  answer installer Qs    │
 └────────────────────────┘     └──────────────────────────┘       └────────────────────────┘
```

## 1. Build

```bash
# generate the key once (key-only auth; password auth is disabled in the image)
ssh-keygen -t ed25519 -f keys/fsh-lxc -N '' -C fsh-lxc-build

# build the fleet (defaults: Rocky 9.6 + 9.7, amd64/default, INSECURE_TLS=1)
./build-rocky-fleet.sh
# → out/LXC_rockylinux_9.6_toolbox_amd64.zip
# → out/LXC_rockylinux_9.7_toolbox_amd64.zip
```

Key facts baked into the scripts:

- **Minor pinning.** linuxcontainers only ships Rocky *majors* (`9` = latest
  minor, currently 9.8). `--releasever 9.6` repoints the repos at the **vault**
  (`dl.rockylinux.org/vault/rocky/<minor>/`) and `distro-sync --nobest
  --allowerasing` downgrades to the exact minor. Works for any minor.
- **Key-only auth.** Pass `--ssh-key-file` and no passwords → build-lxc.sh sets
  `PasswordAuthentication no` + `PermitRootLogin no`. (FS doesn't reliably
  inject a password during build; keys sidestep that until we find the
  FS-compatible password options.)
- **`INSECURE_TLS=1`** disables dnf cert checks — required behind the lab's
  SSL-inspecting proxy. Set `INSECURE_TLS=0` on a trusted network.
- **macOS/Apple-Silicon:** colima provides amd64 via qemu; builds are emulated
  and slow (the downgrade transaction is the long pole). `colima start` first.
- The build-lxc.sh script is **baked into the Docker image** (`COPY`), so script
  edits need an image rebuild — don't pass `--no-build` after editing it.

To add another minimal release: `RELEASES="9.6 9.7 9.5" ./build-rocky-fleet.sh`,
or build other distros directly via `./build-lxc-wrapper.sh <dist> <release>`.

## ⚠️ Networking footguns (read before building a non-Debian image)

These cost ~4 build/deploy cycles to find. The short version: **FS configures an
LXC's network the Debian way, EL can't consume it natively, and the obvious EL
workarounds don't work in an LXC container.**

1. **FS injects Debian `ifupdown` config — there is no DHCP.** FS auto-assigns a
   *static* address in its model and writes it straight into the container rootfs
   as `/etc/network/interfaces` (`source interfaces.d/*.conf`) +
   `/etc/network/interfaces.d/ethN.conf` (`iface ethN inet static` + address /
   netmask). The debian-trixie toolbox "just works" only because it ships
   `ifupdown` and consumes those files. **Don't chase DHCP** — FS never serves it
   for a STA port. (Three prior fixes burned on dhclient/NM/networkd before this
   was understood.)

2. **No EL package consumes `/etc/network/interfaces.d`.** Rocky/RHEL ship neither
   `ifupdown`, nor the NM-ifupdown plugin (NM has only `ifcfg-rh`/`keyfile`), and
   `network-scripts` reads `ifcfg-*`, not Debian `interfaces.d`. So on any
   non-Debian image **you must ship a translator** that parses the injected files
   and applies them with iproute2. That's what the `centos|rockylinux|almalinux|
   fedora` case in `build-lxc.sh` does (`/usr/local/sbin/fsh-netcfg.sh` +
   `fsh-netcfg.service`). Installing `ifupdown` is not an option (not in EL repos).

3. **udev does NOT run inside these LXC containers** — so a udev-triggered bring-up
   never fires. `systemd-udevd` is `inactive` in *both* rocky and trixie (no udevd
   process, no `/run/udev/control`); the FS host owns device management. This means
   trixie's `/lib/udev/rules.d/80-ifupdown.rules`
   (`SUBSYSTEM=="net",ACTION=="add" → ifup`) is dead weight in LXC — trixie's eth0
   is actually raised by **boot-time `ifup -a`** (`networking.service`). Do **not**
   build an EL shim around a udev rule; it'll look right and do nothing.

4. **A single early `ip link set up` does not stick — the veth-attach race.** FS
   attaches the container veth around boot and the port can end up **admin-DOWN
   *after* an early oneshot runs**, even though the address you added persists
   (symptom: in-guest `eth0 DOWN 10.254.254.x/24`, and from the pod `ping` to that
   IP = 100% loss / "No route to host"). Once eth0 is genuinely UP, nothing
   re-lowers it. trixie wins because `networking.service` is ordered *late* (after
   `local-fs`/`modules-load`/`ifupdown-pre`) so the veth has settled. The EL shim
   handles this without udev by: **wait for the device to appear → apply addr →
   background a short (~20s) link-up watchdog** (`KillMode=process` so the child
   survives the oneshot exit). Re-assert, don't assume.

5. **You can't SSH the 1100x port-forwards from off-pod (typically).** From a dev
   machine behind a split-tunnel, only pod:22 + REST API 443 are routable; the
   `11000+port_idx` SSH forwards are firewalled. Use `fs_lxc_deploy … --via-pod`
   (jump through pod:22). The **serial console** (fs_console `con`, root /
   `FSHrecover1!`) is the network-independent ground truth for debugging an image
   that won't come up.

## 2. Deploy to a pod  (fabric_studio_fixer/tools/fs_lxc_deploy.py)

```bash
cd <fabric_studio_fixer>
python -m tools.fs_lxc_deploy all --host 10.99.249.159 \
    --image <lxc-builder>/out/LXC_rockylinux_9.6_toolbox_amd64.zip \
    --fabric lxc-build --vm rocky96 \
    --ssh-user fabric --ssh-key <lxc-builder>/keys/fsh-lxc
```

Steps: upload the zip into the pod **home** repo
(`POST system/repository/home/firmware:import`, recognized as `vm_type: LXC`) →
ensure a dedicated fabric → create a VM on that firmware → set SSH access PUBLIC
→ install + wait booted → SSH in with the key and run `os-release; id`.
LXC shares the host rootfs, so no extra disk is attached by default.

## 3. Config (future — Ansible)

Once the container is up and key-reachable, drive package installs, variables,
and interactive `.bin` installers from `evoke-image-builder` (Packer+Ansible,
already has an FSR-on-Rocky precedent). The SSH endpoint from step 2 is the
Ansible inventory target.

## Toward a declarative FS provisioner

`fs_lxc_deploy.py` is the imperative engine for one node type. The goal is a
Terraform-style declarative layer over `backend/engine/fs_admin.py` that builds
whole topologies — FGT/LXC/VM nodes, networks, and routing — from a spec:

```yaml
fabric: lab-1
images: [ {build: rockylinux/9.6, auth: key}, ... ]
nodes:
  - {name: rtr, type: FGT, firmware: <fgt>, config: rtr.cfg}
  - {name: host1, type: LXC, image: rockylinux/9.6}
networks: [ ... ]          # links/bridges between node ports
routes:   [ ... ]          # ensure traffic flows the intended path
```

The pieces that already exist to build on: fabric/VM/firmware/access/disk CRUD
and task-tracking in `fs_admin`; port/topology models in
`backend/engine/channels/fabric_topology.py`; FGT config push + verify in
`tests/verification/provision.py` (`push(...)`). The declarative layer is mostly
a planner that diffs desired-vs-actual and calls these primitives in order.
