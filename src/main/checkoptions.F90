!--------------------------------------------------------------------------!
! The Phantom Smoothed Particle Hydrodynamics code, by Daniel Price et al. !
! Copyright (c) 2007-2017 The Authors (see AUTHORS)                        !
! See LICENCE file for usage and distribution conditions                   !
! http://users.monash.edu.au/~dprice/phantom                               !
!--------------------------------------------------------------------------!
!+
!  MODULE: checkoptions
!
!  DESCRIPTION:
!  this module performs checks of the compile time options
!
!  REFERENCES: None
!
!  OWNER: Daniel Price
!
!  $Id$
!
!  RUNTIME PARAMETERS: None
!
!  DEPENDENCIES: io, part
!+
!--------------------------------------------------------------------------
module checkoptions
 implicit none
 public :: check_compile_time_settings

 private

contains

!-------------------------------------------------------------------
!
! This subroutine checks that the compile time options are sensible
! and mutually compatible with each other
!
!-------------------------------------------------------------------
subroutine check_compile_time_settings(ierr)
 use part,  only:mhd,maxBevol,gravity,ngradh,h2chemistry,maxvxyzu
 use io,    only:error,id,master
 integer, intent(out) :: ierr
 character(len=16), parameter :: string = 'compile settings'

 ierr = 0
!
!--check MHD dimension settings are OK
!
#ifdef MHD
 if (.not.mhd) then
    if (id==master) call error(string,'-DMHD but mhd=.false.')
    ierr = 1
 endif
#endif
 if (mhd) then
    if (maxBevol < 3 .or. maxBevol > 4) then
       if (id==master) call error(string,'must have maxBevol=3 (no cleaning) or maxBevol=4 (cleaning)')
       ierr = 1
    endif
 endif
#ifdef NONIDEALMHD
 if (.not.mhd) then
    if (id==master) call error(string,'-DNONIDEALMHD requires -DMHD')
    ierr = 1
 endif
#endif

#ifdef GRAVITY
 if (.not.gravity) call error(string,'-DGRAVITY but gravity=.false.')
#endif
 if (gravity) then
    if (ngradh < 2) then
       if (id==master) call error(string,'gravity requires ngradh=2 for gradsoft storage')
       ierr = 2
    endif
 endif
 if (h2chemistry) then
    if (maxvxyzu /= 4) then
       if (id==master) call error(string,'must store thermal energy (maxvxyzu=4 in dim file) if using H2 chemistry')
       ierr = 3
    endif
 endif

#ifdef DISC_VISCOSITY
#ifdef CONST_AV
 if (id==master) call error(string,'should not use both -DCONST_AV and -DDISC_VISCOSITY')
 ierr = 4
#endif
#endif

#ifdef DUST
#ifdef MHD
 if (id==master) call error(string,'-DDUST currently not compatible with magnetic fields (-DMHD)')
#endif
#endif

 return
end subroutine check_compile_time_settings

end module checkoptions
