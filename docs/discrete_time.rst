Time Discretization
===================

In MOM6, it is possible to have at least four different timesteps: the barotropic
timestep, the baroclinic (momentum dynamics) timestep, the tracer timestep, and the
remapping interval. There can also be a forcing timestep on which model coupling can
occur.

.. toctree::
    :maxdepth: 2

    api/generated/pages/Barotropic_Momentum_Equations
    api/generated/pages/Baroclinic_Momentum_Equations
    api/generated/pages/ALE_Timestep
