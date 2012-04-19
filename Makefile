perltidy:
	find . -name \*.pm | xargs perltidy -b
	perltidy -b loadbars
	find . -name \*.bak -delete
