// -*- c-basic-offset: 4 -*-
/** @file CreateBrightImgDlg.h
 *
 *  @brief Definition of dialog class to create brighter/darker versions of the image
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

#ifndef _CREATEBRIGHTIMGDIALOG_H
#define _CREATEBRIGHTIMGDIALOG_H

#include "panoinc_WX.h"
#include <vector>
#include <vigra/imagecontainer.hxx>
#include "base_wx/wxImageCache.h"

/** Dialog for create brighter and/or darker versions of an image */

class CreateBrightImgDlg : public wxDialog
{
public:
    /** Constructor, read from xrc ressource; restore position */
	CreateBrightImgDlg(wxWindow *parent);
	/** destructor, save position */
	~CreateBrightImgDlg();
	/** load the image, return true on success, otherwise false, error cause is in errorMsg */
	bool SetImage(const wxString& filename, wxString& errorMsg);
	wxArrayString GetTempFiles() const;
protected:
	/** process all images */
	void OnOk(wxCommandEvent & e);
	/** update listbox with new exposure values */
	void OnCreateExposureLevels(wxCommandEvent& e);
	/** one exposure selected */
	void OnExposureSelected(wxListEvent& e);
	/** prevent checking of exposure value 0 */
	void OnExposureChecked(wxListEvent& e);
	/** handler called when size of control was changed */
	void OnSize(wxSizeEvent& e);
private:
	/** returns the current selected exposure step width */
	double GetExposureStepWidth() const;
	/** create rescaled image */
	void RescaleImage();
	/** create the wxBitmap version and apply color profiles */
	void CreatewxBitmap(const vigra::BRGBImage& img);
	/** create the exposure corrected image and save it to the file */
	bool CreateAndSaveExposureCorrectedImage(const wxString& filename, const double correction);
	/** return the number of checked exposures */
	long GetCheckedItemCount();
	// pointer to controls
	wxChoice* m_stepWidthChoice{ nullptr };
	wxChoice* m_levelChoice{ nullptr };
	wxListCtrl* m_exposuresListBox{ nullptr };
	wxStaticBitmap* m_previewBitmap{ nullptr };
	// vector of all exposure values
	std::vector<double> m_exposures;
	/** image cache entry for current image */
	ImageCache::EntryPtr m_image;
	/** current image as vigra::RGBImage */
	vigra::BRGBImage m_scaledImg;
	/** current image as wxBitmap */
	wxBitmap m_scaledwxBitmap;
	double m_currentExposure{ 0 };
	wxArrayString m_tempFiles;
	wxString m_filename;
};

#endif //_CREATEBRIGHTIMGDIALOG_H
