# Copyright (c) 2006-2007 by Nicholas Kain <njk@kain.us>
# Copyright (C) 2001, 2002 by Peder Stray <peder@ninja.no>

use strict;
use Irssi;
use Irssi::Irc;

use vars qw{$VERSION %IRSSI};
($VERSION) = '$Revision: 1.30 $' =~ / (\d+\.\d+) /;
%IRSSI = (
          name        => 'keepnick',
          authors     => 'Nicholas Kain, Peder Stray',
          contact     => 'niklata@aerifal.cx, peder@ninja.no',
          url         => 'http://brightrain.aerifal.cx/~niklata/projects',
          license     => 'GPL',
          description => 'Recover nicks and identify/ghost as necessary.',
         );

my(%keepnick);		# nicks we want to keep: key == nick, password
my(%getnick);		# nicks we are currently waiting for
my(%inactive);		# inactive chatnets
my(%manual);		# manual nickchanges
my(%nspw);			# nickserv username:password pairs

sub change_nick {
    my($server,$nick) = @_;
	my $net = lc $server->{chatnet};

    $server->redirect_event('keepnick nick', 1, ":$nick", -1, undef,
			    {
			     "event nick" => "redir keepnick nick",
			     "" => "event empty",
			    });
    $server->send_raw("NICK :$nick");
}

sub ghost_nick {
	my($server) = @_;
	my $net = lc $server->{chatnet};
	my $nick = $keepnick{$net}->[0];
	my $pwnick = $nspw{$net}->[0];
	my $password = $nspw{$net}->[1];

	if (lc $server->{nick} ne lc $nick) {
		if ($password and ($pwnick eq $nick)) {
			Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'keepnick_ghost_nick',
				$nick);
			$server->command("QUOTE NickServ GHOST ".$nick." ".$password);
		}
		change_nick($server,$nick);
	}
}

sub check_nick {
    my($server,$net,$nick);

    %getnick = ();	# clear out any old entries
    
    for $net (keys %keepnick) {
	next if $inactive{$net};
	$server = Irssi::server_find_chatnet($net);
	next unless $server;
	next if lc $server->{nick} eq lc $keepnick{$net}->[0];
	
	$getnick{$net} = $keepnick{$net}->[0];
    }
    
    for $net (keys %getnick) {
	$server = Irssi::server_find_chatnet($net);
	next unless $server;
	$nick = $getnick{$net};
	if (lc $server->{nick} eq lc $nick) {
	    delete $getnick{$net};
	    next;
	}
	$server->redirect_event('keepnick ison', 1, '', -1, undef,
				{ "event 303" => "redir keepnick ison" });
	$server->send_raw("ISON :$nick");
    }
}

sub load_nicks {
    my($file) = Irssi::get_irssi_dir."/keepnick";
    my($count) = 0;
    local(*CONF);
    
    %keepnick = ();
    open CONF, "< $file";
    while (<CONF>) {
	my($net,$nick,$pass) = split;
	if ($net && $nick) {
	    $keepnick{lc $net}->[0] = $nick;
	    $nspw{lc $net}->[0] = $nick;
	    $count++;
		if ($pass) {
			$nspw{lc $net}->[1] = $pass;
		}
	}
    }
    close CONF;
    
    Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'keepnick_crap',
		       "Loaded $count nicks from $file");
}

sub save_nicks {
    my($auto) = @_;
    my($file) = Irssi::get_irssi_dir."/keepnick";
    my($count) = 0;
    local(*CONF);
    
    return if $auto && !Irssi::settings_get_bool('keepnick_autosave');
    
    open CONF, "> $file";
    for my $net (sort keys %keepnick) {
	print CONF "$net\t$nspw{$net}->[0]";
		if ($nspw{$net}->[1]) {
			print CONF "\t$nspw{$net}->[1]";
		}
		print CONF "\n";
	$count++;
    }
    close CONF;
    
    Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'keepnick_crap',
		       "Saved $count nicks to $file")
	unless $auto;
}

sub server_printformat {
    my($server,$level,$format,@params) = @_;
	$server->printformat(undef,$level,$format,@params);
}

# ======[ Signal Hooks ]================================================

# if anyone changes their nick, check if we want their old one.
sub sig_message_nick {
    my($server,$newnick,$oldnick) = @_;
    my($chatnet) = lc $server->{chatnet};
    if (lc $oldnick eq lc $getnick{$chatnet}) {
	change_nick($server, $getnick{$chatnet});
    }
}

# if we change our nick, check it to see if we wanted it and if so
# remove it from the list.
sub sig_message_own_nick {
    my($server,$newnick,$oldnick) = @_;
    my($chatnet) = lc $server->{chatnet};
    if (lc $newnick eq lc $keepnick{$chatnet}->[0]) {
	delete $getnick{$chatnet};
	if ($inactive{$chatnet}) {
	    delete $inactive{$chatnet};
	    server_printformat($server, MSGLEVEL_CLIENTCRAP, 'keepnick_unhold', 
			       $newnick);
	}
    } elsif (lc $oldnick eq lc $keepnick{$chatnet}->[0] &&
	     lc $newnick eq lc $manual{$chatnet}) {
	$inactive{$chatnet} = 1;
	delete $getnick{$chatnet};
	server_printformat($server, MSGLEVEL_CLIENTCRAP, 'keepnick_hold',
			   $oldnick);
    }
}

sub sig_message_own_nick_block {
    my($server,$new,$old,$addr) = @_;
    Irssi::signal_stop();
	server_printformat($server, MSGLEVEL_NICKS | MSGLEVEL_NO_ACT,
			   'keepnick_got_nick', $new)
	unless Irssi::settings_get_bool('keepnick_quiet');
}

# if anyone quits, check if we want their nick.
sub sig_message_quit {
    my($server,$nick) = @_;
    my($chatnet) = lc $server->{chatnet};
    if (lc $nick eq lc $getnick{$chatnet}) {
	change_nick($server, $getnick{$chatnet});
    }
}

sub sig_redir_keepnick_ison {
    my($server,$text) = @_;
    my $nick = $getnick{lc $server->{chatnet}};
    ghost_nick($server)
      unless $text =~ /:\Q$nick\E\s?$/i;
}

sub sig_redir_keepnick_nick {
    my($server,$args,$nick,$addr) = @_;
    Irssi::signal_add_first('message own_nick', 'sig_message_own_nick_block');
    Irssi::signal_emit('event nick', @_);
    Irssi::signal_remove('message own_nick', 'sig_message_own_nick_block');
}

# main setup is reread, so let us do it too
sub sig_setup_reread {
    load_nicks;
}

# main config is saved, and so we should save too
sub sig_setup_save {
    my($mainconf,$auto) = @_;
    save_nicks($auto);
}

sub ident_nick {
    my($server) = @_;
	my $nick = $server->{nick};
	my $net = lc $server->{chatnet};
	my $pwnick = $nspw{$net}->[0];
	my $password = $nspw{$net}->[1];

	if ($password and ($pwnick eq $nick)) {
		if (lc $nick eq lc $keepnick{$net}->[0]) {
			server_printformat($server, MSGLEVEL_CLIENTCRAP,
				'keepnick_identify_request', $nick);
			$server->command("QUOTE NickServ identify ".$password);
		} else {
			ghost_nick($server);
		}
	}
}

sub sig_event_notice {
	my ($server, $data, $nick, $address) = @_;
	my ($target, $text) = $data =~ /^(\S*)\s:(.*)/;
	my $unick = $server->{nick};
	my $net = lc $server->{chatnet};

	if ($nick =~ /^NickServ$/i) {
		if ($text =~ /This nickname is registered and protected\.  If it is your/i) {
			ident_nick($server);
		} elsif ($text =~ /This nickname is owned by someone else/i) {
			ident_nick($server);
		} elsif ($text =~ /Password accepted - you are now recognized\./i) {
			server_printformat($server, MSGLEVEL_CLIENTCRAP,
				'keepnick_identify_success', $unick);
		}
	}
}

# ======[ Commands ]====================================================

# Usage: /KEEPNICK [-net <chatnet>] [<nick>] [<pw>]
sub cmd_keepnick {
    my(@params) = split " ", shift;
    my($server) = @_;
    my($chatnet,$nick,$pw,@opts);

    # parse named parameters from the parameterlist
	while (@params) {
		my($param) = shift @params;
		if ($param =~ /^-(chat|irc)?net$/i) {
			$chatnet = shift @params;
		} elsif ($param =~ /^-/) {
			Irssi::print("Unknown parameter $param");
		} else {
			push @opts, $param;
		}
	}
    $nick = shift @opts;
	$pw = shift @opts;

    # check if the ircnet specified (if any) is valid, and if so get the
    # server for it
	if ($chatnet) {
		my($cn) = Irssi::chatnet_find($chatnet);
		unless ($cn) {
			Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'keepnick_crap', 
				"Unknown chat network: $chatnet");
			return;
		}
		$chatnet = $cn->{name};
		$server = Irssi::server_find_chatnet($chatnet);
	}

    # if we need a server, check if the one we got is connected.
	unless ($server || ($nick && $chatnet)) {
		Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'keepnick_crap', 
			"Not connected to server");
		return;
	}

    # lets get the chatnet, and the nick we want
    $chatnet ||= $server->{chatnet};
    $nick    ||= $server->{nick};

    # check that we really have a chatnet
	unless ($chatnet) {
		Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'keepnick_crap',
			"Unable to find a chatnet");
		return;
	}
	
	if ($inactive{lc $chatnet}) {
		delete $inactive{lc $chatnet};
		server_printformat($server, MSGLEVEL_CLIENTCRAP, 'keepnick_unhold',
			$nick);
	}

    server_printformat($server, MSGLEVEL_CLIENTCRAP, 'keepnick_add', $nick);

    $keepnick{lc $chatnet}->[0] = $nick;
	if ($pw) {
		$nspw{lc $chatnet}->[1] = $pw;
	}

    save_nicks(1);
    check_nick();
}

# Usage: /UNKEEPNICK [<chatnet>]
sub cmd_unkeepnick {
    my($chatnet,$server) = @_;
    
    # check if the ircnet specified (if any) is valid, and if so get the
    # server for it
    if ($chatnet) {
	my($cn) = Irssi::chatnet_find($chatnet);
	unless ($cn) {
	    Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'keepnick_crap', 
			       "Unknown chat network: $chatnet");
	    return;
	}
	$chatnet = $cn->{name};
    } else {
	$chatnet = $server->{chatnet};
    }

    server_printformat($server, MSGLEVEL_CLIENTCRAP, 'keepnick_remove',
		       $keepnick{lc $chatnet}->[0]);

    delete $keepnick{lc $chatnet};
    delete $getnick{lc $chatnet};

    save_nicks(1);
}

# Usage: /LISTNICK
sub cmd_listnick {
    my(@nets) = sort keys %keepnick;
    my $net;
    if (@nets) {
	Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'keepnick_list_header');
	for (@nets) {
	    $net = Irssi::chatnet_find($_);
	    Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'keepnick_list_line',
			       $keepnick{$_}->[0],
			       $net ? $net->{name} : ">$_<",
			       $inactive{$_}?'inactive':'active');
	}
	Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'keepnick_list_footer');
    } else {
	Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'keepnick_list_empty');
    }
}

sub cmd_nick {
    my($data,$server) = @_;
    my($nick) = split " ", $data;
    return unless $server;
    $manual{lc $server->{chatnet}} = $nick;
}

# ======[ Setup ]=======================================================

Irssi::settings_add_bool('keepnick', 'keepnick_autosave', 1);
Irssi::settings_add_bool('keepnick', 'keepnick_quiet', 0);

Irssi::theme_register(
[
 'keepnick_crap', 
 '{line_start}{hilight Keepnick:} $0',

 'keepnick_add', 
 '{line_start}{hilight Keepnick:} Now keeping {nick $0}',

 'keepnick_remove',
 '{line_start}{hilight Keepnick:} Stopped trying to keep {nick $0}',

 'keepnick_hold',
 '{line_start}{hilight Keepnick:} Nickkeeping deactivated',

 'keepnick_unhold',
 '{line_start}{hilight Keepnick:} Nickkeeping reactivated',

 'keepnick_list_empty', 
 '{line_start}{hilight Keepnick:} No nicks in keep list',

 'keepnick_list_header', 
 '',

 'keepnick_list_line', 
 '{line_start}{hilight Keepnick:} Keeping {nick $0} [$1] ($2)',

 'keepnick_list_footer', 
 '',

 'keepnick_got_nick',
 '{line_start}{hilight Keepnick:} Nickstealer left, got {nick $0} back',
 
 'keepnick_ghost_nick',
 '{line_start}{hilight Keepnick:} Ghosting {nick $0}',
 
 'keepnick_identify_request',
 '{line_start}{hilight Keepnick:} Got identify request {nick $0}',
 
 'keepnick_identify_success',
 '{line_start}{hilight Keepnick:} Successfully identified {nick $0}',
 
]);

Irssi::signal_add('message quit', 'sig_message_quit');
Irssi::signal_add('message nick', 'sig_message_nick');
Irssi::signal_add('message own_nick', 'sig_message_own_nick');

Irssi::signal_add('redir keepnick ison', 'sig_redir_keepnick_ison');
Irssi::signal_add('redir keepnick nick', 'sig_redir_keepnick_nick');

Irssi::signal_add('setup saved', 'sig_setup_save');
Irssi::signal_add('setup reread', 'sig_setup_reread');

Irssi::signal_add('event notice', 'sig_event_notice');

Irssi::command_bind("keepnick", "cmd_keepnick");
Irssi::command_bind("unkeepnick", "cmd_unkeepnick");
Irssi::command_bind("listnick", "cmd_listnick");
Irssi::command_bind("nick", "cmd_nick");

Irssi::timeout_add(12000, 'check_nick', '');

Irssi::Irc::Server::redirect_register('keepnick ison', 0, 0,
			 undef,
			 {
			  "event 303" => -1,
			 },
			 undef );

Irssi::Irc::Server::redirect_register('keepnick nick', 0, 0,
			 undef,
			 {
			  "event nick" => 0,
			  "event 432" => -1,	# ERR_ERRONEUSNICKNAME
			  "event 433" => -1,	# ERR_NICKNAMEINUSE
			  "event 437" => -1,	# ERR_UNAVAILRESOURCE
			  "event 484" => -1,	# ERR_RESTRICTED
			 },
			 undef );

load_nicks;

