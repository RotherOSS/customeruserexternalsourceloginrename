# --
# OTOBO is a web-based ticketing system for service organisations.
# --
# Copyright (C) 2001-2020 OTRS AG, https://otrs.com/
# Copyright (C) 2019-2024 Rother OSS GmbH, https://otobo.io/
# --
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later version.
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
# --

package Kernel::System::Console::Command::Admin::CustomerUser::ExternalSourceLoginRename;

use v5.24;
use strict;
use warnings;
use namespace::autoclean;
use utf8;

use parent qw(Kernel::System::Console::BaseCommand);

# core modules

# CPAN modules

# OTOBO modules

our @ObjectDependencies = (
    'Kernel::System::CustomerUser',
    'Kernel::System::JSON',
);

sub Configure {
    my ( $Self, %Param ) = @_;

    $Self->Description(<<'END_DESCRIPTION');
Change the login names of customer users. The passed parameters are the variables, first item, in
the customer user map.
END_DESCRIPTION

    $Self->AddOption(
        Name        => 'old-login-field',
        Description => 'Attribute of the CustomerUser map that holds the old login name',
        Required    => 1,
        HasValue    => 1,
        ValueRegex  => qr/^\S{3,}$/smx,
    );
    $Self->AddOption(
        Name        => 'new-login-field',
        Description => 'Attribute of the CustomerUser map that holds the new login name',
        Required    => 1,
        HasValue    => 1,
        ValueRegex  => qr/^\S{3,}$/smx,
    );
    $Self->AddOption(
        Name        => 'use-batches',
        Description => 'search in batches - i.e. instead of Filter="*" search for "a*"-"9*" (1), or "aa*"-"99*" (2), and so forth',
        Required    => 0,
        HasValue    => 1,
        ValueRegex  => qr/^\d$/smx,
    );
    $Self->AddOption(
        Name        => 'dry-run',
        Description => 'only print out the renamings and problematic cases',
        Required    => 0,
        HasValue    => 0,
    );
    $Self->AddOption(
        Name        => 'limit',
        Description => 'limit the number of renamed customer users',
        Required    => 0,
        HasValue    => 1,
        ValueRegex  => qr/^[0-9]+$/smx,
    );
    $Self->AddOption(
        Name        => 'force',
        Description => 'proceed with renaming even if there are errors reported',
        Required    => 0,
        HasValue    => 0,
    );

    return;
}

sub Run {
    my ( $Self, %Param ) = @_;

    $Self->Print("<yellow>Getting list of customer users</yellow>\n");

    # get needed objects
    my $CustomerUserObject = $Kernel::OM->Get('Kernel::System::CustomerUser');
    my $JSONObject         = $Kernel::OM->Get('Kernel::System::JSON');

    # Parameter Check
    my $OldLoginField = $Self->GetOption('old-login-field');
    if ( !$CustomerUserObject->GetFieldConfig( FieldName => $OldLoginField ) ) {
        die "invalid value '$OldLoginField' for parameter --old-login-field";
    }
    my $NewLoginField = $Self->GetOption('new-login-field');
    if ( !$CustomerUserObject->GetFieldConfig( FieldName => $NewLoginField ) ) {
        die "invalid value '$NewLoginField' for parameter --new-login-field";
    }

    # first collect the mapping, using a high search limit per default
    my $Limit         = $Self->GetOption('limit') || 100_000_000;
    my $BatchDepth    = $Self->GetOption('use-batches');
    my @SearchBatches = ('');

    if ( $BatchDepth ) {
        # build "aa", "ab", ..., "3x", "3y", ..., "99"; in desired depth
        while ( $BatchDepth-- > 0 ) {
            my @NextDepth;
            for my $Prefix ( @SearchBatches ) {
                for my $Char ( 'a'..'z', 0..9 ) {
                    push @NextDepth, $Prefix.$Char;
                }
            }
            @SearchBatches = @NextDepth;
        }
    }

    my %CustomerUserList;
    for my $Prefix ( @SearchBatches ) {
        my %SearchResult = $CustomerUserObject->CustomerSearch(
            Search => $Prefix . '*',
            Valid  => 0,
            Limit  => $Limit,
        );

        %CustomerUserList = ( %CustomerUserList, %SearchResult );
    }

    my $NumCustomerUsers = keys %CustomerUserList;
    $Self->Print("Found $NumCustomerUsers customer users\n");

    my @Old2NewMappings;
    my %Old2CustomerUserData;
    my $NumSkipped = 0;
    CUSTOMER_USER_ID:
    for my $CustomerUserID ( sort keys %CustomerUserList ) {
        my %CustomerUserData = $CustomerUserObject->CustomerUserDataGet(
            User => $CustomerUserID,
        );
        if ( !%CustomerUserData ) {
            $Self->Print("<yellow>Could not retrieve data for $CustomerUserID.</yellow>\n");
            $NumSkipped++;

            next CUSTOMER_USER_ID;
        }

        my $OldLogin = $CustomerUserData{$OldLoginField};
        if ( !$OldLogin ) {
            $Self->Print("<yellow>Could not retrieve old login for $CustomerUserID.</yellow>\n");
            $NumSkipped++;

            next CUSTOMER_USER_ID;
        }
        $Old2CustomerUserData{$OldLogin} = \%CustomerUserData;    # needed e.g. for elasticsearch upddate

        # CustomerID is not needed
        #my $CustomerID = $CustomerUserData{UserCustomerID};
        #if ( !$CustomerID ) {
        #    $Self->Print("<yellow>Could not retrieve customer id for $CustomerUserID.</yellow>\n");
        #    $NumSkipped++;

        #    next CUSTOMER_USER_ID;
        #}

        my $NewLogin = $CustomerUserData{$NewLoginField};
        if ( !$NewLogin ) {
            $Self->Print("<yellow>Could not retrieve new login for $CustomerUserID.</yellow>\n");
            $NumSkipped++;

            next CUSTOMER_USER_ID;
        }

        if ( $NewLogin eq $OldLogin ) {
            $Self->Print("<yellow>nothing to do for $OldLogin as the login is not changed</yellow>\n");
            $NumSkipped++;

            next CUSTOMER_USER_ID;
        }

        push @Old2NewMappings, [ $OldLogin, $NewLogin ];
    }
    if ($NumSkipped) {
        $Self->Print("<yellow>Skipped $NumSkipped customer users</yellow>\n");
    }

    # create simple mapping
    # identify problematic cases
    # The CustomerID does not change
    my ( %Old2New, %Old2NewList, %New4OldList );
    for my $Old2NewRef (@Old2NewMappings) {
        my ( $Old, $New ) = $Old2NewRef->@*;

        # the simple mapping that will actually be used
        $Old2New{$Old} = $New;

        # only for the sanity checks
        $Old2NewList{$Old} //= [];
        push $Old2NewList{$Old}->@*, $New;
        $New4OldList{$New} //= [];
        push $New4OldList{$New}->@*, $Old;
    }

    # check consistency of the mapping
    my $NumErrors = 0;
    for my $Old ( grep { $Old2NewList{$_}->@* > 1 } keys %Old2NewList ) {
        my $List = join ', ', map {qq{"$_"}} $Old2NewList{$Old}->@*;
        $Self->PrintError("duplicate mapping: $Old maps to $List");
        $NumErrors++;
    }
    for my $New ( grep { $New4OldList{$_}->@* > 1 } keys %New4OldList ) {
        my $List = join ', ', map {qq{"$_"}} $New4OldList{$New}->@*;
        $Self->PrintError("duplicate mapping: $New is mapped by $List");
        $NumErrors++;
    }

    if ($NumErrors) {
        $Self->Print("<yellow>Encountered $NumErrors errors</yellow>\n");
    }

    # dry run
    if ( $Self->GetOption('dry-run') ) {
        my $JSONString = $JSONObject->Encode(
            Data     => \%Old2New,
            SortKeys => 1,
            Pretty   => 1,
        );
        $Self->Print("Mapping of old login to new login:\n$JSONString");

        return $Self->ExitCodeOk;
    }

    if ($NumErrors) {
        if ( !$Self->GetOption('force') ) {
            $Self->PrintError("Abort the renaming because there were errors reported");

            return $Self->ExitCodeError;
        }

        $Self->Print("<yellow>Proceeding despite reported errors because --force was passed</yellow>\n");
    }

    # actual renaming, by triggering events
    for my $Old ( sort keys %Old2New ) {
        my $New = $Old2New{$Old};
        $CustomerUserObject->EventHandler(
            Event => 'CustomerUserUpdate',
            Data  => {
                UserLogin => $Old,
                OldData   => {
                    $Old2CustomerUserData{$Old}->%*,
                    UserLogin => $Old,
                },
                NewData => {
                    $Old2CustomerUserData{$Old}->%*,
                    UserLogin => $New,
                },
            },
            UserID => 1,    # no checking of privileges
        );
    }

    $CustomerUserObject->EventHandlerTransaction;

    $Self->Print("finished\n");

    return $Self->ExitCodeOk;
}

1;
