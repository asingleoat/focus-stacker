## cmakelists.txt for libpano13 in a Hugin build environment.
##     03-04 Aug 2009 TKSharpless
##  Updated 16 Jan 2010 to add general Pannini projection
##
## For Windows, download just part of the panotools SVN tree:
## https://panotools.svn.sourceforge.net/svnroot/panotools/trunk/libpano
## into local directory libpano under the hugin SDK root.
## Then build in-place with CMake, and build INSTALL.  That
## will create a directory in the SDK root that the hugin
## CMake build scripts can use.
##    
## Builds libpano13 and selected panotools, by default without 
## support for the Java programs ptpicker and pteditor.  You
## can define SUPPORT_JAVA_PROGRAMS on the CMake command line; the script
## produces error if the Java header jni.h and its dependencies are not found.
##
## This script uses the Hugin CMake modules to find required
## image file format libraries, so it needs to know the name
## of the Hign source tree root.  By default that must be
## "../hugin" relative to the libpano root(that contains
## this file).  But you can set HUGIN_BASE_DIR to the path
## name of the Hugin root on the CMake command line.
##
## The parent directory of the Hugin root is one place where
## dependencies will be looked for.  On Windows that should
## be the root directory of the Hugin SDK, and the wxWidgets
## package will likely supply the dependencies.  Note:  you
## may need to edit the wxWidgets version number below.
##

cmake_minimum_required(VERSION 3.12...4.0)
if(POLICY CMP0074)
  cmake_policy(SET CMP0074 NEW)
endif()

## Locate the hugin source root and its parent directory
IF(HUGIN_BASE_DIR)
  GET_FILENAME_COMPONENT(SOURCE_BASE_DIR ${HUGIN_BASE_DIR} PATH CACHE)
  set(CMAKE_MODULE_PATH ${HUGIN_BASE_DIR}/CMakeModules)
ELSE(HUGIN_BASE_DIR)
  GET_FILENAME_COMPONENT(SOURCE_BASE_DIR ${CMAKE_SOURCE_DIR} PATH CACHE)
  set(CMAKE_MODULE_PATH ${SOURCE_BASE_DIR}/hugin/CMakeModules)
ENDIF(HUGIN_BASE_DIR)
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}")
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/CMakeModules")

IF(WIN32)
  set(CMAKE_INSTALL_PREFIX "${SOURCE_BASE_DIR}/libpano13" CACHE PATH "Install prefix for libpano")
ENDIF(WIN32)

SET(CMAKE_DEBUG_POSTFIX d)

include(CheckIncludeFiles)

##  global setup
project(libpano13)

# support lib/lib64
include(GNUInstallDirs)

##
#  This must come before FINDs for tiff, jpeg, png, zlib to enable
#  finding the wxWidgets distributions of those packages on Windows.
IF(WIN32)
  ADD_DEFINITIONS(-D__Win__)
  OPTION(BUILD_DLL "Build dynamic libpano 13" ON)
  OPTION(BUILD_WINGUI "Build with Windows GUI, otherwise the information is printed to shell/cmd.exe" OFF)
  IF(MSVC)
    set(win_c "tools/compat_win32/getopt.c")
  ENDIF()
  IF(BUILD_WINGUI)
    SET(sys_c "sys_win.c")
    SET(sys_h "sys_win.h")
  ELSE(BUILD_WINGUI)
    SET(sys_c "sys_ansi.c")
    SET(sys_h "sys_ansi.h")
  ENDIF(BUILD_WINGUI)
  SET(sys_compat_c "sys_compat_win.c")
ELSE(WIN32)
  ##
  ## Cleaner Debian Packaging (enable by -DDISABLE_DPKG=OFF)
  ##

  SET(sys_c "sys_ansi.c")
  SET(sys_h "sys_ansi.h")
  SET(sys_compat_c "sys_compat_unix.c")
ENDIF(WIN32)

OPTION(SUPPORT_JAVA_PROGRAMS "Set this to support for the Java programs ptpicker and pteditor" OFF)
if(SUPPORT_JAVA_PROGRAMS)
  find_package(Java REQUIRED)
  find_package(JNI REQUIRED)
  include_directories(${JAVA_INCLUDE_PATH} ${JAVA_INCLUDE_PATH2})
endif()

##
## Graphics libraries
##
# wxWidgets sub-packages will be used if native ones aren't found

FIND_PACKAGE(TIFF REQUIRED)
INCLUDE_DIRECTORIES(${TIFF_INCLUDE_DIR})
FIND_PACKAGE(JPEG REQUIRED)
INCLUDE_DIRECTORIES(${JPEG_INCLUDE_DIR})
FIND_PACKAGE(PNG REQUIRED)
INCLUDE_DIRECTORIES(${ZLIB_INCLUDE_DIR})
INCLUDE_DIRECTORIES(${PNG_INCLUDE_DIR})

set(_common_libs ${TIFF_LIBRARIES} ${ZLIB_LIBRARIES} ${JPEG_LIBRARIES} ${PNG_LIBRARIES})

include(CheckLibraryExists)
# Does explicit linking against libm work?
check_library_exists(m exp "" LIBMNEEDED)
if(LIBMNEEDED)
  list(APPEND _common_libs "m")
endif()

# Sparse or dense Levenberg Marquardt
OPTION(USE_SPARSE_LEVMAR "Use Sparse Levenberg Marquardt algorithm instead of dense Levenberg Marquardt algorithm" OFF)
IF(USE_SPARSE_LEVMAR)
  FIND_PACKAGE(SUITESPARSE REQUIRED)
  LIST(APPEND _common_libs ${SUITESPARSE_LIBRARIES})
ENDIF()

#
# Check build type and set options accordingly
#
IF(NOT CMAKE_BUILD_TYPE)
  SET(CMAKE_BUILD_TYPE Release CACHE STRING
      "Choose the type of build, options are: None Debug Release RelWithDebInfo MinSizeRel."
      FORCE)
ENDIF(NOT CMAKE_BUILD_TYPE)
IF(${CMAKE_BUILD_TYPE} STREQUAL "Debug")
  ADD_DEFINITIONS(-DDEBUG)
  IF(UNIX)
    ADD_DEFINITIONS(-Wall)
  ENDIF(UNIX)
ENDIF(${CMAKE_BUILD_TYPE} STREQUAL "Debug")

IF(UNIX)
  ADD_DEFINITIONS(-D__Ansi__)
ELSE(UNIX)
  IF(MSVC)
    # Stop MSVC8 from bitching about the C library
    ADD_DEFINITIONS(/D_CRT_SECURE_NO_DEPRECATE)
    # Stop MSVC9 from bitching about possibly invalid STL usage
    ADD_DEFINITIONS(/D_SCL_SECURE_NO_WARNINGS)
    # Stop MSVC9 from bitching about POSIX names without underscores
    ADD_DEFINITIONS(/D_CRT_NONSTDC_NO_DEPRECATE)
    IF(NOT BUILD_WINGUI)
      ADD_DEFINITIONS(/D__Ansi__)
    ENDIF()
    IF(NOT BUILD_DLL)
      # compile everything for the static C runtime
		FOREACH(TYPE C CXX)
			# makefiles use blank configuration
			FOREACH(CFG "_DEBUG" "_MINSIZEREL" "_RELEASE" "_RELWITHDEBINFO")
				#MESSAGE("Replacing CMAKE_${TYPE}_FLAGS${CFG}: ${CMAKE_${TYPE}_FLAGS${CFG}}")
				SET(NEW_FLAGS "${CMAKE_${TYPE}_FLAGS${CFG}}")
				# fix up static libc flags
				STRING(REPLACE "/MD" "/MT" NEW_FLAGS "${NEW_FLAGS}")
				# *FORCE* to override whats already placed into the cache
				SET(CMAKE_${TYPE}_FLAGS${CFG} "${NEW_FLAGS}" CACHE STRING
					"CMAKE_${TYPE}_FLAGS${CFG} (overwritten to ensure static build)" FORCE)
				#MESSAGE("New       CMAKE_${TYPE}_FLAGS${CFG}: ${CMAKE_${TYPE}_FLAGS${CFG}}")
			ENDFOREACH(CFG)
		ENDFOREACH(TYPE)
	    # link only with the static C runtime !! THIS IS A MUST !!
		SET(NEW_FLAGS "${CMAKE_EXE_LINKER_FLAGS}")
		# ensure that the flags are not duplicaated on subsequent runs
		STRING(REPLACE " /NODEFAULTLIB:\"MSVCRT.lib\" /NODEFAULTLIB:\"MSVCRTd.lib\"" "" NEW_FLAGS "${NEW_FLAGS}")
		# note that flag names(NODEFAULTLIB) etc.) are case sensitive
    	SET(CMAKE_EXE_LINKER_FLAGS
        	"${NEW_FLAGS} /NODEFAULTLIB:\"MSVCRT.lib\" /NODEFAULTLIB:\"MSVCRTd.lib\""
	       CACHE STRING "for MSVC" FORCE
		)
	ENDIF(NOT BUILD_DLL)
  ENDIF(MSVC)
  IF(MINGW)
    IF(NOT BUILD_WINGUI)
      ADD_DEFINITIONS(/D__Ansi__)
    ENDIF()
  ENDIF(MINGW)
ENDIF(UNIX)

##
## Here is the part that builds libpano
##
if(SUPPORT_JAVA_PROGRAMS)
  set(java_h pteditor.h ptutils.h)
  set(java_c ptpicker.c pteditor.c)
else()
  set(java_c javastub.c)
endif(SUPPORT_JAVA_PROGRAMS)

set(pano13_install_hdr
  panorama.h
  filter.h
  version.h
  panotypes.h
  PTcommon.h
  file.h
  queryfeature.h
  pteditor.h
  ptutils.h)

set(pano13_hdr
	${java_h}
	${pano13_install_hdr}
	ColourBrightness.h
	f2c.h
	fftn.h
	rgbe.h
        sys_compat.h
	${sys_h}
	ZComb.h
	PaniniGeneral.h
)

set(pano13_res
	pano13.rc
)

set(pano13_src
	${java_c}
	${win_c}
	adjust.c
	bmp.c
	ColourBrightness.c
	correct.c
        dump.c
	fftn.c
	file.c
	filter.c
	fourier.c
	hdrfile.c
	jpeg.c
	jpegicc.c
	math.c
	metadata.c
	morpher.c
	multilayer.c
	optimize.c
	pan.c
	parser.c
	perspect.c
	png.c
	ppm.c
	PTcommon.c
	PTDialogs.c
	ptfeather.c
	ptstitch.c
	queryfeature.c
	remap.c
	resample.c
	rgbe.c
	seamer.c
	${sys_c}
	${sys_compat_c}
	sys_common.c
	tiff.c
	Triangulate.c
	ZComb.c
	PaniniGeneral.c
)
# We have some header files at top source level now
include_directories(${CMAKE_SOURCE_DIR})

IF(USE_SPARSE_LEVMAR)
  LIST(APPEND pano13_hdr levmar.h)
  LIST(APPEND pano13_src levmar.c)
  ADD_DEFINITIONS(-DUSE_SPARSE_LEVENBERG_MARQUARDT)
  INCLUDE_DIRECTORIES(${SUITESPARSE_INCLUDE_DIRS})
ELSE()
  LIST(APPEND pano13_src lmdif.c)
ENDIF()

if(NOT WIN32)
  # Create and install shared library on non-windows
  add_library(pano13 SHARED ${pano13_hdr} ${pano13_src})
  target_link_libraries(pano13 ${_common_libs})
  set_target_properties(pano13 PROPERTIES VERSION "3.0.0" SOVERSION "3")
  install(TARGETS pano13 LIBRARY COMPONENT libraries)
  set(_pano_target pano13)
  #create and install static library
  add_library(pano13a STATIC ${pano13_hdr} ${pano13_src})
  set_target_properties(pano13a PROPERTIES OUTPUT_NAME pano13)
  install(TARGETS pano13a ARCHIVE COMPONENT libraries)
else()
  IF(BUILD_DLL)
    # Create and install shared library
    ADD_DEFINITIONS(-DPANO13_DLL)
    add_library(pano13 SHARED ${pano13_hdr} ${pano13_res} ${pano13_src})
    target_link_libraries(pano13 ${_common_libs})
    set_target_properties(pano13 PROPERTIES VERSION "3.0.0" SOVERSION "3")
    IF(MINGW)
      set_target_properties(pano13 PROPERTIES PREFIX "")
    ENDIF()
    install(TARGETS pano13 COMPONENT libraries)
  ELSE(BUILD_DLL)
    #create and install static library
    add_library(pano13 STATIC ${pano13_hdr} ${pano13_res} ${pano13_src})
    install(TARGETS pano13 COMPONENT libraries)
  ENDIF(BUILD_DLL)
  set(_pano_target pano13)
endif()

IF( CMAKE_SIZEOF_VOID_P EQUAL 8 AND MSVC )
	# Error detected with generator Visual Studio 10 Win64
	# > LINK : warning LNK4068: /MACHINE not specified; defaulting to X86
	# > fatal error LNK1112: module machine type 'x64' conflicts with target machine type 'X86'
	#
	# There is no default value for static libraries and cmake isn't setting it either.
	# We fix this by adding the flag manually.
	IF(NOT BUILD_DLL)
		SET_TARGET_PROPERTIES(pano13 PROPERTIES STATIC_LIBRARY_FLAGS \"/machine:x64\")
	ENDIF()
ENDIF()

install(FILES ${pano13_install_hdr} DESTINATION "include/pano13" COMPONENT headers)

# install documentation expected by hugin install script
INSTALL(
  FILES
	AUTHORS
	COPYING
	README
  DESTINATION "share/pano13/doc"
  COMPONENT headers
        )
INSTALL(
  FILES
        doc/Optimize.txt
        doc/PTblender.readme
        doc/PTmender.readme
        doc/stitch.txt
  DESTINATION "share/pano13/doc"
  COMPONENT doc
        )

set(TOP_SRC_DIR ${CMAKE_SOURCE_DIR})

add_subdirectory(tools)
add_dependencies(tools ${_pano_target})

macro(setstripped _varname _value)
  string(STRIP ${_value} _v)
  if(USE_POSIX_PACKAGING)
    string(TOLOWER ${_v} ${_varname})
  else()
    set(${_varname} ${_v})
  endif()
endmacro(setstripped)

file(STRINGS "${TOP_SRC_DIR}/version.h" _config_lines)
foreach(_c_l ${_config_lines})
  if(_c_l MATCHES "^.define PTVERSION_FILEVERSIONNUMBER \([0-9]+,[0-9]+,[0-9]+\)")
    setstripped(PACKAGE_VERSION ${CMAKE_MATCH_1})
    if(PACKAGE_VERSION MATCHES "^\([0-9]+\),\([0-9]+\),\([0-9]+\)")
      message(STATUS "found version = ${PACKAGE_VERSION}")
      set(PANO_MAJOR_VERSION ${CMAKE_MATCH_1})
      set(PANO_MINOR_VERSION ${CMAKE_MATCH_2})
      set(PANO_PATCH_VERSION ${CMAKE_MATCH_3})
    endif()
  endif()
endforeach(_c_l)

set(PACKAGE_BASE "pano13")
set(PACKAGE_VERSION ${PANO_MAJOR_VERSION}.${PANO_MINOR_VERSION}.${PANO_PATCH_VERSION})
set(PACKAGE_BUGREPORT "https://bugs.launchpad.net/panotools")

# man pages need the version string
if(NOT WIN32)
add_subdirectory(man)
add_dependencies(${_pano_target} man)
endif()

# create TAGS file
ADD_CUSTOM_COMMAND( OUTPUT ${PROJECT_SOURCE_DIR}/TAGS
                   COMMAND ctags -e *.c *.h tools/*.c
                   WORKING_DIRECTORY ${PROJECT_SOURCE_DIR}/
                   COMMENT "Build TAGS file"
                 )
ADD_CUSTOM_TARGET( TAGS DEPENDS ${PROJECT_SOURCE_DIR}/TAGS)


# set some variables which are used in libpano13.pc.in
set(prefix ${CMAKE_INSTALL_PREFIX})
set(exec_prefix ${CMAKE_INSTALL_PREFIX})
set(includedir ${CMAKE_INSTALL_PREFIX}/include)
if(DEFINED CMAKE_INSTALL_LIBDIR)
  set(libdir "${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_LIBDIR}")
else()
  set(libdir "${CMAKE_INSTALL_PREFIX}/lib")
endif()
set(LIB_JPEG ${JPEG_LIBRARY})
set(LIB_TIFF ${TIFF_LIBRARY})
set(LIB_ZLIB ${ZLIB_LIBRARY})
set(LIB_PNG ${PNG_LIBRARY})
set(VERSION ${PACKAGE_VERSION})
configure_file("${TOP_SRC_DIR}/libpano13.pc.in" "${CMAKE_BINARY_DIR}/libpano13.pc" @ONLY)
IF(DEFINED CMAKE_INSTALL_LIBDIR)
  install(FILES "${CMAKE_BINARY_DIR}/libpano13.pc" DESTINATION "${CMAKE_INSTALL_LIBDIR}/pkgconfig" COMPONENT libraries)
else()
  install(FILES "${CMAKE_BINARY_DIR}/libpano13.pc" DESTINATION "lib/pkgconfig" COMPONENT libraries)
endif()

set(CPACK_PACKAGE_VERSION_MAJOR "${PANO_MAJOR_VERSION}")
set(CPACK_PACKAGE_VERSION_MINOR "${PANO_MINOR_VERSION}")
set(CPACK_PACKAGE_VERSION_PATCH "${PANO_PATCH_VERSION}")
set(CPACK_PACKAGING_INSTALL_PREFIX ${CMAKE_INSTALL_PREFIX})

set(CPACK_SOURCE_IGNORE_FILES
"/BUILD/"
"/build/"
"~$"
"\\\\.swp$"
"\\\\.history$"
"\\\\.orig$"
"\\\\.#"
"\\\\.hg/"
"\\\\.hgignore$"
"\\\\.hgeol$"
"\\\\.hgtags$"
"\\\\.cvsignore$"
)

# needed by rpm
set(CPACK_SET_DESTDIR "ON")

# the next ones are needed by deb
set(CPACK_PACKAGE_CONTACT "${PACKAGE_BUGREPORT}")
set(CPACK_SOURCE_PACKAGE_FILE_NAME "libpano13")
set(CPACK_PACKAGE_DESCRIPTION_FILE "${TOP_SRC_DIR}/README")
set(CPACK_RESOURCE_FILE_LICENSE "${TOP_SRC_DIR}/COPYING")

# Find the revision number and use it as the release in rpm-package-build.
# This way we may omit the otherwise needed "--force" parameter when
# installing from that rpm package.
IF(EXISTS ${PROJECT_SOURCE_DIR}/.hg)
  FIND_PROGRAM(_hg hg)
  if(_hg)
    execute_process(COMMAND ${_hg} summary
        WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
        OUTPUT_VARIABLE LIBPANO_TIP_OUT
        ERROR_VARIABLE LIBPANO_TIP_ERROR
        OUTPUT_STRIP_TRAILING_WHITESPACE)
    STRING(REGEX REPLACE "\n" ";" LIBPANO_TIP_LINES ${LIBPANO_TIP_OUT})
    foreach(_v_l ${LIBPANO_TIP_LINES})
      if(_v_l MATCHES ".*:[ ]+\([0-9]+\):[0-9a-f]+ tip$")
        set(CPACK_PACKAGE_VERSION_PATCH "${PANO_PATCH_VERSION}-${CMAKE_MATCH_1}")
        break()
      endif()
    endforeach()
  endif()
endif()

set(CPACK_SOURCE_PACKAGE_FILE_NAME "libpano13-${PANO_MAJOR_VERSION}.${PANO_MINOR_VERSION}.${PANO_PATCH_VERSION}")
set(CPACK_PACKAGE_DESCRIPTION_FILE "${CMAKE_CURRENT_SOURCE_DIR}/CpackDescription.txt")
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "Library for manipulating panoramic images")
set(CPACK_COMPONENTS_ALL_IN_ONE_PACKAGE 1)
#set(CPACK_COMPONENTS_ALL libraries tools headers doc)

# install necessary DLL for Windows
IF(WIN32 AND BUILD_DLL)
  SET(DLL_SEARCH_PATH ${SOURCE_BASE_DIR}/../bin)
  IF(VCPKG_TOOLCHAIN)
    LIST(APPEND DLL_SEARCH_PATH ${_VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/bin)
  ENDIF()

  FIND_FILE(TIFF_DLL
    NAMES libtiff.dll tiff.dll
    PATHS ${DLL_SEARCH_PATH}
    NO_SYSTEM_ENVIRONMENT_PATH
  )
  FIND_FILE(LZMA_DLL
    NAMES liblzma.dll lzma.dll
    PATHS ${DLL_SEARCH_PATH}
    NO_SYSTEM_ENVIRONMENT_PATH
  )
  FIND_FILE(JPEG_DLL
    NAMES jpeg.dll libjpeg.dll jpeg62.dll
    PATHS ${DLL_SEARCH_PATH}
    NO_SYSTEM_ENVIRONMENT_PATH
  )
  FIND_FILE(PNG_DLL
    NAMES libpng16.dll libpng15.dll libpng14.dll 
    PATHS ${DLL_SEARCH_PATH}
    NO_SYSTEM_ENVIRONMENT_PATH
  )
  FIND_FILE(ZLIB_DLL
    NAMES zlib1.dll zlib.dll libz.dll libzlib.dll
    PATHS ${DLL_SEARCH_PATH}
    NO_SYSTEM_ENVIRONMENT_PATH
  )
  INSTALL(FILES ${TIFF_DLL} ${LZMA_DLL} ${JPEG_DLL} ${PNG_DLL} ${ZLIB_DLL} DESTINATION bin)
  IF(USE_SPARSE_LEVMAR)
    FIND_FILE(LIBCHOLMOD_DLL
      NAMES libcholmod.dll
      PATHS ${DLL_SEARCH_PATH}
      NO_SYSTEM_ENVIRONMENT_PATH
    )
    FIND_FILE(LIBAMD_DLL
      NAMES libamd.dll
      PATHS ${DLL_SEARCH_PATH}
      NO_SYSTEM_ENVIRONMENT_PATH
    )
    FIND_FILE(LIBCAMD_DLL
      NAMES libcamd.dll
      PATHS ${DLL_SEARCH_PATH}
      NO_SYSTEM_ENVIRONMENT_PATH
    )
    FIND_FILE(LIBCOLAMD_DLL
      NAMES libcolamd.dll
      PATHS ${DLL_SEARCH_PATH}
      NO_SYSTEM_ENVIRONMENT_PATH
    )
    FIND_FILE(LIBCCOLAMD_DLL
      NAMES libccolamd.dll
      PATHS ${DLL_SEARCH_PATH}
      NO_SYSTEM_ENVIRONMENT_PATH
    )
    FIND_FILE(LIBLAPACK_DLL
      NAMES liblapack.dll
      PATHS ${DLL_SEARCH_PATH}
      NO_SYSTEM_ENVIRONMENT_PATH
    )
    FIND_FILE(LIBGFORTRAN_DLL
      NAMES libgfortran-5.dll
      PATHS ${DLL_SEARCH_PATH}
      NO_SYSTEM_ENVIRONMENT_PATH
    )
    FIND_FILE(LIBOPENBLAS_DLL
      NAMES openblas.dll
      PATHS ${DLL_SEARCH_PATH}
      NO_SYSTEM_ENVIRONMENT_PATH
    )
    FIND_FILE(LIBSPQR_DLL
      NAMES libspqr.dll
      PATHS ${DLL_SEARCH_PATH}
      NO_SYSTEM_ENVIRONMENT_PATH
    )
    FIND_FILE(LIBGCC_S_SEH_DLL
      NAMES libgcc_s_seh-1.dll
      PATHS ${DLL_SEARCH_PATH}
      NO_SYSTEM_ENVIRONMENT_PATH
    )
    FIND_FILE(LIBQUADMATH_DLL
      NAMES libquadmath-0.dll
      PATHS ${DLL_SEARCH_PATH}
      NO_SYSTEM_ENVIRONMENT_PATH
    )
    FIND_FILE(LIBWINPTHREAD_DLL
      NAMES libwinpthread-1.dll
      PATHS ${DLL_SEARCH_PATH}
      NO_SYSTEM_ENVIRONMENT_PATH
    )
    INSTALL(FILES ${LIBCHOLMOD_DLL} ${LIBAMD_DLL} ${LIBCAMD_DLL} ${LIBCOLAMD_DLL} ${LIBCCOLAMD_DLL} ${LIBLAPACK_DLL} ${LIBGFORTRAN_DLL} 
      ${LIBOPENBLAS_DLL} ${LIBSPQR_DLL} ${LIBGCC_S_SEH_DLL} ${LIBQUADMATH_DLL} ${LIBWINPTHREAD_DLL}
      DESTINATION bin
    )
  ENDIF()
ENDIF()

find_package(GNUTAR QUIET)
if(GNUTAR_FOUND)
  #message(STATUS "GNUTAR_VERSION_STRING = ${GNUTAR_VERSION_STRING}")
  add_custom_target(dist
    COMMAND ${GNUTAR_EXECUTABLE} -cj -C "${CMAKE_CURRENT_SOURCE_DIR}"
      --file "${CPACK_SOURCE_PACKAGE_FILE_NAME}.tar.bz2"
      --transform 's/^\\./${CPACK_SOURCE_PACKAGE_FILE_NAME}/'
      --owner=root
      --group=root
      --numeric-owner
      --exclude-from "${CMAKE_CURRENT_SOURCE_DIR}/excludes" .
    )
endif()

if(CPACK_BINARY_DEB)
  # Use dpkg-shlibdeps to get the needed dependences
  # Use dpkg-shlibdeps to get the needed dependences
  SET(CPACK_DEBIAN_PACKAGE_SHLIBDEPS ON)

  # the following part copied from http://www.cmake.org/Wiki/CMake_RPATH_handling
  # use, i.e. don't skip the full RPATH for the build tree
  SET(CMAKE_SKIP_BUILD_RPATH  FALSE)

  # when building, don't use the install RPATH already
  # (but later on when installing)
  SET(CMAKE_BUILD_WITH_INSTALL_RPATH FALSE)

  SET(CMAKE_INSTALL_RPATH "${CMAKE_INSTALL_LIBDIR}")
  SET(CPACK_DEBIAN_PACKAGE_DEBUG ON)

  # add the automatically determined parts of the RPATH
  # which point to directories outside the build tree to the install RPATH
  SET(CMAKE_INSTALL_RPATH_USE_LINK_PATH TRUE)

  #this environment will be used by dpkg-shlibdebs to find local created libs
  string(REGEX REPLACE "^/(.*)" "\\1" LDLIBPATH "${CMAKE_INSTALL_RPATH}")

  set(CPACK_PROJECT_CONFIG_FILE "${CMAKE_BINARY_DIR}/CPackEnv.cmake")
  FILE(WRITE "${CPACK_PROJECT_CONFIG_FILE}" "set(ENV{LD_LIBRARY_PATH} \"${LDLIBPATH}\")")
  set(CPACK_DEBIAN_PACKAGE_CONTROL_EXTRA "${CMAKE_CURRENT_SOURCE_DIR}/Debian/postinst")
endif()
if(CPACK_BINARY_RPM)
  set(CPACK_RPM_PACKAGE_DEBUG ON)
  set(CPACK_RPM_COMPONENT_INSTALL ON)
  set(CPACK_RPM_PACKAGE_LICENSE "GPLv2+")
  set(CPACK_RPM_PACKAGE_RELEASE "${PANO_MAJOR_VERSION}.${PANO_MINOR_VERSION}.${PANO_PATCH_VERSION}")
  set(CPACK_RPM_PACKAGE_GROUP "Development/Libraries")
  set(CPACK_RPM_PACKAGE_OBSOLETES "libpano13-tools < 2.9.18")
  #set(CPACK_RPM_POST_INSTALL_SCRIPT_FILE "${CMAKE_CURRENT_SOURCE_DIR}/rpm_postinst")
  set(CPACK_RPM_PACKAGE_REQUIRES "libjpeg-devel, libtiff-devel, libpng-devel, zlib-devel, libgcj-devel")
endif()

include(CPack)

enable_testing()
add_subdirectory(tests)
