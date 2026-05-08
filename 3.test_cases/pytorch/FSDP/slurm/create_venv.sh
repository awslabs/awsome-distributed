#!/usr/bin/env bash
set -ex

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

PYTHON_V=python3
OS_VERSION=$(cat /etc/os-release | grep VERSION_ID | awk -F '=' '{print $2}')
OS_VERSION=${OS_VERSION//\"/}

if [ $OS_VERSION = "20.04" ]; then

   PYTHON_VERSION=$(python3.9 --version | awk '{print $2}' | awk -F'.' '{print $1"."$2}')
   PYTHON_V=python3.9
else
  PYTHON_VERSION=$(python3 --version | awk '{print $2}' | awk -F'.' '{print $1"."$2}')
fi

# Install venv package if sudo is available, otherwise assume pre-installed
if command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
    sudo apt install -y python${PYTHON_VERSION}-venv
else
    echo "No sudo access — assuming python${PYTHON_VERSION}-venv is pre-installed"
fi

# Create and actiate Python virtual environment
$PYTHON_V -m venv env
source ./env/bin/activate

pip install -U wheel setuptools
pip install -r ../src/requirements.txt

# Create checkpoint dir
mkdir checkpoints
