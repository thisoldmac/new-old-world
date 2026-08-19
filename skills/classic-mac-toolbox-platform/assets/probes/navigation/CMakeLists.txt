cmake_minimum_required(VERSION 3.20)
project(NavigationProbe C)

add_application(NavigationProbe navigation_probe.c)

if(CMAKE_SYSTEM_NAME MATCHES Retro68)
    target_link_libraries(NavigationProbe PRIVATE Navigation)
    set_target_properties(NavigationProbe PROPERTIES LINK_FLAGS "-Wl,--mac-single")
elseif(CMAKE_SYSTEM_NAME MATCHES RetroPPC)
    target_link_libraries(NavigationProbe PRIVATE NavigationLib)
endif()
