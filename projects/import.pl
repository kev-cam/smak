#!/usr/bin/perl -s

use File::Copy;

$prj_dir=$ARGV[0];
$lcl_dir=$ARGV[1];

open(FIND,"find $prj_dir -iname makefile 2>&1 |");

while (<FIND>) {
    chomp;
    s=$prj_dir/==;
    $file = $_;
    print "$_\n";
    $sub="";
    $_ = $lcl_dir."/".$file;
    while (s=(.*?)/==) {
	if (! -d $sub.($path = $1)) {
	   mkdir $sub.$path or die "Failed - mkdir $sub.$path"; 
	}
	$sub .= "$path/";
    }
    copy($prj_dir."/".$file, $lcl_dir."/".$file) or die "$prj_dir/$_ -> $lcl_dir/$_";
}
