// -*- c-basic-offset: 4 -*-
/** @file EnfusePanel.cpp
 *
 *  @brief implementation of panel for enfuse GUI
 *
 *  @author T. Modes
 *
 */

/*  This program is free software; you can redistribute it and/or
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

#include "EnfusePanel.h"
#include <wx/stdpaths.h>
#include <wx/propgrid/advprops.h>
#include "base_wx/platform.h"
#include "base_wx/wxPlatform.h"
#include "base_wx/MyExternalCmdExecDialog.h"
#include "base_wx/Executor.h"
#include <wx/fileconf.h>
#include <wx/wfstream.h>
#include <wx/sstream.h>
#include "hugin_utils/utils.h"
#include "hugin_base/panodata/SrcPanoImage.h"
#include "base_wx/LensTools.h"
#include "base_wx/wxutils.h"
#include "CreateBrightImgDlg.h"

 /** file drag and drop handler method */
class EnfuseDropTarget : public wxFileDropTarget
{
public:
    EnfuseDropTarget(EnfusePanel* parent) : wxFileDropTarget()
    {
        m_enfusePanel = parent;
    }

    bool OnDropFiles(wxCoord x, wxCoord y, const wxArrayString& filenames)
    {
        // try to add as images
        wxArrayString files;
        for (unsigned int i = 0; i < filenames.GetCount(); i++)
        {
            wxFileName file(filenames[i]);
            if (file.GetExt().CmpNoCase("jpg") == 0 ||
                file.GetExt().CmpNoCase("jpeg") == 0 ||
                file.GetExt().CmpNoCase("tif") == 0 ||
                file.GetExt().CmpNoCase("tiff") == 0 ||
                file.GetExt().CmpNoCase("png") == 0 ||
                file.GetExt().CmpNoCase("bmp") == 0 ||
                file.GetExt().CmpNoCase("gif") == 0 ||
                file.GetExt().CmpNoCase("pnm") == 0 ||
                file.GetExt().CmpNoCase("sun") == 0 ||
                file.GetExt().CmpNoCase("hdr") == 0 ||
                file.GetExt().CmpNoCase("viff") == 0)
            {
                files.push_back(file.GetFullPath());
            };
        };
        // we got some images to add.
        if (!files.empty())
        {
            for (auto& f : files)
            {
                m_enfusePanel->AddFile(f);
            };
        };
        return true;
    }
private:
    EnfusePanel* m_enfusePanel;
};

// load wxPropertyGrid settings from string
void SetPropertyGridContent(wxPropertyGrid* grid, const wxString values)
{
    wxArrayString properties = wxStringTokenize(values, "|");
    for (size_t i = 0; i < properties.size(); ++i)
    {
        wxArrayString prop = wxStringTokenize(properties[i], ":");
        if (prop.size() == 3)
        {
            if (prop[1] == "double")
            {
                double doubleVal;
                if (prop[2].ToCDouble(&doubleVal))
                {
                    grid->SetPropertyValue(prop[0], doubleVal);
                };
            }
            else
            {
                if (prop[1] == "long")
                {
                    long longVal;
                    if (prop[2].ToLong(&longVal))
                    {
                        grid->SetPropertyValue(prop[0], longVal);
                    }
                }
                else
                {
                    if (prop[1] == "bool")
                    {
                        if (prop[2] == "true")
                        {
                            grid->SetPropertyValue(prop[0], true);
                        }
                        else
                        {
                            grid->SetPropertyValue(prop[0], false);
                        };
                    }
                    else
                    {
                        // unknown type, currently not implemented
                    };
                };
            };
        };
    };
}

// save wxPropertyGrid settings into a string
wxString GetPropertyGridContent(const wxPropertyGrid* grid)
{
    wxPropertyGridConstIterator it;
    wxString output;
    for (it = grid->GetIterator(); !it.AtEnd(); it++)
    {
        const wxPGProperty* p = *it;
        if (p->IsCategory())
        {
            // skip categories
            continue;
        }
        if (!output.IsEmpty())
        {
            output.Append("|");
        };
        const wxString type = p->GetValueType();
        output.Append(p->GetName() + ":");
        if (type == "double")
        {
            output.Append("double:" + wxString::FromCDouble(p->GetValue().GetDouble()));
        }
        else
        {
            if (type == "long")
            {
                output.Append("long:" + wxString::FromCDouble(p->GetValue().GetLong()));
            }
            else
            {
                if (type == "bool")
                {
                    if (p->GetValue().GetBool())
                    {
                        output.Append("bool:true");
                    }
                    else
                    {
                        output.Append("bool:false");
                    };
                }
                else
                {
                    // this should not happen
                    output.Append(type);
                };
            };
        };
    };
    return output;
}

// destructor, save settings
EnfusePanel::~EnfusePanel()
{
    wxConfigBase* config = wxConfigBase::Get();
    config->Write("/ToolboxFrame/Enfuse/Splitter", XRCCTRL(*this, "enfuse_splitter", wxSplitterWindow)->GetSashPosition());
    config->Write("/ToolboxFrame/Enfuse/LastSettings", GetPropertyGridContent(m_enfuseOptions));
    //save width of list ctrl column width
    for (int j = 0; j < m_fileListCtrl->GetColumnCount(); j++)
    {
        config->Write(wxString::Format("/ToolboxFrame/Enfuse/FileListColumnWidth%d", j), m_fileListCtrl->GetColumnWidth(j));
    };
    config->Flush();
    CleanUpTempFiles();
}

bool EnfusePanel::Create(wxWindow* parent, MyExecPanel* logPanel)
{
    if (!wxPanel::Create(parent, wxID_ANY, wxDefaultPosition, wxDefaultSize, wxTAB_TRAVERSAL, "panel"))
    {
        return false;
    }
    // populate wxPropertyGrid with all options
    m_enfuseOptions = new wxPropertyGrid(this, wxID_ANY, wxDefaultPosition, wxDefaultSize, wxPG_SPLITTER_AUTO_CENTER);
    PopulateEnfuseOptions();
    // create preview window
    m_preview = new PreviewWindow();
    m_preview->Create(this);

    m_logWindow = logPanel;
    // load from xrc file and attach unknown controls
    wxXmlResource::Get()->LoadPanel(this, "enfuse_panel");
    wxXmlResource::Get()->AttachUnknownControl("enfuse_properties", m_enfuseOptions->GetGrid(), this);
    wxXmlResource::Get()->AttachUnknownControl("enfuse_preview_window", m_preview, this);
    // add to sizer
    wxPanel* mainPanel = XRCCTRL(*this, "enfuse_panel", wxPanel);
    wxBoxSizer* topsizer = new wxBoxSizer(wxVERTICAL);
    topsizer->Add(mainPanel, wxSizerFlags(1).Expand());
    // create columns in wxListCtrl
    m_fileListCtrl = XRCCTRL(*this, "enfuse_files", wxListCtrl);
    m_fileListCtrl->InsertColumn(0, _("Filename"), wxLIST_FORMAT_LEFT, 200);
    m_fileListCtrl->InsertColumn(1, _("Aperture"), wxLIST_FORMAT_LEFT, 50);
    m_fileListCtrl->InsertColumn(2, _("Shutter Speed"), wxLIST_FORMAT_LEFT, 50);
    m_fileListCtrl->InsertColumn(3, _("ISO"), wxLIST_FORMAT_LEFT, 50);
    m_fileListCtrl->EnableCheckBoxes(true);
    SetSizer(topsizer);
    SetDropTarget(new EnfuseDropTarget(this));

    wxConfigBase* config = wxConfigBase::Get();
    // restore splitter position
    if (config->HasEntry("/ToolboxFrame/Enfuse/Splitter"))
    {
        XRCCTRL(*this, "enfuse_splitter", wxSplitterWindow)->SetSashPosition(config->ReadLong("/ToolboxFrame/Enfuse/Splitter", 300));
    }
    const wxString enfuseOptionsString=config->Read("/ToolboxFrame/Enfuse/LastSettings");
    if (!enfuseOptionsString.IsEmpty())
    {
        SetPropertyGridContent(m_enfuseOptions, enfuseOptionsString);
    };
    //get saved width of list ctrl column width
    for (int j = 0; j < m_fileListCtrl->GetColumnCount(); j++)
    {
        // -1 is auto
        int width = config->Read(wxString::Format("/ToolboxFrame/Enfuse/FileListColumnWidth%d", j), -1);
        if (width != -1)
        {
            m_fileListCtrl->SetColumnWidth(j, width);
        };
    };
    // bind event handler
    Bind(wxEVT_SIZE, &EnfusePanel::OnSize, this);
    Bind(wxEVT_BUTTON, &EnfusePanel::OnAddFiles, this, XRCID("enfuse_add_file"));
    Bind(wxEVT_BUTTON, &EnfusePanel::OnRemoveFile, this, XRCID("enfuse_remove_file"));
    Bind(wxEVT_BUTTON, &EnfusePanel::OnCreateFile, this, XRCID("enfuse_create_file"));
    m_fileListCtrl->Bind(wxEVT_CHAR, &EnfusePanel::OnFileListChar, this);
    m_fileListCtrl->Bind(wxEVT_LIST_ITEM_SELECTED, &EnfusePanel::OnFileSelectionChanged, this);
    m_fileListCtrl->Bind(wxEVT_LIST_ITEM_DESELECTED, &EnfusePanel::OnFileSelectionChanged, this);
    m_fileListCtrl->Bind(wxEVT_LIST_ITEM_CHECKED, &EnfusePanel::OnFileCheckStateChanged, this);
    m_fileListCtrl->Bind(wxEVT_LIST_ITEM_UNCHECKED, &EnfusePanel::OnFileCheckStateChanged, this);
    Bind(wxEVT_BUTTON, &EnfusePanel::OnLoadSetting, this, XRCID("enfuse_load_setting"));
    Bind(wxEVT_BUTTON, &EnfusePanel::OnSaveSetting, this, XRCID("enfuse_save_setting"));
    Bind(wxEVT_BUTTON, &EnfusePanel::OnResetSetting, this, XRCID("enfuse_reset_setting"));
    Bind(wxEVT_BUTTON, &EnfusePanel::OnGeneratePreview, this, XRCID("enfuse_preview"));
    Bind(wxEVT_BUTTON, &EnfusePanel::OnGenerateOutput, this, XRCID("enfuse_enfuse"));
    Bind(wxEVT_CHOICE, &EnfusePanel::OnZoom, this, XRCID("enfuse_choice_zoom"));

    EnableFileButtons();
    EnableOutputButtons(false);
    return true;
}

void EnfusePanel::AddFile(const wxString& filename)
{
    // add filename
    m_files.push_back(filename);
    // add to wxListCtrl
    wxFileName fullFilename(filename);
    long index = m_fileListCtrl->InsertItem(m_fileListCtrl->GetItemCount(), fullFilename.GetFullName());
    // set checkbox
    m_fileListCtrl->CheckItem(index, true);
    // read exif
    {
        HuginBase::SrcPanoImage srcImage;
        srcImage.setFilename(std::string(fullFilename.GetFullPath().mb_str(HUGIN_CONV_FILENAME)));
        if (srcImage.readEXIF())
        {
            m_fileListCtrl->SetItem(index, 1, FormatString::GetAperture(&srcImage));
            m_fileListCtrl->SetItem(index, 2, FormatString::GetExposureTime(&srcImage));
            m_fileListCtrl->SetItem(index, 3, FormatString::GetIso(&srcImage));
        };
    };
    EnableOutputButtons(GetCheckedItemCount() > 0);
}

void EnfusePanel::OnSize(wxSizeEvent& e)
{
    Layout();
    Update();
    e.Skip();
}

void EnfusePanel::OnAddFiles(wxCommandEvent& e)
{
    wxConfigBase* config = wxConfigBase::Get();
    wxString path = config->Read("/actualPath", "");
    wxFileDialog dlg(this, _("Add images"), path, wxEmptyString,
        GetFileDialogImageFilters(), wxFD_OPEN | wxFD_MULTIPLE | wxFD_FILE_MUST_EXIST | wxFD_PREVIEW, wxDefaultPosition);
    dlg.SetDirectory(path);

    // remember the image extension
    wxString img_ext;
    if (config->HasEntry("lastImageType"))
    {
        img_ext = config->Read("lastImageType").c_str();
    }
    if (img_ext == "all images")
        dlg.SetFilterIndex(0);
    else if (img_ext == "jpg")
        dlg.SetFilterIndex(1);
    else if (img_ext == "tiff")
        dlg.SetFilterIndex(2);
    else if (img_ext == "png")
        dlg.SetFilterIndex(3);
    else if (img_ext == "hdr")
        dlg.SetFilterIndex(4);
    else if (img_ext == "exr")
        dlg.SetFilterIndex(5);
    else if (img_ext == "all files")
        dlg.SetFilterIndex(6);

    // call the file dialog
    if (dlg.ShowModal() == wxID_OK)
    {
        // get the selections
        wxArrayString Pathnames;
        dlg.GetPaths(Pathnames);
        // save the current path to config
        config->Write("/actualPath", dlg.GetDirectory());
        // save the image extension
        switch (dlg.GetFilterIndex())
        {
            case 0: config->Write("lastImageType", "all images"); break;
            case 1: config->Write("lastImageType", "jpg"); break;
            case 2: config->Write("lastImageType", "tiff"); break;
            case 3: config->Write("lastImageType", "png"); break;
            case 4: config->Write("lastImageType", "hdr"); break;
            case 5: config->Write("lastImageType", "exr"); break;
            case 6: config->Write("lastImageType", "all files"); break;
        }
        for (auto& f : Pathnames)
        {
            AddFile(f);
        }
    }
}

void EnfusePanel::OnRemoveFile(wxCommandEvent& e)
{
    HuginBase::UIntSet selected;
    if (m_fileListCtrl->GetSelectedItemCount() >= 1)
    {
        for (int i = 0; i < m_fileListCtrl->GetItemCount(); ++i)
        {
            if (m_fileListCtrl->GetItemState(i, wxLIST_STATE_SELECTED) & wxLIST_STATE_SELECTED)
            {
                selected.insert(i);
            };
        };
    };
    if (!selected.empty())
    {
        // remove selected file from wxListBox and internal file list
        for (auto i = selected.rbegin(); i != selected.rend(); ++i)
        {
            if (*i >= 0 && *i < m_files.size())
            {
                m_fileListCtrl->DeleteItem(*i);
                m_files.RemoveAt(*i, 1);
            };
        };
        EnableFileButtons();
        EnableOutputButtons(GetCheckedItemCount() > 0);
    }
    else
    {
        wxBell();
    };
}

void EnfusePanel::OnCreateFile(wxCommandEvent& e)
{
    if (m_fileListCtrl->GetSelectedItemCount() == 1)
    {
        // single image selected
        long index = m_fileListCtrl->GetNextItem(-1, wxLIST_NEXT_ALL, wxLIST_STATE_SELECTED);
        if (index != -1)
        {
            CreateBrightImgDlg dlg(this);
            wxString errorMsg;
            if (dlg.SetImage(std::string(m_files[index].mb_str(HUGIN_CONV_FILENAME)), errorMsg))
            {
                if (dlg.ShowModal() == wxID_OK)
                {
                    // get all new files
                    wxArrayString newFiles = dlg.GetTempFiles();
                    // wait a little bit before reading the files back
                    // wxMilliSleep(1000);
                    for (const auto& f : newFiles)
                    {
                        // add to list of temp files for cleanup at end
                        m_tempFiles.Add(f);
                        // add to list
                        AddFile(f);
                    };
                };
            }
            else
            {
                hugin_utils::HuginMessageBox(errorMsg, _("Hugin toolbox"), wxOK | wxICON_QUESTION, this);
            };
        };
    }
    else
    {
        wxBell();
    };
}

void EnfusePanel::OnFileListChar(wxKeyEvent& e)
{
    // ctrl + a, select all files
    if (e.GetKeyCode() == 1 && e.CmdDown())
    {
        // select all
        for (int i = 0; i < m_fileListCtrl->GetItemCount(); i++)
        {
            m_fileListCtrl->SetItemState(i, wxLIST_STATE_SELECTED, wxLIST_STATE_SELECTED);
        };
    };
    // insert key, add file
    if ((e.GetKeyCode() == WXK_INSERT || e.GetKeyCode() == WXK_NUMPAD_INSERT) && !e.HasAnyModifiers())
    {
        wxCommandEvent e(wxEVT_BUTTON);
        e.SetId(XRCID("enfuse_add_file"));
        this->GetEventHandler()->AddPendingEvent(e);
    };
    // delete key, delete selected file
    if ((e.GetKeyCode() == WXK_DELETE || e.GetKeyCode() == WXK_NUMPAD_DELETE) && !e.HasAnyModifiers())
    {
        if (m_fileListCtrl->GetSelectedItemCount() > 0)
        {
            wxCommandEvent e(wxEVT_BUTTON);
            e.SetId(XRCID("enfuse_remove_file"));
            this->GetEventHandler()->AddPendingEvent(e);
        }
        else
        {
            wxBell();
        };
    };
    e.Skip();
}

void EnfusePanel::OnFileSelectionChanged(wxCommandEvent& e)
{
    // enable/disable button according to selected files
    EnableFileButtons();
}

void EnfusePanel::OnFileCheckStateChanged(wxCommandEvent& e)
{
    EnableOutputButtons(GetCheckedItemCount() > 0);
}

/** default ini, if no one exists load this one */
static const wxString defaultIni
{
    "[Enfuse_Settings]\n"
    "Exposure fusion=exposureWeight:double:1|saturationWeight:double:0|contrastWeight:double:0|entropyWeight:double:0|hardMask:bool:false|levels:long:0|blendColorspace:long:0|wrapMode:long:0|exposureOptimum:double:0.5|exposureWidth:double:0.2|contrastEdgeScale:double:0|contrastMinCurvature:double:0|contrastWindowSize:long:5|entropyLowerCutoff:double:0|entropyUpperCutoff:double:100|entropyWindowSize:long:3|exposureLowerCutoff:double:0|exposureUpperCutoff:double:100|exposureWeightFunction:long:0|grayProjector:long:1\n"
    "Focus stacking=exposureWeight:double:0|saturationWeight:double:0|contrastWeight:double:1|entropyWeight:double:0|hardMask:bool:true|levels:long:0|blendColorspace:long:0|wrapMode:long:0|exposureOptimum:double:0.5|exposureWidth:double:0.2|contrastEdgeScale:double:0|contrastMinCurvature:double:0|contrastWindowSize:long:5|entropyLowerCutoff:double:0|entropyUpperCutoff:double:100|entropyWindowSize:long:3|exposureLowerCutoff:double:0|exposureUpperCutoff:double:100|exposureWeightFunction:long:0|grayProjector:long:1\n"
};

wxFileConfig* ReadIni(const wxString& filename)
{
    wxInputStream* iniStream{ nullptr };
    if (wxFileExists(filename))
    {
        iniStream = new wxFileInputStream(filename);
        if (!iniStream->IsOk())
        {
            delete iniStream;
            iniStream = nullptr;
        }
    };
    if (iniStream == nullptr)
    {
        iniStream = new wxStringInputStream(defaultIni);
    };
    // now read from stream
    wxFileConfig* iniFile=new wxFileConfig(*iniStream);
    delete iniStream;
    return iniFile;
}

void EnfusePanel::OnLoadSetting(wxCommandEvent& e)
{
    wxFileName iniFilename(hugin_utils::GetUserAppDataDir(), "toolbox.ini");
    wxFileConfig* iniFile = ReadIni(iniFilename.GetFullPath());
    // read known settings from file
    iniFile->SetPath("Enfuse_Settings");
    wxArrayString knownNames;
    wxArrayString knownSettings;
    wxString key;
    long indexKey;
    bool hasKeys = iniFile->GetFirstEntry(key, indexKey);
    while (hasKeys)
    {
        knownNames.push_back(key);
        knownSettings.push_back(iniFile->Read(key));
        hasKeys = iniFile->GetNextEntry(key, indexKey);
    };
    int selection=wxGetSingleChoiceIndex(_("Select the Enfuse setting, which should be loaded."), _("Hugin toolbox"), knownNames, 0, this);
    if (selection != -1)
    {
        SetPropertyGridContent(m_enfuseOptions, knownSettings[selection]);
    };
    delete iniFile;
}

void EnfusePanel::OnSaveSetting(wxCommandEvent& e)
{
    wxFileName iniFilename(hugin_utils::GetUserAppDataDir(), "toolbox.ini");
    wxFileConfig* iniFile = ReadIni(iniFilename.GetFullPath());
    // read known settings from file
    iniFile->SetPath("Enfuse_Settings");
    wxArrayString knownNames;
    wxString key;
    long indexKey;
    bool hasKeys = iniFile->GetFirstEntry(key, indexKey);
    while (hasKeys)
    {
        knownNames.push_back(key);
        hasKeys = iniFile->GetNextEntry(key, indexKey);
    };
    wxString name;
    while (true)
    {
        name = wxGetTextFromUser(_("Enter name of Enfuse setting"), "Enfuse settings", name, this);
        if (name.IsEmpty())
        {
            // empty name or cancel
            delete iniFile;
            return;
        };
        // remove the '=' character from name, it is used as separator in ini file
        name.Replace("=", "", true);
        if (knownNames.Index(name) != wxNOT_FOUND)
        {
            if (hugin_utils::HuginMessageBox(wxString::Format(_("Enfuse setting with name \"%s\" is already existing.\nShould it be overwritten?"), name),
                _("Hugin toolbox"), wxYES_NO | wxICON_QUESTION, this) == wxYES)
            {
                break;
            };
        }
        else
        {
            break;
        };
    };
    // finally write settings
    iniFile->Write(name, GetPropertyGridContent(m_enfuseOptions));
    // finally write to disc
    wxFileOutputStream iniStream(iniFilename.GetFullPath());
    bool success = true;
    if (iniStream.IsOk())
    {
        success = iniFile->Save(iniStream);
    };
    if (!success)
    {
        hugin_utils::HuginMessageBox(wxString::Format(_("Could not save ini file \"%s\"."), iniFilename.GetFullPath()), _("Hugin toolbox"), wxOK | wxICON_ERROR, this);
    };
    delete iniFile;
}

void EnfusePanel::OnResetSetting(wxCommandEvent& e)
{
    // reset all settings to default values
    m_enfuseOptions->SetPropertyValue("exposureWeight", 1.0);
    m_enfuseOptions->SetPropertyValue("saturationWeight", 0.0);
    m_enfuseOptions->SetPropertyValue("contrastWeight", 0.0);
    m_enfuseOptions->SetPropertyValue("entropyWeight", 0.0);
    m_enfuseOptions->SetPropertyValue("hardMask", false);
    m_enfuseOptions->SetPropertyValue("levels", 0);
    m_enfuseOptions->SetPropertyValue("blendColorspace", 0);
    m_enfuseOptions->SetPropertyValue("wrapMode", 0);
    m_enfuseOptions->SetPropertyValue("exposureOptimum", 0.5);
    m_enfuseOptions->SetPropertyValue("exposureWidth", 0.2);
    m_enfuseOptions->SetPropertyValue("contrastEdgeScale", 0.0);
    m_enfuseOptions->SetPropertyValue("contrastMinCurvature", 0.0);
    m_enfuseOptions->SetPropertyValue("contrastWindowSize", 5);
    m_enfuseOptions->SetPropertyValue("entropyLowerCutoff", 0.0);
    m_enfuseOptions->SetPropertyValue("entropyUpperCutoff", 100.0);
    m_enfuseOptions->SetPropertyValue("entropyWindowSize", 3);
    m_enfuseOptions->SetPropertyValue("exposureLowerCutoff", 0.0);
    m_enfuseOptions->SetPropertyValue("exposureUpperCutoff", 100.0);
    m_enfuseOptions->SetPropertyValue("exposureWeightFunction", 0);
    m_enfuseOptions->SetPropertyValue("grayProjector", 1);
}

void EnfusePanel::OnGeneratePreview(wxCommandEvent& e)
{
    // create temp file name, set extension to tif
    m_outputFilenames.resize(2);
    wxFileName tempfile(wxFileName::CreateTempFileName(HuginQueue::GetConfigTempDir(wxConfig::Get()) + "he"));
    m_outputFilenames[1] = tempfile.GetFullPath();
    tempfile.SetExt("tif");
    m_outputFilenames[0] = tempfile.GetFullPath();
    m_cleanupOutput = true;
    // get command line and execute
    ExecuteEnfuse();
}

void EnfusePanel::ExecuteEnfuse()
{
    wxString cmd = GetEnfuseCommandLine();
    if (!cmd.IsEmpty())
    {
        EnableOutputButtons(false);
        m_logWindow->ClearOutput();
        cmd = HuginQueue::wxEscapeFilename(HuginQueue::GetExternalProgram(wxConfigBase::Get(), wxFileName(wxStandardPaths::Get().GetExecutablePath()).GetPath(wxPATH_GET_VOLUME | wxPATH_GET_SEPARATOR), "enfuse")) + cmd;
        m_logWindow->AddString(cmd);
        m_logWindow->ExecWithRedirect(cmd);
    }
}

void EnfusePanel::ExecuteEnfuseExiftool()
{
    wxString cmd = GetEnfuseCommandLine();
    if (!cmd.IsEmpty())
    {
        EnableOutputButtons(false);
        m_logWindow->ClearOutput();
        HuginQueue::CommandQueue* queue = new HuginQueue::CommandQueue();
        wxString exePath = wxFileName(wxStandardPaths::Get().GetExecutablePath()).GetPath(wxPATH_GET_VOLUME | wxPATH_GET_SEPARATOR);
        queue->push_back(new HuginQueue::NormalCommand(HuginQueue::GetExternalProgram(wxConfig::Get(), exePath, "enfuse"), cmd, _("Merging images") + " (" + cmd + ")"));
        // get first image
        long index = -1;
        for (long i = 0; i < m_fileListCtrl->GetItemCount(); ++i)
        {
            if (m_fileListCtrl->IsItemChecked(i))
            {
                index = i;
                break;
            };
        };
        wxString exiftoolArgs(" -overwrite_original -tagsfromfile " + HuginQueue::wxEscapeFilename(m_files[index]));
        exiftoolArgs.Append(" -all:all --thumbnail --thumbnailimage --xposition --yposition --imagefullwidth --imagefullheight ");
        exiftoolArgs.Append(HuginQueue::wxEscapeFilename(m_outputFilenames[0]));
        queue->push_back(new HuginQueue::OptionalCommand(HuginQueue::GetExternalProgram(wxConfig::Get(), exePath, "exiftool"), exiftoolArgs, _("Updating EXIF")));
        m_logWindow->ExecQueue(queue);
    };
}

void EnfusePanel::OnGenerateOutput(wxCommandEvent& e)
{
    if (m_files.IsEmpty())
    {
        wxBell();
        return;
    };
    wxConfigBase* config = wxConfigBase::Get();
    wxString path = config->Read("/actualPath", "");
    wxFileDialog dlg(this, _("Save output"), path, wxEmptyString, GetMainImageFilters(), wxFD_SAVE | wxFD_OVERWRITE_PROMPT, wxDefaultPosition);
    dlg.SetDirectory(path);

    // remember the image extension
    wxString img_ext;
    if (config->HasEntry("lastImageType"))
    {
        img_ext = config->Read("lastImageType").c_str();
    }
    if (img_ext == "jpg")
    {
        dlg.SetFilterIndex(0);
    }
    else
    {
        if (img_ext == "tiff")
        {
            dlg.SetFilterIndex(1);
        }
        else
        {
            if (img_ext == "png")
            {
                dlg.SetFilterIndex(2);
            };
        };
    };
    wxFileName outputfilename(m_files[0]);
    outputfilename.SetName(outputfilename.GetName() + "_stacked");
    dlg.SetFilename(outputfilename.GetFullPath());
    // call the file dialog
    if (dlg.ShowModal() == wxID_OK)
    {
        m_outputFilenames.resize(1);
        m_outputFilenames[0] = dlg.GetPath();
        // save the current path to config
        config->Write("/actualPath", dlg.GetDirectory());
        // save the image extension
        switch (dlg.GetFilterIndex())
        {
            case 0:
                config->Write("lastImageType", "jpg");
                break;
            case 1:
                config->Write("lastImageType", "tiff");
                break;
            case 2:
                config->Write("lastImageType", "png");
                break;
        };
        m_cleanupOutput = false;
        ExecuteEnfuseExiftool();
    };
}

void EnfusePanel::OnZoom(wxCommandEvent& e)
{
    double factor;
    switch (e.GetSelection())
    {
        case 0:
            factor = 1;
            break;
        case 1:
            // fit to window
            factor = 0;
            break;
        case 2:
            factor = 2;
            break;
        case 3:
            factor = 1.5;
            break;
        case 4:
            factor = 0.75;
            break;
        case 5:
            factor = 0.5;
            break;
        case 6:
            factor = 0.25;
            break;
        default:
            DEBUG_ERROR("unknown scale factor");
            factor = 1;
    }
    m_preview->setScale(factor);
}

void EnfusePanel::OnProcessFinished(wxCommandEvent& e)
{
    wxFileName output(m_outputFilenames[0]);
    if (output.FileExists() && output.GetSize()>0)
    {
        m_preview->setImage(output.GetFullPath());
    };
    EnableOutputButtons(true);
    if (m_cleanupOutput && output.FileExists())
    {
        // cleanup up preview files
        for (const auto& f : m_outputFilenames)
        {
            wxRemoveFile(f);
        };
    };
}

void EnfusePanel::PopulateEnfuseOptions()
{
    // all weight options, with spin control
    wxPGProperty* prop = m_enfuseOptions->Append(new wxFloatProperty("Exposure weight", "exposureWeight", 1));
    prop->SetEditor(wxPGEditor_SpinCtrl);
    prop->SetAttribute(wxPG_ATTR_MIN, 0);
    prop->SetAttribute(wxPG_ATTR_MAX, 1);
    prop->SetAttribute(wxPG_ATTR_SPINCTRL_STEP, 0.05);
    prop = m_enfuseOptions->Append(new wxFloatProperty("Saturation weight", "saturationWeight", 0));
    prop->SetEditor(wxPGEditor_SpinCtrl);
    prop->SetAttribute(wxPG_ATTR_MIN, 0);
    prop->SetAttribute(wxPG_ATTR_MAX, 1);
    prop->SetAttribute(wxPG_ATTR_SPINCTRL_STEP, 0.05);
    prop = m_enfuseOptions->Append(new wxFloatProperty("Contrast weight", "contrastWeight", 0));
    prop->SetEditor(wxPGEditor_SpinCtrl);
    prop->SetAttribute(wxPG_ATTR_MIN, 0);
    prop->SetAttribute(wxPG_ATTR_MAX, 1);
    prop = m_enfuseOptions->Append(new wxFloatProperty("Entropy weight", "entropyWeight", 0));
    prop->SetEditor(wxPGEditor_SpinCtrl);
    prop->SetAttribute(wxPG_ATTR_MIN, 0);
    prop->SetAttribute(wxPG_ATTR_MAX, 1);
    prop->SetAttribute(wxPG_ATTR_SPINCTRL_STEP, 0.05);
    // hard / soft mask
    m_enfuseOptions->Append(new wxBoolProperty("Hard mask", "hardMask", false));
    // general options
    prop = m_enfuseOptions->Append(new wxPropertyCategory(_("General"), "general"));
    prop = m_enfuseOptions->Append(new wxIntProperty("Levels", "levels", 0));
    prop->SetEditor(wxPGEditor_SpinCtrl);
    prop->SetAttribute(wxPG_ATTR_MIN, -29);
    prop->SetAttribute(wxPG_ATTR_MAX, 29);
    prop->SetAttribute(wxPG_ATTR_SPINCTRL_STEP, 1);
    wxArrayString blendColorspaces;
    blendColorspaces.Add("Auto");
    blendColorspaces.Add("Identity (RGB)");
    blendColorspaces.Add("CIELab");
    blendColorspaces.Add("CIELuv");
    blendColorspaces.Add("CIECAM02");
    m_enfuseOptions->Append(new wxEnumProperty("Blend colorspace", "blendColorspace", blendColorspaces));
    wxArrayString wrapMode;
    wrapMode.Add("None");
    wrapMode.Add("Horizontal");
    wrapMode.Add("Vertical");
    wrapMode.Add("Both");
    m_enfuseOptions->Append(new wxEnumProperty("Wrap mode", "wrapMode", wrapMode));
    m_enfuseOptions->Collapse("general");
    m_enfuseOptions->Append(new wxPropertyCategory(_("Fusions options"), "fusionOptions"));
    prop = m_enfuseOptions->Append(new wxFloatProperty("Exposure optimum", "exposureOptimum", 0.5));
    prop->SetEditor(wxPGEditor_SpinCtrl);
    prop->SetAttribute(wxPG_ATTR_MIN, 0);
    prop->SetAttribute(wxPG_ATTR_MAX, 1);
    prop->SetAttribute(wxPG_ATTR_SPINCTRL_STEP, 0.05);
    prop = m_enfuseOptions->Append(new wxFloatProperty("Exposure width", "exposureWidth", 0.2));
    prop->SetEditor(wxPGEditor_SpinCtrl);
    prop->SetAttribute(wxPG_ATTR_MIN, 0);
    prop->SetAttribute(wxPG_ATTR_MAX, 1);
    prop->SetAttribute(wxPG_ATTR_SPINCTRL_STEP, 0.05);
    prop = m_enfuseOptions->Append(new wxFloatProperty("Contrast edge scale", "contrastEdgeScale", 0));
    prop->SetEditor(wxPGEditor_SpinCtrl);
    prop->SetAttribute(wxPG_ATTR_MIN, 0);
    prop->SetAttribute(wxPG_ATTR_MAX, 5);
    prop->SetAttribute(wxPG_ATTR_SPINCTRL_STEP, 0.1);
    prop = m_enfuseOptions->Append(new wxFloatProperty("Contrast min curvature", "contrastMinCurvature", 0));
    prop->SetEditor(wxPGEditor_SpinCtrl);
    prop->SetAttribute(wxPG_ATTR_MIN, 0);
    prop->SetAttribute(wxPG_ATTR_MAX, 50);
    prop->SetAttribute(wxPG_ATTR_SPINCTRL_STEP, 0.5);
    prop = m_enfuseOptions->Append(new wxIntProperty("Contrast window size", "contrastWindowSize", 5));
    prop->SetEditor(wxPGEditor_SpinCtrl);
    prop->SetAttribute(wxPG_ATTR_MIN, 3);
    prop->SetAttribute(wxPG_ATTR_MAX, 30);
    prop->SetAttribute(wxPG_ATTR_SPINCTRL_STEP, 1);
    prop = m_enfuseOptions->Append(new wxFloatProperty("Entropy lower cutoff", "entropyLowerCutoff", 0));
    prop->SetEditor(wxPGEditor_SpinCtrl);
    prop->SetAttribute(wxPG_ATTR_MIN, 0);
    prop->SetAttribute(wxPG_ATTR_MAX, 100);
    prop->SetAttribute(wxPG_ATTR_SPINCTRL_STEP, 0.5);
    prop = m_enfuseOptions->Append(new wxFloatProperty("Entropy higher cutoff", "entropyUpperCutoff", 100));
    prop->SetEditor(wxPGEditor_SpinCtrl);
    prop->SetAttribute(wxPG_ATTR_MIN, 0);
    prop->SetAttribute(wxPG_ATTR_MAX, 100);
    prop->SetAttribute(wxPG_ATTR_SPINCTRL_STEP, 0.5);
    prop = m_enfuseOptions->Append(new wxIntProperty("Entropy window size", "entropyWindowSize", 3));
    prop->SetEditor(wxPGEditor_SpinCtrl);
    prop->SetAttribute(wxPG_ATTR_MIN, 3);
    prop->SetAttribute(wxPG_ATTR_MAX, 7);
    prop->SetAttribute(wxPG_ATTR_SPINCTRL_STEP, 1);
    prop = m_enfuseOptions->Append(new wxFloatProperty("Expoure lower cutoff", "exposureLowerCutoff", 0));
    prop->SetEditor(wxPGEditor_SpinCtrl);
    prop->SetAttribute(wxPG_ATTR_MIN, 0);
    prop->SetAttribute(wxPG_ATTR_MAX, 100);
    prop->SetAttribute(wxPG_ATTR_SPINCTRL_STEP, 0.5);
    prop = m_enfuseOptions->Append(new wxFloatProperty("Exposure higher cutoff", "exposureUpperCutoff", 100));
    prop->SetEditor(wxPGEditor_SpinCtrl);
    prop->SetAttribute(wxPG_ATTR_MIN, 0);
    prop->SetAttribute(wxPG_ATTR_MAX, 100);
    prop->SetAttribute(wxPG_ATTR_SPINCTRL_STEP, 0.5);
    wxArrayString exposureWeightFunction;
    exposureWeightFunction.Add("Gaussian");
    exposureWeightFunction.Add("Lorentzian");
    exposureWeightFunction.Add("Half-sine");
    exposureWeightFunction.Add("Full-sine");
    exposureWeightFunction.Add("Bi-square");
    m_enfuseOptions->Append(new wxEnumProperty("Exposure weight function", "exposureWeightFunction", exposureWeightFunction));
    wxArrayString grayProjector;
    grayProjector.Add("anti-value"); // index 0
    grayProjector.Add("Average"); // index 1
    grayProjector.Add("L-channel from Lab (gamma=1)");  // index 2
    grayProjector.Add("L-channel from Lab (gamma corrected)"); // index 3
    grayProjector.Add("Lightness"); // index 4
    grayProjector.Add("Luminance"); // index 5
    grayProjector.Add("Value from HSV"); // index 6
    // missing: channelMixel
    prop = m_enfuseOptions->Append(new wxEnumProperty("Gray projector", "grayProjector", grayProjector));
    m_enfuseOptions->SetPropertyValue("grayProjector", 1);
    // if you add new options also update GetEnfuseOptions() and OnResetSetting(..)
}

wxString EnfusePanel::GetEnfuseOptions()
{
    wxString commandline("--verbose ");
    double doubleValue=m_enfuseOptions->GetPropertyValueAsDouble("exposureWeight");
    if (doubleValue != 1)
    {
        commandline.Append(" --exposure-weight=" + wxString::FromCDouble(doubleValue));
    };
    doubleValue = m_enfuseOptions->GetPropertyValueAsDouble("saturationWeight");
    if (doubleValue != 0)
    {
        commandline.Append(" --saturation-weight=" + wxString::FromCDouble(doubleValue));
    };
    doubleValue = m_enfuseOptions->GetPropertyValueAsDouble("contrastWeight");
    if (doubleValue != 0)
    {
        commandline.Append(" --contrast-weight=" + wxString::FromCDouble(doubleValue));
    };
    doubleValue = m_enfuseOptions->GetPropertyValueAsDouble("entropyWeight");
    if (doubleValue != 0)
    {
        commandline.Append(" --entropy-weight=" + wxString::FromCDouble(doubleValue));
    };
    bool boolVal = m_enfuseOptions->GetPropertyValueAsBool("hardMask");
    if (boolVal)
    {
        commandline.Append(" --hard-mask");
    };
    int intValue = m_enfuseOptions->GetPropertyValueAsInt("levels");
    if (intValue != 0)
    {
        commandline.Append(wxString::Format(" --level=%d", intValue));
    };
    intValue = m_enfuseOptions->GetPropertyValueAsInt("blendColorspace");
    switch (intValue)
    {
        case 1:
            commandline.Append(" --blend-colorspace=identity");
            break;
        case 2:
            commandline.Append(" --blend-colorspace=cielab");
            break;
        case 3:
            commandline.Append(" --blend-colorspace=cieluv");
            break;
        case 4:
            commandline.Append(" --blend-colorspace=ciecam");
            break;
        default:
        case 0:
            // do nothing
            break;
    };
    intValue = m_enfuseOptions->GetPropertyValueAsInt("wrapMode");
    switch (intValue)
    {
        case 1:
            commandline.Append(" --wrap=horizontal");
            break;
        case 2:
            commandline.Append(" --wrap=vertical");
            break;
        case 3:
            commandline.Append(" --wrap=both ");
            break;
        case 0:
        default:
            break;
    };
    doubleValue = m_enfuseOptions->GetPropertyValueAsDouble("exposureOptimum");
    if (doubleValue != 0.5)
    {
        commandline.Append(" --exposure-optimum=" + wxString::FromCDouble(doubleValue));
    };
    doubleValue = m_enfuseOptions->GetPropertyValueAsDouble("exposureWidth");
    if (doubleValue != 0.2)
    {
        commandline.Append(" --exposure-width=" + wxString::FromCDouble(doubleValue));
    };
    doubleValue = m_enfuseOptions->GetPropertyValueAsDouble("contrastEdgeScale");
    if (doubleValue != 0)
    {
        commandline.Append(" --contrast-edge-scale=" + wxString::FromCDouble(doubleValue));
    };
    doubleValue = m_enfuseOptions->GetPropertyValueAsDouble("contrastMinCurvature");
    if (doubleValue != 0)
    {
        commandline.Append(" --contrast-min-curvature=" + wxString::FromCDouble(doubleValue) + "%");
    };
    intValue = m_enfuseOptions->GetPropertyValueAsInt("contrastWindowSize");
    if (intValue != 5)
    {
        commandline.Append(wxString::Format(" --contrast-window-size=%d", intValue));
    };
    // entropy cutoff
    doubleValue = m_enfuseOptions->GetPropertyValueAsDouble("entropyLowerCutoff");
    double doubleValue2 = m_enfuseOptions->GetPropertyValueAsDouble("entropyUpperCutoff");
    if (doubleValue > 0 || doubleValue2 < 100)
    {
        commandline.Append(" --entropy-cutoff=" + wxString::FromCDouble(doubleValue) + "%");
        if (doubleValue2 < 100)
        {
            commandline.Append(":" + wxString::FromCDouble(doubleValue2) + "%");
        };
    };
    intValue = m_enfuseOptions->GetPropertyValueAsInt("entropyWindowSize");
    if (intValue != 3)
    {
        commandline.Append(wxString::Format(" --entropy-window-size=%d", intValue));
    };
    // exposure cutoff
    doubleValue = m_enfuseOptions->GetPropertyValueAsDouble("exposureLowerCutoff");
    doubleValue2 = m_enfuseOptions->GetPropertyValueAsDouble("exposureUpperCutoff");
    if (doubleValue > 0 || doubleValue2 < 100)
    {
        commandline.Append(" --exposure-cutoff=" + wxString::FromCDouble(doubleValue) + "%");
        if (doubleValue2 < 100)
        {
            commandline.Append(":" + wxString::FromCDouble(doubleValue2) + "%");
        };
    };
    // exposure weight function
    intValue = m_enfuseOptions->GetPropertyValueAsInt("exposureWeightFunction");
    switch (intValue)
    {
        case 1:
            commandline.Append(" --exposure-weight-function=lorentz");
            break;
        case 2:
            commandline.Append(" --exposure-weight-function=halfsine");
            break;
        case 3:
            commandline.Append(" --exposure-weight-function=fullsine");
            break;
        case 4:
            commandline.Append(" --exposure-weight-function=bisquare");
            break;
        case 0:
        default:
            break;
    };
    // gray projector
    intValue = m_enfuseOptions->GetPropertyValueAsInt("grayProjector");
    switch (intValue)
    {
        case 0:
            commandline.Append(" --gray-projector=anti-value");
            break;
        case 2:
            commandline.Append(" --gray-projector=al-star");
            break;
        case 3:
            commandline.Append(" --gray-projector=pl-star");
            break;
        case 4:
            commandline.Append(" --gray-projector=lightness");
            break;
        case 5:
            commandline.Append(" --gray-projector=luminance");
            break;
        case 6:
            commandline.Append(" --gray-projector=value");
            break;
        case 1:
        default:
            break;
    };
    return commandline;
}

wxString EnfusePanel::GetEnfuseCommandLine()
{
    wxString commandline(" --output=" + hugin_utils::wxQuoteFilename(m_outputFilenames[0]));
    // add options from control
    commandline.Append(" ");
    commandline.Append(GetEnfuseOptions());
    // now build image list
    wxArrayInt selectedFiles;
    for (int i = 0; i < m_fileListCtrl->GetItemCount(); ++i)
    {
        if (m_fileListCtrl->IsItemChecked(i))
        {
            selectedFiles.push_back(i);
        };
    };
    if (selectedFiles.IsEmpty())
    {
        hugin_utils::HuginMessageBox(_("Please activate at least one file."), _("Hugin_toolbox"), wxOK | wxOK_DEFAULT | wxICON_WARNING, this);
        return wxEmptyString;
    }
    for (int i = 0; i < selectedFiles.size(); ++i)
    {
        commandline.Append(" ");
        commandline.Append(hugin_utils::wxQuoteFilename(m_files[selectedFiles[i]]));
    }
    return commandline;
}

void EnfusePanel::EnableFileButtons()
{
    // enable/disable button according to selected files
    XRCCTRL(*this, "enfuse_remove_file", wxButton)->Enable(m_fileListCtrl->GetSelectedItemCount() >= 1);
    XRCCTRL(*this, "enfuse_create_file", wxButton)->Enable(m_fileListCtrl->GetSelectedItemCount() == 1);
}

long EnfusePanel::GetCheckedItemCount() const
{
    // count checked items
    long count = 0;
    for (int i = 0; i < m_fileListCtrl->GetItemCount(); ++i)
    {
        if (m_fileListCtrl->IsItemChecked(i))
        {
            ++count;
        };
    };
    return count;
}

void EnfusePanel::EnableOutputButtons(bool enable)
{
    XRCCTRL(*this, "enfuse_preview", wxButton)->Enable(enable);
    XRCCTRL(*this, "enfuse_enfuse", wxButton)->Enable(enable);

}

void EnfusePanel::CleanUpTempFiles()
{
    for (const auto& f : m_tempFiles)
    {
        wxRemoveFile(f);
    };
}

IMPLEMENT_DYNAMIC_CLASS(EnfusePanel, wxPanel)
