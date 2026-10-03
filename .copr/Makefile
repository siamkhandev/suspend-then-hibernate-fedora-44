# COPR "make srpm" build method: make -f .copr/Makefile srpm outdir=... spec=...
NAME := sk-slumber

srpm:
	git archive --format=tar.gz --prefix=$(NAME)-$$(sed -n 's/^Version:[[:space:]]*//p' packaging/$(NAME).spec)/ \
		-o $(outdir)/$(NAME)-$$(sed -n 's/^Version:[[:space:]]*//p' packaging/$(NAME).spec).tar.gz HEAD
	rpmbuild -bs packaging/$(NAME).spec --define "_sourcedir $(outdir)" --define "_srcrpmdir $(outdir)"
