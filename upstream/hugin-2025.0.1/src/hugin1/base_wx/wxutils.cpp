/** @file wxutils.cpp
*
*  @brief implementation of some little utility functions
*
*  @author T. Modes
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

#include "wxutils.h"
#include <wx/translation.h>

namespace hugin_utils
{
WXIMPEX wxString GetFormattedTimeSpan(const wxTimeSpan& timeSpan)
{
    if (timeSpan.IsNull())
    {
        return wxEmptyString;
    };
    if (timeSpan.GetHours() >= 1)
    {
        // longer than 1 h, format hours:minutes
        return timeSpan.Format(_("%H:%M h"));
    }
    else
    {
        // shorter than 1 h
        if (timeSpan.GetSeconds() > 60)
        {
            // format minutes:seconds
            return timeSpan.Format(_("%M:%S min"));
        }
        else
        {
            if (timeSpan.GetSeconds() < 1)
            {
                // shorter then 1 s, don't display anything
                return wxEmptyString;
            }
            else
            {
                // below 1 min, show only seconds
                return timeSpan.Format(_("%S s"));
            }
        }
    }
}

// utility functions
#include <wx/config.h>

void RestoreFramePosition(wxTopLevelWindow* frame, const wxString& basename)
{
    DEBUG_TRACE(basename.mb_str(wxConvLocal));
    wxConfigBase* config = wxConfigBase::Get();

    // get display size
    int dx, dy;
    wxDisplaySize(&dx, &dy);

#if ( __WXGTK__ )
    // restoring the splitter positions properly when maximising doesn't work.
    // Disabling maximise on wxWidgets >= 2.6.0 and gtk
            //size
    const int w = config->Read("/" + basename + "/width", -1l);
    const int h = config->Read("/" + basename + "/height", -1l);
    if (w > 0 && w <= dx)
    {
        frame->SetClientSize(w, h);
    }
    else
    {
        frame->Fit();
    };
    //position
    const int x = config->Read("/" + basename + "/positionX", -1l);
    const int y = config->Read("/" + basename + "/positionY", -1l);
    if (y >= 0 && x >= 0 && x < dx && y < dy)
    {
        frame->Move(x, y);
    }
    else
    {
        frame->Move(0, 44);
    };
#else
    const bool maximized = config->Read("/" + basename + "/maximized", 0l) != 0;
    if (maximized)
    {
        frame->Maximize();
    }
    else
    {
        //size
        const int w = config->Read("/" + basename + "/width", -1l);
        const int h = config->Read("/" + basename + "/height", -1l);
        if (w > 0 && w <= dx)
        {
            frame->SetClientSize(w, h);
        }
        else
        {
            frame->Fit();
        };
        //position
        const int x = config->Read("/" + basename + "/positionX", -1l);
        const int y = config->Read("/" + basename + "/positionY", -1l);
        if (y >= 0 && x >= 0 && x < dx && y < dy)
        {
            frame->Move(x, y);
        }
        else
        {
            frame->Move(0, 44);
        };
    };
#endif
}

void StoreFramePosition(wxTopLevelWindow* frame, const wxString& basename)
{
    DEBUG_TRACE(basename);
    wxConfigBase* config = wxConfigBase::Get();

#if ( __WXGTK__ )
    // restoring the splitter positions properly when maximising doesn't work.
    // Disabling maximise on wxWidgets >= 2.6.0 and gtk
    wxSize sz = frame->GetClientSize();
    config->Write("/" + basename + "/width", sz.GetWidth());
    config->Write("/" + basename + "/height", sz.GetHeight());
    wxPoint ps = frame->GetPosition();
    config->Write("/" + basename + "/positionX", ps.x);
    config->Write("/" + basename + "/positionY", ps.y);
    config->Write("/" + basename + "/maximized", 0);
#else
    if ((!frame->IsMaximized()) && (!frame->IsIconized()))
    {
        const wxSize sz = frame->GetClientSize();
        config->Write("/" + basename + "/width", sz.GetWidth());
        config->Write("/" + basename + "/height", sz.GetHeight());
        wxPoint ps = frame->GetPosition();
        config->Write("/" + basename + "/positionX", ps.x);
        config->Write("/" + basename + "/positionY", ps.y);
        config->Write("/" + basename + "/maximized", 0);
    }
    else
    {
        if (frame->IsMaximized())
        {
            config->Write("/" + basename + "/maximized", 1l);
        };
    };
#endif
}

#ifdef __WXMSW__
#include <wx/msgdlg.h>
#include <wx/settings.h>
#endif

int HuginMessageBox(const wxString& message, const wxString& caption, int  style, wxWindow* parent)
{
#ifdef __WXMSW__
    if (wxSystemSettings::GetAppearance().IsDark())
    {
        // wxMessageBox does not support dark mode on window
        // so use wxGenericMessageDialog instead
        wxGenericMessageDialog dlg(parent, message, caption, style);
        // translate the return code
        switch (dlg.ShowModal())
        {
            case wxID_OK:
                return wxOK;
            case wxID_YES:
                return wxYES;
            case wxID_NO:
                return wxNO;
            case wxID_HELP:
                return wxHELP;
            case wxID_CANCEL:
            default:
                return wxCANCEL;
        };
    }
    else
    {
        // in light mode we are using default wxMessageBox for best
        // integration with os default style
        return wxMessageBox(message, caption, style, parent);
    };
#else
    // on Linux/Mac OS the message box has no caption (see guidelines of the os)
    return wxMessageBox(message, wxEmptyString, style, parent);
#endif
}

MessageDialog GetMessageDialog(const wxString& message, const wxString& caption, int style, wxWindow* parent)
{
#ifdef __WXMSW__
    if (wxSystemSettings::GetAppearance().IsDark())
    {
        // wxMessageDialog does not support dark mode
        // so use wxGenericMessageDialog for dark mode
        return std::make_unique<wxGenericMessageDialog>(parent, message, caption, style);
    }
    else
    {   
        // in light mode wxGenericMessageDialog looks slightly different than OS standard
        // so use in this case wxMessageDialog
        return std::make_unique<wxMessageDialog>(parent, message, caption, style);
    };
#else
    // on Linux/Mac OS the message box has no caption (see guidelines of the os)
    return std::make_unique<wxMessageDialog>(parent, message, wxEmptyString, style);
#endif
}

bool AskUserOverwrite(const wxString& filename, const wxString& caption, wxWindow* parent)
{
    if (HuginMessageBox(wxString::Format(_("File %s already exists.\nShould this file overwritten?"), filename),
        caption, wxYES_NO | wxICON_QUESTION, parent) == wxYES)
    {
        return true;
    }
    else
    {
        return false;
    };
}

DisableWindow::DisableWindow(wxWindow* window)
{
    m_window = window;
    m_window->Disable();
}

DisableWindow::~DisableWindow()
{
    m_window->Enable();
}

}
