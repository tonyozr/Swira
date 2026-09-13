# Makefile front-end for the project's build/test/clean commands. Keeps the same
# few verbs reachable the same way regardless of what the underlying toolchain
# actually is — that's the point of a make front-end, so this file avoids naming
# specific tools/subprojects in the parts people read (`help`, this banner). If
# the toolchain changes, update the recipes below rather than the verbs.
#
# `build`/`test`/`clean` each cover everything buildable on the current platform —
# not one target per subproject. Anything platform-specific that can't build here
# is skipped quietly rather than failing the whole command.
#
# File removal/copy goes through $(call rm-rf,...)/$(call mkdir-p,...)/$(call
# cp-into,...) rather than bare `rm`/`cp`/`mkdir -p` in the recipes below. Windows
# has no POSIX coreutils by default — not a PATH problem, they're just not part of
# the OS — so those three are defined per-platform once, here, and every recipe
# calls them the same way regardless of which platform ends up running.
# PowerShell (not `cmd`) backs them on Windows: it's the one thing guaranteed
# present, and calling it directly as a single command (rather than chaining with
# `&&`) keeps `make` from routing the line through `cmd.exe` — which is what
# happens if it sees only cmd-compatible compound syntax like `&&` and decides
# that's cheaper than invoking $(SHELL).
#
# Usage:
#   make build                  build everything
#   make build CONFIG=release   release build
#   make test                   run the test suite (FILTER=<name> to narrow)
#   make dist                   build, then collect artifacts into dist/
#   make clean                  remove build artifacts (incl. dist/)
#   make help                   list targets

SHELL := /bin/sh

FILTER ?=
# One knob for both build systems: `swift build -c` wants lowercase
# (debug/release), `dotnet build -c` wants capitalized (Debug/Release) — CONFIG
# is what people pass, DOTNET_CONFIG is derived from it for the dotnet side.
CONFIG ?= debug
ifeq ($(CONFIG),release)
	DOTNET_CONFIG := Release
else
	DOTNET_CONFIG := Debug
endif
WIN_PROJECT := Apps/SwiraWin/SwiraWin.csproj
DIST_DIR := dist

# `OS=Windows_NT` is an environment variable the Windows kernel itself sets for
# every process's environment block — cmd.exe, PowerShell, and Git Bash alike all
# inherit it the same way, so `make` sees it as a plain variable with no `$(shell
# ...)` call needed. Deliberately NOT `uname -s`: that only exists inside Git
# Bash/MSYS, so invoking `make` from a plain `cmd.exe` prompt made the `uname`
# pipeline silently produce nothing, and this ended up permanently false there —
# confirmed live: from `cmd.exe`, `IS_WINDOWS` came out `0` and `clean` fell
# through to the POSIX `rm`, which doesn't exist there either.
ifeq ($(OS),Windows_NT)
	IS_WINDOWS := 1
else
	IS_WINDOWS := 0
endif

ifeq ($(IS_WINDOWS),1)
rm-rf = powershell.exe -NoProfile -Command "Remove-Item -Recurse -Force -ErrorAction SilentlyContinue -Path '$(1)'; exit 0"
mkdir-p = powershell.exe -NoProfile -Command "New-Item -ItemType Directory -Force -Path '$(1)' | Out-Null; exit 0"
cp-into = powershell.exe -NoProfile -Command "Copy-Item -Recurse -Force -Path '$(1)' -Destination '$(2)'; exit 0"
else
rm-rf = rm -rf $(1)
mkdir-p = mkdir -p $(1)
cp-into = cp -r $(1) $(2)
endif

.PHONY: help build test dist clean

help:
	@echo "Targets:"
	@echo "  build              build everything (CONFIG=release for a release build)"
	@echo "  test               run the test suite (FILTER=<name> to narrow)"
	@echo "  dist               build, then collect artifacts into $(DIST_DIR)/"
	@echo "  clean              remove build artifacts (incl. $(DIST_DIR)/)"

build:
	swift build -c $(CONFIG)
ifeq ($(IS_WINDOWS),1)
	swift build --product SwiraABI -c $(CONFIG)
	dotnet build $(WIN_PROJECT) -c $(DOTNET_CONFIG)
endif

test:
ifneq ($(FILTER),)
	swift test --filter "$(FILTER)"
else
	swift test
endif

clean:
	swift package clean
ifeq ($(IS_WINDOWS),1)
	dotnet clean $(WIN_PROJECT) -c $(DOTNET_CONFIG)
endif
	$(call rm-rf,$(DIST_DIR))

# Collects everything `build` produced into one place. Swift's executable
# products always land here; on Windows SwiraWin is rebuilt straight into
# dist/SwiraWin/ with `dotnet build -o`, rather than copied out of its normal
# bin/<config>/<tfm>/<rid>/ output — that path segment names the exact target
# framework/RID from SwiraWin.csproj, so hardcoding it here would silently go
# stale the next time that project file changes. `-o` sidesteps knowing it at
# all; the rebuild itself is a fast no-op after `build` already did one.
dist: build
	$(call rm-rf,$(DIST_DIR))
	$(call mkdir-p,$(DIST_DIR))
ifeq ($(IS_WINDOWS),1)
	$(call cp-into,.build/$(CONFIG)/swira-probe.exe,$(DIST_DIR)/)
	$(call cp-into,.build/$(CONFIG)/swira-web.exe,$(DIST_DIR)/)
	$(call cp-into,.build/$(CONFIG)/SwiraABI.dll,$(DIST_DIR)/)
	dotnet build $(WIN_PROJECT) -c $(DOTNET_CONFIG) -o $(DIST_DIR)/SwiraWin
else
	$(call cp-into,.build/$(CONFIG)/swira-probe,$(DIST_DIR)/)
	$(call cp-into,.build/$(CONFIG)/swira-web,$(DIST_DIR)/)
endif
	@echo "Artifacts copied to $(DIST_DIR)/"
