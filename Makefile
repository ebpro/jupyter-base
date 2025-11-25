SHELL := /usr/bin/env bash
.PHONY: help generate validate preview build-one build-all

help:
	@echo "Make targets: generate validate preview build-one build-all"

generate:
	./scripts/build.sh generate --all-profiles

validate:
	./scripts/build.sh validate

preview:
	./scripts/build.sh preview

build-one:
	@echo "Use: make build-one PROFILE=00-01-minimal"
	@if [ -z "${PROFILE}" ]; then echo "PROFILE is required"; exit 2; fi
	./scripts/build.sh build-one --profile ${PROFILE}

build-all:
	./scripts/build.sh build-all --platform ${PLATFORM:-linux/amd64}
