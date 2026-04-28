// -*- c-basic-offset: 4 -*-
/** @file PreviewWindow.h
 *
 *  @brief declaration of PreviewWindow class
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

#ifndef PREVIEWWINDOW_H
#define PREVIEWWINDOW_H

#include <wx/scrolwin.h>
#include <wx/bitmap.h>
#include <wx/image.h>
#include "base_wx/wxcms.h"

/** @brief preview window
 *
 *  This class handles display of an image at different zoom ratio 
 */
class PreviewWindow : public wxScrolledWindow
{
public:
    /** create the control */
    bool Create(wxWindow* parent, wxWindowID id = wxID_ANY, const wxPoint& pos = wxDefaultPosition, const wxSize& size = wxDefaultSize, long style = wxTAB_TRAVERSAL, const wxString& name = "panel");
    /** set the current image and mask list, this loads also the image from cache */
    void setImage (const wxString& filename);
    /** set the scaling factor f.
     *
     *  @param factor zoom factor, 0 means fit to window.
     */
    void setScale(double factor);
    /** return scale factor, 0 for autoscale */
    double getScale();
    /** drawing routine */
    void OnPaint(wxPaintEvent& e);
protected:
    /** handler called when size of control was changed */
    void OnSize(wxSizeEvent & e);
    /** get scale factor (calculates factor when fit to window is active) */
    double getScaleFactor() const;
    /** calculate new scale factor for this image */
    double calcAutoScaleFactor(wxSize size);
    /** rescale the image */
    void rescaleImage();
 private:
    //orignal image
    wxImage m_image;
    // scaled bitmap
    wxBitmap m_bitmap;
    /** helper function to scale of width/height */
    int scale(int x) const;
    double scale(double x) const;
    /** store current scale factor */
    double m_scaleFactor{ 1.0 };
    bool m_fitToWindow{ false };
    /** remember icc profile of currently loaded file */
    vigra::ImageImportInfo::ICCProfile m_iccProfile;
    DECLARE_DYNAMIC_CLASS(PreviewWindow)
};

#endif // PREVIEWWINDOW_H
