PREFIX ?= $(HOME)/.local
BINARY = tokens-exporter

BOLD   = \033[1m
DIM    = \033[2m
GREEN  = \033[0;32m
CYAN   = \033[0;36m
YELLOW = \033[0;33m
RED    = \033[0;31m
RESET  = \033[0m

.PHONY: help build install uninstall clean

help: ## Show this help
	@printf '\n  $(BOLD)$(BINARY)$(RESET) — Figma design tokens → LLM-friendly formats\n\n'
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(CYAN)%-12s$(RESET) %s\n", $$1, $$2}'
	@printf '\n'

build: ## Build release binary
	@printf '  $(DIM)Building…$(RESET)\n'
	@swift build -c release 2>&1 | tail -1
	@printf '  $(GREEN)✓$(RESET) Built $(BOLD).build/release/$(BINARY)$(RESET)\n'

install: build ## Install to $(PREFIX)/bin
	@install -d $(PREFIX)/bin
	@install .build/release/$(BINARY) $(PREFIX)/bin/$(BINARY)
	@printf '  $(GREEN)✓$(RESET) Installed $(BOLD)$(BINARY)$(RESET) → $(DIM)$(PREFIX)/bin$(RESET)\n'

uninstall: ## Remove from $(PREFIX)/bin
	@rm -f $(PREFIX)/bin/$(BINARY)
	@printf '  $(GREEN)✓$(RESET) Removed $(BOLD)$(BINARY)$(RESET) from $(DIM)$(PREFIX)/bin$(RESET)\n'

clean: ## Delete build artifacts
	@swift package clean 2>/dev/null || true
	@rm -rf .build
	@printf '  $(GREEN)✓$(RESET) Clean\n'
