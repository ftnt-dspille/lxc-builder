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

: "${ZIP_BASENAME:=LXC_${DIST}_${RELEASE}_toolbox_${ARCH}}"

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
            PACKAGES="dhcpcd-base ifupdown openssh-server python3 sudo"
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

# Install packages based on distribution
echo "Installing packages: $PACKAGES"
chroot "$ROOT" $CHROOT_SHELL -c "
    $PKG_UPDATE && $PKG_INSTALL $PACKAGES
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

    # If no password authentication is desired and we have keys, disable passwords
    if [[ -n '$SSH_KEY_FILE' && -z '$SSH_PASSWORD' && -z '$ROOT_PASSWORD' ]]; then
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
esac

# --- unmount before packaging ---
umount -q "$ROOT/dev/pts" || true
umount -q "$ROOT/dev"     || true
umount -q "$ROOT/run"     || true
umount -q "$ROOT/proc"    || true
umount -q "$ROOT/sys"     || true

echo "[4/6] Creating customized rootfs.tar.xz..."
WORK=/work && rm -rf "$WORK" && mkdir -p "$WORK" "$OUTDIR"
tar -C "$ROOT" -cJf "$WORK/rootfs.tar.xz" --exclude=proc --exclude=sys .

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