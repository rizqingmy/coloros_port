#!/bin/bash
# blockdev --getsize64 /dev/block/by-name/super
device_code=$1
case $device_code in
	OnePlus9R) size=9932111872;;
	OnePlus8T) size=7516192768;;
    OnePlus8 | OnePlus8Pro) size=15032385536;;
	#Oppo find X3
	OP4E5D | OnePlus9 | OnePlus9Pro ) size=11190403072;;
    #Oppo Find X3 Pro
    OP4E3F | OP4F57L1) size=11186208768;;
	RE54E4L1| RMX3371) size=11274289152;;
	# Oplus ACE3V
	OP5CFBL1) size=16106127360;; 
    #OP5CFBL1) size=16105078784;;
    # Gt neo2
	RE5473 | RE879AL1) size=10200547328;;
    # OnePlus Ace 5
	OP5D2BL1) size=14574100480;;
	# OnePlus 13
	OP5D0DL1) size=15354134528;;
	# OnePlus 13T
	OP60F5L1) size=14952693760;;

	#Others
	*) size=15032385536;;
esac
echo $size
