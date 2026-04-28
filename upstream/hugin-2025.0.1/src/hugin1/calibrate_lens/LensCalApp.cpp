// -*- c-basic-offset: 4 -*-
/** @file LensCalApp.cpp
 *
 *  @brief implementation of LensCal application class
 *
 *  @author T. Modes
 *
 */

/* 
 *  This program is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU General Public
 *  License as published by the Free Software Foundation; either
 *  version 2 of the License, or (at your option) any later version.
 *
 *  This software is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *  General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public
 *  License along with this software. If not, see
 *  <http://www.gnu.org/licenses/>.
 *
 */

#include "panoinc_WX.h"
#include "panoinc.h"
#include <wx/stdpaths.h>
#include "base_wx/platform.h"
#include "base_wx/wxutils.h"

#include "LensCalApp.h"
#include "LensCalImageCtrl.h"
#include "base_wx/huginConfig.h"
#include "hugin/config_defaults.h"
#include "base_wx/PTWXDlg.h"
#if defined __WXGTK__
#include "base_wx/wxPlatform.h"
#endif

#include <tiffio.h>


// make wxwindows use this class as the main application
IMPLEMENT_APP(LensCalApp)

bool LensCalApp::OnInit()
{
#if wxUSE_ON_FATAL_EXCEPTION
    wxHandleFatalExceptions();
#endif
    SetAppName("hugin");
#if defined __WXMSW__ && wxCHECK_VERSION(3,3,0)
    // automatically switch between light and dark mode
    SetAppearance(Appearance::System);
#endif
#if defined __WXGTK__
    CheckConfigFilename();
#endif
    // register our custom pano tools dialog handlers
    registerPTWXDlgFcn();

#if defined __WXMSW__
    wxFileName exeDir(wxStandardPaths::Get().GetExecutablePath());
    exeDir.RemoveLastDir();
    m_xrcPrefix = exeDir.GetPath(wxPATH_GET_VOLUME | wxPATH_GET_SEPARATOR) + "share\\hugin\\xrc\\";
    // locale setup
    locale.AddCatalogLookupPathPrefix(exeDir.GetPath(wxPATH_GET_VOLUME | wxPATH_GET_SEPARATOR) + "share\\locale");
#elif defined __WXMAC__ && defined MAC_SELF_CONTAINED_BUNDLE
    // initialize paths
    wxString thePath = MacGetPathToBundledResourceFile(CFSTR("xrc"));
    if (thePath == wxEmptyString) {
        hugin_utils::HuginMessageBox(_("xrc directory not found in bundle"), _("Calibrate_lens_GUI"), wxOK | wxICON_ERROR, wxGetActiveWindow());
        return false;
    }
    m_xrcPrefix = thePath + "/";
#elif defined UNIX_SELF_CONTAINED_BUNDLE
    // initialize paths
    {
      wxFileName exePath(wxStandardPaths::Get().GetExecutablePath());
      exePath.RemoveLastDir();
      const wxString huginRoot=exePath.GetPath(wxPATH_GET_VOLUME | wxPATH_GET_SEPARATOR);
      // add the locale directory specified during configure
      m_xrcPrefix = huginRoot + "share/hugin/xrc/";
      locale.AddCatalogLookupPathPrefix(huginRoot + "share/locale");
    }
#else
    // add the locale directory specified during configure
    m_xrcPrefix = INSTALL_XRC_DIR;
    locale.AddCatalogLookupPathPrefix(INSTALL_LOCALE_DIR);
#endif

    if ( ! wxFile::Exists(m_xrcPrefix + "/lenscal_frame.xrc") )
    {
        hugin_utils::HuginMessageBox(wxString::Format(_("xrc directory not found, hugin needs to be properly installed\nTried Path: %s"), m_xrcPrefix), _("Calibrate_lens_GUI"), wxOK | wxICON_ERROR, wxGetActiveWindow());
        return false;
    }

    // here goes and comes configuration
    wxConfigBase * config = wxConfigBase::Get();
    // do not record default values in the preferences file
    config->SetRecordDefaults(false);
    config->Flush();

    // need to explicitly initialize locale for C++ library/runtime
    setlocale(LC_ALL, "");
    // initialize i18n
    int localeID = config->Read("language", (long) HUGIN_LANGUAGE);
    DEBUG_TRACE("localeID: " << localeID);
    {
        bool bLInit;
	    bLInit = locale.Init(localeID);
	    if (bLInit) {
	        DEBUG_TRACE("locale init OK");
	        DEBUG_TRACE("System Locale: " << locale.GetSysName().mb_str(wxConvLocal))
	        DEBUG_TRACE("Canonical Locale: " << locale.GetCanonicalName().mb_str(wxConvLocal))
        } else {
          DEBUG_TRACE("locale init failed");
        }
	}
	
    // set the name of locale recource to look for
    locale.AddCatalog("hugin");

    // initialize image handlers
    wxInitAllImageHandlers();

    // Initialize all the XRC handlers.
    wxXmlResource::Get()->InitAllHandlers();
    wxXmlResource::Get()->AddHandler(new LensCalImageCtrlXmlHandler());
    // load XRC files
    wxXmlResource::Get()->Load(m_xrcPrefix + "lenscal_frame.xrc");
    wxXmlResource::Get()->Load(m_xrcPrefix + "lensdb_dialogs.xrc");
    wxXmlResource::Get()->Load(m_xrcPrefix + "dlg_warning.xrc");

    // create main frame
    m_frame = new LensCalFrame(NULL);
    SetTopWindow(m_frame);

    // setup main frame size, after it has been created.
    hugin_utils::RestoreFramePosition(m_frame, "LensCalFrame");

    // show the frame.
    m_frame->Show(TRUE);

    // suppress tiff warnings
    TIFFSetWarningHandler(0);

    return true;
}

#if wxUSE_ON_FATAL_EXCEPTION
void LensCalApp::OnFatalException()
{
    GenerateReport(wxDebugReport::Context_Exception);
};
#endif
