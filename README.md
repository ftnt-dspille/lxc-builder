# LXC Image Builder

A Docker-based tool for building customized LXC container images with SSH, Python, and sudo preinstalled across multiple Linux distributions.

## Quick Start

```bash
git clone <your-repo-url>
cd lxc-image-builder

# Create environment file with SSH configuration
cp .env.template .env
nano .env  # Edit with your SSH settings

# Build with SSH user configured
./build-lxc-wrapper.sh
```

This will create a ready-to-use LXC image with SSH access in the `./out/` directory.

## SSH Configuration

### Using Environment Variables (.env file) - Recommended

Create a `.env` file for secure credential management:

```bash
# Copy the template
cp .env.template .env

# Edit with your settings
SSH_USER=admin
SSH_PASSWORD=your_secure_password
ROOT_PASSWORD=your_root_password
SSH_KEY_FILE=/path/to/your/public/key.pub
```

### Command Line Options

```bash
# Create user with password
./build-lxc-wrapper.sh --ssh-user admin --ssh-password mypassword ubuntu jammy

# Create user with SSH key (more secure)
./build-lxc-wrapper.sh --ssh-user admin --ssh-key-file ~/.ssh/id_rsa.pub debian

# Both password and key
./build-lxc-wrapper.sh --ssh-user admin --ssh-password mypass --ssh-key-file ~/.ssh/id_rsa.pub
```

### Security Best Practices

1. **Use SSH keys instead of passwords** when possible
2. **Use .env file** for credentials (automatically gitignored)
3. **Set strong passwords** if using password authentication
4. **Disable root login** in production (handled automatically when using keys only)

## Requirements

| Platform    | Requirements                                    |
| ----------- | ----------------------------------------------- |
| **Windows** | Docker Desktop with WSL2 backend                |
| **macOS**   | Docker Desktop                                  |
| **Linux**   | Docker Engine with privileged container support |

## Installation & Setup

### Windows

1. **Install Docker Desktop**

   ```powershell
   winget install Docker.DockerDesktop
   ```

2. **Enable WSL2 Backend** in Docker Desktop settings

3. **Clone and setup**
   ```powershell
   git clone <your-repo-url>
   cd lxc-image-builder
   cp .env.template .env
   # Edit .env with your SSH settings
   .\build-lxc-wrapper.sh ubuntu jammy
   ```

### macOS

1. **Install Docker Desktop**

   ```bash
   brew install --cask docker
   ```

2. **Clone and setup**
   ```bash
   git clone <your-repo-url>
   cd lxc-image-builder
   cp .env.template .env
   # Edit .env with your SSH settings
   ./build-lxc-wrapper.sh fedora 39
   ```

### Linux

1. **Install Docker Engine**

   ```bash
   curl -fsSL https://get.docker.com -o get-docker.sh
   sudo sh get-docker.sh
   sudo usermod -aG docker $USER
   ```

2. **Clone and setup**
   ```bash
   git clone <your-repo-url>
   cd lxc-image-builder
   cp .env.template .env
   # Edit .env with your SSH settings
   ./build-lxc-wrapper.sh alpine 3.19
   ```

## Supported Distributions

| Distribution    | Supported Releases          | Default Release |
| --------------- | --------------------------- | --------------- |
| **Debian**      | bookworm, trixie, sid       | trixie          |
| **Ubuntu**      | focal, jammy, noble, mantic | jammy           |
| **Fedora**      | 38, 39, 40                  | 39              |
| **CentOS**      | 8, 9                        | 9               |
| **Rocky Linux** | 8, 9                        | 9               |
| **AlmaLinux**   | 8, 9                        | 9               |
| **Alpine**      | 3.17, 3.18, 3.19, edge      | 3.19            |
| **Arch Linux**  | current                     | current         |

## Usage Examples

### Basic Usage with SSH

```bash
# Build with SSH user (using .env file)
./build-lxc-wrapper.sh

# Build Ubuntu with command line SSH options
./build-lxc-wrapper.sh --ssh-user ubuntu --ssh-password mypass ubuntu jammy

# Build with SSH key authentication
./build-lxc-wrapper.sh --ssh-user admin --ssh-key-file ~/.ssh/id_rsa.pub debian
```

### Advanced Usage

```bash
# Build with custom output and SSH configuration
./build-lxc-wrapper.sh -o /tmp/images --ssh-user devuser centos 9

# Skip Docker rebuild with SSH key
./build-lxc-wrapper.sh --no-build --ssh-key-file ~/.ssh/id_rsa.pub alpine edge

# Build minimal variant with root password
./build-lxc-wrapper.sh --root-password rootpass fedora 39 amd64 minimal
```

### Platform-Specific Examples

#### Windows (PowerShell)

```powershell
# Basic build with SSH
.\build-lxc-wrapper.sh --ssh-user admin --ssh-password mypass debian trixie

# Build with Windows paths
.\build-lxc-wrapper.sh -o "C:\LXC\Images" --ssh-user admin ubuntu jammy
```

#### macOS

```bash
# Build for development with SSH key
./build-lxc-wrapper.sh -o ~/lxc-images --ssh-key-file ~/.ssh/id_rsa.pub arch current
```

#### Linux

```bash
# Direct usage with SSH configuration
sudo ./build-lxc.sh -d alpine -r 3.19 --ssh-user alpine --ssh-password mypass

# Using Docker wrapper with custom cache
./build-lxc-wrapper.sh --cache /var/cache/lxc-builder --ssh-user admin rocky 9
```

## Project Structure

```
lxc-image-builder/
├── build-lxc.sh              # Core build script (runs inside container)
├── build-lxc-wrapper.sh      # Docker wrapper script
├── Dockerfile                # Docker image definition
├── .env.template             # Environment variable template
├── .gitignore                # Git ignore file (includes .env)
├── README.md                 # This file
├── out/                      # Generated LXC images (created automatically)
└── lxc-cache/               # Cached base images (created automatically)
```

## Configuration Options

### Environment Variables (.env file)

```bash
# Build configuration
DIST=ubuntu
RELEASE=jammy
ARCH=amd64
VARIANT=cloud

# SSH configuration
SSH_USER=admin
SSH_PASSWORD=secure_password_here
SSH_KEY_FILE=/path/to/public/key.pub
ROOT_PASSWORD=root_password_here

# Advanced options
OUTDIR=/custom/output/path
CACHE_DIR=/custom/cache/path
ZIP_BASENAME=MyCustom_LXC_Image
```

### Command Line Options

#### build-lxc-wrapper.sh

```bash
./build-lxc-wrapper.sh [OPTIONS] [DIST] [RELEASE] [ARCH] [VARIANT]

SSH Options:
  --ssh-user USER         Create SSH user with this username
  --ssh-password PASS     Set SSH password (use .env for security)
  --ssh-key-file FILE     Add SSH public key from file
  --root-password PASS    Set root password (use .env for security)

Other Options:
  -h, --help              Show help message
  -o, --output DIR        Output directory (default: ./out)
  -c, --cache DIR         Cache directory (default: ./lxc-cache)
  --no-build              Skip Docker image build
  --zip-name NAME         Custom zip filename prefix
  --docker-args ARGS      Additional Docker run arguments
```

## Using the Generated Images

After building, you'll get a zip file like `LXC_ubuntu_jammy_toolbox_amd64.zip` with SSH pre-configured.

### Method 1: Manual Installation

```bash
# Extract the image
unzip LXC_ubuntu_jammy_toolbox_amd64.zip -d /var/lib/lxc/images/ubuntu-jammy/

# Create a container
sudo lxc-create -n mycontainer -t local -- --metadata /var/lib/lxc/images/ubuntu-jammy/

# Start the container
sudo lxc-start -n mycontainer

# Get container IP and connect via SSH
CONTAINER_IP=$(sudo lxc-info -n mycontainer -iH)
ssh admin@$CONTAINER_IP  # Use your configured SSH user
```

### Method 2: Quick Connection

```bash
# Create and start container
sudo lxc-create -n mycontainer -t local -- --metadata ./
sudo lxc-start -n mycontainer

# Connect via SSH (if SSH user configured)
ssh admin@$(sudo lxc-info -n mycontainer -iH)

# Or attach directly
sudo lxc-attach -n mycontainer
```

## What's Included

Each generated LXC image includes:

- **SSH Server** - Pre-configured and ready for remote access
- **SSH User** - With password and/or key authentication (if configured)
- **Python 3** - For scripting and development
- **sudo** - Administrative access control for SSH user
- **Base system** - Minimal but functional OS
- **Working DNS** - Internet connectivity configured
- **Service management** - SystemD/OpenRC depending on distro

## Security Features

### Automatic SSH Configuration

- **Password authentication** - Enabled when SSH_PASSWORD is set
- **Key authentication** - Enabled when SSH_KEY_FILE is provided
- **Security hardening** - Automatic security settings based on auth method
- **User management** - SSH user added to sudo group automatically

### Key-Only Authentication (Recommended)

When using only SSH keys (no passwords set):

- Password authentication is automatically disabled
- Root login is disabled
- Only key-based authentication is allowed

```bash
# Example: Secure key-only setup
./build-lxc-wrapper.sh --ssh-user admin --ssh-key-file ~/.ssh/id_rsa.pub
```

## ️ Troubleshooting

### Common Issues

#### SSH Connection Problems

```bash
# Check if SSH service is running in container
sudo lxc-attach -n mycontainer -- systemctl status ssh

# Check SSH configuration
sudo lxc-attach -n mycontainer -- cat /etc/ssh/sshd_config

# Restart SSH service
sudo lxc-attach -n mycontainer -- systemctl restart ssh
```

#### Password Authentication Issues

```bash
# Verify user exists and has password set
sudo lxc-attach -n mycontainer -- id your-ssh-user
sudo lxc-attach -n mycontainer -- passwd your-ssh-user
```

#### Key Authentication Issues

```bash
# Check authorized_keys file
sudo lxc-attach -n mycontainer -- cat /home/your-ssh-user/.ssh/authorized_keys

# Verify permissions
sudo lxc-attach -n mycontainer -- ls -la /home/your-ssh-user/.ssh/
```

### Build Failures

```bash
# Check Docker logs
docker logs $(docker ps -l -q)

# Clear cache and retry
rm -rf ./lxc-cache/*
./build-lxc-wrapper.sh

# Verify SSH key file format
ssh-keygen -l -f /path/to/your/key.pub
```

## Security Considerations

### Default Security Settings

- SSH server is configured based on authentication methods provided
- Root login policy depends on whether SSH user is configured
- No default passwords are set unless explicitly configured
- SSH user is automatically added to sudo group

### Recommended Production Setup

```bash
# 1. Use SSH keys instead of passwords
SSH_USER=admin
SSH_KEY_FILE=/path/to/production/key.pub
# Don't set SSH_PASSWORD or ROOT_PASSWORD

# 2. Use strong passwords if needed
SSH_PASSWORD=$(openssl rand -base64 32)
ROOT_PASSWORD=$(openssl rand -base64 32)

# 3. Change default SSH port (manual step after container creation)
sudo lxc-attach -n mycontainer -- sed -i 's/#Port 22/Port 2222/' /etc/ssh/sshd_config
sudo lxc-attach -n mycontainer -- systemctl restart ssh
```

## Advanced Usage

### Custom SSH Configuration

After container creation, you can further customize SSH:

```bash
# Connect to container
sudo lxc-attach -n mycontainer

# Advanced SSH security
echo "AllowUsers your-ssh-user" >> /etc/ssh/sshd_config
echo "MaxAuthTries 3" >> /etc/ssh/sshd_config
echo "ClientAliveInterval 300" >> /etc/ssh/sshd_config
systemctl restart ssh
```

### Batch Building with Different SSH Configs

```bash
#!/bin/bash
# build-fleet.sh - Build multiple containers with different SSH configs

# Development container with password
SSH_USER=dev SSH_PASSWORD=devpass ./build-lxc-wrapper.sh ubuntu jammy

# Production container with key only
SSH_USER=admin SSH_KEY_FILE=~/.ssh/prod_key.pub ./build-lxc-wrapper.sh ubuntu jammy

# Testing container with both
SSH_USER=test SSH_PASSWORD=testpass SSH_KEY_FILE=~/.ssh/test_key.pub ./build-lxc-wrapper.sh alpine edge
```

## Contributing

### Security Guidelines

When contributing:

1. Never commit `.env` files or real credentials
2. Use placeholder values in documentation
3. Test SSH configurations with different authentication methods
4. Ensure backwards compatibility with existing configurations

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Support

- **Issues**: [GitHub Issues](https://github.com/ftnt-dspille/lxc-builder/issues)
- **Documentation**: This README and `--help` commands
