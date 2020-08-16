# Variables
BUILDDIR=_build

# Doxygen cleanup
rm -rf xml MOM6.tags api/generated
# Sphinx cleanup
make clean
# Build html
make html >& ${BUILDDIR}/html_log.txt
# Build pdf
make latexpdf >& ${BUILDDIR}/latex_log.txt
# Build doxygen pdf
make -C ${BUILDDIR}/doxygen_latex >& ${BUILDDIR}/doxygen_latex_log.txt

if [ "${1}" == "upload" ]; then
	rsync --del -ru _build cermak@recon.lccllc.info:html/MOM6/esmgNew/
fi
