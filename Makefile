SHELL:=/bin/bash
PACKAGE=github.com/controlplane/theseus/cmd
.phony : dev dep build test container local
.SILENT:

all:
	make dep
	make test
	make build

test-old:
	cd test && ./test-acceptance.sh && ./test-theseus.sh

test-acceptance-old:
	cd test && ./test-acceptance.sh

test-unit-old:
	cd test && ./test-theseus.sh

dev:
	make test
	make build

dep-safe:
	bash -xc ' \
		make dep && make test || { \
			echo "Attempting to remedy gopkg.in/yaml.v2"; \
			rm -rf $$(pwd)/vendor/gopkg.in/yaml.v2; \
			go get -v gopkg.in/yaml.v2 && \
				ln -s $${GOPATH}/src/gopkg.in/yaml.v2 $$(pwd)/vendor/gopkg.in/ && \
				make test; \
		}; \
	'

dep:
	dep ensure -v

prune:
	dep prune -v

build:
	bash -xc ' \
		PACKAGE="$(PACKAGE)"; \
		STATUS=$$(git diff-index --quiet HEAD || echo "-dirty"); \
		HASH="$$(git rev-parse --short HEAD)"; \
		VERSION="$$(git describe --tags || echo $${HASH})$${STATUS}"; \
		go build -ldflags "\
			-X $${PACKAGE}.buildStamp=$$(date -u '+%Y-%m-%d_%I:%M:%S%p') \
			-X $${PACKAGE}.gitHash=$${HASH} \
			-X $${PACKAGE}.buildVersion=$${VERSION} \
		"; \
	'

cloud:
	cat cloudbuild.yaml
	gcloud container builds submit --config cloudbuild.yaml .

local:
	bash -c "container-builder-local --config cloudbuild.yaml --dryrun=false . 2>&1"

alpine:
	bash -xc ' \
		pwd; ls -lasp; \
		mkdir -p /gocode/src/github.com/controlplane/; \
		ln -s /workspace /gocode/src/github.com/controlplane/theseus; \
		cd /gocode/src/github.com/controlplane/theseus; \
		pwd; \
		ls -lasp; \
		\
		make dep-safe && \
		make build; \
	'

test :
	cd cmd && go test

release:
	hub release create \
		-d \
		-a $$(basename $$(pwd)) \
		-m "Version $$(git describe --tags)" \
		-m "$$(git log --format=oneline \
			| cut -d' ' -f 2- \
			| awk '!x[$$0]++' \
			| grep -iE '^[^ :]*:' \
			| grep -iEv '^(build|refactor):')" \
		$$(git describe --tags)

.PHONY : test test-acceptance test-unit
.SILENT:

