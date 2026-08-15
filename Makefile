# Makefile front-end for `swift build`/`swift test`/`swift run`.
#
# This wraps SwiftPM so the same handful of verbs work the same way on every
# platform Swira targets (macOS, Windows, Linux). Any new build system that
# replaces or sits alongside SwiftPM must stay reachable through these same
# `make` targets — update the recipes below rather than only teaching people
# a new one-off command.
#
# Usage:
#   make build                  swift build
#   make test                   swift test (offline suite; must stay green)
#   make test FILTER=Foo        swift test --filter Foo
#   make run-probe ARGS="whoami"
#   make run-web                swift run swira-web (PORT=8787 by default)
#   make run-web PORT=9000
#   make stop-web                kill whatever is listening on PORT (default 8787)
#   make clean                  swift package clean
#   make help                   list targets

SHELL := /bin/sh

PORT ?= 8787
FILTER ?=
ARGS ?=

.PHONY: help build test run-probe run-web stop-web clean

help:
	@echo "Targets:"
	@echo "  build              swift build"
	@echo "  test               swift test (FILTER=<SuiteOrTestName> to narrow)"
	@echo "  run-probe          swift run swira-probe \$$(ARGS)"
	@echo "  run-web            swift run swira-web (PORT=$(PORT))"
	@echo "  stop-web           stop whatever is listening on PORT=$(PORT)"
	@echo "  clean              swift package clean"

build:
	swift build

test:
	@if [ -n "$(FILTER)" ]; then \
		swift test --filter "$(FILTER)"; \
	else \
		swift test; \
	fi

run-probe:
	swift run swira-probe $(ARGS)

# On Windows a running swira-web.exe holds a file lock that makes `swift
# build` fail with a linker "permission denied" error — run `make stop-web`
# first if a previous `make run-web` is still up.
run-web:
	swift run swira-web --port $(PORT) $(ARGS)

stop-web:
	@case "$$(uname -s 2>/dev/null)" in \
		MINGW*|MSYS*|CYGWIN*) \
			powershell.exe -NoProfile -Command " \
				\$$conns = Get-NetTCPConnection -LocalPort $(PORT) -State Listen -ErrorAction SilentlyContinue; \
				if (-not \$$conns) { Write-Host 'Nothing listening on port $(PORT).'; exit 0 }; \
				foreach (\$$c in \$$conns) { \
					\$$p = Get-Process -Id \$$c.OwningProcess -ErrorAction SilentlyContinue; \
					if (\$$p -and \$$p.Path -like '*swira-web.exe') { \
						Write-Host \"Stopping swira-web.exe (PID \$$(\$$p.Id))\"; \
						Stop-Process -Id \$$p.Id -Force; \
					} else { \
						Write-Host \"Port $(PORT) is held by PID \$$(\$$c.OwningProcess), not swira-web.exe — leaving it alone.\"; \
					} \
				}"; \
			;; \
		*) \
			pid="$$(lsof -ti tcp:$(PORT) 2>/dev/null)"; \
			if [ -z "$$pid" ]; then \
				echo "Nothing listening on port $(PORT)."; \
			else \
				echo "Stopping process $$pid on port $(PORT)"; \
				kill $$pid; \
			fi; \
			;; \
	esac

clean:
	swift package clean
