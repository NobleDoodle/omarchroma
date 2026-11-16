PREFIX ?= /usr
DESTDIR ?=

BIN     = $(DESTDIR)$(PREFIX)/bin
LIB     = $(DESTDIR)$(PREFIX)/lib/hyprchroma
SHARE   = $(DESTDIR)$(PREFIX)/share/hyprchroma
UNITS   = $(DESTDIR)$(PREFIX)/lib/systemd/user
DOC     = $(DESTDIR)$(PREFIX)/share/doc/hyprchroma
LICENSES= $(DESTDIR)$(PREFIX)/share/licenses/hyprchroma

.PHONY: install check

# The Python helpers. Each is installed as a module, hyprchroma_state.py and so
# on, compiled to bytecode here, and started through packaging/launcher.py under
# its own name, so a start loads that bytecode instead of compiling the source
# again. checked-hash: the bytecode is used only while it
# matches the source beside it, whatever the files' times.
HELPERS = hyprchroma-state hyprchroma-dark-reader hyprchroma-palette hyprchroma-icons

install:
	install -Dm755 bin/hyprchroma              $(BIN)/hyprchroma
	for helper in $(HELPERS); do \
	  module=$$(printf '%s' "$$helper" | tr - _); \
	  install -Dm644 "lib/$$helper" "$(LIB)/$$module.py" || exit 1; \
	  sed "s/@MODULE@/$$module/g" packaging/launcher.py > "$(LIB)/$$helper" || exit 1; \
	  chmod 755 "$(LIB)/$$helper"; \
	done
	/usr/bin/python3 -I -m compileall -q --invalidation-mode checked-hash \
	  -d $(PREFIX)/lib/hyprchroma $(LIB)
	install -Dm755 lib/sync-gtk-theme          $(LIB)/sync-gtk-theme
	install -Dm755 lib/sync-qt-kde-theme       $(LIB)/sync-qt-kde-theme
	install -Dm644 share/pear-theme.css.template $(SHARE)/pear-theme.css.template
	install -Dm755 share/hooks/hyprchroma      $(SHARE)/hooks/hyprchroma
	install -Dm644 share/hooks/hyprchroma.sha256 $(SHARE)/hooks/hyprchroma.sha256
	install -Dm644 packaging/systemd/hyprchromad.service $(UNITS)/hyprchromad.service
	install -Dm644 README.md                   $(DOC)/README.md
	install -Dm644 LICENSE                     $(LICENSES)/LICENSE

check:
	bash -n bin/hyprchroma bin/hyprchroma-setup bin/hyprchroma-uninstall lib/sync-gtk-theme lib/sync-qt-kde-theme share/hooks/hyprchroma
	/usr/bin/python3 -I -c "import ast;[ast.parse(open(f).read()) for f in ['lib/hyprchroma-state','lib/hyprchroma-dark-reader','lib/hyprchroma-palette','lib/hyprchroma-icons','packaging/launcher.py']]"
