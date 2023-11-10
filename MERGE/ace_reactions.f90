module ace_reactions
use omp_lib
use constants,         only : PI, wgt_min, barn, tiny_bit, m_u, m_n, mevj, wgt_split
use variables,         only : E_mode, keff, k_col, icore, score
use material_header 
use ace_header
use ace_xs
use randoms,          only : rang, rand_vec
use scattering_laws 
use particle_header
use bank_header
use geometry_header, only: cells 

implicit none 

contains

! ================================================== !
!	COLLISION_CE : Collision simulation for CE
! ================================================== !
subroutine collision_CE (p)
    use constants, only: k_b
    implicit none 
    type(particle), intent(inout) :: p
    integer :: iso, i, i_iso, xn, j
    real(8) :: rn, el, noel, r, sigt_sum, temp, sum1, sum2, g
    real(8) :: micro_xs(6)
    real(8) :: macro_xs(5) !tmparr(4)
    ! * microscopic cross section
    ! 1 : total
    ! 2 : elastic
    ! 3 : absorption
    ! 4 : fission
    ! 5 : nufission
    ! 6 : thermal elastic
    real(8) :: ipfac
    integer :: ierg, ierg2
    integer :: n_iso
    real(8) :: dtemp
    integer :: ii, jj, kk, mm, column 
    real(8) :: xs_t(5)
	real(8) :: E_prev, tmp
	logical :: elastic = .true. 
	
	E_prev = p%E 
    p%n_collision = p%n_collision + 1
    p % n_coord = 1
    xn = 1
    !===============================================
    ! Sample a target isotope in the mixture
    if(p%material==0) then
        p%alive = .false.
        print *, 'KILLED'
        return
    endif
    call WHAT_TEMPERATURE(p)
	
    if(do_ueg) then
        macro_xs = getMacroXS_UEG(materials(p%material), p%E,p%kT, p%urn)
    else
        macro_xs= getMacroXS(materials(p%material), p%E,p%kT, p%urn)
    endif
    !write(*,*) 'COMP', macro_xs(1), tmp, p%E
    rn = rang(); temp = 0; iso = materials(p%material)%n_iso
    do i = 1, materials(p%material)%n_iso
        dtemp = abs(p%kT-ace(materials(p%material)%ace_idx(i))%temp) 
		
        if ( materials(p%material)%db .and. dtemp > K_B .and. p%E < 1D0 ) then
        ! On-the-fly Doppler broadening
        call GET_OTF_DB_MIC(p%kT,materials(p%material)%ace_idx(i),p%E,micro_xs)
        !if (  micro_xs(1) > 1E+30 ) stop
        else
        ! point-wise data at the given temperature
        micro_xs = getMicroXS( materials(p%material)%ace_idx(i), p%E)
        ! URR Region
        if(materials(p%material)%numden(i) > ures_cut) &
            call GET_URR_MICRO(materials(p%material)%ace_idx(i), p%E, micro_xs, p%urn)  
        end if
        ! S(a,b)
        call GET_SAB_MIC(materials(p%material),i,p%E,micro_xs)
        temp = temp + micro_xs(1)*materials(p%material)%numden(i)*barn
        if ( rn < temp/macro_xs(1) ) then
            iso = materials(p%material)%ace_idx(i)
            i_iso = i
            if ( materials(p%material)%sab .and. ace(iso)%sab_iso /= 0 &
                .and. p%E < 4D-6 ) then
                p%yes_sab = .true.
            else
                p%yes_sab = .false.
            endif
            exit
        endif
    enddo

    !> Collision estimator
    !$OMP ATOMIC
    k_col = k_col + p%wgt * macro_xs(4)/macro_xs(1)


    call fissionSite_CE(p, iso, micro_xs)
	
	call fissionSite_dynamic (p, iso, micro_xs)
	
    !!===============================================
    !Sampling reaction: elastic vs.non-elastic
    el   = micro_xs(2)
    !noel = micro_xs(1)-micro_xs(3)-el
    !if (abs(noel) < 1.d-5) noel = 0 

    noel = 0 
    call getierg(iso,ierg,p%E)
    ipfac = max(0.d0, min(1.d0,(p%E-ace(iso)%E(ierg))/(ace(iso)%E(ierg+1)-ace(iso)%E(ierg))))
    do i = 1, ace(iso)%NXS(5) !> through the reaction types...
        if (abs(ace(iso)%TY(i)) == 19) cycle 
        noel = noel + ace(iso)%sig_MT(i)%cx(ierg) & 
                    + ipfac*(ace(iso)%sig_MT(i)%cx(ierg+1) - ace(iso)%sig_MT(i)%cx(ierg))
    enddo 

    r = rang()*(noel+el)-el
    if( ace(iso)%nxs(5) == 0 .or. r <= 0.0d0 ) then 
        if ( p%yes_sab ) then
                !print *, materials(p%material)%mat_name , materials(p%material)%sab
                !print *, ace(iso)%sab_iso, p%E 
                !print *, ( materials(p%material)%sab == .true.  .and. ace(iso)%sab_iso /= 0 &
                !.and. p%E < 4D-6 )
        call SAB_CE(p,iso,micro_xs(2),micro_xs(6))
        else
        call elastic_CE (p, iso)
        end if
    else
		elastic = .false. 
        call notElastic_CE (p, iso, xn)
    end if
    
	p%iso = iso 
	
    p%wgt = p%wgt * ((el+noel)/micro_xs(1)) !(1 - micro_xs(3)/micro_xs(1))
    
    !> (n, xn) reaction
    p%wgt = p%wgt * dble(xn)
    
    call absorption_CE(p)
    
    if(do_ures)then
        do i = 1, n_unr
            iso = uresiso(i)
            p % urn(i) = rang()
        enddo
    endif



end subroutine


! =============================================================================
! WHAT_TEMPERATURE
! =============================================================================
subroutine WHAT_TEMPERATURE(p)
    use TH_HEADER, only: t_fuel, t_clad, t_bulk, th_on
    use TEMPERATURE, only: TH_INSIDE
    use CONSTANTS, only: k_b
    implicit none
    type(Particle), intent(inout):: p
    integer:: ixyz(3)
    logical:: inside

    inside = .false.
    if ( th_on ) then
        call TH_INSIDE(p%coord(1)%xyz(:),ixyz,inside)
    end if

    if ( inside ) then
        select case(materials(p%material)%mat_type)
        case(1); p%kT = t_fuel(ixyz(1),ixyz(2),ixyz(3))
        case(2); p%kT = t_clad(ixyz(1),ixyz(2),ixyz(3))
        case(3); p%kT = t_bulk(ixyz(1),ixyz(2),ixyz(3))
        end select
    elseif ( .not. materials(p%material)%DB .or. p%kT == 0 .or. (do_gmsh .and. .not. p%in_tet)) then 
        p%kT = ace(materials(p%material)%ace_idx(1))%temp
    end if

end subroutine


! =============================================================================
! SAB_CE
! =============================================================================
subroutine SAB_CE(p,iso,th,thel)
    type(particle), intent(inout):: p
    integer, intent(in):: iso
    real(8), intent(in):: th
    real(8), intent(in):: thel
    real(8):: re

    re = rang()*th-thel
    if ( re <= 0D0 ) then
        call SAB_EL_CE(p,iso)    ! elastic scattering
    else
        call SAB_IN_CE(p,iso)    ! inelastic scattering
    end if
    p%yes_sab = .false.

end subroutine


! =============================================================================
! SAB_EL_CE
! =============================================================================
subroutine SAB_EL_CE(p,iso)
    type(particle), intent(inout):: p
    integer, intent(in):: iso
    type(SAB_EL_ANG), pointer:: ab1
    type(SAB_EL_XS), pointer:: ab2
    integer:: isab, ierg    ! index of S(a,b) and energy
    integer:: iang          ! index of angle
    real(8):: ssum          ! summation (CDF)
    real(8):: rn            ! random number
    real(8):: mu            ! cosine angle
    real(8):: ipfac         ! interpolation factor
    real(8):: awr           ! atomic weight ratio
    real(8):: aa            ! parameter

    isab = ace(iso)%sab_iso
    ab1 => sab(isab)%itca
    ab2 => sab(isab)%itce
    
    ! energy index
    call GET_IERG_SABE(isab,ierg,p%e)
    
    ! angle index
    iang = int(rang()*(sab(isab)%nxs(6)+1))+1
    
    ! interpolation factor
    ipfac=max(0D0,min(1D0,(p%e-ab2%erg(ierg))/(ab2%erg(ierg+1)-ab2%erg(ierg))))

    ! outgoing angle
    mu = ab1%ang(ierg,iang) + ipfac*(ab1%ang(ierg+1,iang)-ab1%ang(ierg,iang))
    
    ! coordinate change
    awr = ace(iso)%atn
    aa = 1D0+awr*(awr+2D0*mu)
    p%E = p%E*aa / ((1D0+awr)*(1D0+awr))
    mu = (1D0+mu*awr)/sqrt(aa)
    p%coord(1)%uvw = rotate_angle(p%coord(1)%uvw,mu)
    
    if ( associated(ab1) ) nullify(ab1)
    if ( associated(ab2) ) nullify(ab2)

end subroutine


! =============================================================================
! SAB_IN_CE
! =============================================================================
subroutine SAB_IN_CE(p,iso)
    type(particle), intent(inout):: p
    integer, intent(in):: iso
    type(SAB_INEL_E), pointer:: ab1
    type(SAB_INEL_XS), pointer:: ab2
    integer:: isab, ierg, ierg2, iang   ! index of S(a,b), energy, angle
    real(8):: mu    ! cosine angle
    real(8):: Ecm   ! energy (COM)
    real(8):: Eout  ! outgoing energy
    real(8):: ipfac ! interpolation factor
    real(8):: awr   ! atomic weight ratio

    isab = ace(iso)%sab_iso
    ab1 => sab(isab)%itxe
    ab2 => sab(isab)%itie

    ! energy & angle indices
    call GET_IERG_SABI(isab,ierg,p%e)
    ierg2 = int(rang()*(sab(isab)%nxs(4)))+1
    call SKEWED_SECOND(sab(isab)%nxs(4),ierg2)
    iang = int(rang()*(sab(isab)%nxs(3)+1))+1

    ! interpolation factor
    ipfac=max(0D0,min(1D0,(p%e-ab2%erg(ierg))/(ab2%erg(ierg+1)-ab2%erg(ierg))))

    ! outgoing energy
    p%E = ab1%erg(ierg,ierg2)+ipfac*(ab1%erg(ierg+1,ierg2)-ab1%erg(ierg,ierg2))

    ! outgoing angle
    mu = ab1%ang(ierg,ierg2,iang) + &
        ipfac*(ab1%ang(ierg+1,ierg2,iang)-ab1%ang(ierg,ierg2,iang))

    ! coordinate change
    p%coord(1)%uvw = rotate_angle(p%coord(1)%uvw,mu)
    
    if ( associated(ab1) ) nullify(ab1)
    if ( associated(ab2) ) nullify(ab2)

end subroutine


! =============================================================================
! SKEWED_SECOND
! =============================================================================
subroutine SKEWED_SECOND(ne,ierg2)
    integer, intent(in) :: ne
    integer, intent(out):: ierg2
    real(8):: pp    ! proability

    pp = rang()*(ne-3)
    if ( pp > 1D0 ) then
        ierg2 = int(pp) + 2
    elseif ( pp > 6D-1 ) then
        ierg2 = ne - 1
    elseif ( pp > 5D-1 ) then
        ierg2 = ne
    elseif ( pp > 1D-1 ) then
        ierg2 = 2
    else
        ierg2 = 1
    end if

end subroutine



! ================================================== !
!    acecos() samples the scattering cosine of the 
!    secondary neutron in the CM frame.
! ================================================== !
subroutine acecos (erg, iso, mu, iMT)
    !type(particle), intent(inout) :: p
    real(8), intent(in) :: erg 
    integer, intent(in) :: iso, iMT
    real(8), intent(inout):: mu
    real(8) :: LOCB, LC
    real(8) :: rn1, rn2 
    real(8) :: ipfac
    real(8) :: temp
    real(8) :: CSOUT1, CSOUT2, PDF1, PDF2, CDF1, CDF2
    integer :: NE, pt1, pt2, pt3, IE, i, JJ, ilaw, law
    type (AngularDist), pointer :: an
    real(8), allocatable :: P_tbl(:), CSOUT(:), PDF(:), CDF(:)
    integer :: K, NP 
	real(8) :: erg_tmp
	
    an => ace(iso)%ang(iMT)
    LOCB = ace(iso) % ang_flag(iMT)
    if (LOCB == 0)  then
        !> isotropic scattering (CM system)
        mu = 2.0d0*rang()-1.0d0

    elseif (LOCB == -1) then 
        ! No angular distribution data are given for this reaction in the AND Block. 
        ! Angular distribution data are specified through LAW_i=44 in the DLW Blaock.
        !print *, 'law 44 called'!, p%last_E , '->', p%E, 100*(p%last_E - p%E)/p%last_E        
        !do i = 1, ace(iso)%pneg(1)%nlaw
        !    if (ace(iso)%pneg(1)%dist(i)%law == 44) then 
        !        ilaw = i
        !        exit 
        !    endif
        !enddo 
        !call LAW44_ANG(erg, iso, mu, ace(iso)%pneg(1)%dist(ilaw), iMT)
        
		if (ace(iso)%pneg(1)%nlaw > 1) then 
			print *, "There are more than 1 laws for this isotope", iso 
			print *, "ace_reaction.f90 >> acecos() "
			stop
		endif 
		erg_tmp = erg 
		ilaw = 1
		law = ace(iso)%pneg(1)%dist(1)%law
		call law_selector(erg_tmp, iso, mu, ace(iso)%pneg(1)%dist(ilaw), iMT, law)
		
    elseif (LOCB > 0) then 
        !print *, 'tabular or 32 equiprobable', LOCB
        !> Find energy index
        NE  = an%NE 
        pt1 = 1; pt2 = NE
        do 
            if (pt2-pt1 ==1) exit 
            pt3 = (pt1+pt2)/2
            if(erg >= an%E(pt3)) then 
                pt1 = pt3 
            else 
                pt2 = pt3
            endif 
        enddo 
        
        ipfac = max(0.d0, min(1.d0,(erg-an%E(pt1))/(an%E(pt2)-an%E(pt1))))
        IE = pt1
        if (rang()  < ipfac) IE = pt2
        
        !if(curr_cyc==1) write(*,*) 'ACOS  ', ace(iso)%xslib, icore+1, LOCB, an%dist_flag(IE)
        LC = an%dist_flag(IE) 
        if (LC == 0) then   
            !> isotropic scattering (CM system)
            mu = 2.0d0*rang()-1.0d0
        elseif (LC > 0) then  !> 32 Equiprobable bin distribution 
            rn1 = rang()
            i  = int(32.0*rn1)
            allocate(P_tbl(33)) 
            !if( rang()*(an%E(pt2)-an%E(pt1)) < p%E-an%E(pt1) )  IE=pt2
            P_tbl(1:33) = an % dist(IE) % LDAT(1:33)
            mu = P_tbl(i) + (32.*rn1-i)*(P_tbl(i+1) - P_tbl(i))
            !mu = an%dist(IE)%P(i) + (32.*rn1-i)*(an%dist(IE)%P(i+1) - an%dist(IE)%P(i))
        else  !> Tabular probability angular distribution        
            NP = an % dist(IE) % LDAT(2)  !(size(an % dist(IE) % LDAT)-2)/3
            allocate(CSOUT(1:NP))
            allocate(PDF(1:NP))
            allocate(CDF(1:NP))
            
            CSOUT(1:NP) = an % dist(IE) % LDAT(3:3+NP-1)
            PDF(1:NP) = an % dist(IE) % LDAT(3+NP:3+2*NP-1)
            CDF(1:NP) = an % dist(IE) % LDAT(3+2*NP:3+3*NP-1)
                        
            rn1 = rang() 
            pt1 = 1; pt2 = NP
            do 
                if (pt2-pt1 ==1) exit 
                pt3 = (pt1+pt2)/2 
                if(rn1 >= CDF(pt3)) then 
                    pt1 = pt3
                else 
                    pt2 = pt3
                endif
            enddo 
            
            CSOUT1 = CSOUT(pt1)
            CSOUT2 = CSOUT(pt2)
            PDF1   = PDF(pt1)
            PDF2   = PDF(pt2)
            CDF1   = CDF(pt1)
            CDF2   = CDF(pt2)
            
            JJ = an % dist(IE) % LDAT(1) !an % dist(IE) % JJ
            temp = (PDF2-PDF1)/(CSOUT2-CSOUT1)
            if (JJ == 1 .or. temp == 0) then !> Histogram 
                mu = CSOUT1 + (rn1-CDF1)/PDF1
            elseif (JJ == 2) then !> Linear-Linear 
                mu = CSOUT1+(sqrt(max(0.0d0,PDF1**2 +2.0d0*temp*(rn1-CDF1)))-PDF1)/temp
            else
                print *, "ERROR :: UNKNOWN INTERPOLATION TYPE IN SCATTERING ANGLE DISTRIBUTIOIN"
            endif
        endif         
        
    else 
        print *, "ERROR: NO SCATTERING ANGLE DISTRIBUTION", ace(iso)%library, ace(iso)%MT(iMT)
        stop
    endif
    
    
end subroutine

! ================================================== !
!    elastic_CE() handles elastic scattering of the 
!    particle 
!    Output :: Angle & Energy of p object
! ================================================== !
subroutine elastic_CE (p, iso)
    type(particle), intent(inout) :: p
    integer, intent(in) :: iso
    real(8) :: mu
    integer :: iMT, i 
    
    iMT = 0
    p%last_E = p%E
    !sample the neutron output direction and calculate its energy.
    !> elastic scattering is always considered as CM frame
    call acecos(p%E, iso, mu, iMT) !scattering angle in COM    
    if (abs(mu) > 1. ) then 
        !print *, "cos larger than 1"
        mu = sign(1.0d0, mu)
    endif
    
    call directionEnergy (p, mu, iMT, iso) 
    
end subroutine


! ================================================== !
!    notElastic_CE() handles all scattering event 
!    excluding elastic scattering. 
!    Output :: Angle & Energy of p object
! ================================================== !
subroutine notElastic_CE (p,iso,xn)
    type(particle), intent(inout) :: p
    type (AngularDist), pointer :: an
    type (EnergyDist),  pointer :: eg
    type (CrossSectionDataForm), pointer :: sigmt
    integer, intent(in) :: iso
    integer, intent(inout) :: xn
    integer :: i, j
    integer :: iMT, MT 
    integer :: pt1, pt2, pt3
    integer :: ierg
    integer :: law, ilaw        ! collision law
    real(8) :: ipfac    ! interpolation factor
    real(8) :: F         ! collision probability
    real(8) :: rn 
    real(8) :: mu 
    real(8) :: erg
    real(8) :: sig_arr(1:ace(iso)%NXS(5)), sig_sum, temp
    real(8) :: u, v, w, phi
    real(8) :: micro(6)
    
    
    
    erg = p%E
    call getierg(iso,ierg,erg)
    ipfac = max(0.d0, min(1.d0,(erg-ace(iso)%E(ierg))/(ace(iso)%E(ierg+1)-ace(iso)%E(ierg))))
    
    sig_arr(:) = 0
    do i = 1, ace(iso)%NXS(5) !> through the reaction types...
    !> Determine reaction type number from 1 to NXS(5)
        !print *, int(ace(iso)%MT(i)), int(ace(iso)%ty(i)), ace(iso)%sig_MT(i)%cx(ierg), ipfac
    
        if (int(ace(iso)%ty(i))==19) cycle
        !> 1. locate energy grid in SIG(i) block 
        sigmt => ace(iso)%sig_MT(i)
        ! if p%E is outside the energy grid :: cycle
        !print *, sigmt%IE, ierg, (sigmt%IE+sigmt%NE-1)
        if (ierg >= (sigmt%IE+sigmt%NE-1) .or. ierg < sigmt%IE  ) cycle 
        
        !> 2. calculate XS for the reaction type
        sig_arr(i) = sigmt%cx(ierg) + ipfac*(sigmt%cx(ierg+1)-sigmt%cx(ierg))
        
        !print *, i, sigmt%cx(ierg), ipfac
        !print *, i, int(ace(iso)%MT(i)), sig_arr(i) 
    enddo 
    
    
    rn = rang()
    sig_sum = sum(sig_arr(:)); temp = 0; iMT = -10
    do i = 1, ace(iso)%NXS(5) !> through the reaction types...
        temp = temp + sig_arr(i)
        if (rn < temp/sig_sum) then
            MT = ace(iso)%MT(i)
            iMT = i
            exit
        endif 
    enddo 
    
    if (iMT < 0) then 
        print *, '*********** warning :: iMT not selected ************'
        print *, 'rn',rn
        print *, 'NXS(5)', ace(iso)%NXS(5)
        print *, 'sig_arr', sig_arr(:)
        
		print *, 'isotope ', ace(iso)%library
		print *, 'energy ', p%E
        micro = getMicroXS( iso, p%E)
        
        print *, '  elastic', micro(2)
        print *, 'inelastic', micro(1)-micro(3)-micro(2)

        stop 
    endif
    
    rn = rang()
    !> determine collision law number
    eg => ace(iso) % pneg(iMT)
    law = -1
    !print *, iMT, 'MT num', ace(iso)%MT(iMT), 'nlaw', eg%nlaw
    F = 0.
    law_search: do ilaw = 1, eg%nlaw
        !> Binary search to corresponding energy grid index
        pt1 = 1; pt2 =  eg % dist(ilaw) % NE
        do 
            if(pt2-pt1 == 1) exit 
            pt3 = (pt2+pt1)/2 
            if (p%E >= eg%dist(ilaw)%E(pt3) ) then 
                pt1 = pt3 
            else 
                pt2 = pt3
            endif
        enddo
        !print *, 'inelastic' , eg%nlaw, pt1, pt2 , eg % dist(ilaw) % NE
        !> Interpolate F(E) (P(E) in ENDF Manual...)
        ipfac = max(0.d0, min(1.d0,(p%E-eg%dist(ilaw)%E(pt1))/(eg%dist(ilaw)%E(pt1+1)-eg%dist(ilaw)%E(pt1))))
        F     = F + eg%dist(ilaw)%F(pt1) + ipfac*(eg%dist(ilaw)%F(pt1+1)-eg%dist(ilaw)%F(pt1))
        
        if (rn < F) then 
            law = eg % dist(ilaw) % law
            exit law_search
        endif
    enddo law_search
    
    if ( eg%nlaw == 1 ) then 
        law = eg % dist(1) % law
        ilaw = 1
    endif 
    
    if (law < 0) then 
        print *, 'ERROR :: law not selected'
        print *, F, eg%dist(ilaw)%F(pt1), ipfac
        print *, ace(iso)%library, iMT, ace(iso)%TY(iMT), eg%nlaw, law
        stop
    endif 
    
    !print *, ace(iso)%library, 'MT num', ace(iso)%MT(iMT), ace(iso)%TY(iMT), 'law', law
    
    
    p%last_E = p%E
    !> Sample the scattering cosine
    if (law /= 44 .and. law /= 61) then 
        call acecos (p%E, iso, mu, iMT)
    endif 
    !p%E = p%last_E
    
    
    !> Sample the outgoing energy by the specific scattering Law
    !> call the corresponding law subroutines
    call law_selector (p%E, iso, mu, eg%dist(ilaw), iMT, law)
    
    if (abs(mu) > 1. ) then 
        !print *, 'WARNING :: abs cosine larger than 1', mu 
        mu = sign(1.0d0, mu)
    endif
    
	
	
    call directionEnergy (p, mu, iMT, iso) 
    
    xn = abs(ace(iso)%TY(iMT))
    if(xn > 4 .or. xn == 0) xn = 1
    
	
	
	
	
end subroutine


! ================================================== !
!    fissionSite_CE() samples the potential fission 
!    source through the implicit capture process. 
! ================================================== !
subroutine fissionSite_CE (p, iso, micro_xs)
    use FMFD, only: fmfdon, fsd_MC
    use TALLY, only: FM_ID, INSIDE
    implicit none
    type(particle), intent(in) :: p
    real(8), intent(in) :: micro_xs(5) 
    integer, intent(in) :: iso
    real(8) :: sig_arr(1:ace(iso)%NXS(5)), sig_sum, temp
    type (CrossSectionDataForm), pointer :: sigmt
    type (EnergyDist),  pointer :: eg
    real(8) :: rn
    integer :: i_source, i, n, ierg, NE
    integer :: iMT, MT
    integer :: pt1, pt2, pt3
    integer :: law, ilaw        ! collision law
    real(8) :: ipfac    ! interpolation factor
    real(8) :: F         ! collision probability
    real(8) :: erg_out, mu
    integer :: id(3)
    logical :: delayed
	real(8) :: pdf
    real(8) :: trvl, lambda
	
	
	delayed = .false. 
	! check if the source is delayed precursor
	if (ace(iso)%JXS(24)>0 .and. rang() <= getnudel(iso,p%E)/getnu(iso,p%E))   delayed = .true. 
    n = int(p%wgt*(micro_xs(5)/micro_xs(1))*(1.0/keff) + rang())
	
    ! fission site for FMFD calculation
    if ( fmfdon ) then
        if ( INSIDE(p%coord(1)%xyz) ) then
            id(:) = FM_ID(p%coord(1)%xyz)
            fsd_MC(id(1),id(2),id(3)) = fsd_MC(id(1),id(2),id(3)) + n
        end if
    end if

    ! fission source
    do i_source = 1, n
        bank_idx = bank_idx + 1
		thread_bank(bank_idx)%wgt = p%wgt * (micro_xs(4)/micro_xs(1))
        thread_bank(bank_idx)%xyz = p%coord(1)%xyz
        thread_bank(bank_idx)%uvw = rand_vec()
        
        !> Sample fission neutron energy 
        call getierg(iso,ierg,p%E)
        ipfac = max(0.d0, min(1.d0,(p%E-ace(iso)%E(ierg))/(ace(iso)%E(ierg+1)-ace(iso)%E(ierg))))
        sig_arr(:) = 0
        do i = 1, ace(iso)%NXS(5) !> through the reaction types...
        !> Determine reaction type number from 1 to NXS(5)
            !> 1. locate energy grid in SIG(i) block 
            if (int(ace(iso)%ty(i))/=19) cycle  ! consider fission reaction only
            sigmt => ace(iso)%sig_MT(i)
            if (ierg >= (sigmt%IE+sigmt%NE-1) .or. ierg < sigmt%IE  ) cycle 
            !> 2. calculate XS for the reaction type
            sig_arr(i) = sigmt%cx(ierg) + ipfac*(sigmt%cx(ierg+1)-sigmt%cx(ierg))
        enddo 
        
        
        !> determine collision law number
		rn = rang()
        if (delayed) then 
			! sample precursor group
			temp = 0; iMT = ace(iso)%NXS(8)
			do i = 1, ace(iso)%NXS(8)
				NE = ace(iso) % prcr( i ) % NE
				
				pt1 = 1; pt2 =  NE
				BS: do 
					if(pt2-pt1 == 1) exit BS
					pt3 = (pt2+pt1)/2 
					if (p%E >= ace(iso)%prcr(i)%E(pt3)) then 
						pt1 = pt3 
					else 
						pt2 = pt3
					endif 
				enddo BS
				
				ipfac = max(0.d0, min(1.d0,(p%E-ace(iso)%prcr(i)%E(pt1))/(ace(iso)%prcr(i)%E(pt1+1)-ace(iso)%prcr(i)%E(pt1))))
				pdf = ace(iso)%prcr(i)%F(pt1) + ipfac*(ace(iso)%prcr(i)%F(pt1+1)-ace(iso)%prcr(i)%F(pt1))
				temp = temp + pdf
				if (rn < temp) then 
					iMT = i
					exit
				endif
			enddo
			
			eg => ace(iso) % dneg(iMT)
			!thread_bank(bank_idx)%lambda = sample_precursor(iso, p%E)
			call bank_precursor(thread_bank(bank_idx), iso, p%E)
		else 
			sig_sum = sum(sig_arr(:)); temp = 0; 
			do i = 1, ace(iso)%NXS(5) !> through the reaction types...
				temp = temp + sig_arr(i)
				if (rn < temp/sig_sum) then
					MT = ace(iso)%MT(i)
					iMT = i 
					exit
				endif 
			enddo
            if(iMT<0) write(*,*) iso, iMT, micro_xs(1:5), n, 'WTF'
            if(iMT<0) write(*,*) allocated(ace(iso)%sigf), ace(iso)%NXS(3)
            if(iMT<0) write(*,*) ace(iso)%JXS(21), ace(iso)%ty(1:ace(iso)%NXS(5))
            if(iMT<0) write(*,*) 'SIGARR', ace(iso)%NXS(5), sig_sum, sig_arr(:)
			eg => ace(iso) % pneg(iMT)
			!thread_bank(bank_idx)%lambda = 0
		endif 
		
        rn = rang(); law = -1
        law_search: do ilaw = 1, eg%nlaw
            !> Binary search to corresponding energy grid index
            pt1 = 1; pt2 =  eg % dist(ilaw) % NE
            do 
                if(pt2-pt1 == 1) exit 
                pt3 = (pt2+pt1)/2 
                if (p%E >= eg%dist(ilaw)%E(pt3) ) then 
                    pt1 = pt3 
                else 
                    pt2 = pt3
                endif 
            enddo 
            
            !> Interpolate F(E) (P(E) in ENDF Manual...)
            ipfac = max(0.d0, min(1.d0,(p%E-eg%dist(ilaw)%E(pt1)) &
                /(eg%dist(ilaw)%E(pt1+1)-eg%dist(ilaw)%E(pt1))))
            F     = eg%dist(ilaw)%F(pt1) + ipfac*(eg%dist(ilaw)%F(pt1+1)-eg%dist(ilaw)%F(pt1))
            if (rn < F) then 
                law = eg % dist(ilaw) % law
                exit law_search
            endif 
        enddo law_search
        
        if (law < 0) then 
            print *, '**************************   law not selected'
            print *, F, ace(iso)%xslib, iMT, rn, pt1,  ipfac, i_source, n
            print *, (p%wgt*(micro_xs(5)/micro_xs(1))*(1.0/keff)), iso, micro_xs(5), ace(iso)%zaid
            stop
        endif 
        erg_out = p%E
        !print *, 'input E ',erg_out
        !> call the corresponding law subroutines
        call law_selector (erg_out, iso, mu, eg%dist(ilaw), iMT, law)
		!if (erg_out > Emax) erg_out = Emax-1.0d-10
		
        thread_bank(bank_idx)%E = erg_out
        thread_bank(bank_idx)%delayed = delayed
        thread_bank(bank_idx)%G = iso
        thread_bank(bank_idx)%time = 0
        if(do_ifp) then
        ! ADJOINT : pass particle's IFP related info. to bank
            if(latent>1) thread_bank(bank_idx)%delayedarr(1:latent-1) = p%delayedarr(2:latent)
            if(latent>1) thread_bank(bank_idx)%delayedlam(1:latent-1) = p%delayedlam(2:latent)
            if(latent>1) thread_bank(bank_idx)%nlifearr(1:latent-1)   = p%nlifearr(2:latent)
            if(p%trvltime > 0) thread_bank(bank_idx)%nlifearr(latent)    = p%trvltime
            if(delayed) then
                thread_bank(bank_idx)%delayedarr(latent) = iMT
                thread_bank(bank_idx)%delayedlam(latent) = ace(iso) % prcr(iMT) % decay_const
                thread_bank(bank_idx)%G   = iMT
            else !prompt
                thread_bank(bank_idx)%delayedarr(latent) = 0
                thread_bank(bank_idx)%delayedlam(latent) = 0
            endif
        endif
        if(do_fuel_mv .and. delayed) then
            lambda = ace(iso)%prcr(iMT)%decay_const
            thread_bank(bank_idx)%time= -log(rang())/lambda
            !call MSR_treatment(thread_bank(bank_idx)%xyz, thread_bank(bank_idx)%time)
            call prec_rz(thread_bank(bank_idx) % xyz, thread_bank(bank_idx) % time)
        endif
    enddo 

        
end subroutine


subroutine MSR_treatment(xyz, t_emit)
    use variables, only: core_radius, core_height, fuel_speed, core_base, t_rc, MSR_leak
    implicit none
    real(8), intent(inout) :: xyz(3)
    real(8), intent(in)    :: t_emit
    integer :: n_recirc
    real(8) :: t_end, t_res
    real(8) :: rn1, rn2
    integer :: zidx

    if(.not. do_fuel_mv) return
    if(fuel_speed <= 0.d0) return
    t_end   = (core_height-(xyz(3)-core_base)) / fuel_speed
    n_recirc= max(0,floor((t_emit-t_end)/(t_rc + (core_height/fuel_speed))))
    t_res   = t_emit - t_end - n_recirc * (t_rc + core_height/fuel_speed)

    if(t_emit < t_end) then ! decays before hits top
        xyz(3) = xyz(3) + fuel_speed * t_emit
    elseif(t_res<=t_rc) then ! decays out of the core: exterminates
        bank_idx = bank_idx - 1
        !print *, 'DEAD', t_emit, t_end, t_res, t_rc
        MSR_leak = MSR_leak + 1
        !print *, MSR_leak
    elseif(t_res>t_rc) then ! recirculate and decayed
        rn1 = rang(); rn2 = rang()
        xyz(1) = rn1 * core_radius * cos(2*pi*rn2)
        xyz(2) = rn1 * core_radius * sin(2*pi*rn2)
        xyz(3) = core_base + fuel_speed * (t_res-t_rc)
        !print *, 'RECIRC', t_emit, t_end, t_res, t_rc, xyz(1:3)
    else
        bank_idx = bank_idx - 1
    endif
end subroutine

subroutine prec_rz(xyz, t_emit)
    use variables, only : nr, nz, &
        axial_axis, &
        velocity_r, velocity_z, active_r, active_z, &
        riser_r, &
        t_recirc, &
        MSR_leak
    implicit none
    real(8), intent(inout) :: xyz(3) !> Position of prec. [cm]
    real(8), intent(in)    :: t_emit !> Time to emit [sec]
    
    ! integer : nr,  nz               !> # of mesh along r and z
    ! real: axial_axis                !> xy pos of axial_axis [cm]
    ! real array: vr(nr,nz)           !> Salt r velo. [cm/s]
    ! real array: vz(nr,nz)           !> Salt z velo. [cm/s]
    ! real array: active_r(nr+1)      !> Active core radial mesh [cm]
    ! real array: active_z(nz+1)      !> Active core axial mesh [cm]
    ! real: riser_r                   !> Riser radius from 0 [cm]  
    ! real: t_recirc                  !> Time to recirculate [sec]

    real(8) :: pos(3)                 !> Position wrt Axial_axis
    real(8) :: t_left                 !> Time left to emit [sec]
    real(8) :: r, z, cost, sint, theta!> R, Z, cos(t), sin(t) [cm]
    integer :: i, ii, j, jj
    real(8) :: vz, vr                 !> v along radial and axial [cm/s]
    real(8) :: tr, tz


    ! === OUTLINE ===
    ! PRELIM: END CONDITION
    if( .not. do_fuel_mv) return

    ! 0. T_LEFT = t_emit
    t_left = t_emit

    ! 1. Convert xyz to rz + theta (+ END COND)
    pos = xyz ; pos(1:2) = pos(1:2) - axial_axis(1:2)
    r = sqrt(pos(1)**2+pos(2)**2)
    if ( r > active_r(nr+1) ) return

    z = pos(3)
    if ( z < active_z(1) .or. z > active_z(nz+1) ) return

    cost = pos(1) / r;  sint = pos(2) / r

    ! 2. (r,z) in [r(i-1),ri] and [z(j-1),zj]
    ! Find mesh
    do ii = 1, nr
        if( r < active_r(ii+1) ) then
            i = ii; exit
        endif
    enddo

    do jj = 1, nz
        if( z < active_z(jj+1) ) then
            j = jj; exit
        endif
    enddo

    ! DO while alive
    do
        if(t_emit> 1D4) print '(I,A7,5F10.3)', bank_idx, 'RZT', r, z, cost, sint, t_left

        ! 3. vr, vz = v(i,j)
        vr = velocity_r(i,j); vz = velocity_z(i,j)
        ! 3-1. IF r out of active core: vr = 0d0
        if( r == 0d0 .and. vr < 0d0 ) vr = 0d0
        if( r == active_r(nr+1) .and. vr > 0d0 ) vr = 0d0
        if( z == 0d0 .and. vz < 0d0 ) vz = 0d0
        if( z == active_z(nz+1) .and. vz > 0d0 ) vz = 0d0
    
        ! 3-2. IF vr = vz = 0, TERMINATE
        if ( vr == 0d0 .and. vz == 0d0 ) then
            xyz(1) = cost * r + axial_axis(1)
            xyz(2) = sint * r + axial_axis(2)
            xyz(3) = z
            if(t_emit > 1D4) print '(I,A7,5F10.3)', bank_idx, 'STUCK', r, z, cost, sint, t_left
            return
        endif
        
        ! 4-0. tr = tz = 0
        tr = 0d0; tz = 0d0
        ! 4-1. IF abs(vr) > 0
        ! 4-1-1.  tr = (ri-r)/vr
        if( vr > 0 ) then
            tr = (active_r(i+1) - r) / vr
        elseif ( vr < 0 ) then
            tr = (r - active_r(i)) / abs(vr)
        endif
    
        ! 4-2. IF abs(vz) > 0
        ! 4-2-1.  tz = (zi-z)/vz
        if( vz > 0 ) then
            tz = (active_z(j+1) - z) / vz
        elseif( vz < 0 ) then
            tz = (z - active_z(j)) / abs(vz)
        endif
    
        ! 4-3. Set zero time larger than other
        ! NOTE) tr = tz = 0 is impossible... in theory
        if( tr == 0d0 ) tr = tz + 1d0
        if( tz == 0d0 ) tz = tr + 1d0 
    
        ! 5. IF (tleft < tr and tz)
        if ( t_left < tr .and. t_left < tz ) then
            ! 5-1. rz = r+tleft*vr, z+tleft*vz
            r = r + t_left * vr
            z = z + t_left * vz
            ! 5-2. Convert rtz to xyz => DONE
            xyz(1) = cost * r + axial_axis(1)
            xyz(2) = sint * r + axial_axis(2)
            xyz(3) = z
            if(t_emit>1D4) print '(I,A7,5F10.3)', bank_idx, 'EMIT', r, z, cost, sint, t_left
            return
    
        ! 6. ELSE if (tr < tz)
        elseif ( tr < tz ) then
            ! 6-1. rz = r+tr*vr (=ri), z+tr*vz
            if( vr > 0d0 ) then
                r = active_r(i+1)
            elseif ( vr < 0d0 ) then
                r = active_r(i)
            endif
            z = z + tr * vz
            ! 6-2. t_left = t_left - tr
            t_left = t_left - tr
            ! 6-3. IF r <= 0 || r >= active_r(nr+1)
            ! 6-3-1.  r = 0 || r = active_r(nr+1)
            if ( r <= 0d0 ) then
                r = 0d0
            elseif ( r >= active_r(nr+1) ) then
                r = active_r(nr+1)
            ! 6-4. ELSE
            else
            ! 6-4-1.  i = i +- 1
                i = i + sign(1d0, vr)
                if(i==0) print *, 'WTF', r, z, i, j, vr, vz, tr, tz, t_left
            endif
    
        ! 7. ELSE (tz > tr)
        elseif ( tz < tr ) then
            ! 7-1. rz = r+tz*vr, z+tz*vz (=zi)
            r = r + tz * vr
            if( vz > 0d0 ) then
                z = active_z(j+1)
            elseif ( vz < 0d0 ) then
                z = active_z(j)
            endif
            ! 7-2. t_left = t_left - tz
            t_left = t_left - tz
            ! 7-3. IF z >= active_z(nz+1)
            if ( z >= active_z(nz+1) ) then
                ! 7-3-1.  IF r > riser_r !> Trapped
                if ( r > riser_r ) then
                    ! 7-3-1-1.   z = active_z(nz+1)
                    z = active_z(nz+1)
                endif
            ! 7-4. ELSEIF z <= active_z(1)
            elseif ( z <= active_z(1) ) then
                ! 7-4-1.  z = active_z(1)
                z = active_z(1)
            ! 7-5. ELSE
            else
                ! 7-5-1.  j = j +- 1
                j = j + sign(1d0, vz)
            endif
        endif

        ! 8. If Reaches TOP & Inside riser
        if ( r < riser_r .and. z >= active_z(nz+1) ) then
            if(t_emit>1D4) print '(I,A7,5F10.3)', bank_idx, 'TOP', r, z, cost, sint, t_left
            ! 8-1.   IF t_left < t_recirc
            if( t_left <= t_recirc ) then
                ! 8-1-1.    KILL and DONE
                bank_idx = bank_idx - 1
                MSR_leak = MSR_leak + 1
                if(t_emit>1D4) print '(I,A7,5F10.3)', bank_idx, 'LEAK', r, z, cost, sint, t_left
                return
            ! 8-2.   ELSE
            else
                ! 8-2-1.    t_left -= t_recirc
                t_left = t_left - t_recirc
                ! 8-2-2.    j = 1, z = 0
                j = 1; z = 0d0
                ! 8-2-3.    sample r and theta randomly
                r = active_r(nr+1) * sqrt(rang())
                do ii = 1, nr
                    if( r < active_r(ii+1) ) then
                        i = ii; exit
                    endif
                enddo
                theta = 2d0 * pi * rang()
                cost = cos(theta); sint = sin(theta);
                if(t_emit>1D4) print '(I,A7,5F10.3)', bank_idx, 'RECIRC', r, z, cost, sint, t_left
            endif
        endif
    enddo 
end subroutine prec_rz
! ================================================== !
!    fission_E() samples the fission neutron Energy. 
! ================================================== !
function fission_E (E_in, iso,delayed,delayed_group) result (E_out)

	implicit none 
	
	real(8), intent(in) :: E_in
    integer, intent(in) :: iso
	logical, intent(in) :: delayed
    integer, optional	:: delayed_group
	
    real(8) :: sig_arr(1:ace(iso)%NXS(5)), sig_sum, temp
    type (CrossSectionDataForm), pointer :: sigmt
    type (EnergyDist),  pointer :: eg
    real(8) :: rn
    integer :: i_source, i, n, ierg
    integer :: iMT, MT
    integer :: pt1, pt2, pt3
    integer :: law, ilaw        ! collision law
    real(8) :: ipfac    ! interpolation factor
    real(8) :: F         ! collision probability
    real(8) :: E_out, mu

    !> Sample fission neutron energy 
    call getierg(iso,ierg,E_in)
    ipfac = max(0.d0, min(1.d0,(E_in-ace(iso)%E(ierg))/(ace(iso)%E(ierg+1)-ace(iso)%E(ierg))))
    sig_arr(:) = 0
    do i = 1, ace(iso)%NXS(5) !> through the reaction types...
    !> Determine reaction type number from 1 to NXS(5)
        !> 1. locate energy grid in SIG(i) block 
        if (int(ace(iso)%ty(i))/=19) cycle  ! consider fission reaction only
        sigmt => ace(iso)%sig_MT(i)
        if (ierg >= (sigmt%IE+sigmt%NE-1) .or. ierg < sigmt%IE  ) cycle 
        !> 2. calculate XS for the reaction type
        sig_arr(i) = sigmt%cx(ierg) + ipfac*(sigmt%cx(ierg+1)-sigmt%cx(ierg))
    enddo 
    
    rn = rang()
    sig_sum = sum(sig_arr(:)); temp = 0; 
    do i = 1, ace(iso)%NXS(5) !> through the reaction types...
        temp = temp + sig_arr(i)
        if (rn < temp/sig_sum) then
            MT = ace(iso)%MT(i)
            iMT = i 
            exit
        endif 
    enddo
    
    !> determine collision law number
    if (delayed) then 
		if ( present(delayed_group) ) iMT = delayed_group
		eg => ace(iso) % dneg(iMT)
	else 
		eg => ace(iso) % pneg(iMT)
	endif 
	
    rn = rang(); law = -1
    law_search: do ilaw = 1, eg%nlaw
        !> Binary search to corresponding energy grid index
        pt1 = 1; pt2 =  eg % dist(ilaw) % NE
        do 
            if(pt2-pt1 == 1) exit 
            pt3 = (pt2+pt1)/2 
            if (E_in >= eg%dist(ilaw)%E(pt3) ) then 
                pt1 = pt3 
            else 
                pt2 = pt3
            endif 
        enddo 
        
        !> Interpolate F(E) (P(E) in ENDF Manual...)
        ipfac = max(0.d0, min(1.d0,(E_in-eg%dist(ilaw)%E(pt1)) &
            /(eg%dist(ilaw)%E(pt1+1)-eg%dist(ilaw)%E(pt1))))
        F     = eg%dist(ilaw)%F(pt1) + ipfac*(eg%dist(ilaw)%F(pt1+1)-eg%dist(ilaw)%F(pt1))
        if (rn < F) then 
            law = eg % dist(ilaw) % law
            exit law_search
        endif 
    enddo law_search
    
    E_out = E_in

    !> call the corresponding law subroutines
    call law_selector (E_out, iso, mu, eg%dist(ilaw), iMT, law)
	if (E_out > Emax) E_out = Emax-1.0d-10
	
	

end function 


! ================================================== !
!    absorption_CE() kills the particle if the weight
!    is too small than the cutoff + Russian Roulette
! ================================================== !
subroutine absorption_CE (p)
    type(particle), intent(inout) :: p
    real(8) :: wgt_s
    
    !if (p%n_collision > 1000) then 
    !    p%wgt = 0 
    !    p%alive = .false.
    !    print *, 'killed for too many collisions'
    !endif
    
    !if (p%E < 1.0d-11) then 
    !    p%wgt = 0 
    !    p%alive = .false.
    !    !print *, 'killed for too small energy'
    !endif 
    if (p%wgt < wgt_min) THEN !call Russian_Roulette(p)
        wgt_s = 2*wgt_min
        if ((p%wgt/wgt_s).ge.rang()) then
            p%wgt = wgt_s
        else
            !p%wgt = 0 
			!print *, 'killed for small weight'
            p%alive = .false.
        endif
    endif
end subroutine

! ================================================== !
!    directionEnergy() calculates mu and E in the 
!    target-at-rest (lab) frame 
! ================================================== !
subroutine directionEnergy (p, mu, iMT, iso) 

    type(particle), intent(inout) :: p 
    real(8), intent(inout) :: mu
    integer, intent(in) :: iMT, iso 
    real(8) :: mu_CM, Eout_CM, Eout_lab, Ein, A
    real(8) :: u,v,w, u0, v0, w0, phi
    real(8) :: temp, val
    logical :: found = .false. 
    integer :: j 
    real(8) :: kT        ! temperature (MeV)
    real(8):: uvw(3)
    
    
    !> Elastic scattering 
    if (iMT == 0) then
        !print *, 'elastic'
        !> Elastic Scattering Energy calculation 
        
        mu_CM = mu
        Ein = p%E
        A = ace(iso)%atn
        kT = ace(iso)%temp
        

        ! collision with resonant nuclei
        if ( ace(iso)%resonant /= 0 ) then
            call TWO_BODY_COLLISION(p,mu,kT,A,ace(iso)%resonant)
        else

        ! target in rest
        if ( p%E > 4d2*kT .and. A > 1D0 ) then
            temp = 1.+A*(A+2.*mu_CM)
            Eout_lab = Ein*temp/(1.+A)**2
            mu     = (1.+mu_CM*A)/sqrt(temp)
            p%E = Eout_lab 
            p%coord(1)%uvw = rotate_angle(p%coord(1)%uvw, mu, iso)
        ! target in motion
        else
            call TWO_BODY_COLLISION(p,mu,kT,A,ace(iso)%resonant)
        end if
        end if
        
        
    !> Inelastic scattering 
    elseif (ace(iso)%TY(iMT) < 0) then !> CM frame
        !> mu and p%E are in CM frame
        !> convert to lab frame (existing code )
        A = ace(iso)%atn
        Eout_CM = p%E
        Ein = p%last_E
        mu_CM = mu
        Eout_lab = Eout_cm + (Ein + 2.*mu_cm*(A+1.)*sqrt(Ein*Eout_cm))/(A+1.)**2
        mu         = mu_CM*sqrt(Eout_CM/Eout_lab) + sqrt(Ein/Eout_lab)/(A+1.)
        
        p%E = Eout_lab
        p%coord(1)%uvw = rotate_angle(p%coord(1)%uvw, mu, iso)
        !do j = 1, p%n_coord
        !    p%coord(j)%uvw = rotate_angle (p%coord(j)%uvw, mu)
        !enddo 
        
    else!if(ace(iso)%TY(iMT)>0) then  !> Reaction was in TAR frame 
        !> mu and p%E are in lab frame
        p%coord(1)%uvw = rotate_angle(p%coord(1)%uvw, mu, iso)

        !do j = 1, p%n_coord
        !    p%coord(j)%uvw = rotate_angle (p%coord(j)%uvw, mu)
        !enddo 
    endif 
    
end subroutine 

! =============================================================================
! TWO_BODY_COLLISION
! =============================================================================
subroutine TWO_BODY_COLLISION(p,mu,kT,A,iso0K)
    type(Particle), intent(inout):: p
    real(8), intent(inout):: mu
    real(8), intent(in):: kT
    real(8), intent(in):: A
    integer, intent(in):: iso0K
    real(8):: speedn                    ! neutron speed
    real(8):: uvw(3)                    ! incoming & outgoing direction
    real(8):: uvw_cm(3)                 ! direction of COM
    real(8):: v_t(3), v_n(3), v_cm(3)   ! velocity of target, neutron, COM
    real(8):: v_r2                      ! square of relative speed
    real(8):: mu_cm                     ! cosine angle
    real(8):: bb                        ! beta parameter

    real(8), parameter:: m_u = 1.660540D-27 ! amu to Kg
    real(8), parameter:: m_n = 1.008664     ! neutron mass (amu)
    real(8), parameter:: mevj = 1.6022D-13  ! MeV to Joule

    ! -------------------------------------------------------------------------
    ! LAB system
    ! - speed of neutron
    speedn = sqrt(2D0*p%E*mevj/(m_u*m_n))   ! m/s
    ! - neutron incoming direction
    uvw = p%coord(1)%uvw
    ! - velocity of neutron
    v_n = speedn * uvw
    ! - target velocity
    !   - DBRC
    if ( iso0K /= 0 ) then
        if ( DBRC_E_min > p%E ) then
            call TARGETV(p%E,uvw,A,kT,v_t,v_r2)
        elseif ( DBRC_E_max < p%E ) then
            v_t = 0
        else
            call REJECTION_CORRECTION(iso0K,p%E,uvw,A,kT,v_t)
        end if
    !   - Constant XS
    else
        call TARGETV(p%E,uvw,A,kT,v_t,v_r2)
    end if


    ! -------------------------------------------------------------------------
    ! COM system
    ! - velocity of COM
    v_cm = (v_n + A * v_t)/(A+1D0)
    ! - transform to COM
    v_n = v_n - v_cm
    ! - speed of neutron
    speedn = sqrt(dot_product(v_n,v_n))
    ! - scattering angle
    mu_cm = mu
    ! - direction cosine
    uvw_cm = v_n / speedn
    ! - neutron velocity
    v_n = speedn * rotate_angle(uvw_cm,mu_cm)


    ! -------------------------------------------------------------------------
    ! LAB system
    ! - transform to LAB
    v_n = v_n + v_cm
    ! - neutron speed
    speedn = sqrt(dot_product(v_n,v_n))
    ! - neutron outgoing energy
    p%E = (m_u*m_n)*speedn*speedn/(mevj*2D0)
    ! - angle test
    mu = dot_product(uvw,v_n) / speedn
    if ( abs(mu) > 1D0 ) mu = sign(1D0,mu)
    ! - neutron outgoing direction ( p%E = speed of neutron )
    p%coord(1)%uvw = v_n / speedn


end subroutine

! =============================================================================
! TARGETV
! =============================================================================
subroutine TARGETV(E0,uvw,A,kT,v_t,accept1)
    real(8), intent(in):: E0        ! incident energy (MeV)
    real(8), intent(in):: uvw(3)    ! incident direction
    real(8), intent(in):: A         ! atomic weight ratio
    real(8), intent(in):: kT        ! temperature (MeV)
    real(8), intent(inout):: v_t(3) ! target velocity
    real(8), intent(out):: accept1  ! square of relative speed
    real(8):: urn1, urn2            ! uniform random number
    real(8):: accept2               ! acceptance parameter
    real(8):: speedt                ! target speed
    real(8):: mut                   ! cosine angle
    real(8):: xx, xx2, yy           ! parameters
    real(8):: aa, bb, cc, ss

    real(8), parameter:: m_u = 1.660540D-27 ! AMU to Kg
    real(8), parameter:: m_n = 1.008664     ! neutron mass (amu)
    real(8), parameter:: mevj = 1.6022D-13  ! MeV to Joule

    ! no vibration
    if ( kT == 0 ) then
        v_t = 0
        return
    end if

    ! parameters
    bb = sqrt(A*m_u*m_n/(2D0*kT*mevj))
    yy = sqrt(A*E0/kT)   ! (beta) X (v_n)
    aa = 2D0/(sqrt(pi)*yy+2D0)

    ! sampling target speed from Maxwellian distribution
    do
        ! 1) target speed
        urn1 = rang()
        urn2 = rang()
        if ( rang() < aa ) then
            xx2 = -log(urn1*urn2)
        else
            cc = cos(pi/2D0*rang())
            xx2 = -log(urn1)-log(urn2)*cc*cc
        end if
        xx = sqrt(xx2)  ! (beta) X (v_t)

        ! 2) cosine angle (isotropic)
        mut = 2D0*rang()-1D0

        ! 3) rejection method
        accept1 = yy*yy+xx2-2D0*xx*yy*mut
        accept2 = xx+yy
        if ( rang() < sqrt(accept1)/accept2 ) exit
    end do

    ! target speed
    speedt = xx / bb

    ! target velocity
    v_t = speedt * rotate_angle(uvw,mut)

    ! square of relative speed
    accept1 = accept1 / (bb*bb)


    ! Sampling scheme by MCNP & Serpent
!    do
!        if ( rang()*(yy+1.12837917D0) > yy ) then
!            xx2 = -log(rang()*rang())
!        else
!            do
!                urn1 = rang()
!                urn2 = rang()
!                ss = urn1*urn1+urn2*urn2
!                if ( ss <= 1D0 ) exit
!            end do
!            xx2 = -urn1*urn1*log(ss)/ss-log(rang())
!        end if
!
!        xx = sqrt(xx2)
!        mut = 2D0*rang()-1D0
!        accept = yy*yy+xx2-2D0*xx*yy*mut
!        if ( (rang()*(yy+xx))**2 <= accept ) exit
!
!    end do

end subroutine


! =============================================================================
! REJECTION_CORRECTION
! =============================================================================
subroutine REJECTION_CORRECTION(iso0K,E0,uvw,a,kT,v_t)
    implicit none
    integer, intent(in):: iso0K     ! isotope number
    real(8), intent(in):: E0        ! incident energy (MeV)
    real(8), intent(in):: uvw(3)    ! incident direction
    real(8), intent(in):: A         ! atomic weight ratio
    real(8), intent(in):: kT        ! temperature (MeV)
    real(8), intent(inout):: v_t(3) ! target velocity

    type(AceFormat0K), pointer:: a0
    real(8), parameter:: m_u = 1.660540D-27 ! AMU to kg
    real(8), parameter:: m_n = 1.008664     ! neutron mass (amu)
    real(8), parameter:: mevj = 1.6022D-13  ! Mev to Joule

    real(8):: v_r2
    real(8):: E_rel, E_min, E_max
    real(8):: speedn
    integer:: imin, imax
    real(8):: xs_low, xs_high, xs_max, xs_0K
    real(8):: bb
    real(8):: ipfac

    if ( associated(a0) ) nullify(a0)
    a0 => ace0K(iso0K)

    ! parameters
    bb = sqrt(A*m_u*m_n/(2D0*kT*mevj))     ! s/m
    speedn = sqrt(2D0*E0*mevj/(m_u*m_n))   ! m/s

    ! energy range for XS search
    ! - mimimum energy
    E_min = max(0D0,speedn-4D0/bb)
    E_min = 5D-1*(m_n*m_u)*E_min*E_min/mevj
    ! - maximum energy
    E_max = speedn+4D0/bb
    E_min = 5D-1*(m_n*m_u)*E_min*E_min/mevj
    E_max = 5D-1*(m_n*m_u)*E_max*E_max/mevj

    ! energy indices
    call GET_IERG_DBRC(iso0K,imin,E_min)
    call GET_IERG_DBRC(iso0K,imax,E_max)

    ! cross section in the energy range
    ipfac = max(0D0,min(1D0, &
        (a0%xs0(imin+1)-a0%xs0(imin))/(a0%erg(imin+1)-a0%erg(imin))))
    xs_low = a0%xs0(imin) + ipfac*(E_min-a0%xs0(imin))
    ipfac = max(0D0,min(1D0, &
        (a0%xs0(imax+1)-a0%xs0(imax))/(a0%erg(imax+1)-a0%erg(imax))))
    xs_high = a0%xs0(imax) + ipfac*(E_max-a0%xs0(imax))
    xs_max = max(xs_low,maxval(a0%xs0(imin:imax)),xs_high)

    do
        ! target velocity
        call TARGETV(E0,uvw,A,kT,v_t,v_r2)
        ! - relative energy
        E_rel = 5D-1*(m_n*m_u)*v_r2/mevj
        ! cross sectioon
        xs_0K = GET_ELASTIC0K(iso0K,E_rel)

        if ( rang() < xs_0K / xs_max ) exit

    end do

end subroutine


! =============================================================================
! GET_ELASTIC0K
! =============================================================================
function GET_ELASTIC0K(iso0K,E_rel) result(xs)
    real(8):: xs
    integer, intent(in):: iso0K
    real(8), intent(in):: E_rel
    type(AceFormat0K), pointer:: a0
    integer:: ie
    real(8):: ip

    if ( associated(a0) ) nullify(a0)
    a0 => ace0K(iso0K)

    call GET_IERG_DBRC(iso0K,ie,E_rel)
    ip = max(0D0,min(1D0,(E_rel-a0%erg(ie))/(a0%erg(ie+1)-a0%erg(ie))))
    xs = a0%xs0(ie) + ip*(a0%xs0(ie+1)-a0%xs0(ie))

end function



! =============================================================================
function rotate_angle (uvw0, mu, iso) result (uvw)
    implicit none
    real(8), intent(in) :: uvw0(3) 
    real(8), intent(in) :: mu 
    integer, optional   :: iso
    real(8) :: uvw(3)
    
    real(8) :: phi
    real(8) :: u0, v0, w0 
    real(8) :: a, b, sinphi, cosphi, temp
    integer :: i 
    
    u0 = uvw0(1); v0 = uvw0(2); w0 = uvw0(3)
    phi = 2*PI*rang()
    sinphi = sin(phi) 
    cosphi = cos(phi)
    a = sqrt(max(0.0d0,1-mu**2))
    b = sqrt(max(0.0d0, 1-w0**2))
    
    if (b > 1.0d-10) then 
        uvw(1) = mu*u0 + a*(u0*w0*cosphi-v0*sinphi)/b
        uvw(2) = mu*v0 + a*(v0*w0*cosphi+u0*sinphi)/b
        uvw(3) = mu*w0 - a*b*cosphi
    else 
        b = sqrt(max(0.0d0, 1-v0**2))
        uvw(1) = mu*u0 + a*(u0*v0*cosphi + w0*sinphi)/b
        uvw(2) = mu*v0 - a*b*cosphi
        uvw(3) = mu*w0 + a*(v0*w0*cosphi - u0*sinphi)/b
    endif

    do i = 1, 3 
        if ( uvw(i) /= uvw(i) ) then 
            print*, "rotation error"
            if ( present(iso) ) print*, iso, ace(iso)%library
            print *, a, b, mu
            print *, uvw(:) 
            stop
        endif 
    enddo 
    !temp = sqrt(uvw(1)**2 + uvw(2)**2 + uvw(3)**2) 
    !uvw(:) = uvw(:)/temp
    
    !print *, sqrt(uvw(1)**2 + uvw(2)**2 + uvw(3)**2) 
end function 



subroutine DB_POLY(ne,ee)
    integer, intent(in):: ne
    real(8), intent(in):: ee(:)
    real(8) :: micro_xs(6)
    real(8):: xs(3,ne)
    real(8):: xs0(3)
    integer:: id(3)
    integer:: ii, jj
    real(8):: coef(3)
    real(8):: mm(3,3), aa(3), bb(3)
    real(8):: temp, tt0, tt1


    id(1) = 4
    id(2) = 7
    id(3) = 10

    aa(1) = 293D0
    aa(2) = 9D2
    aa(3) = 2.5D3
    temp  = 6D2

    do ii = 1, 3
        mm(ii,1) = aa(ii)*aa(ii)
        mm(ii,2) = aa(ii)
        mm(ii,3) = 1D0
    end do


    call CPU_TIME(tt0)
    do jj = 1, ne
    do ii = 1, 3
        micro_xs = getMicroXS(id(ii),ee(jj))
        bb(ii) = micro_xs(1)
    end do
    call GAUSSEL(mm,bb,coef)
    !write(8,1), ee(jj), coef(1)*temp*temp+coef(2)*temp+coef(3)
    !write(8,1), ee(jj), bb(1), bb(2), bb(3)
    !print*
    !pause

    end do
    call CPU_TIME(tt1)
    print*, tt1-tt0

    do jj = 1, ne
        write(8,1), ee(jj), (xs(ii,jj), ii =1, 3)
    end do
    1 format(10es15.7)
    stop



    print*, size(ee), ne
    stop


end subroutine

subroutine GAUSSEL(aa,bb,xx)
    real(8):: aa(3,3), bb(3), xx(3)
    real(8):: mm(3,3)
    integer:: ii, jj, kk
    real(8):: temp

    mm = aa

    do kk = 1, 2
    do ii = kk+1, 3
        temp = mm(ii,kk)/mm(kk,kk)
        mm(ii,kk) = 0
        bb(ii) = bb(ii) - temp*bb(kk)
        do jj = kk+1, 3
            mm(ii,jj) = mm(ii,jj) - temp*mm(kk,jj)
        end do
    end do
    end do

    xx(3) = bb(3)/mm(3,3)
    do ii = 2, 1, -1
        temp = 0
        do jj = ii+1, 3
            temp = temp + mm(ii,jj)*xx(jj)
        end do
        xx(ii) = (bb(ii)-temp)/mm(ii,ii)
    end do

end subroutine


! =================================================================================
! ***************             Subroutines for dynamic MC             **************
! =================================================================================


! ================================================== !
!    fissionSite_dynamic() samples the potential fission 
!    source through the implicit capture process. 
! ================================================== !
subroutine fissionSite_dynamic (p, iso, micro_xs)
	
	implicit none 
	
    type(particle), intent(inout) :: p
	integer, intent(in) :: iso
    real(8), intent(in) :: micro_xs(6)
    real(8) :: sig_tot, rnum, wgt_s, uvw_temp(3)
    integer :: i, i_group, idx_group, n_group, n, bsize
	logical :: delayed
	integer :: pg, ng, nsplit
	integer :: pt1, pt2, pt3 
	integer :: NE
	real(8) :: r, pdf, ipfac
	real(8) :: nu_del, speedn
	real(8) :: temp, beta, lambda_b
	real(8) :: beta_g(8), lambda(8)
	
	
	
	!> For Transient Neutron Source Initialization 
	if (.not. do_transient) return 
	if (.not. curr_cyc > n_inact) return 
	
	! Calculate beta_g & lambda 
	nu_del = getnudel(iso,p%E)
	ng = ace(iso)%NXS(8)
	if (ng > 8) then 
		print *, "delayed precursor group is larger than 8 :: ", ng, ace(iso)%library 
		stop
	endif 
	
	beta_g(:) = 0 
	lambda(:) = 0 
	! sample precursor group
	do i = 1, ng
		NE = ace(iso) % prcr( i ) % NE
        pt1 = 1; pt2 =  NE
        BS: do 
            if(pt2-pt1 == 1) exit BS
            pt3 = (pt2+pt1)/2 
            if (p%E >= ace(iso)%prcr(i)%E(pt3)) then 
                pt1 = pt3 
            else 
                pt2 = pt3
            endif 
        enddo BS
		
        ipfac = max(0.d0, min(1.d0,(p%E-ace(iso)%prcr(i)%E(pt1))/(ace(iso)%prcr(i)%E(pt1+1)-ace(iso)%prcr(i)%E(pt1))))
        pdf = ace(iso)%prcr(i)%F(pt1) + ipfac*(ace(iso)%prcr(i)%F(pt1+1)-ace(iso)%prcr(i)%F(pt1))
		beta_g(i) = pdf * nu_del
		lambda(i) = ace(iso) % prcr( i ) % decay_const
	enddo 		
	
	
	
    speedn = sqrt(2D0*p%E*mevj/(m_u*m_n))   ! m/s
	
	
	beta = sum(beta_g(1:ng))
	temp = 0 
	do i = 1, ng 
		temp = temp + beta_g(i) / lambda(i)
	enddo 
	lambda_b = beta / temp
	!> Neutron Source Sample for Transient Calculation (not fission source) 
	init_idx = init_idx + 1
	thread_bank_init(init_idx)%wgt 			= p%wgt / (speedn*micro_xs(1))
	thread_bank_init(init_idx)%xyz 			= p%coord(1)%xyz
	thread_bank_init(init_idx)%uvw 			= p%coord(1)%uvw
	thread_bank_init(init_idx)%delayed 		= .false.
	thread_bank_init(init_idx)%time 		= 0
	thread_bank_init(init_idx)%E 			= p%E
	
	
	!> Precursor bank add
	temp = p%wgt*(beta/lambda_b)*micro_xs(5)/micro_xs(1)
	
	nsplit = int(temp/1.0) + 1 
	do i = 1, nsplit
		prec_idx = prec_idx + 1
		prec_thread(prec_idx)%wgt 			= temp/real(nsplit,8)
		prec_thread(prec_idx)%xyz 			= p%coord(1)%xyz
		prec_thread(prec_idx)%E 			= p%E
		prec_thread(prec_idx)%idx 			= iso
		prec_thread(prec_idx)%time 			= 0
		prec_thread(prec_idx)%beta(1:ng)	= beta_g(1:ng)
		prec_thread(prec_idx)%lambda(1:ng)	= lambda(1:ng)
	enddo
        
end subroutine fissionSite_dynamic

!===============================================================================
! SAMPLE_PRECURSOR - Sample precursor group & decay constant.
!===============================================================================
	subroutine bank_precursor(prec, iso, E)
		integer, intent(in) :: iso 
		real(8), intent(in) :: E 
		type(bank) :: prec
		integer :: i, pt1, pt2, pt3 
		integer :: NE
		real(8) :: r, pdf, ipfac
		real(8) :: nu_del
		integer :: prec_group
		
		nu_del = getnudel(iso,E)
		prec_group = ace(iso)%NXS(8)
		if (prec_group > 8) then 
			print *, "delayed precursor group is larger than 8 :: ", prec_group, ace(iso)%library 
			stop
		endif 
		
		prec%beta(:) = 0 
		prec%lambda(:) = 0 
		! sample precursor group
		do i = 1, prec_group
			NE = ace(iso) % prcr( i ) % NE
			
            pt1 = 1; pt2 =  NE
            BS: do 
                if(pt2-pt1 == 1) exit BS
                pt3 = (pt2+pt1)/2 
                if (E >= ace(iso)%prcr(i)%E(pt3)) then 
                    pt1 = pt3 
                else 
                    pt2 = pt3
                endif 
            enddo BS
			
            ipfac = max(0.d0, min(1.d0,(E-ace(iso)%prcr(i)%E(pt1))/(ace(iso)%prcr(i)%E(pt1+1)-ace(iso)%prcr(i)%E(pt1))))
            pdf = ace(iso)%prcr(i)%F(pt1) + ipfac*(ace(iso)%prcr(i)%F(pt1+1)-ace(iso)%prcr(i)%F(pt1))
			
			prec%beta(i) = pdf * nu_del
			prec%lambda(i) = ace(iso) % prcr( i ) % decay_const
			
		enddo 		

	end subroutine

! ================================================== !
!    inElastic_CE() handles all inelastic 
!	 scattering events
!    Output :: Angle & Energy of p object
! ================================================== !
subroutine inElastic_CE (p,iso,xn)
    type(particle), intent(inout) :: p
    type (AngularDist), pointer :: an
    type (EnergyDist),  pointer :: eg
    type (CrossSectionDataForm), pointer :: sigmt
    integer, intent(in) :: iso
    integer, intent(inout) :: xn
    integer :: i, j
    integer :: iMT, MT 
    integer :: pt1, pt2, pt3
    integer :: ierg
    integer :: law, ilaw        ! collision law
    real(8) :: ipfac    ! interpolation factor
    real(8) :: F         ! collision probability
    real(8) :: rn 
    real(8) :: mu 
    real(8) :: erg
    real(8) :: sig_arr(1:ace(iso)%NXS(5)), sig_sum, temp
    real(8) :: u, v, w, phi
    real(8) :: micro(6)
    
    
    
    erg = p%E
    call getierg(iso,ierg,erg)
    ipfac = max(0.d0, min(1.d0,(erg-ace(iso)%E(ierg))/(ace(iso)%E(ierg+1)-ace(iso)%E(ierg))))
    
    sig_arr(:) = 0
    do i = 1, ace(iso)%NXS(5) !> through the reaction types...
        if (abs(ace(iso)%ty(i))==19 ) cycle
        sigmt => ace(iso)%sig_MT(i)
        if (ierg >= (sigmt%IE+sigmt%NE-1) .or. ierg < sigmt%IE  ) cycle 
        sig_arr(i) = sigmt%cx(ierg) + ipfac*(sigmt%cx(ierg+1)-sigmt%cx(ierg))
    enddo 
    
    
    rn = rang()
    sig_sum = sum(sig_arr(:)); temp = 0; iMT = -10
    do i = 1, ace(iso)%NXS(5) !> through the reaction types...
        temp = temp + sig_arr(i)
        if (rn < temp/sig_sum) then
            MT = ace(iso)%MT(i)
            iMT = i
            exit
        endif 
    enddo 
    
    rn = rang()
    !> determine collision law number
    eg => ace(iso) % pneg(iMT)
    law = -1
    F = 0d0
    law_search: do ilaw = 1, eg%nlaw
        !> Binary search to corresponding energy grid index
        pt1 = 1; pt2 =  eg % dist(ilaw) % NE
        do 
            if(pt2-pt1 == 1) exit 
            pt3 = (pt2+pt1)/2 
            if (p%E >= eg%dist(ilaw)%E(pt3) ) then 
                pt1 = pt3 
            else 
                pt2 = pt3
            endif
        enddo
        !> Interpolate F(E) (P(E) in ENDF Manual...)
        ipfac = max(0.d0, min(1.d0,(p%E-eg%dist(ilaw)%E(pt1))/(eg%dist(ilaw)%E(pt1+1)-eg%dist(ilaw)%E(pt1))))
        F     = F + eg%dist(ilaw)%F(pt1) + ipfac*(eg%dist(ilaw)%F(pt1+1)-eg%dist(ilaw)%F(pt1))
        
        if (rn < F) then 
            law = eg % dist(ilaw) % law
            exit law_search
        endif
    enddo law_search
    
    if ( eg%nlaw == 1 ) then 
        law = eg % dist(1) % law
        ilaw = 1
    endif 
    
    
    p%last_E = p%E
    !> Sample the scattering cosine
    if (law /= 44 .and. law /= 61) then 
        call acecos (p%E, iso, mu, iMT)
    endif 
    
    !> Sample the outgoing energy by the specific scattering Law
    !> call the corresponding law subroutines
    call law_selector (p%E, iso, mu, eg%dist(ilaw), iMT, law)
    
    if (abs(mu) > 1. ) mu = sign(1.0d0, mu)
    
    call directionEnergy (p, mu, iMT, iso) 
    
    xn = abs(ace(iso)%TY(iMT))
    if(xn > 4) xn = 1
    
end subroutine


end module
