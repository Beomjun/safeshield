# shellcheck shell=sh

Describe 'SafeShield shell regression suite'
	Parameters:dynamic
		for test_file in tests/test_*.sh; do
			%data "$test_file"
		done
	End

	It "passes $1"
		When run script "$1"
		The status should be success
		The output should not equal ''
		The error should equal ''
	End
End
