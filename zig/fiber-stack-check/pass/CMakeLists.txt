cmake_minimum_required(VERSION 3.13)
project(FiberStackCheck LANGUAGES C CXX)

find_package(LLVM REQUIRED CONFIG)

message(STATUS "Found LLVM includes: ${LLVM_INCLUDE_DIRS}")
message(STATUS "LLVM Link Dylib: ${LLVM_LINK_LLVM_DYLIB}")

include_directories(${LLVM_INCLUDE_DIRS})
add_definitions(${LLVM_DEFINITIONS})

add_library(FiberStackCheck SHARED FiberStackCheckPass.cpp)
set_target_properties(FiberStackCheck PROPERTIES
    CXX_STANDARD 17
    POSITION_INDEPENDENT_CODE ON
)

if(LLVM_LINK_LLVM_DYLIB)
    target_link_libraries(FiberStackCheck PRIVATE LLVM)
else()
    # Fallback: If no dylib, we link components, but we might need to allow undefined symbols
    # if the host tool 'opt' has them.
    llvm_map_components_to_libnames(LLVM_LIBS core irreader passes support)
    target_link_libraries(FiberStackCheck PRIVATE ${LLVM_LIBS})
endif()

