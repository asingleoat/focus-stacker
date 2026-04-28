// -*- c-basic-offset: 4 -*-

/** @file PreferencesDialog.cpp
 *
 *  @brief implementation of PreferencesDialog Class
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
#include "wx/listbook.h"
#include <wx/stdpaths.h> 
#include "panoinc.h"

#include "base_wx/wxPlatform.h"
#include "base_wx/LensTools.h"
#include "base_wx/wxutils.h"

#include "hugin/huginApp.h"
#include "hugin/config_defaults.h"
#include "hugin/PreferencesDialog.h"
#include "hugin/CPDetectorDialog.h"
#include "hugin/MainFrame.h"
#include "hugin/EditOutputIniDialog.h"
#include "base_wx/huginConfig.h"

// validators are working different somehow...
//#define MY_STR_VAL(id, filter) { XRCCTRL(*this, "prefs_" #id, wxTextCtrl)->SetValidator(wxTextValidator(filter, &id)); }
//#define MY_SPIN_VAL(id) {     XRCCTRL(*this, "prefs_" #id, wxSpinCtrl)->SetValidator(wxGenericValidator(&id)); }

#define MY_STR_VAL(id, val) { XRCCTRL(*this, id, wxTextCtrl)->SetValue(val); };
#define MY_SPIN_VAL(id, val) { XRCCTRL(*this, id, wxSpinCtrl)->SetValue(val); };
#define MY_BOOL_VAL(id, val) { XRCCTRL(*this, id, wxCheckBox)->SetValue(val); };
#define MY_CHOICE_VAL(id, val) { XRCCTRL(*this, id, wxChoice)->SetSelection(val); };
#define MY_STATIC_VAL(id, val) { XRCCTRL(*this, id, wxStaticText)->SetLabel(val); };

#define MY_G_STR_VAL(id)  XRCCTRL(*this, id, wxTextCtrl)->GetValue()
#define MY_G_SPIN_VAL(id)  XRCCTRL(*this, id, wxSpinCtrl)->GetValue()
#define MY_G_BOOL_VAL(id)  XRCCTRL(*this, id, wxCheckBox)->GetValue()
#define MY_G_CHOICE_VAL(id)  XRCCTRL(*this, id, wxChoice)->GetSelection()

PreferencesDialog::PreferencesDialog(wxWindow* parent)
//: wxDialog(parent, -1, _("Preferences - hugin"))
{
    DEBUG_TRACE("");
    // load our children. some children might need special
    // initialization. this will be done later.
    wxXmlResource::Get()->LoadDialog(this, parent, "pref_dialog");

    // Custom setup ( stuff that can not be done in XRC )
    XRCCTRL(*this, "prefs_ft_RotationStartAngle", wxSpinCtrl)->SetRange(-180,0);
    XRCCTRL(*this, "prefs_ft_RotationStopAngle", wxSpinCtrl)->SetRange(0,180);
    XRCCTRL(*this, "prefs_ass_nControlPoints", wxSpinCtrl)->SetRange(3,3000);

    wxChoice* lang_choice = XRCCTRL(*this, "prefs_gui_language", wxChoice);
    // add languages to choice
    long* lp = new long;
    *lp = wxLANGUAGE_DEFAULT;
    lang_choice->Append(_("System default"), lp);
    lp = new long;
    *lp = wxLANGUAGE_BASQUE;
    lang_choice->Append(_("Basque"), lp);
    /** outdated
    lp = new long;
    *lp = wxLANGUAGE_BULGARIAN;
    lang_choice->Append(_("Bulgarian"), lp);
    */
    lp = new long;
    *lp = wxLANGUAGE_CATALAN;
    lang_choice->Append(_("Catalan"), lp);
    lp = new long;
    *lp = wxLANGUAGE_CHINESE_SIMPLIFIED;
    lang_choice->Append(_("Chinese (Simplified)"), lp);
    lp = new long;
    *lp = wxLANGUAGE_CHINESE_TRADITIONAL;
    lang_choice->Append(_("Chinese (Traditional)"), lp);
    lp = new long;
    *lp = wxLANGUAGE_CZECH;
    lang_choice->Append(_("Czech"), lp);
    lp = new long;
    *lp = wxLANGUAGE_DANISH;
    lang_choice->Append(_("Danish"), lp);
    lp = new long;
    *lp = wxLANGUAGE_DUTCH;
    lang_choice->Append(_("Dutch"), lp);
    lp = new long;
    *lp = wxLANGUAGE_ENGLISH;
    lang_choice->Append(_("English"), lp);
    lp = new long;
    *lp = wxLANGUAGE_FRENCH;
    lang_choice->Append(_("French"), lp);
    lp = new long;
    *lp = wxLANGUAGE_GERMAN;
    lang_choice->Append(_("German"), lp);
    lp = new long;
    *lp = wxLANGUAGE_HUNGARIAN;
    lang_choice->Append(_("Hungarian"), lp);
    lp = new long;
    *lp = wxLANGUAGE_ITALIAN;
    lang_choice->Append(_("Italian"), lp);
    lp = new long;
    *lp = wxLANGUAGE_JAPANESE;
    lang_choice->Append(_("Japanese"), lp);
    /** outdated
    lp = new long;
    *lp = wxLANGUAGE_KOREAN;
    lang_choice->Append(_("Korean"), lp);
    */
    lp = new long;
    *lp = wxLANGUAGE_POLISH;
    lang_choice->Append(_("Polish"), lp);
    lp = new long;
    *lp = wxLANGUAGE_PORTUGUESE_BRAZILIAN;
    lang_choice->Append(_("Portuguese (Brazilian)"), lp);
    lp = new long;
    *lp = wxLANGUAGE_RUSSIAN;
    lang_choice->Append(_("Russian"), lp);
    lp = new long;
    *lp = wxLANGUAGE_SLOVAK;
    lang_choice->Append(_("Slovak"), lp);
    /** outdated
    lp = new long;
    *lp = wxLANGUAGE_SLOVENIAN;
    lang_choice->Append(_("Slovenian"), lp);
    */
    lp = new long;
    *lp = wxLANGUAGE_SPANISH;
    lang_choice->Append(_("Spanish"), lp);
    lp = new long;
    *lp = wxLANGUAGE_SWEDISH;
    lang_choice->Append(_("Swedish"), lp);
    /** outdated
    lp = new long;
    *lp = wxLANGUAGE_UKRAINIAN;
    lang_choice->Append(_("Ukrainian"), lp);
    */
    lp = new long;
    *lp = wxLANGUAGE_FINNISH;
    lang_choice->Append(_("Finnish"), lp);
    lp = new long;
    *lp = wxLANGUAGE_VALENCIAN;
    lang_choice->Append(_("Valencian (Southern Catalan)"), lp);
    lang_choice->SetSelection(0);

    // enable auto completion on raw converter executables
    XRCCTRL(*this, "pref_raw_dcraw_exe", wxTextCtrl)->AutoCompleteFileNames();
    XRCCTRL(*this, "pref_raw_rt_exe", wxTextCtrl)->AutoCompleteFileNames();
    XRCCTRL(*this, "pref_raw_darktable_exe", wxTextCtrl)->AutoCompleteFileNames();

    // default blender settings
    FillBlenderList(XRCCTRL(*this, "pref_default_blender", wxChoice));

    wxStaticText* preview=XRCCTRL(*this, "prefs_project_filename_preview", wxStaticText);
    preview->SetWindowStyle(preview->GetWindowStyle() | wxST_ELLIPSIZE_START);
    preview=XRCCTRL(*this, "prefs_output_filename_preview", wxStaticText);
    preview->SetWindowStyle(preview->GetWindowStyle() | wxST_ELLIPSIZE_START);
    // enable auto-completion
    XRCCTRL(*this, "prefs_misc_tempdir", wxTextCtrl)->AutoCompleteDirectories();
    XRCCTRL(*this, "pref_exiftool_argfile", wxTextCtrl)->AutoCompleteFileNames();
    XRCCTRL(*this, "pref_exiftool_argfile2", wxTextCtrl)->AutoCompleteFileNames();
    XRCCTRL(*this, "prefs_enblend_EnblendExe", wxTextCtrl)->AutoCompleteFileNames();
    XRCCTRL(*this, "prefs_enblend_EnfuseExe", wxTextCtrl)->AutoCompleteFileNames();
    // load autopano settings
    wxConfigBase* cfg = wxConfigBase::Get();
    m_CPDetectorList = XRCCTRL(*this, "pref_cpdetector_list", wxListBox);
    m_CPDetectorList->Bind(wxEVT_LEFT_DCLICK, [this](wxMouseEvent& e) {
        wxCommandEvent evt; this->OnCPDetectorEdit(evt); });
    cpdetector_config_edit.Read(cfg);

#if defined __APPLE__ && defined __aarch64__
    {
        // disable GPU remapping checkbox on ARM Macs, GPU code is not working on these systems
        wxCheckBox* gpuCheckBox = XRCCTRL(*this, "prefs_nona_useGpu", wxCheckBox);
        gpuCheckBox->Disable();
        gpuCheckBox->SetValue(false);
        cfg->Write("/Nona/UseGPU", false);
        gpuCheckBox->Hide();
    }
#endif

    // Load configuration values from wxConfig
    UpdateDisplayData(0);

    Update();
    GetSizer()->SetSizeHints(this);
    // bind all event handler for buttons and boxes
    Bind(wxEVT_BUTTON, &PreferencesDialog::OnEnblendExe, this, XRCID("prefs_enblend_select"));
    Bind(wxEVT_BUTTON, &PreferencesDialog::OnEnfuseExe, this, XRCID("prefs_enblend_enfuse_select"));
    Bind(wxEVT_BUTTON, &PreferencesDialog::OnDcrawExe, this, XRCID("pref_raw_dcraw_exe_select"));
    Bind(wxEVT_BUTTON, &PreferencesDialog::OnRawTherapeeExe, this, XRCID("pref_raw_rt_exe_select"));
    Bind(wxEVT_BUTTON, &PreferencesDialog::OnDarktableExe, this, XRCID("pref_raw_darktable_exe_select"));
    Bind(wxEVT_BUTTON, &PreferencesDialog::OnExifArgfileChoose, this, XRCID("pref_exiftool_argfile_choose"));
    Bind(wxEVT_BUTTON, &PreferencesDialog::OnExifArgfileEdit, this, XRCID("pref_exiftool_argfile_edit"));
    Bind(wxEVT_BUTTON, &PreferencesDialog::OnExifArgfile2Choose, this, XRCID("pref_exiftool_argfile2_choose"));
    Bind(wxEVT_BUTTON, &PreferencesDialog::OnExifArgfile2Edit, this, XRCID("pref_exiftool_argfile2_edit"));
    Bind(wxEVT_CHECKBOX, &PreferencesDialog::OnExifTool, this, XRCID("pref_exiftool_metadata"));
    Bind(wxEVT_CHECKBOX, &PreferencesDialog::OnRotationCheckBox, this, XRCID("prefs_ft_RotationSearch"));
    Bind(wxEVT_CHECKBOX, &PreferencesDialog::OnCustomEnblend, this, XRCID("prefs_enblend_Custom"));
    Bind(wxEVT_CHECKBOX, &PreferencesDialog::OnCustomEnfuse, this, XRCID("prefs_enblend_enfuseCustom"));
    Bind(wxEVT_CHECKBOX, &PreferencesDialog::OnUserDefinedOutputOptionsCheckBox, this, XRCID("pref_ass_output"));
    Bind(wxEVT_BUTTON, &PreferencesDialog::OnChangeUserDefinedOutputOptions, this, XRCID("pref_ass_change_output"));
    Bind(wxEVT_BUTTON, &PreferencesDialog::OnCPDetectorAdd, this, XRCID("pref_cpdetector_new"));
    Bind(wxEVT_BUTTON, &PreferencesDialog::OnCPDetectorEdit, this, XRCID("pref_cpdetector_edit"));
    Bind(wxEVT_BUTTON, &PreferencesDialog::OnCPDetectorDelete, this, XRCID("pref_cpdetector_del"));
    Bind(wxEVT_BUTTON, &PreferencesDialog::OnCPDetectorMoveUp, this, XRCID("pref_cpdetector_moveup"));
    Bind(wxEVT_BUTTON, &PreferencesDialog::OnCPDetectorMoveDown, this, XRCID("pref_cpdetector_movedown"));
    Bind(wxEVT_BUTTON, &PreferencesDialog::OnCPDetectorDefault, this, XRCID("pref_cpdetector_default"));
    Bind(wxEVT_BUTTON, &PreferencesDialog::OnCPDetectorLoad, this, XRCID("pref_cpdetector_load"));
    Bind(wxEVT_BUTTON, &PreferencesDialog::OnCPDetectorSave, this, XRCID("pref_cpdetector_save"));
    Bind(wxEVT_CHOICE, &PreferencesDialog::OnFileFormatChanged, this, XRCID("pref_ldr_output_file_format"));
    Bind(wxEVT_CHOICE, &PreferencesDialog::OnProcessorChanged, this, XRCID("pref_processor_gui"));
    Bind(wxEVT_CHOICE, &PreferencesDialog::OnBlenderChanged, this, XRCID("pref_default_blender"));
    Bind(wxEVT_TEXT, &PreferencesDialog::OnUpdateProjectFilename, this, XRCID("prefs_project_filename"));
    Bind(wxEVT_TEXT, &PreferencesDialog::OnUpdateOutputFilename, this, XRCID("prefs_output_filename"));

    // only enable bundled if the build is actually bundled.
#if defined __WXMSW__ || defined MAC_SELF_CONTAINED_BUNDLE

#else
    MY_BOOL_VAL("prefs_enblend_Custom", HUGIN_ENBLEND_EXE_CUSTOM);
    XRCCTRL(*this, "prefs_enblend_Custom", wxCheckBox)->Hide();
    cfg->Write("/Enblend/Custom", HUGIN_ENBLEND_EXE_CUSTOM);

    MY_BOOL_VAL("prefs_enblend_enfuseCustom", HUGIN_ENFUSE_EXE_CUSTOM);
    XRCCTRL(*this, "prefs_enblend_enfuseCustom", wxCheckBox)->Hide();
    cfg->Write("/Enfuse/Custom", HUGIN_ENFUSE_EXE_CUSTOM);
#endif

    hugin_utils::RestoreFramePosition(this, "PreferencesDialog");
    // event handler for default buttons
    Bind(wxEVT_BUTTON, &PreferencesDialog::OnOk, this, wxID_OK);
    Bind(wxEVT_BUTTON, &PreferencesDialog::OnHelp, this, wxID_HELP);
    Bind(wxEVT_BUTTON, &PreferencesDialog::OnRestoreDefaults, this, XRCID("prefs_defaults"));
}


PreferencesDialog::~PreferencesDialog()
{
    DEBUG_TRACE("begin dtor");

    hugin_utils::StoreFramePosition(this, "PreferencesDialog");

    // delete custom list data
    wxChoice* lang_choice = XRCCTRL(*this, "prefs_gui_language", wxChoice);
    for (int i = 0; i < (int) lang_choice->GetCount(); i++)
    {
        delete static_cast<long*>(lang_choice->GetClientData(i));
    }

    DEBUG_TRACE("end dtor");
}

void PreferencesDialog::OnOk(wxCommandEvent& e)
{
    UpdateConfigData();
    this->EndModal(wxOK);
}

void PreferencesDialog::OnHelp(wxCommandEvent& e)
{
    MainFrame::Get()->DisplayHelp("Hugin_Preferences.html");
};

void PreferencesDialog::OnRotationCheckBox(wxCommandEvent& e)
{
    EnableRotationCtrls(e.IsChecked());
}

void PreferencesDialog::OnEnblendExe(wxCommandEvent& e)
{
    wxFileDialog dlg(this,_("Select Enblend"),
                     wxEmptyString, HUGIN_ENBLEND_EXE,
#ifdef __WXMSW__
                     _("Executables (*.exe)|*.exe"),
#else
                     "*",
#endif
                     wxFD_OPEN, wxDefaultPosition);
    if (dlg.ShowModal() == wxID_OK)
    {
        XRCCTRL(*this, "prefs_enblend_EnblendExe", wxTextCtrl)->SetValue(
            dlg.GetPath());
    }
}

void PreferencesDialog::OnEnfuseExe(wxCommandEvent& e)
{
    wxFileDialog dlg(this,_("Select Enfuse"),
                     wxEmptyString, HUGIN_ENFUSE_EXE,
#ifdef __WXMSW__
                     _("Executables (*.exe)|*.exe"),
#else
                     "*",
#endif
                     wxFD_OPEN, wxDefaultPosition);
    if (dlg.ShowModal() == wxID_OK)
    {
        XRCCTRL(*this, "prefs_enblend_EnfuseExe", wxTextCtrl)->SetValue(
            dlg.GetPath());
    }
}

void PreferencesDialog::OnDcrawExe(wxCommandEvent & e)
{
    wxTextCtrl* ctrl = XRCCTRL(*this, "pref_raw_dcraw_exe", wxTextCtrl);
    wxFileDialog dlg(this, _("Select dcraw"), "", ctrl->GetValue(),
#ifdef __WXMSW__
        _("Executables (*.exe)|*.exe"),
#else
        "*",
#endif
        wxFD_OPEN, wxDefaultPosition);
    if (dlg.ShowModal() == wxID_OK)
    {
        ctrl->SetValue(dlg.GetPath());
    };
};

void PreferencesDialog::OnRawTherapeeExe(wxCommandEvent & e)
{
    wxTextCtrl* ctrl = XRCCTRL(*this, "pref_raw_rt_exe", wxTextCtrl);
    wxFileDialog dlg(this, _("Select RawTherapee-cli"), "", ctrl->GetValue(),
#ifdef __WXMSW__
        _("Executables (*.exe)|*.exe"),
#else
        "*",
#endif
        wxFD_OPEN, wxDefaultPosition);
    if (dlg.ShowModal() == wxID_OK)
    {
        ctrl->SetValue(dlg.GetPath());
    };
};

void PreferencesDialog::OnDarktableExe(wxCommandEvent & e)
{
    wxTextCtrl* ctrl = XRCCTRL(*this, "pref_raw_darktable_exe", wxTextCtrl);
    wxFileDialog dlg(this, _("Select Darktable-cli"), "", ctrl->GetValue(),
#ifdef __WXMSW__
        _("Executables (*.exe)|*.exe"),
#else
        "*",
#endif
        wxFD_OPEN, wxDefaultPosition);
    if (dlg.ShowModal() == wxID_OK)
    {
        ctrl->SetValue(dlg.GetPath());
    };
};


void PreferencesDialog::OnCustomEnblend(wxCommandEvent& e)
{
    XRCCTRL(*this, "prefs_enblend_EnblendExe", wxTextCtrl)->Enable(e.IsChecked());
    XRCCTRL(*this, "prefs_enblend_select", wxButton)->Enable(e.IsChecked());
}

void PreferencesDialog::OnCustomEnfuse(wxCommandEvent& e)
{
    XRCCTRL(*this, "prefs_enblend_EnfuseExe", wxTextCtrl)->Enable(e.IsChecked());
    XRCCTRL(*this, "prefs_enblend_enfuse_select", wxButton)->Enable(e.IsChecked());
}

void PreferencesDialog::OnExifArgfileChoose(wxCommandEvent & e)
{
    wxFileDialog dlg(this,_("Select ExifTool argfile"),
                     wxEmptyString, XRCCTRL(*this, "pref_exiftool_argfile", wxTextCtrl)->GetValue(), 
                     _("ExifTool Argfiles (*.arg)|*.arg|All Files(*)|*"),
                     wxFD_OPEN, wxDefaultPosition);
    if (dlg.ShowModal() == wxID_OK)
    {
        XRCCTRL(*this, "pref_exiftool_argfile", wxTextCtrl)->SetValue(
            dlg.GetPath());
    }
}

void CreateNewArgFile(const wxString& newFilename, const wxString& sourceFile)
{
    wxTextFile defaultFile(sourceFile);
    defaultFile.Open();
    wxTextFile newFile(newFilename);
    newFile.Create();
    if (defaultFile.IsOpened())
    {
        for (size_t i = 0; i < defaultFile.GetLineCount(); ++i)
        {
            newFile.AddLine(defaultFile[i]);
        };
    };
    newFile.Write();
    defaultFile.Close();
    newFile.Close();
};

void PreferencesDialog::OnExifArgfileEdit(wxCommandEvent & e)
{
    wxString filename=XRCCTRL(*this, "pref_exiftool_argfile", wxTextCtrl)->GetValue();
    if(!filename.empty())
    {
        wxFileName file(filename);
        file.Normalize(wxPATH_NORM_ABSOLUTE | wxPATH_NORM_DOTS | wxPATH_NORM_TILDE | wxPATH_NORM_SHORTCUT);
        if(!file.Exists())
        {
            if (hugin_utils::HuginMessageBox(wxString::Format(_("Argfile %s does not exist.\nShould the argfile be created with default tags?"), filename),
                _("Hugin"), wxYES_NO | wxICON_EXCLAMATION, this) != wxYES)
            {
                return;
            };
            filename = file.GetFullPath();
            CreateNewArgFile(filename, MainFrame::Get()->GetDataPath() + "hugin_exiftool_copy.arg");
        }
        else
        {
            filename = file.GetFullPath();
        };
    }
    else
    {
        if (hugin_utils::HuginMessageBox(_("No file selected.\nShould an argfile be created with default tags?"),
            _("Hugin"), wxYES_NO | wxICON_EXCLAMATION, this) != wxYES)
        {
            return;
        };
        wxFileDialog dlg(this,_("Select new ExifTool argfile"),
            wxStandardPaths::Get().GetUserConfigDir(), wxEmptyString,
                         _("ExifTool Argfiles (*.arg)|*.arg|All Files(*)|*"),
                         wxFD_SAVE | wxFD_OVERWRITE_PROMPT, wxDefaultPosition);
        if (dlg.ShowModal() != wxID_OK)
        {
            return;
        };
        filename=dlg.GetPath();
        CreateNewArgFile(filename, MainFrame::Get()->GetDataPath() + "hugin_exiftool_copy.arg");
    };
    XRCCTRL(*this, "pref_exiftool_argfile", wxTextCtrl)->SetValue(filename);
    wxDialog edit_dlg;
    wxXmlResource::Get()->LoadDialog(&edit_dlg, this, "pref_edit_argfile");
    hugin_utils::RestoreFramePosition(&edit_dlg, "EditArgfile");
    wxTextCtrl* argfileControl=XRCCTRL(edit_dlg, "pref_edit_textcontrol", wxTextCtrl);
    argfileControl->LoadFile(filename);
    if(edit_dlg.ShowModal() == wxID_OK)
    {
        if(!argfileControl->SaveFile(filename))
        {
            hugin_utils::HuginMessageBox(wxString::Format(_("Could not save file \"%s\"."), filename),
                _("Hugin"), wxOK | wxICON_ERROR, this);
        };
        hugin_utils::StoreFramePosition(&edit_dlg, "EditArgfile");
    };
};

void PreferencesDialog::OnExifArgfile2Choose(wxCommandEvent & e)
{
    wxFileDialog dlg(this, _("Select ExifTool argfile"),
        wxEmptyString, XRCCTRL(*this, "pref_exiftool_argfile2", wxTextCtrl)->GetValue(),
        _("ExifTool Argfiles (*.arg)|*.arg|All Files(*)|*"),
        wxFD_OPEN, wxDefaultPosition);
    if (dlg.ShowModal() == wxID_OK)
    {
        XRCCTRL(*this, "pref_exiftool_argfile2", wxTextCtrl)->SetValue(
            dlg.GetPath());
    }
}

void PreferencesDialog::OnExifArgfile2Edit(wxCommandEvent & e)
{
    wxString filename = XRCCTRL(*this, "pref_exiftool_argfile2", wxTextCtrl)->GetValue();
    if (!filename.empty())
    {
        wxFileName file(filename);
        file.Normalize(wxPATH_NORM_ABSOLUTE | wxPATH_NORM_DOTS | wxPATH_NORM_TILDE | wxPATH_NORM_SHORTCUT);
        if (!file.Exists())
        {
            if (hugin_utils::HuginMessageBox(wxString::Format(_("File %s does not exist.\nShould an example argfile be created?"), filename),
                _("Hugin"), wxYES_NO | wxICON_EXCLAMATION, this) != wxYES)
            {
                return;
            };
            filename = file.GetFullPath();
            CreateNewArgFile(filename, MainFrame::Get()->GetDataPath() + "hugin_exiftool_final_example.arg");
        }
        else
        {
            filename = file.GetFullPath();
        };
    }
    else
    {
        if (hugin_utils::HuginMessageBox(_("No file selected.\nShould an example argfile be created?"),
            _("Hugin"), wxYES_NO | wxICON_EXCLAMATION, this) != wxYES)
        {
            return;
        };
        wxFileDialog dlg(this, _("Select new ExifTool argfile"),
            wxStandardPaths::Get().GetUserConfigDir(), wxEmptyString,
            _("ExifTool Argfiles (*.arg)|*.arg|All Files(*)|*"),
            wxFD_SAVE | wxFD_OVERWRITE_PROMPT, wxDefaultPosition);
        if (dlg.ShowModal() != wxID_OK)
        {
            return;
        };
        filename = dlg.GetPath();
        CreateNewArgFile(filename, MainFrame::Get()->GetDataPath() + "hugin_exiftool_final_example.arg");
    };
    XRCCTRL(*this, "pref_exiftool_argfile2", wxTextCtrl)->SetValue(filename);
    wxDialog edit_dlg;
    wxXmlResource::Get()->LoadDialog(&edit_dlg, this, "pref_edit_argfile_placeholders");
    hugin_utils::RestoreFramePosition(&edit_dlg, "EditArgfilePlaceholders");
    wxTextCtrl* argfileControl = XRCCTRL(edit_dlg, "pref_edit_textcontrol", wxTextCtrl);
    argfileControl->LoadFile(filename);
    if (edit_dlg.ShowModal() == wxID_OK)
    {
        if (!argfileControl->SaveFile(filename))
        {
            hugin_utils::HuginMessageBox(wxString::Format(_("Could not save file \"%s\"."), filename),
                _("Hugin"), wxOK | wxICON_ERROR, this);
        };
        hugin_utils::StoreFramePosition(&edit_dlg, "EditArgfilePlaceholders");
    };
};

void PreferencesDialog::OnExifTool(wxCommandEvent & e)
{
    bool copyMetadata=XRCCTRL(*this, "pref_exiftool_metadata", wxCheckBox)->GetValue();
    XRCCTRL(*this, "pref_exiftool_argfile_general_label", wxStaticText)->Enable(copyMetadata);
    XRCCTRL(*this, "pref_exiftool_argfile_intermediate_label", wxStaticText)->Enable(copyMetadata);
    XRCCTRL(*this, "pref_exiftool_argfile_label", wxStaticText)->Enable(copyMetadata);
    XRCCTRL(*this, "pref_exiftool_argfile", wxTextCtrl)->Enable(copyMetadata);
    XRCCTRL(*this, "pref_exiftool_argfile_choose", wxButton)->Enable(copyMetadata);
    XRCCTRL(*this, "pref_exiftool_argfile_edit", wxButton)->Enable(copyMetadata);
    XRCCTRL(*this, "pref_exiftool_argfile_final_label", wxStaticText)->Enable(copyMetadata);
    XRCCTRL(*this, "pref_exiftool_argfile2_label", wxStaticText)->Enable(copyMetadata);
    XRCCTRL(*this, "pref_exiftool_argfile2", wxTextCtrl)->Enable(copyMetadata);
    XRCCTRL(*this, "pref_exiftool_argfile2_choose", wxButton)->Enable(copyMetadata);
    XRCCTRL(*this, "pref_exiftool_argfile2_edit", wxButton)->Enable(copyMetadata);
    XRCCTRL(*this, "pref_exiftool_gpano", wxCheckBox)->Enable(copyMetadata);
};

void PreferencesDialog::EnableRotationCtrls(bool enable)
{
    XRCCTRL(*this, "prefs_ft_rot_panel", wxPanel)->Enable(enable);
}

void PreferencesDialog::UpdateDisplayData(int panel)
{
    DEBUG_DEBUG("Updating display data");

    double d;
    bool t;
    wxString tstr;
    wxConfigBase* cfg = wxConfigBase::Get();

    if (panel==0 || panel == 1)
    {
        // memory setting
        unsigned long long mem = cfg->Read("/ImageCache/UpperBound", HUGIN_IMGCACHE_UPPERBOUND);
#ifdef __WXMSW__
        unsigned long mem_low = cfg->Read("/ImageCache/UpperBound", HUGIN_IMGCACHE_UPPERBOUND);
        unsigned long mem_high = cfg->Read("/ImageCache/UpperBoundHigh", (long) 0);
        if (mem_high > 0)
        {
            mem = ((unsigned long long) mem_high << 32) + mem_low;
        }
        else
        {
            mem = mem_low;
        }
#endif
        MY_SPIN_VAL("prefs_cache_UpperBound", mem >> 20);

        // language
        // check if current language is in list and activate it then.
        wxChoice* lang_choice = XRCCTRL(*this, "prefs_gui_language", wxChoice);
        int curlang = cfg->Read("language", HUGIN_LANGUAGE);
        bool found = false;
        int idx = 0;
        int idxDefault = 0;
        for (int i = 0; i < (int)lang_choice->GetCount(); i++)
        {
            long lang = * static_cast<long*>(lang_choice->GetClientData(i));
            if (curlang == lang)
            {
                found = true;
                idx = i;
            }
            if (lang == wxLANGUAGE_DEFAULT)
            {
                idxDefault=i;
            }
        }
        if (found)
        {
            DEBUG_DEBUG("wxChoice language updated:" << curlang);
            // update language
            lang_choice->SetSelection(idx);
        }
        else
        {
            // unknown language selected..
            DEBUG_WARN("Unknown language configured");
            // select default language
            lang_choice->SetSelection(idxDefault);
        }

        // smart undo
        t = cfg->Read("smartUndo", HUGIN_SMART_UNDO) == 1;
        MY_BOOL_VAL("prefs_smart_undo", t);

        // copy log to clipboard
        t = cfg->Read("CopyLogToClipboard", 0l) == 1;
        MY_BOOL_VAL("prefs_copy_log", t);

        t = cfg->Read("/GLPreviewFrame/ShowProjectionHints", HUGIN_SHOW_PROJECTION_HINTS) == 1;
        MY_BOOL_VAL("pref_show_projection_hints", t);
        // auto-rotate
        t = cfg->Read("/CPEditorPanel/AutoRot", 1l) == 1;
        MY_BOOL_VAL("pref_autorotate", t);

        // raw converter programs paths
        MY_STR_VAL("pref_raw_dcraw_exe", cfg->Read("/RawImportDialog/dcrawExe", ""));
        MY_STR_VAL("pref_raw_rt_exe", cfg->Read("/RawImportDialog/RTExe", ""));
        MY_STR_VAL("pref_raw_darktable_exe", cfg->Read("/RawImportDialog/DarktableExe", ""));
    };

    // filename panel
    if(panel==0 || panel==2)
    {
        // tempdir
        MY_STR_VAL("prefs_misc_tempdir", cfg->Read("tempDir",wxEmptyString));
        // default filenames
        wxString filename=cfg->Read("ProjectFilename", HUGIN_DEFAULT_PROJECT_NAME);
#ifdef __WXMSW__
        filename.Replace("/","\\",true);
#endif
        MY_STR_VAL("prefs_project_filename", filename);
        filename=cfg->Read("OutputFilename", HUGIN_DEFAULT_OUTPUT_NAME);
#ifdef __WXMSW__
        filename.Replace("/","\\",true);
#endif
        MY_STR_VAL("prefs_output_filename", filename);
    }

    if (panel==0 || panel == 3)
    {
        // Assistant settings
        t = cfg->Read("/Assistant/autoAlign", HUGIN_ASS_AUTO_ALIGN) == 1;
        MY_BOOL_VAL("prefs_ass_autoAlign", t);
        t = cfg->Read("/General/IgnoreFovRectilinearOnAdd", 1l) == 1l;
        MY_BOOL_VAL("prefs_ass_loadFovRectilinear", !t);
        MY_SPIN_VAL("prefs_ass_nControlPoints",
                    cfg->Read("/Assistant/nControlPoints", HUGIN_ASS_NCONTROLPOINTS));
        double factor = HUGIN_ASS_PANO_DOWNSIZE_FACTOR;
        cfg->Read("/Assistant/panoDownsizeFactor", &factor);
        MY_SPIN_VAL("prefs_ass_panoDownsizeFactor",(int)(factor*100.0));
        t = cfg->Read("/Assistant/Linefind", HUGIN_ASS_LINEFIND) == 1;
        MY_BOOL_VAL("prefs_ass_linefind", t);
        t = cfg->Read("/Celeste/Auto", HUGIN_CELESTE_AUTO) == 1;
        MY_BOOL_VAL("prefs_celeste_auto", t);
        t = cfg->Read("/Assistant/AutoCPClean", HUGIN_ASS_AUTO_CPCLEAN) == 1;
        MY_BOOL_VAL("prefs_auto_cpclean", t);
        t = cfg->Read("/Assistant/UserDefinedOutputOption", 0l) == 1;
        MY_BOOL_VAL("pref_ass_output", t);
        wxCommandEvent dummy;
        OnUserDefinedOutputOptionsCheckBox(dummy);
    }
    // Fine tune settings

    if (panel==0 || panel == 4)
    {
        // hdr display settings
        MY_CHOICE_VAL("prefs_misc_hdr_mapping", cfg->Read("/ImageCache/Mapping", HUGIN_IMGCACHE_MAPPING_FLOAT));
        //MY_CHOICE_VAL("prefs_misc_hdr_range", cfg->Read("/ImageCache/Range", HUGIN_IMGCACHE_RANGE));

        int val = wxConfigBase::Get()->Read("/CPEditorPanel/MagnifierWidth", 61l);
        val = hugin_utils::floori((val - 61) / 20);
        val = std::min(val, 3);
        XRCCTRL(*this, "prefs_misc_magnifier_width", wxChoice)->SetSelection(val);


        MY_SPIN_VAL("prefs_ft_TemplateSize",
                    cfg->Read("/Finetune/TemplateSize",HUGIN_FT_TEMPLATE_SIZE));
        MY_SPIN_VAL("prefs_ft_SearchAreaPercent",cfg->Read("/Finetune/SearchAreaPercent",
                    HUGIN_FT_SEARCH_AREA_PERCENT));
        MY_SPIN_VAL("prefs_ft_LocalSearchWidth", cfg->Read("/Finetune/LocalSearchWidth",
                    HUGIN_FT_LOCAL_SEARCH_WIDTH));

        d=HUGIN_FT_CORR_THRESHOLD;
        cfg->Read("/Finetune/CorrThreshold", &d, HUGIN_FT_CORR_THRESHOLD);
        tstr = hugin_utils::doubleTowxString(d);
        MY_STR_VAL("prefs_ft_CorrThreshold", tstr);

        cfg->Read("/Finetune/CurvThreshold", &d, HUGIN_FT_CURV_THRESHOLD);
        tstr = hugin_utils::doubleTowxString(d);
        MY_STR_VAL("prefs_ft_CurvThreshold", tstr);

        t = cfg->Read("/Finetune/RotationSearch", HUGIN_FT_ROTATION_SEARCH) == 1;
        MY_BOOL_VAL("prefs_ft_RotationSearch", t);
        EnableRotationCtrls(t);

        d = HUGIN_FT_ROTATION_START_ANGLE;
        cfg->Read("/Finetune/RotationStartAngle",&d,HUGIN_FT_ROTATION_START_ANGLE);
        MY_SPIN_VAL("prefs_ft_RotationStartAngle", hugin_utils::roundi(d))

        d = HUGIN_FT_ROTATION_STOP_ANGLE;
        cfg->Read("/Finetune/RotationStopAngle", &d, HUGIN_FT_ROTATION_STOP_ANGLE);
        MY_SPIN_VAL("prefs_ft_RotationStopAngle", hugin_utils::roundi(d));

        MY_SPIN_VAL("prefs_ft_RotationSteps", cfg->Read("/Finetune/RotationSteps",
                    HUGIN_FT_ROTATION_STEPS));
    }

    /////
    /// MISC

    /////
    /// CP Detector programs

    if (panel==0 || panel == 5)
    {
        cpdetector_config_edit.FillControl(m_CPDetectorList,true,true);
    }

    if (panel == 0 || panel == 6)
    {
        /////
        /// DEFAULT OUTPUT FORMAT
        MY_CHOICE_VAL("pref_ldr_output_file_format", cfg->Read("/output/ldr_format", HUGIN_LDR_OUTPUT_FORMAT));
        /** HDR currently deactivated since HDR TIFF broken and only choice is EXR */
        // MY_CHOICE_VAL("pref_hdr_output_file_format", cfg->Read("/output/hdr_format", HUGIN_HDR_OUTPUT_FORMAT));
        MY_CHOICE_VAL("pref_tiff_compression", cfg->Read("/output/tiff_compression", HUGIN_TIFF_COMPRESSION));
        MY_SPIN_VAL("pref_jpeg_quality", cfg->Read("/output/jpeg_quality", HUGIN_JPEG_QUALITY));
        UpdateFileFormatControls();

        // default blender
        SelectListValue(XRCCTRL(*this, "pref_default_blender", wxChoice), cfg->Read("/default_blender", HUGIN_DEFAULT_BLENDER));
        // default verdandi parameters
        const wxString defaultVerdandiArgs = cfg->Read("/VerdandiDefaultArgs", wxEmptyString);
        if (defaultVerdandiArgs.Find("--seam=blend") != wxNOT_FOUND)
        {
            XRCCTRL(*this, "pref_internal_blender_seam", wxChoice)->SetSelection(1);
        }
        else
        {
            XRCCTRL(*this, "pref_internal_blender_seam", wxChoice)->SetSelection(0);
        };
        UpdateBlenderControls();

        /////
        /// PROCESSOR
        MY_CHOICE_VAL("pref_processor_gui", cfg->Read("/Processor/gui", HUGIN_PROCESSOR_GUI));
        t = cfg->Read("/Processor/start", HUGIN_PROCESSOR_START) == 1;
        MY_BOOL_VAL("pref_processor_start", t);
        t = cfg->Read("/Processor/overwrite", HUGIN_PROCESSOR_OVERWRITE) == 1;
        MY_BOOL_VAL("pref_processor_overwrite", t);
        t = cfg->Read("/Processor/verbose", HUGIN_PROCESSOR_VERBOSE) == 1;
        MY_BOOL_VAL("pref_processor_verbose", t);
        UpdateProcessorControls();
    }

    if (panel == 0 || panel == 7)
    {
        // stitching (2) panel
        t = cfg->Read("/output/useExiftool", HUGIN_USE_EXIFTOOL) == 1;
        MY_BOOL_VAL("pref_exiftool_metadata", t);
        MY_STR_VAL("pref_exiftool_argfile", cfg->Read("/output/CopyArgfile", wxEmptyString));
        MY_STR_VAL("pref_exiftool_argfile2", cfg->Read("/output/FinalArgfile", wxEmptyString));
        t = cfg->Read("/output/writeGPano", HUGIN_EXIFTOOL_CREATE_GPANO) == 1;
        MY_BOOL_VAL("pref_exiftool_gpano", t);
        wxCommandEvent dummy;
        OnExifTool(dummy);
        // number of threads
        int nThreads = cfg->Read("/output/NumberOfThreads", 0l);
        MY_SPIN_VAL("prefs_output_NumberOfThreads", nThreads);
    }

    if (panel==0 || panel == 8)
    {

        /////
        /// NONA
        MY_CHOICE_VAL("prefs_nona_interpolator", cfg->Read("/Nona/Interpolator", HUGIN_NONA_INTERPOLATOR));
        t = cfg->Read("/Nona/CroppedImages", HUGIN_NONA_CROPPEDIMAGES) == 1;
        MY_BOOL_VAL("prefs_nona_createCroppedImages", t);
        t = cfg->Read("/Nona/UseGPU", HUGIN_NONA_USEGPU) == 1;
        MY_BOOL_VAL("prefs_nona_useGpu", t);

        /////
        /// ENBLEND
        MY_STR_VAL("prefs_enblend_EnblendExe", cfg->Read("/Enblend/Exe",
                   HUGIN_ENBLEND_EXE));
        bool customEnblendExe = HUGIN_ENBLEND_EXE_CUSTOM;
        cfg->Read("/Enblend/Custom", &customEnblendExe);
        MY_BOOL_VAL("prefs_enblend_Custom", customEnblendExe);
        XRCCTRL(*this, "prefs_enblend_EnblendExe", wxTextCtrl)->Enable(customEnblendExe);
        XRCCTRL(*this, "prefs_enblend_select", wxButton)->Enable(customEnblendExe);
        MY_STR_VAL("prefs_enblend_EnblendArgs", cfg->Read("/Enblend/Args",
                   HUGIN_ENBLEND_ARGS));
        /////
        /// ENFUSE
        MY_STR_VAL("prefs_enblend_EnfuseExe", cfg->Read("/Enfuse/Exe",
                   HUGIN_ENFUSE_EXE));
        bool customEnfuseExe = HUGIN_ENFUSE_EXE_CUSTOM;
        cfg->Read("/Enfuse/Custom", &customEnfuseExe);
        MY_BOOL_VAL("prefs_enblend_enfuseCustom", customEnfuseExe);
        XRCCTRL(*this, "prefs_enblend_EnfuseExe", wxTextCtrl)->Enable(customEnfuseExe);
        XRCCTRL(*this, "prefs_enblend_enfuse_select", wxButton)->Enable(customEnfuseExe);
        MY_STR_VAL("prefs_enblend_EnfuseArgs", cfg->Read("/Enfuse/Args",
                   HUGIN_ENFUSE_ARGS));
    }

    if (panel==0 || panel == 9)
    {
        // Celeste settings
        d=HUGIN_CELESTE_THRESHOLD;
        cfg->Read("/Celeste/Threshold", &d, HUGIN_CELESTE_THRESHOLD);
        tstr = hugin_utils::doubleTowxString(d);
        MY_STR_VAL("prefs_celeste_threshold", tstr);
        MY_CHOICE_VAL("prefs_celeste_filter", cfg->Read("/Celeste/Filter", HUGIN_CELESTE_FILTER));
        // photometric optimizer settings
        MY_SPIN_VAL("prefs_photo_optimizer_nr_points", cfg->Read("/OptimizePhotometric/nRandomPointsPerImage", HUGIN_PHOTOMETRIC_OPTIMIZER_NRPOINTS));
        // warnings
        t = cfg->Read("/ShowSaveMessage", 1l) == 1;
        MY_BOOL_VAL("prefs_warning_save", t);
        t = cfg->Read("/ShowExposureWarning", 1l) == 1;
        MY_BOOL_VAL("prefs_warning_exposure", t);
        t = cfg->Read("/ShowFisheyeCropHint", 1l) == 1;
        MY_BOOL_VAL("prefs_warning_fisheye_crop", t);
        MY_CHOICE_VAL("pref_editcp_action", cfg->Read("/EditCPAfterAction", 0l));
    }
}

void PreferencesDialog::OnRestoreDefaults(wxCommandEvent& e)
{
    DEBUG_TRACE("");
    wxConfigBase* cfg = wxConfigBase::Get();
    // check which tab is enabled
    wxNotebook* noteb = XRCCTRL(*this, "prefs_tab", wxNotebook);
    if (hugin_utils::HuginMessageBox(_("Really reset displayed preferences to default values?"), _("Hugin"), wxYES_NO | wxICON_QUESTION, this) == wxYES)
    {
        if (noteb->GetSelection() == 0)
        {
            // MISC
            // cache
            /*
             * special treatment for windows not necessary here since we know the value of
             * HUGIN_IMGCACHE_UPPERBOUND must fit into 32bit to be compatible with 32bit systems.
             * However, just as a reminder:
            #ifdef __WXMSW__
                cfg->Write("/ImageCache/UpperBoundHigh", HUGIN_IMGCACHE_UPPERBOUND >> 32);
            #endif
            */
            cfg->Write("/ImageCache/UpperBound", HUGIN_IMGCACHE_UPPERBOUND);
            // locale
            cfg->Write("language", int(HUGIN_LANGUAGE));
            // smart undo
            cfg->Write("smartUndo", HUGIN_SMART_UNDO);
            cfg->Write("CopyLogToClipboard", 0l);
            // projection hints
            cfg->Write("/GLPreviewFrame/ShowProjectionHints", HUGIN_SHOW_PROJECTION_HINTS);
            cfg->Write("/CPEditorPanel/AutoRot", 1l);
            // raw converter
            cfg->Write("/RawImportDialog/dcrawExe", "");
            cfg->Write("/RawImportDialog/RTExe", "");
            cfg->Write("/RawImportDialog/DarktableExe", "");
        }
        if(noteb->GetSelection() == 1)
        {
            cfg->Write("tempDir", wxEmptyString);
            cfg->Write("ProjectFilename", HUGIN_DEFAULT_PROJECT_NAME);
            cfg->Write("OutputFilename", HUGIN_DEFAULT_OUTPUT_NAME);
        };
        if (noteb->GetSelection() == 2)
        {
            cfg->Write("/Assistant/autoAlign", HUGIN_ASS_AUTO_ALIGN);
            cfg->Write("/General/IgnoreFovRectilinearOnAdd", 1l);
            cfg->Write("/Assistant/nControlPoints", HUGIN_ASS_NCONTROLPOINTS);
            cfg->Write("/Assistant/panoDownsizeFactor",HUGIN_ASS_PANO_DOWNSIZE_FACTOR);
            cfg->Write("/Assistant/Linefind", HUGIN_ASS_LINEFIND);
            cfg->Write("/Celeste/Auto", HUGIN_CELESTE_AUTO);
            cfg->Write("/Assistant/AutoCPClean", HUGIN_ASS_AUTO_CPCLEAN);
            cfg->Write("/Assistant/UserDefinedOutputOption", 0l);
        }
        if (noteb->GetSelection() == 3)
        {
            // hdr
            cfg->Write("/ImageCache/Mapping", HUGIN_IMGCACHE_MAPPING_FLOAT);
            //cfg->Write("/ImageCache/Range", HUGIN_IMGCACHE_RANGE);
            cfg->Write("/CPEditorPanel/MagnifierWidth", 61l);
            // Fine tune settings
            cfg->Write("/Finetune/SearchAreaPercent", HUGIN_FT_SEARCH_AREA_PERCENT);
            cfg->Write("/Finetune/TemplateSize", HUGIN_FT_TEMPLATE_SIZE);
            cfg->Write("/Finetune/LocalSearchWidth", HUGIN_FT_LOCAL_SEARCH_WIDTH);

            cfg->Write("/Finetune/CorrThreshold", HUGIN_FT_CORR_THRESHOLD);
            cfg->Write("/Finetune/CurvThreshold", HUGIN_FT_CURV_THRESHOLD);

            cfg->Write("/Finetune/RotationSearch", HUGIN_FT_ROTATION_SEARCH);
            cfg->Write("/Finetune/RotationStartAngle", HUGIN_FT_ROTATION_START_ANGLE);
            cfg->Write("/Finetune/RotationStopAngle", HUGIN_FT_ROTATION_STOP_ANGLE);
            cfg->Write("/Finetune/RotationSteps", HUGIN_FT_ROTATION_STEPS);
        }
        if (noteb->GetSelection() == 4)
        {
            /////
            /// AUTOPANO
            cpdetector_config_edit.ReadFromFile(huginApp::Get()->GetDataPath()+"default.setting");
            cpdetector_config_edit.Write(cfg);
        }
        if (noteb->GetSelection() == 5)
        {
            /// OUTPUT
            cfg->Write("/output/ldr_format", HUGIN_LDR_OUTPUT_FORMAT);
            /** HDR currently deactivated since HDR TIFF broken and only choice is EXR */
            // cfg->Write("/output/hdr_format", HUGIN_HDR_OUTPUT_FORMAT);
            cfg->Write("/output/tiff_compression", HUGIN_TIFF_COMPRESSION);
            cfg->Write("/output/jpeg_quality", HUGIN_JPEG_QUALITY);
            // default blender
            cfg->Write("/default_blender", static_cast<long>(HUGIN_DEFAULT_BLENDER));
            cfg->Write("/VerdandiDefaultArgs", wxEmptyString);
            // stitching engine
            cfg->Write("/Processor/gui", HUGIN_PROCESSOR_GUI);
            cfg->Write("/Processor/start", HUGIN_PROCESSOR_START);
            cfg->Write("/Processor/overwrite", HUGIN_PROCESSOR_OVERWRITE);
            cfg->Write("/Processor/verbose", HUGIN_PROCESSOR_VERBOSE);
        }
        if (noteb->GetSelection() == 6)
        {
            cfg->Write("/output/useExiftool", HUGIN_USE_EXIFTOOL);
            cfg->Write("/output/CopyArgfile", wxEmptyString);
            cfg->Write("/output/FinalArgfile", wxEmptyString);
            cfg->Write("/output/writeGPano", HUGIN_EXIFTOOL_CREATE_GPANO);
            cfg->Write("/output/NumberOfThreads", 0l);
        }
        if (noteb->GetSelection() == 7)
        {
            /// ENBLEND
            cfg->Write("/Enblend/Exe", HUGIN_ENBLEND_EXE);
            cfg->Write("/Enblend/Custom", HUGIN_ENBLEND_EXE_CUSTOM);
            cfg->Write("/Enblend/Args", HUGIN_ENBLEND_ARGS);

            cfg->Write("/Enfuse/Exe", HUGIN_ENFUSE_EXE);
            cfg->Write("/Enfuse/Custom", HUGIN_ENFUSE_EXE_CUSTOM);
            cfg->Write("/Enfuse/Args", HUGIN_ENFUSE_ARGS);
        }

        if (noteb->GetSelection() == 8)
        {
            /// Celeste
            cfg->Write("/Celeste/Threshold", HUGIN_CELESTE_THRESHOLD);
            cfg->Write("/Celeste/Filter", HUGIN_CELESTE_FILTER);
            cfg->Write("/OptimizePhotometric/nRandomPointsPerImage", HUGIN_PHOTOMETRIC_OPTIMIZER_NRPOINTS);
            cfg->Write("/ShowSaveMessage", 1l);
            cfg->Write("/ShowExposureWarning", 1l);
            cfg->Write("/ShowFisheyeCropHint", 1l);
            cfg->Write("/EditCPAfterAction", 0l);
        }

        /*
                if (noteb->GetSelection() == 5) {
                    cfg->Write("/PTmender/Exe", HUGIN_PT_MENDER_EXE );
                    cfg->Write("/PTmender/Custom",HUGIN_PT_MENDER_EXE_CUSTOM);
                    cfg->Write("/PanoTools/ScriptFile", "PT_script.txt");
                }
        */
        UpdateDisplayData(noteb->GetSelection() + 1);
    }
}

void PreferencesDialog::UpdateConfigData()
{
    DEBUG_TRACE("");
    wxConfigBase* cfg = wxConfigBase::Get();
    // Assistant
    cfg->Write("/Assistant/autoAlign",MY_G_BOOL_VAL("prefs_ass_autoAlign"));
    cfg->Write("/General/IgnoreFovRectilinearOnAdd", !MY_G_BOOL_VAL("prefs_ass_loadFovRectilinear"));
    cfg->Write("/Assistant/nControlPoints", MY_G_SPIN_VAL("prefs_ass_nControlPoints"));
    cfg->Write("/Assistant/panoDownsizeFactor", MY_G_SPIN_VAL("prefs_ass_panoDownsizeFactor") / 100.0);
    cfg->Write("/Assistant/Linefind", MY_G_BOOL_VAL("prefs_ass_linefind"));
    cfg->Write("/Celeste/Auto", MY_G_BOOL_VAL("prefs_celeste_auto"));
    cfg->Write("/Assistant/AutoCPClean", MY_G_BOOL_VAL("prefs_auto_cpclean"));
    cfg->Write("/Assistant/UserDefinedOutputOption", MY_G_BOOL_VAL("pref_ass_output"));

    // hdr display
    cfg->Write("/ImageCache/Mapping",MY_G_CHOICE_VAL("prefs_misc_hdr_mapping"));
    //cfg->Write("/ImageCache/Range",MY_G_CHOICE_VAL("prefs_misc_hdr_range"));
    cfg->Write("/CPEditorPanel/MagnifierWidth", MY_G_CHOICE_VAL("prefs_misc_magnifier_width") * 20 + 61l);

    // Fine tune settings
    cfg->Write("/Finetune/SearchAreaPercent", MY_G_SPIN_VAL("prefs_ft_SearchAreaPercent"));
    cfg->Write("/Finetune/TemplateSize", MY_G_SPIN_VAL("prefs_ft_TemplateSize"));
    cfg->Write("/Finetune/LocalSearchWidth", MY_G_SPIN_VAL("prefs_ft_LocalSearchWidth"));
    wxString t = MY_G_STR_VAL("prefs_ft_CorrThreshold");
    double td= HUGIN_FT_CORR_THRESHOLD;
    hugin_utils::stringToDouble(std::string(t.mb_str(wxConvLocal)), td);
    cfg->Write("/Finetune/CorrThreshold", td);

    t = MY_G_STR_VAL("prefs_ft_CurvThreshold");
    td = HUGIN_FT_CURV_THRESHOLD;
    hugin_utils::stringToDouble(std::string(t.mb_str(wxConvLocal)), td);
    cfg->Write("/Finetune/CurvThreshold", td);

    cfg->Write("/Finetune/RotationSearch", MY_G_BOOL_VAL("prefs_ft_RotationSearch"));
    cfg->Write("/Finetune/RotationStartAngle", (double) MY_G_SPIN_VAL("prefs_ft_RotationStartAngle"));
    cfg->Write("/Finetune/RotationStopAngle", (double) MY_G_SPIN_VAL("prefs_ft_RotationStopAngle"));
    cfg->Write("/Finetune/RotationSteps", MY_G_SPIN_VAL("prefs_ft_RotationSteps"));

    /////
    /// MISC
    // cache
#ifdef __WXMSW__
    // shifting only 12 bits rights: 32-20=12 and the prefs_cache_UpperBound is in GB
    cfg->Write("/ImageCache/UpperBoundHigh", (long) MY_G_SPIN_VAL("prefs_cache_UpperBound") >> 12);
#endif
    cfg->Write("/ImageCache/UpperBound", (long) MY_G_SPIN_VAL("prefs_cache_UpperBound") << 20);
    // locale
    // language
    wxChoice* lang = XRCCTRL(*this, "prefs_gui_language", wxChoice);
    // DEBUG_TRACE("Language Selection Name: " << huginApp::Get()->GetLocale().GetLanguageName((int) lang->GetClientData(lang->GetSelection())).mb_str(wxConvLocal));
    //DEBUG_INFO("Language Selection locale: " << ((huginApp::Get()->GetLocale().GetLanguageInfo((int) lang->GetClientData(lang->GetSelection())))->CanonicalName).mb_str(wxConvLocal));
    //DEBUG_INFO("Current System Language ID: " << huginApp::Get()->GetLocale().GetSystemLanguage());

    void* tmplp = lang->GetClientData(lang->GetSelection());
    long templ =  * static_cast<long*>(tmplp);
    cfg->Write("language", templ);
    DEBUG_INFO("Language Selection ID: " << templ);
    // smart undo
    cfg->Write("smartUndo", MY_G_BOOL_VAL("prefs_smart_undo"));
    cfg->Write("CopyLogToClipboard", MY_G_BOOL_VAL("prefs_copy_log"));
    // show projections hints
    cfg->Write("/GLPreviewFrame/ShowProjectionHints", MY_G_BOOL_VAL("pref_show_projection_hints"));
    //auto-rotate
    cfg->Write("/CPEditorPanel/AutoRot", MY_G_BOOL_VAL("pref_autorotate"));
    // raw converter
    cfg->Write("/RawImportDialog/dcrawExe", MY_G_STR_VAL("pref_raw_dcraw_exe"));
    cfg->Write("/RawImportDialog/RTExe", MY_G_STR_VAL("pref_raw_rt_exe"));
    cfg->Write("/RawImportDialog/DarktableExe", MY_G_STR_VAL("pref_raw_darktable_exe"));;
    // tempdir
    cfg->Write("tempDir",MY_G_STR_VAL("prefs_misc_tempdir"));
    // filename templates
    wxString filename=XRCCTRL(*this, "prefs_project_filename", wxTextCtrl)->GetValue();
#ifdef __WXMSW__
    filename.Replace("\\", "/", true);
#endif
    cfg->Write("ProjectFilename", filename);
    filename=XRCCTRL(*this, "prefs_output_filename", wxTextCtrl)->GetValue();
#ifdef __WXMSW__
    filename.Replace("\\", "/", true);
#endif
    cfg->Write("OutputFilename", filename);
    /////
    /// AUTOPANO
    cpdetector_config_edit.Write(cfg);

    /////
    /// OUTPUT
    cfg->Write("/output/ldr_format", MY_G_CHOICE_VAL("pref_ldr_output_file_format"));
    /** HDR currently deactivated since HDR TIFF broken and only choice is EXR */
    // cfg->Write("/output/hdr_format", MY_G_CHOICE_VAL("pref_hdr_output_file_format"));
    cfg->Write("/output/tiff_compression", MY_G_CHOICE_VAL("pref_tiff_compression"));
    cfg->Write("/output/jpeg_quality", MY_G_SPIN_VAL("pref_jpeg_quality"));

    cfg->Write("/default_blender", static_cast<long>(GetSelectedValue(XRCCTRL(*this, "pref_default_blender", wxChoice))));
    if (XRCCTRL(*this, "pref_internal_blender_seam", wxChoice)->GetSelection() == 1)
    {
        cfg->Write("/VerdandiDefaultArgs", "--seam=blend");
    }
    else
    {
        cfg->Write("/VerdandiDefaultArgs", wxEmptyString);
    };

    /////
    /// PROCESSOR
    cfg->Write("/Processor/gui", MY_G_CHOICE_VAL("pref_processor_gui"));
    cfg->Write("/Processor/start", MY_G_BOOL_VAL("pref_processor_start"));
    cfg->Write("/Processor/overwrite", MY_G_BOOL_VAL("pref_processor_overwrite"));
    cfg->Write("/Processor/verbose", MY_G_BOOL_VAL("pref_processor_verbose"));

    cfg->Write("/output/useExiftool", MY_G_BOOL_VAL("pref_exiftool_metadata"));
    cfg->Write("/output/CopyArgfile", MY_G_STR_VAL("pref_exiftool_argfile"));
    cfg->Write("/output/FinalArgfile", MY_G_STR_VAL("pref_exiftool_argfile2"));
    cfg->Write("/output/writeGPano", MY_G_BOOL_VAL("pref_exiftool_gpano"));
    cfg->Write("/output/NumberOfThreads", MY_G_SPIN_VAL("prefs_output_NumberOfThreads"));
    /////
    /// STITCHING
    cfg->Write("/Nona/Interpolator", MY_G_CHOICE_VAL("prefs_nona_interpolator"));
    cfg->Write("/Nona/CroppedImages", MY_G_BOOL_VAL("prefs_nona_createCroppedImages"));
    cfg->Write("/Nona/UseGPU", MY_G_BOOL_VAL("prefs_nona_useGpu"));

    /////
    /// ENBLEND
    cfg->Write("/Enblend/Custom", MY_G_BOOL_VAL("prefs_enblend_Custom"));
    cfg->Write("/Enblend/Exe", MY_G_STR_VAL("prefs_enblend_EnblendExe"));
    cfg->Write("/Enblend/Args", MY_G_STR_VAL("prefs_enblend_EnblendArgs"));

    cfg->Write("/Enfuse/Custom", MY_G_BOOL_VAL("prefs_enblend_enfuseCustom"));
    cfg->Write("/Enfuse/Exe", MY_G_STR_VAL("prefs_enblend_EnfuseExe"));
    cfg->Write("/Enfuse/Args", MY_G_STR_VAL("prefs_enblend_EnfuseArgs"));

    // Celeste
    t = MY_G_STR_VAL("prefs_celeste_threshold");
    td = HUGIN_CELESTE_THRESHOLD;
    hugin_utils::stringToDouble(std::string(t.mb_str(wxConvLocal)), td);
    cfg->Write("/Celeste/Threshold", td);
    cfg->Write("/Celeste/Filter", MY_G_CHOICE_VAL("prefs_celeste_filter"));
    //photometric optimizer
    cfg->Write("/OptimizePhotometric/nRandomPointsPerImage", MY_G_SPIN_VAL("prefs_photo_optimizer_nr_points"));
    cfg->Write("/ShowSaveMessage", MY_G_BOOL_VAL("prefs_warning_save"));
    cfg->Write("/ShowExposureWarning", MY_G_BOOL_VAL("prefs_warning_exposure"));
    cfg->Write("/ShowFisheyeCropHint", MY_G_BOOL_VAL("prefs_warning_fisheye_crop"));
    cfg->Write("/EditCPAfterAction", MY_G_CHOICE_VAL("pref_editcp_action"));

    cfg->Flush();
    UpdateDisplayData(0);
}

void PreferencesDialog::OnCPDetectorAdd(wxCommandEvent& e)
{
    CPDetectorDialog cpdetector_dlg(this);
    if(cpdetector_dlg.ShowModal()==wxOK)
    {
        cpdetector_config_edit.settings.Add(new CPDetectorSetting);
        cpdetector_dlg.UpdateSettings(&cpdetector_config_edit,cpdetector_config_edit.GetCount()-1);
        cpdetector_config_edit.FillControl(m_CPDetectorList,false,true);
        m_CPDetectorList->SetSelection(cpdetector_config_edit.GetCount()-1);
    };
};

void PreferencesDialog::OnCPDetectorEdit(wxCommandEvent& e)
{
    CPDetectorDialog autopano_dlg(this);
    int selection=m_CPDetectorList->GetSelection();
    if (selection == wxNOT_FOUND)
    {
        hugin_utils::HuginMessageBox(_("Please select an entry first"), _("Hugin"), wxOK | wxICON_EXCLAMATION, this);
    }
    else
    {
        autopano_dlg.UpdateFields(&cpdetector_config_edit, selection);
        if(autopano_dlg.ShowModal()==wxOK)
        {
            autopano_dlg.UpdateSettings(&cpdetector_config_edit, selection);
            cpdetector_config_edit.FillControl(m_CPDetectorList,false,true);
            m_CPDetectorList->SetSelection(selection);
        };
    }
};

void PreferencesDialog::OnCPDetectorDelete(wxCommandEvent& e)
{
    unsigned int selection=m_CPDetectorList->GetSelection();
    if(m_CPDetectorList->GetCount()==1)
    {
        hugin_utils::HuginMessageBox(_("You can't delete the last setting.\nAt least one setting is required."), _("Hugin"), wxOK | wxICON_EXCLAMATION, this);
    }
    else
    {
        if (hugin_utils::HuginMessageBox(wxString::Format(_("Do you really want to remove control point detector setting \"%s\"?"), cpdetector_config_edit.settings[selection].GetCPDetectorDesc()),
            _("Hugin"), wxYES_NO | wxICON_QUESTION, this) == wxYES)
        {
            if(cpdetector_config_edit.GetDefaultGenerator()==selection)
            {
                cpdetector_config_edit.SetDefaultGenerator(0);
            }
            cpdetector_config_edit.settings.RemoveAt(selection);
            cpdetector_config_edit.FillControl(m_CPDetectorList,false,true);
            if(selection>=m_CPDetectorList->GetCount())
            {
                selection=m_CPDetectorList->GetCount()-1;
            }
            m_CPDetectorList->SetSelection(selection);
        };
    };
};

void PreferencesDialog::OnCPDetectorMoveUp(wxCommandEvent& e)
{
    unsigned int selection=m_CPDetectorList->GetSelection();
    if(selection>0)
    {
        cpdetector_config_edit.Swap(selection-1);
        cpdetector_config_edit.FillControl(m_CPDetectorList,false,true);
        m_CPDetectorList->SetSelection(selection-1);
    };
};

void PreferencesDialog::OnCPDetectorMoveDown(wxCommandEvent& e)
{
    unsigned int selection=m_CPDetectorList->GetSelection();
    if(selection<m_CPDetectorList->GetCount()-1)
    {
        cpdetector_config_edit.Swap(selection);
        cpdetector_config_edit.FillControl(m_CPDetectorList,false,true);
        m_CPDetectorList->SetSelection(selection+1);
    };
};

void PreferencesDialog::OnCPDetectorDefault(wxCommandEvent& e)
{
    unsigned int selection=m_CPDetectorList->GetSelection();
    if(selection!=cpdetector_config_edit.GetDefaultGenerator())
    {
        cpdetector_config_edit.SetDefaultGenerator(selection);
        cpdetector_config_edit.FillControl(m_CPDetectorList,false,true);
        m_CPDetectorList->SetSelection(selection);
    };
};

void PreferencesDialog::OnCPDetectorLoad(wxCommandEvent& e)
{
    wxFileDialog dlg(this,_("Load control point detector settings"),
                     wxConfigBase::Get()->Read("/actualPath",wxEmptyString), wxEmptyString,
                     _("Control point detector settings (*.setting)|*.setting"),wxFD_OPEN | wxFD_FILE_MUST_EXIST);
    if (dlg.ShowModal() == wxID_OK)
    {
        wxConfig::Get()->Write("/actualPath", dlg.GetDirectory());  // remember for later
        wxString fn = dlg.GetPath();
        cpdetector_config_edit.ReadFromFile(fn);
        cpdetector_config_edit.Write();
        UpdateDisplayData(5);
    };
};

void PreferencesDialog::OnCPDetectorSave(wxCommandEvent& e)
{
    wxFileDialog dlg(this,_("Save control point detector settings"),
                     wxConfigBase::Get()->Read("/actualPath",wxEmptyString), wxEmptyString,
                     _("Control point detector settings (*.setting)|*.setting"),wxFD_SAVE | wxFD_OVERWRITE_PROMPT);
    if (dlg.ShowModal() == wxID_OK)
    {
        wxConfig::Get()->Write("/actualPath", dlg.GetDirectory());  // remember for later
        wxString fn = dlg.GetPath();
#ifndef __WXMSW__
        //append extension if not given
        //not necessary on Windows, the wxFileDialog appends it automatic
        if(fn.Right(8)!=".setting")
        {
            fn.Append(".setting");
        };
#endif
        cpdetector_config_edit.WriteToFile(fn);
    };
};

void PreferencesDialog::OnFileFormatChanged(wxCommandEvent& e)
{
    UpdateFileFormatControls();
};

void PreferencesDialog::UpdateFileFormatControls()
{
    int i=MY_G_CHOICE_VAL("pref_ldr_output_file_format");
    XRCCTRL(*this,"pref_tiff_compression_label",wxStaticText)->Show(i==0);
    XRCCTRL(*this,"pref_tiff_compression",wxChoice)->Show(i==0);
    XRCCTRL(*this,"pref_jpeg_quality_label",wxStaticText)->Show(i==1);
    XRCCTRL(*this,"pref_jpeg_quality",wxSpinCtrl)->Show(i==1);
    XRCCTRL(*this,"pref_tiff_compression",wxChoice)->GetParent()->Layout();
};

void PreferencesDialog::OnProcessorChanged(wxCommandEvent& e)
{
    UpdateProcessorControls();
};

void PreferencesDialog::UpdateProcessorControls()
{
    int i=MY_G_CHOICE_VAL("pref_processor_gui");
    XRCCTRL(*this,"pref_processor_start",wxCheckBox)->Enable(i==0);
    XRCCTRL(*this,"pref_processor_verbose",wxCheckBox)->Enable(i==0);
    switch(i)
    {
        case 0:
            //PTBatcherGUI
            {
                wxConfigBase* config=wxConfigBase::Get();
                XRCCTRL(*this,"pref_processor_start",wxCheckBox)->SetValue(config->Read("/Processor/start", HUGIN_PROCESSOR_START) == 1);
                XRCCTRL(*this,"pref_processor_verbose",wxCheckBox)->SetValue(config->Read("/Processor/verbose", HUGIN_PROCESSOR_VERBOSE) == 1);
            }
            break;
        case 1:
            //Hugin_stitch_project
            XRCCTRL(*this,"pref_processor_start",wxCheckBox)->SetValue(true);
            XRCCTRL(*this,"pref_processor_verbose",wxCheckBox)->SetValue(true);
            break;
    };
};

void PreferencesDialog::OnBlenderChanged(wxCommandEvent & e)
{
    UpdateBlenderControls();
};

void PreferencesDialog::UpdateBlenderControls()
{
    const int blender = MY_G_CHOICE_VAL("pref_default_blender");
    XRCCTRL(*this, "pref_internal_blender_seam_label", wxStaticText)->Show(blender == 1);
    wxChoice* seamChoice = XRCCTRL(*this, "pref_internal_blender_seam", wxChoice);
    seamChoice->Show(blender == 1);
    seamChoice->Enable(blender == 1);
};

void PreferencesDialog::OnUpdateProjectFilename(wxCommandEvent& e)
{
    XRCCTRL(*this, "prefs_project_filename_preview", wxStaticText)->SetLabel(
        getDefaultProjectName(MainFrame::Get()->getPanorama(), XRCCTRL(*this, "prefs_project_filename", wxTextCtrl)->GetValue())
    );
};

void PreferencesDialog::OnUpdateOutputFilename(wxCommandEvent& e)
{
    XRCCTRL(*this, "prefs_output_filename_preview", wxStaticText)->SetLabel(
        getDefaultOutputName(MainFrame::Get()->getProjectName(), MainFrame::Get()->getPanorama(), XRCCTRL(*this, "prefs_output_filename", wxTextCtrl)->GetValue())
    );
};

void PreferencesDialog::OnUserDefinedOutputOptionsCheckBox(wxCommandEvent& e)
{
    //enable/disable button related to user defined output options of assistant
    XRCCTRL(*this, "pref_ass_change_output", wxButton)->Enable(XRCCTRL(*this, "pref_ass_output", wxCheckBox)->IsChecked());
}

void PreferencesDialog::OnChangeUserDefinedOutputOptions(wxCommandEvent& e)
{
    // show dialog to change user defined output options of assistant
    EditOutputIniDialog dlg(this);
    dlg.ShowModal();
}
