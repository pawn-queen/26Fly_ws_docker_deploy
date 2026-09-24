cmake_minimum_required(VERSION 3.16)
project(vision_debug_viewer LANGUAGES CXX)

find_package(ament_cmake REQUIRED)
find_package(cv_bridge REQUIRED)
find_package(OpenCV 4 REQUIRED COMPONENTS core highgui imgproc)
find_package(rclcpp REQUIRED)
find_package(sensor_msgs REQUIRED)

add_executable(vision-debug-viewer vision_debug_viewer.cpp)
target_compile_features(vision-debug-viewer PRIVATE cxx_std_17)
target_compile_options(vision-debug-viewer PRIVATE -Wall -Wextra -Wpedantic)
ament_target_dependencies(vision-debug-viewer cv_bridge rclcpp sensor_msgs)
target_link_libraries(vision-debug-viewer ${OpenCV_LIBS})

install(TARGETS vision-debug-viewer DESTINATION bin)
