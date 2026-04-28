// -*- c-basic-offset: 4 -*-
/** @file PerspectivePanel.h
 *
 *  @brief declaration of panel for perspective correction GUI
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

#ifndef PERSPECTIVEPANEL_H
#define PERSPECTIVEPANEL_H

#include "panoinc_WX.h"
#include "wx/clrpicker.h"
#include "PerspectiveImageCtrl.h"
#include "base_wx/MyExternalCmdExecDialog.h"

/** panel for enfuse GUI
 *
 */
class PerspectivePanel : public wxPanel
{
public:
    /** create the panel and populate all controls */
    bool Create(wxWindow* parent, MyExecPanel* logWindow);
    /** clean up temporary files at end */
    void OnProcessFinished(wxCommandEvent& e);
    /** return help text for current mode */
    wxString GetStatusString();
    /** load the given image */
    void SetImage(const wxString& filename);

protected:
    // event handler
    void OnSize(wxSizeEvent& e);
    void OnLoadImage(wxCommandEvent& e);
    void OnZoom(wxCommandEvent& e);
    void OnPreview(wxCommandEvent& e);
    void OnColourChanged(wxColourPickerEvent& e);
    void OnCropChanged(wxCommandEvent& e);
    void OnRotationChanged(wxCommandEvent& e);
    void OnModeChanged(wxCommandEvent& e);
    void OnFindLines(wxCommandEvent& e);
    void OnSavePTO(wxCommandEvent& e);
    void OnSaveOutput(wxCommandEvent& e);

private:
    /** read the values from the input boxes */
    bool ReadInputs();
    /** return Pano object, it is optimized and the crop set when optimized=true */
    bool GetPanorama(HuginBase::Panorama& pano, const bool optimized = true);
    /** return the image rotation */
    const PerspectiveImageCtrl::ImageRotation GetRotation() const;
    /** return the roll angle in degree */
    const double GetRoll() const;
    /** controls */
    PerspectiveImageCtrl* m_preview{ nullptr };
    wxChoice* m_previewChoice{ nullptr };
    wxChoice* m_zoomChoice{ nullptr };
    wxChoice* m_rotationChoice{ nullptr };
    wxChoice* m_modeChoice{ nullptr };
    wxTextCtrl* m_focallengthTextCtrl{ nullptr };
    wxTextCtrl* m_cropTextCtrl{ nullptr };
    wxButton* m_findLineButton{ nullptr };
    wxButton* m_outputButton{ nullptr };
    wxStaticText* m_helpTextCtrl{ nullptr };
    MyExecPanel* m_logWindow{ nullptr };
    /** SrcPanoImage, contains information about the image */
    HuginBase::SrcPanoImage m_srcImage;
    /** save rotation as written in EXIF */
    PerspectiveImageCtrl::ImageRotation m_exifRotation{ PerspectiveImageCtrl::ROT0 };
    int m_degDigits{ 3 };
    /** temp files, which should be deleted at end */
    wxArrayString m_tempFiles;
    DECLARE_DYNAMIC_CLASS(PerspectivePanel)
};

#endif // PERSPECTIVEPANEL_H
