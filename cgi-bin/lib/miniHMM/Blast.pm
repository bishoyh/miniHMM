package miniHMM::Blast;
use strict;
use warnings;
use Bio::SearchIO;
use Memoize;
use File::Temp qw/tempfile/;

use base 'Exporter';
our @EXPORT_OK = qw/blast_for_relative/;

# constants
$ENV{SGE_ROOT} = '/usr/local/sge_current';
$ENV{SGE_EXECD_PORT} = '6445';
$ENV{SGE_QMASTER_PORT} = '6444';
$ENV{SGE_CELL} = 'jcvi';
$ENV{SGE_CLUSTER_NAME} = 'p6444-jcvi';

my @qsub_cmd = qw(/usr/local/sge_current/bin/lx24-amd64/qsub -P 0116 -l fast -sync y -cwd);
my $blastp_cmd = '/usr/local/bin/blastp';
my @blast_options = qw/W=10 gapE=2000 warnings notes/;
$ENV{BLASTMAT} = '/usr/local/packages/blast2/matrix';
my $yank_cmd = '/usr/local/common/yank_panda';

sub _yank_accession {
    my $accession = shift;
    my ($min_acc) = $accession =~ /^([^\|]+\|[^\|]+)/; # get db/first accession
    open my $yank_in, '-|', ($yank_cmd, '-a', $min_acc);
    local $/ = undef;
    my $fasta = <$yank_in>;
    if ($fasta =~ /Found 0 results/) {
         $fasta = undef;
    }
    close $yank_in;
    return $fasta;
}


sub _search_accession {
    my $accession = shift;
    my $db_file = shift;
    open my $db, '<', $db_file or die "Can't open $db_file\n";
    local $/ = "\n>";
    while (my $fasta_seq = <$db>) {
        if ($fasta_seq =~ /$accession/) {
            $fasta_seq =~ s/\A>?/>/s; #add > back to beginning of fasta
            $fasta_seq =~ s/>\z//s; # remove > from end of fasta
            return $fasta_seq;
        }
    }
    return; # if we didn't find anything;
}

sub get_fasta_file {
    my $accession = shift;
    my $db = shift;
    
    my $fasta;
    eval {
        $fasta = _yank_accession($accession);
    };
    if ($@ or !$fasta) {
        $fasta = _search_accession($accession, $db);
    }
    if ( not $fasta) {
        die "Could not find fasta sequence for $accession\n";
    }
    
    # save sequence
    my $fasta_file = $accession;
    $fasta_file =~ s/[^\w\.\_]+/_/g;
    $fasta_file .= '.fasta'; 
    open my $fh, ">", $fasta_file or die "Can't create $fasta_file. $!\n";
    print $fh $fasta;
    close $fh or die "Can't close $fasta_file. $!\n";
    return $fasta_file;
}

sub do_blastp {
    my $accession = shift;
    my $db = shift;
    if (not -r $db) {
        die "Can't read $db\n";
    }
    
    my $fasta_file = get_fasta_file($accession, $db);
    
    my $blast_file = "$accession.blastout";
    $blast_file =~ s/[^\w\.\_]+/_/g;
    my @cmd = (@qsub_cmd, $blastp_cmd, $db, $fasta_file, @blast_options, '-o', $blast_file);
    warn "blast command: ",join(' ', @cmd); 
    my $res = system(@cmd);
    if ($res) {
        die "Blast failed. $!";        
    }
    my $search_io = Bio::SearchIO->new(-file=>$blast_file, -format=>'blast');    
    return $search_io; 
}

memoize 'blast_for_relative';
sub blast_for_relative {
    my $accession = shift;
    my $db = shift;
    print "  blastp $db against $accession\n";
    my $search_io;
    eval {
        $search_io = do_blastp($accession, $db);
    };
    if ($@) {
        print "blast_for_relative failed for $accession, $db\n$@\n";
        return;
    }
    my $acc_species; # to be determined by looking at hits
    my %species;
    my @top_hits;
    my $top_hit;
    RESULT: while (my $search = $search_io->next_result) {
        while (my $hit = $search->next_hit ) {
            my $hit_acc = $hit->accession;
            my $hit_desc = $hit->description;
            my ($organism) = $hit_desc =~ / \{ ([^\}]+) \} /x; # i.e. anything between { and }
            my ($genus, $species) = split (/\s+/, $organism);
            $species = "$genus $species";
            print "  hit: $hit_acc ($species)\n";
            if ($accession ne $hit_acc) { # other-than-self hit
                if (! $acc_species) {
                    # save the hit if we don't know the query species
                    push @top_hits, {hit=>$hit, species=>$species};
                    $species{$species}++;
                    print "    maybe top hit? saved\n";
                }
                elsif ($species ne $acc_species) {
                    # either the self-hit was the first hit,
                    # or all the @top_hits are the same species
                    # either way, this should be the top hit
                    print "    top hit $hit_acc ($species) found\n";
                    $top_hit = $hit;
                    last RESULT;
                }
            }
            else { # self-hit
                $acc_species = $species;
                print "    self-hit\n"; 
                if (grep {$_ ne $acc_species} keys %species) {
                    ($top_hit) = map {$_->{hit}} grep {$_->{species} ne $acc_species} @top_hits;
                    print "    top hit ",$top_hit->accession," found\n";
                    last RESULT;
                }
            }
        } 
    }
    if ($top_hit) {
        return $top_hit->accession;
    }
    elsif ($top_hits[0]) {
        # return the top non-self hit if we didn't find anything outside the species
        return $top_hits[0]->{hit};
    }
    else {
        return;
    }
}
1;