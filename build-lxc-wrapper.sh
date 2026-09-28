#!/bin/bash

# This script wraps the LXC image build process using Docker, which is helpful for
# users who don't want to install lxc-create or worry about cleaning up leftover files.
# It sets up build parameters, ensures output and cache directories exist,
# builds the Docker image, and runs the build in a privileged container,
# mounting necessary directories for output and caching.
# The result is a ready-to-use LXC image zip file.

set -euo pipefail

# Load environment variables from .env file if it exists
if [[ -f ".env" ]]; then
    echo "🔧 Loading environment variables from .env file..."
    # Source the file in a subshell to avoid polluting current environment with potential issues
    set -a
    source .env
    set +a
fi

show_help() {
    cat << EOF
Usage: $0 [OPTIONS] [DIST] [RELEASE] [ARCH] [VARIANT]

Docker wrapper for building customized LXC container images.

POSITIONAL ARGUMENTS:
    DIST        Distribution (default: debian)
                Supported: debian, ubuntu, fedora, centos, rockylinux, almalinux, alpine, arch
    RELEASE     Release/version (auto-detected if not specified)
    ARCH        Architecture (default: amd64)
    VARIANT     Variant (default: cloud)

OPTIONS:
    -h, --help              Show this help message
    -o, --output DIR        Output directory (default: ./out)
    -c, --cache DIR         Cache directory (default: ./lxc-cache)
    --no-build              Skip Docker image build (use existing lxc-builder image)
    --zip-name NAME         Custom zip filename prefix
    --docker-args ARGS      Additional Docker run arguments
    --ssh-user USER         Create SSH user with this username
    --ssh-password PASS     Set SSH password for the user (use .env file for security)
    --ssh-key-file FILE     Add SSH public key from file
    --root-password PASS    Set root password (use .env file for security)
    --provision-script FILE Run FILE inside the image chroot at BUILD time (bake
                            in packages/config, e.g. install Docker). Runs after
                            the standard customization, before packaging.
    --fabric-payload DIR    Copy DIR into the image rootfs at /fabric (init +
                            setup.d/) and enable a boot-time fabric-init unit that
                            runs /fabric/init on first boot.

ENVIRONMENT VARIABLES (.env file):
    Create a .env file (gitignored) with:
    SSH_USER=myuser
    SSH_PASSWORD=secure_password_here
    ROOT_PASSWORD=root_password_here
    SSH_KEY_FILE=/path/to/public/key

EXAMPLES:
    $0                                    # Build Debian Trixie (default)
    $0 ubuntu jammy                       # Build Ubuntu 22.04
    $0 fedora 39 amd64 minimal           # Build Fedora 39 minimal
    $0 -o /tmp/images alpine 3.19        # Build Alpine, output to /tmp/images
    $0 --no-build centos 9               # Use existing Docker image
    $0 --zip-name "my-custom" debian     # Custom zip filename
    $0 --ssh-user admin --ssh-key-file ~/.ssh/id_rsa.pub  # SSH with key

SUPPORTED DISTRIBUTIONS:
    debian      - Releases: bookworm, trixie, sid
    ubuntu      - Releases: focal, jammy, noble, mantic
    fedora      - Releases: 38, 39, 40
    centos      - Releases: 8, 9
    rockylinux       - Releases: 8, 9
    almalinux   - Releases: 8, 9
    alpine      - Releases: 3.17, 3.18, 3.19, edge
    arch        - Releases: current

REQUIREMENTS:
    - Docker installed and running
    - User must be able to run privileged containers

OUTPUT:
    The built LXC image will be available in the output directory as:
    LXC_\${DIST}_\${RELEASE}_toolbox_\${ARCH}.zip

SECURITY NOTES:
    - Use .env file for passwords instead of command line
    - Add .env to .gitignore to keep credentials secure
    - SSH keys are recommended over passwords for better security

EOF
}

# Default values
OUTPUT_DIR="./out"
CACHE_DIR="./lxc-cache"
DOCKER_BUILD=true
ZIP_BASENAME=""
EXTRA_DOCKER_ARGS=""

# Parse command line options
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -o|--output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -c|--cache)
            CACHE_DIR="$2"
            shift 2
            ;;
        --no-build)
            DOCKER_BUILD=false
            shift
            ;;
        --zip-name)
            ZIP_BASENAME="$2"
            shift 2
            ;;
        --releasever)
            RELEASEVER="$2"
            shift 2
            ;;
        --docker-args)
            EXTRA_DOCKER_ARGS="$2"
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
        --provision-script)
            PROVISION_SCRIPT="$2"
            shift 2
            ;;
        --fabric-payload)
            FABRIC_PAYLOAD="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "Unknown option: $1"
            echo "Use --help for usage information."
            exit 1
            ;;
        *)
            # This is a positional argument, stop parsing options
            break
            ;;
    esac
done

# Parse positional arguments
DIST="${1:-${DIST:-debian}}"
RELEASE="${2:-${RELEASE:-}}"
ARCH="${3:-${ARCH:-amd64}}"
VARIANT="${4:-${VARIANT:-cloud}}"

# Use environment variables from .env if not overridden by command line
: "${SSH_USER:=${SSH_USER:-}}"
: "${SSH_PASSWORD:=${SSH_PASSWORD:-}}"
: "${SSH_KEY_FILE:=${SSH_KEY_FILE:-}}"
: "${ROOT_PASSWORD:=${ROOT_PASSWORD:-}}"
: "${PROVISION_SCRIPT:=${PROVISION_SCRIPT:-}}"
: "${FABRIC_PAYLOAD:=${FABRIC_PAYLOAD:-}}"

# Validate Docker is available
if ! command -v docker &> /dev/null; then
    echo "❌ Error: Docker is not installed or not in PATH"
    echo "Please install Docker first:"
    echo "  - Windows/macOS: https://docs.docker.com/desktop/"
    echo "  - Linux: https://docs.docker.com/engine/install/"
    exit 1
fi

# Check if Docker is running
if ! docker info &> /dev/null; then
    echo "❌ Error: Docker daemon is not running"
    echo "Please start Docker and try again."
    exit 1
fi

# Validate distribution
case "$DIST" in
    debian|ubuntu|fedora|centos|rockylinux|almalinux|alpine|arch)
        ;;
    *)
        echo "❌ Error: Unsupported distribution '$DIST'"
        echo "Supported: debian, ubuntu, fedora, centos, rockylinux, almalinux, alpine, arch"
        exit 1
        ;;
esac

# Validate SSH key file if specified
if [[ -n "$SSH_KEY_FILE" && ! -f "$SSH_KEY_FILE" ]]; then
    echo "❌ Error: SSH key file '$SSH_KEY_FILE' not found"
    exit 1
fi

# Security warning for command line passwords
if [[ -n "$SSH_PASSWORD" ]] && ! [[ -f ".env" ]]; then
    echo "⚠️  Warning: Consider using .env file for passwords instead of command line"
fi

# Convert relative paths to absolute paths for Docker mounting
OUTPUT_DIR="$(cd "$(dirname "$OUTPUT_DIR")" && pwd)/$(basename "$OUTPUT_DIR")"
CACHE_DIR="$(cd "$(dirname "$CACHE_DIR")" && pwd)/$(basename "$CACHE_DIR")"

# If SSH key file is specified, convert to absolute path and validate it exists
if [[ -n "$SSH_KEY_FILE" ]]; then
    if [[ "$SSH_KEY_FILE" == /* ]]; then
        # Already absolute path
        SSH_KEY_FILE_ABS="$SSH_KEY_FILE"
    else
        # Convert relative path to absolute
        SSH_KEY_FILE_ABS="$(cd "$(dirname "$SSH_KEY_FILE")" && pwd)/$(basename "$SSH_KEY_FILE")"
    fi

    if [[ ! -f "$SSH_KEY_FILE_ABS" ]]; then
        echo "❌ Error: SSH key file '$SSH_KEY_FILE_ABS' not found"
        exit 1
    fi
    SSH_KEY_FILE="$SSH_KEY_FILE_ABS"
fi

# Resolve + validate the provision script (run in-chroot at build time)
if [[ -n "$PROVISION_SCRIPT" ]]; then
    if [[ ! -f "$PROVISION_SCRIPT" ]]; then
        echo "❌ Error: provision script '$PROVISION_SCRIPT' not found"
        exit 1
    fi
    PROVISION_SCRIPT="$(cd "$(dirname "$PROVISION_SCRIPT")" && pwd)/$(basename "$PROVISION_SCRIPT")"
fi

# Resolve + validate the fabric payload dir (copied into the rootfs at /fabric)
if [[ -n "$FABRIC_PAYLOAD" ]]; then
    if [[ ! -d "$FABRIC_PAYLOAD" ]]; then
        echo "❌ Error: fabric payload '$FABRIC_PAYLOAD' is not a directory"
        exit 1
    fi
    FABRIC_PAYLOAD="$(cd "$FABRIC_PAYLOAD" && pwd)"
fi

# Ensure directories exist
echo "📁 Creating directories..."
mkdir -p "$OUTPUT_DIR" "$CACHE_DIR" "$CACHE_DIR/dnf"

# Build Docker image if requested
if [ "$DOCKER_BUILD" = true ]; then
    echo "🔨 Building Docker image..."
    if ! docker build -t lxc-builder . -q; then
        echo "❌ Error: Failed to build Docker image"
        echo "Make sure Dockerfile is present in the current directory"
        exit 1
    fi
    echo "✅ Docker image built successfully"
else
    echo "⏭️  Skipping Docker build (using existing lxc-builder image)"
    # Check if image exists
    if ! docker image inspect lxc-builder &> /dev/null; then
        echo "❌ Error: lxc-builder image not found"
        echo "Run without --no-build to build the image first"
        exit 1
    fi
fi

# Prepare environment variables
ENV_ARGS="-e DIST=$DIST -e ARCH=$ARCH -e VARIANT=$VARIANT"
if [[ -n "$RELEASE" ]]; then
    ENV_ARGS="$ENV_ARGS -e RELEASE=$RELEASE"
fi
if [[ -n "${RELEASEVER:-}" ]]; then
    ENV_ARGS="$ENV_ARGS -e RELEASEVER=$RELEASEVER"
fi
if [[ -n "${INSECURE_TLS:-}" ]]; then
    ENV_ARGS="$ENV_ARGS -e INSECURE_TLS=$INSECURE_TLS"
fi
if [[ -n "$ZIP_BASENAME" ]]; then
    ENV_ARGS="$ENV_ARGS -e ZIP_BASENAME=$ZIP_BASENAME"
fi

# Add SSH configuration to environment
if [[ -n "$SSH_USER" ]]; then
    ENV_ARGS="$ENV_ARGS -e SSH_USER=$SSH_USER"
fi
if [[ -n "$SSH_PASSWORD" ]]; then
    ENV_ARGS="$ENV_ARGS -e SSH_PASSWORD=$SSH_PASSWORD"
fi
if [[ -n "$ROOT_PASSWORD" ]]; then
    ENV_ARGS="$ENV_ARGS -e ROOT_PASSWORD=$ROOT_PASSWORD"
fi

echo "Debug: SSH_USER=$SSH_USER"
echo "Debug: SSH_PASSWORD is set: $([[ -n "$SSH_PASSWORD" ]] && echo "YES" || echo "NO")"

# Prepare volume mounts. /dnf-cache persists downloaded rpms across builds
# (build-lxc.sh bind-mounts it into the chroot's /var/cache/dnf).
VOLUME_ARGS="-v $OUTPUT_DIR:/out -v $CACHE_DIR:/var/cache/lxc -v $CACHE_DIR/dnf:/dnf-cache"

# Mount SSH key file if specified
if [[ -n "$SSH_KEY_FILE" ]]; then
    VOLUME_ARGS="$VOLUME_ARGS -v $SSH_KEY_FILE:/ssh_key:ro"
    ENV_ARGS="$ENV_ARGS -e SSH_KEY_FILE=/ssh_key"
fi

# Mount the provision script + fabric payload (consumed by build-lxc.sh)
if [[ -n "$PROVISION_SCRIPT" ]]; then
    VOLUME_ARGS="$VOLUME_ARGS -v $PROVISION_SCRIPT:/provision.sh:ro"
    ENV_ARGS="$ENV_ARGS -e PROVISION_SCRIPT=/provision.sh"
    # Also mount the agent image tar if it exists next to the provision script
    AGENT_TAR="$(dirname "$PROVISION_SCRIPT")/agent_765.tar"
    if [[ -f "$AGENT_TAR" ]]; then
        VOLUME_ARGS="$VOLUME_ARGS -v $AGENT_TAR:/agent_765.tar:ro"
        ENV_ARGS="$ENV_ARGS -e AGENT_TAR=/agent_765.tar"
    fi
fi
if [[ -n "$FABRIC_PAYLOAD" ]]; then
    VOLUME_ARGS="$VOLUME_ARGS -v $FABRIC_PAYLOAD:/fabric-payload:ro"
    ENV_ARGS="$ENV_ARGS -e FABRIC_PAYLOAD=/fabric-payload"
fi

# Show build information
echo ""
echo "🚀 Starting LXC image build..."
echo "   Distribution: $DIST"
echo "   Release:      ${RELEASE:-auto-detect}"
echo "   Architecture: $ARCH"
echo "   Variant:      $VARIANT"
echo "   Output dir:   $OUTPUT_DIR"
echo "   Cache dir:    $CACHE_DIR"
if [[ -n "$SSH_USER" ]]; then
    echo "   SSH User:     $SSH_USER"
    [[ -n "$SSH_PASSWORD" ]] && echo "   SSH Password: [SET]"
    [[ -n "$SSH_KEY_FILE" ]] && echo "   SSH Key:      $SSH_KEY_FILE"
fi
[[ -n "$ROOT_PASSWORD" ]] && echo "   Root Password: [SET]"
echo ""

# Check for privileged Docker support
echo "⚠️  Note: Running privileged container (required for LXC operations)"

# Run the container
echo "🐳 Running Docker container..."
# shellcheck disable=SC2086
if docker run --rm --privileged \
    $VOLUME_ARGS \
    $ENV_ARGS \
    $EXTRA_DOCKER_ARGS \
    lxc-builder; then

    echo ""
    echo "✅ Build complete!"
    echo ""
    echo "📂 Output files:"
    ls -la "$OUTPUT_DIR"
    echo ""
    echo "🔐 SSH Connection Info:"
    if [[ -n "$SSH_USER" ]]; then
        echo "   User: $SSH_USER"
        if [[ -n "$SSH_PASSWORD" ]]; then
            echo "   Password: [as configured]"
        fi
        if [[ -n "$SSH_KEY_FILE" ]]; then
            echo "   Key authentication: enabled"
        fi
        echo "   Connect: ssh $SSH_USER@<container-ip>"
    else
        echo "   No SSH user configured - use lxc-attach"
    fi
    echo ""
    echo "💡 Next steps:"
    echo "   1. Extract the zip file to your LXC images directory"
    echo "   2. Create a container: lxc-create -n mycontainer -t local -- --metadata ./"
    echo "   3. Start the container: lxc-start -n mycontainer"
    if [[ -n "$SSH_USER" ]]; then
        echo "   4. Connect via SSH: ssh $SSH_USER@\$(lxc-info -n mycontainer -iH)"
    else
        echo "   4. Connect to container: lxc-attach -n mycontainer"
    fi
else
    echo ""
    echo "❌ Build failed!"
    echo ""
    echo "🔍 Troubleshooting tips:"
    echo "   - Ensure Docker has privileged container support"
    echo "   - Check that the distribution/release combination is valid"
    echo "   - Verify internet connectivity for downloading base images"
    echo "   - Check Docker logs: docker logs <container-id>"
    echo "   - Verify SSH key file permissions and format"
    exit 1
fi