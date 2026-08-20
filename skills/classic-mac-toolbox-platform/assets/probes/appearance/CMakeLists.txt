cmake_minimum_required(VERSION 3.20)
project(AppearanceProbe C)

add_application(AppearanceProbe appearance_probe.c appearance_probe.r)

if(CMAKE_SYSTEM_NAME MATCHES RetroPPC)
    target_link_libraries(AppearanceProbe PRIVATE AppearanceLib)
endif()
