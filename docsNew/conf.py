# Configuration file for the Sphinx documentation builder.
#
# This file only contains a selection of the most common options. For a full
# list see the documentation:
# https://www.sphinx-doc.org/en/master/usage/configuration.html

# -- Path setup --------------------------------------------------------------

# If extensions (or modules to document with autodoc) are in another directory,
# add these directories to sys.path here. If the directory is relative to the
# documentation root, use os.path.abspath to make it absolute, like shown here.
#
# import os
# import sys
# sys.path.insert(0, os.path.abspath('.'))

import subprocess, os, sys
from subprocess import check_output
doxygen_version='1.8.19'
running_on_rtd=False

# debugging
#subprocess.call('hostname', shell=True)
#subprocess.call('uname -a', shell=True)
#subprocess.call('apt list', shell=True)

# Detect if we are running on readthedocs.org
out = check_output(["pwd"])
out = out.strip().decode('utf-8')
print("*>",out)
# On RTD you would see something like:
# /home/docs/checkouts/readthedocs.org/user_builds/mom6devesmgnew/checkouts/latest/docsNew
if out.find('readthedocs.org') >= 0:
    running_on_rtd = True

# Attempt to do some setup on RTD
if running_on_rtd:
    # Get current doxygen version and path
    out = check_output(["doxygen","-v"])
    out = out.strip().decode('utf-8')
    print("*>",out)
    out = check_output(["pwd"])
    out = out.strip().decode('utf-8')
    print("*>",out)
    out = check_output(["which","doxygen"])
    out = out.strip().decode('utf-8')
    print("*>",out)
    subprocess.call('sudo apt-get -y install cmake', shell=True)
    out = check_output(["which","cmake"])
    out = out.strip().decode('utf-8')
    print("*>",out)
    # If we do not have the doxygen version we want, build it
    subprocess.call('wget -q http://doxygen.nl/files/doxygen-1.8.19.src.tar.gz', shell=True)
    subprocess.call('tar xzf doxygen-1.8.19.src.tar.gz', shell=True)
    #subprocess.call('ls -l', shell=True)
    #os.chdir('doxygen-1.8.19')
    #os.mkdir('build')
    #os.chdir('build')
    subprocess.call('(cd doxygen-1.8.19;cmake -G "Unix Makefiles" ..)', shell=True)
    #subprocess.call('ls -lR', shell=True)
    #os.chdir('../..')

# Automatic switching of doxygen configuration files 
if running_on_rtd:
  subprocess.call('doxygen doxygen_rtd.conf', shell=True)
else:
  subprocess.call('doxygen doxygen.conf', shell=True)

# -- Project information -----------------------------------------------------

project = 'MOM6'
copyright = ('2017-2020, %s developers' % (project))
author = u'Alistair Adcroft, Robert Hallberg, Stephen Griffies, Matthew Harrison, Brandon Reichl, Niki Zadeh, John Krasting, Nic Hannah'

# The full version, including alpha/beta/rc tags
release = '0.0'

# -- General configuration ---------------------------------------------------

# Add any Sphinx extension module names here, as strings. They can be
# extensions coming with Sphinx (named 'sphinx.ext.*') or your custom
# ones.
extensions = [
        'sphinxcontrib.bibtex',
        'sphinxcontrib.autodoc_doxygen',
]

# Add any paths that contain templates here, relative to this directory.
templates_path = ['_templates']

# List of patterns, relative to source directory, that match files and
# directories to ignore when looking for source files.
# This pattern also affects html_static_path and html_extra_path.
exclude_patterns = ['_build', 'Thumbs.db', '.DS_Store']

# -- Options for HTML output -------------------------------------------------

# The theme to use for HTML and HTML Help pages.  See the documentation for
# a list of builtin themes.
#
html_theme = 'sphinx_rtd_theme'

# Add any paths that contain custom static files (such as style sheets) here,
# relative to this directory. They are copied after the builtin static files,
# so a file named "default.css" will overwrite the builtin "default.css".
html_static_path = ['_static']

# -- Options for autodoc_doxygen --------------------------------------------
doxygen_xml = 'xml'
autosummary_generate = [
        'api/pages.rst',
]
