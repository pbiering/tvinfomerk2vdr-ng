tvinfomerk2vdr-ng
=================

SERVICE to DVR timer importer Next Generation

supported SERVICEs so far: TVinfo (Merkzettel)

supported DVRs: vdr, tvheadend

supported SYSTEMs: ReelBox (vdr), OpenELEC (tvheadend)


This sophisticated Perl program pulls channels and timers from supported SERVICE and updates DVR timers accordingly (add, change, delete).

It also supports multiple SERVICE user accounts (by a shell wrapper):
 - create DVR timers with configurable folder per user
 - detects duplicate timer entries and change folder to special one (covering more than one user)

It also supports multiple TVinfo user accounts (by a shell wrapper):
 - create VDR timers with configurable folder per user
 - detects duplicate entries on 'Merkzettel' and change folder to special one

******
 See now also devel branch for new features
******
