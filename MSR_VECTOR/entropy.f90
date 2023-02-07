module ENTROPY
    use variables
    use GEOMETRY_HEADER
    use CONSTANTS
    use PARTICLE_HEADER, only: Particle
    implicit none
    integer:: ii
    real(8), allocatable:: entrp(:,:,:) ! entropies in mesh grid
    real(8):: entrp0    ! entropy at this cycle
    real(8):: entrp1    ! MPRUP entropy at previous generation
    real(8):: entrp2    ! MPRUP entropy at current generation
    real(8):: dentrp    ! entropy difference
    real(8), allocatable:: entrp3(:)  ! entropy for FMFD calculation

    ! =========================================================================
    ! Modified paricle ramp-up method (MPRUP)
    logical:: mprupon = .false.         ! MPRUP on ?
    logical:: genup   = .false.         ! generation size up ?
    logical:: up_sign = .false.         ! generation up in message
    integer:: rampup                    ! rampup generation size
    real(8), allocatable:: shannon(:)   ! cycle-wise shannon
    real(8):: dshannon                  ! averaged difference
    integer:: elength                   ! accumulation length
    integer:: ccrt, scrt                ! type of criteria, judged by
                                        ! 1 - relative error
                                        ! 2 - no. of cycles / histories
    real(8):: crt1, crt2, crt3          ! convergence / stopping / finishing
    real(8):: crt1c, crt2c, crt3c       ! constant for the criteria
    real(8):: en0(3)                    ! (x0,y0,z0)
    real(8):: en1(3)                    ! (x1,y1,z1)
    real(8):: en2(3)                    ! (x2,y2,z2)
    integer:: nen(3)                    ! (nx,ny,nz)
    real(8):: den(3)                    ! (dx,dy,dz)

    ! =========================================================================
    ! Functional expansion tallies (FET)
    integer:: nth = 6
    real(8), allocatable:: fetall(:)
    real(8), allocatable:: fetxyz(:,:,:,:)
    real(8), allocatable:: fetnusigf(:,:,:)

contains

! =============================================================================
! ENTRP_INIT initializes parameters and options for Shannon entropy calcluation
! =============================================================================
subroutine ENTRP_INIT
    implicit none

    ! entropy mesh grid
    en2(:) = en1(:) - en0(:)
    den(:) = en2(:) / nen(:)
    allocate(entrp(nen(1),nen(2),nen(3)))
    if ( mprupon ) up_sign = .true.
    
    allocate(fetall(nth))
    allocate(fetxyz(nth,nen(1),nen(2),nen(3)))
    allocate(fetnusigf(nen(1),nen(2),nen(3)))
    fetnusigf = 1D0

end subroutine


! =============================================================================
! SHENTROPY calculates Shannon entropy at every cycle
! =============================================================================
subroutine SHENTROPY(sb)
    use BANK_HEADER,        only: Bank
    implicit none
    type(Bank), intent(in):: sb(:)
    type(Particle):: p
    integer:: exyz(3)
    logical:: found
    integer:: ii, jj
    integer:: ssize

    ! initialization
    entrp = 0

    ! local entropy
    ssize = size(sb)
    do ii = 1, ssize
        call p%initialize()
        call p%set(sb(ii))
        exyz(:) = FIND_ENTRP_LAT(p%coord(1)%xyz(:))
        if ( exyz(1) < 1 .or. exyz(1) > nen(1) ) cycle
        if ( exyz(2) < 1 .or. exyz(2) > nen(2) ) cycle
        if ( exyz(3) < 1 .or. exyz(3) > nen(3) ) cycle
        entrp(exyz(1),exyz(2),exyz(3)) = &
        entrp(exyz(1),exyz(2),exyz(3)) + p%wgt
    end do

    ! global entropy
    !   normalization
    entrp = entrp / sum(entrp)
    !   entropy calculation
    where ( entrp(:,:,:) /= 0 ) entrp = -entrp*log(entrp)/log(2D0)
    entrp0 = sum(entrp)

    ! MPRUP method
    if ( mprupon ) then
        shannon = eoshift(shannon,-1,entrp0,1)
        dshannon = abs(sum(shannon(1:elength)-shannon(elength+1:2*elength))) &
                 / sum(shannon(1:elength))
    end if

end subroutine

! =============================================================================
! FIND_ENTRP_LAT
! =============================================================================
function FIND_ENTRP_LAT(mcxyz) result(exyz)
    implicit none
    real(8):: mcxyz(3)
    integer:: exyz(3)

    exyz(:) = floor((mcxyz(:)-en0(:))/den(:))+1

end function

! =============================================================================
! FET : functional 
! =============================================================================
subroutine FET_CALC(sb)
    use BANK_HEADER, only: Bank
    implicit none
    type(Bank), intent(in):: sb(:)
    type(Particle):: p
    integer:: exyz(3)
    integer:: ii, jj
    integer:: ssize

    fetxyz = 0
    ssize = size(sb)
    do ii = 1, ssize
        call p%initialize()
        call p%set(sb(ii))
        exyz(:) = FIND_ENTRP_LAT(p%coord(1)%xyz(:))
        if ( exyz(1) < 1 .or. exyz(1) > nen(1) ) cycle
        if ( exyz(2) < 1 .or. exyz(2) > nen(2) ) cycle
        if ( exyz(3) < 1 .or. exyz(3) > nen(3) ) cycle
        do jj = 1, nth
        fetxyz(jj,exyz(1),exyz(2),exyz(3)) = &
        fetxyz(jj,exyz(1),exyz(2),exyz(3)) + &
        LP(jj,NORMX(p%coord(1)%xyz(1))) * fetnusigf(exyz(1),exyz(2),exyz(3)) * p%wgt
        end do
    end do

    do jj = 1, nth
    fetall(jj) = sum(fetxyz(jj,:,:,:))*(2D0*jj+1D0)*5D-1
    end do
    fetall = fetall/dble(ngen)

end subroutine

function NORMX(xx)
    real(8):: NORMX
    real(8), intent(in):: xx
    real(8):: xx1 = 75D0

    NORMX = xx/xx1

end function


! =============================================================================
! Legendre polynomial
! =============================================================================
function LP(nn,xx)
    real(8):: LP
    integer, intent(in):: nn
    real(8), intent(in):: xx

    select case(nn)
    case(1); LP = xx
    case(2); LP = (3*xx*xx-1*5D-1)
    case(3); LP = xx*(5*xx*xx-3)*5D-1
    case(4); LP = (35*xx*xx*xx*xx-3D1*xx*xx+3)*1.25D-1
    case(5); LP = (63*xx*xx*xx*xx-7D1*xx*xx+15)*xx*1.25D-1
    case(6); LP = (231*xx*xx*xx*xx*xx*xx-315*xx*xx*xx*xx+105*xx*xx-5)*6.25D-2
    end select

end function

end module
