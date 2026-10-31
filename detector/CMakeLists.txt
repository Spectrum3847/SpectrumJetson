# Drop-in lib971apriltag.so for the FRC-Team-4143 PhotonVision fork, built from
# Austin Schuh's current CUDA AprilTag detector as packaged in frc971/bos
# (third_party/971apriltag) plus our JNI bridge (GpuDetectorJNI.cc).
#
# Configure with -DBOS_DIR=<frc971/bos checkout with the abseil-cpp submodule> and
# -DAPRILTAG_DIR=<AprilRobotics/apriltag checkout, in a directory named "apriltag">.
# scripts/jetson/07-build-bos-detector.sh does the fetch + build.
#
# No WPILib: PhotonVision loads its own (2026 or 2027) into the same JVM, so this library links
# none of it (wpi_compat.h), and the AprilTag C library and abseil are built in statically with
# their symbols hidden (--exclude-libs), so they can't clash with WPILib's copies in the process.
cmake_minimum_required(VERSION 3.21)

set(CMAKE_CUDA_COMPILER /usr/local/cuda/bin/nvcc CACHE FILEPATH "")
project(spectrum_971apriltag C CXX CUDA)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_STANDARD 20)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_ARCHITECTURES 87)  # Orin
set(CMAKE_CUDA20_STANDARD_COMPILE_OPTION "-std=c++20")
set(CMAKE_CUDA20_EXTENSION_COMPILE_OPTION "-std=c++20")
set(CMAKE_CUDA_FLAGS "--expt-relaxed-constexpr")
# Everything ends up inside one shared library loaded by the JVM.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(BOS_DIR "" CACHE PATH "frc971/bos checkout")
if(NOT EXISTS "${BOS_DIR}/third_party/971apriltag/apriltag.h")
  message(FATAL_ERROR "BOS_DIR must point at a frc971/bos checkout")
endif()
set(APRILTAG_DIR "" CACHE PATH "AprilRobotics/apriltag checkout, in a directory named apriltag")
get_filename_component(APRILTAG_NAME "${APRILTAG_DIR}" NAME)
if(NOT EXISTS "${APRILTAG_DIR}/apriltag.h" OR NOT APRILTAG_NAME STREQUAL "apriltag")
  message(FATAL_ERROR "APRILTAG_DIR must be an AprilRobotics/apriltag checkout named apriltag")
endif()

# Same globals frc971/bos's top-level CMakeLists.txt sets for its subprojects.
find_package(CUDAToolkit REQUIRED)
find_package(Threads REQUIRED)
include_directories(${CUDAToolkit_INCLUDE_DIRS})
# CUDA 13 moved CUB, Thrust and libcu++ under include/cccl, which nvcc adds itself but the C++
# compiler doesn't; bos's headers include <cub/...> from plain .cc files too.
# CUB 3 also removed TransformInputIterator and DiscardOutputIterator, which bos still uses:
# cub13/ has stand-ins at the removed headers' paths (aliases for their Thrust replacements).
foreach(d ${CUDAToolkit_INCLUDE_DIRS})
  if(EXISTS ${d}/cccl/cub)
    include_directories(${d}/cccl)
  endif()
  if(EXISTS ${d}/cccl/cub AND NOT EXISTS ${d}/cccl/cub/iterator/transform_input_iterator.cuh)
    include_directories(${CMAKE_CURRENT_SOURCE_DIR}/cub13)
  endif()
endforeach()
link_directories(${CUDAToolkit_LIBRARY_DIR})
add_compile_options($<$<COMPILE_LANGUAGE:C,CXX>:-march=armv8-a+simd> $<$<COMPILE_LANGUAGE:C,CXX>:-Wno-psabi>)

# The AprilTag C library WPILib bundles (the same upstream; WPILib 2027 alpha-8 pins b7c0ebe),
# as the "apriltag" target bos's CMake links; included as <apriltag/...>, like WPILib installs it.
# Not apriltag.c: bos carries its own modified copy (971apriltag_dep), which with WPILib's shared
# libapriltag silently took precedence; linked statically the two would clash.
file(GLOB APRILTAG_COMMON_SRC ${APRILTAG_DIR}/common/*.c)
add_library(apriltag STATIC ${APRILTAG_DIR}/apriltag_pose.c
            ${APRILTAG_DIR}/apriltag_quad_thresh.c ${APRILTAG_DIR}/tag36h11.c ${APRILTAG_COMMON_SRC})
get_filename_component(APRILTAG_PARENT "${APRILTAG_DIR}" DIRECTORY)
target_include_directories(apriltag PUBLIC ${APRILTAG_PARENT} PRIVATE ${APRILTAG_DIR})
set_target_properties(apriltag PROPERTIES C_VISIBILITY_PRESET hidden)
target_compile_options(apriltag PRIVATE -w)
target_link_libraries(apriltag PUBLIC m Threads::Threads)
# bos's third_party/971apriltag/CMakeLists.txt starts with find_package(wpilib REQUIRED); all it
# needs from it is the apriltag target above and its headers on the include path for every target
# there (971apriltag_dep includes <apriltag/...> without linking apriltag).
file(WRITE ${CMAKE_BINARY_DIR}/wpilib-stub/wpilibConfig.cmake
     "# SpectrumJetson: no WPILib\ninclude_directories(${APRILTAG_PARENT})\n")
set(wpilib_DIR ${CMAKE_BINARY_DIR}/wpilib-stub)

set(ABSL_PROPAGATE_CXX_STD ON)
set(ABSL_ENABLE_INSTALL OFF)
add_subdirectory(${BOS_DIR}/third_party/abseil-cpp abseil EXCLUDE_FROM_ALL)
add_subdirectory(${BOS_DIR}/third_party/971apriltag 971apriltag EXCLUDE_FROM_ALL)
# bos's apriltag.c copy (971apriltag_dep) calls AprilTag's common/ code but doesn't link it, which
# only worked with WPILib's shared libapriltag; declare it so the static link orders them right.
target_link_libraries(971apriltag_dep PUBLIC apriltag)

# JVM only: the headless JDK has no AWT, which FindJNI otherwise requires.
find_package(JNI REQUIRED COMPONENTS JVM)
# Headers only in lib971apriltag.so (PhotonVision's JVM has its own OpenCV); imgproc for the far
# search's bench test, a separate program.
find_package(OpenCV REQUIRED core imgproc)
find_package(JPEG REQUIRED)  # libjpeg-turbo (libjpeg-turbo8-dev), for decodeMjpegGray

add_library(971apriltag_jni SHARED GpuDetectorJNI.cc far_search.cc fault_kernel.cu)
set_target_properties(971apriltag_jni PROPERTIES OUTPUT_NAME 971apriltag)
target_include_directories(971apriltag_jni PRIVATE ${BOS_DIR} ${JNI_INCLUDE_DIRS}
                                                   ${OpenCV_INCLUDE_DIRS})
# bos uses ABSL_FLAG (use_neon, debug_blob_index) but its CMake does not link absl::flags.
target_link_libraries(971apriltag_jni PRIVATE 971apriltag absl::flags CUDA::cudart JPEG::JPEG
                                              ${JNI_LIBRARIES} Threads::Threads ${CMAKE_DL_LIBS})
# Only the JNI entry points (JNIEXPORT) and spectrum_cuda_* are exported; everything linked in
# statically (AprilTag, abseil, bos) stays private to this library. --no-undefined: fail at link
# time, not in the JVM, if a symbol is missing.
set_target_properties(971apriltag_jni PROPERTIES CXX_VISIBILITY_PRESET hidden
                                                 CUDA_VISIBILITY_PRESET hidden)
target_link_options(971apriltag_jni PRIVATE -Wl,--no-undefined -Wl,--exclude-libs,ALL)

# SpectrumJetson: NVJPG hardware JPEG decode (libspectrumnvjpg.so), which lib971apriltag.so
# loads with dlopen when SPECTRUM_JPEG_DECODER=nvjpg. Its own library because libnvjpeg exports
# the same jpeg_* names as libjpeg-turbo (nvjpg_decoder.h). It must never link libjpeg-turbo, and
# it takes jpeglib.h from the Jetson Multimedia API (libnvjpeg's struct layout).
set(JETSON_MMAPI /usr/src/jetson_multimedia_api CACHE PATH "Jetson Multimedia API (nvidia-l4t-jetson-multimedia-api)")
set(TEGRA_LIBDIR /usr/lib/aarch64-linux-gnu/nvidia)
# JetPack 6 (r36): libnvjpeg.so and include/libjpeg-8b. JetPack 7 (r39): renamed libnvmm_jpeg.so,
# with include/libjpeg-9f. (Tegra's, not CUDA's libnvjpeg in /usr/local/cuda.)
find_library(NVJPEG_LIB NAMES nvmm_jpeg nvjpeg PATHS ${TEGRA_LIBDIR} NO_DEFAULT_PATH)
find_library(NVBUFSURFACE_LIB nvbufsurface PATHS ${TEGRA_LIBDIR} NO_DEFAULT_PATH)
find_library(EGL_LIB EGL)
foreach(v libjpeg-9f libjpeg-8b)
  if(NOT MMAPI_JPEG_INCLUDE AND EXISTS ${JETSON_MMAPI}/include/${v}/jpeglib.h)
    set(MMAPI_JPEG_INCLUDE ${JETSON_MMAPI}/include/${v})
  endif()
endforeach()
if(NVJPEG_LIB AND NVBUFSURFACE_LIB AND EGL_LIB AND MMAPI_JPEG_INCLUDE)
  message(STATUS "NVJPG: ${NVJPEG_LIB}, headers ${MMAPI_JPEG_INCLUDE}")
  add_library(spectrumnvjpg SHARED NvJpgDecoder.cc nvjpg_bgr.cu)
  target_include_directories(spectrumnvjpg BEFORE PRIVATE ${MMAPI_JPEG_INCLUDE}
                                                          ${JETSON_MMAPI}/include)
  target_compile_definitions(spectrumnvjpg PRIVATE EGL_NO_X11)
  set_target_properties(spectrumnvjpg PROPERTIES CXX_VISIBILITY_PRESET hidden
                                                 CUDA_VISIBILITY_PRESET hidden)
  target_link_libraries(spectrumnvjpg PRIVATE ${NVJPEG_LIB} ${NVBUFSURFACE_LIB} ${EGL_LIB}
                                              CUDA::cuda_driver CUDA::cudart)
  target_link_options(spectrumnvjpg PRIVATE -Wl,--no-undefined -Wl,-rpath,${TEGRA_LIBDIR})
else()
  message(STATUS "libnvjpeg or the Jetson Multimedia API not found: skipping libspectrumnvjpg.so")
endif()

# SpectrumJetson: TensorRT YOLO object detection (libspectrumtrt.so) for PhotonVision's
# object-detection pipeline (TensorRtYoloJNI.cu; Java side in the photonvision-13 patch).
find_library(NVINFER_LIB nvinfer)
if(NVINFER_LIB)
  add_library(spectrumtrt_jni SHARED TensorRtYoloJNI.cu)
  set_target_properties(spectrumtrt_jni PROPERTIES OUTPUT_NAME spectrumtrt)
  target_include_directories(spectrumtrt_jni PRIVATE ${JNI_INCLUDE_DIRS} ${OpenCV_INCLUDE_DIRS})
  target_link_libraries(spectrumtrt_jni PRIVATE ${NVINFER_LIB} CUDA::cudart ${JNI_LIBRARIES})
  target_link_options(spectrumtrt_jni PRIVATE -Wl,--no-undefined)
else()
  message(STATUS "TensorRT (libnvinfer) not found: skipping libspectrumtrt.so")
endif()

# SpectrumJetson: fieldcal_detect, which replays a Rewind recording through the same 971 detector
# for tools/fieldcal (field calibration). A command-line tool; not installed, not used by
# PhotonVision. Build it alone with --target fieldcal_detect.
add_executable(fieldcal_detect fieldcal_detect.cc)
target_include_directories(fieldcal_detect PRIVATE ${BOS_DIR})
target_link_libraries(fieldcal_detect PRIVATE 971apriltag absl::flags CUDA::cudart JPEG::JPEG
                                              Threads::Threads ${CMAKE_DL_LIBS})

# SpectrumJetson: the far-tag search's bench test (far_search_test.cc): synthetic tags, no camera.
# tests/far-search/run.sh builds and runs it on the Jetson.
add_executable(far_search_test far_search_test.cc far_search.cc)
target_include_directories(far_search_test PRIVATE ${BOS_DIR} ${OpenCV_INCLUDE_DIRS})
target_link_libraries(far_search_test PRIVATE 971apriltag absl::flags CUDA::cudart JPEG::JPEG
                                              ${OpenCV_LIBS} Threads::Threads ${CMAKE_DL_LIBS})

# SpectrumJetson: far_replay, a whole Rewind session through the detector with the far-tag search
# deciding as it does live (far_replay.cc). A command-line tool; tests/far-search/replay.sh.
add_executable(far_replay far_replay.cc far_search.cc)
target_include_directories(far_replay PRIVATE ${BOS_DIR} ${OpenCV_INCLUDE_DIRS})
target_link_libraries(far_replay PRIVATE 971apriltag absl::flags CUDA::cudart JPEG::JPEG
                                         ${OpenCV_LIBS} Threads::Threads ${CMAKE_DL_LIBS})

# SpectrumJetson: graph_bench, Detect() timing (thread CPU, wall) and exact detections on one
# Rewind camera folder, for A/B tests of the detector's CUDA launch path (bos-11). Not installed.
add_executable(graph_bench graph_bench.cc)
target_include_directories(graph_bench PRIVATE ${BOS_DIR})
target_link_libraries(graph_bench PRIVATE 971apriltag absl::flags CUDA::cudart JPEG::JPEG
                                          Threads::Threads ${CMAKE_DL_LIBS})
