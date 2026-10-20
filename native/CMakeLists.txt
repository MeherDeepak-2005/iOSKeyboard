cmake_minimum_required(VERSION 3.22)
project(XploreeDecoderCore VERSION 1.0 LANGUAGES CXX)

# Platform-neutral algorithms only. Foundation/JNI/model APIs belong in adapters.
add_library(DecoderCore STATIC
    DecoderCore/src/Adaptation.cpp
    DecoderCore/src/CandidateGeneration.cpp
    DecoderCore/src/Glide.cpp
    DecoderCore/src/IncrementalSearch.cpp
    DecoderCore/src/LanguageModel.cpp
    DecoderCore/src/Multiword.cpp
    DecoderCore/src/NeuralSearch.cpp
    DecoderCore/src/PackedLexicon.cpp
    DecoderCore/src/Ranking.cpp
    DecoderCore/src/SpatialModel.cpp)
target_include_directories(DecoderCore PUBLIC DecoderCore/include)
target_compile_features(DecoderCore PUBLIC cxx_std_20)
set_target_properties(DecoderCore PROPERTIES POSITION_INDEPENDENT_CODE ON CXX_EXTENSIONS OFF)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(DecoderCore PRIVATE -Wall -Wextra -Werror)
endif()

option(KB_BUILD_TESTS "Build portable decoder tests" ON)
if(KB_BUILD_TESTS)
    enable_testing()
    add_executable(candidate-generation-tests tests/CandidateGenerationTests.cpp)
    target_link_libraries(candidate-generation-tests PRIVATE DecoderCore)
    add_test(NAME candidate-generation COMMAND candidate-generation-tests)
    add_test(NAME neural-search COMMAND neural-search-tests)
    add_executable(neural-search-tests tests/NeuralSearchTests.cpp)
    target_link_libraries(neural-search-tests PRIVATE DecoderCore)
    add_executable(decoder-core-tests tests/PackedLexiconTests.cpp)
    target_link_libraries(decoder-core-tests PRIVATE DecoderCore)
    # These small portable executables use assert for their independent goldens.
    # Release must still execute them rather than compiling the checks away.
    if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
        target_compile_options(candidate-generation-tests PRIVATE -UNDEBUG)
        target_compile_options(neural-search-tests PRIVATE -UNDEBUG)
        target_compile_options(decoder-core-tests PRIVATE -UNDEBUG)
    endif()
    add_test(NAME decoder-core-parity COMMAND decoder-core-tests
        "${CMAKE_CURRENT_SOURCE_DIR}/../keyboard/langdata.bin")
endif()
