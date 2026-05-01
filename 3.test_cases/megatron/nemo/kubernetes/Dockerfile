FROM nvcr.io/nvidia/nemo:25.04.01
ARG GDRCOPY_VERSION=v2.4.1
ARG EFA_INSTALLER_VERSION=1.37.0
ARG AWS_OFI_NCCL_VERSION=v1.13.2-aws
ARG NCCL_VERSION=v2.23.4-1
ARG NCCL_TESTS_VERSION=v2.13.10
ARG TRANSFORMERS_VERSION=4.48.1

ARG OPEN_MPI_PATH=/opt/amazon/openmpi

######################
# Update and remove the IB libverbs
######################
RUN apt-get update -y && apt-get upgrade -y
RUN apt-get remove -y --allow-change-held-packages \
    ibverbs-utils \
    libibverbs-dev \
    libibverbs1 \
    libmlx5-1

RUN rm -rf /opt/hpcx/ompi \
    && rm -rf /usr/local/mpi \
    && rm -rf /usr/local/ucx \
    && ldconfig

RUN DEBIAN_FRONTEND=noninteractive apt install -y --allow-unauthenticated \
    apt-utils \
    autoconf \
    automake \
    build-essential \
    cmake \
    curl \
    gcc \
    gdb \
    git \
    kmod \
    libtool \
    openssh-client \
    openssh-server \
    vim \
    && apt autoremove -y

RUN mkdir -p /var/run/sshd && \
    sed -i 's/[ #]\(.*StrictHostKeyChecking \).*/ \1no/g' /etc/ssh/ssh_config && \
    echo "    UserKnownHostsFile /dev/null" >> /etc/ssh/ssh_config && \
    sed -i 's/#\(StrictModes \).*/\1no/g' /etc/ssh/sshd_config && \
    sed 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' -i /etc/pam.d/sshd

RUN rm -rf /root/.ssh/ \
 && mkdir -p /root/.ssh/ \
 && ssh-keygen -q -t rsa -N '' -f /root/.ssh/id_rsa \
 && cp /root/.ssh/id_rsa.pub /root/.ssh/authorized_keys \
 && printf "Host *\n  StrictHostKeyChecking no\n" >> /root/.ssh/config

ENV LD_LIBRARY_PATH=/usr/local/cuda/extras/CUPTI/lib64:/opt/amazon/openmpi/lib:/opt/nccl/build/lib:/opt/amazon/efa/lib:/opt/aws-ofi-nccl/install/lib:$LD_LIBRARY_PATH
ENV PATH=/opt/amazon/openmpi/bin/:/opt/amazon/efa/bin:/usr/bin:/usr/local/bin:$PATH

######################
# Install libcheck
######################
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        check pkg-config

#################################################
## Install NVIDIA GDRCopy
##
## NOTE: if `nccl-tests` or `/opt/gdrcopy/bin/sanity -v` crashes with incompatible version, ensure
## that the cuda-compat-xx-x package is the latest.
RUN git clone -b ${GDRCOPY_VERSION} https://github.com/NVIDIA/gdrcopy.git /tmp/gdrcopy \
    && cd /tmp/gdrcopy \
    && make prefix=/opt/gdrcopy install

ENV LD_LIBRARY_PATH /opt/gdrcopy/lib:/usr/local/cuda/compat:$LD_LIBRARY_PATH
ENV LIBRARY_PATH /opt/gdrcopy/lib:/usr/local/cuda/compat/:$LIBRARY_PATH
ENV CPATH /opt/gdrcopy/include:$CPATH
ENV PATH /opt/gdrcopy/bin:$PATH

#################################################
## Install EFA installer
RUN cd $HOME \
    && curl -O https://efa-installer.amazonaws.com/aws-efa-installer-${EFA_INSTALLER_VERSION}.tar.gz \
    && tar -xf $HOME/aws-efa-installer-${EFA_INSTALLER_VERSION}.tar.gz \
    && cd aws-efa-installer \
    && ./efa_installer.sh -y -g -d --skip-kmod --skip-limit-conf --no-verify \
    && rm -rf $HOME/aws-efa-installer


###################################################
## Install AWS-OFI-NCCL plugin
RUN DEBIAN_FRONTEND=noninteractive apt-get install -y libhwloc-dev
#Switch from sh to bash to allow parameter expansion
SHELL ["/bin/bash", "-c"]
RUN curl -OL https://github.com/aws/aws-ofi-nccl/releases/download/${AWS_OFI_NCCL_VERSION}/aws-ofi-nccl-${AWS_OFI_NCCL_VERSION//v}.tar.gz \
    && tar -xf aws-ofi-nccl-${AWS_OFI_NCCL_VERSION//v}.tar.gz \
    && cd aws-ofi-nccl-${AWS_OFI_NCCL_VERSION//v} \
    && ./configure --prefix=/opt/aws-ofi-nccl/install \
        --with-mpi=/opt/amazon/openmpi \
        --with-libfabric=/opt/amazon/efa \
        --with-cuda=/usr/local/cuda \
        --enable-platform-aws \
    && make -j $(nproc) \
    && make install \
    && cd .. \
    && rm -rf aws-ofi-nccl-${AWS_OFI_NCCL_VERSION//v} \
    && rm aws-ofi-nccl-${AWS_OFI_NCCL_VERSION//v}.tar.gz

SHELL ["/bin/sh", "-c"]

###################################################
RUN rm -rf /var/lib/apt/lists/*

RUN echo "hwloc_base_binding_policy = none" >> /opt/amazon/openmpi/etc/openmpi-mca-params.conf \
 && echo "rmaps_base_mapping_policy = slot" >> /opt/amazon/openmpi/etc/openmpi-mca-params.conf

RUN pip3 install awscli pynvml wandb

RUN mv $OPEN_MPI_PATH/bin/mpirun $OPEN_MPI_PATH/bin/mpirun.real \
 && echo '#!/bin/bash' > $OPEN_MPI_PATH/bin/mpirun \
 && echo '/opt/amazon/openmpi/bin/mpirun.real "$@"' >> $OPEN_MPI_PATH/bin/mpirun \
 && chmod a+x $OPEN_MPI_PATH/bin/mpirun

######################
# Transformers dependencies used in the model
######################
RUN pip install transformers==${TRANSFORMERS_VERSION} sentencepiece python-etcd

ENV OPAL_PREFIX=/opt/amazon/openmpi \
    NCCL_SOCKET_IFNAME=^docker,lo,veth

## Turn off PMIx Error https://github.com/open-mpi/ompi/issues/7516
ENV PMIX_MCA_gds=hash
