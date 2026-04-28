// -*- c-basic-offset: 4 -*-
/** @file EnfusePanel.h
 *
 *  @brief declaration of panel for enfuse GUI
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

#ifndef ENFUSEPANEL_H
#define ENFUSEPANEL_H

#include "panoinc_WX.h"
#include <wx/propgrid/propgrid.h>
#include "PreviewWindow.h"
#include "base_wx/MyExternalCmdExecDialog.h"

/** panel for enfuse GUI
 *
 */
class EnfusePanel : public wxPanel
{
public:
    /** destructor, save state and settings */
    ~EnfusePanel();
    /** creates the control and populates all controls with their settings */
    bool Create(wxWindow* parent, MyExecPanel* logPanel);
    /** adds the given file to the list */
    void AddFile(const wxString& filename);
    /** call at the end of the enfuse command, to load result back and enable buttons again */
    void OnProcessFinished(wxCommandEvent& e);

protected:
    /** event handler */
    void OnSize(wxSizeEvent& e);
    void OnAddFiles(wxCommandEvent& e);
    void OnRemoveFile(wxCommandEvent& e);
    void OnCreateFile(wxCommandEvent& e);
    void OnFileListChar(wxKeyEvent& e);
    void OnFileSelectionChanged(wxCommandEvent& e);
    void OnFileCheckStateChanged(wxCommandEvent& e);
    void OnLoadSetting(wxCommandEvent& e);
    void OnSaveSetting(wxCommandEvent& e);
    void OnResetSetting(wxCommandEvent& e);
    void OnGeneratePreview(wxCommandEvent& e);
    void OnGenerateOutput(wxCommandEvent& e);
    void OnZoom(wxCommandEvent& e);

private:
    /** fill the PropertyGrid with all enfuse options */
    void PopulateEnfuseOptions();
    /** build the command line and execute enfuse command */
    void ExecuteEnfuse();
    /** build the command line and execute enfuse and exiftool afterwards */
    void ExecuteEnfuseExiftool();
    /** build string with all enfuse options from values in wxPropertyGrid 
     *  this are the mainly the fusion options without the filesnames  
     */
    wxString GetEnfuseOptions();
    /** get the full commandline for enfuse without program, but with files and output options, the output filename is read from m_outputFilename */
    wxString GetEnfuseCommandLine();
    /** enable/disable the file(s) remove and create buttons depending on selection of wxListCtrl */
    void EnableFileButtons();
    /** return the number of check images */
    long GetCheckedItemCount() const;
    /** enable/disable output buttons */
    void EnableOutputButtons(bool enable);
    /** delete all temporary files, to be called mainly at end */
    void CleanUpTempFiles();
    // member variables
    wxListCtrl* m_fileListCtrl = nullptr;
    wxPropertyGrid* m_enfuseOptions = nullptr;
    wxArrayString m_files;
    PreviewWindow* m_preview = nullptr;
    MyExecPanel* m_logWindow = nullptr;
    wxArrayString m_outputFilenames;
    wxArrayString m_tempFiles;
    bool m_cleanupOutput = false;

    DECLARE_DYNAMIC_CLASS(EnfusePanel)
};

#endif // ENFUSEPANEL_H
