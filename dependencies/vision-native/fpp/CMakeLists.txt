cmake_minimum_required(VERSION 3.0)
project(FPPLibrary)

# Set the source files
set(SOURCES
  ../utility/cvtools.cpp
  ../projector/ProjectorOpenGL.cpp
  ../projector/OpenGLContext.Unix.cpp
  ../projector/LC4500API/dlpc350_api.cpp
  ../projector/LC4500API/dlpc350_usb.cpp
  ../projector/LC4500API/dlpc350_firmware.cpp
  ../projector/LC4500API/hid.Libusb.c
  ../codec/CodecFactory.cpp
  ../codec/CodecPhaseShift2x3.cpp
  ../codec/CodecPhaseShiftDescatter.cpp
  ../codec/CodecPhaseShift3.cpp
  ../codec/CodecPhaseShift3FastWrap.cpp
  ../codec/CodecPhaseShift3Unwrap.cpp
  ../codec/CodecPhaseShift4.cpp
  ../codec/CodecFastRatio.cpp
  ../codec/CodecPhaseShift2p1.cpp
  ../codec/CodecPhaseShiftModulated.cpp
  ../codec/CodecPhaseShiftMicro.cpp
  ../codec/CodecGrayCode.cpp
  ../codec/pstools.cpp
  ../codec/CodecPhaseShiftNStep.cpp
  ../codec/phaseunwrap.cpp
  ../codec/CodecCalibration.cpp
  ../triangulator/Triangulator.cpp
  ../triangulator/RBFInterpolator.cpp
  ../triangulator/CalibrationData.cpp
  )

add_library(FFPLibrary SHARED ${SOURCES})
target_include_directories(FFPLibrary PUBLIC
  ../projector ../utility ../triangulator ../codec ../projector/LC4500API
  ${OpenCV_INCLUDE_DIRS})
target_link_libraries(FFPLibrary PUBLIC ${OpenCV_LIBS} Eigen3::Eigen
  OpenGL::GL X11::X11 PkgConfig::LIBUSB)
