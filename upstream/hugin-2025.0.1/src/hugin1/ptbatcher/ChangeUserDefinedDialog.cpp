// -*- c-basic-offset: 4 -*-

/** @file FindPanoDialog.cpp
 *
 *  @brief implementation of dialog to change user defined sequence
 *
 *  @author T. Modes
 *
 */

/*  This is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU General Public
 *  License as published by the Free Software Foundation; either
 *  version 2 of the License, or (at your option) any later version.
 *
 *  This software is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *  Lesser General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public
 *  License along with this software. If not, see
 *  <http://www.gnu.org/licenses/>.
 *
 */

#include "ChangeUserDefinedDialog.h"
#include <wx/dir.h>
#include <wx/stdpaths.h>
#include <wx/wfstream.h>
#include "base_wx/Executor.h"
#include "base_wx/wxutils.h"
#if defined __WXMAC__ && defined MAC_SELF_CONTAINED_BUNDLE
#include "base_wx/platform.h"
#endif

ChangeUserDefinedSequenceDialog::ChangeUserDefinedSequenceDialog(wxWindow* parent, wxString xrcPrefix, wxString userDefinedSequence, bool assistantUserDefined)
{
    // load our children. some children might need special
    // initialization. this will be done later.
    wxXmlResource::Get()->LoadDialog(this, parent, "change_user_defined_dialog");

    m_radio_default = XRCCTRL(*this, "radio_default_sequence", wxRadioButton);
    m_radio_default->Bind(wxEVT_RADIOBUTTON, &ChangeUserDefinedSequenceDialog::UpdateStatus, this);
    m_radio_user_sequence = XRCCTRL(*this, "radio_user_defined", wxRadioButton);
    m_radio_user_sequence->Bind(wxEVT_RADIOBUTTON, &ChangeUserDefinedSequenceDialog::UpdateStatus, this);
    m_choice_user_define=XRCCTRL(*this, "choice_user_defined", wxChoice);
    m_choice_user_define->Bind(wxEVT_CHOICE, &ChangeUserDefinedSequenceDialog::OnChangeUserDefinedChoice, this);
    m_label_user_define = XRCCTRL(*this, "label_user_defined", wxStaticText);
    m_label_user_define_filename = XRCCTRL(*this, "label_user_defined_filename", wxStaticText);
    m_radio_external = XRCCTRL(*this, "radio_external_sequence", wxRadioButton);
    m_radio_external->Bind(wxEVT_RADIOBUTTON, &ChangeUserDefinedSequenceDialog::UpdateStatus, this);
    m_text_external_file = XRCCTRL(*this, "text_external_file", wxTextCtrl);
    m_text_external_file->AutoCompleteFileNames();
    m_button_external_file = XRCCTRL(*this, "button_external_file", wxButton);
    m_button_external_file->Bind(wxEVT_BUTTON, &ChangeUserDefinedSequenceDialog::OnChooseFilename, this);

    m_isAssistantUserDefined = assistantUserDefined;
    if (m_isAssistantUserDefined)
    {
        FillAssistantUserDefined();
    }
    else
    {
        FillStitcherUserDefined();
    };
    if (userDefinedSequence.IsEmpty())
    {
        m_radio_default->SetValue(true);
    }
    else
    {
        int index = m_userFileNames.Index(userDefinedSequence);
        if (index == wxNOT_FOUND)
        {
            // user defined sequence not found in list
            // so use external entry
            m_radio_external->SetValue(true);
            m_text_external_file->SetValue(userDefinedSequence);
        }
        else
        {
            // item found in list
            m_radio_user_sequence->SetValue(true);
            m_choice_user_define->Select(index);
        };
    };
    wxCommandEvent dummy;
    UpdateStatus(dummy);

    //set parameters
    wxConfigBase* config = wxConfigBase::Get();
    // restore position and size
    int dx,dy;
    wxDisplaySize(&dx,&dy);
    //size
    int w = config->Read("/UserDefinedSequenceDialog/width", -1l);
    int h = config->Read("/UserDefinedSequenceDialog/height", -1l);
    if (w > 0 && w <= dx)
    {
        this->SetClientSize(w,h);
    }
    else
    {
        this->Fit();
    }
    //position
    int x = config->Read("/UserDefinedSequenceDialog/positionX", -1l);
    int y = config->Read("/UserDefinedSequenceDialog/positionY", -1l);
    if ( y >= 0 && x >= 0 && x < dx && y < dy)
    {
        this->Move(x, y);
    }
    else
    {
        this->Move(0, 44);
    }
    Bind(wxEVT_BUTTON, &ChangeUserDefinedSequenceDialog::OnOk, this, wxID_OK);
}

ChangeUserDefinedSequenceDialog::~ChangeUserDefinedSequenceDialog()
{
    wxConfigBase* config=wxConfigBase::Get();
    wxSize sz = this->GetClientSize();
    config->Write("/UserDefinedSequenceDialog/width", sz.GetWidth());
    config->Write("/UserDefinedSequenceDialog/height", sz.GetHeight());
    wxPoint ps = this->GetPosition();
    config->Write("/UserDefinedSequenceDialog/positionX", ps.x);
    config->Write("/UserDefinedSequenceDialog/positionY", ps.y);
}

void ChangeUserDefinedSequenceDialog::UpdateStatus(wxCommandEvent& e)
{
    m_choice_user_define->Enable(m_radio_user_sequence->GetValue());
    m_label_user_define->Enable(m_radio_user_sequence->GetValue());
    m_label_user_define_filename->Enable(m_radio_user_sequence->GetValue());
    m_text_external_file->Enable(m_radio_external->GetValue());
    m_button_external_file->Enable(m_radio_external->GetValue());
}

void ChangeUserDefinedSequenceDialog::OnChangeUserDefinedChoice(wxCommandEvent& e)
{
    // update help text 
    const long id = e.GetSelection();
    if (id >= 0 && id < m_userHelpTexts.size())
    {
        m_label_user_define_filename->SetLabel(m_userFileNames[id]);
        m_label_user_define->SetLabel(m_userHelpTexts[id]);
    };
}

void ChangeUserDefinedSequenceDialog::OnChooseFilename(wxCommandEvent& e)
{
    wxFileDialog userOutputDlg(this, (m_isAssistantUserDefined ? _("Select user defined assistant") : _("Select user defined output")),
        m_text_external_file->GetValue(), wxEmptyString, (m_isAssistantUserDefined ? _("User defined assistant|*.assistant") : _("User defined output|*.executor")),
        wxFD_OPEN | wxFD_FILE_MUST_EXIST, wxDefaultPosition);
    if (userOutputDlg.ShowModal() == wxID_OK)
    {
        m_text_external_file->SetValue(userOutputDlg.GetPath());
    };
}

void ChangeUserDefinedSequenceDialog::OnOk(wxCommandEvent& e)
{
    if (m_radio_external->GetValue())
    {
        // check that a valid file was given
        wxString filename = m_text_external_file->GetValue();
        if (filename.IsEmpty())
        {
            hugin_utils::HuginMessageBox(_("Please provide a filename to the user defined sequence."), _("PTBatcherGUI"), wxOK | wxOK_DEFAULT | wxICON_WARNING, this);
                return;
        };
        if (!wxFileName::FileExists(filename))
        {
            hugin_utils::HuginMessageBox(wxString::Format(_("The file \"%s\" does not exists.\nPlease provide an existing file to the user defined sequence."), filename),
                _("PTBatcherGUI"), wxOK | wxOK_DEFAULT | wxICON_WARNING, this);
            return;
        };
    }
    EndModal(wxID_OK);
}

wxString ChangeUserDefinedSequenceDialog::GetNewSequence()
{
    if (m_radio_default->GetValue())
    {
        return wxEmptyString;
    };
    if (m_radio_user_sequence->GetValue())
    {
        if (m_choice_user_define->GetCount() > 0 && m_choice_user_define->GetSelection() != wxNOT_FOUND)
        {
            return m_userFileNames[m_choice_user_define->GetSelection()];
        }
        else
        {
            return wxEmptyString;
        };
    };
    return m_text_external_file->GetValue();
}

/** return path to data directory, it depends on operating system */
wxString GetDataPath()
{
#if defined __WXMSW__
    wxFileName exePath(wxStandardPaths::Get().GetExecutablePath());
    exePath.RemoveLastDir();
    const wxString huginRoot = exePath.GetPath(wxPATH_GET_VOLUME | wxPATH_GET_SEPARATOR);
    return huginRoot + "share\\hugin\\data\\";
#elif defined __WXMAC__ && defined MAC_SELF_CONTAINED_BUNDLE
    // initialize paths
    {
        wxString thePath = MacGetPathToBundledResourceFile(CFSTR("xrc"));
        if (thePath.IsEmpty())
        {
            hugin_utils::HuginMessageBox(_("xrc directory not found in bundle"), _("PTBatcherGUI"), wxOK|wxICON_ERROR, wxGetActiveWindow());
            return wxEmptyString;
        }
        return thePath + "/";
    }
#elif defined UNIX_SELF_CONTAINED_BUNDLE
    // initialize paths
    {
        wxFileName exePath(wxStandardPaths::Get().GetExecutablePath());
        exePath.RemoveLastDir();
        const wxString huginRoot = exePath.GetPath(wxPATH_GET_VOLUME | wxPATH_GET_SEPARATOR);
        return huginRoot + "share/hugin/data/";
    }
#else
    // add the locale directory specified during configure
    return INSTALL_DATA_DIR;
#endif
}

void ChangeUserDefinedSequenceDialog::FillAssistantUserDefined()
{
    wxArrayString files;
    // search all .assistant files, do not follow links
    wxDir::GetAllFiles(GetDataPath() + "assistant", &files, "*.assistant", wxDIR_FILES | wxDIR_HIDDEN | wxDIR_NO_FOLLOW);
    wxDir::GetAllFiles(hugin_utils::GetUserAppDataDir(), &files, "*.assistant", wxDIR_FILES | wxDIR_HIDDEN | wxDIR_NO_FOLLOW);
    FillUserDefinedChoice(files);
}

void ChangeUserDefinedSequenceDialog::FillStitcherUserDefined()
{
    wxArrayString files;
    // search all .executor files, do not follow links
    wxDir::GetAllFiles(GetDataPath() + "output", &files, "*.executor", wxDIR_FILES | wxDIR_HIDDEN | wxDIR_NO_FOLLOW);
    wxDir::GetAllFiles(hugin_utils::GetUserAppDataDir(), &files, "*.executor", wxDIR_FILES | wxDIR_HIDDEN | wxDIR_NO_FOLLOW);
    FillUserDefinedChoice(files);
}

void ChangeUserDefinedSequenceDialog::FillUserDefinedChoice(const wxArrayString& files)
{
    if (!files.IsEmpty())
    {
        for (auto file : files)
        {
            // read all files
            wxFileInputStream inputStream(file);
            if (inputStream.IsOk())
            {
                // read descriptions from file
                wxFileConfig executorFile(inputStream);
                wxString desc = HuginQueue::GetSettingStringTranslated(&executorFile, "/General/Description", wxEmptyString);
                if (desc.IsEmpty())
                {
                    desc = file;
                };
                wxString help = HuginQueue::GetSettingStringTranslated(&executorFile, "/General/Help", wxEmptyString);
                if (help.IsEmpty())
                {
                    help = wxString::Format(_("User defined sequence: %s"), file);
                };
                // add to wxChoice and remember help text
                m_choice_user_define->AppendString(desc);
                m_userFileNames.Add(file);
                m_userHelpTexts.Add(help);
            };
        };
        if (m_choice_user_define->GetCount() > 0)
        {
            m_choice_user_define->Select(0);
            wxCommandEvent dummy;
            dummy.SetInt(0);
            OnChangeUserDefinedChoice(dummy);
        };
    };
}
