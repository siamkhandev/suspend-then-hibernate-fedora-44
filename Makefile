# Install Slumber's programs and unit files. Packaging uses DESTDIR/PREFIX:
#   make install DESTDIR=%{buildroot} PREFIX=/usr
PREFIX  ?= /usr
BINDIR  ?= $(PREFIX)/bin
UNITDIR ?= $(PREFIX)/lib/systemd
DESTDIR ?=

BINS := slumber-setup slumber-status lock-sleep sleep-notify sleep-report usb-wake-guard

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

uninstall:
	for b in $(BINS); do rm -f $(DESTDIR)$(BINDIR)/$$b; done
	rm -f $(DESTDIR)$(UNITDIR)/system/usb-wake-guard.service \
		$(DESTDIR)$(UNITDIR)/user/lock-sleep.service $(DESTDIR)$(UNITDIR)/user/sleep-notify.service \
		$(DESTDIR)$(UNITDIR)/system-sleep/sleep-battery

check:
	for b in slumber-setup lock-sleep sleep-notify sleep-report usb-wake-guard; do bash -n bin/$$b; done
	bash -n data/system-sleep/sleep-battery
	PYTHONDONTWRITEBYTECODE=1 python3 -c "import ast,sys; ast.parse(open('bin/slumber-status').read())"
