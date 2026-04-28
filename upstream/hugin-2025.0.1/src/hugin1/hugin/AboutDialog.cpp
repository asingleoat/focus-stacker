// -*- c-basic-offset: 4 -*-

/** @file AboutDialog.cpp
 *
 *  @brief Definition of about dialog
 *
 *  @author Yuval Levy <http://www.photopla.net/>
 *
 *  $Id$
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

#include "hugin/AboutDialog.h"

#include "base_wx/wxPlatform.h"
#include "panoinc.h"
#include "hugin/huginApp.h"
#include <wx/utils.h>
extern "C"
{
#include "pano13/queryfeature.h"
}
#ifdef _WIN32
// workaround for a conflict between exiv2 and wxWidgets/CMake built
#define HAVE_PID_T 1
#endif
#include <exiv2/exiv2.hpp>
#include "lensdb/LensDB.h"
#include "sqlite3.h"
#include <lcms2.h>
#include "vigra/config.hxx"
#include "hugin_config.h"

AboutDialog::AboutDialog(wxWindow *parent)
{
    wxXmlResource::Get()->LoadDialog(this, parent, "about_dlg");

    // Version
    XRCCTRL(*this,"about_version", wxTextCtrl)->ChangeValue(wxString(hugin_utils::GetHuginVersion().c_str(), wxConvLocal));

#ifdef __WXMAC__
    wxFont font(10, wxFONTFAMILY_TELETYPE, wxFONTSTYLE_NORMAL, wxFONTWEIGHT_NORMAL);
#else
    wxFont font(8, wxFONTFAMILY_TELETYPE, wxFONTSTYLE_NORMAL, wxFONTWEIGHT_NORMAL);
#endif

    // License
    wxTextCtrl* textCtrl = XRCCTRL(*this, "license_txt", wxTextCtrl);
    wxString strFile = huginApp::Get()->GetXRCPath() + "data/COPYING.txt";
#ifndef _WIN32
    textCtrl->SetFont(font);
#endif
    textCtrl->LoadFile(strFile);

    // Upstream
    textCtrl = XRCCTRL(*this, "upstream_txt", wxTextCtrl);
    strFile = huginApp::Get()->GetXRCPath() + "data/upstream.txt";
#ifndef _WIN32
    textCtrl->SetFont(font);
#endif
    textCtrl->LoadFile(strFile);
    GetSystemInformation(&font);

    // set the position and the size (x,y,width,height). -1 = keep existing
    SetSize(this->FromDIP(wxSize(560, 560)));
    CenterOnParent();
}

void AboutDialog::GetSystemInformation(wxFont *font)
{
    wxTextCtrl* infoText=XRCCTRL(*this,"system_txt",wxTextCtrl);
#ifndef _WIN32
    infoText->SetFont(*font);
#endif
    wxString text;
    text=wxString::Format(_("Operating System: %s"),wxGetOsDescription().c_str());
    wxString is64;
    if(wxIsPlatform64Bit())
        is64=_("64 bit");
    else
        is64=_("32 bit");
    text = text + "\n" + wxString::Format(_("Architecture: %s"), is64.c_str());
    // wxGetFreeMemory returns a wxMemorySize, which is undocumented.
    // However, we know -1 is returned on failure, so it must be signed.
    text = text + "\n" + wxString::Format(_("Free memory: %lld kiB"), wxGetFreeMemory().GetValue() / 1024ll);
#ifdef _WIN32
    UINT cp=GetACP();
    text = text + "\n" + wxString::Format(_("Active Codepage: %u"), cp);
    switch(cp)
    {
    case 1250:
        text = text + " (Central European Windows)";
        break;
    case 1251:
        text = text + " (Cyrillic Windows)";
        break;
    case 1252:
        text = text + " (Western European Windows)";
        break;
    case 1253:
        text = text + " (Greek Windows)";
        break;
    case 1254:
        text = text + " (Turkish Windows)";
        break;
    case 1255:
        text = text + " (Hebrew Windows)";
        break;
    case 1256:
        text = text + " (Arabic Windows)";
        break;
    case 1257:
        text = text + " (Baltic Windows)";
        break;
    case 1258:
        text = text + " (Vietnamese Windows)";
        break;
    };
#endif
    text = text + "\n\nHugin\n" + wxString::Format(_("Version: %s"), wxString(hugin_utils::GetHuginVersion().c_str(), wxConvLocal).c_str());
    text = text + "\n" + wxString::Format(_("Path to resources: %s"), huginApp::Get()->GetXRCPath().c_str());
    text = text + "\n" + wxString::Format(_("Path to data: %s"), huginApp::Get()->GetDataPath().c_str());
    HuginBase::LensDB::LensDB& lensDB = HuginBase::LensDB::LensDB::GetSingleton();
    text = text + "\n" + wxString::Format(_("Hugins camera and lens database: %s"), wxString(lensDB.GetDBFilename().c_str(), wxConvLocal).c_str());
    text = text + "\n" + _("Multi-threading using C++11 std::thread and OpenMP");
    if (huginApp::Get()->HasMonitorProfile())
    {
        text = text + "\n" + wxString::Format(_("Monitor profile: %s"), huginApp::Get()->GetMonitorProfileName().c_str());
    }
    text = text + "\n\n" + _("Libraries");
    wxVersionInfo info = wxGetLibraryVersionInfo();
    text = text + "\nwxWidgets: " + info.GetVersionString();
    if(info.HasDescription())
    {
        text = text + "\n" + info.GetDescription();
    };
    {
        char panoVersion[255];
        if (queryFeatureString(PTVERSION_NAME_FILEVERSION, panoVersion, sizeof(panoVersion) / sizeof(panoVersion[0])))
        {
            text = text + "\nlibpano13: " + wxString(panoVersion, wxConvLocal);
        };
    }
    text = text + "\nExiv2: " + wxString(Exiv2::versionString().c_str(), wxConvLocal);
    text = text + "\nSQLite3: " + wxString(sqlite3_libversion(), wxConvLocal);
    text = text + "\n" + wxString::Format("Vigra: %s", wxString(VIGRA_VERSION, wxConvLocal).c_str());
    text = text + "\n" + wxString::Format("LittleCMS2: %i.%i", LCMS_VERSION / 1000, LCMS_VERSION / 10 % 100);
    infoText->SetValue(text);
}
