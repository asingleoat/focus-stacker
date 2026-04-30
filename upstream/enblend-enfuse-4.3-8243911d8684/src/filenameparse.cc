/*
 * Copyright (C) 2009-2019 Dr. Christoph L. Spiel
 *
 * This file is part of Enblend.
 *
 * Enblend is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * Enblend is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Enblend; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */


// Life is tough and then you die.  -- Jack Dempsey


#include <filesystem>
#include <numeric>
#include <string>
#include <vector>


#ifdef HAVE_CONFIG_H
#include <config.h>
#endif

#include "filenameparse.h"


#define CURRENT_DIRECTORY "."
#define PARENT_DIRECTORY ".."


typedef std::filesystem::path basic_path;


namespace enblend {

bool
isRelativePath(const std::string& aFilename)
{
    const basic_path path {aFilename};

    return path.is_relative();
}


std::string
extractDirname(const std::string& aFilename)
{
    const basic_path path {aFilename};
    const std::string directory {path.parent_path().string()};

    return directory.empty() ? CURRENT_DIRECTORY : directory;
}


std::string
extractBasename(const std::string& aFilename)
{
    const basic_path path {aFilename};

    return path.filename().string();
}


std::string
extractFilename(const std::string& aFilename)
{
    const basic_path path {aFilename};

    return path.stem().string();
}


std::string
extractExtension(const std::string& aFilename)
{
    const basic_path path {aFilename};

    return path.extension().string();
}


static
basic_path
removeDotsInPath(const basic_path& aPath)
{
    basic_path result;

    for (const auto& p : aPath)
    {
        if (p != CURRENT_DIRECTORY)
        {
            result /= p;
        }
    }

    return result;
}


static
basic_path
removeDotDotsInPath(const basic_path& aPath)
{
    std::vector<std::string> directories;

    for (const auto& p : aPath)
    {
        if (p == PARENT_DIRECTORY &&
            !directories.empty() && directories.back() != PARENT_DIRECTORY)
        {
            directories.pop_back();
        }
        else
        {
            directories.push_back(p.string());
        }
    }

    return std::accumulate(directories.begin(), directories.end(),
                           basic_path {},
                           [](const basic_path& parent, const basic_path& leaf)
                           {
                               return basic_path {parent} /= leaf;
                           });
}


std::string
canonicalizePath(const std::string& aPathname, bool keepDot)
{
    const basic_path result {removeDotDotsInPath(removeDotsInPath(basic_path(aPathname)))};

    if (keepDot && result.empty())
    {
        return CURRENT_DIRECTORY;
    }
    else
    {
        return result.string();
    }
}


std::string
concatPath(const std::string& aPathname, const std::string& anotherPathname)
{
    basic_path path {aPathname};
    basic_path leaf {anotherPathname};

    path /= leaf;

    return path.string();
}

} // namespace enblend


// Local Variables:
// mode: c++
// End:
