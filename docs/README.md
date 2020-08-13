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
- libxslt-dev

(e.g. `apt-get install libxml2-dev libxslt-dev`)

We strongly recommend using `python3` with its virtual environment and `pip3`.

(e.g. `apt-get install python3 python3-venv python3-pip`)

Before running sphinx (`make html`) you will need to issue:

```bash
pip install -r requirements.txt
```

You may need to use `pip3` to install requirements for python3.

Requirements currently lock sphinx to version 1.5.  The latest version of doxygen is 1.8.18.

## Credits

The sphinx documentation of MOM6 is made possible by modifications by [Angus Gibson](https://github.com/angus-g) to two packages, [sphinx-fortran](https://github.com/angus-g/sphinx-fortran) and [autodoc_doxygen](https://github.com/angus-g/sphinxcontrib-autodoc_doxygen).

## Troubleshooting

### sphinxcontrib.autodoc_doxygen

The value `node.text` can be `None` when passed to `visit_image`.  Edit `site-packages/sphinxcontrib/autodoc_doxygen/xmlutils.py`:

```python
    def visit_image(self, node):

        type = None
        if node.text == None and node.tag == 'image':
            type = 'image'

        if type == None and len(node.text.strip()):
            type = 'figure'
        else:
            type = 'image'
```

### MathJax

Only one `\label` is supported per large formula block surrounded by `\[` and `\]`.  At this point, we are not
certain the references from embedded formulas are working.

## Install documentation pipeline

On a relatively bare system with the few dependencies as described above, you can install
a fairly stable documentation pipeline.

### doxygen

Download latest [source](https://www.doxygen.nl/download.html).  Latest is `doxygen-1.8.19.src.tar.gz`.

```bash
tar xzf doxygen-1.8.19.src.tar.gz
cd doxygen-1.8.18
mkdir build
cd build
cmake -G "Unix Makefiles" ..
make
sudo make install
```

Make install attempts to place the compiled version into /usr/local/bin.  You can link to a
specific executable within the virtual environment.   At this point we also recommend
renaming `doxygen` to `doxygen-1.8.19` within `/usr/local/bin`.

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
Add the following line to stop the program at that point for debugging.

```python
import pdb; pdb.set_trace()
```

## Example execution

This assumes use of the example above.

```
$ source venv/mom6Doc/bin/activate
(mom6Doc) $ cd docs
(mom6Doc) $ make clean
(mom6Doc) $ make html >& _build/html_log.txt
# If you have latex installed, you can build the pdf
(mom6Doc) $ make latexpdf >& _build/latex_log.txt
```

The last command may appear to hang.  On error, latex will request input from the keyboard.
Press `R` and enter.  This will keep latex running to completion or stop after 100 errors
are reached.

Once the documentation is built, you can use a web browser to look around in the `_build`
directory.
