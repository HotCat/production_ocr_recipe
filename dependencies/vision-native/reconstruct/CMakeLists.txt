add_library(reconstruct SHARED reconstruct.cpp)
target_compile_definitions(reconstruct PRIVATE EIGEN_MAX_ALIGN_BYTES=16)
target_include_directories(reconstruct PUBLIC
  . .. ../codec ../triangulator ../utility ../projector
  ../../husk-scheme/hs-src/Device/Motion
  ${OpenCV_INCLUDE_DIRS} ${Open3D_INCLUDE_DIRS})
# Some Open3D distributions put bundled fmt headers here.
find_path(OPEN3D_BUNDLED_INCLUDE fmt/core.h PATH_SUFFIXES open3d/3rdparty)
if(OPEN3D_BUNDLED_INCLUDE)
  target_include_directories(reconstruct PRIVATE ${OPEN3D_BUNDLED_INCLUDE})
endif()
target_link_libraries(reconstruct PUBLIC FFPLibrary Open3D DIP DIPviewer
  fmt::fmt ${OpenCV_LIBS} Ceres::ceres OpenMP::OpenMP_CXX CGAL::CGAL gmp mpfr)
