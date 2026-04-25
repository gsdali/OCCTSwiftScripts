PREFIX ?= /usr/local
BINDIR  = $(PREFIX)/bin
BIN     = occtkit
BUILD   = .build/release/$(BIN)

VERBS = run graph-validate graph-compact graph-dedup graph-query graph-ml feature-recognize dxf-export drawing-export reconstruct compose-sheet-metal

.PHONY: build install uninstall clean help

help:
	@echo "Targets:"
	@echo "  build              swift build -c release"
	@echo "  install [PREFIX=]  copy occtkit + verb symlinks to \$$(PREFIX)/bin (default /usr/local)"
	@echo "  uninstall [PREFIX=]"
	@echo "  clean              swift package clean"

build:
	swift build -c release

$(BUILD): build

install: $(BUILD)
	@install -d $(BINDIR)
	install -m 0755 $(BUILD) $(BINDIR)/$(BIN)
	@for v in $(VERBS); do \
		ln -sf $(BIN) $(BINDIR)/$$v; \
		echo "linked $(BINDIR)/$$v -> $(BIN)"; \
	done
	@echo "Installed to $(BINDIR)/$(BIN)"

uninstall:
	@rm -f $(BINDIR)/$(BIN)
	@for v in $(VERBS); do rm -f $(BINDIR)/$$v; done
	@echo "Removed $(BIN) and verb symlinks from $(BINDIR)"

clean:
	swift package clean
