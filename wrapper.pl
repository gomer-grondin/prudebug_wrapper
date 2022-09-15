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
my ( $m4, $load, $unload, $registers, $disassemble, $datadump ) = 
   ( {}, {}, {}, {}, {}, {} );

my $ramdisk = '/dev/shm';
`mkdir -p "$ramdisk/PRU0"`;
`mkdir -p "$ramdisk/PRU1"`;
`mkdir -p "$ramdisk/shared"`;

my ( $funtab, $output );
$funtab = {
	dd	=> sub { datadump( $_[0], $output ); },
	d	=> sub { $funtab->{dd}($_[0]); },
	q	=> sub { die "you're a quitter"; },
	ss	=> sub { disassemble_report(); },
	halt	=> sub { disassemble_report(); },
	br	=> sub { 1; },
	help	=> sub { 1; },
	hb	=> sub { 1; },
	wa	=> sub { 1; },
	dis	=> sub {
			for ( @$output ) {
				if( /^\[0x(\S+)\]\s+0x\S+\s+(.*)$/i ) {
					my ( $o, $i ) = ( $1, $2 );
					my $addr = sprintf( "%d", hex $o );
					# strip pc indicator
					if( $i =~ /^>> / ) {
						$i = substr( $i, 3, 99 );
					}
					$disassemble->{$active_pru}{$addr} = $i;
				}
			}
			disassemble_report();
		},
	load	=> sub {
			my @input = split( /\s+/, $_[0] );
			if( @input == 1 ) { load_report(); }
			if( @input == 2 ) { load( $_[0] ); }
			disassemble_report();
		},
	unload	=> sub {
			my @input = split( /\s+/, $_[0] );
			if( @input == 1 ) { print "unload what?\n"; }
			if( @input  > 1 ) { unload( $_[0] ); }
		},
	g	=> sub {
			`echo '' > $ramdisk/$active_pru/register`;
			`echo '' > $ramdisk/$active_pru/disassemble`;
			`echo '' > $ramdisk/$active_pru/datadump`;
			`echo '' > $ramdisk/shared/datadump`;
		},
	pru	=> sub {
			for ( @$output ) {
				next unless /active pru/i;
				my @ray2 = split;
				$active_pru = $ray2[$#ray2];
				chop $active_pru;
				last;
			}
		},
	r	=> sub {
			register( $output );
			register_report();
		},
};

my $term = Term::ReadLine->new('prudebug wrapper');
my $latest = '';
while( defined ( $_ = $term->readline($prompt) ) ) { 
	chomp;
	my $raw_input = $_;
	if( $raw_input ) {
		$term->addhistory($raw_input);
		$latest = $raw_input;
	} else {
		next unless $latest;
		$raw_input = $latest;
	}
	my @input = split( /\s+/, $raw_input );
	my $c = lc $input[0];
	if( exists $funtab->{$c} ) {
		print "$raw_input\n";
		$output = communicate( $raw_input, [], command_echo( $c ) ) ;
		$funtab->{$c}( $raw_input );
	} else {
		print "$raw_input ----- not yet implemented\n";
	}	
	$prompt = "prudebug_wrapper $active_pru > ";
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
	$output = communicate( 'r', [], command_echo( 'r' ) ) ;
	$funtab->{r}( 'r' );
	my $start = $program_counter - 10;
	$start < 0 and $start = 0;
	my $end = $program_counter + 10;
	my $fetch = 0;
	for( my $x = $start ; $x < $end ; $x++ )  {
		$fetch++ unless( exists $disassemble->{$active_pru}{$x} );
	}
	if( $fetch ) {
		$output = communicate( "dis $start 0x15", [], 0 ) ;
		$funtab->{'dis'}('dis');
	}

	my $h = $disassemble->{$active_pru};
	open my $FH, ">$ramdisk/$active_pru/disassemble" or die "unable : $!";
	for( my $x = $start ; $x < $end ; $x++ )  {
		exists $h->{$x} or next;
		my $s  = lc $h->{$x};
		my $m4 = m4( $s );
		my $p  = "   $s";
		   $p  = ">> $s" if $x == $program_counter;
		print $FH sprintf( "0x%04x %s\n", $x, $p );
		next if $m4 eq $s;
		print $FH sprintf( "0x%04x\t\t\t%s\n", $x, uc $m4 );

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
			$datadump->{$ap}{$key++} = $plus0;
			$datadump->{$ap}{$key++} = $plus1;
			$datadump->{$ap}{$key++} = $plus2;
			$datadump->{$ap}{$key} = $plus3;
		}
	}
	my @ray = split( /\s+/, $input );
	datadump_report( \@ray );
	1;
}

sub communicate {
	my( $input, $output, $echo ) = @_;
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
	}
	close $OUTPUT or die "unable : $!";
	# what about when the 'current' file gets archived?
	open $OUTPUT, "<$logfile" or die "unable : $!";
	while( <$OUTPUT> ) {
		/(\S+)\s+(.*)$/;
		$1 lt $stamp and last;
		my $x = $2;
		push @$output, $x;
	}
	close $OUTPUT or die "unable : $!";
	my $ic = grep { $_ =~ /Invalid command/i } @$output;
	$output = $ic ? [] : $output;
 	$echo and print join( "\n", @$output ) . "\n";
	$output;
}

sub load_report {
	my $ap = $active_pru;
	if ( keys %{$load->{$ap}} ) {
		print "\t", join( "\n\t", sort keys %{$load->{$ap}} ), "\n";
	} else {
		print "No source files loaded\n";
	}
}

sub unload {
	my( $input ) = @_;
	my @input = split( /\s+/, $input );
	my $ap = $active_pru;
	for my $k ( @input ) {
		next if $k eq 'unload';
		delete $load->{$ap}{$k};
		$unload->{$ap}{$k}++;
	}

	$m4->{$ap} = {};
	for my $f ( keys %{$load->{$ap}} ) {
		$funtab->{'load'}( "load $f" );
	}
	delete $disassemble->{$ap}; # force reinitialization
}

sub load {
	my( $input ) = @_;
	my @input = split( /\s+/, $input );
	my $ap = $active_pru;
	if( exists $unload->{$ap}{$input[1]} ) {
		delete $unload->{$ap}{$input[1]};
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
			my $f = $1;
			exists $unload->{$ap}{$f} and next;
			$funtab->{'load'}( "load $f" );
			next;
		}
	}
	close $FH or die "unable : $!";
	$load->{$ap}{$input[1]}++;
	delete $disassemble->{$ap}; # force reinitialization
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
		$output .= $last eq ',' ? ', ' : ' ';
	}
	$output =~ /\s*(\S+.*\S+)\s*$/;
	$1;
}

# do we want to echo command output to invocation screen?
sub command_echo	{
	my( $i ) = @_;
	$i eq 'r'    and return 0;
	$i eq 'ss'   and return 0;
	$i eq 'dis'  and return 0;
	$i eq 'br'   and return 1;
	$i eq 'wa'   and return 1;
	$i eq 'help' and return 1;
	$i eq 'hb'   and return 1;
	1;
}
