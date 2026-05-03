#include <exception>
#include <cstdio>
#include <iostream>
#include <optional>
#include <string>

#include <lcms2.h>
#include <vigra/impex.hxx>
#include <vigra/impexalpha.hxx>

namespace vigra {
inline std::string impexListExtensions()
{
    return "";
}
} // namespace vigra

#include "global.h"
#include "openmp_vigra.h"

const std::string command("enfuse_pyramid_oracle");
std::string OutputFileName(DEFAULT_OUTPUT_FILENAME);
std::optional<std::string> OutputMaskFileName;
int Verbose = 0;
bool OneAtATime = true;
boundary_t WrapAround = OpenBoundaries;
bool Checkpoint = false;
bool StopAfterMaskGeneration = false;
bool LoadMasks = false;
bool UseHardMask = false;
bool OutputIsValid = false;
blend_colorspace_t BlendColorspace = IdentitySpace;
cmsHPROFILE InputProfile = nullptr;
cmsHTRANSFORM InputToXYZTransform = nullptr;
cmsHTRANSFORM XYZToInputTransform = nullptr;
cmsHTRANSFORM InputToLabTransform = nullptr;
cmsHTRANSFORM LabToInputTransform = nullptr;
cmsHANDLE CIECAMTransform = nullptr;

#include "numerictraits.h"
#include "pyramid.h"

namespace {

void usage()
{
    std::cerr
        << "usage:\n"
        << "  enfuse_pyramid_oracle dump-gaussian <aligned_image> <levels> <output_prefix>\n"
        << "  enfuse_pyramid_oracle dump-laplacian <aligned_image> <levels> <output_prefix>\n";
}

template <typename SKIPSMImagePyramidType, typename PyramidImageType>
void exportPyramidLocal(std::vector<PyramidImageType *> *v, const std::string &prefix, vigra::VigraTrueType)
{
    using PyramidValueType = typename PyramidImageType::value_type;

    for (unsigned int i = 0; i < v->size(); ++i)
    {
        char filename_buf[512];
        std::snprintf(filename_buf, sizeof(filename_buf), "%s%04u.tif", prefix.c_str(), i);

        vigra::UInt16Image out((*v)[i]->width(), (*v)[i]->height());
        vigra::omp::transformImage(
            srcImageRange(*((*v)[i])),
            destImage(out),
            vigra::linearRangeMapping(
                vigra::NumericTraits<PyramidValueType>::min(),
                vigra::NumericTraits<PyramidValueType>::max(),
                vigra::NumericTraits<vigra::UInt16>::min(),
                vigra::NumericTraits<vigra::UInt16>::max()));

        vigra::ImageExportInfo info(filename_buf);
        vigra::exportImage(srcImageRange(out), info);
    }
}

template <typename SKIPSMImagePyramidType, typename PyramidImageType>
void exportPyramidLocal(std::vector<PyramidImageType *> *v, const std::string &prefix, vigra::VigraFalseType)
{
    using PyramidVectorType = typename PyramidImageType::value_type;
    using PyramidValueType = typename PyramidVectorType::value_type;

    for (unsigned int i = 0; i < v->size(); ++i)
    {
        char filename_buf[512];
        std::snprintf(filename_buf, sizeof(filename_buf), "%s%04u.tif", prefix.c_str(), i);

        vigra::UInt16RGBImage out((*v)[i]->width(), (*v)[i]->height());
        vigra::omp::transformImage(
            srcImageRange(*((*v)[i])),
            destImage(out),
            vigra::linearRangeMapping(
                PyramidVectorType(vigra::NumericTraits<PyramidValueType>::min()),
                PyramidVectorType(vigra::NumericTraits<PyramidValueType>::max()),
                typename vigra::UInt16RGBImage::value_type(vigra::NumericTraits<vigra::UInt16>::min()),
                typename vigra::UInt16RGBImage::value_type(vigra::NumericTraits<vigra::UInt16>::max())));

        vigra::ImageExportInfo info(filename_buf);
        vigra::exportImage(srcImageRange(out), info);
    }
}

template <typename SKIPSMImagePyramidType, typename PyramidImageType>
void exportPyramidLocal(std::vector<PyramidImageType *> *v, const std::string &prefix)
{
    using PyramidIsScalar = typename vigra::NumericTraits<typename PyramidImageType::value_type>::isScalar;
    exportPyramidLocal<SKIPSMImagePyramidType, PyramidImageType>(v, prefix, PyramidIsScalar());
}

template <typename ImagePixelType>
int dumpGaussian(const std::string &image_path, unsigned levels, const std::string &prefix)
{
    using Traits = enblend::EnblendNumericTraits<ImagePixelType>;
    using ImageType = typename Traits::ImageType;
    using AlphaType = typename Traits::AlphaType;
    using ImagePyramidType = typename Traits::ImagePyramidType;
    using SKIPSMImagePixelType = typename Traits::SKIPSMImagePixelType;
    using SKIPSMAlphaPixelType = typename Traits::SKIPSMAlphaPixelType;

    vigra::ImageImportInfo info(image_path.c_str());
    ImageType image(info.size());
    AlphaType alpha(info.size());
    vigra::importImageAlpha(info, destImage(image), destImage(alpha));

    std::vector<ImagePyramidType *> *gp =
        enblend::gaussianPyramid<ImageType, AlphaType, ImagePyramidType,
                                 Traits::ImagePyramidIntegerBits, Traits::ImagePyramidFractionBits,
                                 SKIPSMImagePixelType, SKIPSMAlphaPixelType>(
            levels,
            false,
            srcImageRange(image),
            maskImage(alpha));

    exportPyramidLocal<SKIPSMImagePixelType, ImagePyramidType>(gp, prefix);

    for (auto *level : *gp)
    {
        delete level;
    }
    delete gp;
    return 0;
}

template <typename ImagePixelType>
int dumpLaplacian(const std::string &image_path, unsigned levels, const std::string &prefix)
{
    using Traits = enblend::EnblendNumericTraits<ImagePixelType>;
    using ImageType = typename Traits::ImageType;
    using AlphaType = typename Traits::AlphaType;
    using ImagePyramidType = typename Traits::ImagePyramidType;
    using SKIPSMImagePixelType = typename Traits::SKIPSMImagePixelType;
    using SKIPSMAlphaPixelType = typename Traits::SKIPSMAlphaPixelType;

    vigra::ImageImportInfo info(image_path.c_str());
    ImageType image(info.size());
    AlphaType alpha(info.size());
    vigra::importImageAlpha(info, destImage(image), destImage(alpha));

    std::vector<ImagePyramidType *> *lp =
        enblend::laplacianPyramid<ImageType, AlphaType, ImagePyramidType,
                                  Traits::ImagePyramidIntegerBits, Traits::ImagePyramidFractionBits,
                                  SKIPSMImagePixelType, SKIPSMAlphaPixelType>(
            prefix.c_str(),
            levels,
            false,
            srcImageRange(image),
            maskImage(alpha));

    exportPyramidLocal<SKIPSMImagePixelType, ImagePyramidType>(lp, prefix);

    for (auto *level : *lp)
    {
        delete level;
    }
    delete lp;
    return 0;
}

} // namespace

int main(int argc, char **argv)
{
    try
    {
        if (argc != 5)
        {
            usage();
            return 1;
        }

        const std::string subcommand(argv[1]);
        const std::string image_path(argv[2]);
        const unsigned levels = static_cast<unsigned>(std::stoul(argv[3]));
        const std::string prefix(argv[4]);
        if (subcommand == "dump-gaussian")
        {
            return dumpGaussian<vigra::RGBValue<vigra::UInt8, 0, 1, 2>>(image_path, levels, prefix);
        }
        if (subcommand == "dump-laplacian")
        {
            return dumpLaplacian<vigra::RGBValue<vigra::UInt8, 0, 1, 2>>(image_path, levels, prefix);
        }
        usage();
        return 1;
    }
    catch (const std::exception &err)
    {
        std::cerr << command << ": " << err.what() << '\n';
        return 1;
    }
}
