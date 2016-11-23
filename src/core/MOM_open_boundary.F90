!> Controls where open boundary conditions are applied
module MOM_open_boundary

! This file is part of MOM6. See LICENSE.md for the license.

use MOM_cpu_clock, only : cpu_clock_id, cpu_clock_begin, cpu_clock_end, CLOCK_ROUTINE
use MOM_diag_mediator, only : diag_ctrl, time_type
use MOM_domains, only : pass_var, pass_vector
use MOM_domains, only : To_All, SCALAR_PAIR, CGRID_NE
use MOM_error_handler, only : MOM_mesg, MOM_error, FATAL, WARNING
use MOM_file_parser, only : get_param, log_version, param_file_type, log_param
use MOM_grid, only : ocean_grid_type
use MOM_dyn_horgrid, only : dyn_horgrid_type
use MOM_io, only : EAST_FACE, NORTH_FACE
use MOM_io, only : slasher, read_data, field_size
use MOM_obsolete_params, only : obsolete_logical, obsolete_int, obsolete_real, obsolete_char
use MOM_string_functions, only : extract_word, remove_spaces
use MOM_tracer_registry, only : add_tracer_OBC_values, tracer_registry_type
use MOM_variables, only : thermo_var_ptrs
use time_interp_external_mod, only : init_external_field, time_interp_external
use MOM_remapping, only : remappingSchemesDoc, remappingDefaultScheme, remapping_CS, initialize_remapping
use MOM_remapping, only : remapping_core_h, end_remapping
use MOM_regridding, only : regridding_CS
use MOM_verticalGrid, only : verticalGrid_type

implicit none ; private

#include <MOM_memory.h>

public open_boundary_config
public open_boundary_init
public open_boundary_query
public open_boundary_end
public open_boundary_impose_normal_slope
public open_boundary_impose_land_mask
public radiation_open_bdry_conds
public set_Flather_data
public update_obc_segment_data

integer, parameter, public :: OBC_NONE = 0, OBC_SIMPLE = 1, OBC_WALL = 2
integer, parameter, public :: OBC_FLATHER = 3
integer, parameter, public :: OBC_RADIATION = 4
integer, parameter, public :: OBC_DIRECTION_N = 100 !< Indicates the boundary is an effective northern boundary
integer, parameter, public :: OBC_DIRECTION_S = 200 !< Indicates the boundary is an effective southern boundary
integer, parameter, public :: OBC_DIRECTION_E = 300 !< Indicates the boundary is an effective eastern boundary
integer, parameter, public :: OBC_DIRECTION_W = 400 !< Indicates the boundary is an effective western boundary
integer, parameter         :: MAX_OBC_FIELDS = 100  !< Maximum number of data fields needed for OBC segments


type, public :: OBC_segment_data_type
  integer :: fid                                ! handle from FMS associated with segment data on disk
  integer :: fid_dz                             ! handle from FMS associated with segment thicknesses on disk
  character(len=8)                :: name       ! a name identifier for the segment data 
  real, dimension(:,:,:), pointer :: buffer_src ! buffer for segment data on the model interpolated to 
                                                ! horizontal grid faces.
  integer                         :: nk_src     ! Number of vertical levels in the source data
  real, dimension(:,:,:), pointer :: dz_src     ! vertical grid cell spacing of the incoming segment data (m)
  real, dimension(:,:,:), pointer :: buffer_dst ! buffer src data remapped to the target vertical grid
end type OBC_segment_data_type

type, public :: OBC_segment_type
  logical :: Flather        !< If true, applies Flather + Chapman radiation of barotropic gravity waves.
  logical :: radiation      !< If true, 1D Orlanksi radiation boundary conditions are applied.
                            !! If False, a gradient condition is applied.
  logical :: oblique        !< Oblique waves supported at radiation boundary.
  logical :: nudged         !< Optional supplement to radiation boundary.
  logical :: specified      !< Boundary fixed to external value.
  logical :: gradient       !< Zero gradient at boundary.
  logical :: values_needed  !< Whether or not baroclinic OBC fields are needed.
  logical :: legacy         !< Old code for tangential BT velocities.
  integer :: direction      !< Boundary faces one of the four directions.
  type(OBC_segment_data_type), dimension(:), pointer :: field   !<  OBC data
  integer :: num_fields !< number of OBC data fields (e.g. u_normal,u_parallel and eta for Flather)
  character(len=8), dimension(:), pointer :: field_names !< field names for this segment
  integer :: Is_obc         !< i-indices of boundary segment.
  integer :: Ie_obc         !< i-indices of boundary segment.
  integer :: Js_obc         !< j-indices of boundary segment.
  integer :: Je_obc         !< j-indices of boundary segment.
  real :: Tnudge_in         !< Inverse nudging timescale on inflow (1/s).
  real :: Tnudge_out        !< Inverse nudging timescale on outflow (1/s).
end type OBC_segment_type

!> Open-boundary data
type, public :: ocean_OBC_type
  integer :: number_of_segments = 0 !< The number of open-boundary segments.
  logical :: Flather_u_BCs_exist_globally = .false.   !< True if any zonal velocity points
                                                      !! in the global domain use Flather BCs.
  logical :: Flather_v_BCs_exist_globally = .false.   !< True if any meridional velocity points
                                                      !! in the global domain use Flather BCs.
  logical :: nudged_u_BCs_exist_globally = .false.    !< True if any velocity points in the
                                                      !! global domain use nudged BCs.
  logical :: nudged_v_BCs_exist_globally = .false.    !< True if any velocity points in the
                                                      !! global domain use nudged BCs.
  logical :: specified_u_BCs_exist_globally = .false. !< True if any zonal velocity points
                                                      !! in the global domain use specified BCs.
  logical :: specified_v_BCs_exist_globally = .false. !< True if any meridional velocity points
                                                      !! in the global domain use specified BCs.
  real :: g_Earth
  ! Properties of the segments used.
  type(OBC_segment_type), pointer, dimension(:) :: &
    OBC_segment_number => NULL()   !< List of segment objects.
  ! Which segment object describes the current point.
  integer, pointer, dimension(:,:) :: &
    OBC_segment_u => NULL(), &   !< Segment number of u-points.
    OBC_segment_v => NULL()      !< Segment number of v-points.
  ! The following apply at points with OBC_kind_[uv] = OBC_FLATHER.
  real, pointer, dimension(:,:,:) :: &
    rx_old_u => NULL(), &  !< The rx_old_u value for radiation coeff for u-velocity in x-direction
    ry_old_v => NULL(), &  !< The ry_old_v value for radiation coeff for v-velocity in y-direction
    rx_old_h => NULL(), &  !< The rx_old_h value for radiation coeff for layer thickness h in x-direction
    ry_old_h => NULL()     !< The ry_old_h value for radiation coeff for layer thickness h in y-direction

  !   The following can be used to specify the outer-domain values of the
  ! surface height and barotropic velocity.  If these are not allocated, the
  ! default with Flather boundary conditions is the same as if they were
  ! filled with zeros.  With simple OBCs, these should not be allocated.
  real, pointer, dimension(:,:) :: &
    ubt_outer => NULL(), &    !< The u-velocity in the outer domain, in m s-1.
    vbt_outer => NULL(), &    !< The v-velocity in the outer domain, in m s-1.
    eta_outer_u => NULL(), &  !< The SSH anomaly in the outer domain, in m or kg m-2.
    eta_outer_v => NULL()     !< The SSH anomaly in the outer domain, in m or kg m-2.

  ! The following apply at points with OBC_kind_[uv] = OBC_SIMPLE and/or
  ! if nudging is turned on.
  real, pointer, dimension(:,:,:) :: &
    u => NULL(), &  !< The prescribed values of the zonal velocity (u) at OBC points.
    v => NULL(), &  !< The prescribed values of the meridional velocity (v) at OBC points.
    uh => NULL(), & !< The prescribed values of the zonal volume transport (uh) at OBC points.
    vh => NULL()    !< The prescribed values of the meridional volume transport (vh) at OBC points.

  ! The following parameters are used in the baroclinic radiation code:
  real :: gamma_uv !< The relative weighting for the baroclinic radiation
                   !! velocities (or speed of characteristics) at the
                   !! new time level (1) or the running mean (0) for velocities.
                   !! Valid values range from 0 to 1, with a default of 0.3.
  real :: gamma_h  !< The relative weighting for the baroclinic radiation
                   !! velocities (or speed of characteristics) at the
                   !! new time level (1) or the running mean (0) for thicknesses.
                   !! Valid values range from 0 to 1, with a default of 0.2.
  real :: rx_max   !< The maximum magnitude of the baroclinic radiation
                   !! velocity (or speed of characteristics), in m s-1.  The
                   !! default value is 10 m s-1.
  logical :: OBC_pe !< Is there an open boundary on this tile?
  logical :: update_OBC = .false. !< Is the open boundary info going to get updated?
  character(len=200) :: OBC_values_config
  type(remapping_CS), pointer         :: remap_CS   ! ALE remapping control structure for segments only
end type ocean_OBC_type

integer :: id_clock_pass

character(len=40)  :: mod = "MOM_open_boundary" ! This module's name.
! This include declares and sets the variable "version".
#include "version_variable.h"

contains

!> Enables OBC module and reads configuration parameters
!> This routine is called from MOM_initialize_fixed which
!> occurs before the initialization of the vertical coordinate
!> and ALE_init.  Therefore segment data are not fully initialized
!> here. The remainder of the segment data are initialized in a
!> later call to update_open_boundary_data

subroutine open_boundary_config(G, param_file, OBC)
  type(dyn_horgrid_type),  intent(in)    :: G !< Ocean grid structure
  type(param_file_type),   intent(in)    :: param_file !< Parameter file handle
  type(ocean_OBC_type),    pointer       :: OBC !< Open boundary control structure
  ! Local variables
  integer :: l ! For looping over segments
  character(len=15) :: segment_param_str ! The run-time parameter name for each segment
  character(len=100) :: segment_str ! The contents (rhs) for parameter "segment_param_str"

  allocate(OBC)

  call log_version(param_file, mod, version, "Controls where open boundaries are located, what "//&
                 "kind of boundary condition to impose, and what data to apply, if any.")
  call get_param(param_file, mod, "OBC_NUMBER_OF_SEGMENTS", OBC%number_of_segments, &
                 "The number of open boundary segments.", &
                 default=0)
  call get_param(param_file, mod, "G_EARTH", OBC%g_Earth, &
                 "The gravitational acceleration of the Earth.", &
                 units="m s-2", default = 9.80)
  if (OBC%number_of_segments > 0) then
    ! Allocate everything
    allocate(OBC%OBC_segment_number(0:OBC%number_of_segments))
    do l=0,OBC%number_of_segments
      OBC%OBC_segment_number(l)%Flather = .false.
      OBC%OBC_segment_number(l)%radiation = .false.
      OBC%OBC_segment_number(l)%oblique = .false.
      OBC%OBC_segment_number(l)%nudged = .false.
      OBC%OBC_segment_number(l)%specified = .false.
      OBC%OBC_segment_number(l)%gradient = .false.
      OBC%OBC_segment_number(l)%values_needed = .false.
      OBC%OBC_segment_number(l)%legacy = .false.
      OBC%OBC_segment_number(l)%direction = OBC_NONE
      OBC%OBC_segment_number(l)%Tnudge_in = 0.0
      OBC%OBC_segment_number(l)%Tnudge_out = 0.0
    enddo
    allocate(OBC%OBC_segment_u(G%IsdB:G%IedB,G%jsd:G%jed)) ; OBC%OBC_segment_u(:,:) = OBC_NONE
    allocate(OBC%OBC_segment_v(G%isd:G%ied,G%JsdB:G%JedB)) ; OBC%OBC_segment_v(:,:) = OBC_NONE

    do l = 1, OBC%number_of_segments
      write(segment_param_str(1:15),"('OBC_SEGMENT_',i3.3)") l
      call get_param(param_file, mod, segment_param_str, segment_str, &
                   "Documentation needs to be dynamic?????", &
                   fail_if_missing=.true.)
      segment_str = remove_spaces(segment_str)
      if (segment_str(1:2) == 'I=') then
        call setup_u_point_obc(OBC, G, segment_str, l)
      elseif (segment_str(1:2) == 'J=') then
        call setup_v_point_obc(OBC, G, segment_str, l)
      else
        call MOM_error(FATAL, "MOM_open_boundary.F90, open_boundary_config: "//&
                       "Unable to interpret "//segment_param_str//" = "//trim(segment_str))
      endif
    enddo

    call initialize_segment_data(OBC, param_file)
  endif

  ! Safety check
  if ((OBC%Flather_u_BCs_exist_globally .or. OBC%Flather_v_BCs_exist_globally) .and. &
      .not.G%symmetric ) call MOM_error(FATAL, &
                 "MOM_open_boundary, open_boundary_config: "//&
                 "Symmetric memory must be used when using Flather OBCs.")

  if (.not.(OBC%specified_u_BCs_exist_globally .or. OBC%specified_v_BCs_exist_globally .or. &
            OBC%Flather_u_BCs_exist_globally .or. OBC%Flather_v_BCs_exist_globally)) then
    ! No open boundaries have been requested
    call open_boundary_dealloc(OBC)
  endif

end subroutine open_boundary_config

subroutine initialize_segment_data(OBC, PF)
  type(ocean_OBC_type), intent(inout) :: OBC
  type(param_file_type), intent(in)   :: PF

  integer :: num_segs,n,m,num_fields
  character(len=256) :: segstr, filename
  character(len=20)  :: segnam,suffix
  character(len=32)  :: varnam, fieldname
  real               :: value
  integer, dimension(4) :: siz
  integer            :: orient
  character(len=32), dimension(MAX_OBC_FIELDS) :: fields  ! segment field names
  character(len=128) :: inputdir
  type(OBC_segment_type), pointer, dimension(:) :: OBC_segments ! pointer to segment type list
  character(len=32)  :: remappingScheme
  logical :: check_reconstruction, check_remapping, force_bounds_in_subcell

  num_segs = OBC%number_of_segments

  ! There is a problem with the order of the OBC initialization
  ! with respect to ALE_init. Currently handling this by copying the
  ! param file so that I can use it later in step_MOM in order to finish
  ! initializing segments on the first step.


  call get_param(PF, mod, "INPUTDIR", inputdir, default=".")
  inputdir = slasher(inputdir)
  
  call get_param(PF, mod, "REMAPPING_SCHEME", remappingScheme, &
          "This sets the reconstruction scheme used\n"//&
          "for vertical remapping for all variables.\n"//&
          "It can be one of the following schemes:\n"//&
          trim(remappingSchemesDoc), default=remappingDefaultScheme)
  call get_param(PF, mod, "FATAL_CHECK_RECONSTRUCTIONS", check_reconstruction, &
          "If true, cell-by-cell reconstructions are checked for\n"//&
          "consistency and if non-monotonicty or an inconsistency is\n"//&
          "detected then a FATAL error is issued.", default=.false.)
  call get_param(PF, mod, "FATAL_CHECK_REMAPPING", check_remapping, &
          "If true, the results of remapping are checked for\n"//&
          "conservation and new extrema and if an inconsistency is\n"//&
          "detected then a FATAL error is issued.", default=.false.)
  call get_param(PF, mod, "REMAP_BOUND_INTERMEDIATE_VALUES", force_bounds_in_subcell, &
          "If true, the values on the intermediate grid used for remapping\n"//&
          "are forced to be bounded, which might not be the case due to\n"//&
          "round off.", default=.false.)
  
  allocate(OBC%remap_CS)
  call initialize_remapping(OBC%remap_CS, remappingScheme, boundary_extrapolation = .false., &
       check_reconstruction=check_reconstruction, &
       check_remapping=check_remapping, force_bounds_in_subcell=force_bounds_in_subcell)


  OBC_segments => OBC%OBC_segment_number(1:num_segs)

  do n=1, num_segs
     write(segnam,"('OBC_SEGMENT_',i3.3,'_DATA')") n
     write(suffix,"('_segment_',i3.3)") n
     call get_param(PF, mod, segnam, segstr)
!     print *,'n, segstr=',n, trim(segstr)
     call parse_segment_data_str(trim(segstr),fields=fields, num_fields=num_fields)

     allocate(OBC_segments(n)%field(num_fields))

     if (OBC_segments(n)%Flather) then
        if (num_fields /= 3) call MOM_error(FATAL, &
                   "MOM_open_boundary, initialize_segment_data: "//&
                   "Need three inputs for Flather")
        OBC_segments(n)%num_fields = 3 ! these are the input fields required for the Flather option
                                       ! note that this is assuming that the inputs are coming in this order
                                       ! and independent of the input param string . Needs cleanup - mjh
        allocate(OBC_segments(n)%field_names(OBC_segments(n)%num_fields))
        OBC_segments(n)%field_names(:)='None'
        OBC_segments(n)%field_names(1)='UO'
        OBC_segments(n)%field_names(2)='VO'
        OBC_segments(n)%field_names(3)='ZOS'
     endif

     do m=1,num_fields
        call parse_segment_data_str(segstr,var=trim(fields(m)), value=value, filenam=filename, fieldnam=fieldname)

        OBC_segments(n)%field(m)%name = trim(fields(m))
        filename = trim(inputdir)//trim(filename)
        fieldname = trim(fieldname)//trim(suffix)
!        print *,'varnam,filename,fieldname=',trim(fields(m)), ',',trim(filename),',', trim(fieldname)
        call field_size(filename,fieldname,siz,no_domain=.true.)
!        print *,'field size= ',siz
        allocate(OBC_segments(n)%field(m)%buffer_src(siz(1),siz(2),siz(3)))
        OBC_segments(n)%field(m)%fid = init_external_field(trim(filename),trim(fieldname))
!        OBC_segments(n)%field(m)%fid = init_external_field(trim(filename),trim(fieldname))
        if (siz(3) > 1) then
          fieldname = 'dz_'//trim(fieldname)
          call field_size(filename,fieldname,siz,no_domain=.true.)
          allocate(OBC_segments(n)%field(m)%dz_src(siz(1),siz(2),siz(3)))
          OBC_segments(n)%field(m)%nk_src=siz(3)
          OBC_segments(n)%field(m)%fid_dz = init_external_field(trim(filename),trim(fieldname))
        else
          OBC_segments(n)%field(m)%nk_src=1
        endif
     enddo

  enddo

  return
end subroutine initialize_segment_data

!> Parse an OBC_SEGMENT_%%% string starting with "I=" and configure placement and type of OBC accordingly
subroutine setup_u_point_obc(OBC, G, segment_str, l_seg)
  type(ocean_OBC_type),    pointer    :: OBC !< Open boundary control structure
  type(dyn_horgrid_type),  intent(in) :: G !< Ocean grid structure
  character(len=*),        intent(in) :: segment_str !< A string in form of "I=%,J=%:%,string"
  integer,                 intent(in) :: l_seg !< which segment is this?
  ! Local variables
  integer :: I_obc, Js_obc, Je_obc ! Position of segment in global index space
  integer :: j, this_kind, a_loop
  character(len=32) :: action_str(5)

  ! This returns the global indices for the segment
  call parse_segment_str(G%ieg, G%jeg, segment_str, I_obc, Js_obc, Je_obc, action_str )
  I_obc = I_obc - G%idg_offset ! Convert to local tile indices on this tile
  Js_obc = Js_obc - G%jdg_offset ! Convert to local tile indices on this tile
  Je_obc = Je_obc - G%jdg_offset ! Convert to local tile indices on this tile
  this_kind = OBC_NONE

  ! Hack to extend segment by one point
  if (Js_obc<Je_obc) then
    Js_obc = Js_obc - 1 ; Je_obc = Je_obc + 1
  else
    Js_obc = Js_obc + 1 ; Je_obc = Je_obc - 1
  endif

  if (Je_obc>Js_obc) OBC%OBC_segment_number(l_seg)%direction = OBC_DIRECTION_E
  if (Je_obc<Js_obc) OBC%OBC_segment_number(l_seg)%direction = OBC_DIRECTION_W
  do a_loop = 1,5
    if (len_trim(action_str(a_loop)) == 0) then
      cycle
    elseif (trim(action_str(a_loop)) == 'FLATHER') then
      this_kind = OBC_FLATHER
      OBC%OBC_segment_number(l_seg)%Flather = .true.
      OBC%Flather_u_BCs_exist_globally = .true.
    elseif (trim(action_str(a_loop)) == 'ORLANSKI') then
      OBC%OBC_segment_number(l_seg)%radiation = .true.
      OBC%Flather_u_BCs_exist_globally = .true.
    elseif (trim(action_str(a_loop)) == 'OBLIQUE') then
      OBC%OBC_segment_number(l_seg)%radiation = .true.
      OBC%OBC_segment_number(l_seg)%oblique = .true.
      OBC%Flather_u_BCs_exist_globally = .true.
    elseif (trim(action_str(a_loop)) == 'NUDGED') then
      OBC%OBC_segment_number(l_seg)%nudged = .true.
      OBC%OBC_segment_number(l_seg)%values_needed = .true.
      OBC%OBC_segment_number(l_seg)%Tnudge_in = 1.0/(3*86400)
      OBC%OBC_segment_number(l_seg)%Tnudge_out = 1.0/(360*86400)
      OBC%nudged_u_BCs_exist_globally = .true.
    elseif (trim(action_str(a_loop)) == 'GRADIENT') then
      OBC%OBC_segment_number(l_seg)%gradient = .true.
    elseif (trim(action_str(a_loop)) == 'LEGACY') then
      this_kind = OBC_FLATHER
      OBC%OBC_segment_number(l_seg)%legacy = .true.
      OBC%OBC_segment_number(l_seg)%Flather = .true.
      OBC%OBC_segment_number(l_seg)%radiation = .true.
      OBC%OBC_segment_number(l_seg)%gradient = .true.
      OBC%Flather_u_BCs_exist_globally = .true.
    elseif (trim(action_str(a_loop)) == 'SIMPLE') then
      OBC%OBC_segment_number(l_seg)%specified = .true.
      OBC%OBC_segment_number(l_seg)%values_needed = .true.
      OBC%specified_u_BCs_exist_globally = .true. ! This avoids deallocation
      ! Hack to undo the hack above for SIMPLE BCs
      if (Js_obc<Je_obc) then
        Js_obc = Js_obc + 1 ; Je_obc = Je_obc - 1
      else
        Js_obc = Js_obc - 1 ; Je_obc = Je_obc + 1
      endif
    else
      call MOM_error(FATAL, "MOM_open_boundary.F90, setup_u_point_obc: "//&
                     "String '"//trim(action_str(a_loop))//"' not understood.")
    endif

    if (I_obc<G%HI%IsdB .or. I_obc>G%HI%IedB) return ! Boundary is not on tile
    if (max(Js_obc,Je_obc)<G%HI%JsdB .or. min(Js_obc,Je_obc)>G%HI%JedB) return ! Segment is not on tile

    do j=G%HI%jsd, G%HI%jed
      if (j>min(Js_obc,Je_obc) .and. j<=max(Js_obc,Je_obc)) then
        OBC%OBC_segment_u(I_obc,j) = l_seg
        if (Je_obc>Js_obc) then ! East is outward
          if (this_kind == OBC_FLATHER) then
            ! Set v points outside segment
            if (OBC%OBC_segment_v(i_obc+1,J) == OBC_NONE) then
              OBC%OBC_segment_v(i_obc+1,J) = l_seg
            endif
            if (OBC%OBC_segment_v(i_obc+1,J-1) == OBC_NONE) then
              OBC%OBC_segment_v(i_obc+1,J-1) = l_seg
            endif
          endif
        else ! West is outward
          if (this_kind == OBC_FLATHER) then
            ! Set v points outside segment
            if (OBC%OBC_segment_v(i_obc,J) == OBC_NONE) then
              OBC%OBC_segment_v(i_obc,J) = l_seg
            endif
            if (OBC%OBC_segment_v(i_obc,J-1) == OBC_NONE) then
              OBC%OBC_segment_v(i_obc,J-1) = l_seg
            endif
          endif
        endif
      endif
    enddo
  enddo ! a_loop
  OBC%OBC_segment_number(l_seg)%Is_obc = I_obc
  OBC%OBC_segment_number(l_seg)%Ie_obc = I_obc
  OBC%OBC_segment_number(l_seg)%Js_obc = Js_obc
  OBC%OBC_segment_number(l_seg)%Je_obc = Je_obc

end subroutine setup_u_point_obc

!> Parse an OBC_SEGMENT_%%% string starting with "J=" and configure placement and type of OBC accordingly
subroutine setup_v_point_obc(OBC, G, segment_str, l_seg)
  type(ocean_OBC_type),    pointer    :: OBC !< Open boundary control structure
  type(dyn_horgrid_type),  intent(in) :: G !< Ocean grid structure
  character(len=*),        intent(in) :: segment_str !< A string in form of "J=%,I=%:%,string"
  integer,                 intent(in) :: l_seg !< which segment is this?
  ! Local variables
  integer :: J_obc, Is_obc, Ie_obc ! Position of segment in global index space
  integer :: i, this_kind, a_loop
  character(len=32) :: action_str(5)

  ! This returns the global indices for the segment
  call parse_segment_str(G%ieg, G%jeg, segment_str, J_obc, Is_obc, Ie_obc, action_str )
  J_obc = J_obc - G%jdg_offset ! Convert to local tile indices on this tile
  Is_obc = Is_obc - G%idg_offset ! Convert to local tile indices on this tile
  Ie_obc = Ie_obc - G%idg_offset ! Convert to local tile indices on this tile
  this_kind = OBC_NONE

  ! Hack to extend segment by one point
  if (Is_obc<Ie_obc) then
    Is_obc = Is_obc - 1 ; Ie_obc = Ie_obc + 1
  else
    Is_obc = Is_obc + 1 ; Ie_obc = Ie_obc - 1
  endif

  if (Ie_obc>Is_obc) OBC%OBC_segment_number(l_seg)%direction = OBC_DIRECTION_S
  if (Ie_obc<Is_obc) OBC%OBC_segment_number(l_seg)%direction = OBC_DIRECTION_N
  do a_loop = 1,5
    if (len_trim(action_str(a_loop)) == 0) then
      cycle
    elseif (trim(action_str(a_loop)) == 'FLATHER') then
      this_kind = OBC_FLATHER
      OBC%OBC_segment_number(l_seg)%Flather = .true.
      OBC%Flather_v_BCs_exist_globally = .true.
    elseif (trim(action_str(a_loop)) == 'ORLANSKI') then
      OBC%OBC_segment_number(l_seg)%radiation = .true.
      OBC%Flather_v_BCs_exist_globally = .true.
    elseif (trim(action_str(a_loop)) == 'OBLIQUE') then
      OBC%OBC_segment_number(l_seg)%radiation = .true.
      OBC%OBC_segment_number(l_seg)%oblique = .true.
      OBC%Flather_v_BCs_exist_globally = .true.
    elseif (trim(action_str(a_loop)) == 'NUDGED') then
      OBC%OBC_segment_number(l_seg)%nudged = .true.
      OBC%OBC_segment_number(l_seg)%values_needed = .true.
      OBC%OBC_segment_number(l_seg)%Tnudge_in = 1.0/(3*86400)
      OBC%OBC_segment_number(l_seg)%Tnudge_out = 1.0/(360*86400)
      OBC%nudged_v_BCs_exist_globally = .true.
    elseif (trim(action_str(a_loop)) == 'GRADIENT') then
      OBC%OBC_segment_number(l_seg)%gradient = .true.
    elseif (trim(action_str(a_loop)) == 'LEGACY') then
      this_kind = OBC_FLATHER
      OBC%OBC_segment_number(l_seg)%legacy = .true.
      OBC%OBC_segment_number(l_seg)%gradient = .true.
      OBC%OBC_segment_number(l_seg)%radiation = .true.
      OBC%OBC_segment_number(l_seg)%Flather = .true.
      OBC%Flather_v_BCs_exist_globally = .true.
    elseif (trim(action_str(a_loop)) == 'SIMPLE') then
      OBC%OBC_segment_number(l_seg)%specified = .true.
      OBC%OBC_segment_number(l_seg)%values_needed = .true.
      OBC%specified_v_BCs_exist_globally = .true. ! This avoids deallocation
      ! Hack to undo the hack above for SIMPLE BCs
      if (Is_obc<Ie_obc) then
        Is_obc = Is_obc + 1 ; Ie_obc = Ie_obc - 1
      else
        Is_obc = Is_obc - 1 ; Ie_obc = Ie_obc + 1
      endif
    else
      call MOM_error(FATAL, "MOM_open_boundary.F90, setup_v_point_obc: "//&
                     "String '"//trim(action_str(a_loop))//"' not understood.")
    endif

    if (J_obc<G%HI%JsdB .or. J_obc>G%HI%JedB) return ! Boundary is not on tile
    if (max(Is_obc,Ie_obc)<G%HI%IsdB .or. min(Is_obc,Ie_obc)>G%HI%IedB) return ! Segment is not on tile

    do i=G%HI%isd, G%HI%ied
      if (i>min(Is_obc,Ie_obc) .and. i<=max(Is_obc,Ie_obc)) then
        OBC%OBC_segment_v(i,J_obc) = l_seg
        if (Is_obc>Ie_obc) then ! North is outward
          if (this_kind == OBC_FLATHER) then
            ! Set u points outside segment
            if (OBC%OBC_segment_u(I,j_obc+1) == OBC_NONE) then
              OBC%OBC_segment_u(I,j_obc+1) = l_seg
            endif
            if (OBC%OBC_segment_u(I-1,j_obc+1) == OBC_NONE) then
              OBC%OBC_segment_u(I-1,j_obc+1) = l_seg
            endif
          endif
        else ! South is outward
          if (this_kind == OBC_FLATHER) then
            ! Set u points outside segment
            if (OBC%OBC_segment_u(I,j_obc) == OBC_NONE) then
              OBC%OBC_segment_u(I,j_obc) = l_seg
            endif
            if (OBC%OBC_segment_u(I-1,j_obc) == OBC_NONE) then
              OBC%OBC_segment_u(I-1,j_obc) = l_seg
            endif
          endif
        endif
      endif
    enddo
  enddo ! a_loop
  OBC%OBC_segment_number(l_seg)%Is_obc = Is_obc
  OBC%OBC_segment_number(l_seg)%Ie_obc = Ie_obc
  OBC%OBC_segment_number(l_seg)%Js_obc = J_obc
  OBC%OBC_segment_number(l_seg)%Je_obc = J_obc

end subroutine setup_v_point_obc

!> Parse an OBC_SEGMENT_%%% string
subroutine parse_segment_str(ni_global, nj_global, segment_str, l, m, n, action_str )
  integer,          intent(in)  :: ni_global !< Number of h-points in zonal direction
  integer,          intent(in)  :: nj_global !< Number of h-points in meridional direction
  character(len=*), intent(in)  :: segment_str !< A string in form of "I=l,J=m:n,string" or "J=l,I=m,n,string"
  integer,          intent(out) :: l !< The value of I=l, if segment_str begins with I=l, or the value of J=l
  integer,          intent(out) :: m !< The value of J=m, if segment_str begins with I=, or the value of I=m
  integer,          intent(out) :: n !< The value of J=n, if segment_str begins with I=, or the value of I=n
  character(len=*), intent(out) :: action_str(:) !< The "string" part of segment_str
  ! Local variables
  character(len=24) :: word1, word2, m_word, n_word !< Words delineated by commas in a string in form of "I=%,J=%:%,string"
  integer :: l_max !< Either ni_global or nj_global, depending on whether segment_str begins with "I=" or "J="
  integer :: mn_max !< Either nj_global or ni_global, depending on whether segment_str begins with "I=" or "J="
  integer :: j

  ! Process first word which will started with either 'I=' or 'J='
  word1 = extract_word(segment_str,',',1)
  word2 = extract_word(segment_str,',',2)
  if (word1(1:2)=='I=') then
    l_max = ni_global
    mn_max = nj_global
    if (.not. (word2(1:2)=='J=')) call MOM_error(FATAL, "MOM_open_boundary.F90, parse_segment_str: "//&
                     "Second word of string '"//trim(segment_str)//"' must start with 'J='.")
  elseif (word1(1:2)=='J=') then ! Note that the file_parser uniformaly expands "=" to " = "
    l_max = nj_global
    mn_max = ni_global
    if (.not. (word2(1:2)=='I=')) call MOM_error(FATAL, "MOM_open_boundary.F90, parse_segment_str: "//&
                     "Second word of string '"//trim(segment_str)//"' must start with 'I='.")
  else
    call MOM_error(FATAL, "MOM_open_boundary.F90, parse_segment_str"//&
                   "String '"//segment_str//"' must start with 'I=' or 'J='.")
  endif

  ! Read l
  l = interpret_int_expr( word1(3:24), l_max )
  if (l<0 .or. l>l_max) then
    call MOM_error(FATAL, "MOM_open_boundary.F90, parse_segment_str: "//&
                   "First value from string '"//trim(segment_str)//"' is outside of the physical domain.")
  endif

  ! Read m
  m_word = extract_word(word2(3:24),':',1)
  m = interpret_int_expr( m_word, mn_max )
  if (m<-1 .or. m>mn_max+1) then
    call MOM_error(FATAL, "MOM_open_boundary.F90, parse_segment_str: "//&
                   "Beginning of range in string '"//trim(segment_str)//"' is outside of the physical domain.")
  endif

  ! Read m
  n_word = extract_word(word2(3:24),':',2)
  n = interpret_int_expr( n_word, mn_max )
  if (n<-1 .or. n>mn_max+1) then
    call MOM_error(FATAL, "MOM_open_boundary.F90, parse_segment_str: "//&
                   "End of range in string '"//trim(segment_str)//"' is outside of the physical domain.")
  endif

  if (abs(n-m)==0) then
    call MOM_error(FATAL, "MOM_open_boundary.F90, parse_segment_str: "//&
                   "Range in string '"//trim(segment_str)//"' must span one cell.")
  endif

  ! Type of open boundary condition
  do j = 1, size(action_str)
    action_str(j) = extract_word(segment_str,',',2+j)
  enddo

  contains

  ! Returns integer value interpreted from string in form of %I, N or N-%I
  integer function interpret_int_expr(string, imax)
    character(len=*), intent(in) :: string !< Integer in form or %I, N or N-%I
    integer,          intent(in) :: imax !< Value to replace 'N' with
    ! Local variables
    integer slen

    slen = len_trim(string)
    if (slen==0) call MOM_error(FATAL, "MOM_open_boundary.F90, parse_segment_str"//&
                                "Parsed string was empty!")
    if (len_trim(string)==1 .and. string(1:1)=='N') then
      interpret_int_expr = imax
    elseif (string(1:1)=='N') then
      read(string(2:slen),*,err=911) interpret_int_expr
      interpret_int_expr = imax - interpret_int_expr
    else
      read(string(1:slen),*,err=911) interpret_int_expr
    endif
    return
    911 call MOM_error(FATAL, "MOM_open_boundary.F90, parse_segment_str"//&
                       "Problem reading value from string '"//trim(string)//"'.")
  end function interpret_int_expr
end subroutine parse_segment_str

 subroutine parse_segment_data_str(segment_str, var, value, filenam, fieldnam, fields, num_fields, debug )
   character(len=*), intent(in)             :: segment_str !< A string in form of "VAR1=file:foo1.nc(varnam1),VAR2=file:foo2.nc(varnam2),..."
   character(len=*), intent(in),  optional  :: var         !< The name of the variable for which parameters are needed
   character(len=*), intent(out), optional  :: filenam     !< The name of the input file if using "file" method
   character(len=*), intent(out), optional  :: fieldnam    !< The name of the variable in the input file if using "file" method
   real,             intent(out), optional  :: value       !< A constant value if using the "value" method
   character(len=*), dimension(MAX_OBC_FIELDS), intent(out), optional :: fields   !< List of fieldnames for each segment
   integer, intent(out), optional           :: num_fields
   logical, intent(in), optional            :: debug
   ! Local variables
   character(len=128) :: word1, word2, word3, method
   integer :: lword, nfields, n, m, orient
   logical :: continue,dbg
   character(len=32), dimension(MAX_OBC_FIELDS) :: flds

   nfields=0
   continue=.true.
   dbg=.false.
   if (PRESENT(debug)) dbg=debug

   do while (continue)
      word1 = extract_word(segment_str,',',nfields+1,debug=dbg)
      if (trim(word1) == '') exit
      nfields=nfields+1
      word2 = extract_word(word1,'=',1,debug=dbg)
!      print *,'nfields,field=',nfields,trim(word2)
      flds(nfields) = trim(word2)
   enddo

   if (PRESENT(fields)) then
     do n=1,nfields
       fields(n) = flds(n)
     enddo
   endif

   if (PRESENT(num_fields)) then
      num_fields=nfields
      return
   endif

   m=0
   if (PRESENT(var)) then
     do n=1,nfields
!       print *, 'fields(n)= ',trim(flds(n))
       if (trim(var)==trim(flds(n))) then
          m=n
          exit
       endif
     enddo
     if (m==0) then
!        print *,'Error finding field ',trim(var)
        call abort()
     endif

    ! Process first word which will start with the fieldname
     word3 = extract_word(segment_str,',',m,debug=dbg)
     word1 = extract_word(word3,':',1,debug=dbg)
!     if (trim(word1) == '') exit
     word2 = extract_word(word1,'=',1,debug=dbg)
     if (trim(word2) == trim(var)) then
        method=trim(extract_word(word1,'=',2,debug=dbg))
        lword=len_trim(method)
        if (method(lword-3:lword) == 'file') then
           ! raise an error id filename/fieldname not in argument list
           word1 = extract_word(word3,':',2)
           filenam = extract_word(word1,'(',1)
           fieldnam = extract_word(word1,'(',2)
           lword=len_trim(fieldnam)
           fieldnam = fieldnam(1:lword-1)  ! remove trailing parenth
!           print *,'in parser, filename,fieldname= ',trim(filenam), ',',trim(fieldnam)
           value=-999.
        elseif (method(lword-4:lword) == 'value') then
           filenam = 'none'
           fieldnam = 'none'
           word1 = extract_word(word3,':',2)
           lword=len_trim(word1)
           read(word2(1:lword),*) value
        endif
      endif
    endif

 end subroutine parse_segment_data_str

!> Initialize open boundary control structure
subroutine open_boundary_init(G, param_file, OBC)
  type(ocean_grid_type), intent(in)    :: G !< Ocean grid structure
  type(param_file_type), intent(in)    :: param_file !< Parameter file handle
  type(ocean_OBC_type),  pointer       :: OBC !< Open boundary control structure
  ! Local variables

  if (.not.associated(OBC)) return

  if ( OBC%Flather_u_BCs_exist_globally .or. OBC%Flather_v_BCs_exist_globally ) then
    call get_param(param_file, mod, "OBC_RADIATION_MAX", OBC%rx_max, &
                   "The maximum magnitude of the baroclinic radiation \n"//&
                   "velocity (or speed of characteristics).  This is only \n"//&
                   "used if one of the open boundary segments is using Orlanski.", &
                   units="m s-1", default=10.0)
    call get_param(param_file, mod, "OBC_RAD_VEL_WT", OBC%gamma_uv, &
                   "The relative weighting for the baroclinic radiation \n"//&
                   "velocities (or speed of characteristics) at the new \n"//&
                   "time level (1) or the running mean (0) for velocities. \n"//&
                   "Valid values range from 0 to 1. This is only used if \n"//&
                   "one of the open boundary segments is using Orlanski.", &
                   units="nondim",  default=0.3)
    call get_param(param_file, mod, "OBC_RAD_THICK_WT", OBC%gamma_h, &
                   "The relative weighting for the baroclinic radiation \n"//&
                   "velocities (or speed of characteristics) at the new \n"//&
                   "time level (1) or the running mean (0) for thicknesses. \n"//&
                   "Valid values range from 0 to 1. This is only used if \n"//&
                   "one of the open boundary segments is using Orlanski.", &
                   units="nondim",  default=0.2)
  endif

  id_clock_pass = cpu_clock_id('(Ocean OBC halo updates)', grain=CLOCK_ROUTINE)

end subroutine open_boundary_init

logical function open_boundary_query(OBC, apply_specified_OBC, apply_Flather_OBC, apply_nudged_OBC, use_OBC_segments)
  type(ocean_OBC_type), pointer     :: OBC !< Open boundary control structure
  logical, optional,    intent(in)  :: apply_specified_OBC !< If present, returns True if specified_*_BCs_exist_globally is true
  logical, optional,    intent(in)  :: apply_Flather_OBC   !< If present, returns True if Flather_*_BCs_exist_globally is true
  logical, optional,    intent(in)  :: apply_nudged_OBC    !< If present, returns True if nudged_*_BCs_exist_globally is true
  logical, optional,    intent(in)  :: use_OBC_segments !< If present, returns True if using the newer obc segments
  open_boundary_query = .false.
  if (.not. associated(OBC)) return
  if (present(apply_specified_OBC)) open_boundary_query = OBC%specified_u_BCs_exist_globally .or. &
                                                          OBC%specified_v_BCs_exist_globally
  if (present(apply_Flather_OBC)) open_boundary_query = OBC%Flather_u_BCs_exist_globally .or. &
                                                        OBC%Flather_v_BCs_exist_globally
  if (present(apply_nudged_OBC)) open_boundary_query = OBC%nudged_u_BCs_exist_globally .or. &
                                                       OBC%nudged_v_BCs_exist_globally
  if (present(use_OBC_segments) .and. OBC%number_of_segments > 0) open_boundary_query = .true.

end function open_boundary_query

!> Deallocate open boundary data
subroutine open_boundary_dealloc(OBC)
  type(ocean_OBC_type), pointer :: OBC !< Open boundary control structure
  if (.not. associated(OBC)) return
  if (associated(OBC%OBC_segment_number)) deallocate(OBC%OBC_segment_number)
  if (associated(OBC%OBC_segment_u)) deallocate(OBC%OBC_segment_u)
  if (associated(OBC%OBC_segment_v)) deallocate(OBC%OBC_segment_v)
  if (associated(OBC%rx_old_u)) deallocate(OBC%rx_old_u)
  if (associated(OBC%ry_old_v)) deallocate(OBC%ry_old_v)
  if (associated(OBC%rx_old_h)) deallocate(OBC%rx_old_h)
  if (associated(OBC%ry_old_h)) deallocate(OBC%ry_old_h)
  if (associated(OBC%ubt_outer)) deallocate(OBC%ubt_outer)
  if (associated(OBC%vbt_outer)) deallocate(OBC%vbt_outer)
  if (associated(OBC%eta_outer_u)) deallocate(OBC%eta_outer_u)
  if (associated(OBC%eta_outer_v)) deallocate(OBC%eta_outer_v)
  if (associated(OBC%u)) deallocate(OBC%u)
  if (associated(OBC%v)) deallocate(OBC%v)
  if (associated(OBC%uh)) deallocate(OBC%uh)
  if (associated(OBC%vh)) deallocate(OBC%vh)
  deallocate(OBC)
end subroutine open_boundary_dealloc

!> Close open boundary data
subroutine open_boundary_end(OBC)
  type(ocean_OBC_type), pointer :: OBC !< Open boundary control structure
  call open_boundary_dealloc(OBC)
end subroutine open_boundary_end

!> Sets the slope of bathymetry normal to an open bounndary to zero.
subroutine open_boundary_impose_normal_slope(OBC, G, depth)
  type(ocean_OBC_type),             pointer       :: OBC !< Open boundary control structure
  type(dyn_horgrid_type),           intent(in)    :: G !< Ocean grid structure
  real, dimension(SZI_(G),SZJ_(G)), intent(inout) :: depth !< Bathymetry at h-points
  ! Local variables
  integer :: i, j
  logical :: bc_north, bc_south, bc_east, bc_west

  if (.not.associated(OBC)) return

  do J=G%jsd+1,G%jed-1 ; do i=G%isd+1,G%ied-1
    bc_north = .false. ; bc_south = .false. ; bc_east = .false. ; bc_west = .false.
    if (associated(OBC%OBC_segment_u)) then
      if (OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%direction == OBC_DIRECTION_E &
          .and. .not. OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%specified) bc_east = .true.
      if (OBC%OBC_segment_number(OBC%OBC_segment_u(I-1,j))%direction == OBC_DIRECTION_W &
          .and. .not. OBC%OBC_segment_number(OBC%OBC_segment_u(I-1,j))%specified) bc_west = .true.
    endif
    if (associated(OBC%OBC_segment_v)) then
      if (OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%direction == OBC_DIRECTION_N &
          .and. .not. OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%specified) bc_north = .true.
      if (OBC%OBC_segment_number(OBC%OBC_segment_v(i,J-1))%direction == OBC_DIRECTION_S &
          .and. .not. OBC%OBC_segment_number(OBC%OBC_segment_v(i,J-1))%specified) bc_south = .true.
    endif
    if (bc_north) depth(i,j+1) = depth(i,j)
    if (bc_south) depth(i,j-1) = depth(i,j)
    if (bc_east) depth(i+1,j) = depth(i,j)
    if (bc_west) depth(i-1,j) = depth(i,j)
    ! Convex corner cases
    if (bc_north.and.bc_east) depth(i+1,j+1) = depth(i,j)
    if (bc_north.and.bc_west) depth(i-1,j+1) = depth(i,j)
    if (bc_south.and.bc_east) depth(i+1,j-1) = depth(i,j)
    if (bc_south.and.bc_west) depth(i-1,j-1) = depth(i,j)
  enddo ; enddo

end subroutine open_boundary_impose_normal_slope

!> Reconcile masks and open boundaries, deallocate OBC on PEs where it is not needed.
!! Also adjust u- and v-point cell area on specified open boundaries.
subroutine open_boundary_impose_land_mask(OBC, G, areaCu, areaCv)
  type(ocean_OBC_type),              pointer       :: OBC !< Open boundary control structure
  type(dyn_horgrid_type),            intent(in)    :: G !< Ocean grid structure
  real, dimension(SZIB_(G),SZJ_(G)), intent(inout) :: areaCu !< Area of a u-cell (m2)
  real, dimension(SZI_(G),SZJB_(G)), intent(inout) :: areaCv !< Area of a u-cell (m2)
  ! Local variables
  integer :: i, j
  logical :: any_U, any_V

  if (.not.associated(OBC)) return

  ! Sweep along u-segments and delete the OBC for blocked points.
  if (associated(OBC%OBC_segment_u)) then
    do j=G%jsd,G%jed ; do I=G%IsdB,G%IedB
      if (G%mask2dCu(I,j) == 0 .and. (OBC%OBC_segment_u(I,j) /= OBC_NONE)) then
        if (.not. OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%specified) then
          OBC%OBC_segment_u(I,j) = OBC_NONE
        endif
      endif
    enddo ; enddo
  endif

  ! Sweep along v-segments and delete the OBC for blocked points.
  if (associated(OBC%OBC_segment_v)) then
    do J=G%JsdB,G%JedB ; do i=G%isd,G%ied
      if (G%mask2dCv(i,J) == 0 .and. (OBC%OBC_segment_v(i,J) /= OBC_NONE)) then
        if (.not. OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%specified) then
          OBC%OBC_segment_v(I,j) = OBC_NONE
        endif
      endif
    enddo ; enddo
  endif

  ! Sweep along u-segments and for %specified BC points reset the u-point area which was masked out
  if (associated(OBC%OBC_segment_u)) then
    do j=G%jsd,G%jed ; do I=G%isd,G%ied-1
      if (OBC%OBC_segment_u(I,j) /= OBC_NONE) then
        if (OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%specified) then
          if (OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%direction == OBC_DIRECTION_W) then
            areaCu(I,j) = G%areaT(i+1,j)
           !G%IareaCu(I,j) = G%IareaT(i+1,j) ?
          elseif (OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%direction == OBC_DIRECTION_E) then
            areaCu(I,j) = G%areaT(i,j)
           !G%IareaCu(I,j) = G%IareaT(i,j) ?
          endif
        endif
      endif
    enddo ; enddo
  endif

  ! Sweep along v-segments and for %specified BC points reset the v-point area which was masked out
  if (associated(OBC%OBC_segment_v)) then
    do J=G%jsd,G%jed-1 ; do i=G%isd,G%ied
      if (OBC%OBC_segment_v(i,J) /= OBC_NONE) then
        if (OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%specified) then
          if (OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%direction == OBC_DIRECTION_S) then
            areaCv(i,J) = G%areaT(i,j+1)
           !G%IareaCv(i,J) = G%IareaT(i,j+1) ?
          elseif (OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%direction == OBC_DIRECTION_N) then
            areaCu(i,J) = G%areaT(i,j)
           !G%IareaCu(i,J) = G%IareaT(i,j) ?
          endif
        endif
      endif
    enddo ; enddo
  endif

  any_U = .false.
  if (associated(OBC%OBC_segment_u)) then
    do j=G%jsd,G%jed ; do I=G%IsdB,G%IedB
      ! G%mask2du will be open wherever bathymetry allows it.
      ! Bathymetry outside of the open boundary was adjusted to match
      ! the bathymetry inside so these points will be open unless the
      ! bathymetry inside the boundary was do shallow and flagged as land.
      if (OBC%OBC_segment_u(I,j) /= OBC_NONE) any_U = .true.
    enddo ; enddo
  endif

  any_V = .false.
  if (associated(OBC%OBC_segment_v)) then
    do J=G%JsdB,G%JedB ; do i=G%isd,G%ied
      if (OBC%OBC_segment_v(i,J) /= OBC_NONE) any_V = .true.
    enddo ; enddo
  endif

  OBC%OBC_pe = .true.
  if (.not.(any_U .or. any_V)) OBC%OBC_pe = .false.

end subroutine open_boundary_impose_land_mask

!> Apply radiation conditions to 3D  u,v (,h) at open boundaries
subroutine radiation_open_bdry_conds(OBC, u_new, u_old, v_new, v_old, &
                                     h_new, h_old, G)
  type(ocean_grid_type),                     intent(inout) :: G !< Ocean grid structure
  type(ocean_OBC_type),                      pointer       :: OBC !< Open boundary control structure
  real, dimension(SZIB_(G),SZJ_(G),SZK_(G)), intent(inout) :: u_new !< New u values on open boundaries
  real, dimension(SZIB_(G),SZJ_(G),SZK_(G)), intent(in)    :: u_old !< Original unadjusted u
  real, dimension(SZI_(G),SZJB_(G),SZK_(G)), intent(inout) :: v_new !< New v values on open boundaries
  real, dimension(SZI_(G),SZJB_(G),SZK_(G)), intent(in)    :: v_old !< Original unadjusted v
  real, dimension(SZI_(G),SZJ_(G),SZK_(G)),  intent(inout) :: h_new !< New h values on open boundaries
  real, dimension(SZI_(G),SZJ_(G),SZK_(G)),  intent(in)    :: h_old !< Original h values
  ! Local variables
  real, dimension(SZI_(G),SZJ_(G)) :: grad
  real :: dhdt, dhdx, dhdy, gamma_u, gamma_h, gamma_v
  real :: cff, Cx, Cy, tau
  real :: rx_max, ry_max ! coefficients for radiation
  real :: rx_new, rx_avg ! coefficients for radiation
  real, parameter :: eps = 1.0e-20

  integer :: i, j, k, is, ie, js, je, nz
  is = G%isc ; ie = G%iec ; js = G%jsc ; je = G%jec ; nz = G%ke

  if (.not.associated(OBC)) return
  if (.not.(OBC%Flather_u_BCs_exist_globally .or. OBC%Flather_v_BCs_exist_globally)) &
    return

  gamma_u = OBC%gamma_uv ; gamma_v = OBC%gamma_uv ; gamma_h = OBC%gamma_h
  rx_max = OBC%rx_max ; ry_max = OBC%rx_max

  do k=1,nz ; do j=js,je ; do I=is-1,ie ; if (OBC%OBC_segment_u(I,j) /= OBC_NONE) then
    if (OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%direction == OBC_DIRECTION_E) then
      if (OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%legacy) then
        dhdt = u_old(I-1,j,k)-u_new(I-1,j,k) !old-new
        dhdx = u_new(I-1,j,k)-u_new(I-2,j,k) !in new time backward sasha for I-1
        rx_new = 0.0
        if (dhdt*dhdx > 0.0) rx_new = min( (dhdt/dhdx), rx_max)
        rx_avg = (1.0-gamma_u)*OBC%rx_old_u(I,j,k) + gamma_u*rx_new
        OBC%rx_old_u(I,j,k) = rx_avg
        u_new(I,j,k) = (u_old(I,j,k) + rx_avg*u_new(I-1,j,k)) / (1.0+rx_avg)

    !   dhdt = h_old(I,j,k)-h_new(I,j,k) !old-new
    !   dhdx = h_new(I,j,k)-h_new(I-1,j,k) !in new time
    !   rx_new = 0.0
    !   if (dhdt*dhdx > 0.0) rx_new = min( (dhdt/dhdx), rx_max)
    !   rx_avg = (1.0-gamma_h)*OBC%rx_old_h(I,j,k) + gamma_h*rx_new
    !   OBC%rx_old_h(I,j,k) = rx_avg
    !    h_new(I+1,j,k) = (h_old(I+1,j,k) + rx_avg*h_new(I,j,k)) / (1.0+rx_avg) !original
      elseif (OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%radiation) then
        grad(I,J) = u_old(I,j+1,k) - u_old(I,j,k)
        grad(I,J-1) = u_old(I,j,k) - u_old(I,j-1,k)
        grad(I-1,J) = u_old(I-1,j+1,k) - u_old(I-1,j,k)
        grad(I-1,J-1) = u_old(I-1,j,k) - u_old(I-1,j-1,k)
        dhdt = u_old(I-1,j,k)-u_new(I-1,j,k) !old-new
        dhdx = u_new(I-1,j,k)-u_new(I-2,j,k) !in new time backward sasha for I-1
        if (dhdt*dhdx < 0.0) dhdt = 0.0
        if (dhdt*(grad(I-1,J) + grad(I-1,J-1)) > 0.0) then
          dhdy = grad(I-1,J-1)
        else
          dhdy = grad(I-1,J)
        endif
        cff = max(dhdx*dhdx + dhdy*dhdy, eps)
        Cx = dhdt*dhdx
        Cy = 0
        if (OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%oblique) &
             Cy = min(cff,max(dhdt*dhdy,-cff))
        u_new(I,j,k) = ((cff*u_old(I,j,k) + Cx*u_new(I-1,j,k)) - &
          (max(Cy,0.0)*grad(I,J-1) - min(Cy,0.0)*grad(I,J))) / (cff + Cx)
      endif
      if (OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%radiation .and. &
          OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%nudged) then
        if (dhdt*dhdx < 0.0) then
          tau = OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%Tnudge_in
        else
          tau = OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%Tnudge_out
        endif
        u_new(I,j,k) = u_new(I,j,k) + tau*(OBC%u(I,j,k) - u_old(I,j,k))
      endif
    endif

    if (OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%direction == OBC_DIRECTION_W) then
      if (OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%radiation) then
        dhdt = u_old(I+1,j,k)-u_new(I+1,j,k) !old-new
        dhdx = u_new(I+1,j,k)-u_new(I+2,j,k) !in new time backward sasha for I+1
        rx_new = 0.0
        if (dhdt*dhdx > 0.0) rx_new = min( (dhdt/dhdx), rx_max)
        rx_avg = (1.0-gamma_u)*OBC%rx_old_u(I,j,k) + gamma_u*rx_new
        OBC%rx_old_u(I,j,k) = rx_avg
        u_new(I,j,k) = (u_old(I,j,k) + rx_avg*u_new(I+1,j,k)) / (1.0+rx_avg)

    !   dhdt = h_old(I+1,j,k)-h_new(I+1,j,k) !old-new
    !   dhdx = h_new(I+1,j,k)-h_new(I+2,j,k) !in new time
    !   rx_new = 0.0
    !   if (dhdt*dhdx > 0.0) rx_new = min( (dhdt/dhdx), rx_max)
    !   rx_avg = (1.0-gamma_h)*OBC%rx_old_h(I,j,k) + gamma_h*rx_new
    !   OBC%rx_old_h(I,j,k) = rx_avg
    !   h_new(I,j,k) = (h_old(I,j,k) + rx_avg*h_new(I+1,j,k)) / (1.0+rx_avg) !original
      elseif (OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%radiation) then
        grad(I,J) = u_old(I,j+1,k) - u_old(I,j,k)
        grad(I,J-1) = u_old(I,j,k) - u_old(I,j-1,k)
        grad(I+1,J) = u_old(I+1,j+1,k) - u_old(I+1,j,k)
        grad(I+1,J-1) = u_old(I+1,j,k) - u_old(I+1,j-1,k)
        dhdt = u_old(I+1,j,k)-u_new(I+1,j,k) !old-new
        dhdx = u_new(I+1,j,k)-u_new(I+2,j,k) !in new time backward sasha for I+1
        if (dhdt*dhdx < 0.0) dhdt = 0.0
        if (dhdt*(grad(I+1,J) + grad(I+1,J-1)) > 0.0) then
          dhdy = grad(I+1,J-1)
        else
          dhdy = grad(I+1,J)
        endif
        cff = max(dhdx*dhdx + dhdy*dhdy, eps)
        Cx = dhdt*dhdx
        Cy = 0
        if (OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%oblique) &
             Cy = min(cff,max(dhdt*dhdy,-cff))
        u_new(I,j,k) = ((cff*u_old(I,j,k) + Cx*u_new(I+1,j,k)) - &
          (max(Cy,0.0)*grad(I,J-1) - min(Cy,0.0)*grad(I,J))) / (cff + Cx)
      endif
      if (OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%radiation .and. &
          OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%nudged) then
        if (dhdt*dhdx < 0.0) then
          tau = OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%Tnudge_in
        else
          tau = OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%Tnudge_out
        endif
        u_new(I,j,k) = u_new(I,j,k) + tau*(OBC%u(I,j,k) - u_old(I,j,k))
      endif
    endif

    if (OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%direction == OBC_DIRECTION_N) then
      if (OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%gradient .or. &
          OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%legacy) then
        u_new(I,j,k) = u_new(I,j-1,k)
      elseif (OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%radiation) then
        grad(i,j) = u_old(I,j,k) - u_old(I-1,j,k)
        grad(i,j-1) = u_old(I,j-1,k) - u_old(I-1,j-1,k)
        grad(i+1,j) = u_old(I+1,j,k) - u_old(I,j,k)
        grad(i+1,j-1) = u_old(I+1,j-1,k) - u_old(I,j-1,k)
        dhdt = u_old(I,j-1,k)-u_new(I,j-1,k) !old-new
        dhdy = u_new(I,j-1,k)-u_new(I,j-2,k) !in new time backward sasha for I+1
        if (dhdt*dhdy < 0.0) dhdt = 0.0
        if (dhdt*(grad(i,j-1) + grad(i+1,j-1)) > 0.0) then
          dhdx = grad(i,j-1)
        else
          dhdx = grad(i+1,j-1)
        endif
        cff = max(dhdx*dhdx + dhdy*dhdy, eps)
        Cx = 0.0
        if (OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%oblique) &
               Cx = min(cff, max(dhdt*dhdx, -cff))
        Cy = dhdt*dhdy
        u_new(I,j,k) = ((cff*u_old(I,j,k) + Cy*u_new(I,j-1,k)) - &
               (max(Cx, 0.0)*grad(i,j) - min(Cx, 0.0)*grad(i+1,j)))/(cff + Cy)
      endif
    endif

    if (OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%direction == OBC_DIRECTION_S) then
      if (OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%gradient .or. &
          OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%legacy) then
        u_new(I,j,k) = u_new(I,j+1,k)
      elseif (OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%radiation) then
        grad(i,j) = u_old(I,j,k) - u_old(I-1,j,k)
        grad(i,j+1) = u_old(I,j+1,k) - u_old(I-1,j+1,k)
        grad(i+1,j) = u_old(I+1,j,k) - u_old(I,j,k)
        grad(i+1,j+1) = u_old(I+1,j+1,k) - u_old(I,j+1,k)
        dhdt = u_old(I,j+1,k)-u_new(I,j+1,k) !old-new
        dhdy = u_new(I,j+1,k)-u_new(I,j+2,k) !in new time backward sasha for I+1
        if (dhdt*dhdy < 0.0) dhdt = 0.0
        if (dhdt*(grad(i,j+1) + grad(i+1,j+1)) > 0.0) then
          dhdx = grad(i,j+1)
        else
          dhdx = grad(i+1,j+1)
        endif
        cff = max(dhdx*dhdx + dhdy*dhdy, eps)
        Cx = 0.0
        if (OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%oblique) &
               Cx = min(cff, max(dhdt*dhdx, -cff))
        Cy = dhdt*dhdy
        u_new(I,j,k) = ((cff*u_old(I,j,k) + Cy*u_new(I,j+1,k)) - &
               (max(Cx, 0.0)*grad(i,j) - min(Cx, 0.0)*grad(i+1,j)))/(cff + Cy)
      endif
    endif
  endif ; enddo ; enddo ; enddo

  do k=1,nz ; do J=js-1,je ; do i=is,ie ; if (OBC%OBC_segment_v(i,J) /= OBC_NONE) then
    if (OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%direction == OBC_DIRECTION_N) then
      if (OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%legacy) then
        dhdt = v_old(i,J-1,k)-v_new(i,J-1,k) !old-new
        dhdy = v_new(i,J-1,k)-v_new(i,J-2,k) !in new time backward sasha for J-1
        rx_new = 0.0
        if (dhdt*dhdy > 0.0) rx_new = min( (dhdt/dhdy), rx_max)
        rx_avg = (1.0-gamma_v)*OBC%ry_old_v(i,J,k) + gamma_v*rx_new
        OBC%ry_old_v(i,J,k) = rx_avg
        v_new(i,J,k) = (v_old(i,J,k) + rx_avg*v_new(i,J-1,k)) / (1.0+rx_avg)

    !   dhdt = h_old(i,J,k)-h_new(i,J,k) !old-new
    !   dhdx = h_new(i,J,k)-h_new(i,J-1,k) !in new time
    !   rx_new = 0.0
    !   if (dhdt*dhdx > 0.0) rx_new = min( (dhdt/dhdx), rx_max)
    !   rx_avg = (1.0-gamma_h)*OBC%ry_old_h(i,J,k) + gamma_h*rx_new
    !   OBC%ry_old_h(i,J,k) = rx_avg
    !   h_new(i,J+1,k) = (h_old(i,J+1,k) + rx_avg*h_new(i,J,k)) / (1.0+rx_avg) !original
      elseif (OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%radiation) then
        grad(I,J) = v_old(i+1,J,k) - v_old(i,J,k)
        grad(I-1,J) = v_old(i,J,k) - v_old(i-1,J,k)
        grad(I,J-1) = v_old(i+1,J-1,k) - v_old(i,J-1,k)
        grad(I-1,J-1) = v_old(i,J-1,k) - v_old(i-1,J-1,k)
        dhdt = v_old(i,J-1,k)-v_new(i,J-1,k) !old-new
        dhdy = v_new(i,J-1,k)-v_new(i,J-2,k) !in new time backward sasha for J-1
        if (dhdt*dhdy < 0.0) dhdt = 0.0
        if (dhdt*(grad(I,J-1) + grad(I-1,J-1)) > 0.0) then
          dhdx = grad(I-1,J-1)
        else
          dhdx = grad(I,J-1)
        endif
        cff = max(dhdx*dhdx + dhdy*dhdy, eps)
        Cy = dhdt*dhdy
        Cx = 0
        if (OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%oblique) &
             Cx = min(cff,max(dhdt*dhdx,-cff))
        v_new(i,J,k) = ((cff*v_old(i,J,k) + Cy*v_new(i,J-1,k)) - &
          (max(Cx,0.0)*grad(I-1,J) - min(Cx,0.0)*grad(I,J))) / (cff + Cy)
      endif
      if (OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%radiation .and. &
          OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%nudged) then
        if (dhdt*dhdy < 0.0) then
          tau = OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%Tnudge_in
        else
          tau = OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%Tnudge_out
        endif
        v_new(i,J,k) = v_new(i,J,k) + tau*(OBC%v(i,J,k) - v_old(i,J,k))
      endif
    endif

    if (OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%direction == OBC_DIRECTION_S) then
      if (OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%legacy) then
        dhdt = v_old(i,J+1,k)-v_new(i,J+1,k) !old-new
        dhdy = v_new(i,J+1,k)-v_new(i,J+2,k) !in new time backward sasha for J+1
        rx_new = 0.0
        if (dhdt*dhdy > 0.0) rx_new = min( (dhdt/dhdy), rx_max)
        rx_avg = (1.0-gamma_v)*OBC%ry_old_v(i,J,k) + gamma_v*rx_new
        OBC%ry_old_v(i,J,k) = rx_avg
        v_new(i,J,k) = (v_old(i,J,k) + rx_avg*v_new(i,J+1,k)) / (1.0+rx_avg)

    !   dhdt = h_old(i,J+1,k)-h_new(i,J+1,k) !old-new
    !   dhdx = h_new(i,J+1,k)-h_new(i,J+2,k) !in new time
    !   rx_new = 0.0
    !   if (dhdt*dhdx > 0.0) rx_new = min( (dhdt/dhdx), rx_max)
    !   rx_avg = (1.0-gamma_h)*OBC%ry_old_h(i,J,k) + gamma_h*rx_new
    !   OBC%ry_old_h(i,J,k) = rx_avg
    !   h_new(i,J,k) = (h_old(i,J,k) + rx_avg*h_new(i,J+1,k)) / (1.0+rx_avg) !original
      elseif (OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%radiation) then
        grad(I,J) = v_old(i+1,J,k) - v_old(i,J,k)
        grad(I-1,J) = v_old(i,J,k) - v_old(i-1,J,k)
        grad(I,J+1) = v_old(i+1,J+1,k) - v_old(i,J+1,k)
        grad(I-1,J+1) = v_old(i,J+1,k) - v_old(i-1,J+1,k)
        dhdt = v_old(i,J+1,k)-v_new(i,J+1,k) !old-new
        dhdy = v_new(i,J+1,k)-v_new(i,J+2,k) !in new time backward sasha for J+1
        if (dhdt*dhdy < 0.0) dhdt = 0.0
        if (dhdt*(grad(I,J+1) + grad(I-1,J+1)) > 0.0) then
          dhdx = grad(I-1,J+1)
        else
          dhdx = grad(I,J+1)
        endif
        cff = max(dhdx*dhdx + dhdy*dhdy, eps)
        Cy = dhdt*dhdy
        Cx = 0
        if (OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%oblique) &
             Cx = min(cff,max(dhdt*dhdx,-cff))
        v_new(i,J,k) = ((cff*v_old(i,J,k) + Cy*v_new(i,J+1,k)) - &
          (max(Cx,0.0)*grad(I-1,J) - min(Cx,0.0)*grad(I,J))) / (cff + Cy)
      endif
      if (OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%radiation .and. &
          OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%nudged) then
        if (dhdt*dhdy < 0.0) then
          tau = OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%Tnudge_in
        else
          tau = OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%Tnudge_out
        endif
        v_new(i,J,k) = v_new(i,J,k) + tau*(OBC%v(i,J,k) - v_old(i,J,k))
      endif
    endif

    if (OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%direction == OBC_DIRECTION_E) then
      if (OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%gradient .or. &
          OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%legacy) then
        v_new(i,J,k) = v_new(i-1,J,k)
      elseif (OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%radiation) then
        grad(i,j) = v_old(i,J,k) - v_old(i,J-1,k)
        grad(i,j+1) = v_old(i,J+1,k) - v_old(i,J,k)
        grad(i-1,j) = v_old(i-1,J,k) - v_old(i-1,J-1,k)
        grad(i-1,j+1) = v_old(i-1,J+1,k) - v_old(i-1,J,k)
        dhdt = v_old(i-1,J,k)-v_new(i-1,J,k) !old-new
        dhdx = v_new(i-1,J,k)-v_new(i-2,J,k) !in new time backward sasha for I+1
        if (dhdt*dhdx < 0.0) dhdt = 0.0
        if (dhdt*(grad(i-1,j) + grad(i-1,j+1)) > 0.0) then
          dhdy = grad(i-1,j)
        else
          dhdy = grad(i-1,j+1)
        endif
        cff = max(dhdx*dhdx + dhdy*dhdy, eps)
        Cx = dhdt*dhdx
        Cy = 0.0
        if (OBC%OBC_segment_number(OBC%OBC_segment_v(I,j))%oblique) &
               Cy = min(cff, max(dhdt*dhdy, -cff))
        v_new(i,J,k) = ((cff*v_old(i,J,k) + Cx*v_new(i-1,J,k)) - &
               (max(Cy, 0.0)*grad(i,j) - min(Cy, 0.0)*grad(i,j+1)))/(cff + Cx)
      endif
    endif
    if (OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%direction == OBC_DIRECTION_W) then
      if (OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%gradient .or. &
          OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%legacy) then
        v_new(i,J,k) = v_new(i+1,J,k)
      elseif (OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%radiation) then
        grad(i,j) = v_old(i,J,k) - v_old(i,J-1,k)
        grad(i+1,j) = v_old(i+1,J,k) - v_old(i+1,J-1,k)
        grad(i,j+1) = v_old(i,J+1,k) - v_old(i,J,k)
        grad(i+1,j+1) = v_old(i+1,J+1,k) - v_old(i+1,J,k)
        dhdt = v_old(i+1,J,k)-v_new(i+1,J,k) !old-new
        dhdx = v_new(i+1,J,k)-v_new(i+2,J,k) !in new time backward sasha for I+1
        if (dhdt*dhdx < 0.0) dhdt = 0.0
        if (dhdt*(grad(i+1,j) + grad(i+1,j+1)) > 0.0) then
          dhdy = grad(i+1,j)
        else
          dhdy = grad(i+1,j+1)
        endif
        cff = max(dhdx*dhdx + dhdy*dhdy, eps)
        Cx = dhdt*dhdx
        Cy = 0.0
        if (OBC%OBC_segment_number(OBC%OBC_segment_v(I,j))%oblique) &
               Cy = min(cff, max(dhdt*dhdy, -cff))
        v_new(i,J,k) = ((cff*v_old(i,J,k) + Cx*v_new(i+1,J,k)) - &
               (max(Cy, 0.0)*grad(i,j) - min(Cy, 0.0)*grad(i+1,j)))/(cff + Cx)
      endif
    endif
  endif ; enddo ; enddo ; enddo

  call cpu_clock_begin(id_clock_pass)
  call pass_vector(u_new, v_new, G%Domain)
  call pass_var(h_new, G%Domain)
  call cpu_clock_end(id_clock_pass)

end subroutine radiation_open_bdry_conds

!> Sets the initial definitions of the characteristic open boundary conditions.
!! \author Mehmet Ilicak
subroutine set_Flather_data(OBC, tv, h, G, PF, tracer_Reg)
  type(ocean_grid_type),                     intent(inout) :: G !< Ocean grid structure
  type(ocean_OBC_type),                      pointer       :: OBC !< Open boundary structure
  type(thermo_var_ptrs),                     intent(inout) :: tv !< Thermodynamics structure
  real, dimension(SZI_(G),SZJ_(G), SZK_(G)), intent(inout) :: h !< Thickness
  type(param_file_type),                     intent(in)    :: PF !< Parameter file handle
  type(tracer_registry_type),                pointer       :: tracer_Reg !< Tracer registry
  ! Local variables
  logical :: read_OBC_eta = .false.
  logical :: read_OBC_uv = .false.
  logical :: read_OBC_TS = .false.
  integer :: i, j, k, itt, is, ie, js, je, isd, ied, jsd, jed, nz
  integer :: isd_off, jsd_off
  integer :: IsdB, IedB, JsdB, JedB
  character(len=40)  :: mod = "set_Flather_data" ! This subroutine's name.
  character(len=200) :: filename, OBC_file, inputdir ! Strings for file/path

  real :: temp_u(G%domain%niglobal+1,G%domain%njglobal)
  real :: temp_v(G%domain%niglobal,G%domain%njglobal+1)

  real, pointer, dimension(:,:,:) :: &
    OBC_T_u => NULL(), &    ! These arrays should be allocated and set to
    OBC_T_v => NULL(), &    ! specify the values of T and S that should come
    OBC_S_u => NULL(), &
    OBC_S_v => NULL()

  is = G%isc ; ie = G%iec ; js = G%jsc ; je = G%jec ; nz = G%ke
  isd = G%isd ; ied = G%ied ; jsd = G%jsd ; jed = G%jed
  IsdB = G%IsdB ; IedB = G%IedB ; JsdB = G%JsdB ; JedB = G%JedB

  call get_param(PF, mod, "READ_OBC_UV", read_OBC_uv, &
                 "If true, read the values for the velocity open boundary \n"//&
                 "conditions from the file specified by OBC_FILE.", &
                 default=.false.)
  call get_param(PF, mod, "READ_OBC_ETA", read_OBC_eta, &
                 "If true, read the values for the sea surface height \n"//&
                 "open boundary conditions from the file specified by \n"//&
                 "OBC_FILE.", default=.false.)
  call get_param(PF, mod, "READ_OBC_TS", read_OBC_TS, &
                 "If true, read the values for the temperature and \n"//&
                 "salinity open boundary conditions from the file \n"//&
                 "specified by OBC_FILE.", default=.false.)
  if (read_OBC_uv .or. read_OBC_eta .or. read_OBC_TS) then
    call get_param(PF, mod, "OBC_FILE", OBC_file, &
                 "The file from which the appropriate open boundary \n"//&
                 "condition values are read.", default="MOM_OBC_FILE.nc")
    call get_param(PF, mod, "INPUTDIR", inputdir, default=".")
    inputdir = slasher(inputdir)
    filename = trim(inputdir)//trim(OBC_file)
    call log_param(PF, mod, "INPUTDIR/OBC_FILE", filename)
  endif

  if (.not.associated(OBC%vbt_outer)) then
    allocate(OBC%vbt_outer(isd:ied,JsdB:JedB)) ; OBC%vbt_outer(:,:) = 0.0
  endif

  if (.not.associated(OBC%ubt_outer)) then
    allocate(OBC%ubt_outer(IsdB:IedB,jsd:jed)) ; OBC%ubt_outer(:,:) = 0.0
  endif

  if (.not.associated(OBC%eta_outer_u)) then
    allocate(OBC%eta_outer_u(IsdB:IedB,jsd:jed)) ; OBC%eta_outer_u(:,:) = 0.0
  endif

  if (.not.associated(OBC%eta_outer_v)) then
    allocate(OBC%eta_outer_v(isd:ied,JsdB:JedB)) ; OBC%eta_outer_v(:,:) = 0.0
  endif

  if (read_OBC_uv) then
    call read_data(filename, 'ubt', OBC%ubt_outer, &
                   domain=G%Domain%mpp_domain, position=EAST_FACE)
    call read_data(filename, 'vbt', OBC%vbt_outer, &
                   domain=G%Domain%mpp_domain, position=NORTH_FACE)
  endif

  if (read_OBC_eta) then
    call read_data(filename, 'eta_outer_u', OBC%eta_outer_u, &
                   domain=G%Domain%mpp_domain, position=EAST_FACE)
    call read_data(filename, 'eta_outer_v', OBC%eta_outer_v, &
                   domain=G%Domain%mpp_domain, position=NORTH_FACE)
  endif

  call pass_vector(OBC%eta_outer_u,OBC%eta_outer_v,G%Domain, To_All+SCALAR_PAIR, CGRID_NE)
  call pass_vector(OBC%ubt_outer,OBC%vbt_outer,G%Domain)

  ! Define radiation coefficients r[xy]_old_[uvh] as needed.  For now, there are
  ! no radiation conditions applied to the thicknesses, since the thicknesses
  ! might not be physically motivated.  Instead, sponges should be used to
  ! enforce the near-boundary layer structure.
  if (OBC%Flather_u_BCs_exist_globally) then
    allocate(OBC%rx_old_u(IsdB:IedB,jsd:jed,nz)) ; OBC%rx_old_u(:,:,:) = 0.0
 !   allocate(OBC%rx_old_h(Isd:Ied,jsd:jed,nz))   ; OBC%rx_old_h(:,:,:) = 0.0
  endif
  if (OBC%Flather_v_BCs_exist_globally) then
    allocate(OBC%ry_old_v(isd:ied,JsdB:JedB,nz)) ; OBC%ry_old_v(:,:,:) = 0.0
 !   allocate(OBC%ry_old_h(isd:ied,Jsd:Jed,nz))   ; OBC%ry_old_h(:,:,:) = 0.0
  endif

  if (associated(tv%T)) then
    allocate(OBC_T_u(IsdB:IedB,jsd:jed,nz)) ; OBC_T_u(:,:,:) = 0.0
    allocate(OBC_S_u(IsdB:IedB,jsd:jed,nz)) ; OBC_S_u(:,:,:) = 0.0
    allocate(OBC_T_v(isd:ied,JsdB:JedB,nz)) ; OBC_T_v(:,:,:) = 0.0
    allocate(OBC_S_v(isd:ied,JsdB:JedB,nz)) ; OBC_S_v(:,:,:) = 0.0

    if (read_OBC_TS) then
      call read_data(filename, 'OBC_T_u', OBC_T_u, &
                     domain=G%Domain%mpp_domain, position=EAST_FACE)
      call read_data(filename, 'OBC_S_u', OBC_S_u, &
                     domain=G%Domain%mpp_domain, position=EAST_FACE)

      call read_data(filename, 'OBC_T_v', OBC_T_v, &
                     domain=G%Domain%mpp_domain, position=NORTH_FACE)
      call read_data(filename, 'OBC_S_v', OBC_S_v, &
                     domain=G%Domain%mpp_domain, position=NORTH_FACE)
    else
      call pass_var(tv%T, G%Domain)
      call pass_var(tv%S, G%Domain)
      do k=1,nz ; do j=js,je ; do I=is-1,ie
        if (OBC%OBC_segment_u(I,j) /= OBC_NONE) then
          if (OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%direction == OBC_DIRECTION_E) then
            OBC_T_u(I,j,k) = tv%T(i,j,k)
            OBC_S_u(I,j,k) = tv%S(i,j,k)
          elseif (OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%direction == OBC_DIRECTION_W) then
            OBC_T_u(I,j,k) = tv%T(i+1,j,k)
            OBC_S_u(I,j,k) = tv%S(i+1,j,k)
          elseif (G%mask2dT(i,j) + G%mask2dT(i+1,j) > 0) then
            OBC_T_u(I,j,k) = (G%mask2dT(i,j)*tv%T(i,j,k) + G%mask2dT(i+1,j)*tv%T(i+1,j,k)) / &
                             (G%mask2dT(i,j) + G%mask2dT(i+1,j))
            OBC_S_u(I,j,k) = (G%mask2dT(i,j)*tv%S(i,j,k) + G%mask2dT(i+1,j)*tv%S(i+1,j,k)) / &
                             (G%mask2dT(i,j) + G%mask2dT(i+1,j))
          else ! This probably shouldn't happen or maybe it doesn't matter?
            OBC_T_u(I,j,k) = 0.5*(tv%T(i,j,k)+tv%T(i+1,j,k))
            OBC_S_u(I,j,k) = 0.5*(tv%S(i,j,k)+tv%S(i+1,j,k))
          endif
        else
          OBC_T_u(I,j,k) = 0.5*(tv%T(i,j,k)+tv%T(i+1,j,k))
          OBC_S_u(I,j,k) = 0.5*(tv%S(i,j,k)+tv%S(i+1,j,k))
        endif
      enddo; enddo ; enddo

      do k=1,nz ; do J=js-1,je ; do i=is,ie
        if (OBC%OBC_segment_v(i,J) /= OBC_NONE) then
          if (OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%direction == OBC_DIRECTION_N) then
            OBC_T_v(i,J,k) = tv%T(i,j,k)
            OBC_S_v(i,J,k) = tv%S(i,j,k)
          elseif (OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%direction == OBC_DIRECTION_S) then
            OBC_T_v(i,J,k) = tv%T(i,j+1,k)
            OBC_S_v(i,J,k) = tv%S(i,j+1,k)
          elseif (G%mask2dT(i,j) + G%mask2dT(i,j+1) > 0) then
            OBC_T_v(i,J,k) = (G%mask2dT(i,j)*tv%T(i,j,k) + G%mask2dT(i,j+1)*tv%T(i,j+1,k)) / &
                             (G%mask2dT(i,j) + G%mask2dT(i,j+1))
            OBC_S_v(i,J,k) = (G%mask2dT(i,j)*tv%S(i,j,k) + G%mask2dT(i,j+1)*tv%S(i,j+1,k)) / &
                             (G%mask2dT(i,j) + G%mask2dT(i,j+1))
          else ! This probably shouldn't happen or maybe it doesn't matter?
            OBC_T_v(i,J,k) = 0.5*(tv%T(i,j,k)+tv%T(i,j+1,k))
            OBC_S_v(i,J,k) = 0.5*(tv%S(i,j,k)+tv%S(i,j+1,k))
          endif
        else
          OBC_T_v(i,J,k) = 0.5*(tv%T(i,j,k)+tv%T(i,j+1,k))
          OBC_S_v(i,J,k) = 0.5*(tv%S(i,j,k)+tv%S(i,j+1,k))
        endif
      enddo; enddo ; enddo
    endif

    call pass_vector(OBC_T_u, OBC_T_v, G%Domain, To_All+SCALAR_PAIR, CGRID_NE)
    call pass_vector(OBC_S_u, OBC_S_v, G%Domain, To_All+SCALAR_PAIR, CGRID_NE)

    call add_tracer_OBC_values("T", tracer_Reg, OBC_in_u=OBC_T_u, &
                                                OBC_in_v=OBC_T_v)
    call add_tracer_OBC_values("S", tracer_Reg, OBC_in_u=OBC_S_u, &
                                                OBC_in_v=OBC_S_v)
    do k=1,nz ; do j=jsd,jed ; do I=isd,ied-1
      if (OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%direction == OBC_DIRECTION_E) then
        tv%T(i+1,j,k) = tv%T(i,j,k) ; tv%S(i+1,j,k) = tv%S(i,j,k)
      elseif (OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%direction == OBC_DIRECTION_W) then
        tv%T(i,j,k) = tv%T(i+1,j,k) ; tv%S(i,j,k) = tv%S(i+1,j,k)
      endif
    enddo ; enddo ; enddo
    do k=1,nz ; do J=jsd,jed-1 ; do i=isd,ied
      if (OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%direction == OBC_DIRECTION_N) then
        tv%T(i,j+1,k) = tv%T(i,j,k) ; tv%S(i,j+1,k) = tv%S(i,j,k)
      elseif (OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%direction == OBC_DIRECTION_S) then
        tv%T(i,j,k) = tv%T(i,j+1,k) ; tv%S(i,j,k) = tv%S(i,j+1,k)
      endif
    enddo ; enddo ; enddo
  endif

  do k=1,nz ; do j=jsd,jed ; do I=isd,ied-1
    if (OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%direction == OBC_DIRECTION_E) &
                        h(i+1,j,k) = h(i,j,k)
    if (OBC%OBC_segment_number(OBC%OBC_segment_u(I,j))%direction == OBC_DIRECTION_W) &
                        h(i,j,k) = h(i+1,j,k)
  enddo ; enddo ; enddo
  do k=1,nz ; do J=jsd,jed-1 ; do i=isd,ied
    if (OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%direction == OBC_DIRECTION_N) &
                       h(i,j+1,k) = h(i,j,k)
    if (OBC%OBC_segment_number(OBC%OBC_segment_v(i,J))%direction == OBC_DIRECTION_S) &
                       h(i,j,k) = h(i,j+1,k)
  enddo ; enddo ; enddo
! When we do not extend segments, this commented block was needed to
! get the same'ish h's.
! do k=1,nz ; do j=jsd,jed-1 ; do i=isd,ied
!   if (OBC%OBC_direction_v(i,J) == OBC_DIRECTION_N) h(i,j+1,k) = h(i,j,k)
! enddo ; enddo ; enddo
! do k=1,nz ; do j=jsd+1,jed ; do i=isd,ied
!   if (OBC%OBC_direction_v(i,J-1) == OBC_DIRECTION_S) h(i,j-1,k) = h(i,j,k)
! enddo ; enddo ; enddo
! do k=1,nz ; do j=jsd,jed ; do i=isd,ied-1
!   if (OBC%OBC_direction_u(I,j) == OBC_DIRECTION_E) h(i+1,j,k) = h(i,j,k)
! enddo ; enddo ; enddo
! do k=1,nz ; do j=jsd,jed ; do i=isd+1,ied
!   if (OBC%OBC_direction_u(I-1,j) == OBC_DIRECTION_W) h(i-1,j,k) = h(i,j,k)
! enddo ; enddo ; enddo
! do k=1,nz ; do j=jsd,jed-1 ; do i=isd,ied-1
!   if (OBC%OBC_direction_v(i,J) == OBC_DIRECTION_N .and. &
!       OBC%OBC_direction_u(I,j) == OBC_DIRECTION_E) h(i+1,j+1,k) = h(i,j,k)
! enddo ; enddo ; enddo
! do k=1,nz ; do j=jsd,jed-1 ; do i=isd+1,ied
!   if (OBC%OBC_direction_v(i,J) == OBC_DIRECTION_N .and. &
!       OBC%OBC_direction_u(I-1,j) == OBC_DIRECTION_W) h(i-1,j+1,k) = h(i,j,k)
! enddo ; enddo ; enddo
! do k=1,nz ; do j=jsd+1,jed ; do i=isd,ied-1
!   if (OBC%OBC_direction_v(i,J-1) == OBC_DIRECTION_S .and. &
!       OBC%OBC_direction_u(I,j) == OBC_DIRECTION_E) h(i+1,j-1,k) = h(i,j,k)
! enddo ; enddo ; enddo
! do k=1,nz ; do j=jsd+1,jed ; do i=isd+1,ied
!   if (OBC%OBC_direction_v(i,J-1) == OBC_DIRECTION_S .and. &
!       OBC%OBC_direction_u(I-1,j) == OBC_DIRECTION_W) h(i-1,j-1,k) = h(i,j,k)
! enddo ; enddo ; enddo

end subroutine set_Flather_data

subroutine update_OBC_segment_data(G, GV, OBC, h, Time)

  type(ocean_grid_type),                     intent(inout) :: G !< Ocean grid structure
  type(verticalGrid_type),                   intent(in)    :: GV
  type(ocean_OBC_type),                      pointer       :: OBC !< Open boundary structure
  real, dimension(SZI_(G),SZJ_(G), SZK_(G)), intent(inout) :: h !< Thickness
  type(time_type),                           intent(in)    :: Time
  ! Local variables

  integer :: i, j, k, is, ie, js, je, isd, ied, jsd, jed
  integer :: IsdB, IedB, JsdB, JedB, n, m
  character(len=40)  :: mod = "set_OBC_segment_data" ! This subroutine's name.
  character(len=200) :: filename, OBC_file, inputdir ! Strings for file/path
  type(OBC_segment_type), pointer :: segment
  integer, dimension(4) :: siz  
  integer :: ni_src, nj_src  ! number of src gridpoints along the segments
  
                               
  is = G%isc ; ie = G%iec ; js = G%jsc ; je = G%jec
  isd = G%isd ; ied = G%ied ; jsd = G%jsd ; jed = G%jed
  IsdB = G%IsdB ; IedB = G%IedB ; JsdB = G%JsdB ; JedB = G%JedB

   do n = 1, OBC%number_of_segments
      segment => OBC%OBC_segment_number(n)
      do m = 1,segment%num_fields
           ! move this to segment initialization
           if (.not.associated(segment%field(m)%buffer_dst)) then
              siz(1)=size(segment%field(m)%buffer_src,1)
              siz(2)=size(segment%field(m)%buffer_src,2)
              if (segment%field(m)%nk_src == 1) then
                 allocate(segment%field(m)%buffer_dst(siz(1),siz(2),GV%ke))
              else
                 allocate(segment%field(m)%buffer_dst(siz(1),siz(2),1))
              endif
              segment%field(m)%buffer_dst(:,:,:)=0.0
           endif
           ! read source data interpolated to the current model time
           call time_interp_external(segment%field(m)%fid,Time, segment%field(m)%buffer_src)

           nj_src=size(segment%field(m)%buffer_dst,2)
           ni_src=size(segment%field(m)%buffer_dst,1)

           if (segment%field(m)%nk_src > 1) then
             call time_interp_external(segment%field(m)%fid_dz,Time, segment%field(m)%dz_src)
             do j=1,nj_src
                do i=1,ni_src
                  ! Using the h remapping approach
                  ! Pretty sure we need to check for source/target grid consistency here
                  segment%field(m)%buffer_dst(i,j,:)=0.0  ! initialize remap destination buffer
                  if (G%mask2dT(i,j)>0.) then
                     call remapping_core_h(segment%field(m)%nk_src,segment%field(m)%dz_src(i,j,:),&
                           segment%field(m)%buffer_src(i,j,:),GV%ke, h(i,j,:),&
                           segment%field(m)%buffer_dst(i,j,:),OBC%remap_CS)
                  endif
                enddo
             enddo
           else  ! 2d data
             segment%field(m)%buffer_dst(:,:,1)=segment%field(m)%buffer_src(:,:,1)  ! initialize remap destination buffer
           endif
      enddo ! end field loop
    enddo

end subroutine update_OBC_segment_data

!> \namespace mom_open_boundary
!! This module implements some aspects of internal open boundary
!! conditions in MOM.
!!
!! A small fragment of the grid is shown below:
!!
!!    j+1  x ^ x ^ x   At x:  q, CoriolisBu
!!    j+1  > o > o >   At ^:  v, tauy
!!    j    x ^ x ^ x   At >:  u, taux
!!    j    > o > o >   At o:  h, bathyT, buoy, tr, T, S, Rml, ustar
!!    j-1  x ^ x ^ x
!!        i-1  i  i+1  At x & ^:
!!           i  i+1    At > & o:
!!
!! The boundaries always run through q grid points (x).

end module MOM_open_boundary
