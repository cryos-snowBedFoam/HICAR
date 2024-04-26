!>----------------------------------------------------------
!! This module provides a wrapper to call various radiation models
!! It sets up variables specific to the physics package to be used
!!
!! The main entry point to the code is rad(domain,options,dt)
!!
!! <pre>
!! Call tree graph :
!!  radiation_init->[ external initialization routines]
!!  rad->[  external radiation routines]
!!
!! High level routine descriptions / purpose
!!   radiation_init     - initializes physics package
!!   rad                - sets up and calls main physics package
!!
!! Inputs: domain, options, dt
!!      domain,options  = as defined in data_structures
!!      dt              = time step (seconds)
!! </pre>
!!
!!  @author
!!  Ethan Gutmann (gutmann@ucar.edu)
!!
!!----------------------------------------------------------
module radiation
    use module_ra_simple, only: ra_simple, ra_simple_init, calc_solar_elevation
    use module_ra_simple, only: calc_solar_azimuth, calc_solar_elevation_corr !! MJ added
    use module_ra_rrtmg_lw, only: rrtmg_lwinit, rrtmg_lwrad
    use module_ra_rrtmg_sw, only: rrtmg_swinit, rrtmg_swrad
    use options_interface,  only : options_t
    use domain_interface,   only : domain_t
    use data_structures
    use icar_constants, only : kVARS
    use mod_wrf_constants, only : cp, R_d, gravity, DEGRAD, DPD, piconst
    use mod_atm_utilities, only : cal_cldfra3
    implicit none
    integer :: update_interval
    real*8  :: last_model_time
    real    :: solar_constant

    !! MJ added to aggregate radiation over output interval
    real, allocatable, dimension(:,:) :: sum_SWdif, sum_SWdir, sum_SW, sum_LW, cos_project_angle, solar_elevation_store, solar_azimuth_store
    real, allocatable                 :: solar_azimuth(:), solar_elevation(:), day_frac(:)
    real*8 :: counter
    real*8  :: Delta_t !! MJ added to detect the time for outputting 
    integer :: ims, ime, jms, jme, kms, kme
    integer :: its, ite, jts, jte, kts, kte
    integer :: ids, ide, jds, jde, kds, kde

    
contains

    subroutine radiation_init(domain,options)
        type(domain_t), intent(inout) :: domain
        type(options_t),intent(in) :: options
        
        ims = domain%grid%ims
        ime = domain%grid%ime
        jms = domain%grid%jms
        jme = domain%grid%jme
        kms = domain%grid%kms
        kme = domain%grid%kme
        its = domain%grid%its
        ite = domain%grid%ite
        jts = domain%grid%jts
        jte = domain%grid%jte
        kts = domain%grid%kts
        kte = domain%grid%kte

        ids = domain%grid%ids
        ide = domain%grid%ide
        jds = domain%grid%jds
        jde = domain%grid%jde
        kds = domain%grid%kds
        kde = domain%grid%kde
        
        !! MJ added to aggregate radiation over output interval
        !allocate(sum_SW(domain%grid%ims:domain%grid%ime,domain%grid%jms:domain%grid%jme)); sum_SW=0.
        !allocate(sum_SWdif(domain%grid%ims:domain%grid%ime,domain%grid%jms:domain%grid%jme)); sum_SWdif=0.
        !allocate(sum_SWdir(domain%grid%ims:domain%grid%ime,domain%grid%jms:domain%grid%jme)); sum_SWdir=0.
        !allocate(sum_LW(domain%grid%ims:domain%grid%ime,domain%grid%jms:domain%grid%jme)); sum_LW=0.
        
        if (options%physics%radiation_downScaling==1) then
            allocate(cos_project_angle(ims:ime,jms:jme)) !! MJ added
            allocate(solar_elevation_store(ims:ime,jms:jme)) !! MJ added
            allocate(solar_azimuth_store(ims:ime,jms:jme)) !! MJ added
        endif
        
        allocate(solar_elevation(ims:ime))
        allocate(solar_azimuth(ims:ime)) !! MJ added
        allocate(day_frac(ims:ime))


        if (STD_OUT_PE) write(*,*) "Initializing Radiation"

        if (options%physics%radiation==kRA_BASIC) then
            if (STD_OUT_PE) write(*,*) "    Basic Radiation"
        endif
        if (options%physics%radiation==kRA_SIMPLE .or. (options%physics%landsurface>0 .and. options%physics%radiation==0)) then
            if (STD_OUT_PE) write(*,*) "    Simple Radiation"
            call ra_simple_init(domain, options)
        endif!! MJ added to detect the time for outputting 

        if (options%physics%radiation==kRA_RRTMG) then
            if (STD_OUT_PE) write(*,*) "    RRTMG"
            if(.not.allocated(domain%tend%th_lwrad)) &
                allocate(domain%tend%th_lwrad(domain%ims:domain%ime,domain%kms:domain%kme,domain%jms:domain%jme))
            if(.not.allocated(domain%tend%th_swrad)) &
                allocate(domain%tend%th_swrad(domain%ims:domain%ime,domain%kms:domain%kme,domain%jms:domain%jme))

            if (options%physics%microphysics .ne. kMP_THOMP_AER) then
               if (STD_OUT_PE)write(*,*) '    NOTE: When running RRTMG, microphysics option 5 works best.'
            endif

            ! needed to allocate module variables so ra_driver can use calc_solar_elevation
            call ra_simple_init(domain, options)

            call rrtmg_lwinit(                           &
                p_top=(minval(domain%pressure_interface%data_3d(:,domain%kme+1,:))),     allowed_to_read=.TRUE. ,                &
                ids=domain%ids, ide=domain%ide, jds=domain%jds, jde=domain%jde, kds=domain%kds, kde=domain%kde,                &
                ims=domain%ims, ime=domain%ime, jms=domain%jms, jme=domain%jme, kms=domain%kms, kme=domain%kme,                &
                its=domain%its, ite=domain%ite, jts=domain%jts, jte=domain%jte, kts=domain%kts, kte=domain%kte                 )

            call rrtmg_swinit(                           &
                allowed_to_read=.TRUE.,                     &
                ids=domain%ids, ide=domain%ide, jds=domain%jds, jde=domain%jde, kds=domain%kds, kde=domain%kde,                &
                ims=domain%ims, ime=domain%ime, jms=domain%jms, jme=domain%jme, kms=domain%kms, kme=domain%kme,                &
                its=domain%its, ite=domain%ite, jts=domain%jts, jte=domain%jte, kts=domain%kts, kte=domain%kte                 )
                domain%tend%th_swrad = 0
                domain%tend%th_lwrad = 0
        endif
        update_interval=options%rad_options%update_interval_rrtmg ! 30 min, 1800 s   600 ! 10 min (600 s)
        last_model_time = domain%model_time%seconds()-update_interval

    end subroutine radiation_init


    subroutine ra_var_request(options)
        implicit none
        type(options_t), intent(inout) :: options

        if (options%physics%radiation == kRA_SIMPLE) then
            call ra_simple_var_request(options)
        endif

        if (options%physics%radiation == kRA_RRTMG) then
            call ra_rrtmg_var_request(options)
        endif
        
        !! MJ added: the vars requested if we have radiation_downScaling  
        if (options%physics%radiation_downScaling==1) then        
            call options%alloc_vars( [kVARS%slope, kVARS%slope_angle, kVARS%aspect_angle, kVARS%svf, kVARS%hlm, kVARS%shortwave_direct, &
                                      kVARS%shortwave_diffuse, kVARS%shortwave_direct_above, kVARS%shortwave_total]) 
        endif

    end subroutine ra_var_request


    !> ----------------------------------------------
    !! Communicate to the master process requesting the variables requred to be allocated, used for restart files, and advected
    !!
    !! ----------------------------------------------
    subroutine ra_simple_var_request(options)
        implicit none
        type(options_t), intent(inout) :: options


        ! List the variables that are required to be allocated for the simple radiation code
        call options%alloc_vars( &
                     [kVARS%pressure,    kVARS%potential_temperature,   kVARS%exner,        kVARS%cloud_fraction,   &
                      kVARS%shortwave,   kVARS%longwave, kVARS%cosine_zenith_angle])

        ! List the variables that are required to be advected for the simple radiation code
        call options%advect_vars( &
                      [kVARS%potential_temperature] )

        ! List the variables that are required when restarting for the simple radiation code
        call options%restart_vars( &
                       [kVARS%pressure,     kVARS%potential_temperature, kVARS%shortwave,   kVARS%longwave, kVARS%cloud_fraction, kVARS%cosine_zenith_angle] )

    end subroutine ra_simple_var_request


    !> ----------------------------------------------
    !! Communicate to the master process requesting the variables requred to be allocated, used for restart files, and advected
    !!
    !! ----------------------------------------------
    subroutine ra_rrtmg_var_request(options)
        implicit none
        type(options_t), intent(inout) :: options

        ! List the variables that are required to be allocated for the simple radiation code
        call options%alloc_vars( &
                     [kVARS%pressure,     kVARS%pressure_interface,    kVARS%potential_temperature,   kVARS%exner,            &
                      kVARS%shortwave, kVARS%shortwave_direct, kVARS%shortwave_diffuse,   kVARS%longwave,                                                                     &
                      kVARS%out_longwave_rad, &
                      kVARS%land_mask,    kVARS%snow_water_equivalent,                                                        &
                      kVARS%dz_interface, kVARS%skin_temperature,      kVARS%temperature,             kVARS%density,          &
                      kVARS%longwave_cloud_forcing,                    kVARS%land_emissivity,         kVARS%temperature_interface,  &
                      kVARS%cosine_zenith_angle,                       kVARS%shortwave_cloud_forcing, kVARS%tend_swrad,           &
                      kVARS%cloud_fraction, kVARS%albedo])


        ! List the variables that are required when restarting for the simple radiation code
        call options%restart_vars( &
                     [kVARS%pressure,     kVARS%pressure_interface,    kVARS%potential_temperature,   kVARS%exner,            &
                      kVARS%water_vapor,  kVARS%shortwave, kVARS%shortwave_direct, kVARS%shortwave_diffuse,    kVARS%longwave,                                                 &          
                      kVARS%out_longwave_rad, &
                      kVARS%snow_water_equivalent,                                                                            &
                      kVARS%dz_interface, kVARS%skin_temperature,      kVARS%temperature,             kVARS%density,          &
                      kVARS%longwave_cloud_forcing,                    kVARS%land_emissivity, kVARS%temperature_interface,    &
                      kVARS%cosine_zenith_angle,                       kVARS%shortwave_cloud_forcing, kVars%tend_swrad] )

    end subroutine ra_rrtmg_var_request


    subroutine rad(domain, options, dt, halo, subset)
        implicit none

        type(domain_t), intent(inout) :: domain
        type(options_t),intent(in)    :: options
        real,           intent(in)    :: dt
        integer,        intent(in), optional :: halo, subset


        real, dimension(:,:,:,:), pointer :: tauaer_sw=>null(), ssaaer_sw=>null(), asyaer_sw=>null()
        real, allocatable:: albedo(:,:),gsw(:,:)
        real, allocatable:: t_1d(:), p_1d(:), Dz_1d(:), qv_1d(:), qc_1d(:), qi_1d(:), qs_1d(:), cf_1d(:)
        real, allocatable :: qc(:,:,:),qi(:,:,:), qs(:,:,:), qg(:,:,:), qr(:,:,:), cldfra(:,:,:)
        real, allocatable :: re_c(:,:,:),re_i(:,:,:), re_s(:,:,:)

        real, allocatable :: xland(:,:)

        real :: gridkm, ra_dt, declin
        integer :: i, k, j

        logical :: f_qr, f_qc, f_qi, F_QI2, F_QI3, f_qs, f_qg, f_qv, f_qndrop
        integer :: mp_options, F_REC, F_REI, F_RES
        
        
        !! MJ added
        real :: trans_atm, trans_atm_dir, max_dir_1, max_dir_2, max_dir, elev_th, ratio_dif
        integer :: zdx, zdx_max
        
        if (options%physics%radiation == 0) return
        
        !We only need to calculate these variables if we are using terrain shading, otherwise only call on each radiation update
        if (options%physics%radiation_downScaling == 1 .or. &
            ((domain%model_time%seconds() - last_model_time) >= update_interval)) then
            do j = jms,jme
               !! MJ used corr version, as other does not work in Erupe
                solar_elevation  = calc_solar_elevation_corr(date=domain%model_time, lon=domain%longitude%data_2d, &
                                j=j, ims=ims,ime=ime,jms=jms,jme=jme,its=its,ite=ite,day_frac=day_frac, solar_azimuth=solar_azimuth)
                domain%cosine_zenith_angle%data_2d(its:ite,j)=sin(solar_elevation(its:ite))
                
                !If we are doing terrain shading, we will need these later!
                if (options%physics%radiation_downScaling == 1) then
                    cos_project_angle(its:ite,j)= cos(domain%slope_angle%data_2d(its:ite,j))*sin(solar_elevation(its:ite)) + &
                                                  sin(domain%slope_angle%data_2d(its:ite,j))*cos(solar_elevation(its:ite))   &
                                                  *cos(solar_azimuth(its:ite)-domain%aspect_angle%data_2d(its:ite,j))

                    solar_elevation_store(its:ite,j) = solar_elevation(its:ite)
                    solar_azimuth_store(its:ite,j) = solar_azimuth(its:ite)
                endif
            enddo
        endif
        !If we are not over the update interval, don't run any of this, since it contains allocations, etc...
        if ((domain%model_time%seconds() - last_model_time) >= update_interval) then

            ra_dt = domain%model_time%seconds() - last_model_time
            last_model_time = domain%model_time%seconds()

            allocate(t_1d(kms:kme))
            allocate(p_1d(kms:kme))
            allocate(Dz_1d(kms:kme))
            allocate(qv_1d(kms:kme))
            allocate(qc_1d(kms:kme))
            allocate(qi_1d(kms:kme))
            allocate(qs_1d(kms:kme))
            allocate(cf_1d(kms:kme))

            allocate(qc(ims:ime,kms:kme,jms:jme))
            allocate(qi(ims:ime,kms:kme,jms:jme))
            allocate(qs(ims:ime,kms:kme,jms:jme))
            allocate(qg(ims:ime,kms:kme,jms:jme))
            allocate(qr(ims:ime,kms:kme,jms:jme))

            allocate(re_c(ims:ime,kms:kme,jms:jme))
            allocate(re_i(ims:ime,kms:kme,jms:jme))
            allocate(re_s(ims:ime,kms:kme,jms:jme))

            allocate(cldfra(ims:ime,kms:kme,jms:jme))
            allocate(xland(ims:ime,jms:jme))

            allocate(albedo(ims:ime,jms:jme))
            allocate(gsw(ims:ime,jms:jme))

            ! Note, need to link NoahMP to update albedo

            qc = 0
            qi = 0
            qs = 0
            qg = 0
            qr = 0

            re_c = 0
            re_i = 0
            re_s = 0

            cldfra=0

            F_QI=.false.
            F_QI2 = .false.
            F_QI3 = .false.
            F_QC=.false.
            F_QR=.false.
            F_QS=.false.
            F_QG=.false.
            f_qndrop=.false.
            F_QV=.false.

            F_REC=0
            F_REI=0
            F_RES=0

            F_QI=associated(domain%cloud_ice_mass%data_3d )
            F_QC=associated(domain%cloud_water_mass%data_3d )
            F_QR=associated(domain%rain_mass%data_3d )
            F_QS=associated(domain%snow_mass%data_3d )
            F_QV=associated(domain%water_vapor%data_3d )
            F_QG=associated(domain%graupel_mass%data_3d )
            F_QNDROP=associated(domain%cloud_number%data_3d)
            F_QI2=associated(domain%ice2_mass%data_3d)
            F_QI3=associated(domain%ice3_mass%data_3d)

            if(associated(domain%re_cloud%data_3d)) F_REC = 1
            if(associated(domain%re_ice%data_3d)) F_REI = 1
            if(associated(domain%re_snow%data_3d)) F_RES = 1


            if (F_QG) qg(:,:,:) = domain%graupel_mass%data_3d
            if (F_QC) qc(:,:,:) = domain%cloud_water_mass%data_3d
            if (F_QI) qi(:,:,:) = domain%cloud_ice_mass%data_3d
            if (F_QI2) qi(:,:,:) = qi + domain%ice2_mass%data_3d
            if (F_QI3) qi(:,:,:) = qi + domain%ice3_mass%data_3d
            if (F_QS) qs(:,:,:) = domain%snow_mass%data_3d
            if (F_QR) qr(:,:,:) = domain%rain_mass%data_3d

            if (F_REC > 0) re_c(:,:,:) = domain%re_cloud%data_3d
            if (F_REI > 0) re_i(:,:,:) = domain%re_ice%data_3d
            if (F_RES > 0) re_s(:,:,:) = domain%re_snow%data_3d

            mp_options=0

            !Calculate solar constant
            call radconst(domain%model_time%day_of_year(), declin, solar_constant)
           
            if (options%physics%radiation==kRA_SIMPLE) then
                call ra_simple(theta = domain%potential_temperature%data_3d,         &
                               pii= domain%exner%data_3d,                            &
                               qv = domain%water_vapor%data_3d,                      &
                               qc = qc,                 &
                               qs = qs + qi + qg,                                    &
                               qr = qr,                        &
                               p =  domain%pressure%data_3d,                         &
                               swdown =  domain%shortwave%data_2d,                   &
                               lwdown =  domain%longwave%data_2d,                    &
                               cloud_cover =  domain%cloud_fraction%data_2d,         &
                               lat = domain%latitude%data_2d,                        &
                               lon = domain%longitude%data_2d,                       &
                               date = domain%model_time,                             &
                               options = options,                                    &
                               dt = ra_dt,                                           &
                               ims=ims, ime=ime, jms=jms, jme=jme, kms=kms, kme=kme, &
                               its=its, ite=ite, jts=jts, jte=jte, kts=kts, kte=kte, F_runlw=.True.)
            endif

            if (options%physics%radiation==kRA_RRTMG) then

                if (options%lsm_options%monthly_albedo) then
                    ALBEDO = domain%albedo%data_3d(:, domain%model_time%month, :)
                else
                    ALBEDO = domain%albedo%data_3d(:, 1, :)
                endif

                domain%tend%th_swrad = 0
                domain%shortwave%data_2d = 0
                ! Calculate cloud fraction
                If (options%rad_options%icloud == 3) THEN
                    IF ( F_QC .AND. F_QI ) THEN
                        gridkm = domain%dx/1000
                        XLAND = domain%land_mask
                        domain%cloud_fraction%data_2d = 0
                        DO j = jts,jte
                            DO i = its,ite
                                DO k = kts,kte
                                    p_1d(k) = domain%pressure%data_3d(i,k,j) !p(i,k,j)
                                    t_1d(k) = domain%temperature%data_3d(i,k,j)
                                    qv_1d(k) = domain%water_vapor%data_3d(i,k,j)
                                    qc_1d(k) = qc(i,k,j)
                                    qi_1d(k) = qi(i,k,j)
                                    qs_1d(k) = qs(i,k,j)
                                    Dz_1d(k) = domain%dz_interface%data_3d(i,k,j)
                                    cf_1d(k) = cldfra(i,k,j)
                                ENDDO
                                CALL cal_cldfra3(cf_1d, qv_1d, qc_1d, qi_1d, qs_1d, Dz_1d, &
                 &                              p_1d, t_1d, XLAND(i,j), gridkm,        &
                 &                              .false., 1.5, kms, kme)

                                DO k = kts,kte
                                    ! qc, qi and qs are locally recalculated in cal_cldfra3 base on RH to account for subgrid clouds                                     qc(i,k,j) = qc_1d(k)
                                    qc(i,k,j) = qc_1d(k)
                                    qi(i,k,j) = qi_1d(k)
                                    qs(i,k,j) = qs_1d(k)
                                    cldfra(i,k,j) = cf_1d(k)
                                    domain%cloud_fraction%data_2d(i,j) = max(domain%cloud_fraction%data_2d(i,j), cf_1d(k))
                                ENDDO
                            ENDDO
                        ENDDO
                    END IF
                END IF

                call RRTMG_SWRAD(rthratensw=domain%tend%th_swrad,         &
!                swupt, swuptc, swuptcln, swdnt, swdntc, swdntcln, &
!                swupb, swupbc, swupbcln, swdnb, swdnbc, swdnbcln, &
!                      swupflx, swupflxc, swdnflx, swdnflxc,      &
                    swdnb = domain%shortwave%data_2d,                     &
                    swcf = domain%shortwave_cloud_forcing%data_2d,        &
                    gsw = gsw,                                            &
                    xtime = 0., gmt = 0.,                                 &  ! not used
                    xlat = domain%latitude%data_2d,                       &  ! not used
                    xlong = domain%longitude%data_2d,                     &  ! not used
                    radt = 0., degrad = 0., declin = 0.,                  &  ! not used
                    coszr = domain%cosine_zenith_angle%data_2d,           &
                    julday = 0,                                           &  ! not used
                    solcon = solar_constant,                              &
                    albedo = albedo,                                      &
                    t3d = domain%temperature%data_3d,                     &
                    t8w = domain%temperature_interface%data_3d,           &
                    tsk = domain%skin_temperature%data_2d,                &
                    p3d = domain%pressure%data_3d,                        &
                    p8w = domain%pressure_interface%data_3d,              &
                    pi3d = domain%exner%data_3d,                          &
                    rho3d = domain%density%data_3d,                       &
                    dz8w = domain%dz_interface%data_3d,                   &
                    cldfra3d=cldfra,                                      &
                    !, lradius, iradius,                                  &
                    is_cammgmp_used = .False.,                            &
                    r = R_d,                                               &
                    g = gravity,                                          &
                    re_cloud = re_c,                   &
                    re_ice   = re_i,                     &
                    re_snow  = re_s,                    &
                    has_reqc=F_REC,                                           & ! use with icloud > 0
                    has_reqi=F_REI,                                           & ! use with icloud > 0
                    has_reqs=F_RES,                                           & ! use with icloud > 0 ! G. Thompson
                    icloud = options%rad_options%icloud,                  & ! set to nonzero if effective radius is available from microphysics
                    warm_rain = .False.,                                  & ! when a dding WSM3scheme, add option for .True.
                    cldovrlp=options%rad_options%cldovrlp,                & ! J. Henderson AER: cldovrlp namelist value
                    !f_ice_phy, f_rain_phy,                               &
                    xland=real(domain%land_mask),                         &
                    xice=real(domain%land_mask)*0,                        & ! should add a variable for sea ice fraction
                    snow=domain%snow_water_equivalent%data_2d,            &
                    qv3d=domain%water_vapor%data_3d,                      &
                    qc3d=qc,                                              &
                    qr3d=qr,                                              &
                    qi3d=qi,                                              &
                    qs3d=qs,                                              &
                    qg3d=qg,                                              &
                    !o3input, o33d,                                       &
                    aer_opt=0,                                            &
                    !aerod,                                               &
                    no_src = 1,                                           &
!                   alswvisdir, alswvisdif,                               &  !Zhenxin ssib alb comp (06/20/2011)
!                   alswnirdir, alswnirdif,                               &  !Zhenxin ssib alb comp (06/20/2011)
!                   swvisdir, swvisdif,                                   &  !Zhenxin ssib swr comp (06/20/2011)
!                   swnirdir, swnirdif,                                   &  !Zhenxin ssib swi comp (06/20/2011)
                    sf_surface_physics=1,                                 &  !Zhenxin
                    f_qv=f_qv, f_qc=f_qc, f_qr=f_qr,                      &
                    f_qi=f_qi, f_qs=f_qs, f_qg=f_qg,                      &
                    !tauaer300,tauaer400,tauaer600,tauaer999,             & ! czhao
                    !gaer300,gaer400,gaer600,gaer999,                     & ! czhao
                    !waer300,waer400,waer600,waer999,                     & ! czhao
!                   aer_ra_feedback,                                      &
!jdfcz              progn,prescribe,                                      &
                    calc_clean_atm_diag=0,                                &
!                    qndrop3d=domain%cloud_number%data_3d,                 &
                    f_qndrop=f_qndrop,                                    & !czhao
                    mp_physics=0,                                         & !wang 2014/12
                    ids=ids, ide=ide, jds=jds, jde=jde, kds=kds, kde=kde, &
                    ims=ims, ime=ime, jms=jms, jme=jme, kms=kms, kme=kme, &
                    its=its, ite=ite, jts=jts, jte=jte, kts=kts, kte=kte-1, &
                    !swupflx, swupflxc,                                   &
                    !swdnflx, swdnflxc,                                   &
                    tauaer3d_sw=tauaer_sw,                                & ! jararias 2013/11
                    ssaaer3d_sw=ssaaer_sw,                                & ! jararias 2013/11
                    asyaer3d_sw=asyaer_sw,                                &
                    swddir = domain%shortwave_direct%data_2d,             &
!                   swddni = domain%skin_temperature%data_2d,             &
                    swddif = domain%shortwave_diffuse%data_2d,             & ! jararias 2013/08
!                   swdownc = domain%skin_temperature%data_2d,            &
!                   swddnic = domain%skin_temperature%data_2d,            &
!                   swddirc = domain%skin_temperature%data_2d,            &   ! PAJ
                    xcoszen = domain%cosine_zenith_angle%data_2d,         &  ! NEED TO CALCULATE THIS.
                    yr=domain%model_time%year,                            &
                    julian=domain%model_time%day_of_year(),               &
                    mp_options=mp_options                               )
                    
                    
                ! DR added December 2023 -- this is necesarry because HICAR does not use a pressure coordinate, so
                ! p_top is not fixed throughout the simulation. p_top must be reset for each call of RRTMG_LW, 
                ! which is what RRTMG_LWINIT does. Pass allowed_to_read=.False.
                ! to avoid re-reading look up tables (already done in init).
                CALL RRTMG_LWINIT(minval(domain%pressure_interface%data_3d(:,domain%kme+1,:)), &
                                  allowed_to_read=.FALSE.,         &
                                  ids=ids, ide=ide, jds=jds, jde=jde, kds=kds, kde=kde, &
                                  ims=ims, ime=ime, jms=jms, jme=jme, kms=kms, kme=kme, &
                                  its=its, ite=ite, jts=jts, jte=jte, kts=kts, kte=kte)
                
                call RRTMG_LWRAD(rthratenlw=domain%tend%th_lwrad,                 &
!                           lwupt, lwuptc, lwuptcln, lwdnt, lwdntc, lwdntcln,     &        !if lwupt defined, all MUST be defined
!                           lwupb, lwupbc, lwupbcln, lwdnb, lwdnbc, lwdnbcln,     &
                            glw = domain%longwave%data_2d,                        &
                            olr = domain%out_longwave_rad%data_2d,                &
                            lwcf = domain%longwave_cloud_forcing%data_2d,         &
                            emiss = domain%land_emissivity%data_2d,               &
                            p8w = domain%pressure_interface%data_3d,              &
                            p3d = domain%pressure%data_3d,                        &
                            pi3d = domain%exner%data_3d,                          &
                            dz8w = domain%dz_interface%data_3d,                   &
                            tsk = domain%skin_temperature%data_2d,                &
                            t3d = domain%temperature%data_3d,                     &
                            t8w = domain%temperature_interface%data_3d,           &     ! temperature interface
                            rho3d = domain%density%data_3d,                       &
                            r = R_d,                                               &
                            g = gravity,                                          &
                            icloud = options%rad_options%icloud,                  & ! set to nonzero if effective radius is available from microphysics
                            warm_rain = .False.,                                  & ! when a dding WSM3scheme, add option for .True.
                            cldfra3d = cldfra,                                    &
                            cldovrlp=options%rad_options%cldovrlp,                & ! J. Henderson AER: cldovrlp namelist value
!                            lradius,iradius,                                     & !goes with CAMMGMP (Morrison Gettelman CAM mp)
                            is_cammgmp_used = .False.,                            & !goes with CAMMGMP (Morrison Gettelman CAM mp)
!                            f_ice_phy, f_rain_phy,                               & !goes with MP option 5 (Ferrier)
                            xland=real(domain%land_mask),                         &
                            xice=real(domain%land_mask)*0,                        & ! should add a variable for sea ice fraction
                            snow=domain%snow_water_equivalent%data_2d,            &
                            qv3d=domain%water_vapor%data_3d,                      &
                            qc3d=qc,                                              &
                            qr3d=qr,                                              &
                            qi3d=qi,                                              &
                            qs3d=qs,                                              &
                            qg3d=qg,                                              &
!                           o3input, o33d,                                        &
                            f_qv=f_qv, f_qc=f_qc, f_qr=f_qr,                      &
                            f_qi=f_qi, f_qs=f_qs, f_qg=f_qg,                      &
                            re_cloud = re_c,                   &
                            re_ice   = re_i,                     &
                            re_snow  = re_s,                    &
                            has_reqc=F_REC,                                       & ! use with icloud > 0
                            has_reqi=F_REI,                                       & ! use with icloud > 0
                            has_reqs=F_RES,                                       & ! use with icloud > 0 ! G. Thompson
!                           tauaerlw1,tauaerlw2,tauaerlw3,tauaerlw4,              & ! czhao
!                           tauaerlw5,tauaerlw6,tauaerlw7,tauaerlw8,              & ! czhao
!                           tauaerlw9,tauaerlw10,tauaerlw11,tauaerlw12,           & ! czhao
!                           tauaerlw13,tauaerlw14,tauaerlw15,tauaerlw16,          & ! czhao
!                           aer_ra_feedback,                                      & !czhao
!                    !jdfcz progn,prescribe,                                      & !czhao
                            calc_clean_atm_diag=0,                                & ! used with wrf_chem !czhao
!                            qndrop3d=domain%cloud_number%data_3d,                 & ! used with icould > 0
                            f_qndrop=f_qndrop,                                    & ! if icloud > 0, use this
                        !ccc added for time varying gases.
                            yr=domain%model_time%year,                             &
                            julian=domain%model_time%day_of_year(),                &
                        !ccc
                            mp_physics=0,                                          &
                            ids=ids, ide=ide, jds=jds, jde=jde, kds=kds, kde=kde,  &
                            ims=ims, ime=ime, jms=jms, jme=jme, kms=kms, kme=kme,  &
                            its=its, ite=ite, jts=jts, jte=jte, kts=kts, kte=kte-1,  &
!                           lwupflx, lwupflxc, lwdnflx, lwdnflxc,                  &
                            read_ghg=options%rad_options%read_ghg                  &
                            )
                            
                ! If the user has provided sky view fraction, then apply this to the diffuse SW now, 
                ! since svf is time-invariant
                if (associated(domain%svf%data_2d)) then
                    domain%shortwave_diffuse%data_2d=domain%shortwave_diffuse%data_2d*domain%svf%data_2d
                endif
                
                domain%tend_swrad%data_3d = domain%tend%th_swrad
            endif
        endif
        
        !If using the RRTMG scheme, then apply tendencies here. This is now outside of interval loop, so this will be called every phys timestep
        if (options%physics%radiation==kRA_RRTMG) then
            domain%potential_temperature%data_3d = domain%potential_temperature%data_3d+domain%tend%th_lwrad*dt+domain%tend%th_swrad*dt
            domain%temperature%data_3d = domain%potential_temperature%data_3d*domain%exner%data_3d
            domain%tend_swrad%data_3d = domain%tend%th_swrad
        endif
        
        !! MJ: note that radiation down scaling works only for simple and rrtmg schemes as they provide the above-topography radiation per horizontal plane
        !! MJ corrected, as calc_solar_elevation has largley understimated the zenith angle in Switzerland
        !! MJ added: this is Tobias Jonas (TJ) scheme based on swr function in metDataWizard/PROCESS_COSMO_DATA_1E2E.m and also https://github.com/Tobias-Jonas-SLF/HPEval
        if (options%physics%radiation_downScaling==1) then            
            !! partitioning the total radiation per horizontal plane into the diffusive and direct ones based on https://www.sciencedirect.com/science/article/pii/S0168192320300058, HPEval
            if (.not.(options%physics%radiation==kRA_RRTMG)) then
                ratio_dif=0.            
                do j = jts,jte
                    do i = its,ite
                        trans_atm = max(min(domain%shortwave%data_2d(i,j)/&
                                ( solar_constant* (sin(solar_elevation_store(i,j)+1.e-4)) ),1.),0.)   ! atmospheric transmissivity
                        if (trans_atm<=0.22) then
                            ratio_dif=1.-0.09*trans_atm  
                        elseif (0.22<trans_atm .and. trans_atm<=0.8) then
                            ratio_dif=0.95-0.16*trans_atm+4.39*trans_atm**2.-16.64*trans_atm**3.+12.34*trans_atm**4.   
                        elseif (trans_atm>0.8) then
                            ratio_dif=0.165
                        endif
                        domain%shortwave_diffuse%data_2d(i,j)= &
                                ratio_dif*domain%shortwave%data_2d(i,j)*domain%svf%data_2d(i,j)
                    enddo
                enddo                
            endif
            !!
            zdx_max = ubound(domain%hlm%data_3d,1)
            do j = jts,jte
                do i = its,ite
                    domain%shortwave_direct%data_2d(i,j) = max( domain%shortwave%data_2d(i,j) - &
                                                                    domain%shortwave_diffuse%data_2d(i,j),0.0)

                    ! determin maximum allowed direct swr
                    trans_atm_dir = max(min(domain%shortwave_direct%data_2d(i,j)/&
                                    (solar_constant*sin(solar_elevation_store(i,j)+1.e-4)),1.),0.)  ! atmospheric transmissivity for direct sw radiation
                    max_dir_1     = solar_constant*exp(log(1.-0.165)/max(sin(solar_elevation_store(i,j)),1.e-4))            
                    max_dir_2     = solar_constant*trans_atm_dir                          
                    max_dir       = min(max_dir_1,max_dir_2)                     ! applying both above criteria 1 and 2                    
                    
                    !!
                    zdx=floor(solar_azimuth_store(i,j)*(180./piconst)/4.0) !! MJ added= we have 90 by 4 deg for hlm ...zidx is the right index based on solar azimuthal angle

                    zdx = max(min(zdx,zdx_max),1)
                    elev_th=(90.-domain%hlm%data_3d(i,zdx,j))*DEGRAD !! MJ added: it is the solar elevation threshold above which we see the sun from the pixel  
                    if (solar_elevation_store(i,j)>=elev_th) then
                        domain%shortwave_direct_above%data_2d(i,j)=min(domain%shortwave_direct%data_2d(i,j),max_dir)
                        domain%shortwave_direct%data_2d(i,j) = min(domain%shortwave_direct%data_2d(i,j)/            &
                                                               max(sin(solar_elevation_store(i,j)),0.01),max_dir) * &
                                                               max(cos_project_angle(i,j),0.)
                    else
                        domain%shortwave_direct_above%data_2d(i,j)=0.
                        domain%shortwave_direct%data_2d(i,j)=0.
                    endif
                    domain%shortwave_total%data_2d(i,j) = domain%shortwave_diffuse%data_2d(i,j) + &
                                                          domain%shortwave_direct%data_2d(i,j)
                enddo
            enddo           
        endif
    end subroutine rad
    
    
! DR 2023: Taken from WRF mod_radiation_driver
!---------------------------------------------------------------------
!BOP
! !IROUTINE: radconst - compute radiation terms
! !INTERFAC:
   SUBROUTINE radconst(JULIAN, DECLIN, SOLCON)
!---------------------------------------------------------------------
   IMPLICIT NONE
!---------------------------------------------------------------------

! !ARGUMENTS:
   REAL, INTENT(IN   )      ::       JULIAN
   REAL, INTENT(OUT  )      ::       DECLIN,SOLCON
   REAL                     ::       OBECL,SINOB,SXLONG,ARG,  &
                                     DECDEG,DJUL,RJUL,ECCFAC
!
! !DESCRIPTION:
! Compute terms used in radiation physics 
!EOP

! for short wave radiation

   DECLIN=0.
   SOLCON=0.

!-----OBECL : OBLIQUITY = 23.5 DEGREE.
        
   OBECL=23.5*DEGRAD
   SINOB=SIN(OBECL)
        
!-----CALCULATE LONGITUDE OF THE SUN FROM VERNAL EQUINOX:
        
   IF(JULIAN.GE.80.)SXLONG=DPD*(JULIAN-80.)
   IF(JULIAN.LT.80.)SXLONG=DPD*(JULIAN+285.)
   SXLONG=SXLONG*DEGRAD
   ARG=SINOB*SIN(SXLONG)
   DECLIN=ASIN(ARG)
   DECDEG=DECLIN/DEGRAD
!----SOLAR CONSTANT ECCENTRICITY FACTOR (PALTRIDGE AND PLATT 1976)
   DJUL=JULIAN*360./365.
   RJUL=DJUL*DEGRAD
   ECCFAC=1.000110+0.034221*COS(RJUL)+0.001280*SIN(RJUL)+0.000719*  &
          COS(2*RJUL)+0.000077*SIN(2*RJUL)
   SOLCON=1370.*ECCFAC
   
   END SUBROUTINE radconst
   
end module radiation
