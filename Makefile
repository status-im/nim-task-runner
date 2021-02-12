SHELL := bash # the shell used internally by "make"

# used inside the included makefiles
BUILD_SYSTEM_DIR := vendor/nimbus-build-system

# we don't want an error here, so we can handle things later, in the ".DEFAULT" target
-include $(BUILD_SYSTEM_DIR)/makefiles/variables.mk

.PHONY: \
	all \
	clean \
	clean-build-dirs \
	deps \
	nat-libs-sub \
	test \
	update

ifeq ($(NIM_PARAMS),)
# "variables.mk" was not included, so we update the submodules.
GIT_SUBMODULE_UPDATE := git submodule update --init --recursive
.DEFAULT:
	+@ echo -e "Git submodules not found. Running '$(GIT_SUBMODULE_UPDATE)'.\n"; \
		$(GIT_SUBMODULE_UPDATE) && \
		echo
# Now that the included *.mk files appeared, and are newer than this file, Make will restart itself:
# https://www.gnu.org/software/make/manual/make.html#Remaking-Makefiles
#
# After restarting, it will execute its original goal, so we don't have to start a child Make here
# with "$(MAKE) $(MAKECMDGOALS)". Isn't hidden control flow great?

else # "variables.mk" was included. Business as usual until the end of this file.

# default target, because it's the first one that doesn't start with '.'
all: test

# must be included after the default target
-include $(BUILD_SYSTEM_DIR)/makefiles/targets.mk

ifeq ($(OS),Windows_NT)
 # is Windows_NT on XP, 2000, 7, Vista, 10...
 detected_OS := Windows
else ifeq ($(strip $(shell uname)),Darwin)
 detected_OS := macOS
else
 # e.g. Linux
 detected_OS := $(strip $(shell uname))
endif

clean: | clean-common clean-build-dirs

clean-build-dirs:
	rm -rf test/build

# nim-nat-traversal assumes nat-libs are available in its parent's vendor;
# also, in msys2 environment miniupnpc's Makefile.mingw's invocation of
# `wingenminiupnpcstrings.exe` will fail if containing directory is not in PATH
nat-libs-sub:
	cd vendor/nim-waku && \
		PATH="$(shell pwd)/vendor/nim-waku/vendor/nim-nat-traversal/vendor/miniupnp/miniupnpc:$${PATH}" \
		$(ENV_SCRIPT) $(MAKE) USE_SYSTEM_NIM=1 nat-libs

deps: | deps-common nat-libs-sub

update: | update-common

test: | deps
	$(ENV_SCRIPT) nimble tests

endif # "variables.mk" was not included
