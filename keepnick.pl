# Copyright (c) 2006-2007 by Nicholas Kain <njk@kain.us>
# Copyright (C) 2001, 2002 by Peder Stray <peder@ninja.no>

use strict;
use vars qw( $VERSION %IRSSI );

$VERSION = '$Revision: 1.30 $' =~ / (\d+\.\d+) /;

%IRSSI = (
	name        => 'keepnick',
	authors     => 'Nicholas Kain, Peder Stray',
	contact     => 'niklata@aerifal.cx, peder@ninja.no',
	url         => 'http://brightrain.aerifal.cx/~niklata/projects',
	license     => 'GPL',
	description => 'Recover nicks and identify/ghost as necessary.',
);

use Irssi 20011118.1727;
use Irssi::Irc;

use Fcntl qw( O_RDWR O_CREAT );
use SDBM_File;

my %keepnick; # nicks we want to keep
my %getnick;  # nicks we are currently waiting for
my %inactive; # inactive chatnets
my %manual;   # manual nickchanges
my %nickpass; # nickserv username:password pairs

BEGIN {
	my %tie = ( keepnick => \%keepnick, nickpass => \%nickpass );
	while ( my ( $name, $hash ) = each %tie ) {
		my $sdbm = Irssi::get_irssi_dir . '/' . $name;
		tie %$hash,
			SDBM_File => $sdbm,
			O_RDWR | O_CREAT, 0666
			or die "Couldn't tie SDBM file $sdbm: $!\n";
	}
}

sub _printfmt {
	my ( $fmt, @msg ) = @_;
	Irssi::printformat( MSGLEVEL_CLIENTCRAP, "keepnick_$fmt", @msg );
}

sub validate_chatnet {
	my ( $chatnet, $server ) = @_;

	if ( $$chatnet ) {
		my ( $cn ) = Irssi::chatnet_find( $$chatnet );
		unless ( $cn ) {
			_printfmt( crap => "Unknown chat network: $$chatnet" );
			return;
		}
		$$chatnet = $cn->{ name };
		$$server  = Irssi::server_find_chatnet( $$chatnet );
	}
	else {
		if ( not $$server ) {
			_printfmt( crap => 'Not connected to server' );
			return;
		}
		$$chatnet = $$server->{ chatnet };
	}

	return 1;
}

sub change_nick {
	my ( $server, $nick ) = @_;
	$server->redirect_event( 'keepnick nick', 1, ":$nick", -1, undef, {
		'event nick' => 'redir keepnick nick',
		''           => 'event empty',
	} );
	$server->send_raw( "NICK :$nick" );
}

sub check_available_nick {
	my ( $server, $nick ) = @_;
	my ( $chatnet ) = lc $server->{ chatnet };
	if ( lc $nick eq lc $getnick{ $chatnet } ) {
		change_nick( $server, $getnick{ $chatnet } );
	}
}

sub ghost_nick {
	my ( $server ) = @_;
	my $net        = lc $server->{ chatnet };
	my $nick       = $keepnick{ $net };
	my $password   = $nickpass{ $net } or return;

	if ( lc $nick ne lc $server->{ nick } ) {
		Irssi::printformat( MSGLEVEL_CLIENTCRAP, 'keepnick_ghost_nick', $nick, $server->{ chatnet } );
		$server->command( "QUOTE NickServ GHOST $nick $password" );
		change_nick( $server, $nick );
	}
}

sub ident_nick {
	my ( $server ) = @_;
	my $net        = lc $server->{ chatnet };
	my $nick       = $server->{ nick };
	my $password   = $nickpass{ $net } or return;

	if ( lc $nick eq lc $keepnick{ $net } ) {
		_printfmt( identify_request => $nick, $server->{ chatnet } );
		$server->command( "QUOTE NickServ IDENTIFY $password" );
	}
	else {
		ghost_nick( $server );
	}
}

sub check_nick {
	%getnick = ();

	while ( my ( $net, $nick ) = each %keepnick ) {
		next if $inactive{ $net };
		my $server = Irssi::server_find_chatnet( $net ) or next;
		next if lc $server->{ nick } eq lc $nick;
		$getnick{ $net } = $nick;
		$server->redirect_event( 'keepnick ison', 1, '', -1, undef, { 'event 303' => 'redir keepnick ison' } );
		$server->send_raw( "ISON :$nick" );
	}
}



# ==== [ SIGNALS ] =====================================================

# if anyone quits, check if we want their nick.
Irssi::signal_add 'message quit' => sub {
	my ( $server, $nick ) = @_;
	check_available_nick( $server, $nick );
};

# if anyone changes their nick, check if we want their old one.
Irssi::signal_add 'message nick' => sub {
	my ( $server, $newnick, $oldnick ) = @_;
	check_available_nick( $server, $newnick );
};

# if we change our nick, check it to see if we wanted it and if so
# remove it from the list.
Irssi::signal_add 'message own_nick' => sub {
	my ( $server, $newnick, $oldnick ) = @_;
	my ( $chatnet ) = lc $server->{ chatnet };
	if ( lc $newnick eq lc $keepnick{ $chatnet } ) {
		delete $getnick{ $chatnet };
		if ( $inactive{ $chatnet } ) {
			delete $inactive{ $chatnet };
			_printfmt( unhold => $newnick, $chatnet );
		}
	}
	elsif (
		lc $oldnick eq lc $keepnick{ $chatnet }
		&& lc $newnick eq lc $manual{ $chatnet }
	) {
		$inactive{ $chatnet } = 1;
		delete $getnick{ $chatnet };
		_printfmt( hold => $oldnick, $chatnet );
	}
};

Irssi::signal_add 'redir keepnick ison' => sub {
	my ( $server, $text ) = @_;
	my $nick = $getnick{ lc $server->{ chatnet } };
	ghost_nick( $server )
		unless $text =~ /:\Q$nick\E\s?$/i;
};

sub sig_message_own_nick_block {
	my ( $server, $new, $old, $addr ) = @_;
	Irssi::signal_stop();
	$server->printformat( undef, MSGLEVEL_NICKS | MSGLEVEL_NO_ACT, 'keepnick_got_nick', $new, $server->{ chatnet } )
		unless Irssi::settings_get_bool( 'keepnick_quiet' );
}

Irssi::signal_add 'redir keepnick nick' => sub {
	my ( $server, $args, $nick, $addr ) = @_;
	Irssi::signal_add_first( 'message own_nick', 'sig_message_own_nick_block' );
	Irssi::signal_emit( 'event nick', $server, $args, $nick, $addr );
	Irssi::signal_remove( 'message own_nick', 'sig_message_own_nick_block' );
};

Irssi::Irc::Server::redirect_register( 'keepnick ison', 0, 0, undef, { 'event 303' => -1, }, undef );

Irssi::Irc::Server::redirect_register(
	'keepnick nick',
	0, 0, undef,
	{
		'event nick' => 0,
		'event 432'  => -1, # ERR_ERRONEUSNICKNAME
		'event 433'  => -1, # ERR_NICKNAMEINUSE
		'event 437'  => -1, # ERR_UNAVAILRESOURCE
		'event 484'  => -1, # ERR_RESTRICTED
	},
	undef
);

Irssi::signal_add 'event notice' => sub {
	my ( $server, $data, $nick, $address ) = @_;
	my ( $target, $text ) = $data =~ /^(\S*)\s:(.*)/;
	my $unick = $server->{ nick };
	my $net   = lc $server->{ chatnet };

	if ( lc $nick eq 'nickserv' ) {
		if ( $text =~ /This nickname is registered and protected\.  If it is your/i ) {
			ident_nick $server;
		}
		elsif ( $text =~ /This nickname is owned by someone else/i ) {
			ident_nick $server;
		}
		elsif ( $text =~ /Password accepted - you are now recognized\./i ) {
			_printfmt( identify_success => $unick, $server->{ chatnet } );
		}
	}
};

# ==== [ COMMANDS ] ===================================================

sub _usage_error {
	_printfmt( @_ ), Irssi::print( '', MSGLEVEL_CRAP ) if @_;
	Irssi::print( $_, MSGLEVEL_CRAP ) for split /\n/, <<'END_USAGE';
KEEPNICK REMOVE [<network>]
KEEPNICK ADD [<network> [<nick> [<pass>]]]
KEEPNICK LIST
KEEPNICK HELP
END_USAGE
}

Irssi::command_bind keepnick => sub {
	my ( $params, $server, $witem ) = @_;
	Irssi::command_runsub( keepnick => $params, $server, $witem );
};

Irssi::command_bind 'keepnick add' => sub {
	my ( $params, $server, $witem ) = @_;

	my ( $chatnet, $nick, $pass, @extraneous_param ) = split ' ', $params;

	if ( @extraneous_param ) { _usage_error cmderr_toomanyarg => 'ADD'; return }

	validate_chatnet( \$chatnet, \$server ) or return;

	$nick = $server->{ nick } unless defined $nick;

	if ( $inactive{ lc $chatnet } ) {
		delete $inactive{ lc $chatnet };
		_printfmt( unhold => $nick, $chatnet );
	}

	_printfmt( add => $nick, $chatnet );

	$keepnick{ lc $chatnet } = $nick;
	$pass ? $nickpass{ lc $chatnet } = $pass : delete $nickpass{ lc $chatnet };

	check_nick();
};

Irssi::command_bind 'keepnick remove' => sub {
	my ( $params, $server, $witem ) = @_;

	my ( $chatnet, @extraneous_param ) = split ' ', $params;

	if ( @extraneous_param ) { _usage_error cmderr_toomanyarg => 'REMOVE'; return }

	validate_chatnet( \$chatnet, \$server ) or return;

	_printfmt( remove => $keepnick{ lc $chatnet }, $chatnet );

	delete $keepnick{ lc $chatnet };
	delete $getnick{ lc $chatnet };
	delete $nickpass{ lc $chatnet };
};

Irssi::command_bind 'keepnick list' => sub {
	my ( $params, $server, $witem ) = @_;

	if ( length $params ) { _usage_error cmderr_toomanyarg => 'LIST'; return }

	if ( %keepnick ) {
		_printfmt( 'list_header' );
		while ( my ( $chatnet, $nick ) = each %keepnick ) {
			my $net     = Irssi::chatnet_find( $chatnet );
			my $netname = $net ? $net->{ name } : ">$_<";
			my $status  = $inactive{ $_ } ? 'inactive' : 'active';
			_printfmt( list_line => $nick, $netname, $status );
		}
		_printfmt( 'list_footer' );
	}
	else {
		_printfmt( 'list_empty' );
	}
};

Irssi::command_bind 'keepnick help' => sub {
	my ( $params, $server, $witem ) = @_;
	_usage_error();
};

Irssi::command_bind nick => sub {
	my ( $data, $server ) = @_;
	my ( $nick ) = split ' ', $data;
	return unless $server;
	$manual{ lc $server->{ chatnet } } = $nick;
};



# ==== [ SETUP ] ====================================================

Irssi::timeout_add 12000 => \&check_nick, '';

Irssi::settings_add_bool keepnick => keepnick_quiet => 0;

Irssi::theme_register [
	'keepnick_crap',
	'{line_start}{hilight Keepnick:} $0',

	'keepnick_add',
	'{line_start}{hilight Keepnick:} Now keeping {nick $0} on [$1]',

	'keepnick_remove',
	'{line_start}{hilight Keepnick:} Stopped trying to keep {nick $0} on [$1]',

	'keepnick_hold',
	'{line_start}{hilight Keepnick:} Nickkeeping deactivated on [$1]',

	'keepnick_unhold',
	'{line_start}{hilight Keepnick:} Nickkeeping reactivated on [$1]',

	'keepnick_list_empty',
	'{line_start}{hilight Keepnick:} No nicks in keep list',

	'keepnick_list_header',
	'',

	'keepnick_list_line',
	'{line_start}{hilight Keepnick:} Keeping {nick $0} in [$1] ($2)',

	'keepnick_list_footer',
	'',

	'keepnick_got_nick',
	'{line_start}{hilight Keepnick:} Got back {nick $0} on [$1]',

	'keepnick_ghost_nick',
	'{line_start}{hilight Keepnick:} Ghosting {nick $0} on [$1]',

	'keepnick_identify_request',
	'{line_start}{hilight Keepnick:} Being asked to identify for {nick $0} on [$1]',

	'keepnick_identify_success',
	'{line_start}{hilight Keepnick:} Identified to {nick $0} on [$1]',

	'keepnick_cmderr_toomanyarg',
	'{line_start}{hilight Keepnick:} Too many arguments for $0',

	'keepnick_cmderr_unknown',
	'{line_start}{hilight Keepnick:} Unknown command $0',
];
