#=====================================================================
# LX-Office ERP
# Copyright (C) 2004
# Based on SQL-Ledger Version 2.1.9
# Web http://www.lx-office.org
#
#=====================================================================
# SQL-Ledger, Accounting
# Copyright (c) 1998-2002
#
#  Author: Dieter Simader
#   Email: dsimader@sql-ledger.org
#     Web: http://www.sql-ledger.org
#
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
# MA 02110-1335, USA.
#======================================================================
#
# Inventory received module
#
#======================================================================

use SL::FU;
use SL::IR;
use SL::IS;
use SL::DB::Default;
use SL::DB::Department;
use SL::DB::PurchaseInvoice;
use SL::DB::Vendor;
use List::Util qw(max sum);
use List::UtilsBy qw(sort_by);

require "bin/mozilla/io.pl";
require "bin/mozilla/common.pl";

use strict;

1;

# end of main

sub add {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my $locale   = $main::locale;

  $main::auth->assert('vendor_invoice_edit');

  if (!$::instance_conf->get_allow_new_purchase_invoice) {
    $::form->show_generic_error($::locale->text("You do not have the permissions to access this function."));
  }

  $form->{show_details} = $::myconfig{show_form_details};

  $form->{title} = $locale->text('Record Vendor Invoice');

  &invoice_links;
  &prepare_invoice;
  &display_form;

  $main::lxdebug->leave_sub();
}

sub edit {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my $locale   = $main::locale;

  $main::auth->assert('vendor_invoice_edit');

  $form->{show_details} = $::myconfig{show_form_details};

  # show history button
  $form->{javascript} = qq|<script type=text/javascript src=js/show_history.js></script>|;
  #/show hhistory button

  $form->{title} = $locale->text('Edit Vendor Invoice');

  &invoice_links;
  &prepare_invoice;
  &display_form;

  $main::lxdebug->leave_sub();
}

sub invoice_links {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;

  $main::auth->assert('vendor_invoice_edit');

  $form->{vc} = 'vendor';

  # create links
  $form->create_links("AP", \%myconfig, "vendor");

  $form->backup_vars(qw(payment_id language_id taxzone_id
                        currency delivery_term_id intnotes cp_id));

  IR->get_vendor(\%myconfig, \%$form);
  IR->retrieve_invoice(\%myconfig, \%$form);

  $form->restore_vars(qw(payment_id language_id taxzone_id
                         currency delivery_term_id intnotes cp_id));

  my @curr = $form->get_all_currencies();
  map { $form->{selectcurrency} .= "<option>$_\n" } @curr;

  # forex
  $form->{forex} = $form->{exchangerate};
  my $exchangerate = ($form->{exchangerate}) ? $form->{exchangerate} : 1;

  foreach my $key (keys %{ $form->{AP_links} }) {

    foreach my $ref (@{ $form->{AP_links}{$key} }) {
      $form->{"select$key"} .= "<option>$ref->{accno}--$ref->{description}</option>";
    }

    next unless $form->{acc_trans}{$key};

    if ($key eq "AP_paid") {
      for my $i (1 .. scalar @{ $form->{acc_trans}{$key} }) {
        $form->{"AP_paid_$i"} =
          "$form->{acc_trans}{$key}->[$i-1]->{accno}--$form->{acc_trans}{$key}->[$i-1]->{description}";

        $form->{"acc_trans_id_$i"} = $form->{acc_trans}{$key}->[$i - 1]->{acc_trans_id};
        # reverse paid
        $form->{"paid_$i"}     = $form->{acc_trans}{$key}->[$i - 1]->{amount};
        $form->{"datepaid_$i"} =
          $form->{acc_trans}{$key}->[$i - 1]->{transdate};
        $form->{"gldate_$i"}   = $form->{acc_trans}{$key}->[$i - 1]->{gldate};
        $form->{"forex_$i"} = $form->{"exchangerate_$i"} =
          $form->{acc_trans}{$key}->[$i - 1]->{exchangerate};
        $form->{"source_$i"} = $form->{acc_trans}{$key}->[$i - 1]->{source};
        $form->{"memo_$i"}   = $form->{acc_trans}{$key}->[$i - 1]->{memo};

        $form->{paidaccounts} = $i;
      }
    } else {
      $form->{$key} =
        "$form->{acc_trans}{$key}->[0]->{accno}--$form->{acc_trans}{$key}->[0]->{description}";
    }

  }

  $form->{paidaccounts} = 1 unless (exists $form->{paidaccounts});

  $form->{AP} = $form->{AP_1} unless $form->{id};

  $form->{locked} =
    ($form->datetonum($form->{invdate}, \%myconfig) <=
     $form->datetonum($form->{closedto}, \%myconfig));

  $main::lxdebug->leave_sub();
}

sub prepare_invoice {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;

  $main::auth->assert('vendor_invoice_edit');

  $form->{type}     = "purchase_invoice";

  if ($form->{id}) {

    map { $form->{$_} =~ s/\"/&quot;/g } qw(invnumber ordnumber quonumber);

    my $i = 0;
    foreach my $ref (@{ $form->{invoice_details} }) {
      $i++;
      map { $form->{"${_}_$i"} = $ref->{$_} } keys %{$ref};
      # übernommen aus is.pl Fix für Bug 1642. Nebenwirkungen? jb 12.5.2011
      # getestet: Lieferantenauftrag -> Rechnung i.O.
      #           Lieferantenauftrag -> Lieferschein -> Rechnung i.O.
      # Werte: 20% (Lieferantenrabatt), 12,4% individuell und 0,4 individuell s.a.
      # Screenshot zu Bug 1642
      $form->{"discount_$i"}   = $form->format_amount(\%myconfig, $form->{"discount_$i"} * 100);

      my ($dec) = ($form->{"sellprice_$i"} =~ /\.(\d+)/);
      $dec           = length $dec;
      my $decimalplaces = ($dec > 2) ? $dec : 2;

      $form->{"sellprice_$i"} =
        $form->format_amount(\%myconfig, $form->{"sellprice_$i"},
                             $decimalplaces);

      (my $dec_qty) = ($form->{"qty_$i"} =~ /\.(\d+)/);
      $dec_qty = length $dec_qty;

      $form->{"qty_$i"} =
        $form->format_amount(\%myconfig, ($form->{"qty_$i"} * -1), $dec_qty);

      $form->{rowcount} = $i;
    }
  }

  $main::lxdebug->leave_sub();
}

sub setup_ir_action_bar {
  my $form                    = $::form;
  my $change_never            = $::instance_conf->get_ir_changeable == 0;
  my $change_on_same_day_only = $::instance_conf->get_ir_changeable == 2 && ($form->current_date(\%::myconfig) ne $form->{gldate});

  for my $bar ($::request->layout->get('actionbar')) {
    $bar->add(
      action => [
        t8('Update'),
        submit    => [ '#form', { action => "update" } ],
        id        => 'update_button',
        accesskey => 'enter',
      ],

      combobox => [
        action => [
          t8('Post'),
          submit   => [ '#form', { action => "post" } ],
          disabled => $form->{locked}                           ? t8('The billing period has already been locked.')
                    : $form->{storno}                           ? t8('A canceled invoice cannot be posted.')
                    : ($form->{id} && $change_never)            ? t8('Changing invoices has been disabled in the configuration.')
                    : ($form->{id} && $change_on_same_day_only) ? t8('Invoices can only be changed on the day they are posted.')
                    :                                             undef,
        ],
        action => [
          t8('Post Payment'),
          submit   => [ '#form', { action => "post_payment" } ],
          disabled => !$form->{id} ? t8('This invoice has not been posted yet.') : undef,
        ],
        action => [
          t8('Mark as paid'),
          submit   => [ '#form', { action => "mark_as_paid" } ],
          confirm  => t8('This will remove the invoice from showing as unpaid even if the unpaid amount does not match the amount. Proceed?'),
          disabled => !$form->{id} ? t8('This invoice has not been posted yet.') : undef,
          only_if  => $::instance_conf->get_ir_show_mark_as_paid,
        ],
      ], # end of combobox "Post"

      combobox => [
        action => [ t8('Storno'),
          submit   => [ '#form', { action => "storno" } ],
          confirm  => t8('Do you really want to cancel this invoice?'),
          disabled => !$form->{id} ? t8('This invoice has not been posted yet.') : undef,
        ],
        action => [ t8('Delete'),
          submit   => [ '#form', { action => "delete" } ],
          confirm  => t8('Do you really want to delete this object?'),
          disabled => !$form->{id}             ? t8('This invoice has not been posted yet.')
                    : $form->{locked}          ? t8('The billing period has already been locked.')
                    : $change_never            ? t8('Changing invoices has been disabled in the configuration.')
                    : $change_on_same_day_only ? t8('Invoices can only be changed on the day they are posted.')
                    :                            undef,
        ],
      ], # end of combobox "Storno"

      'separator',

      combobox => [
        action => [ t8('Workflow') ],
        action => [
          t8('Use As New'),
          submit   => [ '#form', { action => "use_as_new" } ],
          disabled => !$form->{id} ? t8('This invoice has not been posted yet.') : undef,
        ],
       ], # end of combobox "Workflow"

      combobox => [
        action => [ t8('more') ],
        action => [
          t8('History'),
          call     => [ 'set_history_window', $::form->{id} * 1, 'id', 'glid' ],
          disabled => !$form->{id} ? t8('This invoice has not been posted yet.') : undef,
        ],
        action => [
          t8('Follow-Up'),
          call     => [ 'follow_up_window' ],
          disabled => !$form->{id} ? t8('This invoice has not been posted yet.') : undef,
        ],
        action => [
          t8('Drafts'),
          call     => [ 'kivi.Draft.popup', 'ir', 'invoice', $::form->{draft_id}, $::form->{draft_description} ],
          disabled => $form->{id}     ? t8('This invoice has already been posted.')
                    : $form->{locked} ? t8('The billing period has already been locked.')
                    :                   undef,
        ],
      ], # end of combobox "more"
    );
  }
}

sub form_header {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;
  my $locale   = $main::locale;
  my $cgi      = $::request->{cgi};

  $main::auth->assert('vendor_invoice_edit');

  my %TMPL_VAR = ();
  my @custom_hiddens;

  $TMPL_VAR{invoice_obj} = SL::DB::PurchaseInvoice->load_cached($form->{id}) if $form->{id};
  $TMPL_VAR{vendor_obj}  = SL::DB::Vendor->load_cached($form->{vendor_id})   if $form->{vendor_id};
  $form->{employee_id} = $form->{old_employee_id} if $form->{old_employee_id};
  $form->{salesman_id} = $form->{old_salesman_id} if $form->{old_salesman_id};

  $form->{defaultcurrency} = $form->get_default_currency(\%myconfig);

  my @old_project_ids = ($form->{"globalproject_id"});
  map { push @old_project_ids, $form->{"project_id_$_"} if $form->{"project_id_$_"}; } 1..$form->{"rowcount"};

  $form->get_lists("taxzones"      => ($form->{id} ? "ALL_TAXZONES" : "ALL_ACTIVE_TAXZONES"),
                   "currencies"    => "ALL_CURRENCIES",
                   "price_factors" => "ALL_PRICE_FACTORS");

  $TMPL_VAR{ALL_DEPARTMENTS}       = SL::DB::Manager::Department->get_all_sorted;
  $TMPL_VAR{ALL_EMPLOYEES}         = SL::DB::Manager::Employee->get_all_sorted(query => [ or => [ id => $::form->{employee_id},  deleted => 0 ] ]);
  $TMPL_VAR{ALL_CONTACTS}          = SL::DB::Manager::Contact->get_all_sorted(query => [
    or => [
      cp_cv_id => $::form->{"$::form->{vc}_id"} * 1,
      and      => [
        cp_cv_id => undef,
        cp_id    => $::form->{cp_id} * 1
      ]
    ]
  ]);

  # currencies and exchangerate
  my @values = map { $_       } @{ $form->{ALL_CURRENCIES} };
  my %labels = map { $_ => $_ } @{ $form->{ALL_CURRENCIES} };
  $form->{currency}            = $form->{defaultcurrency} unless $form->{currency};
  # show_exchangerate is also later needed in another template
  $form->{show_exchangerate} = $form->{currency} ne $form->{defaultcurrency};
  $TMPL_VAR{currencies}        = NTI($cgi->popup_menu('-name' => 'currency', '-default' => $form->{"currency"},
                                                      '-values' => \@values, '-labels' => \%labels,
                                                      '-onchange' => "document.getElementById('update_button').click();"
                                     )) if scalar @values;
  push @custom_hiddens, "forex";
  push @custom_hiddens, "exchangerate" if $form->{forex};

  $TMPL_VAR{creditwarning} = ($form->{creditlimit} != 0) && ($form->{creditremaining} < 0) && !$form->{update};
  $TMPL_VAR{is_credit_remaining_negativ} = $form->{creditremaining} =~ /-/;

# set option selected
  foreach my $item (qw(AP)) {
    $form->{"select$item"} =~ s/ selected//;
    $form->{"select$item"} =~ s/option>\Q$form->{$item}\E/option selected>$form->{$item}/;
  }

  $TMPL_VAR{is_type_credit_note} = $form->{type}   eq "credit_note";
  $TMPL_VAR{is_format_html}      = $form->{format} eq 'html';
  $TMPL_VAR{dateformat}          = $myconfig{dateformat};
  $TMPL_VAR{numberformat}        = $myconfig{numberformat};

  # hiddens
  $TMPL_VAR{HIDDENS} = [qw(
    id type queued printed emailed title vc discount
    title creditlimit creditremaining tradediscount business closedto locked shipped storno storno_id
    max_dunning_level dunning_amount
    shiptoname shiptostreet shiptozipcode shiptocity shiptocountry shiptogln shiptocontact shiptophone shiptofax
    shiptoemail shiptodepartment_1 shiptodepartment_2 message email subject cc bcc taxaccounts cursor_fokus
    convert_from_do_ids convert_from_oe_ids convert_from_ap_ids show_details gldate useasnew
  ), @custom_hiddens,
  map { $_.'_rate', $_.'_description', $_.'_taxnumber' } split / /, $form->{taxaccounts}];

  $TMPL_VAR{payment_terms_obj} = get_payment_terms_for_invoice();
  $form->{duedate}             = $TMPL_VAR{payment_terms_obj}->calc_date(reference_date => $form->{invdate}, due_date => $form->{duedate})->to_kivitendo if $TMPL_VAR{payment_terms_obj};

  $::request->{layout}->use_javascript(map { "${_}.js" } qw(kivi.Draft kivi.File  kivi.SalesPurchase kivi.Part ckeditor/ckeditor ckeditor/adapters/jquery kivi.io autocomplete_customer autocomplete_project client_js));

  setup_ir_action_bar();

  $form->{ALL_DELIVERY_TERMS} = SL::DB::Manager::DeliveryTerm->get_all_sorted(); # moved to here from sub form_footer

  $form->header();

  print $form->parse_html_template("ir/form_header", \%TMPL_VAR);

  $main::lxdebug->leave_sub();
}

sub _sort_payments {
  my @fields   = qw(acc_trans_id gldate datepaid source memo paid AP_paid);
  my @payments =
    grep { $_->{paid} != 0 }
    map  {
      my $idx = $_;
      +{ map { ($_ => delete($::form->{"${_}_${idx}"})) } @fields }
    } (1..$::form->{paidaccounts});

  @payments = sort_by { DateTime->from_kivitendo($_->{datepaid}) } @payments;

  $::form->{paidaccounts} = max scalar(@payments), 1;

  foreach my $idx (1 .. scalar(@payments)) {
    my $payment = $payments[$idx - 1];
    $::form->{"${_}_${idx}"} = $payment->{$_} for @fields;
  }
}

sub form_footer {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;
  my $locale   = $main::locale;

  $main::auth->assert('vendor_invoice_edit');

  $form->{invtotal}    = $form->{invsubtotal};
  $form->{oldinvtotal} = $form->{invtotal};

  # note rows
  $form->{rows} = max 2,
    $form->numtextrows($form->{notes},    26, 8),
    $form->numtextrows($form->{intnotes}, 35, 8);


  # tax, total and subtotal calculations
  my ($tax, $subtotal);
  $form->{taxaccounts_array} = [ split / /, $form->{taxaccounts} ];

  foreach my $item (@{ $form->{taxaccounts_array} }) {
    if ($form->{"${item}_base"}) {
      if ($form->{taxincluded}) {
        $form->{"${item}_total"} = $form->round_amount( ($form->{"${item}_base"} * $form->{"${item}_rate"} / (1 + $form->{"${item}_rate"})), 2);
        $form->{"${item}_netto"} = $form->round_amount( ($form->{"${item}_base"} - $form->{"${item}_total"}), 2);
      } 
      else {
        $form->{"${item}_total"} = $form->round_amount( $form->{"${item}_base"} * $form->{"${item}_rate"}, 2);
        $form->{invtotal} += $form->{"${item}_total"};
      }
    }
  }

  # follow ups
  if ($form->{id}) {
    $form->{follow_ups}            = FU->follow_ups('trans_id' => $form->{id}, 'not_done' => 1) || [];
    $form->{follow_ups_unfinished} = ( sum map { $_->{due} * 1 } @{ $form->{follow_ups} } ) || 0;
  }

  # payments
  _sort_payments();

  my $totalpaid = 0;
  $form->{paidaccounts}++ if ($form->{"paid_$form->{paidaccounts}"});
  $form->{paid_indices} = [ 1 .. $form->{paidaccounts} ];

  # Standard Konto für Umlaufvermögen
  my $accno_arap = IS->get_standard_accno_current_assets(\%myconfig, \%$form);

  for my $i (1 .. $form->{paidaccounts}) {
    $form->{"changeable_$i"} = 1;
    if (SL::DB::Default->get->payments_changeable == 0) {
      # never
      $form->{"changeable_$i"} = ($form->{"acc_trans_id_$i"})? 0 : 1;
    } elsif (SL::DB::Default->get->payments_changeable == 2) {
      # on the same day
      $form->{"changeable_$i"} = (($form->{"gldate_$i"} eq '') ||
                                  ($form->current_date(\%myconfig) eq $form->{"gldate_$i"}));
    }

    $form->error($locale->text('Cannot post transaction above the maximum future booking date!'))
      if ($form->date_max_future($form->{"datepaid_$i"}, \%myconfig));

    #deaktivieren von Zahlungen ausserhalb der Bücherkontrolle
    if ($form->date_closed($form->{"gldate_$i"})) {
      $form->{"changeable_$i"} = 0;
    }

    $form->{"selectAP_paid_$i"} = $form->{selectAP_paid};
    if (!$form->{"AP_paid_$i"}) {
      $form->{"selectAP_paid_$i"} =~ s/option>$accno_arap--(.*?)>/option selected>$accno_arap--$1>/;
    } else {
      $form->{"selectAP_paid_$i"} =~ s/option>\Q$form->{"AP_paid_$i"}\E/option selected>$form->{"AP_paid_$i"}/;
    }

    $totalpaid += $form->{"paid_$i"};
  }

  # $form->{ALL_DELIVERY_TERMS} = SL::DB::Manager::DeliveryTerm->get_all_sorted(); # moved to sub form_header

  print $form->parse_html_template('ir/form_footer', {
    is_type_credit_note => ($form->{type} eq "credit_note"),
    totalpaid           => $totalpaid,
    paid_missing        => $form->{invtotal} - $totalpaid,
    show_storno         => $form->{id} && !$form->{storno} && !IS->has_storno(\%myconfig, $form, "ap") && !$totalpaid,
    show_delete         => ($::instance_conf->get_ir_changeable == 2)
                             ? ($form->current_date(\%myconfig) eq $form->{gldate})
                             : ($::instance_conf->get_ir_changeable == 1),
    today               => DateTime->today,
  });
##print $form->parse_html_template('ir/_payments'); # parser
##print $form->parse_html_template('webdav/_list'); # parser

  $main::lxdebug->leave_sub();
}

sub mark_as_paid {
  $::auth->assert('vendor_invoice_edit');

  SL::DB::PurchaseInvoice->new(id => $::form->{id})->load->mark_as_paid;

  $::form->redirect($::locale->text("Marked as paid"));
}

sub show_draft {
  update();
}

sub update {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;

  $main::auth->assert('vendor_invoice_edit');

  if (($form->{previous_vendor_id} || $form->{vendor_id}) != $form->{vendor_id}) {
    IR->get_vendor(\%myconfig, $form);
  }

  if (!$form->{forex}) {        # read exchangerate from input field (not hidden)
    $form->{exchangerate} = $form->parse_amount(\%myconfig, $form->{exchangerate});
  }
  $form->{forex}        = $form->check_exchangerate(\%myconfig, $form->{currency}, $form->{invdate}, 'sell');
  $form->{exchangerate} = $form->{forex} if $form->{forex};

  for my $i (1 .. $form->{paidaccounts}) {
    next unless $form->{"paid_$i"};
    map { $form->{"${_}_$i"} = $form->parse_amount(\%myconfig, $form->{"${_}_$i"}) } qw(paid exchangerate);
    $form->{"forex_$i"}        = $form->check_exchangerate(\%myconfig, $form->{currency}, $form->{"datepaid_$i"}, 'sell');
    $form->{"exchangerate_$i"} = $form->{"forex_$i"} if $form->{"forex_$i"};
  }

  my $i            = $form->{rowcount};
  my $exchangerate = ($form->{exchangerate} * 1) || 1;

  if (   ($form->{"partnumber_$i"} eq "")
      && ($form->{"description_$i"} eq "")
      && ($form->{"partsgroup_$i"} eq "")) {
    $form->{creditremaining} += ($form->{oldinvtotal} - $form->{oldtotalpaid});
    &check_form;

  } else {

    IR->retrieve_item(\%myconfig, \%$form);

    my $rows = scalar @{ $form->{item_list} };

    $form->{"discount_$i"}   = $form->parse_amount(\%myconfig, $form->{"discount_$i"}) / 100.0;
    $form->{"discount_$i"} ||= $form->{vendor_discount};

    if ($rows) {
      $form->{"qty_$i"} = $form->parse_amount(\%myconfig, $form->{"qty_$i"});
      if( !$form->{"qty_$i"} ) {
        $form->{"qty_$i"} = 1;
      }

      if ($rows > 1) {

        select_item(mode => 'IR', pre_entered_qty => $form->{"qty_$i"});
        $::dispatcher->end_request;

      } else {

        # override sellprice if there is one entered
        my $sellprice = $form->parse_amount(\%myconfig, $form->{"sellprice_$i"});

        map { $form->{item_list}[$i]{$_} =~ s/\"/&quot;/g } qw(partnumber description unit);
        map { $form->{"${_}_$i"} = $form->{item_list}[0]{$_} } keys %{ $form->{item_list}[0] };

        $form->{"marge_price_factor_$i"} = $form->{item_list}->[0]->{price_factor};

        ($sellprice || $form->{"sellprice_$i"}) =~ /\.(\d+)/;
        my $dec_qty       = length $1;
        my $decimalplaces = max 2, $dec_qty;

        if ($sellprice) {
          $form->{"sellprice_$i"} = $sellprice;
        } else {
          my $record        = _make_record();
          my $price_source  = SL::PriceSource->new(record_item => $record->items->[$i-1], record => $record);
          my $best_price    = $price_source->best_price;
          my $best_discount = $price_source->best_discount;

          if ($best_price) {
            $::form->{"sellprice_$i"}           = $best_price->price;
            $::form->{"active_price_source_$i"} = $best_price->source;
          }
          if ($best_discount) {
            $::form->{"discount_$i"}               = $best_discount->discount;
            $::form->{"active_discount_source_$i"} = $best_discount->source;
          }

          # if there is an exchange rate adjust sellprice
          $form->{"sellprice_$i"} /= $exchangerate;
        }

        my $amount                = $form->{"sellprice_$i"} * $form->{"qty_$i"} * (1 - $form->{"discount_$i"});
        $form->{creditremaining} -= $amount;
        $form->{"sellprice_$i"}   = $form->format_amount(\%myconfig, $form->{"sellprice_$i"}, $decimalplaces);
        $form->{"qty_$i"}         = $form->format_amount(\%myconfig, $form->{"qty_$i"},       $dec_qty);
        $form->{"discount_$i"}    = $form->format_amount(\%myconfig, $form->{"discount_$i"} * 100.0);
      }

      &display_form;

    } else {

      # ok, so this is a new part
      # ask if it is a part or service item

      if (   $form->{"partsgroup_$i"}
          && ($form->{"partsnumber_$i"} eq "")
          && ($form->{"description_$i"} eq "")) {
        $form->{rowcount}--;
        $form->{"discount_$i"} = "";
        display_form();

      } else {
        $form->{"id_$i"}   = 0;
        new_item();
      }
    }
  }
  $main::lxdebug->leave_sub();
}

sub storno {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;
  my $locale   = $main::locale;

  $main::auth->assert('vendor_invoice_edit');

  if ($form->{storno}) {
    $form->error($locale->text('Cannot storno storno invoice!'));
  }

  if (IS->has_storno(\%myconfig, $form, "ap")) {
    $form->error($locale->text("Invoice has already been storno'd!"));
  }

  $form->error($locale->text('Cannot post storno for a closed period!'))
    if ( $form->date_closed($form->{invdate}, \%myconfig));

  my $employee_id = $form->{employee_id};
  invoice_links();
  prepare_invoice();
  relink_accounts();

  # Payments must not be recorded for the new storno invoice.
  $form->{paidaccounts} = 0;
  map { my $key = $_; delete $form->{$key} if grep { $key =~ /^$_/ } qw(datepaid_ gldate_ acc_trans_id_ source_ memo_ paid_ exchangerate_ AR_paid_) } keys %{ $form };
  # set new ids for storno invoice
  # set new persistent ids for storno invoice items
  $form->{"converted_from_invoice_id_$_"} = delete $form->{"invoice_id_$_"} for 1 .. $form->{"rowcount"};

  # saving the history
  if(!exists $form->{addition} && $form->{id} ne "") {
    $form->{snumbers}  = qq|invnumber_| . $form->{invnumber};
    $form->{what_done} = "invoice";
    $form->{addition}  = "CANCELED";
    $form->save_history;
  }
  # /saving the history

  # record link invoice to storno
  $form->{convert_from_ap_ids} = $form->{id};
  $form->{storno_id} = $form->{id};
  $form->{storno} = 1;
  $form->{id} = "";
  $form->{invnumber} = "Storno zu " . $form->{invnumber};
  $form->{rowcount}++;
  $form->{employee_id} = $employee_id;
  post();
  $main::lxdebug->leave_sub();

}

sub use_as_new {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;

  $main::auth->assert('vendor_invoice_edit');

  map { delete $form->{$_} } qw(printed emailed queued invnumber invdate deliverydate id datepaid_1 gldate_1 acc_trans_id_1 source_1 memo_1 paid_1 exchangerate_1 AP_paid_1 storno);
  $form->{paidaccounts} = 1;
  $form->{rowcount}--;
  $form->{invdate} = $form->current_date(\%myconfig);

  $form->{"converted_from_invoice_id_$_"} = delete $form->{"invoice_id_$_"} for 1 .. $form->{"rowcount"};

  $form->{useasnew} = 1;
  &display_form;

  $main::lxdebug->leave_sub();
}

sub post_payment {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;
  my $locale   = $main::locale;

  $main::auth->assert('vendor_invoice_edit');

  $form->mtime_ischanged('ap') ;
  $form->{defaultcurrency} = $form->get_default_currency(\%myconfig);
  for my $i (1 .. $form->{paidaccounts}) {
    if ($form->{"paid_$i"}) {
      my $datepaid = $form->datetonum($form->{"datepaid_$i"}, \%myconfig);

      $form->isblank("datepaid_$i", $locale->text('Payment date missing!'));

      $form->error($locale->text('Cannot post transaction above the maximum future booking date!'))
        if ($form->date_max_future($form->{"datepaid_$i"}, \%myconfig));

      #Zusätzlich noch das Buchungsdatum in die Bücherkontrolle einbeziehen
      # (Dient zur Prüfung ob ZE oder ZA geprüft werden soll)
      $form->error($locale->text('Cannot post payment for a closed period!'))
        if ($form->date_closed($form->{"datepaid_$i"})  && !$form->date_closed($form->{"gldate_$i"}, \%myconfig));

      if ($form->{currency} ne $form->{defaultcurrency}) {
#        $form->{"exchangerate_$i"} = $form->{exchangerate} if ($invdate == $datepaid); # invdate isn't set here
        $form->isblank("exchangerate_$i", $locale->text('Exchangerate for payment missing!'));
      }
    }
  }

  ($form->{AP})      = split /--/, $form->{AP};
  ($form->{AP_paid}) = split /--/, $form->{AP_paid};
  if (IR->post_payment(\%myconfig, \%$form)){
    if (!exists $form->{addition} && $form->{id} ne "") {
      # saving the history
      $form->{snumbers}  = qq|invnumber_| . $form->{invnumber};
      $form->{addition}  = "PAYMENT POSTED";
      $form->{what_done} = "invoice";
      $form->save_history;
      # /saving the history
    }

    $form->redirect($locale->text('Payment posted!'));
  }

  $form->error($locale->text('Cannot post payment!'));

  $main::lxdebug->leave_sub();
}

sub _max_datepaid {
  my $form  =  $main::form;

  my @dates = sort { $b->[1] cmp $a->[1] }
              map  { [ $_, $main::locale->reformat_date(\%main::myconfig, $_, 'yyyy-mm-dd') ] }
              grep { $_ }
              map  { $form->{"datepaid_${_}"} }
              (1..$form->{rowcount});

  return @dates ? $dates[0]->[0] : undef;
}


sub post {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;
  my $locale   = $main::locale;

  $main::auth->assert('vendor_invoice_edit');

  $form->mtime_ischanged('ap');
  $form->{defaultcurrency} = $form->get_default_currency(\%myconfig);

  $form->isblank("invdate",   $locale->text('Invoice Date missing!'));
  $form->isblank("vendor_id", $locale->text('Vendor missing!'));
  $form->isblank("invnumber", $locale->text('Invnumber missing!'));

  $form->{invnumber} =~ s/^\s*//g;
  $form->{invnumber} =~ s/\s*$//g;

  # if the vendor changed get new values
  if (($form->{previous_vendor_id} || $form->{vendor_id}) != $form->{vendor_id}) {
    &update;
    $::dispatcher->end_request;
  }

  if ($myconfig{mandatory_departments} && !$form->{department_id}) {
    $form->{saved_message} = $::locale->text('You have to specify a department.');
    update();
    exit;
  }

  remove_emptied_rows();
  &validate_items;

  my $closedto     = $form->datetonum($form->{closedto}, \%myconfig);
  my $invdate      = $form->datetonum($form->{invdate},  \%myconfig);
  my $max_datepaid = _max_datepaid();

  $form->error($locale->text('Cannot post transaction above the maximum future booking date!'))
    if ($form->date_max_future($invdate, \%myconfig));
  $form->error($locale->text('Cannot post invoice for a closed period!'))
    if ($invdate <= $closedto);

  $form->isblank("exchangerate", $locale->text('Exchangerate missing!'))
    if ($form->{currency} ne $form->{defaultcurrency});

  my $i;
  for $i (1 .. $form->{paidaccounts}) {
    if ($form->parse_amount(\%myconfig, $form->{"paid_$i"})) {
      my $datepaid = $form->datetonum($form->{"datepaid_$i"}, \%myconfig);

      $form->isblank("datepaid_$i", $locale->text('Payment date missing!'));

      $form->error($locale->text('Cannot post transaction above the maximum future booking date!'))
        if ($form->date_max_future($form->{"datepaid_$i"}, \%myconfig));

      #Zusätzlich noch das Buchungsdatum in die Bücherkontrolle einbeziehen
      # (Dient zur Prüfung ob ZE oder ZA geprüft werden soll)
      $form->error($locale->text('Cannot post payment for a closed period!'))
        if ($form->date_closed($form->{"datepaid_$i"})  && !$form->date_closed($form->{"gldate_$i"}, \%myconfig));

      if ($form->{currency} ne $form->{defaultcurrency}) {
        $form->{"exchangerate_$i"} = $form->{exchangerate}
          if ($invdate == $datepaid);
        $form->isblank("exchangerate_$i",
                       $locale->text('Exchangerate for payment missing!'));
      }
    }
  }

  ($form->{AP})      = split /--/, $form->{AP};
  ($form->{AP_paid}) = split /--/, $form->{AP_paid};
  $form->{storno}  ||= 0;

  $form->{id} = 0 if $form->{postasnew};


  relink_accounts();
  if (IR->post_invoice(\%myconfig, \%$form)){
    # saving the history
    if(!exists $form->{addition} && $form->{id} ne "") {
      $form->{snumbers}  = qq|invnumber_| . $form->{invnumber};
      $form->{addition}  = "POSTED";
      $form->{what_done} = 'invoice';
      $form->save_history;
    }
    # /saving the history
    $form->{callback} = 'ir.pl?action=add';
    $form->redirect(  $locale->text('Invoice')
                  . " $form->{invnumber} "
                  . $locale->text('posted!'));
  }
  $form->error($locale->text('Cannot post invoice!'));

  $main::lxdebug->leave_sub();
}

sub delete {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my $locale   = $main::locale;

  $main::auth->assert('vendor_invoice_edit');

  $form->header;
  print qq|
<form method=post action=$form->{script}>
|;

  # delete action variable
  map { delete $form->{$_} } qw(action header);

  foreach my $key (keys %$form) {
    next if (($key eq 'login') || ($key eq 'password') || ('' ne ref $form->{$key}));
    $form->{$key} =~ s/\"/&quot;/g;
    print qq|<input type=hidden name=$key value="$form->{$key}">\n|;
  }

  print qq|
<h2 class=confirm>| . $locale->text('Confirm!') . qq|</h2>

<h4>|
    . $locale->text('Are you sure you want to delete Invoice Number')
    . qq| $form->{invnumber}</h4>
<p>
<input name=action class=submit type=submit value="|
    . $locale->text('Yes') . qq|">
</form>
|;

  $main::lxdebug->leave_sub();
}

sub display_form {
  $::lxdebug->enter_sub;

  $::auth->assert('vendor_invoice_edit');

  relink_accounts();

  my $new_rowcount = $::form->{"rowcount"} * 1 + 1;
  $::form->{"project_id_${new_rowcount}"} = $::form->{"globalproject_id"};

  $::form->language_payment(\%::myconfig);

  Common::webdav_folder($::form);

  form_header();
  display_row(++$::form->{rowcount});
  form_footer();

  $::lxdebug->leave_sub;
}

sub yes {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;
  my $locale   = $main::locale;

  $main::auth->assert('vendor_invoice_edit');

  if (IR->delete_invoice(\%myconfig, \%$form)) {
    # saving the history
    if(!exists $form->{addition}) {
      $form->{snumbers} = qq|invnumber_| . $form->{invnumber};
      $form->{addition} = "DELETED";
      $form->save_history;
    }
    # /saving the history
    $form->redirect($locale->text('Invoice deleted!'));
  }
  $form->error($locale->text('Cannot delete invoice!'));

  $main::lxdebug->leave_sub();
}

sub get_duedate_vendor {
  $::lxdebug->enter_sub;

  my $result = IR->get_duedate(
    vendor_id => $::form->{vendor_id},
    invdate   => $::form->{invdate},
    default   => $::form->{old_duedate},
  );

  print $::form->ajax_response_header, $result;
  $::lxdebug->leave_sub;
}
