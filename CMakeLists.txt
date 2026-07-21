cmake_minimum_required(VERSION 3.16)

project(mongreldb_objc
    VERSION 0.62.0
    DESCRIPTION "Objective-C (Apple Foundation) HTTP client for MongrelDB"
    LANGUAGES OBJC
)

set(CMAKE_OBJC_STANDARD 11)
set(CMAKE_OBJC_STANDARD_REQUIRED ON)

option(MONGRELDB_OBJC_BUILD_TESTS "Build the MongrelDB ObjC client tests" ON)

# Apple frameworks. The client uses NSURLSession, NSJSONSerialization, and
# Foundation. On non-Apple platforms (Linux) this would need GNUstep; CI runs on
# macOS so we link against the system frameworks.
if(APPLE)
    find_library(FOUNDATION Foundation)
else()
    set(FOUNDATION "")
endif()

add_library(mongreldb_objc SHARED
    src/MongrelDBClient.m
    src/MongrelDBError.m
)
# The source is written for ARC (strong/copy properties, no explicit
# retain/release/autorelease). Enable it explicitly so object lifetimes are
# correct -- without ARC, autoreleased results from convenience constructors
# are freed when the autorelease pool drains, leaving dangling pointers.
target_compile_options(mongreldb_objc PRIVATE -fobjc-arc)
target_include_directories(mongreldb_objc
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/src>
        $<INSTALL_INTERFACE:include>
)
if(APPLE)
    target_link_libraries(mongreldb_objc PRIVATE ${FOUNDATION})
endif()
set_target_properties(mongreldb_objc PROPERTIES
    VERSION ${PROJECT_VERSION}
    SOVERSION ${PROJECT_VERSION_MAJOR}
)

if(MONGRELDB_OBJC_BUILD_TESTS)
    enable_testing()
    add_executable(test_mongreldb tests/test_mongreldb.m)
    target_link_libraries(test_mongreldb PRIVATE mongreldb_objc)
    target_compile_options(test_mongreldb PRIVATE -fobjc-arc)
    if(APPLE)
        target_link_libraries(test_mongreldb PRIVATE ${FOUNDATION})
    endif()
    add_test(NAME test_mongreldb COMMAND test_mongreldb)

    # Offline wire-shape conformance test: serializes a create_table body and a
    # batch txn body without contacting the daemon, asserting the exact JSON
    # keys/shape the server expects.
    add_executable(test_wire_shape tests/test_wire_shape.m)
    target_link_libraries(test_wire_shape PRIVATE mongreldb_objc)
    target_compile_options(test_wire_shape PRIVATE -fobjc-arc)
    if(APPLE)
        target_link_libraries(test_wire_shape PRIVATE ${FOUNDATION})
    endif()
    add_test(NAME test_wire_shape COMMAND test_wire_shape)
endif()

# Install rules: library and headers for packagers.
include(GNUInstallDirs)

install(TARGETS mongreldb_objc
    EXPORT MongrelDBObjCTargets
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)

install(FILES src/MongrelDBClient.h src/MongrelDBError.h
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/MongrelDB
)
