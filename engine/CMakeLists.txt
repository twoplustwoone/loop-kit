cmake_minimum_required(VERSION 3.20)
project(loopkit_engine LANGUAGES CXX)

option(LOOPKIT_BUILD_TESTS "Build LoopKit engine tests" ON)

add_library(
  loopkit_engine
  STATIC
  src/loopkit_engine.cpp
  src/loopkit_c_api.cpp
  src/loopkit_resampler.cpp
)
target_include_directories(loopkit_engine PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_compile_features(loopkit_engine PUBLIC cxx_std_17)

if(LOOPKIT_BUILD_TESTS)
  enable_testing()

  add_executable(loopkit_engine_tests tests/test_engine.cpp)
  target_link_libraries(loopkit_engine_tests PRIVATE loopkit_engine)
  add_test(NAME loopkit_engine_tests COMMAND loopkit_engine_tests)

  add_executable(loopkit_resampler_tests tests/test_resampler.cpp)
  target_link_libraries(loopkit_resampler_tests PRIVATE loopkit_engine)
  add_test(NAME loopkit_resampler_tests COMMAND loopkit_resampler_tests)
endif()
