#include <cctype>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

#define DEBUG_DEBUG(x) do { } while(0)
#define DEBUG_NOTICE(x) do { } while(0)
#define DEBUG_TRACE(x) do { } while(0)

#include "vigra/stdimage.hxx"
#include "vigra/impex.hxx"
#include "vigra_ext/Correlation.h"
#include "vigra_ext/InterestPoints.h"
#include "vigra_ext/Pyramid.h"

namespace {

using MapPoints = std::multimap<double, vigra::Diff2D>;

std::string readToken(std::istream &in)
{
    std::string token;
    char ch = 0;
    while(in.get(ch))
    {
        if(std::isspace(static_cast<unsigned char>(ch)))
            continue;
        if(ch == '#')
        {
            in.ignore(std::numeric_limits<std::streamsize>::max(), '\n');
            continue;
        }
        token.push_back(ch);
        break;
    }

    while(in.get(ch))
    {
        if(std::isspace(static_cast<unsigned char>(ch)))
            break;
        token.push_back(ch);
    }
    return token;
}

vigra::BImage loadPgm(const std::string &path)
{
    std::ifstream in(path, std::ios::binary);
    if(!in)
        throw std::runtime_error("failed to open PGM");

    const std::string magic = readToken(in);
    if(magic != "P5")
        throw std::runtime_error("unsupported PGM magic");

    const int width = std::stoi(readToken(in));
    const int height = std::stoi(readToken(in));
    const int maxValue = std::stoi(readToken(in));
    if(maxValue != 255)
        throw std::runtime_error("unsupported PGM max value");

    std::vector<unsigned char> data(static_cast<std::size_t>(width * height));
    in.read(reinterpret_cast<char *>(data.data()), static_cast<std::streamsize>(data.size()));
    if(!in)
        throw std::runtime_error("failed to read PGM pixel data");

    vigra::BImage image(width, height);
    for(int y = 0; y < height; ++y)
    {
        for(int x = 0; x < width; ++x)
        {
            image(x, y) = data[static_cast<std::size_t>(y * width + x)];
        }
    }
    return image;
}

std::vector<vigra::Rect2D> buildRects(int width, int height, unsigned grid)
{
    std::vector<vigra::Rect2D> rects;
    vigra::Size2D size(width, height);
    for(unsigned party = 0; party < grid; ++party)
    {
        for(unsigned partx = 0; partx < grid; ++partx)
        {
            vigra::Rect2D rect(
                static_cast<int>(partx * size.x / grid),
                static_cast<int>(party * size.y / grid),
                static_cast<int>((partx + 1) * size.x / grid),
                static_cast<int>((party + 1) * size.y / grid));
            rect &= vigra::Rect2D(size);
            if(rect.width() > 0 && rect.height() > 0)
                rects.push_back(rect);
        }
    }
    return rects;
}

void usage()
{
    std::cerr
        << "usage:\n"
        << "  vigra_oracle dump-reduced-pgm-image <image> <pyr_level> <output.pgm>\n"
        << "  vigra_oracle dump-import-ppm <image> <output.ppm>\n"
        << "  vigra_oracle dump-interest <image.pgm> <grid_size> <rect_index> <scale> <max_points>\n"
        << "  vigra_oracle match-point <left.pgm> <right.pgm> <left_x> <left_y> <right_x> <right_y> <template_size> <search_width>\n"
        << "  vigra_oracle match-rect <left_pyr.pgm> <right_pyr.pgm> <left_full.pgm> <right_full.pgm> <grid_size> <rect_index> <points_per_grid> <pyr_level> <corr_threshold>\n"
        << "  vigra_oracle trace-rect <left_pyr.pgm> <right_pyr.pgm> <left_full.pgm> <right_full.pgm> <grid_size> <rect_index> <points_per_grid> <pyr_level> <corr_threshold>\n"
        << "  vigra_oracle trace-rect-image <left_image> <right_image> <grid_size> <rect_index> <points_per_grid> <pyr_level> <corr_threshold>\n";
}

template <class ImageType>
void loadAndReduceImage(const std::string &path, int pyrLevel, ImageType &orig, ImageType &reduced)
{
    vigra::ImageImportInfo info(path.c_str());
    orig.resize(info.size());
    vigra::importImage(info, vigra::destImage(orig));
    vigra_ext::reduceNTimes(orig, reduced, pyrLevel);
}

template <class ImageType>
void writeGrayPgm(const ImageType &image, const std::string &path, vigra::VigraTrueType)
{
    std::ofstream out(path, std::ios::binary);
    if(!out)
        throw std::runtime_error("failed to open output PGM");
    out << "P5\n" << image.width() << ' ' << image.height() << "\n255\n";
    for(int y = 0; y < image.height(); ++y)
    {
        for(int x = 0; x < image.width(); ++x)
        {
            const auto value = image(x, y);
            const unsigned char byte = static_cast<unsigned char>(std::max(0, std::min(255, static_cast<int>(value))));
            out.put(static_cast<char>(byte));
        }
    }
}

template <class ImageType>
void writeGrayPgm(const ImageType &image, const std::string &path, vigra::VigraFalseType)
{
    std::ofstream out(path, std::ios::binary);
    if(!out)
        throw std::runtime_error("failed to open output PGM");
    out << "P5\n" << image.width() << ' ' << image.height() << "\n255\n";
    for(int y = 0; y < image.height(); ++y)
    {
        for(int x = 0; x < image.width(); ++x)
        {
            const auto value = image(x, y);
            const double gray = 0.3 * value.red() + 0.59 * value.green() + 0.11 * value.blue();
            const int rounded = static_cast<int>(gray + 0.5);
            const unsigned char byte = static_cast<unsigned char>(std::max(0, std::min(255, rounded)));
            out.put(static_cast<char>(byte));
        }
    }
}

template <class ImageType>
void writeGrayPgm(const ImageType &image, const std::string &path)
{
    typedef typename ImageType::value_type PixelType;
    typedef typename vigra::NumericTraits<PixelType>::isScalar is_scalar;
    writeGrayPgm(image, path, is_scalar());
}

namespace detail
{
template <class ImageType>
vigra_ext::CorrelationResult FineTunePoint(const ImageType& leftImg, const vigra::Diff2D templPos, const int templSize,
    const ImageType& rightImg, const vigra::Diff2D searchPos, const int searchWidth, vigra::VigraTrueType)
{
    return vigra_ext::PointFineTune(leftImg, leftImg.accessor(),
        templPos, templSize,
        rightImg, rightImg.accessor(),
        searchPos, searchWidth);
}

template <class ImageType>
vigra_ext::CorrelationResult FineTunePoint(const ImageType& leftImg, const vigra::Diff2D templPos, const int templSize,
    const ImageType& rightImg, const vigra::Diff2D searchPos, const int searchWidth, vigra::VigraFalseType)
{
    return vigra_ext::PointFineTune(leftImg,
        vigra::RGBToGrayAccessor<typename ImageType::value_type>(),
        templPos, templSize,
        rightImg, vigra::RGBToGrayAccessor<typename ImageType::value_type>(),
        searchPos, searchWidth);
}

template <class ImageType>
void FindInterestPointsPartial(const ImageType& image, const vigra::Rect2D& rect, double scale,
    unsigned nPoints, std::multimap<double, vigra::Diff2D> &points, vigra::VigraTrueType)
{
    vigra_ext::findInterestPointsPartial(vigra::srcImageRange(image), rect, scale, nPoints, points);
}

template <class ImageType>
void FindInterestPointsPartial(const ImageType& image, const vigra::Rect2D& rect, double scale,
    unsigned nPoints, std::multimap<double, vigra::Diff2D> &points, vigra::VigraFalseType)
{
    typedef typename ImageType::value_type ImageValueType;
    vigra_ext::findInterestPointsPartial(vigra::srcImageRange(image, vigra::RGBToGrayAccessor<ImageValueType>()), rect, scale, nPoints, points);
}
}

template <class ImageType>
void traceRectImagePath(const std::string &leftPath, const std::string &rightPath, int pyrLevel, unsigned gridSize, unsigned rectIndex, unsigned pointsPerGrid, double corrThreshold)
{
    typedef typename ImageType::value_type ImageValueType;
    typedef typename vigra::NumericTraits<ImageValueType>::isScalar is_scalar;

    ImageType leftOrig;
    ImageType leftReduced;
    ImageType rightOrig;
    ImageType rightReduced;
    loadAndReduceImage(leftPath, pyrLevel, leftOrig, leftReduced);
    loadAndReduceImage(rightPath, pyrLevel, rightOrig, rightReduced);

    std::vector<vigra::Rect2D> rects = buildRects(leftReduced.width(), leftReduced.height(), gridSize);
    if(rectIndex >= rects.size())
        throw std::runtime_error("rect index out of range");

    MapPoints points;
    detail::FindInterestPointsPartial(leftReduced, rects[rectIndex], 2.0, 5 * pointsPerGrid, points, is_scalar());

    const double scaleFactor = 1 << pyrLevel;
    const long templWidth = 20;
    const long sWidth = 100;
    unsigned accepted = 0;
    std::cout
        << "rect " << rectIndex << ": "
        << rects[rectIndex].left() << ' '
        << rects[rectIndex].top() << ' '
        << rects[rectIndex].right() << ' '
        << rects[rectIndex].bottom() << '\n';
    std::cout << std::fixed << std::setprecision(9);

    unsigned candIndex = 0;
    for (MapPoints::const_reverse_iterator it = points.rbegin(); it != points.rend(); ++it, ++candIndex)
    {
        vigra_ext::CorrelationResult res = detail::FineTunePoint(leftReduced, it->second, templWidth,
            rightReduced, it->second, sWidth, is_scalar());

        const bool coarseOk = res.maxi >= corrThreshold;
        const double coarseScore = res.maxi;
        const double coarseX = res.maxpos.x * scaleFactor;
        const double coarseY = res.maxpos.y * scaleFactor;
        double finalX = coarseX;
        double finalY = coarseY;
        double finalScore = res.maxi;
        bool refinedOk = coarseOk;

        if (coarseOk && pyrLevel > 0)
        {
            res = detail::FineTunePoint(
                leftOrig,
                vigra::Diff2D(it->second.x * scaleFactor, it->second.y * scaleFactor),
                templWidth,
                rightOrig,
                vigra::Diff2D(res.maxpos.x * scaleFactor, res.maxpos.y * scaleFactor),
                scaleFactor,
                is_scalar());
            finalX = res.maxpos.x;
            finalY = res.maxpos.y;
            finalScore = res.maxi;
            refinedOk = res.maxi >= corrThreshold;
        }

        const bool acceptedNow = coarseOk && refinedOk && accepted < pointsPerGrid;
        std::cout
            << "cand=" << candIndex
            << " left=" << (it->second.x * scaleFactor) << "," << (it->second.y * scaleFactor)
            << " coarse=" << coarseX << "," << coarseY
            << " coarse_score=" << coarseScore
            << " final=" << finalX << "," << finalY
            << " final_score=" << finalScore
            << " coarse_ok=" << (coarseOk ? 1 : 0)
            << " refined_ok=" << (refinedOk ? 1 : 0)
            << " accepted=" << (acceptedNow ? 1 : 0)
            << '\n';
        if (acceptedNow)
            ++accepted;
    }
}

void writeRgbPpm(const vigra::BRGBImage &image, const std::string &path)
{
    std::ofstream out(path, std::ios::binary);
    if(!out)
        throw std::runtime_error("failed to open output PPM");
    out << "P6\n" << image.width() << ' ' << image.height() << "\n255\n";
    for(int y = 0; y < image.height(); ++y)
    {
        for(int x = 0; x < image.width(); ++x)
        {
            const auto value = image(x, y);
            out.put(static_cast<char>(value.red()));
            out.put(static_cast<char>(value.green()));
            out.put(static_cast<char>(value.blue()));
        }
    }
}

} // namespace

int main(int argc, char **argv)
{
    try
    {
        const std::string command = argv[1];
        if(command == "dump-import-ppm")
        {
            if(argc != 4)
            {
                usage();
                return 1;
            }

            const std::string imagePath = argv[2];
            const std::string outputPath = argv[3];
            vigra::ImageImportInfo info(imagePath.c_str());
            const std::string pixelType = info.getPixelType();
            if(info.numBands() == 1 && pixelType == "UINT8")
            {
                vigra::BImage image(info.size());
                vigra::importImage(info, vigra::destImage(image));
                writeGrayPgm(image, outputPath);
                return 0;
            }
            if(info.numBands() == 3 && pixelType == "UINT8")
            {
                vigra::BRGBImage image(info.size());
                vigra::importImage(info, vigra::destImage(image));
                writeRgbPpm(image, outputPath);
                return 0;
            }
            throw std::runtime_error(
                std::string("unsupported image type for dump-import-ppm: bands=") +
                std::to_string(info.numBands()) +
                " pixelType=" + pixelType);
        }

        if(command == "dump-reduced-pgm-image")
        {
            if(argc != 5)
            {
                usage();
                return 1;
            }

            const std::string imagePath = argv[2];
            const int pyrLevel = std::stoi(argv[3]);
            const std::string outputPath = argv[4];

            vigra::ImageImportInfo info(imagePath.c_str());
            const std::string pixelType = info.getPixelType();
            if(info.numBands() == 1 && pixelType == "UINT8")
            {
                vigra::BImage orig;
                vigra::BImage reduced;
                loadAndReduceImage(imagePath, pyrLevel, orig, reduced);
                writeGrayPgm(reduced, outputPath);
                return 0;
            }
            if(info.numBands() == 3 && pixelType == "UINT8")
            {
                vigra::BRGBImage orig;
                vigra::BRGBImage reduced;
                loadAndReduceImage(imagePath, pyrLevel, orig, reduced);
                writeGrayPgm(reduced, outputPath);
                return 0;
            }
            if(info.numBands() == 1 && pixelType == "UINT16")
            {
                vigra::UInt16Image orig;
                vigra::UInt16Image reduced;
                loadAndReduceImage(imagePath, pyrLevel, orig, reduced);
                writeGrayPgm(reduced, outputPath);
                return 0;
            }
            if(info.numBands() == 3 && pixelType == "UINT16")
            {
                vigra::UInt16RGBImage orig;
                vigra::UInt16RGBImage reduced;
                loadAndReduceImage(imagePath, pyrLevel, orig, reduced);
                writeGrayPgm(reduced, outputPath);
                return 0;
            }

            throw std::runtime_error(
                std::string("unsupported image type for dump-reduced-pgm-image: bands=") +
                std::to_string(info.numBands()) +
                " pixelType=" + info.getPixelType());
        }

        if(command == "dump-interest")
        {
            if(argc != 7)
            {
                usage();
                return 1;
            }

            const std::string imagePath = argv[2];
            const unsigned gridSize = static_cast<unsigned>(std::stoul(argv[3]));
            const unsigned rectIndex = static_cast<unsigned>(std::stoul(argv[4]));
            const double scale = std::stod(argv[5]);
            const unsigned maxPoints = static_cast<unsigned>(std::stoul(argv[6]));

            vigra::BImage image = loadPgm(imagePath);
            std::vector<vigra::Rect2D> rects = buildRects(image.width(), image.height(), gridSize);
            if(rectIndex >= rects.size())
                throw std::runtime_error("rect index out of range");

            MapPoints points;
            vigra_ext::findInterestPointsPartial(vigra::srcImageRange(image), rects[rectIndex], scale, maxPoints, points);

            std::cout
                << "rect " << rectIndex << ": "
                << rects[rectIndex].left() << ' '
                << rects[rectIndex].top() << ' '
                << rects[rectIndex].right() << ' '
                << rects[rectIndex].bottom() << '\n';
            std::cout << std::fixed << std::setprecision(9);
            unsigned idx = 0;
            for(MapPoints::const_reverse_iterator it = points.rbegin(); it != points.rend(); ++it, ++idx)
            {
                std::cout << idx << ' ' << it->second.x << ' ' << it->second.y << ' ' << it->first << '\n';
            }
            return 0;
        }

        if(command == "match-point")
        {
            if(argc != 10)
            {
                usage();
                return 1;
            }

            const std::string leftPath = argv[2];
            const std::string rightPath = argv[3];
            const int leftX = std::stoi(argv[4]);
            const int leftY = std::stoi(argv[5]);
            const int rightX = std::stoi(argv[6]);
            const int rightY = std::stoi(argv[7]);
            const int templateSize = std::stoi(argv[8]);
            const int searchWidth = std::stoi(argv[9]);

            vigra::BImage left = loadPgm(leftPath);
            vigra::BImage right = loadPgm(rightPath);
            const vigra_ext::CorrelationResult res = vigra_ext::PointFineTune(
                left,
                left.accessor(),
                vigra::Diff2D(leftX, leftY),
                templateSize,
                right,
                right.accessor(),
                vigra::Diff2D(rightX, rightY),
                searchWidth);
            std::cout << std::fixed << std::setprecision(9)
                      << res.maxi << ' ' << res.maxpos.x << ' ' << res.maxpos.y << '\n';
            return 0;
        }

        if(command == "match-rect")
        {
            if(argc != 11)
            {
                usage();
                return 1;
            }

            const std::string leftPyrPath = argv[2];
            const std::string rightPyrPath = argv[3];
            const std::string leftFullPath = argv[4];
            const std::string rightFullPath = argv[5];
            const unsigned gridSize = static_cast<unsigned>(std::stoul(argv[6]));
            const unsigned rectIndex = static_cast<unsigned>(std::stoul(argv[7]));
            const unsigned pointsPerGrid = static_cast<unsigned>(std::stoul(argv[8]));
            const int pyrLevel = std::stoi(argv[9]);
            const double corrThreshold = std::stod(argv[10]);

            vigra::BImage leftPyr = loadPgm(leftPyrPath);
            vigra::BImage rightPyr = loadPgm(rightPyrPath);
            vigra::BImage leftFull = loadPgm(leftFullPath);
            vigra::BImage rightFull = loadPgm(rightFullPath);
            std::vector<vigra::Rect2D> rects = buildRects(leftPyr.width(), leftPyr.height(), gridSize);
            if(rectIndex >= rects.size())
                throw std::runtime_error("rect index out of range");

            MapPoints points;
            vigra_ext::findInterestPointsPartial(vigra::srcImageRange(leftPyr), rects[rectIndex], 2.0, 5 * pointsPerGrid, points);

            const int scaleFactor = 1 << pyrLevel;
            unsigned accepted = 0;
            std::cout
                << "rect " << rectIndex << ": "
                << rects[rectIndex].left() << ' '
                << rects[rectIndex].top() << ' '
                << rects[rectIndex].right() << ' '
                << rects[rectIndex].bottom() << '\n';
            std::cout << std::fixed << std::setprecision(9);
            unsigned candIndex = 0;
            for(MapPoints::const_reverse_iterator it = points.rbegin(); it != points.rend(); ++it, ++candIndex)
            {
                if(accepted >= pointsPerGrid)
                    break;

                vigra_ext::CorrelationResult res = vigra_ext::PointFineTune(
                    leftPyr,
                    leftPyr.accessor(),
                    it->second,
                    20,
                    rightPyr,
                    rightPyr.accessor(),
                    it->second,
                    100);
                if(res.maxi < corrThreshold)
                    continue;

                const double coarseScore = res.maxi;
                const double coarseX = res.maxpos.x * scaleFactor;
                const double coarseY = res.maxpos.y * scaleFactor;
                double finalX = coarseX;
                double finalY = coarseY;
                double finalScore = res.maxi;

                if(pyrLevel > 0)
                {
                    res = vigra_ext::PointFineTune(
                        leftFull,
                        leftFull.accessor(),
                        vigra::Diff2D(it->second.x * scaleFactor, it->second.y * scaleFactor),
                        20,
                        rightFull,
                        rightFull.accessor(),
                        vigra::Diff2D(static_cast<int>(res.maxpos.x * scaleFactor), static_cast<int>(res.maxpos.y * scaleFactor)),
                        scaleFactor);
                    if(res.maxi < corrThreshold)
                        continue;
                    finalX = res.maxpos.x;
                    finalY = res.maxpos.y;
                    finalScore = res.maxi;
                }

                std::cout
                    << accepted
                    << " cand=" << candIndex
                    << " left=" << (it->second.x * scaleFactor) << "," << (it->second.y * scaleFactor)
                    << " coarse=" << coarseX << "," << coarseY
                    << " coarse_score=" << coarseScore
                    << " final=" << finalX << "," << finalY
                    << " final_score=" << finalScore
                    << '\n';
                ++accepted;
            }
            return 0;
        }

        if(command == "trace-rect")
        {
            if(argc != 11)
            {
                usage();
                return 1;
            }

            const std::string leftPyrPath = argv[2];
            const std::string rightPyrPath = argv[3];
            const std::string leftFullPath = argv[4];
            const std::string rightFullPath = argv[5];
            const unsigned gridSize = static_cast<unsigned>(std::stoul(argv[6]));
            const unsigned rectIndex = static_cast<unsigned>(std::stoul(argv[7]));
            const unsigned pointsPerGrid = static_cast<unsigned>(std::stoul(argv[8]));
            const int pyrLevel = std::stoi(argv[9]);
            const double corrThreshold = std::stod(argv[10]);

            vigra::BImage leftPyr = loadPgm(leftPyrPath);
            vigra::BImage rightPyr = loadPgm(rightPyrPath);
            vigra::BImage leftFull = loadPgm(leftFullPath);
            vigra::BImage rightFull = loadPgm(rightFullPath);
            std::vector<vigra::Rect2D> rects = buildRects(leftPyr.width(), leftPyr.height(), gridSize);
            if(rectIndex >= rects.size())
                throw std::runtime_error("rect index out of range");

            MapPoints points;
            vigra_ext::findInterestPointsPartial(vigra::srcImageRange(leftPyr), rects[rectIndex], 2.0, 5 * pointsPerGrid, points);

            const int scaleFactor = 1 << pyrLevel;
            unsigned accepted = 0;
            std::cout
                << "rect " << rectIndex << ": "
                << rects[rectIndex].left() << ' '
                << rects[rectIndex].top() << ' '
                << rects[rectIndex].right() << ' '
                << rects[rectIndex].bottom() << '\n';
            std::cout << std::fixed << std::setprecision(9);
            unsigned candIndex = 0;
            for(MapPoints::const_reverse_iterator it = points.rbegin(); it != points.rend(); ++it, ++candIndex)
            {
                vigra_ext::CorrelationResult res = vigra_ext::PointFineTune(
                    leftPyr,
                    leftPyr.accessor(),
                    it->second,
                    20,
                    rightPyr,
                    rightPyr.accessor(),
                    it->second,
                    100);

                const bool coarseOk = res.maxi >= corrThreshold;
                const double coarseScore = res.maxi;
                const double coarseX = res.maxpos.x * scaleFactor;
                const double coarseY = res.maxpos.y * scaleFactor;
                double finalX = coarseX;
                double finalY = coarseY;
                double finalScore = res.maxi;
                bool refinedOk = coarseOk;

                if (coarseOk && pyrLevel > 0)
                {
                    res = vigra_ext::PointFineTune(
                        leftFull,
                        leftFull.accessor(),
                        vigra::Diff2D(it->second.x * scaleFactor, it->second.y * scaleFactor),
                        20,
                        rightFull,
                        rightFull.accessor(),
                        vigra::Diff2D(res.maxpos.x * scaleFactor, res.maxpos.y * scaleFactor),
                        scaleFactor);
                    finalX = res.maxpos.x;
                    finalY = res.maxpos.y;
                    finalScore = res.maxi;
                    refinedOk = res.maxi >= corrThreshold;
                }

                const bool acceptedNow = coarseOk && refinedOk && accepted < pointsPerGrid;
                std::cout
                    << "cand=" << candIndex
                    << " left=" << (it->second.x * scaleFactor) << "," << (it->second.y * scaleFactor)
                    << " coarse=" << coarseX << "," << coarseY
                    << " coarse_score=" << coarseScore
                    << " final=" << finalX << "," << finalY
                    << " final_score=" << finalScore
                    << " coarse_ok=" << (coarseOk ? 1 : 0)
                    << " refined_ok=" << (refinedOk ? 1 : 0)
                    << " accepted=" << (acceptedNow ? 1 : 0)
                    << '\n';
                if (acceptedNow)
                    ++accepted;
            }
            return 0;
        }

        if(command == "trace-rect-image")
        {
            if(argc != 9)
            {
                usage();
                return 1;
            }

            const std::string leftPath = argv[2];
            const std::string rightPath = argv[3];
            const unsigned gridSize = static_cast<unsigned>(std::stoul(argv[4]));
            const unsigned rectIndex = static_cast<unsigned>(std::stoul(argv[5]));
            const unsigned pointsPerGrid = static_cast<unsigned>(std::stoul(argv[6]));
            const int pyrLevel = std::stoi(argv[7]);
            const double corrThreshold = std::stod(argv[8]);

            vigra::ImageImportInfo info(leftPath.c_str());
            const std::string pixelType = info.getPixelType();
            if(info.numBands() == 1 && pixelType == "UINT8")
            {
                traceRectImagePath<vigra::BImage>(leftPath, rightPath, pyrLevel, gridSize, rectIndex, pointsPerGrid, corrThreshold);
                return 0;
            }
            if(info.numBands() == 3 && pixelType == "UINT8")
            {
                traceRectImagePath<vigra::BRGBImage>(leftPath, rightPath, pyrLevel, gridSize, rectIndex, pointsPerGrid, corrThreshold);
                return 0;
            }
            if(info.numBands() == 1 && pixelType == "UINT16")
            {
                traceRectImagePath<vigra::UInt16Image>(leftPath, rightPath, pyrLevel, gridSize, rectIndex, pointsPerGrid, corrThreshold);
                return 0;
            }
            if(info.numBands() == 3 && pixelType == "UINT16")
            {
                traceRectImagePath<vigra::UInt16RGBImage>(leftPath, rightPath, pyrLevel, gridSize, rectIndex, pointsPerGrid, corrThreshold);
                return 0;
            }
            throw std::runtime_error(
                std::string("unsupported image type for trace-rect-image: bands=") +
                std::to_string(info.numBands()) +
                " pixelType=" + pixelType);
        }

        usage();
        return 1;
    }
    catch(const std::exception &err)
    {
        std::cerr << "vigra_oracle: " << err.what() << '\n';
        return 1;
    }
}
