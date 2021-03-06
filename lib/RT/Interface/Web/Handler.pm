# BEGIN BPS TAGGED BLOCK {{{
#
# COPYRIGHT:
#
# This software is Copyright (c) 1996-2010 Best Practical Solutions, LLC
#                                          <jesse@bestpractical.com>
#
# (Except where explicitly superseded by other copyright notices)
#
#
# LICENSE:
#
# This work is made available to you under the terms of Version 2 of
# the GNU General Public License. A copy of that license should have
# been provided with this software, but in any event can be snarfed
# from www.gnu.org.
#
# This work is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
# 02110-1301 or visit their web page on the internet at
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.html.
#
#
# CONTRIBUTION SUBMISSION POLICY:
#
# (The following paragraph is not intended to limit the rights granted
# to you to modify and distribute this software under the terms of
# the GNU General Public License and is only of importance to you if
# you choose to contribute your changes and enhancements to the
# community by submitting them to Best Practical Solutions, LLC.)
#
# By intentionally submitting any modifications, corrections or
# derivatives to this work, or any other work intended for use with
# Request Tracker, to Best Practical Solutions, LLC, you confirm that
# you are the copyright holder for those contributions and you grant
# Best Practical Solutions,  LLC a nonexclusive, worldwide, irrevocable,
# royalty-free, perpetual, license to use, copy, create derivative
# works based on those contributions, and sublicense and distribute
# those contributions and any derivatives thereof.
#
# END BPS TAGGED BLOCK }}}

package RT::Interface::Web::Handler;
use warnings;
use strict;

use CGI qw/-private_tempfiles/;
use MIME::Entity;
use Text::Wrapper;
use CGI::Cookie;
use Time::ParseDate;
use Time::HiRes;
use HTML::Entities;
use HTML::Scrubber;
use RT::Interface::Web;
use RT::Interface::Web::Request;
use File::Path qw( rmtree );
use File::Glob qw( bsd_glob );
use File::Spec::Unix;

sub DefaultHandlerArgs  { (
    comp_root => [
        [ local    => $RT::MasonLocalComponentRoot ],
        (map {[ "plugin-".$_->Name =>  $_->ComponentRoot ]} @{RT->Plugins}),
        [ standard => $RT::MasonComponentRoot ]
    ],
    default_escape_flags => 'h',
    data_dir             => "$RT::MasonDataDir",
    allow_globals        => [qw(%session)],
    # Turn off static source if we're in developer mode.
    static_source        => (RT->Config->Get('DevelMode') ? '0' : '1'), 
    use_object_files     => (RT->Config->Get('DevelMode') ? '0' : '1'), 
    autoflush            => 0,
    error_format         => (RT->Config->Get('DevelMode') ? 'html': 'brief'),
    request_class        => 'RT::Interface::Web::Request',
    named_component_subs => $INC{'Devel/Cover.pm'} ? 1 : 0,
) };

sub InitSessionDir {
    # Activate the following if running httpd as root (the normal case).
    # Resets ownership of all files created by Mason at startup.
    # Note that mysql uses DB for sessions, so there's no need to do this.
    unless ( RT->Config->Get('DatabaseType') =~ /(?:mysql|Pg)/ ) {

        # Clean up our umask to protect session files
        umask(0077);

        if ($CGI::MOD_PERL and $CGI::MOD_PERL < 1.9908 ) {

            chown( Apache->server->uid, Apache->server->gid,
                $RT::MasonSessionDir )
            if Apache->server->can('uid');
        }

        # Die if WebSessionDir doesn't exist or we can't write to it
        stat($RT::MasonSessionDir);
        die "Can't read and write $RT::MasonSessionDir"
        unless ( ( -d _ ) and ( -r _ ) and ( -w _ ) );
    }

}


use UNIVERSAL::require;
sub NewHandler {
    my $class = shift;
    $class->require or die $!;
    my $handler = $class->new(
        DefaultHandlerArgs(),
        RT->Config->Get('MasonParameters'),
        @_
    );
  
    $handler->interp->set_escape( h => \&RT::Interface::Web::EscapeUTF8 );
    $handler->interp->set_escape( u => \&RT::Interface::Web::EscapeURI  );
    return($handler);
}

=head2 _mason_dir_index

=cut

sub _mason_dir_index {
    my ($self, $interp, $path) = @_;
    $path =~ s!/$!!;
    if (   !$interp->comp_exists( $path )
         && $interp->comp_exists( $path . "/index.html" ) )
    {
        return $path . "/index.html";
    }

    return $path;
}


=head2 CleanupRequest

Clean ups globals, caches and other things that could be still
there from previous requests:

=over 4

=item Rollback any uncommitted transaction(s)

=item Flush the ACL cache

=item Flush records cache of the L<DBIx::SearchBuilder> if
WebFlushDbCacheEveryRequest option is enabled, what is true by default
and is not recommended to change.

=item Clean up state of RT::Action::SendEmail using 'CleanSlate' method

=item Flush tmp GnuPG key preferences

=back

=cut

sub CleanupRequest {

    if ( $RT::Handle && $RT::Handle->TransactionDepth ) {
        $RT::Handle->ForceRollback;
        $RT::Logger->crit(
            "Transaction not committed. Usually indicates a software fault."
            . "Data loss may have occurred" );
    }

    # Clean out the ACL cache. the performance impact should be marginal.
    # Consistency is imprived, too.
    RT::Principal->InvalidateACLCache();
    DBIx::SearchBuilder::Record::Cachable->FlushCache
      if ( RT->Config->Get('WebFlushDbCacheEveryRequest')
        and UNIVERSAL::can(
            'DBIx::SearchBuilder::Record::Cachable' => 'FlushCache' ) );

    # cleanup global squelching of the mails
    require RT::Action::SendEmail;
    RT::Action::SendEmail->CleanSlate;
    
    if (RT->Config->Get('GnuPG')->{'Enable'}) {
        require RT::Crypt::GnuPG;
        RT::Crypt::GnuPG::UseKeyForEncryption();
        RT::Crypt::GnuPG::UseKeyForSigning( undef );
    }

    %RT::Ticket::MERGE_CACHE = ( effective => {}, merged => {} );

    # RT::System persists between requests, so its attributes cache has to be
    # cleared manually. Without this, for example, subject tags across multiple
    # processes will remain cached incorrectly
    delete $RT::System->{attributes};

    # Explicitly remove any tmpfiles that GPG opened, and close their
    # filehandles.  unless we are doing inline psgi testing, which kills all the tmp file created by tests.
    File::Temp::cleanup()
            unless $INC{'Test/WWW/Mechanize/PSGI.pm'};


}


# PSGI App

use RT::Interface::Web::Handler;
use CGI::Emulate::PSGI;
use Plack::Request;
use Plack::Util;
use Encode qw(encode_utf8);

sub PSGIApp {
    my $self = shift;

    # XXX: this is fucked
    require HTML::Mason::CGIHandler;
    require HTML::Mason::PSGIHandler::Streamy;
    my $h = RT::Interface::Web::Handler::NewHandler('HTML::Mason::PSGIHandler::Streamy');

    $self->InitSessionDir;

    return sub {
        my $env = shift;
        RT::ConnectToDatabase() unless RT->InstallMode;

        my $req = Plack::Request->new($env);

        $env->{PATH_INFO} = $self->_mason_dir_index( $h->interp, $req->path_info);

        my $ret;
        {
            # XXX: until we get rid of all $ENV stuff.
            local %ENV = (%ENV, CGI::Emulate::PSGI->emulate_environment($env));

            $ret = $h->handle_psgi($env);
        }

        $RT::Logger->crit($@) if $@ && $RT::Logger;
        warn $@ if $@ && !$RT::Logger;
        if (ref($ret) eq 'CODE') {
            my $orig_ret = $ret;
            $ret = sub {
                my $respond = shift;
                local %ENV = (%ENV, CGI::Emulate::PSGI->emulate_environment($env));
                $orig_ret->($respond);
            };
        }

        return $self->_psgi_response_cb($ret,
                                        sub {
                                            $self->CleanupRequest()
                                        });
};

sub _psgi_response_cb {
    my $self = shift;
    my ($ret, $cleanup) = @_;
    Plack::Util::response_cb
            ($ret,
             sub {
                 return sub {
                     if (!defined $_[0]) {
                         $cleanup->();
                         return '';
                     }
                     return utf8::is_utf8($_[0]) ? encode_utf8($_[0]) : $_[0];
                     return $_[0];
                 };
             });
    }
}

1;
