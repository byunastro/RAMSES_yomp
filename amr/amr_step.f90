recursive subroutine amr_step(ilevel,icount)
  use amr_commons
  use pm_commons
  use hydro_commons
  use poisson_commons
#ifdef RT
  use rt_hydro_commons
  use SED_module
  use UV_module
  use coolrates_module, only: update_coolrates_tables
  use rt_cooling_module, only: update_UVrates
#endif
  use mpi_mod
  use sink_particle_tracer, only : MC_tracer_to_jet
  implicit none
#ifndef WITHOUTMPI
  integer::mpi_err
#endif
  integer, intent(in) :: ilevel, icount
  !-------------------------------------------------------------------!
  ! This routine is the adaptive-mesh/adaptive-time-step main driver. !
  ! Each routine is called using a specific order, don't change it,   !
  ! unless you check all consequences first                           !
  !-------------------------------------------------------------------!
  integer::i,idim,ivar
  logical::ok_defrag,output_now_all,stop_next_all
  logical,save::first_step=.true.
  character(LEN=80)::str
  real(dp)::scale_l,scale_t,scale_d,scale_v,scale_nH,scale_T2

  ! Conversion factor from user units to cgs units
  if(numbtot(1,ilevel)==0)return

  if(verbose)write(*,999)icount,ilevel

  call units(scale_l,scale_t,scale_d,scale_v,scale_nH,scale_T2)

  if(checkhydro)call check_uold_unew(ilevel,0)
  !-------------------------------------------
  ! Make new refinements and update boundaries
  !-------------------------------------------
                               call timer('refine','start')
  if(levelmin.lt.nlevelmax .and.(.not.static.or.(nstep_coarse_old.eq.nstep_coarse.and.restart_remap)))then
     if(ilevel==levelmin.or.icount>1)then
        do i=ilevel,nlevelmax
           if(i>levelmin)then

              !--------------------------
              ! Build communicators
              !--------------------------
              call build_comm(i)

              !--------------------------
              ! Update boundaries
              !--------------------------
              call make_virtual_fine_int(cpu_map(1),i)
              if(hydro)then
#ifdef SOLVERmhd
                 do ivar=1,nvar+3
#else
                 do ivar=1,nvar
#endif
                    call make_virtual_fine_dp(uold(1,ivar),i)
#ifdef SOLVERmhd
                 end do
#else
                 end do
#endif
                 if(momentum_feedback)call make_virtual_fine_dp(pstarold(1),i)
                 if(simple_boundary)call make_boundary_hydro(i)
              end if
#ifdef RT
              if(rt)then
                 do ivar=1,nrtvar
                    call make_virtual_fine_dp(rtuold(1,ivar),i)
                 end do
                 if(simple_boundary)call rt_make_boundary_hydro(i)
              end if
#endif
              if(poisson)then
                 call make_virtual_fine_dp(phi(1),i)
                 do idim=1,ndim
                    call make_virtual_fine_dp(f(1,idim),i)
                 end do
                 if(simple_boundary)call make_boundary_force(i)
              end if
           end if

           !--------------------------
           ! Refine grids
           !--------------------------
           call refine_fine(i)
        end do
     end if
  end if

  !--------------------------
  ! Load balance
  !--------------------------
                               call timer('load balance','start')
  ok_defrag=.false.
  if(levelmin.lt.nlevelmax)then

     if(ilevel==levelmin)then
        if(nremap>0)then
           ! Skip first load balance because it has been performed before file dump
           if(nrestart>0.and.first_step)then
              if(nrestart.eq.nrestart_quad) restart_remap=.true.
              if(restart_remap) then
                 call load_balance
                 call defrag
                 ok_defrag=.true.
              endif
              first_step=.false.
           else
              if(MOD(nstep_coarse,nremap)==0)then
                 call load_balance
                 call defrag
                 ok_defrag=.true.
              endif
           end if
        end if
     endif
  end if

  !-----------------
  ! Particle leakage
  !-----------------
                               call timer('particles - make','start')
  if(pic)call make_tree_fine(ilevel)

  !------------------------
  ! Output results to files
  !------------------------
  if(ilevel==levelmin)then

#ifdef WITHOUTMPI
     output_now_all = output_now
#else
     ! check if any of the processes received a signal for output
     call MPI_BARRIER(MPI_COMM_WORLD,mpi_err)
     call MPI_ALLREDUCE(output_now,output_now_all,1,MPI_LOGICAL,MPI_LOR,MPI_COMM_WORLD,mpi_err)
     call MPI_ALLREDUCE(stop_next,stop_next_all,1,MPI_LOGICAL,MPI_LOR,MPI_COMM_WORLD,mpi_err)
#endif
     if(mod(nstep_coarse,foutput)==0.or.aexp>=aout(iout).or.t>=tout(iout).or.output_now_all.EQV..true.)then
                               call timer('io','start')
        if(.not.ok_defrag)then
           call defrag
        endif

        ! Run the clumpfinder, (produce output, don't keep arrays alive on output)
        ! CAREFUL: create_output is used to destinguish between the case where
        ! the clumpfinder is called from create_sink or directly from amr_step.
#if NDIM==3
        if(clumpfind .and. ndim==3) call clump_finder(.true.,.false.)
#endif

        if(output) call dump_all

        ! Dump lightcone
        if(lightcone .and. ndim==3) call output_cone()

        if (output_now_all.EQV..true.) then
           output_now=.false.
           if (dump_stop) then
              call clean_stop
           endif
        endif

        if(stop_next_all) then
           call clean_stop
        endif

     endif
     if(foutput_timer>0.and.mod(nstep_coarse,foutput_timer)==0)then
        call output_timer(.false.,str)
     endif
  endif

  !----------------------------
  ! Output frame to movie dump (without synced levels)
  !----------------------------
  if(movie) then
     if(imov.le.imovout)then
        if(aexp>=amovout(imov).or.t>=tmovout(imov))then
                               call timer('movie','start')
           call output_frame()
        endif
     endif
  end if

  !-----------------------------------------------------------
  ! Put here all stuffs that are done only at coarse time step
  !-----------------------------------------------------------
  if(ilevel==levelmin)then
                               call timer('star - feedback','start')
     if (hydro .and. star .and. eta_sn>0 .and. f_w>0 .and. (.not.mechanical_feedback)) then
     !----------------------------------------------------
     ! Kinetic feedback
     !----------------------------------------------------
        call kinetic_feedback
     endif

     if(sink) then
        if (sink_AGN .and. (.not. finestep_AGN)) &
                               call timer('sinks - feedback','start')
             call AGN_feedback
        !-----------------------------------------------------
        ! Create sink particles and associated cloud particles
        !-----------------------------------------------------
                               call timer('sinks - create','start')
        call create_sink
     end if
  endif

  !--------------------
  ! Poisson source term
  !--------------------
  if(poisson)then
                               call timer('poisson - save phi','start')
     !save old potential for time-extrapolation at level boundaries
     call save_phi_old(ilevel)
                               call timer('particles - cic','start')
     call rho_fine(ilevel,icount)
  endif

  !-------------------------------------------
  ! Sort particles between ilevel and ilevel+1
  !-------------------------------------------
  if(pic)then
     ! Remove particles to finer levels
                               call timer('particles - kill','start')
     call kill_tree_fine(ilevel)
                               call timer('particles - virtual tree','start')
     ! Update boundary conditions for remaining particles
     call virtual_tree_fine(ilevel)
  end if

  !---------------
  ! Gravity update
  !---------------
  if(poisson)then
                               call timer('poisson - synchro hydro','start')

     ! Remove gravity source term with half time step and old force
     if(hydro)then
        call synchro_hydro_fine(ilevel,-0.5*dtnew(ilevel))
     endif

     ! Compute gravitational potential
                               call timer('poisson - mg','start')
     if(ilevel>levelmin)then
        if(ilevel .ge. cg_levelmin) then
                               call timer('poisson - cg','start')
           call phi_fine_cg(ilevel,icount)
        else
           call multigrid_fine(ilevel,icount)
        end if
     else
        call multigrid_fine(levelmin,icount)
     end if
     !when there is no old potential...
                               call timer('poisson - save phi','start')
     if (nstep==0)call save_phi_old(ilevel)

                               call timer('poisson - force fine','start')
     ! Compute gravitational acceleration
     call force_fine(ilevel,icount)

     ! Mechanical feedback from stars
                               call timer('star - feedback','start')

     if(hydro.and.star.and. mechanical_feedback) then
        if(checkhydro)call check_uold_unew(ilevel,10)
        call mechanical_feedback_fine(ilevel,icount)
        if(checkhydro)call check_uold_unew(ilevel,11)
        if (snIa) call mechanical_feedback_snIa_fine(ilevel,icount)
        if(checkhydro)call check_uold_unew(ilevel,12)

#ifdef SOLVERmhd
        do ivar=1,nvar+3
#else
        do ivar=1,nvar
#endif
           call make_virtual_fine_dp(uold(1,ivar),ilevel)
#ifdef SOLVERmhd
        end do
#else
        end do
#endif

     endif

     ! Synchronize remaining particles for gravity
     if(pic)then
                               call timer('particles - synchro','start')
        if(static_dm.or.static_stars)then
           call synchro_fine_static(ilevel)
        else
           call synchro_fine(ilevel)
        end if
     end if

     if(hydro)then
                               call timer('poisson - synchro hydro','start')

        ! Add gravity source term with half time step and new force
        call synchro_hydro_fine(ilevel,+0.5*dtnew(ilevel))


        ! Density threshold and/or Bondi accretion onto sink particle
        if(sink)then
           if(bondi .or. maximum_accretion) then
                               call timer('sinks - drag','start')
              if (drag_part) call get_drag_part(ilevel)  ! HP
                               call timer('sinks - grow','start')
              call grow_bondi(ilevel)
           else
              call grow_jeans(ilevel)
           endif
           if(finestep_AGN.and.sink_AGN)then
              call AGN_feedback
           endif

        endif

        ! Update boundaries
                               call timer('hydro - ghostzones','start')
#ifdef SOLVERmhd
        do ivar=1,nvar+3
#else
        do ivar=1,nvar
#endif
           call make_virtual_fine_dp(uold(1,ivar),ilevel)
#ifdef SOLVERmhd
        end do
#else
        end do
#endif
        if(simple_boundary)call make_boundary_hydro(ilevel)

     end if
  end if

#ifdef RT
  ! Turn on RT in case of rt_stars and first stars just created:
  ! Update photon packages according to star particles
                               call timer('radiative transfer','start')
  if(rt .and. (rt_star .or. rt_AGN)) call update_star_RT_feedback(ilevel)
#endif



  !----------------------
  ! Compute new time step
  !----------------------
                               call timer('courant','start')
  call newdt_fine(ilevel)
  if(ilevel>levelmin)then
     dtnew(ilevel)=MIN(dtnew(ilevel-1)/real(nsubcycle(ilevel-1)),dtnew(ilevel))
     if(dtnew(ilevel)<dtstop)then
         write(*,*) 'dtnew=', dtnew(ilevel), 'stopping...'
         call clean_stop
     end if
  end if
  ! Set unew equal to uold
                               call timer('hydro - set unew','start')
  if(hydro)call set_unew(ilevel)

#ifdef RT
  ! Set rtunew equal to rtuold
                               call timer('radiative transfer','start')
  if(rt)call rt_set_unew(ilevel)
#endif

  !---------------------------
  ! Recursive call to amr_step
  !---------------------------
  if(ilevel<nlevelmax)then
     if(numbtot(1,ilevel+1)>0)then
        if(nsubcycle(ilevel)==2)then
           call amr_step(ilevel+1,1)
           call amr_step(ilevel+1,2)
        else
           call amr_step(ilevel+1,1)
        endif
     else
        ! Otherwise, update time and finer level time-step
        dtold(ilevel+1)=dtnew(ilevel)/dble(nsubcycle(ilevel))
        dtnew(ilevel+1)=dtnew(ilevel)/dble(nsubcycle(ilevel))
        call update_time(ilevel)
     end if
  else
     call update_time(ilevel)
  end if

#if NDIM==3
  ! Thermal feedback from stars (also call if no feedback, for bookkeeping)
  if(hydro .and. star .and. f_w==0.0 .and. (.not.mechanical_feedback)) then
                               call timer('star - feedback','start')
     !call thermal_feedback(ilevel)
  endif
#endif

  if(checkhydro)call check_uold_unew(ilevel,20)
  ! Stellar winds from stars
                               call timer('star - feedback','start')
  if(hydro.and.star.and.stellar_winds) call stellar_winds_fine(ilevel)
  if(checkhydro)call check_uold_unew(ilevel,21)




  !-----------
  ! Hydro step
  !-----------
  if((hydro).and.(.not.static_gas))then

     if(checkhydro)call check_uold_unew(ilevel,30)
     ! Hyperbolic solver
                               call timer('hydro - godunov','start')
     if(.not.frozen)call godunov_fine(ilevel)

     ! Reverse update boundaries
                               call timer('hydro - rev ghostzones','start')
     if(checkhydro)call check_uold_unew(ilevel,31)


#ifdef SOLVERmhd
     do ivar=1,nvar+3
#else
     do ivar=1,nvar
#endif
        call make_virtual_reverse_dp(unew(1,ivar),ilevel)
#ifdef SOLVERmhd
     end do
#else
     end do
#endif
     ! MC Tracer
     ! Communicate fluxes accross boundaries
     if(MC_tracer)then
                                call timer('tracer','start')
        do ivar=1,twondim
           call make_virtual_reverse_dp(fluxes(1,ivar),ilevel-1)
           call make_virtual_fine_dp(fluxes(1,ivar),ilevel-1)
        end do
     end if

     if(momentum_feedback)then
        call make_virtual_reverse_dp(pstarnew(1),ilevel)
     endif

     if(pressure_fix)then
        call make_virtual_reverse_dp(enew(1),ilevel)
        call make_virtual_reverse_dp(divu(1),ilevel)
     endif

     ! Set uold equal to unew
                               call timer('hydro - set uold','start')
     call set_uold(ilevel)

     ! Add gravity source term with half time step and old force
     ! in order to complete the time step
                               call timer('poisson - synchro hydro','start')
     if(poisson)call synchro_hydro_fine(ilevel,+0.5*dtnew(ilevel))

     ! Restriction operator
                               call timer('hydro upload fine','start')
     call upload_fine(ilevel)

  endif

  !---------------------
  ! Do RT/Chemistry step
  !---------------------
#ifdef RT
  if(rt .and. rt_advect) then
                               call timer('radiative transfer','start')
     call rt_step(ilevel)
  else
     ! Still need a chemistry call if RT is defined but not
     ! actually doing radiative transfer (i.e. rt==false):
                               call timer('cooling','start')
     if(neq_chem.or.cooling.or.T2_star>0.0)call cooling_fine(ilevel)
  endif
  ! Regular updates and book-keeping:
  if(ilevel==levelmin) then
                               call timer('radiative transfer','start')
     if(cosmo) call update_rt_c
     if(cosmo .and. haardt_madau) call update_UVrates(aexp)
     if(cosmo .and. rt_isDiffuseUVsrc) call update_UVsrc
                               call timer('cooling','start')
     if(cosmo) call update_coolrates_tables(dble(aexp))
                               call timer('radiative transfer','start')
     if(ilevel==levelmin) call output_rt_stats
  endif
#else
  if(checkhydro)call check_uold_unew(ilevel,40)
                               call timer('cooling','start')
  if((hydro).and.(.not.static_gas)) then
    if(neq_chem.or.cooling.or.T2_star>0.0)call cooling_fine(ilevel)
  endif
  if(checkhydro)call check_uold_unew(ilevel,41)
#endif

  !---------------
  ! Move particles
  !---------------
  ! Move other particles
                               call timer('particles - move fine','start')
  if(pic)then
     if(static_dm.or.static_stars)then
        call move_fine_static(ilevel) ! Only remaining particles
     else
        call move_fine(ilevel) ! Only remaining particles
     end if
  end if
  ! Move tracer particles in the jet.
  if (sink_AGN .and. MC_tracer) then
                                call timer('tracer','start')
     call MC_tracer_to_jet(ilevel)
  end if


  !----------------------------------
  ! Star formation in leaf cells only
  !----------------------------------
  if(checkhydro)call check_uold_unew(ilevel,50)
                               call timer('star - formation','start')
  if(hydro.and.star.and.(.not.static_gas))call star_formation(ilevel)
  if(checkhydro)call check_uold_unew(ilevel,51)

  ! Compute Bondi-Hoyle accretion parameters
                               call timer('sinks - accretion','start')
  if(sink.and.bondi)call bondi_hoyle(ilevel)

  !---------------------------------------
  ! Update physical and virtual boundaries
  !---------------------------------------
  if((hydro).and.(.not.static_gas))then
                               call timer('hydro - ghostzones','start')
#ifdef SOLVERmhd
     do ivar=1,nvar+3
#else
     do ivar=1,nvar
#endif
        call make_virtual_fine_dp(uold(1,ivar),ilevel)
#ifdef SOLVERmhd
     end do
#else
     end do
#endif
     if(momentum_feedback)call make_virtual_fine_dp(pstarold(1),ilevel)
     if(simple_boundary)call make_boundary_hydro(ilevel)
  endif

#ifdef SOLVERmhd
  ! Magnetic diffusion step
  if((hydro).and.(.not.static_gas))then
     if(eta_mag>0d0.and.ilevel==levelmin)then
                               call timer('hydro - diffusion','start')
        call diffusion
     endif
  end if
#endif

  !-----------------------
  ! Compute refinement map
  !-----------------------
                               call timer('flag','start')
  if(.not.static.or.(nstep_coarse_old.eq.nstep_coarse.and.restart_remap)) call flag_fine(ilevel,icount)

  !----------------------------
  ! Merge finer level particles
  !----------------------------
                               call timer('particles - merge','start')
  if(pic)call merge_tree_fine(ilevel)

  !---------------
  ! Radiation step
  !---------------
#ifdef ATON
  if(aton.and.ilevel==levelmin)then
                               call timer('aton','start')
     call rad_step(dtnew(ilevel))
  endif
#endif

  !-------------------------------
  ! Update coarser level time-step
  !-------------------------------
  if(ilevel>levelmin)then
     if(nsubcycle(ilevel-1)==1)dtnew(ilevel-1)=dtnew(ilevel)
     if(icount==2)dtnew(ilevel-1)=dtold(ilevel)+dtnew(ilevel)
  end if

  ! Reset move flag flag
  if(MC_tracer) then
                                call timer('tracer','start')
     ! Decrease the move flag by 1
     call reset_tracer_move_flag(ilevel)
  end if

#if NDUST>0
  if(ilevel==levelmin) then
  if(dtnew(ilevel).gt.0.0d0)then
#ifndef WITHOUTMPI
     call MPI_ALLREDUCE(dM_acc,dM_acc_all,ndust,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,mpi_err)
     dM_acc=dM_acc_all
     call MPI_ALLREDUCE(dM_spu,dM_spu_all,ndust,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,mpi_err)
     dM_spu=dM_spu_all
     call MPI_ALLREDUCE(dM_coa,dM_coa_all,ndust,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,mpi_err)
     dM_coa=dM_coa_all
     call MPI_ALLREDUCE(dM_sha,dM_sha_all,ndust,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,mpi_err)
     dM_sha=dM_sha_all
     call MPI_ALLREDUCE(dM_SNd,dM_SNd_all,ndust,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,mpi_err)
     dM_SNd=dM_SNd_all
     call MPI_ALLREDUCE(dM_SNd_Ia,dM_SNd_Ia_all,ndust,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,mpi_err)
     dM_SNd_Ia=dM_SNd_Ia_all
     call MPI_ALLREDUCE(dM_prod,dM_prod_all,ndust,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,mpi_err)
     dM_prod=dM_prod_all
     call MPI_ALLREDUCE(dM_prod_Ia,dM_prod_Ia_all,ndust,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,mpi_err)
     dM_prod_Ia=dM_prod_Ia_all
     call MPI_ALLREDUCE(dM_prod_SW,dM_prod_SW_all,ndust,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,mpi_err)
     dM_prod_SW=dM_prod_SW_all
#endif
     if (myid==1) then
        write(*,998) 'dM Acc        =', dM_acc*(scale_d*scale_l**3) /(dtnew(levelmin)*scale_t)
        write(*,998) 'dM Spu        =', dM_spu*(scale_d*scale_l**3) /(dtnew(levelmin)*scale_t)
        write(*,998) 'dM Coa        =', dM_coa*(scale_d*scale_l**3) /(dtnew(levelmin)*scale_t)
        write(*,998) 'dM Sha        =', dM_sha*(scale_d*scale_l**3) /(dtnew(levelmin)*scale_t)
        write(*,998) 'dM SNd  (II)  =', dM_SNd*(scale_d*scale_l**3) /(dtnew(levelmin)*scale_t)
        if(snia)write(*,998) 'dM SNd  (Ia)  =', dM_SNd_Ia*(scale_d*scale_l**3) /(dtnew(levelmin)*scale_t)
        write(*,998) 'dM Prod (II)  =', dM_prod*(scale_d*scale_l**3)/(dtnew(levelmin)*scale_t)
        if(snia)write(*,998) 'dM Prod (Ia)  =', dM_prod_Ia*(scale_d*scale_l**3)/(dtnew(levelmin)*scale_t)
        write(*,998) 'dM Prod (SW)  =', dM_prod_SW*(scale_d*scale_l**3)/(dtnew(levelmin)*scale_t)
        write(*,*) 'time [s] :', t*scale_t
        write(*,*) 'time [Myr] :', t
        write(*,*) 'dt [s] :', dtnew(levelmin)*scale_t
        write(*,*) 'dt [Myr] :', dtnew(levelmin)
     endif
     dM_acc=0.0d0
     dM_spu=0.0d0
     dM_coa=0.0d0
     dM_sha=0.0d0
     dM_SNd=0.0d0
     dM_SNd_Ia=0.0d0
     dM_prod=0.0d0
     dM_prod_IA=0.0d0
     dM_prod_SW=0.0d0
  endif
  endif
#endif

  if(checkhydro)call check_uold_unew(ilevel,1000)

#if NDUST==1
998 format(A,es14.6)
#endif
#if NDUST==2
998 format(A,2es14.6)
#endif
#if NDUST==4
998 format(A,4es14.6)
#endif
999 format(' Entering amr_step(',i1,') for level',i2)

end subroutine amr_step

!##########################################################################
!##########################################################################
!##########################################################################
!##########################################################################

#ifdef RT
subroutine rt_step(ilevel)
  use amr_parameters, only: dp
  use amr_commons,    only: levelmin, t, dtnew, myid
  use rt_cooling_module, only: update_UVrates
  use rt_hydro_commons
  use UV_module
  use SED_module,     only: star_RT_feedback
  use mpi_mod
  implicit none
  integer, intent(in) :: ilevel

!--------------------------------------------------------------------------
!  Radiative transfer and chemistry step. Either do one step on ilevel,
!  with radiation field updates in coarser level neighbours, or, if
!  rt_nsubsteps>1, do many substeps in ilevel only, using Dirichlet
!  boundary conditions for the level boundaries.
!--------------------------------------------------------------------------

  real(dp) :: dt_hydro, t_left, dt_rt, t_save
  integer  :: i_substep, ivar

  dt_hydro = dtnew(ilevel)                   ! Store hydro timestep length
  t_left = dt_hydro
  ! We shift the time backwards one hydro-dt, to get evolution of stellar
  ! ages within the hydro timestep, in the case of rt subcycling:
  t_save=t ; t=t-t_left

  i_substep = 0
  do while (t_left > 0)                      !                RT sub-cycle
     i_substep = i_substep + 1
     call get_rt_courant_coarse(dt_rt)
     ! Temporarily change timestep length to rt step:
     dtnew(ilevel) = MIN(t_left, dt_rt/2.0**(ilevel-levelmin))
     t = t + dtnew(ilevel) ! Shift the time forwards one dt_rt

     ! If (myid==1) write(*,900) dt_hydro, dtnew(ilevel), i_substep, ilevel
     if (i_substep > 1) call rt_set_unew(ilevel)

     if(rt_star) call star_RT_feedback(ilevel,dtnew(ilevel))

     ! Hyperbolic solver
     if(rt_advect) call rt_godunov_fine(ilevel,dtnew(ilevel))

     call add_rt_sources(ilevel,dtnew(ilevel))

     ! Reverse update boundaries
     do ivar=1,nrtvar
        call make_virtual_reverse_dp(rtunew(1,ivar),ilevel)
     end do

     ! Set rtuold equal to rtunew
     call rt_set_uold(ilevel)

                               call timer('cooling','start')
     if(neq_chem.or.cooling.or.T2_star>0.0)call cooling_fine(ilevel)
                               call timer('radiative transfer','start')

     do ivar=1,nrtvar
        call make_virtual_fine_dp(rtuold(1,ivar),ilevel)
     end do
     if(simple_boundary)call rt_make_boundary_hydro(ilevel)

     t_left = t_left - dtnew(ilevel)
  end do                                   !          End RT subcycle loop
  dtnew(ilevel) = dt_hydro                 ! Restore hydro timestep length
  t = t_save       ! Restore original time (otherwise tiny roundoff error)

  ! Restriction operator to update coarser level split cells
  call rt_upload_fine(ilevel)

  if (myid==1 .and. rt_nsubcycle .gt. 1) write(*,901) ilevel, i_substep

  !900 format (' dt_hydro=', 1pe12.3, ' dt_rt=', 1pe12.3, ' i_sub=', I5, ' level=', I5)
901 format (' Performed level', I3, ' RT-step with ', I5, ' subcycles')

end subroutine rt_step
#endif
