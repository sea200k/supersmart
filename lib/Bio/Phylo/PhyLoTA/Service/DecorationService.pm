package Bio::Phylo::PhyLoTA::Service::DecorationService;
use strict;
use warnings;
use List::Util 'sum';
use List::MoreUtils qw(pairwise uniq all);
use Bio::Phylo::PhyLoTA::Service;
use Bio::Phylo::PhyLoTA::Domain::MarkersAndTaxa;
use Bio::Phylo::PhyLoTA::Service::SequenceGetter;
use Bio::Phylo::PhyLoTA::Service::CalibrationService;
use Bio::Phylo::PhyLoTA::Service::MarkersAndTaxaSelector;
use base 'Bio::Phylo::PhyLoTA::Service';

=head1 NAME

Bio::Phylo::PhyLoTA::Service::DecorationService - Applies decorations to trees

=head1 DESCRIPTION

Applies decorations to trees to visualize the provenance of a pipeline run, e.g.
by indicating which nodes were calibrated, to which NCBI species the tips map,
which markers were included in the supermatrix, and so on.

=over

=item apply_taxon_colors

Given a taxa table (file) and a tree, applies colors to the genera. The colors
are spaced out over the RGB spectrum from (255,127,0) to (0,127,255) (with an
oscillation in the G). The colors are blended from tips to root. To each tip,
the NCBI species ID is attached with C<set_guid>.

=cut

sub apply_taxon_colors {
	my ($self,$file,$tree) = @_;
	$self->logger->debug("going to apply taxon colors using $file");
	my $mts = Bio::Phylo::PhyLoTA::Domain::MarkersAndTaxa->new;
	my @records = $mts->parse_taxa_file($file);
	$_->{'name'} =~ s/_/ /g for @records;

	# create lookup table for genus colors, which we
	# will then blend in a traversal from tips to root
	my %genera  = map { $_->{'genus'} => 1 } @records;
	
	my @genera  = keys %genera;
	my $steps   = 255 / $#genera;
	for my $i ( 0 .. $#genera ) {
		my $R = int( $i * $steps );
		my $G = abs( 127 - $R );
		my $B = 255 - $R;
		$genera{$genera[$i]} = [ $R, $G, $B ];
	}

	# apply colors
	$tree->visit_depth_first(

		# pre-order
		'-pre' => sub {
			my $n = shift;
			if ( $n->is_terminal ) {

				# lookup species record and give it color of its genus
				my $name = $n->get_name;
				my ($record) = grep { $_->{'name'} eq $name } @records;
				my ( $R, $G, $B ) = @{ $genera{ $record->{'genus'} } };
				$n->set_branch_color( [ $R, $G, $B ] );
				$n->set_guid( $record->{'species'} );
				$n->set_rank( 'species' );
			}
		},

		# post-order
		'-post' => sub {
			my $n = shift;
			my @children = @{ $n->get_children };
			if ( $n->is_internal ) {

				# average over the RGB values of the children
				my @RGBs = map { $_->get_branch_color } @children;
				my $R_mean = int( sum( map { $_->[0] } @RGBs ) / @RGBs );
				my $G_mean = int( sum( map { $_->[1] } @RGBs ) / @RGBs );
				my $B_mean = int( sum( map { $_->[2] } @RGBs ) / @RGBs );
				$n->set_branch_color( [ $R_mean, $G_mean, $B_mean ] );
			}
		}
	);
}

=item apply_markers

Given a marker file, a tree and an argument to distinguis 'backbone' from 'clade',
sets the following annotations:

- backbone exemplar tips are given a true value for the 'exemplar' key in the generic hash
- exemplar tips are given a hash of marker ID to accession mappings under 'backbone'
- backbone nodes are given hash of marker ID to n seqs mappings under 'backbone'
- the root is given a hash of marker ID to marker name mappings under 'markers'

=cut

sub apply_markers {
	my ($self,$file,$tree,$type) = @_;
	my $logger = $self->logger;
	$logger->debug("going to apply $type markers using $file");
	my $mt = Bio::Phylo::PhyLoTA::Domain::MarkersAndTaxa->new;
	my $sg  = Bio::Phylo::PhyLoTA::Service::SequenceGetter->new;
	my @records   = $mt->parse_taxa_file($file);
	my $predicate = $type . '_markers'; 

	# iterate over record, add generic annotation to all nodes on the path
	# listing which markers and accessions participated in the node
	for my $r ( @records ) {
		if ( my $tip = $tree->get_by_name( $r->{'taxon'} ) ) {
			$tip->set_generic( 'exemplar' => 1 ) if $type eq 'backbone';

			# store marker ID and accession number
			my %markers;
			for my $m ( @{ $r->{'keys'} } ) {
				next if $m eq 'taxon';
				$markers{$m} = $r->{$m} if $r->{$m} and $r->{$m} =~ m/\S/;
			}
			$tip->set_generic( $predicate => \%markers );
			$logger->debug("attached ".scalar(keys(%markers))." $type markers to ".$r->{'taxon'});

			# start the counts at 1
			my %counts = map { $_ => 1 } keys %markers;
			my $ancestors = 0;
			NODE: for my $node ( @{ $tip->get_ancestors } ) {

				# may have visited node from another descendent, need
				# to add current counts
				if ( my $h = $node->get_generic($predicate) ) {
					$h->{$_} += $counts{$_} for keys %counts;
					my %copy = %$h;
					$node->set_generic( $predicate => \%copy );
				}
				else {
					my %copy = %counts;
					$node->set_generic( $predicate => \%copy );
				}
				last NODE if $node->get_meta_object('fig:clade');
				$ancestors++;
			}
			$logger->debug("updated annotations for $ancestors ancestors");
		}
		else {
			# XXX this really shouldn't happen, yet it did on @rvosa's bunch
			# of primate files. Possibly this is because I had been poking around
			# merging files under different settings?
			$logger->debug("Couldn't find taxon '".$r->{'taxon'}."' from file $file");
		}
	}

	# get marker names
	my %markers;
	my @markers_table = $mt->parse_taxa_file( $file );

	for my $row ( @markers_table ) {
		my %h = %$row;
		my @cols = @{$h{'keys'}};
		for my $c ( 1 .. $#cols ) {			
			if ( my $marker = $h{$c} ) {
				$markers{$marker} = $marker;
			}
		}
	}	
	$tree->get_root->set_generic( $predicate => \%markers );
}

=item apply_fossil_nodes

Given a fossil table and a tree, attaches a hash describing a calibration
point to each appropriate fossil node, under the 'fossil' key in the
generic hash.

=cut

sub apply_fossil_nodes {
	my ($self,$file,$tree) = @_;
	$self->logger->debug("going to apply fossil nodes using $file");

	# read fossil table and convert to calibration table
	my $mts = Bio::Phylo::PhyLoTA::Service::MarkersAndTaxaSelector->new;
	my $cs  = Bio::Phylo::PhyLoTA::Service::CalibrationService->new;
	my @records = $cs->read_fossil_table($file);
	@records = map { $cs->find_calibration_point($_) } @records;

	# taxize, if need be
	my @prune;
	$tree->visit(sub{
		my $n = shift;
		my $name = $n->get_name;

		# tip doesn't have TI as name
		if ( $n->is_terminal and $name !~ /^\d+$/ ) {

			# already taxized using species.tsv
			if ( my $ti = $n->get_guid ) {
				$n->set_generic( 'binomial' => $name );
				$n->set_name($ti);
			}
			else {
				$self->logger->info("taxize: $name");
				if ( my ($node) = $mts->get_nodes_for_names($name) ) {
					$n->set_name($node->ti);
					$n->set_guid($node->ti);
					$n->set_generic( 'binomial' => $name );
				}
				else {
					push @prune, $n;
				}
			}
		}
	});
	$tree->prune_tips(\@prune) if @prune;
	my $table = $cs->create_calibration_table($tree,@records);

	# apply calibration points
	my %desc;
	$tree->visit_depth_first(
		'-post' => sub {
			my $n  = shift;
			my $id = $n->get_id;

			# start list of descendants
			if ( $n->is_terminal ) {
				$desc{$id} = [ $n->get_name ];
			}

			# extend, see if fossil found
			else {
				my @desc;
				$n->visit(sub{ push @desc, @{ $desc{shift->get_id} }});
				my @sorted = sort { $a cmp $b } @desc;
				$desc{$id} = [ uniq @sorted ];

				# iterate over fossils
				for my $f ( $table->get_rows ) {
					my @taxa = map { join ' ', split /_/, $_ } sort { $a cmp $b } $f->taxa;

					# match found
					if ( @sorted == @taxa and all { $sorted[$_] eq $taxa[$_] } 0 .. $#sorted ) {
						$n->set_generic( 'fossil' => {
							'name'    => $f->name,
							'min_age' => $f->min_age,
							'max_age' => $f->max_age,
						} );
					}
				}
			}
		}
	);
}

=back

=cut

1;