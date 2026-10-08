cmake_minimum_required(VERSION 3.16)
project(realsense_profile_probe LANGUAGES CXX)

# Use the same ROS-provided librealsense SDK as realsense2_camera.
find_package(realsense2 REQUIRED CONFIG PATHS /opt/ros/humble NO_DEFAULT_PATH)

add_executable(realsense-profile-probe realsense_profile_probe.cpp)
target_compile_features(realsense-profile-probe PRIVATE cxx_std_17)
target_compile_options(realsense-profile-probe PRIVATE -Wall -Wextra -Wpedantic)
target_link_libraries(realsense-profile-probe realsense2::realsense2)

install(TARGETS realsense-profile-probe DESTINATION bin)
install(FILES select_profile.py DESTINATION lib/26fly
        RENAME select-realsense-profile.py)
