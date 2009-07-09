!
! Calculates density of a certain element in 1D around the origin
!

program density_1d

    use libatoms_module

    implicit none

    integer, parameter                    :: DISTANCES_INIT = 1000000
    integer, parameter                    :: DISTANCES_INCR = 1000000

    type(atoms_ll)                        :: structure_ll
    type(atoms_ll_entry), pointer         :: structure_ll_entry
    type(Atoms), pointer                  :: structure
    type(Atoms)                           :: structure_in
    type(Table)                           :: distances, atom_table
    real(dp)                              :: d
    type(Inoutput)                        :: xyzfile, datafile, xyzfile_list
    type(CInoutput)                       :: cxyzfile
    integer                               :: frame_count, frames_processed, frames_processed_intermed
    integer                               :: status
    integer                               :: i, j

    !Input
    type(Dictionary)                      :: params_in
    character(FIELD_LENGTH)               :: xyzfilename, datafilename
    logical                               :: xyzfile_is_list
    real(dp)                              :: cutoff, bin_width
    character(FIELD_LENGTH)               :: mask
    integer                               :: IO_Rate, Density_Time_Evolution_Rate
    integer                               :: decimation
    integer                               :: from, to
    real(dp)                              :: min_time, max_time
    logical                               :: Gaussian_smoothing
    real(dp)                              :: Gaussian_sigma
    logical                               :: fortran_io

    !AtomMask processing
    character(30)                         :: prop_name
    logical                               :: list, prop
    integer                               :: prop_val
    integer                               :: Zb

    !Histogram & its integration/normalisation
    real(dp), allocatable, dimension(:,:) :: data, data_intermed
    real(dp), allocatable, dimension(:)   :: hist, hist_sum, hist_sum_intermed
    integer                               :: num_bins, num_atoms
    real(dp)                              :: hist_int, hist_int_intermed
    real(dp)                              :: density, r, dV
    logical :: first_time, skip_frame
    integer :: last_file_frame_n
    real(dp) :: cur_time


  !Start up LOTF, suppressing messages
    call system_initialise(NORMAL)

#ifdef DEBUG
    call print('********** DEBUG BUILD **********')
    call print('')
#endif

    call initialise(params_in)
    call param_register(params_in, 'xyzfile', param_mandatory, xyzfilename)
    call param_register(params_in, 'xyzfile_is_list', 'F', xyzfile_is_list)
    call param_register(params_in, 'datafile', 'data.den1', datafilename)
    call param_register(params_in, 'AtomMask', param_mandatory, mask)
    call param_register(params_in, 'Cutoff', param_mandatory, cutoff)
    call param_register(params_in, 'BinWidth', param_mandatory, bin_width)
    call param_register(params_in, 'decimation', '1', decimation)
    call param_register(params_in, 'min_time', '-1.0', min_time)
    call param_register(params_in, 'max_time', '-1.0', max_time)
    call param_register(params_in, 'from', '0', from)
    call param_register(params_in, 'to', '0', to)
    call param_register(params_in, 'IO_Rate', '1', IO_Rate)
    call param_register(params_in, 'Density_Time_Evolution_Rate', '0', Density_Time_Evolution_Rate)
    call param_register(params_in, 'Gaussian', 'F', Gaussian_smoothing)
    call param_register(params_in, 'sigma', '0.0', Gaussian_sigma)
    call param_register(params_in, 'fortran_io', 'F', fortran_io)
    if (.not. param_read_args(params_in, do_check = .true.)) then
       if (EXEC_NAME == '<UNKNOWN>') then
          call print_usage
       else
          call print_usage(EXEC_NAME)
       end if
      call system_abort('could not parse argument line')
    end if
    call finalise(params_in)

    call print('Run_parameters: ')
    call print('==================================')
    call print('         Input file: '//trim(xyzfilename))
    call print(' Input file is list: '//xyzfile_is_list)
    call print('        Output file: '//trim(datafilename))
    call print('           AtomMask: '//trim(mask))
    call print('             Cutoff: '//round(Cutoff,3))
    call print('           BinWidth: '//round(bin_width,3))
    call print('         decimation: '//decimation)
    if (decimation == 1) then
       call print('             Processing every frame')
    else
       write(line,'(a,i0,a,a)')'             Processing every ',decimation,th(decimation),' frame'
       call print(line)
    end if
    call print('    from Frame: '//from)
    call print('      to Frame: '//to)
    call print('       IO_Rate: '//IO_Rate)
    call print('       Density_Time_Evolution_Rate: '//Density_Time_Evolution_Rate)
    if (IO_Rate > 0 .and. Density_Time_Evolution_Rate > 0) then
      call print('WARNING: IO_Rate = ' // IO_Rate // ' will effectively override Density_Time_Evolution_Rate='//Density_Time_Evolution_Rate, ERROR)
    endif
    call print('     Gaussians: '//Gaussian_smoothing)
    if (Gaussian_smoothing) call print('        sigma: '//round(Gaussian_sigma,3))
    call print('==================================')
    call print('')

    !
    ! Read the element symbol / atom mask
    !
    call print('Mask 2:')
    call print('=======')
    if (mask(1:1)=='@') then
       list = .true.
       prop = .false.
       call parse_atom_mask(mask,atom_table)
    else if (scan(mask,'=')/=0) then
       list = .true.
       prop = .true.
       call get_prop_info(mask, prop_name, prop_val)
       call print('')
       call print('Selecting all atoms that have '//trim(prop_name)//' set to '//prop_val)
       call print('')
    else
       list = .false.
       prop = .false.
       Zb = Atomic_Number(mask)
       call print('')
       write(line,'(a,i0,a)')'Selecting all '//trim(ElementName(Zb))//' atoms (Z = ',Zb,')'
       call print(line)
       call print('')
    end if

    if (cutoff < 0.0_dp) call system_abort('Cutoff < 0.0 Angstroms')
    if (bin_width < 0.0_dp) call system_abort('Bin width < 0.0 Angstroms')
    if (Gaussian_smoothing.and.(Gaussian_sigma.le.0._dp)) call system_abort('sigma must be > 0._dp')

    !Make num_bins and bin_width consistent
    num_bins = ceiling(cutoff / bin_width)
    bin_width = cutoff / real(num_bins,dp)

    allocate( hist(num_bins), hist_sum(num_bins), hist_sum_intermed(num_bins), data(num_bins,3), data_intermed(num_bins,3) )

    hist = 0.0_dp
    hist_sum = 0.0_dp
    hist_int = 0.0_dp

    !Set up the x coordinates of the plot
    do i = 1, num_bins
       data_intermed(i,1) = (real(i,dp) - 0.5_dp) * bin_width
    end do
    data(:,1) = data_intermed(:,1)

    call print('')
    write(line,'(i0,a,f0.4,a,f0.4,a)') num_bins,' bins x ',bin_width,' Angstroms per bin = ',cutoff,' Angstroms cutoff'
    call print(line)
    call print('')

    call print('Reading data...')

    ! initialize frame counters
    frames_processed = 0
    frames_processed_intermed = 0


    if (fortran_io) then
      if (xyzfile_is_list) call system_abort("ERROR: xyzfile_is_list is not supported with fortran I/O")
      call initialise(xyzfile,xyzfilename,action=INPUT)
      status = 0
      frame_count = 0
      do while (frame_count < from-1)
        frame_count = frame_count + 1
        call read_xyz(xyzfile,status)
        if (status/=0) exit
      end do
  
      ! read rest of configs, skipping decimation related ones, put in structure_ll
      do while (status == 0 .and. (to <= 0 .or. frame_count < to))
        frame_count = frame_count + 1
        write(mainlog%unit,'(a,a,i0,$)') achar(13),'Read Frame ',frame_count
        call read_xyz(structure_in, xyzfile, status=status)
	skip_frame = .false.
	if (min_time > 0.0_dp .or. max_time > 0.0_dp) then
	  if (get_value(structure_in%params,"Time",cur_time)) then
	    if (cur_time < min_time .or. cur_time > max_time) skip_frame = .true.
	  else
	    call system_abort("ERROR: min_time="//min_time//" > 0.0 or max_time="//max_time//" > 0.0, but Time field wasn't found in config " // frame_count)
	  endif
	endif
	if (.not. skip_frame) then
	  call new_entry(structure_ll, structure)
	  call atoms_copy_without_connect(structure, structure_in, properties="pos:Z")
	endif
        if (to > 0 .and. frame_count >= to) then
	  exit
        endif
  
        do i=1, (decimation-1)
  	frame_count = frame_count + 1
  	call read_xyz(xyzfile, status)
  	if (status /= 0) exit
        end do
      end do
  
      if (status /= 0) then
        call remove_last_entry(structure_ll)
      endif

      call finalise(xyzfile)

    else ! not fortran I/O, i.e. C

      if (from > 0) then
	frame_count = from
      else
	frame_count = 1
      endif
      last_file_frame_n = 0

      if (xyzfile_is_list) then
	call initialise(xyzfile_list, trim(xyzfilename), INPUT)
	xyzfilename = read_line(xyzfile_list, status)
	if (status /= 0) call finalise(xyzfile_list)
      endif

      do while (status == 0) ! loop over files
	call initialise(cxyzfile,trim(xyzfilename),action=INPUT)
	status = 0
	do while ((to <= 0 .or. frame_count <= to) .and. status == 0)
	  write(mainlog%unit,'(4a,i0,a,i0,$)') achar(13), 'Read file ',trim(xyzfilename), ' Frame ',frame_count,' which in this file is frame (zero based) ',(frame_count-1-last_file_frame_n)
	  call read(cxyzfile, structure_in, frame=frame_count-1-last_file_frame_n, status=status)
	  if (status == 0) then
	    skip_frame = .false.
	    if (min_time > 0.0_dp .or. max_time > 0.0_dp) then
	      if (get_value(structure_in%params,"Time",cur_time)) then
		if (cur_time < min_time .or. cur_time > max_time) skip_frame = .true.
	      else
		call system_abort("ERROR: min_time="//min_time//" > 0 but Time field wasn't found in config " // frame_count)
	      endif
	    endif
	    if (.not. skip_frame) then
	      call new_entry(structure_ll, structure)
	      call atoms_copy_without_connect(structure, structure_in, properties="pos:Z")
	    else
	      write (mainlog%unit,'(a,$)') " skip"
	    endif
	    frame_count = frame_count + decimation
	  endif
	end do
	last_file_frame_n = frame_count - 1
	call finalise(cxyzfile)

	if (xyzfile_is_list) then
	  xyzfilename = read_line(xyzfile_list, status)
	  if (status /= 0) call finalise(xyzfile_list)
	else
	  status = 1
	endif

      end do

    endif ! fortran I/O

    call allocate(distances,0,1,0,0,DISTANCES_INIT)
    call set_increment(distances,DISTANCES_INCR)

    first_time=.true.

    structure_ll_entry => structure_ll%first

    frame_count = from
    if (min_time > 0.0_dp) call print("WARNING: min_time > 0, frame_count will be wrong if frames were skipped", ERROR)

    do while (associated(structure_ll_entry))

       structure => structure_ll_entry%at

       write(mainlog%unit,'(a,a,i0,$)') achar(13),'Processing Frame ',frame_count

	if (prop) call list_matching_prop(structure,atom_table,trim(prop_name),prop_val)

	call wipe(distances)

	num_atoms = 0

	hist = 0.0_dp
	do j = 1, structure%N

	   !Count the atoms
	   if (list) then
	      if (find(atom_table,j)/=0) num_atoms = num_atoms + 1
	   else
	      if (structure%Z(j) == Zb) num_atoms = num_atoms + 1
	   end if

	   !Do we have a "Mask" atom? Cycle if not
	   if (list) then
	      if (find(atom_table,j)==0) cycle
	   else
	      if (structure%Z(j) /= Zb) cycle
	   end if

	   d = distance_min_image(structure,j,(/0._dp,0._dp,0._dp/))
	   if (d < cutoff+3.0*Gaussian_sigma) then
#ifdef DEBUG
	      call print('Storing distance (/0,0,0/)--'//j//' = '//round(d,5)//'A')
#endif
	      !Add this distance to the list
	      call accum_histogram(hist, d, 0.0_dp, cutoff, num_bins, Gaussian_smoothing, Gaussian_sigma)
	   end if
	end do


	frames_processed = frames_processed + 1
	frames_processed_intermed = frames_processed_intermed + 1

#ifdef DEBUG
	call print('Number of atoms = '//num_atoms)
#endif

	!Calculate B atom density
	density = real(num_atoms,dp) / cell_volume(structure)

	!Normalise histogram
	do i = 1, num_bins
	   r = (real(i,dp) - 1._dp) * bin_width
	   dV = 4.0_dp * PI * (r*r + r*bin_width + bin_width*bin_width/3.0_dp ) * bin_width
	   hist(i) = hist(i) / (dV * density * 1._dp)
	end do

	!Accumulate the data
	hist_sum = hist_sum + hist
	hist_sum_intermed = hist_sum_intermed + hist

	!copy the current averages into the y coordinates of the plot
	data(:,2) = hist_sum / real(frames_processed,dp)
	data_intermed(:,2) = hist_sum_intermed / real(frames_processed_intermed,dp)

	!integrate the average data
	hist_int = 0.0_dp
	hist_int_intermed = 0.0_dp
	do i = 1, num_bins
	   r = data(i,1)
	   dV = PI * (4.0_dp * r*r + bin_width*bin_width/3.0_dp) * bin_width
	   hist_int = hist_int + data(i,2)*dV*density
	   data(i,3) = hist_int
	   hist_int_intermed = hist_int_intermed + data_intermed(i,2)*dV*density
	   data_intermed(i,3) = hist_int_intermed
	end do

	if (Density_Time_Evolution_Rate > 0) then
	  if (mod(frames_processed,Density_Time_Evolution_Rate)==0) then
	     if (first_time) then
	       call initialise(datafile,datafilename,action=OUTPUT)
	       first_time = .false.
	     else
	       call initialise(datafile,datafilename,action=OUTPUT,append=.true.)
	       call print('',file=datafile)
	       call print('',file=datafile)
	     endif
	     call print('# Density 1D',file=datafile)
	     call print('# Input file: '//trim(xyzfilename),file=datafile)
	     call print('#      Frames read = '//frame_count,file=datafile)
	     call print('# Frames processed = '//frames_processed,file=datafile)
	     call print(data_intermed,file=datafile)
	     call finalise(datafile)
	     hist_sum_intermed = 0.0_dp
	     frames_processed_intermed = 0.0_dp
	  endif
	endif

	!Write the current data. This allows the user to Ctrl-C after a certain number
	!of frames if things are going slowly
	if (IO_Rate > 0) then
	  if (mod(frames_processed,IO_Rate)==0) then
	     call initialise(datafile,datafilename,action=OUTPUT)
	     call print('# Density 1D',file=datafile)
	     call print('# Input file: '//trim(xyzfilename),file=datafile)
	     call print('#      Frames read = '//frame_count,file=datafile)
	     call print('# Frames processed = '//frames_processed,file=datafile)
	     call print(data,file=datafile)
	     call finalise(datafile)
	  endif
	endif

       !Try to read another frame
       structure_ll_entry => structure_ll_entry%next
       frame_count = frame_count + decimation
  
    end do

    frame_count = frame_count - decimation

    if (Density_Time_Evolution_Rate > 0) then
      call initialise(datafile,datafilename,action=OUTPUT,append=.true.)
      call print('',file=datafile)
      call print('',file=datafile)
    else
      call initialise(datafile,datafilename,action=OUTPUT)
    endif
    call print('# Final Density 1D',file=datafile)
    call print('# Input file: '//trim(xyzfilename),file=datafile)
    call print('#      Frames read = '//frame_count,file=datafile)
    call print('# Frames processed = '//frames_processed,file=datafile)
    call print(data,file=datafile)
    call finalise(datafile)

    call print('')
    call print('Read '//frame_count//' frames, processed '//frames_processed//' frames.')

    !Free up memory
    call finalise(distances)
    call finalise(structure_in)
    call finalise(xyzfile)

    deallocate(hist, hist_sum, data)

    call print('Finished.')

    !call verbosity_pop
    call system_finalise

contains

  subroutine accum_histogram(hist, d, minx, maxx, num_bins, gaussian_smoothing, sigma)
    real(dp), intent(inout) :: hist(:)
    real(dp) :: d, minx, maxx
    integer :: num_bins
    logical :: gaussian_smoothing
    real(dp) :: sigma

    real(dp), allocatable :: hist_t(:)
    real(dp), allocatable :: d_a(:), w_a(:)
    real(dp) :: px, py, pz
    integer :: ix, iy, iz, io
    integer :: n_samples = 20
    real(dp) :: n_samples_d, normalization
    real(dp) :: range

    range = 3.0_dp*sigma
    normalization=((2.0*range/real(n_samples,dp))**3)/(sigma*sqrt(PI))**3

    n_samples_d = real(n_samples/2,dp)
    allocate(hist_t(size(hist)))

    if (gaussian_smoothing) then
      allocate(d_a((n_samples+1)**3))
      allocate(w_a((n_samples+1)**3))
      do ix=1, n_samples+1
      px = real(ix-1-(n_samples/2), dp)/n_samples_d*range
      do iy=1, n_samples+1
      py = real(iy-1-(n_samples/2), dp)/n_samples_d*range
      do iz=1, n_samples+1
      pz = real(iz-1-(n_samples/2), dp)/n_samples_d*range
	io = (ix-1)*(n_samples+1)**2 + (iy-1)*(n_samples+1) + (iz-1) + 1
	d_a(io) = sqrt((px+d)**2+py**2+pz**2)
	w_a(io) = normalization*exp(-(px**2+py**2+pz**2)/sigma**2)
      end do
      end do
      end do
      hist_t = histogram(d_a, minx, maxx, num_bins, weight_vector=w_a, drop_outside=.true.)
      deallocate(d_a)
      deallocate(w_a)
    else
      hist_t = histogram((/d/), minx, maxx, num_bins, drop_outside=.true.)
    endif
    hist = hist + hist_t
    deallocate(hist_t)

  end subroutine accum_histogram

  subroutine print_usage(name)

    character(*), optional, intent(in) :: name

    if (present(name)) then
       write(line,'(3a)')'Usage: ',trim(name),' xyzfile datafile AtomMask Cutoff BinWidth [decimation] [from] [to] [IO_Rate] [Gaussian] [sigma]'
    else
       write(line,'(a)')'Usage: density_1d xyzfile datafile AtomMask Cutoff BinWidth [decimation] [from] [to] [IO_Rate] [Gaussian] [sigma]'
    end if
    call print(line)
    call print(' <xyzfile>       The input xyz file.')
    call print(' <AtomMask>      An element symbol, e.g. H or Ca, or @ followed by a list of indices/ranges, e.g. @1-35,45,47,50-99 or property=value')
    call print(' <Cutoff>        The cutoff radius in Angstroms.')
    call print(' <BinWidth>      The width of each bin in Angstroms.')
    call print(' <datafile>      The output data file.')
    call print(' <decimation>    Optional. Only process 1 out of every n frames.')
    call print(' <from>          Optional. Only process frames from this frame.')
    call print(' <to>            Optional. Only process frames until this frame.')
    call print(' <IO_Rate>       Optional. Write data after every n processed frames.')
    call print(' <Density_Time_Evolution_Rate>  Optional. Compute separate densities for each n processed frames (overriden if IO_Rate > 0)')
    call print(' <Gaussian>      Optional. Use Gaussians instead of delta functions.')
    call print(' <sigma>         Optional. The sigma is the sqrt(variance) of the Gaussian function.')
    call print(' <fotran_io>     Optional. If true, use FORTRAN I/O.  Slower, but might not work for stdin otherwise')
    call print('')
    call print('Pressing Ctrl-C during execution will leave the output file with the rdf averaged over the frames read so far')
    call print('')

    !call verbosity_pop
    call system_finalise
    stop

  end subroutine print_usage

  subroutine get_prop_info(mask,name,value)

    character(*), intent(in)  :: mask
    character(*), intent(out) :: name
    integer,      intent(out) :: value
    integer                   :: delimiter

    delimiter = scan(mask,'=')
    if (delimiter > 1) then
       name = adjustl(mask(1:delimiter-1))
       value = string_to_int(mask(delimiter+1:len_trim(mask)))
    else
       call system_abort('Zero length property name in mask: "'//trim(mask)//'"')
    end if

  end subroutine get_prop_info

  subroutine list_matching_prop(at,list,name,value)

    type(atoms), intent(in)    :: at
    type(table), intent(inout) :: list
    character(*), intent(in)   :: name
    integer,     intent(in)    :: value

    integer                    :: i, pos_indices(3), index

    !find property
    if (get_value(at%properties,name,pos_indices)) then
       index = pos_indices(2)
    else
       call system_abort('Property "'//name//'" not found')
    end if

    call wipe(list)

    do i = 1, at%N

       if (at%data%int(index,i)==value) call append(list,(/i/))

    end do

  end subroutine list_matching_prop

  function Gaussian_histogram(vector,min_x,max_x,Nbin,Gaussian,sigma)

    real(dp), dimension(:), intent(in) :: vector
    real(dp),               intent(in) :: min_x, max_x
    integer,                intent(in) :: Nbin
    logical,       intent(in) :: Gaussian
    real(dp),      intent(in) :: sigma
    real(dp), dimension(Nbin)          :: Gaussian_histogram
    !local variables
    real(dp)                           :: binsize,min_bin,max_bin
    integer                            :: i, bin, j

    if(max_x <= min_x) then
       call system_abort('Vector_Histogram: max_x < min_x')
    end if

    binsize=(max_x-min_x)/(real(Nbin,dp))
    Gaussian_histogram = 0.0_dp

    do i=1,size(vector)
!       call print('')
!       call print('Distribution of vector '//i//' over the whole histogram:')

       if (Gaussian) then
!          if(.not.present(sigma)) call system_abort('Gaussian_histogram: Missing Gaussian sigma parameter.')
          do j=1,Nbin
             min_bin = min_x + real(j-1,dp) * binsize
             max_bin = min_bin + binsize
!             call print('min_bin: '//min_bin//', max_bin: '//max_bin)
!             call print('ERF(min_bin) = '//erf((vector(i)-min_bin)/(sigma*sqrt(2._dp))))
!             call print('ERF(max_bin) = '//erf((max_bin-vector(i))/(sigma*sqrt(2.0_dp))))
!             call print('Adding to bin '//j//' '//(erf((vector(i)-min_bin)/(sigma*sqrt(2._dp))) + erf((max_bin-vector(i))/(sigma*sqrt(2.0_dp)))))
             Gaussian_histogram(j) = Gaussian_histogram(j) - 0.5_dp*erf((min_bin-vector(i))/(sigma*sqrt(2._dp))) + 0.5_dp*erf((max_bin-vector(i))/(sigma*sqrt(2.0_dp)))
          enddo
       else
          bin = ceiling((vector(i)-min_x)/binsize)
          if (bin < 1) bin = 1
          if (bin > Nbin) bin = Nbin
          Gaussian_histogram(bin) = Gaussian_histogram(bin) + 1.0_dp
       endif
    end do

  end function Gaussian_histogram

end program density_1d
