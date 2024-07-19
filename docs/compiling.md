## Compiling ICAR

Edit the makefile to set the path to your compiled NetCDF and FFTW libraries

Also to set the compiler for your machine if necessary (defaults to gfortran)

    make clean
         # remove build by-products

    make
         # default (relatively high) optimization compile

    make install
        # compile if necessary, then install in the install directory [~/bin]

### Options:
    MODE=fast           # more optimization, slower compile, WARNING:not safe optimizations
    MODE=profile        # set profiling options for gnu or intel compilers
    MODE=debug          # debug compile with optimizations
    MODE=debugslow      # debug compile w/o optimizations
    MODE=debugomp       # debug compile with optimizations and OpenMP parallelization
    MODE=debugompslow   # debug compile w/o optimizations but with OpenMP parallelization

    make doc
    # build doxygen documentation in docs/html

    make test
        # compiles various test programs (mpdata_test, fftshift_test, and calendar_test)

    add -jn to parallelize the compile over n processors

### Example:
    make install MODE=debug -j4  # uses 4 processes to compile in debug mode


### Example of how to compile on daint machine in CSCS:
    
	For gnu:

	rm -rf build/*; make cleanall; make COMPILER=gnu -j 36 PETSC_DIR=$HOME FSM_DIR=$HOME CAF_DIR=$HOME/OpenCoarrays/src/mpi ; make install

	note that the version of OpenCoarrays:
		commit 52b1dd35ef27d5f21b0ef4775127f4f975ddec75 (HEAD -> master, origin/master, origin/HEAD)
		Merge: 15dc8c3 8318f9e
		Author: Damian Rouson <damian@sourceryinstitute.org>
		Date:   Tue Feb 4 22:22:16 2020 -0600

	For cray:
	rm -rf build/*; make cleanall; make COMPILER=cray -j 36 FSM_DIR=$HOME; make install
