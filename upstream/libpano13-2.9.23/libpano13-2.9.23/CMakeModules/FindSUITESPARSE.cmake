# Try to find the SuiteSparse libraries
# This check defines:
#
#  SUITESPARSE_FOUND - system has OpenEXR
#  SUITESPARSE_INCLUDE_DIRS - SuiteSparse include directory
#  SUITESPARSE_LIBRARIES - Libraries needed to use SuiteSparse
#
#
# Redistribution and use is allowed according to the terms of the BSD license.


IF (SUITESPARSE_INCLUDE_DIR AND SUITESPARSE_LIBRARIES)
  # in cache already
  SET(SUITESPASE_FOUND TRUE)
else ()

FIND_PATH(SUITESPARSE_INCLUDE_DIRS cholmod.h
     PATH_SUFFIXES suitesparse
)

find_library(SUITESPARSE_CHOLMOD_LIBRARY 
    NAMES cholmod libcholmod
  )

find_library(SUITESPARSE_SPQRT_LIBRARY
    NAMES spqr libspqr
)

IF(SUITESPARSE_CHOLMOD_LIBRARY AND SUITESPARSE_SPQRT_LIBRARY)
  SET(SUITESPARSE_LIBRARIES ${SUITESPARSE_CHOLMOD_LIBRARY} ${SUITESPARSE_SPQRT_LIBRARY})
ENDIF()

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(SUITESPARSE DEFAULT_MSG 
                                  SUITESPARSE_INCLUDE_DIRS SUITESPARSE_LIBRARIES)

MARK_AS_ADVANCED(
     SUITESPARSE_INCLUDE_DIRS 
     SUITESPARSE_LIBRARIES 
)
  
endif()
