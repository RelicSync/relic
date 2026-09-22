cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "native_gem_toast.cpp"
  "native_voice.cpp"
  "voice_text_context.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib" "wtsapi32.lib" "uiautomationcore.lib" "ole32.lib" "oleaut32.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Explicit opt-in test executables. They are never installed with the app.
option(RELIC_VOICE_TESTS "Build Windows Voice integration fixtures" OFF)
if(RELIC_VOICE_TESTS)
  add_executable(voice_gesture_test voice_gesture_test.cpp)
  target_compile_features(voice_gesture_test PRIVATE cxx_std_17)
  target_compile_options(voice_gesture_test PRIVATE /UNDEBUG)
  add_executable(voice_native_test voice_native_test.cpp native_gem_toast.cpp voice_text_context.cpp)
  target_compile_features(voice_native_test PRIVATE cxx_std_17)
  target_compile_definitions(voice_native_test PRIVATE NOMINMAX)
  target_compile_options(voice_native_test PRIVATE /UNDEBUG)
  target_link_libraries(voice_native_test PRIVATE flutter flutter_wrapper_app wtsapi32.lib uiautomationcore.lib ole32.lib oleaut32.lib)
  set_target_properties(voice_gesture_test voice_native_test PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/voice-tests")
endif()
