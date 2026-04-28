// -*- c-basic-offset: 4 -*-

/** @file BatchFrame.cpp
 *
 *  @brief Batch processor for Hugin with GUI
 *
 *  @author Marko Kuder <marko.kuder@gmail.com>
 *
 *  $Id: BatchFrame.cpp 3322 2008-08-18 1:10:07Z mkuder $
 *
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

#include "BatchFrame.h"
#include <wx/stdpaths.h>
#include "PTBatcherGUI.h"
#include "FindPanoDialog.h"
#include "FailedProjectsDialog.h"
#include "ChangeUserDefinedDialog.h"
#include "GenerateSequenceDialog.h"
#ifdef __WXMSW__
#include <powrprof.h>
#ifdef _MSC_VER
#pragma comment(lib, "PowrProf.lib")
#endif
#include <wx/taskbarbutton.h>
#endif
#include "base_wx/wxutils.h"

/* file drag and drop handler method */
bool BatchDropTarget::OnDropFiles(wxCoord x, wxCoord y, const wxArrayString& filenames)
{
    BatchFrame* MyBatchFrame = wxGetApp().GetFrame();
    if (!MyBatchFrame)
    {
        return false;
    }
    if(filenames.GetCount()==0)
    {
        return false;
    }
    for(unsigned int i=0; i< filenames.GetCount(); i++)
    {
        wxFileName file(filenames[i]);
        if(file.HasExt())
        {
            if (file.GetExt().CmpNoCase("pto") == 0 ||
                    file.GetExt().CmpNoCase("ptp") == 0 ||
                    file.GetExt().CmpNoCase("pts") == 0 )
            {
                if(file.FileExists())
                {
                    MyBatchFrame->AddToList(filenames[i]);
                }
            };
        }
        else
        {
            if(file.DirExists())
            {
                MyBatchFrame->AddDirToList(filenames[i]);
            }
        };
    };
    return true;
};

enum
{
    EVT_TIMER_UPDATE_LISTBOX
};

BatchFrame::BatchFrame(wxLocale* locale, wxString xrc)
{
    this->SetLocaleAndXRC(locale,xrc);
    m_cancelled = false;

    //load xrc resources
    wxXmlResource::Get()->LoadFrame(this, (wxWindow* )NULL, "batch_frame");
    // load our menu bar
#ifdef __WXMAC__
    wxApp::s_macExitMenuItemId = XRCID("menu_exit");
    wxApp::s_macHelpMenuTitleName = _("&Help");
#endif
    SetMenuBar(wxXmlResource::Get()->LoadMenuBar(this, "batch_menu"));

    // create tool bar
    SetToolBar(wxXmlResource::Get()->LoadToolBar(this, "batch_toolbar"));

    int widths[2] = { -1, 150 };
    CreateStatusBar(2);
    SetStatusWidths(2, widths);
    SetStatusText(_("Not doing much..."));

    // set the minimize icon
#ifdef __WXMSW__
    m_iconNormal = wxIcon(m_xrcPrefix + "data/ptbatcher.ico", wxBITMAP_TYPE_ICO);
    m_iconRunning = wxIcon(m_xrcPrefix + "data/ptbatcher_running.ico", wxBITMAP_TYPE_ICO);
    m_iconPaused = wxIcon(m_xrcPrefix + "data/ptbatcher_pause.ico", wxBITMAP_TYPE_ICO);
    wxIconBundle myIcons(m_xrcPrefix + "data/ptbatcher.ico", wxBITMAP_TYPE_ICO);
    SetIcons(myIcons);
#else
    m_iconNormal = wxIcon(m_xrcPrefix + "data/ptbatcher.png", wxBITMAP_TYPE_PNG);
    m_iconRunning = wxIcon(m_xrcPrefix + "data/ptbatcher_running.png", wxBITMAP_TYPE_PNG);
    m_iconPaused = wxIcon(m_xrcPrefix + "data/ptbatcher_pause.png", wxBITMAP_TYPE_PNG);
    SetIcon(m_iconNormal);
#endif

    m_batch = new Batch(this);
    if(wxGetKeyState(WXK_COMMAND))
    {
#ifdef __WXMAC__
        wxString text(_("You have pressed the Command key."));
#else
        wxString text(_("You have pressed the Control key."));
#endif
        text.Append("\n");
        text.Append(_("Should the loading of the batch queue be skipped?"));
        if (hugin_utils::HuginMessageBox(text, _("PTBatcherGUI"), wxYES_NO | wxICON_EXCLAMATION, this) == wxNO)
        {
            m_batch->LoadTemp();
        }
        else
        {
            // save empty batch queue
            m_batch->SaveTemp();
        };
    }
    else
    {
        m_batch->LoadTemp();
    };
    projListBox = XRCCTRL(*this,"project_listbox",ProjectListBox);
    projListBox->Bind(wxEVT_LIST_ITEM_ACTIVATED, &BatchFrame::OnButtonOpenWithHugin, this);
    // fill at end list box, check which options are available
    m_endChoice = XRCCTRL(*this, "choice_end", wxChoice);
    m_endChoice->Clear();
    m_endChoice->Append(_("Do nothing"), (void*)Batch::DO_NOTHING);
    m_endChoice->Append(_("Close PTBatcherGUI"), (void*)Batch::CLOSE_PTBATCHERGUI);
#if !defined __WXMAC__ && !defined __WXOSX_COCOA__
    // there is no wxShutdown for wxMac
    m_endChoice->Append(_("Shutdown computer"), (void*)Batch::SHUTDOWN);
#endif
    m_endChoice->Bind(wxEVT_CHOICE, &BatchFrame::OnChoiceEnd, this);
#ifdef __WXMSW__
    SYSTEM_POWER_CAPABILITIES pwrCap;
    if (GetPwrCapabilities(&pwrCap))
    {
        if (pwrCap.SystemS3)
        {
            m_endChoice->Append(_("Suspend computer"), (void*)Batch::SUSPEND);
        };
        if (pwrCap.SystemS4 && pwrCap.HiberFilePresent)
        {
            m_endChoice->Append(_("Hibernate computer"), (void*)Batch::HIBERNATE);
        };
    };
#endif

    //TO-DO: include a batch or project progress gauge?
    projListBox->Fill(m_batch);
    SetDropTarget(new BatchDropTarget());

    m_tray = NULL;
    if (wxTaskBarIcon::IsAvailable())
    {
        // minimize to tray is by default disabled
        // activate only if task bar icon is available
        GetMenuBar()->Enable(XRCID("menu_tray"), true);
        bool minTray;
        // tray icon is disabled by default 
        wxConfigBase::Get()->Read("/BatchFrame/minimizeTray", &minTray, false);
        GetMenuBar()->Check(XRCID("menu_tray"), minTray);
        UpdateTrayIcon(minTray);
    }

    UpdateTaskBarProgressBar();

#ifndef __WXMSW__
    // check settings of help window and fix when needed
    FixHelpSettings();
#endif
    m_updateProjectsTimer = new wxTimer(this, EVT_TIMER_UPDATE_LISTBOX);
    // start timer for check for updates in project files
    m_updateProjectsTimer->StartOnce(5000);
    // connect all events
    // tool buttons
    Bind(wxEVT_TOOL, &BatchFrame::OnButtonClear, this, XRCID("tool_clear"));
    Bind(wxEVT_TOOL, &BatchFrame::OnButtonOpenBatch, this, XRCID("tool_open"));
    Bind(wxEVT_TOOL, &BatchFrame::OnButtonSaveBatch, this, XRCID("tool_save"));
    Bind(wxEVT_TOOL, &BatchFrame::OnButtonRunBatch, this, XRCID("tool_start"));
    Bind(wxEVT_TOOL, &BatchFrame::OnButtonSkip, this, XRCID("tool_skip"));
    Bind(wxEVT_TOOL, &BatchFrame::OnButtonPause, this, XRCID("tool_pause"));
    Bind(wxEVT_TOOL, &BatchFrame::OnButtonCancel, this, XRCID("tool_cancel"));
    Bind(wxEVT_TOOL, &BatchFrame::OnButtonAddToStitchingQueue, this, XRCID("tool_add"));
    Bind(wxEVT_TOOL, &BatchFrame::OnButtonRemoveFromList, this, XRCID("tool_remove"));
    Bind(wxEVT_TOOL, &BatchFrame::OnButtonAddDir, this, XRCID("tool_adddir"));
    // menu items
    Bind(wxEVT_MENU, &BatchFrame::OnButtonAddToStitchingQueue, this, XRCID("menu_add"));
    Bind(wxEVT_MENU, &BatchFrame::OnButtonAddToAssistantQueue, this, XRCID("menu_add_assistant"));
    Bind(wxEVT_MENU, &BatchFrame::OnButtonRemoveFromList, this, XRCID("menu_remove"));
    Bind(wxEVT_MENU, &BatchFrame::OnButtonAddDir, this, XRCID("menu_adddir"));
    Bind(wxEVT_MENU, &BatchFrame::OnButtonSearchPano, this, XRCID("menu_searchpano"));
    Bind(wxEVT_MENU, &BatchFrame::OnButtonGenerateSequence, this, XRCID("menu_generate_sequence"));
    Bind(wxEVT_MENU, &BatchFrame::OnButtonOpenBatch, this, XRCID("menu_open"));
    Bind(wxEVT_MENU, &BatchFrame::OnButtonSaveBatch, this, XRCID("menu_save"));
    Bind(wxEVT_MENU, &BatchFrame::OnButtonClear, this, XRCID("menu_clear"));
    Bind(wxEVT_MENU, &BatchFrame::OnMinimizeTrayMenu, this, XRCID("menu_tray"));
    Bind(wxEVT_MENU, &BatchFrame::OnUserExit, this, XRCID("menu_exit"));
    Bind(wxEVT_MENU, &BatchFrame::OnButtonHelp, this, XRCID("menu_help"));
    // buttons
    Bind(wxEVT_BUTTON, &BatchFrame::OnButtonAddCommand, this, XRCID("button_addcommand"));
    Bind(wxEVT_BUTTON, &BatchFrame::OnButtonRemoveComplete, this, XRCID("button_remove"));
    Bind(wxEVT_BUTTON, &BatchFrame::OnButtonChangePrefix, this, XRCID("button_prefix"));
    Bind(wxEVT_BUTTON, &BatchFrame::OnButtonChangeUserDefinedSequence, this, XRCID("button_user_defined"));
    Bind(wxEVT_BUTTON, &BatchFrame::OnButtonReset, this, XRCID("button_reset"));
    Bind(wxEVT_BUTTON, &BatchFrame::OnButtonResetAll, this, XRCID("button_resetall"));
    Bind(wxEVT_BUTTON, &BatchFrame::OnButtonOpenWithHugin, this, XRCID("button_edit"));
    Bind(wxEVT_BUTTON, &BatchFrame::OnButtonMoveUp, this, XRCID("button_move_up"));
    Bind(wxEVT_BUTTON, &BatchFrame::OnButtonMoveDown, this, XRCID("button_move_down"));
    // checkboxes
    Bind(wxEVT_CHECKBOX, &BatchFrame::OnCheckOverwrite, this, XRCID("cb_overwrite"));
    Bind(wxEVT_CHECKBOX, &BatchFrame::OnCheckVerbose, this, XRCID("cb_verbose"));
    Bind(wxEVT_CHECKBOX, &BatchFrame::OnCheckAutoRemove, this, XRCID("cb_autoremove"));
    Bind(wxEVT_CHECKBOX, &BatchFrame::OnCheckAutoStitch, this, XRCID("cb_autostitch"));
    Bind(wxEVT_CHECKBOX, &BatchFrame::OnCheckSaveLog, this, XRCID("cb_savelog"));
    // some general flow events
    Bind(wxEVT_END_PROCESS, &BatchFrame::OnProcessTerminate, this);
    Bind(wxEVT_CLOSE_WINDOW, &BatchFrame::OnClose, this);
    Bind(wxEVT_TIMER, &BatchFrame::OnUpdateListBox, this, EVT_TIMER_UPDATE_LISTBOX);
    Bind(EVT_BATCH_FAILED, &BatchFrame::OnBatchFailed, this);
    Bind(EVT_INFORMATION, &BatchFrame::OnBatchInformation, this);
    Bind(EVT_UPDATE_PARENT, &BatchFrame::OnRefillListBox, this);
    Bind(EVT_QUEUE_PROGRESS, &BatchFrame::OnProgress, this);
    Bind(wxEVT_ICONIZE, &BatchFrame::OnMinimize, this);
}

wxStatusBar* BatchFrame::OnCreateStatusBar(int number, long style, wxWindowID id, const wxString& name)
{
    m_progStatusBar = new ProgressStatusBar(this, id, style, name);
    m_progStatusBar->SetFieldsCount(number);
    return m_progStatusBar;
}

bool BatchFrame::IsRunning()
{
    return m_batch->IsRunning();
};

bool BatchFrame::IsPaused()
{
    return m_batch->IsPaused();
};

void BatchFrame::OnUpdateListBox(wxTimerEvent& event)
{
    wxFileName tempFile;
    bool change = false;
    for(int i = 0; i< m_batch->GetProjectCount(); i++)
    {
        if(m_batch->GetProject(i)->id >= 0 && m_batch->GetStatus(i)!=Project::FINISHED)
        {
            tempFile.Assign(m_batch->GetProject(i)->path);
            if(tempFile.FileExists())
            {
                wxDateTime modify;
                modify=tempFile.GetModificationTime();
                if(m_batch->GetProject(i)->skip)
                {
                    change = true;
                    m_batch->GetProject(i)->skip = false;
                    m_batch->SetStatus(i,Project::WAITING);
                    projListBox->ReloadProject(projListBox->GetIndex(m_batch->GetProject(i)->id),m_batch->GetProject(i));
                }
                else if(!modify.IsEqualTo(m_batch->GetProject(i)->modDate))
                {
                    change = true;
                    m_batch->GetProject(i)->modDate = modify;
                    m_batch->GetProject(i)->ResetOptions();
                    if(m_batch->GetProject(i)->target==Project::STITCHING)
                    {
                        m_batch->SetStatus(i,Project::WAITING);
                    };
                    projListBox->ReloadProject(projListBox->GetIndex(m_batch->GetProject(i)->id),m_batch->GetProject(i));
                }
                if (!m_batch->GetProject(i)->userDefindSequence.empty())
                {
                    // check for existence of user defined sequence
                    if (!wxFileName::FileExists(m_batch->GetProject(i)->userDefindSequence))
                    {
                        change = true;
                        m_batch->GetProject(i)->skip = true;
                        m_batch->SetStatus(i, Project::MISSING);
                        projListBox->SetMissing(projListBox->GetIndex(m_batch->GetProject(i)->id));
                    };
                };
            }
            else
            {
                if(m_batch->GetStatus(i) != Project::MISSING)
                {
                    change = true;
                    m_batch->GetProject(i)->skip = true;
                    m_batch->SetStatus(i,Project::MISSING);
                    projListBox->SetMissing(projListBox->GetIndex(m_batch->GetProject(i)->id));
                }
            }
        }
        if(projListBox->UpdateStatus(i,m_batch->GetProject(i)))
        {
            change = true;
        }
    }
    if(change)
    {
        m_batch->SaveTemp();
    };
    // start timer again
    m_updateProjectsTimer->StartOnce(2000);
};

void BatchFrame::OnUserExit(wxCommandEvent& event)
{
    Close(true);
};

void BatchFrame::OnButtonAddCommand(wxCommandEvent& event)
{
    wxTextEntryDialog dlg(this,_("Please enter the command-line application to execute:"),_("Enter application"));
    wxTheApp->SetEvtHandlerEnabled(false);
    if(dlg.ShowModal() == wxID_OK)
    {
        wxString line = dlg.GetValue();
        m_batch->AddAppToBatch(line);
        //SetStatusText(_T("Added application"));
        projListBox->AppendProject(m_batch->GetProject(m_batch->GetProjectCount()-1));
        m_batch->SaveTemp();
    }
    wxTheApp->SetEvtHandlerEnabled(true);
}

void BatchFrame::OnButtonAddDir(wxCommandEvent& event)
{
    wxString defaultdir = wxConfigBase::Get()->Read("/BatchFrame/actualPath",wxEmptyString);
    wxDirDialog dlg(this,
                    _("Specify a directory to search for projects in"),
                    defaultdir, wxDD_DEFAULT_STYLE | wxDD_DIR_MUST_EXIST);
    dlg.SetPath(wxConfigBase::Get()->Read("/BatchFrame/actualPath",wxEmptyString));
    if (dlg.ShowModal() == wxID_OK)
    {
        wxConfig::Get()->Write("/BatchFrame/actualPath", dlg.GetPath());  // remember for later
        AddDirToList(dlg.GetPath());
    };
}

void BatchFrame::OnButtonSearchPano(wxCommandEvent& e)
{
    FindPanoDialog findpano_dlg(this,m_xrcPrefix);
    findpano_dlg.ShowModal();
};

void BatchFrame::OnButtonGenerateSequence(wxCommandEvent& e)
{
    wxString defaultdir = wxConfigBase::Get()->Read("/BatchFrame/actualPath", wxEmptyString);
    wxFileDialog dlg(0,
        _("Specify project source file(s)"),
        defaultdir, wxEmptyString,
        _("Project files (*.pto)|*.pto|All files (*)|*"),
        wxFD_OPEN , wxDefaultPosition);
    dlg.SetDirectory(defaultdir);

    if (dlg.ShowModal() == wxID_OK)
    {
        wxConfig::Get()->Write("/BatchFrame/actualPath", wxPathOnly(dlg.GetPath()));
        GenerateSequenceDialog sequenceDialog(this, m_xrcPrefix, dlg.GetPath());
        if (sequenceDialog.IsValidPanorama())
        {
            if (sequenceDialog.ShowModal())
            {
            };
        }
        else
        {
            hugin_utils::HuginMessageBox(wxString::Format(_("Could not read file %s as valid Hugin pto file."), dlg.GetPath()), _("PTBatcherGUI"),
                wxOK | wxICON_EXCLAMATION, this);
        };
    };
};

void BatchFrame::OnButtonAddToStitchingQueue(wxCommandEvent& event)
{
    wxString defaultdir = wxConfigBase::Get()->Read("/BatchFrame/actualPath",wxEmptyString);
    wxFileDialog dlg(0,
                     _("Specify project source file(s)"),
                     defaultdir, wxEmptyString,
                     _("Project files (*.pto)|*.pto|All files (*)|*"),
                     wxFD_OPEN | wxFD_MULTIPLE, wxDefaultPosition);
    dlg.SetDirectory(defaultdir);

    if (dlg.ShowModal() == wxID_OK)
    {
        wxArrayString paths;
        dlg.GetPaths(paths);
#ifdef __WXGTK__
        //workaround a bug in GTK, see https://bugzilla.redhat.com/show_bug.cgi?id=849692 and http://trac.wxwidgets.org/ticket/14525
        wxConfig::Get()->Write("/BatchFrame/actualPath", wxPathOnly(paths[0]));  // remember for later
#else
        wxConfig::Get()->Write("/BatchFrame/actualPath", dlg.GetDirectory());  // remember for later
#endif
        for(unsigned int i=0; i<paths.GetCount(); i++)
        {
            AddToList(paths.Item(i));
        }
        m_batch->SaveTemp();
    };
}

void BatchFrame::OnButtonAddToAssistantQueue(wxCommandEvent& event)
{
    wxString defaultdir = wxConfigBase::Get()->Read("/BatchFrame/actualPath",wxEmptyString);
    wxFileDialog dlg(0,
                     _("Specify project source file(s)"),
                     defaultdir, wxEmptyString,
                     _("Project files (*.pto)|*.pto|All files (*)|*"),
                     wxFD_OPEN | wxFD_MULTIPLE, wxDefaultPosition);
    dlg.SetDirectory(defaultdir);

    if (dlg.ShowModal() == wxID_OK)
    {
        wxArrayString paths;
        dlg.GetPaths(paths);
#ifdef __WXGTK__
        //workaround a bug in GTK, see https://bugzilla.redhat.com/show_bug.cgi?id=849692 and http://trac.wxwidgets.org/ticket/14525
        wxConfig::Get()->Write("/BatchFrame/actualPath", wxPathOnly(paths[0]));  // remember for later
#else
        wxConfig::Get()->Write("/BatchFrame/actualPath", dlg.GetDirectory());  // remember for later
#endif

        for(unsigned int i=0; i<paths.GetCount(); i++)
        {
            AddToList(paths.Item(i),Project::DETECTING);
        }
        m_batch->SaveTemp();
    };
}

void BatchFrame::AddDirToList(wxString aDir)
{
    //we traverse all subdirectories of chosen path
    DirTraverser traverser;
    wxDir dir(aDir);
    dir.Traverse(traverser);
    wxArrayString projects = traverser.GetProjectFiles();
    for(unsigned int i=0; i<projects.GetCount(); i++)
    {
        m_batch->AddProjectToBatch(projects.Item(i));
        Project* proj=m_batch->GetProject(m_batch->GetProjectCount()-1);
        if(!proj->isAligned)
        {
            proj->target=Project::DETECTING;
        };
        projListBox->AppendProject(proj);
    };
    m_batch->SaveTemp();
    SetStatusText(wxString::Format(_("Added projects from dir %s"), aDir.c_str()));
};

void BatchFrame::AddToList(wxString aFile, Project::Target target, wxString userDefined)
{
    m_batch->AddProjectToBatch(aFile, wxEmptyString, userDefined, target);
    wxString s;
    switch(target)
    {
        case Project::STITCHING:
            s=wxString::Format(_("Add project %s to stitching queue."),aFile.c_str());
            break;
        case Project::DETECTING:
            s=wxString::Format(_("Add project %s to assistant queue."),aFile.c_str());
            break;
    };
    SetStatusText(s);
    projListBox->AppendProject(m_batch->GetProject(m_batch->GetProjectCount()-1));
    m_batch->SaveTemp();
}

void BatchFrame::AddArrayToList(const wxArrayString& fileList, Project::Target target)
{
    for (size_t i = 0; i < fileList.GetCount(); ++i)
    {
        m_batch->AddProjectToBatch(fileList[i], wxEmptyString, wxEmptyString, target);
        projListBox->AppendProject(m_batch->GetProject(m_batch->GetProjectCount() - 1));
    };
    m_batch->SaveTemp();
}

void BatchFrame::OnButtonCancel(wxCommandEvent& event)
{
    GetToolBar()->ToggleTool(XRCID("tool_pause"),false);
    m_cancelled = true;
    m_batch->CancelBatch();
    SetStatusText(_("Batch stopped"));
    if (m_tray)
    {
        m_tray->SetIcon(m_iconNormal, _("Hugin's Batch processor"));
    };
}

void BatchFrame::OnButtonChangePrefix(wxCommandEvent& event)
{
    const HuginBase::UIntSet selected(projListBox->GetSelectedProjects());
    if(selected.size()== 1)
    {
        Project* project = m_batch->GetProject(*selected.begin());
        if (project->id < 0)
        {
            SetStatusText(_("The prefix of command cannot be changed."));
            wxBell();
            return;
        }
        if (project->target == Project::STITCHING)
        {
            wxFileName prefix(project->prefix);
            wxFileDialog dlg(0, wxString::Format(_("Specify output prefix for project %s"), project->path),
                             prefix.GetPath(),
                             prefix.GetFullName(), wxEmptyString,
                             wxFD_SAVE, wxDefaultPosition);
            if (dlg.ShowModal() == wxID_OK)
            {
                while(containsInvalidCharacters(dlg.GetPath()))
                {
                    wxArrayString list;
                    list.Add(dlg.GetPath());
                    ShowFilenameWarning(this, list);
                    if(dlg.ShowModal()!=wxID_OK)
                    {
                        return;
                    }
                };
                wxFileName prefix(dlg.GetPath());
                while (!prefix.IsDirWritable())
                {
                    hugin_utils::HuginMessageBox(wxString::Format(_("You have no permissions to write in folder \"%s\".\nPlease select another folder for the final output."), prefix.GetPath()),
                        _("PTBatcherGUI"), wxOK | wxICON_INFORMATION, this);
                    if (dlg.ShowModal() != wxID_OK)
                    {
                        return;
                    };
                    prefix = dlg.GetPath();
                };

                wxString outname(dlg.GetPath());
                ChangePrefix(*selected.begin(), outname);
                //SetStatusText(_T("Changed prefix for "+projListBox->GetSelectedProject()));
                m_batch->SaveTemp();
            }
        }
        else
        {
            SetStatusText(_("The prefix of an assistant target cannot be changed."));
            wxBell();
        };
    }
    else
    {
        if (selected.empty())
        {
            SetStatusText(_("Please select a project"));
        }
        else
        {
            wxBell();
            SetStatusText(_("Please select only one project"));
        };
    };
}

void BatchFrame::ChangePrefix(int index,wxString newPrefix)
{
    int i;
    if(index!=-1)
    {
        i=index;
    }
    else
    {
        i=m_batch->GetProjectCount()-1;
    }
    m_batch->ChangePrefix(i,newPrefix);
    projListBox->ChangePrefix(i,newPrefix);
}

void BatchFrame::ChangeUserDefined(int index, wxString newUserDefined)
{
    int i;
    if (index != -1)
    {
        i = index;
    }
    else
    {
        i = m_batch->GetProjectCount() - 1;
    }
    m_batch->ChangeUserDefined(i, newUserDefined);
    projListBox->ChangeUserDefined(i, newUserDefined);
}

void BatchFrame::OnButtonChangeUserDefinedSequence(wxCommandEvent& event)
{
    HuginBase::UIntSet selectedProjects = projListBox->GetSelectedProjects();
    if (selectedProjects.empty())
    {
        SetStatusText(_("Please select a project"));
    }
    else
    {
        Project* project = m_batch->GetProject(*selectedProjects.begin());
        const Project::Target target = project->target;
        for (auto& i : selectedProjects)
        {
            const Project* projectI = m_batch->GetProject(i);
            if (projectI->id < 0)
            {
                wxBell();
                SetStatusText(_("Changing user defined sequence is not possible for application entries."));
                return;
            };
            if (target != projectI->target)
            {
                wxBell();
                SetStatusText(_("You can change the user defined sequence only for the same type of operation (either stitching or assistant)."));
                return;
            }
        };
        ChangeUserDefinedSequenceDialog dialog(this, m_xrcPrefix, project->userDefindSequence, target == Project::DETECTING);
        if (dialog.ShowModal() == wxID_OK)
        {
            const wxString newUserDefined = dialog.GetNewSequence();
            for (auto& i : selectedProjects)
            {
                m_batch->ChangeUserDefined(i, newUserDefined);
                projListBox->ChangeUserDefined(i, newUserDefined);
            };
        };
    };
}

void BatchFrame::OnButtonClear(wxCommandEvent& event)
{
    int returnCode = m_batch->ClearBatch();
    if(returnCode == 0)
    {
        projListBox->DeleteAllItems();
    }
    else if(returnCode == 2)
    {
        m_cancelled = true;
        projListBox->DeleteAllItems();
        if(GetToolBar()->GetToolState(XRCID("tool_pause")))
        {
            GetToolBar()->ToggleTool(XRCID("tool_pause"),false);
        }
    }
    m_batch->SaveTemp();
}

void BatchFrame::OnButtonHelp(wxCommandEvent& event)
{
    DEBUG_TRACE("");
    GetHelpController().DisplaySection("Hugin_Batch_Processor.html");
}

void BatchFrame::OnButtonMoveDown(wxCommandEvent& event)
{
    const HuginBase::UIntSet selected(projListBox->GetSelectedProjects());
    if (selected.size() == 1)
    {
        SwapProject(*selected.begin(), true);
        m_batch->SaveTemp();
    }
    else
    {
        wxBell();
    };
}

void BatchFrame::OnButtonMoveUp(wxCommandEvent& event)
{
    const HuginBase::UIntSet selected(projListBox->GetSelectedProjects());
    if (selected.size() == 1)
    {
        SwapProject(*selected.begin() - 1, false);
        m_batch->SaveTemp();
    }
    else
    {
        wxBell();
    };
}

void BatchFrame::OnButtonOpenBatch(wxCommandEvent& event)
{
    wxString defaultdir = wxConfigBase::Get()->Read("/BatchFrame/batchPath",wxEmptyString);
    wxFileDialog dlg(0,
                     _("Specify batch file to open"),
                     defaultdir, wxEmptyString,
                     _("Batch file (*.ptq)|*.ptq;|All files (*)|*"),
                     wxFD_OPEN, wxDefaultPosition);
    if (dlg.ShowModal() == wxID_OK)
    {
        wxConfig::Get()->Write("/BatchFrame/batchPath", dlg.GetDirectory());  // remember for later
        int clearCode = m_batch->LoadBatchFile(dlg.GetPath());
        //1 is error code for not clearing batch
        if(clearCode!=1)
        {
            /*if(clearCode==2) //we just cancelled the batch, so we need to try loading again
            	m_batch->LoadBatchFile(dlg.GetPath());*/
            projListBox->DeleteAllItems();
            projListBox->Fill(m_batch);
            m_batch->SaveTemp();
        }
    }
}

void BatchFrame::OnButtonOpenWithHugin(wxCommandEvent& event)
{
    const wxFileName exePath(wxStandardPaths::Get().GetExecutablePath());
    const HuginBase::UIntSet selected(projListBox->GetSelectedProjects());
    if (selected.size() == 1)
    {
        if (projListBox->GetText(*selected.begin(), 0).Cmp(_T("")) != 0)
#ifdef __WXMAC__
            wxExecute(_T("open -b net.sourceforge.Hugin \"" + m_batch->GetProject(*selected.begin())->path + _T("\"")));
#else
            wxExecute(exePath.GetPath(wxPATH_GET_VOLUME | wxPATH_GET_SEPARATOR) + _T("hugin \"" + m_batch->GetProject(*selected.begin())->path + _T("\" -notips")));
#endif
        else
        {
            SetStatusText(_("Cannot open app in Hugin."));
        };
    }
    else
    {
        if (selected.empty())
        {
            //ask user if he/she wants to load an empty project
            if (hugin_utils::HuginMessageBox(_("No project selected. Open Hugin without project?"), _("PTBatcherGUI"), wxYES_NO|wxICON_INFORMATION, this) == wxYES)
            {
#ifdef __WXMAC__
                wxExecute(_T("open -b net.sourceforge.Hugin"));
#else
                wxExecute(exePath.GetPath(wxPATH_GET_VOLUME | wxPATH_GET_SEPARATOR) + _T("hugin"));
#endif
            }
        }
        else
        {
            wxBell();
            SetStatusText(_("Please select only one project"));
        };
    };
}

void BatchFrame::OnButtonPause(wxCommandEvent& event)
{
    if(m_batch->GetRunningCount()>0)
    {
        if(!m_batch->IsPaused())
        {
            m_batch->PauseBatch();
            GetToolBar()->ToggleTool(XRCID("tool_pause"),true);
            SetStatusText(_("Batch paused"));
            if (m_tray)
            {
                m_tray->SetIcon(m_iconPaused, _("Pausing processing Hugin's batch queue"));
            };
        }
        else
        {
            m_batch->PauseBatch();
            GetToolBar()->ToggleTool(XRCID("tool_pause"),false);
            SetStatusText(_("Continuing batch..."));
            if (m_tray)
            {
                m_tray->SetIcon(m_iconRunning, _("Processing Hugin's batch queue"));
            };
        }
    }
    else //if no projects are running, we deactivate the button
    {
        GetToolBar()->ToggleTool(XRCID("tool_pause"),false);
    }
    UpdateTaskBarProgressBar();
}

void BatchFrame::OnButtonRemoveComplete(wxCommandEvent& event)
{
    bool removeErrors=false;
    if(!m_batch->NoErrors())
    {
        if (hugin_utils::HuginMessageBox(_("There are failed projects in the list.\nRemove them too?"), _("PTBatcherGUI"), wxYES_NO | wxICON_INFORMATION, this) == wxYES)
        {
            removeErrors=true;
        }
    }
    for(int i=projListBox->GetItemCount()-1; i>=0; i--)
    {
        if(m_batch->GetStatus(i)==Project::FINISHED ||
                (removeErrors && m_batch->GetStatus(i)==Project::FAILED))
        {
            projListBox->Deselect(i);
            projListBox->DeleteItem(i);
            m_batch->RemoveProjectAtIndex(i);
        }
    }
    m_batch->SaveTemp();
}

void BatchFrame::OnButtonRemoveFromList(wxCommandEvent& event)
{
    
    const HuginBase::UIntSet selected = projListBox->GetSelectedProjects();
    if(!selected.empty())
    {
        for (auto i = selected.rbegin(); i != selected.rend(); ++i)
        {
            const int selIndex = *i;
            if (m_batch->GetStatus(selIndex) == Project::RUNNING || m_batch->GetStatus(selIndex) == Project::PAUSED)
            {
                if (hugin_utils::HuginMessageBox(_("Cannot remove project in progress.\nDo you want to cancel it?"), _("PTBatcherGUI"), wxYES_NO | wxICON_INFORMATION, this) == wxYES)
                {
                    OnButtonSkip(event);
                };
            }
            else
            {
                SetStatusText(wxString::Format(_("Removed project %s"), m_batch->GetProject(selIndex)->path.c_str()));
                projListBox->Deselect(selIndex);
                projListBox->DeleteItem(selIndex);
                m_batch->RemoveProjectAtIndex(selIndex);
                m_batch->SaveTemp();
            };
        };
    }
    else
    {
        SetStatusText(_("Please select a project to remove"));
    }
}


void BatchFrame::OnButtonReset(wxCommandEvent& event)
{
    const HuginBase::UIntSet selected(projListBox->GetSelectedProjects());
    if(!selected.empty())
    {
        for (auto selIndex : selected)
        {
            if (m_batch->GetStatus(selIndex) == Project::RUNNING || m_batch->GetStatus(selIndex) == Project::PAUSED)
            {
                if (hugin_utils::HuginMessageBox(_("Cannot reset project in progress.\nDo you want to cancel it?"), _("PTBatcherGUI"), wxYES_NO | wxICON_INFORMATION, this) == wxYES)
                {
                    OnButtonSkip(event);
                }
            }
            else
            {
                m_batch->SetStatus(selIndex, Project::WAITING);
                SetStatusText(wxString::Format(_("Reset project %s"), m_batch->GetProject(selIndex)->path.c_str()));
            };
        };
    }
    else
    {
        SetStatusText(_("Please select a project to reset"));
    }
    m_batch->SaveTemp();
}

void BatchFrame::OnButtonResetAll(wxCommandEvent& event)
{
    if(m_batch->GetRunningCount()!=0)
    {
        if (hugin_utils::HuginMessageBox(_("Cannot reset projects in progress.\nDo you want to cancel the batch?"), _("PTBatcherGUI"), wxYES_NO | wxICON_INFORMATION, this) == wxYES)
        {
            OnButtonCancel(event);
        }
    }
    else
    {
        for(int i=projListBox->GetItemCount()-1; i>=0; i--)
        {
            m_batch->SetStatus(i,Project::WAITING);
        }
    }
    m_batch->SaveTemp();
}

void BatchFrame::OnButtonRunBatch(wxCommandEvent& event)
{
    if(m_batch->IsPaused())
    {
        //m_batch->paused = false;
        OnButtonPause(event);
    }
    else
    {
        RunBatch();
    }
}

void BatchFrame::OnButtonSaveBatch(wxCommandEvent& event)
{
    wxString defaultdir = wxConfigBase::Get()->Read("/BatchFrame/batchPath",wxEmptyString);
    wxFileDialog dlg(0,
                     _("Specify batch file to save"),
                     defaultdir, wxEmptyString,
                     _("Batch file (*.ptq)|*.ptq;|All files (*)|*"),
                     wxFD_SAVE | wxFD_OVERWRITE_PROMPT, wxDefaultPosition);
    if (dlg.ShowModal() == wxID_OK)
    {
        wxConfig::Get()->Write("/BatchFrame/batchPath", dlg.GetDirectory());  // remember for later
        m_batch->SaveBatchFile(dlg.GetPath());
    }
}

void BatchFrame::OnButtonSkip(wxCommandEvent& event)
{
    const HuginBase::UIntSet selected(projListBox->GetSelectedProjects());
    if(!selected.empty())
    {
        for (auto selIndex : selected)
        {
            if (m_batch->GetStatus(selIndex) == Project::RUNNING
                || m_batch->GetStatus(selIndex) == Project::PAUSED)
            {
                if (m_batch->GetStatus(selIndex) == Project::PAUSED)
                {
                    if (m_batch->GetRunningCount() == 1)
                    {
                        GetToolBar()->ToggleTool(XRCID("tool_pause"), false);
                    }
                    for (int i = 0; i < m_batch->GetRunningCount(); i++)
                    {
                        if (m_batch->GetStatus(selIndex) == Project::PAUSED
                            && m_batch->CompareProjectsInLists(i, selIndex))
                        {
                            m_batch->CancelProject(i);
                        }
                    }
                }
                else
                {
                    //we go through all running projects to find the one with the same id as chosen one
                    for (int i = 0; i < m_batch->GetRunningCount(); i++)
                    {
                        if (m_batch->GetStatus(selIndex) == Project::RUNNING
                            && m_batch->CompareProjectsInLists(i, selIndex))
                        {
                            m_batch->CancelProject(i);
                        }
                    }
                }
            }
            else
            {
                m_batch->SetStatus(selIndex, Project::FAILED);
            };
        };
    }
}

void SelectEndTask(wxControlWithItems* list, const Batch::EndTask endTask)
{
    for (unsigned int i = 0; i<list->GetCount(); i++)
    {
        if (static_cast<Batch::EndTask>((size_t)list->GetClientData(i)) == endTask)
        {
            list->SetSelection(i);
            return;
        };
    };
    list->SetSelection(0);
};

void BatchFrame::SetCheckboxes()
{
    wxConfigBase* config=wxConfigBase::Get();
    int i;
    // read older version
#if defined __WXMAC__ || defined __WXOSX_COCOA__
    i = 0;
#else
    i=config->Read("/BatchFrame/ShutdownCheck", 0l);
#endif
    if (i != 0)
    {
        SelectEndTask(m_endChoice, Batch::SHUTDOWN);
        m_batch->atEnd = Batch::SHUTDOWN;
    };
    config->DeleteEntry("/BatchFrame/ShutdownCheck");
    // now read current version
    i = config->Read("/BatchFrame/AtEnd", 0l);
#if defined __WXMAC__ || defined __WXOSX_COCOA__
    // wxWidgets for MacOS does not support wxShutdown
    if (i == Batch::SHUTDOWN)
    {
        i = 0;
    };
#endif
    m_batch->atEnd = static_cast<Batch::EndTask>(i);
    SelectEndTask(m_endChoice, m_batch->atEnd);
    i=config->Read("/BatchFrame/OverwriteCheck", 0l);
    XRCCTRL(*this,"cb_overwrite",wxCheckBox)->SetValue(i!=0);
    m_batch->overwrite=(i!=0);
    i=config->Read("/BatchFrame/VerboseCheck", 0l);
    XRCCTRL(*this,"cb_verbose",wxCheckBox)->SetValue(i!=0);
    m_batch->verbose=(i!=0);
    i=config->Read("/BatchFrame/AutoRemoveCheck", 1l);
    XRCCTRL(*this,"cb_autoremove",wxCheckBox)->SetValue(i!=0);
    m_batch->autoremove=(i!=0);
    i=config->Read("/BatchFrame/AutoStitchCheck", 0l);
    XRCCTRL(*this,"cb_autostitch",wxCheckBox)->SetValue(i!=0);
    m_batch->autostitch=(i!=0);
    i=config->Read("/BatchFrame/SaveLog", 0l);
    XRCCTRL(*this, "cb_savelog",wxCheckBox)->SetValue(i!=0);
    m_batch->saveLog=(i!=0);
};

Batch::EndTask BatchFrame::GetEndTask()
{
    return static_cast<Batch::EndTask>((size_t)m_endChoice->GetClientData(m_endChoice->GetSelection()));
};

bool BatchFrame::GetCheckOverwrite()
{
    return XRCCTRL(*this,"cb_overwrite",wxCheckBox)->IsChecked();
};

bool BatchFrame::GetCheckVerbose()
{
    return XRCCTRL(*this,"cb_verbose",wxCheckBox)->IsChecked();
};

bool BatchFrame::GetCheckAutoRemove()
{
    return XRCCTRL(*this,"cb_autoremove",wxCheckBox)->IsChecked();
};

bool BatchFrame::GetCheckAutoStitch()
{
    return XRCCTRL(*this,"cb_autostitch",wxCheckBox)->IsChecked();
};

bool BatchFrame::GetCheckSaveLog()
{
    return XRCCTRL(*this,"cb_savelog",wxCheckBox)->IsChecked();
};

void BatchFrame::OnCheckOverwrite(wxCommandEvent& event)
{
    wxConfigBase* config=wxConfigBase::Get();
    if(event.IsChecked())
    {
        m_batch->overwrite = true;
        config->Write("/BatchFrame/OverwriteCheck", 1l);
    }
    else
    {
        m_batch->overwrite = false;
        config->Write("/BatchFrame/OverwriteCheck", 0l);
    }
    config->Flush();
}

void BatchFrame::OnChoiceEnd(wxCommandEvent& event)
{
    m_batch->atEnd = static_cast<Batch::EndTask>((size_t)m_endChoice->GetClientData(event.GetSelection()));
    wxConfigBase* config=wxConfigBase::Get();
    config->Write("/BatchFrame/AtEnd", static_cast<long>(m_batch->atEnd));
    config->Flush();
}

void BatchFrame::OnCheckVerbose(wxCommandEvent& event)
{
    wxConfigBase* config=wxConfigBase::Get();
    if(event.IsChecked())
    {
        m_batch->verbose = true;
        config->Write("/BatchFrame/VerboseCheck", 1l);
    }
    else
    {
        m_batch->verbose = false;
        config->Write("/BatchFrame/VerboseCheck", 0l);
    };
    config->Flush();
    m_batch->ShowOutput(m_batch->verbose);
}

void BatchFrame::SetInternalVerbose(bool newVerbose)
{
    m_batch->verbose=newVerbose;
};

void BatchFrame::OnCheckAutoRemove(wxCommandEvent& event)
{
    m_batch->autoremove=event.IsChecked();
    wxConfigBase* config=wxConfigBase::Get();
    if(m_batch->autoremove)
    {
        config->Write("/BatchFrame/AutoRemoveCheck", 1l);
    }
    else
    {
        config->Write("/BatchFrame/AutoRemoveCheck", 0l);
    }
    config->Flush();
};

void BatchFrame::OnCheckAutoStitch(wxCommandEvent& event)
{
    m_batch->autostitch=event.IsChecked();
    wxConfigBase* config=wxConfigBase::Get();
    if(m_batch->autostitch)
    {
        config->Write("/BatchFrame/AutoStitchCheck", 1l);
    }
    else
    {
        config->Write("/BatchFrame/AutoStitchCheck", 0l);
    }
    config->Flush();
};

void BatchFrame::OnCheckSaveLog(wxCommandEvent& event)
{
    m_batch->saveLog=event.IsChecked();
    wxConfigBase* config=wxConfigBase::Get();
    if(m_batch->saveLog)
    {
        config->Write("/BatchFrame/SaveLog", 1l);
    }
    else
    {
        config->Write("/BatchFrame/SaveLog", 0l);
    }
    config->Flush();
};

void BatchFrame::OnClose(wxCloseEvent& event)
{
    // check size of batch queue
    if (m_batch->GetProjectCount() > 500)
    {
        hugin_utils::MessageDialog message = hugin_utils::GetMessageDialog(_("The batch queue contains many items.\nThis can have negative effects on performance.\nShould the batch queue be cleared now?"),
            _("PTBatcherGUI"), wxYES_NO | wxICON_INFORMATION, this);
        message->SetYesNoLabels(_("Clear batch queue now"), _("Keep batch queue"));
        if (message->ShowModal() == wxID_YES)
        {
            m_batch->ClearBatch();
            m_batch->SaveTemp();
        };
    };
    //save windows position
    wxConfigBase* config=wxConfigBase::Get();
    if(IsMaximized())
    {
        config->Write("/BatchFrame/Max", 1l);
        config->Write("/BatchFrame/Minimized", 0l);
    }
    else
    {
        config->Write("/BatchFrame/Max", 0l);
        if(m_tray!=NULL && !IsShown())
        {
            config->Write("/BatchFrame/Minimized", 1l);
        }
        else
        {
            config->Write("/BatchFrame/Minimized", 0l);
            config->Write("/BatchFrame/Width", GetSize().GetWidth());
            config->Write("/BatchFrame/Height", GetSize().GetHeight());
        };
    }
    config->Flush();
    if(m_tray!=NULL)
    {
        delete m_tray;
        m_tray = NULL;
    }
    delete m_updateProjectsTimer;
    this->Destroy();
}

void BatchFrame::PropagateDefaults()
{
    m_batch->atEnd = GetEndTask();
    m_batch->overwrite=GetCheckOverwrite();
    m_batch->verbose=GetCheckVerbose();
    m_batch->autoremove=GetCheckAutoRemove();
    m_batch->autostitch=GetCheckAutoStitch();
}

void BatchFrame::RunBatch()
{
    if(!IsRunning())
    {
        SetStatusText(_("Starting batch"));
        if (m_tray)
        {
            m_tray->SetIcon(m_iconRunning, _("Processing Hugin's batch queue"));
        };
    }
    m_batch->RunBatch();
}

void BatchFrame::SetLocaleAndXRC(wxLocale* locale, wxString xrc)
{
    m_locale = locale;
    m_xrcPrefix = xrc;
}

void BatchFrame::SwapProject(int index, bool down)
{
    if(index>=0 && index<(projListBox->GetItemCount()-1))
    {
        projListBox->SwapProject(index);
        m_batch->SwapProject(index);
        if(down)
        {
            projListBox->Deselect(index);
            projListBox->Select(index + 1);
        }
        else
        {
            projListBox->Select(index);
            projListBox->Deselect(index + 1);
        };
    }
}


void BatchFrame::OnProcessTerminate(wxProcessEvent& event)
{
    if(m_batch->GetRunningCount()==1)
    {
        GetToolBar()->ToggleTool(XRCID("tool_pause"),false);
        if (m_tray)
        {
            m_tray->SetIcon(m_iconNormal, _("Hugin's Batch processor"));
        };
    }
    event.Skip();
}

void BatchFrame::RestoreSize()
{
    //get saved size
    wxConfigBase* config=wxConfigBase::Get();
    int width = config->Read("/BatchFrame/Width", -1l);
    int height = config->Read("/BatchFrame/Height", -1l);
    int max = config->Read("/BatchFrame/Max", -1l);
    int min = config->Read("/BatchFrame/Minimized", -1l);
    if((width != -1) && (height != -1))
    {
        SetSize(width,height);
    }
    else
    {
        SetSize(this->FromDIP(wxSize(600,400)));
    }

    if(max==1)
    {
        Maximize();
    };
    m_startedMinimized=(m_tray!=NULL) && (min==1);
}

void BatchFrame::OnBatchFailed(wxCommandEvent& event)
{
    if(m_batch->GetFailedProjectsCount()>0)
    {
        if (m_tray)
        {
            m_tray->SetIcon(m_iconNormal, _("Hugin's Batch processor"));
        };
        FailedProjectsDialog failedProjects_dlg(this, m_batch, m_xrcPrefix);
        failedProjects_dlg.ShowModal();
    };
};

void BatchFrame::OnBatchInformation(wxCommandEvent& e)
{
    SetStatusText(e.GetString());
    if (m_tray && e.GetInt() == 1)
    {
        // batch finished, reset icon in task bar
        m_tray->SetIcon(m_iconNormal, _("Hugin's Batch processor"));
    };
};

void BatchFrame::OnProgress(wxCommandEvent& e)
{
    m_progStatusBar->SetProgress(e.GetInt());
    UpdateTaskBarProgressBar();
};

void BatchFrame::UpdateTaskBarProgressBar()
{
#if defined __WXMSW__ && wxUSE_TASKBARBUTTON
    // provide also a feedback in task bar if available
    if (IsShown())
    {
        wxTaskBarButton* taskBarButton = MSWGetTaskBarButton();
        if (taskBarButton != NULL)
        {
            if (m_progStatusBar->GetProgress() < 0)
            {
                taskBarButton->SetProgressValue(wxTASKBAR_BUTTON_NO_PROGRESS);
            }
            else
            {
                taskBarButton->SetProgressRange(100);
                taskBarButton->SetProgressState(m_batch->IsPaused() ? wxTASKBAR_BUTTON_PAUSED : wxTASKBAR_BUTTON_NORMAL);
                taskBarButton->SetProgressValue(m_progStatusBar->GetProgress());
            };
        };
    };
#endif
};

void BatchFrame::OnMinimize(wxIconizeEvent& e)
{
    //hide/show window in taskbar when minimizing
    if(m_tray!=NULL)
    {
        Show(!e.IsIconized());
        //switch off verbose output if PTBatcherGUI is in tray/taskbar
        if(e.IsIconized())
        {
            m_batch->verbose=false;
        }
        else
        {
            m_batch->verbose=XRCCTRL(*this,"cb_verbose",wxCheckBox)->IsChecked();
            UpdateTaskBarProgressBar();
        };
        m_batch->ShowOutput(m_batch->verbose);
    }
    else //don't hide window if no tray icon
    {
        if (!e.IsIconized())
        {
            // window is restored, update progress indicators
            UpdateTaskBarProgressBar();
        };
        e.Skip();
    };
};

void BatchFrame::UpdateBatchVerboseStatus()
{
    m_batch->verbose=XRCCTRL(*this,"cb_verbose",wxCheckBox)->IsChecked();
    m_batch->ShowOutput(m_batch->verbose);
};

void BatchFrame::OnRefillListBox(wxCommandEvent& event)
{
    const HuginBase::UIntSet selected = projListBox->GetSelectedProjects();
    std::set<long> selectedID;
    for (auto index : selected)
    {
        selectedID.insert(m_batch->GetProject(index)->id);
    };
    projListBox->DeleteAllItems();
    projListBox->Fill(m_batch);
    for(auto id:selectedID)
    {
        int index=projListBox->GetIndex(id);
        if(index!=-1)
        {
            projListBox->Select(index);
        };
    };
};

void BatchFrame::OnMinimizeTrayMenu(wxCommandEvent& event)
{
    UpdateTrayIcon(event.IsChecked());
    wxConfigBase* config=wxConfigBase::Get();
    config->Write("/BatchFrame/minimizeTray", event.IsChecked());
    config->Flush();
}

void BatchFrame::UpdateTrayIcon(const bool createTrayIcon)
{
    if (createTrayIcon)
    {
        // create tray icon only if it not exists
        if (m_tray)
        {
            delete m_tray;
            m_tray = NULL;
        }
        m_tray = new BatchTaskBarIcon();
        if (m_batch->IsRunning())
        {
            m_tray->SetIcon(m_iconRunning, _("Processing Hugin's batch queue"));
        }
        else
        {
            if (m_batch->IsPaused())
            {
                m_tray->SetIcon(m_iconPaused, _("Pausing processing Hugin's batch queue"));
            }
            else
            {
                m_tray->SetIcon(m_iconNormal, _("Hugin's Batch processor"));
            }
        }
    }
    else
    {
        // destroy tray icon
        if (m_tray)
        {
            delete m_tray;
            m_tray = NULL;
        }
    }
}
