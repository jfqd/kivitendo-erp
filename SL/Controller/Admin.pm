package SL::Controller::Admin;

use strict;

use parent qw(SL::Controller::Base);

use IO::Dir;
use List::Util qw(first);

use SL::Common ();
use SL::DB::AuthUser;
use SL::DB::AuthGroup;
use SL::DB::Printer;
use SL::Helper::Flash;
use SL::Locale::String qw(t8);
use SL::System::InstallationLock;
use SL::User;
use SL::Layout::AdminLogin;

use Rose::Object::MakeMethods::Generic
(
  'scalar --get_set_init' => [ qw(client user group printer db_cfg is_locked
                                  all_dateformats all_numberformats all_countrycodes all_stylesheets all_menustyles all_clients all_groups all_users all_rights all_printers
                                  all_dbsources all_used_dbsources all_accounting_methods all_inventory_systems all_profit_determinations all_charts) ],
);

__PACKAGE__->run_before(\&setup_layout);
__PACKAGE__->run_before(\&setup_client, only => [ qw(list_printers new_printer edit_printer save_printer delete_printer) ]);

sub get_auth_level { "admin" };
sub keep_auth_vars {
  my ($class, %params) = @_;
  return $params{action} eq 'login';
}

#
# actions: login, logout
#

sub action_login {
  my ($self) = @_;

  return $self->login_form if !$::form->{do_login};
  return                   if !$self->authenticate_root;
  return                   if !$self->check_auth_db_and_tables;
  return                   if  $self->apply_dbupgrade_scripts;

  $self->redirect_to(action => 'show');
}

sub action_logout {
  my ($self) = @_;
  $::auth->destroy_session;
  $self->redirect_to(action => 'login');
}

#
# actions: creating the authentication database & tables, applying database ugprades
#

sub action_apply_dbupgrade_scripts {
  my ($self) = @_;

  return if $self->apply_dbupgrade_scripts;
  $self->redirect_to(action => 'show');
}

sub action_create_auth_db {
  my ($self) = @_;

  $::auth->create_database(superuser          => $::form->{db_superuser},
                           superuser_password => $::form->{db_superuser_password},
                           template           => $::form->{db_template});
  $self->check_auth_db_and_tables;
}

sub action_create_auth_tables {
  my ($self) = @_;

  $::auth->create_tables;
  $::auth->set_session_value('admin_password', $::lx_office_conf{authentication}->{admin_password});
  $::auth->create_or_refresh_session;

  return if $self->apply_dbupgrade_scripts;

  my $group = (SL::DB::Manager::AuthGroup->get_all(limit => 1))[0];
  if (!$group) {
    SL::DB::AuthGroup->new(
      name        => t8('Full Access'),
      description => t8('Full access to all functions'),
      rights      => [ map { SL::DB::AuthGroupRight->new(right => $_, granted => 1) } $::auth->all_rights ],
    )->save;
  }

  $self->action_login;
}

#
# actions: users
#

sub action_show {
  my ($self) = @_;

  $self->render(
    "admin/show",
    title => "kivitendo " . t8('Administration'),
  );
}

sub action_new_user {
  my ($self) = @_;

  $self->user(SL::DB::AuthUser->new(
    config_values => {
      vclimit      => 200,
      countrycode  => "de",
      numberformat => "1.000,00",
      dateformat   => "dd.mm.yy",
      stylesheet   => "kivitendo.css",
      menustyle    => "neu",
    },
  ));

  $self->edit_user_form(title => t8('Create a new user'));
}

sub action_edit_user {
  my ($self) = @_;
  $self->edit_user_form(title => t8('Edit User'));
}

sub action_save_user {
  my ($self) = @_;
  my $params = delete($::form->{user})          || { };
  my $props  = delete($params->{config_values}) || { };
  my $is_new = !$params->{id};

  # Assign empty arrays if the browser doesn't send those controls.
  $params->{clients} ||= [];
  $params->{groups}  ||= [];

  $self->user($is_new ? SL::DB::AuthUser->new : SL::DB::AuthUser->new(id => $params->{id})->load)
    ->assign_attributes(%{ $params })
    ->config_values({ %{ $self->user->config_values }, %{ $props } });

  my @errors = $self->user->validate;

  if (@errors) {
    flash('error', @errors);
    $self->edit_user_form(title => $is_new ? t8('Create a new user') : t8('Edit User'));
    return;
  }

  $self->user->save;

  if ($::auth->can_change_password && $::form->{new_password}) {
    $::auth->change_password($self->user->login, $::form->{new_password});
  }

  flash_later('info', $is_new ? t8('The user has been created.') : t8('The user has been saved.'));
  $self->redirect_to(action => 'show');
}

sub action_delete_user {
  my ($self) = @_;

  my @clients = @{ $self->user->clients || [] };

  # backup user metadata (email, name, etc)
  my $user_config_values_ref = $self->user->config_values();
  my $login =$self->user->login;

  if (!$self->user->delete) {
    flash('error', t8('The user could not be deleted.'));
    $self->edit_user_form(title => t8('Edit User'));
    return;
  }

  # Flag corresponding entries in 'employee' as deleted.
  # and restore the most important user data in employee
  # TODO try and catch the whole transaction {user->delete; update employee} {exception}
  foreach my $client (@clients) {
    my $dbh = $client->dbconnect(AutoCommit => 1) || next;
    $dbh->do(qq|UPDATE employee SET deleted = TRUE, name = ?, deleted_email = ?,
                deleted_tel = ?, deleted_fax = ?, deleted_signature = ? WHERE login = ?|,undef,
              $user_config_values_ref->{name}, $user_config_values_ref->{email},
              $user_config_values_ref->{tel}, $user_config_values_ref->{fax},
              $user_config_values_ref->{signature}, $self->user->login);
    $dbh->disconnect;
  }

  flash_later('info', t8('The user has been deleted.'));
  $self->redirect_to(action => 'show');
}

#
# actions: clients
#

sub action_new_client {
  my ($self) = @_;

  $self->client(SL::DB::AuthClient->new(
    dbhost   => $::auth->{DB_config}->{host},
    dbport   => $::auth->{DB_config}->{port},
    dbuser   => $::auth->{DB_config}->{user},
    dbpasswd => $::auth->{DB_config}->{password},
  ));

  $self->edit_client_form(title => t8('Create a new client'));
}

sub action_edit_client {
  my ($self) = @_;
  $self->edit_client_form(title => t8('Edit Client'));
}

sub action_save_client {
  my ($self) = @_;
  my $params = delete($::form->{client}) || { };
  my $is_new = !$params->{id};

  # Assign empty arrays if the browser doesn't send those controls.
  $params->{groups} ||= [];
  $params->{users}  ||= [];

  $self->client($is_new ? SL::DB::AuthClient->new : SL::DB::AuthClient->new(id => $params->{id})->load)->assign_attributes(%{ $params });

  my @errors = $self->client->validate;

  if (@errors) {
    flash('error', @errors);
    $self->edit_client_form(title => $is_new ? t8('Create a new client') : t8('Edit Client'));
    return;
  }

  $self->client->save;
  if ($self->client->is_default) {
    SL::DB::Manager::AuthClient->update_all(set => { is_default => 0 }, where => [ '!id' => $self->client->id ]);
  }

  flash_later('info', $is_new ? t8('The client has been created.') : t8('The client has been saved.'));
  $self->redirect_to(action => 'show');
}

sub action_delete_client {
  my ($self) = @_;

  if (!$self->client->delete) {
    flash('error', t8('The client could not be deleted.'));
    $self->edit_client_form(title => t8('Edit Client'));
    return;
  }

  flash_later('info', t8('The client has been deleted.'));
  $self->redirect_to(action => 'show');
}

sub action_test_database_connectivity {
  my ($self)    = @_;

  my %cfg       = %{ $::form->{client} || {} };
  my $dbconnect = 'dbi:Pg:dbname=' . $cfg{dbname} . ';host=' . $cfg{dbhost} . ';port=' . $cfg{dbport};
  my $dbh       = DBI->connect($dbconnect, $cfg{dbuser}, $cfg{dbpasswd});

  my $ok        = !!$dbh;
  my $error     = $DBI::errstr;

  $dbh->disconnect if $dbh;

  $self->render('admin/test_db_connection', { layout => 0 },
                title => t8('Database Connection Test'),
                ok    => $ok,
                error => $error);
}

#
# actions: groups
#

sub action_new_group {
  my ($self) = @_;

  $self->group(SL::DB::AuthGroup->new);
  $self->edit_group_form(title => t8('Create a new group'));
}

sub action_edit_group {
  my ($self) = @_;
  $self->edit_group_form(title => t8('Edit User Group'));
}

sub action_save_group {
  my ($self) = @_;

  my $params = delete($::form->{group}) || { };
  my $is_new = !$params->{id};

  # Assign empty arrays if the browser doesn't send those controls.
  $params->{clients} ||= [];
  $params->{users}   ||= [];

  $self->group($is_new ? SL::DB::AuthGroup->new : SL::DB::AuthGroup->new(id => $params->{id})->load)->assign_attributes(%{ $params });

  my @errors = $self->group->validate;

  if (@errors) {
    flash('error', @errors);
    $self->edit_group_form(title => $is_new ? t8('Create a new user group') : t8('Edit User Group'));
    return;
  }

  $self->group->save;

  flash_later('info', $is_new ? t8('The user group has been created.') : t8('The user group has been saved.'));
  $self->redirect_to(action => 'show');
}

sub action_delete_group {
  my ($self) = @_;

  if (!$self->group->delete) {
    flash('error', t8('The user group could not be deleted.'));
    $self->edit_group_form(title => t8('Edit User Group'));
    return;
  }

  flash_later('info', t8('The user group has been deleted.'));
  $self->redirect_to(action => 'show');
}

#
# actions: printers
#

sub action_list_printers {
  my ($self) = @_;
  $self->render('admin/list_printers', title => t8('Printer management'));
}

sub action_new_printer {
  my ($self) = @_;

  $self->printer(SL::DB::Printer->new);
  $self->edit_printer_form(title => t8('Create a new printer'));
}

sub action_edit_printer {
  my ($self) = @_;
  $self->edit_printer_form(title => t8('Edit Printer'));
}

sub action_save_printer {
  my ($self) = @_;
  my $params = delete($::form->{printer}) || { };
  my $is_new = !$params->{id};

  $self->printer($is_new ? SL::DB::Printer->new : SL::DB::Printer->new(id => $params->{id})->load)->assign_attributes(%{ $params });

  my @errors = $self->printer->validate;

  if (@errors) {
    flash('error', @errors);
    $self->edit_printer_form(title => $is_new ? t8('Create a new printer') : t8('Edit Printer'));
    return;
  }

  $self->printer->save;

  flash_later('info', $is_new ? t8('The printer has been created.') : t8('The printer has been saved.'));
  $self->redirect_to(action => 'list_printers', 'client.id' => $self->client->id);
}

sub action_delete_printer {
  my ($self) = @_;

  if (!$self->printer->delete) {
    flash('error', t8('The printer could not be deleted.'));
    $self->edit_printer_form(title => t8('Edit Printer'));
    return;
  }

  flash_later('info', t8('The printer has been deleted.'));
  $self->redirect_to(action => 'list_printers', 'client.id' => $self->client->id);
}

#
# actions: database administration
#

sub action_create_dataset_login {
  my ($self) = @_;

  $self->database_administration_login_form(
    title       => t8('Create Dataset'),
    next_action => 'create_dataset',
  );
}

sub action_create_dataset {
  my ($self) = @_;
  $self->create_dataset_form;
}

sub action_do_create_dataset {
  my ($self) = @_;

  my @errors;
  push @errors, t8("Dataset missing!")          if !$::form->{db};
  push @errors, t8("Default currency missing!") if !$::form->{defaultcurrency};

  if (@errors) {
    flash('error', @errors);
    return $self->create_dataset_form;
  }

  $::form->{encoding} = 'UNICODE';
  User->new->dbcreate($::form);

  flash_later('info', t8("The dataset #1 has been created.", $::form->{db}));
  $self->redirect_to(action => 'show');
}

sub action_delete_dataset_login {
  my ($self) = @_;

  $self->database_administration_login_form(
    title       => t8('Delete Dataset'),
    next_action => 'delete_dataset',
  );
}

sub action_delete_dataset {
  my ($self) = @_;
  $self->delete_dataset_form;
}

sub action_do_delete_dataset {
  my ($self) = @_;

  my @errors;
  push @errors, t8("Dataset missing!") if !$::form->{db};

  if (@errors) {
    flash('error', @errors);
    return $self->create_dataset_form;
  }

  User->new->dbdelete($::form);

  flash_later('info', t8("The dataset #1 has been deleted.", $::form->{db}));
  $self->redirect_to(action => 'show');
}

#
# actions: locking, unlocking
#

sub action_show_lock {
  my ($self) = @_;

  $self->render(
    "admin/show_lock",
    title => "kivitendo " . t8('Administration'),
  );
}

sub action_unlock_system {
  my ($self) = @_;

  SL::System::InstallationLock->unlock;
  flash_later('info', t8('Lockfile removed!'));
  $self->redirect_to(action => 'show');
}

sub action_lock_system {
  my ($self) = @_;

  SL::System::InstallationLock->lock;
  flash_later('info', t8('Lockfile created!'));
  $self->redirect_to(action => 'show');
}

#
# initializers
#

sub init_db_cfg            { $::lx_office_conf{'authentication/database'}                                                    }
sub init_is_locked         { SL::System::InstallationLock->is_locked                                                         }
sub init_client            { SL::DB::Manager::AuthClient->find_by(id => ($::form->{id} || ($::form->{client}  || {})->{id})) }
sub init_user              { SL::DB::AuthUser  ->new(id => ($::form->{id} || ($::form->{user}    || {})->{id}))->load        }
sub init_group             { SL::DB::AuthGroup ->new(id => ($::form->{id} || ($::form->{group}   || {})->{id}))->load        }
sub init_printer           { SL::DB::Printer   ->new(id => ($::form->{id} || ($::form->{printer} || {})->{id}))->load        }
sub init_all_clients       { SL::DB::Manager::AuthClient->get_all_sorted                                                     }
sub init_all_users         { SL::DB::Manager::AuthUser  ->get_all_sorted                                                     }
sub init_all_groups        { SL::DB::Manager::AuthGroup ->get_all_sorted                                                     }
sub init_all_printers      { SL::DB::Manager::Printer   ->get_all_sorted                                                     }
sub init_all_dateformats   { [ qw(mm/dd/yy dd/mm/yy dd.mm.yy yyyy-mm-dd)      ]                                              }
sub init_all_numberformats { [ '1,000.00', '1000.00', '1.000,00', '1000,00'   ]                                              }
sub init_all_stylesheets   { [ qw(lx-office-erp.css kivitendo.css) ]                                                         }
sub init_all_dbsources             { [ sort User->dbsources($::form)                               ] }
sub init_all_used_dbsources        { { map { (join(':', $_->dbhost || 'localhost', $_->dbport || 5432, $_->dbname) => $_->name) } @{ $_[0]->all_clients }  } }
sub init_all_accounting_methods    { [ { id => 'accrual',   name => t8('Accrual accounting')  }, { id => 'cash',     name => t8('Cash accounting')       } ] }
sub init_all_inventory_systems     { [ { id => 'perpetual', name => t8('Perpetual inventory') }, { id => 'periodic', name => t8('Periodic inventory')    } ] }
sub init_all_profit_determinations { [ { id => 'balance',   name => t8('Balancing')           }, { id => 'income',   name => t8('Cash basis accounting') } ] }

sub init_all_charts {
  tie my %dir_h, 'IO::Dir', 'sql/';

  return [
    map { s/-chart\.sql$//; +{ id => $_ } }
    sort
    grep { /-chart\.sql\z/ && !/Default-chart.sql\z/ }
    keys %dir_h
  ];
}

sub init_all_menustyles    {
  return [
    { id => 'old', title => $::locale->text('Old (on the side)') },
    { id => 'v3',  title => $::locale->text('Top (CSS)') },
    { id => 'neu', title => $::locale->text('Top (Javascript)') },
  ];
}

sub init_all_rights {
  my (@sections, $current_section);

  foreach my $entry ($::auth->all_rights_full) {
    if ($entry->[0] =~ m/^--/) {
      push @sections, { description => $entry->[1], rights => [] };

    } elsif (@sections) {
      push @{ $sections[-1]->{rights} }, {
        name        => $entry->[0],
        description => $entry->[1],
      };

    } else {
      die "Right without sections: " . join('::', @{ $entry });
    }
  }

  return \@sections;
}

sub init_all_countrycodes {
  my %cc = User->country_codes;
  return [ map { id => $_, title => $cc{$_} }, sort { $cc{$a} cmp $cc{$b} } keys %cc ];
}

#
# filters
#

sub setup_layout {
  my ($self, $action) = @_;

  $::request->layout(SL::Layout::Dispatcher->new(style => 'admin'));
  $::form->{favicon} = "favicon.ico";
  %::myconfig        = (
    countrycode      => 'de',
    numberformat     => '1.000,00',
    dateformat       => 'dd.mm.yy',
  ) if !%::myconfig;
}

sub setup_client {
  my ($self) = @_;

  $self->client(SL::DB::Manager::AuthClient->get_default || $self->all_clients->[0]) if !$self->client;
  $::auth->set_client($self->client->id);
}

#
# displaying forms
#

sub use_multiselect_js {
  my ($self) = @_;

  $::request->layout->use_javascript("${_}.js") for qw(jquery.selectboxes jquery.multiselect2side);
  return $self;
}

sub login_form {
  my ($self, %params) = @_;
  $::request->layout(SL::Layout::AdminLogin->new);
  my $version         = $::form->read_version;
  $self->render('admin/adminlogin', title => t8('kivitendo v#1 administration', $version), %params, version => $version);
}

sub edit_user_form {
  my ($self, %params) = @_;
  $self->use_multiselect_js->render('admin/edit_user', %params);
}

sub edit_client_form {
  my ($self, %params) = @_;
  $self->use_multiselect_js->render('admin/edit_client', %params);
}

sub edit_group_form {
  my ($self, %params) = @_;
  $self->use_multiselect_js->render('admin/edit_group', %params);
}

sub edit_printer_form {
  my ($self, %params) = @_;
  $self->render('admin/edit_printer', %params);
}

sub database_administration_login_form {
  my ($self, %params) = @_;

  $self->render(
    'admin/dbadmin',
    dbhost    => $::form->{dbhost}    || $::auth->{DB_config}->{host} || 'localhost',
    dbport    => $::form->{dbport}    || $::auth->{DB_config}->{port} || 5432,
    dbuser    => $::form->{dbuser}    || $::auth->{DB_config}->{user} || 'kivitendo',
    dbpasswd  => $::form->{dbpasswd}  || $::auth->{DB_config}->{password},
    dbdefault => $::form->{dbdefault} || 'template1',
    %params,
  );
}

sub create_dataset_form {
  my ($self, %params) = @_;
  $self->render('admin/create_dataset', title => (t8('Database Administration') . " / " . t8('Create Dataset')));
}

sub delete_dataset_form {
  my ($self, %params) = @_;
  $self->render('admin/delete_dataset', title => (t8('Database Administration') . " / " . t8('Delete Dataset')));
}

#
# helpers
#

sub check_auth_db_and_tables {
  my ($self) = @_;

  if (!$::auth->check_database) {
    $self->render('admin/check_auth_database', title => t8('Authentification database creation'));
    return 0;
  }

  if (!$::auth->check_tables) {
    $self->render('admin/check_auth_tables', title => t8('Authentification tables creation'));
    return 0;
  }

  return 1;
}

sub apply_dbupgrade_scripts {
  return SL::DBUpgrade2->new(form => $::form, auth => 1)->apply_admin_dbupgrade_scripts(1);
}

sub authenticate_root {
  my ($self) = @_;

  return 1 if $::auth->authenticate_root($::form->{'{AUTH}admin_password'}) == $::auth->OK();

  $::auth->punish_wrong_login;
  $::auth->delete_session_value('admin_password');

  $self->login_form(error => t8('Incorrect password!'));

  return undef;
}

1;
