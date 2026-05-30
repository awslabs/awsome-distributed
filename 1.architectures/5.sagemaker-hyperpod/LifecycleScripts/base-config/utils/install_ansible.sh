#!/bin/bash

set -ex

# Ansible Version
ANSIBLE_VERSION="10.7.0"

# Install Ansible and collections: Move to higher LCS once others start using Ansible too.
install_ansible()
{
    apt-get update
    # apt-get install -y ansible=$ANSIBLE_VERSION
    apt-get install -y python3-pip
    python3 -m pip install --break-system-packages "ansible==${ANSIBLE_VERSION}"
    ansible-galaxy collection install ansible.posix

    # Verify ansible installation
    echo "Ansible version:"
    ansible --version
}

main()
{
    echo "Installing Ansible..."
    install_ansible
}

main