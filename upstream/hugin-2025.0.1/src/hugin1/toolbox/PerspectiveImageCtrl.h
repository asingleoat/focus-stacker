// -*- c-basic-offset: 4 -*-
/** @file PerspectiveImageCtrl.h
 *
 *  @brief declaration of preview for lens calibration gui
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

#ifndef PerspectiveImageCtrl_H
#define PerspectiveImageCtrl_H

#include <base_wx/wxImageCache.h>
#include <panoinc.h>
#include <lcms2.h>

/** size of border at all sides */
const int PerspectiveOffset = 200;
/** maximal distance for selection of one point */
const int maxSelectionDistance = 10;
/** half size of markers */
const int polygonPointSize = 3;

/** image previewer for perspective correction
 *
 */
class PerspectiveImageCtrl : public wxScrolledWindow
{
public:
    // simple struct for lines
    class Line
    {
        public:
            hugin_utils::FDiff2D start, end;
            // constructor for fast creation
            Line() : start(hugin_utils::FDiff2D()), end(hugin_utils::FDiff2D()) {};
            Line(const hugin_utils::FDiff2D& p1, const hugin_utils::FDiff2D& p2)
            {
                start = p1;
                end = p2;
            };
            // swap start and end point
            void Mirror()
            {
                hugin_utils::FDiff2D temp = start;
                start = end;
                end = temp;
            };
    };

    /** creates the control */
    bool Create(wxWindow* parent, wxWindowID id = wxID_ANY, const wxPoint& pos = wxDefaultPosition, const wxSize& size = wxDefaultSize, long style = wxTAB_TRAVERSAL, const wxString& name = "panel");

    /** image rotation.
     *  Useful to display images depending on their roll setting.
     *  rotation is clockwise
     */
    enum ImageRotation { ROT0 = 0, ROT90, ROT180, ROT270 };

    /** show the original images with selected zoom ration, the mouse handlers are activated */
    void setOriginalMode();
    bool IsOriginalShown() const { return !m_showRemappedImage; };
    /** set the panorama object for remapping, the mouse handler are deactivated */
    void SetRemappedMode(const HuginBase::Panorama& pano);
    /** set the current image and mask list, this loads also the image from cache */
    void setImage(const std::string& filename, ImageRotation rot);
    void ChangeRotation(ImageRotation newRot);

    /** event handler when mouse is moving */
    void OnMouseMove(wxMouseEvent& mouse);
    /** event handler when left mouse button is pressed */
    void OnLeftMouseDown(wxMouseEvent& mouse);
    /** event handler when right mouse button is released */
    void OnLeftMouseUp(wxMouseEvent& mouse);
    /** event handler when right mouse button is released */
    void OnRightMouseUp(wxMouseEvent& mouse);
    /** event handler for middle mouse button, start scrolling */
    void OnMiddleMouseDown(wxMouseEvent& mouse);
    /** event handler for middle mouse button, end scrolling */
    void OnMiddleMouseUp(wxMouseEvent& mouse);
    /** event handler, when mouse capture is lost, e.g. user click outside of window
     *  cancels creating of new mask */
    void OnCaptureLost(wxMouseCaptureLostEvent& e);
    /** event handler, when editor lost focus, mainly cancels creating new polygon */
    void OnKillFocus(wxFocusEvent& e);

    /** set the scaling factor for mask editing display.
     *
     *  @param factor zoom factor, 0 means fit to window.
     */
    void setScale(double factor);
    /** return scale factor, 0 for autoscale */
    double getScale() const;

    /** returns the current rotation of displayed image */
    ImageRotation getCurrentRotation() { return m_imgRotation; };
    /** sets the colour for the lines */
    void SetLineColour(wxColour newColour);

    /** drawing routine */
    void OnPaint(wxPaintEvent& e);
    /** set line or rect mode */
    void SetRectMode(bool newMode);
    /** return list of control points */
    HuginBase::CPVector GetControlPoints(const unsigned int index);

    /** return pointer to ImageCache */
    ImageCache::EntryPtr getCachedImage() { return m_img; };
    /** add the lines to the list */
    void AddLines(const HuginBase::CPVector& lines);
protected:
    /** handler called when size of control was changed */
    void OnSize(wxSizeEvent& e);

    /** get scale factor (calculates factor when fit to window is active) */
    double getScaleFactor() const;
    /** calculate new scale factor for this image */
    double calcAutoScaleFactor(wxSize size);
    /** rescale the image */
    void rescaleImage();
    /** update the virtual size of the control, necessary for correctly display the scrollbars */
    void UpdateVirtualSize();

private:
    /** return the HuginBase::ControlPoint, using index as image index, p1 and p2 as position, take image rotation into account 
        to decide if control point is horizontal or vertical */
    HuginBase::ControlPoint GetCP(const unsigned int index, const hugin_utils::FDiff2D& p1, const hugin_utils::FDiff2D& p2);
    /** clip the given pos to image size + offset */
    void ClipPos(hugin_utils::FDiff2D& pos);
    /** return index of nearest rectangle point or -1 if the point is too far from rectangle */
    int GetNearestRectanglePoint(const hugin_utils::FDiff2D& p);
    /** return index of nearest rectangle line or -1 if the point is too far from the rectangle lines */
    int GetNearestRectangleLine(const hugin_utils::FDiff2D& p);
    /** return true, if the point p is inside the rect */
    bool IsInsideRect(const hugin_utils::FDiff2D& p);
    /** return index of nearest line or -1 if the point to far from line
      @param p point for testing 
      @param isStart (out): return true if the pos is near the start of the line, otherwise false, unchanged if not line is near the given point*
      */
    int GetNearestLinePoint(const hugin_utils::FDiff2D& p, bool& isStart);
    /** return index of nearest line or -1 if the point is too far from all lines */
    int GetNearestLine(const hugin_utils::FDiff2D& p);
    /** generates the remapped image suitable for wxBitmap */
    void GenerateRemappedImage(const unsigned int newWidth, const unsigned int newHeight);
    //draw the given polygon
    void DrawRect(wxDC& dc, const std::vector<hugin_utils::FDiff2D>& rect);
    // draw lines
    void DrawLines(wxDC& dc, const std::vector<Line>& lines);

    //scaled bitmap
    wxBitmap m_bitmap;
    /** the remapped image as wxBitmap */
    wxBitmap m_remappedImg;

    //filename of current editing file
    std::string m_imageFilename;
    // stores rotation of image
    ImageRotation m_imgRotation{ ROT0 };
    // size of displayed (probably scaled) image
    wxSize m_imageSize;
    // size of real image
    wxSize m_realSize;
    /** helper function for scale, offset and rotation */
    /** scale of width/height */
    int scale(int x) const
    {
        return (int)(x * getScaleFactor() + 0.5);
    };
    double scale(double x) const
    {
        return x * getScaleFactor();
    };
    /** convert image coordinate to screen coordinates, considers additional added border */
    int transform(int x) const
    {
        return (int)((x + PerspectiveOffset) * getScaleFactor() + 0.5);
    };
    double transform(double x) const
    {
        return (x + PerspectiveOffset) * getScaleFactor();
    };
    wxPoint transform(const hugin_utils::FDiff2D& p) const
    {
        wxPoint r;
        r.x = transform(p.x);
        r.y = transform(p.y);
        return r;
    };
    /** translate screen coordinates to image coordinates, considers additional added border */
    int invtransform(int x) const
    {
        return (int)(x / getScaleFactor() - PerspectiveOffset + 0.5);
    };
    double invtransform(double x) const
    {
        return (x / getScaleFactor() - PerspectiveOffset);
    };
    hugin_utils::FDiff2D invtransform(const wxPoint& p) const
    {
        hugin_utils::FDiff2D r;
        r.x = invtransform(p.x);
        r.y = invtransform(p.y);
        return r;
    };
    // rotate coordinate to fit possibly rotated image display
    // useful for drawing something on the rotated display
    template <class T>
    T applyRot(const T& p) const
    {
        switch (m_imgRotation) {
        case ROT0:
            return p;
            break;
        case ROT90:
            return T(m_realSize.GetHeight() - 1 - p.y, p.x);
            break;
        case ROT180:
            return T(m_realSize.GetWidth() - 1 - p.x, m_realSize.GetHeight() - 1 - p.y);
            break;
        case ROT270:
            return T(p.y, m_realSize.GetWidth() - 1 - p.x);
            break;
        default:
            return p;
            break;
        }
    }
    // rotate coordinate to fit possibly rotated image display
    // useful for converting rotated display coordinates to image coordinates
    template <class T>
    T applyRotInv(const T& p) const
    {
        switch (m_imgRotation) {
        case ROT90:
            return T(p.y, m_realSize.GetHeight() - 1 - p.x);
            break;
        case ROT180:
            return T(m_realSize.GetWidth() - 1 - p.x, m_realSize.GetHeight() - 1 - p.y);
            break;
        case ROT270:
            return T(m_realSize.GetWidth() - 1 - p.y, p.x);
            break;
        case ROT0:
        default:
            return p;
            break;
        }
    }

    /**  different states of the editor */
    enum PerspectiveEditorState
    {
        NO_IMAGE = 0, // no image selected
        SHOW_IMAGE, // image loaded and rectangle
        POINT_MOVING, // dragging points of the rectangle
        SEGMENT_MOVING, // dragging line of the rectangle
        RECT_MOVING, // dragging the whole rectangle
        LINE_CREATE, // create a new line
        LINE_POINT_MOVING,  // dragging one point of the line
        LINE_MOVING  // dragging one line
    };
    PerspectiveEditorState m_editorState{ NO_IMAGE };

    double m_scaleFactor{ 1.0 };
    bool m_fitToWindow{ false };
    bool m_showRemappedImage{ false };
    bool m_showRect{ true };

    /** image cache entry for current image */
    ImageCache::EntryPtr m_img;
    /** HuginBase::Panorama object for calculation of remapped image */
    HuginBase::Panorama m_pano;

    // positions of mouse drag
    wxPoint m_dragStartPos;
    wxPoint m_currentPos;
    int m_movingPoint{ -1 };
    // variable for saving scrolling state
    bool m_middleMouseScroll{ false };
    wxPoint m_scrollPos;

    // colours for different parts
    wxColor m_colour_selected;
    // coordinates of the rectangle
    std::vector<hugin_utils::FDiff2D> m_rectPoints, m_rectPointsStartDrag;
    std::vector<Line> m_lines, m_currentLine;
    Line m_lineStartDrag;

    DECLARE_DYNAMIC_CLASS(PerspectiveImageCtrl)
};

#endif // PerspectiveImageCtrl_H
