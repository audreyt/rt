#!/usr/bin/perl
# BEGIN LICENSE BLOCK
# 
# Copyright (c) 1996-2002 Jesse Vincent <jesse@bestpractical.com>
# 
# (Except where explictly superceded by other copyright notices)
# 
# This work is made available to you under the terms of Version 2 of
# the GNU General Public License. A copy of that license should have
# been provided with this software, but in any event can be snarfed
# from www.gnu.org
# 
# This work is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
# 
# 
# Unless otherwise specified, all modifications, corrections or
# extensions to this work which alter its source code become the
# property of Best Practical Solutions, LLC when submitted for
# inclusion in the work.
# 
# 
# END LICENSE BLOCK

use strict;
use File::Basename;
require (dirname(__FILE__) . '/webmux.pl');

my $h = &RT::Interface::Web::NewCGIHandler();

# Enter CGI::Fast mode, which should also work as a vanilla CGI script.
require CGI::Fast;

RT::Init();

# Response loop
while ( my $cgi = CGI::Fast->new ) {
    unless ($h->interp->comp_exists($cgi->path_info)) {
	$cgi->path_info($cgi->path_info . "/index.html");
    }
    $h->handle_cgi_object($cgi);
    # _should_ always be tied
}

1;
