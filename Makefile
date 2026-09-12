PREFIX ?= /usr
DESTDIR ?=

BIN     = $(DESTDIR)$(PREFIX)/bin
LIB     = $(DESTDIR)$(PREFIX)/lib/hyprchroma
SHARE   = $(DESTDIR)$(PREFIX)/share/hyprchroma
UNITS   = $(DESTDIR)$(PREFIX)/lib/systemd/user
DOC     = $(DESTDIR)$(PREFIX)/share/doc/hyprchroma
LICENSES= $(DESTDIR)$(PREFIX)/share/licenses/hyprchroma

.PHONY: install check

install:
	install -Dm755 bin/hyprchroma              $(BIN)/hyprchroma
	install -Dm755 lib/hyprchroma-state        $(LIB)/hyprchroma-state
	install -Dm755 lib/hyprchroma-dark-reader  $(LIB)/hyprchroma-dark-reader
	install -Dm755 lib/hyprchroma-palette      $(LIB)/hyprchroma-palette
	install -Dm755 lib/sync-gtk-theme          $(LIB)/sync-gtk-theme
	install -Dm755 lib/sync-qt-kde-theme       $(LIB)/sync-qt-kde-theme
	install -Dm644 share/pear-theme.css.template $(SHARE)/pear-theme.css.template
	install -Dm755 share/hooks/hyprchroma      $(SHARE)/hooks/hyprchroma
	install -Dm644 packaging/systemd/hyprchromad.service $(UNITS)/hyprchromad.service
	install -Dm644 README.md                   $(DOC)/README.md
	install -Dm644 LICENSE                     $(LICENSES)/LICENSE

check:
	bash -n bin/hyprchroma lib/sync-gtk-theme lib/sync-qt-kde-theme share/hooks/hyprchroma
	python3 -c "import ast;[ast.parse(open(f).read()) for f in ['lib/hyprchroma-state','lib/hyprchroma-dark-reader','lib/hyprchroma-palette']]"
