#!/bin/bash
# Set to -x to debug
set +x
# Parse arguments
# Ref: https://medium.com/@Drew_Stokes/bash-argument-parsing-54f3b81a6a8f

# Result upload command (-c)
UPLOAD_COMMAND=""
# Requested doxygen version (-d)
REQ_DOXYGEN_VER=""
# Verbose flag (-v)
VERBOSE_FLAG=0
# remote update (-r)
REMOTE_UPDATE=0
# local update (-l)
LOCAL_UPDATE=0
# Track errors
ARG_ERRORS=0

while (( "$#" )); do
  case "$1" in
    -r)
      REMOTE_UPDATE=1
      shift
      ;;
    -l)
      LOCAL_UPDATE=1
      shift
      ;;
    -v)
      VERBOSE_FLAG=1
      shift
      ;;
    -c)
      if [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
        UPLOAD_COMMAND=$2
        shift 2
      else
        echo "Error: Argument for $1 is missing" >&2
        exit 1
      fi
      ;;
    -d)
      if [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
        REQ_DOXYGEN_VER=$2
        shift 2
      else
        echo "Error: Argument for $1 is missing" >&2
        exit 1
      fi
      ;;
    *)
      # Unable to parse arguments
      ARG_ERRORS=1
      shift
      ;;
  esac
done
if [ "${ARG_ERRORS}" -ne "0" ]; then
  echo "Invalid argument(s).";
  exit 1;
fi
if [ "${VERBOSE_FLAG}" -ne "0" ]; then
  echo "Upload command:" ${UPLOAD_COMMAND}
  echo "Requested doxygen version:" ${REQ_DOXYGEN_VER}
  echo "Verbose flag:" ${VERBOSE_FLAG}
fi

# Set variables
BUILDDIR=_build
DOXYGEN_BINDIR=/usr/local/bin
DOXYGEN_VER=`doxygen -v`

# Detect virtual environment
VIRTENV=0
if [ "x${VIRTUAL_ENV}" != "x" ]; then
  # basename ${VIRTUAL_ENV}
  if [ -d ${VIRTUAL_ENV} ]; then
    if [ "${VERBOSE_FLAG}" -ne "0" ]; then
      echo "Found virtual environment:" ${VIRTUAL_ENV}
    fi
    VIRTENV=1
  fi
fi
if [ "${VIRTENV}" -ne "0" ]; then
  # if requested doxygen version does not match current
  # version, attempt to fix it in the virtual environment
  if [ "x${REQ_DOXYGEN_VER}" != "x" ]; then
    # Make sure requested version exists
    REQ_DOXYGEN=${DOXYGEN_BINDIR}/doxygen-${REQ_DOXYGEN_VER}
    if [ -e ${REQ_DOXYGEN} ]; then
      if [ "${REQ_DOXYGEN_VER}" != "${DOXYGEN_VER}" ]; then
        if [ "${VERBOSE_FLAG}" -ne "0" ]; then
          echo "Updating doxygen version to" ${REQ_DOXYGEN_VER}
        fi
        if [ -e ${VIRTUAL_ENV}/bin/doxygen ]; then
          rm ${VIRTUAL_ENV}/bin/doxygen
        fi
        ln -sf ${REQ_DOXYGEN} ${VIRTUAL_ENV}/bin/doxygen
      fi
    fi
  fi
fi

# Recheck doxygen version at this point
DOXYGEN_VER=`doxygen -v`
if [ "${VERBOSE_FLAG}" -ne "0" ]; then
  echo "Doxygen verison =" ${DOXYGEN_VER}
fi

# A cleanup operation needs to take place before any sphinx-build
# run to collect all the appropriate error messages.  Otherwise
# it will utilize cached data.

# Doxygen cleanup
#rm -rf xml MOM6.tags api/generated
# Sphinx cleanup of _build
make clean

# Build html
if [ "${VERBOSE_FLAG}" -ne "0" ]; then
  echo "Building doxygen + sphinx html"
fi
make html >& ${BUILDDIR}/html_log.txt

# TODO: Build this into conf.py
# Doxygen cleanup
#rm -rf xml MOM6.tags api/generated
# Sphinx cleanup
#make clean

# Build pdf
if [ "${VERBOSE_FLAG}" -ne "0" ]; then
  echo "Building sphinx latex (if hung press R or Q and ENTER)"
fi

make latexpdf >& ${BUILDDIR}/latex_log.txt
# Build doxygen pdf
if [ -d "${BUILDDIR}/doxygen_latex" ]; then
  if [ "${VERBOSE_FLAG}" -ne "0" ]; then
    echo "Building pdf in doxygen_latex (if hung press R or Q and ENTER)"
  fi
  make -C ${BUILDDIR}/doxygen_latex >& ${BUILDDIR}/doxygen_latex_log.txt
fi

# Remote update
if [ "${REMOTE_UPDATE}" -ne "0" ]; then
  if [ "${VERBOSE_FLAG}" -ne "0" ]; then
    echo "Uploading to remote website"
  fi
  rsync --del -ru _build cermak@recon.lccllc.info:html/MOM6/esmgNew/
  rsync --del -ru xml cermak@recon.lccllc.info:html/MOM6/esmgNew/
fi

# Local update
if [ "${LOCAL_UPDATE}" -ne "0" ]; then
  TARGET=/var/www/html/MOM6/local/_build-${DOXYGEN_VER}
  if [ -d ${TARGET} ]; then
    if [ "${VERBOSE_FLAG}" -ne "0" ]; then
      echo "Results copied to ${TARGET}"
    fi
    rm -rf ${TARGET}
    cp -a _build ${TARGET}
    cp -a xml ${TARGET}/
    if [ "x${DOXYGEN_VER}" == "x1.8.19" ]; then
      TARGET=/var/www/html/MOM6/esmgNew/_build
      if [ -d ${TARGET} ]; then
        if [ "${VERBOSE_FLAG}" -ne "0" ]; then
          echo "Results copied to ${TARGET}"
        fi
        rm -rf ${TARGET}
        cp -a _build ${TARGET}
        cp -a xml ${TARGET}/
      else
        echo "Target directory not found:" ${TARGET}
        exit 1
      fi
    fi
  else
    echo "Target directory not found:" ${TARGET}
    exit 1
  fi
fi
