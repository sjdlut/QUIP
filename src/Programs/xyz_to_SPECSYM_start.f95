! H0 XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
! H0 X
! H0 X   libAtoms+QUIP: atomistic simulation library
! H0 X
! H0 X   Portions of this code were written by
! H0 X     Albert Bartok-Partay, Silvia Cereda, Gabor Csanyi, James Kermode,
! H0 X     Ivan Solt, Wojciech Szlachta, Csilla Varnai, Steven Winfield.
! H0 X
! H0 X   Copyright 2006-2010.
! H0 X
! H0 X   These portions of the source code are released under the GNU General
! H0 X   Public License, version 2, http://www.gnu.org/copyleft/gpl.html
! H0 X
! H0 X   If you would like to license the source code under different terms,
! H0 X   please contact Gabor Csanyi, gabor@csanyi.net
! H0 X
! H0 X   Portions of this code were written by Noam Bernstein as part of
! H0 X   his employment for the U.S. Government, and are not subject
! H0 X   to copyright in the USA.
! H0 X
! H0 X
! H0 X   When using this software, please cite the following reference:
! H0 X
! H0 X   http://www.libatoms.org
! H0 X
! H0 X  Additional contributions by
! H0 X    Alessio Comisso, Chiara Gattinoni, and Gianpietro Moras
! H0 X
! H0 XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

program xyz_to_SPECSYM_start
use libatoms_module
implicit none
  type(Atoms) :: at
  integer i
  real(dp) :: dipole_mom(3)

  call system_initialise()
  call read(at, "stdin")


  mainlog%prefix = "SPECSYM"

  call print(at%N//" 0.02 0.005 0.0 0.0")
  call print("300.0 0.0 1 6.0")
  do i=1, at%N
    call print(ElementMass(at%Z(i))/MASSCONVERT)
  end do
  call print("0.0 0")
  do i=1, at%N
    call print (at%pos(:,i)/BOHR // " " // at%Z(i) // " " // at%Z(i))
    call print ("0.0 0.0 0.0")
  end do

  if (.not. get_value(at%params, 'Dipole_Moment', dipole_mom)) dipole_mom = 0.0_dp

  call print (dipole_mom/BOHR)
  call print ("0.0 0.0 0.0")

  mainlog%prefix = ""

  call system_finalise()
end program
