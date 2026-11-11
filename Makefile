# make lint | test | container | release CHANNEL=dev | srcinfo
# lint and test use shellcheck, shfmt and bats from PATH when present, and a
# clean Arch container (tests/container/run.sh) when not.
SHELL := bash
CHANNEL ?= dev

.PHONY: all lint test container release srcinfo fixtures clean

all: lint test container

lint:
	@if command -v shellcheck >/dev/null && command -v shfmt >/dev/null; then \
	  scripts/lint.sh; \
	else \
	  tests/container/run.sh lint; \
	fi

test:
	@if command -v bats >/dev/null; then \
	  bats tests; \
	else \
	  tests/container/run.sh test; \
	fi

container:
	tests/container/run.sh install launch package

release:
	scripts/build-release.sh $(CHANNEL) dist

srcinfo:
	tests/container/run.sh srcinfo

fixtures:
	python3 tests/fixtures/make-fixtures.py tests/fixtures

clean:
	rm -rf dist
