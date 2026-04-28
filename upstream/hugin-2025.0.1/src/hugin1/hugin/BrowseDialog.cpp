// -*- c-basic-offset: 4 -*-

/** @file BrowseDialog.cpp
 *
 *  @brief implementation of dialog to browse directory with pto files
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

#include "hugin/BrowseDialog.h"
#include "hugin/huginApp.h"
#include "wx/dir.h"
#include "wx/busyinfo.h"
#include "hugin/GenerateThumbnail.h"
#include "hugin/MainFrame.h"
#include "base_wx/wxcms.h"
#include "base_wx/LensTools.h"
#include "base_wx/platform.h"
#include "base_wx/wxutils.h"

wxDECLARE_EVENT(wxEVT_COMMAND_THUMBNAILTHREAD_UPDATE, wxCommandEvent);
wxDEFINE_EVENT(wxEVT_COMMAND_THUMBNAILTHREAD_UPDATE, wxCommandEvent);

/** helper class to transfer thumbnail data from worker thread to GUI thread */
class ThreadImage : public wxObject
{
public:
    // explicit disable default contructor
    ThreadImage() = delete;
    // construct wxImage with given vigra image classes
    ThreadImage(vigra::BRGBImage* thumbnail, vigra::BImage* mask)
    {
        // save pointer to raw image data for cleanup in destructor
        m_preview = thumbnail;
        m_mask = mask;
        // construct wxImage, we keep track of the raw data
        m_image=new wxImage(m_preview->width(), m_preview->height(), (unsigned char*)m_preview->data(), (unsigned char*)m_mask->data(), true);
    }
    // clean up
    ~ThreadImage()
    {
        delete m_image;
        delete m_preview;
        delete m_mask;
    }
    // return pointer to wxImage
    wxImage* GetwxImage() const { return m_image; }
private:
    wxImage* m_image;
    vigra::BRGBImage* m_preview;
    vigra::BImage* m_mask;
};

/** background thread to generate thumbnails of all pto files */
class ThumbnailThread : public wxThread
{
public:
    ThumbnailThread(BrowsePTOFilesDialog* parentDialog, const wxArrayString& fileList, const wxSize size)
        : wxThread(wxTHREAD_DETACHED)
    {
        m_parentDialog = parentDialog;
        m_files = fileList;
        m_thumbnailSize = size;
    }
    ~ThumbnailThread()
    {
        wxCriticalSectionLocker enter(m_parentDialog->m_ThreadCS);
        // the thread is being destroyed; make sure not to leave dangling pointers around
        m_parentDialog->m_thumbnailThread = NULL;
    }

protected:
    // main worker thread
    virtual ExitCode Entry()
    {
        for (int i = 0; i < m_files.size(); ++i)
        {
            // generate thumbnail
            vigra::BRGBImage* preview=new vigra::BRGBImage();
            vigra::BImage* mask = new vigra::BImage();
            vigra::ImageImportInfo::ICCProfile iccProfile;
            if (!GenerateThumbnail(m_files[i].ToStdString(), m_thumbnailSize, *preview, *mask, iccProfile))
            {
                // generation of thumbnail failed, skip file
                delete preview;
                delete mask;
                continue;
            };
            if (TestDestroy())
            {
                break;
            };
            // fit generated thumbnail into the full thumbnail rectangle
            if (m_thumbnailSize.GetWidth() != preview->size().width() || m_thumbnailSize.GetHeight() != preview->size().height())
            {
                vigra::BRGBImage* scaledPreview = new vigra::BRGBImage(vigra::Diff2D(m_thumbnailSize.GetWidth(), m_thumbnailSize.GetHeight()), vigra::RGBValue<vigra::UInt8>(255, 255, 255));
                vigra::BImage* scaledMask = new vigra::BImage(scaledPreview->size(), vigra::UInt8(0));
                vigra::Point2D offset((scaledPreview->width() - preview->width()) / 2, (scaledPreview->height() - preview->height()) / 2);
                vigra::copyImage(vigra::srcImageRange(*preview), vigra::destImage(*scaledPreview, offset));
                vigra::copyImage(vigra::srcImageRange(*mask), vigra::destImage(*scaledMask, offset));
                delete preview;
                delete mask;
                preview = scaledPreview;
                mask = scaledMask;
            }
            // convert vigra image to wxImage
            ThreadImage* thumbnailImageData = new ThreadImage(preview, mask);
            // notify dialog about new available thumbnail
            wxCommandEvent* event = new wxCommandEvent(wxEVT_COMMAND_THUMBNAILTHREAD_UPDATE);
            event->SetInt(i);
            event->SetEventObject(thumbnailImageData);
            // check if we need to cancel
            if (TestDestroy())
            {
                // we are destroying the thread
                // clean up all unneeded pointer
                delete event;
                delete thumbnailImageData;
                break;
            }
            else
            {
                // all ok, notify dialog to update its image list
                wxQueueEvent(m_parentDialog, event);
            };
        };
        return (wxThread::ExitCode)0;
    }

    BrowsePTOFilesDialog* m_parentDialog;
    wxArrayString m_files;
    wxSize m_thumbnailSize;
};

#define THUMBNAIL_SIZE 128

BrowsePTOFilesDialog::BrowsePTOFilesDialog(wxWindow *parent, const wxString startDirectory)
{
    // load our children. some children might need special
    // initialization. this will be done later.
    wxXmlResource::Get()->LoadDialog(this, parent, "browse_pto_dialog");

    m_dirCtrl = XRCCTRL(*this, "browse_dirctrl", wxGenericDirCtrl);
    m_dirCtrl->Bind(wxEVT_DIRCTRL_SELECTIONCHANGED, &BrowsePTOFilesDialog::OnDirectoryChanged, this);
    m_listCtrl = XRCCTRL(*this, "browse_listctrl", wxListCtrl);
    m_listCtrl->Bind(wxEVT_LIST_ITEM_SELECTED, &BrowsePTOFilesDialog::OnFileChanged, this);
    m_listCtrl->Bind(wxEVT_LIST_COL_CLICK, &BrowsePTOFilesDialog::OnListColClick, this);
    m_previewCtrl = XRCCTRL(*this, "browse_preview", wxStaticBitmap);
    m_splitter1 = XRCCTRL(*this, "browse_splitter1", wxSplitterWindow);
    m_splitter2 = XRCCTRL(*this, "browse_splitter2", wxSplitterWindow);
    m_showMap = XRCCTRL(*this, "browse_show_map", wxButton);
    m_labelControl = XRCCTRL(*this, "browse_statictext", wxStaticText);
    m_labelControl->SetFont(m_labelControl->GetFont().Larger().Larger());
    m_thumbnails.Create(THUMBNAIL_SIZE, THUMBNAIL_SIZE, true, 0);
    m_listCtrl->SetWindowStyle(wxLC_REPORT | wxLC_AUTOARRANGE | wxLC_SINGLE_SEL | wxLC_HRULES | wxLC_VRULES);
    m_listCtrl->SetImageList(&m_thumbnails, wxIMAGE_LIST_NORMAL);
    m_listCtrl->Bind(wxEVT_LEFT_DCLICK, &BrowsePTOFilesDialog::OnDblClickListCtrl, this);
    m_listCtrl->InsertColumn(0, _("Filename"), wxLIST_FORMAT_LEFT, 300);
    m_listCtrl->InsertColumn(1, _("# images"), wxLIST_FORMAT_RIGHT, 50);
    m_listCtrl->InsertColumn(2, _("# active images"), wxLIST_FORMAT_RIGHT, 50);
    m_listCtrl->InsertColumn(3, _("Projection"), wxLIST_FORMAT_LEFT, 200);
    m_listCtrl->InsertColumn(4, _("Field of view"), wxLIST_FORMAT_LEFT, 100);
    m_listCtrl->InsertColumn(5, _("Canvas size"), wxLIST_FORMAT_LEFT, 100);
    m_listCtrl->InsertColumn(6, _("Model"), wxLIST_FORMAT_LEFT, 200);
    m_listCtrl->InsertColumn(7, _("Lens"), wxLIST_FORMAT_LEFT, 250);
    m_listCtrl->InsertColumn(8, _("Focal length"), wxLIST_FORMAT_LEFT, 150);
    m_listCtrl->InsertColumn(9, _("Capture date"), wxLIST_FORMAT_LEFT, 150);
    m_listCtrl->InsertColumn(10, _("Duration"), wxLIST_FORMAT_LEFT, 50);
    m_listType = XRCCTRL(*this, "browse_list_type", wxChoice);
    m_listType->Bind(wxEVT_CHOICE, &BrowsePTOFilesDialog::OnListTypeChanged, this);
    // restore some settings
    hugin_utils::RestoreFramePosition(this, "BrowsePTODialog");
    wxConfigBase* config = wxConfigBase::Get();
    //splitter position
    int splitter_pos = config->Read("/BrowsePTODialog/splitterPos1", -1l);
    if (splitter_pos > 0)
    {
        m_splitter1->SetSashPosition(splitter_pos);
    };
    splitter_pos = config->Read("/BrowsePTODialog/splitterPos2", -1l);
    if (splitter_pos > 0)
    {
        m_splitter2->SetSashPosition(splitter_pos);
    };
    //get saved width
    for (int j = 0; j < m_listCtrl->GetColumnCount(); j++)
    {
        // -1 is auto
        int width = config->Read(wxString::Format("/BrowsePTODialog/ColumnWidth%d", j), -1);
        if (width != -1 && width > 5)
        {
            m_listCtrl->SetColumnWidth(j, width);
        };
    };
    m_sortCol = config->Read("/BrowsePTODialog/SortColumn", -1);
    m_sortAscending = config->Read("/BrowsePTODialog/SortAscending", 1) == 1 ? true : false;
    if (m_sortCol != -1)
    {
        m_listCtrl->ShowSortIndicator(m_sortCol, m_sortAscending);
    };

    // fill values for start directory
    if (!startDirectory.IsEmpty())
    {
        m_dirCtrl->SetPath(startDirectory);
    };
    long listType = config->Read("/BrowsePTODialog/ListType", 0l);
    m_listType->SetSelection(listType);
    wxCommandEvent event;
    event.SetInt(listType);
    OnListTypeChanged(event);
    Bind(wxEVT_BUTTON, &BrowsePTOFilesDialog::OnOk, this, wxID_OK);
    Bind(wxEVT_BUTTON, &BrowsePTOFilesDialog::OnShowOnMap, this, XRCID("browse_show_map"));
    Bind(wxEVT_COMMAND_THUMBNAILTHREAD_UPDATE, &BrowsePTOFilesDialog::OnThumbnailUpdate, this);
};

BrowsePTOFilesDialog::~BrowsePTOFilesDialog()
{
    // stop working thread
    EndThumbnailThread();
    // save some settings
    hugin_utils::StoreFramePosition(this, "BrowsePTODialog");
    wxConfigBase* config = wxConfigBase::Get();
    config->Write("/BrowsePTODialog/splitterPos1", m_splitter1->GetSashPosition());
    config->Write("/BrowsePTODialog/splitterPos2", m_splitter2->GetSashPosition());
    // save width of all columns in wxListCtrl
    for (int j = 0; j < m_listCtrl->GetColumnCount(); j++)
    {
        config->Write(wxString::Format("/BrowsePTODialog/ColumnWidth%d", j), m_listCtrl->GetColumnWidth(j));
    };
    config->Write("/BrowsePTODialog/ListType", m_listType->GetSelection());
    config->Write("/BrowsePTODialog/SortColumn", m_sortCol);
    config->Write("/BrowsePTODialog/SortAscending", m_sortAscending ? 1 : 0);
    config->Flush();
}

wxString BrowsePTOFilesDialog::GetSelectedProject()
{
    long index = -1;
    if (m_listCtrl->GetSelectedItemCount() == 1)
    {
        index = m_listCtrl->GetNextItem(-1, wxLIST_NEXT_ALL, wxLIST_STATE_SELECTED);
    };
    if (index >= 0 && index < m_ptoInfo.size())
    {
        return m_ptoInfo[TranslateIndex(index)].ptoFilename.GetFullPath();
    }
    else
    {
        return wxEmptyString;
    };
}

wxString BrowsePTOFilesDialog::GetSelectedPath()
{
    return m_dirCtrl->GetPath();
}

void BrowsePTOFilesDialog::OnOk(wxCommandEvent& e)
{
    if (m_listCtrl->GetSelectedItemCount() == 1)
    {
        EndModal(wxID_OK);
    }
    else
    {
        wxBell();
    }
}

PanoInfo BrowsePTOFilesDialog::ParsePTOFile(const wxFileName file)
{
    PanoInfo info;
    info.ptoFilename = file;
    // read pto file
    HuginBase::Panorama pano;
    const std::string input(file.GetFullPath().mb_str(HUGIN_CONV_FILENAME));
    if (!pano.ReadPTOFile(input, hugin_utils::getPathPrefix(input)))
    {
        return info;
    };
    // fill class to store some information about the pano
    info.nrImages = pano.getNrOfImages();
    info.nrActiveImages = pano.getActiveImages().size();
    info.options = pano.getOptions();
    // translate projection name
    {
        pano_projection_features proj;
        wxString s;
        if (panoProjectionFeaturesQuery(info.options.getProjection(), &proj))
        {
            wxString str2(proj.name, wxConvLocal);
            info.projectionName = wxGetTranslation(str2);
        };
    };
    // read some EXIF data
    const HuginBase::UIntSet activeImages = pano.getActiveImages();
    if (!activeImages.empty())
    {
        HuginBase::SrcPanoImage img0 = pano.getSrcImage(*activeImages.begin());
        if(!hugin_utils::FileExists(img0.getFilename()))
        {
            return info;
        }
        img0.readEXIF();
        info.camera = img0.getExifModel();
        info.lens = img0.getExifLens();
        info.focalLength35 = img0.getExifFocalLength35();
        if (info.focalLength35 < 0.01 && img0.getCropFactor()>0)
        {
            info.focalLength35 = img0.getExifFocalLength() * img0.getCropFactor();
        };
        if (info.focalLength35 < 0.01)
        {
            info.focalLength35 = HuginBase::SrcPanoImage::calcFocalLength(img0.getProjection(), img0.getHFOV(), 1.0, img0.getSize());
        };
        info.focalLengthString = FormatString::GetFocalLength(&img0);
        // read date/time of all active images
        if (!img0.getExifDate().empty())
        {
            struct tm exifdatetime;
            if (img0.getExifDateTime(&exifdatetime) == 0)
            {
                info.start = wxDateTime(exifdatetime);
                info.end = info.start;
            };
            // iterate all images, except the first one, this image is already handled before
            HuginBase::UIntSet imgs(activeImages);
            imgs.erase(imgs.begin());
            for (const auto& img : imgs)
            {
                HuginBase::SrcPanoImage imgSrcImage = pano.getSrcImage(img);
                if (!hugin_utils::FileExists(imgSrcImage.getFilename()))
                {
                    continue;
                };
                imgSrcImage.readEXIF();
                memset(&exifdatetime, 0, sizeof(exifdatetime));
                if (!imgSrcImage.getExifDate().empty() && imgSrcImage.getExifDateTime(&exifdatetime) == 0)
                {
                    const wxDateTime dateTime = wxDateTime(exifdatetime);
                    if (info.start.IsValid())
                    {
                        if (dateTime.IsEarlierThan(info.start))
                        {
                            info.start = dateTime;
                        }
                        if (dateTime.IsLaterThan(info.end))
                        {
                            info.end = dateTime;
                        }
                    }
                    else
                    {
                        info.start = dateTime;
                        info.end = dateTime;
                    }
                }
            }
            if (info.start.IsValid())
            {
                info.duration = info.end.Subtract(info.start);
            }
        };
        const auto& fileMetadata = img0.getFileMetadata();
        const auto& latitude = fileMetadata.find("latitude");
        const auto& longitude = fileMetadata.find("longitude");
        if (latitude != fileMetadata.end())
        {
            hugin_utils::stringToDouble(latitude->second, info.GPSLatitude);
        };
        if (longitude != fileMetadata.end())
        {
            hugin_utils::stringToDouble(longitude->second, info.GPSLongitude);
        };
    };
    return info;
}

void BrowsePTOFilesDialog::FillPanoInfo(const PanoInfo& info, long index)
{
#ifndef __WXMSW__
    // in generic implementation we can add text to column only in report view
    if (m_listCtrl->InReportView())
#endif
    {
        m_listCtrl->SetItem(index, 1, wxString::Format("%zu", info.nrImages));
        m_listCtrl->SetItem(index, 2, wxString::Format("%zu", info.nrActiveImages));
        m_listCtrl->SetItem(index, 3, info.projectionName);
        m_listCtrl->SetItem(index, 4, wxString::Format("%.0f x %.0f", info.options.getHFOV(), info.options.getVFOV()));
        m_listCtrl->SetItem(index, 5, wxString::Format("%u x %u", info.options.getWidth(), info.options.getHeight()));
        m_listCtrl->SetItem(index, 6, info.camera);
        m_listCtrl->SetItem(index, 7, info.lens);
        m_listCtrl->SetItem(index, 8, info.focalLengthString);
        if (info.start.IsValid())
        {
            m_listCtrl->SetItem(index, 9, info.start.Format());
        };
        m_listCtrl->SetItem(index, 10, hugin_utils::GetFormattedTimeSpan(info.duration));
    };
}

void BrowsePTOFilesDialog::UpdateItemTexts(long newStyle)
{
#ifndef __WXMSW__
    m_listCtrl->DeleteAllItems();
#endif
    m_listCtrl->SetWindowStyle(newStyle);
#ifndef __WXMSW__
    // changing the window style does invalidate the items, so we delete all items 
    // and add then again
    for (size_t i = 0; i < m_ptoInfo.size(); ++i)
    {
        m_listCtrl->InsertItem(i, m_ptoInfo[i].ptoFilename.GetFullName(), -1);
        m_listCtrl->SetItemData(i, i);
        FillPanoInfo(m_ptoInfo[i], i);
    };
    SortItems();
#endif
}

void BrowsePTOFilesDialog::OnDirectoryChanged(wxTreeEvent& e)
{
    if (m_dirCtrl && m_listCtrl)
    {
        wxWindowDisabler disableAll;
        wxBusyInfo busy(wxBusyInfoFlags().Icon(MainFrame::Get()->GetIcon()).Label(wxString::Format(_("Reading directory %s"), m_dirCtrl->GetPath().c_str())));
        // stop running thumbnail thread from last directory if not finished yet
        EndThumbnailThread();
        // find all pto files in directory
        m_ptoInfo.clear();
        m_thumbnails.RemoveAll();
        SetTitle(wxString::Format(_("Browse project files in %s"), m_dirCtrl->GetPath().c_str()));
        wxArrayString files;
        wxDir::GetAllFiles(m_dirCtrl->GetPath(), &files, "*.pto", wxDIR_FILES | wxDIR_HIDDEN | wxDIR_NO_FOLLOW);
        // add to wxListCtrl
        m_listCtrl->DeleteAllItems();
        m_ptoInfo.resize(files.size());
        for (size_t i = 0; i < files.size(); ++i)
        {
            const wxFileName filename(files[i]);
            m_ptoInfo[i] = ParsePTOFile(filename);
            m_listCtrl->InsertItem(i, m_ptoInfo[i].ptoFilename.GetFullName(), -1);
            m_listCtrl->SetItemData(i, i);
            FillPanoInfo(m_ptoInfo[i], i);
        };
        SortItems();
        // start background thread for creating all thumbnails
        m_thumbnailThread = new ThumbnailThread(this, files, m_thumbnails.GetSize());
        if (!m_listCtrl->InReportView())
        {
            m_thumbnailThread->Run();
        };
        // clear preview area
        m_previewCtrl->SetBitmap(wxBitmap());
        m_previewCtrl->Show(true);
        m_labelControl->Show(false);
        m_showMap->Show(false);
        m_showMap->Enable(false);
        m_showMap->GetParent()->Layout();
    };
}

void BrowsePTOFilesDialog::OnFileChanged(wxListEvent& e)
{
    if (e.GetIndex() >= 0)
    {
        GeneratePreview(TranslateIndex(e.GetIndex()));
    };
}

void BrowsePTOFilesDialog::OnDblClickListCtrl(wxMouseEvent& e)
{
    if (m_listCtrl->GetSelectedItemCount() == 1)
    {
        EndModal(wxID_OK);
    };
}

void BrowsePTOFilesDialog::OnListColClick(wxListEvent& e)
{
    const int newCol = e.GetColumn();
    if (m_sortCol == newCol)
    {
        m_sortAscending = !m_sortAscending;
    }
    else
    {
        m_sortCol = newCol;
        m_sortAscending = true;
    };
    m_listCtrl->ShowSortIndicator(m_sortCol, m_sortAscending);
    SortItems();
    Refresh();
}

void BrowsePTOFilesDialog::OnThumbnailUpdate(wxCommandEvent& e)
{
    // we have created a new thumbnail, make the wxListCtrl aware of it
    const int index = e.GetInt();
    ThreadImage* thumbnail= wxDynamicCast(e.GetEventObject(), ThreadImage);
    m_ptoInfo[index].imageIndex = m_thumbnails.Add(*(thumbnail->GetwxImage()));
    for (size_t i = 0; i < m_listCtrl->GetItemCount(); ++i)
    {
        if (m_listCtrl->GetItemData(i) == index)
        {
            m_listCtrl->SetItemImage(i, m_ptoInfo[index].imageIndex);
            break;
        };
    };
    delete thumbnail;
#ifndef __WXMSW__
    // a simple Refresh for repainting the control is not working
    // all thumbnails are drawn on top of each other
    // only when all done after a size event all is drawn correctly
    m_listCtrl->SendSizeEvent();
#endif
}

void BrowsePTOFilesDialog::OnListTypeChanged(wxCommandEvent& e)
{
    if (e.GetSelection() == 0)
    {
        UpdateItemTexts(wxLC_ICON | wxLC_AUTOARRANGE | wxLC_SINGLE_SEL);
        // start creating thumbnail images in background thread
        if (m_thumbnailThread && !m_thumbnailThread->IsRunning())
        {
            m_thumbnailThread->Run();
        };
    }
    else
    {
        UpdateItemTexts(wxLC_REPORT | wxLC_AUTOARRANGE | wxLC_SINGLE_SEL | wxLC_HRULES | wxLC_VRULES);
    };
#ifndef __WXMSW__
    // a simple Refresh for repainting the control is not working
    // all thumbnails are drawn on top of each other
    // only when all done after a size event all is drawn correctly
    m_listCtrl->SendSizeEvent();
#endif
}

void BrowsePTOFilesDialog::OnShowOnMap(wxCommandEvent& e)
{
    long index = -1;
    if (m_listCtrl->GetSelectedItemCount() == 1)
    {
        index = m_listCtrl->GetNextItem(-1, wxLIST_NEXT_ALL, wxLIST_STATE_SELECTED);
    };
    if (index >= 0 && index < m_ptoInfo.size())
    {
        if (m_ptoInfo[index].HasGPS())
        {
            const wxString openstreetMapLink = "https://www.openstreetmap.org/?mlat=" + wxString::FromCDouble(m_ptoInfo[index].GPSLatitude) + "&mlon=" + wxString::FromCDouble(m_ptoInfo[index].GPSLongitude);
            wxLaunchDefaultBrowser(openstreetMapLink);
        }
    }
}

long BrowsePTOFilesDialog::TranslateIndex(const long index)
{
    return m_listCtrl->GetItemData(index);
}

template <class Type>
int GreaterComparisonOperator(const Type& a, const Type& b)
{
    if (a > b)
    {
        return 1;
    }
    else
    {
        if (a < b)
        {
            return -1;
        }
        else {
            return 0;
        };
    }
}

template <class Type>
int SmallerComparisonOperator(const Type& a, const Type& b)
{
    if (a < b)
    {
        return 1;
    }
    else
    {
        if (a > b)
        {
            return -1;
        }
        else {
            return 0;
        };
    }
}

#define SORTASCENDING(functionName, var) \
int wxCALLBACK functionName(wxIntPtr item1, wxIntPtr item2, wxIntPtr sortData)\
{\
    std::vector<PanoInfo>* data = (std::vector<PanoInfo>*)(sortData);\
    return GreaterComparisonOperator(data->at(item1).var, data->at(item2).var);\
}
#define SORTDESCENDING(functionName, var) \
int wxCALLBACK functionName(wxIntPtr item1, wxIntPtr item2, wxIntPtr sortData)\
{\
    std::vector<PanoInfo>* data = (std::vector<PanoInfo>*)(sortData);\
    return SmallerComparisonOperator(data->at(item1).var, data->at(item2).var);\
}

SORTASCENDING(SortFilenameAscending, ptoFilename.GetFullName())
SORTDESCENDING(SortFilenameDescending, ptoFilename.GetFullName())
SORTASCENDING(SortNrImagesAscending, nrImages)
SORTDESCENDING(SortNrImagesDescending, nrImages)
SORTASCENDING(SortNrActiveImagesAscending, nrActiveImages)
SORTDESCENDING(SortNrActiveImagesDescending, nrActiveImages)
SORTASCENDING(SortProjectionAscending, projectionName)
SORTDESCENDING(SortProjectionDescending, projectionName)
SORTASCENDING(SortCanvasSizeAcending, options.getSize().area())
SORTDESCENDING(SortCanvasSizeDescending, options.getSize().area())
SORTASCENDING(SortFocalLengthAscending, focalLength35)
SORTDESCENDING(SortFocalLengthDescending, focalLength35)

#undef SORTASCENDING
#undef SORTDESCENDING

// special variant for wxStrings
#define SORTASCENDING(functionName, var) \
int wxCALLBACK functionName(wxIntPtr item1, wxIntPtr item2, wxIntPtr sortData)\
{\
    std::vector<PanoInfo>* data = (std::vector<PanoInfo>*)(sortData);\
    return data->at(item1).var.CmpNoCase(data->at(item2).var);\
}
#define SORTDESCENDING(functionName, var) \
int wxCALLBACK functionName(wxIntPtr item1, wxIntPtr item2, wxIntPtr sortData)\
{\
    std::vector<PanoInfo>* data = (std::vector<PanoInfo>*)(sortData);\
    return -(data->at(item1).var.CmpNoCase(data->at(item2).var));\
}
SORTASCENDING(SortCameraAscending, camera)
SORTDESCENDING(SortCameraDescending, camera)
SORTASCENDING(SortLensAscending, lens)
SORTDESCENDING(SortLensDescending, lens)

#undef SORTASCENDING
#undef SORTDESCENDING

// sort by field of view
int wxCALLBACK SortFieldOfViewAscending(wxIntPtr item1, wxIntPtr item2, wxIntPtr sortData)
{
    std::vector<PanoInfo>* data = (std::vector<PanoInfo>*)(sortData);
    const float fieldOfView1 = data->at(item1).options.getHFOV() * 1000 + data->at(item1).options.getVFOV();
    const float fieldOfView2 = data->at(item2).options.getHFOV() * 1000 + data->at(item2).options.getVFOV();
    return GreaterComparisonOperator(fieldOfView1, fieldOfView2);
}

int wxCALLBACK SortFieldOfViewDescending(wxIntPtr item1, wxIntPtr item2, wxIntPtr sortData)
{
    std::vector<PanoInfo>* data = (std::vector<PanoInfo>*)(sortData);
    const float fieldOfView1 = data->at(item1).options.getHFOV() * 1000 + data->at(item1).options.getVFOV();
    const float fieldOfView2 = data->at(item2).options.getHFOV() * 1000 + data->at(item2).options.getVFOV();
    return SmallerComparisonOperator(fieldOfView1, fieldOfView2);
}

// sort by date
int wxCALLBACK SortDateAscending(wxIntPtr item1, wxIntPtr item2, wxIntPtr sortData)
{
    std::vector<PanoInfo>* data = (std::vector<PanoInfo>*)(sortData);
    if (data->at(item1).start.IsLaterThan(data->at(item2).start))
    {
        return 1;
    }
    if (data->at(item1).start.IsEarlierThan(data->at(item2).start))
    {
        return -1;
    }
    return 0;
};

int wxCALLBACK SortDateDesending(wxIntPtr item1, wxIntPtr item2, wxIntPtr sortData)
{
    std::vector<PanoInfo>* data = (std::vector<PanoInfo>*)(sortData);
    if (data->at(item1).start.IsEarlierThan(data->at(item2).start))
    {
        return 1;
    }
    if (data->at(item1).start.IsLaterThan(data->at(item2).start))
    {
        return -1;
    }
    return 0;
};

// sort by duration
int wxCALLBACK SortDurationAscending(wxIntPtr item1, wxIntPtr item2, wxIntPtr sortData)
{
    std::vector<PanoInfo>* data = (std::vector<PanoInfo>*)(sortData);
    if (data->at(item1).duration.IsLongerThan(data->at(item2).duration))
    {
        return 1;
    }
    if (data->at(item1).duration.IsShorterThan(data->at(item2).duration))
    {
        return -1;
    }
    return 0;
};

int wxCALLBACK SortDurationDesending(wxIntPtr item1, wxIntPtr item2, wxIntPtr sortData)
{
    std::vector<PanoInfo>* data = (std::vector<PanoInfo>*)(sortData);
    if (data->at(item1).duration.IsShorterThan(data->at(item2).duration))
    {
        return 1;
    }
    if (data->at(item1).duration.IsLongerThan(data->at(item2).duration))
    {
        return -1;
    }
    return 0;
};

void BrowsePTOFilesDialog::SortItems()
{
    if (m_sortCol > -1)
    {
        switch (m_sortCol)
        {
            default:
            case 0:  // filename
                if (m_sortAscending)
                {
                    m_listCtrl->SortItems(SortFilenameAscending, wxIntPtr(&m_ptoInfo));
                }
                else
                {
                    m_listCtrl->SortItems(SortFilenameDescending, wxIntPtr(&m_ptoInfo));
                };
                break;
            case 1:  // number of images
                if (m_sortAscending)
                {
                    m_listCtrl->SortItems(SortNrImagesAscending, wxIntPtr(&m_ptoInfo));
                }
                else
                {
                    m_listCtrl->SortItems(SortNrImagesDescending, wxIntPtr(&m_ptoInfo));
                };
                break;
            case 2:  // number of active images
                if (m_sortAscending)
                {
                    m_listCtrl->SortItems(SortNrActiveImagesAscending, wxIntPtr(&m_ptoInfo));
                }
                else
                {
                    m_listCtrl->SortItems(SortNrActiveImagesDescending, wxIntPtr(&m_ptoInfo));
                };
                break;
            case 3: // projection
                if (m_sortAscending)
                {
                    m_listCtrl->SortItems(SortProjectionAscending, wxIntPtr(&m_ptoInfo));
                }
                else
                {
                    m_listCtrl->SortItems(SortProjectionDescending, wxIntPtr(&m_ptoInfo));
                };
                break;
            case 4: // field of view
                if (m_sortAscending)
                {
                    m_listCtrl->SortItems(SortFieldOfViewAscending, wxIntPtr(&m_ptoInfo));
                }
                else
                {
                    m_listCtrl->SortItems(SortFieldOfViewDescending, wxIntPtr(&m_ptoInfo));
                };
                break;
            case 5: // canvas size
                if (m_sortAscending)
                {
                    m_listCtrl->SortItems(SortCanvasSizeAcending, wxIntPtr(&m_ptoInfo));
                }
                else
                {
                    m_listCtrl->SortItems(SortCanvasSizeDescending, wxIntPtr(&m_ptoInfo));
                };
                break;
            case 6: // model
                if (m_sortAscending)
                {
                    m_listCtrl->SortItems(SortCameraAscending, wxIntPtr(&m_ptoInfo));
                }
                else
                {
                    m_listCtrl->SortItems(SortCameraDescending, wxIntPtr(&m_ptoInfo));
                };
                break;
            case 7: // lens
                if (m_sortAscending)
                {
                    m_listCtrl->SortItems(SortLensAscending, wxIntPtr(&m_ptoInfo));
                }
                else
                {
                    m_listCtrl->SortItems(SortLensDescending, wxIntPtr(&m_ptoInfo));
                };
                break;
            case 8: // focal length
                if (m_sortAscending)
                {
                    m_listCtrl->SortItems(SortFocalLengthAscending, wxIntPtr(&m_ptoInfo));
                }
                else
                {
                    m_listCtrl->SortItems(SortFocalLengthDescending, wxIntPtr(&m_ptoInfo));
                };
                break;
            case 9: // capture date
                if (m_sortAscending)
                {
                    m_listCtrl->SortItems(SortDateAscending, wxIntPtr(&m_ptoInfo));
                }
                else
                {
                    m_listCtrl->SortItems(SortDateDesending, wxIntPtr(&m_ptoInfo));
                };
                break;
            case 10: // duration
                if (m_sortAscending)
                {
                    m_listCtrl->SortItems(SortDurationAscending, wxIntPtr(&m_ptoInfo));
                }
                else
                {
                    m_listCtrl->SortItems(SortDurationDesending, wxIntPtr(&m_ptoInfo));
                };
                break;
        };
    };
};

void BrowsePTOFilesDialog::EndThumbnailThread()
{
    // delete running background thread
    wxBusyCursor busy;
    {
        bool deleteStoppedThread = false;
        {
            wxCriticalSectionLocker enter(m_ThreadCS);
            if (m_thumbnailThread)
            {
                if (m_thumbnailThread->IsRunning())
                {
                    m_thumbnailThread->Delete();
                }
                else
                {
                    deleteStoppedThread = true;
                };
            };
        };
        if (deleteStoppedThread)
        {
            delete m_thumbnailThread;
        };
    };
    // exit from the critical section to give the thread
    // the possibility to enter its destructor
    // (which is guarded with m_ThreadCS critical section!)
    while (1)
    {
        {
            wxCriticalSectionLocker enter(m_ThreadCS);
            if (!m_thumbnailThread)
            {
                break;
            };
        };
        // wait for thread completion
        wxThread::This()->Sleep(1);
    };
}

void BrowsePTOFilesDialog::GeneratePreview(int index)
{
    if (index<0 || index>m_ptoInfo.size())
    {
        return;
    };
    wxWindowDisabler disableAll;
    wxBusyInfo busyInfo(wxBusyInfoFlags().Icon(MainFrame::Get()->GetIcon()).Label(wxString::Format(_("Generating preview for %s"), m_ptoInfo[index].ptoFilename.GetFullName().c_str())));
    wxSize previewSize = m_previewCtrl->GetParent()->GetSize();
    vigra::BRGBImage preview;
    vigra::BImage mask;
    vigra::ImageImportInfo::ICCProfile iccProfile;
    if (GenerateThumbnail(m_ptoInfo[index].ptoFilename.GetFullPath().ToStdString(), previewSize, preview, mask, iccProfile))
    {
        wxImage image(preview.width(), preview.height(), (unsigned char*)preview.data(), (unsigned char*)mask.data(), true);
        // now apply color profile
        if (!iccProfile.empty() || huginApp::Get()->HasMonitorProfile())
        {
            HuginBase::Color::CorrectImage(image, iccProfile, huginApp::Get()->GetMonitorProfile());
        };
        // now show in GUI
        m_previewCtrl->SetBitmap(image);
        m_previewCtrl->Show(true);
        m_labelControl->Show(false);
        m_showMap->Show(m_ptoInfo[index].HasGPS());
        m_showMap->Enable(m_ptoInfo[index].HasGPS());
        m_showMap->GetParent()->Layout();
    }
    else
    {
        // could not create preview, disable control and show error message
        m_previewCtrl->Show(false);
        m_labelControl->Show(true);
        m_showMap->Show(false);
        m_showMap->Enable(false);
        m_showMap->GetParent()->Layout();
    };
    Update();
}
