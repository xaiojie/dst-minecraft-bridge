CXX := xcrun clang++
CXXFLAGS := -std=c++17 -Wall -Wextra -Werror -O2 -arch x86_64 -Iinclude
BUILD := build
JAVA ?= $(shell /usr/libexec/java_home -v 21)/bin/java
.PHONY: contract-test java-contract-classes clean
$(BUILD)/frame_contract_test: tests/frame_contract_test.cpp include/frame_protocol.h
	mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) tests/frame_contract_test.cpp -o $@
java-contract-classes:
	cd ../mc && ./gradlew contractTestClasses --console plain
contract-test: $(BUILD)/frame_contract_test java-contract-classes
	DSTMC_JAVA="$(JAVA)" ./$(BUILD)/frame_contract_test ../protocol/fixtures/frame-v2.bin
clean:
	rm -rf $(BUILD)
