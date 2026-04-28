// -*- c-basic-offset: 4 -*-
/** @file PerspectivePanel.cpp
 *
 *  @brief implementation of panel for perspective correction GUI
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

#include "PerspectivePanel.h"
#include "ToolboxApp.h"
#include "base_wx/platform.h"
#include "wx/clrpicker.h"
#include "hugin/config_defaults.h"
#include "base_wx/wxPlatform.h"
#include "panodata/Panorama.h"
#include "algorithms/optimizer/PTOptimizer.h"
#include "base_wx/PTWXDlg.h"
#include "appbase/ProgressDisplay.h"
#include "algorithms/basic/CalculateOptimalScale.h"
#include "algorithms/basic/CalculateOptimalROI.h"
#include "algorithms/nona/CalculateFOV.h"
#include "algorithms/nona/FitPanorama.h"
#include "lines/FindLines.h"
#include "wx/stdpaths.h"
#include "base_wx/Executor.h"
#include "base_wx/wxutils.h"

 /** file drag and drop handler method */
class PerspectiveDropTarget : public wxFileDropTarget
{
public:
    PerspectiveDropTarget(PerspectivePanel* parent) : wxFileDropTarget()
    {
        m_perspectivePanel = parent;
    }

    bool OnDropFiles(wxCoord x, wxCoord y, const wxArrayString& filenames)
    {
        // try to add as images
        if (filenames.size() == 1)
        {
            wxFileName file(filenames[0]);
            if (file.GetExt().CmpNoCase("jpg") == 0 ||
                file.GetExt().CmpNoCase("jpeg") == 0 ||
                file.GetExt().CmpNoCase("tif") == 0 ||
                file.GetExt().CmpNoCase("tiff") == 0 ||
                file.GetExt().CmpNoCase("png") == 0 ||
                file.GetExt().CmpNoCase("bmp") == 0 ||
                file.GetExt().CmpNoCase("gif") == 0 ||
                file.GetExt().CmpNoCase("pnm") == 0)
            {
                m_perspectivePanel->SetImage(filenames[0]);
                return true;
            }
            else
            {
                wxBell();
            };
        }
        else
        {
            wxBell();
        };
        return false;
    }
private:
    PerspectivePanel* m_perspectivePanel;
};

bool PerspectivePanel::Create(wxWindow* parent, MyExecPanel* logWindow)
{
    if (!wxPanel::Create(parent, wxID_ANY, wxDefaultPosition, wxDefaultSize, wxTAB_TRAVERSAL, "panel"))
    {
        return false;
    };
    // create image control
    m_preview = new PerspectiveImageCtrl();
    m_preview->Create(this);
    // set to scale to window
    m_preview->setScale(0);
    // load from xrc file
    wxXmlResource::Get()->LoadPanel(this, "perspective_panel");
    // connect image control
    wxXmlResource::Get()->AttachUnknownControl("perspective_preview_window", m_preview, this);
    // add to sizer
    wxPanel* mainPanel = XRCCTRL(*this, "perspective_panel", wxPanel);
    wxBoxSizer* topsizer = new wxBoxSizer(wxVERTICAL);
    topsizer->Add(mainPanel, wxSizerFlags(1).Expand());
    SetSizer(topsizer);
    // remember some pointer to controls for easier access
    m_focallengthTextCtrl = XRCCTRL(*this, "perspective_focallength", wxTextCtrl);
    m_cropTextCtrl = XRCCTRL(*this, "perspective_cropfactor", wxTextCtrl);
    m_previewChoice = XRCCTRL(*this, "perspective_preview", wxChoice);
    m_zoomChoice = XRCCTRL(*this, "perspective_choice_zoom", wxChoice);
    m_rotationChoice = XRCCTRL(*this, "perspective_rotation", wxChoice);
    m_modeChoice = XRCCTRL(*this, "perspective_mode", wxChoice);
    m_findLineButton = XRCCTRL(*this, "perspective_find_lines", wxButton);
    m_helpTextCtrl = XRCCTRL(*this, "perspective_help_text", wxStaticText);
    m_outputButton = XRCCTRL(*this, "perspective_output", wxButton);
    m_logWindow = logWindow;

    wxConfigBase* config = wxConfigBase::Get();
    //load and set colour
    wxColour colour, defaultColour;
    defaultColour.Set(HUGIN_MASK_COLOUR_POINT_SELECTED);
    colour = config->Read("/ToolboxFrame/Perspective/LineColour", defaultColour.GetAsString(wxC2S_HTML_SYNTAX));
    XRCCTRL(*this, "perspective_color_picker", wxColourPickerCtrl)->SetColour(colour);
    m_preview->SetLineColour(colour);
    m_degDigits = config->Read("/General/DegreeFractionalDigitsEdit", 3);

    // bind event handler
    Bind(wxEVT_SIZE, &PerspectivePanel::OnSize, this);
    Bind(wxEVT_BUTTON, &PerspectivePanel::OnLoadImage, this, XRCID("perspective_load"));
    Bind(wxEVT_BUTTON, &PerspectivePanel::OnSavePTO, this, XRCID("perspective_output_pto"));
    m_outputButton->Bind(wxEVT_BUTTON, &PerspectivePanel::OnSaveOutput, this);
    m_previewChoice->Bind(wxEVT_CHOICE, &PerspectivePanel::OnPreview, this);
    m_zoomChoice->Bind(wxEVT_CHOICE, &PerspectivePanel::OnZoom, this);
    m_modeChoice->Bind(wxEVT_CHOICE, &PerspectivePanel::OnModeChanged, this);
    Bind(wxEVT_CHOICE, &PerspectivePanel::OnCropChanged, this, XRCID("perspective_crop"));
    m_rotationChoice->Bind(wxEVT_CHOICE, &PerspectivePanel::OnRotationChanged, this);
    m_findLineButton->Bind(wxEVT_BUTTON, &PerspectivePanel::OnFindLines, this);
    Bind(wxEVT_COLOURPICKER_CHANGED, &PerspectivePanel::OnColourChanged, this, XRCID("perspective_color_picker"));
    // update help text
    wxCommandEvent commandEvent;
    OnModeChanged(commandEvent);
    // allow dropping files
    SetDropTarget(new PerspectiveDropTarget(this));
    return true;
}

void PerspectivePanel::OnSize(wxSizeEvent& e)
{
    Layout();
    Update();
    Refresh();
    e.Skip();
}

void PerspectivePanel::OnZoom(wxCommandEvent& e)
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

void PerspectivePanel::OnPreview(wxCommandEvent& e)
{
    if (m_previewChoice->GetSelection() == 1)
    {
        // preview mode
        HuginBase::Panorama pano;
        if (GetPanorama(pano))
        {
            // disable zoom choice in preview mode
            m_zoomChoice->Enable(e.GetSelection() == 0);
            m_preview->SetRemappedMode(pano);
        }
        else
        {
            // could not create pano, reset selection
            m_previewChoice->SetSelection(0);
            m_zoomChoice->Enable();
            m_preview->setOriginalMode();
        }
    }
    else
    {
        // show original
        m_zoomChoice->Enable();
        m_preview->setOriginalMode();
    };
    Refresh();
    e.Skip();
}

void PerspectivePanel::SetImage(const wxString& filename)
{
    // update label for display of filename
    XRCCTRL(*this, "perspective_filename", wxStaticText)->SetLabel(filename);
    Layout();
    // create HuginBase::SrcPanoImage and load values from EXIF
    m_srcImage = HuginBase::SrcPanoImage();
    const std::string filenameString(filename.mb_str(HUGIN_CONV_FILENAME));
    m_srcImage.setFilename(filenameString);
    m_srcImage.checkImageSizeKnown();
    m_focallengthTextCtrl->Clear();
    m_cropTextCtrl->Clear();
    m_exifRotation = PerspectiveImageCtrl::ROT0;
    if (m_srcImage.readEXIF())
    {
        bool ok = m_srcImage.applyEXIFValues();
        // load crop factor from database if unknown
        if (m_srcImage.getCropFactor() < 0.1)
        {
            m_srcImage.readCropfactorFromDB();
            ok = (m_srcImage.getExifFocalLength() > 0 && m_srcImage.getCropFactor() > 0.1);
        };
        // update values in control
        const double focallength = HuginBase::SrcPanoImage::calcFocalLength(m_srcImage.getProjection(), m_srcImage.getHFOV(), m_srcImage.getCropFactor(), m_srcImage.getSize());;
        const double cropFactor = m_srcImage.getCropFactor();
        if (focallength > 0 && focallength < 10000)
        {
            // use ChangeValue explicit, SetValue would create EVT_TEXT event which collides with our TextKillFocusHandler
            m_focallengthTextCtrl->ChangeValue(hugin_utils::doubleTowxString(focallength, m_degDigits));
        };
        if (cropFactor > 0 && cropFactor < 1000)
        {
            m_cropTextCtrl->ChangeValue(hugin_utils::doubleTowxString(cropFactor, m_degDigits));
        };
        const double rotation = m_srcImage.getExifOrientation();
        if (rotation == 90)
        {
            m_exifRotation = PerspectiveImageCtrl::ROT90;
        }
        else
        {
            if (rotation == 180)
            {
                m_exifRotation = PerspectiveImageCtrl::ROT180;
            }
            else
            {
                if (rotation == 270)
                {
                    m_exifRotation = PerspectiveImageCtrl::ROT270;
                };
            };
        };
    };
    m_preview->setImage(filenameString, GetRotation());
    // reset preview mode to original
    wxCommandEvent e;
    m_previewChoice->SetSelection(0);
    OnPreview(e);
}

void PerspectivePanel::OnLoadImage(wxCommandEvent& e)
{
    wxConfigBase* config = wxConfigBase::Get();
    wxString path = config->Read("/actualPath", "");
    wxFileDialog dlg(this, _("Add images"), path, wxEmptyString, GetFileDialogImageFilters(), wxFD_OPEN | wxFD_FILE_MUST_EXIST | wxFD_PREVIEW, wxDefaultPosition);
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
        // display the selected image
        SetImage(dlg.GetPath());
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
        };
    };
}

void PerspectivePanel::OnColourChanged(wxColourPickerEvent& e)
{
    m_preview->SetLineColour(e.GetColour());
    wxConfigBase::Get()->Write("/ToolboxFrame/Perspective/LineColour", e.GetColour().GetAsString(wxC2S_HTML_SYNTAX));
}

void PerspectivePanel::OnCropChanged(wxCommandEvent& e)
{
    if (!m_preview->IsOriginalShown())
    {
        // refresh preview
        OnPreview(e);
    };
}

void PerspectivePanel::OnRotationChanged(wxCommandEvent& e)
{
    m_preview->ChangeRotation(GetRotation());
    if (!m_preview->IsOriginalShown())
    {
        // refresh preview
        OnPreview(e);
    };
}

void PerspectivePanel::OnModeChanged(wxCommandEvent& e)
{
    const bool isRectMode = m_modeChoice->GetSelection() == 0;
    m_preview->SetRectMode(isRectMode);
    if (!m_preview->IsOriginalShown())
    {
        // set mode back to original
        m_previewChoice->SetSelection(0);
        // refresh preview
        OnPreview(e);
    };
    m_findLineButton->Enable(!isRectMode);
    m_findLineButton->Show(!isRectMode);
    // update help text
    m_helpTextCtrl->SetLabel(GetStatusString());
    m_helpTextCtrl->Wrap(XRCCTRL(*this, "perspective_color_picker", wxColourPickerCtrl)->GetSize().GetWidth());
    Layout();
}

void PerspectivePanel::OnFindLines(wxCommandEvent& e)
{
    HuginBase::Panorama pano;
    // get unoptimized pano
    if (GetPanorama(pano, false))
    {
        // find lines
        HuginBase::CPVector lines;
        if (wxGetKeyState(WXK_COMMAND))
        {
            lines = HuginLines::GetVerticalLines(pano, 0, *(m_preview->getCachedImage()->get8BitImage()), *(m_preview->getCachedImage()->mask), 10);
        }
        else
        {
            lines = HuginLines::GetLines(pano, 0, *(m_preview->getCachedImage()->get8BitImage()), *(m_preview->getCachedImage()->mask));
        };
        if (!lines.empty())
        {
            // add them to image control
            m_preview->AddLines(lines);
            // reset preview mode to original
            m_previewChoice->SetSelection(0);
            OnPreview(e);
        };
    };
}

void PerspectivePanel::OnSavePTO(wxCommandEvent& e)
{
    HuginBase::Panorama pano;
    wxConfigBase* config = wxConfigBase::Get();
    wxString path = config->Read("/actualPath", "");

    if (GetPanorama(pano))
    {
        wxFileDialog dlg(this, _("Save project file"), path, wxEmptyString,
            _("Project files (*.pto)|*.pto|All files (*)|*"),
            wxFD_SAVE | wxFD_OVERWRITE_PROMPT, wxDefaultPosition);
        if (dlg.ShowModal() == wxID_OK)
        {
            wxConfig::Get()->Write("/actualPath", dlg.GetDirectory());  // remember for later
            wxString fn = dlg.GetPath();
            if (fn.Right(4).CmpNoCase(".pto") != 0)
            {
                fn.Append(".pto");
                if (wxFile::Exists(fn))
                {
                    if (!hugin_utils::AskUserOverwrite(fn , _("Hugin toolbox"), this))
                    {
                        return;
                    };
                };
            };
            const std::string script(fn.mb_str(HUGIN_CONV_FILENAME));
            pano.WritePTOFile(script, hugin_utils::getPathPrefix(script));
        };
    };
    m_preview->SendSizeEvent();
}

void PerspectivePanel::OnSaveOutput(wxCommandEvent& e)
{
    HuginBase::Panorama pano;
    if (GetPanorama(pano))
    {
        wxConfigBase* config = wxConfigBase::Get();
        wxString path = config->Read("/actualPath", "");
        wxFileDialog dlg(this, _("Save output"), path, wxEmptyString, GetMainImageFilters(), wxFD_SAVE | wxFD_OVERWRITE_PROMPT, wxDefaultPosition);
        dlg.SetDirectory(path);

        // remember the image extension
        wxString img_ext;
        if (config->HasEntry("lastImageType"))
        {
            img_ext = config->Read("lastImageType").c_str();
        };
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
        wxFileName outputfilename(wxString(m_srcImage.getFilename().c_str(), HUGIN_CONV_FILENAME));
        wxString inputFilename = outputfilename.GetFullPath();
        outputfilename.SetName(outputfilename.GetName() + "_corrected");
        dlg.SetFilename(outputfilename.GetFullPath());
        // call the file dialog
        if (dlg.ShowModal() == wxID_OK)
        {
            std::string outputFilename(dlg.GetPath().mb_str(HUGIN_CONV_FILENAME));
            // save the current path to config
            config->Write("/actualPath", dlg.GetDirectory());
            // save the image extension
            wxString tempFilename = wxFileName::CreateTempFileName(HuginQueue::GetConfigTempDir(wxConfig::Get()) + "htb");
            pano.WritePTOFile(std::string(tempFilename.mb_str(HUGIN_CONV_FILENAME)));
            const wxFileName exePath(wxStandardPaths::Get().GetExecutablePath());
            wxString nonaArgs;
            switch (dlg.GetFilterIndex())
            {
            case 0:
                config->Write("lastImageType", "jpg");
                nonaArgs.Append("-m JPEG ");
                break;
            case 1:
            default:
                config->Write("lastImageType", "tiff");
                nonaArgs.Append("-m TIFF ");
                break;
            case 2:
                config->Write("lastImageType", "png");
                nonaArgs.Append("-m PNG ");
                break;
            };
            // use nona for remapping
            nonaArgs.Append("-v -o " + HuginQueue::wxEscapeFilename(dlg.GetPath()) + " " + HuginQueue::wxEscapeFilename(tempFilename));
            HuginQueue::CommandQueue* queue = new HuginQueue::CommandQueue();
            queue->push_back(new HuginQueue::NormalCommand(HuginQueue::GetInternalProgram(exePath.GetPath(wxPATH_GET_VOLUME | wxPATH_GET_SEPARATOR), "nona"), nonaArgs, _("Remapping image")));
            wxString exiftoolArgs("-overwrite_original -tagsfromfile ");
            exiftoolArgs.Append(HuginQueue::wxEscapeFilename(wxString(m_srcImage.getFilename().c_str(), HUGIN_CONV_FILENAME)));
            // tags to copy and to ignore (white space at begin and at end!)
            exiftoolArgs.Append(" -all:all --thumbnail --thumbnailimage --xposition --yposition --orientation --imagefullwidth --imagefullheight ");
            exiftoolArgs.Append(HuginQueue::wxEscapeFilename(dlg.GetPath()));
            queue->push_back(new HuginQueue::OptionalCommand(HuginQueue::GetExternalProgram(wxConfig::Get(), exePath.GetPath(wxPATH_GET_VOLUME | wxPATH_GET_SEPARATOR), "exiftool"), exiftoolArgs, _("Updating EXIF")));
            m_tempFiles.Add(tempFilename);
            m_logWindow->ClearOutput();
            m_logWindow->ExecQueue(queue);
            m_outputButton->Disable();
        };
    };
}

void PerspectivePanel::OnProcessFinished(wxCommandEvent& e)
{
    if (!m_tempFiles.IsEmpty())
    {
        // delete all temporary files at the end of command
        for (auto& file : m_tempFiles)
        {
            if (wxFileExists(file))
            {
                wxRemoveFile(file);
            };
        };
        m_tempFiles.clear();
    };
    m_outputButton->Enable();
}

wxString PerspectivePanel::GetStatusString()
{
    if (m_modeChoice->GetSelection()==0)
    {
        return _("Adjust the rectangle to an area which should be rectangular in the projected image.");
    }
    else
    {
        return _("Create a new line by dragging with left mouse button on a free space.\nExisting lines or line end points can be moved by dragging with left mouse button.\nA line can be deleted by clicking with the right mouse button.");
    };
}

bool PerspectivePanel::ReadInputs()
{
    if (m_srcImage.getFilename().empty())
    {
        hugin_utils::HuginMessageBox(_("You need to load an image first."), _("Hugin toolbox"), wxICON_ERROR | wxOK, this);
        return false;
    }
    wxString focallengthText = m_focallengthTextCtrl->GetValue();
    if (focallengthText.IsEmpty())
    {
        hugin_utils::HuginMessageBox(_("Focal length input box is empty."), _("Hugin toolbox"), wxICON_ERROR | wxOK, this);
        return false;
    };
    double focallength, cropfactor;
    if (!hugin_utils::str2double(focallengthText, focallength))
    {
        hugin_utils::HuginMessageBox(_("Focal length input box contains no valid number."), _("Hugin toolbox"), wxICON_ERROR | wxOK, this);
        return false;
    }
    //no negative values, no zero input please
    if (focallength < 0.1)
    {
        hugin_utils::HuginMessageBox(_("The focal length must be positive."), _("Hugin toolbox"), wxICON_ERROR | wxOK, this);
        return false;
    };
    wxString cropfactorText = m_cropTextCtrl->GetValue();
    if (cropfactorText.IsEmpty())
    {
        hugin_utils::HuginMessageBox(_("Crop factor input box is empty."), _("Hugin toolbox"), wxICON_ERROR | wxOK, this);
        return false;
    };
    if (!hugin_utils::str2double(cropfactorText, cropfactor))
    {
        hugin_utils::HuginMessageBox(_("Crop factor input box contains no valid number."), _("Hugin toolbox"), wxICON_ERROR | wxOK, this);
        return false;
    }
    //no negative values, no zero input please
    if (cropfactor < 0.1)
    {
        hugin_utils::HuginMessageBox(_("The crop factor must be positive."), _("Hugin toolbox"), wxICON_ERROR | wxOK, this);
        return false;
    };
    const double hfov = HuginBase::SrcPanoImage::calcHFOV(m_srcImage.getProjection(), focallength, cropfactor, m_srcImage.getSize());
    if (hfov > 178)
    {
        hugin_utils::HuginMessageBox(_("The focal length and crop factor result in a invalid value of %d for the horizontal field of view.\nPlease input a valid combination of focal length and crop factor."),
            _("Hugin toolbox"), wxICON_QUESTION | wxOK, this);
        return false;
    };
    m_srcImage.setHFOV(hfov);
    return true;
}

bool PerspectivePanel::GetPanorama(HuginBase::Panorama& pano, const bool optimized)
{
    if (ReadInputs())
    {
        HuginBase::SrcPanoImage panoImage(m_srcImage);
        panoImage.setRoll(GetRoll());
        pano.addImage(panoImage);
        pano.setCtrlPoints(m_preview->GetControlPoints(0));
        if (optimized && pano.getCtrlPoints().size() < 2)
        {
            hugin_utils::HuginMessageBox(_("You need to create at least 2 lines."), _("Hugin toolbox"), wxICON_ERROR | wxOK, this);
            return false;
        };
        HuginBase::OptimizeVector optvec;
        // optimize yaw, pitch and roll
        std::set<std::string> imgopt;
        imgopt.insert("y");
        imgopt.insert("p");
        imgopt.insert("r");
        optvec.push_back(imgopt);
        pano.setOptimizeVector(optvec);
        // set some sensible values for PanoramaOptions
        HuginBase::PanoramaOptions opts;
        opts.setProjection(HuginBase::PanoramaOptions::RECTILINEAR);
        opts.outputExposureValue = m_srcImage.getExposureValue();
        pano.setOptions(opts);
        // now optimize pano
        if (optimized)
        {
            deregisterPTWXDlgFcn();
            HuginBase::PTools::optimize(pano);
            registerPTWXDlgFcn();
            // calculate field of view
            HuginBase::CalculateFitPanorama fitPano(pano);
            fitPano.run();
            opts.setHFOV(fitPano.getResultHorizontalFOV());
            opts.setHeight(hugin_utils::roundi(fitPano.getResultHeight()));
            // calculate scale
            const double scale = HuginBase::CalculateOptimalScale::calcOptimalPanoScale(m_srcImage, opts);
            opts.setWidth(scale * opts.getWidth());
            pano.setOptions(opts);
            // crop pano
            AppBase::DummyProgressDisplay progress;
            const int cropMode = XRCCTRL(*this, "perspective_crop", wxChoice)->GetSelection();
            if (cropMode == 1)
            {
                // crop inside
                HuginBase::CalculateOptimalROI cropPano(pano, &progress);
                cropPano.run();
                if (cropPano.hasRunSuccessfully())
                {
                    opts.setROI(cropPano.getResultOptimalROI());
                };
                pano.setOptions(opts);
            }
            else
            {
                // crop outside
                HuginBase::CalculateOptimalROIOutside cropPano(pano, &progress);
                cropPano.run();
                if (cropPano.hasRunSuccessfully())
                {
                    opts.setROI(cropPano.getResultOptimalROI());
                };
                pano.setOptions(opts);
            };
        };
        return true;
    }
    else
    {
        return false;
    };
}

const PerspectiveImageCtrl::ImageRotation PerspectivePanel::GetRotation() const
{
    switch (m_rotationChoice->GetSelection())
    {
        case 0:
        default:
            // auto-rotate, return EXIF value
            return m_exifRotation;
            break;
        case 1:
            return PerspectiveImageCtrl::ROT0;
            break;
        case 2:
            return PerspectiveImageCtrl::ROT90;
            break;
        case 3:
            return PerspectiveImageCtrl::ROT270;
            break;
        case 4:
            return PerspectiveImageCtrl::ROT180;
            break;
    }
    return PerspectiveImageCtrl::ROT0;
}

const double PerspectivePanel::GetRoll() const
{
    switch (GetRotation())
    {
        case PerspectiveImageCtrl::ROT0:
        default:
            return 0.0;
            break;
        case PerspectiveImageCtrl::ROT90:
            return 90.0;
            break;
        case PerspectiveImageCtrl::ROT180:
            return 180.0;
            break;
        case PerspectiveImageCtrl::ROT270:
            return 270.0;
            break;
    }
    return 0.0;
}

IMPLEMENT_DYNAMIC_CLASS(PerspectivePanel, wxPanel)
