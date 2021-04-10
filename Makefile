# Copyright (c) 2020 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

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
	rlnlib-sub \
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

LIBMINIUPNPC := $(shell pwd)/vendor/nim-waku/vendor/nim-nat-traversal/vendor/miniupnp/miniupnpc/libminiupnpc.a
LIBNATPMP := $(shell pwd)/vendor/nim-waku/vendor/nim-nat-traversal/vendor/libnatpmp-upstream/libnatpmp.a

# nat-libs target assumes libs are in vendor subdir of working directory;
# also, in msys2 environment miniupnpc's Makefile.mingw's invocation of
# `wingenminiupnpcstrings.exe` will fail if containing directory is not in PATH
$(LIBMINIUPNPC):
	cd vendor/nim-waku && \
		PATH="$$(pwd)/vendor/nim-nat-traversal/vendor/miniupnp/miniupnpc:$${PATH}" \
		$(ENV_SCRIPT) $(MAKE) USE_SYSTEM_NIM=1 nat-libs

$(LIBNATPMP): $(LIBMINIUPNPC)

nat-libs-sub: $(LIBMINIUPNPC) $(LIBNATPMP)

deps: | deps-common nat-libs-sub rlnlib-sub

update: | update-common

ifndef SHARED_LIB_EXT
 ifeq ($(detected_OS),macOS)
  SHARED_LIB_EXT := dylib
 else ifeq ($(detected_OS),Windows)
  SHARED_LIB_EXT := dll
 else
  SHARED_LIB_EXT := so
 endif
endif

RELEASE ?= false

ifneq ($(RELEASE),false)
 RLN_CARGO_BUILD_FLAGS := --release
 RLN_TARGET_SUBDIR := release
 ifeq ($(detected_OS),Windows)
  WIN_STATIC := true
 else
  WIN_STATIC := false
 endif
else
 RLN_TARGET_SUBDIR := debug
 WIN_STATIC := false
endif
RLN_LIB_DIR := $(shell pwd)/vendor/nim-waku/vendor/rln/target/$(RLN_TARGET_SUBDIR)
RLN_STATIC ?= false
ifeq ($(RLN_STATIC),false)
 ifeq ($(detected_OS),Windows)
  RLN_LIB := $(RLN_LIB_DIR)/librln.$(SHARED_LIB_EXT).a
 else
  RLN_LIB := $(RLN_LIB_DIR)/librln.$(SHARED_LIB_EXT)
 endif
else
 RLN_LIB := $(RLN_LIB_DIR)/librln.a
endif

$(RLN_LIB):
	cd vendor/nim-waku && \
		cargo build \
			--manifest-path vendor/rln/Cargo.toml \
			$(RLN_CARGO_BUILD_FLAGS)
ifeq ($(detected_OS),macOS)
	install_name_tool -id \
		@rpath/librln.$(SHARED_LIB_EXT) \
		$(RLN_LIB_DIR)/librln.$(SHARED_LIB_EXT)
endif

rlnlib-sub: $(RLN_LIB)

ifndef RLN_LDFLAGS
 ifeq ($(RLN_STATIC),false)
  ifeq ($(detected_OS),macOS)
   RLN_LDFLAGS := -L$(RLN_LIB_DIR) -lrln -rpath $(RLN_LIB_DIR)
  else ifeq ($(detected_OS),Windows)
   ifneq ($(WIN_STATIC),false)
    RLN_LDFLAGS := -L$(shell cygpath -m $(RLN_LIB_DIR)) -lrln -luserenv
   else
    RLN_LDFLAGS := -L$(shell cygpath -m $(RLN_LIB_DIR)) -lrln
   endif
  else
   RLN_LDFLAGS := -L$(RLN_LIB_DIR) -lrln
  endif
 else
  ifeq ($(detected_OS),Windows)
   RLN_LDFLAGS := $(shell cygpath -m $(RLN_LIB)) -luserenv
  else ifeq ($(detected_OS),macOS)
   RLN_LDFLAGS := $(RLN_LIB)
  else
   RLN_LDFLAGS := $(RLN_LIB) -lm
  endif
 endif
endif

ifeq ($(RLN_STATIC),false)
 LD_LIBRARY_PATH_NIMBLE ?= $(RLN_LIB_DIR)$${LD_LIBRARY_PATH:+:$${LD_LIBRARY_PATH}}
 PATH_NIMBLE ?= $(RLN_LIB_DIR):$${PATH}
else
 LD_LIBRARY_PATH_NIMBLE ?= $${LD_LIBRARY_PATH}
 PATH_NIMBLE ?= $${PATH}
endif

RUN_AFTER_BUILD ?= true

test: | deps
ifeq ($(detected_OS),macOS)
	RELEASE=$(RELEASE) \
	RLN_LDFLAGS="$(RLN_LDFLAGS)" \
	RLN_LIB_DIR="$(RLN_LIB_DIR)" \
	RLN_STATIC=$(RLN_STATIC) \
	RUN_AFTER_BUILD=$(RUN_AFTER_BUILD) \
	WIN_STATIC=$(WIN_STATIC) \
	$(ENV_SCRIPT) nimble tests
else ifeq ($(detected_OS),Windows)
	PATH="$(PATH_NIMBLE)" \
	RELEASE=$(RELEASE) \
	RLN_LDFLAGS="$(RLN_LDFLAGS)" \
	RLN_LIB_DIR="$(RLN_LIB_DIR)" \
	RLN_STATIC=$(RLN_STATIC) \
	RUN_AFTER_BUILD=$(RUN_AFTER_BUILD) \
	WIN_STATIC=$(WIN_STATIC) \
	$(ENV_SCRIPT) nimble tests
else
	LD_LIBRARY_PATH="$(LD_LIBRARY_PATH_NIMBLE)" \
	RELEASE=$(RELEASE) \
	RLN_LDFLAGS="$(RLN_LDFLAGS)" \
	RLN_LIB_DIR="$(RLN_LIB_DIR)" \
	RLN_STATIC=$(RLN_STATIC) \
	RUN_AFTER_BUILD=$(RUN_AFTER_BUILD) \
	WIN_STATIC=$(WIN_STATIC) \
	$(ENV_SCRIPT) nimble tests
endif

endif # "variables.mk" was not included
