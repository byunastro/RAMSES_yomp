module pm_parameters
  use amr_parameters, ONLY: dp, i8b
  integer::nsinkmax=0               ! Maximum number of sinks
  integer::npartmax=0               ! Maximum number of particles
  integer::npart=0                  ! Actual number of particles
  integer::nsink=0                  ! Actual number of sinks
  integer::iseed=0                  ! Seed for stochastic star formation
  integer::tseed=0                  ! Seed for MC tracers
  integer(i8b)::nstar_tot=0         ! Total number of star particle
  real(dp)::mstar_tot=0             ! Total star mass
  real(dp)::mstar_lost=0            ! Missing star mass

  integer::ntracer_tot=0            ! Total number of tracers
  integer::npartmax_rho=10000       ! Maximum number of particles in single grid to compute rho
                                    ! Exceeding grid particles are randomly sampled by this number

  ! More sink related parameters, can all be set in namelist file

  integer::ir_cloud=4                        ! Radius of cloud region in unit of grid spacing (i.e. the ACCRETION RADIUS)
  integer::ir_cloud_massive=3                ! Radius of massive cloud region in unit of grid spacing for PM sinks
  real(dp)::sink_soft=2.d0                   ! Sink grav softening length in dx at levelmax for "direct force" sinks
  real(dp)::mass_sink_direct_force=-1.d0     ! mass above which sinks are treated as "direct force" objects

  logical::create_sinks=.false.              ! turn formation of new sinks on

  real(dp)::merging_timescale=-1.d0          ! time during which sinks are considered for merging (only when 'timescale' is used),                                             ! used also as contraction timescale in creation
  real(dp)::cont_speed=0.

  character(LEN=15)::accretion_scheme='none' ! Sink accretion scheme; options: 'none', 'flux', 'bondi', 'threshold'
  logical::flux_accretion=.false.
  logical::threshold_accretion=.false.
  logical::bondi_accretion=.false.

  logical::nol_accretion=.false.             ! Leave angular momentum in the gas at accretion
  real(dp)::mass_sink_seed=0.0               ! Initial sink mass. If < 0, use the AGN feedback based recipe
  real(dp)::c_acc=-1.0                       ! "courant factor" for sink accretion time step control.
                                             ! gives fration of available gas that can be accreted in one timestep.

  logical::sink_drag=.false.                 ! Gas dragging sink
  logical::clump_core=.false.                ! Trims the clump (for star formation)
  logical::verbose_AGN=.false.               ! Controls print verbosity for the SMBH case
  real(dp)::acc_sink_boost=1.0               ! Boost coefficient for accretion
  real(dp)::mass_merger_vel_check_AGN=-1.0   ! Threshold for velocity check in  merging; in Msun; default: don't check

  character(LEN=15)::feedback_scheme='energy' ! AGN feedback scheme; options: 'energy' or 'momentum'
  real(dp)::T2_min=1.d7                      ! Minimum temperature of the gas to trigger AGN blast; in K
  real(dp)::T2_max=1.d9                      ! Maximum allowed temperature of the AGN blast; in K
  real(dp)::T2_AGN=1.d12                     ! AGN blast temperature; in K

  real(dp)::v_max=5.d4                       ! Maximum allowed velocity of the AGN blast; in km/s
  real(dp)::v_AGN=1.d4                       ! AGN blast velocity; in km/s
  real(dp)::cone_opening=180.                ! Outflow cone opening angle; in deg

  real(dp)::mass_halo_AGN=1.d10              ! Minimum mass of the halo for sink creation
  real(dp)::mass_clump_AGN=1.d10             ! Minimum mass of the clump for sink creation

  type part_t
     ! We store these two things contiguously in memory
     ! because they are fetched at similar times
     integer(1) :: family
     integer(1) :: tag
  end type part_t

  ! MC Tracer
  character(LEN=1025) :: tracer_feed             ! Filename to read the tracer from
  character(LEN=  10) :: tracer_feed_fmt='ascii' ! Format of the input (ascii or binary)
  real(dp)::tracer_mass=-1.0                     ! Mass of the tracers, used for outputs and seed

  integer :: tracer_first_balance_levelmin = -1  ! Set to >0 to add more weight on level finer than this
  integer :: tracer_first_balance_part_per_cell = 0 ! Typical initial number of parts per cell
  real(dp):: tracer_per_cell = -1.0              ! Initial number of tracer parts per cell (active only for 'inplace' and tracer_mass is not set)
  integer :: tracer_level = -1                   ! Level of cell that puts tracer on (active only with tracer_per_cell)
  logical :: no_init_gas_tracer=.false.
end module pm_parameters
