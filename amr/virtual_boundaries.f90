!################################################################
!################################################################
!################################################################
!################################################################
subroutine authorize_coarse
  use amr_commons
  implicit none
  !----------------------------------------------------------------------
  ! This routine authorizes all base cells for refinement.
  ! This duplicates all base grids over all cpu's.
  !----------------------------------------------------------------------
  integer::nxny,i,j,k,ind

  if(verbose)write(*,*)'  Entering authorize_coarse'
  ! Constants
  nxny=nx*ny
  ! Initialize flag2(0) to zero
  flag2(0)=0
  ! Duplicate full domain over cpus
!$omp parallel do private(ind) collapse(3)
  do k=0,nz-1
  do j=0,ny-1
  do i=0,nx-1
     ind=1+i+j*nx+k*nxny
     flag2(ind)=1
  end do
  end do
  end do

end subroutine authorize_coarse
!################################################################
!################################################################
!################################################################
!################################################################
subroutine authorize_fine(ilevel)
  use amr_commons
  use bisection
  implicit none
  integer::ilevel
  ! -------------------------------------------------------------------
  ! This routine computes the authorization map (flag2) for level ilevel.
  ! All myid cells are first marked for authorization.
  ! All virtual cells that intersect the local ordering domain are
  ! also marked for authorization. Finally, the routine performs
  ! a dilatation of the authorization map of one cell width.
  ! Array flag1 for virtual cells is used as temporary work space.
  ! -------------------------------------------------------------------
  integer::ismooth,ibound,ngrid,i,ncache,iskip,igrid,ind,icpu
  integer::ix,iy,iz,idim,nx_loc,isub
  integer,dimension(1:3)::n_nbor
  integer,dimension(1:nvector)::ind_grid,ind_cell
  integer,dimension(1:nvector,0:twondim)::igridn
  real(dp)::dx,dx_loc,scale
  real(dp),dimension(1:3)::skip_loc
  real(dp),dimension(1:twotondim,1:3)::xc
  real(dp),dimension(1:nvector,1:ndim)::xx
  real(qdp),dimension(1:nvector)::order_min,order_max
  logical::test
  real(dp),dimension(1:ndim)::xmin,xmax

  if(ilevel==nlevelmax)return
  if(verbose)write(*,111)ilevel

  ! Mesh size at level ilevel in coarse cell units
  dx=0.5D0**ilevel

  ! Set position of cell centers relative to grid center
  do ind=1,twotondim
     iz=(ind-1)/4
     iy=(ind-1-4*iz)/2
     ix=(ind-1-2*iy-4*iz)
     if(ndim>0)xc(ind,1)=(dble(ix)-0.5D0)*dx
     if(ndim>1)xc(ind,2)=(dble(iy)-0.5D0)*dx
     if(ndim>2)xc(ind,3)=(dble(iz)-0.5D0)*dx
  end do

  ! Scaling factor
  nx_loc=(icoarse_max-icoarse_min+1)
  skip_loc=(/0.0d0,0.0d0,0.0d0/)
  if(ndim>0)skip_loc(1)=dble(icoarse_min)
  if(ndim>1)skip_loc(2)=dble(jcoarse_min)
  if(ndim>2)skip_loc(3)=dble(kcoarse_min)
  scale=boxlen/dble(nx_loc)
  dx_loc=dx*scale

  ! Authorize all myid grids (needed for uploads)
  ncache=active(ilevel)%ngrid
  ! Loop over grids by vector sweeps
!$omp parallel do private(ngrid,ind_grid,ind,iskip,ind_cell)
  do igrid=1,ncache,nvector
     ! Gather nvector grids
     ngrid=MIN(nvector,ncache-igrid+1)
     do i=1,ngrid
        ind_grid(i)=active(ilevel)%igrid(igrid+i-1)
     end do
     ! Loop over cells
     do ind=1,twotondim
        ! Gather cell indices
        iskip=ncoarse+(ind-1)*ngridmax
        do i=1,ngrid
           ind_cell(i)=iskip+ind_grid(i)
        end do
        do i=1,ngrid
           flag2(ind_cell(i))=1
        end do
     end do
     ! End loop over cells
  end do
  ! End loop over grids

  ! Authorize virtual cells that contains myid children cells
!$omp parallel private(ncache,ngrid,ind_grid,iskip,ind_cell,xx,order_min,order_max,test,xmin,xmax)
  do icpu=1,ncpu
     ncache=reception(icpu,ilevel)%ngrid
     ! Loop over grids by vector sweeps
!$omp do schedule(dynamic,nchunk)
     do igrid=1,ncache,nvector
        ! Gather nvector grids
        ngrid=MIN(nvector,ncache-igrid+1)
        do i=1,ngrid
           ind_grid(i)=reception(icpu,ilevel)%igrid(igrid+i-1)
        end do
        ! Loop over cells
        do ind=1,twotondim
           ! Gather cell indices
           iskip=ncoarse+(ind-1)*ngridmax
           do i=1,ngrid
              ind_cell(i)=iskip+ind_grid(i)
           end do
           ! Gather cell centre positions
           do idim=1,ndim
              do i=1,ngrid
                 xx(i,idim)=xg(ind_grid(i),idim)+xc(ind,idim)
              end do
           end do
           ! Rescale position from code units to user units
           do idim=1,ndim
              do i=1,ngrid
                 xx(i,idim)=(xx(i,idim)-skip_loc(idim))*scale
              end do
           end do
           ! Reset flag2
           do i=1,ngrid
              flag2(ind_cell(i))=0
           end do

           if (ordering /= 'bisection') then
              ! Compute minimum and maximum ordering key
              call cmp_minmaxorder(xx,order_min,order_max,dx_loc,ngrid)
              ! Determine if cell is authorized
              do isub=1,overload
                 do i=1,ngrid
                    if(    order_max(i)>bound_key(myid-1+(isub-1)*ncpu).and.&
                         & order_min(i)<bound_key(myid  +(isub-1)*ncpu) )then
                       flag2(ind_cell(i))=1
                    endif
                 end do
              end do
           else ! recursive bisection method
               do i=1,ngrid
                  ! Test if cell overlaps the cpu
                  test=.true.
                  xmin=xx(i,:)-0.5*dx_loc
                  xmax=xx(i,:)+0.5*dx_loc
                  do idim=1,ndim
                     ! This needs to be a >=, not a >, to precisely match the
                     ! ordering/=case for refinement flagging
                     test=test .and. (bisec_cpubox_max(myid,idim).ge.xmin(idim) &
                                          .and. bisec_cpubox_min(myid,idim).le.xmax(idim))
                  end do
                  if(test) flag2(ind_cell(i))=1
               end do
           endif

           ! For load balancing operations
           if(balance)then
              if(ordering/='bisection') then
                 do isub=1,overload
                    do i=1,ngrid
                       if(    order_max(i)>bound_key2(myid-1+(isub-1)*ncpu).and.&
                            & order_min(i)<bound_key2(myid  +(isub-1)*ncpu) )then
                          flag2(ind_cell(i))=1
                       endif
                    end do
                 end do
              else
                 do i=1,ngrid
                    ! Test if cell overlaps the cpu with new cpu map
                    test=.true.
                    xmin=xx(i,:)-0.5*dx_loc
                    xmax=xx(i,:)+0.5*dx_loc
                    do idim=1,ndim
                       ! This needs to be a >=, not a >, to precisely match the
                       ! ordering/=case for refinement flagging
                       test=test .and. (bisec_cpubox_max2(myid,idim).ge.xmin(idim) &
                            .and. bisec_cpubox_min2(myid,idim).le.xmax(idim))
                    end do
                    if(test) flag2(ind_cell(i))=1
                 end do
              end if
              do i=1,ngrid
                 if(cpu_map2(father(ind_grid(i)))==myid)then
                    flag2(ind_cell(i))=1
                 endif
              end do
           end if
        end do
        ! End loop over cells
     end do
!$omp end do nowait
     ! End loop over grids
  end do
!$omp end parallel
  ! End loop over cpus

  ! Apply dilatation operator over flag2 cells on virtual cells only

  flag2(0)=0
  ! Set flag2 to 0 for physical boundary grids
  do ibound=1,nboundary
  do ind=1,twotondim
     iskip=ncoarse+(ind-1)*ngridmax
     do i=1,boundary(ibound,ilevel)%ngrid
        flag2(boundary(ibound,ilevel)%igrid(i)+iskip)=0
     end do
  end do
  end do

  n_nbor(1:3)=(/1,2,3/)
  ! Loop over steps
!$omp parallel private(ncache,ngrid,ind_grid,iskip,ind_cell,igridn)
  do ibound=1,nexpand_bound
  do ismooth=1,ndim
     ! Initialize flag1 to 0 in virtual cells
     do icpu=1,ncpu
        ncache=reception(icpu,ilevel)%ngrid
!$omp do schedule(dynamic,nchunk)
        do igrid=1,ncache,nvector
           ngrid=MIN(nvector,ncache-igrid+1)
           do i=1,ngrid
              ind_grid(i)=reception(icpu,ilevel)%igrid(igrid+i-1)
           end do
           do ind=1,twotondim
              iskip=ncoarse+(ind-1)*ngridmax
              do i=1,ngrid
                 ind_cell(i)=iskip+ind_grid(i)
              end do
              do i=1,ngrid
                 flag1(ind_cell(i))=0
              end do
           end do
        end do
!$omp end do nowait
     end do
!$omp barrier

     ! Count neighbors and set flag2 accordingly
     do icpu=1,ncpu
        ncache=reception(icpu,ilevel)%ngrid
!$omp do schedule(dynamic,nchunk)
        do igrid=1,ncache,nvector
           ngrid=MIN(nvector,ncache-igrid+1)
           do i=1,ngrid
              ind_grid(i)=reception(icpu,ilevel)%igrid(igrid+i-1)
           end do
           call getnborgrids(ind_grid,igridn,ngrid)
           do ind=1,twotondim
              call count_nbors2(igridn,ind,n_nbor(ismooth),ngrid)
           end do
        end do
!$omp end do nowait
     end do
!$omp barrier

     ! Set flag2=1 for cells with flag1=1
     do icpu=1,ncpu
        ncache=reception(icpu,ilevel)%ngrid
!$omp do schedule(dynamic,nchunk)
        do igrid=1,ncache,nvector
           ngrid=MIN(nvector,ncache-igrid+1)
           do i=1,ngrid
              ind_grid(i)=reception(icpu,ilevel)%igrid(igrid+i-1)
           end do
           do ind=1,twotondim
              iskip=ncoarse+(ind-1)*ngridmax
              do i=1,ngrid
                 ind_cell(i)=iskip+ind_grid(i)
              end do
              do i=1,ngrid
                 if(flag1(ind_cell(i))==1)flag2(ind_cell(i))=1
              end do
           end do
        end do
!$omp end do nowait
     end do
!$omp barrier
  end do
  ! End loop over steps
  end do
!$omp end parallel

  ! Compute authorization map for physical boundaries
  if(simple_boundary)call init_boundary_fine(ilevel)

  ! Restore boundaries for flag1
  call make_virtual_fine_int(flag1(1),ilevel)
  if(simple_boundary)call make_boundary_flag(ilevel)

111 format('   Entering authorize_fine for level ',I2)

end subroutine authorize_fine
!################################################################
!################################################################
!################################################################
!################################################################
subroutine make_virtual_coarse_int(xx)
  use amr_commons
  use mpi_mod
  implicit none
  integer,dimension(1:ncoarse+ngridmax*twotondim)::xx
  !-----------------------------------------------------------
  ! This routine communicates virtual boundary conditions
  ! at the coarse level for integer arrays.
  !-----------------------------------------------------------
  integer::nxny,ncell

#ifndef WITHOUTMPI
  integer::i,j,k
  integer::icell,info
  integer,dimension(:),allocatable::ind_cell,fff,ffg
#endif

  ! Constants
  nxny=nx*ny
  ncell=  (icoarse_max-icoarse_min+1) &
       & *(jcoarse_max-jcoarse_min+1) &
       & *(kcoarse_max-kcoarse_min+1)

#ifndef WITHOUTMPI
  ! Allocate local arrays
  allocate(ind_cell(1:ncell),fff(1:ncell),ffg(1:ncell))

  ! Compute cell indices
  icell=0
  do k=kcoarse_min,kcoarse_max
  do j=jcoarse_min,jcoarse_max
  do i=icoarse_min,icoarse_max
     icell=icell+1
     ind_cell(icell)=1+i+j*nx+k*nxny
  end do
  end do
  end do

  ! Communications
  fff=0; ffg=0
!$omp parallel do
  do icell=1,ncell
     if(cpu_map(ind_cell(icell))==myid)fff(icell)=xx(ind_cell(icell))
  end do
  call MPI_ALLREDUCE(fff,ffg,ncell,MPI_INTEGER,MPI_SUM,MPI_COMM_WORLD,info)
!$omp parallel do
  do icell=1,ncell
     xx(ind_cell(icell))=ffg(icell)
  end do

  ! Dealocate local arrays
  deallocate(ind_cell,fff,ffg)
#endif

end subroutine make_virtual_coarse_int
!################################################################
!################################################################
!################################################################
!################################################################
subroutine make_virtual_fine_dp(xx,ilevel)
  use amr_commons
  use mpi_mod
  implicit none
#ifndef WITHOUTMPI
  integer,dimension(MPI_STATUS_SIZE,ncpu)::statuses
#endif
  integer::ilevel
  real(dp),dimension(1:ncoarse+ngridmax*twotondim)::xx
  ! -------------------------------------------------------------------
  ! This routine communicates virtual boundaries among all cpu's.
  ! at level ilevel for any double precision array in the AMR grid.
  ! -------------------------------------------------------------------
#ifndef WITHOUTMPI
  integer::icpu,i,j,ncache,iskip,step
  integer::countsend,countrecv
  integer::info,tag=101
  integer,dimension(ncpu)::reqsend,reqrecv
#endif

  if(numbtot(1,ilevel)==0)return
  if(verbose)write(*,111)ilevel

#ifndef WITHOUTMPI
!$omp parallel private(step,iskip)
!$omp single
  ! Receive all messages
  countrecv=0
  do icpu=1,ncpu
     ncache=reception(icpu,ilevel)%ngrid
     if(ncache>0) then
       countrecv=countrecv+1
       call MPI_IRECV(reception(icpu,ilevel)%u,ncache*twotondim, &
            & MPI_DOUBLE_PRECISION,icpu-1,tag,MPI_COMM_WORLD,reqrecv(countrecv),info)
     end if
  end do
!$omp end single nowait

  ! Gather emission array
!$omp do collapse(2) schedule(dynamic,nchunk)
  do j=1,twotondim
     do icpu=1,ncpu
        if (emission(icpu,ilevel)%ngrid>0) then
           iskip=ncoarse+(j-1)*ngridmax
           step=(j-1)*emission(icpu,ilevel)%ngrid
           do i=1,emission(icpu,ilevel)%ngrid
              emission(icpu,ilevel)%u(i+step,1)=xx(emission(icpu,ilevel)%igrid(i)+iskip)
           end do
        end if
     end do
  end do

  ! Send all messages
!$omp single
  countsend=0
  do icpu=1,ncpu
     ncache=emission(icpu,ilevel)%ngrid
     if(ncache>0) then
       countsend=countsend+1
       call MPI_ISEND(emission(icpu,ilevel)%u,ncache*twotondim, &
            & MPI_DOUBLE_PRECISION,icpu-1,tag,MPI_COMM_WORLD,reqsend(countsend),info)
     end if
  end do
  ! Wait for full completion of receives
  call MPI_WAITALL(countrecv,reqrecv,statuses,info)
!$omp end single

  ! Scatter reception array
!$omp do collapse(2) schedule(dynamic,nchunk)
  do j=1,twotondim
     do icpu=1,ncpu
        if (reception(icpu,ilevel)%ngrid>0) then
           iskip=ncoarse+(j-1)*ngridmax
           step=(j-1)*reception(icpu,ilevel)%ngrid
           do i=1,reception(icpu,ilevel)%ngrid
              xx(reception(icpu,ilevel)%igrid(i)+iskip)=reception(icpu,ilevel)%u(i+step,1)
           end do
        end if
     end do
  end do
!$omp end parallel
  ! Wait for full completion of sends
  call MPI_WAITALL(countsend,reqsend,statuses,info)
#endif

111 format('   Entering make_virtual_fine for level ',I2)

end subroutine make_virtual_fine_dp
!################################################################
!################################################################
!################################################################
!################################################################
subroutine make_virtual_fine_int(xx,ilevel)
  use amr_commons
  use mpi_mod
  implicit none
#ifndef WITHOUTMPI
  integer,dimension(MPI_STATUS_SIZE,ncpu)::statuses
#endif
  integer::ilevel
  integer,dimension(1:ncoarse+ngridmax*twotondim)::xx
  ! -------------------------------------------------------------------
  ! This routine communicates virtual boundaries among all cpu's.
  ! at level ilevel for any integer array in the AMR grid.
  ! -------------------------------------------------------------------
#ifndef WITHOUTMPI
  integer::icpu,i,j,ncache,iskip,step
  integer::countsend,countrecv
  integer::info,tag=101
  integer,dimension(ncpu)::reqsend,reqrecv
#endif

  if(numbtot(1,ilevel)==0)return
  if(verbose)write(*,111)ilevel

#ifndef WITHOUTMPI
!$omp parallel private(step,iskip)
!$omp single
  ! Receive all messages
  countrecv=0
  do icpu=1,ncpu
     ncache=reception(icpu,ilevel)%ngrid
     if(ncache>0) then
       countrecv=countrecv+1
       call MPI_IRECV(reception(icpu,ilevel)%f,ncache*twotondim, &
            & MPI_INTEGER,icpu-1,tag,MPI_COMM_WORLD,reqrecv(countrecv),info)
     end if
  end do
!$omp end single nowait

  ! Gather emission array
!$omp do collapse(2) schedule(dynamic,nchunk)
  do j=1,twotondim
     do icpu=1,ncpu
        if (emission(icpu,ilevel)%ngrid>0) then
           iskip=ncoarse+(j-1)*ngridmax
           step=(j-1)*emission(icpu,ilevel)%ngrid
           do i=1,emission(icpu,ilevel)%ngrid
              emission(icpu,ilevel)%f(i+step,1)=xx(emission(icpu,ilevel)%igrid(i)+iskip)
           end do
        end if
     end do
  end do
!$omp single
  ! Send all messages
  countsend=0
  do icpu=1,ncpu
     ncache=emission(icpu,ilevel)%ngrid
     if(ncache>0) then
       countsend=countsend+1
       call MPI_ISEND(emission(icpu,ilevel)%f,ncache*twotondim, &
            & MPI_INTEGER,icpu-1,tag,MPI_COMM_WORLD,reqsend(countsend),info)
     end if
  end do

  ! Wait for full completion of receives
  call MPI_WAITALL(countrecv,reqrecv,statuses,info)
!$omp end single

  ! Scatter reception array
!$omp do collapse(2) schedule(dynamic,nchunk)
  do j=1,twotondim
     do icpu=1,ncpu
        if (reception(icpu,ilevel)%ngrid>0) then
           iskip=ncoarse+(j-1)*ngridmax
           step=(j-1)*reception(icpu,ilevel)%ngrid
           do i=1,reception(icpu,ilevel)%ngrid
              xx(reception(icpu,ilevel)%igrid(i)+iskip)=reception(icpu,ilevel)%f(i+step,1)
           end do
        end if
     end do
  end do
!$omp end parallel
  ! Wait for full completion of sends
  call MPI_WAITALL(countsend,reqsend,statuses,info)
#endif

111 format('   Entering make_virtual_fine for level ',I2)

end subroutine make_virtual_fine_int
!################################################################
!################################################################
!################################################################
!################################################################
subroutine make_virtual_reverse_dp(xx,ilevel)
  use amr_commons
  use mpi_mod
  implicit none
  integer::ilevel
  real(dp),dimension(1:ncoarse+ngridmax*twotondim)::xx
  ! -------------------------------------------------------------------
  ! This routine communicates virtual boundaries among all cpu's.
  ! at level ilevel in a reverse way for double precision arrays.
  ! -------------------------------------------------------------------
#ifndef WITHOUTMPI
  integer::icpu,i,j,ncache,iskip,step,icell,ibuf
  integer::countsend,countrecv
  integer::info,tag=101
  integer,dimension(ncpu)::reqsend,reqrecv
  integer,dimension(MPI_STATUS_SIZE,ncpu)::statuses
  integer::switchlevel=3
#endif

  if(numbtot(1,ilevel)==0)return
  if(verbose)write(*,111)ilevel

#ifndef WITHOUTMPI
  if(ilevel.LE.switchlevel)then

 ! Gather emission array
!$omp parallel private(iskip,step,icell,ibuf)
!$omp do collapse(2) schedule(dynamic)
  do j=1,twotondim
     do icpu=1,ncpu
        if (reception(icpu,ilevel)%ngrid>0) then
           iskip=ncoarse+(j-1)*ngridmax
           step=(j-1)*reception(icpu,ilevel)%ngrid
           do i=1,reception(icpu,ilevel)%ngrid
              icell=reception(icpu,ilevel)%igrid(i)+iskip
              ibuf=i+step
              reception(icpu,ilevel)%u(ibuf,1)=xx(icell)
           end do
        end if
     end do
  end do

!$omp single
  ! Receive all messages
  countrecv=0
  do icpu=1,myid-1
     ncache=emission(icpu,ilevel)%ngrid
     if(ncache>0) then
        countrecv=countrecv+1
        ! request to send
        call MPI_SEND(countrecv,0, MPI_INTEGER, icpu-1,101,MPI_COMM_WORLD,info)
        call MPI_RECV(emission(icpu,ilevel)%u,ncache*twotondim, &
             & MPI_DOUBLE_PRECISION,icpu-1,tag,MPI_COMM_WORLD,MPI_STATUS_IGNORE,info)
     end if
  end do

  ! Send all messages
  countsend=0
  do icpu=1,ncpu
     ncache=reception(icpu,ilevel)%ngrid
     if(ncache>0) then
        countsend=countsend+1
        ! wait for request to send
        call MPI_RECV(countrecv,0, MPI_INTEGER, icpu-1,101,MPI_COMM_WORLD, &
             & MPI_STATUS_IGNORE, info)
        call MPI_SEND(reception(icpu,ilevel)%u,ncache*twotondim, &
             & MPI_DOUBLE_PRECISION,icpu-1,tag,MPI_COMM_WORLD,info)
     end if
  end do

  ! Receive all messages
  countrecv=0
  do icpu=myid+1,ncpu
     ncache=emission(icpu,ilevel)%ngrid
     if(ncache>0) then
        countrecv=countrecv+1
        ! request to send
        call MPI_SEND(countrecv,0, MPI_INTEGER, icpu-1,101,MPI_COMM_WORLD,info)
        call MPI_RECV(emission(icpu,ilevel)%u,ncache*twotondim, &
             & MPI_DOUBLE_PRECISION,icpu-1,tag,MPI_COMM_WORLD,MPI_STATUS_IGNORE,info)
     end if
  end do
!$omp end single

  ! Scatter reception array
!$omp do collapse(2) schedule(dynamic,nchunk)
  do j=1,twotondim
     do icpu=1,ncpu
        if (emission(icpu,ilevel)%ngrid>0) then
           iskip=ncoarse+(j-1)*ngridmax
           step=(j-1)*emission(icpu,ilevel)%ngrid
           do i=1,emission(icpu,ilevel)%ngrid
              xx(emission(icpu,ilevel)%igrid(i)+iskip)= &
                   & xx(emission(icpu,ilevel)%igrid(i)+iskip) + emission(icpu,ilevel)%u(i+step,1)
           end do
        end if
     end do
  end do
!$omp end parallel
  else

!$omp parallel private(step,iskip)
!$omp single
  ! Receive all messages
  countrecv=0
  do icpu=1,ncpu
     ncache=emission(icpu,ilevel)%ngrid
     if(ncache>0) then
        countrecv=countrecv+1
        call MPI_IRECV(emission(icpu,ilevel)%u,ncache*twotondim, &
             & MPI_DOUBLE_PRECISION,icpu-1,tag,MPI_COMM_WORLD,reqrecv(countrecv),info)
     end if
  end do
!$omp end single nowait

  ! Gather emission array
!$omp do collapse(2) schedule(dynamic,nchunk)
  do j=1,twotondim
     do icpu=1,ncpu
        if (reception(icpu,ilevel)%ngrid>0) then
           iskip=ncoarse+(j-1)*ngridmax
           step=(j-1)*reception(icpu,ilevel)%ngrid
           do i=1,reception(icpu,ilevel)%ngrid
              reception(icpu,ilevel)%u(i+step,1)=xx(reception(icpu,ilevel)%igrid(i)+iskip)
           end do
        end if
     end do
  end do

!$omp single
  ! Send all messages
  countsend=0
  do icpu=1,ncpu
     ncache=reception(icpu,ilevel)%ngrid
     if(ncache>0) then
       countsend=countsend+1
        call MPI_ISEND(reception(icpu,ilevel)%u,ncache*twotondim, &
             & MPI_DOUBLE_PRECISION,icpu-1,tag,MPI_COMM_WORLD,reqsend(countsend),info)
     end if
  end do

  ! Wait for full completion of receives
  call MPI_WAITALL(countrecv,reqrecv,statuses,info)
!$omp end single

  ! Scatter reception array
!$omp do
  do j=1,twotondim
     do icpu=1,ncpu
        if (emission(icpu,ilevel)%ngrid>0) then
           iskip=ncoarse+(j-1)*ngridmax
           step=(j-1)*emission(icpu,ilevel)%ngrid
           do i=1,emission(icpu,ilevel)%ngrid
              xx(emission(icpu,ilevel)%igrid(i)+iskip)= &
                   & xx(emission(icpu,ilevel)%igrid(i)+iskip) + emission(icpu,ilevel)%u(i+step,1)
           end do
        end if
     end do
  end do
!$omp end parallel
  ! Wait for full completion of sends
  call MPI_WAITALL(countsend,reqsend,statuses,info)
  endif
#endif

111 format('   Entering make_virtual_reverse for level ',I2)

end subroutine make_virtual_reverse_dp
!################################################################
!################################################################
!################################################################
!################################################################
subroutine make_virtual_reverse_int(xx,ilevel)
  use amr_commons
  use mpi_mod
  implicit none
  integer::ilevel
  integer,dimension(1:ncoarse+ngridmax*twotondim)::xx
  ! -------------------------------------------------------------------
  ! This routine communicates virtual boundaries among all cpu's.
  ! at level ilevel in a reverse way for integer arrays.
  ! -------------------------------------------------------------------
#ifndef WITHOUTMPI
  integer::icpu,i,j,ncache,iskip,step,icell,ibuf
  integer::countsend,countrecv
  integer::info,tag=101
  integer,dimension(ncpu)::reqsend,reqrecv
  integer,dimension(MPI_STATUS_SIZE,ncpu)::statuses
  integer::switchlevel=3
#endif

  if(numbtot(1,ilevel)==0)return
  if(verbose)write(*,111)ilevel

#ifndef WITHOUTMPI

  if(ilevel.le.switchlevel) then

  ! Gather emission array
!$$omp parallel do private(step,iskip,icell,ibuf) collapse(2) schedule(dynamic,nchunk)
  do j=1,twotondim
     do icpu=1,ncpu
        if (reception(icpu,ilevel)%ngrid>0) then
           iskip=ncoarse+(j-1)*ngridmax
           step=(j-1)*reception(icpu,ilevel)%ngrid
           do i=1,reception(icpu,ilevel)%ngrid
              icell=reception(icpu,ilevel)%igrid(i)+iskip
              ibuf=i+step
              reception(icpu,ilevel)%f(ibuf,1)=xx(icell)
           end do
        end if
     end do
  end do

  ! Receive all messages
  countrecv=0
  do icpu=1,myid-1
     ncache=emission(icpu,ilevel)%ngrid
     if(ncache>0) then
        countrecv=countrecv+1
        ! request to send
        call MPI_SEND(countrecv,0, MPI_INTEGER, icpu-1,101,MPI_COMM_WORLD,info)
        call MPI_RECV(emission(icpu,ilevel)%f,ncache*twotondim, &
             & MPI_INTEGER,icpu-1,tag,MPI_COMM_WORLD,MPI_STATUS_IGNORE,info)
     end if
  end do

  ! Send all messages
  countsend=0
  do icpu=1,ncpu
     ncache=reception(icpu,ilevel)%ngrid
     if(ncache>0) then
        countsend=countsend+1
        ! wait for request to send
        call MPI_RECV(countrecv,0, MPI_INTEGER, icpu-1,101,MPI_COMM_WORLD, &
             & MPI_STATUS_IGNORE, info)
        call MPI_SEND(reception(icpu,ilevel)%f,ncache*twotondim, &
             & MPI_INTEGER,icpu-1,tag,MPI_COMM_WORLD,info)
     end if
  end do

  ! Receive all messages
  countrecv=0
  do icpu=myid+1,ncpu
     ncache=emission(icpu,ilevel)%ngrid
     if(ncache>0) then
        countrecv=countrecv+1
        ! request to send
        call MPI_SEND(countrecv,0, MPI_INTEGER, icpu-1,101,MPI_COMM_WORLD,info)
        call MPI_RECV(emission(icpu,ilevel)%f,ncache*twotondim, &
             & MPI_INTEGER,icpu-1,tag,MPI_COMM_WORLD,MPI_STATUS_IGNORE,info)
     end if
  end do

  ! Scatter reception array
!$$omp parallel do private(step,iskip) collapse(2) schedule(dynamic,nchunk)
  do j=1,twotondim
     do icpu=1,ncpu
        if (emission(icpu,ilevel)%ngrid>0) then
           iskip=ncoarse+(j-1)*ngridmax
           step=(j-1)*emission(icpu,ilevel)%ngrid
           do i=1,emission(icpu,ilevel)%ngrid
              xx(emission(icpu,ilevel)%igrid(i)+iskip)= &
                   & xx(emission(icpu,ilevel)%igrid(i)+iskip) + emission(icpu,ilevel)%f(i+step,1)
           end do
        end if
     end do
  end do

  else

!$$omp parallel private(step,iskip)
!$$omp single
  ! Receive all messages
  countrecv=0
  do icpu=1,ncpu
     ncache=emission(icpu,ilevel)%ngrid
     if(ncache>0) then
        countrecv=countrecv+1
        call MPI_IRECV(emission(icpu,ilevel)%f,ncache*twotondim, &
             & MPI_INTEGER,icpu-1,tag,MPI_COMM_WORLD,reqrecv(countrecv),info)
     end if
  end do
!$$omp end single nowait

  ! Gather emission array
!$$omp do collapse(2)
  do j=1,twotondim
     do icpu=1,ncpu
        if (reception(icpu,ilevel)%ngrid>0) then
           iskip=ncoarse+(j-1)*ngridmax
           step=(j-1)*reception(icpu,ilevel)%ngrid
           do i=1,reception(icpu,ilevel)%ngrid
              reception(icpu,ilevel)%f(i+step,1)=xx(reception(icpu,ilevel)%igrid(i)+iskip)
           end do
        end if
     end do
  end do

!$$omp single
  ! Send all messages
  countsend=0
  do icpu=1,ncpu
     ncache=reception(icpu,ilevel)%ngrid
     if(ncache>0) then
       countsend=countsend+1
        call MPI_ISEND(reception(icpu,ilevel)%f,ncache*twotondim, &
             & MPI_INTEGER,icpu-1,tag,MPI_COMM_WORLD,reqsend(countsend),info)
     end if
  end do

  ! Wait for full completion of receives
  call MPI_WAITALL(countrecv,reqrecv,statuses,info)
!$$omp end single

  ! Scatter reception array
!$$omp do
  do j=1,twotondim
     do icpu=1,ncpu
        if (emission(icpu,ilevel)%ngrid>0) then
           iskip=ncoarse+(j-1)*ngridmax
           step=(j-1)*emission(icpu,ilevel)%ngrid
           do i=1,emission(icpu,ilevel)%ngrid
              xx(emission(icpu,ilevel)%igrid(i)+iskip)= &
                   & xx(emission(icpu,ilevel)%igrid(i)+iskip) + emission(icpu,ilevel)%f(i+step,1)
           end do
        end if
     end do
  end do
!$$omp end parallel
  ! Wait for full completion of sends
  call MPI_WAITALL(countsend,reqsend,statuses,info)

  endif

#endif

111 format('   Entering make_virtual_reverse for level ',I2)

end subroutine make_virtual_reverse_int
!################################################################
!################################################################
!################################################################
!################################################################
subroutine build_comm(ilevel)
  use amr_commons
  use poisson_commons, only: lookup_mg
  use mpi_mod
  implicit none
  integer::ilevel
  ! -------------------------------------------------------------------
  ! This routine builds the communication structure for level ilevel.
  ! Array flag2 is used as temporary work space.
  ! -------------------------------------------------------------------
  integer::icpu,ibound
  integer::ncache,ind,iskip
  integer::i,j,k,nxny
  integer::igrid,jgrid,ngrid
#ifndef WITHOUTMPI
  integer::info,tag=101
  integer,dimension(ncpu)::reqsend,reqrecv
  integer,dimension(ncpu)::sendbuf,recvbuf
  integer,dimension(MPI_STATUS_SIZE,ncpu)::statuses
  integer::countsend,countrecv
#endif
  integer,dimension(1:nvector)::ind_grid,ind_cell

  if(verbose)write(*,111)ilevel
  nxny=nx*ny

  !----------------------------------------------------------------
  ! Compute grids global adress using flag2 array at level ilevel-1
  !----------------------------------------------------------------
  if(ilevel==1)then
!$omp parallel do private(ind) collapse(3)
     do k=kcoarse_min,kcoarse_max
     do j=jcoarse_min,jcoarse_max
     do i=icoarse_min,icoarse_max
        ind=1+i+j*nx+k*nxny
        if(cpu_map(ind)==myid)then
           flag2(ind)=son(ind)
        else
           flag2(ind)=0
        end if
     end do
     end do
     end do
     call make_virtual_coarse_int(flag2(1))
  else
     ! Initialize flag2 to local adress for cpu map = myid cells
!$omp parallel private(icpu,i,ind,igrid,ncache,ngrid,ind_grid,iskip,ind_cell)
     do icpu=1,ncpu
        if(icpu==myid) then
           ncache=active(ilevel-1)%ngrid
        else
           ncache=reception(icpu,ilevel-1)%ngrid
        end if
!$omp do
        do igrid=1,ncache,nvector
           ngrid=MIN(nvector,ncache-igrid+1)
           if(icpu==myid) then
              do i=1,ngrid
                 ind_grid(i)=active(ilevel-1)%igrid(igrid+i-1)
              end do
           else
              do i=1,ngrid
                 ind_grid(i)=reception(icpu,ilevel-1)%igrid(igrid+i-1)
              end do
           end if
           do ind=1,twotondim
              iskip=ncoarse+(ind-1)*ngridmax
              do i=1,ngrid
                 ind_cell(i)=iskip+ind_grid(i)
              end do
              do i=1,ngrid
                 if(cpu_map(ind_cell(i))==myid)then
                    flag2(ind_cell(i))=son(ind_cell(i))
                 else
                    flag2(ind_cell(i))=0
                 end if
              end do
           end do
        end do
!$omp end do nowait
     end do
!$omp end parallel
     call make_virtual_reverse_int(flag2(1),ilevel-1)
     call make_virtual_fine_int   (flag2(1),ilevel-1)
  end if
  !--------------------------------------------------------
  ! Compute number and index of active grid at level ilevel
  !--------------------------------------------------------
  ncache=numbl(myid,ilevel)
  ! Reset old communicator
  if(active(ilevel)%ngrid>0)then
     active(ilevel)%ngrid=0
     deallocate(active(ilevel)%igrid)
  end if
  if(ncache>0)then
     ! Allocate grid index to new communicator
     active(ilevel)%ngrid=ncache
     allocate(active(ilevel)%igrid(1:ncache))
     ! Gather all grids
     igrid=headl(myid,ilevel)
     do jgrid=1,numbl(myid,ilevel)
        active(ilevel)%igrid(jgrid)=igrid
        igrid=next(igrid)
     end do
  end if
  ! Fill up lookup_mg for active
  if(poisson)then
     igrid=headl(myid,ilevel)
     do jgrid=1,numbl(myid,ilevel)
        lookup_mg(igrid)=0
        igrid=next(igrid)
     end do
  end if

  !----------------------------------------------------
  ! Compute number and index of physical boundary grids
  !----------------------------------------------------
  do ibound=1,nboundary
     ncache=numbb(ibound,ilevel)
     ! Reset old communicator
     if(boundary(ibound,ilevel)%ngrid>0)then
        boundary(ibound,ilevel)%ngrid=0
        deallocate(boundary(ibound,ilevel)%igrid)
     end if
     if(ncache>0)then
        ! Allocate grid index to new communicator
        boundary(ibound,ilevel)%ngrid=ncache
        allocate(boundary(ibound,ilevel)%igrid(1:ncache))
        ! Gather all grids
        igrid=headb(ibound,ilevel)
        do jgrid=1,numbb(ibound,ilevel)
           boundary(ibound,ilevel)%igrid(jgrid)=igrid
           igrid=next(igrid)
        end do
     end if
  end do

  !----------------------------------------------------
  ! Compute number and index of virtual boundary grids
  !----------------------------------------------------
#ifndef WITHOUTMPI
!$omp parallel do private(icpu,ncache,igrid,jgrid,i)
   do icpu=1,ncpu
      ncache=0
      if(icpu.ne.myid)ncache=numbl(icpu,ilevel)
      ! Reset old communicators
      if(emission(icpu,ilevel)%ngrid>0)then
         emission(icpu,ilevel)%ngrid=0
         deallocate(emission(icpu,ilevel)%igrid)
         deallocate(emission(icpu,ilevel)%u)
         deallocate(emission(icpu,ilevel)%f)
      end if
      if(reception(icpu,ilevel)%ngrid>0)then
         reception(icpu,ilevel)%ngrid=0
         deallocate(reception(icpu,ilevel)%igrid)
         deallocate(reception(icpu,ilevel)%u)
         deallocate(reception(icpu,ilevel)%f)
      end if
      if(ncache>0)then
         ! Allocate grid index to new communicator
         reception(icpu,ilevel)%ngrid=ncache
         allocate(reception(icpu,ilevel)%igrid(1:ncache))
         ! Gather all grids
         igrid=headl(icpu,ilevel)
         do jgrid=1,numbl(icpu,ilevel)
            reception(icpu,ilevel)%igrid(jgrid)=igrid
            igrid=next(igrid)
         end do
         ! Allocate temporary communication buffer
         allocate(reception(icpu,ilevel)%f(1:ncache,1:1))
         do i=1,ncache
            reception(icpu,ilevel)%f(i,1) = &
            & flag2(father(reception(icpu,ilevel)%igrid(i)))
         end do
         ! Fill up lookup_mg for reception
         if(poisson)then
            do i=1,ncache
               lookup_mg(reception(icpu,ilevel)%igrid(i))= -reception(icpu,ilevel)%f(i,1)
            end do
         end if
      end if
      sendbuf(icpu)=reception(icpu,ilevel)%ngrid
   end do

  !--------------------------------------------------------
  ! Communicate virtual grid number and index to parent cpu
  !--------------------------------------------------------
  call MPI_ALLTOALL(sendbuf,1,MPI_INTEGER,recvbuf,1,MPI_INTEGER,MPI_COMM_WORLD,info)

  ! Allocate grid index
!$omp parallel do private(icpu,ncache)
  do icpu=1,ncpu
     emission(icpu,ilevel)%ngrid=recvbuf(icpu)
     ncache=emission(icpu,ilevel)%ngrid
     if(ncache>0)allocate(emission(icpu,ilevel)%igrid(1:ncache))
  end do

  ! Receive grid list
  countrecv=0
  do icpu=1,ncpu
     ncache=emission(icpu,ilevel)%ngrid
     if(ncache>0) then
        countrecv=countrecv+1
        call MPI_IRECV(emission(icpu,ilevel)%igrid,ncache, &
             & MPI_INTEGER,icpu-1,tag,MPI_COMM_WORLD,reqrecv(countrecv),info)
     end if
  end do

  ! Send global index
  countsend=0
  do icpu=1,ncpu
     ncache=reception(icpu,ilevel)%ngrid
     if(ncache>0) then
        countsend=countsend+1
        call MPI_ISEND(reception(icpu,ilevel)%f,ncache, &
             & MPI_INTEGER,icpu-1,tag,MPI_COMM_WORLD,reqsend(countsend),info)
     end if
  end do

  ! Wait for full completion of sends
  call MPI_WAITALL(countsend,reqsend,statuses,info)

  ! Wait for full completion of receives
  call MPI_WAITALL(countrecv,reqrecv,statuses,info)

  ! Deallocate temporary communication buffers
!$omp parallel do private(icpu,ncache)
  do icpu=1,ncpu
     ncache=reception(icpu,ilevel)%ngrid
     if(ncache>0)deallocate(reception(icpu,ilevel)%f)
  end do

  ! Allocate temporary communication buffers
!$omp parallel do private(icpu,ncache)
  do icpu=1,ncpu
     ncache=emission(icpu,ilevel)%ngrid
     if(ncache>0)then
        allocate(emission(icpu,ilevel)%u(1:ncache*twotondim,1:1))
        allocate(emission(icpu,ilevel)%f(1:ncache*twotondim,1:1))
     endif
     ncache=reception(icpu,ilevel)%ngrid
     if(ncache>0)then
        allocate(reception(icpu,ilevel)%u(1:ncache*twotondim,1:1))
        allocate(reception(icpu,ilevel)%f(1:ncache*twotondim,1:1))
     endif
  end do

#endif

111 format('   Entering build_comm for level ',I2)

end subroutine build_comm
!################################################################
!################################################################
!################################################################
!################################################################
