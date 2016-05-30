package Serge::Sync::Plugin::TranslationService::crowdin;
use parent Serge::Sync::Plugin::Base::TranslationService, Serge::Interface::SysCmdRunner;

use strict;

use Serge::Util qw(subst_macros read_and_normalize_file);
use File::Temp;

sub name {
    return 'Crowdin Translation Service (https://crowdin.com/) synchronization plugin';
}

sub init {
    my $self = shift;

    $self->SUPER::init( @_ );

    $self->{optimizations} = 1; # set to undef to disable optimizations

    $self->merge_schema( {
            crowdin_cli_path  => 'STRING',
            crowdin_config_template_path => 'STRING',
            project_base_path  => 'STRING',
            crowdin_project_api_key  => 'STRING'
        } );
}

sub validate_data {
    my ($self) = @_;

    $self->SUPER::validate_data;

    $self->{data}->{crowdin_cli_path} = subst_macros( $self->{data}->{crowdin_cli_path} );
    $self->{data}->{crowdin_config_template_path} = subst_macros( $self->{data}->{crowdin_config_template_path} );
    $self->{data}->{project_base_path} = subst_macros( $self->{data}->{project_base_path} );
    $self->{data}->{crowdin_project_api_key} = subst_macros( $self->{data}->{crowdin_project_api_key} );

    die "'crowdin_cli_path' not defined" unless defined $self->{data}->{crowdin_cli_path};
    die "'crowdin_project_api_key' not defined" unless defined $self->{data}->{crowdin_project_api_key};

    die "'crowdin_config_template_path' not defined" unless defined $self->{data}->{crowdin_config_template_path};
    die "'crowdin_config_template_path', which is set to '$self->{data}->{crowdin_config_template_path}', does not point to a valid file.\n" unless -f $self->{data}->{crowdin_config_template_path};

    die "'project_base_path' not defined" unless defined $self->{data}->{project_base_path};
}

sub prepare_crowdin_cli_config {
    my ($self) = @_;

    print "\nProcessing Crowdin config template: ".$self->{data}->{crowdin_config_template_path};
    print "\nUsing Base path: ".$self->{data}->{project_base_path};

    my $crowdin_config_template_content = read_and_normalize_file($self->{data}->{crowdin_config_template_path});

    $crowdin_config_template_content =~ s/%API_KEY%/$self->{data}->{crowdin_project_api_key}/ge;
    $crowdin_config_template_content =~ s/%BASE_PATH%/$self->{data}->{project_base_path}/ge;

    my $crowdin_config_file_path = tmpnam();
    #    my $crowdin_config_file_path = $self->{data}->{project_base_path}."/crowdin.yaml";

    open(my $fh, '>', $crowdin_config_file_path) or die "Could not open file for write access'".$crowdin_config_file_path."'";
    print $fh $crowdin_config_template_content;
    close $fh;

    print "\nSaved Crowdin config into: ".$crowdin_config_file_path;

    return $crowdin_config_file_path
}

sub pull_ts {
    my ($self, $langs) = @_;
    print "\nDownload translation from Crowdin";

    my $crowdin_cli_config_path = prepare_crowdin_cli_config($self);

    my $command = "java -jar ".$self->{data}->{crowdin_cli_path}." -c ".$crowdin_cli_config_path." download";

    print "\nRunning Crowdin command ".$command." \n\n";

    return $self->run_cmd( $command, 1 );
}

sub push_ts {
    my ($self, $langs) = @_;
    print "\nUpload translation from Crowdin";

    my $crowdin_cli_config_path = prepare_crowdin_cli_config($self);

    my $command = "java -jar ".$self->{data}->{crowdin_cli_path}." -c ".$crowdin_cli_config_path." upload source";

    print "\nRunning Crowdin command ".$command." \n\n";

    return $self->run_cmd( $command, 1 );
}


1;