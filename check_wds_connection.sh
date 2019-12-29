#!/bin/sh
LOCKFILE=/var/lock/`basename "$0"`.lock
if [ -e $LOCKFILE ] && kill -0 `cat $LOCKFILE`; then
    echo "${0} already running"
    exit
fi

# make sure the lockfile is removed when we exit and then claim it
trap "rm -f ${LOCKFILE}; exit" INT TERM EXIT
echo $$ > $LOCKFILE

# do stuff
# тип сети wds моста (2 или 5) 
WDSRADIOTYPE=5
# интервал между проверками (в сек)
DELAYSUCCESS=5
# интервал проверки после перезапуска радио (в сек)
DELAYERROR=45
# количество неудачных результатов проверок со всеми пирами перед перезапуском радио
MAXBADS=2

for i in "$@"
do
case $i in
    -ds=*|--delay-success=*)
		DELAYSUCCESS="${i#*=}"
		shift # past argument=value
	;;
	-de=*|--delay-error=*)
		DELAYERROR="${i#*=}"
		shift # past argument=value
	;;
	-wrt=*|--wds-radio-type=*)
		WDSRADIOTYPE="${i#*=}"
		shift # past argument=value
	;;
	-mb=*|--max-bads=*)
		MAXBADS="${i#*=}"
		shift # past argument=value
	;;
    # -h=*|--hosts=*)
	# 	HOSTS="${i#*=}"
	# 	shift # past argument=value
	# ;;
    --default)
		DEFAULT=YES
		shift # past argument with no value
	;;
    *)
          # unknown option
    ;;
esac
done

echo "WDSRADIOTYPE	= ${WDSRADIOTYPE}"
echo "DELAYSUCCESS	= ${DELAYSUCCESS}"
echo "DELAYERROR	= ${DELAYERROR}"
echo "MAXBADS		= ${MAXBADS}"

comparemac(){ #$1-mac1 $2-mac2 $3-number of matches
	matches=0
	for i in `seq 1 12`;
	do
		if [ $(echo $1 | cut -c$i) = $(echo $2 | cut -c$i) ]; then matches=$((matches+1)); fi
	done
	if [ $matches -ge $3 ]; then
		return 0
	else 
		return 1
	fi
}

nvrg(){
	echo `nvram get ${wrt}_${*}`
	return
}

tolog() { 
	echo $@
	logger -t `basename $0`[${$}] -p user.notice $@
}

restart_radio() {
	tolog $@
	eval "/sbin/radio${WDSRADIOTYPE}_disable"
	eval "/sbin/radio${WDSRADIOTYPE}_enable"
}

check_wds_config() {
	case $WDSRADIOTYPE in
			2)      
				wrt="rt"
				;;
			5)      
				wrt="wl"
				;;
			*)
				echo "WTF radio type?!"
				return 1
				;;
	esac
	wdsapply=$(nvrg wdsapply_x)
	wdsnum=$(nvrg wdsnum_x)
	if [ $wdsapply -eq 0 ] || [ $wdsnum -eq 0 ]; then
		tolog "WDS $wds_radio_type отключен. Завершение работы."
		return 1
	fi
}

get_hosts() {
	for i in `seq 0 $((${wdsnum}-1))`;
	do
		wdspeerbssid=$(nvrg wdslist_x${i})
		lanclmacs=$(ip neighbor | sed "s/\://g" | cut -d" " -f5)
		for mac in $lanclmacs
		do
			if [ "$mac" = "FAILED" ]; then continue; fi
			comparemac $wdspeerbssid $mac 10
			if [ $? -eq 0 ]; then
				hosts="$hosts $(ip neighbor | sed "s/\://g" | grep $mac | cut -d" " -f1)"
			fi
		done
	done

	if [ $(echo $hosts | wc -w) -eq $wdsnum ]; then
		tolog "[OK]" "Все IP-адреса WDS клиентов найдены: $hosts"
		return 0
	else
		restart_radio "[FAIL]" "Не все IP-адреса WDS клиентов найдены." "Завершение работы."
		return 1
	fi
}

check_connection() {
	boolres=1;
	for host in $hosts
	do
		ping -q -c 3 -W 2 $host > /dev/null
		result=$?
		boolres=$(( $boolres && $result ))
		if [ $result -gt 0 ]; then  tolog "[FAIL]" "Ping $host"; fi
	done
	return $boolres
}

run() {
	bads=0
	while :
	do
		check_connection
		case $? in
			0)
				bads=0
				;;
			1)
				bads=$(($bads+1))
				;;
		esac
		if [ $bads -ge $MAXBADS ]
		then
			restart_radio "Перезапуск WDS"
			sleep $DELAYERROR
		else
			sleep $DELAYSUCCESS
		fi
	done
}

check_wds_config && get_hosts && run

rm -f $LOCKFILE