// -*- c-basic-offset: 4 -*-
/** @file ToolboxFrame.h
 *
 *  @brief declaration of main frame class for toolbox GUI
 *
 *  @author T. Modes
 *
 */

/* 
 *  This program is free software; you can redistribute it and/or
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

#ifndef TOOLBOXFRAME_H
#define TOOLBOXFRAME_H

#include "panoinc_WX.h"
#include "appbase/ProgressDisplay.h"
#include "base_wx/MyExternalCmdExecDialog.h"
#include "base_wx/wxcms.h"

// forward declaration
class EnfusePanel;
class PerspectivePanel;

/** The main window frame.
 *
 */
class ToolboxFrame:public wxFrame, public AppBase::ProgressDisplay
{
public:

    /** constructor  */
    explicit ToolboxFrame(wxWindow* parent);
    /** destructor */
    virtual ~ToolboxFrame();

    /** get the path to the xrc directory */
    const wxString & GetXRCPath() const;
    bool HasMonitorProfile() const;
    cmsHPROFILE GetMonitorProfile() const;
protected:
    /** called when a progress message should be displayed */
    void updateProgressDisplay();
    // event handlers
    void OnExit(wxCommandEvent& e);
    void OnQueueProgress(wxCommandEvent& e);

private:
    wxNotebook* m_mainNotebook{ nullptr };
    MyExecPanel* m_logPanel{ nullptr };
    wxSplitterWindow* m_mainSplitter{ nullptr };
    EnfusePanel* m_enfusePanel{ nullptr };
    PerspectivePanel* m_perspectivePanel{ nullptr };
    /** monitor profile */
    cmsHPROFILE m_monitorProfile{ nullptr };
    /** true, if we found a real monitor profile */
    bool m_hasMonitorProfile{ false };
};


#endif // TOOLBOXFRAME_H
