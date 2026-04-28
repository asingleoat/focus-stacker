// -*- c-basic-offset: 4 -*-

/** @file wxImageCache.cpp
 *
 *  @brief implementation of ImageCache Class
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

#include "wxImageCache.h"
#include "vigra_ext/utils.h"

wxImage imageCacheEntry2wxImage(ImageCache::EntryPtr e)
{
    if (e->imageFloat->size().area() > 0)
    {
        // for float images we need to apply the mapping as selected by the user
        // in the preferences
        const int mapping = wxConfigBase::Get()->Read("/ImageCache/Mapping", HUGIN_IMGCACHE_MAPPING_FLOAT);
        // find average and variance
        vigra::RGBToGrayAccessor<vigra::RGBValue<float> > ga;
        vigra::FindAverageAndVariance<float> mean;   // init functor
        vigra::inspectImage(srcImageRange(*(e->imageFloat), ga), mean);
        // create temporary image with remapped tone scale
        vigra::BRGBImage mappedImg(e->imageFloat->size());
        // scale image to (mean - 3 * std deviation) - (mean + 3 * std deviation), 
        vigra_ext::applyMapping(srcImageRange(*(e->imageFloat)), destImage(mappedImg), std::max(mean.average() - 3 * sqrt(mean.variance()), 1e-6f), mean.average() + 3 * sqrt(mean.variance()), mapping);
        // convert to wxImage
        wxImage mappedwxImg(mappedImg.width(), mappedImg.height(), (unsigned char *)mappedImg.data(), true);
        return mappedwxImg.Copy();
    }
    else
    {
        ImageCacheRGB8Ptr img = e->get8BitImage();
        if (img)
        {
            return wxImage(img->width(), img->height(), (unsigned char *)img->data(), true);
        }
        else
        {
            // invalid wxImage
            return wxImage();
        };
    };
}

