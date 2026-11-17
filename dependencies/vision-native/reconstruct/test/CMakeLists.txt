cmake_minimum_required(VERSION 2.8)
project(ReconstructLibrary)

# Set C++ standard
# set(CMAKE_CXX_STANDARD 11)
# set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Find required packages (e.g., OpenCV, Open3D)
find_package(DIPlib REQUIRED)
find_package(Eigen3 REQUIRED)
find_package(OpenCV REQUIRED)
find_package(Open3D REQUIRED)

include_directories( ${OpenCV_INCLUDE_DIRS})
include_directories( ${Open3D_INCLUDE_DIRS})
include_directories( /usr/local/include/open3d/3rdparty)

# Source files
set(SOURCES reconstruct.cpp)

# Create shared library
#add_library(reconstruct SHARED ${SOURCES})

add_executable( reconstruct ${SOURCES} )

# target_include_directories(reconstruct
#   PUBLIC
#   ${Open3D_INCLUDE_DIRS}
#   )

# Link Libraries
# target_link_libraries(reconstruct ${OpenCV_LIBS})
target_link_libraries(reconstruct DIP DIPviewer ${OpenCV_LIBS})
target_link_libraries(reconstruct Open3D::Open3D)


