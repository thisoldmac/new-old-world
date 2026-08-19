cmake_minimum_required(VERSION 3.16)

project(ClassicMacCarbonTargetProbe LANGUAGES C CXX)

add_application(ClassicMacCarbonTargetProbe
    FILES target_probe.c
    CONSOLE
    CREATOR "C9Pr"
)

set_target_properties(ClassicMacCarbonTargetProbe PROPERTIES
    C_STANDARD 99
    C_STANDARD_REQUIRED YES
    C_EXTENSIONS NO
)

target_compile_options(ClassicMacCarbonTargetProbe PRIVATE
    -Wall
    -Wextra
    -Wno-multichar
)
