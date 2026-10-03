# COPR "make srpm" build method: make -f .copr/Makefile srpm outdir=... spec=...
# COPR's source-build environment has no git, so the tarball is made with tar.
NAME    := sk-slumber
VERSION := $(shell sed -n 's/^Version:[[:space:]]*//p' packaging/$(NAME).spec)

srpm:
	tar --exclude-vcs --exclude='*.tar.gz' --exclude='*.src.rpm' --owner=0 --group=0 \
		--transform 's,^\./,$(NAME)-$(VERSION)/,;s,^\.$$,$(NAME)-$(VERSION),' \
		-czf $(outdir)/$(NAME)-$(VERSION).tar.gz .
	rpmbuild -bs packaging/$(NAME).spec --define "_sourcedir $(outdir)" --define "_srcrpmdir $(outdir)"
