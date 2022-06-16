REGISTRY ?= ghcr.io/azure
HUB_AGENT_IMAGE_NAME ?= hub-agent
HUB_AGENT_IMAGE_VERSION ?= v0.1.0
MEMBER_AGENT_IMAGE_NAME ?= member-agent
MEMBER_AGENT_IMAGE_VERSION ?= v0.1.0
REFRESH_TOKEN_IMAGE_NAME := refresh-token
REFRESH_TOKEN_IMAGE_VERSION ?= v0.1.0
HUB_KUBECONFIG ?=$(KUBECONFIG)
HUB_KUBECONFIG_CONTEXT ?=$(shell kubectl --kubeconfig $(HUB_KUBECONFIG) config current-context)
MEMBER_KUBECONFIG ?=$(KUBECONFIG)
MEMBER_KUBECONFIG_CONTEXT ?=$(shell kubectl --kubeconfig $(MEMBER_KUBECONFIG) config current-context)


# Directories
ROOT_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))
TOOLS_DIR := hack/tools
TOOLS_BIN_DIR := $(abspath $(TOOLS_DIR)/bin)

# Binaries
# Note: Need to use abspath so we can invoke these from subdirectories

CONTROLLER_GEN_VER := v0.7.0
CONTROLLER_GEN_BIN := controller-gen
CONTROLLER_GEN := $(abspath $(TOOLS_BIN_DIR)/$(CONTROLLER_GEN_BIN)-$(CONTROLLER_GEN_VER))

STATICCHECK_VER := 2022.1
STATICCHECK_BIN := staticcheck
STATICCHECK := $(abspath $(TOOLS_BIN_DIR)/$(STATICCHECK_BIN)-$(STATICCHECK_VER))

GOIMPORTS_VER := latest
GOIMPORTS_BIN := goimports
GOIMPORTS := $(abspath $(TOOLS_BIN_DIR)/$(GOIMPORTS_BIN)-$(GOIMPORTS_VER))

GOLANGCI_LINT_VER := v1.41.1
GOLANGCI_LINT_BIN := golangci-lint
GOLANGCI_LINT := $(abspath $(TOOLS_BIN_DIR)/$(GOLANGCI_LINT_BIN)-$(GOLANGCI_LINT_VER))

# ENVTEST_K8S_VERSION refers to the version of kubebuilder assets to be downloaded by envtest binary.
ENVTEST_K8S_VER = v0.0.0-20211110210527-619e6b92dab9
ENVTEST_K8S_BIN := setup-envtest
ENVTEST :=  $(abspath $(TOOLS_BIN_DIR)/$(ENVTEST_K8S_BIN)-$(ENVTEST_K8S_VER))

# Scripts
GO_INSTALL := ./hack/go-install.sh

## --------------------------------------
## Tooling Binaries
## --------------------------------------

$(GOLANGCI_LINT):
	GOBIN=$(TOOLS_BIN_DIR) $(GO_INSTALL) github.com/golangci/golangci-lint/cmd/golangci-lint $(GOLANGCI_LINT_BIN) $(GOLANGCI_LINT_VER)

$(CONTROLLER_GEN):
	GOBIN=$(TOOLS_BIN_DIR) $(GO_INSTALL) sigs.k8s.io/controller-tools/cmd/controller-gen $(CONTROLLER_GEN_BIN) $(CONTROLLER_GEN_VER)

# Style checks
$(STATICCHECK):
	GOBIN=$(TOOLS_BIN_DIR) $(GO_INSTALL) honnef.co/go/tools/cmd/staticcheck $(STATICCHECK_BIN) $(STATICCHECK_VER)

# GOIMPORTS
$(GOIMPORTS):
	GOBIN=$(TOOLS_BIN_DIR) $(GO_INSTALL) golang.org/x/tools/cmd/goimports $(GOIMPORTS_BIN) $(GOIMPORTS_VER)

# ENVTEST
$(ENVTEST):
	GOBIN=$(TOOLS_BIN_DIR) $(GO_INSTALL) sigs.k8s.io/controller-runtime/tools/setup-envtest $(ENVTEST_K8S_BIN) $(ENVTEST_K8S_VER) 

## --------------------------------------
## Linting
## --------------------------------------

.PHONY: lint
lint: $(GOLANGCI_LINT)
	$(GOLANGCI_LINT) run -v

.PHONY: lint-full
lint-full: $(GOLANGCI_LINT) ## Run slower linters to detect possible issues
	$(GOLANGCI_LINT) run -v --fast=false

## --------------------------------------
## Development
## --------------------------------------

staticcheck: $(STATICCHECK)
	$(STATICCHECK) ./...

.PHONY: fmt
fmt:  $(GOIMPORTS) ## Run go fmt against code.
	go fmt ./...
	$(GOIMPORTS) -local go.goms.io/fleet -w $$(go list -f {{.Dir}} ./...)

.PHONY: vet
vet: ## Run go vet against code.
	go vet ./...

## --------------------------------------
## test
## --------------------------------------

.PHONY: test
test: manifests generate fmt vet local-unit-test ## Run tests.

.PHONY: local-unit-test
local-unit-test: ## Run local tests.
	CGO_ENABLED=1 KUBEBUILDER_ASSETS="$(shell $(ENVTEST) use $(ENVTEST_K8S_VERSION) -p path)" go test ./pkg/... -race -coverprofile=coverage.xml -covermode=atomic -v

cluster-ip:
	kubectl config use-context $(HUB_KUBECONFIG_CONTEXT) --kubeconfig $(HUB_KUBECONFIG)
  	CLUSTER_IP?=$(shell kubectl --kubeconfig $(HUB_KUBECONFIG) get svc kubernetes -n default -o jsonpath="{.spec.clusterIP}")

e2e-hub-kubeconfig-secret: cluster-ip
	cp $(HUB_KUBECONFIG) e2e-hub-kubeconfig
	kubectl config set clusters.$(HUB_KUBECONFIG_CONTEXT).server https://$(CLUSTER_IP) --kubeconfig e2e-hub-kubeconfig
	kubectl delete secret hub-kubeconfig-secret -n fleet-system --ignore-not-found --kubeconfig $(MEMBER_KUBECONFIG)
	kubectl create secret generic hub-kubeconfig-secret --from-file=kubeconfig=e2e-hub-kubeconfig -n fleet-system --kubeconfig $(MEMBER_KUBECONFIG)
	rm ./e2e-hub-kubeconfig

build-e2e:
	go test -c ./test/e2e

.PHONY: e2e-tests
e2e-tests: build-e2e e2e-hub-kubeconfig-secret
	./e2e.test -test.v -ginkgo.v

.PHONY: reviewable
reviewable: fmt vet lint staticcheck
	go mod tidy

## --------------------------------------
## Code Generation
## --------------------------------------

# Produce CRDs that work back to Kubernetes 1.11 (no version conversion)
CRD_OPTIONS ?= "crd:crdVersions=v1"

# Generate manifests e.g. CRD, RBAC etc.
.PHONY: manifests
manifests: $(CONTROLLER_GEN)
	$(CONTROLLER_GEN) \
		$(CRD_OPTIONS) rbac:roleName=manager-role webhook paths="./..." output:crd:artifacts:config=config/crd/bases

# Generate code
generate: $(CONTROLLER_GEN)
	$(CONTROLLER_GEN) \
		object:headerFile="hack/boilerplate.go.txt" paths="./..."

## --------------------------------------
## Build
## --------------------------------------

.PHONY: build
build: generate fmt vet ## Build agent binaries.
	go build -o bin/hubagent cmd/hubagent/main.go
	go build -o bin/memberagent cmd/memberagent/main.go

.PHONY: run-hubagent
run-hubagent: manifests generate fmt vet ## Run a controllers from your host.
	go run ./cmd/hubagent/main.go

.PHONY: run-memberagent
run-memberagent: manifests generate fmt vet ## Run a controllers from your host.
	go run ./cmd/memberagent/main.go


## --------------------------------------
## Images
## --------------------------------------

OUTPUT_TYPE ?= type=registry
BUILDX_BUILDER_NAME ?= img-builder
QEMU_VERSION ?= 5.2.0-2

.PHONY: docker-buildx-builder
docker-buildx-builder:
	@if ! docker buildx ls | grep $(BUILDX_BUILDER_NAME); then \
		docker run --rm --privileged multiarch/qemu-user-static:$(QEMU_VERSION) --reset -p yes; \
		docker buildx create --name $(BUILDX_BUILDER_NAME) --use; \
		docker buildx inspect $(BUILDX_BUILDER_NAME) --bootstrap; \
	fi

.PHONY: docker-build-hub-agent
docker-build-hub-agent: docker-buildx-builder
	docker buildx build \
		--file docker/$(HUB_AGENT_IMAGE_NAME).Dockerfile \
		--output=$(OUTPUT_TYPE) \
		--platform="linux/amd64" \
		--pull \
		--tag $(REGISTRY)/$(HUB_AGENT_IMAGE_NAME):$(HUB_AGENT_IMAGE_VERSION) .

.PHONY: docker-build-member-agent
docker-build-member-agent: docker-buildx-builder
	docker buildx build \
		--file docker/$(MEMBER_AGENT_IMAGE_NAME).Dockerfile \
		--output=$(OUTPUT_TYPE) \
		--platform="linux/amd64" \
		--pull \
		--tag $(REGISTRY)/$(MEMBER_AGENT_IMAGE_NAME):$(MEMBER_AGENT_IMAGE_VERSION) .

.PHONY: docker-build-refresh-token
docker-build-refresh-token: docker-buildx-builder
	docker buildx build \
		--file docker/$(REFRESH_TOKEN_IMAGE_NAME).Dockerfile \
		--output=$(OUTPUT_TYPE) \
		--platform="linux/amd64" \
		--pull \
		--tag $(REGISTRY)/$(REFRESH_TOKEN_IMAGE_NAME):$(REFRESH_TOKEN_IMAGE_VERSION) .

## -----------------------------------
## Cleanup 
## -----------------------------------

.PHONY: clean-bin
clean-bin: ## Remove all generated binaries
	rm -rf $(TOOLS_BIN_DIR)
	rm -rf ./bin
