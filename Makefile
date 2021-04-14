
# Default values if not already set
ANSIBLE_VERSION ?= 2.9.*
PGOROOT ?= $(CURDIR)
PGO_BASEOS ?= centos8
PGO_IMAGE_PREFIX ?= crunchydata
PGO_IMAGE_TAG ?= $(PGO_BASEOS)-$(PGO_VERSION)
PGO_VERSION ?= v1beta1
PGO_PG_VERSION ?= 13
PGO_PG_FULLVERSION ?= 13.2
PGO_BACKREST_VERSION ?= 2.29
PGO_KUBE_CLIENT ?= kubectl
PACKAGER ?= yum

RELTMPDIR=/tmp/release.$(PGO_VERSION)
RELFILE=/tmp/postgres-operator.$(PGO_VERSION).tar.gz

# Valid values: buildah (default), docker
IMGBUILDER ?= buildah
# Determines whether or not rootless builds are enabled
IMG_ROOTLESS_BUILD ?= false
# The utility to use when pushing/pulling to and from an image repo (e.g. docker or buildah)
IMG_PUSHER_PULLER ?= docker
# Determines whether or not images should be pushed to the local docker daemon when building with
# a tool other than docker (e.g. when building with buildah)
IMG_PUSH_TO_DOCKER_DAEMON ?= true
# Defines the sudo command that should be prepended to various build commands when rootless builds are
# not enabled
IMGCMDSUDO=
ifneq ("$(IMG_ROOTLESS_BUILD)", "true")
	IMGCMDSUDO=sudo --preserve-env
endif
IMGCMDSTEM=$(IMGCMDSUDO) buildah bud --layers $(SQUASH)
DFSET=$(PGO_BASEOS)

# Default the buildah format to docker to ensure it is possible to pull the images from a docker
# repository using docker (otherwise the images may not be recognized)
export BUILDAH_FORMAT ?= docker

DOCKERBASEREGISTRY=registry.access.redhat.com/

# Allows simplification of IMGBUILDER switching
ifeq ("$(IMGBUILDER)","docker")
        IMGCMDSTEM=docker build
endif

# Allows consolidation of ubi/rhel/centos Dockerfile sets
ifeq ("$(PGO_BASEOS)", "rhel7")
        DFSET=rhel
endif

ifeq ("$(PGO_BASEOS)", "ubi7")
        DFSET=rhel
endif

ifeq ("$(PGO_BASEOS)", "ubi8")
        DFSET=rhel
        PACKAGER=dnf
endif

ifeq ("$(PGO_BASEOS)", "centos7")
        DFSET=centos
        DOCKERBASEREGISTRY=centos:
endif

ifeq ("$(PGO_BASEOS)", "centos8")
        DFSET=centos
        PACKAGER=dnf
        DOCKERBASEREGISTRY=centos:
endif

DEBUG_BUILD ?= false
GO ?= go
GO_BUILD = $(GO_CMD) build -trimpath
GO_CMD = $(GO_ENV) $(GO)

# Disable optimizations if creating a debug build
ifeq ("$(DEBUG_BUILD)", "true")
	GO_BUILD = $(GO_CMD) build -gcflags='all=-N -l'
endif

# To build a specific image, run 'make <name>-image' (e.g. 'make postgres-operator-image')
images = pgo-backrest \
	pgo-backrest-repo \
	pgo-rmdata \
	pgo-sqlrunner \
	pgo-deployer \
	crunchy-postgres-exporter \
	postgres-operator

.PHONY: all installrbac setup setupnamespaces cleannamespaces \
	deployoperator clean push pull release deploy


#======= Main functions =======
all: linuxpgo $(images:%=%-image)

installrbac:
	PGOROOT='$(PGOROOT)' ./deploy/install-rbac.sh

setup:
	PGOROOT='$(PGOROOT)' ./bin/get-deps.sh
	./bin/check-deps.sh

setupnamespaces:
	PGOROOT='$(PGOROOT)' ./deploy/setupnamespaces.sh

cleannamespaces:
	PGOROOT='$(PGOROOT)' ./deploy/cleannamespaces.sh

deployoperator:
	PGOROOT='$(PGOROOT)' ./deploy/deploy.sh


#=== postgrescluster CRD ===

# Create operator and target namespaces
createnamespaces:
	$(PGO_KUBE_CLIENT) apply -k ./config/namespace

# Delete operator and target namespaces
deletenamespaces:
	$(PGO_KUBE_CLIENT) delete -k ./config/namespace

# Install the postgrescluster CRD
install:
	$(PGO_KUBE_CLIENT) apply -k ./config/crd

# Delete the postgrescluster CRD
uninstall:
	$(PGO_KUBE_CLIENT) delete -k ./config/crd

# Deploy the PostgreSQL Operator (enables the postgrescluster controller)
deploy:
	$(PGO_KUBE_CLIENT) apply -k ./config/default

# Deploy the PostgreSQL Operator locally
deploy-dev: build-postgres-operator
	$(PGO_KUBE_CLIENT) apply -k ./config/dev
	hack/create-kubeconfig.sh postgres-operator postgres-operator
	CRUNCHY_POSTGRES_OPERATOR_NAMESPACE=postgres-operator CRUNCHY_DEBUG=true \
		PGO_DISABLE_PGCLUSTER=true KUBECONFIG=hack/.kube/postgres-operator/postgres-operator \
		bin/postgres-operator

# Undeploy the PostgreSQL Operator
undeploy:
	$(PGO_KUBE_CLIENT) delete -k ./config/default


#======= Binary builds =======
build-pgo-backrest:
	$(GO_BUILD) -o bin/pgo-backrest/pgo-backrest ./cmd/pgo-backrest

build-pgo-rmdata:
	$(GO_BUILD) -o bin/pgo-rmdata/pgo-rmdata ./cmd/pgo-rmdata

build-postgres-operator:
	$(GO_BUILD) -o bin/postgres-operator ./cmd/postgres-operator

build-pgo-%:
	$(info No binary build needed for $@)

build-crunchy-postgres-exporter:
	$(info No binary build needed for $@)


#======= Image builds =======
$(PGOROOT)/build/%/Dockerfile:
	$(error No Dockerfile found for $* naming pattern: [$@])

%-img-build: pgo-base-$(IMGBUILDER) build-% $(PGOROOT)/build/%/Dockerfile
	$(IMGCMDSTEM) \
		-f $(PGOROOT)/build/$*/Dockerfile \
		-t $(PGO_IMAGE_PREFIX)/$*:$(PGO_IMAGE_TAG) \
		--build-arg BASEOS=$(PGO_BASEOS) \
		--build-arg BASEVER=$(PGO_VERSION) \
		--build-arg PREFIX=$(PGO_IMAGE_PREFIX) \
		--build-arg PGVERSION=$(PGO_PG_VERSION) \
		--build-arg BACKREST_VERSION=$(PGO_BACKREST_VERSION) \
		--build-arg ANSIBLE_VERSION=$(ANSIBLE_VERSION) \
		--build-arg DFSET=$(DFSET) \
		--build-arg PACKAGER=$(PACKAGER) \
		$(PGOROOT)

%-img-buildah: %-img-build ;
# only push to docker daemon if variable PGO_PUSH_TO_DOCKER_DAEMON is set to "true"
ifeq ("$(IMG_PUSH_TO_DOCKER_DAEMON)", "true")
	$(IMGCMDSUDO) buildah push $(PGO_IMAGE_PREFIX)/$*:$(PGO_IMAGE_TAG) docker-daemon:$(PGO_IMAGE_PREFIX)/$*:$(PGO_IMAGE_TAG)
endif

%-img-docker: %-img-build ;

%-image: %-img-$(IMGBUILDER) ;

pgo-base: pgo-base-$(IMGBUILDER)

pgo-base-build: $(PGOROOT)/build/pgo-base/Dockerfile
	$(IMGCMDSTEM) \
		-f $(PGOROOT)/build/pgo-base/Dockerfile \
		-t $(PGO_IMAGE_PREFIX)/pgo-base:$(PGO_IMAGE_TAG) \
		--build-arg BASEOS=$(PGO_BASEOS) \
		--build-arg RELVER=$(PGO_VERSION) \
		--build-arg PGVERSION=$(PGO_PG_VERSION) \
		--build-arg PG_FULL=$(PGO_PG_FULLVERSION) \
		--build-arg DFSET=$(DFSET) \
		--build-arg PACKAGER=$(PACKAGER) \
		--build-arg DOCKERBASEREGISTRY=$(DOCKERBASEREGISTRY) \
		$(PGOROOT)

pgo-base-buildah: pgo-base-build ;
# only push to docker daemon if variable PGO_PUSH_TO_DOCKER_DAEMON is set to "true"
ifeq ("$(IMG_PUSH_TO_DOCKER_DAEMON)", "true")
	$(IMGCMDSUDO) buildah push $(PGO_IMAGE_PREFIX)/pgo-base:$(PGO_IMAGE_TAG) docker-daemon:$(PGO_IMAGE_PREFIX)/pgo-base:$(PGO_IMAGE_TAG)
endif

pgo-base-docker: pgo-base-build


#======== Utility =======
.PHONY: check
check:
	PGOROOT=$(PGOROOT) $(GO) test -cover ./...

# - KUBEBUILDER_ATTACH_CONTROL_PLANE_OUTPUT=true
.PHONY: check-envtest
check-envtest: hack/tools/envtest
	KUBEBUILDER_ASSETS="$(CURDIR)/$^/bin" $(GO) test -count=1 -cover -tags=envtest ./internal/controller/... ./internal/pgbackrest/...

.PHONY: check-envtest-existing
check-envtest-existing:
	${PGO_KUBE_CLIENT} apply -f "$(CURDIR)/config/rbac/pgo-cluster-role.yaml"
	USE_EXISTING_CLUSTER=true $(GO) test -count=1 -tags=envtest ./internal/controller/... ./internal/pgbackrest/...
	${PGO_KUBE_CLIENT} delete -f "$(CURDIR)/config/rbac/pgo-cluster-role.yaml"


.PHONY: check-generate
check-generate: generate-crd generate-deepcopy
	git diff --exit-code -- config/crd
	git diff --exit-code -- pkg/apis

clean: clean-deprecated
	rm -f bin/postgres-operator
	rm -f bin/pgo-backrest/pgo-backrest
	rm -f bin/pgo-rmdata/pgo-rmdata
	[ ! -d hack/tools/envtest ] || rm -r hack/tools/envtest
	[ ! -n "$$(ls hack/tools)" ] || rm hack/tools/*
	[ ! -d hack/.kube ] || rm -r hack/.kube

clean-deprecated:
	@# packages used to be downloaded into the vendor directory
	[ ! -d vendor ] || rm -r vendor
	@# executables used to be compiled into the $GOBIN directory
	[ ! -n '$(GOBIN)' ] || rm -f $(GOBIN)/postgres-operator $(GOBIN)/apiserver $(GOBIN)/*pgo
	[ ! -d bin/postgres-operator ] || rm -r bin/postgres-operator

push: $(images:%=push-%) ;

push-%:
	$(IMG_PUSHER_PULLER) push $(PGO_IMAGE_PREFIX)/$*:$(PGO_IMAGE_TAG)

pull: $(images:%=pull-%) ;

pull-%:
	$(IMG_PUSHER_PULLER) pull $(PGO_IMAGE_PREFIX)/$*:$(PGO_IMAGE_TAG)

release:  linuxpgo macpgo winpgo
	rm -rf $(RELTMPDIR) $(RELFILE)
	mkdir $(RELTMPDIR)
	cp -r $(PGOROOT)/examples $(RELTMPDIR)
	cp -r $(PGOROOT)/deploy $(RELTMPDIR)
	cp -r $(PGOROOT)/conf $(RELTMPDIR)
	tar czvf $(RELFILE) -C $(RELTMPDIR) .

generate: generate-crd generate-deepcopy
	GOBIN='$(CURDIR)/hack/tools' ./hack/update-codegen.sh

generate-crd:
	GOBIN='$(CURDIR)/hack/tools' ./hack/controller-generator.sh \
		crd:crdVersions='v1',preserveUnknownFields='false' \
		paths='./pkg/apis/postgres-operator.crunchydata.com/...' \
		output:dir='config/crd/bases' # config/crd/bases/{group}_{plural}.yaml

generate-deepcopy:
	GOBIN='$(CURDIR)/hack/tools' ./hack/controller-generator.sh \
		object:headerFile='hack/boilerplate.go.txt' \
		paths='./pkg/apis/postgres-operator.crunchydata.com/...'

# Available versions: curl -s 'https://storage.googleapis.com/kubebuilder-tools/' | grep -o '<Key>[^<]*</Key>'
# - ENVTEST_K8S_VERSION=1.19.2
hack/tools/envtest: SHELL = bash
hack/tools/envtest:
	source '$(shell $(GO) list -f '{{ .Dir }}' -m 'sigs.k8s.io/controller-runtime')/hack/setup-envtest.sh' && fetch_envtest_tools $@
