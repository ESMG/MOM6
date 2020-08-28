# Generated documentation

We use [Doxygen](http://www.doxygen.org/) for in-code documentation of APIs (i.e. arguments to subroutines/functions and
members of types).
The guide for using doxygen in MOM6 is hosted on the [MOM6 developer's wiki](https://github.com/NOAA-GFDL/MOM6/wiki/Doxygen).

You can preview documentation by running doxygen or sphinx.

## Sphinx based documentation

The full documentation can be generated locally with
```bash
make html >& _build/html_log.txt
```
which will generate html in `docs/_build/html/`. Start at `docs/_build/html/index.html`. This will also place log information
into the `_build` tree that is viewable.  Doxygen output is also available as `doxygen_log.txt`.

## Local web server

Python provides a way to quickly stand up a private web server for checking documentation. It requires knowledge of
the IP address if you are using a remote server, otherwise `localhost` should work.

You can start the server on any port. Port 8080 is shown here as an example.
```bash
python3 -m http.server 8080
```

After starting the server, you can browse to the known IP using `http://IP/` or if you are on the same
machine use `http://localhost/`.

## Doxygen generated HTML

The doxygen generated HTML can be obtained locally (and slightly more quickly) with
```bash
make nortd SPHINXBUILD=false
```
which will generate html in `docs/APIs/`. Start at `docs/APIs/index.html`. If doxygen is not already available this will install a
local copy of doxygen.

## Dependencies

If you do not have doxygen, to build a local version of the doxygen processor you will need the following packages:
- cmake
- g++ (or a c++ compiler)
- flex
- bison
- graphviz

(e.g. `apt-get install cmake g++ flex bison graphviz`)

If you are building the full generated sphinx documentation you will need the following packages in addition to those for doxygen above:
- libxml2-dev
- libxslt-dev (may also be called libxslt1-dev)

(e.g. `apt-get install libxml2-dev libxslt-dev`)

We strongly recommend using `python3` with its virtual environment and `pip3`.

(e.g. `apt-get install python3 python3-venv python3-pip`)

Before running sphinx (`make html`) you will need to issue:

```bash
pip install -r requirements.txt
```

You may need to use `pip3` to install requirements for python3.

Requirements currently look like:
- Cython (for machines that need to build future or numpy)
- doxygen 1.8.19
- sphinx 3.2.1mom6
- sphinx-rtd-theme
- sphinx-bibtex 1.0.0
- sphinx-fortran 1.1.1dev & numpy
- sphinxcontrib\_autodox-doxygen 0.6.1.dev6
- flint 0.0.1dev

### Latex/PDF generation

PDF generation requires the following packages
- texlive-latex-base
- texlive-latex-recommended
- texlive-latex-extra
- latexmk

## Credits

The sphinx documentation of MOM6 is made possible by modifications by [Angus Gibson](https://github.com/angus-g) to two packages, [sphinx-fortran](https://github.com/angus-g/sphinx-fortran) and [autodoc\_doxygen](https://github.com/angus-g/sphinxcontrib-autodoc_doxygen).

## Troubleshooting

### Latex Math

Good locations to test equations for both latex and MathJax:
- [LaTex Base](https://latexbase.com/)
- [MathJax](https://www.mathjax.org/#demo)

*eqnarray*
- Use of `\mbox{}` requires surrounding braces as in {\mbox{}}
- If a formula needs formatting using `&` you must use eqnarray
- MathJax does not handle backslashes (`\`) within `\mbox{}`
  - Wrong (ok in latex): `\mbox{nonpen\_SW}`
  - Correct: `\mbox{nonpen}\_\mbox{SW}`

*formula*
- Math elements within `\mbox{}` requires `$` escaping

## Install documentation pipeline

On a relatively bare system with the few dependencies as described above, you can install
a fairly stable documentation pipeline.

### doxygen

Download latest [source](https://www.doxygen.nl/download.html).  Latest is `doxygen-1.8.19.src.tar.gz`.

```bash
tar xzf doxygen-1.8.19.src.tar.gz
cd doxygen-1.8.19
mkdir build
cd build
cmake -G "Unix Makefiles" ..
make
sudo make install
```

Make install attempts to place the compiled version into /usr/local/bin.  You can link to a
specific executable within the virtual environment.   At this point we also recommend
renaming `doxygen` to `doxygen-1.8.19` within `/usr/local/bin`.

### Read the Docs

The [Read the Docs](https://readthedocs.org/) (RTD) site uses a virtual machine (VM) for processing documentation.  The VM is of
os architecture type x86\_64.  A doxygen binary can be compiled and included in our git repo
for use in ReadTheDocs.  The defualt doxygen in use is 1.8.13 which produces XML that does not work for our use.  We
supply a compiled binary version 1.8.19 that provide better XML.  However, there are still some shortcomings.

NOTE: Using modified python modules on RTD is possible through careful crafting of the requirements.txt file.  It is impossible to replace system binaries or compile code on RTD.  It is possible to ship replacement binaries that can be run from the repo.

### python3 virtual enviroment

Setup a virtual environment for processing:

```bash
python3 -m venv venv/mom6Doc
source venv/mom6Doc/bin/activate
# cd to the docs directory within the MOM6 repo
pip3 install -r requirements.txt
```

The `deactivate` command allows you to exit from the virtual environment.

### debugging

A useful commnad line tool for debugging sphinx and extensions is the python debugger.
Add the following line to stop to any portion of the python code to create a break
point.

```python
import pdb; pdb.set_trace()
```

Run `make html` without redirection to a log file.

## Example execution

The following example assumes a virtual environment as setup above using `mom6Doc`.
The same environment is possible using anaconda.

```
$ source venv/mom6Doc/bin/activate
(mom6Doc) $ cd docs
(mom6Doc) $ make clean
(mom6Doc) $ make html >& \_build/html\_log.txt
(mom6Doc) $ make latexpdf >& \_build/latex\_log.txt
```

The last command may appear to hang.  On error, latex will request input from the keyboard.
Press `R` and enter.  This will keep latex running to completion or stop after 100 errors
are reached.

Once the documentation is built, you can use a web browser to look around in the `_build`
directory.
