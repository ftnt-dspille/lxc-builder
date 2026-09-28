#!/bin/sh
# Baked into the image at BUILD time (lxc-builder's --provision-script hook,
# runs in-chroot with network access). Gives devices/fmgfaz_onboard (in
# fabric_studio_terraform) a base image where run-onboard.sh's fast-path check
# (ansible-playbook + the fortinet.* collections already present) is true from
# first boot -- no apt/ansible-galaxy install at fabric-launch time.
set -eu

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ansible-core python3-pip python3-requests sshpass curl netcat-traditional

ansible-galaxy collection install \
    fortinet.fortios \
    fortinet.fortimanager \
    fortinet.fortianalyzer

ansible --version | head -1
echo "install-ansible-fortinet: done"
