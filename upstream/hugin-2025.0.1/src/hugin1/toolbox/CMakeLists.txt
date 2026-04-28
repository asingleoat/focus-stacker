
set(TOOLBOX_SOURCE ToolboxApp.cpp ToolboxFrame.cpp EnfusePanel.cpp CreateBrightImgDlg.cpp PreviewWindow.cpp PerspectivePanel.cpp PerspectiveImageCtrl.cpp)
set(TOOLBOX_HEADER ToolboxApp.h ToolboxFrame.h EnfusePanel.h PreviewWindow.h CreateBrightImgDlg.h PerspectivePanel.h PerspectiveImageCtrl.h)

IF (WIN32)
  add_executable(hugin_toolbox WIN32 ${TOOLBOX_SOURCE} ${TOOLBOX_HEADER} hugin_toolbox_rc.rc ${WINDOWS_DPI_MANIFEST})
ELSEIF(APPLE)

  set( PROGNAME hugin_toolbox )

  set( INFO_PLIST ${CMAKE_MODULE_PATH}/HuginBundleInfo.plist.in)

  set( MACOSX_BUNDLE_GUI_IDENTIFIER net.sourceforge.hugin.hugin_toolbox)
  set( MACOSX_BUNDLE_BUNDLE_VERSION ${V_MAJOR}.${V_MINOR}.${V_PATCH} )
  set( MACOSX_BUNDLE_SHORT_VERSION_STRING ${MACOSX_BUNDLE_BUNDLE_VERSION})
  set( MACOSX_BUNDLE_LONG_VERSION_STRING "Version ${MACOSX_BUNDLE_BUNDLE_VERSION}" )
  set( MACOSX_BUNDLE_INFO_STRING "hugin_toolbox ${MACOSX_BUNDLE_BUNDLE_VERSION}" )
  set( MACOSX_BUNDLE_BUNDLE_NAME "hugin_toolbox" )
  set( MACOSX_BUNDLE_COPYRIGHT "Copyright 2025 Pablo d'Angelo" )

  IF(MAC_SELF_CONTAINED_BUNDLE)
    
    #translations
    FILE(GLOB PO_FILES "${CMAKE_SOURCE_DIR}/src/translations/*.po")
    SET(TRANSLATION_FILES )
    FOREACH(_file_po ${PO_FILES})
      GET_FILENAME_COMPONENT(LANG ${_file_po} NAME_WE)
      SET(_file_out ${CMAKE_BINARY_DIR}/src/translations/mac/${LANG}.lproj/hugin.mo)
      LIST(APPEND TRANSLATION_FILES ${_file_out} )
      SET_SOURCE_FILES_PROPERTIES( ${_file_out} PROPERTIES 
              MACOSX_PACKAGE_LOCATION "Resources/${LANG}.lproj" 
              GENERATED TRUE)
    ENDFOREACH(_file_po)

    SET(EN_US_HACK "${CMAKE_BINARY_DIR}/src/translations/mac/en_US.lproj")
    LIST(APPEND TRANSLATION_FILES ${EN_US_HACK})
    SET_SOURCE_FILES_PROPERTIES( ${EN_US_HACK} PROPERTIES 
              MACOSX_PACKAGE_LOCATION "Resources" 
              GENERATED TRUE)


    #xrc files
    FILE(GLOB_RECURSE XRC_FILES ${CMAKE_SOURCE_DIR}/src/hugin1/hugin/xrc/*.html 
                                ${CMAKE_SOURCE_DIR}/src/hugin1/hugin/xrc/*.htm
                                ${CMAKE_SOURCE_DIR}/src/hugin1/hugin/xrc/*.hhc
                                ${CMAKE_SOURCE_DIR}/src/hugin1/hugin/xrc/*.hhk 
                                ${CMAKE_SOURCE_DIR}/src/hugin1/hugin/xrc/*.hhp
                                ${CMAKE_SOURCE_DIR}/src/hugin1/hugin/xrc/*.xrc
                                ${CMAKE_SOURCE_DIR}/src/hugin1/hugin/xrc/*.ico
                                ${CMAKE_SOURCE_DIR}/src/hugin1/hugin/xrc/*.jpg
                                ${CMAKE_SOURCE_DIR}/src/hugin1/hugin/xrc/*.png
                                ${CMAKE_SOURCE_DIR}/src/hugin1/hugin/xrc/*.svg
                                ${CMAKE_SOURCE_DIR}/src/hugin1/hugin/xrc/*.txt
                                ${CMAKE_SOURCE_DIR}/src/hugin1/hugin/xrc/*.pl )

    FOREACH(_file ${XRC_FILES})
      GET_FILENAME_COMPONENT(_file_dir ${_file} PATH)
      FILE(RELATIVE_PATH _file_dir "${CMAKE_SOURCE_DIR}/src/hugin1/hugin/" ${_file_dir})
      IF(${_file_dir} MATCHES "xrc/data/help_*")
        CONTINUE()
      ENDIF()
      SET_SOURCE_FILES_PROPERTIES( ${_file} PROPERTIES 
              MACOSX_PACKAGE_LOCATION "Resources/${_file_dir}")
    ENDFOREACH(_file)

    ADD_EXECUTABLE( ${PROGNAME} MACOSX_BUNDLE ${TOOLBOX_SOURCE} ${TOOLBOX_HEADER}
          ${TRANSLATION_FILES} ${XRC_FILES} )
    if(INFO_PLIST)
      set_target_properties(${PROGNAME} PROPERTIES
            MACOSX_BUNDLE_INFO_PLIST ${INFO_PLIST})
    endif(INFO_PLIST)
    ADD_DEPENDENCIES(${PROGNAME} translations)

  ELSE(MAC_SELF_CONTAINED_BUNDLE)
    ADD_EXECUTABLE( ${PROGNAME} MACOSX_BUNDLE ${TOOLBOX_SOURCE} ${TOOLBOX_HEADER})
  ENDIF()

ELSE()
 add_executable(hugin_toolbox ${TOOLBOX_SOURCE} ${TOOLBOX_HEADER})
ENDIF()


target_link_libraries(hugin_toolbox huginbasewx ${common_libs} ${image_libs} ${wxWidgets_LIBRARIES})

IF (APPLE)
  IF (NOT MAC_SELF_CONTAINED_BUNDLE)
    install(TARGETS hugin_toolbox
            DESTINATION ${INSTALL_OSX_BUNDLE_DIR})
  ELSE (NOT MAC_SELF_CONTAINED_BUNDLE)
    install(TARGETS ${PROGNAME}
            DESTINATION "Hugin"
            COMPONENT ${PROGNAME})
  ENDIF (NOT MAC_SELF_CONTAINED_BUNDLE)
ELSE()
    INSTALL(TARGETS hugin_toolbox DESTINATION ${BINDIR})
    IF(UNIX)
        # install further stuff (icons etc.)
        INSTALL(FILES hugin_toolbox_gui.desktop DESTINATION ${DATADIR}/applications)
    ENDIF()
ENDIF()

set_property(INSTALL "bin/$<TARGET_FILE_NAME:hugin_toolbox>"
  PROPERTY CPACK_START_MENU_SHORTCUTS "Hugin Toolbox GUI"
)

