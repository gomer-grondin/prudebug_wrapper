# prudebug_wrapper
wrapper for prudebug v.25 .. in perl WIP

NOTE -- does not yet support beaglebone AI, ONLY supports beaglebone black

Features not found in v.25
*	readline support
*	output to multiple windows
*	context sensitive disassemble report
*	dump format includes decimal values

Required software
*	daemontools ( cr.yp.to/daemontools.html ) 
	*	excellent tool by DJB
*	ncat -- ( https://nmap.org/ncat/ )
	* NOT 'netcat'
*	Perl
	*	Term::Readline

	
daemontools code
*	2 services
	*	ncatPRUDEBUG
		*	mknod /var/local/PRUDEBUG.pipe p
		*	run script
			*	#!/bin/sh
			*	exec 1>> /var/local/PRUDEBUG.pipe
			*	exec ncat -k -l localhost 32768
		*	log script
			*	#!/bin/sh
			*	exec multilog t ./main
	*	PRUDEBUG
		*	run script
			*	#!/bin/sh
			*	exec 0< /var/local/PRUDEBUG.pipe
			*	exec /usr/local/bin/prudebug
		*	log script
			*	#!/bin/sh
			*	exec multilog t ./main


use your (burly) laptop or desktop to ssh into multiple windows.
The more real estate the better.  position and size your windows to taste. 
for the files you'd like to monitor, it is as simple as 'watch "cat $filename"' in your window

current output supported:
*	gomer@bbb42:~/ti_pru/prudebug-0.25$ find /dev/shm
*	/dev/shm
*	/dev/shm/shared
*	/dev/shm/shared/datadump
*	/dev/shm/PRU1
*	/dev/shm/PRU1/register
*	/dev/shm/PRU1/datadump
*	/dev/shm/PRU1/disassemble
*	/dev/shm/PRU0
*	/dev/shm/PRU0/datadump
*	/dev/shm/PRU0/disassemble
*	/dev/shm/PRU0/register
*	gomer@bbb42:~/ti_pru/prudebug-0.25$ 

disassemble report is coordinated with program counter and updates as you execute 'ss' command.  If you inform the wrapper of your source code, it will also
replace some of your symbolic substitutions (.asg commands)... (still WIP for 
complete support and symbol table entries)

with any Perl skill at all, you can customize dump format, etc..  without
further modifications to V.25.

What I modified to V.25 :
*	Makefile
	*	install :
		*	sudo cp ./prudebug /usr/local/bin
*	cmdinput.c
	*	fflush( stdout );
		* necessary for timely access to output

I've included the prudebug executable... 
*	compiled on my BBB should work on yours (not necessary to recompile)

Invocation:
*	 I suggest a copy of wrapper.pl in your source directory
*	 chmod 755 ./wrapper.pl
*	 ./wrapper.pl

So far only two 'custom' commands ... 
*	'load' will look at your source code and
	*	build a hash of symbolic substitutions and 
	*	use it in your disassemble report.
*	'unload' will do the reverse.

*	gomer@bbb42:~/prudebug_wrapper$ cat /etc/dogtag
*	BeagleBoard.org Debian Image 2018-10-07
*	gomer@bbb42:~/prudebug_wrapper$ 

update 9/15/22

No longer track breakpoints within the wrapper ... breakpoints and watchpoints
are reported in the invocation window

help and hb reported in invocation window

output from several commands ( r, dis, ss )  no longer echoed to invocation
 window.  there is a new sub 'command_echo' that controls this.


