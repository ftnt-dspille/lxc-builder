#!/usr/bin/env bash

# This script automates building a customized LXC container image for various Linux distributions,
# with SSH, Python, and sudo preinstalled. It uses a caching mechanism for the base image,
# customizes the root filesystem in a chroot, and packages the result as a zip file
# with LXC configuration files for easy deployment.
#
# Supported distributions: debian, ubuntu, fedora, centos, rockylinux, almalinux, alpine, arch
#
# Steps:
# 1. Fetch or cache the base LXC image.
# 2. Customize the rootfs (install packages, fix DNS).
# 3. Configure SSH with optional password/key setup.
# 4. Package the rootfs as a tar.xz.
# 5. Prepare LXC config and metadata files.
# 6. Zip everything for distribution.

set -euo pipefail

# Load environment variables from .env file if it exists
if [[ -f ".env" ]]; then
    echo "Loading environment variables from .env file..."
    # Source the file in a subshell to avoid polluting current environment with potential issues
    set -a
    source .env
    set +a
fi

show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Build customized LXC container images with SSH, Python, and sudo preinstalled.

OPTIONS:
    -h, --help          Show this help message
    -d, --dist DIST     Distribution (default: debian)
                        Supported: debian, ubuntu, fedora, centos, rockylinux, almalinux, alpine, arch
    -r, --release REL   Release/version (default: trixie for debian)
    -a, --arch ARCH     Architecture (default: amd64)
    -v, --variant VAR   Variant (default: cloud)
                        Common variants: default, cloud, minimal
    -n, --name NAME     Container name (default: tmp-image)
    -o, --outdir DIR    Output directory (default: /out)
    -c, --cache DIR     Cache directory (default: /var/cache/lxc)
    --zip-name NAME     Custom zip filename prefix
    --ssh-user USER     Create SSH user with this username
    --ssh-password PASS Set SSH password for the user (use .env file for security)
    --ssh-key-file FILE Add SSH public key from file
    --root-password PASS Set root password (use .env file for security)

ENVIRONMENT VARIABLES:
    DIST, RELEASE, ARCH, VARIANT, NAME, OUTDIR, CACHE_DIR, ZIP_BASENAME
    SSH_USER, SSH_PASSWORD, SSH_KEY_FILE, ROOT_PASSWORD
    (Command line options override environment variables)

SECURITY NOTES:
    Create a .env file (gitignored) with sensitive variables:
    SSH_USER=myuser
    SSH_PASSWORD=secure_password_here
    ROOT_PASSWORD=root_password_here
    SSH_KEY_FILE=/path/to/public/key

EXAMPLES:
    $0                                          # Build Debian Trixie
    $0 -d ubuntu -r jammy                      # Build Ubuntu 22.04
    $0 -d fedora -r 39 -v minimal              # Build Fedora 39 minimal
    $0 -d alpine -r 3.19                       # Build Alpine 3.19
    $0 --dist centos --release 9               # Build CentOS 9
    $0 --ssh-user admin --ssh-key-file ~/.ssh/id_rsa.pub  # With SSH key

SUPPORTED DISTRIBUTIONS:
    debian      - Releases: bookworm, trixie, sid
    ubuntu      - Releases: focal, jammy, noble, mantic
    fedora      - Releases: 38, 39, 40
    centos      - Releases: 8, 9
    rockylinux       - Releases: 8, 9
    almalinux   - Releases: 8, 9
    alpine      - Releases: 3.17, 3.18, 3.19, edge
    arch        - Releases: current

NOTE: This script requires privileged access for chroot operations.
      When using Docker, run with --privileged flag.

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -d|--dist)
            DIST="$2"
            shift 2
            ;;
        -r|--release)
            RELEASE="$2"
            shift 2
            ;;
        --releasever)
            RELEASEVER="$2"
            shift 2
            ;;
        -a|--arch)
            ARCH="$2"
            shift 2
            ;;
        -v|--variant)
            VARIANT="$2"
            shift 2
            ;;
        -n|--name)
            NAME="$2"
            shift 2
            ;;
        -o|--outdir)
            OUTDIR="$2"
            shift 2
            ;;
        -c|--cache)
            CACHE_DIR="$2"
            shift 2
            ;;
        --zip-name)
            ZIP_BASENAME="$2"
            shift 2
            ;;
        --ssh-user)
            SSH_USER="$2"
            shift 2
            ;;
        --ssh-password)
            SSH_PASSWORD="$2"
            shift 2
            ;;
        --ssh-key-file)
            SSH_KEY_FILE="$2"
            shift 2
            ;;
        --root-password)
            ROOT_PASSWORD="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information."
            exit 1
            ;;
    esac
done

# Default values (can be overridden by environment or command line)
: "${DIST:=debian}"
: "${RELEASE:=}"
# Optional exact point-release to pin a dnf-based distro to (e.g. 9.6, 9.7).
# The base image is still fetched at major --release (linuxcontainers only
# serves majors for Rocky/Alma); RELEASEVER then `distro-sync`s to the exact
# minor against the vault repos. Leave empty to track the latest minor.
: "${RELEASEVER:=}"
: "${ARCH:=amd64}"
: "${VARIANT:=cloud}"
: "${NAME:=tmp-image}"
: "${OUTDIR:=/out}"
: "${CACHE_DIR:=/var/cache/lxc}"
: "${SSH_USER:=}"
: "${SSH_PASSWORD:=}"
: "${SSH_KEY_FILE:=}"
: "${ROOT_PASSWORD:=}"

# Set default releases if not specified
if [[ -z "$RELEASE" ]]; then
    case "$DIST" in
        debian) RELEASE="trixie" ;;
        ubuntu) RELEASE="jammy" ;;
        fedora) RELEASE="39" ;;
        centos|rockylinux|almalinux) RELEASE="9" ;;
        alpine) RELEASE="3.19" ;;
        arch) RELEASE="current" ;;
        *)
            echo "Error: Unknown distribution '$DIST' or missing release version"
            echo "Use --help to see supported distributions"
            exit 1
            ;;
    esac
fi

# Label used in the output zip name: the pinned minor when set, else the major.
RELEASE_LABEL="${RELEASEVER:-$RELEASE}"
: "${ZIP_BASENAME:=LXC_${DIST}_${RELEASE_LABEL}_toolbox_${ARCH}}"

# Validate distribution
case "$DIST" in
    debian|ubuntu|fedora|centos|rockylinux|almalinux|alpine|arch)
        ;;
    *)
        echo "Error: Unsupported distribution '$DIST'"
        echo "Supported: debian, ubuntu, fedora, centos, rockylinux, almalinux, alpine, arch"
        exit 1
        ;;
esac

# Validate SSH key file if specified
if [[ -n "$SSH_KEY_FILE" && ! -f "$SSH_KEY_FILE" ]]; then
    echo "Error: SSH key file '$SSH_KEY_FILE' not found"
    exit 1
fi

# Security warning for command line passwords
if [[ -n "$SSH_PASSWORD" ]] && [[ "${SSH_PASSWORD}" == *"$"* ]]; then
    echo "Warning: Consider using .env file for passwords instead of command line"
fi

# Distribution-specific configuration
get_package_config() {
    case "$DIST" in
        debian|ubuntu)
            PKG_UPDATE="apt-get update"
            PKG_INSTALL="apt-get install -y"
            PACKAGES="dhcpcd-base ifupdown openssh-server python3 sudo sshpass"
            SSH_SERVICE_ENABLE=""  # Enabled by default
            ;;
        fedora)
            PKG_UPDATE="dnf makecache"
            PKG_INSTALL="dnf install -y"
            PACKAGES="openssh-server python3 sudo"
            SSH_SERVICE_ENABLE="systemctl enable sshd"
            ;;
        centos|rockylinux|almalinux)
            PKG_UPDATE="dnf makecache"
            PKG_INSTALL="dnf install -y"
            PACKAGES="openssh-server python3 sudo"
            SSH_SERVICE_ENABLE="systemctl enable sshd"
            ;;
        alpine)
            PKG_UPDATE="apk update"
            PKG_INSTALL="apk add"
            PACKAGES="openssh python3 sudo"
            SSH_SERVICE_ENABLE="rc-update add sshd default"
            ;;
        arch)
            PKG_UPDATE="pacman -Sy"
            PKG_INSTALL="pacman -S --noconfirm"
            PACKAGES="openssh python sudo"
            SSH_SERVICE_ENABLE="systemctl enable sshd"
            ;;
    esac
}

# Cache key for the BASE image (before customization)
CACHE_KEY="${DIST}-${RELEASE}-${ARCH}-${VARIANT}"
CACHED_BASE="${CACHE_DIR}/base-${CACHE_KEY}.tar.xz"

echo "Building LXC image: $DIST $RELEASE ($ARCH, $VARIANT)"
echo "Output: $OUTDIR/${ZIP_BASENAME}.zip"
if [[ -n "$SSH_USER" ]]; then
    echo "SSH User: $SSH_USER"
    [[ -n "$SSH_PASSWORD" ]] && echo "SSH Password: [SET]"
    [[ -n "$SSH_KEY_FILE" ]] && echo "SSH Key: $SSH_KEY_FILE"
fi
[[ -n "$ROOT_PASSWORD" ]] && echo "Root Password: [SET]"
echo ""

echo "Debug: SSH_USER=$SSH_USER"
echo "Debug: SSH_PASSWORD is set: $([[ -n "$SSH_PASSWORD" ]] && echo "YES" || echo "NO")"

echo "[1/6] Fetching base image..."

if [[ -f "$CACHED_BASE" ]]; then
    echo "[CACHE HIT] Extracting cached base image: $CACHED_BASE"
    rm -rf /var/lib/lxc/"$NAME" || true
    mkdir -p /var/lib/lxc/"$NAME"/rootfs
    tar -xJf "$CACHED_BASE" -C /var/lib/lxc/"$NAME"/rootfs
else
    echo "[CACHE MISS] Downloading base image with lxc-download..."
    rm -rf /var/lib/lxc/"$NAME" || true

    # Some distributions might not support all variants
    echo "Attempting to download $DIST $RELEASE $ARCH $VARIANT..."
    if ! lxc-create -n "$NAME" -t download -- \
        --dist "$DIST" \
        --release "$RELEASE" \
        --arch "$ARCH" \
        --variant "$VARIANT" 2>/dev/null; then

        echo "Warning: Variant '$VARIANT' not available, trying 'default'..."
        VARIANT="default"
        lxc-create -n "$NAME" -t download -- \
            --dist "$DIST" \
            --release "$RELEASE" \
            --arch "$ARCH" \
            --variant "$VARIANT"
    fi

    # Cache the BASE image for next time
    echo "[CACHE] Saving base image to cache..."
    mkdir -p "$CACHE_DIR"
    tar --xattrs --acls --numeric-owner \
        -C /var/lib/lxc/"$NAME"/rootfs \
        -cJf "$CACHED_BASE" .
fi

ROOT=/var/lib/lxc/"$NAME"/rootfs

echo "[2/6] Customizing rootfs (ssh, python, sudo)..."

# Get distribution-specific package configuration
get_package_config

# --- mount chroot virtual filesystems ---
mount -t proc proc "$ROOT/proc"
mount -t sysfs sys "$ROOT/sys"
mount --bind /dev "$ROOT/dev"
mount --bind /dev/pts "$ROOT/dev/pts"
mount --bind /run "$ROOT/run"

# Determine shell to use (Alpine uses ash, others use bash)
CHROOT_SHELL="bash"
if [[ "$DIST" == "alpine" ]]; then
    CHROOT_SHELL="ash"
fi

# Fix DNS resolution (works for most distributions)
echo "Fixing DNS resolution..."
chroot "$ROOT" $CHROOT_SHELL -c "
    rm -f /etc/resolv.conf
    printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf
"

# Behind an SSL-inspecting proxy (e.g. corporate/Fortinet MITM), dnf rejects
# the self-signed CA in the chain. INSECURE_TLS=1 disables dnf cert checking
# in the image's dnf.conf so distro-sync, package install, and later Ansible
# dnf calls all work. Lab-only convenience; leave unset for trusted networks.
if [[ "${INSECURE_TLS:-0}" == "1" ]]; then
    case "$DIST" in
        centos|rockylinux|almalinux|fedora)
            echo "INSECURE_TLS=1 -> setting sslverify=False in dnf.conf"
            chroot "$ROOT" $CHROOT_SHELL -c "
                grep -q '^sslverify' /etc/dnf/dnf.conf 2>/dev/null \
                  && sed -i 's/^sslverify.*/sslverify=False/' /etc/dnf/dnf.conf \
                  || echo 'sslverify=False' >> /etc/dnf/dnf.conf
            "
            ;;
    esac
fi

# Persistent dnf package cache (optimization). The wrapper bind-mounts a host
# cache dir at /dnf-cache; map it into the chroot's /var/cache/dnf and tell dnf
# to keep downloaded rpms. distro-sync + package install (the build's biggest
# cost, run under qemu emulation) then reuse rpms across rebuilds instead of
# re-downloading. The mount is removed before packaging so it never lands in the
# image; pair this with `dnf clean metadata` (NOT `clean all`) below to preserve
# the package cache.
DNF_CACHE_MOUNTED=0
case "$DIST" in
    centos|rockylinux|almalinux|fedora)
        chroot "$ROOT" $CHROOT_SHELL -c "
            grep -q '^keepcache' /etc/dnf/dnf.conf 2>/dev/null \
              && sed -i 's/^keepcache.*/keepcache=1/' /etc/dnf/dnf.conf \
              || echo 'keepcache=1' >> /etc/dnf/dnf.conf
        "
        if [[ -d /dnf-cache ]]; then
            mkdir -p "$ROOT/var/cache/dnf"
            if mount --bind /dnf-cache "$ROOT/var/cache/dnf"; then
                DNF_CACHE_MOUNTED=1
                echo "dnf package cache: persisting via /dnf-cache bind mount"
            fi
        fi
        ;;
esac

# Pin the exact point release (dnf-based distros only) BEFORE installing
# packages, so everything that follows resolves against the pinned minor.
if [[ -n "$RELEASEVER" ]]; then
    case "$DIST" in
        rockylinux)
            # Only the CURRENT minor is on the live mirror network; archived
            # minors (and reliably ALL minors) live in the vault. Disable the
            # stock mirrorlist repos and write a clean vault-pinned repo file —
            # robust whether $RELEASEVER is current or archived. (Writing the
            # file from the host side avoids chroot double-shell $var expansion.)
            echo "Pinning rockylinux to $RELEASEVER via vault repos + distro-sync..."
            VAULT_BASE="https://dl.rockylinux.org/vault/rocky/$RELEASEVER"
            for f in "$ROOT"/etc/yum.repos.d/*.repo; do
                [[ -e "$f" ]] && mv "$f" "$f.disabled"
            done
            cat > "$ROOT/etc/yum.repos.d/vault.repo" <<EOF
[baseos]
name=Rocky Linux $RELEASEVER - BaseOS (vault)
baseurl=$VAULT_BASE/BaseOS/\$basearch/os/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9

[appstream]
name=Rocky Linux $RELEASEVER - AppStream (vault)
baseurl=$VAULT_BASE/AppStream/\$basearch/os/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9

[crb]
name=Rocky Linux $RELEASEVER - CRB (vault)
baseurl=$VAULT_BASE/CRB/\$basearch/os/
gpgcheck=1
enabled=0
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
EOF
            chroot "$ROOT" $CHROOT_SHELL -c "
                set -e
                echo '$RELEASEVER' > /etc/dnf/vars/releasever
                dnf clean metadata
                # The linuxcontainers base tracks the LATEST minor, so pinning
                # to an earlier one is a downgrade. fips provider pkgs pin exact
                # openssl-libs and block distro-sync; drop them, then sync with
                # --nobest --allowerasing to push the downgrade through.
                rpm -e --nodeps openssl-fips-provider openssl-fips-provider-so 2>/dev/null || true
                dnf -y --releasever='$RELEASEVER' --nobest --allowerasing distro-sync
                # distro-sync reinstalls rocky-repos, which restores the stock
                # mirrorlist repo files (404 for archived minors). Remove them so
                # only vault.repo remains for the package-install step that follows.
                rm -f /etc/yum.repos.d/rocky*.repo /etc/yum.repos.d/*.repo.disabled
                dnf clean metadata
                echo 'Pinned release:'; cat /etc/rocky-release || true
            "
            ;;
        almalinux)
            echo "Pinning almalinux to $RELEASEVER via distro-sync..."
            chroot "$ROOT" $CHROOT_SHELL -c "
                set -e
                echo '$RELEASEVER' > /etc/dnf/vars/releasever
                dnf -y --releasever='$RELEASEVER' distro-sync
            "
            ;;
        fedora)
            echo "Pinning fedora to $RELEASEVER via distro-sync..."
            chroot "$ROOT" $CHROOT_SHELL -c "
                set -e
                dnf -y --releasever='$RELEASEVER' distro-sync
                echo '$RELEASEVER' > /etc/dnf/vars/releasever
            "
            ;;
        *)
            echo "Warning: --releasever ignored for non-dnf distro '$DIST'"
            ;;
    esac
fi

# Install packages based on distribution. EXTRA_PACKAGES (env, space-separated)
# appends distro packages on top of the preset — e.g. EXTRA_PACKAGES=python3.12
# to bake a specific interpreter into the image. Pass it through the wrapper with
# `--docker-args "-e EXTRA_PACKAGES=python3.12"`.
echo "Installing packages: $PACKAGES ${EXTRA_PACKAGES:-}"
chroot "$ROOT" $CHROOT_SHELL -c "
    $PKG_UPDATE && $PKG_INSTALL $PACKAGES ${EXTRA_PACKAGES:-}
"

# Enable SSH service if needed
if [[ -n "$SSH_SERVICE_ENABLE" ]]; then
    echo "Enabling SSH service..."
    chroot "$ROOT" $CHROOT_SHELL -c "$SSH_SERVICE_ENABLE" || echo "Warning: Could not enable SSH service"
fi

echo "[3/6] Configuring SSH and user accounts..."

# Set root password if specified
if [[ -n "$ROOT_PASSWORD" ]]; then
    echo "Setting root password..."
    chroot "$ROOT" $CHROOT_SHELL -c "echo 'root:$ROOT_PASSWORD' | chpasswd"
fi

# Create SSH user if specified
if [[ -n "$SSH_USER" ]]; then
    echo "Creating SSH user: $SSH_USER"
    chroot "$ROOT" $CHROOT_SHELL -c "
        # Create user with home directory
        useradd -m -s /bin/bash '$SSH_USER' || true

        # Add to sudo group (distribution-dependent)
        if getent group sudo >/dev/null 2>&1; then
            usermod -aG sudo '$SSH_USER'
        elif getent group wheel >/dev/null 2>&1; then
            usermod -aG wheel '$SSH_USER'
        fi

        # Create .ssh directory
        mkdir -p /home/'$SSH_USER'/.ssh
        chmod 700 /home/'$SSH_USER'/.ssh
        chown '$SSH_USER':'$SSH_USER' /home/'$SSH_USER'/.ssh
    "

    # Set user password if specified
    if [[ -n "$SSH_PASSWORD" ]]; then
        echo "Setting password for user: $SSH_USER"
        chroot "$ROOT" $CHROOT_SHELL -c "echo '$SSH_USER:$SSH_PASSWORD' | chpasswd"
    fi

    # Add SSH key if specified
    if [[ -n "$SSH_KEY_FILE" ]]; then
        echo "Adding SSH key from: $SSH_KEY_FILE"
        SSH_KEY_CONTENT=$(cat "$SSH_KEY_FILE")
        chroot "$ROOT" $CHROOT_SHELL -c "
            echo '$SSH_KEY_CONTENT' > /home/'$SSH_USER'/.ssh/authorized_keys
            chmod 600 /home/'$SSH_USER'/.ssh/authorized_keys
            chown '$SSH_USER':'$SSH_USER' /home/'$SSH_USER'/.ssh/authorized_keys
        "
    fi
fi

# Configure SSH server for better security
echo "Configuring SSH server..."
chroot "$ROOT" $CHROOT_SHELL -c "
    # Backup original config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup || true

    # Update SSH configuration for better security
    sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config || true
    sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config || true
    sed -i 's/#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config || true

    # Key provided and no SSH *user* password -> SSH is key-only. ROOT_PASSWORD
    # is intentionally NOT part of this condition: it's a CONSOLE/recovery
    # credential (getty), and PermitRootLogin no still blocks root over SSH, so
    # SSH stays key-only even with a root password set for serial-console debug.
    if [[ -n '$SSH_KEY_FILE' && -z '$SSH_PASSWORD' ]]; then
        sed -i 's/PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config || true
        sed -i 's/PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config || true
    fi
"

# Distribution-specific post-install configuration
case "$DIST" in
    alpine)
        echo "Configuring Alpine-specific settings..."
        chroot "$ROOT" $CHROOT_SHELL -c "
            # Generate SSH host keys
            ssh-keygen -A
            # Ensure SSH starts on boot
            rc-update add sshd default || true
        "
        ;;
    arch)
        echo "Configuring Arch-specific settings..."
        chroot "$ROOT" $CHROOT_SHELL -c "
            # Initialize pacman keyring if needed
            pacman-key --init || true
            pacman-key --populate || true
        "
        ;;
    centos|rockylinux|almalinux|fedora)
        # EL minimal LXC networking. ROOT CAUSE (confirmed live, 2026-06-09):
        # Fabric Studio does NOT serve DHCP for a port — it auto-assigns a STATIC
        # address in its model and injects it into the guest by writing Debian
        # ifupdown config straight into the rootfs: /etc/network/interfaces +
        # /etc/network/interfaces.d/ethN.conf with `iface ethN inet static /
        # address / netmask`. The known-good debian-trixie toolbox comes up
        # because it ships ifupdown and consumes those files. Rocky/RHEL ships
        # NEITHER systemd-networkd NOR an ifupdown package NOR the NM ifupdown
        # plugin (RH's NetworkManager has only ifcfg-rh + keyfile), so FS's
        # injected config is ignored and eth0 never gets an address.
        #
        # Fix: a tiny oneshot that parses FS's interfaces.d/*.conf and applies it
        # via iproute2 — no package deps, works on minimal EL. NM stays disabled
        # so it can't fight the shim; the stale dhcp ifcfg-eth0 is removed.
        echo "Configuring EL networking (FS ifupdown-config shim)..."
        chroot "$ROOT" $CHROOT_SHELL -c "
            $PKG_INSTALL iproute 2>/dev/null || true
            systemctl disable NetworkManager 2>/dev/null || true
            rm -f /etc/sysconfig/network-scripts/ifcfg-eth0
        "
        cat > "$ROOT/usr/local/sbin/fsh-netcfg.sh" <<'EOF'
#!/bin/sh
# Apply Fabric Studio-injected ifupdown config (/etc/network/interfaces.d/*.conf)
# on minimal EL, where ifupdown / NM-ifupdown are unavailable. FS writes per-port
# `iface ethN inet {static|manual|dhcp}` with address/netmask (+optional gateway).
#
# WHY A SCRIPT, NOT A NATIVE CONSUMER: FS writes Debian ifupdown-format files.
# EL ships nothing that reads /etc/network/interfaces.d — no ifupdown package, no
# NM-ifupdown plugin (NM has only ifcfg-rh/keyfile), and network-scripts reads
# ifcfg, not interfaces.d. The known-good debian-trixie toolbox consumes them via
# ifupdown's `networking.service` (`ifup -a`) at boot. NOTE: udev does NOT run in
# these LXC containers (systemd-udevd inactive, no /run/udev — host owns devices),
# so trixie's 80-ifupdown.rules never fires; its eth0 is raised by boot-time
# `ifup -a`. So this is a boot-time oneshot too.
#
# RACE (confirmed live 2026-06-09): a single early `ip link set up` does NOT stick
# — FS attaches the container veth around boot and the port ends admin-DOWN *after*
# the oneshot exits, even though the address we add persists. Once eth0 is genuinely
# UP nothing re-lowers it. trixie escapes this because networking.service is ordered
# late (After local-fs/modules-load/ifupdown-pre) so the veth has settled. We can't
# rely on udev, so we instead: (1) wait for each device to appear, (2) apply
# addr/route, (3) re-assert `link up` over a short settle window so a post-attach FS
# toggle still ends UP.
set -u

mask2prefix() {
    p=0; oldifs="$IFS"; IFS=.
    for o in $1; do
        case "$o" in
            255) p=$((p+8));; 254) p=$((p+7));; 252) p=$((p+6));; 248) p=$((p+5));;
            240) p=$((p+4));; 224) p=$((p+3));; 192) p=$((p+2));; 128) p=$((p+1));;
            *) ;;
        esac
    done
    IFS="$oldifs"; echo "$p"
}

is_up() { ip link show dev "$1" 2>/dev/null | grep -q "state UP"; }

managed=""
for f in /etc/network/interfaces.d/*.conf; do
    [ -f "$f" ] || continue
    iface=""; method=""; addr=""; mask=""; gw=""
    while read -r key val rest; do
        case "$key" in
            iface)   iface="$val"; method="$rest" ;;
            address) addr="$val" ;;
            netmask) mask="$val" ;;
            gateway) gw="$val" ;;
        esac
    done < "$f"
    [ -n "$iface" ] || continue

    # Wait up to ~15s for FS to attach the device before configuring it.
    i=0
    while [ $i -lt 30 ] && ! ip link show dev "$iface" >/dev/null 2>&1; do
        i=$((i+1)); sleep 0.5
    done
    ip link show dev "$iface" >/dev/null 2>&1 || continue

    ip link set "$iface" up 2>/dev/null || true
    managed="$managed $iface"
    case "$method" in
        *static*)
            [ -n "$addr" ] || continue
            pfx=24; [ -n "$mask" ] && pfx=$(mask2prefix "$mask")
            ip addr show dev "$iface" | grep -q "inet $addr/" \
                || ip addr add "$addr/$pfx" dev "$iface"
            [ -n "$gw" ] && ip route replace default via "$gw" dev "$iface" 2>/dev/null || true
            ;;
        *dhcp*)
            command -v dhclient >/dev/null 2>&1 && dhclient -1 "$iface" 2>/dev/null || true
            ;;
        *) : ;;  # manual: link up only
    esac
done

# Settle loop: re-assert link-up for ~20s so a post-attach FS toggle that lands
# after the config pass still ends with the interface UP. Backgrounded so the
# oneshot returns immediately (sshd isn't delayed); the unit uses KillMode=process
# so this child survives the oneshot exit.
[ -n "$managed" ] || exit 0
(
    i=0
    while [ $i -lt 20 ]; do
        for iface in $managed; do
            is_up "$iface" || ip link set "$iface" up 2>/dev/null || true
        done
        i=$((i+1)); sleep 1
    done
) &
exit 0
EOF
        chmod +x "$ROOT/usr/local/sbin/fsh-netcfg.sh"
        cat > "$ROOT/etc/systemd/system/fsh-netcfg.service" <<'EOF'
[Unit]
Description=FSH apply Fabric Studio ifupdown network config (minimal EL)
After=network-pre.target
Wants=network-pre.target
Before=network-online.target sshd.service

[Service]
Type=oneshot
RemainAfterExit=yes
# KillMode=process: the script backgrounds a ~20s link-up watchdog and returns;
# don't reap that child when the oneshot's main process exits.
KillMode=process
ExecStart=/usr/local/sbin/fsh-netcfg.sh

[Install]
WantedBy=multi-user.target
EOF
        chroot "$ROOT" $CHROOT_SHELL -c "systemctl enable fsh-netcfg.service 2>/dev/null || true"
        ;;
esac

# --- unmount before packaging ---
# Remove the persistent dnf cache bind mount BEFORE tarring so cached rpms stay
# on the host (for reuse) and never bloat the packaged image.
[[ "$DNF_CACHE_MOUNTED" == "1" ]] && umount -q "$ROOT/var/cache/dnf" || true
umount -q "$ROOT/dev/pts" || true
umount -q "$ROOT/dev"     || true
umount -q "$ROOT/run"     || true
umount -q "$ROOT/proc"    || true
umount -q "$ROOT/sys"     || true

echo "[4/6] Creating customized rootfs.tar.xz (parallel xz)..."
WORK=/work && rm -rf "$WORK" && mkdir -p "$WORK" "$OUTDIR"
# -T0: use all cores for xz. Compression of the ~150MB rootfs is the 2nd-biggest
# build cost and single-threaded xz is especially slow under qemu emulation.
tar -C "$ROOT" --exclude=proc --exclude=sys -cf - . | xz -T0 -c > "$WORK/rootfs.tar.xz"

echo "[5/6] Preparing packaging files..."
cat > "$WORK/config" <<EOF
lxc.include = /usr/share/lxc/config/common.conf
lxc.arch = linux64
lxc.mount.auto = proc:rw sys:rw cgroup:rw
lxc.net.0.type = veth
lxc.net.0.link = lxcbr0
EOF

cat > "$WORK/templates" <<EOF
/etc/hostname
/etc/hosts
EOF

cat > "$WORK/config-user" <<EOF
lxc.include = /usr/share/lxc/config/common.conf
lxc.include = /usr/share/lxc/config/userns.conf
lxc.arch = linux64
EOF

> "$WORK/excludes-user"

# Create descriptive message with SSH info
DESCRIPTION="${DIST^} ${RELEASE} with SSH, Python, and sudo preinstalled"
if [[ -n "$SSH_USER" ]]; then
    DESCRIPTION="${DESCRIPTION}. SSH user: ${SSH_USER}"
    if [[ -n "$SSH_PASSWORD" ]]; then
        DESCRIPTION="${DESCRIPTION} (password set)"
    fi
    if [[ -n "$SSH_KEY_FILE" ]]; then
        DESCRIPTION="${DESCRIPTION} (SSH key added)"
    fi
fi

cat > "$WORK/create-message" <<EOF
$DESCRIPTION

SSH Configuration:
$(if [[ -n "$SSH_USER" ]]; then
    echo "- User: $SSH_USER"
    if [[ -n "$SSH_PASSWORD" ]]; then
        echo "- Password authentication: enabled"
    fi
    if [[ -n "$SSH_KEY_FILE" ]]; then
        echo "- SSH key authentication: enabled"
    fi
else
    echo "- No SSH user configured"
fi)
$(if [[ -n "$ROOT_PASSWORD" ]]; then
    echo "- Root password: set"
else
    echo "- Root password: not set"
fi)

To connect via SSH:
$(if [[ -n "$SSH_USER" ]]; then
    echo "ssh $SSH_USER@<container-ip>"
else
    echo "Configure SSH user first or use lxc-attach"
fi)
EOF

ZIP_NAME="${ZIP_BASENAME}.zip"
echo "[6/6] Zipping into $OUTDIR/$ZIP_NAME..."
(cd "$WORK" && zip -q "$OUTDIR/$ZIP_NAME" config excludes-user config-user rootfs.tar.xz create-message templates)

echo ""
echo "✅ Build complete!"
echo "📦 Output: $OUTDIR/$ZIP_NAME"
echo "📋 Description: $DESCRIPTION"
echo ""
echo "To use this image:"
echo "1. Unzip the file in your LXC images directory"
echo "2. Use 'lxc-create -n mycontainer -t local -- --metadata ./'"
if [[ -n "$SSH_USER" ]]; then
    echo "3. Start container and connect: ssh $SSH_USER@<container-ip>"
else
    echo "3. Start container and attach: lxc-attach -n mycontainer"
fi