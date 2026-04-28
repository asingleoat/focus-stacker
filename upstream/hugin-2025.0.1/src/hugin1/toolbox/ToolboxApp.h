// -*- c-basic-offset: 4 -*-
/** @file ToolboxAPp.h
 *
 *  @author T. Modes
 *
 *  @brief declaration of application class for toolbox app
 *
 */

/*
 *  This is free software; you can redistribute it and/or
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

#ifndef TOOLBOXAPP_H
#define TOOLBOXAPP_H

#include "ToolboxFrame.h"

/** The application class for toolbox app
 */
class ToolboxApp : public wxApp
{
public:
    virtual bool OnInit();
#if wxUSE_ON_FATAL_EXCEPTION
    virtual void OnFatalException() wxOVERRIDE;
#endif

    /** return currently active locale */
    wxLocale & GetLocale()
    {
        return locale;
    }
   /** return the current xrc path */
    const wxString & GetXRCPath()
    {
        return m_xrcPrefix;
    }
    /** returns pointer to main frame */
    ToolboxFrame* GetToolboxFrame()
    {
        return m_frame;
    };

private:
    /** locale for internationalisation */
    wxLocale locale;
    wxString m_xrcPrefix;
    ToolboxFrame* m_frame;
};

DECLARE_APP(ToolboxApp)

#endif // TOOLBOXAPP_H
