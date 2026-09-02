# shellcheck shell=sh

Describe 'SafeShield runtime process behavior'
	It 'interrupts refreshd long sleeps without one-second polling'
		When call ss_case_refreshd_wait
		The status should be success
		The output should equal ''
		The error should equal ''
	End

	It 'starts and stops the statistics collector cleanly'
		When call ss_case_statistics_collector
		The status should be success
		The output should equal ''
		The error should equal ''
	End

	It 'reconciles statistics runtime without disturbing refreshd'
		When call ss_case_statistics_reconcile
		The status should be success
		The output should equal ''
		The error should equal ''
	End
End
