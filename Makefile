# Install Slumber's programs and unit files. Packaging uses DESTDIR/PREFIX:
#   make install DESTDIR=%{buildroot} PREFIX=/usr
PREFIX  ?= /usr
BINDIR  ?= $(PREFIX)/bin
UNITDIR ?= $(PREFIX)/lib/systemd
DATADIR ?= $(PREFIX)/share
EXTDIR  ?= $(DATADIR)/gnome-shell/extensions/slumber@sk
DESTDIR ?=

BINS := slumber slumber-setup slumber-status slumber-ctl lock-sleep sleep-notify sleep-report usb-wake-guard

.PHONY: install uninstall check

install:
	install -d $(DESTDIR)$(BINDIR) $(DESTDIR)$(UNITDIR)/system $(DESTDIR)$(UNITDIR)/user \
		$(DESTDIR)$(UNITDIR)/system-sleep
	for b in $(BINS); do install -m 0755 bin/$$b $(DESTDIR)$(BINDIR)/$$b; done
	for u in data/systemd/system/*.service; do \
		sed 's|/usr/bin|$(BINDIR)|g' $$u > $(DESTDIR)$(UNITDIR)/system/$$(basename $$u); \
		chmod 0644 $(DESTDIR)$(UNITDIR)/system/$$(basename $$u); done
	for u in data/systemd/user/*.service; do \
		sed 's|/usr/bin|$(BINDIR)|g' $$u > $(DESTDIR)$(UNITDIR)/user/$$(basename $$u); \
		chmod 0644 $(DESTDIR)$(UNITDIR)/user/$$(basename $$u); done
	install -m 0755 data/system-sleep/sleep-battery $(DESTDIR)$(UNITDIR)/system-sleep/sleep-battery
	install -D -m 0644 data/applications/io.github.siamkhandev.Slumber.desktop \
		$(DESTDIR)$(DATADIR)/applications/io.github.siamkhandev.Slumber.desktop
	install -D -m 0644 data/metainfo/io.github.siamkhandev.Slumber.metainfo.xml \
		$(DESTDIR)$(DATADIR)/metainfo/io.github.siamkhandev.Slumber.metainfo.xml
	install -D -m 0644 data/icons/hicolor/scalable/apps/io.github.siamkhandev.Slumber.svg \
		$(DESTDIR)$(DATADIR)/icons/hicolor/scalable/apps/io.github.siamkhandev.Slumber.svg
	install -d $(DESTDIR)$(DATADIR)/polkit-1/actions
	sed 's|/usr/bin|$(BINDIR)|g' data/polkit/io.github.siamkhandev.slumber.policy \
		> $(DESTDIR)$(DATADIR)/polkit-1/actions/io.github.siamkhandev.slumber.policy
	chmod 0644 $(DESTDIR)$(DATADIR)/polkit-1/actions/io.github.siamkhandev.slumber.policy
	install -d $(DESTDIR)$(EXTDIR)
	install -m 0644 data/gnome-shell/extensions/slumber@sk/*.js* $(DESTDIR)$(EXTDIR)/

uninstall:
	for b in $(BINS); do rm -f $(DESTDIR)$(BINDIR)/$$b; done
	rm -f $(DESTDIR)$(UNITDIR)/system/usb-wake-guard.service \
		$(DESTDIR)$(UNITDIR)/user/lock-sleep.service $(DESTDIR)$(UNITDIR)/user/sleep-notify.service \
		$(DESTDIR)$(UNITDIR)/system-sleep/sleep-battery
	rm -rf $(DESTDIR)$(EXTDIR)
	rm -f $(DESTDIR)$(DATADIR)/applications/io.github.siamkhandev.Slumber.desktop \
		$(DESTDIR)$(DATADIR)/metainfo/io.github.siamkhandev.Slumber.metainfo.xml \
		$(DESTDIR)$(DATADIR)/icons/hicolor/scalable/apps/io.github.siamkhandev.Slumber.svg \
		$(DESTDIR)$(DATADIR)/polkit-1/actions/io.github.siamkhandev.slumber.policy

check:
	for b in slumber-setup slumber-ctl lock-sleep sleep-notify sleep-report usb-wake-guard; do bash -n bin/$$b; done
	bash -n data/system-sleep/sleep-battery
	desktop-file-validate data/applications/*.desktop
	PYTHONDONTWRITEBYTECODE=1 python3 -c "import ast; ast.parse(open('bin/slumber').read())"
	PYTHONDONTWRITEBYTECODE=1 python3 -c "import ast,sys; ast.parse(open('bin/slumber-status').read())"

# --- packaging -----------------------------------------------------------------
NAME    := sk-slumber
VERSION := $(shell sed -n 's/^Version:[[:space:]]*//p' packaging/$(NAME).spec)

.PHONY: dist srpm rpm
dist:
	git archive --format=tar.gz --prefix=$(NAME)-$(VERSION)/ -o $(NAME)-$(VERSION).tar.gz HEAD

srpm: dist
	rpmbuild -bs packaging/$(NAME).spec --define "_sourcedir $(CURDIR)" --define "_srcrpmdir $(CURDIR)"

rpm: dist
	rpmbuild -bb packaging/$(NAME).spec --define "_sourcedir $(CURDIR)" --define "_rpmdir $(CURDIR)"
