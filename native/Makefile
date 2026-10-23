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
	DSTMC_JAVA="$(JAVA)" $(BUILD)/frame_contract_test ../protocol/fixtures/frame-v2.bin
clean:
	rm -rf $(BUILD)

GLFLAGS := -Wno-deprecated-declarations -framework OpenGL -framework Cocoa
.PHONY: all gl-test
all: $(BUILD)/libdstmc_probe.dylib
$(BUILD)/gl_state_test: tests/gl_state_test.mm src/gl_observer.mm include/gl_observer.h
	mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) $(GLFLAGS) tests/gl_state_test.mm src/gl_observer.mm -o $@
gl-test: $(BUILD)/gl_state_test
	$(BUILD)/gl_state_test
$(BUILD)/frame_reader_test: tests/frame_reader_test.cpp src/frame_reader.cpp include/gl_observer.h include/frame_protocol.h
	mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) tests/frame_reader_test.cpp src/frame_reader.cpp -o $@
.PHONY: reader-test
reader-test: $(BUILD)/frame_reader_test
	$(BUILD)/frame_reader_test
$(BUILD)/loader_test: tests/loader_test.mm
	mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) $(GLFLAGS) $< -o $@
.PHONY: loader-test
loader-test: $(BUILD)/loader_test all
	@d=$$(mktemp -d); DSTMC_PROBE_DIR="$$d" DYLD_INSERT_LIBRARIES="$(abspath $(BUILD))/libdstmc_probe.dylib" $(BUILD)/loader_test; result=$$?; rm -rf "$$d"; exit $$result
$(BUILD)/libdstmc_probe.dylib: src/entry.mm src/camera_http.mm src/gl_observer.mm src/frame_reader.cpp src/camera_service.cpp src/compositor.mm src/scene_depth.mm include/compositor.h include/camera_http.h include/camera_service.h include/gl_observer.h include/frame_protocol.h
	mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) $(GLFLAGS) -dynamiclib src/entry.mm src/camera_http.mm src/gl_observer.mm src/frame_reader.cpp src/camera_service.cpp src/compositor.mm src/scene_depth.mm -o $@

$(BUILD)/lease_test: tests/lease_test.cpp src/camera_service.cpp include/camera_service.h include/frame_protocol.h include/camera_http.h include/compositor.h include/gl_observer.h
	mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) tests/lease_test.cpp src/camera_service.cpp -o $@
.PHONY: lease-test
lease-test: $(BUILD)/lease_test
	$(BUILD)/lease_test

$(BUILD)/compositor_test: tests/compositor_test.mm src/compositor.mm src/scene_depth.mm src/camera_service.cpp include/compositor.h include/camera_service.h include/frame_protocol.h include/gl_observer.h
	mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) $(GLFLAGS) tests/compositor_test.mm src/compositor.mm src/scene_depth.mm src/camera_service.cpp -o $@
gl-test: compositor-test
.PHONY: compositor-test
compositor-test: $(BUILD)/compositor_test
	$(BUILD)/compositor_test

$(BUILD)/http_framing_test: tests/http_framing_test.mm src/camera_http.mm src/camera_service.cpp include/camera_http.h include/camera_service.h include/frame_protocol.h
	mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) $(GLFLAGS) tests/http_framing_test.mm src/camera_http.mm src/camera_service.cpp -o $@
.PHONY: http-framing-test
http-framing-test: $(BUILD)/http_framing_test
	$(BUILD)/http_framing_test

$(BUILD)/transform_status_test: tests/transform_status_test.mm src/camera_http.mm src/camera_service.cpp include/camera_http.h include/camera_service.h include/frame_protocol.h
	mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) $(GLFLAGS) tests/transform_status_test.mm src/camera_http.mm src/camera_service.cpp -o $@
.PHONY: transform-status-test
transform-status-test: $(BUILD)/transform_status_test
	$(BUILD)/transform_status_test

$(BUILD)/scene_pipeline_test: tests/scene_pipeline_test.mm src/entry.mm src/compositor.mm src/scene_depth.mm src/camera_service.cpp src/gl_observer.mm include/compositor.h include/camera_service.h
	mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) $(GLFLAGS) tests/scene_pipeline_test.mm src/compositor.mm src/scene_depth.mm src/camera_service.cpp src/gl_observer.mm -o $@
.PHONY: pipeline-test
pipeline-test: $(BUILD)/scene_pipeline_test
	$(BUILD)/scene_pipeline_test

$(BUILD)/window_geometry_test: tests/window_geometry_test.cpp include/camera_http.h
	mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) $< -o $@
.PHONY: geometry-test
geometry-test: $(BUILD)/window_geometry_test
	$(BUILD)/window_geometry_test
