#!/software/perl-5.16.3/bin/perl

##########LICENCE############################################################
# Copyright (c) 2016 Genome Research Ltd.
# 
# Author: Cancer Genome Project cgpit@sanger.ac.uk
# 
# This file is part of cgpVAF.
# 
# cgpVAF is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation; either version 3 of the License, or (at your option) any
# later version.
# 
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
# 
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.
##########LICENCE##############################################################

BEGIN {
  use Cwd qw(abs_path);
  use File::Basename;
  $ENV{POSIXLY_CORRECT}=1;
  unshift (@INC,dirname(abs_path($0)).'/../lib');
  $SIG{__WARN__} = sub {warn $_[0] unless(( $_[0] =~ m/^Subroutine Tabix.* redefined/) || ($_[0] =~ m/^Use of uninitialized value \$buf/) || ($_[0] =~ m/gzip: stdout: Broken pipe/))};
};

use strict;
#$main::SQL_LIB_LOC = '.'; # this suppresses warnings about uninitialised values

use File::Path qw(mkpath);
use FindBin qw($Bin);
use English qw( -no_match_vars );
use Pod::Usage qw(pod2usage);
use warnings FATAL => 'all';
use Carp;
use Const::Fast qw(const);
use Getopt::Long;
use Data::Dumper;
use Try::Tiny qw(try catch finally);
use Capture::Tiny qw(:all);


use Log::Log4perl;

use Sanger::CGP::Vaf::Data::ReadVcf;
use Sanger::CGP::Vaf::VafConstants;

my $log = Log::Log4perl->get_logger(__PACKAGE__);

my $store_results;
my $chr_results;

my @tags=qw(FAZ FCZ FGZ FTZ RAZ RCZ RGZ RTZ MTR WTR DEP MDR WDR OFS);

try {
	my ($options) = option_builder();
	
	if ($options->{'a'} eq 'indel') {
    	@tags=qw(MTR WTR DEP AMB MDR WDR OFS);
  }
	my $vcf_obj = Sanger::CGP::Vaf::Data::ReadVcf->new($options);
	# this is called only once to add allSample names to vcf object
	$vcf_obj->getAllSampleNames;
	my($info_tag_val,$updated_info_tags,$vcf_file_obj)=$vcf_obj->getVcfHeaderData;
	my($variant,$bam_header_data,$bam_objects)=$vcf_obj->getVarinatObject($info_tag_val);
	my($bed_locations)=$vcf_obj->getBedHash;
	my ($chromosomes)=$vcf_obj->getChromosomes;
	my($progress_fhw,$progress_data)=$vcf_obj->getProgress;
	
	foreach my $chr(@$chromosomes) {
		my($data_for_all_samples,$unique_locations)=$vcf_obj->getMergedLocations($chr,$updated_info_tags,$vcf_file_obj);
		if(defined $options->{'b'} ){
			($bed_locations)=$vcf_obj->filterBedLocations($unique_locations,$bed_locations);	
		}	
		($store_results)=$vcf_obj->processMergedLocations($data_for_all_samples,$unique_locations,$variant,$bam_header_data,$bam_objects,$store_results,$chr,\@tags,$info_tag_val,$progress_fhw,$progress_data);
		$log->debug("Completed analysis for: $chr ");
	}# completed all chromosomes;
	
	if(defined $bed_locations) {
		my($data_for_all_samples,$unique_locations)=$vcf_obj->populateBedLocations($bed_locations,$updated_info_tags);
		($store_results)=$vcf_obj->processMergedLocations($data_for_all_samples,$unique_locations,$variant,$bam_header_data,$bam_objects,$store_results,'bed_file_data',\@tags,$info_tag_val,$progress_fhw,$progress_data);	
	}
	
	#
  if(defined $store_results && defined $options->{'m'}) {
      my($aug_vcf_fh,$aug_vcf_name)=$vcf_obj->WriteAugmentedHeader();
    	$vcf_obj->writeResults($aug_vcf_fh,$store_results,$aug_vcf_name); 
  }
  
  my($outfile_name_no_ext)=$vcf_obj->writeFinalFileHeaders($info_tag_val);
  
  if(defined $outfile_name_no_ext){
  	foreach my $progress_line(@$progress_data) {
			chomp $progress_line;
			if ($progress_line eq "$outfile_name_no_ext.tsv") {
				$log->debug("Skipping Analysis: result file: $outfile_name_no_ext.vcf exists");
				close $progress_fhw;
				exit(0);
			}
		}
		$vcf_obj->catFiles($options->{'tmp'},'vcf',$outfile_name_no_ext);
		$vcf_obj->catFiles($options->{'tmp'},'tsv',$outfile_name_no_ext);
		$log->debug("Compressing and Validating VCF file");
		my($outfile_gz,$outfile_tabix)=$vcf_obj->compressVcf("$outfile_name_no_ext.vcf");
		print $progress_fhw "$outfile_name_no_ext.tsv\n";
		close $progress_fhw;
		
  }

}
	
catch {
  croak "\n\n".$_."\n\n" if($_);
};

# get options from user

sub option_builder {
        my ($factory) = @_;
        my %options;
        &GetOptions (
                'h|help'    => \$options{'h'},
                't|infoTags=s' => \$options{'t'},
                'd|inputDir=s' => \$options{'d'},
                'b|bedIntervals=s' => \$options{'b'},
                'e|vcfExtension=s' => \$options{'e'},
                'c|hdr_cutoff=i' => \$options{'c'},
                'g|genome=s' => \$options{'g'},
                'a|variant_type=s' => \$options{'a'},
                'r|restrict_flag=i' => \$options{'r'},
                'o|outDir=s'  => \$options{'o'},
                'm|augment=i' => \$options{'m'},
                'ao|augment_only=i' => \$options{'ao'},
                # provide at least 1 tumour samples name
                'tn|tumour_name=s{1,}' => \@{$options{'tn'}},
                'nn|normal_name=s' => \$options{'nn'},
                'bo|bed_only=i' => \$options{'bo'},
                'oe|output_vcfExtension=s' => \$options{'oe'},
                'tmp|tmpdir=s' => \$options{'tmp'},
                'dp|depth=s' => \$options{'dp'},
                'pid|id_int_project=s' => \$options{'pid'},
                'vn|vcf_normal=i' => \$options{'vn'},
                'v|version'  => \$options{'v'}
	);
	
  pod2usage(-message => Sanger::CGP::Vaf::license, -verbose => 1) if(defined $options{'h'});
        
	if(defined $options{'v'}){
		print $Sanger::CGP::Vaf::VafConstants::VERSION."\n";
		exit;
	}
	pod2usage(q{'-g' genome must be defined}) unless (defined $options{'g'});
	pod2usage(q{'-d' input directory path must be defined}) unless (defined $options{'d'});
	pod2usage(q{'-a' variant type must be defined}) unless (defined $options{'a'});
	pod2usage(q{'-tn' toumour sample name/s must be provided}) unless (defined $options{'tn'});
	pod2usage(q{'-nn' normal sample name/s must be provided}) unless (defined $options{'nn'});
  pod2usage(q{'-e' Input vcf file extension must be provided}) unless (defined $options{'e'} || defined $options{'bo'});
	pod2usage(q{'-b' bed file must be specified }) unless (!defined $options{'e'} || !defined $options{'bo'});
  pod2usage(q{'-o' Output folder must be provided}) unless (defined $options{'o'});
	if(!defined $options{'bo'}) { $options{'bo'}=0;}
	mkpath($options{'o'});
	if(!defined $options{'tmp'}) {
		mkpath($options{'o'}.'/tmpvaf');
		$options{'tmp'}=$options{'o'}.'/tmpvaf';
	}
	if(!defined $options{'vn'}) { $options{'vn'}=1;}
	if(defined $options{'a'} and ( (lc($options{'a'}) eq 'indel') || (lc($options{'a'}) eq 'snp') ) ) {	
		warn "Analysing:".$options{'a'}."\n";
	}
	else{
		$log->logcroak("Not a valid variant type [should be either [snp or indel]");	
		exit(0); 
	}	
 	# use annotation tags
	if(!defined $options{'t'}) { 
		$options{'t'}="VD,VW,VT,VC";
	}
	#use tabix file 
	if(!defined $options{'c'}) {
		$options{'c'}='005';
	}
	# use PASS flag
	if(!defined $options{'r'}) {
		$options{'r'}= 1;
	}
	if($options{'a'} eq 'indel' && !defined $options{'dp'}) {
		$options{'dp'}='NR,PR';
	}
	
	if(!defined $options{'s'}) {
		#analyse single sample no merge step 
		$options{'s'}=undef;
	}
	if(!defined $options{'ao'}) {
		# augment vcf no merging step
		$options{'ao'}=undef;
	}
	if(!defined $options{'oe'}) {
		# augment vcf extesnion
		$options{'oe'}='.vaf.vcf';
	}
	
 \%options;
}

__END__

=head1 NAME

vaf.pl merge the variants in vcf files for a given Tumour - normal pairs in a project  and write pileup and exonerate output for merged locations

=head1 SYNOPSIS

vaf.pl [-h] -d -a  -tn -nn -b -e  -o[ -t -c -r -g -f -v]

  Required Options (inputDir and variant_type must be defined):

   --variant_type  (-a)  variant type (snp or indel) [default snp]
   --inputDir      (-d)  input directory path
   --genome        (-g)  genome fasta file name (default genome.fa)
   --tumour_name   (-tn) Toumour sample name [ list of space separated names in same order as input files ]
   --normal_name   (-nn) Normal sample name
   --outDir        (-o)  Output folder
   --vcfExtension  (-e)  vcf file extension string after the sample name - INCLUDE's dot (default: .caveman_c.annot.vcf.gz) 

  Optional
   --infoTags      (-t)  comma separated list of tags to be included in the vcf INFO field 
                         (default: VD,VW,VT,VC for Vagrent annotations)
   --bedIntervals  (-b)  tab separated file containing list of intervals in the form of <chr><pos> <ref><alt> (e.g 1  14000  A  C)
                         bed file can be specified in the config file after the last sample pair,
                         if specified on command line then same bed file is used for all the tumour/normal pairs,
                         bed file name in config file overrides command line argument
   --hdr_cutoff    (-c)  High Depth Region(HDR) cutoff  value[ avoids extreme depth regions (default: 005 i.e top 0.05% )]
                         (possible values 001,005,01,05 and 1)
   --restrict_flag (-r)  restrict analysis on (possible values 1 : PASS or 0 : ALL) [default 1 ]   
   --augment       (-m)  Augment pindel file [ this will add additional fields[ MTR, WTR, AMB] to FORMAT column of NORMAL and TUMOUR samples ] (default 0: don not augment)
   --augment_only  (-ao) Only augment pindel VCF file (-m must be specified) [ do not  merge input files and add non passed varinats to output file ] (default 0: augment and merge )
   --depth         (-dp)  comma separated list of field(s) as specified in FORMAT field representing total depth at given location
   --id_int_project(-pid) Internal project id [WTSI only]
   --bed_only      (-bo) Only analyse bed intervals in the file (default 0: analyse vcf and bed interval)
   --vcf_normal    (-vn) use normal sample defined in vcf header field [ default 1 ]
   --help          (-h)  Display this help message
   --version       (-v)  provide version information for vaf

   Examples:
      Merge vcf files to create single vcf containing union of all the variant sites and provides pileup output for each location
      perl vaf.pl -d tmpvcfdir -o testout -a snp -g genome.fa -e .caveman_c.annot.vcf.gz -nn PD21369b -tn PD26296a PD26296c2 
      Merge vcf files to create single vcf containing union of all the variant sites and provides allele count for underlying location
      perl vaf.pl -d tmpvcfdir -o testout -a indel -g genome.fa -e .caveman_c.annot.vcf.gz -nn PD21369b -tn PD26296a PD26296c2
=cut

