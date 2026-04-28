// -*- c-basic-offset: 4 -*-
/** @file PerspectiveImageCtrl.cpp
 *
 *  @brief implementation of preview for lens calibration gui
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


#include "panoinc_WX.h"
#include "panoinc.h"
#include "ToolboxApp.h"
#include <wx/dcbuffer.h>
#include "base_wx/platform.h"
#include "PerspectiveImageCtrl.h"
#include "vigra/transformimage.hxx"
#include "nona/RemappedPanoImage.h"
#include "nona/ImageRemapper.h"
#include "base_wx/wxcms.h"

// init some values
bool PerspectiveImageCtrl::Create(wxWindow* parent, wxWindowID id,
    const wxPoint& pos,
    const wxSize& size,
    long style,
    const wxString& name)
{
    wxScrolledWindow::Create(parent, id, pos, size, style, name);
    SetBackgroundStyle(wxBG_STYLE_PAINT);
    // bind event handler
    Bind(wxEVT_SIZE, &PerspectiveImageCtrl::OnSize, this);
    Bind(wxEVT_MOTION, &PerspectiveImageCtrl::OnMouseMove, this);
    Bind(wxEVT_LEFT_DOWN, &PerspectiveImageCtrl::OnLeftMouseDown, this);
    Bind(wxEVT_LEFT_UP, &PerspectiveImageCtrl::OnLeftMouseUp, this);
    Bind(wxEVT_RIGHT_UP, &PerspectiveImageCtrl::OnRightMouseUp, this);
    Bind(wxEVT_MIDDLE_DOWN, &PerspectiveImageCtrl::OnMiddleMouseDown, this);
    Bind(wxEVT_MIDDLE_UP, &PerspectiveImageCtrl::OnMiddleMouseUp, this);
    Bind(wxEVT_MOUSE_CAPTURE_LOST, &PerspectiveImageCtrl::OnCaptureLost, this);
    Bind(wxEVT_KILL_FOCUS, &PerspectiveImageCtrl::OnKillFocus, this);
    Bind(wxEVT_PAINT, &PerspectiveImageCtrl::OnPaint, this);

    return true;
}

void PerspectiveImageCtrl::setImage(const std::string& file, ImageRotation rot)
{
    if (!file.empty())
    {
        try
        {
            ImageCache::getInstance().softFlush();
            m_img = ImageCache::getInstance().getImage(file);
        }
        catch (...)
        {
            // loading of image failed, set all to empty values
            m_imageFilename = "";
            m_editorState = NO_IMAGE;
            m_bitmap = wxBitmap();
            // delete the image (release shared_ptr)
            // create an empty image.
            m_img = ImageCache::EntryPtr(new ImageCache::Entry);
            SetVirtualSize(100, 100);
            Refresh(true);
            return;
        }
        m_editorState = SHOW_IMAGE;
        m_imageFilename = file;
        m_imgRotation = rot;
        m_showRemappedImage = false;
        rescaleImage();
        // create initial rectangle
        m_rectPoints.resize(4);
        m_rectPoints[0] = vigra::Point2D(0.25 * m_realSize.GetWidth(), 0.25 * m_realSize.GetHeight());
        m_rectPoints[1] = vigra::Point2D(0.75 * m_realSize.GetWidth(), 0.25 * m_realSize.GetHeight());
        m_rectPoints[2] = vigra::Point2D(0.75 * m_realSize.GetWidth(), 0.75 * m_realSize.GetHeight());
        m_rectPoints[3] = vigra::Point2D(0.25 * m_realSize.GetWidth(), 0.75 * m_realSize.GetHeight());
        // clear lines
        m_lines.clear();
        Refresh();
    }
    else
    {
        m_editorState = NO_IMAGE;
        m_bitmap = wxBitmap();
        // delete the image (release shared_ptr)
        // create an empty image.
        m_img = ImageCache::EntryPtr(new ImageCache::Entry);
        m_imgRotation = ROT0;
        SetVirtualSize(100, 100);
        m_lines.clear();
        Refresh(true);
    }
}

void PerspectiveImageCtrl::ChangeRotation(ImageRotation newRot)
{
    if (newRot != m_imgRotation)
    {
        // image rotation changed, rotate the rectangle
        // update flag and redraw image
        m_imgRotation = newRot;
        rescaleImage();
        Refresh();
    };
}

void PerspectiveImageCtrl::OnMouseMove(wxMouseEvent& mouse)
{
    if (m_showRemappedImage)
    {
        return;
    };
    if (m_middleMouseScroll)
    {
        // handle scrolling and break out
        wxPoint viewStart = GetViewStart();
        viewStart = viewStart - (mouse.GetPosition() - m_scrollPos);
        Scroll(viewStart);
        m_scrollPos = mouse.GetPosition();
        return;
    };
    wxPoint mpos;
    CalcUnscrolledPosition(mouse.GetPosition().x, mouse.GetPosition().y, &mpos.x, &mpos.y);
    hugin_utils::FDiff2D currentPos = applyRotInv(invtransform(mpos));
    ClipPos(currentPos);
    switch (m_editorState)
    {
        case POINT_MOVING:
            m_rectPoints[m_movingPoint] = currentPos;
            Refresh(false);
            break;
        case SEGMENT_MOVING:
            m_rectPoints = m_rectPointsStartDrag;
            {
                const hugin_utils::FDiff2D delta = currentPos - applyRotInv(invtransform(m_dragStartPos));
                m_rectPoints[m_movingPoint] = m_rectPoints[m_movingPoint] + delta;
                m_rectPoints[(m_movingPoint + 1) % 4] = m_rectPoints[(m_movingPoint + 1) % 4] + delta;
            };
            Refresh(false);
            break;
        case RECT_MOVING:
            m_rectPoints = m_rectPointsStartDrag;
            {
                const hugin_utils::FDiff2D delta = currentPos - applyRotInv(invtransform(m_dragStartPos));
                for (auto& p : m_rectPoints)
                {
                    p = p + delta;
                };
            };
            Refresh(false);
            break;
        case LINE_CREATE:
        case LINE_POINT_MOVING:
            if (!m_currentLine.empty())
            {
                m_currentLine[0].end = currentPos;
                Refresh(false);
            };
            break;
        case LINE_MOVING:
            if (!m_currentLine.empty())
            {
                m_currentLine[0] = m_lineStartDrag;
                const hugin_utils::FDiff2D delta = currentPos - applyRotInv(invtransform(m_dragStartPos));
                m_currentLine[0].start = m_currentLine[0].start + delta;
                m_currentLine[0].end = m_currentLine[0].end + delta;
                Refresh(false);
            };
            break;
        default:
            break;
    }
}

void PerspectiveImageCtrl::OnLeftMouseDown(wxMouseEvent& mouse)
{
    if (m_showRemappedImage)
    {
        return;
    };
    DEBUG_DEBUG("LEFT MOUSE DOWN");
    CalcUnscrolledPosition(mouse.GetPosition().x, mouse.GetPosition().y, &m_dragStartPos.x, &m_dragStartPos.y);
    hugin_utils::FDiff2D currentPos = applyRotInv(invtransform(m_dragStartPos));
    m_currentPos = m_dragStartPos;
    if (!HasCapture())
        CaptureMouse();
    SetFocus();
    
    if (m_editorState == SHOW_IMAGE)
    {
        if (m_showRect)
        {
            // in rect mode
            m_movingPoint = GetNearestRectanglePoint(currentPos);
            if (m_movingPoint != -1)
            {
                // click is near one point of the rectangle
                m_editorState = POINT_MOVING;
            }
            else
            {
                m_movingPoint = GetNearestRectangleLine(currentPos);
                if (m_movingPoint != -1)
                {
                    // click is near one line of the rectangle
                    m_editorState = SEGMENT_MOVING;
                    m_rectPointsStartDrag = m_rectPoints;
                }
                else
                {
                    if (IsInsideRect(currentPos))
                    {
                        // click is inside the rect
                        m_editorState = RECT_MOVING;
                        m_rectPointsStartDrag = m_rectPoints;
                    };
                };
            };
        }
        else
        {
            // in lines mode
            bool isStart = true;
            int lineIndex = GetNearestLinePoint(currentPos, isStart);
            if (lineIndex != -1)
            {
                // click is near one point
                m_editorState = LINE_POINT_MOVING;
                Line currentLine = m_lines[lineIndex];
                if (isStart)
                {
                    // if click is near end point, mirror point
                    // so we can move always the end point
                    currentLine.Mirror();
                }
                m_currentLine.push_back(currentLine);
                m_lines.erase(m_lines.begin() + lineIndex);
            }
            else
            {
                lineIndex = GetNearestLine(currentPos);
                if (lineIndex != -1)
                {
                    // click was near one line
                    m_editorState = LINE_MOVING;
                    m_lineStartDrag = m_lines[lineIndex];
                    m_currentLine.push_back(m_lineStartDrag);
                    m_lines.erase(m_lines.begin() + lineIndex);
                }
                else
                {
                    // click is far from all lines, start creating a new line
                    m_editorState = LINE_CREATE;
                    m_currentLine.push_back(Line(currentPos, currentPos));
                };
            };
        };
    };
}

void PerspectiveImageCtrl::ClipPos(hugin_utils::FDiff2D& pos)
{
    if (pos.x < -PerspectiveOffset)
    {
        pos.x = -PerspectiveOffset;
    };
    if (pos.x > m_realSize.GetWidth() + PerspectiveOffset)
    {
        pos.x = m_realSize.GetWidth() + PerspectiveOffset;
    };
    if (pos.y < -PerspectiveOffset)
    {
        pos.y = -PerspectiveOffset;
    };
    if (pos.y > m_realSize.GetHeight() + PerspectiveOffset)
    {
        pos.y = m_realSize.GetHeight() + PerspectiveOffset;
    };
}

void PerspectiveImageCtrl::OnLeftMouseUp(wxMouseEvent& mouse)
{
    if (m_showRemappedImage || m_middleMouseScroll)
    {
        return;
    };
    DEBUG_DEBUG("LEFT MOUSE UP");
    wxPoint mpos;
    CalcUnscrolledPosition(mouse.GetPosition().x, mouse.GetPosition().y, &mpos.x, &mpos.y);
    // limit position to valid area
    hugin_utils::FDiff2D currentPos = applyRotInv(invtransform(mpos));
    ClipPos(currentPos);
    bool doUpdate = false;
    switch (m_editorState)
    {
        case POINT_MOVING:
            m_editorState = SHOW_IMAGE;
            m_rectPoints[m_movingPoint] = currentPos;
            doUpdate = true;
            break;
        case SEGMENT_MOVING:
            m_editorState = SHOW_IMAGE;
            {
                m_rectPoints = m_rectPointsStartDrag;
                const hugin_utils::FDiff2D delta = currentPos - applyRotInv(invtransform(m_dragStartPos));
                m_rectPoints[m_movingPoint] = m_rectPoints[m_movingPoint] + delta;
                m_rectPoints[(m_movingPoint + 1) % 4] = m_rectPoints[(m_movingPoint + 1) % 4] + delta;
            };
            doUpdate = true;
            break;
        case RECT_MOVING:
            m_editorState = SHOW_IMAGE;
            {
                m_rectPoints = m_rectPointsStartDrag;
                const hugin_utils::FDiff2D delta = currentPos - applyRotInv(invtransform(m_dragStartPos));
                for (auto& p : m_rectPoints)
                {
                    p = p + delta;
                };
            };
            doUpdate = true;
            break;
        case LINE_CREATE:
        case LINE_POINT_MOVING:
            m_editorState = SHOW_IMAGE;
            {
                if (!m_currentLine.empty())
                {
                    // update line position and add them to m_lines vector
                    m_currentLine[0].end = currentPos;
                    m_lines.push_back(m_currentLine[0]);
                    m_currentLine.clear();
                };
            };
            doUpdate = true;
            break;
        case LINE_MOVING:
            m_editorState = SHOW_IMAGE;
            {
                Line movedLine = m_lineStartDrag;
                // update start and end position of the line
                const hugin_utils::FDiff2D delta = currentPos - applyRotInv(invtransform(m_dragStartPos));
                movedLine.start = movedLine.start + delta;
                movedLine.end = movedLine.end + delta;
                m_lines.push_back(movedLine);
                m_currentLine.clear();
            };
                doUpdate = true;
            break;
        default:
            break;
    };
    if (HasCapture())
    {
        ReleaseMouse();
    };
    if (doUpdate)
    {
        Refresh(false);
    };
}

void PerspectiveImageCtrl::OnRightMouseUp(wxMouseEvent& mouse)
{
    if (m_showRemappedImage || m_middleMouseScroll || m_showRect)
    {
        // do nothing when
        // * showing remapped images
        // * when scrolling with middle mouse button
        // * when in rectangle mode
        return;
    };
    DEBUG_DEBUG("RIGHT MOUSE UP");
    wxPoint mpos;
    CalcUnscrolledPosition(mouse.GetPosition().x, mouse.GetPosition().y, &mpos.x, &mpos.y);
    hugin_utils::FDiff2D currentPos = applyRotInv(invtransform(mpos));
    if (m_editorState == SHOW_IMAGE)
    {
        // check if click is near one line
        const int lineIndex = GetNearestLine(currentPos);
        if (lineIndex != -1)
        {
            // delete the found line
            m_lines.erase(m_lines.begin() + lineIndex);
            Refresh();
        };
    };
}

void PerspectiveImageCtrl::OnMiddleMouseDown(wxMouseEvent& mouse)
{
    if (m_showRemappedImage || m_middleMouseScroll)
    {
        return;
    };
    switch (m_editorState)
    {
    case SHOW_IMAGE:
        if (!HasCapture())
        {
            CaptureMouse();
        };
        // store the scroll rate, the scroll rate set in rescaleImage is optimized for srolling
        // with the cursor keys, but this is too high for mouse scrolling
        // so change the scroll rate here and restore later in OnMiddleMouseUp
        m_middleMouseScroll = true;
        m_scrollPos = mouse.GetPosition();
        break;
    default:
        // in other case ignore the middle mouse button
        break;
    };
}

void PerspectiveImageCtrl::OnMiddleMouseUp(wxMouseEvent& mouse)
{
    if (m_showRemappedImage)
    {
        return;
    };
    if (HasCapture())
    {
        ReleaseMouse();
    };
    m_middleMouseScroll = false;
}

void PerspectiveImageCtrl::OnCaptureLost(wxMouseCaptureLostEvent& e)
{
    wxFocusEvent dummy;
    OnKillFocus(dummy);
};

void PerspectiveImageCtrl::OnKillFocus(wxFocusEvent& e)
{
    if (HasCapture())
    {
        ReleaseMouse();
    };
}

void PerspectiveImageCtrl::SetLineColour(wxColour newColour)
{
    m_colour_selected = newColour;
    Refresh();
}

void PerspectiveImageCtrl::DrawRect(wxDC& dc, const std::vector<hugin_utils::FDiff2D>& rect)
{
    if (rect.size() == 4)
    {
        wxPoint* polygonPoints = new wxPoint[4];
        for (unsigned int j = 0; j < 4; j++)
        {
            polygonPoints[j] = transform(applyRot(rect[j]));
        };
        dc.SetPen(wxPen(m_colour_selected, 1, wxPENSTYLE_SOLID));
        dc.SetBrush(*wxTRANSPARENT_BRUSH);
        dc.DrawPolygon(4, polygonPoints);
        // draw markers at each corner
        dc.SetBrush(wxBrush(m_colour_selected));
        for (unsigned int j = 0; j < 4; j++)
        {
            dc.DrawRectangle(polygonPoints[j].x - polygonPointSize, polygonPoints[j].y - polygonPointSize,
                2 * polygonPointSize, 2 * polygonPointSize);
        };
        delete[]polygonPoints;
    };
}

void PerspectiveImageCtrl::DrawLines(wxDC& dc, const std::vector<Line>& lines)
{
    if (!lines.empty())
    {
        dc.SetPen(wxPen(m_colour_selected, 1, wxPENSTYLE_SOLID));
        // dc.SetBrush(*wxTRANSPARENT_BRUSH);
        dc.SetBrush(wxBrush(m_colour_selected));
        for (const auto& p : lines)
        {
            const wxPoint start = transform(applyRot(p.start));
            const wxPoint end = transform(applyRot(p.end));
            dc.DrawLine(start, end);
            // draw markers
            dc.DrawRectangle(start.x - polygonPointSize, start.y - polygonPointSize, 2 * polygonPointSize, 2 * polygonPointSize);
            dc.DrawRectangle(end.x - polygonPointSize, end.y - polygonPointSize, 2 * polygonPointSize, 2 * polygonPointSize);
        };
    };
}

void PerspectiveImageCtrl::OnPaint(wxPaintEvent& e)
{
    wxAutoBufferedPaintDC dc(this);
    PrepareDC(dc);
    dc.SetBackground(GetBackgroundColour());
    dc.Clear();
    if (m_showRemappedImage)
    {
        // draw remapped image
        if (m_remappedImg.IsOk() && m_remappedImg.GetWidth() > 0 && m_remappedImg.GetHeight() > 0)
        {
            dc.DrawBitmap(m_remappedImg, 0, 0);
        };
    }
    else
    {
        // draw original image
        if (m_bitmap.IsOk())
        {
            const int offset = scale(PerspectiveOffset);
            dc.DrawBitmap(m_bitmap, offset, offset);
            if (m_showRect)
            {
                // draw user rectangle
                DrawRect(dc, m_rectPoints);
            }
            else
            {
                // draw lines
                DrawLines(dc, m_lines);
                if (!m_currentLine.empty())
                {
                    DrawLines(dc, m_currentLine);
                };
            };
        };
    };
}

HuginBase::ControlPoint PerspectiveImageCtrl::GetCP(const unsigned int index, const hugin_utils::FDiff2D& p1, const hugin_utils::FDiff2D& p2)
{
    HuginBase::ControlPoint cp;
    cp.image1Nr = index;
    cp.x1 = p1.x;
    cp.y1 = p1.y;
    cp.x2 = p2.x;
    cp.y2 = p2.y;
    const bool rotatedImage = m_imgRotation == ROT90 || m_imgRotation == ROT270;
    if (abs(cp.x1 - cp.x2) < abs(cp.y1 - cp.y2))
    {
        cp.mode = rotatedImage ? HuginBase::ControlPoint::Y : HuginBase::ControlPoint::X;
    }
    else
    {
        cp.mode = rotatedImage ? HuginBase::ControlPoint::X : HuginBase::ControlPoint::Y;
    };   
    return cp;
}

void PerspectiveImageCtrl::SetRectMode(bool newMode)
{
    if (m_showRect != newMode)
    {
        m_showRect = newMode;
        Refresh();
    };
}

HuginBase::CPVector PerspectiveImageCtrl::GetControlPoints(const unsigned int index)
{
    HuginBase::CPVector controlPoints;
    if (m_showRect)
    {
        // create control points from rect
        controlPoints.push_back(GetCP(index, m_rectPoints[0], m_rectPoints[1]));
        controlPoints.push_back(GetCP(index, m_rectPoints[1], m_rectPoints[2]));
        controlPoints.push_back(GetCP(index, m_rectPoints[2], m_rectPoints[3]));
        controlPoints.push_back(GetCP(index, m_rectPoints[3], m_rectPoints[0]));
    }
    else
    {
        // transform lines into HuginBase::ControlPoint
        for (const auto& p : m_lines)
        {
            controlPoints.push_back(GetCP(index, p.start, p.end));
        };
    }
    return controlPoints;
}

void PerspectiveImageCtrl::SetRemappedMode(const HuginBase::Panorama& pano)
{
    m_pano = pano.duplicate();
    GenerateRemappedImage(GetClientSize().GetWidth(), GetClientSize().GetHeight());
    m_showRemappedImage = true;
    SetVirtualSize(GetClientSize());
    Refresh();
}

void PerspectiveImageCtrl::setOriginalMode() 
{
    m_showRemappedImage = false;
    UpdateVirtualSize();
    Refresh();
}

void PerspectiveImageCtrl::AddLines(const HuginBase::CPVector& lines)
{
    m_lines.clear();
    for (const auto& l : lines)
    {
        m_lines.push_back(Line(hugin_utils::FDiff2D(l.x1, l.y1), hugin_utils::FDiff2D(l.x2, l.y2)));
    };
    Refresh();
}

void PerspectiveImageCtrl::OnSize(wxSizeEvent& e)
{
    // rescale m_bitmap if needed.
    if (!m_imageFilename.empty())
    {
        if (m_fitToWindow)
        {
            setScale(0);
        }
    };
    if (m_showRemappedImage)
    {
        GenerateRemappedImage(e.GetSize().GetWidth(), e.GetSize().GetHeight());
    };
}

void PerspectiveImageCtrl::rescaleImage()
{
    if (m_editorState == NO_IMAGE)
    {
        return;
    }
    wxImage img = imageCacheEntry2wxImage(m_img);
    if (img.GetWidth() == 0)
    {
        return;
    }
    m_imageSize = wxSize(img.GetWidth(), img.GetHeight());
    m_realSize = m_imageSize;
    m_imageSize.IncBy(2 * PerspectiveOffset);
    if (m_fitToWindow)
    {
        m_scaleFactor = calcAutoScaleFactor(m_imageSize);
    };

    //scaling image to screen size
    if (getScaleFactor() != 1.0)
    {
        m_imageSize.SetWidth(scale(m_imageSize.GetWidth()));
        m_imageSize.SetHeight(scale(m_imageSize.GetHeight()));
        wxImageResizeQuality resizeQuality = wxIMAGE_QUALITY_NORMAL;
        if (std::max(img.GetWidth(), img.GetHeight()) > (ULONG_MAX >> 16))
        {
            // wxIMAGE_QUALITY_NORMAL resizes the image with ResampleNearest
            // this algorithm works only if image dimensions are smaller then 
            // ULONG_MAX >> 16 (actual size of unsigned long differ from system
            // to system)
            resizeQuality = wxIMAGE_QUALITY_BOX_AVERAGE;
        };
        img = img.Scale(scale(m_realSize.GetWidth()), scale(m_realSize.GetHeight()), resizeQuality);
    }
    else
    {
        //the conversion to disabled m_bitmap would work on the original cached image file
        //therefore we need to create a copy to work on it
        img = img.Copy();
    };
    //and now rotating
    switch (m_imgRotation)
    {
    case ROT90:
        img = img.Rotate90(true);
        break;
    case ROT180:
        img = img.Rotate180();
        break;
    case ROT270:
        img = img.Rotate90(false);
        break;
    default:
        break;
    }
    // do color correction only if input image has icc profile or if we found a monitor profile
    if (!m_img->iccProfile->empty() || wxGetApp().GetToolboxFrame()->HasMonitorProfile())
    {
        HuginBase::Color::CorrectImage(img, *(m_img->iccProfile), wxGetApp().GetToolboxFrame()->GetMonitorProfile());
    };
    m_bitmap = wxBitmap(img);
    UpdateVirtualSize();
    Refresh(true);
}

void PerspectiveImageCtrl::UpdateVirtualSize()
{
    if (m_imgRotation == ROT90 || m_imgRotation == ROT270)
    {
        SetVirtualSize(m_imageSize.GetHeight(), m_imageSize.GetWidth());
    }
    else
    {
        SetVirtualSize(m_imageSize.GetWidth(), m_imageSize.GetHeight());
    };
    SetScrollRate(1, 1);
}

void PerspectiveImageCtrl::GenerateRemappedImage(const unsigned int newWidth, const unsigned int newHeight)
{
    HuginBase::Nona::RemappedPanoImage<vigra::BRGBImage, vigra::BImage>* remapped = new HuginBase::Nona::RemappedPanoImage<vigra::BRGBImage, vigra::BImage>;
    //fill options with actual size
    HuginBase::PanoramaOptions opts = m_pano.getOptions();
    const double scale = std::min((double)newWidth / opts.getROI().width(), (double)newHeight / opts.getROI().height());
    opts.setWidth(opts.getWidth() * scale, true);
    //now remap image
    remapped->setPanoImage(m_pano.getSrcImage(0), opts, opts.getROI());
    AppBase::DummyProgressDisplay* progress = new AppBase::DummyProgressDisplay();
    remapped->remapImage(vigra::srcImageRange(*(m_img->get8BitImage())), vigra_ext::INTERP_CUBIC, progress);
    delete progress;
    vigra::BRGBImage remappedImage = remapped->m_image;
    wxImage remappedwxImage;
    remappedwxImage.SetData((unsigned char*)remappedImage.data(), remappedImage.width(), remappedImage.height(), true);
    // apply color profiles
    if (!m_img->iccProfile->empty() || wxGetApp().GetToolboxFrame()->HasMonitorProfile())
    {
        HuginBase::Color::CorrectImage(remappedwxImage, *(m_img->iccProfile), wxGetApp().GetToolboxFrame()->GetMonitorProfile());
    };
    delete remapped;
    m_remappedImg = wxBitmap(remappedwxImage);
}

/** returns distance between point p and line between points a and p, the footpoint of p has to be between a and b */
double GetDistance(const hugin_utils::FDiff2D& p, const hugin_utils::FDiff2D& a, const hugin_utils::FDiff2D& b)
{
    const hugin_utils::FDiff2D& r(b - a);
    const double l = (p - a) * r / (r * r);
    if (l >= 0.0 && l <= 1.0)
    {
        // check that footpoint is between both points
        const hugin_utils::FDiff2D x = a + r * l;
        return std::sqrt(x.squareDistance(p));
    }
    else
    {
        return DBL_MAX;
    }
}

int PerspectiveImageCtrl::GetNearestRectanglePoint(const hugin_utils::FDiff2D& p)
{
    if (m_rectPoints.size() == 4)
    {
        double minDist = DBL_MAX;
        int indexMin = -1;
        for (int i = 0; i < 4; ++i)
        {
            const double dist = std::sqrt(p.squareDistance(m_rectPoints[i]));
            if (dist < minDist)
            {
                minDist = dist;
                indexMin = i;
            };
        };
        if (minDist * getScaleFactor() < maxSelectionDistance)
        {
            return indexMin;
        };
    };    
    return -1;
}

int PerspectiveImageCtrl::GetNearestRectangleLine(const hugin_utils::FDiff2D& p)
{
    if (m_rectPoints.size() == 4)
    {
        double minDist = DBL_MAX;
        int indexMin = -1;
        for (int i = 0; i < 4; ++i)
        {
            double dist = GetDistance(p, m_rectPoints[i], m_rectPoints[(i + 1) % 4]);
            if (dist < minDist)
            {
                minDist = dist;
                indexMin = i;
            };
        };
        if (minDist * getScaleFactor() < maxSelectionDistance)
        {
            return indexMin;
        };
    };
    return -1;
}

bool PerspectiveImageCtrl::IsInsideRect(const hugin_utils::FDiff2D& p)
{
    std::vector<double> xpos, ypos;
    for (const auto& p : m_rectPoints)
    {
        xpos.push_back(p.x);
        ypos.push_back(p.y);
    };
    std::sort(xpos.begin(), xpos.end());
    std::sort(ypos.begin(), ypos.end());
    const unsigned int index = (xpos.size() - 1) / 2;
    return (p.x > xpos[index] && p.x < xpos[index + 1] && p.y > ypos[index] && p.y < ypos[index + 1]) ? true : false;
}

int PerspectiveImageCtrl::GetNearestLinePoint(const hugin_utils::FDiff2D& p, bool& isStart)
{
    if (!m_lines.empty())
    {
        double minDist = DBL_MAX;
        int minLineIndex = -1;
        bool minLineStart = false;
        for (int i = 0; i < m_lines.size(); ++i)
        {
            const double distStart = std::sqrt(p.squareDistance(m_lines[i].start));
            const double distEnd = std::sqrt(p.squareDistance(m_lines[i].end));
            // check if distance is shorter to start or end of line
            if (distStart < distEnd)
            {
                if (distStart < minDist)
                {
                    // distance is nearer than older one
                    minDist = distStart;
                    minLineIndex = i;
                    minLineStart = true;
                }
            }
            else
            {
                if (distEnd < minDist)
                {
                    // distance is nearer than older one
                    minDist = distEnd;
                    minLineIndex = i;
                    minLineStart = false;
                }
            };
        };
        if (minLineIndex != -1 && minDist < DBL_MAX)
        {
            if (minDist * getScaleFactor() < maxSelectionDistance)
            {
                // distance is smaller than threshold, return nearest point
                isStart = minLineStart;
                return minLineIndex;
            };
        };
    };
    return -1;
}

int PerspectiveImageCtrl::GetNearestLine(const hugin_utils::FDiff2D& p)
{
    if (!m_lines.empty())
    {
        double minDist = DBL_MAX;
        int indexMin = -1;
        for (int i = 0; i < m_lines.size(); ++i)
        {
            double dist = GetDistance(p, m_lines[i].start, m_lines[i].end);
            if (dist < minDist)
            {
                minDist = dist;
                indexMin = i;
            };
        };
        if (minDist * getScaleFactor() < maxSelectionDistance)
        {
            return indexMin;
        };
    };
    return -1;
}

void PerspectiveImageCtrl::setScale(double factor)
{
    if (factor == 0)
    {
        m_fitToWindow = true;
        factor = calcAutoScaleFactor(m_imageSize);
    }
    else
    {
        m_fitToWindow = false;
    }
    DEBUG_DEBUG("new scale factor:" << factor);
    // update if factor changed
    if (factor != m_scaleFactor)
    {
        m_scaleFactor = factor;
        // keep existing scale focussed.
        rescaleImage();
    }
}

double PerspectiveImageCtrl::getScale() const
{
    return m_fitToWindow ? 0 : m_scaleFactor;
}

double PerspectiveImageCtrl::calcAutoScaleFactor(wxSize size)
{
    int w = size.GetWidth();
    int h = size.GetHeight();
    if (m_imgRotation == ROT90 || m_imgRotation == ROT270)
    {
        int t = w;
        w = h;
        h = t;
    }

    wxSize csize = GetSize();
    DEBUG_DEBUG("csize: " << csize.GetWidth() << "x" << csize.GetHeight() << "image: " << w << "x" << h);
    double s1 = (double)csize.GetWidth() / w;
    double s2 = (double)csize.GetHeight() / h;
    DEBUG_DEBUG("s1: " << s1 << "  s2:" << s2);
    return s1 < s2 ? s1 : s2;
}

double PerspectiveImageCtrl::getScaleFactor() const
{
    return m_scaleFactor;
}

IMPLEMENT_DYNAMIC_CLASS(PerspectiveImageCtrl, wxScrolledWindow)
