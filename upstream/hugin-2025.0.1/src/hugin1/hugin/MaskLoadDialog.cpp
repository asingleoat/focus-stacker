// -*- c-basic-offset: 4 -*-

/** @file MaskLoadDialog.cpp
 *
 *	@brief implementation of mask load dialog
 *
 *  @author Thomas Modes
 *
 *  $Id$
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

#include "hugin/MaskLoadDialog.h"
#include "base_wx/wxPlatform.h"
#include "base_wx/wxutils.h"
#ifdef __APPLE__
#include "panoinc_WX.h"
#include "panoinc.h"
#endif
#include <hugin/config_defaults.h>
#include "hugin/huginApp.h"

MaskLoadDialog::MaskLoadDialog(wxWindow *parent)
{
    wxXmlResource::Get()->LoadDialog(this, parent, "mask_load_dialog");

    m_image=XRCCTRL(*this,"mask_preview",MaskImageCtrl);
    m_image->setPreviewOnly();
    //load and set colours
    wxColour defaultColour;
    defaultColour.Set(HUGIN_MASK_COLOUR_POLYGON_NEGATIVE);
    wxColour colour=wxConfigBase::Get()->Read("/MaskEditorPanel/ColourPolygonNegative",defaultColour.GetAsString(wxC2S_HTML_SYNTAX));
    m_image->SetUserColourPolygonNegative(colour);
    defaultColour.Set(HUGIN_MASK_COLOUR_POLYGON_POSITIVE);
    colour=wxConfigBase::Get()->Read("/MaskEditorPanel/ColourPolygonPositive",defaultColour.GetAsString(wxC2S_HTML_SYNTAX));
    m_image->SetUserColourPolygonPositive(colour);
    defaultColour.Set(HUGIN_MASK_COLOUR_POINT_SELECTED);
    colour=wxConfigBase::Get()->Read("/MaskEditorPanel/ColourPointSelected",defaultColour.GetAsString(wxC2S_HTML_SYNTAX));
    m_image->SetUserColourPointSelected(colour);
    defaultColour.Set(HUGIN_MASK_COLOUR_POINT_UNSELECTED);
    colour=wxConfigBase::Get()->Read("/MaskEditorPanel/ColourPointUnselected",defaultColour.GetAsString(wxC2S_HTML_SYNTAX));
    m_image->SetUserColourPointUnselected(colour);

    m_maskScaleMode=XRCCTRL(*this,"mask_rescale",wxRadioBox);
    m_maskScaleMode->Bind(wxEVT_RADIOBOX, &MaskLoadDialog::ProcessMask, this);
    m_maskRotateMode=XRCCTRL(*this,"mask_rotate",wxRadioBox);
    m_maskRotateMode->Bind(wxEVT_RADIOBOX, &MaskLoadDialog::ProcessMask, this);

    hugin_utils::RestoreFramePosition(this, "MaskLoadDialog");
    if(GetSize().GetWidth()<400)
        SetClientSize(400,GetSize().GetHeight());
};

MaskLoadDialog::~MaskLoadDialog()
{
    hugin_utils::StoreFramePosition(this, "MaskLoadDialog");
};

void MaskLoadDialog::initValues(const HuginBase::SrcPanoImage image, const HuginBase::MaskPolygonVector newMask, const vigra::Size2D maskSize)
{
    HuginBase::MaskPolygonVector emptyMask;
    m_image->setImage(image.getFilename(),newMask,emptyMask,MaskImageCtrl::ROT0);
    m_image->setScale(0);
    m_loadedMask=newMask;
    m_imageSize=image.getSize();
    m_maskSize=maskSize;
    // set dummy value
    if(m_imageSize.width()==0)
        m_imageSize.setWidth(100);
    if(m_imageSize.height()==0)
        m_imageSize.setHeight(100);
    if((m_maskSize.width()==0) || (m_maskSize.height()==0))
        m_maskSize=m_imageSize;
    XRCCTRL(*this,"label_image_size",wxStaticText)->SetLabel(wxString::Format("%d x %d",m_imageSize.width(),m_imageSize.height()));
    XRCCTRL(*this,"label_mask_size",wxStaticText)->SetLabel(wxString::Format("%d x %d",m_maskSize.width(),m_maskSize.height()));
    //if image is rotated, set rotation to clockwise
    if((m_maskSize.width()==m_imageSize.height()) && (m_maskSize.height()==m_imageSize.width()))
        m_maskRotateMode->SetSelection(1);
    wxCommandEvent dummy;
    ProcessMask(dummy);
};

void MaskLoadDialog::ProcessMask(wxCommandEvent &e)
{
    m_processedMask=m_loadedMask;
    if(m_processedMask.empty())
    {
        UpdatePreviewImage();
        return;
    };
    double maskWidth;
    double maskHeight;
    if(m_maskRotateMode->GetSelection()==0)
    {
        maskWidth=m_maskSize.width();
        maskHeight=m_maskSize.height();
    }
    else
    {
        maskWidth=m_maskSize.height();
        maskHeight=m_maskSize.width();
        bool clockwise=(m_maskRotateMode->GetSelection()==1);
        for(unsigned int i=0;i<m_processedMask.size();i++)
            m_processedMask[i].rotate90(clockwise,m_maskSize.width(),m_maskSize.height());
    };
    switch(m_maskScaleMode->GetSelection())
    {
        case 0:
            // clip mask
            for(unsigned int i=0;i<m_processedMask.size();i++)
                m_processedMask[i].clipPolygon(vigra::Rect2D(-0.5*HuginBase::maskOffset,-0.5*HuginBase::maskOffset,
                    m_imageSize.width()+0.5*HuginBase::maskOffset,m_imageSize.height()+0.5*HuginBase::maskOffset));
            break;
        case 1:
            // scale mask
            for(unsigned int i=0;i<m_processedMask.size();i++)
                m_processedMask[i].scale((double)m_imageSize.width()/maskWidth,(double)m_imageSize.height()/maskHeight);
            break;
        case 2:
            // proportional scale mask
            {
                double factor=std::min((double)m_imageSize.width()/maskWidth,(double)m_imageSize.height()/maskHeight);
                for(unsigned int i=0;i<m_processedMask.size();i++)
                    m_processedMask[i].scale(factor);
            };
            break;
    };

    UpdatePreviewImage();
};

void MaskLoadDialog::UpdatePreviewImage()
{
    HuginBase::MaskPolygonVector emptyMask;
    m_image->setNewMasks(m_processedMask,emptyMask);
};
