TARGET = SpringBoardAlert.dylib
TC = SpringBoardAlert.tc
CC = clang
SDK ?= $(shell xcrun --sdk iphoneos --show-sdk-path)
DESTDIR ?= .

CFLAGS = -isysroot $(SDK) -arch arm64 -arch arm64e -miphoneos-version-min=15.0 -fobjc-arc -dynamiclib -framework UIKit -framework Foundation -framework CoreGraphics -install_name @loader_path/$(TARGET)

.PHONY: all clean

all: $(TARGET) $(TC)
	@if [ -n "$(DESTDIR)" ] && [ "$(DESTDIR)" != "." ]; then \
		cp "$(TARGET)" "$(DESTDIR)/"; \
		cp "$(TC)" "$(DESTDIR)/"; \
	fi

$(TARGET): SpringBoardAlert.m
	$(CC) $(CFLAGS) -o $@ $^
	ldid -Cadhoc -S $@

$(TC): $(TARGET)
	trustcache create $@ $<

clean:
	rm -f $(TARGET) $(TC)
