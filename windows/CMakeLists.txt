cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "easy_compressor")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "easy_compressor_plugin")

add_library(${PLUGIN_NAME} SHARED
  "easy_compressor_plugin.cpp"
  "video_compressor.cpp"
  "media_info_extractor.cpp"
)

apply_standard_settings(${PLUGIN_NAME})

# C++/WinRT requires exceptions and the correct __cplusplus value.
# apply_standard_settings sets _HAS_EXCEPTIONS=0; override it here so the
# WinRT projection can throw hresult_error correctly.
target_compile_definitions(${PLUGIN_NAME} PRIVATE _HAS_EXCEPTIONS=1)
target_compile_options(${PLUGIN_NAME} PRIVATE /Zc:__cplusplus)

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED YES
)

target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
  mfplat.lib
  mfreadwrite.lib
  mfuuid.lib
  mf.lib
  shlwapi.lib
  propsys.lib
  windowsapp.lib
)

set(easy_compressor_bundled_libraries
  ""
  PARENT_SCOPE
)
