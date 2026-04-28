// -*- c-basic-offset: 4 -*-

/** @file hugin_stitch_project.cpp
 *
 *  @brief Stitch a pto project file, with GUI output etc.
 *
 *  @author Pablo d'Angelo <pablo.dangelo@web.de>
 *
 *  $Id$
 *
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

#include <hugin_config.h>
#include "panoinc_WX.h"
#include "panoinc.h"

#include <wx/wfstream.h>
#if defined __WXMSW__ || defined UNIX_SELF_CONTAINED_BUNDLE
#include <wx/stdpaths.h>
#endif

#include <fstream>
#include <sstream>
#include "base_wx/RunStitchPanel.h"
#include "base_wx/huginConfig.h"
#include "base_wx/MyExternalCmdExecDialog.h"
#include "base_wx/platform.h"
#include "base_wx/wxPlatform.h"
#include "base_wx/wxutils.h"

#include <tiffio.h>

// somewhere SetDesc gets defined.. this breaks wx/cmdline.h on OSX
#ifdef SetDesc
#undef SetDesc
#endif

#include <wx/cmdline.h>

class RunStitchFrame: public wxFrame
{
public:
    RunStitchFrame(wxWindow * parent, const wxString& title, const wxPoint& pos, const wxSize& size);

    bool StitchProject(const wxString& scriptFile, const wxString& outname, const wxString& userDefinedOutput, bool doDeleteOnExit);

    void OnQuit(wxCommandEvent& event);
    void OnAbout(wxCommandEvent& event);
    void OnProgress(wxCommandEvent& event);
    /** sets, if existing output file should be automatic overwritten */
    void SetOverwrite(bool doOverwrite);

private:

    bool m_isStitching;
    wxString m_scriptFile;
    bool m_deleteOnExit;
    wxGauge* m_progress;

    void OnProcessTerminate(wxProcessEvent & event);
    void OnCancel(wxCommandEvent & event);

    RunStitchPanel * m_stitchPanel;
};

// event ID's for RunStitchPanel
enum
{
    ID_Quit = 1,
    ID_About   
};

RunStitchFrame::RunStitchFrame(wxWindow * parent, const wxString& title, const wxPoint& pos, const wxSize& size)
    : wxFrame(parent, -1, title, pos, size), m_isStitching(false)
{
    wxBoxSizer * topsizer = new wxBoxSizer( wxVERTICAL );
    m_stitchPanel = new RunStitchPanel(this);

    topsizer->Add(m_stitchPanel, 1, wxEXPAND | wxALL, 2);

    wxBoxSizer* bottomsizer = new wxBoxSizer(wxHORIZONTAL);
    m_progress = new wxGauge(this, wxID_ANY, 100, wxDefaultPosition, wxDefaultSize, wxGA_HORIZONTAL | wxGA_PROGRESS);
    bottomsizer->Add(m_progress, 1, wxEXPAND | wxALL, 10);
    bottomsizer->Add( new wxButton(this, wxID_CANCEL, _("Cancel")),
                   0, wxALL, 10);
    topsizer->Add(bottomsizer, 0, wxEXPAND);

#ifdef __WXMSW__
    // wxFrame does have a strange background color on Windows..
    this->SetBackgroundColour(m_stitchPanel->GetBackgroundColour());
#endif

    // setup the environment for the different operating systems
    wxInitAllImageHandlers();
#if defined __WXMSW__
    wxFileName exePath(wxStandardPaths::Get().GetExecutablePath());
    exePath.RemoveLastDir();
    wxIconBundle myIcons(exePath.GetPath(wxPATH_GET_VOLUME | wxPATH_GET_SEPARATOR) + "share\\hugin\\xrc\\data\\hugin.ico", wxBITMAP_TYPE_ICO);
    SetIcons(myIcons);
#else
    wxString xrcPrefix;
#if defined __WXMAC__ && defined MAC_SELF_CONTAINED_BUNDLE
    {
        wxString exec_path = MacGetPathToBundledResourceFile(CFSTR("xrc"));
        if (!exec_path.IsEmpty())
        {
            xrcPrefix = exec_path + "/";
        }
        else
        {
            hugin_utils::HuginMessageBox(_("xrc directory not found in bundle"), _("Hugin_stitch_project"), wxOK | wxICON_ERROR, wxGetActiveWindow());
        }
    }
#elif defined UNIX_SELF_CONTAINED_BUNDLE
    // initialize paths
    {
        wxFileName exePath(wxStandardPaths::Get().GetExecutablePath());
        exePath.RemoveLastDir();
        const wxString huginRoot(exePath.GetPath(wxPATH_GET_VOLUME | wxPATH_GET_SEPARATOR));
        xrcPrefix = huginRoot + "share/hugin/xrc/";
    }
#else
    // add the locale directory specified during configure
    xrcPrefix = INSTALL_XRC_DIR;
#endif
    if (!xrcPrefix.IsEmpty())
    {
        wxIcon myIcon(xrcPrefix + "data/hugin.png", wxBITMAP_TYPE_PNG);
        SetIcon(myIcon);
    }
#endif

    SetSizer( topsizer );
//    topsizer->SetSizeHints( this );   // set size hints to honour minimum size
    m_deleteOnExit=false;
    // bind event handler
    Bind(wxEVT_MENU, &RunStitchFrame::OnQuit, this, ID_Quit);
    Bind(wxEVT_MENU, &RunStitchFrame::OnAbout, this, ID_About);
    Bind(wxEVT_BUTTON, &RunStitchFrame::OnCancel, this, wxID_CANCEL);
    Bind(wxEVT_END_PROCESS, &RunStitchFrame::OnProcessTerminate, this);
    Bind(EVT_QUEUE_PROGRESS, &RunStitchFrame::OnProgress, this);

}

void RunStitchFrame::OnAbout(wxCommandEvent& WXUNUSED(event))
{
    hugin_utils::HuginMessageBox(wxString::Format(_("HuginStitchProject. Application to stitch hugin project files.\n Version: %s"), hugin_utils::GetHuginVersion()),
                  _("Hugin_stitch_project"), wxOK | wxICON_INFORMATION, this);
}
void RunStitchFrame::OnQuit(wxCommandEvent& WXUNUSED(event))
{
    DEBUG_TRACE("");
    if (m_isStitching) {
        m_stitchPanel->CancelStitch();
        m_isStitching = false;
    }
    Close();
}

void RunStitchFrame::OnCancel(wxCommandEvent& WXUNUSED(event))
{
    DEBUG_TRACE("");
    if (m_isStitching) {
        m_stitchPanel->CancelStitch();
        m_isStitching = false;
    } else {
        Close();
    }
}

void RunStitchFrame::OnProcessTerminate(wxProcessEvent & event)
{
    if (! m_isStitching) {
        // canceled stitch
        // TODO: Cleanup files?
        Close();
    } else {
        m_isStitching = false;
        if (event.GetExitCode() != 0)
        {
            if (hugin_utils::HuginMessageBox(_("Error during stitching\nPlease report the complete text to the bug tracker on https://bugs.launchpad.net/hugin.\n\nDo you want to save the log file?"),
                _("Hugin_stitch_project"), wxICON_ERROR | wxYES_NO, this) == wxYES)
            {
                wxString defaultdir = wxConfigBase::Get()->Read("/actualPath",wxEmptyString);
                wxFileDialog dlg(this,
                         _("Specify log file"),
                         defaultdir, wxEmptyString,
                         _("Log files (*.log)|*.log|All files (*)|*"),
                         wxFD_SAVE | wxFD_OVERWRITE_PROMPT, wxDefaultPosition);
                dlg.SetDirectory(wxConfigBase::Get()->Read("/actualPath",wxEmptyString));
                if (dlg.ShowModal() == wxID_OK)
                {
                    wxConfig::Get()->Write("/actualPath", dlg.GetDirectory());  // remember for later
                    m_stitchPanel->SaveLog(dlg.GetPath());
                };
            }
        } else {
            if(m_deleteOnExit)
            {
                wxRemoveFile(m_scriptFile);
            };
            Close();
        }
    }
}

void RunStitchFrame::OnProgress(wxCommandEvent& event)
{
    if (event.GetInt() >= 0)
    {
        m_progress->SetValue(event.GetInt());
    };
};

bool RunStitchFrame::StitchProject(const wxString& scriptFile, const wxString& outname, const wxString& userDefinedOutput, bool doDeleteOnExit)
{
    if (! m_stitchPanel->StitchProject(scriptFile, outname, userDefinedOutput)) {
        return false;
    }
    m_isStitching = true;
    m_scriptFile=scriptFile;
    m_deleteOnExit=doDeleteOnExit;
    return true;
}

void RunStitchFrame::SetOverwrite(bool doOverwrite)
{
    m_stitchPanel->SetOverwrite(doOverwrite);
};

// **********************************************************************


/** The application class for hugin_stitch_project
 *
 *  it contains the main frame.
 */
class stitchApp : public wxApp
{
public:

    /** ctor.
     */
    stitchApp();

    /** dtor.
     */
    virtual ~stitchApp();

    /** pseudo constructor. with the ability to fail gracefully.
     */
    virtual bool OnInit();

    /** just for testing purposes */
    virtual int OnExit();
    
#ifdef __WXMAC__
    /** the wx calls this method when the app gets "Open file" AppleEvent */
    void MacOpenFile(const wxString &fileName);
#endif

private:
    wxLocale m_locale;
#ifdef __WXMAC__
    wxString m_macFileNameToOpenOnStart;
#endif
};

stitchApp::stitchApp()
{
    // suppress tiff warnings
    TIFFSetWarningHandler(0);

    DEBUG_TRACE("ctor");
}

stitchApp::~stitchApp()
{
    DEBUG_TRACE("dtor");
    DEBUG_TRACE("dtor end");
}

bool stitchApp::OnInit()
{
    // Required to access the preferences of hugin
    SetAppName("hugin");
#if defined __WXMSW__ && wxCHECK_VERSION(3,3,0)
    // automatically switch between light and dark mode
    SetAppearance(Appearance::System);
#endif
#if defined __WXGTK__
    CheckConfigFilename();
#endif

    // need to explicitly initialize locale for C++ library/runtime
    setlocale(LC_ALL, "");
    // initialize i18n
#if defined __WXMSW__
    int localeID = wxConfigBase::Get()->Read("language", (long) wxLANGUAGE_DEFAULT);
    m_locale.Init(localeID);
#else
    m_locale.Init(wxLANGUAGE_DEFAULT);
#endif

    // setup the environment for the different operating systems
#if defined __WXMSW__
    wxFileName exePath(wxStandardPaths::Get().GetExecutablePath());
    exePath.RemoveLastDir();
    // locale setup
    m_locale.AddCatalogLookupPathPrefix(exePath.GetPath(wxPATH_GET_VOLUME | wxPATH_GET_SEPARATOR) + "share\\locale");

#elif defined UNIX_SELF_CONTAINED_BUNDLE
    // initialize paths
    {
      wxFileName exePath(wxStandardPaths::Get().GetExecutablePath());
      exePath.RemoveLastDir();
      const wxString huginRoot=exePath.GetPath(wxPATH_GET_VOLUME | wxPATH_GET_SEPARATOR);
      // add the locale directory specified during configure
      m_locale.AddCatalogLookupPathPrefix(huginRoot + "share/locale");
    }
#else
    // add the locale directory specified during configure
    m_locale.AddCatalogLookupPathPrefix(INSTALL_LOCALE_DIR);
#endif

    // set the name of locale recource to look for
    m_locale.AddCatalog("hugin");

    // parse arguments
    static const wxCmdLineEntryDesc cmdLineDesc[] =
    {
        //On wxWidgets 2.9, wide characters don't work here.
        //On previous versions, the wxT macro is required for unicode builds.
      { wxCMD_LINE_SWITCH, "h", "help", "show this help message",
        wxCMD_LINE_VAL_NONE, wxCMD_LINE_OPTION_HELP },
      { wxCMD_LINE_OPTION, "o", "output",  "output prefix" },
      { wxCMD_LINE_SWITCH, "d", "delete",  "delete pto file after stitching" },
      { wxCMD_LINE_SWITCH, "w", "overwrite", "overwrite existing files" },
      { wxCMD_LINE_OPTION, "u", "user-defined-output", "use user defined output" },
      { wxCMD_LINE_PARAM,  NULL, NULL, "<project>",
        wxCMD_LINE_VAL_STRING, wxCMD_LINE_PARAM_OPTIONAL },
      { wxCMD_LINE_NONE }
    };

    wxCmdLineParser parser(cmdLineDesc, argc, argv);

    switch ( parser.Parse() ) {
      case -1: // -h or --help was given, and help displayed so exit
	return false;
	break;
      case 0:  // all is well
        break;
      default:
        wxLogError(_("Syntax error in parameters detected, aborting."));
	return false;
        break;
    }

    wxString scriptFile;
#ifdef __WXMAC__
    m_macFileNameToOpenOnStart = wxEmptyString;
    wxYield();
    scriptFile = m_macFileNameToOpenOnStart;
    
    // bring myself front (for being called from command line)
    {
        ProcessSerialNumber selfPSN;
        OSErr err = GetCurrentProcess(&selfPSN);
        if (err == noErr)
        {
            SetFrontProcess(&selfPSN);
        }
    }
#endif
    
    wxString userDefinedOutput;
    parser.Found("u", &userDefinedOutput);
    if (!userDefinedOutput.IsEmpty())
    {
        if (!wxFileName::FileExists(userDefinedOutput))
        {
            hugin_utils::HuginMessageBox(wxString::Format(_("Could not find the specified user output file \"%s\"."), userDefinedOutput),
                _("Hugin_stitch_project"), wxOK | wxICON_EXCLAMATION, wxGetActiveWindow());
            return false;
        };
    };
    if( parser.GetParamCount() == 0 && wxIsEmpty(scriptFile)) 
    {
        wxString defaultdir = wxConfigBase::Get()->Read("/actualPath",wxEmptyString);
        wxFileDialog dlg(0,
                         _("Specify project source project file"),
                         defaultdir, wxEmptyString,
                         _("Project files (*.pto)|*.pto|All files (*)|*"),
                         wxFD_OPEN, wxDefaultPosition);

        dlg.SetDirectory(wxConfigBase::Get()->Read("/actualPath",wxEmptyString));
        if (dlg.ShowModal() == wxID_OK) {
            wxConfig::Get()->Write("/actualPath", dlg.GetDirectory());  // remember for later
            scriptFile = dlg.GetPath();
        } else { // bail
            return false;
        }
    } else if(wxIsEmpty(scriptFile)) {
        scriptFile = parser.GetParam(0);
        std::cout << "********************* script file: " << (const char *)scriptFile.mb_str(wxConvLocal) << std::endl;
        if (! wxIsAbsolutePath(scriptFile)) {
            scriptFile = wxGetCwd() + wxFileName::GetPathSeparator() + scriptFile;
        }
    }

    std::cout << "input file is " << (const char *)scriptFile.mb_str(wxConvLocal) << std::endl;

    wxString outname;

    if ( !parser.Found("o", &outname) ) {
        // ask for output.
        wxFileDialog dlg(0,_("Specify output prefix"),
                         wxConfigBase::Get()->Read("/actualPath",wxEmptyString),
                         wxEmptyString, wxEmptyString,
                         wxFD_SAVE, wxDefaultPosition);
        dlg.SetDirectory(wxConfigBase::Get()->Read("/actualPath",wxEmptyString));
        if (dlg.ShowModal() == wxID_OK) {
            while(containsInvalidCharacters(dlg.GetPath()))
            {
                hugin_utils::HuginMessageBox(wxString::Format(_("The given filename contains one of the following invalid characters: %s\nHugin can not work with this filename. Please enter a valid filename."), getInvalidCharacters()),
                    _("Hugin_stitch_project"), wxOK | wxICON_EXCLAMATION, wxGetActiveWindow());
                if(dlg.ShowModal()!=wxID_OK)
                    return false;
            };
            wxFileName prefix(dlg.GetPath());
            while (!prefix.IsDirWritable())
            {
                hugin_utils::HuginMessageBox(wxString::Format(_("You have no permissions to write in folder \"%s\".\nPlease select another folder for the final output."), prefix.GetPath().c_str()),
                    _("Hugin_stitch_project"), wxOK | wxICON_INFORMATION, wxGetActiveWindow());
                if (dlg.ShowModal() != wxID_OK)
                {
                    return false;
                };
                prefix = dlg.GetPath();
            };

            wxConfig::Get()->Write("/actualPath", dlg.GetDirectory());  // remember for later
            outname = dlg.GetPath();
        } else { // bail
//            wxLogError( _("No project files specified"));
            return false;
        }
    }

    // check output filename
    wxFileName outfn(outname);
    wxString ext = outfn.GetExt();
    // remove extension if it indicates an image file
    if (ext.CmpNoCase("jpg") == 0 || ext.CmpNoCase("jpeg") == 0|| 
        ext.CmpNoCase("tif") == 0|| ext.CmpNoCase("tiff") == 0 || 
        ext.CmpNoCase("png") == 0 || ext.CmpNoCase("exr") == 0 ||
        ext.CmpNoCase("pnm") == 0 || ext.CmpNoCase("hdr")) 
    {
        outfn.ClearExt();
        outname = outfn.GetFullPath();
    }

    RunStitchFrame *frame = new RunStitchFrame(NULL, "Hugin Stitcher", wxDefaultPosition, wxSize(640,600) );
    frame->Show( true );
    SetTopWindow( frame );

    wxFileName basename(scriptFile);
    frame->SetTitle(wxString::Format(_("%s - Stitching"), basename.GetName().c_str()));
    frame->SetOverwrite(parser.Found("w"));
    bool n = frame->StitchProject(scriptFile, outname, userDefinedOutput, parser.Found("d"));
    return n;
}


int stitchApp::OnExit()
{
    DEBUG_TRACE("");
    return 0;
}


#ifdef __WXMAC__
// wx calls this method when the app gets "Open file" AppleEvent 
void stitchApp::MacOpenFile(const wxString &fileName)
{
    m_macFileNameToOpenOnStart = fileName;
}
#endif

// make wxwindows use this class as the main application
IMPLEMENT_APP(stitchApp)
