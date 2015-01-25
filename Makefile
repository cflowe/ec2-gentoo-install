#
# When running from this Makefile's directory
# sudo -i make -C $PWD install
# 

.PHONY: install
install: fix-perms
	umask 0022 && tar -C $(CURDIR)/stage -cjf $(CURDIR)/build-root.tar.bz2 .

.PHONY: fix-perms
fix-perms: update
	chown -R root:root $(CURDIR)/stage
	chgrp portage $(CURDIR)/stage/var/lib/portage
	chmod g+xs $(CURDIR)/stage/var/lib/portage
	chown root:portage $(CURDIR)/stage/var/lib/portage/world
	chown root:portage $(CURDIR)/stage/var/lib/portage
	chmod 1777 $(CURDIR)/stage/tmp

.PHONY: update
update: check-env
	rsync -a $(CURDIR)/root/ $(CURDIR)/stage/

.PHONY: check-env
check-env:
	@if [ "$(CURDIR)" == ~root ]; then \
		echo "Use 'make -C <dir> -f Makefile' instead of 'make -f <dir>/Makefile'" >&2; \
		/bin/false; \
	fi

.PHONY: update-portage-use
update-portage-use:
	awk '/^[a-zA-Z0-9]/{print $$1}' /usr/portage/profiles/use.desc \
		> $(CURDIR)/root/tmp/portage.use.lis
