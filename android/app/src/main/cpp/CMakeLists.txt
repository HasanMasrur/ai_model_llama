cmake_minimum_required(VERSION 3.22)
project(llama_android LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_VERBOSE_MAKEFILE ON)

# --- Where to find llama headers ---
# Default to src/main/cpp/llama; override via -DLLAMA_HEADERS_DIR=/abs/path
if (NOT DEFINED LLAMA_HEADERS_DIR)
  set(LLAMA_HEADERS_DIR ${CMAKE_CURRENT_LIST_DIR}/llama)
endif()

if (EXISTS ${LLAMA_HEADERS_DIR}/llama.h)
  message(STATUS "Using llama headers at: ${LLAMA_HEADERS_DIR}")
else()
  message(FATAL_ERROR "llama.h not found in LLAMA_HEADERS_DIR=${LLAMA_HEADERS_DIR}")
endif()

include_directories(${LLAMA_HEADERS_DIR})

# --- Prebuilt llama shared library in jniLibs/<abi> ---
add_library(llama SHARED IMPORTED GLOBAL)
set_target_properties(llama PROPERTIES
  IMPORTED_LOCATION ${CMAKE_CURRENT_LIST_DIR}/../jniLibs/${ANDROID_ABI}/libllama.so
)

# --- Your JNI/FFI wrapper ---
add_library(llama_android SHARED
  ${CMAKE_CURRENT_LIST_DIR}/llm_bridge.cpp
)

# Android system libs
find_library(log-lib log)
find_library(android-lib android)

target_link_libraries(llama_android
  PRIVATE
  llama
  ${log-lib}
  ${android-lib}
)
