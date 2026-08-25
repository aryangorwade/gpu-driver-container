ARG BASE_IMAGE=ubuntu:noble-20260730.1
ARG SYFT_IMAGE=docker.io/anchore/syft:v1.51.0@sha256:678bfa565b60f747aac0f8e964fe5588a24445b8d0a480e91f6efd70020dfbb0
ARG JQ_IMAGE=ghcr.io/jqlang/jq:1.8.1@sha256:4f34c6d23f4b1372ac789752cc955dc67c2ae177eb1b5860b75cdc5091ce6f91

FROM ${SYFT_IMAGE} AS syft
FROM ${JQ_IMAGE} AS jq

FROM ${BASE_IMAGE} AS runtime

ENV DEBIAN_FRONTEND=noninteractive

ARG BASE_URL=https://us.download.nvidia.com/tesla
ARG TARGETARCH
ENV TARGETARCH=$TARGETARCH
ARG DRIVER_BRANCH=550
ENV DRIVER_BRANCH=$DRIVER_BRANCH
ARG DRIVER_VERSION=550.90.12
ENV DRIVER_VERSION=$DRIVER_VERSION

ARG KERNEL_VERSION=6.8.0-44-generic
ENV KERNEL_VERSION=$KERNEL_VERSION

ARG GIT_COMMIT

ENV NVIDIA_VISIBLE_DEVICES=void

RUN echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections

# Add i386 architecture only for amd64 builds (not available on ARM)
RUN if [ "$TARGETARCH" = "amd64" ]; then dpkg --add-architecture i386; fi && \
    apt-get update && apt-get install -y --no-install-recommends \
        apt-utils \
        build-essential \
        ca-certificates \
        curl \
        kmod \
        file \
        libelf-dev \
        libglvnd-dev \
        pkg-config && \
    rm -rf /var/lib/apt/lists/*

# Fetch GPG keys for CUDA repo (architecture-specific)
RUN CUDA_ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "sbsa" || echo "x86_64") && \
    rm -f /etc/apt/sources.list.d/cuda* && \
    curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/${CUDA_ARCH}/cuda-keyring_1.1-1_all.deb -o cuda-keyring_1.1-1_all.deb && \
    dpkg -i cuda-keyring_1.1-1_all.deb && \
    rm -f cuda-keyring_1.1-1_all.deb

RUN usermod -o -u 0 -g 0 _apt

# Install / upgrade packages here that are required to resolve CVEs
ARG CVE_UPDATES
RUN if [ -n "${CVE_UPDATES}" ]; then \
        apt-get update && apt-get --only-upgrade -y install ${CVE_UPDATES} && \
        rm -rf /var/lib/apt/lists/*; \
    fi

COPY nvidia-driver /usr/local/bin

ADD local-repo.sh /tmp

RUN mkdir -p /usr/local/repos && \
    /tmp/local-repo.sh download_driver_package_deps && \
    /tmp/local-repo.sh build_local_apt_repo && \
    /tmp/local-repo.sh fetch_nvidia_installer && \
    # Remove all other ubuntu apt sources to ensure we only pull from the local apt repo
    rm /etc/apt/sources.list.d/*

WORKDIR  /drivers

LABEL io.k8s.display-name="NVIDIA Driver Container"
LABEL name="NVIDIA Driver Container"
LABEL vendor="NVIDIA"
LABEL version="${DRIVER_BRANCH}-${KERNEL_VERSION}"
LABEL vcs-ref="${GIT_COMMIT}"
LABEL release="N/A"
LABEL summary="Provision the NVIDIA driver through containers"
LABEL description="See summary"

# Generate third-party notices from the completed runtime filesystem in a
# disposable stage. Syft, jq, and the generator never reach the shipped image.
#
# The unmanaged-file audit only reports here. These images need a kernel version
# matched to published driver packages to build, so the audit has never run
# against one. Making it fatal untested could break a build this change cannot
# exercise. Drop TPN_AUDIT_UNMANAGED once a build has been seen to pass.
FROM runtime AS tpn

ARG GIT_COMMIT
ARG KERNEL_VERSION
ARG CVE_UPDATES

COPY --from=syft /syft /tmp/tpn-tools/syft
COPY --from=jq /jq /tmp/tpn-tools/jq
COPY generate-in-image-tpn.sh /tmp/generate-in-image-tpn.sh
RUN PATH="/tmp/tpn-tools:${PATH}" \
    SYFT=/tmp/tpn-tools/syft \
    JQ=/tmp/tpn-tools/jq \
    TPN_AUDIT_UNMANAGED=0 \
    bash /tmp/generate-in-image-tpn.sh /licenses

FROM runtime

COPY --from=tpn /licenses /licenses

ENTRYPOINT ["nvidia-driver", "init"]
