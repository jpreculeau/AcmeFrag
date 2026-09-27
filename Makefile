SHELL := /bin/bash
SCRIPTS := AcmeFrag.sh config.sh $(wildcard lib/*.sh) $(wildcard tests/*.sh)

.PHONY: lint test it check
lint:
	shellcheck -x $(SCRIPTS)
test:
	tests/run_tests.sh
it:
	tests/integration.sh
check: lint test
