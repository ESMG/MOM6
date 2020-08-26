======
README
======

General materials and modifications needed to render the MOM6 manual.

References
----------

* Read the Docs `markup demo <https://sphinx-rtd-theme.readthedocs.io/en/latest/demo/demo.html>`_
* Read the Docs `raw markup <https://raw.githubusercontent.com/readthedocs/sphinx_rtd_theme/master/docs/demo/demo.rst>`_
* Sphinx `reStructuredText Primer <https://www.sphinx-doc.org/en/master/usage/restructuredtext/basics.html>`_

Math
----

This is a test. Here is an equation:
:math:`X_{0:5} = (X_0, X_1, X_2, X_3, X_4)`.
Here is another:

.. math::
    :label: This is a label

    \nabla^2 f =
    \frac{1}{r^2} \frac{\partial}{\partial r}
    \left( r^2 \frac{\partial f}{\partial r} \right) +
    \frac{1}{r^2 \sin \theta} \frac{\partial f}{\partial \theta}
    \left( \sin \theta \, \frac{\partial f}{\partial \theta} \right) +
    \frac{1}{r^2 \sin^2\theta} \frac{\partial^2 f}{\partial \phi^2}

You can add a link to equations like the one above :eq:`This is a label` by using ``:eq:``.

Notes for MOM6
--------------

When we parse a ``_*.dox`` file.  We have to scan every math block for embedded ``\label{}``
commands and place them above the formula so they can be properly referenced within the
html.

The entire ``\label{}`` should not be broken up by a newline.

We will want to ensure the math block are untouched going to the latex processor.

We may need to provide two outputs: html and latex versions?

Sphinx
------

The latest sphinx needs this patch to fix extremely long author strings.  Will need a hack
for RTD.  This should be easy to do.

.. code-block:: python
    :linenos:
    :emphasize-lines: 9

    diff --git a/sphinx/builders/latex/__init__.py b/sphinx/builders/latex/__init__.py
    index c24e87a13..3f71be9b0 100644
    --- a/sphinx/builders/latex/__init__.py
    +++ b/sphinx/builders/latex/__init__.py
    @@ -446,6 +446,7 @@ def default_latex_documents(config: Config) -> List[Tuple[str, str, str, str, st
         """ Better default latex_documents settings. """
         project = texescape.escape(config.project, config.latex_engine)
         author = texescape.escape(config.author, config.latex_engine)
    +    author = author.replace(', ', '\\and ').replace(' and ', '\\and and ')
         return [(config.master_doc,
                  make_filename_from_project(config.project) + '.tex',
                  texescape.escape_abbr(project),

We modifiy to sphinx/util/math.py to make sure eqnarrays
are not wrapped.

.. code-block:: python
    :linenos:

    def wrap_displaymath(text: str, label: str, numbering: bool) -> str:
        def is_equation(part: str) -> str:
            return part.strip()

        if label is None:
            labeldef = ''
        else:
            labeldef = r'\label{%s}' % label
            numbering = True

        parts = list(filter(is_equation, text.split('\n\n')))
        equations = []

        #import pdb; pdb.set_trace()

        # do not wrap eqnarray with anything
        eqnarray_flag = False
        for part in parts:
            if part.find('begin{eqnarray}') >= 0:
                eqnarray_flag = True

        if len(parts) == 0:
            return ''
        elif len(parts) == 1:
            if numbering:
                begin = r'\begin{equation}' + labeldef
                end = r'\end{equation}'
            else:
                begin = r'\begin{equation*}' + labeldef
                end = r'\end{equation*}'
            if eqnarray_flag:
                equations.append('%s\n' % parts[0])
            else:
                equations.append('\\begin{split}%s\\end{split}\n' % parts[0])
        else:
            if numbering:
                begin = r'\begin{align}%s\!\begin{aligned}' % labeldef
                end = r'\end{aligned}\end{align}'
            else:
                begin = r'\begin{align*}%s\!\begin{aligned}' % labeldef
                end = r'\end{aligned}\end{align*}'
            for part in parts:
                equations.append('%s\\\\\n' % part.strip())

        if eqnarray_flag:
            begin = r''
            end = r''

        return '%s\n%s%s' % (begin, ''.join(equations), end)
