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

# -- Custom configuration values and roles -----------------------------------
from docutils import nodes

def setup(app):
    app.add_config_value('sphinx_build_mode', '', 'env')
    app.add_role('latex', latexPassthru)
def latexPassthru(name, rawtext, text, lineno, inliner, options={}, content=[]):
    node = nodes.raw('',rawtext[8:-1],format='latex')

    return [node],[]

# -- Clean out generated content ---------------------------------------------

import shutil, os, sys

# Running build-sphinx for html and latexpdf requires a rebuild of auto
# generated content.  Label and reference wiring are quite different to
# try and support html/MathJax.

if os.path.isdir("api/generated"):
    shutil.rmtree("api/generated/")

if os.path.isdir("xml"):
    shutil.rmtree("xml")

if os.path.isfile("MOM6.tags"):
    os.unlink("MOM6.tags")

# -- Auto detect runs on readthedocs.org -------------------------------------

import subprocess
from subprocess import check_output
running_on_rtd = False

# Get current doxygen version
out = check_output(["doxygen","-v"])
doxygen_version = out.strip().decode('utf-8')
print("Reported doxygen version = %s" % (doxygen_version))

# Detect if we are running on readthedocs.org
out = check_output(["pwd"])
out = out.strip().decode('utf-8')
# On RTD you would see something like:
# /home/docs/checkouts/readthedocs.org/user_builds/mom6devesmgnew/checkouts/latest/docsNew
if out.find('readthedocs.org') >= 0:
    running_on_rtd = True

# This allows us to run locally as if we are running on RTD
##
if not(running_on_rtd) and doxygen_version == '1.8.13':
    print("WARNING: Local run using RTD.")
    running_on_rtd = True

# Automatic switching of doxygen configuration files 
if running_on_rtd:
    subprocess.call('doxygen doxygen_rtd.conf', shell=True)
else:
    subprocess.call('doxygen doxygen.conf', shell=True)

# -- Determine how sphinx-build was called -----------------------------------

# Determine how sphinx-build called.  This is needed to drive
sphinx_build_mode = None
# hunt for -M (or -b) and then we want the argument after it
if '-M' in sys.argv:
    idx = sys.argv.index('-M')
    sphinx_build_mode = sys.argv[idx+1]
    print("Sphinx-build mode: %s" % (sphinx_build_mode))
elif '-b' in sys.argv:
    idx = sys.argv.index('-b')
    sphinx_build_mode = sys.argv[idx+1]
    print("Sphinx-build mode: %s" % (sphinx_build_mode))

# -- Project information -----------------------------------------------------

project = 'MOM6'
copyright = ('2017-2020, %s developers' % (project))
# NOTE: Use commas only between authors.
# Sphinx latex processor automatically changes (,) to (\and).
# Requires: https://github.com/sphinx-doc/sphinx/issues/6875
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
	'sphinx.ext.ifconfig',
        'sphinxfortran.fortran_domain',
        'sphinxfortran.fortran_autodoc',
]

# Add any paths that contain templates here, relative to this directory.
templates_path = ['_templates']

# List of patterns, relative to source directory, that match files and
# directories to ignore when looking for source files.
# This pattern also affects html_static_path and html_extra_path.
exclude_patterns = ['_build', 'Thumbs.db', '.DS_Store']

# -- Options for Latex output ------------------------------------------------

# RTD systematically builds latex and latexpdf versions automatically
latex_engine = 'pdflatex'

# -- Options for HTML output -------------------------------------------------

# The theme to use for HTML and HTML Help pages.  See the documentation for
# a list of builtin themes.
#
html_theme = 'sphinx_rtd_theme'

# Add any paths that contain custom static files (such as style sheets) here,
# relative to this directory. They are copied after the builtin static files,
# so a file named "default.css" will overwrite the builtin "default.css".
html_static_path = ['_static']

html_last_updated_fmt = '%b %d, %Y'

# -- Options for Read the Docs theme -----------------------------------------
# https://sphinx-rtd-theme.readthedocs.io/en/latest/configuring.html

html_theme_options = {
  'display_version': True,
}

# -- Options for sphinxcontrib.autodoc_doxygen ------------------------------
doxygen_xml = 'xml'

# This is required to generate the pages from _*.dox files
autosummary_generate = [
        'api/pages.rst',
        'api/modules.rst',
]

# -- Options for sphinxfortran ----------------------------------------------
autodoc_default_flags = ['members', 'undoc-members', 'private-members', 'show-inheritance']
