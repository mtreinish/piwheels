# vim: set noet sw=4 ts=4 fileencoding=utf-8:

# External utilities
PYTHON ?= python
PIP ?= pip
PYTEST ?= pytest
COVERAGE ?= coverage
TWINE ?= twine
PYFLAGS ?=
DEST_DIR ?= /

# Find the location of python-apt (only packaged for apt, not pip)
PYTHON_APT:=$(wildcard /usr/lib/python3/dist-packages/apt) \
	$(wildcard /usr/lib/python3/dist-packages/apt_pkg*.so) \
	$(wildcard /usr/lib/python3/dist-packages/apt_inst*.so)

# Calculate the base names of the distribution, the location of all source,
# documentation, packaging, icon, and executable script files
NAME:=$(shell $(PYTHON) $(PYFLAGS) setup.py --name)
PKG_DIR:=$(subst -,_,$(NAME))
VER:=$(shell $(PYTHON) $(PYFLAGS) setup.py --version)
DEB_ARCH:=$(shell dpkg --print-architecture)
ifeq ($(shell lsb_release -si),Ubuntu)
DEB_SUFFIX:=ubuntu1
else
DEB_SUFFIX:=
endif
PY_SOURCES:=$(shell \
	$(PYTHON) $(PYFLAGS) setup.py egg_info >/dev/null 2>&1 && \
	grep -v "\.egg-info" $(PKG_DIR).egg-info/SOURCES.txt)
DEB_SOURCES:=debian/changelog \
	debian/control \
	debian/copyright \
	debian/rules \
	debian/docs \
	$(wildcard debian/*.init) \
	$(wildcard debian/*.default) \
	$(wildcard debian/*.manpages) \
	$(wildcard debian/*.docs) \
	$(wildcard debian/*.doc-base) \
	$(wildcard debian/*.desktop)
DOC_SOURCES:=docs/conf.py \
	$(wildcard docs/*.png) \
	$(wildcard docs/*.svg) \
	$(wildcard docs/*.dot) \
	$(wildcard docs/*.mscgen) \
	$(wildcard docs/*.gpi) \
	$(wildcard docs/*.rst) \
	$(wildcard docs/*.pdf)
SUBDIRS:=

# Calculate the name of all outputs
DIST_WHEEL=dist/$(NAME)-$(VER)-py2.py3-none-any.whl
DIST_TAR=dist/$(NAME)-$(VER).tar.gz
DIST_ZIP=dist/$(NAME)-$(VER).zip
DIST_DEB=dist/$(NAME)-master_$(VER)$(DEB_SUFFIX)_all.deb \
	dist/$(NAME)-slave_$(VER)$(DEB_SUFFIX)_all.deb \
	dist/$(NAME)-docs_$(VER)$(DEB_SUFFIX)_all.deb \
	dist/$(NAME)_$(VER)$(DEB_SUFFIX)_$(DEB_ARCH).build \
	dist/$(NAME)_$(VER)$(DEB_SUFFIX)_$(DEB_ARCH).buildinfo \
	dist/$(NAME)_$(VER)$(DEB_SUFFIX)_$(DEB_ARCH).changes
DIST_DSC=dist/$(NAME)_$(VER)$(DEB_SUFFIX).tar.xz \
	dist/$(NAME)_$(VER)$(DEB_SUFFIX).dsc \
	dist/$(NAME)_$(VER)$(DEB_SUFFIX)_source.build \
	dist/$(NAME)_$(VER)$(DEB_SUFFIX)_source.buildinfo \
	dist/$(NAME)_$(VER)$(DEB_SUFFIX)_source.changes
MAN_PAGES=man/piw-master.1 man/piw-slave.1 man/piw-monitor.1 man/piw-initdb.1


# Default target
all:
	@echo "make install - Install on local system"
	@echo "make develop - Install symlinks for development"
	@echo "make test - Run tests"
	@echo "make doc - Generate HTML and PDF documentation"
	@echo "make source - Create source package"
	@echo "make egg - Generate a PyPI egg package"
	@echo "make zip - Generate a source zip package"
	@echo "make tar - Generate a source tar package"
	@echo "make deb - Generate Debian packages"
	@echo "make dist - Generate all packages"
	@echo "make clean - Get rid of all generated files"
	@echo "make release - Create and tag a new release"
	@echo "make upload - Upload the new release to repositories"

install: $(SUBDIRS)
	$(PYTHON) $(PYFLAGS) setup.py install --root $(DEST_DIR)

doc: $(DOC_SOURCES)
	$(MAKE) -C docs clean
	$(MAKE) -C docs html
	$(MAKE) -C docs epub
	$(MAKE) -C docs latexpdf

source: $(DIST_TAR) $(DIST_ZIP)

wheel: $(DIST_WHEEL)

zip: $(DIST_ZIP)

tar: $(DIST_TAR)

deb: $(DIST_DEB) $(DIST_DSC)

dist: $(DIST_WHEEL) $(DIST_DEB) $(DIST_DSC) $(DIST_TAR) $(DIST_ZIP)

develop: tags
	@# These have to be done separately to avoid a cockup...
	$(PIP) install -U setuptools
	$(PIP) install -U pip
	$(PIP) install -e .[doc,test,master,slave,monitor,logger]
	@# If we're in a venv, link the system's RTIMULib into it
ifeq ($(VIRTUAL_ENV),)
	@echo "Virtualenv not detected! You may need to link python3-apt manually"
else
ifeq ($(PYTHON_APT),)
	@echo "WARNING: python3-apt not found. This is fine on non-Debian platforms"
else
	for lib in $(PYTHON_APT); do ln -sf $$lib $(VIRTUAL_ENV)/lib/python*/site-packages/; done
endif
endif

test:
	$(COVERAGE) run --rcfile coverage.cfg -m $(PYTEST) -v tests
	$(COVERAGE) report --rcfile coverage.cfg

clean:
	dh_clean
	rm -fr dist/ $(NAME).egg-info/ tags
	for dir in $(SUBDIRS); do \
		$(MAKE) -C $$dir clean; \
	done
	find $(CURDIR) -name "*.pyc" -delete

tags: $(PY_SOURCES)
	ctags -R --exclude="build/*" --exclude="debian/*" --exclude="docs/*" --languages="Python"

lint: $(PY_SOURCES)
	pylint piwheels

$(SUBDIRS):
	$(MAKE) -C $@

$(MAN_PAGES): $(DOC_SOURCES)
	$(PYTHON) $(PYFLAGS) setup.py build_sphinx -b man
	mkdir -p man/
	cp build/sphinx/man/*.[0-9] man/

$(DIST_TAR): $(PY_SOURCES) $(SUBDIRS)
	$(PYTHON) $(PYFLAGS) setup.py sdist --formats gztar

$(DIST_ZIP): $(PY_SOURCES) $(SUBDIRS)
	$(PYTHON) $(PYFLAGS) setup.py sdist --formats zip

$(DIST_WHEEL): $(PY_SOURCES) $(SUBDIRS)
	$(PYTHON) $(PYFLAGS) setup.py bdist_wheel

changelog: $(PY_SOURCES) $(DOC_SOURCES) $(DEB_SOURCES)
	$(MAKE) clean
	# ensure there are no current uncommitted changes
	test -z "$(shell git status --porcelain)"
	# update the debian changelog with new release information
	dch --newversion $(VER)$(DEB_SUFFIX)
	# commit the changes and add a new tag
	git commit debian/changelog -m "Updated changelog for release $(VER)"

release: $(PY_SOURCES) $(DOC_SOURCES) $(DIST_DEB) $(DIST_DSC)
	git tag -s release-$(VER) -m "Release $(VER)"
	git push --tags
	git push
	# build a source archive and upload to PyPI
	$(TWINE) upload $(DIST_TAR) $(DIST_WHEEL)

.PHONY: all install develop test doc source wheel zip tar deb dist clean tags changelog release-pi release-ubuntu $(SUBDIRS)
