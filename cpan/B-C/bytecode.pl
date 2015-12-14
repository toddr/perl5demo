# -*- cperl-indent-level:4 -*-
BEGIN {		
    push @INC, '.', 'lib';
    push @INC, '../../regen' if $ENV{PERL_CORE};
    require 'regen_lib.pl';
}
use strict;
use Config;
my %alias_to = (
                U32 => [qw(line_t)],
                PADOFFSET => [qw(STRLEN SSize_t)],
                U16 => [qw(OPCODE short)],
                U8  => [qw(char)],
               );
%alias_to = (
             U32 => [qw(PADOFFSET STRLEN)],
             I32 => [qw(SSize_t long)],
             U16 => [qw(OPCODE line_t short)],
             U8  => [qw(char)],
            ) if $] < 5.008001;

my (%alias_from, $from, $tos);
while (($from, $tos) = each %alias_to) {
    map { $alias_from{$_} = $from } @$tos;
}
my (@optype, @specialsv_name);
if ($ENV{PERL_CORE}) {
    if ($] < 5.009) {
      @optype = @{*B::Asmdata::optype{ARRAY}};
      @specialsv_name = @{*B::Asmdata::specialsv_name{ARRAY}};
    } else {
        @optype = qw(OP UNOP BINOP LOGOP LISTOP PMOP SVOP PADOP PVOP LOOP
                     COP METHOP UNOP_AUX);
        @specialsv_name = 
          qw(Nullsv &PL_sv_undef &PL_sv_yes &PL_sv_no
             (SV*)pWARN_ALL (SV*)pWARN_NONE (SV*)pWARN_STD);
    }
} else {
    # @optype was in B::Asmdata, and is since 5.10 in B
    # B cannot be loaded from miniperl
    if ($] < 5.009) {
        require B::Asmdata;
        @optype = @{*B::Asmdata::optype{ARRAY}};
        @specialsv_name = @{*B::Asmdata::specialsv_name{ARRAY}};
        # B::Asmdata->import qw(@optype @specialsv_name);
    } else {
        require B;
        @optype = @{*B::optype{ARRAY}};
        @specialsv_name = @{*B::specialsv_name{ARRAY}};
        # B->import qw(@optype @specialsv_name);
    }
}


my $perlversion = sprintf("%1.6f%s", $], ($Config{useithreads} ? '' : '-nt'));
my $c_header = <<"EOT";
/* -*- buffer-read-only: t -*-
 *
 *      Copyright (c) 1996-1999 Malcolm Beattie
 *      Copyright (c) 2008,2009,2010,2011,2012 Reini Urban
 *      Copyright (c) 2011-2015 cPanel Inc
 *
 *      You may distribute under the terms of either the GNU General Public
 *      License or the Artistic License, as specified in the README file.
 *
 */
/*
 * This file is autogenerated from bytecode.pl. Changes made here will be lost.
 * It is specific for Perl $perlversion only.
 */
EOT

my $perl_header;
($perl_header = $c_header) =~ s{[/ ]?\*/?}{#}g;
my @targets = ("lib/B/Asmdata.pm", "ByteLoader/byterun.c", "ByteLoader/byterun.h");

safer_unlink @targets;

#
# Start with boilerplate for Asmdata.pm
#
open(ASMDATA_PM, "> $targets[0]") or die "$targets[0]: $!";
binmode ASMDATA_PM;
print ASMDATA_PM $perl_header, <<'EOT';
package B::Asmdata;

our $VERSION = '1.03';

use Exporter;
@ISA = qw(Exporter);
@EXPORT_OK = qw(%insn_data @insn_name @optype @specialsv_name);
EOT

if ($] > 5.009) {
    print ASMDATA_PM 'our(%insn_data, @insn_name);

use B qw(@optype @specialsv_name);
';
} elsif ($] > 5.008) {
    print ASMDATA_PM 'our(%insn_data, @insn_name, @optype, @specialsv_name);

@optype = qw(OP UNOP BINOP LOGOP LISTOP PMOP SVOP PADOP PVOP LOOP COP);
@specialsv_name = qw(Nullsv &PL_sv_undef &PL_sv_yes &PL_sv_no pWARN_ALL pWARN_NONE);
';
} else {
    print ASMDATA_PM 'my(%insn_data, @insn_name, @optype, @specialsv_name);

@optype = qw(OP UNOP BINOP LOGOP LISTOP PMOP SVOP PADOP PVOP LOOP COP);
@specialsv_name = qw(Nullsv &PL_sv_undef &PL_sv_yes &PL_sv_no pWARN_ALL pWARN_NONE);
';
}

print ASMDATA_PM <<"EOT";

# XXX insn_data is initialised this way because with a large
# %insn_data = (foo => [...], bar => [...], ...) initialiser
# I get a hard-to-track-down stack underflow and segfault.
EOT

#
# Boilerplate for byterun.c
#
open(BYTERUN_C, "> $targets[1]") or die "$targets[1]: $!";
binmode BYTERUN_C;
print BYTERUN_C $c_header, <<'EOT';

#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#define NO_XSLOCKS
#include "XSUB.h"
#if PERL_VERSION < 8
  #define NEED_sv_2pv_flags
  #include "ppport.h"
#endif

/* Change 31252: move PL_tokenbuf into the PL_parser struct */
#if (PERL_VERSION > 8) && (!defined(PL_tokenbuf))
  #define PL_tokenbuf		(PL_parser->tokenbuf)
#endif
#if (PERL_VERSION < 8) && (!defined(DEBUG_v))
  #define DEBUG_v(a) DEBUG_f(a)
#endif

#include "byterun.h"
#include "bytecode.h"

struct byteloader_header bl_header;

static const int optype_size[] = {
EOT
my $i = 0;
for ($i = 0; $i < @optype - 1; $i++) {
    printf BYTERUN_C "    sizeof(%s),\n", $optype[$i], $i;
}
printf BYTERUN_C "    sizeof(%s)\n", $optype[$i], $i;
print BYTERUN_C <<'EOT';
};

void *
bset_obj_store(pTHX_ struct byteloader_state *bstate, void *obj, I32 ix)
{
    if (ix > bstate->bs_obj_list_fill) {
	Renew(bstate->bs_obj_list, ix + 32, void*);
	bstate->bs_obj_list_fill = ix + 31;
    }
    bstate->bs_obj_list[ix] = obj;
    return obj;
}

int bytecode_header_check(pTHX_ struct byteloader_state *bstate, U32 *isjit) {
    U32 sz = 0;
    strconst str;

    BGET_U32(sz); /* Magic: 'PLBC' or 'PLJC' */
    if (sz != 0x43424c50) {
        if (sz != 0x434a4c50) {
	    HEADER_FAIL1("bad magic (want 0x43424c50 PLBC or 0x434a4c50 PLJC, got %#x)",
		         (int)sz);
	} else {
	    *isjit = 1;
        }
    }
    BGET_strconst(str,80);	/* archname */
    strcpy(bl_header.archname, str);
    /* just warn. relaxed strictness, only check for ithread in archflag */
    if (strNE(str, ARCHNAME)) {
	HEADER_WARN2("Different architecture %s, you have %s", str, ARCHNAME);
    }

    /* ByteLoader version strategy: Strict for 0.06_ development releases and 0.03-0.04.
       0.07 should be able to load 0.5 (5.8.1 CORE) */
    BGET_strconst(str,16);
    strcpy(bl_header.version, str);
    if (strNE(str, VERSION)) {
        if ((strGT(str, "0.06") && strLT(str, "0.06_06")) /*|| strLT(str, "0.05")*/) {
	    HEADER_FAIL2("Incompatible bytecode version %s, you have %s",
		         str, VERSION);
        }
    }

    BGET_U32(sz); /* ivsize */
    bl_header.ivsize = sz;

    BGET_U32(sz); /* ptrsize */
    bl_header.ptrsize = sz;

    /* new since 0.06_03 */
    if (strGE(bl_header.version, "0.06_03")) {
        BGET_U32(sz); /* longsize */
        bl_header.longsize = sz;
    } else {
        bl_header.longsize = LONGSIZE;
    }

    if (strGT(bl_header.version, "0.06") || strEQ(bl_header.version, "0.04"))
    {   /* added again with 0.06_01 */
	/* config.h BYTEORDER: 0x1234 of length longsize, not ivsize */
	char supported[16];
	/* Note: perl's $Config{byteorder} is wrong with 64int.
	   Bug in Config.pm:921 my $s = $Config{ivsize}; => my $s = $Config{longsize};
	*/
	sprintf(supported, "%x", BYTEORDER);
	BGET_strconst(str, 16); /* optional 0x prefix, 12345678 or 1234 */
	if (str[0] == 0x30 && str[1] == 0x78) { /* skip '0x' */
	    str++; str++;
	}
	strcpy(bl_header.byteorder, str);
	if (strNE(str, supported)) {
	    /* swab only if same length. 1234 => 4321, 12345678 => 87654321 */
	    if (strlen(str) == strlen(supported)) {
		bget_swab = 1;
		HEADER_WARN2("EXPERIMENTAL byteorder conversion: .plc=%s, perl=%s",
			     str, supported);
	    } else {
		HEADER_FAIL2("Unsupported byteorder conversion: .plc=%s, perl=%s",
			     str, supported);
	    }
	}
    }

    /* swab byteorder */
    if (bget_swab) {
	bl_header.ivsize = _swab_32_(bl_header.ivsize);
	bl_header.ptrsize = _swab_32_(bl_header.ptrsize);
        if (bl_header.longsize != LONGSIZE) {
	    bl_header.longsize = _swab_32_(bl_header.longsize);
        }
    }

#ifdef USE_ITHREADS
# define HAVE_ITHREADS_I 1
#else
# define HAVE_ITHREADS_I 0
#endif
#ifdef MULTIPLICITY
# define HAVE_MULTIPLICITY_I 2
#else
# define HAVE_MULTIPLICITY_I 0
#endif
    if (strGE(bl_header.version, "0.06_05")) {
        BGET_U16(sz); /* archflag */
        bl_header.archflag = sz;
        if ((sz & 1) != HAVE_ITHREADS_I) {
	    HEADER_FAIL2("Wrong USE_ITHREADS. Bytecode: %s, System: %s)",
		         bl_header.archflag & 1 ? "yes" : "no",
			 HAVE_ITHREADS_I ? "yes" : "no");
	}
	if (strGE(bl_header.version, "0.08")) {		
 	    if ((sz & 2) != HAVE_MULTIPLICITY_I) {
	        HEADER_FAIL2("Wrong MULTIPLICITY. Bytecode: %s, System: %s)",
		             bl_header.archflag & 2 ? "yes" : "no",
			     HAVE_MULTIPLICITY_I ? "yes" : "no");
	    }
	}
    }

    if (bl_header.ivsize != IVSIZE) {
	HEADER_WARN("different IVSIZE");
        if ((bl_header.ivsize != 4) && (bl_header.ivsize != 8))
	    HEADER_FAIL1("unsupported IVSIZE %d", bl_header.ivsize);
    }
    if (bl_header.ptrsize != PTRSIZE) {
	HEADER_WARN("different PTRSIZE");
        if ((bl_header.ptrsize != 4) && (bl_header.ptrsize != 8))
	    HEADER_FAIL1("unsupported PTRSIZE %d", bl_header.ptrsize);
    }
    if (strGE(bl_header.version, "0.06_03")) {
        if (bl_header.longsize != LONGSIZE) {
	    HEADER_WARN("different LONGSIZE");
            if ((bl_header.longsize != 4) && (bl_header.longsize != 8))
	        HEADER_FAIL1("unsupported LONGSIZE %d", bl_header.longsize);
      }
    }
    if (strGE(bl_header.version, "0.06_06")) {
        BGET_strconst(str, 16);
        strcpy(bl_header.perlversion, str);
    } else {
        *bl_header.perlversion = 0;
    }

    return 1;
}

int
byterun(pTHX_ struct byteloader_state *bstate)
{
    register int insn;
    U32 isjit = 0;
    U32 ix;
EOT
printf BYTERUN_C "    SV *specialsv_list[%d];\n", scalar @specialsv_name;
print BYTERUN_C <<'EOT';

    bytecode_header_check(aTHX_ bstate, &isjit); /* croak if incorrect platform,
						    set isjit on PLJC magic header */
    if (isjit) {
	Perl_croak(aTHX_ "PLJC-magic: No JIT support yet\n");
        return 0; /*jitrun(aTHX_ &bstate);*/
    } else {
        New(0, bstate->bs_obj_list, 32, void*); /* set op objlist */
        bstate->bs_obj_list_fill = 31;
        bstate->bs_obj_list[0] = NULL;          /* first is always Null */
        bstate->bs_ix = 1;
	CopLINE(PL_curcop) = bstate->bs_fdata->next_out;
	DEBUG_l( Perl_deb(aTHX_ "(bstate.bs_fdata.idx %d)\n", bstate->bs_fdata->idx));
	DEBUG_l( Perl_deb(aTHX_ "(bstate.bs_fdata.next_out %d)\n", bstate->bs_fdata->next_out));
	DEBUG_l( Perl_deb(aTHX_ "(bstate.bs_fdata.datasv %p:\"%s\")\n", bstate->bs_fdata->datasv,
				 SvPV_nolen(bstate->bs_fdata->datasv)));

EOT

for my $i ( 0 .. $#specialsv_name ) {
    print BYTERUN_C "        specialsv_list[$i] = $specialsv_name[$i];\n";
}

print BYTERUN_C <<'EOT';

        while ((insn = BGET_FGETC()) != EOF) {
	    CopLINE(PL_curcop) = bstate->bs_fdata->next_out;
	    switch (insn) {
EOT


my ($idx, @insn_name, $insn_num, $ver, $insn, $lvalue, $argtype, $flags, $fundtype, $unsupp);
my $ITHREADS = $Config{useithreads} eq 'define';
my $MULTI = $Config{useithreads} eq 'define';

$insn_num = 0;
my @data = <DATA>;
my @insndata = ();
for (@data) {
    if (/^\s*#/) {
	print BYTERUN_C if /^\s*#\s*(?:if|endif|el)/;
	next;
    }
    chop;
    next unless length;
    ($idx, $ver, $insn, $lvalue, $argtype, $flags) = split;
    # bc numbering policy: <=5.6: leave out (squeeze), >=5.8 leave holes
    if ($] > 5.007) {
	$insn_num = $idx ? $idx : $insn_num;
	$insn_num = 0 if !$idx and $insn eq 'ret';
    } else { # ignore the idx and count through. just fixup comment and nop
	$insn_num = 35 if $insn eq "comment";
	$insn_num = 10 if $insn eq "nop";
	$insn_num = 0  if $insn eq "ret"; # start from 0
    }
    my $rvalcast = '';
    $unsupp = 0;
    if ($argtype =~ m:(.+)/(.+):) {
	($rvalcast, $argtype) = ("($1)", $2);
    }
    if ($ver) {
	if ($ver =~ /^\!?i/) {
	    $unsupp++ if ($ver =~ /^i/ and !$ITHREADS) or ($ver =~ /\!i/ and $ITHREADS);
	    $ver =~ s/^\!?i//;
	}
	if ($ver =~ /^\!?m/) {
	    $unsupp++ if ($ver =~ /^m/ and !$MULTI) or ($ver =~ /\!m/ and $MULTI);
	    $ver =~ s/^\!?m//;
	}
	# perl version 5.010000 => 10.000, 5.009003 => 9.003
	# Have to round the float: 5.010 - 5 = 0.00999999999999979
	my $pver = 0.0+(substr($],2,3).".".substr($],5));
	if ($ver =~ /^<?8\-?/) {
	    $ver =~ s/8/8.001/; # as convenience for a shorter table.
	}
	# Add these misses to ASMDATA. TODO: To BYTERUN maybe with a translator, as the
	# perl fields to write to are gone. Reading for the disassembler should be possible.
	if ($ver =~ /^\>[\d\.]+$/) {
	    $unsupp++ if $pver < substr($ver,1);# ver >10: skip if pvar lowereq 10
	} elsif ($ver =~ /^\<[\d\.]+$/) {
	    $unsupp++ if $pver >= substr($ver,1); # ver <10: skip if pvar higher than 10;
	} elsif ($ver =~ /^([\d\.]+)-([\d\.]+)$/) {
	    $unsupp++ if $pver >= $2 or $pver < $1; # ver 8-10 (both inclusive): skip if pvar
	    # lower than 8 or higher than 10;
	} elsif ($ver =~ /^[\d\.]*$/) {
	    $unsupp++ if $pver < $ver; # ver 10: skip if pvar lower than 10;
	}
    }
    # warn "unsupported $idx\t$ver\t$insn\n" if $unsupp;
    if (!$unsupp or ($] >= 5.007 and $insn !~ /pad|xcv_name_hek|unop_aux/)) {
	$insn_name[$insn_num] = $insn;
	push @insndata, [$insn_num, $unsupp, $insn, $lvalue, $rvalcast, $argtype, $flags];
	# Find the next unused instruction number
	do { $insn_num++ } while $insn_name[$insn_num];
    }
}

# calculate holes and insn_nums (number of instructions per bytecode)
my %holes = ();
my $insn_max = $insndata[$#insndata]->[0];
# %holes = (46=>1,66=>1,68=>1,107=>1,108=>1,115=>1,126=>1,127=>1,129=>1,131=>1) if $] > 5.007;
my %insn_nums;
if ($] > 5.007) {
    my %unsupps;
    for (@insndata) { $insn_nums{$_->[0]}++; } # all
    for (@insndata) { $holes{$_->[0]}++ if $_->[1] and $insn_nums{$_->[0]} == 1; }
}

my $UVxf = substr($Config{uvxformat},1,-1);
$UVxf =~ s/[\0"]//g;
$UVxf = "lx" unless $UVxf;

for (@insndata) {
    my ($unsupp, $rvalcast);
    ($insn_num, $unsupp, $insn, $lvalue, $rvalcast, $argtype, $flags) = @$_;
    $fundtype = $alias_from{$argtype} || $argtype;
    #
    # Add the initialiser line for %insn_data in Asmdata.pm
    #
    if ($unsupp) {
      print ASMDATA_PM <<"EOT" if $insn_nums{$insn_num} == 1; # singletons only
\$insn_data{$insn} = [$insn_num, 0, "GET_$fundtype"];
EOT
    } else {
      print ASMDATA_PM <<"EOT";
\$insn_data{$insn} = [$insn_num, \\&PUT_$fundtype, "GET_$fundtype"];
EOT
    }

    #
    # Add the case statement and code for the bytecode interpreter in byterun.c
    #
    # On unsupported codes add to BYTERUN CASE only for certain nums: holes.
    if (!$unsupp or $holes{$insn_num}) {
	printf BYTERUN_C "\t  case %s:\t\t/* %d */\n\t    {\n",
	  $unsupp ? $insn_num : "INSN_".uc($insn), $insn_num;
    } else {
	next;
    }
    my $optarg = $argtype eq "none" ? "" : ", arg";
    my ($argfmt, $rvaldcast, $printarg);
    if ($fundtype =~ /(strconst|pvcontents|op_tr_array)/) {
	$argfmt = '\"%s\"';
	$rvaldcast = '(char*)';
        $printarg = "${rvaldcast}arg";
    } elsif ($argtype =~ /index$/) {
	$argfmt = '0x%'.$UVxf.', ix:%d';
	$rvaldcast = "($argtype)";
        $printarg = "PTR2UV(arg)";
    } else {
	$argfmt = $fundtype =~ /^U/ ? '%u' : '%d';
	$rvaldcast = '(int)';
        $printarg = "${rvaldcast}arg";
    }
    if ($optarg) {
	print BYTERUN_C "\t\t$argtype arg;\n";
	if ($rvalcast) {
	    $argtype = $rvalcast . $argtype;
	}
	if ($unsupp and $holes{$insn_num}) {
	    printf BYTERUN_C "\t\tPerlIO_printf(Perl_error_log, \"Unsupported bytecode instruction %%d (%s) at stream offset %%d.\\n\",
	                                  insn, bstate->bs_fdata->next_out);\n", uc($insn);
	}
	print BYTERUN_C "\t\tif (force)\n\t" if $unsupp;
	if ($fundtype eq 'strconst') {
	    my $maxsize = ($flags =~ /(\d+$)/) ? $1 : 0;
	    printf BYTERUN_C "\t\tBGET_%s(arg, %d);\n", $fundtype, $maxsize;
	} else {
	    printf BYTERUN_C "\t\tBGET_%s(arg);\n", $fundtype;
	}
	printf BYTERUN_C "\t\tDEBUG_v(Perl_deb(aTHX_ \"(insn %%3d) $insn $argtype:%s\\n\",\n\t\t\t\tinsn, $printarg%s));\n",
	  $argfmt, ($argtype =~ /index$/ ? ', (int)ix' : '');
	if ($insn eq 'newopx' or $insn eq 'newop') {
	    print BYTERUN_C "\t\tDEBUG_v(Perl_deb(aTHX_ \"\t   [%s %d]\\n\", PL_op_name[arg>>7], bstate->bs_ix));\n";
	}
	if ($fundtype eq 'PV') {
	    print BYTERUN_C "\t\tDEBUG_v(Perl_deb(aTHX_ \"\t   BGET_PV(arg) => \\\"%s\\\"\\n\", bstate->bs_pv.pv));\n";
	}
    } else {
	if ($unsupp and $holes{$insn_num}) {
	    printf BYTERUN_C "\t\tPerlIO_printf(Perl_error_log, \"Unsupported bytecode instruction %%d (%s) at stream offset %%d.\\n\",
	                                  insn, bstate->bs_fdata->next_out);\n", uc($insn);
	}
	print BYTERUN_C "\t\tDEBUG_v(Perl_deb(aTHX_ \"(insn %3d) $insn\\n\", insn));\n";
    }
    if ($flags =~ /x/) {
	# Special setter method named after insn
	print BYTERUN_C "\t\tif (force)\n\t" if $unsupp;
	print BYTERUN_C "\t\tBSET_$insn($lvalue$optarg);\n";
	my $optargcast = $optarg eq ", arg" ? ",\n\t\t\t\t$printarg" : '';
	$optargcast .= ($insn =~ /x$/ and $optarg eq ", arg" ? ", bstate->bs_ix-1" : '');
	printf BYTERUN_C "\t\tDEBUG_v(Perl_deb(aTHX_ \"\t   BSET_$insn($lvalue%s)\\n\"$optargcast));\n",
	  $optarg eq ", arg"
	    ? ($fundtype =~ /(strconst|pvcontents)/
	       ? ($insn =~ /x$/ ? ', \"%s\" ix:%d' : ', \"%s\"')
	       : (", " .($argtype =~ /index$/ ? '0x%'.$UVxf : $argfmt)
	               .($insn =~ /x$/ ? ' ix:%d' : ''))
	    )
	      : '';
    } elsif ($flags =~ /s/) {
	# Store instructions to bytecode_obj_list[arg]. "lvalue" field is rvalue.
	print BYTERUN_C "\t\tif (force)\n\t" if $unsupp;
	print BYTERUN_C "\t\tBSET_OBJ_STORE($lvalue$optarg);\n";
	print BYTERUN_C "\t\tDEBUG_v(Perl_deb(aTHX_ \"\t   BSET_OBJ_STORE($lvalue$optarg)\\n\"));\n";
    }
    elsif ($optarg && $lvalue ne "none") {
	print BYTERUN_C "\t\t$lvalue = ${rvalcast}arg;\n" unless $unsupp;
	printf BYTERUN_C "\t\tDEBUG_v(Perl_deb(aTHX_ \"\t   $lvalue = ${rvalcast}%s;\\n\", $printarg%s));\n",
	  $fundtype =~ /(strconst|pvcontents)/ ? '\"%s\"' : ($argtype =~ /index$/ ? '0x%'.$UVxf : $argfmt);
    }
    print BYTERUN_C "\t\tbreak;\n\t    }\n";
}

#
# Finish off byterun.c
#
print BYTERUN_C <<'EOT';
	    default:
	      Perl_croak(aTHX_ "Illegal bytecode instruction %d at stream offset %d.\n",
                         insn, bstate->bs_fdata->next_out);
	      /* NOTREACHED */
	  }
	  /* debop is not public in 5.10.0 on strict platforms like mingw and MSVC, cygwin is fine. */
#if defined(DEBUG_t_TEST_) && !defined(_MSC_VER) && !defined(__MINGW32__) && !defined(AIX)
          if (PL_op && DEBUG_t_TEST_)
              /* GV without the cGVOPo_gv initialized asserts. We need to skip newopx */
              if ((insn != INSN_NEWOPX) && (insn != INSN_NEWOP) && (PL_op->op_type != OP_GV)) debop(PL_op);
#endif
        }
    }
    return 0;
}

/* ex: set ro: */
EOT

#
# Write the instruction and optype enum constants into byterun.h
#
open(BYTERUN_H, "> $targets[2]") or die "$targets[2]: $!";
binmode BYTERUN_H;
print BYTERUN_H $c_header, <<'EOT';
#if PERL_VERSION < 10
# define PL_RSFP PL_rsfp
#else
# define PL_RSFP PL_parser->rsfp
#endif

#if (PERL_VERSION <= 8) && (PERL_SUBVERSION < 8)
# define NEED_sv_2pv_flags
# include "ppport.h"
#endif

/* macros for correct constant construction */
# if INTSIZE >= 2
#  define U16_CONST(x) ((U16)x##U)
# else
#  define U16_CONST(x) ((U16)x##UL)
# endif

# if INTSIZE >= 4
#  define U32_CONST(x) ((U32)x##U)
# else
#  define U32_CONST(x) ((U32)x##UL)
# endif

# ifdef HAS_QUAD
typedef I64TYPE I64;
typedef U64TYPE U64;
#  if INTSIZE >= 8
#   define U64_CONST(x) ((U64)x##U)
#  elif LONGSIZE >= 8
#   define U64_CONST(x) ((U64)x##UL)
#  elif QUADKIND == QUAD_IS_LONG_LONG
#   define U64_CONST(x) ((U64)x##ULL)
#  else /* best guess we can make */
#   define U64_CONST(x) ((U64)x##UL)
#  endif
# endif

/* byte-swapping functions for big-/little-endian conversion */
# define _swab_16_(x) ((U16)( \
         (((U16)(x) & U16_CONST(0x00ff)) << 8) | \
         (((U16)(x) & U16_CONST(0xff00)) >> 8) ))

# define _swab_32_(x) ((U32)( \
         (((U32)(x) & U32_CONST(0x000000ff)) << 24) | \
         (((U32)(x) & U32_CONST(0x0000ff00)) <<  8) | \
         (((U32)(x) & U32_CONST(0x00ff0000)) >>  8) | \
         (((U32)(x) & U32_CONST(0xff000000)) >> 24) ))

# ifdef HAS_QUAD
#  define _swab_64_(x) ((U64)( \
          (((U64)(x) & U64_CONST(0x00000000000000ff)) << 56) | \
          (((U64)(x) & U64_CONST(0x000000000000ff00)) << 40) | \
          (((U64)(x) & U64_CONST(0x0000000000ff0000)) << 24) | \
          (((U64)(x) & U64_CONST(0x00000000ff000000)) <<  8) | \
          (((U64)(x) & U64_CONST(0x000000ff00000000)) >>  8) | \
          (((U64)(x) & U64_CONST(0x0000ff0000000000)) >> 24) | \
          (((U64)(x) & U64_CONST(0x00ff000000000000)) >> 40) | \
          (((U64)(x) & U64_CONST(0xff00000000000000)) >> 56) ))
# else
#  define _swab_64_(x) _swab_32_((U32)(x) & U32_CONST(0xffffffff))
# endif

#  define _swab_iv_(x,size) ((size==4) ? _swab_32_(x) : ((size==8) ? _swab_64_(x) : _swab_16_(x)))

struct byteloader_fdata {
    SV	*datasv;
    int  next_out;
    int	 idx;
};

struct byteloader_xpv {
    char *pv;
    int   cur;
    int	  len;
};

struct byteloader_header {
    char 	archname[80];
    char 	version[16];
    int 	ivsize;
    int 	ptrsize;
    int 	longsize;
    char 	byteorder[16];
    int 	archflag;
    char 	perlversion[16];
};

struct byteloader_state {
    struct byteloader_fdata	*bs_fdata;
    SV				*bs_sv;
    void			**bs_obj_list;
    int				bs_obj_list_fill;
    int				bs_ix;
    struct byteloader_xpv	bs_pv;
    int				bs_iv_overflows;
};

int bl_getc(struct byteloader_fdata *);
int bl_read(struct byteloader_fdata *, char *, size_t, size_t);
extern int byterun(pTHX_ register struct byteloader_state *);

enum {
EOT

my $add_enum_value = 0;
my ($old, $max_insn) = (-1);
enum:
for (sort {$a->[0] <=> $b->[0] } @insndata) {
  ($i, $unsupp, $insn) = @$_;
  #
  # Add ENUMS to the header
  #
  $add_enum_value = 1 if $i != $old + 1;
  if (!$unsupp) {
    $insn = uc($insn);
    $max_insn = $i;
    if ($add_enum_value) {
      my $tabs = "\t" x (4-((9+length($insn)))/8);
      printf BYTERUN_H "    INSN_$insn = %3d,$tabs/* $i */\n", $i;
      $add_enum_value = 0;
    } else {
      my $tabs = "\t" x (4-((3+length($insn))/8));
      print BYTERUN_H "    INSN_$insn,$tabs/* $i */\n";
    }
  } else {
    $add_enum_value = 1;
  }
  $old = $i;
}

print BYTERUN_H "    MAX_INSN = $max_insn\n};\n";

print BYTERUN_H "\nenum {\n";
for ($i = 0; $i < @optype - 1; $i++) {
    printf BYTERUN_H "    OPt_%s,\t\t/* %d */\n", $optype[$i], $i;
}
printf BYTERUN_H "    OPt_%s\t\t/* %d */\n};\n\n", $optype[$i], $i;

print BYTERUN_H "/* ex: set ro: */\n";

#
# Finish off insn_data and create array initialisers in Asmdata.pm
#
print ASMDATA_PM <<'EOT';

my ($insn_name, $insn_data);
while (($insn_name, $insn_data) = each %insn_data) {
    $insn_name[$insn_data->[0]] = $insn_name;
}
# Fill in any gaps
@insn_name = map($_ || "unused", @insn_name);

1;

__END__

=head1 NAME

B::Asmdata - Autogenerated data about Perl ops, used to generate bytecode

=head1 SYNOPSIS

	use B::Asmdata qw(%insn_data @insn_name @optype @specialsv_name);

=head1 DESCRIPTION

Provides information about Perl ops in order to generate bytecode via
a bunch of exported variables.  Its mostly used by B::Assembler and
B::Disassembler.

=over 4

=item %insn_data

  my($bytecode_num, $put_sub, $get_meth) = @$insn_data{$op_name};

For a given $op_name (for example, 'cop_label', 'sv_flags', etc...)
you get an array ref containing the bytecode number of the op, a
reference to the subroutine used to 'PUT' the op argument to the bytecode stream,
and the name of the method used to 'GET' op argument from the bytecode stream.

Most ops require one arg, in fact all ops without the PUT/GET_none methods,
and the GET and PUT methods are used to en-/decode the arg to binary bytecode.
The names are constructed from the GET/PUT prefix and the argument type,
such as U8, U16, U32, svindex, opindex, pvindex, ...

The PUT method is used in the L<B::Bytecode> compiler within L<B::Assembler>,
the GET method just for the L<B::Disassembler>.
The GET method is not used by the binary L<ByteLoader> module.

A full C<insn> table with version, opcode, name, lvalue, argtype and flags
is located as DATA in F<bytecode.pl>.

An empty PUT method, the number 0, denotes an unsupported bytecode for this perl.
It is there to support disassembling older perl bytecode. This was added with 1.02_02.

=item @insn_name

  my $op_name = $insn_name[$bytecode_num];

A simple mapping of the bytecode number to the name of the op.
Suitable for using with %insn_data like so:

  my $op_info = $insn_data{$insn_name[$bytecode_num]};

=item @optype

  my $op_type = $optype[$op_type_num];

A simple mapping of the op type number to its type (like 'COP' or 'BINOP').

Since Perl version 5.10 defined in L<B>.

=item @specialsv_name

  my $sv_name = $specialsv_name[$sv_index];

Certain SV types are considered 'special'.  They're represented by
B::SPECIAL and are referred to by a number from the specialsv_list.
This array maps that number back to the name of the SV (like 'Nullsv'
or '&PL_sv_undef').

Since Perl version 5.10 defined in L<B>.

=back

=head1 PORTABILITY

All bytecode values are already portable.
Cross-platform portability is implemented, cross-version not yet.

Cross-version portability will be very limited, cross-platform only
for the same threading model.

=head2 CROSS-PLATFORM PORTABILITY

For different endian-ness there are ByteLoader converters in effect.
Header entry: byteorder.

64int - 64all - 32int is portable. Header entry: ivsize

ITHREADS are unportable; header entry: archflag - bitflag 1.
MULTIPLICITY is also unportable; header entry: archflag - bitflag 2

TODO For cross-version portability we will try to translate older
bytecode ops to the current perl op via L<ByteLoader::Translate>.
Asmdata already contains the old ops, all with the PUT method 0.
Header entry: perlversion

=head2 CROSS-VERSION PORTABILITY (TODO - HARD)

Bytecode ops:
We can only reliably load bytecode from previous versions and promise
that from 5.10.0 on future versions will only add new op numbers at
the end, but will never replace old opcodes with incompatible arguments.
Unsupported insn's are supported by disassemble, and if C<force> in the
ByteLoader is set, it is tried to load/set them also, with probably fatal
consequences.
On the first unknown bytecode op from a future version - added to the end
- we will die.

L<ByteLoader::BcVersions> contains logic to translate previous errors
from this bytecode policy. E.g. 5.8 violated the 5.6 bytecode order policy
and began to juggle it around (similar to parrot), in detail removed
various bytecodes, like ldspecsvx:7, xpv_cur, xpv_len, xiv64:26.
So in theory it would have been possible to load 5.6 into 5.8 bytecode
as the underlying perl pp_code ops didn't change that much, but it is risky.

We have unused tables of all bytecode ops for all version-specific changes
to the bytecode table. This only changed with
the ByteLoader version, ithreads and major Perl versions.

Also special replacements in the byteloader for all the unsupported
ops, like xiv64, cop_arybase.

=head1 AUTHOR

Malcolm Beattie C<MICB at cpan.org> I<(retired)>,
Reini Urban added the version logic, support >= 5.10, portability.

=cut

# ex: set ro:
EOT

close ASMDATA_PM or die "Error closing $targets[0]: $!";
close BYTERUN_C or die "Error closing $targets[1]: $!";
close BYTERUN_H or die "Error closing $targets[2]: $!";
chmod 0444, @targets;

# TODO 5.10:
#   stpv (?)
#   pv_free: free the bs_pv and the SvPVX? (?)

__END__
# First set instruction ord("#") to read comment to end-of-line (sneaky)
35 0 comment	arg			comment_t
# Then make ord("\n") into a no-op
10 0 nop	none			none

# Now for the rest of the ordinary ones, beginning with \0 which is
# ret so that \0-terminated strings can be read properly as bytecode.
#
# The argtype is either a single type or "rightvaluecast/argtype".
# The version is either "i" or "!i" for ITHREADS or not,
#   "m" or "!m" for MULTI or not,
#   or num, num-num, >num or <num.
#   "0" is for all, "<10" requires PERL_VERSION<10, "10" requires
#   PERL_VERSION>=10, ">10" requires PERL_VERSION>10, "10-10"
#   requires PERL_VERSION>==10 only.
# lvalue is the (statemachine) value to read or write.
# argtype specifies the reader or writer method.
# flags x specifies a special writer method BSET_$insn in bytecode.h
# flags s store instructions to bytecode_obj_list[arg]. "lvalue" field is rvalue.
# flags \d+ specifies the maximal length.
#
# bc numbering policy: <=5.6: leave out, >=5.8 leave holes
# Note: ver 8 is really 8.001. 5.008000 had the same bytecodes as 5.006002.

#idx version opcode	lvalue				argtype		flags
#
0  0	ret		none				none		x
1  0 	ldsv		bstate->bs_sv			svindex
2  0 	ldop		PL_op				opindex
3  0 	stsv		bstate->bs_sv			U32		s
4  0 	stop		PL_op				U32		s
5  6.001 stpv		bstate->bs_pv.pv		U32		x
6  0 	ldspecsv	bstate->bs_sv			U8		x
7  8 	ldspecsvx	bstate->bs_sv			U8		x
8  0 	newsv		bstate->bs_sv			U8		x
9  8 	newsvx		bstate->bs_sv			U32		x
#10 0 	nop		none				none
11 0 	newop		PL_op				U8		x
12 8	newopx		PL_op				U16		x
13 0 	newopn		PL_op				U8		x
14 0 	newpv		none				U32/PV
15 0 	pv_cur		bstate->bs_pv.cur		STRLEN
16 0 	pv_free		bstate->bs_pv			none		x
17 0 	sv_upgrade	bstate->bs_sv			U8		x
18 0 	sv_refcnt	SvREFCNT(bstate->bs_sv)		U32
19 0 	sv_refcnt_add	SvREFCNT(bstate->bs_sv)		I32		x
20 0 	sv_flags	SvFLAGS(bstate->bs_sv)		U32
21 0 	xrv		bstate->bs_sv			svindex		x
22 0 	xpv		bstate->bs_sv			none		x
23 8	xpv_cur		bstate->bs_sv	 		STRLEN		x
24 8	xpv_len		bstate->bs_sv			STRLEN		x
25 8	xiv		bstate->bs_sv			IV		x
25 <8 	xiv32		SvIVX(bstate->bs_sv)		I32
0  <8 	xiv64		SvIVX(bstate->bs_sv)		IV64
26 0	xnv		bstate->bs_sv			NV		x
27 0 	xlv_targoff	LvTARGOFF(bstate->bs_sv)	STRLEN
28 0 	xlv_targlen	LvTARGLEN(bstate->bs_sv)	STRLEN
29 0 	xlv_targ	LvTARG(bstate->bs_sv)		svindex
30 0 	xlv_type	LvTYPE(bstate->bs_sv)		char
31 0 	xbm_useful	BmUSEFUL(bstate->bs_sv)		I32
32 <19 	xbm_previous	BmPREVIOUS(bstate->bs_sv)	U16
33 <19 	xbm_rare	BmRARE(bstate->bs_sv)		U8
34 0 	xfm_lines	FmLINES(bstate->bs_sv)		IV
#35 0 	comment		arg				comment_t
36 0 	xio_lines	IoLINES(bstate->bs_sv)		IV
37 0 	xio_page	IoPAGE(bstate->bs_sv)		IV
38 0 	xio_page_len	IoPAGE_LEN(bstate->bs_sv)	IV
39 0 	xio_lines_left 	IoLINES_LEFT(bstate->bs_sv)	IV
40 0 	xio_top_name	IoTOP_NAME(bstate->bs_sv)	pvindex
41 0 	xio_top_gv	*(SV**)&IoTOP_GV(bstate->bs_sv)	svindex
42 0 	xio_fmt_name	IoFMT_NAME(bstate->bs_sv)	pvindex
43 0 	xio_fmt_gv	*(SV**)&IoFMT_GV(bstate->bs_sv)	svindex
44 0 	xio_bottom_name IoBOTTOM_NAME(bstate->bs_sv)	pvindex
45 0 	xio_bottom_gv	*(SV**)&IoBOTTOM_GV(bstate->bs_sv) svindex
46 <10 	xio_subprocess 	IoSUBPROCESS(bstate->bs_sv)	short
47 0 	xio_type	IoTYPE(bstate->bs_sv)		char
48 0 	xio_flags	IoFLAGS(bstate->bs_sv)		char
49 8 	xcv_xsubany	*(SV**)&CvXSUBANY(bstate->bs_sv).any_ptr svindex
50 <13	xcv_stash	CvSTASH(bstate->bs_sv)		svindex
50 13	xcv_stash	bstate->bs_sv			svindex		x
51 0 	xcv_start	CvSTART(bstate->bs_sv)		opindex
52 0 	xcv_root	CvROOT(bstate->bs_sv)		opindex
53 0	xcv_gv		bstate->bs_sv			svindex		x
#  <8   xcv_filegv	*(SV**)&CvFILEGV(bstate->bs_sv)	svindex
54 0 	xcv_file	CvFILE(bstate->bs_sv)		pvindex
55 0 	xcv_depth	CvDEPTH(bstate->bs_sv)		long
56 0 	xcv_padlist	*(SV**)&CvPADLIST(bstate->bs_sv) svindex
57 0 	xcv_outside	*(SV**)&CvOUTSIDE(bstate->bs_sv) svindex
58 8 	xcv_outside_seq CvOUTSIDE_SEQ(bstate->bs_sv)	U32
59 0 	xcv_flags	CvFLAGS(bstate->bs_sv)		U16
60 0 	av_extend	bstate->bs_sv			SSize_t		x
61 8	av_pushx	bstate->bs_sv			svindex		x
62 <8 	av_push		bstate->bs_sv			svindex		x
63 <8 	xav_fill	AvFILLp(bstate->bs_sv)		SSize_t
64 <8 	xav_max		AvMAX(bstate->bs_sv)		SSize_t
65 <10 	xav_flags	AvFLAGS(bstate->bs_sv)		U8
65 10-12 xav_flags	((XPVAV*)(SvANY(bstate->bs_sv)))->xiv_u.xivu_i32 I32
66 <10 	xhv_riter	HvRITER(bstate->bs_sv)			I32
67 0 	xhv_name	bstate->bs_sv				pvindex		x
68 8-9  xhv_pmroot	*(OP**)&HvPMROOT(bstate->bs_sv)		opindex
69 0 	hv_store	bstate->bs_sv				svindex		x
70 0 	sv_magic	bstate->bs_sv				char		x
71 0 	mg_obj		SvMAGIC(bstate->bs_sv)->mg_obj		svindex
72 0 	mg_private	SvMAGIC(bstate->bs_sv)->mg_private 	U16
73 0 	mg_flags	SvMAGIC(bstate->bs_sv)->mg_flags	U8
# mg_name <5.8001 called mg_pv
74 0 	mg_name		SvMAGIC(bstate->bs_sv)			pvcontents	x
75 8 	mg_namex	SvMAGIC(bstate->bs_sv)			svindex		x
76 0 	xmg_stash	bstate->bs_sv				svindex		x
77 0 	gv_fetchpv	bstate->bs_sv				strconst	128x
78 8	gv_fetchpvx	bstate->bs_sv				strconst	128x
79 0 	gv_stashpv	bstate->bs_sv				strconst	128x
80 8 	gv_stashpvx	bstate->bs_sv				strconst	128x
81 0 	gp_sv		bstate->bs_sv				svindex		x
82 0 	gp_refcnt	GvREFCNT(bstate->bs_sv)			U32
83 0 	gp_refcnt_add	GvREFCNT(bstate->bs_sv)			I32		x
84 0 	gp_av		*(SV**)&GvAV(bstate->bs_sv)		svindex
85 0 	gp_hv		*(SV**)&GvHV(bstate->bs_sv)		svindex
86 0 	gp_cv		*(SV**)&GvCV(bstate->bs_sv)		svindex		x
87 <9 	gp_file		GvFILE(bstate->bs_sv)			pvindex
87 9 	gp_file		bstate->bs_sv				pvindex		x
88 0 	gp_io		*(SV**)&GvIOp(bstate->bs_sv)		svindex
89 0 	gp_form		*(SV**)&GvFORM(bstate->bs_sv)		svindex
90 0 	gp_cvgen	GvCVGEN(bstate->bs_sv)			U32
91 0 	gp_line		GvLINE(bstate->bs_sv)			line_t
92 0 	gp_share	bstate->bs_sv				svindex		x
93 0 	xgv_flags	GvFLAGS(bstate->bs_sv)			U8
94 0 	op_next		PL_op->op_next				opindex
95 0 	op_sibling      PL_op					opindex		x
96 0 	op_ppaddr	PL_op->op_ppaddr			strconst	24x
97 0 	op_targ		PL_op->op_targ				PADOFFSET
98 0 	op_type		PL_op					OPCODE		x
99 <9 	op_seq		PL_op->op_seq				U16
99 9 	op_opt		PL_op->op_opt				U8
100 0 	op_flags	PL_op->op_flags				U8
101 0 	op_private	PL_op->op_private			U8
102 0 	op_first	cUNOP->op_first				opindex
103 0 	op_last		cBINOP->op_last				opindex
104 0 	op_other	cLOGOP->op_other			opindex
# found in 5.5.5, not on 5.5.8. I found 5.5.6 and 5.5.7 nowhere
0   <5.008 op_true	cCONDOP->op_true			opindex
0   <5.008 op_false	cCONDOP->op_false			opindex
0   <6.001 op_children	cLISTOP->op_children			U32
105 <10 op_pmreplroot   cPMOP->op_pmreplroot			opindex
111 !i<10  op_pmreplrootgv *(SV**)&cPMOP->op_pmreplroot			svindex
106 <10 op_pmreplstart  cPMOP->op_pmreplstart				opindex
105 10  op_pmreplroot  (cPMOP->op_pmreplrootu).op_pmreplroot		opindex
106 10  op_pmreplstart  (cPMOP->op_pmstashstartu).op_pmreplstart	opindex
107 <10 op_pmnext	*(OP**)&cPMOP->op_pmnext			opindex
108 i8 	op_pmstashpv	   cPMOP					pvindex		x
109 i<10   op_pmreplrootpo cPMOP->op_pmreplroot				OP*/PADOFFSET
109 i10    op_pmreplrootpo (cPMOP->op_pmreplrootu).op_pmreplroot	OP*/PADOFFSET
110 !i8-10 op_pmstash	*(SV**)&cPMOP->op_pmstash			svindex
110 !i10   op_pmstash	*(SV**)&(cPMOP->op_pmstashstartu).op_pmreplstart svindex
111 !i10   op_pmreplrootgv *(SV**)&(cPMOP->op_pmreplrootu).op_pmreplroot svindex
112 0   pregcomp	PL_op				pvcontents	x
113 0   op_pmflags	cPMOP->op_pmflags		pmflags		x
114 <10 op_pmpermflags  cPMOP->op_pmpermflags		U16
115 8-10 op_pmdynflags   cPMOP->op_pmdynflags		U8
116 0 	op_sv		cSVOP->op_sv			svindex
0   <6  op_gv		*(SV**)&cGVOP->op_gv		svindex
117 0 	op_padix	cPADOP->op_padix		PADOFFSET
118 0 	op_pv		cPVOP->op_pv			pvcontents
119 0 	op_pv_tr	cPVOP->op_pv			op_tr_array
120 0 	op_redoop	cLOOP->op_redoop		opindex
121 0 	op_nextop	cLOOP->op_nextop		opindex
122 0 	op_lastop	cLOOP->op_lastop		opindex
123 0 	cop_label	cCOP				pvindex		x
124 i0 	cop_stashpv	cCOP				pvindex		x
125 i0 	cop_file	cCOP				pvindex		x
126 !i0 cop_stash	cCOP				svindex		x
127 !i0 cop_filegv	cCOP				svindex		x
128 0 	cop_seq		cCOP->cop_seq			U32
129 <10 cop_arybase	cCOP->cop_arybase		I32
130 0 	cop_line	cCOP->cop_line			line_t
131 8-10 cop_io		cCOP->cop_io			svindex
132 0 	cop_warnings	cCOP				svindex		x
133 0 	main_start	PL_main_start			opindex
134 0 	main_root	PL_main_root			opindex
135 8 	main_cv		*(SV**)&PL_main_cv		svindex
136 0 	curpad		PL_curpad			svindex		x
137 0 	push_begin	PL_beginav			svindex		x
138 0 	push_init	PL_initav			svindex		x
139 0 	push_end	PL_endav			svindex		x
140 8 	curstash	*(SV**)&PL_curstash		svindex
141 8 	defstash	*(SV**)&PL_defstash		svindex
142 8 	data		none				U8		x
143 8 	incav		*(SV**)&GvAV(PL_incgv)		svindex
144 8 	load_glob	none				svindex		x
145 i8 	regex_padav	*(SV**)&PL_regex_padav		svindex
146 8 	dowarn		PL_dowarn			U8
147 8 	comppad_name	*(SV**)&PL_comppad_name		svindex
148 8 	xgv_stash	*(SV**)&GvSTASH(bstate->bs_sv)	svindex
149 8 	signal		bstate->bs_sv			strconst	24x
150 8-17 formfeed	PL_formfeed			svindex
151 9-17 op_latefree	PL_op->op_latefree		U8
152 9-17 op_latefreed	PL_op->op_latefreed		U8
153 9-17 op_attached	PL_op->op_attached		U8
# 5.10.0 misses the RX_EXTFLAGS macro
154 10-10.5 op_reflags  PM_GETRE(cPMOP)->extflags	U32
154 11  op_reflags  	RX_EXTFLAGS(PM_GETRE(cPMOP))	U32
155 10 	cop_seq_low	((XPVNV*)(SvANY(bstate->bs_sv)))->xnv_u.xpad_cop_seq.xlow  U32
156 10	cop_seq_high	((XPVNV*)(SvANY(bstate->bs_sv)))->xnv_u.xpad_cop_seq.xhigh U32
157 8	gv_fetchpvn_flags bstate->bs_sv			U32		x
# restore dup to stdio handles 0-2
158 0 	xio_ifp		bstate->bs_sv	  		char		x
159 10	xpvshared	bstate->bs_sv			none		x
160 18	newpadlx	bstate->bs_sv			U8		x
161 18  padl_name	bstate->bs_sv			svindex		x
162 18  padl_sym	bstate->bs_sv			svindex		x
163 18	xcv_name_hek	bstate->bs_sv			pvindex		x
164 18	op_slabbed	PL_op->op_slabbed		U8
165 18	op_savefree	PL_op->op_savefree		U8
166 18	op_static	PL_op->op_static		U8
167 19.003 op_folded	PL_op->op_folded		U8
168 21.002-22 op_lastsib PL_op->op_lastsib		U8
168 22  op_moresib	PL_op->op_moresib		U8
169 18	newpadnlx	bstate->bs_sv					U8	x
170 22	padl_outid	((PADLIST*)bstate->bs_sv)->xpadl_outid		U32
0   22	padl_id		((PADLIST*)bstate->bs_sv)->xpadl_id     	U32
0   22	padnl_push	bstate->bs_sv					svindex		x
0   22	padnl_maxnamed	PadnamelistMAXNAMED((PADNAMELIST*)bstate->bs_sv) U32
0   22	padnl_refcnt	PadnamelistREFCNT((PADNAMELIST*)bstate->bs_sv)	U32
0   22	newpadnx	bstate->bs_sv					strconst	x
0   22	padn_stash	*(SV**)PadnameOURSTASH((PADNAME*)bstate->bs_sv) svindex
0   22	padn_type	*(SV**)PadnameTYPE((PADNAME*)bstate->bs_sv)     svindex
0   22	padn_seq_low	COP_SEQ_RANGE_LOW((PADNAME*)bstate->bs_sv)	U32
0   22	padn_seq_high	COP_SEQ_RANGE_HIGH((PADNAME*)bstate->bs_sv)	U32
0   22	padn_refcnt	PadnameREFCNT((PADNAME*)bstate->bs_sv)		U32
0   22	padn_pv		PadnamePV((PADNAME*)bstate->bs_sv)		strconst	x
0   22	padn_flags	PadnameFLAGS((PADNAME*)bstate->bs_sv)		U8
0   22	unop_aux	cUNOP_AUX->op_aux				strconst	x
0   22	methop_methsv	cMETHOPx(PL_op)->op_u.op_meth_sv		svindex
0 !i22	methop_rclass	cMETHOPx(PL_op)->op_rclass_sv			svindex
0  i22	methop_rclass	cMETHOPx(PL_op)->op_rclass_targ			PADOFFSET

