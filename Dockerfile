# Copyright 2017 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# build nfs-provisioner binary
FROM docker.io/library/golang:1.17.8 AS builder
WORKDIR /workspace
RUN git clone https://github.com/kubernetes-sigs/nfs-ganesha-server-and-external-provisioner.git
WORKDIR /workspace/nfs-ganesha-server-and-external-provisioner
RUN git checkout tags/v3.0.1
RUN mkdir -p bin
RUN go build -o bin/nfs-provisioner ./cmd/nfs-provisioner/

# Modified from https://github.com/rootfs/nfs-ganesha-docker by Huamin Chen
FROM docker.io/library/ubuntu:20.04

RUN apt-get update \
    && apt-get install -y nfs-ganesha nfs-ganesha-vfs dbus-x11 rpcbind hostname libnfs-utils xfsprogs libjemalloc2 libnfsidmap2 \
    && ln -sf ../proc/self/mounts /etc/mtab \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/run/dbus
RUN mkdir -p /export

# expose mountd 20048/tcp and nfsd 2049/tcp and rpcbind 111/tcp 111/udp
EXPOSE 2049/tcp 20048/tcp 111/tcp 111/udp

ARG binary=bin/nfs-provisioner
COPY --from=builder /workspace/nfs-ganesha-server-and-external-provisioner/${binary} /nfs-provisioner

ENTRYPOINT ["/nfs-provisioner"]
