NAME=loadbars
all: version documentation perltidy
version:
	cut -d' ' -f2 debian/changelog | head -n 1 | sed 's/(//;s/)//' > .version
perltidy:
	find . -name \*.pm | xargs perltidy -b
	perltidy -b $(NAME)
	find . -name \*.bak -delete
documentation:
	pod2man --release="$(NAME) $$(cat .version)" \
                       --center="User Commands" ./docs/$(NAME).pod > ./docs/$(NAME).1
	pod2text ./docs/$(NAME).pod > ./docs/$(NAME).txt
install:
	test ! -d $(DESTDIR)/usr/bin && mkdir -p $(DESTDIR)/usr/bin || exit 0
	test ! -d $(DESTDIR)/usr/share/$(NAME) && mkdir -p $(DESTDIR)/usr/share/$(NAME) || exit 0
	cp $(NAME) $(DESTDIR)/usr/bin
	cp -r ./lib $(DESTDIR)/usr/share/$(NAME)/lib
	cp -r ./fonts $(DESTDIR)/usr/share/$(NAME)/fonts
	cp ./.version $(DESTDIR)/usr/share/$(NAME)/version
deinstall:
	test ! -z "$(DESTDIR)" && test -f $(DESTDIR)/usr/bin/$(NAME) && rm $(DESTDIR)/usr/bin/$(NAME) || exit 0
	test ! -z "$(DESTDIR)/usr/share/$(NAME)" && -d $(DESTDIR)/usr/share/$(NAME) && rm -r $(DESTDIR)/usr/share/$(NAME) || exit 0
clean:
	test -f .version && rm .version
deb: 
	dpkg-buildpackage
clean-top:
	rm ../$(NAME)_*.tar.gz
	rm ../$(NAME)_*.dsc
	rm ../$(NAME)_*.changes
	rm ../$(NAME)_*.deb


