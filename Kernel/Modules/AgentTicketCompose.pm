# --
# Kernel/Modules/AgentTicketCompose.pm - to compose and send a message
# Copyright (C) 2001-2008 OTRS AG, http://otrs.org/
# --
# $Id: AgentTicketCompose.pm,v 1.42 2008-05-08 19:46:58 martin Exp $
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see http://www.gnu.org/licenses/gpl-2.0.txt.
# --

package Kernel::Modules::AgentTicketCompose;

use strict;
use warnings;

use Kernel::System::CheckItem;
use Kernel::System::StdAttachment;
use Kernel::System::State;
use Kernel::System::CustomerUser;
use Kernel::System::Web::UploadCache;
use Kernel::System::SystemAddress;
use Mail::Address;

use vars qw($VERSION);
$VERSION = qw($Revision: 1.42 $) [1];

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {%Param};
    bless( $Self, $Type );

    $Self->{Debug} = $Param{Debug} || 0;

    # check all needed objects
    for (qw(TicketObject ParamObject DBObject QueueObject LayoutObject ConfigObject LogObject)) {
        if ( !$Self->{$_} ) {
            $Self->{LayoutObject}->FatalError( Message => "Got no $_!" );
        }
    }

    # some new objects
    $Self->{CustomerUserObject}  = Kernel::System::CustomerUser->new(%Param);
    $Self->{CheckItemObject}     = Kernel::System::CheckItem->new(%Param);
    $Self->{StdAttachmentObject} = Kernel::System::StdAttachment->new(%Param);
    $Self->{StateObject}         = Kernel::System::State->new(%Param);
    $Self->{UploadCachObject}    = Kernel::System::Web::UploadCache->new(%Param);
    $Self->{SystemAddress}       = Kernel::System::SystemAddress->new(%Param);

    # get response format
    $Self->{ResponseFormat} = $Self->{ConfigObject}->Get('Ticket::Frontend::ResponseFormat')
        || '$Data{"Salutation"}
$Data{"OrigFrom"} $Text{"wrote"}:
$Data{"Body"}

$Data{"StdResponse"}

$Data{"Signature"}
';

    # get form id
    $Self->{FormID} = $Self->{ParamObject}->GetParam( Param => 'FormID' );

    # create form id
    if ( !$Self->{FormID} ) {
        $Self->{FormID} = $Self->{UploadCachObject}->FormIDCreate();
    }

    $Self->{Config} = $Self->{ConfigObject}->Get("Ticket::Frontend::$Self->{Action}");

    return $Self;
}

sub Run {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    if ( !$Self->{TicketID} ) {

        # error page
        return $Self->{LayoutObject}->ErrorScreen(
            Message => "Need TicketID is given!",
            Comment => 'Please contact the admin.',
        );
    }

    # check permissions
    if (
        !$Self->{TicketObject}->Permission(
            Type     => $Self->{Config}->{Permission},
            TicketID => $Self->{TicketID},
            UserID   => $Self->{UserID}
        )
        )
    {

        # error screen, don't show ticket
        return $Self->{LayoutObject}->NoPermission(
            Message    => "You need $Self->{Config}->{Permission} permissions!",
            WithHeader => 'yes',
        );
    }
    my %Ticket = $Self->{TicketObject}->TicketGet( TicketID => $Self->{TicketID} );

    # get lock state
    if ( $Self->{Config}->{RequiredLock} ) {
        if ( !$Self->{TicketObject}->LockIsTicketLocked( TicketID => $Self->{TicketID} ) ) {
            $Self->{TicketObject}->LockSet(
                TicketID => $Self->{TicketID},
                Lock     => 'lock',
                UserID   => $Self->{UserID}
            );
            if (
                $Self->{TicketObject}->OwnerSet(
                    TicketID  => $Self->{TicketID},
                    UserID    => $Self->{UserID},
                    NewUserID => $Self->{UserID},
                )
                )
            {

                # show lock state
                $Self->{LayoutObject}->Block(
                    Name => 'PropertiesLock',
                    Data => { %Param, TicketID => $Self->{TicketID}, },
                );
            }
        }
        else {
            my $AccessOk = $Self->{TicketObject}->OwnerCheck(
                TicketID => $Self->{TicketID},
                OwnerID  => $Self->{UserID},
            );
            if ( !$AccessOk ) {
                my $Output = $Self->{LayoutObject}->Header( Value => $Ticket{Number} );
                $Output .= $Self->{LayoutObject}->Warning(
                    Message => "Sorry, you need to be the owner to do this action!",
                    Comment => 'Please change the owner first.',
                );
                $Output .= $Self->{LayoutObject}->Footer();
                return $Output;
            }
            else {
                $Self->{LayoutObject}->Block(
                    Name => 'TicketBack',
                    Data => { %Param, TicketID => $Self->{TicketID}, },
                );
            }
        }
    }
    else {
        $Self->{LayoutObject}->Block(
            Name => 'TicketBack',
            Data => { %Param, %Ticket, },
        );
    }

    # get params
    my %GetParam = ();
    for (
        qw(
        From To Cc Bcc Subject Body InReplyTo ResponseID ReplyArticleID StateID
        ArticleID TimeUnits Year Month Day Hour Minute AttachmentUpload
        AttachmentDelete1 AttachmentDelete2 AttachmentDelete3 AttachmentDelete4
        AttachmentDelete5 AttachmentDelete6 AttachmentDelete7 AttachmentDelete8
        AttachmentDelete9 AttachmentDelete10 AttachmentDelete11 AttachmentDelete12
        AttachmentDelete13 AttachmentDelete14 AttachmentDelete15 AttachmentDelete16
        FormID
        )
        )
    {
        $GetParam{$_} = $Self->{ParamObject}->GetParam( Param => $_ );
    }

    # get ticket free text params
    for ( 1 .. 16 ) {
        $GetParam{"TicketFreeKey$_"} = $Self->{ParamObject}->GetParam( Param => "TicketFreeKey$_" );
        $GetParam{"TicketFreeText$_"}
            = $Self->{ParamObject}->GetParam( Param => "TicketFreeText$_" );
    }

    # get ticket free time params
    for ( 1 .. 6 ) {
        for my $Type (qw(Used Year Month Day Hour Minute)) {
            $GetParam{ "TicketFreeTime" . $_ . $Type }
                = $Self->{ParamObject}->GetParam( Param => "TicketFreeTime" . $_ . $Type );
        }
        if ( !$Self->{ConfigObject}->Get( 'TicketFreeTimeOptional' . $_ ) ) {
            $GetParam{ 'TicketFreeTime' . $_ . 'Used' } = 1;
        }
    }

    # get article free text params
    for ( 1 .. 3 ) {
        $GetParam{"ArticleFreeKey$_"}
            = $Self->{ParamObject}->GetParam( Param => "ArticleFreeKey$_" );
        $GetParam{"ArticleFreeText$_"}
            = $Self->{ParamObject}->GetParam( Param => "ArticleFreeText$_" );
    }

    # send email
    if ( $Self->{Subaction} eq 'SendEmail' ) {
        my %Error = ();
        my %StateData = $Self->{TicketObject}->{StateObject}->StateGet( ID => $GetParam{StateID}, );

        # check pending date
        if ( $StateData{TypeName} && $StateData{TypeName} =~ /^pending/i ) {
            if ( !$Self->{TimeObject}->Date2SystemTime( %GetParam, Second => 0 ) ) {
                $Error{"Date invalid"} = 'invalid';
            }
        }

        # check required FreeTextField (if configured)
        for ( 1 .. 16 ) {
            if ( $Self->{Config}{'TicketFreeText'}{$_} == 2 && $GetParam{"TicketFreeText$_"} eq '' )
            {
                $Error{"TicketFreeTextField$_ invalid"} = 'invalid';
            }
        }

        # attachment delete
        for ( 1 .. 16 ) {
            if ( $GetParam{"AttachmentDelete$_"} ) {
                $Error{AttachmentDelete} = 1;
                $Self->{UploadCachObject}->FormIDRemoveFile(
                    FormID => $Self->{FormID},
                    FileID => $_,
                );
            }
        }

        # attachment upload
        if ( $GetParam{AttachmentUpload} ) {
            $Error{AttachmentUpload} = 1;
            my %UploadStuff = $Self->{ParamObject}->GetUploadAll(
                Param  => "file_upload",
                Source => 'string',
            );
            $Self->{UploadCachObject}->FormIDAddFile(
                FormID => $Self->{FormID},
                %UploadStuff,
            );
        }

        # get all attachments meta data
        my @Attachments = $Self->{UploadCachObject}->FormIDGetAllFilesMeta(
            FormID => $Self->{FormID},
        );

        # check some values
        for (qw(From To Cc Bcc)) {
            if ( $GetParam{$_} ) {
                for my $Email ( Mail::Address->parse( $GetParam{$_} ) ) {
                    if ( !$Self->{CheckItemObject}->CheckEmail( Address => $Email->address() ) ) {
                        $Error{"$_ invalid"} .= $Self->{CheckItemObject}->CheckError();
                    }
                }
            }
        }

        # prepare subject
        my $Tn = $Self->{TicketObject}->TicketNumberLookup( TicketID => $Self->{TicketID} );
        $GetParam{Subject} = $Self->{TicketObject}->TicketSubjectBuild(
            TicketNumber => $Tn,
            Subject => $GetParam{Subject} || '',
        );

        my %ArticleParam = ();

        # run compose modules
        if ( ref $Self->{ConfigObject}->Get('Ticket::Frontend::ArticleComposeModule') eq 'HASH' )
        {
            my %Jobs = %{ $Self->{ConfigObject}->Get('Ticket::Frontend::ArticleComposeModule') };
            for my $Job ( sort keys %Jobs ) {

                # load module
                if ( $Self->{MainObject}->Require( $Jobs{$Job}->{Module} ) ) {
                    my $Object = $Jobs{$Job}->{Module}->new( %{$Self}, Debug => $Self->{Debug} );

                    # get params
                    for ( $Object->Option( %GetParam, Config => $Jobs{$Job} ) ) {
                        $GetParam{$_} = $Self->{ParamObject}->GetParam( Param => $_ );
                    }

                    # run module
                    $Object->Run( %GetParam, Config => $Jobs{$Job} );

                    # ticket params
                    %ArticleParam = (
                        %ArticleParam, $Object->ArticleOption( %GetParam, Config => $Jobs{$Job} )
                    );

                    # get errors
                    %Error = ( %Error, $Object->Error( %GetParam, Config => $Jobs{$Job} ) );
                }
                else {
                    return $Self->{LayoutObject}->FatalError();
                }
            }
        }

        # check if there is an error
        if (%Error) {

            # get free text config options
            my %TicketFreeText = ();
            for ( 1 .. 16 ) {
                $TicketFreeText{"TicketFreeKey$_"} = $Self->{TicketObject}->TicketFreeTextGet(
                    TicketID => $Self->{TicketID},
                    Type     => "TicketFreeKey$_",
                    Action   => $Self->{Action},
                    UserID   => $Self->{UserID},
                );
                $TicketFreeText{"TicketFreeText$_"} = $Self->{TicketObject}->TicketFreeTextGet(
                    TicketID => $Self->{TicketID},
                    Type     => "TicketFreeText$_",
                    Action   => $Self->{Action},
                    UserID   => $Self->{UserID},
                );
            }
            my %TicketFreeTextHTML = $Self->{LayoutObject}->AgentFreeText(
                Config => \%TicketFreeText,
                Ticket => \%GetParam,
            );

            # ticket free time
            my %TicketFreeTimeHTML
                = $Self->{LayoutObject}->AgentFreeDate( %Param, Ticket => \%GetParam, );

            # article free text
            my %ArticleFreeText = ();
            for ( 1 .. 3 ) {
                $ArticleFreeText{"ArticleFreeKey$_"} = $Self->{TicketObject}->ArticleFreeTextGet(
                    TicketID => $Self->{TicketID},
                    Type     => "ArticleFreeKey$_",
                    Action   => $Self->{Action},
                    UserID   => $Self->{UserID},
                );
                $ArticleFreeText{"ArticleFreeText$_"} = $Self->{TicketObject}->ArticleFreeTextGet(
                    TicketID => $Self->{TicketID},
                    Type     => "ArticleFreeText$_",
                    Action   => $Self->{Action},
                    UserID   => $Self->{UserID},
                );
            }
            my %ArticleFreeTextHTML = $Self->{LayoutObject}->TicketArticleFreeText(
                Config  => \%ArticleFreeText,
                Article => \%GetParam,
            );
            my $Output = $Self->{LayoutObject}->Header( Value => $Ticket{TicketNumber} );
            $GetParam{StdResponse} = $GetParam{Body};
            $Output .= $Self->_Mask(
                TicketID       => $Self->{TicketID},
                NextStates     => $Self->_GetNextStates(),
                ResponseFormat => $Self->{LayoutObject}->Ascii2Html( Text => $GetParam{Body} ),
                Errors         => \%Error,
                Attachments    => \@Attachments,
                %Ticket,
                %TicketFreeTextHTML,
                %TicketFreeTimeHTML,
                %ArticleFreeTextHTML,
                %GetParam,
            );
            $Output .= $Self->{LayoutObject}->Footer();
            return $Output;
        }

        # replace <OTRS_TICKET_STATE> with next ticket state name
        if ( $StateData{Name} ) {
            $GetParam{Body} =~ s/<OTRS_TICKET_STATE>/$StateData{Name}/g;
        }

        # get pre loaded attachments
        my @AttachmentData = $Self->{UploadCachObject}->FormIDGetAllFilesData(
            FormID => $Self->{FormID},
        );

        # get submit attachment
        my %UploadStuff = $Self->{ParamObject}->GetUploadAll(
            Param  => 'file_upload',
            Source => 'String',
        );
        if (%UploadStuff) {
            push( @AttachmentData, \%UploadStuff );
        }

        # get recipients
        my $Recipients = '';
        for my $Line (qw(To Cc Bcc)) {
            if ( $GetParam{$Line} ) {
                if ($Recipients) {
                    $Recipients .= ',';
                }
                $Recipients .= $GetParam{$Line};
            }
        }

        # send email
        my $ArticleID = $Self->{TicketObject}->ArticleSend(
            ArticleType    => 'email-external',
            SenderType     => 'agent',
            TicketID       => $Self->{TicketID},
            HistoryType    => 'SendAnswer',
            HistoryComment => "\%\%$Recipients",
            From           => $GetParam{From},
            To             => $GetParam{To},
            Cc             => $GetParam{Cc},
            Bcc            => $GetParam{Bcc},
            Subject        => $GetParam{Subject},
            UserID         => $Self->{UserID},
            Body           => $GetParam{Body},
            InReplyTo      => $GetParam{InReplyTo},
            Charset        => $Self->{LayoutObject}->{UserCharset},
            Type           => 'text/plain',
            Attachment     => \@AttachmentData,
            %ArticleParam,
        );
        if ($ArticleID) {

            # time accounting
            if ( $GetParam{TimeUnits} ) {
                $Self->{TicketObject}->TicketAccountTime(
                    TicketID  => $Self->{TicketID},
                    ArticleID => $ArticleID,
                    TimeUnit  => $GetParam{TimeUnits},
                    UserID    => $Self->{UserID},
                );
            }

            # set ticket free text
            for ( 1 .. 16 ) {
                if ( defined( $GetParam{"TicketFreeKey$_"} ) ) {
                    $Self->{TicketObject}->TicketFreeTextSet(
                        Key      => $GetParam{"TicketFreeKey$_"},
                        Value    => $GetParam{"TicketFreeText$_"},
                        Counter  => $_,
                        TicketID => $Self->{TicketID},
                        UserID   => $Self->{UserID},
                    );
                }
            }

            # set ticket free time
            for ( 1 .. 6 ) {
                if (
                    defined( $GetParam{ "TicketFreeTime" . $_ . "Year" } )
                    && defined( $GetParam{ "TicketFreeTime" . $_ . "Month" } )
                    && defined( $GetParam{ "TicketFreeTime" . $_ . "Day" } )
                    && defined( $GetParam{ "TicketFreeTime" . $_ . "Hour" } )
                    && defined( $GetParam{ "TicketFreeTime" . $_ . "Minute" } )
                    )
                {
                    my %Time;
                    $Time{ "TicketFreeTime" . $_ . "Year" }    = 0;
                    $Time{ "TicketFreeTime" . $_ . "Month" }   = 0;
                    $Time{ "TicketFreeTime" . $_ . "Day" }     = 0;
                    $Time{ "TicketFreeTime" . $_ . "Hour" }    = 0;
                    $Time{ "TicketFreeTime" . $_ . "Minute" }  = 0;
                    $Time{ "TicketFreeTime" . $_ . "Secunde" } = 0;

                    if ( $GetParam{ "TicketFreeTime" . $_ . "Used" } ) {
                        %Time = $Self->{LayoutObject}->TransfromDateSelection(
                            %GetParam,
                            Prefix => "TicketFreeTime" . $_,
                        );
                    }
                    $Self->{TicketObject}->TicketFreeTimeSet(
                        %Time,
                        Prefix   => "TicketFreeTime",
                        TicketID => $Self->{TicketID},
                        Counter  => $_,
                        UserID   => $Self->{UserID},
                    );
                }
            }

            # set article free text
            for ( 1 .. 3 ) {
                if ( defined( $GetParam{"ArticleFreeKey$_"} ) ) {
                    $Self->{TicketObject}->ArticleFreeTextSet(
                        TicketID  => $Self->{TicketID},
                        ArticleID => $ArticleID,
                        Key       => $GetParam{"ArticleFreeKey$_"},
                        Value     => $GetParam{"ArticleFreeText$_"},
                        Counter   => $_,
                        UserID    => $Self->{UserID},
                    );
                }
            }

            # set state
            $Self->{TicketObject}->StateSet(
                TicketID  => $Self->{TicketID},
                ArticleID => $ArticleID,
                StateID   => $GetParam{StateID},
                UserID    => $Self->{UserID},
            );

            # should I set an unlock?
            if ( $StateData{TypeName} =~ /^close/i ) {
                $Self->{TicketObject}->LockSet(
                    TicketID => $Self->{TicketID},
                    Lock     => 'unlock',
                    UserID   => $Self->{UserID},
                );
            }

            # set pending time
            elsif ( $StateData{TypeName} =~ /^pending/i ) {
                $Self->{TicketObject}->TicketPendingTimeSet(
                    UserID   => $Self->{UserID},
                    TicketID => $Self->{TicketID},
                    Year     => $GetParam{Year},
                    Month    => $GetParam{Month},
                    Day      => $GetParam{Day},
                    Hour     => $GetParam{Hour},
                    Minute   => $GetParam{Minute},
                );
            }

            # log use response id and reply article id (useful for response diagnostics)
            $Self->{TicketObject}->HistoryAdd(
                Name =>
                    "ResponseTemplate ($GetParam{ResponseID}/$GetParam{ReplyArticleID}/$ArticleID)",
                HistoryType  => 'Misc',
                TicketID     => $Self->{TicketID},
                CreateUserID => $Self->{UserID},
            );

            # remove pre submited attachments
            $Self->{UploadCachObject}->FormIDRemove( FormID => $GetParam{FormID} );

            # redirect
            if ( $StateData{TypeName} =~ /^close/i ) {
                return $Self->{LayoutObject}->Redirect( OP => $Self->{LastScreenOverview} );
            }
            else {
                return $Self->{LayoutObject}->Redirect(
                    OP =>
                        "Action=AgentTicketZoom&TicketID=$Self->{TicketID}&ArticleID=$ArticleID"
                );
            }
        }
        else {

            # error page
            return $Self->{LayoutObject}->ErrorScreen();
        }
    }
    else {
        my %Error = ();
        my $Output = $Self->{LayoutObject}->Header( Value => $Ticket{TicketNumber} );

        # add std. attachments to email
        if ( $GetParam{ResponseID} ) {
            my %AllStdAttachments = $Self->{StdAttachmentObject}->StdAttachmentsByResponseID(
                ID => $GetParam{ResponseID},
            );
            for ( sort keys %AllStdAttachments ) {
                my %Data = $Self->{StdAttachmentObject}->StdAttachmentGet( ID => $_ );
                $Self->{UploadCachObject}->FormIDAddFile(
                    FormID => $Self->{FormID},
                    %Data,
                );
            }
        }

        # get all attachments meta data
        my @Attachments
            = $Self->{UploadCachObject}->FormIDGetAllFilesMeta( FormID => $Self->{FormID} );

        # get last customer article or selecte article ...
        my %Data = ();
        if ( $GetParam{ArticleID} ) {
            %Data = $Self->{TicketObject}->ArticleGet( ArticleID => $GetParam{ArticleID} );
        }
        else {
            %Data = $Self->{TicketObject}->ArticleLastCustomerArticle(
                TicketID => $Self->{TicketID}
            );
        }

        # check article type and replace To with From (in case)
        if ( $Data{SenderType} !~ /customer/ ) {
            my $To   = $Data{To};
            my $From = $Data{From};

            # set OrigFrom for correct email quoteing (xxxx wrote)
            $Data{OrigFrom} = $Data{From};

            # replace From/To, To/From because sender is agent
            $Data{From}     = $To;
            $Data{To}       = $Data{From};
            $Data{ReplyTo}  = '';
        }
        else {

            # set OrigFrom for correct email quoteing (xxxx wrote)
            $Data{OrigFrom} = $Data{From};
        }

        # build OrigFromName (to only use the realname)
        $Data{OrigFromName} = $Data{OrigFrom};
        $Data{OrigFromName} =~ s/<.*>|\(.*\)|\"|;|,//g;
        $Data{OrigFromName} =~ s/( $)|(  $)//g;

        # get customer data
        my %Customer = ();
        if ( $Ticket{CustomerUserID} ) {
            %Customer = $Self->{CustomerUserObject}->CustomerUserDataGet(
                User => $Ticket{CustomerUserID}
            );
        }

        # check if original content isn't text/plain or text/html, don't use it
        if ( $Data{'ContentType'} ) {
            if ( $Data{'ContentType'} =~ /text\/html/i ) {
                $Data{Body} =~ s/\<.+?\>//gs;
            }
            elsif ( $Data{'ContentType'} !~ /text\/plain/i ) {
                $Data{Body} = "-> no quotable message <-";
            }
        }

        # prepare body, subject, ReplyTo ...
        # rewrap body if exists
        if ( $Data{Body} ) {
            $Data{Body} =~ s/\t/ /g;
            my $Quote = $Self->{ConfigObject}->Get('Ticket::Frontend::Quote');
            if ($Quote) {
                $Data{Body} =~ s/\n/\n$Quote /g;
                $Data{Body} = "\n$Quote " . $Data{Body};
            }
            else {
                $Data{Body} = "\n" . $Data{Body};
                if ( $Data{Created} ) {
                    $Data{Body} = "Date: $Data{Created}\n" . $Data{Body};
                }
                for (qw(Subject ReplyTo Reply-To Cc To From)) {
                    if ( $Data{$_} ) {
                        $Data{Body} = "$_: $Data{$_}\n" . $Data{Body};
                    }
                }
                $Data{Body} = "\n---- Message from $Data{From} ---\n\n" . $Data{Body};
                $Data{Body} .= "\n---- End Message ---\n";
            }
        }
        $Data{Subject} = $Self->{TicketObject}->TicketSubjectBuild(
            TicketNumber => $Ticket{TicketNumber},
            Subject      => $Data{Subject} || '',
        );

        # add not local To addresses to Cc
        for my $Email ( Mail::Address->parse( $Data{To} ) ) {
            my $IsLocal = $Self->{SystemAddress}->SystemAddressIsLocalAddress(
                Address => $Email->address(),
            );
            if (!$IsLocal) {
                if ( $Data{Cc} ) {
                    $Data{Cc} .= ', ';
                }
                $Data{Cc} .= $Email->format();
            }
        }

        # check ReplyTo
        if ( $Data{ReplyTo} ) {
            $Data{To} = $Data{ReplyTo};
        }
        else {
            $Data{To} = $Data{From};

            # try to remove some wrong text to from line (by way of ...)
            # added by some strange mail programs on bounce
            $Data{To} =~ s/(.+?\<.+?\@.+?\>)\s+\(by\s+way\s+of\s+.+?\)/$1/ig;
        }

        # get to email (just "some@example.com")
        for my $Email ( Mail::Address->parse( $Data{To} ) ) {
            $Data{ToEmail} = $Email->address();
        }

        # use database email
        if ( $Customer{UserEmail} && $Data{ToEmail} !~ /^\Q$Customer{UserEmail}\E$/i ) {
            if ( $Self->{ConfigObject}->Get('Ticket::Frontend::ComposeReplaceSenderAddress') ) {
                $Self->{LayoutObject}->Block(
                    Name => 'PropertiesRecipientTo',
                    Data => { To => $Data{To} },
                );
                $Data{To} = $Customer{UserEmail};
            }
            else {
                $Self->{LayoutObject}->Block(
                    Name => 'PropertiesRecipientCc',
                    Data => { Cc => $Customer{UserEmail}, },
                );
                if ( $Data{Cc} ) {
                    $Data{Cc} .= ', ' . $Customer{UserEmail};
                }
                else {
                    $Data{Cc} = $Customer{UserEmail};
                }
            }
        }

        # find duplicate addresses
        my %Recipient = ();
        for my $Type (qw(To Cc Bcc)) {
            if ( $Data{$Type} ) {
                my $NewLine = '';
                for my $Email ( Mail::Address->parse( $Data{$Type} ) ) {
                    my $Address = $Email->address();

                    # only use email addresses with @ inside
                    if ( $Address && $Address =~ /@/ && !$Recipient{$Address} ) {
                        $Recipient{$Address} = 1;
                        my $IsLocal = $Self->{SystemAddress}->SystemAddressIsLocalAddress(
                            Address => $Address,
                        );
                        if ( !$IsLocal ) {
                            if ($NewLine) {
                                $NewLine .= ', ';
                            }
                            $NewLine .= $Email->format();
                        }
                    }
                }
                $Data{$Type} = $NewLine;
            }
        }

        # find queue address
        my %Address = $Self->{QueueObject}->GetSystemAddress(%Ticket);
        $Data{From}        = "$Address{RealName} <$Address{Email}>";
        $Data{Email}       = $Address{Email};
        $Data{RealName}    = $Address{RealName};
        $Data{StdResponse} = $Self->{QueueObject}->GetStdResponse( ID => $GetParam{ResponseID} );

        # prepare salutation & signature
        $Data{Salutation} = $Self->{QueueObject}->GetSalutation(%Ticket);
        $Data{Signature}  = $Self->{QueueObject}->GetSignature(%Ticket);
        for (qw(Signature Salutation StdResponse)) {

            # get and prepare realname
            if ( $Data{$_} =~ /<OTRS_CUSTOMER_REALNAME>/ ) {
                my $From = '';
                if ( $Ticket{CustomerUserID} ) {
                    $From = $Self->{CustomerUserObject}->CustomerName(
                        UserLogin => $Ticket{CustomerUserID}
                    );
                }
                if ( !$From ) {
                    $From = $Data{To} || '';
                    $From =~ s/<.*>|\(.*\)|\"|;|,//g;
                    $From =~ s/( $)|(  $)//g;
                }
                $Data{$_} =~ s/<OTRS_CUSTOMER_REALNAME>/$From/g;
            }

            # current user
            my %User = $Self->{UserObject}->GetUserData(
                UserID => $Self->{UserID},
                Cached => 1,
            );
            for my $UserKey ( keys %User ) {
                if ( $User{$UserKey} ) {
                    $Data{$_} =~ s/<OTRS_Agent_$UserKey>/$User{$UserKey}/gi;
                    $Data{$_} =~ s/<OTRS_CURRENT_$UserKey>/$User{$UserKey}/gi;
                }
            }

            # replace other needed stuff
            $Data{$_} =~ s/<OTRS_FIRST_NAME>/$Self->{UserFirstname}/g;
            $Data{$_} =~ s/<OTRS_LAST_NAME>/$Self->{UserLastname}/g;

            # cleanup
            $Data{$_} =~ s/<OTRS_Agent_.+?>/-/gi;
            $Data{$_} =~ s/<OTRS_CURRENT_.+?>/-/gi;

            # owner user
            my %OwnerUser = $Self->{UserObject}->GetUserData(
                UserID => $Ticket{OwnerID},
                Cached => 1,
            );
            for my $UserKey ( keys %OwnerUser ) {
                if ( $OwnerUser{$UserKey} ) {
                    $Data{$_} =~ s/<OTRS_OWNER_$UserKey>/$OwnerUser{$UserKey}/gi;
                }
            }

            # cleanup
            $Data{$_} =~ s/<OTRS_OWNER_.+?>/-/gi;

            # responsible user
            my %ResponsibleUser = $Self->{UserObject}->GetUserData(
                UserID => $Ticket{ResponsibleID},
                Cached => 1,
            );
            for my $UserKey ( keys %ResponsibleUser ) {
                if ( $ResponsibleUser{$UserKey} ) {
                    $Data{$_} =~ s/<OTRS_RESPONSIBLE_$UserKey>/$ResponsibleUser{$UserKey}/gi;
                }
            }

            # cleanup
            $Data{$_} =~ s/<OTRS_RESPONSIBLE_.+?>/-/gi;

            # replace other needed stuff
            # replace ticket data
            for my $TicketKey ( keys %Ticket ) {
                if ( $Ticket{$TicketKey} ) {
                    $Data{$_} =~ s/<OTRS_TICKET_$TicketKey>/$Ticket{$TicketKey}/gi;
                }
            }

            # cleanup all not needed <OTRS_TICKET_ tags
            $Data{$_} =~ s/<OTRS_TICKET_.+?>/-/gi;

            # replace customer data
            for my $CustomerKey ( keys %Customer ) {
                if ( $Customer{$CustomerKey} ) {
                    $Data{$_} =~ s/<OTRS_CUSTOMER_$CustomerKey>/$Customer{$CustomerKey}/gi;
                    $Data{$_} =~ s/<OTRS_CUSTOMER_DATA_$CustomerKey>/$Customer{$CustomerKey}/gi;
                }
            }

            # cleanup all not needed <OTRS_CUSTOMER_ tags
            $Data{$_} =~ s/<OTRS_CUSTOMER_.+?>/-/gi;
            $Data{$_} =~ s/<OTRS_CUSTOMER_DATA_.+?>/-/gi;

            # replace config options
            $Data{$_} =~ s{<OTRS_CONFIG_(.+?)>}{$Self->{ConfigObject}->Get($1)}egx;
            $Data{$_} =~ s/<OTRS_CONFIG_.+?>/-/gi;
        }

        # check some values
        for (qw(From To Cc Bcc)) {
            if ( $Data{$_} ) {
                for my $Email ( Mail::Address->parse( $Data{$_} ) ) {
                    if ( !$Self->{CheckItemObject}->CheckEmail( Address => $Email->address() ) ) {
                        $Error{"$_ invalid"} .= $Self->{CheckItemObject}->CheckError();
                    }
                }
            }
        }

        # get free text config options
        my %TicketFreeText = ();
        for ( 1 .. 16 ) {
            $TicketFreeText{"TicketFreeKey$_"} = $Self->{TicketObject}->TicketFreeTextGet(
                TicketID => $Self->{TicketID},
                Type     => "TicketFreeKey$_",
                Action   => $Self->{Action},
                UserID   => $Self->{UserID},
            );
            $TicketFreeText{"TicketFreeText$_"} = $Self->{TicketObject}->TicketFreeTextGet(
                TicketID => $Self->{TicketID},
                Type     => "TicketFreeText$_",
                Action   => $Self->{Action},
                UserID   => $Self->{UserID},
            );
        }
        my %TicketFreeTextHTML = $Self->{LayoutObject}->AgentFreeText(
            Ticket => \%Ticket,
            Config => \%TicketFreeText,
        );

        # free time
        my %TicketFreeTime = ();
        for ( 1 .. 6 ) {
            $TicketFreeTime{ "TicketFreeTime" . $_ . 'Optional' }
                = $Self->{ConfigObject}->Get( 'TicketFreeTimeOptional' . $_ ) || 0;
            $TicketFreeTime{ "TicketFreeTime" . $_ . 'Used' }
                = $GetParam{ 'TicketFreeTime' . $_ . 'Used' };

            if ( $Ticket{ "TicketFreeTime" . $_ } ) {
                (
                    $TicketFreeTime{ "TicketFreeTime" . $_ . 'Secunde' },
                    $TicketFreeTime{ "TicketFreeTime" . $_ . 'Minute' },
                    $TicketFreeTime{ "TicketFreeTime" . $_ . 'Hour' },
                    $TicketFreeTime{ "TicketFreeTime" . $_ . 'Day' },
                    $TicketFreeTime{ "TicketFreeTime" . $_ . 'Month' },
                    $TicketFreeTime{ "TicketFreeTime" . $_ . 'Year' }
                    )
                    = $Self->{TimeObject}->SystemTime2Date(
                    SystemTime => $Self->{TimeObject}->TimeStamp2SystemTime(
                        String => $Ticket{ "TicketFreeTime" . $_ },
                    ),
                    );
                $TicketFreeTime{ "TicketFreeTime" . $_ . 'Used' } = 1;
            }
        }
        my %TicketFreeTimeHTML
            = $Self->{LayoutObject}->AgentFreeDate( Ticket => \%TicketFreeTime, );

        # article free text
        my %ArticleFreeText = ();
        for ( 1 .. 3 ) {
            $ArticleFreeText{"ArticleFreeKey$_"} = $Self->{TicketObject}->ArticleFreeTextGet(
                TicketID => $Self->{TicketID},
                Type     => "ArticleFreeKey$_",
                Action   => $Self->{Action},
                UserID   => $Self->{UserID},
            );
            $ArticleFreeText{"ArticleFreeText$_"} = $Self->{TicketObject}->ArticleFreeTextGet(
                TicketID => $Self->{TicketID},
                Type     => "ArticleFreeText$_",
                Action   => $Self->{Action},
                UserID   => $Self->{UserID},
            );
        }
        my %ArticleFreeTextHTML = $Self->{LayoutObject}->TicketArticleFreeText(
            Config  => \%ArticleFreeText,
            Article => \%GetParam,
        );

        # build view ...
        $Output .= $Self->_Mask(
            TicketID       => $Self->{TicketID},
            NextStates     => $Self->_GetNextStates(),
            ResponseFormat => $Self->{ResponseFormat},
            Attachments    => \@Attachments,
            Errors         => \%Error,
            GetParam       => \%GetParam,
            ResponseID     => $GetParam{ResponseID},
            ReplyArticleID => $GetParam{ArticleID},
            %Ticket,
            %Data,
            %TicketFreeTextHTML,
            %TicketFreeTimeHTML,
            %ArticleFreeTextHTML,
        );
        $Output .= $Self->{LayoutObject}->Footer();
        return $Output;
    }
}

sub _GetNextStates {
    my ( $Self, %Param ) = @_;

    # get next states
    my %NextStates = $Self->{TicketObject}->StateList(
        Action   => $Self->{Action},
        TicketID => $Self->{TicketID},
        UserID   => $Self->{UserID},
    );
    return \%NextStates;
}

sub _Mask {
    my ( $Self, %Param ) = @_;

    # build next states string
    if ( !$Self->{Config}->{StateDefault} ) {
        $Param{NextStates}->{''} = '-';
    }
    $Param{'NextStatesStrg'} = $Self->{LayoutObject}->OptionStrgHashRef(
        Data     => $Param{NextStates},
        Name     => 'StateID',
        Selected => $Param{NextState} || $Self->{Config}->{StateDefault},
    );

    # prepare errors!
    if ( $Param{Errors} ) {
        for ( keys %{ $Param{Errors} } ) {
            $Param{$_} = "* " . $Self->{LayoutObject}->Ascii2Html( Text => $Param{Errors}->{$_} );
        }
    }

    # pending data string
    $Param{PendingDateString} = $Self->{LayoutObject}->BuildDateSelection(
        %Param,
        Format => 'DateInputFormatLong',
        DiffTime => $Self->{ConfigObject}->Get('Ticket::Frontend::PendingDiffTime') || 0,
    );

    # js for time accounting
    if ( $Self->{ConfigObject}->Get('Ticket::Frontend::AccountTime') ) {
        $Self->{LayoutObject}->Block(
            Name => 'TimeUnitsJs',
            Data => \%Param,
        );
    }
    $Self->{LayoutObject}->Block(
        Name => 'Content',
        Data => {
            FormID => $Self->{FormID},
            %Param,
        },
    );

    # run compose modules
    if ( ref $Self->{ConfigObject}->Get('Ticket::Frontend::ArticleComposeModule') eq 'HASH' ) {
        my %Jobs = %{ $Self->{ConfigObject}->Get('Ticket::Frontend::ArticleComposeModule') };
        for my $Job ( sort keys %Jobs ) {

            # load module
            if ( $Self->{MainObject}->Require( $Jobs{$Job}->{Module} ) ) {
                my $Object = $Jobs{$Job}->{Module}->new( %{$Self}, Debug => $Self->{Debug}, );

                # get params
                for ( sort keys %{ $Param{GetParam} } ) {
                    if ( !$Param{GetParam}->{$_} && $Param{$_} ) {
                        $Param{GetParam}->{$_} = $Param{$_};
                    }
                }
                for ( $Object->Option( %Param, %{ $Param{GetParam} }, Config => $Jobs{$Job} ) ) {
                    $Param{GetParam}->{$_} = $Self->{ParamObject}->GetParam( Param => $_ );
                }

                # run module
                $Object->Run( %Param, %{ $Param{GetParam} }, Config => $Jobs{$Job} );

                # get errors
                %{ $Param{Errors} } = (
                    %{ $Param{Errors} },
                    $Object->Error( %{ $Param{GetParam} }, Config => $Jobs{$Job} )
                );
            }
            else {
                return $Self->{LayoutObject}->FatalError();
            }
        }
    }

    # ticket free text
    for my $Count ( 1 .. 16 ) {
        if ( $Self->{Config}->{'TicketFreeText'}->{$Count} ) {
            $Self->{LayoutObject}->Block(
                Name => 'TicketFreeText',
                Data => {
                    TicketFreeKeyField  => $Param{ 'TicketFreeKeyField' . $Count },
                    TicketFreeTextField => $Param{ 'TicketFreeTextField' . $Count },
                    Count               => $Count,
                    %Param,
                },
            );
            $Self->{LayoutObject}->Block(
                Name => 'TicketFreeText' . $Count,
                Data => { %Param, Count => $Count, },
            );
        }
    }
    for my $Count ( 1 .. 6 ) {
        if ( $Self->{Config}->{'TicketFreeTime'}->{$Count} ) {
            $Self->{LayoutObject}->Block(
                Name => 'TicketFreeTime',
                Data => {
                    TicketFreeTimeKey => $Self->{ConfigObject}->Get( 'TicketFreeTimeKey' . $Count ),
                    TicketFreeTime    => $Param{ 'TicketFreeTime' . $Count },
                    Count             => $Count,
                },
            );
            $Self->{LayoutObject}->Block(
                Name => 'TicketFreeTime' . $Count,
                Data => { %Param, Count => $Count, },
            );
        }
    }

    # article free text
    for my $Count ( 1 .. 3 ) {
        if ( $Self->{Config}->{'ArticleFreeText'}->{$Count} ) {
            $Self->{LayoutObject}->Block(
                Name => 'ArticleFreeText',
                Data => {
                    ArticleFreeKeyField  => $Param{ 'ArticleFreeKeyField' . $Count },
                    ArticleFreeTextField => $Param{ 'ArticleFreeTextField' . $Count },
                    Count                => $Count,
                },
            );
            $Self->{LayoutObject}->Block(
                Name => 'ArticleFreeText' . $Count,
                Data => { %Param, Count => $Count, },
            );
        }
    }

    # show time accounting box
    if ( $Self->{ConfigObject}->Get('Ticket::Frontend::AccountTime') ) {
        $Self->{LayoutObject}->Block(
            Name => 'TimeUnits',
            Data => \%Param,
        );
    }

    # show spell check
    if (
        $Self->{ConfigObject}->Get('SpellChecker')
        && $Self->{LayoutObject}->{BrowserJavaScriptSupport}
        )
    {
        $Self->{LayoutObject}->Block(
            Name => 'SpellCheck',
            Data => {},
        );
    }

    # show address book
    if ( $Self->{LayoutObject}->{BrowserJavaScriptSupport} ) {
        $Self->{LayoutObject}->Block(
            Name => 'AddressBook',
            Data => {},
        );
    }

    # show attachments
    for my $DataRef ( @{ $Param{Attachments} } ) {
        $Self->{LayoutObject}->Block(
            Name => 'Attachment',
            Data => $DataRef,
        );
    }

    # java script check for required free text fields by form submit
    for my $Key ( keys %{ $Self->{Config}->{TicketFreeText} } ) {
        if ( $Self->{Config}->{TicketFreeText}->{$Key} == 2 ) {
            $Self->{LayoutObject}->Block(
                Name => 'TicketFreeTextCheckJs',
                Data => {
                    TicketFreeTextField => "TicketFreeText$Key",
                    TicketFreeKeyField  => "TicketFreeKey$Key",
                },
            );
        }
    }

    # java script check for required free time fields by form submit
    for my $Key ( keys %{ $Self->{Config}->{TicketFreeTime} } ) {
        if ( $Self->{Config}->{TicketFreeTime}->{$Key} == 2 ) {
            $Self->{LayoutObject}->Block(
                Name => 'TicketFreeTimeCheckJs',
                Data => {
                    TicketFreeTimeCheck => 'TicketFreeTime' . $Key . 'Used',
                    TicketFreeTimeField => 'TicketFreeTime' . $Key,
                    TicketFreeTimeKey   => $Self->{ConfigObject}->Get( 'TicketFreeTimeKey' . $Key ),
                },
            );
        }
    }

    # create & return output
    return $Self->{LayoutObject}->Output( TemplateFile => 'AgentTicketCompose', Data => \%Param );
}

1;
