CC ?= cc
CFLAGS ?= -O1 -g -Wall -Wextra

SRC_DIR := ../../ZZ9000_proto.sdk/ZZ9000OS/src
MOCK_DIR := mock
BUILD_DIR := build
TARGET := $(BUILD_DIR)/ethernet_bdfree_test

# ethernet.c is compiled from BUILD_DIR. A quoted #include resolves against
# the directory of the file containing it, so the mock memorymap.h/mntzorro.h
# placed beside the copy shadow the firmware ones -- otherwise ethernet.c
# would be handed the card's real addresses and dereference them.
SHADOW := memorymap.h mntzorro.h
SHADOWED := $(addprefix $(BUILD_DIR)/,$(SHADOW))

CPPFLAGS += -I$(MOCK_DIR) -I$(SRC_DIR) -DETH_HOST_TEST=1

.PHONY: test clean

test: $(TARGET)
	$(TARGET)

$(BUILD_DIR)/ethernet.c: $(SRC_DIR)/ethernet.c
	@mkdir -p $(BUILD_DIR)
	cp $< $@

$(BUILD_DIR)/%.h: $(MOCK_DIR)/%.h
	@mkdir -p $(BUILD_DIR)
	cp $< $@

$(TARGET): ethernet_bdfree_test.c $(MOCK_DIR)/xemacps_mock.c $(BUILD_DIR)/ethernet.c $(SHADOWED) $(MOCK_DIR)/xemacps.h
	$(CC) $(CPPFLAGS) $(CFLAGS) -o $@ ethernet_bdfree_test.c $(MOCK_DIR)/xemacps_mock.c $(BUILD_DIR)/ethernet.c

clean:
	rm -rf $(BUILD_DIR)
