# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

ENROOT_IMAGE := lerobot-pi0-fast-droid

all: build clean import

build:
	docker build -t ${ENROOT_IMAGE} -f Dockerfile .

clean:
	-rm ${ENROOT_IMAGE}.sqsh

import:
	enroot import -o ${ENROOT_IMAGE}.sqsh dockerd://${ENROOT_IMAGE}:latest
