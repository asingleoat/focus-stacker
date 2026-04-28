// -*- c-basic-offset: 4 -*-
/** @file PreviewWindow.cpp
 *
 *  @brief implementation of PreviewWindow class
 *
 *  @author Thomas Modes
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

#include "PreviewWindow.h"
#include <wx/dcbuffer.h>
#include <wx/dcclient.h>
#include "ToolboxApp.h"
#include "base_wx/platform.h"

// our image control
bool PreviewWindow::Create(wxWindow* parent, wxWindowID id, const wxPoint& pos, const wxSize& size, long style, const wxString& name)
{
    wxScrolledWindow::Create(parent, id, pos, size, style, name);
    m_scaleFactor = 1.0;
    m_fitToWindow = true;
    SetBackgroundStyle(wxBG_STYLE_PAINT);
    // bind event handler
    Bind(wxEVT_SIZE, &PreviewWindow::OnSize, this);
    Bind(wxEVT_PAINT, &PreviewWindow::OnPaint, this);

    return true;
}

void PreviewWindow::setImage(const wxString& file)
{
    if(!file.IsEmpty() && wxFileExists(file))
    {
        m_iccProfile.clear();
        try
        {
            m_image.LoadFile(file);
            // load also icc profile
            vigra::ImageImportInfo info(file.mb_str(HUGIN_CONV_FILENAME));
            m_iccProfile = info.getICCProfile();
        }
        catch (...)
        {
            m_image.Destroy();
            SetVirtualSize(100, 100);
            Refresh(true);
            return;
        }
        rescaleImage();
        Refresh();
    }
    else
    {
        m_image.Destroy();
        SetVirtualSize(100,100);
        Refresh(true);
    }
}

void PreviewWindow::OnPaint(wxPaintEvent& e)
{
    wxAutoBufferedPaintDC dc(this);
    PrepareDC(dc);
    dc.SetBackground(GetBackgroundColour());
    dc.Clear();
    if (m_bitmap.IsOk())
    {
        // draw bitmap
        dc.DrawBitmap(m_bitmap, 0, 0);
    };
}

void PreviewWindow::OnSize(wxSizeEvent &e)
{
    // rescale m_bitmap if needed.
    if (m_image.IsOk())
    {
        if (m_fitToWindow)
        {
            setScale(0);
        }
    }
}

void PreviewWindow::rescaleImage()
{
    if (m_image.GetWidth() == 0)
    {
        return;
    }
    wxSize realSize = m_image.GetSize();
    if (m_fitToWindow)
    {
        m_scaleFactor = calcAutoScaleFactor(m_image.GetSize());
    };

    //scaling image to screen size
    wxImage img;
    if (getScaleFactor()!=1.0)
    {
        realSize.SetWidth(scale(m_image.GetWidth()));
        realSize.SetHeight(scale(m_image.GetHeight()));
        wxImageResizeQuality resizeQuality = wxIMAGE_QUALITY_NORMAL;
        if (std::max(m_image.GetWidth(), m_image.GetHeight()) > (ULONG_MAX >> 16))
        {
            // wxIMAGE_QUALITY_NORMAL resizes the image with ResampleNearest
            // this algorithm works only if image dimensions are smaller then 
            // ULONG_MAX >> 16 (actual size of unsigned long differ from system
            // to system)
            resizeQuality = wxIMAGE_QUALITY_BOX_AVERAGE;
        };
        img=m_image.Scale(realSize.GetWidth(), realSize.GetHeight(), resizeQuality);
    }
    else
    {
        //therefore we need to create a copy to work on it
        img=m_image.Copy();
    };
    // do color correction only if input image has icc profile or if we found a monitor profile
    if (!m_iccProfile.empty() || wxGetApp().GetToolboxFrame()->HasMonitorProfile())
    {
        HuginBase::Color::CorrectImage(img, m_iccProfile, wxGetApp().GetToolboxFrame()->GetMonitorProfile());
    };
    m_bitmap=wxBitmap(img);
    SetVirtualSize(realSize);
    SetScrollRate(1, 1);
    Refresh(true);
}

void PreviewWindow::setScale(double factor)
{
    if (factor == 0)
    {
        m_fitToWindow = true;
        factor = calcAutoScaleFactor(m_image.GetSize());
    }
    else
    {
        m_fitToWindow = false;
    }
    // update if factor changed
    if (factor != m_scaleFactor)
    {
        m_scaleFactor = factor;
        // keep existing scale focussed.
        rescaleImage();
    }
}

double PreviewWindow::getScale()
{ 
    return m_fitToWindow ? 0 : m_scaleFactor; 
}


double PreviewWindow::calcAutoScaleFactor(wxSize size)
{
    const int w = size.GetWidth();
    const int h = size.GetHeight();
    const wxSize csize = GetSize();
    const double s1 = (double)csize.GetWidth() / w;
    const double s2 = (double)csize.GetHeight() / h;
    return s1 < s2 ? s1 : s2;
}

double PreviewWindow::getScaleFactor() const
{
    return m_scaleFactor;
}

int PreviewWindow::scale(int x) const
{  
    return (int) (x * getScaleFactor() + 0.5); 
}

double PreviewWindow::scale(double x) const
{
    return x * getScaleFactor(); 
}

IMPLEMENT_DYNAMIC_CLASS(PreviewWindow, wxScrolledWindow)
