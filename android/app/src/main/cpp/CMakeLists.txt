cmake_minimum_required(VERSION 3.22)
project(llama_android LANGUAGES C CXX)

# -------- toolchain / visibility defaults --------
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_VERBOSE_MAKEFILE ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# keep exported symbols visible
set(CMAKE_C_VISIBILITY_PRESET default)
set(CMAKE_CXX_VISIBILITY_PRESET default)
set(CMAKE_VISIBILITY_INLINES_HIDDEN OFF)

# -------- headers: llama / ggml --------
if (NOT DEFINED LLAMA_HEADERS_DIR)
  set(LLAMA_HEADERS_DIR ${CMAKE_CURRENT_LIST_DIR}/llama)
endif()

if (EXISTS ${LLAMA_HEADERS_DIR}/llama.h)
  message(STATUS "Using llama headers at: ${LLAMA_HEADERS_DIR}")
else()
  message(FATAL_ERROR "llama.h not found in LLAMA_HEADERS_DIR=${LLAMA_HEADERS_DIR}")
endif()

if (NOT DEFINED GGML_HEADERS_DIR)
  set(_cand1 ${LLAMA_HEADERS_DIR}/../ggml/include)
  set(_cand2 ${LLAMA_HEADERS_DIR}/ggml/include)
  if (EXISTS ${_cand1}/ggml.h)
    set(GGML_HEADERS_DIR ${_cand1})
  elseif (EXISTS ${_cand2}/ggml.h)
    set(GGML_HEADERS_DIR ${_cand2})
  endif()
endif()

if (NOT DEFINED GGML_HEADERS_DIR OR NOT EXISTS ${GGML_HEADERS_DIR}/ggml.h)
  message(FATAL_ERROR "ggml.h not found. Pass -DGGML_HEADERS_DIR=/abs/path/to/ggml/include")
else()
  message(STATUS "Using ggml headers at: ${GGML_HEADERS_DIR}")
endif()

include_directories(${LLAMA_HEADERS_DIR})
include_directories(${GGML_HEADERS_DIR})

# -------- prebuilt llama shared lib from jniLibs/<abi> --------
add_library(llama SHARED IMPORTED GLOBAL)
set_target_properties(llama PROPERTIES
  IMPORTED_LOCATION ${CMAKE_CURRENT_LIST_DIR}/../jniLibs/${ANDROID_ABI}/libllama.so
)

# -------- our JNI/FFI wrapper --------
add_library(llama_android SHARED
  ${CMAKE_CURRENT_LIST_DIR}/llm_bridge.cpp
)

# make dlsym happy + prevent GC of our exported symbols
target_link_options(llama_android PRIVATE
  -Wl,--export-dynamic
  -Wl,--undefined=llm_init
  -Wl,--undefined=llm_infer
  -Wl,--undefined=llm_dispose
)

# Android system libs
find_library(log-lib     log)
find_library(android-lib android)

# STL runtime (pack libc++_shared.so into APK)
find_library(cpp_shared  c++_shared REQUIRED)

target_link_libraries(llama_android
  PRIVATE
    llama
    ${log-lib}
    ${android-lib}
    ${cpp_shared}
)

set_target_properties(llama_android PROPERTIES
  C_VISIBILITY_PRESET default
  CXX_VISIBILITY_PRESET default
  VISIBILITY_INLINES_HIDDEN OFF
)
