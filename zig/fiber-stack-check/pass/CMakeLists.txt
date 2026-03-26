cmake_minimum_required(VERSION 3.13)
project(FiberStackCheck LANGUAGES C CXX)

find_package(LLVM REQUIRED CONFIG)

message(STATUS "Found LLVM ${LLVM_PACKAGE_VERSION}")
message(STATUS "LLVM includes: ${LLVM_INCLUDE_DIRS}")

include_directories(${LLVM_INCLUDE_DIRS})
add_definitions(${LLVM_DEFINITIONS})

# ── Shared plugin (for llc --load / --run-pass) ──────────────────
add_library(FiberStackCheck SHARED FiberStackCheckPass.cpp)
set_target_properties(FiberStackCheck PROPERTIES
    CXX_STANDARD 17
    POSITION_INDEPENDENT_CODE ON
)

if(LLVM_LINK_LLVM_DYLIB)
    target_link_libraries(FiberStackCheck PRIVATE LLVM)
else()
    llvm_map_components_to_libnames(LLVM_LIBS core codegen support)
    target_link_libraries(FiberStackCheck PRIVATE ${LLVM_LIBS})
endif()

# ── Standalone tool (avoids MIR round-trip) ──────────────────────
add_executable(fiber-instrument FiberInstrument.cpp)
set_target_properties(fiber-instrument PROPERTIES
    CXX_STANDARD 17
)

if(LLVM_LINK_LLVM_DYLIB)
    target_link_libraries(fiber-instrument PRIVATE LLVM)
else()
    llvm_map_components_to_libnames(TOOL_LIBS
        core codegen irreader passes support
        x86asmparser x86codegen x86desc x86info
        aarch64asmparser aarch64codegen aarch64desc aarch64info
        mc mcparser
        selectiondag
        target
    )
    target_link_libraries(fiber-instrument PRIVATE ${TOOL_LIBS})
endif()
