// -*- c-basic-offset: 4 -*-

/** @file ResetDialog.cpp
 *
 *	@brief implementation of ResetDialog class
 *
 *  @author Thomas Modes
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

#include "hugin/ResetDialog.h"
#include "base_wx/wxPlatform.h"
#include "panoinc.h"

#include "hugin/huginApp.h"

ResetDialog::ResetDialog(wxWindow *parent, GuiLevel guiLevel)
{
    // load our children. some children might need special
    // initialization. this will be done later.
    wxXmlResource::Get()->LoadDialog(this, parent, "reset_dialog");

    //set parameters
    wxConfigBase * cfg = wxConfigBase::Get();
    bool check;
    cfg->Read("/ResetDialog/ResetPosition",&check,true);
    XRCCTRL(*this,"reset_pos",wxCheckBox)->SetValue(check);
    cfg->Read("/ResetDialog/ResetTranslation", &check, true);
    wxCheckBox* reset_translation=XRCCTRL(*this,"reset_translation",wxCheckBox);
    reset_translation->SetValue(check);
    if(guiLevel<GUI_EXPERT)
    {
        reset_translation->Hide();
    };
    cfg->Read("/ResetDialog/ResetFOV",&check,true);
    XRCCTRL(*this,"reset_fov",wxCheckBox)->SetValue(check);
    cfg->Read("/ResetDialog/ResetLens",&check,true);
    XRCCTRL(*this,"reset_lens",wxCheckBox)->SetValue(check);
    cfg->Read("/ResetDialog/ResetExposure",&check,true);
    wxCheckBox* checkbox = XRCCTRL(*this, "reset_exposure", wxCheckBox);
    checkbox->SetValue(check);
    checkbox->Bind(wxEVT_CHECKBOX, &ResetDialog::OnSelectExposure, this);
    int exp_param;
    cfg->Read("/ResetDialog/ResetExposureParam",&exp_param,0);
    XRCCTRL(*this,"combo_exposure",wxComboBox)->Select(exp_param);
    wxCommandEvent dummy;
    OnSelectExposure(dummy);
    cfg->Read("/ResetDialog/ResetColor",&check,true);
    checkbox = XRCCTRL(*this, "reset_color", wxCheckBox);
    checkbox->SetValue(check);
    checkbox->Bind(wxEVT_CHECKBOX, &ResetDialog::OnSelectColor, this);
    cfg->Read("/ResetDialog/ResetColorParam",&exp_param,0);
    OnSelectColor(dummy);
    XRCCTRL(*this,"combo_color",wxComboBox)->Select(exp_param);
    cfg->Read("/ResetDialog/ResetVignetting",&check,true);
    XRCCTRL(*this,"reset_vignetting",wxCheckBox)->SetValue(check);
    cfg->Read("/ResetDialog/ResetResponse",&check,true);
    XRCCTRL(*this,"reset_response",wxCheckBox)->SetValue(check);
    GetSizer()->Fit(this);
    //position
    int x = cfg->Read("/ResetDialog/positionX",-1l);
    int y = cfg->Read("/ResetDialog/positionY",-1l);
    if ( y >= 0 && x >= 0) 
    {
        this->Move(x, y);
    } 
    else 
    {
        this->Move(0, 44);
    };
    Bind(wxEVT_BUTTON, &ResetDialog::OnOk, this, wxID_OK);
};

void ResetDialog::LimitToGeometric()
{
    XRCCTRL(*this,"reset_exposure",wxCheckBox)->Show(false);
    XRCCTRL(*this,"combo_exposure",wxComboBox)->Show(false);
    XRCCTRL(*this,"reset_color",wxCheckBox)->Show(false);
    XRCCTRL(*this,"combo_color",wxComboBox)->Show(false);
    XRCCTRL(*this,"reset_vignetting",wxCheckBox)->Show(false);
    XRCCTRL(*this,"reset_response",wxCheckBox)->Show(false);
    GetSizer()->Fit(this);
};

void ResetDialog::LimitToPhotometric()
{
    XRCCTRL(*this,"reset_pos",wxCheckBox)->Show(false);
    XRCCTRL(*this,"reset_translation",wxCheckBox)->Show(false);
    XRCCTRL(*this,"reset_fov",wxCheckBox)->Show(false);
    XRCCTRL(*this,"reset_lens",wxCheckBox)->Show(false);
    GetSizer()->Fit(this);
};

void ResetDialog::OnOk(wxCommandEvent & e)
{
    wxConfigBase * cfg = wxConfigBase::Get();
    wxPoint ps = this->GetPosition();
    cfg->Write("/ResetDialog/positionX", ps.x);
    cfg->Write("/ResetDialog/positionY", ps.y);
    cfg->Write("/ResetDialog/ResetPosition",GetResetPos());
    cfg->Write("/ResetDialog/ResetTranslation", GetResetTranslation());
    cfg->Write("/ResetDialog/ResetFOV",GetResetFOV());
    cfg->Write("/ResetDialog/ResetLens",GetResetLens());
    cfg->Write("/ResetDialog/ResetExposure",GetResetExposure());
    int exp_param;
    exp_param=XRCCTRL(*this,"combo_exposure",wxComboBox)->GetSelection();
    cfg->Write("/ResetDialog/ResetExposureParam",exp_param);
    cfg->Write("/ResetDialog/ResetColor",GetResetColor());
    exp_param=XRCCTRL(*this,"combo_color",wxComboBox)->GetSelection();
    cfg->Write("/ResetDialog/ResetColorParam", exp_param);
    cfg->Write("/ResetDialog/ResetVignetting",GetResetVignetting());
    cfg->Write("/ResetDialog/ResetResponse",GetResetResponse());
    cfg->Flush();
    e.Skip();
};

void ResetDialog::OnSelectExposure(wxCommandEvent & e)
{
    XRCCTRL(*this,"combo_exposure",wxComboBox)->Enable(XRCCTRL(*this, "reset_exposure", wxCheckBox)->GetValue());
};

void ResetDialog::OnSelectColor(wxCommandEvent & e)
{
    XRCCTRL(*this,"combo_color",wxComboBox)->Enable(XRCCTRL(*this, "reset_color", wxCheckBox)->GetValue());
};

bool ResetDialog::GetResetPos()
{
    return XRCCTRL(*this, "reset_pos", wxCheckBox)->GetValue();
};

bool ResetDialog::GetResetTranslation()
{
    return XRCCTRL(*this, "reset_translation", wxCheckBox)->GetValue();
};

bool ResetDialog::GetResetFOV()
{
    return XRCCTRL(*this, "reset_fov", wxCheckBox)->GetValue();
};

bool ResetDialog::GetResetLens()
{
    return XRCCTRL(*this, "reset_lens", wxCheckBox)->GetValue();
};

bool ResetDialog::GetResetExposure()
{
    return XRCCTRL(*this, "reset_exposure", wxCheckBox)->GetValue();
};

bool ResetDialog::GetResetExposureToExif()
{
    if(!GetResetExposure())
        return false;
    return XRCCTRL(*this, "combo_exposure", wxComboBox)->GetSelection()==0;
};

bool ResetDialog::GetResetColor()
{
    return XRCCTRL(*this, "reset_color", wxCheckBox)->GetValue();
};

bool ResetDialog::GetResetColorToExif()
{
    if(!GetResetColor())
        return false;
    return XRCCTRL(*this, "combo_color", wxComboBox)->GetSelection()==0;
};

bool ResetDialog::GetResetVignetting()
{
    return XRCCTRL(*this, "reset_vignetting", wxCheckBox)->GetValue();
};

bool ResetDialog::GetResetResponse()
{
    return XRCCTRL(*this, "reset_response", wxCheckBox)->GetValue();
};
