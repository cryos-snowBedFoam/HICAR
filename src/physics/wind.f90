!>------------------------------------------------------------
!! Module to manage the ICAR wind field, including calls to linear winds
!! importantly it also rotates the wind field into the ICAR grid and
!! balances the U, V, and W fields for "mass" conservation
!!
!!  @author
!!  Ethan Gutmann (gutmann@ucar.edu)
!!
!!------------------------------------------------------------
module wind
    use linear_theory_winds, only : linear_perturb
    !use mod_blocking,        only : update_froude_number, initialize_blocking
    use data_structures
    use exchangeable_interface,   only : exchangeable_t
    use domain_interface,  only : domain_t
    use options_interface, only : options_t
    use grid_interface,    only : grid_t
    use wind_surf, only         : apply_Sx
    use io_routines, only : io_read, io_write
    use mod_atm_utilities,   only : calc_froude, calc_Ri, calc_dry_stability
    
    implicit none
    private
    public::update_winds, init_winds
    real, parameter::deg2rad=0.017453293 !2*pi/360
    real, parameter :: rad2deg=57.2957779371
contains

    !>------------------------------------------------------------
    !! Forces u,v, and w fields to balance
    !!       du/dx + dv/dy = dw/dz
    !!
    !! Starts by setting w out of the ground=0 then works through layers
    !!
    !!------------------------------------------------------------
    subroutine balance_uvw(u,v,w, jaco_u,jaco_v,jaco_w,dz,dx,jaco,rho,smooth_height, options,vert_weight)
        implicit none
        real,           intent(inout) :: u(:,:,:), v(:,:,:), w(:,:,:)
        real,           intent(in)    :: jaco_u(:,:,:), jaco_v(:,:,:), jaco_w(:,:,:), dz(:,:,:), jaco(:,:,:), rho(:,:,:)
        real,           intent(in)    :: dx, smooth_height
        type(options_t),intent(in)    :: options
        real, optional, intent(in)    :: vert_weight(:,:,:)

        real, allocatable, dimension(:,:) :: rhou, rhov, rhow
        real, allocatable, dimension(:,:,:) :: divergence
        real, allocatable, dimension(:,:,:) :: vert_div_weight
        integer :: ims, ime, jms, jme, kms, kme, k

        !if (this_image()==1) write(*,*) "vert_div_weight: ",vert_div_weight

        ! associate(u => domain%u%data_3d,  &
        !           v => domain%v%data_3d,  &
        !           w => domain%w%data_3d  )

        ims = lbound(w,1)
        ime = ubound(w,1)
        kms = lbound(w,2)
        kme = ubound(w,2)
        jms = lbound(w,3)
        jme = ubound(w,3)

        w = 0
        allocate(vert_div_weight(ims:ime,kms:kme,jms:jme))
        
        !Base assumption is to use same vertical splitting as Sherman 1978 (perfectly neuteral atmosphere)
        vert_div_weight = 1.0000000000
        if (present(vert_weight)) vert_div_weight=vert_weight

        !------------------------------------------------------------
        ! These could be module level to prevent lots of allocation/deallocation/reallocations
        ! but these are relatively small, and should be allocated efficiently on the stack
        !------------------------------------------------------------
        ! if (options%advect_density) then
        !     allocate(rhou(nx-1,ny-2))
        !     allocate(rhov(nx-2,ny-1))
        !     allocate(rhow(nx-2,ny-2))
        ! endif

        allocate(divergence(ims:ime,kms:kme,jms:jme))

        call calc_divergence(divergence,u,v,w,jaco_u,jaco_v,jaco_w,dz,dx,jaco,rho,smooth_height,options,horz_only=.True.)
        !divergence = divergence * vert_div_weight

        ! If this becomes a bottle neck in the code it could be parallelized over y
        ! loop over domain levels
        do k = kms,kme
            !------------------------------------------------------------
            ! If we are incorporating density into the advection equation
            ! then it needs to be incorporated when balancing the wind field
            !
            ! Note that the "else" case below does the same thing without density
            ! and is much easier to understand
            !------------------------------------------------------------

            ! this is the else, advect density is not supported at the moment
            !------------------------------------------------------------
            ! If we are not incorporating density this is simpler
            !------------------------------------------------------------
            ! calculate horizontal divergence
            !   in the North-South direction
            !   in the East-West direction
            !   in net

            ! Then calculate w to balance
                ! if this is the first model level start from 0 at the ground
                ! note the are out for w is dx^2, but there is a dx in the divergence term that is dropped to balance
                if (options%parameters%advect_density) then
                    if (k==kms) then
                        w(:,k,:) = 0 - divergence(:,k,:) * dz(:,k,:) / (jaco_w(:,k,:) * (rho(:,k,:)+rho(:,k+1,:))/2 )
                    elseif (k==kme) then
                        w(:,k,:) = (w(:,k-1,:) * jaco_w(:,k-1,:) - divergence(:,k,:) * dz(:,k,:))/ (jaco_w(:,k,:) * rho(:,k,:))
                    else
                        w(:,k,:) = (w(:,k-1,:) * jaco_w(:,k-1,:) - divergence(:,k,:) * dz(:,k,:))/ (jaco_w(:,k,:) *  (rho(:,k,:)+rho(:,k+1,:))/2 )
                    endif
                else
                    if (k==kms) then
                        w(:,k,:) = vert_div_weight(:,k,:) * (0 - divergence(:,k,:) * dz(:,k,:)) / (jaco_w(:,k,:) )
                    else 
                        w(:,k,:) = vert_div_weight(:,k,:) * ((w(:,k-1,:) * jaco_w(:,k-1,:) - divergence(:,k,:) * dz(:,k,:)))/ (jaco_w(:,k,:) )
                    end if
                    !u(:,k,:) = (u(:,k,:) * jaco_u(:,k,:) - divergence(:,k,:) * 0.25 * dx) / jaco_u(:,k,:)
                    !v(:,k,:) = (v(:,k,:) * jaco_v(:,k,:) - divergence(:,k,:) * 0.25 * dx) / jaco_v(:,k,:)

                
                end if
            end do
            if (present(vert_weight) .and. this_image()==1) then
                !call io_write("ideal_vert_div.nc","vert_div",divergence)
                !call io_write("ideal_w_grid.nc","w_grid",w)
            endif
            !------------------------------------------------------------
            ! Now do the same for the convective wind field if needed
            !------------------------------------------------------------
            ! if (options%physics%convection > 0) then
            !     ! calculate horizontal divergence
            !     dv = domain%v_cu(2:nx-1,i,3:ny) - domain%v_cu(2:nx-1,i,2:ny-1)
            !     du = domain%u_cu(3:nx,i,2:ny-1) - domain%u_cu(2:nx-1,i,2:ny-1)
            !     divergence = du + dv
            !     ! Then calculate w to balance
            !     if (i==1) then
            !         ! if this is the first model level start from 0 at the ground
            !         domain%w_cu(2:nx-1,i,2:ny-1) = 0 - divergence
            !     else
            !         ! else calculate w as a change from w at the level below
            !         domain%w_cu(2:nx-1,i,2:ny-1) = domain%w_cu(2:nx-1,i-1,2:ny-1) - divergence
            !     endif
            ! endif

        ! end associate

    end subroutine balance_uvw


    subroutine calc_divergence(div, u, v, w, jaco_u, jaco_v, jaco_w, dz, dx, jaco, rho, smooth_height,options,horz_only)
        implicit none
        real,           intent(inout) :: div(:,:,:)
        real,           intent(in)    :: u(:,:,:), v(:,:,:), w(:,:,:), dz(:,:,:), jaco_u(:,:,:), jaco_v(:,:,:), jaco_w(:,:,:), jaco(:,:,:), rho(:,:,:)
        real,           intent(in)    :: dx, smooth_height
        logical, optional, intent(in)  :: horz_only
        type(options_t),intent(in)    :: options

        real, allocatable, dimension(:,:,:) :: diff_U, diff_V, u_met, v_met, w_met
        integer :: ims, ime, jms, jme, kms, kme, k
        logical :: horz

        horz = .False.
        if (present(horz_only)) horz=horz_only

        ims = lbound(w,1)
        ime = ubound(w,1)
        kms = lbound(w,2)
        kme = ubound(w,2)
        jms = lbound(w,3)
        jme = ubound(w,3)

        allocate(diff_U(ims:ime,kms:kme,jms:jme))
        allocate(diff_V(ims:ime,kms:kme,jms:jme))
        allocate(u_met(ims:ime+1,kms:kme,jms:jme))
        allocate(v_met(ims:ime,kms:kme,jms:jme+1))
        allocate(w_met(ims:ime,kms:kme,jms:jme))

        !Multiplication of U/V by metric terms, converting jacobian to staggered-grid where possible, otherwise making assumption of 
        !Constant jacobian at edges
        
        if (options%parameters%advect_density) then
            u_met = u * jaco_u * (rho(ims:ime-1,:,jms:jme) + rho(ims+1:ime,:,jms:jme))/2
            v_met = v * jaco_v * (rho(ims:ime,:,jms:jme-1) + rho(ims:ime,:,jms+1:jme))/2
        else
            u_met = u * jaco_u
            v_met = v * jaco_v
        end if
        
        diff_U = u_met(ims+1:ime+1, :, jms:jme) - u_met(ims:ime, :, jms:jme)
        diff_V = v_met(ims:ime, :, jms+1:jme+1) - v_met(ims:ime, :, jms:jme)

        div(ims:ime,kms:kme,jms:jme) = (diff_U+diff_V) /(dx)

        if (.NOT.(horz)) then
            if (options%parameters%advect_density) then
                w_met(:,kme,:) = w(:,kme,:) * jaco_w(:,kme,:) * rho(:,kme,:)
                w_met(:,kms:kme-1,:) = w(:,kms:kme-1,:) * jaco_w(:,kms:kme-1,:) * (rho(:,kms+1:kme,:) + rho(:,kms:kme-1,:))/2 
            else
                w_met = w*jaco_w
            end if
            
            do k = kms,kme
                if (k == kms) then
                    div(ims:ime, k, jms:jme) = div(ims:ime, k, jms:jme) + w_met(ims:ime, k, jms:jme)/(dz(ims:ime, k, jms:jme))
                else
                    div(ims:ime, k, jms:jme) = div(ims:ime, k, jms:jme) + &
                                   (w_met(ims:ime,k,jms:jme)-w_met(ims:ime,k-1,jms:jme))/(dz(ims:ime,k,jms:jme))
                endif
            enddo
            !if (options%parameters%advect_density) then
            !    div = div/(jaco*rho)
            !else
            !    div = div/jaco
            !end if
        endif

    end subroutine calc_divergence
    


    !>------------------------------------------------------------
    !! Correct for a grid that is locally rotated with respect to EW,NS
    !!
    !! Assumes forcing winds are EW, NS relative, not grid relative.
    !!
    !!------------------------------------------------------------
    subroutine make_winds_grid_relative(u, v, w, grid, sintheta, costheta)
        real, intent(inout) :: u(:,:,:), v(:,:,:), w(:,:,:)
        type(grid_t),   intent(in)    :: grid
        double precision, intent(in)    :: sintheta(:,:), costheta(:,:)

        real, dimension(:,:), allocatable :: cos_shifted_u,sin_shifted_u,cos_shifted_v,sin_shifted_v,u_shifted_v,v_shifted_u
        real, dimension(:), allocatable :: u_local,v_local
        integer :: k, j, ims, ime, jms, jme, kms, kme, ids, ide, jds, jde

        ims = lbound(w,1)
        ime = ubound(w,1)
        kms = lbound(w,2)
        kme = ubound(w,2)
        jms = lbound(w,3)
        jme = ubound(w,3)

        ids = lbound(costheta,1)
        ide = ubound(costheta,1)
        jds = lbound(costheta,2)
        jde = ubound(costheta,2)

        allocate(u_local(ims:ime))
        allocate(v_local(ims:ime))

        !assumes u and v come in on a staggered Arakawa C-grid with one additional grid point in x/y for u/v respectively
        ! destagger to a centered grid (the mass grid)
        u(:ime,:,:) = (u(:ime,:,:) + u(ims+1:,:,:))/2
        v(:,:,:jme) = (v(:,:,:jme) + v(:,:,jms+1:))/2

        do j = jms, jme
            do k = kms, kme
                ! rotate wind field to the real grid
                u_local = u(ims:ime,k,j) * costheta(grid%its-1:grid%ite+1,j+grid%jts-2) &
                        + v(ims:ime,k,j) * sintheta(grid%its-1:grid%ite+1,j+grid%jts-2)
                v_local = v(ims:ime,k,j) * costheta(grid%its-1:grid%ite+1,j+grid%jts-2) &
                        + u(ims:ime,k,j) * sintheta(grid%its-1:grid%ite+1,j+grid%jts-2)
                u(:ime,k,j) = u_local
                v(:ime,k,j) = v_local
           enddo
        enddo
        deallocate(u_local,v_local)

        ! put the fields back onto a staggered grid, having effectively lost two grid cells in the staggered directions
        ! estimate the "lost" grid cells by extrapolating beyond the remaining
        u(ims+1:ime,:,:) =  (u(ims:ime-1,:,:) + u(ims+1:ime,:,:))/2
        u(ims,:,:)       = 2*u(ims,:,:)       - u(ims+1,:,:)
        u(ime+1,:,:)     = 2*u(ime,:,:)       - u(ime-1,:,:)

        v(:,:,jms+1:jme) =  (v(:,:,jms:jme-1) + v(:,:,jms+1:jme))/2
        v(:,:,jms)       = 2*v(:,:,jms)       - v(:,:,jms+1)
        v(:,:,jme+1)     = 2*v(:,:,jme)       - v(:,:,jme-1)

    end subroutine


    !>------------------------------------------------------------
    !! Apply wind field physics and adjustments
    !!
    !! This will call the linear wind module if necessary, otherwise it just updates for
    !! This should ONLY be called once for each forcing step, otherwise effects will be additive.
    !!
    !!------------------------------------------------------------
    subroutine update_winds(domain, options)
        implicit none
        type(domain_t), intent(inout) :: domain
        type(options_t),intent(in)    :: options

        real, allocatable, dimension(:,:,:) :: temparray
        integer :: nx, ny, nz, i, j
        
        if (.not.allocated(domain%advection_dz)) then

            call init_winds(domain, options)
            !call initialize_blocking(domain, options)
            call update_stability(domain)

            ! rotate winds from cardinal directions to grid orientation (e.g. u is grid relative not truly E-W)
            !call make_winds_grid_relative(domain%u%data_3d, domain%v%data_3d, domain%w%data_3d, domain%grid, domain%sintheta, domain%costheta)

            ! flow blocking parameterization
            ! if (options%block_options%block_flow) then
            !     call add_blocked_flow(domain, options)
            ! endif

            if (options%wind%Sx) then
                !call iterative_winds(domain, options)
                call apply_Sx(domain%Sx,domain%TPI,domain%u%data_3d, domain%v%data_3d, domain%w%data_3d,domain%Ri)
            endif 

            ! linear winds
            if (options%physics%windtype==kWIND_LINEAR) then
                call linear_perturb(domain,options,options%lt_options%vert_smooth,.False.,options%parameters%advect_density)
            ! simple acceleration over topography
            elseif (options%physics%windtype==kCONSERVE_MASS) then
                if (options%parameters%use_terrain_difference) then  ! 
                !! use the ratio between hi-res and lo-res grid deformation (i.e. due to 'additional' terrain) for speedup
                    call mass_conservative_acceleration(domain%u%data_3d, domain%v%data_3d, domain%zfr_u, domain%zfr_v)
                else    
                    call mass_conservative_acceleration(domain%u%data_3d, domain%v%data_3d, domain%zr_u, domain%zr_v)
                endif    
            elseif (options%physics%windtype==kITERATIVE_WINDS) then
                call iterative_winds(domain, options)

            endif
            ! else assumes even flow over the mountains

            ! use horizontal divergence (convergence) to calculate vertical convergence (divergence)
            call balance_uvw(domain%u%data_3d, domain%v%data_3d, domain%w%data_3d, domain%jacobian_u, domain%jacobian_v, domain%jacobian_w, domain%advection_dz, domain%dx, domain%jacobian, domain%density%data_3d, domain%smooth_height, options)
            
            call calc_w_real(domain% u %data_3d,      &
                             domain% v %data_3d,      &
                             domain% w %data_3d,      &
                             domain% w_real %data_3d,      &
                             domain%dzdx, domain%dzdy,    &
                             domain%jacobian)
        else

            call update_stability(domain)

            ! rotate winds from cardinal directions to grid orientation (e.g. u is grid relative not truly E-W)
            !call make_winds_grid_relative(domain%u%meta_data%dqdt_3d, domain%v%meta_data%dqdt_3d, domain%w%meta_data%dqdt_3d, domain%grid, domain%sintheta, domain%costheta)
            
            if (options%wind%Sx) then
                !call iterative_winds(domain, options, update_in=.True.)
                call apply_Sx(domain%Sx,domain%TPI,domain%u%meta_data%dqdt_3d,domain%v%meta_data%dqdt_3d, domain%w%meta_data%dqdt_3d,domain%Ri)
            endif 

            ! linear winds
            if (options%physics%windtype==kWIND_LINEAR) then
                call linear_perturb(domain,options,options%lt_options%vert_smooth,.False.,options%parameters%advect_density, update=.True.)
            ! simple acceleration over topography
            elseif (options%physics%windtype==kCONSERVE_MASS) then
                if (options%parameters%use_terrain_difference) then  ! 
                !! use the ratio between hi-res and lo-res grid deformation (i.e. due to 'addtional' terrain) for speedup
                    call mass_conservative_acceleration(domain%u%meta_data%dqdt_3d, domain%v%meta_data%dqdt_3d, domain%zfr_u, domain%zfr_v)
                else    
                    call mass_conservative_acceleration(domain%u%meta_data%dqdt_3d, domain%v%meta_data%dqdt_3d, domain%zr_u, domain%zr_v)
                endif   
            elseif (options%physics%windtype==kITERATIVE_WINDS) then
                call iterative_winds(domain, options, update_in=.True.)

            endif
            ! use horizontal divergence (convergence) to calculate vertical convergence (divergence)

            call balance_uvw(domain% u %meta_data%dqdt_3d,      &
                             domain% v %meta_data%dqdt_3d,      &
                             domain% w %meta_data%dqdt_3d,      &
                             domain%jacobian_u, domain%jacobian_v, domain%jacobian_w,         &
                             domain%advection_dz, domain%dx,    &
                             domain%jacobian, domain%density%data_3d, domain%smooth_height, options)
                             
            call calc_w_real(domain% u %meta_data%dqdt_3d,      &
                             domain% v %meta_data%dqdt_3d,      &
                             domain% w %meta_data%dqdt_3d,      &
                             domain% w_real %data_3d,      &
                             domain%dzdx, domain%dzdy,    &
                             domain%jacobian)

        endif

    end subroutine update_winds
    
    subroutine calc_w_real(u,v,w_grid,w_real,dzdx,dzdy,jacobian)
        implicit none
        real, intent(in), dimension(:,:,:) :: u,v,w_grid,dzdx,dzdy,jacobian
        real, intent(inout)                :: w_real(:,:,:)
        
        real, allocatable :: lastw(:,:)
        real, allocatable :: currw(:,:)
        real, allocatable :: uw(:,:)
        real, allocatable :: vw(:,:)
        integer :: z, ims, ime, jms, jme, kms, kme
        
        ims = lbound(w_grid,1)
        ime = ubound(w_grid,1)
        kms = lbound(w_grid,2)
        kme = ubound(w_grid,2)
        jms = lbound(w_grid,3)
        jme = ubound(w_grid,3)
        
        if (.not.allocated(lastw)) then
            allocate( lastw( ims+1:ime-1, jms+1:jme-1))
            allocate( currw( ims+1:ime-1, jms+1:jme-1))
            allocate(    uw( ims+1:ime,   jms+1:jme-1))
            allocate(    vw( ims+1:ime-1, jms+1:jme  ))
        endif
        
        !calculate the real vertical motions (including U*dzdx + V*dzdy)
        lastw = 0
        do z = kms, kme
            
            ! ! if(options%parameters%use_terrain_difference) then
            !                 ! compute the U * dz/dx component of vertical motion
            !     uw    = u(ims+1:ime,   z, jms+1:jme-1) * domain%delta_dzdx(:,z,jms+1:jme-1)
            !     ! compute the V * dz/dy component of vertical motion
            !     vw    = v(ims+1:ime-1, z, jms+1:jme  ) * domain%delta_dzdy(ims+1:ime-1,z,:)
            ! else    
                ! compute the U * dz/dx component of vertical motion
                uw    = u(ims+1:ime,   z, jms+1:jme-1) * SIN(ATAN(dzdx(ims+1:ime,z,jms+1:jme-1)))
                ! compute the V * dz/dy component of vertical motion
                vw    = v(ims+1:ime-1, z, jms+1:jme  ) * SIN(ATAN(dzdy(ims+1:ime-1,z,jms+1:jme)))
            ! endif    
            ! ! convert the W grid relative motion to m/s
            ! currw = w(ims+1:ime-1, z, jms+1:jme-1) * dz_interface(ims+1:ime-1, z, jms+1:jme-1) / domain%dx

            ! the W grid relative motion
            currw = w_grid(ims+1:ime-1, z, jms+1:jme-1)

            ! if (options%physics%convection>0) then
            !     currw = currw + domain%w_cu(2:nx-1,z,2:ny-1) * domain%dz_inter(2:nx-1,z,2:ny-1) / domain%dx
            ! endif

            ! compute the real vertical velocity of air by combining the different components onto the mass grid
            ! includes vertical interpolation between w_z-1/2 and w_z+1/2
            w_real(ims+1:ime-1, z, jms+1:jme-1) = (uw(ims+1:ime-1,:) + uw(ims+2:ime,:))*0.5 &
                                                 +(vw(:,jms+1:jme-1) + vw(:,jms+2:jme))*0.5 &
                                                 +jacobian(ims+1:ime-1,z,jms+1:jme-1)*(lastw + currw) * 0.5
            lastw = currw ! could avoid this memcopy cost using pointers or a single manual loop unroll
        end do
    end subroutine calc_w_real
    
    subroutine iterative_winds(domain, options, update_in)
        implicit none
        type(domain_t), intent(inout) :: domain
        type(options_t),intent(in)    :: options
        logical, optional, intent(in) :: update_in
        
        ! interal parameters
        real, allocatable, dimension(:,:,:) :: div, dial_weights, temp_dw, ADJ1, ADJ2U, ADJ2V, U_D_cor, V_D_cor, current_u, current_v, current_w
        real, allocatable, dimension(:,:,:) :: u_m, v_m, w_m, dzdx_m, dzdy_m, SLOPE, dw_factor, old_dw, dw_tend, temp_w
        real    :: global_max
        integer :: it, k, j, i, ims, ime, jms, jme, kms, kme, wind_k, n, xmin, xmax, ymin, ymax, kmin, kmax, i_start1, i_end1, j_start1, j_end1, i_start2, i_end2, j_start2, j_end2
        logical :: update
        character(len=4) :: img
        
        update=.False.
        if (present(update_in)) update=update_in

        ims = lbound(domain%w%data_3d,1)
        ime = ubound(domain%w%data_3d,1)
        kms = lbound(domain%w%data_3d,2)
        kme = ubound(domain%w%data_3d,2)
        jms = lbound(domain%w%data_3d,3)
        jme = ubound(domain%w%data_3d,3)

        !If we are doing an update, we need to swap meta data into data_3d fields so it can be exchanged while balancing
        !First, we save a copy of the current data_3d so that we can substitute it back in later
        if (update) then
             current_u = domain%u%data_3d
             current_v = domain%v%data_3d
             current_w = domain%w%data_3d
             
             domain%u%data_3d = domain%u%meta_data%dqdt_3d
             domain%v%data_3d = domain%v%meta_data%dqdt_3d
             domain%w%data_3d = domain%w%meta_data%dqdt_3d
        endif
        
        allocate(div(ims:ime,kms:kme,jms:jme))
        allocate(ADJ1(ims:ime,kms:kme,jms:jme))
        allocate(ADJ2U(ims:ime,kms:kme,jms:jme))
        allocate(ADJ2V(ims:ime,kms:kme,jms:jme))
        allocate(U_D_cor(ims:ime,kms:kme,jms:jme))
        allocate(V_D_cor(ims:ime,kms:kme,jms:jme))
        allocate(dzdx_m(ims:ime,kms:kme,jms:jme))
        allocate(dzdy_m(ims:ime,kms:kme,jms:jme))
        allocate(u_m(ims:ime,kms:kme,jms:jme))
        allocate(v_m(ims:ime,kms:kme,jms:jme))
        allocate(w_m(ims:ime,kms:kme,jms:jme))
        allocate(temp_dw(ims:ime,kms:kme,jms:jme))
        allocate(temp_w(ims:ime,kms:kme,jms:jme))
        allocate(dw_factor(ims:ime,kms:kme,jms:jme))
        allocate(old_dw(ims:ime,kms:kme,jms:jme))
        allocate(dw_tend(ims:ime,kms:kme,jms:jme))
        allocate(SLOPE(ims:ime,kms:kme,jms:jme))
        it = 0
        
        ADJ1 = 0
        ADJ2U = 0
        ADJ2V = 0
  
        global_max = 1
        
        i_start1 = ims+2
        i_start2 = ims+2
        i_end1 = ime
        i_end2 = ime
        j_start1 = jms+2
        j_start2 = jms+2
        j_end1 = jme
        j_end2 = jme
        

        if (options%wind%Dial) then
            allocate(dial_weights(ims:ime,kms:kme,jms:jme))
            
            !Dial of 100% (all vertical) at Fr 0.75, 0% (all horizontal) at Fr <= 0.25
            dial_weights = domain%froude/50.0 !max((domain%froude-0.5),0.0) !0.25 !0.2
            
            !Sanity-bounding to min of 0.0, max of 1.0
            dial_weights = max(min(dial_weights,1.0),0.0)
            
            write (img,'(I3.3)') this_image()
            call io_write("dial_weights"//trim(img)//".nc","data",dial_weights)
            if (this_image()==1) call io_write("froude.nc","froude",domain%froude)
            if (this_image()==1) call io_write("Dick.nc","Ri",domain%Ri)
        endif
                
                
        if (domain%its==(domain%ids+1)) then
            i_start1 = ims+1
            i_start2 = ims
        endif
        if (domain%ite==(domain%ide-1)) then
            i_end1 = ime+1
            i_end2 = ime
        endif
        if (domain%jts==(domain%jds+1)) then
            j_start1 = jms+1
            j_start2 = jms
        endif
        if (domain%jte==(domain%jde-1)) then
            j_end1 = jme+1
            j_end2 = jme
        endif

        !Do an initial exchange to make sure the U and V grids are similar for calculating w
        call domain%u%exchange_u()
        call domain%v%exchange_v()
        
        
        !Do some setup for solver
        dzdx_m = ( domain%dzdx(ims+1:ime+1,:,jms:jme) + domain%dzdx(ims:ime,:,jms:jme) )/2
        dzdy_m = ( domain%dzdy(ims:ime,:,jms+1:jme+1) + domain%dzdy(ims:ime,:,jms:jme) )/2
        
        SLOPE = SIN(ATAN(sqrt(dzdx_m**2 + dzdy_m**2)))
        
        !Balance uvw to get initial state of w_grid
        call balance_uvw(domain%u%data_3d, domain%v%data_3d, temp_w, domain%jacobian_u, domain%jacobian_v, domain%jacobian_w, domain%advection_dz, domain%dx, domain%jacobian, domain%density%data_3d, domain%smooth_height, options)

        domain%w%data_3d = temp_w*(dial_weights)

        !Compute horizontal divergence of wind field
        call calc_divergence(div,domain%u%data_3d,domain%v%data_3d,domain%w%data_3d,domain%jacobian_u,domain%jacobian_v,domain%jacobian_w, &
            domain%advection_dz,domain%dx,domain%jacobian,domain%density%data_3d,domain%smooth_height,options,horz_only=.False.)
        
        ADJ1 = -(div) &
               /((4*domain%jacobian)/domain%dx)
                      
        do while ( (global_max > 0.002) .and. (it < 3000) )
           
            !write (img,'(I4.4)') it
            !if ((it < 4000)) call io_write("./../debug_out/w_grid"//trim(img)//".nc","w_grid",domain%w%data_3d)
            !if ((it < 4000)) call io_write("./../debug_out/v_grid"//trim(img)//".nc","v_grid",domain%v%data_3d)
            !if ((it < 4000)) call io_write("./../debug_out/u_grid"//trim(img)//".nc","u_grid",domain%u%data_3d)
            !if ((it < 4000)) call io_write("./../debug_out/w_real"//trim(img)//".nc","w_real",domain%w_real%data_3d)
           
            !Compute mass-grid components of w_real
            u_m = ( SIN(ATAN(domain%dzdx(ims+1:ime+1,:,jms:jme)))*domain%u%data_3d(ims+1:ime+1,:,jms:jme) + &
                    SIN(ATAN(domain%dzdx(ims:ime,:,jms:jme)))*domain%u%data_3d(ims:ime,:,jms:jme) ) / 2
            v_m = ( SIN(ATAN(domain%dzdy(ims:ime,:,jms+1:jme+1)))*domain%v%data_3d(ims:ime,:,jms+1:jme+1) + &
                    SIN(ATAN(domain%dzdy(ims:ime,:,jms:jme)))*domain%v%data_3d(ims:ime,:,jms:jme) ) / 2
                    
            w_m(:,kms,:) = domain%w%data_3d(:,kms,:)*domain%jacobian_w(:,kms,:)/2
            w_m(:,kms+1:kme,:) = (domain%w%data_3d(:,kms+1:kme,:)*domain%jacobian_w(:,kms+1:kme,:) + &
                                  domain%w%data_3d(:,kms:kme-1,:)*domain%jacobian_w(:,kms:kme-1,:))/2
            
            !Compute adjustment for the given loop
            !temp_w(:,kms,:) = 0
            !temp_w(:,kms+1:kme,:) = domain%w%data_3d(:,kms:kme-1,:)*domain%jacobian_w(:,kms:kme-1,:)
            !temp_dw = (u_m+v_m+w_m) - (dial_weights)*(u_m+v_m+temp_w)
            
            temp_dw = (u_m+v_m+w_m) - (dial_weights)*(u_m+v_m)

            dw_tend = temp_dw !/domain%advection_dz

            call calc_divergence(div,domain%u%data_3d,domain%v%data_3d,domain%w%data_3d,domain%jacobian_u,domain%jacobian_v,domain%jacobian_w, &
            domain%advection_dz,domain%dx,domain%jacobian,domain%density%data_3d,domain%smooth_height,options,horz_only=.False.)

            ADJ1 = -div*domain%dx/(4*domain%jacobian) + (1-SLOPE)*(dw_tend)/(domain%advection_dz)
                   
            dw_tend = (1-SLOPE)*0.01*(1-dial_weights)*(u_m+v_m+w_m)/(domain%advection_dz)            
            
            where( .not.( (u_m**2+v_m**2)==0 )) ADJ2U = sign(dw_tend, (domain%u%data_3d(ims:ime,:,:)+domain%u%data_3d(ims+1:ime+1,:,:)) )*abs(u_m)/sqrt(u_m**2+v_m**2)
            where( .not.( (u_m**2+v_m**2)==0 )) ADJ2V = sign(dw_tend, (domain%v%data_3d(:,:,jms:jme)+domain%v%data_3d(:,:,jms+1:jme+1)) )*abs(v_m)/sqrt(u_m**2+v_m**2)
            
            where (abs(ADJ2U) > abs(ADJ2V)) ADJ2V = sign(ADJ2U,u_m*dzdy_m)
            where (abs(ADJ2V) > abs(ADJ2U)) ADJ2U = sign(ADJ2V,dzdx_m*v_m)
            
            if (this_image()==1) write(*,*) "ADJ: ",global_max
            if (this_image()==1) write(*,*) "vert: ",maxval(abs(u_m+v_m+w_m))
            
            !if (this_image()==1) write(*,*) "ADJU: ",maxval(ADJ2U)
            !if (this_image()==1) write(*,*) "ADJV: ",maxval(ADJ2V)
            
            if (this_image()==1) write(*,*) "div: ",maxval(abs(div))
            
            !Apply adjustment

            domain%u%data_3d(i_start1:i_end1,:,j_start1-1:j_end1-1) = &
                                                        domain%u%data_3d(i_start1:i_end1,:,j_start1-1:j_end1-1) + &
                                                        ADJ1(i_start1-1:i_end1-1,:,j_start1-1:j_end1-1) - &
                                                        ADJ2U(i_start1-1:i_end1-1,:,j_start1-1:j_end1-1)
                                                        
            domain%u%data_3d(i_start2:i_end2,:,j_start1-1:j_end1-1) = &
                                                        domain%u%data_3d(i_start2:i_end2,:,j_start1-1:j_end1-1) - &
                                                        ADJ1(i_start2:i_end2,:,j_start1-1:j_end1-1) - &
                                                        ADJ2U(i_start2:i_end2,:,j_start1-1:j_end1-1)
                                                        
            domain%v%data_3d(i_start1-1:i_end1-1,:,j_start1:j_end1) = &
                                                        domain%v%data_3d(i_start1-1:i_end1-1,:,j_start1:j_end1) + &
                                                        ADJ1(i_start1-1:i_end1-1,:,j_start1-1:j_end1-1) - &
                                                        ADJ2V(i_start1-1:i_end1-1,:,j_start1-1:j_end1-1)
                                                        
            domain%v%data_3d(i_start1-1:i_end1-1,:,j_start2:j_end2) = &
                                                        domain%v%data_3d(i_start1-1:i_end1-1,:,j_start2:j_end2) - &
                                                        ADJ1(i_start1-1:i_end1-1,:,j_start2:j_end2) - &
                                                        ADJ2V(i_start1-1:i_end1-1,:,j_start2:j_end2)
                                                        
            !if (domain%jts==(domain%jds+1)) domain%v%data_3d(ims:ime-1,:,jms) = domain%v%data_3d(ims:ime-1,:,jms+1)
                        
            !if (domain%its==(domain%ids+1)) domain%u%data_3d(ims,:,jms+1:jme) = domain%u%data_3d(ims+1,:,jms+1:jme)

            !if (domain%jte==(domain%jde-1)) domain%v%data_3d(ims+1:ime,:,jme+1) = domain%v%data_3d(ims+1:ime,:,jme)

            !if (domain%ite==(domain%ide-1)) domain%u%data_3d(ime+1,:,jms:jme-1) = domain%u%data_3d(ime,:,jms:jme-1)

            call domain%u%exchange_u()
            call domain%v%exchange_v()

            !Update w_grid
            call balance_uvw(domain%u%data_3d, domain%v%data_3d, temp_w, domain%jacobian_u, domain%jacobian_v, domain%jacobian_w, domain%advection_dz, domain%dx, domain%jacobian, domain%density%data_3d, domain%smooth_height, options)
            
            domain%w%data_3d = temp_w*0.01 + domain%w%data_3d*0.99
            !domain%w%data_3d = temp_w*(dial_weights)

            !Update loop controls
            global_max = maxval(abs(ADJ1))
            call CO_MAX(global_max)
            it = it+1
            ADJ1 = 0
        enddo

        sync all 

        !If an update loop, swap meta_data and data_3d fields back
        if (update) then
            domain%u%meta_data%dqdt_3d = domain%u%data_3d
            domain%v%meta_data%dqdt_3d = domain%v%data_3d
            domain%w%meta_data%dqdt_3d = domain%w%data_3d
            
            domain%u%data_3d = current_u
            domain%v%data_3d = current_v
            domain%w%data_3d = current_w
        endif
        
    end subroutine iterative_winds

    subroutine mass_conservative_acceleration(u, v, u_accel, v_accel)
        implicit none
        real, intent(inout) :: u(:,:,:)
        real, intent(inout) :: v(:,:,:)
        real, intent(in)    :: u_accel(:,:,:)
        real, intent(in)    :: v_accel(:,:,:)

        u = u / u_accel
        v = v / v_accel

    end subroutine mass_conservative_acceleration

    !>------------------------------------------------------------
    !! Setup initial fields (i.e. grid relative rotation fields)
    !!
    !!------------------------------------------------------------
    subroutine init_winds(domain,options)
        type(domain_t),  intent(inout) :: domain
        type(options_t), intent(in)    :: options

        integer :: i, j, ims, ime, jms, jme, kms, kme
        integer :: starti, endi
        double precision :: dist, dlat, dlon

        real, allocatable :: temporary_2d(:,:)

        call allocate_winds(domain)

        if (options%parameters%fixed_dz_advection) then
            do i=domain%grid%kms, domain%grid%kme
                domain%advection_dz(:,i,:) = options%parameters%dz_levels(i)
            enddo
        else
            domain%advection_dz = domain%dz_interface%data_3d
        endif


    end subroutine init_winds

    !>------------------------------------------------------------
    !! Allocate memory used in various wind related routines
    !!
    !!------------------------------------------------------------
    subroutine allocate_winds(domain)
        type(domain_t), intent(inout) :: domain
        integer :: ims, ime, jms, jme, kms, kme

        ims = lbound(domain%latitude%data_2d, 1)
        ime = ubound(domain%latitude%data_2d, 1)
        jms = lbound(domain%latitude%data_2d, 2)
        jme = ubound(domain%latitude%data_2d, 2)
        kms = lbound(domain%w%data_3d, 2)
        kme = ubound(domain%w%data_3d, 2)

        if (.not.allocated(domain%advection_dz)) then
            allocate(domain%advection_dz(ims:ime,kms:kme,jms:jme))
        endif

        ! note w is special cased because it does not have a forcing variable, so it is not necessarily allocated automatically
        if (.not.associated(domain%w%meta_data%dqdt_3d)) then
            allocate(domain%w%meta_data%dqdt_3d(ims:ime,kms:kme,jms:jme))
            domain%w%meta_data%dqdt_3d = 0
        endif

        ! if (.not.allocated(domain%dzdx)) then
        !     allocate(domain%dzdx(nx-1,ny))
        ! endif
        ! if (.not.allocated(domain%dzdy)) then
        !     allocate(domain%dzdy(nx,ny-1))
        ! endif

    end subroutine allocate_winds
    
    subroutine update_stability(domain)
        implicit none
        type(domain_t), intent(inout) :: domain

        real, allocatable, dimension(:,:,:) :: wind_speed, temp_froude, u_m, v_m, winddir
        integer,  allocatable, dimension(:,:,:) :: dir_indices
        
        integer :: k, j, i, n, ims, ime, jms, jme, kms, kme
        real :: z_top, z_bot, th_top, th_bot, stability
        integer :: ymin, ymax, xmin, xmax, n_smoothing_passes, nsmooth_gridcells
        
        n_smoothing_passes = 5
        nsmooth_gridcells = 20 !int(500 / domain%dx)
        
        ims = lbound(domain%w%data_3d,1)
        ime = ubound(domain%w%data_3d,1)
        kms = lbound(domain%w%data_3d,2)
        kme = ubound(domain%w%data_3d,2)
        jms = lbound(domain%w%data_3d,3)
        jme = ubound(domain%w%data_3d,3)

        !If it is our first time calculating Fr, allocate and populate froude_terrain array
        if (.not.allocated(domain%froude)) then
            allocate(domain%froude(ims:ime,kms:kme,jms:jme))            
            allocate(domain%froude_terrain(1:72,ims:ime,kms:kme,jms:jme))

            call compute_terrain_blocking_heights(domain)
        endif
       
        if (.not.allocated(domain%Ri)) allocate(domain%Ri(ims:ime,kms:kme,jms:jme))
       
        allocate(u_m(ims:ime,kms:kme,jms:jme))
        allocate(v_m(ims:ime,kms:kme,jms:jme))
        allocate(winddir(ims:ime,kms:kme,jms:jme))
        allocate(dir_indices(ims:ime,kms:kme,jms:jme))
        allocate(wind_speed(ims:ime,kms:kme,jms:jme))
        allocate(temp_froude(ims:ime,kms:kme,jms:jme))       
        
        u_m = (domain%u%data_3d(ims:ime,:,:) + domain%u%data_3d(ims+1:ime+1,:,:))/2
        v_m = (domain%v%data_3d(:,:,jms:jme) + domain%v%data_3d(:,:,jms+1:jme+1))/2
        
        !Compute wind direction for each cell on mass grid
        winddir = atan2(-u_m,-v_m)*rad2deg
        where(winddir < 0.0) winddir = winddir+360
        where(winddir == 360.0) winddir = 0.0
        dir_indices = int(winddir/5)+1

        !Build grid of Sx values based on wind direction at that cell
        do i = ims, ime
            do j = jms, jme
                do k=kms, kme
                    temp_froude(i,k,j) = domain%froude_terrain(dir_indices(i,k,j),i,k,j)
                enddo
            end do
        end do
        call io_write("temp_terrain_blocking.nc","data",temp_froude)
        wind_speed = sqrt( (u_m)**2 + (v_m)**2 )
        
        !Since we will loop up to nz-1, we set all Fr to 0.1, which will leave the upper layer as very stable
        domain%froude = 0.1
        
        !Since we will loop up to nz-1, we set all Ri here to 10
        domain%Ri = 10.0
        
        do i = ims,ime
            do j = jms,jme
                do k = kms,kme-1
                    th_bot = domain%potential_temperature%data_3d(i,k,j)
                    th_top = domain%potential_temperature%data_3d(i,k+1,j)
                    z_bot  = domain%z%data_3d(i,k,j)
                    z_top  = domain%z%data_3d(i,k+1,j)
                    stability = calc_dry_stability(th_top, th_bot, z_top, z_bot) 
                    
                    domain%Ri(i,k,j) =  calc_Ri(stability, wind_speed(i,k,j), temp_froude(i,k,j))

                    stability = sqrt(max(stability, 0.))
                    domain%froude(i,k,j) = calc_froude(stability, temp_froude(i,k,j), wind_speed(i,k,j))
                enddo
            enddo
        enddo

        temp_froude = domain%froude

        !do n = 1,n_smoothing_passes
        !    do j=jms,jme
        !        ymin = max(j-nsmooth_gridcells, jms)
        !        ymax = min(j+nsmooth_gridcells, jme)
        !        do i=ims,ime
        !            xmin = max(i-nsmooth_gridcells, ims)
        !            xmax = min(i+nsmooth_gridcells, ime)
        !            do k=kms,kme
        !                !write(*,*) "temp_f:  ", sum(temp_froude(xmin:xmax,k,ymin:ymax))
                        !write(*,*) "num_sum:  ", ((xmax-xmin+1) * (ymax-ymin+1))
        !                domain%froude(i,k,j) = sum(temp_froude(xmin:xmax,k,ymin:ymax)) / ((xmax-xmin+1) * (ymax-ymin+1))
        !            enddo
        !        enddo
        !    enddo

        !    if (n/=n_smoothing_passes) then
        !        temp_froude = domain%froude
        !    endif
        !enddo

    end subroutine update_stability

    !>-----------------------------------------
    !> Compute a smoothed terrain varience field for use in Froude number calculation
    !>
    !------------------------------------------
    subroutine compute_terrain_blocking_heights(domain) !froude_terrain, terrain)
        implicit none
        type(domain_t), intent(inout) :: domain
        real, allocatable    ::  azm(:,:), temp_ft_array(:,:,:,:)
        integer, allocatable :: azm_indices(:,:)
        integer           :: i, j, k, kms, kme, ang, i_s, j_s, i_start_buffer, i_end_buffer, j_start_buffer, j_end_buffer
        integer           :: rear_ang, fore_ang, test_ang, rear_ang_diff, fore_ang_diff, ang_diff, k_max, window_rear, window_fore, window_width
        integer :: nx, ny, x, y
        integer :: xs,xe, ys,ye, n, np
        integer :: window_size, smooth_window, n_smoothing_passes, search_max
        real, allocatable :: temp_terrain(:,:), f_terrain(:,:)
        real              :: pt_height, temp_ft, maxFTVal
        
        n_smoothing_passes = 5
        window_size   = int(max(5000.0/domain%dx,1.0)) !Compute Froude-terrain as the diff in min and max over a 5000m search window
        smooth_window = 5

        search_max = floor(2000/domain%dx)

        nx = size(domain%global_terrain,1)
        ny = size(domain%global_terrain,2)
        kms = lbound(domain%w%data_3d,2)
        kme = ubound(domain%w%data_3d,2)
        
        allocate(temp_ft_array( 1:72, domain%grid2d%ims:domain%grid2d%ime, kms:kme, domain%grid2d%jms:domain%grid2d%jme ))
        allocate(f_terrain(nx,ny))
        
        
        temp_ft_array = -100000.0
        
        ! first compute lightly smoothed terrain
        !do y=1,ny
        !    ys = max( y - smooth_window, 1)
        !    ye = min( y + smooth_window, ny)
        !    do x=1,nx
        !        xs = max( x - smooth_window, 1)
        !        xe = min( x + smooth_window, nx)
        !        n = (xe-xs+1) * (ye-ys+1)
        !        temp_terrain(x,y) = sum(domain%global_terrain(xs:xe,ys:ye)) / n
        !    enddo
        !enddo
        
        
        allocate(azm( 2*search_max+1, 2*search_max+1 ))
        allocate(azm_indices( 2*search_max+1, 2*search_max+1 ))
        azm = 0
                
        !Setup azm so that it is looking along wind direction (i.e. negatives here)
        do i = 1, 2*search_max+1
            do j = 1, 2*search_max+1                
                azm(i,j)  = atan2(-1.0*(i-(search_max+1)),-1.0*(j-(search_max+1)))
            end do
        end do
        
        !convert azm to deg
        azm = azm*rad2deg
        where(azm < 0) azm = 360+azm
        where(azm >= 360.0) azm=0.0
        azm_indices = int(azm/5)+1

        ! then compute the range of terrain (max-min) in a given window
        do i=domain%grid2d%ims, domain%grid2d%ime
            do j=domain%grid2d%jms, domain%grid2d%jme
                do k=kms,kme
                    if (k == 1) then
                        pt_height = domain%global_terrain(i,j)
                    else if (k > 1) then
                        pt_height = pt_height + domain%global_dz_interface(i,k,j)
                    end if
                    
                    
                    ! Check to use buffers to avoid searching out of grid
                    i_start_buffer = -min(0,i-(search_max+1))
                    i_end_buffer = min(0,domain%grid2d%ide-(i+search_max))
                
                    j_start_buffer = -min(0,j-(search_max+1))
                    j_end_buffer = min(0,domain%grid2d%jde-(j+search_max))
                
                    do i_s = 1+i_start_buffer, (search_max*2+1)+i_end_buffer
                        do j_s = 1+j_start_buffer, (search_max*2+1)+j_end_buffer
                        
                            temp_ft = domain%global_terrain(i+(i_s-(search_max+1)),j+(j_s-(search_max+1))) - pt_height
                            
                            if (temp_ft > temp_ft_array(azm_indices(i_s,j_s),i,k,j)) then
                            
                                !Only save scale length if it is greater than the vertical dz -- otherwise copy that over
                                if (temp_ft > domain%dz_interface%data_3d(i,k,j)) then
                                    temp_ft_array(azm_indices(i_s,j_s),i,k,j) = temp_ft
                                else
                                    temp_ft_array(azm_indices(i_s,j_s),i,k,j) = domain%dz_interface%data_3d(i,k,j)
                                end if
                            end if
                        enddo
                    enddo

                    !After finding Sx in each absolute direction around grid cell, 
                    !Pick max for each 30º window and perform interpolation to other directions if necesarry
                    
                    rear_ang = 1 
                    fore_ang = 1
                    
                    if (.not.( all((temp_ft_array(:,i,k,j) <= -100000.0)) )) then
                    
                        !Perform 20º window max search
                        window_width = 2
                        do ang = 1, 72
                            window_rear = ang-window_width
                            window_fore = ang+window_width
                        
                            if (ang <= window_width) then
                                window_rear = 72-(window_width-ang)
                                
                                maxFTVal = maxval(temp_ft_array(window_rear:72,i,k,j))

                                if (maxval(temp_ft_array(1:window_fore,i,k,j)) > maxFTVal) then
                                    maxFTVal = maxval(temp_ft_array(1:window_fore,i,k,j))
                                end if
                                
                            else if ( ang >= (72-(window_width-1)) ) then
                                window_fore = window_width-(72-ang)
                                
                                maxFTVal = maxval(temp_ft_array(window_rear:72,i,k,j))

                                if (maxval(temp_ft_array(1:window_fore,i,k,j)) > maxFTVal) then
                                    maxFTVal = maxval(temp_ft_array(1:window_fore,i,k,j))
                                end if
                            else
                                maxFTVal = maxval(temp_ft_array(window_rear:window_fore,i,k,j))
                            end if
                            domain%froude_terrain(ang,i,k,j) = maxFTVal
                        end do                    
                    
                        do ang = 1, 72
                            !Determine indices for interpolation
                            if ( (ang==fore_ang) ) then
                                !Update indices for interpolated Sx's
                                rear_ang = ang
                            
                                fore_ang = ang+1
                                if (fore_ang > 72) fore_ang = 1
                                
                                do while (domain%froude_terrain(fore_ang,i,k,j) <= -100000.0)
                                    fore_ang = fore_ang+1
                                    if (fore_ang > 72) fore_ang = 1
                                end do
                            
                            end if
                            
                            if (ang==1) then
                                rear_ang = 72
                                do while(domain%froude_terrain(rear_ang,i,k,j) <= -100000.0)
                                    rear_ang = rear_ang-1
                                end do
                            end if
                    
                            !If we did not calculate Sx for a given direction
                            if (domain%froude_terrain(ang,i,k,j) == -100000.0) then
                                !Weight the two surrounding Sx values based on our angular-distance to them
                                rear_ang_diff = ang-rear_ang
                                fore_ang_diff = fore_ang-ang
                                ang_diff = fore_ang-rear_ang
                        
                                !Handle wrap-around case
                                if (ang > fore_ang) then
                                    fore_ang_diff = fore_ang+(72-ang)
                                    ang_diff = fore_ang+(72-rear_ang)
                                end if
                        
                                !Interpolation, linearly-weighted by angular-distance from values
                                domain%froude_terrain(ang,i,k,j) = (domain%froude_terrain(rear_ang,i,k,j)*fore_ang_diff + &
                                                    domain%froude_terrain(fore_ang,i,k,j)*rear_ang_diff)/ang_diff

                                !if (domain%Sx(ang,i,k,j) > 0) sheltering_TPI(ang,i,k,j) = (sheltering_TPI(rear_ang,i,k,j)*fore_ang_diff + &
                                !                    sheltering_TPI(fore_ang,i,k,j)*rear_ang_diff)/ang_diff

                            end if
                        end do

                    else
                        !IF we only have -100000 for all entries, set to dz
                        domain%froude_terrain(:,i,k,j) = domain%dz_interface%data_3d(i,k,j)
                    end if
                enddo

            enddo
        enddo
                                                               
        if (domain%jts==(domain%jds+1)) domain%froude_terrain(:,:,:,domain%grid2d%jms) = &
                                        domain%froude_terrain(:,:,:,domain%grid2d%jms+1)
                        
        if (domain%its==(domain%ids+1)) domain%froude_terrain(:,domain%grid2d%ims,:,:) = &
                                        domain%froude_terrain(:,domain%grid2d%ims+1,:,:)

        if (domain%jte==(domain%jde-1)) domain%froude_terrain(:,:,:,domain%grid2d%jme) = &
                                        domain%froude_terrain(:,:,:,domain%grid2d%jme-1)

        if (domain%ite==(domain%ide-1)) domain%froude_terrain(:,domain%grid2d%ime,:,:) = &
                                        domain%froude_terrain(:,domain%grid2d%ime-1,:,:)
                                 

        !domain%froude_terrain(x,y) = maxval(domain%global_terrain(xs:xe,ys:ye)) - &
        !                                     minval(domain%global_terrain(xs:xe,ys:ye))        
        
        !do y=1,ny
        !    ys = max( y - window_size, 1)
        !    ye = min( y + window_size, ny)
        !    do x=1,nx
        !        xs = max( x - window_size, 1)
        !        xe = min( x + window_size, nx)
        !        domain%froude_terrain(:,x,:,y) = maxval(domain%global_terrain(xs:xe,ys:ye)) - &
        !                                     minval(domain%global_terrain(xs:xe,ys:ye))
        !    enddo
        !enddo
        ! call io_write("initial_terrain_delta.nc","data",temp_terrain)

        ! finally smooth that terrain delta field a few times as well

        !do np=1,n_smoothing_passes
        !    do y=1,ny
        !        ys = max( y - smooth_window, 1)
        !        ye = min( y + smooth_window, ny)
        !        do x=1,nx
        !            xs = max( x - smooth_window, 1)
        !            xe = min( x + smooth_window, nx)
        !            n = (xe-xs+1) * (ye-ys+1)
        !            temp_terrain(x,y) = sum(f_terrain(xs:xe,ys:ye)) / n
        !        enddo
        !    enddo
        !    if (np /= n_smoothing_passes) then
        !        f_terrain = temp_terrain
        !    endif
        !enddo
        !domain%froude_terrain = temp_terrain(domain%its-1:domain%ite+1,domain%jts-1:domain%jte+1)
        call io_write("terrain_blocking.nc","data",domain%froude_terrain)

    end subroutine compute_terrain_blocking_heights


    !>------------------------------------------------------------
    !! Provides a routine to deallocate memory allocated in allocate_winds
    !!
    !!------------------------------------------------------------
    ! subroutine finalize_winds(domain)
    !     type(domain_t), intent(inout) :: domain
    !
    !     if (allocated(domain%sintheta)) then
    !         deallocate(domain%sintheta)
    !     endif
    !     if (allocated(domain%costheta)) then
    !         deallocate(domain%costheta)
    !     endif
    !     if (allocated(domain%dzdx)) then
    !         deallocate(domain%dzdx)
    !     endif
    !     if (allocated(domain%dzdy)) then
    !         deallocate(domain%dzdy)
    !     endif
    !
    ! end subroutine finalize_winds
end module wind
