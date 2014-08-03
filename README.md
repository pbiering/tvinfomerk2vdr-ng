tvinfomerk2vdr-ng
=================

TVinfo Merkzettel to VDR Importer Next Generation


This sophisticated Perl program pulls stations ('Meine Sender') and schedules ('Merkzettel') via XML interface from TVinfo and updates VDR timers accordingly (add, change, delete).

It also supports multiple TVinfo user accounts (by a shell wrapper):
 - create VDR timers with configurable folder per user
 - detects duplicate entries on 'Merkzettel' and change folder to special one
