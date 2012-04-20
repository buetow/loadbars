NAME=loadbars
perltidy:
	find . -name \*.pm | xargs perltidy -b
	perltidy -b $(NAME)
	find . -name \*.bak -delete
all: documentation
documentation:
	pod2man --release="$(NAME) $$(cut -d' ' -f2 debian/changelog | head -n 1 | sed 's/(//;s/)//')" \
                       --center="User Commands" ./docs/$(NAME).pod > ./docs/$(NAME).1
	pod2text ./docs/$(NAME).pod > ./docs/$(NAME).txt
install:
	test ! -d $(DESTDIR)/usr/bin && mkdir -p $(DESTDIR)/usr/bin || exit 0
	test ! -d $(DESTDIR)/usr/share/$(NAME) && mkdir -p $(DESTDIR)/usr/share/$(NAME) || exit 0
	cp $(NAME) $(DESTDIR)/usr/bin
	cp -r ./lib $(DESTDIR)/usr/share/$(NAME)/lib
	cp -r ./fonts $(DESTDIR)/usr/share/$(NAME)/fonts
deinstall:
	test ! -z "$(DESTDIR)" && test -f $(DESTDIR)/usr/bin/$(NAME) && rm $(DESTDIR)/usr/bin/$(NAME) || exit 0
	test ! -z "$(DESTDIR)/usr/share/$(NAME)" && -d $(DESTDIR)/usr/share/$(NAME) && rm -r $(DESTDIR)/usr/share/$(NAME) || exit 0
deb: 
	dpkg-buildpackage
