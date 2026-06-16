# betto_onnxrt_ios.mk — Makefile fragment for the betto_onnxrt_ios Flutter plugin.
# Included from the repo-root Makefile via
# `include packages/betto_onnxrt_ios/betto_onnxrt_ios.mk`.

BETTO_IOS := packages/betto_onnxrt_ios

prepare_ios:
	cd $(BETTO_IOS) && flutter pub get
.PHONY: prepare_ios

clean_ios:
	cd $(BETTO_IOS) && flutter clean
.PHONY: clean_ios

# License checks for the iOS plugin. The plugin contains a single Dart library
# file and a Swift implementation file. addlicense is run inline here since the
# iOS package has only a handful of source files and no addlicense_config.txt of
# its own.
license_check_ios:
	addlicense -l apache -c "The Authors" --check \
	  --ignore="**/*.yml" \
	  --ignore="**/*.yaml" \
	  --ignore="**/*.xml" \
	  --ignore="**/*.sh" \
	  --ignore="**/*.html" \
	  --ignore="**/*.rb" \
	  --ignore="**/*.txt" \
	  --ignore="**/.dart_tool/**" \
	  --ignore="build/**" \
	  $(BETTO_IOS)
.PHONY: license_check_ios

license_add_ios:
	addlicense -l apache -c "The Authors" \
	  --ignore="**/*.yml" \
	  --ignore="**/*.yaml" \
	  --ignore="**/*.xml" \
	  --ignore="**/*.sh" \
	  --ignore="**/*.html" \
	  --ignore="**/*.rb" \
	  --ignore="**/*.txt" \
	  --ignore="**/.dart_tool/**" \
	  --ignore="build/**" \
	  $(BETTO_IOS)
.PHONY: license_add_ios
