  subroutine general_write_gfsatm(grd,sp_a,sp_b,filename,mype,mype_out,sub_z,sub_ps,&
       sub_vor,sub_div,sub_tv,sub_q,sub_oz,sub_cwmr,iret_write)

    use kinds, only: r_kind,i_kind,r_single
    use sigio_r_module, only: sigio_dbti,sigio_rropen,sigio_rrhead,sigio_rwhead,&
        sigio_rrdbti,sigio_rwdbti,sigio_rwopen,sigio_rclose
    use sigio_module, only: sigio_head,sigio_alhead
    use general_sub2grid_mod, only: sub2grid_info
    use guess_grids, only: ntguessig,ifilesig
    use obsmod, only: iadate
    use mpimod, only: npe
    use general_specmod, only: spec_vars
    use gridmod, only: ntracer,ncepgfs_head,load_grid,idpsfc5,idthrm5,cp5,idvc5,idvm5
    use ncepgfs_io, only: sigio_cnvtdv8
    use constants, only: zero,zero_single,one,fv
    implicit none

! !INPUT PARAMETERS:
    character(*)                           ,intent(in   ) :: filename     ! file to open and write to
    integer(i_kind)                        ,intent(in   ) :: mype,mype_out      ! mpi task number

    type(sub2grid_info)                    ,intent(in   ) :: grd
    type(spec_vars)                        ,intent(in   ) :: sp_a,sp_b

    real(r_kind),dimension(grd%lat2,grd%lon2)      ,intent(in   ) :: sub_z, sub_ps  !2d
    real(r_kind),dimension(grd%lat2,grd%lon2,grd%nsig) ,intent(in   ) :: sub_vor,sub_div,sub_tv,sub_q,sub_oz, &
                                                             sub_cwmr

    integer(i_kind), intent(out)::  iret_write

    integer(i_kind),parameter::  lunges = 11
    integer(i_kind),parameter::  lunanl = 51

    character(5):: string
    character(6):: fname_ges

    real(r_kind),dimension(grd%itotsub):: work
    real(r_kind),dimension(grd%nlon,grd%nlat-2):: grid,grid2
    real(r_kind),dimension(grd%lat2,grd%lon2):: work_ps
    real(r_kind),dimension(grd%lat2,grd%lon2,grd%nsig):: work_tv

    real(r_kind),dimension(sp_b%nc):: spec_work
    real(r_kind),dimension(sp_a%nc):: spec_work_sm
    real(r_kind),dimension(sp_b%nc),target ::  specges_4

    integer nlatm2,icount,itotflds,i,j,iret,kvar,klev,k
    integer(i_kind),dimension(npe)::ilev,ivar

    type(sigio_head):: sigges_head,siganl_head
    type(sigio_dbti):: sigdati

    type(ncepgfs_head):: gfshead

    logical lloop

!*************************************************************************
!   Initialize local variables
    iret_write=0
    nlatm2=grd%nlat-2
    itotflds=6*grd%nsig+2  ! Hardwired for now!  vor,div,tv,q,oz,cwmr,ps,z
    lloop=.true.

!   Set guess file name
    write(fname_ges,100) ifilesig(ntguessig)
100    format('sigf',i2.2)
!   Handle case of NCEP SIGIO

! Have all files open ges and read header for now with RanRead
    call sigio_rropen(lunges,fname_ges,iret)
    call sigio_alhead(sigges_head,iret)
    call sigio_rrhead(lunges,sigges_head,iret)

! All tasks should also open output file for random write
    call sigio_rwopen(lunanl,filename,iret_write)
    if (iret_write /=0) goto 1000

!    if (mype==mype_out) then
!      Replace header record date with analysis time
       siganl_head = sigges_head
       siganl_head%fhour    = zero_single
       siganl_head%idate(1) = iadate(4) !hour
       siganl_head%idate(2) = iadate(2) !month
       siganl_head%idate(3) = iadate(3) !day
       siganl_head%idate(4) = iadate(1) !year

!      Load grid dimension and other variables used below
!      into local header structure
       gfshead%fhour   = siganl_head%fhour
       gfshead%idate   = siganl_head%idate
       gfshead%levs    = siganl_head%levs
       gfshead%ntrac   = siganl_head%ntrac
       gfshead%ncldt   = siganl_head%ncldt
       gfshead%jcap    = siganl_head%jcap
       gfshead%lonb    = grd%nlon
       gfshead%latb    = nlatm2
       gfshead%idrt    = 4

!      Write header to analysis file
    if (mype==mype_out) then
       call sigio_rwhead(lunanl,siganl_head,iret)
       iret_write=iret_write+iret
    end if

!   Surface pressure.
!   NCEP SIGIO has two options for surface pressure.  Variable idpsfc5
!   indicates the type:
!      idpsfc5= 0,1 for ln(psfc)
!      idpsfc5= 2 for psfc
    work_ps=sub_ps
!   If output ln(ps), take log of ps in cb
    if (idpsfc5 /= 2) then
       do j=1,grd%lon2
          do i=1,grd%lat2
             work_ps(i,j)=log(work_ps(i,j))
          end do
       end do
    endif

!   Thermodynamic variable
!   The GSI analysis variable is virtual temperature (Tv).  For SIGIO
!   we have three possibilities:  Tv, sensible temperature (T), or
!   enthalpy (h=CpT).  Variable idthrm5 indicates the type
!       idthrm5 = 0,1 = virtual temperature (Tv)
!       idthrm5 = 2   = sensible (dry) temperature (T)
!       idthrm5 = 3   = enthalpy (h=CpT)
    
    work_tv=sub_tv
    if (idthrm5==2 .or. idthrm5==3) then

!      Convert virtual temperature to dry temperature
       do k=1,grd%nsig
          do j=1,grd%lon2
             do i=1,grd%lat2
                work_tv(i,j,k)=work_tv(i,j,k)/(one+fv*sub_q(i,j,k))
             end do
          end do
       end do

!      If output is enthalpy, convert dry temperature to CpT
       if (idthrm5==3) call sigio_cnvtdv8(grd%lat2*grd%lon2,&
            grd%lat2*grd%lon2,grd%nsig,idvc5,idvm5,ntracer,&
            iret,work_tv,sub_q,cp5,-1)
    endif


! Do loop until total fields have been processed.  Stop condition on itotflds

    icount=0
    gfsfields:  do while (lloop)

! First, perform sub2grid for up to npe
       call general_gather(grd,sub_z,work_ps,work_tv,sub_vor,sub_div,sub_q,sub_oz,&
              sub_cwmr,icount,ivar,ilev,work)

       do k=1,npe  ! loop over pe distributed data
          klev=ilev(k)
          kvar=ivar(k)

! HS
          if ( kvar==1 .and. (mype==k-1) ) then
             sigdati%i = 1                                        ! hs
! PS
          else if ( kvar==2 .and. (mype==(k-1)) ) then
             sigdati%i = 2                                        ! ps
! TV
          else if ( kvar==3 .and. (mype==(k-1)) ) then
             sigdati%i = 2+klev                                   ! temperature
!  Z
          else if ( kvar==4 .and. (mype==(k-1)) ) then
             sigdati%i = gfshead%levs + 2 + (klev-1) * 2 + 2      ! vorticity
!  D
          else if ( kvar==5 .and. (mype==(k-1)) ) then
             sigdati%i = gfshead%levs + 2 + (klev-1) * 2 + 1      ! divergence
!  Q
          else if ( kvar==6 .and. (mype==(k-1)) ) then
             sigdati%i = gfshead%levs * (2+1) + 2 + klev          ! q
! OZ
          else if ( kvar==7 .and. (mype==(k-1)) ) then
             sigdati%i = gfshead%levs * (2+2) + 2 + klev          ! oz
! CW
          else if ( kvar==8 .and. (mype==(k-1)) ) then
             sigdati%i = gfshead%levs * (2+3) + 2 + klev       ! cw, 3rd tracer
          end if

          if ( klev>0 .and. (mype==k-1) ) then
             sigdati%f => specges_4
             call sigio_rrdbti(lunges,sigges_head,sigdati,iret)
             call load_grid(work,grid)
             do i=1,sp_b%nc
                spec_work(i) = specges_4(i)
                if(sp_b%factsml(i))spec_work(i)=zero
             end do
             call general_sptez_s_b(sp_a,sp_b,spec_work,grid2,1)
             grid=grid-grid2
             call general_sptez_s(sp_a,spec_work_sm,grid,-1)
             call sppad(0,sp_a%jcap,spec_work_sm,0,sp_b%jcap,spec_work)
             if (kvar/=4 .and. kvar/=5) then
                do i=1,sp_b%nc
                   specges_4(i)=specges_4(i)+spec_work(i)
                   if(sp_b%factsml(i))specges_4(i)=zero_single
                end do
             else
                do i=1,sp_b%nc
                   specges_4(i)=specges_4(i)+spec_work(i)
                   if(sp_b%factvml(i))specges_4(i)=zero_single
                end do
             endif


! Write out using RanWrite
             call sigio_rwdbti(lunanl,siganl_head,sigdati,iret)
             iret_write=iret_write+iret

          endif ! end if pe and ivar check

       end do  !end do over pes

       if (icount>itotflds) then
          lloop=.false.
          exit gfsfields
       end if

    end do gfsfields

    call sigio_rclose(lunanl,iret)
    iret_write=iret_write+iret
    if (iret_write /=0) goto 1000

!   Print date/time stamp
    if (mype==mype_out) then
       write(6,700) gfshead%jcap,gfshead%lonb,gfshead%latb,gfshead%levs,&
            gfshead%fhour,gfshead%idate
700    format('GENERAL_WRITE_GFSATM:  anl write, jcap,lonb,latb,levs=',&
            4i6,', hour=',f10.1,', idate=',4i5)
    endif
    return

!   ERROR detected while reading file
1000 continue
     write(6,*)'GENERAL_WRITE_GFSATM:  ***ERROR*** writing ',&
         trim(filename),' mype,iret_write=',mype,iret_write
     return

end subroutine general_write_gfsatm


subroutine general_gather(grd,g_z,g_ps,g_tv,g_vor,g_div,g_q,g_oz,g_cwmr, &
           icount,ivar,ilev,work)

! !USES:

  use kinds, only: r_kind,i_kind
  use mpimod, only: npe,mpi_comm_world,ierror,mpi_rtype
  use general_sub2grid_mod, only: sub2grid_info
  use gridmod, only: strip
  implicit none

! !INPUT PARAMETERS:

  type(sub2grid_info)                   ,intent(in   ) :: grd
  integer(i_kind),intent(inout) :: icount
  integer(i_kind),dimension(npe),intent(inout):: ivar,ilev
  real(r_kind),dimension(grd%itotsub),intent(out) :: work

! !OUTPUT PARAMETERS:

  real(r_kind),dimension(grd%lat2,grd%lon2)     ,intent(  in) :: g_z,g_ps
  real(r_kind),dimension(grd%lat2,grd%lon2,grd%nsig),intent(  in) :: g_tv,&
       g_vor,g_div,g_q,g_oz,g_cwmr

! !DESCRIPTION: Transfer contents of 3d subdomains to 2d work arrays over pes
!
! !REVISION HISTORY:
!   2013-06-19  treadon
!
! !REMARKS:
!
!   language: f90
!   machine:  ibm rs/6000 sp; sgi origin 2000; compaq/hp
!
! !AUTHOR:
!   kleist           org: np23                date: 2013-06-19
!
!EOP
!-------------------------------------------------------------------------

  integer(i_kind) i,klev,itotal,k
  real(r_kind),dimension(grd%lat1*grd%lon1,npe):: sub

  do k=1,npe
     icount=icount+1     

     if(icount == 1)then
        ivar(k)=1
        ilev(k)=1
        call strip(g_z ,sub(:,k) ,1)

     else if(icount == 2)then
        ivar(k)=2
        ilev(k)=1
        call strip(g_ps ,sub(:,k) ,1)

     else if( icount>= 3 .and. icount<=(grd%nsig+2) )then
        ivar(k)=3
        klev=icount-2
        ilev(k)=klev
        call strip(g_tv(:,:,klev) ,sub(:,k) ,1)

     else if( icount>=(grd%nsig)+3 .and. icount<=2*(grd%nsig)+2 )then
        ivar(k)=4
        klev=icount-2-(grd%nsig)
        ilev(k)=klev
        call strip(g_vor(:,:,klev) ,sub(:,k) ,1)

     else if( icount>=2*(grd%nsig)+3 .and. icount<=3*(grd%nsig)+2 )then
        ivar(k)=5
        klev=icount-2-2*(grd%nsig)
        ilev(k)=klev
        call strip(g_div(:,:,klev) ,sub(:,k) ,1)

    else if( icount>=3*(grd%nsig)+3 .and. icount<=4*(grd%nsig)+2 )then
        ivar(k)=6
        klev=icount-2-3*(grd%nsig)
        ilev(k)=klev
        call strip(g_q(:,:,klev) ,sub(:,k) ,1)

    else if( icount>=4*(grd%nsig)+3 .and. icount<=5*(grd%nsig)+2 )then
        ivar(k)=7
        klev=icount-2-4*(grd%nsig)
        ilev(k)=klev
        call strip(g_oz(:,:,klev) ,sub(:,k) ,1)

    else if( icount>=5*(grd%nsig)+3 .and. icount<=6*(grd%nsig)+2 )then
        ivar(k)=8
        klev=icount-2-5*(grd%nsig)
        ilev(k)=klev
        call strip(g_cwmr(:,:,klev) ,sub(:,k) ,1)
    else
! NULL, No work to be done for this pe
        ivar(k)=-1
        ilev(k)=-1    
     end if
  end do

  call mpi_alltoallv(sub,grd%isc_g,grd%isd_g,mpi_rtype,&
       work,grd%ijn,grd%displs_g,mpi_rtype,&
       mpi_comm_world,ierror)

  return
end subroutine general_gather