# The EasyRPG Player as one shared library for the framework Scripts/native/build-easyrpg.sh assembles: the
# Player's own CMake builds its object library, and this links it behind op_easyrpg.h (the only exported symbols).
cmake_minimum_required(VERSION 3.22)
project(OmniPlayEasyRPG C CXX)
add_subdirectory(${EASYRPG_PLAYER_DIR} player EXCLUDE_FROM_ALL)
add_library(EasyRPG SHARED op_easyrpg.cpp)
target_link_libraries(EasyRPG PRIVATE EasyRPG_Player)
target_compile_features(EasyRPG PRIVATE cxx_std_17)
target_link_options(EasyRPG PRIVATE -Wl,-exported_symbols_list,${CMAKE_CURRENT_SOURCE_DIR}/exports.txt -Wl,-dead_strip)
set_target_properties(EasyRPG PROPERTIES PREFIX "" SUFFIX "" INSTALL_NAME_DIR "@rpath/EasyRPG.framework"
                      BUILD_WITH_INSTALL_NAME_DIR ON)
