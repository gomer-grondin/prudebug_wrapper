#!/usr/bin/perl
#
# wrapper.pl  -- prudebug running as daemon (cr.yp.to) on 32768
#

use warnings;
use strict;
use Term::ReadLine;

my $HOST = 'localhost';
open my $INPUT, "| ncat $HOST 32768" or die "unable : $!"; # input to daemon

my $program_counter = 0;
my $current_instruction = '';
my $shared12k = sprintf( "0x%X", 0x10000 / 4 );
my $logfile = '/service/PRUDEBUG/log/main/current';
my $sum_command = "cksum $logfile | awk '{print \$1}'";
my $active_pru = 'PRU0';
my $prompt = "prudebug_wrapper $active_pru > ";
my ( $m4, $load, $breakpoints, $watchpoints, $watchvalues, $registers, $disassemble, $datadump, $symtab ) = 
   ( {}, {}, {}, {}, {}, {}, {}, {}, {} );

my $funtab;
$funtab = {
	ss	=> sub {
			my $output = [];
			communicate( $_[0], $output ) ;
			$funtab->{r}( 'r' );
			register_report();
			disassemble_report();
		},
	br	=> sub {
			my $output = [];
			communicate( $_[0], $output ) ;
			my @input = split( /\s+/, $_[0] );
			if( @input == 1 ) {
				breakpoint_report( $output );
			}
			if( @input == 2 ) {
				my $ap = $active_pru;
				$breakpoints->{$ap}{$input[1]} = undef;
				$funtab->{br}( 'br' );
			}
			if( @input == 3 ) {
				my $ap = $active_pru;
				$breakpoints->{$ap}{$input[1]} = $input[2];
				$funtab->{br}( 'br' );
			}
		},
	dis	=> sub {
			$funtab->{r}( 'r' );
			my $output = [];
			communicate( $_[0], $output ) ;
			for ( @$output ) {
				if( /^\[0x(\S+)\]\s+0x\S+\s+(.*)$/i ) {
					my ( $o, $i ) = ( $1, $2 );
					my $addr = sprintf( "%d", hex $o );
					$disassemble->{$active_pru}{$addr} = $i;
				}
			}
			register_report();
			disassemble_report();
		},
	dd	=> sub {
			my $output = [];
			communicate( $_[0], $output ) ;
			for ( @$output ) {
				if( /^\[(0x\S+)\]\s+0x\S+\s+0x\S+\s+/i ) {
					datadump( $_[0], $output );
					last;
				}
			}
		},
	d	=> sub { $funtab->{dd}($_[0]); },
	load	=> sub {
			my @input = split( /\s+/, $_[0] );
			if( @input == 1 ) { load_report(); }
			if( @input == 2 ) { load( $_[0] ); }
		},
	unload	=> sub {
			my @input = split( /\s+/, $_[0] );
			if( @input == 1 ) { print "unload what?\n"; }
			if( @input == 2 ) { unload( $_[0] ); }
		},
	g	=> sub {
			my $output = [];
			communicate( $_[0], $output ) ;
			`echo '' > /dev/shm/$active_pru/register`;
			`echo '' > /dev/shm/$active_pru/disassemble`;
			`echo '' > /dev/shm/$active_pru/datadump`;
			`echo '' > /dev/shm/shared/datadump`;
		},
	pru	=> sub {
			my $output = [];
			communicate( $_[0], $output ) ;
			for ( @$output ) {
				next unless /active pru/i;
				my @ray2 = split;
				$active_pru = $ray2[$#ray2];
				chop $active_pru;
				last;
			}
		},
	r	=> sub {
			my $output = [];
			communicate( $_[0], $output ) ;
			for ( @$output ) {
				if( /^Register info/i ) {
					register( $output );
					last;
				}
			}
			register_report();
		},
	halt	=> sub {
			my $output = [];
			communicate( $_[0], $output ) ;
			for ( @$output ) {
				if( /halted/i ) {
					$funtab->{r}( 'r' );
					last;
				}
			}
			disassemble_report();
		},
};

my $ramdisk = '/dev/shm';
`mkdir -p "$ramdisk/PRU0"`;
`mkdir -p "$ramdisk/PRU1"`;
`mkdir -p "$ramdisk/shared"`;

my $term = Term::ReadLine->new('prudebug wrapper');
while( defined ( $_ = $term->readline($prompt) ) ) { 
	chomp;
	my $raw_input = $_;
	next unless $raw_input;
	$term->addhistory($raw_input);
	my @input = split( /\s+/, $raw_input );
	if( exists $funtab->{lc $input[0]} ) {
		print "$raw_input\n";
		$funtab->{lc $input[0]}( $raw_input );
	} else {
		print "$raw_input ----- not yet implemented\n";
	}	
	$prompt = "prudebug_wrapper $active_pru > ";
}

sub breakpoint_report	{
	my( $ray ) = @_;
	for ( @$ray ) {
		unless ( /^(\d\d)\s+(.*)$/i ) {
			print;
			print "\n";
			next;
		}
		my $br = $1 + 0;
		if( $2 eq 'UNUSED' ) {
			$breakpoints->{$active_pru}{$br} = undef;
			print "$1  UNUSED\n";
			next;
		} else {
			my $h = hex $2;
			$breakpoints->{$active_pru}{$br} = $2;
			printf( "%02d  %s  %u \n", $1, $2, $h );
		}
	}
	open my $FH, ">$ramdisk/$active_pru/breakpoints" or die "unable : $!";
	my $h = $breakpoints->{$active_pru};
	for my $k ( sort keys %$h ) {
		my $l;
		if( defined $h->{$k} ) {
			$l = sprintf( "%02d -- %s  %u", $k, $h->{$k}, hex $h->{$k} );
		} else {
			$l = sprintf( "%02d -- UNUSED", $k );
		}
		printf $FH "$l\n";
	}
	close $FH or die "unable : $!";
}

sub watchpoint_report	{
	my( $input, $output ) = @_;
	for ( @$output ) {
		unless ( /^(\d\d)\s+(.*)$/i ) {
			print;
			print "\n";
			next;
		}
		my $wp = $1 + 0;
		if( $2 eq 'UNUSED' ) {
			$watchpoints->{$active_pru}{$wp} = undef;
			print "$1  UNUSED\n";
			next;
		}
		my @ray = split( /\s+/, $_ );
	        my $address = $ray[1];	
		my $value = '';
		$ray[4] and $value = $ray[4];
		if( @ray > 2 ) {
			$watchpoints->{$active_pru}{$wp} = $address;
			$watchvalues->{$active_pru}{$wp} = $value;
			my $fs = "%02d  %s  %s\n";
			printf( $fs, $wp, $address, $value );
		}
	}
}

sub set_watchpoint	{
	my( $ray ) = @_;
	my $wa = $ray->[1];
	my $address = $ray->[2];
	if( @$ray == 3 ) {
		$watchpoints->{$active_pru}{$wa} = $address;
	} else {
		$watchvalues->{$active_pru}{$wa} = $ray->[3];
	}
}

sub delete_watchpoint	{
	my( $ray ) = @_;
	my $wa = $ray->[1];
	$watchpoints->{$active_pru}{$wa} = undef;
	$watchvalues->{$active_pru}{$wa} = undef;
}

sub register {
	my( $output ) = @_;
	for my $x ( @$output ) {
		if( $x =~ /R0\d:\s+/i ) {
			$x =~ /(R\d\d):\s+(0x\S+)\s+(R\d\d):\s+(0x\S+)\s+(R\d\d):\s+(0x\S+)\s+(R\d\d):\s+(0x\S+)\s*$/;
			$registers->{$active_pru}{$1} = $2;
			$registers->{$active_pru}{$3} = $4;
			$registers->{$active_pru}{$5} = $6;
			$registers->{$active_pru}{$7} = $8;
		}
		if( $x =~ /Program counter/i ) {
			my @ray = split( /\s+/, $x );
			$program_counter = sprintf( "%d", hex $ray[$#ray] );
		}
		if( $x =~ /Current instruction:\s+(.*)$/i ) {
			$current_instruction = $1;
		}
	}
	1;
}

sub datadump_report {
	my( $input ) = @_;
	my( undef, $start, $end ) = @$input;
	substr( $start, 0, 2 ) eq '0x' and $start = hex substr( $start, 2, 99 );
	substr( $end, 0, 2 )   eq '0x' and $end   = hex substr( $end, 2, 99 );
	my $ap = $active_pru;
	$start >= 16 * 1024 and $ap = 'shared';
	open my $FH, ">$ramdisk/$ap/datadump" or die "unable : $!";
	my $h = $datadump->{$ap};
	for( my $r = $start ; $r < $start + $end ; $r++ )  {
		next unless exists $h->{$r};
		my $rv = hex substr( $h->{$r}, 2, 99 );
		my $x = sprintf( "0x%04x %04d 0x%08x %010d\n", $r, $r, $rv, $rv );
		printf $FH $x;
	}
	close $FH or die "unable : $!";
}

sub register_report {
	open my $FH, ">$ramdisk/$active_pru/register" or die "unable : $!";
	my $h = $registers->{$active_pru};
	for my $r ( sort keys %$h ) {
		my $rv = hex substr( $h->{$r}, 3, 99 );
		my $x = sprintf( "%s 0x%08x %010d\n", $r, $rv, $rv );
		printf $FH $x;
	}
	close $FH or die "unable : $!";
}

sub disassemble_report {
	$program_counter or return;
	my $start = $program_counter - 10;
	$start < 0 and $start = 0;
	my $end = $program_counter + 10;
	my $fetch = 0;
	for( my $x = $start ; $x < $end ; $x++ )  {
		unless( exists $disassemble->{$active_pru}{$x} ) {
			printf "%04d 0x%x not exist \n", $x, $x;
			$fetch = 1;
		}
	}
	$fetch and $funtab->{'dis'}("dis 0 $end");

	my $h = $disassemble->{$active_pru};
	open my $FH, ">$ramdisk/$active_pru/disassemble" or die "unable : $!";
	for( my $x = $start ; $x < $end ; $x++ )  {
		exists $h->{$x} or next;
		my( $s, $p ) = ( $h->{$x}, '' );
		if( substr( $s, 0, 1 ) eq '>' ) {
			$p = '   ' . substr( $s, 3, 99 );
		} else {
			$p = "   $s";
		}
		$p = ">> " . substr( $p, 3, 99 ) if $x == $program_counter;
		my $m = sprintf( "0x%04x %s\n", $x, m4( $p ) );
		print $FH $m;
	}
	close $FH or die "unable : $!";
}

sub datadump {
	my( $input, $output, $key ) = @_;
	my $ap = $active_pru;
	for my $x ( @$output ) {
		if( $x =~ /^\[0x(\S+)\]\s+(0x\S+)\s+(0x\S+)\s+(0x\S+)\s(0x\S+)\s*$/i ) {
			my ( $addr, $plus0, $plus1, $plus2, $plus3 ) = 
				( $1, $2, $3, $4, $5 );
			$addr ge '4000' and $ap = 'shared';
			$key = hex $addr;
			$datadump->{$ap}{$key} = $plus0;
			$key += 1;
			$datadump->{$ap}{$key} = $plus1;
			$key += 1;
			$datadump->{$ap}{$key} = $plus2;
			$key += 1;
			$datadump->{$ap}{$key} = $plus3;
		}
	}
	my @ray = split( /\s+/, $input );
	datadump_report( \@ray );
	1;
}

sub communicate {
	my( $input, $output ) = @_;
	my @input = split( /\s+/, $input );
	my $stamp = `echo '' | tai64n | tr -d " \n"`;
	my $sum = `$sum_command`;
	print $INPUT "$input\n";
	while( $sum == `$sum_command` ) { sleep 1; }
	open my $OUTPUT, "<$logfile" or die "unable : $!";
	while( <$OUTPUT> ) {
		/(\S+)\s+(.*)$/;
		$1 lt $stamp and next;
		my $x = $2;
		push @$output, $x;
 		print "$x\n";
	}
	close $OUTPUT or die "unable : $!";
	# what about when the 'current' file gets archived?
	open $OUTPUT, "<$logfile" or die "unable : $!";
	while( <$OUTPUT> ) {
		/(\S+)\s+(.*)$/;
		$1 lt $stamp and last;
		my $x = $2;
		push @$output, $x;
 		print "$x\n";
	}
	close $OUTPUT or die "unable : $!";
}

sub load_report {
	my $ap = $active_pru;
	if ( keys %{$load->{$ap}} ) {
		print join( "\n", sort keys %{$load->{$ap}} );
	} else {
		print "No source files loaded\n";
	}
}

sub unload {
	my( $input ) = @_;
	my @input = split( /\s+/, $input );
	my $ap = $active_pru;
	if( exists $load->{$ap}{$input[1]} ) {
		delete $load->{$ap}{$input[1]};
		$m4 = {};
		for my $f ( keys %{$load->{$ap}} ) {
			$funtab->{'load'}( $f );
		}
	} else {
		print $input[1] . " is not loaded\n";
	}
}

sub load {
	my( $input ) = @_;
	my @input = split( /\s+/, $input );
	my $ap = $active_pru;
	if( exists $load->{$ap}{$input[1]} ) {
		print $input[1] . " is already loaded\n";
		return;
	}
	unless( -f $input[1] ) {
		print $input[1] . " not found\n";
		return;
	}
	open my $FH, "<" . $input[1]  or die "unable : $!";
	for ( <$FH> ) {
		if( /\.asg\s+\"(\S+)\",\s+(\S+)\s*$/ ) {
			$m4->{$ap}{$1} = $2;
			next;
		}
		if( /\.include\s+\"(\S+)\"\s*$/ ) {
			$funtab->{'load'}( "load $1" );
			next;
		}
	}
	close $FH or die "unable : $!";
	$load->{$ap}{$input[1]}++;
}

sub m4 {
	my( $input, $output ) = @_;
	my $ap = $active_pru;
	my @tok = split( /\s+/, $input );
	for my $tok ( @tok ) {
		my $lcase = lc $tok;
		my $last = chop $lcase;
		my $i = $lcase;
		$last eq ',' or  $i .= "$last";
	       	
		while( exists $m4->{$ap}{$i} ) {
			$i = $m4->{$ap}{$i};
		}
		
		$output .= $i;
		if( $last eq ',' ) {
			$output .= ', ';
		} else {
			$output .= ' ';
		}
	}
	$output;
}

