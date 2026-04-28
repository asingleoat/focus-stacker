// -*- c-basic-offset: 4 -*-

/** @file huginApp.cpp
 *
 *  @brief implementation of huginApp Class
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

#include "hugin_config.h"

#include "panoinc_WX.h"

#ifdef __WXMAC__
#include <wx/sysopt.h>
#include <wx/dir.h>
#endif

#include "panoinc.h"

#include "hugin/config_defaults.h"
#include "hugin/huginApp.h"
#include "hugin/ImagesPanel.h"
#include "hugin/MaskEditorPanel.h"
#include "hugin/CPEditorPanel.h"
#include "hugin/OptimizePhotometricPanel.h"
#include "hugin/PanoPanel.h"
#include "hugin/CPListFrame.h"
#include "hugin/PreviewPanel.h"
#include "hugin/GLPreviewFrame.h"
#include "hugin/RawImport.h"
#include "base_wx/PTWXDlg.h"
#include "base_wx/CommandHistory.h"
#include "base_wx/wxcms.h"
#include "base_wx/wxPanoCommand.h"
#include "base_wx/wxutils.h"
#include "hugin/HtmlWindow.h"
#include "hugin/treelistctrl.h"
#include "hugin/ImagesTree.h"
#include "hugin/SplitButton.h"

#include "base_wx/platform.h"
#include "base_wx/huginConfig.h"
#include <wx/cshelp.h>
#include <wx/stdpaths.h>
#ifdef __WXMSW__
#include <wx/dir.h>
#include <wx/taskbarbutton.h>
#endif
#if defined __WXGTK__
#include "base_wx/wxPlatform.h"
#endif

#include <tiffio.h>

#include "AboutDialog.h"

//for natural sorting
#include "hugin_utils/alphanum.h"
#include "lensdb/LensDB.h"

bool checkVersion(wxString v1, wxString v2)
{
    return doj::alphanum_comp(std::string(v1.mb_str(wxConvLocal)),std::string(v2.mb_str(wxConvLocal))) < 0;
};

wxString Components2Str(const HuginGraph::ImageGraph::Components & comp)
{
    wxString ret;
    for (unsigned i=0; i < comp.size(); i++) {
        ret.Append("[");
        HuginGraph::ImageGraph::Components::value_type::const_iterator it = comp[i].begin();
        while (it != comp[i].end())
        {
            unsigned int imgNr = *it;
            ret << imgNr;
            it++;
            if (it != comp[i].end() && *it == imgNr + 1)
            {
                ret.Append("-");
                while (it != comp[i].end() && *it == imgNr + 1)
                {
                    ++it;
                    ++imgNr;
                };
                ret << imgNr;
                if (it != comp[i].end())
                {
                    ret.Append(", ");
                };
            }
            else
            {
                if (it != comp[i].end())
                {
                    ret.Append(", ");
                };
            };
        };

        ret.Append("]");
        if (i + 1 != comp.size())
        {
            ret.Append(", ");
        };
    }
    return ret;
}

// make wxwindows use this class as the main application
#if defined USE_GDKBACKEND_X11
// wxWidgets does not support wxGLCanvas on Wayland
// so until it is fixed upstream enforce using x11 backend
// see ticket http://trac.wxwidgets.org/ticket/17702
#warning Using Hugin with hard coded GDK_BACKEND=x11
wxIMPLEMENT_WX_THEME_SUPPORT
wxIMPLEMENT_APP_NO_MAIN(huginApp);
#include <stdlib.h>
int main(int argc, char **argv)
{   
    wxDISABLE_DEBUG_SUPPORT();
    char backend[]="GDK_BACKEND=x11";
    putenv(backend);
    return wxEntry(argc, argv);
};
#else
wxIMPLEMENT_APP(huginApp);
#endif

wxDEFINE_EVENT(EVT_IMAGE_READY, ImageReadyEvent);

ImageReadyEvent::ImageReadyEvent(HuginBase::ImageCache::RequestPtr request, HuginBase::ImageCache::EntryPtr entry) : wxEvent(0, EVT_IMAGE_READY), request(request), entry(entry)
{
}

wxEvent* ImageReadyEvent::Clone() const
{
    return new ImageReadyEvent(request, entry);
}

huginApp::huginApp()
{
    DEBUG_TRACE("ctor");
    m_this=this;
    m_monitorProfile = NULL;
#if wxUSE_ON_FATAL_EXCEPTION
    wxHandleFatalExceptions();
#endif
    Bind(EVT_IMAGE_READY, &huginApp::relayImageLoaded, this);
}

huginApp::~huginApp()
{
    DEBUG_TRACE("dtor");
    // delete temporary dir
//    if (!wxRmdir(m_workDir)) {
//        DEBUG_ERROR("Could not remove temporary directory");
//    }

	// todo: remove all listeners from the panorama object

//    delete frame;
    HuginBase::LensDB::LensDB::Clean();
    // delete monitor profile
    if (m_monitorProfile)
    {
        cmsCloseProfile(m_monitorProfile);
    };
    DEBUG_TRACE("dtor end");
}

bool huginApp::OnInit()
{
    DEBUG_TRACE("=========================== huginApp::OnInit() begin ===================");
    SetAppName("hugin");
#if defined __WXMSW__ && wxCHECK_VERSION(3,3,0)
    // automatically switch between light and dark mode
    SetAppearance(Appearance::System);
#endif
#if defined __WXGTK__
    CheckConfigFilename();
#endif

    // Connect to ImageCache: we need to tell it when it is safe to handle UI events.
    ImageCache::getInstance().asyncLoadCompleteSignal = &huginApp::imageLoadedAsync;

#ifdef __WXMAC__
    // do not use the native list control on OSX (it is very slow with the control point list window)
    wxSystemOptions::SetOption("mac.listctrl.always_use_generic", 1);
    // On OS X the file open does by default not show the file type list
    // Apple means this is not necessary
    // but the the add images dialog needs this selection, so force to 
    // display always the file type list
    wxSystemOptions::SetOption(wxOSX_FILEDIALOG_ALWAYS_SHOW_TYPES, 1);
#endif

    // register our custom pano tools dialog handlers
    registerPTWXDlgFcn();

    // required by wxHtmlHelpController
    wxFileSystem::AddHandler(new wxZipFSHandler);

    // initialize help provider
    wxHelpControllerHelpProvider* provider = new wxHelpControllerHelpProvider;
    wxHelpProvider::Set(provider);

#if defined __WXMSW__
    wxFileName exePath(wxStandardPaths::Get().GetExecutablePath());
    m_utilsBinDir = exePath.GetPath(wxPATH_GET_VOLUME | wxPATH_GET_SEPARATOR);
    exePath.RemoveLastDir();
    const wxString huginRoot=exePath.GetPath(wxPATH_GET_VOLUME | wxPATH_GET_SEPARATOR);
    m_xrcPrefix = huginRoot + "share\\hugin\\xrc\\";
    m_DataDir = huginRoot + "share\\hugin\\data\\";

    // locale setup
    locale.AddCatalogLookupPathPrefix(huginRoot + "share\\locale");

#elif defined __WXMAC__ && defined MAC_SELF_CONTAINED_BUNDLE
    // initialize paths
    {
        wxString thePath = MacGetPathToBundledResourceFile(CFSTR("xrc"));
        if (thePath == wxEmptyString) {
            hugin_utils::HuginMessageBox(_("xrc directory not found in bundle"), _("Hugin"), wxOK | wxICON_ERROR, wxGetActiveWindow());
            return false;
        }
        m_xrcPrefix = thePath + "/";
        m_DataDir = thePath + "/";
    }

#ifdef HUGIN_HSI
    // Set PYTHONHOME for the hsi module
    {
        wxString pythonHome = MacGetPathToBundledFrameworksDirectory() + "/Python27.framework/Versions/Current";
        if(! wxDir::Exists(pythonHome)){
            hugin_utils::HuginMessageBox(wxString::Format(_("Directory '%s' does not exists"), pythonHome), _("Hugin"), wxOK | wxICON_ERROR, wxGetActiveWindow());
        } else {
            wxUnsetEnv("PYTHONPATH");
            if(! wxSetEnv("PYTHONHOME", pythonHome)){
                hugin_utils::HuginMessageBox(_("Could not set environment variable PYTHONHOME"), _("Hugin"), wxOK | wxICON_ERROR, wxGetActiveWindow());
            } else {
                DEBUG_TRACE("PYTHONHOME set to " << pythonHome);
            }
        }
    }
#endif
    
#elif defined UNIX_SELF_CONTAINED_BUNDLE
    // initialize paths
    {
      wxFileName exePath(wxStandardPaths::Get().GetExecutablePath());
      m_utilsBinDir = exePath.GetPath(wxPATH_GET_VOLUME | wxPATH_GET_SEPARATOR);
      exePath.RemoveLastDir();
      const wxString huginRoot=exePath.GetPath(wxPATH_GET_VOLUME | wxPATH_GET_SEPARATOR);
      m_xrcPrefix = huginRoot + "share/hugin/xrc/";
      m_DataDir = huginRoot + "share/hugin/data/";

      // locale setup
      locale.AddCatalogLookupPathPrefix(huginRoot + "share/locale");
    }

#else
    // add the locale directory specified during configure
    m_xrcPrefix = INSTALL_XRC_DIR;
    m_DataDir = INSTALL_DATA_DIR;
    locale.AddCatalogLookupPathPrefix(INSTALL_LOCALE_DIR);
#endif

    if ( ! wxFile::Exists(m_xrcPrefix + "/main_frame.xrc") ) {
        hugin_utils::HuginMessageBox(wxString::Format(_("xrc directory not found, hugin needs to be properly installed\nTried Path: %s"), m_xrcPrefix), _("Hugin"), wxOK | wxICON_ERROR, wxGetActiveWindow());
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

    // load all XRC files.
    #ifdef _INCLUDE_UI_RESOURCES
        InitXmlResource();
    #else

    // add custom XRC handlers
    wxXmlResource::Get()->AddHandler(new ImagesPanelXmlHandler());
    wxXmlResource::Get()->AddHandler(new CPEditorPanelXmlHandler());
    wxXmlResource::Get()->AddHandler(new CPImageCtrlXmlHandler());
    wxXmlResource::Get()->AddHandler(new CPImagesComboBoxXmlHandler());
    wxXmlResource::Get()->AddHandler(new MaskEditorPanelXmlHandler());
    wxXmlResource::Get()->AddHandler(new MaskImageCtrlXmlHandler());
    wxXmlResource::Get()->AddHandler(new OptimizePanelXmlHandler());
    wxXmlResource::Get()->AddHandler(new OptimizePhotometricPanelXmlHandler());
    wxXmlResource::Get()->AddHandler(new PanoPanelXmlHandler());
    wxXmlResource::Get()->AddHandler(new PreviewPanelXmlHandler());
    wxXmlResource::Get()->AddHandler(new HtmlWindowXmlHandler());
    wxXmlResource::Get()->AddHandler(new wxcode::wxTreeListCtrlXmlHandler());
    wxXmlResource::Get()->AddHandler(new ImagesTreeCtrlXmlHandler());
    wxXmlResource::Get()->AddHandler(new CPListCtrlXmlHandler());
    wxXmlResource::Get()->AddHandler(new SplitButtonXmlHandler());

    // load XRC files
    wxXmlResource::Get()->Load(m_xrcPrefix + "cp_list_frame.xrc");
    wxXmlResource::Get()->Load(m_xrcPrefix + "preview_frame.xrc");
    wxXmlResource::Get()->Load(m_xrcPrefix + "edit_script_dialog.xrc");
    wxXmlResource::Get()->Load(m_xrcPrefix + "main_menu.xrc");
    wxXmlResource::Get()->Load(m_xrcPrefix + "main_tool.xrc");
    wxXmlResource::Get()->Load(m_xrcPrefix + "about.xrc");
    wxXmlResource::Get()->Load(m_xrcPrefix + "pref_dialog.xrc");
    wxXmlResource::Get()->Load(m_xrcPrefix + "cpdetector_dialog.xrc");
    wxXmlResource::Get()->Load(m_xrcPrefix + "reset_dialog.xrc");
    wxXmlResource::Get()->Load(m_xrcPrefix + "optimize_photo_panel.xrc");
    wxXmlResource::Get()->Load(m_xrcPrefix + "cp_editor_panel.xrc");
    wxXmlResource::Get()->Load(m_xrcPrefix + "images_panel.xrc");
    wxXmlResource::Get()->Load(m_xrcPrefix + "main_frame.xrc");
    wxXmlResource::Get()->Load(m_xrcPrefix + "optimize_panel.xrc");
    wxXmlResource::Get()->Load(m_xrcPrefix + "pano_panel.xrc");
    wxXmlResource::Get()->Load(m_xrcPrefix + "mask_editor_panel.xrc");
    wxXmlResource::Get()->Load(m_xrcPrefix + "lensdb_dialogs.xrc");
    wxXmlResource::Get()->Load(m_xrcPrefix + "image_variable_dlg.xrc");
    wxXmlResource::Get()->Load(m_xrcPrefix + "dlg_warning.xrc");
    wxXmlResource::Get()->Load(m_xrcPrefix + "import_raw_dialog.xrc");
#endif

#ifdef __WXMAC__
    // If hugin is starting with file opening AppleEvent, MacOpenFile will be called on first wxYield().
    // Those need to be initialised before first call of Yield which happens in Mainframe constructor.
    m_macInitDone=false;
    m_macOpenFileOnStart=false;
#endif
    // read monitor profile
    HuginBase::Color::GetMonitorProfile(m_monitorProfileName, m_monitorProfile);
    // create main frame
    frame = new MainFrame(NULL, pano);
    SetTopWindow(frame);

    // setup main frame size, after it has been created.
    hugin_utils::RestoreFramePosition(frame, "MainFrame");
#ifdef __WXMSW__
    frame->SendSizeEvent();
// wxUSE_TASKBARBUTTON 1 is default, nevertheless check that the feature has not been deactivated by the user, otherwise issue a warning
#if wxUSE_TASKBARBUTTON
    wxTaskBarJumpList jumpList;
    wxFileName exeFile(wxStandardPaths::Get().GetExecutablePath());
    exeFile.SetName("PTBatcherGUI");
    wxTaskBarJumpListItem *item1 = new wxTaskBarJumpListItem(
        NULL, wxTASKBAR_JUMP_LIST_TASK, _("Open Batch Processor"), exeFile.GetFullPath(), wxEmptyString,
        _("Opens PTBatcherGUI, the batch processor for Hugin's project files"),
        exeFile.GetFullPath(), 0);
    jumpList.GetTasks().Append(item1);
    exeFile.SetName("calibrate_lens_gui");
    item1 = new wxTaskBarJumpListItem(
        NULL, wxTASKBAR_JUMP_LIST_TASK, _("Open Lens calibrate tool"), exeFile.GetFullPath(), wxEmptyString,
        _("Opens Calibrate_lens_gui, a simple GUI for lens calibration"),
        exeFile.GetFullPath(), 0);
    jumpList.GetTasks().Append(item1);
    exeFile.SetName("Hugin_toolbox");
    item1 = new wxTaskBarJumpListItem(
        NULL, wxTASKBAR_JUMP_LIST_TASK, _("Open Hugin toolbox"), exeFile.GetFullPath(), wxEmptyString,
        _("Opens Hugin_toolbox, a GUI for several small helper programs"),
        exeFile.GetFullPath(), 0);
    jumpList.GetTasks().Append(item1);
#else
  #if defined _MSC_VER
    #pragma message("Warning: huginApp.cpp - wxWidgets is compiled without support for taskbar buttons. Some features have therefore disabled.")
  #else
    #warning "Warning: huginApp.cpp - wxWidgets is compiled without support for taskbar buttons. Some features have therefore disabled."
  #endif
#endif
#endif
    // init help system
    provider->SetHelpController(&frame->GetHelpController());
#ifdef __WXMSW__
    frame->GetHelpController().Initialize(m_xrcPrefix + "data/hugin_help_en_EN.chm");
#else
#if wxUSE_WXHTML_HELP
    // using wxHtmlHelpController
#if defined __WXMAC__ && defined MAC_SELF_CONTAINED_BUNDLE
    // On Mac, xrc/data/help_LOCALE should be in the bundle as LOCALE.lproj/help
    // which we can rely on the operating sytem to pick the right locale's.
    wxString strFile = MacGetPathToBundledResourceFile(CFSTR("help"));
    if (!strFile.IsEmpty())
    {
        frame->GetHelpController().AddBook(wxFileName(strFile + "/hugin_help_en_EN.hhp"));
    }
    else
    {
        wxLogError(wxString::Format("Could not find help directory in the bundle", strFile.c_str()));
        return false;
    }
#else
    frame->GetHelpController().AddBook(wxFileName(m_xrcPrefix + "data/help_en_EN/hugin_help_en_EN.hhp"));
#endif
#else
    // using wxExtHelpController
    frame->GetHelpController().Initialize(Initialize(m_xrcPrefix + "data/help_en_EN"));
#endif
#endif

    // we are closing Hugin, if the top level window is deleted
    SetExitOnFrameDelete(true);
    // show the frame.
    if(frame->GetGuiLevel()==GUI_SIMPLE)
    {
        SetTopWindow(frame->getGLPreview());
    }
    else
    {
        frame->Show(TRUE);
    };

    wxString cwd = wxFileName::GetCwd();

    m_workDir = config->Read("tempDir",wxEmptyString);
    // FIXME, make secure against some symlink attacks
    // get a temp dir
    if (m_workDir == wxEmptyString) {
#if (defined __WXMSW__)
        DEBUG_DEBUG("figuring out windows temp dir");
        /* added by Yili Zhao */
        wxChar buffer[MAX_PATH];
        GetTempPath(MAX_PATH, buffer);
        m_workDir = buffer;
#elif (defined __WXMAC__) && (defined MAC_SELF_CONTAINED_BUNDLE)
        DEBUG_DEBUG("temp dir on Mac");
        m_workDir = MacGetPathToUserDomainTempDir();
        if(m_workDir == wxEmptyString)
            m_workDir = "/tmp";
#else //UNIX
        DEBUG_DEBUG("temp dir on unix");
        // try to read environment variable
        if (!wxGetEnv("TMPDIR", &m_workDir)) {
            // still no tempdir, use /tmp
            m_workDir = "/tmp";
        }
#endif
        
    }

    if (!wxFileName::DirExists(m_workDir)) {
        DEBUG_DEBUG("creating temp dir: " << m_workDir.mb_str(wxConvLocal));
        if (!wxMkdir(m_workDir)) {
            DEBUG_ERROR("Tempdir could not be created: " << m_workDir.mb_str(wxConvLocal));
        }
    }
    if (!wxSetWorkingDirectory(m_workDir)) {
        DEBUG_ERROR("could not change to temp. dir: " << m_workDir.mb_str(wxConvLocal));
    }
    DEBUG_DEBUG("using temp dir: " << m_workDir.mb_str(wxConvLocal));

    // set some suitable defaults
    PanoCommand::GlobalCmdHist::getInstance().addCommand(new PanoCommand::wxNewProjectCmd(pano));
    PanoCommand::GlobalCmdHist::getInstance().clear();

    // suppress tiff warnings
    TIFFSetWarningHandler(0);

    if (argc > 1)
    {
#ifdef __WXMSW__
        //on Windows we need to update the fast preview first
        //otherwise there is an infinite loop when starting with a project file
        //and closed panorama editor aka mainframe
        if(frame->GetGuiLevel()==GUI_SIMPLE)
        {
            frame->getGLPreview()->Update();
        };
#endif
        wxFileName file(argv[1]);
        // if the first file is a project file, open it
        if (file.GetExt().CmpNoCase("pto") == 0 ||
            file.GetExt().CmpNoCase("pts") == 0 ||
            file.GetExt().CmpNoCase("ptp") == 0 )
        {
            if(file.IsRelative())
                file.MakeAbsolute(cwd);
            // Loading the project file with set actualPath to its
            // parent directory.  (actualPath is used as starting
            // directory by many subsequent file selection dialogs.)
            frame->LoadProjectFile(file.GetFullPath());
        } else {
            std::vector<std::string> filesv;
            std::vector<std::string> rawFilesv;
            bool actualPathSet = false;
            for (int i=1; i< argc; i++) 
            {
#if defined __WXMSW__
                //expand wildcards
                wxFileName fileList(argv[i]);
                if(fileList.IsRelative())
                    fileList.MakeAbsolute(cwd);
                wxDir dir;
                wxString foundFile;
                wxFileName file;
                if(fileList.DirExists())
                    if(dir.Open(fileList.GetPath()))
                        if(dir.GetFirst(&foundFile,fileList.GetFullName(),wxDIR_FILES | wxDIR_HIDDEN))
                            do
                            {
                                file=foundFile;
                                file.MakeAbsolute(dir.GetName());
#else
                wxFileName file(argv[i]);
#endif
                if (file.IsRelative())
                {
                    file.MakeAbsolute(cwd);
                };
                if (IsRawExtension(file.GetExt()))
                {
                    // we got a raw file from command line
                    if (!containsInvalidCharacters(file.GetFullPath()))
                    {
                        rawFilesv.push_back((const char*)file.GetFullPath().mb_str(HUGIN_CONV_FILENAME));
                        // Use the first filename to set actualPath.
                        if (!actualPathSet)
                        {
                            config->Write("/actualPath", file.GetPath());
                            actualPathSet = true;
                        };
                    };
                }
                else
                {
                    if (vigra::isImage(file.GetFullPath().mb_str(HUGIN_CONV_FILENAME)))
                    {
                        if (!containsInvalidCharacters(file.GetFullPath()))
                        {
                            filesv.push_back((const char *)(file.GetFullPath().mb_str(HUGIN_CONV_FILENAME)));
                            // Use the first filename to set actualPath.
                            if (!actualPathSet)
                            {
                                config->Write("/actualPath", file.GetPath());
                                actualPathSet = true;
                            };
                        };
                    };
                };
#if defined __WXMSW__
                } while (dir.GetNext(&foundFile));
#endif
            }
            if(!filesv.empty())
            {
                std::vector<PanoCommand::PanoCommand*> cmds;
                cmds.push_back(new PanoCommand::wxAddImagesCmd(pano,filesv));
                cmds.push_back(new PanoCommand::DistributeImagesCmd(pano));
                cmds.push_back(new PanoCommand::CenterPanoCmd(pano));
                PanoCommand::GlobalCmdHist::getInstance().addCommand(new PanoCommand::CombinedPanoCommand(pano, cmds));
            };
            if (!rawFilesv.empty())
            {
                if (rawFilesv.size() == 1)
                {
                    hugin_utils::MessageDialog message=hugin_utils::GetMessageDialog(_("You selected only one raw file. This is not recommended.\nAll raw files should be converted at once."), 
                        _("Hugin"), wxICON_EXCLAMATION | wxOK | wxCANCEL, wxGetActiveWindow());
                    message->SetOKLabel(_("Convert anyway."));
                    if (message->ShowModal() != wxID_OK)
                    {
                        return true;
                    };
            };
                RawImportDialog dlg(GetTopWindow(), &pano, rawFilesv);
                // check that raw files are from same camera and that all can be read
                if (dlg.CheckRawFiles())
                {
                    // now show dialog
                    if (dlg.ShowModal() == wxID_OK)
                    {
                        PanoCommand::GlobalCmdHist::getInstance().addCommand(dlg.GetPanoCommand());
                    };
                };
            };
        };
    }
#ifdef __WXMAC__
    m_macInitDone = true;
    if(m_macOpenFileOnStart) {frame->LoadProjectFile(m_macFileNameToOpenOnStart);}
    m_macOpenFileOnStart = false;
#endif

	//check for no tip switch, needed by PTBatcher
	wxString secondParam = argc > 2 ? wxString(argv[2]) : wxString();
	if(secondParam.Cmp(_T("-notips"))!=0)
	{
		//load tip startup preferences (tips will be started after splash terminates)
		int nValue = config->Read("/MainFrame/ShowStartTip", 1l);

		//show tips if needed now
		if(nValue > 0)
		{
			wxCommandEvent dummy;
			frame->OnTipOfDay(dummy);
		}
	}

    DEBUG_TRACE("=========================== huginApp::OnInit() end ===================");
    return true;
}

int huginApp::OnExit()
{
    DEBUG_TRACE("");
    delete wxHelpProvider::Set(NULL);
    return 0;
}

huginApp * huginApp::Get()
{
    if (m_this) {
        return m_this;
    } else {
        DEBUG_FATAL("huginApp not yet created");
        DEBUG_ASSERT(m_this);
        return 0;
    }
}

MainFrame* huginApp::getMainFrame()
{
    if (m_this) {
        return m_this->frame;
    } else {
        return 0;
    }
}

void huginApp::relayImageLoaded(ImageReadyEvent & event)
{
    if (event.entry.get())
    {
        ImageCache::getInstance().postEvent(event.request, event.entry);
    }
    else
    {
        // loading failed, first remove request from image cache list
        ImageCache::getInstance().removeRequest(event.request);
        // now notify main frame to remove the failed image from project
        wxCommandEvent e(EVT_LOADING_FAILED);
        e.SetString(wxString(event.request->getFilename().c_str(), HUGIN_CONV_FILENAME));
        frame->GetEventHandler()->AddPendingEvent(e);
    };
}

void huginApp::imageLoadedAsync(ImageCache::RequestPtr request, ImageCache::EntryPtr entry)
{
    ImageReadyEvent event(request, entry);
    // AddPendingEvent adds the event to the event queue and returns without
    // processing it. This is necessary since we are probably not in the
    // UI thread, but the event handler must be run in the UI thread since it
    // could update image views.
    Get()->AddPendingEvent(event);
}

#ifdef __WXMAC__
void huginApp::MacOpenFile(const wxString &fileName)
{
    if(!m_macInitDone)
    {
        m_macOpenFileOnStart=true;
        m_macFileNameToOpenOnStart = fileName;
        return;
    }

    if(frame) frame->MacOnOpenFile(fileName);
}
#endif

#if wxUSE_ON_FATAL_EXCEPTION
void huginApp::OnFatalException()
{
    GenerateReport(wxDebugReport::Context_Exception);
};
#endif

huginApp * huginApp::m_this = 0;
