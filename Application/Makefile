.PHONY: all clean build_clean

APP = build/Build/Products/Debug-iphoneos/Dopamine.app

all: Dopamine.ipa

Dopamine.ipa: $(APP)
	@echo Packaging Mini payload
	@if [ -f ../BaseBin/basebin.tar ]; then cp ../BaseBin/basebin.tar $(APP)/basebin.tar; else echo "warning: ../BaseBin/basebin.tar missing — run make -C BaseBin"; fi
	@if [ -f ../BaseBin/basebin.tc ]; then cp ../BaseBin/basebin.tc $(APP)/basebin.tc; fi
	@echo Ad-Hoc signing Dopamine
	xattr -rc $(APP)
	ldid -S $(APP)
	ldid -SDopamine/Dopamine.entitlements $(APP)/Dopamine
	rm -rf Payload Dopamine.ipa
	mkdir Payload
	cp -r $(APP) Payload/Dopamine.app
	zip -Ar Dopamine.ipa Payload
	rm -rf Payload
	rm -rf Dopamine.tipa
	cp Dopamine.ipa Dopamine.tipa

ifeq ($(NIGHTLY), 1)
$(APP): FORCE
	xcodebuild -scheme Dopamine -derivedDataPath build -destination 'generic/platform=iOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO GCC_PREPROCESSOR_DEFINITIONS='NIGHTLY=1 COMMIT_HASH=\"$(COMMIT_HASH)\"'
else
$(APP): FORCE
	xcodebuild -scheme Dopamine -derivedDataPath build -destination 'generic/platform=iOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
endif

clean:
	rm -rf build Payload Dopamine.ipa Dopamine.tipa
	@$(MAKE) -C ../Demo clean

build_clean:
	rm -rf Payload build

FORCE: ;
