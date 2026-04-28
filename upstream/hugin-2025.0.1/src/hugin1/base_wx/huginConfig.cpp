// -*- c-basic-offset: 4 -*-

/** @file huginConfig.cpp
 *
 *  @brief functions for interaction with the hugin configuration file
 *
 *  @author Pablo d'Angelo <pablo.dangelo@web.de>
 *
 *  $Id$
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

#include "platform.h"
#include "huginConfig.h"
#include "hugin/config_defaults.h"

// functions to handle with default project/output filenames
typedef std::map<wxString, wxString> Placeholdersmap;

wxString CleanDateTime(const wxString& input)
{
    // replace invalid characters in format string
    // which are not allowed in filenames
    wxString result(input);
    result.Replace("/", "_");
    result.Replace("\\", "_");
    result.Replace(":", "-");
    result.Replace("*", ".");
    result.Replace("?", ".");
    result.Replace("<", ".");
    result.Replace(">", ".");
    result.Replace("|", ".");
    return result;
}
void FillDefaultPlaceholders(Placeholdersmap & placeholder)
{
    placeholder["%firstimage"]=_("first image");
    placeholder["%lastimage"]=_("last image");
    placeholder["%#images"]="0";
    placeholder["%directory"]=_("directory");
    placeholder["%projection"]=_("Equirectangular");
    placeholder["%focallength"]="28";
    wxDateTime datetime=wxDateTime(13,wxDateTime::May,2012,11,35);
    placeholder["%date"] = CleanDateTime(datetime.FormatDate());
    placeholder["%time"] = CleanDateTime(datetime.FormatTime());
    placeholder["%maker"]=_("Camera maker");
    placeholder["%model"]=_("Camera model");
    placeholder["%lens"]=_("Lens");
};

void FillPlaceholders(Placeholdersmap & placeholder, const HuginBase::Panorama & pano)
{
    const HuginBase::SrcPanoImage & img0=pano.getImage(0);
    wxFileName firstImg(wxString(img0.getFilename().c_str(),HUGIN_CONV_FILENAME));
    placeholder["%firstimage"]=firstImg.GetName();
    if (firstImg.GetDirCount() > 0)
    {
        placeholder["%directory"] = firstImg.GetDirs().Last();
    }
    else
    {
        placeholder["%directory"] = wxEmptyString;
    };
    placeholder["%focallength"]=wxString::Format("%.0f", img0.getExifFocalLength());
    struct tm exifdatetime;
    if (img0.getExifDateTime(&exifdatetime) == 0)
    {
        wxDateTime datetime = wxDateTime(exifdatetime);
        placeholder["%date"] = CleanDateTime(datetime.FormatDate());
        placeholder["%time"] = CleanDateTime(datetime.FormatTime());
    }
    else
    {
        // no date found, use file create date 
        const wxFileName firstFile(img0.getFilename());
        wxDateTime createTime;
        firstFile.GetTimes(NULL, NULL, &createTime);
        placeholder["%date"] = CleanDateTime(createTime.FormatDate());
        placeholder["%time"] = CleanDateTime(createTime.FormatTime());
    };
    placeholder["%maker"]=wxString(img0.getExifMake().c_str(), wxConvLocal);
    placeholder["%model"]=wxString(img0.getExifModel().c_str(), wxConvLocal);
    placeholder["%lens"]=wxString(img0.getExifLens().c_str(), wxConvLocal);

    wxFileName lastImg(wxString(pano.getImage(pano.getNrOfImages()-1).getFilename().c_str(),HUGIN_CONV_FILENAME));
    placeholder["%lastimage"]=lastImg.GetName();
    placeholder["%#images"]=wxString::Format("%lu", (unsigned long)pano.getNrOfImages());
    HuginBase::PanoramaOptions opts = pano.getOptions();
    pano_projection_features proj;
    if (panoProjectionFeaturesQuery(opts.getProjection(), &proj))
    {
        wxString str2(proj.name, wxConvLocal);
        placeholder["%projection"]=wxGetTranslation(str2);
    }
    else
    {
        placeholder["%projection"]=_("unknown projection");
    };
};

wxString getDefaultProjectName(const HuginBase::Panorama & pano,const wxString filenameTemplate)
{
    wxString filename;
    if(filenameTemplate.IsEmpty())
    {
        filename=wxConfigBase::Get()->Read("ProjectFilename", HUGIN_DEFAULT_PROJECT_NAME);
#ifdef __WXMSW__
        filename.Replace("/", "\\", true);
#endif
    }
    else
    {
        filename=filenameTemplate;
    };
    wxString pathPrefix;
    Placeholdersmap placeholder;
    if(pano.getNrOfImages()>0)
    {
        FillPlaceholders(placeholder, pano);
        wxFileName firstImg(wxString(pano.getImage(0).getFilename().c_str(),HUGIN_CONV_FILENAME));
        pathPrefix=firstImg.GetPathWithSep();
    }
    else
    {
        FillDefaultPlaceholders(placeholder);
    };
    // now replace all placeholder
    for(Placeholdersmap::const_iterator it=placeholder.begin(); it!=placeholder.end(); ++it)
    {
        filename.Replace(it->first, it->second, true);
    };
    if(filename.empty())
    {
        filename="pano";
    };
    // check if template is an absolute path, if so ignore path from first image
    wxFileName fileName(filename);
    if (fileName.IsAbsolute())
    {
        return filename;
    };
    return pathPrefix+filename;
};

/** gets the default output prefix, based on filename and images in project
  * the setting is read from the preferences */
wxString getDefaultOutputName(const wxString projectname, const HuginBase::Panorama & pano, const wxString filenameTemplate)
{
    wxFileName project;
    if (projectname.IsEmpty())
    {
        project=getDefaultProjectName(pano);
    }
    else
    {
        project=projectname;
    }
    if(project.HasExt())
    {
        project.ClearExt();
    };

    wxString filename;
    if(filenameTemplate.IsEmpty())
    {
        filename=wxConfigBase::Get()->Read("OutputFilename", HUGIN_DEFAULT_PROJECT_NAME);
#ifdef __WXMSW__
        filename.Replace("/", "\\", true);
#endif
    }
    else
    {
        filename=filenameTemplate;
    };
    wxString pathPrefix=project.GetPathWithSep();
    Placeholdersmap placeholder;
    if(pano.getNrOfImages()>0)
    {
        FillPlaceholders(placeholder, pano);
        wxFileName firstImg(wxString(pano.getImage(0).getFilename().c_str(),HUGIN_CONV_FILENAME));
    }
    else
    {
        FillDefaultPlaceholders(placeholder);
    };
    placeholder.insert(std::make_pair("%projectname", project.GetName()));
    // now replace all placeholder
    for(Placeholdersmap::const_iterator it=placeholder.begin(); it!=placeholder.end(); ++it)
    {
        filename.Replace(it->first, it->second, true);
    };
    if(filename.empty())
    {
        filename="pano";
    };
    // check if template is an absolute path, if so ignore path from first image
    wxFileName fileName(filename);
    if (fileName.IsAbsolute())
    {
        return filename;
    };
    return pathPrefix+filename;
};
