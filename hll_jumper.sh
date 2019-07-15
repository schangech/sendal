#!/usr/bin/expect

set timeout 5

set mfaCode [lindex $argv 0]

spawn ssh -o ServerAliveInterval=30 -p 2222 suqirui@go.hualala.com -A

expect "*MFA auth]:" { send "$mfaCode\n" }

interact
