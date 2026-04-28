# This file is part of libpano13, the hugin build environment.
# Licence details can be found in the file COPYING.
#
# Copyright (c) 2009 Kornel Benko, <Kornel.Benko@berlin.de>
#

project(man)

FIND_PROGRAM(POD2MAN pod2man REQUIRED)
IF(NOT POD2MAN)
  MESSAGE(FATAL_ERROR "Pod2man not found, but needed to create man pages")
ENDIF()
file(GLOB manuals "*.pod")

macro(add_manual _mansrc)
  get_filename_component(_mandest ${_mansrc} NAME_WE)
  SET(_created_manual "${CMAKE_CURRENT_BINARY_DIR}/${_mandest}.1")
  ADD_CUSTOM_COMMAND(
        OUTPUT "${_created_manual}"
        COMMAND ${POD2MAN} "--center=LIBPANO13 TOOLS" "--release=Version: ${PACKAGE_VERSION}" "${_mansrc}" "${_created_manual}"
        DEPENDS "${_mansrc}"
        VERBATIM
  )
  SET_SOURCE_FILES_PROPERTIES(${_created_manual} GENERATED)
  LIST(APPEND _manuals ${_created_manual})
endmacro(add_manual)

set(_manuals)
foreach(_m ${manuals})
  add_manual(${_m})
endforeach(_m)

add_custom_target(man ALL DEPENDS ${_manuals})

install(FILES ${_manuals} DESTINATION "share/man/man1" COMPONENT doc)
