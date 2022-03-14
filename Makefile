# ENVTEST_K8S_VERSION refers to the version of kubebuilder assets to be downloaded by envtest binary.
ENVTEST_K8S_VERSION = 1.22

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# Setting SHELL to bash allows bash commands to be executed by recipes.
# This is a requirement for 'setup-envtest.sh' in the test target.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

KUSTOMIZE = $(shell pwd)/bin/kustomize
kustomize: ## Download kustomize locally if necessary.
	$(call go-get-tool,$(KUSTOMIZE),sigs.k8s.io/kustomize/kustomize/v3@v3.8.7)

ENVTEST = $(shell pwd)/bin/setup-envtest
envtest: ## Download envtest-setup locally if necessary.
	$(call go-get-tool,$(ENVTEST),sigs.k8s.io/controller-runtime/tools/setup-envtest@latest)

# go-get-tool will 'go get' any package $2 and install it to $1.
PROJECT_DIR := $(shell dirname $(abspath $(lastword $(MAKEFILE_LIST))))
define go-get-tool
@[ -f $(1) ] || { \
set -e ;\
TMP_DIR=$$(mktemp -d) ;\
cd $$TMP_DIR ;\
go mod init tmp ;\
echo "Downloading $(2)" ;\
GOBIN=$(PROJECT_DIR)/bin go get $(2) ;\
rm -rf $$TMP_DIR ;\
}
endef

# Image URL to use all building/pushing image targets
IMG ?= k8s.gcr.io/sig-storage/nfs-provisioner:v3.0.0

##@ Build

docker-build: ## Build docker image with the manager.
	docker build -t ${IMG} .

docker-push: ## Push docker image with the manager.
	docker push ${IMG}

.PHONY: manifests
manifests: kustomize
	cd config/nfs && $(KUSTOMIZE) edit set image k8s.gcr.io/sig-storage/nfs-provisioner=${IMG}
	$(KUSTOMIZE) build config/default --output config/samples/manifests.yaml

.PHONY: deploy
deploy: manifests
	@echo kubectl apply -f config/samples/manifests.yaml

.PHONY: undeploy
undeploy: manifests
	@echo kubectl delete -f config/samples/manifests.yaml

# ===============================================================================================
# Code below has been added for custom builds using podman
# formatting color values
RD="$(shell tput setaf 1)"
YE="$(shell tput setaf 3)"
NC="$(shell tput sgr0)"

# Image URL to use all building/pushing image targets to
# Google artifact registry
NAME=nfs
CATEGORY=services
TAG=3.0.1-dev-0
REPO=us-central1-docker.pkg.dev/${PROJECT}
IMG_BASE=${REPO}/artifacts/${CATEGORY}/${NAME}
ARCH=$(shell go env GOHOSTARCH)

# sanity check
.PHONY: _sanity
_sanity:
	@if [[ -z "${PROJECT}" ]]; then \
		echo "please set PROJECT env. var for your Google cloud project"; \
		exit 1; \
	fi
	@for cmd in podman; do \
		if [[ -z $$(command -v $${cmd}) ]]; then \
			echo "$${cmd} not found. pl. install."; \
			exit 1; \
		fi; \
	done

# podman-build builds amd64 and arm64 containers when
# the command is run on respective architectures
.PHONY: podman-build
podman-build: _sanity
	@echo -e ${YE}▶ building ${ARCH} container${NC}
	@podman build -t ${IMG_BASE}:${TAG}.${ARCH} ./

# podman-push expects amd64 and arm64 container images to be
# present on the machine. it then pushes both and links them
# in a manifest
.PHONY: podman-push
podman-push: _sanity
	@echo -e ${YE}▶ pushing amd64 container${NC}
	@podman push ${IMG_BASE}:${TAG}.amd64
	@echo -e ${YE}▶ pushing arm64 container${NC}
	@podman push ${IMG_BASE}:${TAG}.arm64
	@echo -e ${YE}▶ creating or modifying manifest${NC}
	@podman manifest create ${IMG_BASE}:${TAG} || \
		for digest in $$(podman manifest inspect ${IMG_BASE}:${TAG} | jq -r '.manifests[].digest'); do \
			podman manifest remove ${IMG_BASE}:${TAG} $${digest}; \
		done
	@echo -e ${YE}▶ adding amd64 container to manifest${NC}
	@podman manifest add ${IMG_BASE}:${TAG} ${IMG_BASE}:${TAG}.amd64
	@echo -e ${YE}▶ adding arm64 container to manifest${NC}
	@podman manifest add ${IMG_BASE}:${TAG} ${IMG_BASE}:${TAG}.arm64
	@echo -e ${YE}▶ pushing manifest${NC}
	@podman push ${IMG_BASE}:${TAG}
	@podman manifest inspect ${IMG_BASE}:${TAG} | jq '.'
	@echo -e ${YE}▶ container images${NC}
	@podman images | grep ${IMG_BASE}

.PHONY: _manifests
_manifests: kustomize
	cd config/nfs && $(KUSTOMIZE) edit set image k8s.gcr.io/sig-storage/nfs-provisioner=${IMG_BASE}:${TAG}
	$(KUSTOMIZE) build config/default --output config/extra/manifests.yaml
	cd config/nfs && $(KUSTOMIZE) edit set image k8s.gcr.io/sig-storage/nfs-provisioner=k8s.gcr.io/sig-storage/nfs-provisioner:v3.0.0
	$(KUSTOMIZE) build config/extra --output config/samples/manifests.yaml

# deploy-manifests creates manifests with custom updates of image name
.PHONY: deploy-manifests
deploy-manifests: _manifests
	@echo kubectl apply -f config/samples/manifests.yaml

.PHONY: undeploy-manifests
undeploy-manifests: _manifests
	@echo kubectl delete -f config/samples/manifests.yaml

.PHONY: deploy-examples
deploy-examples: kustomize
	$(KUSTOMIZE) build config/samples | kubectl apply -f -

.PHONY: undeploy-examples
undeploy-examples: kustomize
	$(KUSTOMIZE) build config/samples | kubectl delete -f -
