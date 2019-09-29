ifeq ($(OS),Windows_NT)
  ifeq ($(shell uname -s),) # not in a bash-like shell
	CLEANUP = del /F /Q
	MKDIR = mkdir
  else # in a bash-like shell, like msys
	CLEANUP = rm -f
	MKDIR = mkdir -p
  endif
	TARGET_EXTENSION=.exe
else
	CLEANUP = rm -f
	MKDIR = mkdir -p
	TARGET_EXTENSION=out
endif

#directories
BUILD_DIR = build/
RELEASE_DIR = release/
PROFILING_RESULTS_DIR = $(BUILD_DIR)profiling_results/
CPPCHECK_RESULTS_DIR = $(BUILD_DIR)cppcheck_results/
TEST_RESULTS_DIR = $(BUILD_DIR)test_results/
TEST_OUTPUT = $(BUILD_DIR)test/
CONFIG_DIR = conf/
SRC_DIRS = src/
LIB_DIRS = lib/
TEST_DIRS = test/
TEST_RUNNERS = $(TEST_DIRS)test_runners/
INCLUDE_DEST = $(RELEASE_DIR)include/
SRC_DEST = $(RELEASE_DIR)src/


#unity testing files
SRCT = $(wildcard $(TEST_DIRS)*.c)
RUNNERS = $(patsubst $(TEST_DIRS)%.c,$(TEST_RUNNERS)%.c,$(SRCT) )
TEST_RESULTS = $(patsubst $(TEST_DIRS)Test%.c,$(TEST_RESULTS_DIR)Test%.txt,$(SRCT) )
PROFILING_RESULTS = $(patsubst $(TEST_DIRS)Test%.c,$(PROFILING_RESULTS_DIR)Test%.out,$(SRCT) )
TEST_OBJS = $(SRCT:%=$(BUILD_DIR)%.o)
UNITY_ROOT=/home/drew/src/Unity

#valgrind stuff
VALGRIND = /usr/bin/valgrind
VALGRIND_SUPPS = $(CONFIG_DIR)valgrind.memcheck.supp

#project source files
SRCS := $(shell find $(LIB_DIRS) $(SRC_DIRS) -maxdepth 2 \( -iname "*.c" \))
HEADERS = $(shell find $(LIB_DIRS) $(SRC_DIRS) -maxdepth 2 \( -iname "*.h" \))
OBJS = $(SRCS:%=$(BUILD_DIR)%.o)
INC_DIRS := $(shell find $(LIB_DIRS) -maxdepth 1 -type d)

#misc variables
DIRECTIVES = -DLOG_USE_COLOR -DUNITY_OUTPUT_COLOR
FLAGS = -fPIC
INC_FLAGS := $(addprefix -I,$(INC_DIRS)) -I$(UNITY_ROOT)/src -I./src
CURRENT_DIR = $(notdir $(shell pwd))
CP = cp
CFLAGS = $(INC_FLAGS) $(FLAGS) $(DIRECTIVES) --std=gnu99
#various build flags

DEBUG ?= 1
ifeq ($(DEBUG), 1)
	CFLAGS +=   -O0 -g3
	LDFLAGS = -shared
else
	CFLAGS +=  -O3
	LDFLAGS = -shared
# 	ARFLAGS = rcs
endif



PLATFORM ?= LINUX
ifeq ($(PLATFORM),$(filter $(PLATFORM),NRF51 STM32F103))
	#set instruction set to thumb... debatably arm might be valid too i guess but I'm too lazy and this code
	#doesn't really have zero wait to worry about...
	CFLAGS += -mthumb
	# set the ABI to aapcs (current standard, needs to be set consistently or linker will explode?)
	CFLAGS += -mabi=aapcs
	#softcore floating point
	CFLAGS += -mfloat-abi=soft
	# keep every function in separate section. This will allow linker to dump unused functions
  	CFLAGS += -ffunction-sections -fdata-sections -fno-strict-aliasing -fstack-usage
	# don't use functions built-into gcc
	#use embedded libc
	CFLAGS += --specs=nano.specs

	ARFLAGS += --target elf32-littlearm
	CC = arm-none-eabi-gcc
	LD = arm-none-eabi-ld
	AR = arm-none-eabi-ar
else
	DIRECTIVES += -DLINUX
	CC = gcc
	LD = ld
	AR = ar
endif

ifeq ($(PLATFORM), NRF51)
	#setting this wrong (like m4) means weird stuff like hard faults when an int goes negative...
	CPU	= cortex-m0
	CFLAGS += -mcpu=$(CPU)
	#software floating point
	CFLAGS +=-mfloat-abi=soft
endif

.PHONY: all
.PHONY: release
.PHONY: test
.PHONY: profile
.PHONY: clean
.PHONY: cppcheck
.PHONY: includes
.PHONY: copy


all: $(RUNNERS) $(OBJS) cppcheck

includes:
	$(MKDIR) $(INCLUDE_DEST)
	cp $(HEADERS) $(INCLUDE_DEST)

copy: release
	$(CLEANUP)r /mnt/windows/include/$(CURRENT_DIR)
	$(MKDIR) /mnt/windows/include/$(CURRENT_DIR)
	cp $(HEADERS) /mnt/windows/include/$(CURRENT_DIR)
	cp $(RELEASE_DIR)lib$(CURRENT_DIR).a /mnt/windows/include


release: all includes $(RELEASE_DIR)lib$(CURRENT_DIR).a

test: all $(TEST_OBJS) $(TEST_RESULTS) $(CPPCHECK_RESULTS)
	@echo ""
	@echo "-----------------------ANALYSIS AND TESTING SUMMARY-----------------------"
	@echo `find $(TEST_RESULTS_DIR) -type f -exec grep IGNORE {} \;|wc -l` "tests ignored"
	@echo "`find $(TEST_RESULTS_DIR) -type f -exec grep IGNORE {} \;`"
	@echo `find $(TEST_RESULTS_DIR) -type f -exec grep FAIL {} \;|wc -l` "tests failed"
	@echo "`find $(TEST_RESULTS_DIR) -type f -exec grep FAIL {} \;`"
	@echo `find $(TEST_RESULTS_DIR) -type f -exec grep PASS {} \;|wc -l` "tests passed"
	@echo ""
	@echo "`grep -Poh 'ERROR SUMMARY:\K ([0-9]+)' $(TEST_RESULTS_DIR)*| awk '{ SUM += $$1} END { print SUM }'` memory leak(s) detected"
	@echo ""
	@echo `find $(CPPCHECK_RESULTS_DIR) -type f -exec grep warning {} \;|wc -l` "code warnings"
	@echo `find $(CPPCHECK_RESULTS_DIR) -type f -exec grep warning {} \;`
	@echo `find $(CPPCHECK_RESULTS_DIR) -type f -exec grep error {} \;|wc -l` "code errors"
	@echo "`find $(CPPCHECK_RESULTS_DIR) -type f -exec grep error {} \;`"

profile: all $(PROFILING_RESULTS)

$(RELEASE_DIR)lib$(CURRENT_DIR).a: $(OBJS)
	$(AR) $(ARFLAGS) $@ $(OBJS)

#generate profiling data
$(PROFILING_RESULTS_DIR)%.out: $(BUILD_DIR)%.c.o.$(TARGET_EXTENSION)
	$(MKDIR) $(dir $@)
	-$(VALGRIND) --tool=callgrind --callgrind-out-file=$@  $< > /dev/null 2>&1

#execute tests
$(TEST_RESULTS_DIR)%.txt: $(BUILD_DIR)%.c.o.$(TARGET_EXTENSION)
	$(MKDIR) $(dir $@)
	-$(VALGRIND) --suppressions=$(VALGRIND_SUPPS) --gen-suppressions=all --tool=memcheck --leak-check=full $< > $@ 2>&1

#build the test runners
$(BUILD_DIR)%.c.o.$(TARGET_EXTENSION): $(TEST_OUTPUT)%.c.o
	$(CC) -g -o $@ $^ $(CFLAGS) $(OBJS) $(UNITY_ROOT)/src/unity.c $(TEST_RUNNERS)$(basename $(notdir $<))

# assembly
$(BUILD_DIR)%.s.o: %.s
	$(MKDIR) $(dir $@)
	$(AS) $(ASFLAGS) -c $< -o $@

#execute cppcheck
$(CPPCHECK_RESULTS_DIR)%.c.txt: %.c
	$(MKDIR) $(dir $@)
	$(CPPCHECK) $(INC_FLAGS) $(DIRECTIVES) $(CPPCHECK_FLAGS) $< > $@ 2>&1

# c source
$(BUILD_DIR)%.c.o: %.c
	$(MKDIR) $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@


#unity test runners
$(TEST_RUNNERS)%.c:: $(TEST_DIRS)%.c
	$(MKDIR) $(dir $@)
	ruby $(UNITY_ROOT)/auto/generate_test_runner.rb $< $@

clean:
	$(CLEANUP)r $(BUILD_DIR)
	$(CLEANUP)r $(RELEASE_DIR)

.PRECIOUS: $(TEST_RESULTS_DIR)%.txt
.PRECIOUS: $(PROFILING_RESULTS_DIR)%.txt
.PRECIOUS: $(BUILD_DIR)%.c.o.out
