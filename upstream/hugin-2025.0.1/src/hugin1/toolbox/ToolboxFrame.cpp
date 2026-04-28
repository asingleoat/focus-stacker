// -*- c-basic-offset: 4 -*-
/** @file ToolboxFrame.cpp
 *
 *  @brief implementation of main frame class for toolbox GUI
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

#include "base_wx/platform.h"
#include "base_wx/wxutils.h"
#include "ToolboxFrame.h"
#include "ToolboxApp.h"
#include "EnfusePanel.h"
#include "PerspectivePanel.h"
#include "huginapp/ImageCache.h"
#include "hugin/config_defaults.h"
#include "CreateBrightImgDlg.h"

ToolboxFrame::ToolboxFrame(wxWindow* parent)
{
    // load from XRC
    wxXmlResource::Get()->LoadFrame(this, parent, "toolbox_frame");
    SetMinSize(wxSize(500, 400));
    SetMenuBar(wxXmlResource::Get()->LoadMenuBar(this, "toolbox_menubar"));

    // set the minimize icon
#ifdef __WXMSW__
    wxIconBundle myIcons(GetXRCPath() + "data/hugin.ico", wxBITMAP_TYPE_ICO);
    SetIcons(myIcons);
#else
    wxIcon myIcon(GetXRCPath() + "data/hugin.png",wxBITMAP_TYPE_PNG);
    SetIcon(myIcon);
#endif
    SetTitle(_("Hugin toolbox GUI"));
    // create a status bar
    const int fields(2);
    CreateStatusBar(fields);
    int widths[fields] = { -1, 85 };
    SetStatusWidths(fields, &widths[0]);
    // load monitor profile
    wxString profileName;
    HuginBase::Color::GetMonitorProfile(profileName, m_monitorProfile);
    m_hasMonitorProfile = !profileName.IsEmpty();

    // initialize image cache
    ImageCache::getInstance().setProgressDisplay(this);
    wxConfigBase* config = wxConfigBase::Get();
#if defined __WXMSW__
    unsigned long long mem = HUGIN_IMGCACHE_UPPERBOUND;
    unsigned long mem_low = config->Read("/ImageCache/UpperBound", HUGIN_IMGCACHE_UPPERBOUND);
    unsigned long mem_high = config->Read("/ImageCache/UpperBoundHigh", (long)0);
    if (mem_high > 0)
    {
        mem = ((unsigned long long) mem_high << 32) + mem_low;
    }
    else
    {
        mem = mem_low;
    }
    ImageCache::getInstance().SetUpperLimit(mem);
#else
    ImageCache::getInstance().SetUpperLimit(config->Read("/ImageCache/UpperBound", HUGIN_IMGCACHE_UPPERBOUND));
#endif

    // create splitter window
    m_mainSplitter = XRCCTRL(*this, "toolbox_splitter", wxSplitterWindow);
    // create log window
    m_logPanel = new MyExecPanel(this);
    wxXmlResource::Get()->AttachUnknownControl("toolbox_logpanel", m_logPanel, this);
    // create main notebook
    m_mainNotebook = XRCCTRL(*this, "toolbox_notebook", wxNotebook);
    m_enfusePanel = new EnfusePanel();
    m_enfusePanel->Create(m_mainNotebook, m_logPanel);
    m_perspectivePanel = new PerspectivePanel();
    m_perspectivePanel->Create(m_mainNotebook, m_logPanel);
    m_mainNotebook->AddPage(m_enfusePanel, _("Enfuse"));
    m_mainNotebook->AddPage(m_perspectivePanel, _("Perspective"));
    m_mainNotebook->SetSelection(config->ReadLong("/ToolboxFrame/ActiveTab", 0l));
    // load frame size and position
    hugin_utils::RestoreFramePosition(this, "ToolboxFrame/MainWindow");
    Layout();
    if (config->HasEntry("/ToolboxFrame/Main_Splitter"))
    {
        m_mainSplitter->SetSashPosition(config->ReadLong("/ToolboxFrame/Main_Splitter", 500));
    };
    // bind event handler
    Bind(wxEVT_MENU, &ToolboxFrame::OnExit, this, XRCID("toolbox_close"));
    Bind(EVT_QUEUE_PROGRESS, &ToolboxFrame::OnQueueProgress, this);
}

ToolboxFrame::~ToolboxFrame()
{
    // store positions/size/settings
    hugin_utils::StoreFramePosition(this, "ToolboxFrame/MainWindow");
    wxConfigBase* config = wxConfigBase::Get();
    config->Write("/ToolboxFrame/Main_Splitter", m_mainSplitter->GetSashPosition());
    config->Write("/ToolboxFrame/ActiveTab", m_mainNotebook->GetSelection());
}

const wxString & ToolboxFrame::GetXRCPath() const
{
     return wxGetApp().GetXRCPath();
}

bool ToolboxFrame::HasMonitorProfile() const
{
    return m_hasMonitorProfile;
}

cmsHPROFILE ToolboxFrame::GetMonitorProfile() const
{
    return m_monitorProfile;
}

void ToolboxFrame::OnExit(wxCommandEvent &e)
{
    Close();
}

void ToolboxFrame::updateProgressDisplay()
{
    // update progress messages in status bar
    wxString msg;
    if (!m_message.empty())
    {
        msg = wxGetTranslation(wxString(m_message.c_str(), wxConvLocal));
        if (!m_filename.empty())
        {
            msg.Append(" ");
            msg.Append(wxString(ProgressDisplay::m_filename.c_str(), HUGIN_CONV_FILENAME));
        };
    };
    GetStatusBar()->SetStatusText(msg, 0);
}

void ToolboxFrame::OnQueueProgress(wxCommandEvent& e)
{
    if (e.GetInt() == -1)
    {
        // notify children about finished process to update their controls
        if (m_mainNotebook->GetSelection() == 0)
        {
            m_enfusePanel->OnProcessFinished(e);
        }
        else
        {
            if (m_mainNotebook->GetSelection() == 1)
            {
                m_perspectivePanel->OnProcessFinished(e);
            };
        };
    };
}
