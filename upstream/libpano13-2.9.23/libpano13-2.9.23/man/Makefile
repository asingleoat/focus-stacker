# FIXME this needs to be integrated with CMake
#
PACKAGE='LIBPANO13 TOOLS'
PACKAGE_VERSION=2.9.22

man : panoinfo.1 PTAInterpolate.1 PTblender.1 PTcrop.1 PTinfo.1 PTmasker.1 PTmender.1 PToptimizer.1 PTroller.1 PTtiff2psd.1 PTtiffdump.1 PTuncrop.1

%.1: %.pod
	pod2man --center $(PACKAGE) --release $(PACKAGE_VERSION) $< $@
