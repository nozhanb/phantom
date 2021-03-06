!--------------------------------------------------------------------------!
! The Phantom Smoothed Particle Hydrodynamics code, by Daniel Price et al. !
! Copyright (c) 2007-2017 The Authors (see AUTHORS)                        !
! See LICENCE file for usage and distribution conditions                   !
! http://users.monash.edu.au/~dprice/phantom                               !
!--------------------------------------------------------------------------!
!+
!  MODULE: initial
!
!  DESCRIPTION:
!   This module initialises (and ends) the run
!
!  REFERENCES: None
!
!  OWNER: Daniel Price
!
!  $Id$
!
!  RUNTIME PARAMETERS: None
!
!  DEPENDENCIES: balance, boundary, centreofmass, checkoptions, checksetup,
!    chem, cooling, cpuinfo, densityforce, deriv, dim, domain, dust,
!    energies, eos, evwrite, externalforces, fastmath, forcing, h2cooling,
!    initial_params, io, io_summary, linklist, mf_write, mpi, mpiutils,
!    nicil, nicil_sup, omputils, options, part, photoevap, ptmass,
!    readwrite_dumps, readwrite_infile, setup, sort_particles,
!    step_lf_global, timestep, timestep_ind, timestep_sts, timing, units,
!    writegitinfo, writeheader
!+
!--------------------------------------------------------------------------
module initial
#ifdef MPI
 use mpi
#endif
 implicit none
 public :: initialise,startrun,endrun
 real(kind=4), private :: twall_start, tcpu_start

 private

contains

!----------------------------------------------------------------
!+
!  short initialisation routine that should be called
!  by any utility which will subsequently call derivs
!+
!----------------------------------------------------------------
subroutine initialise()
 use dim, only:dimid=>modid,maxp
 use io,               only:fatal,die,id,master,nprocs
#ifdef FINVSQRT
 use fastmath,         only:testsqrt
#endif
 use omputils,         only:init_omp,info_omp
 use options,          only:optid=>modid,set_default_options
 use part,             only:partid=>modid,maxBevol
 use units,            only:set_units
 use boundary,         only:set_boundary
 use writeheader,      only:write_codeinfo
 use writegitinfo,     only:write_gitinfo
 use domain,           only:domid=>modid,init_domains
 use densityforce,     only:denid=>modid
 use deriv,            only:derivid=>modid
 use externalforces,   only:extid=>modid
 use linklist,         only:linkid=>modid
 use readwrite_infile, only:inid=>modid
 use readwrite_dumps,  only:dumpid=>modid
 use step_lf_global,   only:stepid=>modid
 use cpuinfo,          only:print_cpuinfo
 use checkoptions,     only:check_compile_time_settings

 integer :: ierr
!
!--write 'PHANTOM' and code version
!
 if (id==master) call write_codeinfo(6)
!
!--print info on compile
!
 if (id==master) then
    write(*,"(20(/,1x,a),/)") 'Compiled with module versions:', &
         trim(dimid),trim(denid),trim(stepid),trim(derivid), &
         trim(partid),trim(extid),trim(dumpid),trim(inid), &
         trim(optid),trim(linkid),trim(domid)
 endif
!
!--write info on latest git commit
!
 if (id==master) call write_gitinfo(6)
!
!--check that it is OK to use fast sqrt functions
!  on this architecture
!
#ifdef FINVSQRT
 if (id==master) write(*,"(1x,a)") 'checking fast inverse sqrt...'
 call testsqrt(ierr,(id==master))
 if (ierr /= 0) call die
 if (id==master) write(*,"(1x,a,/)") 'done'
#else
 if (id==master) write(*,"(1x,a)") 'Using NATIVE inverse sqrt'
#endif

!
!--set units and default options
!
 call set_units
 call set_default_options
 call set_boundary
!
!--check compile-time settings are OK
!
 call check_compile_time_settings(ierr)
 if (ierr /= 0) call fatal('initialise','incompatible compile-time settings')
!
!--initialise openMP things if required
!
 if (id==master) call print_cpuinfo()
 if (id==master) call info_omp
 call init_omp
!
!--initialise MPI domains
!
 call init_domains(nprocs)

 return
end subroutine initialise

!----------------------------------------------------------------
!+
!  routine which starts a Phantom run
!+
!----------------------------------------------------------------
subroutine startrun(infile,logfile,evfile,dumpfile)
 use mpiutils,         only:reduce_mpi,waitmyturn,endmyturn,reduceall_mpi,barrier_mpi
 use dim,              only:maxp,maxalpha,maxvxyzu,nalpha
 use deriv,            only:derivs
 use evwrite,          only:init_evfile,write_evfile,write_evlog
 use io,               only:idisk1,iprint,ievfile,error,iwritein,flush_warnings,&
                            die,fatal,id,master,nprocs,real4,warning
 use externalforces,   only:externalforce,initialise_externalforces,update_externalforce,&
                            externalforce_vdependent
 use options,          only:iexternalforce,damp,alpha,icooling,use_dustfrac
 use readwrite_infile, only:read_infile,write_infile
 use readwrite_dumps,  only:read_dump,write_fulldump
 use part,             only:npart,xyzh,vxyzu,fxyzu,fext,divcurlv,divcurlB,Bevol,dBevol,&
                            npartoftype,maxtypes,alphaind,ntot, &
                            maxphase,iphase,isetphase,iamtype, &
                            nptmass,xyzmh_ptmass,vxyz_ptmass,fxyz_ptmass,igas,massoftype,&
                            epot_sinksink,get_ntypes,isdead_or_accreted,dustfrac,ddustfrac,&
                            set_boundaries_to_active,n_R,n_electronT,dustevol,rhoh
#ifdef PHOTO
 use photoevap,        only:set_photoevap_grid
#endif
#ifdef NONIDEALMHD
 use units,            only:utime,udist,umass,unit_Bfield
 use nicil,            only:nicil_initialise
 use nicil_sup,        only:use_consistent_gmw
#endif
 use ptmass,           only:init_ptmass,get_accel_sink_gas,get_accel_sink_sink, &
                            r_crit,r_crit2,rho_crit,rho_crit_cgs
 use timestep,         only:time,dt,dtextforce,C_force,dtmax, &
                            rho_dtthresh,rho_dtthresh_cgs,dtmax_rat0,mod_dtmax,mod_dtmax_now
 use timing,           only:get_timings
#ifdef RESET_COFM
 use centreofmass,     only:reset_centreofmass
#endif
#ifdef SORT
 use sort_particles,   only:sort_part
#endif
#ifdef IND_TIMESTEPS
 use timestep,         only:dtmax
 use timestep_ind,     only:istepfrac,ibinnow,maxbins,init_ibin
 use part,             only:ibin,ibin_old,ibin_wake,alphaind
 use readwrite_dumps,  only:dt_read_in
#else
 use timestep,         only:dtcourant,dtforce
#endif
#ifdef STS_TIMESTEPS
 use timestep,         only:dtdiff
#endif
 use timestep_sts,     only:sts_initialise
#ifdef DRIVING
 use forcing,          only:init_forcing
#endif
#ifdef DUST
 use dust,             only:init_drag
#endif
#ifdef MFLOW
 use mf_write,         only:mflow_write,mflow_init
 use io,               only:imflow
#endif
#ifdef VMFLOW
 use mf_write,         only:vmflow_write,vmflow_init
 use io,               only:ivmflow
#endif
#ifdef BINPOS
 use mf_write,         only:binpos_write,binpos_init
 use io,               only:ibinpos,igpos
#endif
#ifdef MPI
 use balance,          only:balancedomains
 use domain,           only:ibelong
#endif
 use writeheader,      only:write_codeinfo,write_header
 use eos,              only:gamma,polyk,ieos,init_eos
 use part,             only:hfact,h2chemistry
 use setup,            only:setpart
 use checksetup,       only:check_setup
 use h2cooling,        only:coolinmo
 use cooling,          only:init_cooling
 use chem,             only:init_chem
 use cpuinfo,          only:print_cpuinfo
 use io_summary,       only:summary_initialise
 use units,            only:unit_density
 use centreofmass,     only:get_centreofmass
 use energies,         only:etot,angtot,totmom,mdust,xyzcom
 use initial_params,   only:get_conserv,etot_in,angtot_in,totmom_in,mdust_in,xyzcom_in
 character(len=*), intent(in)  :: infile
 character(len=*), intent(out) :: logfile,evfile,dumpfile
 integer         :: ierr,i,j,idot,nerr,nwarn
 integer(kind=8) :: npartoftypetot(maxtypes)
 real            :: poti,dtf,hfactfile,fextv(3)
 real            :: pmassi,dtsinkgas,dtsinksink,fonrmax,dtphi2,dtnew_first,dummy(3)
#ifdef NONIDEALMHD
 real            :: gmw_old,gmw_new
#endif
 integer         :: itype,iposinit,ipostmp,ntypes,nderivinit
 logical         :: iexist
 integer :: ncount(maxtypes)
 character(len=len(dumpfile)) :: dumpfileold,fileprefix
!
!--do preliminary initialisation
!
 call initialise
!
!--read parameters from the infile
!
 call read_infile(infile,logfile,evfile,dumpfile)
!
!--initialise alpha's (after the infile has been read)
!
 if (maxalpha==maxp) then
    alphaind(:,:) = real4(alpha)
 endif
!
!--initialise log output
!
 if (iprint /= 6 .and. id==master) then
    open(unit=iprint,file=logfile,form='formatted',status='replace')
!
!--write opening "splash screen" to logfile
!
    call write_codeinfo(iprint)
    call print_cpuinfo(iprint)
 endif
 if (id==master) write(iprint,"(a)") ' starting run '//trim(infile)

 if (id==master) call write_header(1,infile,evfile,logfile,dumpfile)
!
!--read particle setup from dumpfile
!
 if (trim(dumpfile)=='setup') then
    write(iprint,"(72('-'))")
    idot = index(infile,'.in')
    if (idot <= 1) idot = len_trim(infile)
    dumpfile = infile(1:idot-1)//'_00000.tmp'
    fileprefix = infile(1:idot-1)
    write(iprint,"(72('-'))")
    call setpart(id,npart,npartoftype,xyzh,massoftype,vxyzu,polyk,gamma,hfact,time,fileprefix)
    call check_setup(nerr,nwarn) ! sanity check output of setpart
    if (nwarn > 0) call warning('initial','warnings during particle setup',var='warnings',ival=nwarn)
    if (nerr > 0)  call fatal('initial','errors in particle setup',var='errors',ival=nerr)
 else
    call read_dump(trim(dumpfile),time,hfactfile,idisk1,iprint,id,nprocs,ierr)
    if (ierr /= 0) call fatal('initial','error reading dumpfile')
    call check_setup(nerr,nwarn,restart=.true.) ! sanity check what has been read from file
    if (nwarn > 0) call warning('initial','warnings from particle data in file',var='warnings',ival=nwarn)
    if (nerr > 0)  call fatal('initial','errors in particle data from file',var='errors',ival=nerr)
 endif
!
!--initialise values for non-ideal MHD
!
#ifdef NONIDEALMHD
 call nicil_initialise(utime,udist,umass,unit_Bfield,ierr,iprint,iprint)
 if (ierr/=0) call fatal('initial','error initialising nicil (the non-ideal MHD library)')
 call use_consistent_gmw(ierr,gmw_old,gmw_new)
 if (ierr/=0) write(iprint,'(2(a,Es18.7))')' initial: Modifying mean molecular mass from ',gmw_old,' to ',gmw_new
#endif
 n_R         = 0.0
 n_electronT = 0.0
!
!--Initialise and verify parameters for super-timestepping
!
#ifdef STS_TIMESTEPS
 call sts_initialise(ierr,dtdiff)
 if (ierr > 0) call fatal('initial','supertimestep: nu > 1 or < 0 or NaN.')
#endif
!
!--initialise the equation of state
!  (must be done AFTER the units are known & AFTER mu is calculated in non-ideal MHD)
!
 call init_eos(ieos,ierr)
 if (ierr /= 0) call fatal('initial','error initialising equation of state')
!
!--Initialise values for summary array
 call summary_initialise
!
!--get total number of particles (on all processors)
!
 ntot           = reduceall_mpi('+',npart)
 npartoftypetot = reduce_mpi('+',npartoftype)
 if (id==master) write(iprint,"(a,i12)") ' npart total   = ',ntot
 if (npart > 0) then
    if (id==master .and. maxalpha==maxp)  write(iprint,*) 'mean alpha  initial: ',sum(alphaind(1,1:npart))/real(npart)
 endif

 if (sum(npartoftype) /= npart) then
    print *, 'npartoftype = ', npartoftype(1:maxtypes)
    print *, 'npart = ', npart
    call fatal('setup','sum of npartoftype  /=  npart')
 endif

#ifdef DRIVING
!
!--initialise turbulence driving
!
 if (id==master) write(iprint,*) 'waiting on input for turbulent driving...'
 call init_forcing(dumpfile,infile,time)
#endif

#ifdef DUST
 call init_drag(ierr)
 if (ierr /= 0) call fatal('initial','error initialising drag coefficients')
#endif

!
!--initialise cooling function
!
 if (h2chemistry) then
    if (icooling > 0) then
       if (id==master) write(iprint,*) 'initialising cooling function...'
       call init_chem()
       call coolinmo()
    endif
 elseif (icooling > 0) then
    call init_cooling(ierr)
    if (ierr /= 0) call fatal('initial','error initialising cooling')
 endif

 if (damp > 0. .and. any(abs(vxyzu(1:3,:)) > tiny(0.)) .and. abs(time) < tiny(time)) then
    call error('setup','damping on: setting non-zero velocities to zero')
    vxyzu(1:3,:) = 0.
 endif
!
!--Check that the numbers of each type add up correctly
!
 if (maxphase == maxp) then
    ncount(:) = 0
    do i=1,npart
       itype = iamtype(iphase(i))
       if (itype < 1 .or. itype > maxtypes) then
          call fatal('initial','unknown value for itype from iphase array',i,var='iphase',ival=int(iphase(i)))
       else
          ncount(itype) = ncount(itype) + 1
       endif
    enddo
    if (any(ncount /= npartoftype)) then
       write(iprint,*) 'ncount,',ncount,'npartoftype,',npartoftype
       call fatal('initial','sum of types in iphase is not equal to npartoftype')
    endif
 endif

#ifdef IND_TIMESTEPS
 ibin(:)       = 0
 ibin_old(:)   = 0
 ibin_wake(:)  = 0
 if (dt_read_in) call init_ibin(npart,dtmax)
 istepfrac     = 0
 ibinnow       = 0
#else
 dtcourant = huge(dtcourant)
 dtforce   = huge(dtforce)
#endif

!
!--balance domains prior to starting calculation
!  (make sure this is called AFTER iphase has been set)
!
#ifdef MPI
 do i=1,npart
    ibelong(i) = id
 enddo
 call balancedomains(npart)
#endif

!
!--check that sorting is allowed
!  and if so sort particles
!
#ifdef SORT
 call sort_part()
#endif

!
!--set up photoevaporation grid, define relevant constants, etc.
!
#ifdef PHOTO
 call set_photoevap_grid
#endif
!
!--get timestep for external forces
!
 dtextforce = huge(dtextforce)
 fext(:,:)  = 0.
 if (iexternalforce > 0) then
    call initialise_externalforces(iexternalforce,ierr)
    call update_externalforce(iexternalforce,time,0.)
    if (ierr /= 0) call fatal('initial','error in external force settings/initialisation')

    !$omp parallel do default(none) &
    !$omp shared(npart,xyzh,vxyzu,fext,time,iexternalforce,C_force) &
    !$omp private(i,poti,dtf,fextv) &
    !$omp reduction(min:dtextforce)
    do i=1,npart
       if (.not.isdead_or_accreted(xyzh(4,i))) then
          call externalforce(iexternalforce,xyzh(1,i),xyzh(2,i),xyzh(3,i), &
                             xyzh(4,i),time,fext(1,i),fext(2,i),fext(3,i),poti,dtf,i)
          dtextforce = min(dtextforce,C_force*dtf)
          ! add velocity-dependent part
          call externalforce_vdependent(iexternalforce,xyzh(1:3,i),vxyzu(1:3,i),fextv,poti)
          fext(1:3,i) = fext(1:3,i) + fextv
       endif
    enddo
    !$omp end parallel do
    write(iprint,*) 'dt(extforce)  = ',dtextforce
 endif
!
!--get timestep and forces for sink particles
!
 dtsinkgas    = huge(dtsinkgas)
 r_crit2      = r_crit*r_crit
 rho_crit     = rho_crit_cgs/unit_density
 rho_dtthresh = rho_dtthresh_cgs/unit_density
 if (nptmass > 0) then
    write(iprint,"(a,i12)") ' nptmass       = ',nptmass

    ! compute initial sink-sink forces and get timestep
    call get_accel_sink_sink(nptmass,xyzmh_ptmass,fxyz_ptmass,epot_sinksink,dtsinksink,&
                             iexternalforce,time)
    dtsinksink = C_force*dtsinksink
    write(iprint,*) 'dt(sink-sink) = ',dtsinksink
    dtextforce = min(dtextforce,dtsinksink)

    ! compute initial sink-gas forces and get timestep
    pmassi = massoftype(igas)
    ntypes = get_ntypes(npartoftype)
    do i=1,npart
       if (.not.isdead_or_accreted(xyzh(4,i))) then
          if (ntypes > 1 .and. maxphase==maxp) then
             pmassi = massoftype(iamtype(iphase(i)))
          endif
          call get_accel_sink_gas(nptmass,xyzh(1,i),xyzh(2,i),xyzh(3,i),xyzh(4,i),xyzmh_ptmass, &
                   fext(1,i),fext(2,i),fext(3,i),poti,pmassi,fxyz_ptmass,fonrmax,dtphi2)
          dtsinkgas = min(dtsinkgas,C_force*1./sqrt(fonrmax),C_force*sqrt(dtphi2))
       endif
    enddo
    write(iprint,*) 'dt(sink-gas)  = ',dtsinkgas
    dtextforce = min(dtextforce,dtsinkgas)
 endif
 call init_ptmass(nptmass,logfile,dumpfile)
!
!--calculate (all) derivatives the first time around
!
 dtnew_first = dtmax  ! necessary in case ntot = 0
 nderivinit = 1
 ! call derivs twice with Cullen-Dehnen switch to update accelerations
 if (maxalpha==maxp .and. nalpha >= 0) nderivinit = 2
 do j=1,nderivinit
    if (ntot > 0) call derivs(1,npart,npart,xyzh,vxyzu,fxyzu,fext,divcurlv,divcurlB,&
                              Bevol,dBevol,dustfrac,ddustfrac,time,0.,dtnew_first)
    if (use_dustfrac) then
       ! set s = sqrt(eps/(1-eps)) from the initial dustfrac setting now we know rho
       do i=1,npart
          if (.not.isdead_or_accreted(xyzh(4,i))) then
             dustevol(i) = sqrt(dustfrac(i)/(1.-dustfrac(i)))
          endif
       enddo
    endif
 enddo
 if (nalpha >= 2) then
    !$omp parallel do private(i)
    do i=1,npart
       alphaind(1,i) = max(alphaind(1,i),alphaind(2,i)) ! set alpha = max(alphaloc,alpha)
    enddo
 endif
 set_boundaries_to_active = .false.
!
!--set initial timestep
!
#ifndef IND_TIMESTEPS
 dt = dtnew_first
 if (id==master) then
    write(iprint,*) 'dt(forces)    = ',dtforce
    write(iprint,*) 'dt(courant)   = ',dtcourant
    write(iprint,*) 'dt initial    = ',dt
 endif
#endif
!
!--Set parameters to allow for reduction of dtmax
!  (if mod_dtmax_now=true, then rhomax > rho_dtthresh and we do not want to decrease dt)
!
 if (rho_dtthresh > 0.0 .and. .not. mod_dtmax_now .and. dtmax_rat0 > 1) then
    dtmax_rat0 = int(2**(int(log(real(dtmax_rat0)-1.0)/log(2.0))+1)) ! ensure that dtmax_rat0 is a power of 2
 else
    mod_dtmax     = .false.
    mod_dtmax_now = .false.
 endif
!
!--Calculate current centre of mass (required for rotational energies)
!
 call get_centreofmass(xyzcom,dummy,npart,xyzh,vxyzu,nptmass,xyzmh_ptmass,vxyz_ptmass)
!
!--write second header to logfile/screen
!
 if (id==master) call write_header(2,infile,evfile,logfile,dumpfile,ntot)

 call init_evfile(ievfile,evfile)
 call write_evfile(time,dt)
 if (id==master) call write_evlog(iprint)
#ifdef MFLOW
 call mflow_init(imflow,evfile,infile) !take evfile in input to create string.mf
 call mflow_write(time, dt)
#endif

#ifdef VMFLOW
 call vmflow_init(ivmflow,evfile,infile) !take evfile in input to create string_v.mflowv
 call vmflow_write(time, dt)
#endif

#ifdef BINPOS
 call binpos_init(ibinpos,evfile) !take evfile in input to create string.binpos
 call binpos_write(time, dt)
#endif
!
!--Set initial values for continual verification of conservation laws
!  get_conserve=0.5: update centre of mass only; get_conserve=1: update all; get_conserve=-1: update none
!
 if (get_conserv > 0.0) then
    xyzcom_in = xyzcom
    if (get_conserv > 0.75) then
       etot_in   = etot
       angtot_in = angtot
       totmom_in = totmom
       mdust_in  = mdust
       write(iprint,'(1x,a)') 'Setting initial values to verify conservation laws:'
    else
       write(iprint,'(1x,a)') 'Reading initial values to verify conservation laws from previous run; resetting centre of mass:'
    endif
    get_conserv = -1.
 else
    write(iprint,'(1x,a)') 'Reading initial values to verify conservation laws from previous run:'
 endif
 write(iprint,'(2x,a,es18.6)')   'Initial total energy:     ', etot_in
 write(iprint,'(2x,a,es18.6)')   'Initial angular momentum: ', angtot_in
 write(iprint,'(2x,a,es18.6)')   'Initial linear momentum:  ', totmom_in
 write(iprint,'(2x,a,3es18.6)')  'Initial centre of mass:   ', xyzcom_in
#ifdef DUST
 write(iprint,'(2x,a,es18.6,/)') 'Initial dust mass:        ', mdust_in
#endif
!
!--write initial conditions to output file
!  if the input file ends in .tmp or .init
!
 iposinit = index(dumpfile,'.init')
 ipostmp  = index(dumpfile,'.tmp')
 if (iposinit > 0 .or. ipostmp > 0) then
    dumpfileold = dumpfile
    if (iposinit > 0) then
       dumpfile = trim(dumpfile(1:iposinit-1))
    else
       dumpfile = trim(dumpfile(1:ipostmp-1))
    endif
    call write_fulldump(time,trim(dumpfile))
    if (id==master) call write_infile(infile,logfile,evfile,trim(dumpfile),iwritein,iprint)
    !
    !  delete temporary dump file
    !
    call barrier_mpi() ! Ensure all procs have read temp file before deleting
    inquire(file=trim(dumpfileold),exist=iexist)
    if (id==master .and. iexist) then
       write(iprint,"(/,a,/)") ' ---> DELETING temporary dump file '//trim(dumpfileold)//' <---'
       open(unit=idisk1,file=trim(dumpfileold),status='old')
       close(unit=idisk1,status='delete')
    endif
 endif

 if (id==master) then
    call flush_warnings()
    call flush(iprint)
!
!--get starting cpu time
!
    call get_timings(twall_start,tcpu_start)
 endif

 return
end subroutine startrun

!----------------------------------------------------------------
!+
!  This module ends the run (prints footer and closes log).
!  Only called by master thread.
!+
!----------------------------------------------------------------

subroutine endrun
 use io,       only:iprint,ievfile,iscfile,ipafile,imflow,ivmflow,ibinpos,igpos
 use timing,   only:printused
 use part,     only:nptmass
 use eos,      only:ieos,finish_eos
 use ptmass,   only:finish_ptmass
 integer           :: ierr
 character(len=10) :: finishdate, finishtime


 call finish_eos(ieos,ierr)

 write (iprint,"(/,'>',74('_'),'<')")
!
!--print time and date of finishing
!
 call date_and_time(finishdate,finishtime)
 finishdate = finishdate(7:8)//'/'//finishdate(5:6)//'/'//finishdate(1:4)
 finishtime = finishtime(1:2)//':'//finishtime(3:4)//':'//finishtime(5:)
 write(iprint,"(/,' Run finished on ',a,' at ',a,/)") finishdate,finishtime
!
!--print out total code timings:
!
 call printused(twall_start,'Total wall time:',iprint)

 write(iprint,40)
40 format(/, &
   6x,' |   |           |               | |   _|       | |         ',/, &
   6x,' __| __ \   _` | __|  __|   _` | | |  |    _ \  | |  /  __| ',/, &
   6x,' |   | | | (   | |  \__ \  (   | | |  __| (   | |   < \__ \ ',/, &
   6x,'\__|_| |_|\__,_|\__|____/ \__,_|_|_| _|  \___/ _|_|\_\____/ ',/)

 write (iprint,"('>',74('_'),'<')")
!
!--close ev, log& ptmass-related files
!
 close(unit=ievfile)
 close(unit=iprint)
 close(unit=imflow)  ! does not matter if not open
 close(unit=ivmflow)
 close(unit=ibinpos)
 close(unit=igpos)

 if (iscfile > 0) close(unit=iscfile)
 if (ipafile > 0) close(unit=ipafile)

 call finish_ptmass(nptmass)

end subroutine endrun

end module initial
