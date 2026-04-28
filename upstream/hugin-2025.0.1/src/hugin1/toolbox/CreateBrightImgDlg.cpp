// -*- c-basic-offset: 4 -*-
/** @file CreateBrightImgDlg.cpp
 *
 *  @brief implementation of dialog class to create brighter/darker versions of the image
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

#include "CreateBrightImgDlg.h"
#include "ToolboxApp.h"
#include <vigra/impex.hxx>
#include <wx/busyinfo.h>
#include <wx/stdpaths.h>
#include "base_wx/wxutils.h"
#include "base_wx/platform.h"
#include "base_wx/wxcms.h"
#include "base_wx/Executor.h"
#include "ToolboxApp.h"

/** creates a brighter or darker version of the input image using HuginBase::Photometric::InvResponse */
template <class PixelType>
vigra::BasicImage<vigra::RGBValue<PixelType>> CreateBrightVersion(const vigra::BasicImage<vigra::RGBValue<PixelType>>& input, const double correction)
{
    HuginBase::SrcPanoImage srcImage;
    srcImage.setSize(input.size());
    // build inverse response transform
    HuginBase::Photometric::InvResponseTransform<PixelType, PixelType> invResponse(srcImage);
    std::vector<PixelType> outLut;
    vigra_ext::EMoR::createEMoRLUT(srcImage.getEMoRParams(), outLut);
    vigra_ext::enforceMonotonicity(outLut);
    invResponse.setOutput(1.0 / std::pow(2.0, srcImage.getExposureValue() - correction), outLut, 1);
    // now do photometric transformation
    vigra::BasicImage<vigra::RGBValue<PixelType>> output(input.size());
    vigra_ext::transformImageSpatial(vigra::srcImageRange(input), vigra::destImage(output), invResponse, vigra::Diff2D(0, 0));
    return output;
}

CreateBrightImgDlg::CreateBrightImgDlg(wxWindow *parent)
{
    // load from xrc
    wxXmlResource::Get()->LoadDialog(this, parent, "enfuse_create_file");
    // get pointer to some controls
    m_stepWidthChoice = XRCCTRL(*this, "create_bright_choice_step_width", wxChoice);
    m_levelChoice = XRCCTRL(*this, "create_bright_choice_levels", wxChoice);
    m_exposuresListBox = XRCCTRL(*this, "create_bright_listctrl", wxListCtrl);
    m_exposuresListBox->InsertColumn(0, _("Exposure value (EV)"), wxLIST_FORMAT_LEFT, wxLIST_AUTOSIZE_USEHEADER);
    m_exposuresListBox->EnableCheckBoxes(true);
    m_previewBitmap = XRCCTRL(*this, "create_bright_preview", wxStaticBitmap);
    // load image size and position
    hugin_utils::RestoreFramePosition(this, "ToolboxFrame/CreateBrighterDarkerImageDialog");
    // bind event handler
    Bind(wxEVT_BUTTON, &CreateBrightImgDlg::OnOk, this, wxID_OK);
    m_stepWidthChoice->Bind(wxEVT_CHOICE, &CreateBrightImgDlg::OnCreateExposureLevels, this);
    m_levelChoice->Bind(wxEVT_CHOICE, &CreateBrightImgDlg::OnCreateExposureLevels, this);
    m_exposuresListBox->Bind(wxEVT_LIST_ITEM_SELECTED, &CreateBrightImgDlg::OnExposureSelected, this);
    m_exposuresListBox->Bind(wxEVT_LIST_ITEM_CHECKED, &CreateBrightImgDlg::OnExposureChecked, this);
    Bind(wxEVT_SIZE, &CreateBrightImgDlg::OnSize, this);
    // fill initial values
    wxCommandEvent e;
    OnCreateExposureLevels(e);
}

CreateBrightImgDlg::~CreateBrightImgDlg()
{
    // save position and size
    hugin_utils::StoreFramePosition(this, "ToolboxFrame/CreateBrighterDarkerImageDialog");
}

bool CreateBrightImgDlg::SetImage(const wxString& filename, wxString& errorMsg)
{
    m_filename = filename;
    const std::string filenameString(filename.mb_str(HUGIN_CONV_FILENAME));
    vigra::ImageImportInfo info(filenameString.c_str());
    const std::string pixeltype(info.getPixelType());
    if (!(pixeltype == "UINT8" || pixeltype == "UINT16"))
    {
        errorMsg = _("The creation of brighter and darker images works only for 8 and 16 bit images.");
        return false;
    }
    try
    {
        ImageCache::getInstance().softFlush();
        m_image = ImageCache::getInstance().getImage(filenameString);
    }
    catch (std::exception& e)
    {
        // loading of image failed
        errorMsg = wxString::Format(_("Could not load image %s"), filename.c_str());;
        errorMsg.Append(" (");
        errorMsg.Append(e.what());
        errorMsg.Append(")");
        return false;
    }
    SetLabel(GetLabel() + " " + filename);
    Layout();
    RescaleImage();
    m_previewBitmap->SetBitmap(m_scaledwxBitmap);
    return true;
}

wxArrayString CreateBrightImgDlg::GetTempFiles() const
{
    return m_tempFiles;
}

void CreateBrightImgDlg::OnOk(wxCommandEvent & e)
{
    wxString tempDir = HuginQueue::GetConfigTempDir(wxConfig::Get());
    {
        wxWindowDisabler disableAll;
        wxBusyCursor busyCursor;
        wxGauge* progress = XRCCTRL(*this, "enfuse_create_file_progress", wxGauge);
        progress->Show();
        Layout();
        progress->SetRange(GetCheckedItemCount() + 1);
        for (long i = 0; i < m_exposuresListBox->GetItemCount(); ++i)
        {
            if (m_exposuresListBox->IsItemChecked(i))
            {
                wxFileName tempfile(wxFileName::CreateTempFileName(tempDir + "htb"));
                if (CreateAndSaveExposureCorrectedImage(tempfile.GetFullPath(), m_exposures[i]))
                {
                    m_tempFiles.Add(tempfile.GetFullPath());
                };
            };
            progress->SetValue(progress->GetValue() + 1);
            progress->Update();
            wxTheApp->Yield();
        };
        progress->Hide();
        Layout();
    }
    if (!m_tempFiles.empty())
    {
        EndModal(wxID_OK);
    }
    else
    {
        hugin_utils::HuginMessageBox(_("You have not yet selected at least one exposure correction."), _("Hugin toolbox"), wxOK | wxICON_WARNING, this);
    };
}

void CreateBrightImgDlg::OnCreateExposureLevels(wxCommandEvent& e)
{
    m_exposures.clear();
    m_exposuresListBox->DeleteAllItems();
    const double stepWidth = GetExposureStepWidth();
    const int nrLevels = (m_levelChoice->GetSelection() + 1) * 2 + 1;
    double exposure = -std::trunc(nrLevels / 2.0) * stepWidth;
    // disable checkbox check for updating the list
    m_exposuresListBox->Unbind(wxEVT_LIST_ITEM_CHECKED, &CreateBrightImgDlg::OnExposureChecked, this);
    for (int i = 0; i < nrLevels; ++i)
    {
        m_exposures.push_back(exposure);
        long index = m_exposuresListBox->InsertItem(m_exposuresListBox->GetItemCount(), wxString::Format(_("EV %+.2f"), exposure));
        // set checkbox, disable checkbox for uncorrected image
        m_exposuresListBox->CheckItem(index, std::abs(exposure) > 0.05);
        exposure = exposure + stepWidth;
    };
    m_exposuresListBox->Bind(wxEVT_LIST_ITEM_CHECKED, &CreateBrightImgDlg::OnExposureChecked, this);
}

void CreateBrightImgDlg::OnExposureSelected(wxListEvent& e)
{
    long index = m_exposuresListBox->GetNextItem(-1, wxLIST_NEXT_ALL, wxLIST_STATE_SELECTED);
    if (index != -1)
    {
        // remember exposure correction value
        m_currentExposure = m_exposures[index];
        // apply exposure correction and update wxStaticBitmap
        vigra::BRGBImage img = CreateBrightVersion(m_scaledImg, m_currentExposure);
        CreatewxBitmap(img);
        m_previewBitmap->SetBitmap(m_scaledwxBitmap);
    }
    else
    {
        // no item selected, do no exposure correction
        m_currentExposure = 0;
    };
}

void CreateBrightImgDlg::OnExposureChecked(wxListEvent& e)
{
    // prevent checking item for exposure correction 0
    if (e.GetIndex() == m_exposuresListBox->GetItemCount() / 2)
    {
        m_exposuresListBox->CheckItem(e.GetIndex(), false);
    };
}

void CreateBrightImgDlg::OnSize(wxSizeEvent& e)
{
    Layout();
    RescaleImage();
    m_previewBitmap->SetBitmap(m_scaledwxBitmap);
}

double CreateBrightImgDlg::GetExposureStepWidth() const
{
    if (m_stepWidthChoice->GetSelection() == 0)
    {
        return 0.6667;
    }
    else
    {
        if (m_stepWidthChoice->GetSelection() == 2)
        {
            return 1.3333;
        };
    };
    return 1.0;
}

void CreateBrightImgDlg::RescaleImage()
{
    wxSize previewSize = m_previewBitmap->GetClientSize();
    const long imageWidth = m_image->image16->size().area() > 0 ? m_image->image16->width() : m_image->image8->width();
    const long imageHeight = m_image->image16->size().area() > 0 ? m_image->image16->height() : m_image->image8->height();
    const double scaleFactor = std::min<double>((double)previewSize.GetWidth() / imageWidth, (double)previewSize.GetHeight() / imageHeight);
    m_scaledImg.resize(scaleFactor * imageWidth, scaleFactor * imageHeight);
    vigra::resizeImageLinearInterpolation(vigra::srcImageRange(*m_image->get8BitImage()), vigra::destImageRange(m_scaledImg));
    if (m_currentExposure > -0.01 && m_currentExposure < 0.01)
    {
        // no exposure correction, directly transform m_scaledImg to wxBitmap
        CreatewxBitmap(m_scaledImg);
    }
    else
    {
        // apply exposure correction and convert to wxBitmap
        vigra::BRGBImage img = CreateBrightVersion(m_scaledImg, m_currentExposure);
        CreatewxBitmap(img);
    };
}

void CreateBrightImgDlg::CreatewxBitmap(const vigra::BRGBImage& img)
{
    wxImage resizedImage;
    resizedImage.SetData((unsigned char*)img.data(), img.width(), img.height(), true);
    // apply color profiles
    if (!m_image->iccProfile->empty() || wxGetApp().GetToolboxFrame()->HasMonitorProfile())
    {
        HuginBase::Color::CorrectImage(resizedImage, *(m_image->iccProfile), wxGetApp().GetToolboxFrame()->GetMonitorProfile());
    };
    wxBitmap bitmap(m_previewBitmap->GetClientSize());
    {
        wxMemoryDC dc(bitmap);
        dc.SetBackground(wxBrush(m_previewBitmap->GetParent()->GetBackgroundColour(), wxBRUSHSTYLE_SOLID));
        dc.Clear();
        wxPoint offset;
        offset.x = (bitmap.GetWidth() - resizedImage.GetWidth()) / 2;
        offset.y = (bitmap.GetHeight() - resizedImage.GetHeight()) / 2;
        dc.DrawBitmap(resizedImage, offset);
    }
    m_scaledwxBitmap = bitmap; // xBitmap(resizedImage);
}

bool CreateBrightImgDlg::CreateAndSaveExposureCorrectedImage(const wxString& filename, const double correction)
{
    vigra::ImageExportInfo info(filename.mb_str(HUGIN_CONV_FILENAME));
    info.setFileType("TIFF");
    // embed icc profile
    if (!m_image->iccProfile->empty())
    {
        info.setICCProfile(*m_image->iccProfile);
    };
    if (m_image->image16->size().area() > 0)
    {
        //process 16 bit image
        info.setPixelType("UINT16");
        vigra::UInt16RGBImage finalImg = CreateBrightVersion(*m_image->image16, correction);
        try
        {
            if (m_image->mask->size().area() > 0)
            {
                vigra::exportImageAlpha(vigra::srcImageRange(finalImg), vigra::srcImage(*m_image->mask), info);
            }
            else
            {
                vigra::exportImage(vigra::srcImageRange(finalImg), info);
            };
        }
        catch (...)
        {
            return false;
        }

    }
    else
    {
        // process 8 bit image
        vigra::BRGBImage finalImg = CreateBrightVersion(*m_image->image8, correction);
        try
        {
            info.setPixelType("UINT8");
            if (m_image->mask->size().area() > 0)
            {
                vigra::exportImageAlpha(vigra::srcImageRange(finalImg), vigra::srcImage(*m_image->mask), info);
            }
            else
            {
                vigra::exportImage(vigra::srcImageRange(finalImg), info);
            };
        }
        catch (...)
        {
            return false;
        };
    };
    // copy some basic Exif data
    const wxFileName exePath(wxStandardPaths::Get().GetExecutablePath());
    wxString exiftoolCmd(HuginQueue::GetExternalProgram(wxConfig::Get(), exePath.GetPath(wxPATH_GET_VOLUME | wxPATH_GET_SEPARATOR), "exiftool"));
    exiftoolCmd.Append(" -overwrite_original -tagsfromfile " + HuginQueue::wxEscapeFilename(m_filename) + " -xresolution -yresolution -resolutionunit -xposition -yposition -imagefullwidth -imagefullheight -FNumber -ISO ");
    // update the exposure time with the corrected one
    exiftoolCmd.Append("-ExposureTime<${exposuretime#;$_*=" + wxString::FromCDouble(std::pow(2, correction)) + "} ");
    exiftoolCmd.Append(HuginQueue::wxEscapeFilename(filename));
    wxExecute(exiftoolCmd, wxEXEC_SYNC | wxEXEC_HIDE_CONSOLE | wxEXEC_NODISABLE | wxEXEC_MAKE_GROUP_LEADER);

    return true;
}

long CreateBrightImgDlg::GetCheckedItemCount()
{
    int count = 0;
    for (long i = 0; i < m_exposuresListBox->GetItemCount(); ++i)
    {
        if (m_exposuresListBox->IsItemChecked(i))
        {
            ++count;
        };
    }
    return count;
}

