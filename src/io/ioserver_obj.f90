
!>----------------------------------------------------------
!!  Define the interface for the output object
!!
!!  Output objects store all of the data and references to data necessary to write
!!  an output file.  This includes primarily internal netcdf related IDs.
!!  Output objects also store an array of variables to output.
!!  These variables maintain pointers to the data to be output as well as
!!  Metadata (e.g. dimension names, units, other attributes)
!!
!!  @author
!!  Dylan Reynolds (dylan.reynolds@slf.ch)
!!
!!----------------------------------------------------------
submodule(ioserver_interface) ioserver_implementation
  use debug_module,             only : check_ncdf
  use iso_fortran_env
  use output_metadata,          only : get_metadata, get_varindx

  implicit none

contains


    module subroutine init(this, domain, options)
        class(ioserver_t),  intent(inout)  :: this
        type(domain_t),     intent(inout)  :: domain
        type(options_t),    intent(in)     :: options

        integer ::  n, var_indx, out_i, rst_i
        
        
        this%io_time = options%parameters%start_time
        !if (this%server_id==kNUM_PROC_PER_NODE) write(*,*) 'Initializing I/O Server'
        this%ide = domain%ide
        this%kde = domain%kde
        this%jde = domain%jde

        call init_with_clients(this)

        !Setup reading capability
        call this%reader%init(this%i_s_r,this%i_e_r,this%k_s_r,this%k_e_r,this%j_s_r,this%j_e_r,options)
        !this%n_children = size(this%children)
        this%n_r = this%reader%n_vars
        this%files_to_read = this%reader%eof

        !Setup writing capability
        call this%outputer%init(domain,options,this%i_s_w,this%i_e_w,this%k_s_w,this%k_e_w,this%j_s_w,this%j_e_w)
        
        this%n_w = this%outputer%n_vars

        !determine if we need to increase our k index due to some very large soil field
        do n = 1,this%n_w
            if(this%outputer%variables(n)%dim_len(3) > this%k_e_w) this%k_e_w = this%outputer%variables(n)%dim_len(3)
        enddo
        
        call setup_MPI_windows(this)

        call setup_MPI_types(this)


        !Link local buffer to the outputer variables
        allocate(this%parent_write_buffer(this%n_w,this%i_s_w:this%i_e_w+1,this%k_s_w:this%k_e_w,this%j_s_w:this%j_e_w+1))
        
        do n = 1,this%n_w
            if(this%outputer%variables(n)%three_d) then
                this%outputer%variables(n)%data_3d => this%parent_write_buffer(n,:,:,:)
            else
                this%outputer%variables(n)%data_2d => this%parent_write_buffer(n,:,1,:)
            endif
        enddo

        !Setup arrays for information about accessing variables from write buffer
        allocate(this%out_var_indices(count(options%io_options%vars_for_output > 0)))
        allocate(this%rst_var_indices(count(options%vars_for_restart > 0)))
        allocate(this%rst_var_names(count(options%vars_for_restart > 0)))

        out_i = 1
        rst_i = 1
        
        do n=1,this%n_w
            var_indx = get_varindx(this%outputer%variables(n)%name)
            if (options%io_options%vars_for_output(var_indx) > 0) then
                this%out_var_indices(out_i) = n
                out_i = out_i + 1
            endif
            if (options%vars_for_restart(var_indx) > 0) then
                this%rst_var_indices(rst_i) = n
                this%rst_var_names(rst_i) = this%outputer%variables(n)%name
                rst_i = rst_i + 1
            endif
        enddo

        if (options%parameters%restart) call this%outputer%init_restart(options, this%IO_comms, this%out_var_indices)

    end subroutine
    
    subroutine setup_MPI_windows(this)
        class(ioserver_t),   intent(inout)  :: this

        type(c_ptr) :: tmp_ptr
        integer(KIND=MPI_ADDRESS_KIND) :: win_size
        integer :: ierr
        real :: realnum

        ! +1 added to handle variables on staggered grids
        this%nx_w = maxval(this%iewc-this%iswc+1)+1
        this%nz_w = maxval(this%kewc-this%kswc+1)
        this%ny_w = maxval(this%jewc-this%jswc+1)+1

        this%nx_r = maxval(this%ierc-this%isrc+1)+1
        this%nz_r = maxval(this%kerc-this%ksrc+1)
        this%ny_r = maxval(this%jerc-this%jsrc+1)+1

       ! Setup MPI windows for inter-process communication        
        call MPI_Allreduce(MPI_IN_PLACE,this%nx_w,1,MPI_INT,MPI_MAX,this%client_comms,ierr)
        call MPI_Allreduce(MPI_IN_PLACE,this%ny_w,1,MPI_INT,MPI_MAX,this%client_comms,ierr)
        call MPI_Allreduce(MPI_IN_PLACE,this%nz_w,1,MPI_INT,MPI_MAX,this%client_comms,ierr)

        call MPI_Allreduce(MPI_IN_PLACE,this%nx_r,1,MPI_INT,MPI_MAX,this%client_comms,ierr)
        call MPI_Allreduce(MPI_IN_PLACE,this%ny_r,1,MPI_INT,MPI_MAX,this%client_comms,ierr)
        call MPI_Allreduce(MPI_IN_PLACE,this%nz_r,1,MPI_INT,MPI_MAX,this%client_comms,ierr)

        call MPI_Allreduce(MPI_IN_PLACE,this%n_w,1,MPI_INT,MPI_MAX,this%client_comms,ierr)
        call MPI_Allreduce(MPI_IN_PLACE,this%n_r,1,MPI_INT,MPI_MAX,this%client_comms,ierr)

        win_size = this%n_w*this%nx_w*this%nz_w*this%ny_w
        call MPI_WIN_ALLOCATE(win_size*sizeof(realnum), sizeof(realnum), MPI_INFO_NULL, this%client_comms, tmp_ptr, this%write_win)

        win_size = this%n_r*this%nx_r*this%nz_r*this%ny_r
        call MPI_WIN_ALLOCATE(win_size*sizeof(realnum), sizeof(realnum), MPI_INFO_NULL, this%client_comms, tmp_ptr, this%read_win)
    
    end subroutine setup_MPI_windows

    subroutine setup_MPI_types(this)
        class(ioserver_t),   intent(inout)  :: this

        integer :: i

        allocate(this%get_types(this%n_children))
        allocate(this%put_types(this%n_children))
        allocate(this%child_get_types(this%n_children))
        allocate(this%child_put_types(this%n_children))

        do i = 1,this%n_children
            ! +2 included to account for staggered grids for output variables
            call MPI_Type_create_subarray(4, [this%n_w, (this%i_e_w-this%i_s_w+2), (this%k_e_w-this%k_s_w+1), (this%j_e_w-this%j_s_w+2)], &
                [this%n_w, (this%iewc(i)-this%iswc(i)+2), (this%kewc(i)-this%kswc(i)+1), (this%jewc(i)-this%jswc(i)+2)], &
                [0,0,0,0], MPI_ORDER_FORTRAN, MPI_REAL, this%get_types(i))

            call MPI_Type_create_subarray(4, [this%n_r, (this%i_e_r-this%i_s_r+1), (this%k_e_r-this%k_s_r+1), (this%j_e_r-this%j_s_r+1)], &
                [this%n_r, (this%ierc(i)-this%isrc(i)+1), (this%kerc(i)-this%ksrc(i)+1), (this%jerc(i)-this%jsrc(i)+1)], &
                [0,0,0,0], MPI_ORDER_FORTRAN, MPI_REAL, this%put_types(i))

            call MPI_Type_create_subarray(4, [this%n_w, this%nx_w, this%nz_w, this%ny_w], &
                [this%n_w, (this%iewc(i)-this%iswc(i)+2), (this%kewc(i)-this%kswc(i)+1), (this%jewc(i)-this%jswc(i)+2)], &
                [0,0,0,0], MPI_ORDER_FORTRAN, MPI_REAL, this%child_get_types(i))

            call MPI_Type_create_subarray(4, [this%n_r, this%nx_r, this%nz_r, this%ny_r], &
                [this%n_r, (this%ierc(i)-this%isrc(i)+1), (this%kerc(i)-this%ksrc(i)+1), (this%jerc(i)-this%jsrc(i)+1)], &
                [0,0,0,0], MPI_ORDER_FORTRAN, MPI_REAL, this%child_put_types(i))

            call MPI_Type_commit(this%get_types(i))
            call MPI_Type_commit(this%put_types(i))
            call MPI_Type_commit(this%child_get_types(i))
            call MPI_Type_commit(this%child_put_types(i))
        enddo
    end subroutine setup_MPI_types

    subroutine init_with_clients(this)
        class(ioserver_t),   intent(inout)  :: this
        integer :: n, comm_size
                        
        type(MPI_Group) :: family_group

        !get number of clients on this communicator
        call MPI_Comm_size(this%client_comms, comm_size)
        ! don't forget about oursevles
        this%n_children = comm_size - 1

        n = 0

        allocate(this%iswc(this%n_children))
        allocate(this%iewc(this%n_children))
        allocate(this%kswc(this%n_children))
        allocate(this%kewc(this%n_children))
        allocate(this%jswc(this%n_children))
        allocate(this%jewc(this%n_children))
        allocate(this%isrc(this%n_children))
        allocate(this%ierc(this%n_children))
        allocate(this%ksrc(this%n_children))
        allocate(this%kerc(this%n_children))
        allocate(this%jsrc(this%n_children))
        allocate(this%jerc(this%n_children))

        call MPI_Gather(n, 0, MPI_INTEGER, this%iswc, 1, MPI_INTEGER, kNUM_PROC_PER_NODE-1, this%client_comms)
        call MPI_Gather(n, 0, MPI_INTEGER, this%iewc, 1, MPI_INTEGER, kNUM_PROC_PER_NODE-1, this%client_comms)
        call MPI_Gather(n, 0, MPI_INTEGER, this%kswc, 1, MPI_INTEGER, kNUM_PROC_PER_NODE-1, this%client_comms)
        call MPI_Gather(n, 0, MPI_INTEGER, this%kewc, 1, MPI_INTEGER, kNUM_PROC_PER_NODE-1, this%client_comms)
        call MPI_Gather(n, 0, MPI_INTEGER, this%jswc, 1, MPI_INTEGER, kNUM_PROC_PER_NODE-1, this%client_comms)
        call MPI_Gather(n, 0, MPI_INTEGER, this%jewc, 1, MPI_INTEGER, kNUM_PROC_PER_NODE-1, this%client_comms)
        call MPI_Gather(n, 0, MPI_INTEGER, this%isrc, 1, MPI_INTEGER, kNUM_PROC_PER_NODE-1, this%client_comms)
        call MPI_Gather(n, 0, MPI_INTEGER, this%ierc, 1, MPI_INTEGER, kNUM_PROC_PER_NODE-1, this%client_comms)
        call MPI_Gather(n, 0, MPI_INTEGER, this%ksrc, 1, MPI_INTEGER, kNUM_PROC_PER_NODE-1, this%client_comms)
        call MPI_Gather(n, 0, MPI_INTEGER, this%kerc, 1, MPI_INTEGER, kNUM_PROC_PER_NODE-1, this%client_comms)
        call MPI_Gather(n, 0, MPI_INTEGER, this%jsrc, 1, MPI_INTEGER, kNUM_PROC_PER_NODE-1, this%client_comms)
        call MPI_Gather(n, 0, MPI_INTEGER, this%jerc, 1, MPI_INTEGER, kNUM_PROC_PER_NODE-1, this%client_comms)

        call MPI_Comm_Group(this%client_comms,family_group)
        call MPI_Comm_rank(this%client_comms,n)

        call MPI_Group_Excl(family_group,1,[n],this%children_group)

        allocate(this%children_ranks(this%n_children))

        do n = 1,this%n_children
            this%children_ranks(n) = n-1
        enddo

        this%i_s_r = minval(this%isrc)
        this%i_e_r = maxval(this%ierc)
        this%i_s_w = minval(this%iswc)
        this%i_e_w = maxval(this%iewc)

        this%j_s_r = minval(this%jsrc)
        this%j_e_r = maxval(this%jerc)
        this%j_s_w = minval(this%jswc)
        this%j_e_w = maxval(this%jewc)
        
        this%k_s_r = minval(this%ksrc)
        this%k_e_r = maxval(this%kerc)
        this%k_s_w = minval(this%kswc)
        this%k_e_w = maxval(this%kewc)

    end subroutine init_with_clients
    
    ! This subroutine gathers the write buffers of its children 
    ! compute processes and then writes them to the output file
    module subroutine write_file(this, time)
        implicit none
        class(ioserver_t), intent(inout)  :: this
        type(Time_type),  intent(in)      :: time

        integer :: i, nx, ny, i_s_w, i_e_w, j_s_w, j_e_w, msg_size
        INTEGER(KIND=MPI_ADDRESS_KIND) :: disp
        msg_size = 1
        disp = 0

        this%parent_write_buffer = kEMPT_BUFF

            ! Do MPI_Win_Start on write_win to initiate get
        call MPI_Win_Start(this%children_group,0,this%write_win)

        ! Loop through child images and send chunks of buffer array to each one
        do i=1,this%n_children
            call MPI_Get(this%parent_write_buffer(:,this%iswc(i),:,this%jswc(i)), msg_size, &
                this%get_types(i), this%children_ranks(i), disp, msg_size, this%child_get_types(i), this%write_win)
        enddo
            ! Do MPI_Win_Complete on write_win to end get
        call MPI_Win_Complete(this%write_win)

        call this%outputer%save_out_file(time,this%IO_comms,this%out_var_indices,this%rst_var_indices)        

    end subroutine 

    
    ! This subroutine calls the read file function from the input object
    ! and then passes the read-in data to the read buffer
    module subroutine read_file(this)
        class(ioserver_t), intent(inout) :: this

        real, allocatable, dimension(:,:,:,:) :: parent_read_buffer
        integer :: i, nx, ny, msg_size
        INTEGER(KIND=MPI_ADDRESS_KIND) :: disp

        msg_size = 1
        disp = 0

        ! read file into buffer array
        call this%reader%read_next_step(parent_read_buffer,this%IO_comms)
        this%files_to_read = .not.(this%reader%eof)

        ! Do MPI_Win_Start on read_win to initiate put
        call MPI_Win_Start(this%children_group,0,this%read_win)

        ! Loop through child images and send chunks of buffer array to each one
        do i=1,this%n_children
            call MPI_Put(parent_read_buffer(:,this%isrc(i),:,this%jsrc(i)), msg_size, &
                this%put_types(i), this%children_ranks(i), disp, msg_size, this%child_put_types(i), this%read_win)
        enddo
        ! Do MPI_Win_Complete on read_win to end put
        call MPI_Win_Complete(this%read_win)

    end subroutine 

    ! Same as above, but for restart file
    module subroutine read_restart_file(this, options)
        class(ioserver_t),   intent(inout) :: this
        type(options_t),     intent(in)    :: options

        integer :: i, n, nx, ny, i_s_w, i_e_w, j_s_w, j_e_w
        integer :: ncid, var_id, dimid_3d(4), nz, err, varid, start_3d(4), cnt_3d(4), start_2d(3), cnt_2d(3), msg_size
        INTEGER(KIND=MPI_ADDRESS_KIND) :: disp
        real, allocatable :: data3d(:,:,:,:)
        type(variable_t)  :: var
        character(len=kMAX_NAME_LENGTH) :: name

        msg_size = 1
        disp = 0

        err = nf90_open(options%io_options%restart_in_file, IOR(nf90_nowrite,NF90_NETCDF4), ncid, &
                comm = this%IO_comms%MPI_VAL, info = MPI_INFO_NULL%MPI_VAL)
        
        ! setup start/count arrays accordingly
        start_3d = (/ this%i_s_w,this%j_s_w,this%k_s_w,options%io_options%restart_step_in_file /)
        start_2d = (/ this%i_s_w,this%j_s_w,options%io_options%restart_step_in_file /)
        cnt_3d = (/ (this%i_e_w-this%i_s_w+1),(this%j_e_w-this%j_s_w+1),(this%k_e_w-this%k_s_w+1),1 /)
        cnt_2d = (/ (this%i_e_w-this%i_s_w+1),(this%j_e_w-this%j_s_w+1),1 /)

        this%parent_write_buffer = kEMPT_BUFF

        do i = 1,size(this%rst_var_indices)
            n = this%rst_var_indices(i)
            name = this%rst_var_names(i)
            var = get_metadata(get_varindx(name))
            
            call check_ncdf( nf90_inq_varid(ncid, name, var_id), " Getting var ID for "//trim(name))
            call check_ncdf( nf90_var_par_access(ncid, var_id, nf90_collective))
            
            
            nx = cnt_3d(1) + var%xstag
            ny = cnt_3d(2) + var%ystag

            if (var%three_d) then
                ! Get length of z dim
                call check_ncdf( nf90_inquire_variable(ncid, var_id, dimids = dimid_3d), " Getting dim IDs for "//trim(name))
                call check_ncdf( nf90_inquire_dimension(ncid, dimid_3d(3), len = nz), " Getting z dim len for "//trim(name))
                
                if (allocated(data3d)) deallocate(data3d)
                allocate(data3d(nx,ny,nz,1))
                call check_ncdf( nf90_get_var(ncid, var_id, data3d, start=start_3d, count=(/ nx, ny, nz /)), " Getting 3D var "//trim(name))

                this%parent_write_buffer(n,this%i_s_w:this%i_e_w+var%xstag,1:nz,this%j_s_w:this%j_e_w+var%ystag) = &
                        reshape(data3d(:,:,:,1), shape=[nx,nz,ny], order=[1,3,2])
            else if (var%two_d) then
                call check_ncdf( nf90_get_var(ncid, var_id, this%parent_write_buffer(n,this%i_s_w:this%i_e_w+var%xstag,1,this%j_s_w:this%j_e_w+var%ystag), &
                        start=start_2d, count=(/ nx, ny /)), " Getting 2D "//trim(name))
            endif
        end do
        
        call check_ncdf(nf90_close(ncid), "Closing file "//trim(options%io_options%restart_in_file))
        
        ! Because this is for reading restart data, performance is not critical, and 
        ! we use a simple MPI_fence syncronization
        call MPI_Win_fence(0,this%write_win)

        ! Loop through child images and send chunks of buffer array to each one
        do i=1,this%n_children
            !Note that the MPI datatypes here are reversed since we are working with the write window
            call MPI_Put(this%parent_write_buffer(:,this%iswc(i),:,this%jswc(i)), msg_size, &
                this%get_types(i), this%children_ranks(i), disp, msg_size, this%child_get_types(i), this%write_win)
        enddo
        call MPI_Win_fence(0,this%write_win)

    end subroutine 


    ! This function closes all open file handles. Files are left open by default
    ! to minimize I/O calls. When the program exits, this must be called
    module subroutine close_files(this)
        class(ioserver_t), intent(inout) :: this
        
        this%creating = .false.
        
        ! close files
        call this%reader%close_file()
        call this%outputer%close_files()

    end subroutine 
    
end submodule
