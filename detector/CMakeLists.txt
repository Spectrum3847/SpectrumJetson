# Drop-in lib971apriltag.so for the FRC-Team-4143 PhotonVision fork, built from
# Austin Schuh's current CUDA AprilTag detector as packaged in frc971/bos
# (third_party/971apriltag) plus our JNI bridge (GpuDetectorJNI.cc).
#
# Configure with -DBOS_DIR=<frc971/bos checkout with the abseil-cpp submodule>.
# scripts/jetson/07-build-bos-detector.sh does the fetch + build.
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

set(ALLWPILIB_DIR "" CACHE PATH "AllWPILib v2027.0.0-alpha-7 source checkout")
set(ALLWPILIB_INCLUDE_DIR "${ALLWPILIB_DIR}/wpiutil/src/main/native/include")
if(NOT EXISTS "${ALLWPILIB_INCLUDE_DIR}/wpi/util/RawFrame.h" OR
   NOT EXISTS "${ALLWPILIB_INCLUDE_DIR}/wpi/util/PixelFormat.h")
  message(FATAL_ERROR "ALLWPILIB_DIR must contain the v2027.0.0-alpha-7 wpiutil headers")
endif()
include(CheckCXXSourceCompiles)
set(CMAKE_REQUIRED_INCLUDES "${ALLWPILIB_INCLUDE_DIR}")
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
check_cxx_source_compiles([=[
#include <wpi/util/PixelFormat.h>
#include <wpi/util/RawFrame.h>
int main() {
  WPI_RawFrame frame{};
  return frame.pixelFormat == WPI_PIXFMT_MJPEG ? 0 : 1;
}
]=] SPECTRUM_WPIUTIL_CXX20_HEADERS)
unset(CMAKE_REQUIRED_INCLUDES)
unset(CMAKE_TRY_COMPILE_TARGET_TYPE)
if(NOT SPECTRUM_WPIUTIL_CXX20_HEADERS)
  message(FATAL_ERROR "The JNI bridge must compile as C++20 with AllWPILib alpha-7 headers")
endif()

# Same globals frc971/bos's top-level CMakeLists.txt sets for its subprojects.
find_package(CUDAToolkit REQUIRED)
include_directories(${CUDAToolkit_INCLUDE_DIRS})
link_directories(${CUDAToolkit_LIBRARY_DIR})
add_compile_options($<$<COMPILE_LANGUAGE:C,CXX>:-march=armv8-a+simd> $<$<COMPILE_LANGUAGE:C,CXX>:-Wno-psabi>)

set(ABSL_PROPAGATE_CXX_STD ON)
set(ABSL_ENABLE_INSTALL OFF)
add_subdirectory(${BOS_DIR}/third_party/abseil-cpp abseil EXCLUDE_FROM_ALL)
add_subdirectory(${BOS_DIR}/third_party/971apriltag 971apriltag EXCLUDE_FROM_ALL)

find_package(JNI REQUIRED)
find_package(OpenCV REQUIRED core)
find_package(JPEG REQUIRED)  # libjpeg-turbo (libjpeg-turbo8-dev), for decodeMjpegGray

add_library(971apriltag_jni SHARED GpuDetectorJNI.cc fault_kernel.cu)
set_target_properties(971apriltag_jni PROPERTIES OUTPUT_NAME 971apriltag)
target_include_directories(971apriltag_jni PRIVATE ${BOS_DIR} ${JNI_INCLUDE_DIRS}
                                                   ${OpenCV_INCLUDE_DIRS} ${ALLWPILIB_INCLUDE_DIR})
# bos uses ABSL_FLAG (use_neon, debug_blob_index) but its CMake does not link absl::flags.
find_package(Threads REQUIRED)
target_link_libraries(971apriltag_jni PRIVATE 971apriltag absl::flags CUDA::cudart JPEG::JPEG
                                              ${JNI_LIBRARIES} Threads::Threads ${CMAKE_DL_LIBS})
# Fail at link time, not in the JVM, if a symbol is missing.
target_link_options(971apriltag_jni PRIVATE -Wl,--no-undefined)

# SpectrumJetson: NVJPG hardware JPEG decode (libspectrumnvjpg.so), which lib971apriltag.so
# loads with dlopen when SPECTRUM_JPEG_DECODER=nvjpg. Its own library because libnvjpeg exports
# the same jpeg_* names as libjpeg-turbo (nvjpg_decoder.h). It must never link libjpeg-turbo, and
# it takes jpeglib.h from the Jetson Multimedia API (libnvjpeg's struct layout).
set(JETSON_MMAPI /usr/src/jetson_multimedia_api CACHE PATH "Jetson Multimedia API (nvidia-l4t-jetson-multimedia-api)")
set(TEGRA_LIBDIR /usr/lib/aarch64-linux-gnu/nvidia)
find_library(NVJPEG_LIB nvjpeg PATHS ${TEGRA_LIBDIR} NO_DEFAULT_PATH)
find_library(NVBUFSURFACE_LIB nvbufsurface PATHS ${TEGRA_LIBDIR} NO_DEFAULT_PATH)
find_library(EGL_LIB EGL)
if(NVJPEG_LIB AND NVBUFSURFACE_LIB AND EGL_LIB AND EXISTS ${JETSON_MMAPI}/include/libjpeg-8b/jpeglib.h)
  add_library(spectrumnvjpg SHARED NvJpgDecoder.cc nvjpg_bgr.cu)
  target_include_directories(spectrumnvjpg BEFORE PRIVATE ${JETSON_MMAPI}/include/libjpeg-8b
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
